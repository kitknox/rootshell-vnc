import Foundation

/// Keeps remote audio's lead over the render clock just above what recent
/// arrivals needed. Excess lead drains by playing slightly fast and a thin
/// lead rebuilds by playing slightly slow, so latency moves without the
/// audible gap of re-anchoring the timeline.
struct AppleRemoteAudioLeadController: Sendable {
    struct Adjustment: Equatable, Sendable {
        /// Synchronizer rate to hold for `durationNanos`, then return to 1.
        let rate: Float
        let durationNanos: UInt64
        /// Change in lead once the adjustment completes.
        let leadChangeNanos: Int64

        /// Too far ahead to drain by rate: restart playback at the live edge.
        var skipsBacklog: Bool { durationNanos == 0 }
    }

    static let bucketNanos: UInt64 = 1_000_000_000
    static let baseHorizonBuckets = 4
    static let maximumHorizonBuckets = 32
    /// Pitch-corrected and inaudible on speech and music.
    static let rateOffset = 0.04
    static let drainHysteresisNanos: Int64 = 10_000_000
    static let maximumLeadChangeNanos: Int64 = 150_000_000
    static let safetyNanos: Int64 = 15_000_000
    /// Lead this far beyond the starting cushion, held for a whole bucket,
    /// is buffered audio that would take many seconds to drain.
    static let backlogNanos: Int64 = 200_000_000
    /// Late-free time before the drain horizon halves again.
    static let horizonRelaxNanos: UInt64 = 60_000_000_000

    /// Slack an arrival needs before the renderer has already played past it.
    private(set) var rendererLeadNanos: Int64
    private var startLeadNanos: Int64 = 0
    private var completedBuckets: [Int64] = []
    private var bucketMinimum: Int64?
    private var bucketStartNanos: UInt64 = 0
    private(set) var horizonBuckets = baseHorizonBuckets
    private var lastLateNanos: UInt64 = 0
    private var pendingLeadChangeNanos: Int64?

    init(rendererLeadNanos: Int64) {
        self.rendererLeadNanos = rendererLeadNanos
    }

    /// Slack every arrival should keep: renderer lead plus a little jitter.
    var floorNanos: Int64 { rendererLeadNanos + Self.safetyNanos }

    var isAdjusting: Bool { pendingLeadChangeNanos != nil }

    /// A new timeline: earlier slack measurements no longer apply.
    mutating func restartTimeline(
        rendererLeadNanos: Int64,
        startLeadNanos: Int64 = 0,
        nowNanos: UInt64
    ) {
        self.rendererLeadNanos = rendererLeadNanos
        self.startLeadNanos = startLeadNanos
        clearMeasurements(nowNanos: nowNanos)
        pendingLeadChangeNanos = nil
    }

    /// The timeline was re-anchored after audio arrived too late to play.
    mutating func noteUnderrun(nowNanos: UInt64) {
        widenHorizon(nowNanos: nowNanos)
        pendingLeadChangeNanos = nil
    }

    /// Record one arrival's slack: its presentation time minus the render
    /// clock. Returns a rate change to start, if one is due.
    mutating func noteArrival(slackNanos: Int64, nowNanos: UInt64) -> Adjustment? {
        if slackNanos < rendererLeadNanos {
            // Partly played as silence: rebuild now, even mid-drain, and
            // drain more cautiously from here on.
            if let pending = pendingLeadChangeNanos, pending > 0 { return nil }
            widenHorizon(nowNanos: nowNanos)
            return begin(leadChangeNanos: floorNanos - slackNanos)
        }
        guard pendingLeadChangeNanos == nil else { return nil }
        if bucketMinimum == nil { bucketStartNanos = nowNanos }
        bucketMinimum = min(bucketMinimum ?? slackNanos, slackNanos)
        guard nowNanos &- bucketStartNanos >= Self.bucketNanos,
              let minimum = bucketMinimum else { return nil }
        completedBuckets.append(minimum)
        if completedBuckets.count > Self.maximumHorizonBuckets {
            completedBuckets.removeFirst(
                completedBuckets.count - Self.maximumHorizonBuckets)
        }
        bucketMinimum = nil
        relaxHorizonIfSettled(nowNanos: nowNanos)

        if minimum < floorNanos {
            return begin(leadChangeNanos: floorNanos - minimum)
        }
        if minimum > max(floorNanos, startLeadNanos) + Self.backlogNanos {
            // Even the worst arrival was far ahead: buffered audio, not jitter.
            clearMeasurements(nowNanos: nowNanos)
            return Adjustment(
                rate: 1, durationNanos: 0, leadChangeNanos: floorNanos - minimum)
        }
        // Draining needs the whole horizon to agree, so periodic spikes
        // keep the lead they need.
        guard completedBuckets.count >= horizonBuckets,
              let horizonMinimum = completedBuckets.suffix(horizonBuckets).min(),
              horizonMinimum > floorNanos + Self.drainHysteresisNanos else {
            return nil
        }
        return begin(leadChangeNanos: floorNanos - horizonMinimum)
    }

    /// The rate change ran its course. Slack is measured afresh, because the
    /// lead rarely moves by exactly what was asked.
    mutating func finishAdjustment(nowNanos: UInt64) {
        guard pendingLeadChangeNanos != nil else { return }
        pendingLeadChangeNanos = nil
        clearMeasurements(nowNanos: nowNanos)
    }

    private mutating func begin(leadChangeNanos: Int64) -> Adjustment {
        let change = max(
            -Self.maximumLeadChangeNanos,
            min(Self.maximumLeadChangeNanos, leadChangeNanos))
        pendingLeadChangeNanos = change
        // Playing slow builds lead; playing fast spends it.
        let rate = change > 0 ? 1 - Self.rateOffset : 1 + Self.rateOffset
        return Adjustment(
            rate: Float(rate),
            durationNanos: UInt64(Double(change.magnitude) / Self.rateOffset),
            leadChangeNanos: change)
    }

    private mutating func widenHorizon(nowNanos: UInt64) {
        horizonBuckets = min(horizonBuckets * 2, Self.maximumHorizonBuckets)
        lastLateNanos = nowNanos
        clearMeasurements(nowNanos: nowNanos)
    }

    private mutating func relaxHorizonIfSettled(nowNanos: UInt64) {
        guard horizonBuckets > Self.baseHorizonBuckets,
              nowNanos &- lastLateNanos >= Self.horizonRelaxNanos else { return }
        horizonBuckets /= 2
        lastLateNanos = nowNanos
    }

    private mutating func clearMeasurements(nowNanos: UInt64) {
        completedBuckets.removeAll(keepingCapacity: true)
        bucketMinimum = nil
        bucketStartNanos = nowNanos
    }
}
