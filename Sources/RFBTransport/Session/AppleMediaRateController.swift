import Foundation

/// Receiver-side capacity estimator for Apple's adaptive HEVC stream.
///
/// The previous implementation advertised its requested target as measured
/// bandwidth. That feedback loop could never discover spare capacity quickly.
/// This controller keeps a
/// capacity estimate separate from observed screen activity. Confirmed loss or
/// confirmed transport loss multiplicatively reduces the estimate. Recovery
/// is deliberately utilization-gated: an idle desktop is not evidence that a
/// link can sustain a higher motion bitrate. RCTL is advisory feedback; this
/// class does not impose a second congestion controller.
final class AppleMediaRateController {
    /// Apple's screen-video RTP profile uses a 24 kHz media clock. Captured
    /// native 60-fps traffic advances by 400 ticks per frame (`0x190`), not
    /// the 1,500 ticks a conventional 90 kHz video clock would use.
    static let screenRTPClockRate: Double = 24_000

    /// The negotiated screen profile uses a 20 Mbps minimum and 40/60 Mbps
    /// maxima. Receiver feedback may still report a lower path estimate, so the
    /// controller must not clamp its RCTL value to the media arbitration range.
    static let nativeScreenMinimumBitrateBps: Double = 20_000_000
    /// The negotiated low-latency screen tiers include 40 and 60 Mbps maxima.
    /// The estimator ceiling uses the 60 Mbps tier for every bearer: a flat
    /// 40 Mbps ceiling starved large virtual displays (a 4288x3072 compound
    /// stream at 40 Mbps is ~3 bits/px/s under motion — visible pulsing
    /// macroblocks with zero loss), and modern Wi-Fi frequently outruns wired.
    /// The bearer sets only the conservative initial prior; the utilization-
    /// gated ramp and loss backoff decide what a path actually sustains. RCTL's
    /// UInt16 kbps field keeps everything below 65.5 Mbps representable.
    static let nativeScreenMaximumBitrateBps: Double = 60_000_000

    private struct Config {
        let minimumCapacity: Double
        let maximumCapacity: Double
        let initialCapacity: Double
        let targetUtilization: Double
        let rampFactor: Double
        let startupRampFactor: Double
        let decreaseFactor: Double
        let utilizationThreshold: Double
        let headroomFactor: Double
        let rampInterval: Double
        let startupRampInterval: Double
        let cooldown: Double
        let backoffInterval: Double
        let throughputWindow: Double
        let updateInterval: Double
        let recoveryMinimumCapacity: Double
        let recoveryQuietInterval: Double
        let recoveryQueueDelayVetoSeconds: Double

