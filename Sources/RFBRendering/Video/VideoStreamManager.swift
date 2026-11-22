import Foundation
import CoreVideo
import CoreMedia
import RFBProtocol

/// Summary of one packet submitted to the accelerated video pipeline.
public struct VideoStreamFeedResult: Sendable, Equatable {
    public let byteCount: Int
    public let isActive: Bool
    public let isRTCP: Bool
    public let sequenceNumber: UInt16?
    public let payloadType: UInt8?
    public let timestamp: UInt32?
    public let nalUnitTypes: [UInt8]
    public let decodedNALUnitCount: Int
    public let errorDescription: String?

    public var reachedHEVCNALUnits: Bool {
        !nalUnitTypes.isEmpty
    }

    public init(
        byteCount: Int,
        isActive: Bool,
        isRTCP: Bool = false,
        sequenceNumber: UInt16? = nil,
        payloadType: UInt8? = nil,
        timestamp: UInt32? = nil,
        nalUnitTypes: [UInt8] = [],
        decodedNALUnitCount: Int = 0,
        errorDescription: String? = nil
    ) {
        self.byteCount = byteCount
        self.isActive = isActive
        self.isRTCP = isRTCP
        self.sequenceNumber = sequenceNumber
        self.payloadType = payloadType
        self.timestamp = timestamp
        self.nalUnitTypes = nalUnitTypes
        self.decodedNALUnitCount = decodedNALUnitCount
        self.errorDescription = errorDescription
    }
}

/// The first asynchronous decoder failure that poisoned a stream generation.
/// VideoToolbox reports reference loss from its output callback after frame
/// submission has already succeeded, so this is distinct from a feed error.
public struct VideoDecoderFailure: Sendable, Equatable {
    public let status: OSStatus
    public let ssrc: UInt32

    public init(status: OSStatus, ssrc: UInt32) {
        self.status = status
        self.ssrc = ssrc
    }
}

/// Authoritative full-frame geometry learned from the public HEVC format.
/// Apple renegotiates the media stream when a display changes size, but does
/// not necessarily send an RFB DesktopSize rectangle on that path. In the
/// portable one-tile profile, the decoded frame dimensions are therefore the
/// source of truth for the new desktop bounds.
public struct VideoFrameGeometry: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let mediaGeneration: UInt64
    /// The `DecodeProgress.streamGeneration` of the stream that reported these
    /// dimensions, or nil when the value was not produced by a stream.
    /// `mediaGeneration` restarts at 1 with every stream, so only this tells
    /// an update from a retired stream apart from one for its replacement.
    public let streamGeneration: UInt64?

    public init(width: Int, height: Int, mediaGeneration: UInt64) {
        self.init(
            width: width,
            height: height,
            mediaGeneration: mediaGeneration,
            streamGeneration: nil)
    }

    public init(
        width: Int,
        height: Int,
        mediaGeneration: UInt64,
        streamGeneration: UInt64?
    ) {
        self.width = width
        self.height = height
        self.mediaGeneration = mediaGeneration
        self.streamGeneration = streamGeneration
    }
}

/// Latches one terminal decoder failure per stream generation. Once the
/// hardware decoder enters its wait-for-IDR state, feeding more dependent
/// pictures only floods its callback with the same error.
struct VideoDecoderFailureLatch {
    private(set) var failure: VideoDecoderFailure?

    var hasFailed: Bool { failure != nil }

    mutating func record(_ candidate: VideoDecoderFailure) -> Bool {
        guard failure == nil else { return false }
        failure = candidate
        return true
    }

    mutating func reset() {
        failure = nil
    }
}

/// Generates a unique, monotonic PTS for each access unit submitted on the
/// compound HEVC decode timeline.
///
/// The four bands share RTP presentation timestamps. Those timestamps cannot
/// identify one asynchronous VideoToolbox callback within a compound frame,
/// so using them directly allows callbacks from adjacent frames to interleave.
/// A unique submission PTS lets ``DecodedFrameOrderer`` restore global DON
/// order before the spatial-band coalescer sees the buffers.
struct HEVCPresentationTimeline {
    static let timescale: CMTimeScale = 90_000
    static let step: CMTimeValue = 3_000
    private var sequentialCounter: CMTimeValue = 0

    mutating func next() -> CMTimeValue {
        defer { sequentialCounter += 1 }
        return sequentialCounter * Self.step
    }

    mutating func reset() {
        sequentialCounter = 0
    }
}

/// Manages the accelerated HEVC video stream for high-performance VNC mode.
///
/// Supports Apple's native multi-band transport and the conventional one-band
/// fallback. The four SSRCs are one interleaved HEVC reference sequence: only
/// the first band starts with an IDR, so global DON order must reach one public
/// VideoToolbox session. The SSRC remains the spatial band identity.
public final class VideoStreamManager: @unchecked Sendable {

    /// Delivers a decoded frame and the source SSRC (which screen band it is).
    public typealias FrameCallback = @Sendable (CVPixelBuffer, UInt32) -> Void

    private let lock = NSLock()
    /// Held while one packet is processed, and by `startStream`/`stopStream`
    /// while they replace the stream. Packet processing takes `lock` many
    /// times and works between those holds with the demuxer and decoder it
    /// read; without this, a restart from another thread could land between
    /// two of them and receive the retired stream's parameter sets or
    /// pictures. A start or stop now waits for at most the packet in flight.
    /// Always taken before `lock`.
    ///
    /// No owner callback runs while it is held. `onLossDetected`,
    /// `onDecoderFailure` and `onFrameGeometryChange` raised by a packet are
    /// collected and delivered after the packet, with no lock held, so a
    /// handler is free to stop or restart the stream, on this thread or by
    /// waiting on another one.
    private let feedLock = NSRecursiveLock()

    /// Owner callbacks raised while a packet is processed under `feedLock`.
    private struct DeferredCallbacks {
        private var pending: [() -> Void] = []

        mutating func add(_ callback: @escaping () -> Void) {
            pending.append(callback)
        }

        /// Call with no lock held.
        mutating func deliver() {
            let callbacks = pending
            pending.removeAll()
            for callback in callbacks { callback() }
        }
    }

    /// Test hook: runs under `feedLock` once a batch packet has been
    /// confirmed to belong to the active stream.
    var packetInFlightHookForTesting: (@Sendable () -> Void)?
    private var decoder: HEVCDecoder?
    private var demuxer: RTPDemuxer
    private var frameCallback: FrameCallback?
    private var _isActive: Bool = false
    private var usesDecodingOrderNumbers = true
    private var numberOfTiles = 4
    private var streamID: UInt32 = 0
    private var streamGeneration: UInt64 = 0
    /// AVC negotiation generation inside the still-live RFB stream. Unlike
    /// `streamGeneration`, this advances for display-size renegotiations.
    private var mediaGeneration: UInt64 = 0
    private var fullFrameWidth = 0
    private var fullFrameHeight = 0
    private var codedBandHeight = 0
    private var expectedBandCount = 0
    private var presentationTimeline = HEVCPresentationTimeline()
    private var submittedFrameCount: UInt64 = 0
    private var decoderOutputCount: UInt64 = 0
    private var lastSubmissionNanos: UInt64 = 0
    private var lastDecoderOutputNanos: UInt64 = 0
    private var droppedPacketLogCount = 0
    private var multiNALAccessUnitLogCount = 0
    private var gatedIRAPLogCount = 0
    private var pendingVPS: Data?
    private var pendingSPS: Data?
    private var pendingPPS: Data?
    private var decoderFailureLatch = VideoDecoderFailureLatch()
    /// Apple's screen stream never sends another IDR, so a session rebuilt
    /// right after reference loss fails every dependent picture until the
    /// gradual intra refresh completes (~1 s). Without pacing, that turned one
    /// lost packet into 30+ session rebuilds per second. The cooldown keeps
    /// the poisoned window quiet; the session owner re-attempts on a timer.
    private var lastDecoderRebuildNanos: UInt64 = 0
    private let decoderRebuildCooldownNanos: UInt64 = 250_000_000
    private let log = VNCLogger(category: "VideoStream")

