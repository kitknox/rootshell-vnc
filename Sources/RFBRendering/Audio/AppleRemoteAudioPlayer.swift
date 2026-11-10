import AudioToolbox
import AVFoundation
import CoreMedia
import Foundation
import RFBProtocol

#if os(iOS)
import AVFAudio
#endif

public enum AppleRemoteAudioPlayerError: Error, Sendable, LocalizedError {
    case formatDescriptionCreationFailed(OSStatus)
    case blockBufferCreationFailed(OSStatus)
    case sampleBufferCreationFailed(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .formatDescriptionCreationFailed(let status):
            return "Could not create the AAC-ELD audio format (OSStatus \(status))."
        case .blockBufferCreationFailed(let status):
            return "Could not create a remote-audio data buffer (OSStatus \(status))."
        case .sampleBufferCreationFailed(let status):
            return "Could not create a remote-audio sample buffer (OSStatus \(status))."
        }
    }
}

/// A point on the audio renderer's active RTP-to-local-host presentation
/// timeline. Consumers can combine this with the stream's RTCP Sender Report
/// to synchronize a separately rendered video stream.
public struct AppleRemoteAudioPlaybackTiming: Sendable, Equatable {
    public let ssrc: UInt32
    public let rtpTimestamp: UInt32
    public let hostTimeNanos: UInt64

    public init(
        ssrc: UInt32,
        rtpTimestamp: UInt32,
        hostTimeNanos: UInt64
    ) {
        self.ssrc = ssrc
        self.rtpTimestamp = rtpTimestamp
        self.hostTimeNanos = hostTimeNanos
    }
}