        static func fromEnvironment(
            minimumCapacity: Double,
            maximumCapacity: Double,
            defaultInitialCapacity: Double?
        ) -> Config {
            let env = ProcessInfo.processInfo.environment
            func value(_ key: String, default fallback: Double) -> Double {
                env[key].flatMap(Double.init) ?? fallback
            }
            let minimum = value(
                "ROOTSHELL_VNC_RC_MIN_KBPS",
                default: minimumCapacity / 1_000
            ) * 1_000
            let maximum = value(
                "ROOTSHELL_VNC_RC_MAX_KBPS",
                default: maximumCapacity / 1_000) * 1_000
            let initial = value(
                "ROOTSHELL_VNC_RC_INIT_KBPS",
                default: (defaultInitialCapacity ?? maximum) / 1_000) * 1_000
            return Config(
                minimumCapacity: minimum,
                maximumCapacity: max(minimum, maximum),
                initialCapacity: min(maximum, max(minimum, initial)),
                // The negotiated media profile already owns its codec
                // headroom. Applying another factor here kept feedback below
                // the profile's real 20/40/60/75/100 Mbps tiers.
                targetUtilization: value("ROOTSHELL_VNC_RC_TARGET_UTILIZATION", default: 1.0),
                // Conservative AIMD uses exponential congestion backoff and
                // continuous recovery. A
                // 10% probe avoids our former 32 -> 40 Mbps one-step pulse.
                rampFactor: value("ROOTSHELL_VNC_RC_RAMP_FACTOR", default: 1.10),
                // Before the first congestion signal, quickly test beyond the
                // route prior. This lets excellent 5G/Wi-Fi links reach full
                // quality without treating their radio class as a cap.
                startupRampFactor: value(
                    "ROOTSHELL_VNC_RC_STARTUP_RAMP_FACTOR",
                    default: 1.35),
                decreaseFactor: value("ROOTSHELL_VNC_RC_DECREASE_FACTOR", default: 0.75),
                utilizationThreshold: value(
                    "ROOTSHELL_VNC_RC_UTILIZATION_THRESHOLD",
                    default: 0.80),
                headroomFactor: value("ROOTSHELL_VNC_RC_HEADROOM", default: 1.10),
                rampInterval: value("ROOTSHELL_VNC_RC_RAMP_INTERVAL", default: 1.0),
                startupRampInterval: value(
                    "ROOTSHELL_VNC_RC_STARTUP_RAMP_INTERVAL",
                    default: 0.5),
                cooldown: value("ROOTSHELL_VNC_RC_COOLDOWN", default: 5.0),
                backoffInterval: value("ROOTSHELL_VNC_RC_BACKOFF_INTERVAL", default: 0.25),
                throughputWindow: value("ROOTSHELL_VNC_RC_TPUT_WINDOW", default: 0.50),
                updateInterval: value("ROOTSHELL_VNC_RC_UPDATE_INTERVAL", default: 0.05),
                // Defaults to the native floor so recovery episodes cannot
                // advertise a rate the negotiated profile never expects; may be
                // lowered in the field for paths that cannot sustain 20 Mbps.
                recoveryMinimumCapacity: min(minimum, value(
                    "ROOTSHELL_VNC_RC_RECOVERY_MIN_KBPS",
                    default: minimum / 1_000) * 1_000),
                recoveryQuietInterval: value(
                    "ROOTSHELL_VNC_RC_RECOVERY_QUIET",
                    default: 0.25),
                recoveryQueueDelayVetoSeconds: value(
                    "ROOTSHELL_VNC_RC_RECOVERY_QDELAY_VETO_MS",
                    default: 50) / 1_000)
        }
    }

    private struct ByteSample {
        let time: Double
        let bytes: Int
    }

    private let config: Config
    private var byteSamples: [ByteSample] = []
    private var byteSampleHead = 0
    private var byteSampleTotal = 0
    private var capacityEstimate: Double
    private var target: Double
    private var lastUpdate: Double?
    private var lastRamp: Double?
    private var cooldownUntil: Double = 0
    private var lastBackoff: Double?
    private var hasExperiencedCongestion = false
    private var lastCongestionTime: Double?
    private var confirmedLossPending = false
    private var intervalReceived = 0
    private var intervalLost = 0
    private var intervalMaximumQueueDelay = 0.0
    private(set) var lastMaximumQueueDelaySeconds = 0.0
    private(set) var peakQueueDelaySeconds = 0.0
    private var recoveryEpisodeActive = false
    private(set) var recoveryAttemptCount = 0

    // Apple's feedback-only receiver estimates one-way queue growth from the
    // first packet of each forward-moving RTP timestamp. Send time is the
    // 90 kHz RTP clock; receive time is truncated to a 1 kHz clock. OWRD is
    // the positive difference between a 10% short EMA and a 0.01% long EMA
    // of that clock drift. Keeping this state here reproduces the algorithm
    // using ordinary RTP metadata.
    private var owrdPreviousRTPTimestamp: UInt32?
    private var owrdFirstSendTimestamp: UInt32?
    private var owrdFirstReceiveTimestamp: UInt32?
    private var owrdShortAverageLag: Double?
    private var owrdLongAverageLag: Double?
    private(set) var owrdSeconds: Double = 0