    // MARK: - Loss detection & recovery
    //
    // After a lost base-layer frame, dependent pictures are withheld while
    // frame-loss feedback is sent through RTCP. Decoding resumes on HEVC
    // IDR_N_LP (type 20). VideoToolbox needs the same pre-decode gate: once a damaged P-frame
    // reaches the hardware session it reports a missing reference and remains
    // poisoned even though later packet assembly is valid.
    private var seenVideoSSRCs: Set<UInt32> = []
    private var awaitingIRAP: Set<UInt32> = []
    /// Recovery is complete only after VideoToolbox outputs the submitted IDR.
    /// Clearing the gate when type 20 is merely parsed lets dependent pictures
    /// poison the old reference chain if that IDR later fails asynchronously.
    private var pendingRecoveryIDRPresentationTimes: Set<CMTimeValue> = []
    private var lastVideoSeq: [UInt32: UInt16] = [:]
    private var lastVideoPacketArrivalNanos: [UInt32: UInt64] = [:]
    private var mediaInterruptionPendingSSRCs: Set<UInt32> = []
    private var lastLossNanos: UInt64 = 0
    /// The non-gating path keeps decoding through Apple's gradual intra
    /// refresh, but each distinct loss episode still needs a fresh recovery
    /// request. Bound requests instead of permanently treating the first loss
    /// in a media generation as the only recoverable episode.
    private let lossRecoveryRequestCooldownNanos: UInt64 = 1_000_000_000
    /// Kill-switch for A/B testing: ROOTSHELL_VNC_DISABLE_LOSS_RECOVERY=1.
    var lossRecoveryEnabled = ProcessInfo.processInfo.environment["ROOTSHELL_VNC_DISABLE_LOSS_RECOVERY"] != "1"
    /// Drop-until-IDR gate. Opt-in only. The recovery exchange can provide an
    /// IDR_N_LP plus fresh
    /// parameter sets (~300 ms round trip), so the correct loss behavior is to
    /// keep the mature session, skip the frames VideoToolbox rejects, request
    /// a keyframe, and let the IDR re-anchor decode. Gating every band until
    /// that IDR decodes only lengthens the freeze, and under motion collapses
    /// playback; enable the gate (ROOTSHELL_VNC_ENABLE_IRAP_GATE=1) only for
    /// diagnostics.
    var irapGateEnabled = ProcessInfo.processInfo.environment["ROOTSHELL_VNC_ENABLE_IRAP_GATE"] == "1"
    /// Fired when a fresh loss is detected while no recovery is in flight,
    /// after the packet that revealed it has been processed and with no lock
    /// held. VNCSession wires this to the transport's keyframe request.
    public var onLossDetected: (@Sendable (UInt32?) -> Void)?

    /// Fired once when VideoToolbox asynchronously rejects a submitted frame.
    /// A missing reference leaves Apple's hardware decoder waiting for an IDR;
    /// the session owner schedules an in-session public-VideoToolbox rebuild.
    public var onDecoderFailure: (@Sendable (VideoDecoderFailure) -> Void)?

    /// Fired when a one-tile HEVC format reports new full-frame dimensions.
    /// The callback runs off-lock on the serial media path.
    public var onFrameGeometryChange: (@Sendable (VideoFrameGeometry) -> Void)?

    /// Counters for tests/diagnostics.
    public struct LossStats: Sendable, Equatable {
        public var gapsDetected = 0
        public var framesDroppedWhileGated = 0
        public var irapsDecoded = 0
        public var gatedBandCount = 0
        public init() {}
    }
    private var lossStats = LossStats()

    // MARK: - Compound-frame decode ordering

    /// Parameter sets bypass this scheduler and configure the decoder
    /// immediately; only completed VCL pictures participate in global DON order.
    private var donReorderBuffer = CompoundHEVCDONReorderBuffer()
    private var sequentialAccessUnitAssembler = SequentialHEVCAccessUnitAssembler()

    /// Monotonic decode-pipeline progress for liveness monitoring. A screen can
    /// legitimately be static, so callers distinguish an idle stream from a
    /// wedged decoder by checking whether submissions continue without output.
    public struct DecodeProgress: Sendable, Equatable {
        public let streamGeneration: UInt64
        public let submittedFrameCount: UInt64
        public let decoderOutputCount: UInt64
        public let lastSubmissionNanos: UInt64
        public let lastDecoderOutputNanos: UInt64
    }

    public var decodeProgress: DecodeProgress {
        lock.lock()
        defer { lock.unlock() }
        return DecodeProgress(
            streamGeneration: streamGeneration,
            submittedFrameCount: submittedFrameCount,
            decoderOutputCount: decoderOutputCount,
            lastSubmissionNanos: lastSubmissionNanos,
            lastDecoderOutputNanos: lastDecoderOutputNanos)
    }