/// Public-framework playback for the system-audio stream negotiated by Apple
/// Remote Desktop. RTP/AAC packet parsing runs on a dedicated serial queue and
/// compressed samples are rendered by AVSampleBufferAudioRenderer, which keeps
/// decode and output hardware selection inside AVFoundation on macOS and iOS.
public final class AppleRemoteAudioPlayer: @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "com.rootshell.vnc.remote-audio",
        qos: .userInitiated)
    private let renderer = AVSampleBufferAudioRenderer()
    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private let formatDescription: CMAudioFormatDescription
    private let log = VNCLogger(category: "Audio")
    private let playbackTimingSink:
        (@Sendable (AppleRemoteAudioPlaybackTiming) -> Void)?
    private var leadController = AppleRemoteAudioLeadController(
        rendererLeadNanos: AppleRemoteAudioPlayer.defaultRendererLeadNanos)
    private var playbackRate: Float = 1
    private var rateAdjustmentGeneration: UInt64 = 0
    private var rateAdjustmentCount: UInt64 = 0

    private var reorderBuffer = AppleRemoteAudioRTPReorderBuffer()
    private var activeSSRC: UInt32?
    private var baseRTPTimestamp: UInt32?
    private var lastOrderedSequence: UInt16?
    private var lastOrderedTimestamp: UInt32?
    private var enqueuedAccessUnitCount = 0
    private var prerollAccessUnitTarget =
        AppleRemoteAudioPlayer.basePrerollAccessUnitTarget
    private var playbackStartHostTime: CMTime?
    /// Preroll cushion bounds, in 10 ms access units. Underruns grow the
    /// cushion for resilience; sustained clean playback decays it back so one
    /// bad Wi-Fi patch does not leave audio a quarter second late for the rest
    /// of the connection.
    static let basePrerollAccessUnitTarget = 10
    static let maximumPrerollAccessUnitTarget = 24
    private static let prerollGrowthStep = 4
    /// Clean-playback window required before each 40 ms decay step.
    private var cushionDecayIntervalNanos: UInt64 = 30_000_000_000
    private var lastCushionAdjustmentNanos: UInt64 = 0
    private var detectedLossCount: UInt64 = 0
    private var underrunCount: UInt64 = 0
    private var isRunning = false
    private var hasActivatedAudioSession = false

    /// Backoff for audio-session activation.
    ///
    /// Activation is attempted from `enqueueAccessUnits`, which runs once per
    /// remote-audio RTP packet. When it fails the flag above stays false, so
    /// without a backoff every subsequent packet retried it: one capture
    /// logged 1375 activation failures, in bursts at roughly 100 Hz.
    /// Activation also legitimately fails for as long as the app is
    /// backgrounded (the host declares no `audio` background mode), which is
    /// exactly when the retries are both loudest and most pointless.
    private var nextAudioSessionAttemptNanos: UInt64 = 0
    private var audioSessionFailureCount: UInt64 = 0
    private static let audioSessionRetryFloorNanos: UInt64 = 250_000_000
    private static let audioSessionRetryCeilingNanos: UInt64 = 5_000_000_000
    private var backlogDropCount: UInt64 = 0
    /// Output lead when the platform cannot report one.
    static let defaultRendererLeadNanos: Int64 = 20_000_000

    private var hasLoggedFirstPacket = false
    private var hasLoggedRendererFailure = false
    private var malformedPacketCount: UInt64 = 0
    private var automaticFlushObserver: NSObjectProtocol?

    public static func canHandleRTPPacket(_ data: Data) -> Bool {
        AppleRemoteAudioRTPDepacketizer.canHandle(data)
    }

    public init(
        playbackTimingSink:
            (@Sendable (AppleRemoteAudioPlaybackTiming) -> Void)? = nil
    ) throws {
        self.playbackTimingSink = playbackTimingSink
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Double(AppleRemoteAudioRTPDepacketizer.sampleRate),
            mFormatID: kAudioFormatMPEG4AAC_ELD_SBR,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: UInt32(
                AppleRemoteAudioRTPDepacketizer.framesPerAccessUnit),
            mBytesPerFrame: 0,
            mChannelsPerFrame: AppleRemoteAudioRTPDepacketizer.channelCount,
            mBitsPerChannel: 0,
            mReserved: 0)
        var description: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &description)
        guard status == noErr, let description else {
            throw AppleRemoteAudioPlayerError.formatDescriptionCreationFailed(status)
        }
        formatDescription = description

        renderer.audioTimePitchAlgorithm = .timeDomain
        synchronizer.delaysRateChangeUntilHasSufficientMediaData = false
        synchronizer.addRenderer(renderer)
        automaticFlushObserver = NotificationCenter.default.addObserver(
            forName: .AVSampleBufferAudioRendererWasFlushedAutomatically,
            object: renderer,
            queue: nil
        ) { [weak self] _ in
            self?.queue.async { [weak self] in
                self?.resetPlaybackState(flushRenderer: true)
                self?.log.warning("Remote audio was flushed by the output device; restarting timeline")
            }
        }
    }

    deinit {
        if let automaticFlushObserver {
            NotificationCenter.default.removeObserver(automaticFlushObserver)
        }
    }

    /// Enqueue a decrypted RTP packet. Non-audio packets are ignored so this is
    /// safe to call directly from the transport's shared media sink.
    public func enqueueRTPPacket(_ data: Data) {
        guard Self.canHandleRTPPacket(data) else { return }
        queue.async { [weak self] in
            self?.processRTPPacket(data)
        }
    }

    /// Discard compressed samples and establish a fresh RTP/playback timeline
    /// after a media renegotiation or application suspension boundary.
    public func reset() {
        queue.async { [weak self] in
            self?.resetPlaybackState(flushRenderer: true)
        }
    }

    /// Stop playback and release the iOS audio session when the VNC connection
    /// ends or the user has disabled remote audio.
    public func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            resetPlaybackState(flushRenderer: true)
            deactivateAudioSessionIfNeeded()
        }
    }

    /// Test-only synchronous snapshot of playback health.
    struct DiagnosticsSnapshot {
        let underrunCount: UInt64
        let isRunning: Bool
        let rendererFailed: Bool
        let prerollAccessUnitTarget: Int
        let rateAdjustmentCount: UInt64
        let backlogDropCount: UInt64
    }

    func diagnosticsSnapshot() -> DiagnosticsSnapshot {
        queue.sync {
            DiagnosticsSnapshot(
                underrunCount: underrunCount,
                isRunning: isRunning,
                rendererFailed: renderer.status == .failed,
                prerollAccessUnitTarget: prerollAccessUnitTarget,
                rateAdjustmentCount: rateAdjustmentCount,
                backlogDropCount: backlogDropCount)
        }
    }

    /// Test-only: simulate an underrun-inflated cushion and optionally shrink
    /// the clean-playback window so decay is observable in test time.
    func setPrerollTargetForTesting(
        _ target: Int,
        decayIntervalNanos: UInt64? = nil
    ) {
        queue.sync {
            prerollAccessUnitTarget = min(
                max(target, Self.basePrerollAccessUnitTarget),
                Self.maximumPrerollAccessUnitTarget)
            if let decayIntervalNanos {
                cushionDecayIntervalNanos = decayIntervalNanos
            }
            lastCushionAdjustmentNanos = DispatchTime.now().uptimeNanoseconds
        }
    }

    private func processRTPPacket(_ data: Data) {
        do {
            let packet = try AppleRemoteAudioRTPDepacketizer.parse(data)
            if !hasLoggedFirstPacket {
                hasLoggedFirstPacket = true
                log.info(
                    "Receiving 48 kHz stereo AAC-ELD/SBR audio: "
                        + "ssrc=0x\(String(packet.ssrc, radix: 16)) "
                        + "accessUnits=\(packet.accessUnits.count)")
            }
            if activeSSRC != packet.ssrc {
                if let activeSSRC {
                    log.info(
                        "Remote audio source changed from ssrc=0x"
                            + "\(String(activeSSRC, radix: 16)) to ssrc=0x"
                            + "\(String(packet.ssrc, radix: 16)); restarting timeline")
                    resetPlaybackState(flushRenderer: true)
                }
                activeSSRC = packet.ssrc
            }
            for orderedPacket in reorderBuffer.enqueue(packet) {
                noteOrderedPacket(orderedPacket)
                try enqueueAccessUnits(from: orderedPacket)
            }
        } catch {
            malformedPacketCount &+= 1
            if malformedPacketCount == 1 || malformedPacketCount.isMultiple(of: 256) {
                let packetDetail: String
                if let rtp = try? RTPDemuxer().parsePacket(data) {
                    let prefix = rtp.payload.prefix(16).map {
                        String(format: "%02x", $0)
                    }.joined(separator: " ")
                    packetDetail = " payloadBytes=\(rtp.payload.count) prefix=[\(prefix)]"
                } else {
                    packetDetail = " packetBytes=\(data.count)"
                }
                log.warning(
                    "Dropped malformed remote-audio packet "
                        + "(count \(malformedPacketCount)): \(error.localizedDescription)"
                        + packetDetail)
            }
        }
    }

    private func enqueueAccessUnits(
        from packet: AppleRemoteAudioRTPPacket
    ) throws {
        guard !packet.accessUnits.isEmpty else { return }
        activateAudioSessionIfNeeded()

        let base = baseRTPTimestamp ?? packet.timestamp
        if baseRTPTimestamp == nil { baseRTPTimestamp = base }
        var packetOffset = packet.timestamp &- base
        var firstPresentationTime: CMTime?
        noteArrivalSlack(
            presentationFrames: Int64(packetOffset),
            hasLeadingAccessUnit: !(packet.accessUnits.first?.isEmpty ?? true))
        if baseRTPTimestamp == nil {
            // A backlog skip restarted the timeline at this packet.
            baseRTPTimestamp = packet.timestamp
            packetOffset = 0
        }

        for (index, accessUnit) in packet.accessUnits.enumerated() {
            guard !accessUnit.isEmpty else { continue }
            var presentationTime = CMTime(
                value: Int64(packetOffset)
                    + Int64(index) * AppleRemoteAudioRTPDepacketizer.framesPerAccessUnit,
                timescale: AppleRemoteAudioRTPDepacketizer.sampleRate)
            if firstPresentationTime == nil {
                firstPresentationTime = presentationTime
            }
            let duration = CMTime(
                value: AppleRemoteAudioRTPDepacketizer.framesPerAccessUnit,
                timescale: AppleRemoteAudioRTPDepacketizer.sampleRate)

            // Once started, incoming media must remain ahead of the render
            // clock. If UDP jitter exhausts that lead, the renderer has
            // already emitted silence for the gap; the queue is empty, so
            // nothing is worth flushing. Slide the RTP timeline forward so
            // this access unit plays a jitter cushion ahead of "now" and keep
            // the synchronizer running — a stop/preroll/restart cycle would
            // only stretch a one-packet glitch into a long dropout.
            if isRunning,
               let renderTime = trustedRenderTime(),
               CMTimeCompare(CMTimeAdd(presentationTime, duration), renderTime) <= 0 {
                underrunCount &+= 1
                prerollAccessUnitTarget = min(
                    prerollAccessUnitTarget + Self.prerollGrowthStep,
                    Self.maximumPrerollAccessUnitTarget)
                lastCushionAdjustmentNanos = DispatchTime.now().uptimeNanoseconds
                leadController.noteUnderrun(
                    nowNanos: DispatchTime.now().uptimeNanoseconds)
                setPlaybackRate(1)
                let lateMilliseconds = Int(
                    (CMTimeSubtract(renderTime, presentationTime).seconds * 1000)
                        .rounded())
                log.warning(
                    "Remote audio underrun (count \(underrunCount), "
                        + "late \(lateMilliseconds) ms); re-anchoring with "
                        + "\(prerollAccessUnitTarget * 10) ms cushion")
                let framesPerAccessUnit =
                    AppleRemoteAudioRTPDepacketizer.framesPerAccessUnit
                let resumeFrames = CMTimeConvertScale(
                    renderTime,
                    timescale: AppleRemoteAudioRTPDepacketizer.sampleRate,
                    method: .roundAwayFromZero).value
                    + Int64(prerollAccessUnitTarget) * framesPerAccessUnit
                let anchorFrames = max(
                    resumeFrames - Int64(index) * framesPerAccessUnit, 0)
                packetOffset = UInt32(truncatingIfNeeded: anchorFrames)
                baseRTPTimestamp = packet.timestamp &- packetOffset
                presentationTime = CMTime(
                    value: Int64(packetOffset) + Int64(index) * framesPerAccessUnit,
                    timescale: AppleRemoteAudioRTPDepacketizer.sampleRate)
                if index == 0 {
                    firstPresentationTime = presentationTime
                }
            }
            let sampleBuffer = try makeSampleBuffer(
                accessUnit: accessUnit,
                presentationTime: presentationTime)

            // The source is real-time. If the renderer is already saturated,
            // resetting on the next packet is preferable to accumulating stale
            // audio and allowing latency to grow without bound.
            guard renderer.isReadyForMoreMediaData else {
                log.warning("Remote-audio renderer fell behind; restarting the live timeline")
                resetPlaybackState(flushRenderer: true)
                return
            }
            renderer.enqueue(sampleBuffer)
            enqueuedAccessUnitCount += 1

            if renderer.status == .failed {
                if !hasLoggedRendererFailure {
                    hasLoggedRendererFailure = true
                    log.error(
                        "Remote-audio decoder failed: "
                            + "\(renderer.error?.localizedDescription ?? "unknown AVFoundation error")")
                }
                synchronizer.setRate(0, time: .invalid)
                isRunning = false
                return
            }
        }

        // Apple's negotiated ptime is 10 ms. A 100 ms initial cushion absorbs
        // ordinary Wi-Fi scheduling bursts; after a measured underrun the
        // target grows in 40 ms steps, capped at 240 ms.
        if !isRunning, enqueuedAccessUnitCount >= prerollAccessUnitTarget {
            let hostTimeNanos = DispatchTime.now().uptimeNanoseconds
            playbackStartHostTime = CMClockGetTime(CMClockGetHostTimeClock())
            synchronizer.setRate(1, time: .zero)
            isRunning = true
            lastCushionAdjustmentNanos = hostTimeNanos
            let rendererLeadNanos = measuredRendererLeadNanos()
            leadController.restartTimeline(
                rendererLeadNanos: rendererLeadNanos,
                startLeadNanos: Int64(prerollAccessUnitTarget) * 10_000_000,
                nowNanos: hostTimeNanos)
            if let activeSSRC, let baseRTPTimestamp {
                playbackTimingSink?(AppleRemoteAudioPlaybackTiming(
                    ssrc: activeSSRC,
                    rtpTimestamp: baseRTPTimestamp,
                    hostTimeNanos: hostTimeNanos))
            }
            log.info(
                "Remote audio playback started with "
                    + "\(prerollAccessUnitTarget * 10) ms preroll, "
                    + "\(rendererLeadNanos / 1_000_000) ms output lead")
        }

        if isRunning,
           let playbackTimingSink,
           let activeSSRC,
           let firstPresentationTime,
           let renderTime = trustedRenderTime() {
            let nowNanos = DispatchTime.now().uptimeNanoseconds
            let untilPresentation = CMTimeSubtract(
                firstPresentationTime,
                renderTime).seconds / Double(playbackRate)
            let targetNanos = untilPresentation > 0
                ? nowNanos &+ UInt64((untilPresentation * 1_000_000_000).rounded())
                : nowNanos
            playbackTimingSink(AppleRemoteAudioPlaybackTiming(
                ssrc: activeSSRC,
                rtpTimestamp: packet.timestamp,
                hostTimeNanos: targetNanos))
        }

        decayPrerollCushionIfClean()
    }

    /// Step an underrun-inflated cushion back down after each clean-playback
    /// window. The narrower cushion takes effect at the next timeline anchor
    /// (renegotiation, discontinuity, or re-anchored underrun recovery), so
    /// steady playback is never perturbed — it only stops future restarts from
    /// inheriting a stale worst-case latency.
    private func decayPrerollCushionIfClean() {
        guard isRunning,
              prerollAccessUnitTarget > Self.basePrerollAccessUnitTarget else {
            return
        }
        let now = DispatchTime.now().uptimeNanoseconds
        guard lastCushionAdjustmentNanos != 0,
              now &- lastCushionAdjustmentNanos >= cushionDecayIntervalNanos else {
            return
        }
        prerollAccessUnitTarget = max(
            Self.basePrerollAccessUnitTarget,
            prerollAccessUnitTarget - Self.prerollGrowthStep)
        lastCushionAdjustmentNanos = now
        log.info(
            "Remote audio cushion decayed to "
                + "\(prerollAccessUnitTarget * 10) ms after clean playback")
    }

    /// Feed the lead controller this packet's slack and apply any rate change
    /// it asks for. Fully late packets are left to the re-anchor below.
    private func noteArrivalSlack(
        presentationFrames: Int64,
        hasLeadingAccessUnit: Bool
    ) {
        guard isRunning, hasLeadingAccessUnit,
              let renderTime = trustedRenderTime() else { return }
        let presentation = CMTime(
            value: presentationFrames,
            timescale: AppleRemoteAudioRTPDepacketizer.sampleRate)
        let slackNanos = Int64(
            (CMTimeSubtract(presentation, renderTime).seconds * 1_000_000_000)
                .rounded())
        let accessUnitNanos = Int64(
            AppleRemoteAudioRTPDepacketizer.framesPerAccessUnit)
            * 1_000_000_000 / Int64(AppleRemoteAudioRTPDepacketizer.sampleRate)
        guard slackNanos > -accessUnitNanos else { return }
        let nowNanos = DispatchTime.now().uptimeNanoseconds
        guard let adjustment = leadController.noteArrival(
            slackNanos: slackNanos,
            nowNanos: nowNanos) else { return }
        if adjustment.skipsBacklog {
            // The server opens with buffered audio, and a stalled network
            // delivers some too; playing it out keeps audio that far behind.
            backlogDropCount &+= 1
            log.info(
                "Remote audio \(-adjustment.leadChangeNanos / 1_000_000) ms "
                    + "ahead of what playback needs; restarting at the live edge")
            resetRendererTimeline(flushRenderer: true)
            return
        }
        rateAdjustmentCount &+= 1
        if adjustment.leadChangeNanos < 0, let start = playbackStartHostTime {
            // The render clock will run ahead of wall time by this much.
            playbackStartHostTime = CMTimeSubtract(
                start,
                CMTime(value: -adjustment.leadChangeNanos, timescale: 1_000_000_000))
        }
        setPlaybackRate(adjustment.rate)
        let generation = rateAdjustmentGeneration
        queue.asyncAfter(
            deadline: .now() + .nanoseconds(Int(adjustment.durationNanos))
        ) { [weak self] in
            guard let self, generation == rateAdjustmentGeneration else { return }
            setPlaybackRate(1)
            leadController.finishAdjustment(
                nowNanos: DispatchTime.now().uptimeNanoseconds)
        }
        log.debug(
            "Remote audio lead \(adjustment.leadChangeNanos > 0 ? "+" : "")"
                + "\(adjustment.leadChangeNanos / 1_000_000) ms at rate \(adjustment.rate)")
    }

    /// A new rate also retires any pending return to normal speed.
    private func setPlaybackRate(_ rate: Float) {
        rateAdjustmentGeneration &+= 1
        guard rate != playbackRate else { return }
        playbackRate = rate
        if isRunning {
            synchronizer.setRate(rate, time: .invalid)
        }
    }

    /// How far ahead of the render clock the output path consumes audio.
    private func measuredRendererLeadNanos() -> Int64 {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        let seconds = session.outputLatency + session.ioBufferDuration
        guard seconds.isFinite, seconds > 0 else {
            return Self.defaultRendererLeadNanos
        }
        return min(max(Int64(seconds * 1_000_000_000), 5_000_000), 300_000_000)
        #else
        return Self.defaultRendererLeadNanos
        #endif
    }

    /// The synchronizer's render position, or nil while the reading is
    /// unusable. setRate(_:time:) applies asynchronously, so for a few
    /// milliseconds after a restart currentTime() still reports the previous
    /// timeline — seconds ahead of the fresh zero-based one. A reading from
    /// the current timeline can never exceed the wall-clock elapsed since
    /// playback started, so anything further ahead is stale. Treating those
    /// reads as underruns is what previously locked the player in a
    /// flush/preroll/flush loop after every media renegotiation.
    private func trustedRenderTime() -> CMTime? {
        guard let playbackStartHostTime else { return nil }
        let renderTime = synchronizer.currentTime()
        guard renderTime.isValid else { return nil }
        let hostElapsed = CMTimeSubtract(
            CMClockGetTime(CMClockGetHostTimeClock()), playbackStartHostTime)
        let tolerance = CMTime(
            value: CMTimeValue(AppleRemoteAudioRTPDepacketizer.sampleRate / 10),
            timescale: AppleRemoteAudioRTPDepacketizer.sampleRate)
        guard CMTimeCompare(renderTime, CMTimeAdd(hostElapsed, tolerance)) <= 0 else {
            return nil
        }
        return renderTime
    }

    private func noteOrderedPacket(_ packet: AppleRemoteAudioRTPPacket) {
        if let previousSequence = lastOrderedSequence {
            let sequenceDelta = packet.sequenceNumber &- previousSequence
            if sequenceDelta > 1, sequenceDelta < 0x8000 {
                let missing = UInt64(sequenceDelta - 1)
                detectedLossCount &+= missing
                if detectedLossCount == missing || detectedLossCount.isMultiple(of: 64) {
                    log.warning(
                        "Remote audio RTP loss: missing=\(missing) "
                            + "total=\(detectedLossCount) "
                            + "sequence=\(packet.sequenceNumber)")
                }
            }
        }

        if let previousTimestamp = lastOrderedTimestamp {
            let timestampDelta = packet.timestamp &- previousTimestamp
            // A normal packet advances by 480 frames. A jump of more than one
            // second is a new codec timeline even if a peer reuses its SSRC.
            if timestampDelta > UInt32(AppleRemoteAudioRTPDepacketizer.sampleRate),
               timestampDelta < 0x8000_0000 {
                log.info(
                    "Remote audio timestamp discontinuity: delta=\(timestampDelta); "
                        + "restarting timeline")
                resetRendererTimeline(flushRenderer: true)
                baseRTPTimestamp = packet.timestamp
            }
        }
        lastOrderedSequence = packet.sequenceNumber
        lastOrderedTimestamp = packet.timestamp
    }

    private func makeSampleBuffer(
        accessUnit: Data,
        presentationTime: CMTime
    ) throws -> CMSampleBuffer {
        let byteCount = accessUnit.count
        var blockBuffer: CMBlockBuffer?
        let blockStatus: OSStatus = accessUnit.withUnsafeBytes { bytes in
            guard let source = bytes.baseAddress else { return OSStatus(-50) } // paramErr
            var created: CMBlockBuffer?
            let createStatus = CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: byteCount,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: byteCount,
                flags: 0,
                blockBufferOut: &created)
            guard createStatus == kCMBlockBufferNoErr, let created else {
                return createStatus
            }
            let copyStatus = CMBlockBufferReplaceDataBytes(
                with: source,
                blockBuffer: created,
                offsetIntoDestination: 0,
                dataLength: byteCount)
            guard copyStatus == kCMBlockBufferNoErr else { return copyStatus }
            blockBuffer = created
            return noErr
        }
        guard blockStatus == noErr, let blockBuffer else {
            throw AppleRemoteAudioPlayerError.blockBufferCreationFailed(blockStatus)
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(
                value: AppleRemoteAudioRTPDepacketizer.framesPerAccessUnit,
                timescale: AppleRemoteAudioRTPDepacketizer.sampleRate),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid)
        var sampleSize = byteCount
        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer)
        guard sampleStatus == noErr, let sampleBuffer else {
            throw AppleRemoteAudioPlayerError.sampleBufferCreationFailed(sampleStatus)
        }
        return sampleBuffer
    }

    private func resetPlaybackState(flushRenderer: Bool) {
        resetRendererTimeline(flushRenderer: flushRenderer)
        reorderBuffer.reset()
        activeSSRC = nil
        lastOrderedSequence = nil
        lastOrderedTimestamp = nil
        detectedLossCount = 0
        malformedPacketCount = 0
    }

    private func resetRendererTimeline(flushRenderer: Bool) {
        synchronizer.setRate(0, time: .invalid)
        if flushRenderer { renderer.flush() }
        baseRTPTimestamp = nil
        playbackStartHostTime = nil
        enqueuedAccessUnitCount = 0
        isRunning = false
        playbackRate = 1
        rateAdjustmentGeneration &+= 1
        hasLoggedRendererFailure = false
    }

    private func activateAudioSessionIfNeeded() {
        guard !hasActivatedAudioSession else { return }
        #if os(iOS)
        let now = DispatchTime.now().uptimeNanoseconds
        guard now >= nextAudioSessionAttemptNanos else { return }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            hasActivatedAudioSession = true
            if audioSessionFailureCount > 0 {
                let failures = audioSessionFailureCount
                log.info("Audio output session activated after \(failures) failed attempt(s)")
            }
            nextAudioSessionAttemptNanos = 0
            audioSessionFailureCount = 0
        } catch {
            audioSessionFailureCount &+= 1
            let failures = audioSessionFailureCount
            // Double the wait per consecutive failure up to the ceiling, so a
            // whole background window costs a handful of attempts rather than
            // one per audio packet.
            let shift = min(failures &- 1, 8)
            let backoff = min(
                Self.audioSessionRetryCeilingNanos,
                Self.audioSessionRetryFloorNanos << shift)
            nextAudioSessionAttemptNanos = now &+ backoff
            // First failure names the cause; after that only occasional
            // reminders, since a backgrounded app fails every single time.
            if failures == 1 || failures.isMultiple(of: 32) {
                log.error(
                    "Could not activate the audio output session "
                        + "(attempt \(failures)): \(error.localizedDescription)")
            }
        }
        #else
        hasActivatedAudioSession = true
        #endif
    }

    private func deactivateAudioSessionIfNeeded() {
        // Cleared ahead of the guard on purpose: a player that never managed
        // to activate still carries a backoff, and a teardown (reconnect,
        // stream restart) is exactly when it should get a clean attempt
        // instead of inheriting the wait from the previous session.
        nextAudioSessionAttemptNanos = 0
        audioSessionFailureCount = 0

        guard hasActivatedAudioSession else { return }
        #if os(iOS)
        do {
            try AVAudioSession.sharedInstance().setActive(
                false,
                options: [.notifyOthersOnDeactivation])
        } catch {
            log.warning("Could not deactivate the audio output session: \(error.localizedDescription)")
        }
        #endif
        hasActivatedAudioSession = false
    }
}