    init(
        minTargetBps: Double = AppleMediaRateController.nativeScreenMinimumBitrateBps,
        maxTargetBps: Double,
        initialTargetBps: Double? = nil
    ) {
        config = Config.fromEnvironment(
            minimumCapacity: minTargetBps,
            maximumCapacity: maxTargetBps,
            defaultInitialCapacity: initialTargetBps)
        capacityEstimate = config.initialCapacity
        target = capacityEstimate * config.targetUtilization
    }

    var targetBitrateBps: UInt32 {
        UInt32(clamping: Int64(target.rounded()))
    }

    var bandwidthEstimateBps: UInt32 {
        UInt32(clamping: Int64(capacityEstimate.rounded()))
    }

    func onVideoPacket(
        ssrc: UInt32,
        rtpTimestamp: UInt32,
        bytes: Int,
        endOfFrame: Bool = false,
        queueDelaySeconds: Double = 0,
        now: Double
    ) {
        _ = ssrc
        _ = endOfFrame
        guard bytes > 0 else { return }
        updateOWRD(rtpTimestamp: rtpTimestamp, arrivalTime: now)
        byteSamples.append(ByteSample(time: now, bytes: bytes))
        byteSampleTotal += bytes
        intervalReceived += 1
        let queueDelay = max(0, queueDelaySeconds)
        intervalMaximumQueueDelay = max(intervalMaximumQueueDelay, queueDelay)
        peakQueueDelaySeconds = max(peakQueueDelaySeconds, queueDelay)
        trimSamples(now: now)
    }

    private func updateOWRD(rtpTimestamp: UInt32, arrivalTime: Double) {
        guard let previous = owrdPreviousRTPTimestamp else {
            owrdPreviousRTPTimestamp = rtpTimestamp
            return
        }
        let forwardDistance = rtpTimestamp &- previous
        guard forwardDistance != 0, forwardDistance < 0x8000_0000 else { return }
        owrdPreviousRTPTimestamp = rtpTimestamp

        // The native collector converts arrival seconds to an unsigned
        // millisecond timestamp before feeding its OWRD estimator.
        let receiveMilliseconds = UInt32(truncatingIfNeeded: UInt64(
            max(0, (arrivalTime * 1_000).rounded(.towardZero))))
        guard let firstSend = owrdFirstSendTimestamp,
              let firstReceive = owrdFirstReceiveTimestamp else {
            owrdFirstSendTimestamp = rtpTimestamp
            owrdFirstReceiveTimestamp = receiveMilliseconds
            return
        }

        let relativeSendTime = Double(rtpTimestamp &- firstSend)
            / Self.screenRTPClockRate
        let relativeReceiveTime = Double(receiveMilliseconds &- firstReceive) / 1_000
        let lag = relativeReceiveTime - relativeSendTime

        guard let short = owrdShortAverageLag,
              let long = owrdLongAverageLag else {
            owrdShortAverageLag = lag
            owrdLongAverageLag = lag
            owrdSeconds = 0
            return
        }

        let nextShort = lag * 0.1 + short * 0.9
        var nextLong = lag * 0.0001 + long * 0.9999
        let difference = nextShort - nextLong
        if difference < 0 {
            // A new lower-delay baseline immediately resets the long average;
            // only queue growth above that baseline is reported.
            nextLong = nextShort
            owrdSeconds = 0
        } else {
            owrdSeconds = difference
        }
        owrdShortAverageLag = nextShort
        owrdLongAverageLag = nextLong
    }

    func onConfirmedLoss(count: Int, now: Double) {
        guard count > 0 else { return }
        intervalLost += count
        confirmedLossPending = true
        lastCongestionTime = now
        cooldownUntil = max(cooldownUntil, now + config.cooldown)
    }