    /// Current AVC negotiation generation within the active RFB stream.
    public var currentMediaGeneration: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return mediaGeneration
    }

    /// Snapshot of the loss/gating counters.
    public var lossStatsSnapshot: LossStats {
        lock.lock()
        defer { lock.unlock() }
        var s = lossStats
        s.gatedBandCount = awaitingIRAP.count
        return s
    }

    /// True while dependent pictures are withheld pending a recovery IDR.
    public var hasGatedBands: Bool {
        lock.lock()
        defer { lock.unlock() }
        return irapGateEnabled && !awaitingIRAP.isEmpty
    }

    public init() {
        self.demuxer = RTPDemuxer()
    }

    struct FrameGeometry: Sendable, Equatable {
        let width: Int
        let height: Int
        let codedBandHeight: Int
        let expectedBandCount: Int
    }

    var frameGeometrySnapshot: FrameGeometry {
        lock.lock()
        defer { lock.unlock() }
        return FrameGeometry(
            width: fullFrameWidth,
            height: fullFrameHeight,
            codedBandHeight: codedBandHeight,
            expectedBandCount: expectedBandCount)
    }

    // MARK: - Stream Lifecycle

    public func startStream(
        streamID: UInt32,
        width: Int,
        height: Int,
        usesDecodingOrderNumbers: Bool = true,
        numberOfTiles: Int? = nil,
        frameCallback: @escaping FrameCallback
    ) {
        feedLock.lock()
        lock.lock()
        let retiredDecoders = _stopStreamLocked()
        self.streamID = streamID
        self.mediaGeneration = 1
        self.fullFrameWidth = width
        self.fullFrameHeight = height
        self.usesDecodingOrderNumbers = usesDecodingOrderNumbers
        self.numberOfTiles = numberOfTiles ?? (usesDecodingOrderNumbers ? 4 : 1)
        self.donReorderBuffer = CompoundHEVCDONReorderBuffer(
            expectedSourceCount: self.numberOfTiles)
        self.frameCallback = frameCallback
        self.presentationTimeline.reset()
        self.submittedFrameCount = 0
        self.decoderOutputCount = 0
        self.lastSubmissionNanos = 0
        self.lastDecoderOutputNanos = 0
        self.droppedPacketLogCount = 0
        self.multiNALAccessUnitLogCount = 0
        self.gatedIRAPLogCount = 0
        self._isActive = true
        demuxer = RTPDemuxer(
            usesDecodingOrderNumbers: usesDecodingOrderNumbers)
        decoder = makeDecoder(
            streamGeneration: streamGeneration,
            mediaGeneration: mediaGeneration,
            frameCallback: frameCallback)
        lock.unlock()
        feedLock.unlock()
        retireDecoders(retiredDecoders)
    }

    /// Update geometry in place when RFB announces DesktopSize. Decoder
    /// reconfiguration remains driven by the stream's next public HEVC
    /// parameter sets; this method only updates assembly/compositing context.
    public func updateFrameGeometry(width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        guard width != fullFrameWidth || height != fullFrameHeight else { return }
        fullFrameWidth = width
        fullFrameHeight = height
        updateExpectedBandCountLocked()
    }

    /// Reset only compressed-media state for a fresh negotiated AVC
    /// generation. The RFB connection, frame callback, geometry, feedback
    /// wiring, and liveness counters remain in place. Calling this on the
    /// session's serial media queue orders it before the new generation's RTP.
    public func prepareForStreamReconfiguration(
        mediaGeneration: UInt64,
        numberOfTiles: Int? = nil
    ) {
        let retiredDecoder: HEVCDecoder?

        lock.lock()
        guard _isActive,
              mediaGeneration > self.mediaGeneration,
              let callback = frameCallback else {
            lock.unlock()
            return
        }

        self.mediaGeneration = mediaGeneration
        self.numberOfTiles = max(1, numberOfTiles ?? self.numberOfTiles)
        self.usesDecodingOrderNumbers = self.numberOfTiles > 1
        retiredDecoder = decoder
        decoder = makeDecoder(
            streamGeneration: streamGeneration,
            mediaGeneration: mediaGeneration,
            frameCallback: callback)
        demuxer = RTPDemuxer(
            usesDecodingOrderNumbers: self.usesDecodingOrderNumbers)
        presentationTimeline.reset()
        pendingVPS = nil
        pendingSPS = nil
        pendingPPS = nil
        decoderFailureLatch.reset()
        lastDecoderRebuildNanos = 0
        nonFatalDecodeFailureCount = 0
        codedBandHeight = 0
        expectedBandCount = 0
        seenVideoSSRCs.removeAll()
        awaitingIRAP.removeAll()
        pendingRecoveryIDRPresentationTimes.removeAll()
        lastVideoSeq.removeAll()
        lastVideoPacketArrivalNanos.removeAll()
        mediaInterruptionPendingSSRCs.removeAll()
        lastLossNanos = 0
        earlyVCLBuffer.removeAll()
        lossStats = LossStats()
        gatedIRAPLogCount = 0
        donReorderBuffer = CompoundHEVCDONReorderBuffer(
            expectedSourceCount: self.numberOfTiles)
        sequentialAccessUnitAssembler.reset()
        lock.unlock()

        retireDecoders([retiredDecoder].compactMap { $0 })
        log.info("Prepared public video decoder for negotiated media generation")
    }

    @discardableResult
    public func feedUDPData(_ data: Data) -> VideoStreamFeedResult {
        feedRTPData(data)
    }

    /// Feed a batch of ordered RTP packets with amortized timestamping and
    /// lock snapshots. Returns the total number of submitted HEVC access units.
    @discardableResult
    public func feedRTPBatch(_ packets: [Data]) -> Int {
        feedRTPBatch(packets, streamGeneration: nil)
    }

    /// Feed a batch on behalf of one specific stream.
    ///
    /// - Parameter expectedStreamGeneration: The `decodeProgress.streamGeneration`
    ///   the caller's packets belong to. A packet source created for one
    ///   stream can still deliver after this manager has been restarted for
    ///   the next (a drain delayed for audio sync, a block already queued);
    ///   binding it to its generation drops those packets instead of feeding
    ///   them to the replacement. Nil feeds whichever stream is active.
    @discardableResult
    public func feedRTPBatch(
        _ packets: [Data],
        streamGeneration expectedStreamGeneration: UInt64?
    ) -> Int {
        guard !packets.isEmpty else { return 0 }
        lock.lock()
        guard _isActive,
              expectedStreamGeneration == nil
                || expectedStreamGeneration == streamGeneration else {
            lock.unlock()
            return 0
        }
        let demuxerRef = demuxer
        let usesDON = usesDecodingOrderNumbers
        let batchStream = FeedStream(
            generation: streamGeneration,
            demuxer: demuxerRef)
        lock.unlock()

        let batchNowNanos = DispatchTime.now().uptimeNanoseconds
        var totalDecoded = 0
        for data in packets {
            guard !RTPDemuxer.isRTCPPacket(data) else { continue }
            // A batch can hold the whole startup backlog, so the stream may be
            // stopped or restarted while it is being fed. Each packet is
            // processed under `feedLock`, which excludes that for the packet's
            // duration, and starts by confirming it still belongs to the
            // active stream. The rest of a retired stream's batch therefore
            // neither touches the replacement's state nor reaches its decoder
            // through the retired demuxer.
            var callbacks = DeferredCallbacks()
            feedLock.lock()
            let decoded = feedBatchPacketLocked(
                data,
                stream: batchStream,
                usesDON: usesDON,
                nowNanos: batchNowNanos,
                callbacks: &callbacks)
            feedLock.unlock()
            callbacks.deliver()
            guard let decoded else { break }
            totalDecoded += decoded
        }
        return totalDecoded
    }

    /// Process one batch packet with `feedLock` held. Returns nil when the
    /// packet's stream is no longer the active one.
    private func feedBatchPacketLocked(
        _ data: Data,
        stream: FeedStream,
        usesDON: Bool,
        nowNanos: UInt64,
        callbacks: inout DeferredCallbacks
    ) -> Int? {
        do {
            let packet = try RTPDemuxer.parsePacket(data)
            guard packet.payloadType == 100 else { return 0 }
            guard let gap = noteVideoPacketAndDetectGap(
                ssrc: packet.ssrc,
                sequence: packet.sequenceNumber,
                nowNanos: nowNanos,
                expecting: stream) else { return nil }
            packetInFlightHookForTesting?()
            if gap.detected, !usesDON {
                discardPartialSequentialAccessUnit()
            }
            if gap.shouldRequestRecovery, let onLossDetected {
                let ssrc = packet.ssrc
                callbacks.add { onLossDetected(ssrc) }
            }
            let demuxed = stream.demuxer.feedPacket(packet)
            guard !demuxed.isEmpty else { return 0 }
            return try submitDemuxedUnits(
                demuxed,
                usesDON: usesDON,
                callbacks: &callbacks)
        } catch {
            guard isCurrentFeedStream(stream) else { return nil }
            let freshLoss = gateAllBands(nowNanos: nowNanos)
            if freshLoss, let onLossDetected {
                callbacks.add { onLossDetected(nil) }
            }
            logDroppedPacket(error: error, byteCount: data.count)
            return 0
        }
    }

    /// Identity of the stream a packet batch was snapshotted from.
    private struct FeedStream {
        let generation: UInt64
        let demuxer: RTPDemuxer
    }

    private func isCurrentFeedStreamLocked(_ stream: FeedStream) -> Bool {
        _isActive && streamGeneration == stream.generation && demuxer === stream.demuxer
    }

    private func isCurrentFeedStream(_ stream: FeedStream) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return isCurrentFeedStreamLocked(stream)
    }

    /// Feed an RTP-shaped media packet (UDP or Apple's encrypted TCP fallback).
    @discardableResult
    public func feedRTPData(_ data: Data) -> VideoStreamFeedResult {
        feedRTPData(data, streamGeneration: nil)
    }

    /// Feed one packet on behalf of one specific stream; see
    /// `feedRTPBatch(_:streamGeneration:)`.
    @discardableResult
    public func feedRTPData(
        _ data: Data,
        streamGeneration expectedStreamGeneration: UInt64?
    ) -> VideoStreamFeedResult {
        var callbacks = DeferredCallbacks()
        feedLock.lock()
        let result = feedRTPDataLocked(
            data,
            expectedStreamGeneration: expectedStreamGeneration,
            callbacks: &callbacks)
        feedLock.unlock()
        callbacks.deliver()
        return result
    }

    private func feedRTPDataLocked(
        _ data: Data,
        expectedStreamGeneration: UInt64?,
        callbacks: inout DeferredCallbacks
    ) -> VideoStreamFeedResult {
        lock.lock()
        guard _isActive,
              expectedStreamGeneration == nil
                || expectedStreamGeneration == streamGeneration else {
            lock.unlock()
            return VideoStreamFeedResult(byteCount: data.count, isActive: false)
        }
        let demuxerRef = demuxer
        let usesDON = usesDecodingOrderNumbers
        lock.unlock()

        guard !RTPDemuxer.isRTCPPacket(data) else {
            return VideoStreamFeedResult(byteCount: data.count, isActive: true, isRTCP: true)
        }

        do {
            let packet = try RTPDemuxer.parsePacket(data)
            // Only the video payload type is HEVC; audio (101) must not reach
            // the decoder.
            guard packet.payloadType == 100 else {
                return VideoStreamFeedResult(
                    byteCount: data.count, isActive: true,
                    sequenceNumber: packet.sequenceNumber, payloadType: packet.payloadType,
                    timestamp: packet.timestamp)
            }

            // Loss detection: a per-SSRC sequence gap means ≥1 video packet
            // died (whole frame, FU fragment, or parameter-set AP). Latch all
            // bands broken before feeding the demuxer, so nothing decoded from
            // this packet onward can render against a stale reference.
            let gap = noteVideoPacketAndDetectGap(
                ssrc: packet.ssrc,
                sequence: packet.sequenceNumber)
            if gap.detected, !usesDON {
                discardPartialSequentialAccessUnit()
            }
            if gap.shouldRequestRecovery, let onLossDetected {
                let ssrc = packet.ssrc
                callbacks.add { onLossDetected(ssrc) }
            }

            let demuxed = demuxerRef.feedPacket(packet)
            guard !demuxed.isEmpty else {
                return VideoStreamFeedResult(
                    byteCount: data.count, isActive: true,
                    sequenceNumber: packet.sequenceNumber, payloadType: packet.payloadType,
                    timestamp: packet.timestamp)
            }

            let nalUnitTypes: [UInt8] = demuxed.compactMap { unit in
                guard unit.nal.count >= 2 else { return nil }
                return (unit.nal[unit.nal.startIndex] >> 1) & 0x3f
            }
            let decodedCount = try submitDemuxedUnits(
                demuxed,
                usesDON: usesDON,
                callbacks: &callbacks)

            return VideoStreamFeedResult(
                byteCount: data.count, isActive: true,
                sequenceNumber: packet.sequenceNumber, payloadType: packet.payloadType,
                timestamp: packet.timestamp, nalUnitTypes: nalUnitTypes,
                decodedNALUnitCount: decodedCount)
        } catch {
            // A packet we couldn't parse/decode is as gone as one that never
            // arrived — latch the gate so the broken chain isn't rendered.
            let freshLoss = gateAllBands()
            if freshLoss, let onLossDetected {
                callbacks.add { onLossDetected(nil) }
            }
            logDroppedPacket(error: error, byteCount: data.count)
            return VideoStreamFeedResult(
                byteCount: data.count, isActive: true,
                errorDescription: error.localizedDescription)
        }
    }

    private func submitDemuxedUnits(
        _ demuxed: [RTPDemuxer.DemuxedNAL],
        usesDON: Bool,
        callbacks: inout DeferredCallbacks
    ) throws -> Int {
        // Parameter sets are not pictures and may share a DON with a later
        // IRAP, so apply them immediately. Buffer only VCL units by DON.
        var orderedVCL: [CompoundHEVCDONReorderBuffer.AccessUnit] = []
        for unit in demuxed {
            guard unit.nal.count >= 2 else { continue }
            let type = (unit.nal[unit.nal.startIndex] >> 1) & 0x3f
            switch type {
            case 32: handleParameterSet(nalUnit: unit.nal, type: .vps, callbacks: &callbacks)
            case 33: handleParameterSet(nalUnit: unit.nal, type: .sps, callbacks: &callbacks)
            case 34: handleParameterSet(nalUnit: unit.nal, type: .pps, callbacks: &callbacks)
            case 0...31:
                if usesDON {
                    orderedVCL.append(contentsOf:
                        enqueueAndDrainReorder([unit]).orderedAccessUnits)
                } else {
                    appendSequentialVCL(unit)
                }
            default: break
            }
            if !usesDON, unit.endOfAccessUnit,
               let complete = finishSequentialAccessUnit(ssrc: unit.ssrc) {
                orderedVCL.append(complete)
            }
        }

        var decodedCount = 0
        for accessUnit in orderedVCL {
            let nalUnits = accessUnit.nals.map(\.nal)
            guard let firstNAL = nalUnits.first, firstNAL.count >= 2 else { continue }
            let nalType = (firstNAL[firstNAL.startIndex] >> 1) & 0x3F
            switch nalType {
            case 32...40: continue
            default:
                // One DON is one band access unit. Preserve all of its VCL
                // NALs/slices in a single VideoToolbox sample; submitting
                // slices separately renders partial pictures.
                // IRAP NAL units (16-21) heal their band; non-IRAP VCL from
                // a gated band is dropped (its reference chain is broken —
                // decoding it would render macroblocks, not fail).
                guard shouldDecodeVCL(nalType: nalType, ssrc: accessUnit.ssrc) else { continue }
                logMultiNALAccessUnitIfNeeded(
                    don: accessUnit.don,
                    count: nalUnits.count)
                // A VCL NAL can beat its parameter sets to the decoder in
                // the startup burst (each band's ONLY IRAP is in there —
                // dropping one leaves the band dead all session). Buffer
                // until the format description exists, then drain in order.
                guard let decoderRef = decoderForSource(accessUnit.ssrc) else {
                    // An IDR can race the asynchronous VT error callback.
                    // Preserve it while the media queue rebuilds the public
                    // decoder instead of consuming the only recovery frame.
                    if isDecoderRecoveryPending {
                        bufferEarlyVCL(
                            nals: nalUnits,
                            ssrc: accessUnit.ssrc,
                            timestamp: accessUnit.timestamp,
                            don: accessUnit.don)
                    }
                    continue
                }
                guard decoderRef.isReady else {
                    bufferEarlyVCL(
                        nals: nalUnits,
                        ssrc: accessUnit.ssrc,
                        timestamp: accessUnit.timestamp,
                        don: accessUnit.don)
                    continue
                }
                let pts = CMTime(
                    value: nextPresentationTimeValue(),
                    timescale: HEVCPresentationTimeline.timescale)
                let recoveryIDRArmed = armRecoveryIDRIfNeeded(
                    nalType: nalType,
                    presentationTime: pts)
                do {
                    try decoderRef.decode(
                        nalUnits: nalUnits,
                        presentationTime: pts,
                        frameTag: accessUnit.ssrc)
                } catch HEVCDecoderError.decodeFailed(let status) {
                    if recoveryIDRArmed {
                        cancelRecoveryIDR(presentationTime: pts)
                    }
                    recordSynchronousDecoderFailure(
                        status: status,
                        presentationTime: pts,
                        ssrc: accessUnit.ssrc,
                        callbacks: &callbacks)
                    throw HEVCDecoderError.decodeFailed(status)
                } catch {
                    if recoveryIDRArmed {
                        cancelRecoveryIDR(presentationTime: pts)
                    }
                    throw error
                }
                recordDecodeSubmission()
                decodedCount += 1
            }
        }
        return decodedCount
    }

    /// Track per-SSRC video sequence numbers; on a gap, mark the stream
    /// recovering. Returns true when this is a FRESH loss (no recovery already
    /// in flight), so callers kick off recovery once per loss burst.
    private func noteVideoPacketAndDetectGap(
        ssrc: UInt32,
        sequence: UInt16,
        nowNanos: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> (detected: Bool, shouldRequestRecovery: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return noteVideoPacketAndDetectGapLocked(
            ssrc: ssrc,
            sequence: sequence,
            nowNanos: nowNanos)
    }

    /// Batch variant: returns nil, leaving all state untouched, when `stream`
    /// is no longer the active one.
    private func noteVideoPacketAndDetectGap(
        ssrc: UInt32,
        sequence: UInt16,
        nowNanos: UInt64,
        expecting stream: FeedStream
    ) -> (detected: Bool, shouldRequestRecovery: Bool)? {
        lock.lock()
        defer { lock.unlock() }
        guard isCurrentFeedStreamLocked(stream) else { return nil }
        return noteVideoPacketAndDetectGapLocked(
            ssrc: ssrc,
            sequence: sequence,
            nowNanos: nowNanos)
    }

    private func noteVideoPacketAndDetectGapLocked(
        ssrc: UInt32,
        sequence: UInt16,
        nowNanos: UInt64
    ) -> (detected: Bool, shouldRequestRecovery: Bool) {
        let now = nowNanos
        let followedLongSilence = lastVideoPacketArrivalNanos[ssrc].map {
            now &- $0 >= 1_000_000_000
        } ?? false
        lastVideoPacketArrivalNanos[ssrc] = now
        let followedKnownInterruption = mediaInterruptionPendingSSRCs.remove(ssrc) != nil
        seenVideoSSRCs.insert(ssrc)
        let last = lastVideoSeq[ssrc]
        lastVideoSeq[ssrc] = sequence
        guard let last, sequence != last &+ 1 else { return (false, false) }
        // A duplicate/late packet (seq <= last) is not a new hole in the chain;
        // only a forward jump means data was lost.
        let forward = sequence &- last
        guard forward != 0,
              forward < 0x8000 || followedLongSilence || followedKnownInterruption else {
            return (false, false)
        }
        lossStats.gapsDetected += 1
        guard lossRecoveryEnabled else { return (true, false) }
        return (true, markLossLocked(affectedSSRC: ssrc, nowNanos: now))
    }

    /// Mark a loss (used directly for losses whose SSRC is unknown: parse
    /// errors, DON skips). Returns true when this loss STARTED a recovery.
    @discardableResult
    private func gateAllBands(
        nowNanos: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        lossStats.gapsDetected += 1
        guard lossRecoveryEnabled else { return false }
        return markLossLocked(affectedSSRC: nil, nowNanos: nowNanos)
    }

    /// Record a loss under `lock`; returns true when no recovery was in flight.
    private func markLossLocked(
        affectedSSRC: UInt32?,
        nowNanos: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> Bool {
        let now = nowNanos
        let fresh: Bool
        if irapGateEnabled {
            fresh = awaitingIRAP.isEmpty
            // Compound tiles share one decoding-reference timeline. The server sends
            // the recovery IDR on the base SSRC even when a sibling lost RTP,
            // so stop every dependent tile until that global reset arrives.
            awaitingIRAP.formUnion(seenVideoSSRCs)
            if let affectedSSRC { awaitingIRAP.insert(affectedSSRC) }
        } else {
            let elapsed = now >= lastLossNanos ? now - lastLossNanos : 0
            fresh = lastLossNanos == 0
                || elapsed >= lossRecoveryRequestCooldownNanos
        }
        // Do not let a continuous cluster of per-band gaps postpone recovery
        // forever. Once one request is sent, the next request becomes eligible
        // after the fixed cooldown even if more gaps arrive in between.
        if fresh { lastLossNanos = now }
        return fresh
    }

    /// Exercise the recovery-request limiter without manufacturing an RTP
    /// packet or waiting on the wall clock.
    func noteLossForTesting(nowNanos: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return markLossLocked(affectedSSRC: nil, nowNanos: nowNanos)
    }

    /// Whether a VCL NAL should reach the decoder. A recovery IDR is allowed
    /// through, but the gate stays latched until VideoToolbox outputs it.
    /// The compound-video recovery profile resumes specifically for HEVC NAL
    /// type 20 (IDR_N_LP); CRA and dependent pictures remain withheld.
    func shouldDecodeVCL(nalType: UInt8, ssrc: UInt32) -> Bool {
        lock.lock()
        if nalType == 20 {
            lossStats.irapsDecoded += 1
            let isRecoveryIDR = irapGateEnabled && !awaitingIRAP.isEmpty
            lock.unlock()
            if isRecoveryIDR {
                log.warning(
                    "Submitting compound recovery HEVC IDR_N_LP type=20 "
                        + "baseSSRC=0x\(String(ssrc, radix: 16))")
            }
            return true
        }
        guard irapGateEnabled, !awaitingIRAP.isEmpty else {
            lock.unlock()
            return true
        }
        lossStats.framesDroppedWhileGated += 1
        let shouldLogIRAP = (16...21).contains(nalType)
            && gatedIRAPLogCount < 8
        if shouldLogIRAP { gatedIRAPLogCount += 1 }
        lock.unlock()
        if shouldLogIRAP {
            log.warning(
                "Withheld non-IDR recovery IRAP type=\(nalType) "
                    + "ssrc=0x\(String(ssrc, radix: 16))")
        }
        return false
    }

    @discardableResult
    private func armRecoveryIDRIfNeeded(
        nalType: UInt8,
        presentationTime: CMTime
    ) -> Bool {
        guard nalType == 20 else { return false }
        lock.lock()
        defer { lock.unlock() }
        guard irapGateEnabled, !awaitingIRAP.isEmpty else { return false }
        pendingRecoveryIDRPresentationTimes.insert(presentationTime.value)
        return true
    }

    private func cancelRecoveryIDR(presentationTime: CMTime) {
        lock.lock()
        pendingRecoveryIDRPresentationTimes.remove(presentationTime.value)
        lock.unlock()
    }

    /// Test-only: route a status through the async-failure classifier exactly
    /// as the VideoToolbox output callback would.
    func simulateDecoderFailureForTesting(status: OSStatus, ssrc: UInt32) {
        lock.lock()
        let generation = streamGeneration
        let media = mediaGeneration
        lock.unlock()
        recordDecoderFailure(
            streamGeneration: generation,
            mediaGeneration: media,
            status: status,
            presentationTime: CMTime(value: 0, timescale: 90000),
            ssrc: ssrc)?()
    }

    func installCompoundRecoveryGateForTesting(sources: Set<UInt32>) {
        lock.lock()
        seenVideoSSRCs = sources
        _ = markLossLocked(affectedSSRC: nil)
        lock.unlock()
    }

    func armRecoveryIDRForTesting(presentationTime: CMTime) -> Bool {
        armRecoveryIDRIfNeeded(nalType: 20, presentationTime: presentationTime)
    }

    func completeRecoveryIDROutputForTesting(presentationTime: CMTime) -> Bool {
        lock.lock()
        let generation = streamGeneration
        let currentMediaGeneration = mediaGeneration
        lock.unlock()
        return recordDecoderOutput(
            streamGeneration: generation,
            mediaGeneration: currentMediaGeneration,
            presentationTime: presentationTime).completedRecovery
    }

    /// Rebuild a VideoToolbox session without touching the VNC or media
    /// connection. The caller runs this on the serial media queue, so incoming
    /// RTP cannot overtake decoder invalidation and parameter-set restoration.
    @discardableResult
    public func recoverDecoderInSession() -> Bool {
        rebuildDecoderInSession(requireLatchedFailure: true)
    }

    /// Liveness fallback for the rare case where submissions stop producing
    /// callbacks without a reported OSStatus. It uses the same in-media reset.
    @discardableResult
    public func recoverDecoderAfterOutputStall() -> Bool {
        rebuildDecoderInSession(requireLatchedFailure: false)
    }

    /// Apply the no-video-displayed fail-safe after sending FIR: discard
    /// receiver-side partial assembly and choose a fresh compound DON
    /// origin from the recovery picture. Parameter sets and the working public
    /// VideoToolbox session remain intact.
    public func resetExpectedDecodingOrderForRecovery() {
        lock.lock()
        guard _isActive else {
            lock.unlock()
            return
        }
        demuxer.reset()
        donReorderBuffer.reset()
        sequentialAccessUnitAssembler.reset()
        earlyVCLBuffer.removeAll(keepingCapacity: true)
        // pendingRecoveryIDRPresentationTimes is deliberately preserved: it
        // tracks IDRs already in flight inside VideoToolbox, not receiver-side
        // assembly. Unarming them here meant a recovery picture that decoded
        // moments after a FIR retry could no longer clear the gate, burning a
        // full extra recovery cycle. Decoder-retirement paths still clear it.
        lock.unlock()
        log.warning("Reset expected HEVC decoding order while awaiting recovery IDR")
    }

    /// Allow the first packet after foregrounding to establish a forward
    /// sequence discontinuity even if more than half the UInt16 space elapsed.
    public func noteMediaInterruption() {
        lock.lock()
        mediaInterruptionPendingSSRCs.formUnion(seenVideoSSRCs)
        lock.unlock()
    }

    public func stopStream() {
        feedLock.lock()
        lock.lock()
        let retiredDecoders = _stopStreamLocked()
        lock.unlock()
        feedLock.unlock()
        retireDecoders(retiredDecoders)
    }

    public var isStreamActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isActive
    }

    // MARK: - Private

    private func nextPresentationTimeValue() -> CMTimeValue {
        lock.lock()
        defer { lock.unlock() }
        return presentationTimeline.next()
    }

    /// Detach decoder callbacks while holding `lock`, but never wait for
    /// VideoToolbox under that lock: an in-flight output callback records its
    /// progress through the same lock and would otherwise deadlock shutdown.
    private func _stopStreamLocked() -> [HEVCDecoder] {
        streamGeneration &+= 1
        let retiredDecoders = [decoder].compactMap { $0 }
        decoder = nil
        demuxer.reset()
        frameCallback = nil
        _isActive = false
        presentationTimeline.reset()
        submittedFrameCount = 0
        decoderOutputCount = 0
        lastSubmissionNanos = 0
        lastDecoderOutputNanos = 0
        droppedPacketLogCount = 0
        multiNALAccessUnitLogCount = 0
        gatedIRAPLogCount = 0
        pendingVPS = nil
        pendingSPS = nil
        pendingPPS = nil
        decoderFailureLatch.reset()
        lastDecoderRebuildNanos = 0
        nonFatalDecodeFailureCount = 0
        fullFrameWidth = 0
        fullFrameHeight = 0
        mediaGeneration = 0
        codedBandHeight = 0
        expectedBandCount = 0
        seenVideoSSRCs.removeAll()
        awaitingIRAP.removeAll()
        pendingRecoveryIDRPresentationTimes.removeAll()
        lastVideoSeq.removeAll()
        lastVideoPacketArrivalNanos.removeAll()
        mediaInterruptionPendingSSRCs.removeAll()
        lastLossNanos = 0
        earlyVCLBuffer.removeAll()
        lossStats = LossStats()
        donReorderBuffer.reset()
        sequentialAccessUnitAssembler.reset()
        return retiredDecoders
    }

    private func retireDecoders(_ decoders: [HEVCDecoder]) {
        for decoder in decoders {
            decoder.reset()
        }
    }

    private func logDroppedPacket(error: Error, byteCount: Int) {
        lock.lock()
        let shouldLog = droppedPacketLogCount < 8
        droppedPacketLogCount += 1
        lock.unlock()
        if shouldLog {
            log.warning("Dropped media packet (\(byteCount) bytes): \(error.localizedDescription)")
        }
    }

    private enum ParameterSetType { case vps, sps, pps }

    /// VCL NAL units that arrived before the decoder had its parameter sets
    /// (startup burst ordering). Drained the moment the format description is
    /// configured; bounded so a broken stream can't grow it unboundedly.
    private var earlyVCLBuffer: [(
        nals: [Data],
        ssrc: UInt32,
        timestamp: UInt32,
        don: UInt16
    )] = []

    private func bufferEarlyVCL(
        nals: [Data],
        ssrc: UInt32,
        timestamp: UInt32,
        don: UInt16
    ) {
        lock.lock()
        defer { lock.unlock() }
        if earlyVCLBuffer.count < 256 {
            earlyVCLBuffer.append((nals, ssrc, timestamp, don))
        }
    }

    private func recordDecodeSubmission() {
        lock.lock()
        submittedFrameCount &+= 1
        lastSubmissionNanos = DispatchTime.now().uptimeNanoseconds
        lock.unlock()
    }

    @discardableResult
    private func recordDecoderOutput(
        streamGeneration: UInt64,
        mediaGeneration: UInt64,
        presentationTime: CMTime
    ) -> (accepted: Bool, completedRecovery: Bool) {
        lock.lock()
        guard streamGeneration == self.streamGeneration,
              mediaGeneration == self.mediaGeneration,
              _isActive else {
            lock.unlock()
            return (false, false)
        }
        decoderOutputCount &+= 1
        lastDecoderOutputNanos = DispatchTime.now().uptimeNanoseconds
        let completedRecovery = pendingRecoveryIDRPresentationTimes.remove(
            presentationTime.value) != nil
        if completedRecovery {
            pendingRecoveryIDRPresentationTimes.removeAll(keepingCapacity: true)
            awaitingIRAP.removeAll(keepingCapacity: true)
            lastLossNanos = 0
        }
        lock.unlock()
        return (true, completedRecovery)
    }

    /// Frame-level VideoToolbox failures that must NOT invalidate the session.
    /// The screen-stream profile normally sends its IRAP at startup:
    /// a session rebuilt after reference loss holds no references at all, so
    /// every dependent picture fails (-17694) until a full intra-refresh sweep
    /// happens to align with a rebuild — in practice a frozen display and an
    /// endless rebuild/FIR loop. The mature session, by contrast, is missing
    /// only the lost picture; skipping the failed frame and continuing lets
    /// the server's gradual intra refresh heal the corruption in under a
    /// second. A decoder that stops producing output entirely is still caught
    /// by the decode-output stall watchdog, which rebuilds on its own cadence.
    private static let nonFatalDecodeStatuses: Set<OSStatus> = [
        -12909, // kVTVideoDecoderBadDataErr — the damaged picture itself
        -17694, // kVTVideoDecoderReferenceMissingErr — refs through a lost frame
    ]
    private var nonFatalDecodeFailureCount: UInt64 = 0

    /// `VTDecompressionSessionDecodeFrame` can report a terminal session error
    /// directly instead of through its output callback. Route that synchronous
    /// failure through the same latch/rebuild path as asynchronous failures.
    private func recordSynchronousDecoderFailure(
        status: OSStatus,
        presentationTime: CMTime,
        ssrc: UInt32,
        callbacks: inout DeferredCallbacks
    ) {
        lock.lock()
        let generation = streamGeneration
        let currentMediaGeneration = mediaGeneration
        lock.unlock()
        if let notifyOwner = recordDecoderFailure(
            streamGeneration: generation,
            mediaGeneration: currentMediaGeneration,
            status: status,
            presentationTime: presentationTime,
            ssrc: ssrc) {
            callbacks.add(notifyOwner)
        }
    }

    /// Latch a decoder failure. Returns the `onDecoderFailure` notification
    /// for the caller to run once it holds no lock, when the failure needs one.
    private func recordDecoderFailure(
        streamGeneration: UInt64,
        mediaGeneration: UInt64,
        status: OSStatus,
        presentationTime: CMTime,
        ssrc: UInt32
    ) -> (() -> Void)? {
        if Self.nonFatalDecodeStatuses.contains(status) {
            lock.lock()
            guard streamGeneration == self.streamGeneration,
                  mediaGeneration == self.mediaGeneration,
                  _isActive else {
                lock.unlock()
                return nil
            }
            nonFatalDecodeFailureCount &+= 1
            let count = nonFatalDecodeFailureCount
            pendingRecoveryIDRPresentationTimes.remove(presentationTime.value)
            lock.unlock()
            if count == 1 || count.isMultiple(of: 64) {
                log.warning(
                    "Skipped frame after non-fatal VideoToolbox status=\(status) "
                        + "ssrc=0x\(String(ssrc, radix: 16)) count=\(count); "
                        + "keeping session for intra-refresh recovery")
            }
            return nil
        }

        let failure = VideoDecoderFailure(status: status, ssrc: ssrc)
        let callback: (@Sendable (VideoDecoderFailure) -> Void)?

        lock.lock()
        guard streamGeneration == self.streamGeneration,
              mediaGeneration == self.mediaGeneration,
              _isActive,
              decoderFailureLatch.record(failure) else {
            lock.unlock()
            return nil
        }
        pendingRecoveryIDRPresentationTimes.remove(presentationTime.value)
        _ = markLossLocked(affectedSSRC: ssrc)
        callback = onDecoderFailure
        lock.unlock()

        log.error(
            "VideoToolbox decoder failed asynchronously status=\(status) "
                + "ssrc=0x\(String(ssrc, radix: 16)); rebuilding in media session")
        guard let callback else { return nil }
        return { callback(failure) }
    }

    private var isDecoderRecoveryPending: Bool {
        lock.lock()
        defer { lock.unlock() }
        return decoderFailureLatch.hasFailed
    }

    /// True while an asynchronous VideoToolbox failure is latched and the
    /// decoder has not yet been rebuilt. The session owner polls this to
    /// re-attempt a rebuild that was deferred by the rebuild cooldown.
    public var hasLatchedDecoderFailure: Bool {
        isDecoderRecoveryPending
    }

    private func rebuildDecoderInSession(requireLatchedFailure: Bool) -> Bool {
        let oldDecoder: HEVCDecoder
        let replacement: HEVCDecoder
        let generation: UInt64
        let currentMediaGeneration: UInt64
        let vps: Data?
        let sps: Data
        let pps: Data

        lock.lock()
        guard _isActive,
              (!requireLatchedFailure || decoderFailureLatch.hasFailed),
              let currentDecoder = decoder,
              let callback = frameCallback,
              let configuredSPS = pendingSPS,
              let configuredPPS = pendingPPS else {
            lock.unlock()
            return false
        }
        let now = DispatchTime.now().uptimeNanoseconds
        guard lastDecoderRebuildNanos == 0
                || now &- lastDecoderRebuildNanos >= decoderRebuildCooldownNanos else {
            lock.unlock()
            return false
        }
        lastDecoderRebuildNanos = now
        generation = streamGeneration
        currentMediaGeneration = mediaGeneration
        oldDecoder = currentDecoder
        replacement = makeDecoder(
            streamGeneration: generation,
            mediaGeneration: currentMediaGeneration,
            frameCallback: callback)
        vps = pendingVPS
        sps = configuredSPS
        pps = configuredPPS
        decoder = nil
        pendingRecoveryIDRPresentationTimes.removeAll(keepingCapacity: true)
        _ = markLossLocked(affectedSSRC: nil)
        lock.unlock()

        // Waiting here is safe because this method is never invoked from the
        // VideoToolbox callback thread. It drains late callbacks before the
        // failure latch is cleared, preventing an old generation from poisoning
        // the replacement session.
        oldDecoder.reset()
        do {
            try replacement.updateFormatDescription(sps: sps, pps: pps, vps: vps)
        } catch {
            log.error("Could not rebuild HEVC decoder: \(error.localizedDescription)")
            replacement.reset()
            return false
        }

        lock.lock()
        guard _isActive,
              streamGeneration == generation,
              mediaGeneration == currentMediaGeneration,
              decoder == nil else {
            lock.unlock()
            replacement.reset()
            return false
        }
        decoder = replacement
        decoderFailureLatch.reset()
        lock.unlock()

        log.info("Rebuilt public VideoToolbox decoder; waiting for recovery IDR")
        drainEarlyVCLIfReady()
        return true
    }

    private func handleParameterSet(
        nalUnit: Data,
        type: ParameterSetType,
        callbacks: inout DeferredCallbacks
    ) {
        lock.lock()
        switch type {
        case .vps: pendingVPS = nalUnit
        case .sps: pendingSPS = nalUnit
        case .pps: pendingPPS = nalUnit
        }
        guard let sps = pendingSPS, let pps = pendingPPS else {
            lock.unlock()
            return
        }
        let decoderRef = decoder
        let vps = pendingVPS
        lock.unlock()

        var codedDimensions: CMVideoDimensions?
        if let decoderRef {
            do {
                try decoderRef.updateFormatDescription(sps: sps, pps: pps, vps: vps)
                codedDimensions = decoderRef.formatDimensions
            } catch {
                log.warning("Failed to configure HEVC format: \(error.localizedDescription)")
            }
        }
        if codedDimensions == nil {
            do {
                codedDimensions = try HEVCDecoder.codedDimensions(
                    sps: sps, pps: pps, vps: vps)
            } catch {
                log.warning("Failed to inspect HEVC format: \(error.localizedDescription)")
            }
        }
        if let codedDimensions,
           codedDimensions.width > 0,
           codedDimensions.height > 0 {
            if let notifyOwner = applyCodedDimensions(
                width: Int(codedDimensions.width),
                height: Int(codedDimensions.height))?.notifyOwner {
                callbacks.add(notifyOwner)
            }
        }
        drainEarlyVCLIfReady()
    }

    /// Apply dimensions carried by the negotiated HEVC parameter sets. In the
    /// default portable one-tile profile this is the complete desktop. The
    /// opt-in tiled profile encodes only a band per output buffer, so it keeps
    /// using explicit RFB geometry for the full height.
    @discardableResult
    func acceptCodedDimensions(width: Int, height: Int) -> VideoFrameGeometry? {
        guard let applied = applyCodedDimensions(width: width, height: height) else {
            return nil
        }
        applied.notifyOwner?()
        return applied.update
    }

    /// Returns the geometry update, if the dimensions changed it, with the
    /// `onFrameGeometryChange` notification for the caller to run once it
    /// holds no lock.
    private func applyCodedDimensions(
        width: Int,
        height: Int
    ) -> (update: VideoFrameGeometry, notifyOwner: (() -> Void)?)? {
        guard width > 0, height > 0 else { return nil }

        let update: VideoFrameGeometry?
        let callback: (@Sendable (VideoFrameGeometry) -> Void)?
        lock.lock()
        codedBandHeight = height
        if !usesDecodingOrderNumbers
            && (width != fullFrameWidth || height != fullFrameHeight) {
            fullFrameWidth = width
            fullFrameHeight = height
            update = VideoFrameGeometry(
                width: width,
                height: height,
                mediaGeneration: mediaGeneration,
                streamGeneration: streamGeneration)
            callback = onFrameGeometryChange
        } else {
            update = nil
            callback = nil
        }
        updateExpectedBandCountLocked()
        lock.unlock()

        guard let update else { return nil }
        log.info(
            "HEVC media geometry \(update.width)x\(update.height) "
                + "generation=\(update.mediaGeneration)")
        guard let callback else { return (update, nil) }
        return (update, { callback(update) })
    }

    private func updateExpectedBandCountLocked() {
        guard fullFrameHeight > 0, codedBandHeight > 0 else { return }
        // ServerInit can describe the union of every physical monitor before
        // DisplayInfo identifies the one receiver selected for this media
        // stream. Never infer more sources than the AVC negotiation created;
        // otherwise a 5K primary in a taller multi-monitor desktop makes the
        // DON bootstrap wait forever for SSRCs that do not exist.
        let count = min(
            numberOfTiles,
            Self.expectedBandCount(
                fullFrameHeight: fullFrameHeight,
                codedBandHeight: codedBandHeight))
        guard count != expectedBandCount else { return }
        expectedBandCount = count
        donReorderBuffer.reconfigureExpectedSourceCount(count)
    }

    static func expectedBandCount(fullFrameHeight: Int, codedBandHeight: Int) -> Int {
        guard fullFrameHeight > 0, codedBandHeight > 0 else { return 0 }
        return max(1, (fullFrameHeight + codedBandHeight - 1) / codedBandHeight)
    }

    /// Decode, in arrival order, any VCL NAL units that beat their parameter
    /// sets to the pipeline (they include the bands' only IRAPs).
    private func drainEarlyVCLIfReady() {
        lock.lock()
        guard !earlyVCLBuffer.isEmpty else {
            lock.unlock()
            return
        }
        let buffered = earlyVCLBuffer
        earlyVCLBuffer.removeAll()
        lock.unlock()

        for item in buffered {
            guard let decoderRef = decoderForSource(item.ssrc), decoderRef.isReady else {
                bufferEarlyVCL(
                    nals: item.nals,
                    ssrc: item.ssrc,
                    timestamp: item.timestamp,
                    don: item.don)
                continue
            }
            let pts = CMTime(
                value: nextPresentationTimeValue(),
                timescale: HEVCPresentationTimeline.timescale)
            let nalType = item.nals.first.flatMap { nal -> UInt8? in
                guard nal.count >= 2 else { return nil }
                return (nal[nal.startIndex] >> 1) & 0x3f
            }
            let recoveryIDRArmed = armRecoveryIDRIfNeeded(
                nalType: nalType ?? .max,
                presentationTime: pts)
            do {
                try decoderRef.decode(
                    nalUnits: item.nals,
                    presentationTime: pts,
                    frameTag: item.ssrc)
                recordDecodeSubmission()
            } catch {
                if recoveryIDRArmed {
                    cancelRecoveryIDR(presentationTime: pts)
                }
                log.warning("Failed to decode buffered startup frame: \(error.localizedDescription)")
            }
        }
    }

    /// The SSRCs are spatial labels on one global HEVC reference sequence, not
    /// independently decodable streams. Route every source through the shared
    /// session after the DON reorder stage.
    private func decoderForSource(_ ssrc: UInt32) -> HEVCDecoder? {
        _ = ssrc
        lock.lock()
        let decoderRef = decoderFailureLatch.hasFailed ? nil : decoder
        lock.unlock()
        return decoderRef
    }

    private func makeDecoder(
        streamGeneration: UInt64,
        mediaGeneration: UInt64,
        frameCallback: @escaping FrameCallback
    ) -> HEVCDecoder {
        let orderer = DecodedFrameOrderer(callback: frameCallback)
        return HEVCDecoder(
            frameCallback: { [weak self] pixelBuffer, pts, frameTag in
                guard let result = self?.recordDecoderOutput(
                    streamGeneration: streamGeneration,
                    mediaGeneration: mediaGeneration,
                    presentationTime: pts),
                      result.accepted else {
                    return
                }
                if result.completedRecovery {
                    self?.log.warning(
                        "Completed compound HEVC recovery after decoded IDR output")
                }
                orderer.submit(
                    pixelBuffer: pixelBuffer,
                    pts: pts,
                    ssrc: frameTag)
            },
            failureCallback: { [weak self] status, pts, frameTag in
                // VideoToolbox's callback thread holds none of our locks.
                self?.recordDecoderFailure(
                    streamGeneration: streamGeneration,
                    mediaGeneration: mediaGeneration,
                    status: status,
                    presentationTime: pts,
                    ssrc: frameTag)?()
            })
    }

    private func logMultiNALAccessUnitIfNeeded(don: UInt16, count: Int) {
        guard count > 1 else { return }
        lock.lock()
        let shouldLog = multiNALAccessUnitLogCount < 8
        multiNALAccessUnitLogCount += 1
        lock.unlock()
        if shouldLog {
            log.info("Submitting complete multi-NAL HEVC access unit DON=\(don) nals=\(count)")
        }
    }

    private func appendSequentialVCL(_ unit: RTPDemuxer.DemuxedNAL) {
        lock.lock()
        sequentialAccessUnitAssembler.appendVCL(unit)
        lock.unlock()
    }

    private func finishSequentialAccessUnit(
        ssrc: UInt32
    ) -> CompoundHEVCDONReorderBuffer.AccessUnit? {
        lock.lock()
        defer { lock.unlock() }
        return sequentialAccessUnitAssembler.finish(ssrc: ssrc)
    }

    private func discardPartialSequentialAccessUnit() {
        lock.lock()
        sequentialAccessUnitAssembler.discardPartialAccessUnit()
        lock.unlock()
    }

    /// Restore completed VCL units to the single cross-SSRC HEVC timeline.
    /// Startup waits for the first compound pass so a late first band cannot be
    /// discarded. Once started, one future picture is enough to release the
    /// current DON; a bounded gap is skipped rather than freezing forever.
    private func enqueueAndDrainReorder(
        _ nals: [RTPDemuxer.DemuxedNAL]
    ) -> CompoundHEVCDONReorderBuffer.Result {
        lock.lock()
        defer { lock.unlock() }
        let result = donReorderBuffer.enqueue(nals)
        if let startupOrder = result.startupOrder {
            let values = startupOrder.map(String.init).joined(separator: ",")
            log.info("Starting compound HEVC decode at DONs [\(values)] across \(seenVideoSSRCs.count) SSRCs")
        }
        for gap in result.skippedGaps {
            log.warning("Skipping missing compound HEVC DON \(gap.missingDON); "
                + "next=\(gap.nextDON) buffered=\(gap.bufferedFrameCount)")
            // Apple legitimately omits unchanged tiles. RTP sequence tracking,
            // not a sparse global DON timeline, is the damage authority.
        }
        return result
    }

    /// Releases asynchronous VideoToolbox callbacks in the exact global order
    /// in which compound access units were submitted.
    ///
    /// A bottom band is often much larger than the upper bands. Hardware may
    /// therefore finish it after callbacks from the next compound frame. If
    /// those callbacks reach the renderer directly, the bottom of the screen
    /// visibly regresses or flickers. The synthetic PTS is a unique submission
    /// ordinal, so buffering a small window restores the DON order without any
    /// private subframe API.
    final class DecodedFrameOrderer: @unchecked Sendable {
        private let lock = NSLock()
        private var pending: [Int64: (CVPixelBuffer, UInt32)] = [:]
        private var nextIndex: Int64 = 0
        private let callback: FrameCallback
        private let maxHeld = 6
        private let maxHoldNanos: UInt64 = 100_000_000
        private var gapTimerGeneration: UInt64 = 0
        private var gapTimerScheduled = false

        init(callback: @escaping FrameCallback) {
            self.callback = callback
        }

        func submit(pixelBuffer: CVPixelBuffer, pts: CMTime, ssrc: UInt32) {
            let index = Int64(pts.value) / Int64(HEVCPresentationTimeline.step)
            var ready: [(CVPixelBuffer, UInt32)] = []

            lock.lock()
            if index < nextIndex {
                lock.unlock()
                return
            }
            pending[index] = (pixelBuffer, ssrc)
            drainLocked(allowGapSkip: pending.count > maxHeld, into: &ready)
            scheduleGapTimerLockedIfNeeded()
            lock.unlock()

            for (buffer, source) in ready {
                callback(buffer, source)
            }
        }

        private func scheduleGapTimerLockedIfNeeded() {
            guard !pending.isEmpty, pending[nextIndex] == nil else {
                if gapTimerScheduled {
                    gapTimerGeneration &+= 1
                    gapTimerScheduled = false
                }
                return
            }
            guard !gapTimerScheduled else { return }
            gapTimerScheduled = true
            gapTimerGeneration &+= 1
            let generation = gapTimerGeneration
            DispatchQueue.global(qos: .userInteractive).asyncAfter(
                deadline: .now() + .nanoseconds(Int(maxHoldNanos))) { [weak self] in
                    self?.expireGap(generation: generation)
                }
        }

        private func expireGap(generation: UInt64) {
            var ready: [(CVPixelBuffer, UInt32)] = []
            lock.lock()
            guard gapTimerScheduled, gapTimerGeneration == generation else {
                lock.unlock()
                return
            }
            gapTimerScheduled = false
            drainLocked(allowGapSkip: true, into: &ready)
            scheduleGapTimerLockedIfNeeded()
            lock.unlock()

            for (buffer, source) in ready {
                callback(buffer, source)
            }
        }

        private func drainLocked(
            allowGapSkip: Bool,
            into ready: inout [(CVPixelBuffer, UInt32)]
        ) {
            while true {
                if let frame = pending.removeValue(forKey: nextIndex) {
                    ready.append(frame)
                    nextIndex += 1
                } else if allowGapSkip, let smallest = pending.keys.min() {
                    nextIndex = smallest
                } else {
                    break
                }
            }
        }
    }

}