    /// A media reconfiguration installs a new RTP clock origin and new SSRCs
    /// on the same network path. Preserve the learned path capacity, but reset
    /// all receive-generation measurements so the random timestamp discontinuity
    /// cannot be interpreted as seconds of queue growth.
    func resetMediaGenerationMeasurements() {
        byteSamples.removeAll(keepingCapacity: true)
        byteSampleHead = 0
        byteSampleTotal = 0
        intervalReceived = 0
        intervalLost = 0
        confirmedLossPending = false
        intervalMaximumQueueDelay = 0
        lastMaximumQueueDelaySeconds = 0

        owrdPreviousRTPTimestamp = nil
        owrdFirstSendTimestamp = nil
        owrdFirstReceiveTimestamp = nil
        owrdShortAverageLag = nil
        owrdLongAverageLag = nil
        owrdSeconds = 0
    }

    func throughputBps(now: Double) -> Double {
        trimSamples(now: now)
        guard byteSampleHead < byteSamples.count,
              let last = byteSamples.last else { return 0 }
        let first = byteSamples[byteSampleHead]
        let span = max(0.05, min(config.throughputWindow, last.time - first.time + 0.05))
        return Double(byteSampleTotal) * 8 / span
    }

    @discardableResult
    func update(now: Double) -> UInt32 {
        if lastUpdate == nil {
            lastUpdate = now
            lastRamp = now
            return targetBitrateBps
        }
        guard now - (lastUpdate ?? now) >= config.updateInterval else {
            return targetBitrateBps
        }
        lastUpdate = now

        let observed = throughputBps(now: now)
        let expected = intervalReceived + intervalLost
        let lossFraction = expected > 0 ? Double(intervalLost) / Double(expected) : 0
        // Socket-to-actor delay measures local frame-burst processing, not path
        // congestion. Retina keyframes routinely arrive in hundreds of packets
        // and create 20–50 ms lossless bursts. Treating each burst as congestion
        // repeatedly drove 40 Mbps down to the 4 Mbps floor in a few seconds.
        // Preserve queue delay as a diagnostic, but reduce the sender only for
        // confirmed RTP loss.
        let congested = confirmedLossPending || lossFraction > 0.01
        let mayBackoff = lastBackoff.map { now - $0 >= config.backoffInterval } ?? true

        if congested, mayBackoff {
            // Loss severity strengthens a bounded exponential reduction. A
            // lone missing packet gets ordinary AIMD backoff; losing a material
            // portion of a frame can halve the estimate in one response.
            let severityAdjustment = intervalLost > 1
                ? min(0.25, lossFraction)
                : 0
            let factor = max(0.50, config.decreaseFactor - severityAdjustment)
            capacityEstimate *= factor
            hasExperiencedCongestion = true
            lastCongestionTime = now
            cooldownUntil = max(cooldownUntil, now + config.cooldown)
            confirmedLossPending = false
            intervalLost = 0
            lastBackoff = now
            lastRamp = now
        } else if now >= cooldownUntil,
                  now - (lastRamp ?? now) >= (hasExperiencedCongestion
                    ? config.rampInterval
                    : config.startupRampInterval),
                  observed >= capacityEstimate * config.utilizationThreshold {
            // Probe only while active content is using most of the current
            // allowance. This prevents idle periods from restoring 40 Mbps and
            // recreating the same burst-loss cycle on the next window move.
            let nextProbe = capacityEstimate * (hasExperiencedCongestion
                ? config.rampFactor
                : config.startupRampFactor)
            let demand = max(capacityEstimate, observed * config.headroomFactor)
            capacityEstimate = min(config.maximumCapacity, nextProbe, demand)
            lastRamp = now
        }

        capacityEstimate = min(
            config.maximumCapacity,
            max(effectiveMinimumCapacity, capacityEstimate))
        target = min(
            config.maximumCapacity,
            max(effectiveMinimumCapacity, capacityEstimate * config.targetUtilization))

        intervalReceived = 0
        if !confirmedLossPending { intervalLost = 0 }
        lastMaximumQueueDelaySeconds = intervalMaximumQueueDelay
        intervalMaximumQueueDelay = 0
        return targetBitrateBps
    }

    /// A full intra picture is a large burst. Request it only after the sender
    /// has converged near our advertised receive rate and the path has remained
    /// gap-free long enough for queued traffic to drain.
    ///
    /// While every band is gated the display is frozen regardless, so the
    /// quiet requirement shortens: recovering promptly beats waiting out a
    /// motion burst that may never pause. The throughput check stays — after a
    /// recovery backoff it confirms the sender actually applied the lower rate
    /// before we invite another IDR burst. The queue-delay veto only defers
    /// (the caller's escalation ladder bounds it in absolute time); it must
    /// never reduce the estimate itself.
    func isReadyForKeyframeRecovery(now: Double, displayGated: Bool = false) -> Bool {
        let observed = throughputBps(now: now)
        guard observed <= target * 1.25 else { return false }
        if displayGated,
           lastMaximumQueueDelaySeconds > config.recoveryQueueDelayVetoSeconds {
            return false
        }
        guard let lastCongestionTime else { return true }
        let quietInterval = displayGated ? config.recoveryQuietInterval : 0.75
        return now - lastCongestionTime >= quietInterval
    }

    /// Step the advertised capacity down ahead of a recovery-IDR retry. Loss
    /// backoff only reacts to packets that were already shredded; a retry IDR
    /// sent at the same rate that just caused the loss tends to be shredded
    /// too. One proactive AIMD step makes the retry picture smaller and
    /// deliverable while motion continues. Returns whether a step was applied.
    @discardableResult
    func forceRecoveryBackoff(now: Double) -> Bool {
        // Share the AIMD rate limit with loss backoff so a confirmed-loss
        // decrease and a recovery decrease cannot compound within one window.
        if let lastBackoff, now - lastBackoff < config.backoffInterval {
            recoveryEpisodeActive = true
            recoveryAttemptCount += 1
            return false
        }
        recoveryEpisodeActive = true
        recoveryAttemptCount += 1
        capacityEstimate = max(
            effectiveMinimumCapacity,
            capacityEstimate * config.decreaseFactor)
        target = min(
            config.maximumCapacity,
            max(effectiveMinimumCapacity, capacityEstimate * config.targetUtilization))
        hasExperiencedCongestion = true
        lastBackoff = now
        lastRamp = now
        cooldownUntil = max(cooldownUntil, now + config.cooldown)
        // lastCongestionTime is deliberately untouched: the caller is about to
        // retry recovery and must not push its own readiness out again.
        return true
    }

    /// The gate cleared. Capacity is restored only through the normal
    /// utilization-gated ramp — snapping back to the pre-episode floor would
    /// recreate the burst that caused the loss.
    func noteRecoveryComplete() {
        recoveryEpisodeActive = false
        recoveryAttemptCount = 0
    }

    /// The relaxed floor applies only during an active recovery episode; the
    /// ramp restores the normal floor as soon as capacity climbs back over it.
    private var effectiveMinimumCapacity: Double {
        recoveryEpisodeActive || capacityEstimate < config.minimumCapacity
            ? config.recoveryMinimumCapacity
            : config.minimumCapacity
    }

    private func trimSamples(now: Double) {
        while byteSampleHead < byteSamples.count,
              now - byteSamples[byteSampleHead].time > config.throughputWindow {
            byteSampleTotal -= byteSamples[byteSampleHead].bytes
            byteSampleHead += 1
        }
        // Array.removeFirst is O(n) and was previously called per RTP packet.
        // Compact only occasionally so steady-state ingest stays O(1).
        if byteSampleHead >= 1_024,
           byteSampleHead * 2 >= byteSamples.count {
            byteSamples.removeFirst(byteSampleHead)
            byteSampleHead = 0
        }
    }
}
