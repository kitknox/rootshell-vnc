import Foundation

/// Fixed-window duplicate detector with O(1) membership and eviction. RTP
/// sequence numbers wrap, so entries leave the set in arrival order rather
/// than being retained for the lifetime of the session.
struct BoundedRTPSequenceHistory {
    private let capacity: Int
    private var order: [UInt16] = []
    private var head = 0
    private var members: Set<UInt16> = []

    init(capacity: Int = 256) {
        precondition(capacity > 0)
        self.capacity = capacity
        order.reserveCapacity(capacity * 2)
        members.reserveCapacity(capacity)
    }

    mutating func insert(_ sequence: UInt16) -> Bool {
        guard members.insert(sequence).inserted else { return false }
        order.append(sequence)
        if order.count - head > capacity {
            members.remove(order[head])
            head += 1
        }
        if head >= capacity, head * 2 >= order.count {
            order.removeFirst(head)
            head = 0
        }
        return true
    }
}

/// Thread-safe SRTP batch decryptor shared between the UDP read task and
/// ``TransportSession``. Running AES-256-CTR + HMAC-SHA1-80 off the transport
/// actor keeps input sends (`sendInputEvents`, scroll, gesture) uncontended
/// during high-bitrate HEVC bursts.
final class AppleMediaSRTPDecryptor: @unchecked Sendable {
    enum DecryptedItem: Sendable {
        /// `wire` is the protected datagram `rtp` was recovered from. It stays
        /// with the item so the session can authenticate the packet again if
        /// `context` was replaced while the batch waited for the actor.
        case decrypted(
            rtp: Data,
            wire: Data,
            ssrc: UInt32,
            context: AppleSRTPContext,
            arrivalNanos: UInt64)
        case raw(datagram: Data, arrivalNanos: UInt64)
    }

    /// What the session does with a packet that was authenticated off-actor.
    enum Disposition: Equatable, Sendable {
        /// The authenticating context is still active: deliver the packet.
        case accept
        /// The authenticating context was replaced while the batch was in
        /// flight. Offer the wire datagram to the current contexts, which
        /// reject it if the keys really changed.
        case reauthenticate
        /// The session holds no contexts: the keys that authenticated this
        /// packet were retired by a renegotiation or teardown.
        case drop
    }

    /// Decide whether a packet authenticated under `batchGeneration` is still
    /// valid for the session's active SRTP state. A matching generation means
    /// the batch was decrypted with exactly `activeContexts`.
    static func disposition(
        ofPacketAuthenticatedBy context: AppleSRTPContext,
        batchGeneration: UInt64,
        activeGeneration: UInt64,
        activeContexts: [AppleSRTPContext]
    ) -> Disposition {
        if batchGeneration == activeGeneration { return .accept }
        if activeContexts.contains(where: { $0 === context }) { return .accept }
        return activeContexts.isEmpty ? .drop : .reauthenticate
    }

    struct DecryptedBatch: Sendable {
        let generation: UInt64
        let items: [DecryptedItem]
    }

    private let lock = NSLock()
    private var contexts: [AppleSRTPContext] = []
    private var contextBySSRC: [UInt32: AppleSRTPContext] = [:]
    private var expectsSRTP = false
    private var generation: UInt64 = 0

    @discardableResult
    func configure(contexts newContexts: [AppleSRTPContext], expectsSRTP: Bool) -> UInt64 {
        lock.lock()
        contexts = newContexts
        contextBySSRC.removeAll(keepingCapacity: true)
        self.expectsSRTP = expectsSRTP
        generation &+= 1
        let activeGeneration = generation
        lock.unlock()
        return activeGeneration
    }

    func setExpectsSRTP(_ value: Bool) {
        lock.lock()
        expectsSRTP = value
        lock.unlock()
    }

    @discardableResult
    func clear() -> UInt64 {
        lock.lock()
        contexts.removeAll(keepingCapacity: false)
        contextBySSRC.removeAll(keepingCapacity: false)
        expectsSRTP = false
        generation &+= 1
        let activeGeneration = generation
        lock.unlock()
        return activeGeneration
    }

    func decryptBatch(_ datagrams: [PosixUDPDatagram]) -> DecryptedBatch {
        lock.lock()
        let activeContexts = contexts
        let activeGeneration = generation
        var localBySSRC = contextBySSRC
        lock.unlock()

        guard !datagrams.isEmpty else {
            return DecryptedBatch(generation: activeGeneration, items: [])
        }

        if activeContexts.isEmpty {
            return DecryptedBatch(
                generation: activeGeneration,
                items: datagrams.map { .raw(datagram: $0.data, arrivalNanos: $0.arrivalNanos) })
        }

        var items: [DecryptedItem] = []
        items.reserveCapacity(datagrams.count)
        var newlyBound: [(UInt32, AppleSRTPContext)] = []

        for datagram in datagrams {
            let data = datagram.data
            guard data.count >= 12 else {
                items.append(.raw(datagram: data, arrivalNanos: datagram.arrivalNanos))
                continue
            }
            let base = data.startIndex
            let firstByte = data[base]
            let secondByte = data[base + 1]
            // RTCP packets (PT 192...223) or non-RTP v2 packets stay on the raw path.
            guard (firstByte >> 6) == 2,
                  secondByte < 192 || secondByte > 223 else {
                items.append(.raw(datagram: data, arrivalNanos: datagram.arrivalNanos))
                continue
            }
            let ssrc = UInt32(data[base + 8]) << 24
                | UInt32(data[base + 9]) << 16
                | UInt32(data[base + 10]) << 8
                | UInt32(data[base + 11])

            if let cached = localBySSRC[ssrc],
               let packet = try? cached.unprotect(data) {
                items.append(.decrypted(
                    rtp: packet,
                    wire: data,
                    ssrc: ssrc,
                    context: cached,
                    arrivalNanos: datagram.arrivalNanos))
                continue
            }

            var matched = false
            for context in activeContexts {
                if let packet = try? context.unprotect(data) {
                    localBySSRC[ssrc] = context
                    newlyBound.append((ssrc, context))
                    items.append(.decrypted(
                        rtp: packet,
                        wire: data,
                        ssrc: ssrc,
                        context: context,
                        arrivalNanos: datagram.arrivalNanos))
                    matched = true
                    break
                }
            }
            if !matched {
                items.append(.raw(datagram: data, arrivalNanos: datagram.arrivalNanos))
            }
        }

        if !newlyBound.isEmpty {
            lock.lock()
            if generation == activeGeneration {
                for (ssrc, context) in newlyBound {
                    contextBySSRC[ssrc] = context
                }
            }
            lock.unlock()
        }

        return DecryptedBatch(generation: activeGeneration, items: items)
    }
}

/// The session's SRTP receive contexts, by media key.
///
/// A context carries each source's rollover counter, which only the packets
/// it has seen can establish: a replacement built from the same key starts at
/// zero and rejects every packet of a source that has already wrapped its
/// 16-bit sequence number, permanently. A negotiation rebuilds the session's
/// SRTP state with unchanged keys after the stream answer, and RTP sequences
/// start at a random value, so that wrap can fall inside the startup burst.
/// Rebuilding through this store keeps the context for an unchanged key and
/// creates one only for a key it has not seen.
struct AppleMediaSRTPReceiveContextStore {
    private var active: [Data: AppleSRTPContext] = [:]
    private var previous: [Data: AppleSRTPContext] = [:]

    /// Start a rebuild: contexts become reusable by key, and any not asked
    /// for again before `finishRebuild()` are retired.
    mutating func beginRebuild() {
        previous = active
        active.removeAll(keepingCapacity: true)
    }

    mutating func context(forMediaKey key: Data) throws -> AppleSRTPContext {
        if let context = active[key] { return context }
        let context = try previous[key] ?? AppleSRTPContext(mediaKey: key)
        active[key] = context
        return context
    }

    mutating func finishRebuild() {
        previous.removeAll(keepingCapacity: false)
    }

    /// Retire every context: the keys themselves are being replaced.
    mutating func removeAll() {
        active.removeAll(keepingCapacity: false)
        previous.removeAll(keepingCapacity: false)
    }
}

/// Ordered handoff between the transport actor and the media decode queue.
///
/// Packets received before the decoder installs its sink stay here instead of
/// taking a second delivery path through `AsyncStream`. Installing the sink and
/// draining this buffer happen in one actor turn, so packets on either side of
/// the handoff cannot overtake one another.
struct AppleMediaPacketHandoff {
    typealias Sink = @Sendable (Data, Int?) -> Void
    typealias BatchSink = @Sendable ([(data: Data, displayIndex: Int?)]) -> Void

    struct DrainResult: Equatable {
        let packetCount: Int
        let byteCount: Int
        let overflowed: Bool
        let droppedPacketCount: Int
    }

    enum DeliveryResult: Equatable {
        case delivered
        case buffered
        case overflow
    }

    private let maximumPackets: Int
    private let maximumBytes: Int
    private var sink: Sink?
    private var batchSink: BatchSink?
    /// The installed batch sink serves one stream offer; see
    /// `retireOfferScopedSink()`.
    private var batchSinkRetiresOnStreamOffer = false
    private var pending: [(data: Data, displayIndex: Int?)] = []
    private var pendingBytes = 0
    private(set) var overflowed = false
    private(set) var droppedPacketCount = 0

    init(maximumPackets: Int = 16_384, maximumBytes: Int = 64 * 1024 * 1024) {
        self.maximumPackets = maximumPackets
        self.maximumBytes = maximumBytes
    }

    var bufferedPacketCount: Int { pending.count }
    var bufferedByteCount: Int { pendingBytes }

    mutating func deliver(
        _ packet: Data,
        displayIndex: Int? = nil
    ) -> DeliveryResult {
        if let batchSink {
            batchSink([(packet, displayIndex)])
            return .delivered
        }
        if let sink {
            sink(packet, displayIndex)
            return .delivered
        }

        guard pending.count < maximumPackets,
              pendingBytes <= maximumBytes - packet.count else {
            // Keep the oldest startup packets (parameter sets and the initial
            // IRAP) and reject the newest data. The caller requests a refresh
            // after the sink is installed if this ever occurs.
            overflowed = true
            droppedPacketCount += 1
            return .overflow
        }

        pending.append((packet, displayIndex))
        pendingBytes += packet.count
        return .buffered
    }

    mutating func deliverBatch(
        _ packets: [(data: Data, displayIndex: Int?)]
    ) -> DeliveryResult {
        guard !packets.isEmpty else { return .delivered }
        if let batchSink {
            batchSink(packets)
            return .delivered
        }
        if let sink {
            for packet in packets {
                sink(packet.data, packet.displayIndex)
            }
            return .delivered
        }
        var result: DeliveryResult = .buffered
        for packet in packets {
            if deliver(packet.data, displayIndex: packet.displayIndex) == .overflow {
                result = .overflow
            }
        }
        return result
    }

    mutating func installSink(_ newSink: Sink?) -> DrainResult {
        batchSink = nil
        batchSinkRetiresOnStreamOffer = false
        sink = newSink
        guard let newSink else {
            // Nothing is drained, so nothing is reported: an overflow stays
            // on record for the sink that receives the truncated backlog.
            return DrainResult(
                packetCount: 0,
                byteCount: 0,
                overflowed: false,
                droppedPacketCount: 0)
        }

        let packets = pending
        let bytes = pendingBytes
        pending.removeAll(keepingCapacity: true)
        pendingBytes = 0
        for packet in packets {
            newSink(packet.data, packet.displayIndex)
        }
        return takeDrainResult(packetCount: packets.count, byteCount: bytes)
    }

    mutating func installBatchSink(
        _ newSink: BatchSink?,
        retiresOnStreamOffer: Bool = false
    ) -> DrainResult {
        sink = nil
        batchSink = newSink
        batchSinkRetiresOnStreamOffer = newSink != nil && retiresOnStreamOffer
        guard let newSink else {
            // Nothing is drained, so nothing is reported: an overflow stays
            // on record for the sink that receives the truncated backlog.
            return DrainResult(
                packetCount: 0,
                byteCount: 0,
                overflowed: false,
                droppedPacketCount: 0)
        }

        let packets = pending
        let bytes = pendingBytes
        pending.removeAll(keepingCapacity: true)
        pendingBytes = 0
        if !packets.isEmpty {
            newSink(packets)
        }
        return takeDrainResult(packetCount: packets.count, byteCount: bytes)
    }

    /// Report a drain and close the buffering interval it ended. The overflow
    /// record describes that interval only: left set, every later sink
    /// installation would report the same loss again and trigger recovery for
    /// a stream that lost nothing.
    private mutating func takeDrainResult(packetCount: Int, byteCount: Int) -> DrainResult {
        defer {
            overflowed = false
            droppedPacketCount = 0
        }
        return DrainResult(
            packetCount: packetCount,
            byteCount: byteCount,
            overflowed: overflowed,
            droppedPacketCount: droppedPacketCount)
    }

    /// Detach a sink that was installed for a single stream offer, because
    /// the next offer is being published. Its owner rebuilds its decoder for
    /// that offer before installing a replacement; until then packets are
    /// held here in order, exactly as before the first sink existed, instead
    /// of reaching a sink whose stream is about to be retired. Returns false,
    /// changing nothing, for a sink that was not installed that way.
    mutating func retireOfferScopedSink() -> Bool {
        guard batchSinkRetiresOnStreamOffer else { return false }
        batchSink = nil
        batchSinkRetiresOnStreamOffer = false
        return true
    }

    mutating func reset() {
        sink = nil
        batchSink = nil
        batchSinkRetiresOnStreamOffer = false
        pending.removeAll(keepingCapacity: false)
        pendingBytes = 0
        overflowed = false
        droppedPacketCount = 0
    }
}

/// Small packet-level jitter buffer for Apple's per-SSRC RTP sequence spaces.
/// It restores benign UDP reordering before HEVC FU reassembly and reports a
/// loss only after the missing packet has exceeded a bounded wait.
struct AppleMediaRTPReorderBuffer {
    struct Gap: Equatable {
        let ssrc: UInt32
        let missingPacketCount: Int
        let frameRTPTimestamp: UInt32
        let estimatedFramePacketCount: Int
        let frameSequenceNumber: UInt16?

        init(
            ssrc: UInt32,
            missingPacketCount: Int,
            frameRTPTimestamp: UInt32 = 0,
            estimatedFramePacketCount: Int? = nil,
            frameSequenceNumber: UInt16? = nil
        ) {
            self.ssrc = ssrc
            self.missingPacketCount = missingPacketCount
            self.frameRTPTimestamp = frameRTPTimestamp
            self.estimatedFramePacketCount = estimatedFramePacketCount
                ?? missingPacketCount
            self.frameSequenceNumber = frameSequenceNumber
        }
    }

    struct RetransmissionRequest: Equatable {
        let ssrc: UInt32
        let missingSequences: [UInt16]
    }

    struct Result {
        fileprivate var released: [(ssrc: UInt32, arrivalOrdinal: UInt64, data: Data)] = []
        fileprivate var preorderedPackets: [Data]?
        var gaps: [Gap] = []
        var retransmissionRequests: [RetransmissionRequest] = []
        var duplicateOrLatePacketCount = 0

        var packets: [Data] {
            if let preorderedPackets { return preorderedPackets }
            if released.isEmpty { return [] }
            if released.count == 1 { return [released[0].data] }
            let firstSSRC = released[0].ssrc
            var singleStream = true
            for index in 1..<released.count where released[index].ssrc != firstSSRC {
                singleStream = false
                break
            }
            if singleStream {
                return released.map(\.data)
            }
            return packetsOrderedByArrivalSlots()
        }

        private func packetsOrderedByArrivalSlots() -> [Data] {
            // Preserve arrival ordering between independent SSRCs, but assign
            // each stream's arrival slots to its sequence-ordered releases.
            // Sorting directly by each packet's original arrival ordinal would
            // undo the exact within-SSRC reordering this buffer exists to do.
            let streams = Dictionary(grouping: released, by: \.ssrc)
            var globallyOrdered: [(ordinal: UInt64, data: Data)] = []
            globallyOrdered.reserveCapacity(released.count)
            for packets in streams.values {
                let arrivalSlots = packets.map(\.arrivalOrdinal).sorted()
                for (index, packet) in packets.enumerated() {
                    globallyOrdered.append((arrivalSlots[index], packet.data))
                }
            }
            return globallyOrdered.sorted { $0.ordinal < $1.ordinal }.map(\.data)
        }

        mutating func merge(_ other: Result) {
            released.append(contentsOf: other.released)
            gaps.append(contentsOf: other.gaps)
            retransmissionRequests.append(contentsOf: other.retransmissionRequests)
            duplicateOrLatePacketCount += other.duplicateOrLatePacketCount
        }
    }

    private struct BufferedPacket {
        let data: Data
        let arrivalNanos: UInt64
        let ordinal: UInt64
    }

    private struct StreamState {
        var firstSequence: UInt16
        var startupDeadlineNanos: UInt64
        var lastAcceptedArrivalNanos: UInt64
        var interruptionPending = false
        var started = false
        var nextSequence: UInt16?
        /// Closest packet ahead of `nextSequence` while that sequence is
        /// missing. Keeping this incrementally avoids an O(buffer size) scan
        /// for every packet received behind the same hole.
        var nearestFutureSequence: UInt16?
        var gapDeadlineNanos: UInt64?
        var nextNACKDeadlineNanos: UInt64?
        var pending: [UInt16: BufferedPacket] = [:]
        /// RTP marker delimits frames even on Apple screen streams whose RTP
        /// timestamp does not advance. These fields let confirmed loss report
        /// the observed damaged-frame size instead of inventing a constant.
        var activeFrameTimestamp: UInt32?
        var activeFrameReceivedPacketCount = 0
        var activeFrameExpectedPacketCount: Int?
        var activeFrameSequenceNumber: UInt16?
    }

    private let startupHoldNanos: UInt64
    private let maximumGapWaitNanos: UInt64
    private let nackRetryNanos: UInt64
    private let discontinuitySilenceNanos: UInt64
    private let maximumBufferedPacketsPerStream: Int
    private var streams: [UInt32: StreamState] = [:]
    private var nextOrdinal: UInt64 = 0
    /// Packets from healthy sibling SSRCs wait here while any compound-video
    /// SSRC has an RTP hole. Letting one band advance while another waits for
    /// retransmission makes the DON reorderer skip the missing global picture
    /// and submit dependent HEVC frames before loss recovery can gate them.
    private var compoundGapHeldPackets: [Data] = []
    /// Internal diagnostic used by regression tests to ensure loss handling
    /// scales with sequence holes rather than packets buffered behind them.
    private(set) var nearestFutureScanCount: UInt64 = 0

    init(
        startupHoldNanos: UInt64 = 8_000_000,
        // This wait is entered only after a sequence hole, so it does not add
        // latency to normal playback. One hundred milliseconds was too short:
        // a lone delayed/retransmitted fragment was declared lost and poisoned
        // the long HEVC reference chain. Keep requesting it for a bounded 300
        // ms before releasing newer packets.
        maximumGapWaitNanos: UInt64 = 300_000_000,
        nackRetryNanos: UInt64 = 25_000_000,
        discontinuitySilenceNanos: UInt64 = 1_000_000_000,
        // Leave generous headroom above the native 40 Mbps receive ceiling.
        // The former 512-packet cap could force a loss before the time deadline
        // during high-bitrate motion.
        maximumBufferedPacketsPerStream: Int = 4096
    ) {
        self.startupHoldNanos = startupHoldNanos
        self.maximumGapWaitNanos = maximumGapWaitNanos
        self.nackRetryNanos = nackRetryNanos
        self.discontinuitySilenceNanos = discontinuitySilenceNanos
        self.maximumBufferedPacketsPerStream = maximumBufferedPacketsPerStream
    }

    var queuedPacketCount: Int {
        streams.values.reduce(0) { $0 + $1.pending.count }
    }

    var nextDeadlineNanos: UInt64? {
        var earliest: UInt64?
        for state in streams.values {
            let candidate: UInt64?
            if !state.started {
                candidate = state.startupDeadlineNanos
            } else if let gap = state.gapDeadlineNanos, let nack = state.nextNACKDeadlineNanos {
                candidate = min(gap, nack)
            } else {
                candidate = state.gapDeadlineNanos ?? state.nextNACKDeadlineNanos
            }
            if let candidate {
                earliest = earliest.map { min($0, candidate) } ?? candidate
            }
        }
        return earliest
    }

    private func hasAnyPendingGap() -> Bool {
        for state in streams.values {
            if state.gapDeadlineNanos != nil {
                return true
            }
        }
        return false
    }

    mutating func insert(
        packet: Data,
        ssrc: UInt32,
        sequence: UInt16,
        nowNanos: UInt64
    ) -> Result {
        var result: Result
        if let earliest = nextDeadlineNanos, nowNanos >= earliest {
            result = flushExpiredRaw(nowNanos: nowNanos)
        } else {
            result = Result()
        }
        nextOrdinal &+= 1

        // Remove before mutating so `state.pending` stays uniquely referenced
        // (avoids Dictionary CoW copies on every inserted/drained packet).
        var state = streams.removeValue(forKey: ssrc) ?? StreamState(
            firstSequence: sequence,
            startupDeadlineNanos: nowNanos &+ startupHoldNanos,
            lastAcceptedArrivalNanos: nowNanos)

        // Steady-state fast path: in-order packet on a started stream with no
        // buffered future packets. Skips dictionary insert+remove and sorting.
        if state.started,
           let next = state.nextSequence,
           sequence == next,
           state.pending.isEmpty {
            state.interruptionPending = false
            state.lastAcceptedArrivalNanos = nowNanos
            state.nextSequence = next &+ 1
            state.gapDeadlineNanos = nil
            state.nextNACKDeadlineNanos = nil
            state.nearestFutureSequence = nil
            noteReleasedFramePacket(packet, state: &state)
            streams[ssrc] = state
            if result.released.isEmpty && !hasAnyPendingGap() && compoundGapHeldPackets.isEmpty {
                result.preorderedPackets = [packet]
                return result
            }
            result.released.append((ssrc, nextOrdinal, packet))
            return finalizeCompoundGapHold(result)
        }

        if state.pending[sequence] != nil {
            result.duplicateOrLatePacketCount += 1
            streams[ssrc] = state
            return finalizeCompoundGapHold(result)
        }

        var interruptionGapPacketCount: Int?
        if state.started, let next = state.nextSequence {
            let forward = sequence &- next
            let followedLongSilence = nowNanos &- state.lastAcceptedArrivalNanos
                >= discontinuitySilenceNanos
            if forward != 0 && (state.interruptionPending || followedLongSilence) {
                // After app suspension or a genuine media outage, more than
                // half of the 16-bit sequence space can pass. That is a known
                // forward discontinuity, not a permanently "late" packet.
                // Drop stale buffered fragments and report the exact modulo
                // distance immediately instead of waiting for impossible NACKs.
                interruptionGapPacketCount = Int(forward)
                state.pending.removeAll(keepingCapacity: true)
                state.nearestFutureSequence = nil
                state.gapDeadlineNanos = nil
                state.nextNACKDeadlineNanos = nil
                state.activeFrameTimestamp = nil
                state.activeFrameReceivedPacketCount = 0
                state.activeFrameExpectedPacketCount = nil
                state.activeFrameSequenceNumber = nil
            } else if forward >= 0x8000 {
                result.duplicateOrLatePacketCount += 1
                streams[ssrc] = state
                return finalizeCompoundGapHold(result)
            }
        }

        state.interruptionPending = false
        state.lastAcceptedArrivalNanos = nowNanos
        state.pending[sequence] = BufferedPacket(
            data: packet,
            arrivalNanos: nowNanos,
            ordinal: nextOrdinal)
        if state.started, let next = state.nextSequence, sequence != next {
            let distance = sequence &- next
            if distance < 0x8000 {
                if let nearest = state.nearestFutureSequence {
                    if distance < (nearest &- next) {
                        state.nearestFutureSequence = sequence
                    }
                } else {
                    state.nearestFutureSequence = sequence
                }
            }
        }
        if let missingPacketCount = interruptionGapPacketCount {
            let frame = estimateDamagedFrame(
                state: state,
                nearestSequence: sequence,
                missingPacketCount: missingPacketCount)
            result.gaps.append(Gap(
                ssrc: ssrc,
                missingPacketCount: missingPacketCount,
                frameRTPTimestamp: frame.timestamp,
                estimatedFramePacketCount: frame.packetCount,
                frameSequenceNumber: frame.sequenceNumber))
            state.nextSequence = sequence
            drain(
                &state,
                ssrc: ssrc,
                nowNanos: nowNanos,
                forceGap: false,
                into: &result)
            streams[ssrc] = state
            return finalizeCompoundGapHold(result)
        }
        if state.pending.count >= maximumBufferedPacketsPerStream {
            if !state.started { start(&state) }
            drain(&state, ssrc: ssrc, nowNanos: nowNanos, forceGap: true, into: &result)
        } else if state.started {
            drain(&state, ssrc: ssrc, nowNanos: nowNanos, forceGap: false, into: &result)
        }
        streams[ssrc] = state
        return finalizeCompoundGapHold(result)
    }

    mutating func flushExpired(nowNanos: UInt64) -> Result {
        finalizeCompoundGapHold(flushExpiredRaw(nowNanos: nowNanos))
    }

    private mutating func flushExpiredRaw(nowNanos: UInt64) -> Result {
        var result = Result()

        for ssrc in Array(streams.keys) {
            guard var state = streams.removeValue(forKey: ssrc) else { continue }
            if !state.started, nowNanos >= state.startupDeadlineNanos {
                start(&state)
            }

            var streamResult = Result()
            let forceGap = state.gapDeadlineNanos.map { nowNanos >= $0 } ?? false
            drain(&state, ssrc: ssrc, nowNanos: nowNanos, forceGap: forceGap, into: &streamResult)

            result.merge(streamResult)
            streams[ssrc] = state
        }
        return result
    }

    mutating func reset() {
        streams.removeAll(keepingCapacity: false)
        compoundGapHeldPackets.removeAll(keepingCapacity: false)
        nextOrdinal = 0
        nearestFutureScanCount = 0
    }

    /// Mark a known application/media interruption. Pending pre-suspension
    /// fragments cannot complete after foregrounding, but retain the expected
    /// sequence so the first new packet yields a real measured gap.
    mutating func markMediaInterruption() {
        for ssrc in Array(streams.keys) {
            guard var state = streams[ssrc] else { continue }
            state.pending.removeAll(keepingCapacity: true)
            state.nearestFutureSequence = nil
            state.gapDeadlineNanos = nil
            state.nextNACKDeadlineNanos = nil
            state.interruptionPending = true
            streams[ssrc] = state
        }
    }

    private func start(_ state: inout StreamState) {
        guard !state.started, !state.pending.isEmpty else { return }
        let reference = state.firstSequence
        let earliest = state.pending.keys.min { lhs, rhs in
            Self.signedDistance(lhs, from: reference) < Self.signedDistance(rhs, from: reference)
        }!
        state.started = true
        state.nextSequence = earliest
        state.nearestFutureSequence = nil
    }

    private mutating func drain(
        _ state: inout StreamState,
        ssrc: UInt32,
        nowNanos: UInt64,
        forceGap: Bool,
        into result: inout Result
    ) {
        guard state.started, var next = state.nextSequence else { return }
        var shouldForceGap = forceGap

        while true {
            if let buffered = state.pending.removeValue(forKey: next) {
                if state.nearestFutureSequence == next {
                    state.nearestFutureSequence = nil
                }
                result.released.append((ssrc, buffered.ordinal, buffered.data))
                noteReleasedFramePacket(buffered.data, state: &state)
                next &+= 1
                state.nextSequence = next
                state.gapDeadlineNanos = nil
                state.nextNACKDeadlineNanos = nil
                shouldForceGap = false
                continue
            }

            let cachedNearest = state.nearestFutureSequence.flatMap { candidate -> UInt16? in
                let distance = candidate &- next
                guard distance != 0, distance < 0x8000,
                      state.pending[candidate] != nil else { return nil }
                return candidate
            }
            let nearest = cachedNearest ?? nearestFutureSequence(
                to: next,
                in: state.pending)
            state.nearestFutureSequence = nearest
            guard let nearest else {
                state.nearestFutureSequence = nil
                state.gapDeadlineNanos = nil
                state.nextNACKDeadlineNanos = nil
                break
            }

            let missing = Int(nearest &- next)
            if shouldForceGap || state.pending.count >= maximumBufferedPacketsPerStream {
                let frame = estimateDamagedFrame(
                    state: state,
                    nearestSequence: nearest,
                    missingPacketCount: missing)
                result.gaps.append(Gap(
                    ssrc: ssrc,
                    missingPacketCount: missing,
                    frameRTPTimestamp: frame.timestamp,
                    estimatedFramePacketCount: frame.packetCount,
                    frameSequenceNumber: frame.sequenceNumber))
                next = nearest
                state.nextSequence = nearest
                state.gapDeadlineNanos = nil
                state.nextNACKDeadlineNanos = nil
                shouldForceGap = false
                continue
            }

            if state.gapDeadlineNanos == nil {
                let oldestArrival = state.pending.values.map(\.arrivalNanos).min() ?? nowNanos
                state.gapDeadlineNanos = oldestArrival &+ maximumGapWaitNanos
                state.nextNACKDeadlineNanos = nowNanos
            }
            if let nackDeadline = state.nextNACKDeadlineNanos,
               nowNanos >= nackDeadline {
                // RFC 4585 Generic NACK can describe many holes, but cap one
                // request to a bounded window. A pathological jump must not
                // allocate tens of thousands of sequence numbers.
                let requestCount = min(missing, 256)
                let sequences = (0..<requestCount).map { next &+ UInt16($0) }
                result.retransmissionRequests.append(.init(
                    ssrc: ssrc,
                    missingSequences: sequences))
                state.nextNACKDeadlineNanos = nowNanos &+ nackRetryNanos
            }
            break
        }
    }

    private mutating func nearestFutureSequence(
        to sequence: UInt16,
        in pending: [UInt16: BufferedPacket]
    ) -> UInt16? {
        nearestFutureScanCount &+= 1
        return pending.keys
            .filter {
                let distance = $0 &- sequence
                return distance != 0 && distance < 0x8000
            }
            .min { ($0 &- sequence) < ($1 &- sequence) }
    }

    /// Keep every band at the same pre-loss decode point while NACK has a
    /// chance to repair a sequence hole. When repair succeeds, the recovered
    /// stream is emitted first so its missing DON reaches the decoder before
    /// sibling pictures accumulated behind it. When loss is confirmed, the
    /// same ordering makes VideoStreamManager observe and gate the sequence
    /// jump before any held sibling-band picture can be decoded.
    private mutating func finalizeCompoundGapHold(_ input: Result) -> Result {
        let hasPendingGap = streams.values.contains { $0.gapDeadlineNanos != nil }
        // Normal media never pays for packet materialization or array copies.
        // The holding path is cold and exists only for an observed RTP hole.
        guard hasPendingGap || !compoundGapHeldPackets.isEmpty else { return input }

        var result = input
        let packets = result.packets
        result.released.removeAll(keepingCapacity: false)
        if hasPendingGap {
            compoundGapHeldPackets.append(contentsOf: packets)
            result.preorderedPackets = []
            return result
        }

        result.preorderedPackets = packets + compoundGapHeldPackets
        compoundGapHeldPackets.removeAll(keepingCapacity: true)
        return result
    }

    private struct RTPFrameBoundary {
        let timestamp: UInt32
        let marker: Bool
        let expectedPacketCount: Int?
        let sequenceNumber: UInt16?
    }

    /// Read only standard RTP fields. The full RTP parser remains in the
    /// rendering layer; loss accounting needs no HEVC payload bytes.
    private func frameBoundary(in packet: Data) -> RTPFrameBoundary? {
        guard packet.count >= 12 else { return nil }
        let base = packet.startIndex
        guard packet[base] >> 6 == 2 else { return nil }
        let timestamp = UInt32(packet[base + 4]) << 24
            | UInt32(packet[base + 5]) << 16
            | UInt32(packet[base + 6]) << 8
            | UInt32(packet[base + 7])
        let mediaControl = appleMediaRTPMediaControlInfo(packet)
        return RTPFrameBoundary(
            timestamp: timestamp,
            marker: packet[base + 1] & 0x80 != 0,
            expectedPacketCount: mediaControl?.totalPacketsPerFrame.map(Int.init),
            sequenceNumber: mediaControl?.frameSequenceNumber)
    }

    private func noteReleasedFramePacket(
        _ packet: Data,
        state: inout StreamState
    ) {
        guard let boundary = frameBoundary(in: packet) else { return }
        let changedFrame = state.activeFrameTimestamp != boundary.timestamp
            || (state.activeFrameSequenceNumber != nil
                && boundary.sequenceNumber != nil
                && state.activeFrameSequenceNumber != boundary.sequenceNumber)
        if changedFrame {
            state.activeFrameTimestamp = boundary.timestamp
            state.activeFrameReceivedPacketCount = 0
            state.activeFrameExpectedPacketCount = boundary.expectedPacketCount
            state.activeFrameSequenceNumber = boundary.sequenceNumber
        } else {
            state.activeFrameExpectedPacketCount = boundary.expectedPacketCount
                ?? state.activeFrameExpectedPacketCount
            state.activeFrameSequenceNumber = boundary.sequenceNumber
                ?? state.activeFrameSequenceNumber
        }
        state.activeFrameReceivedPacketCount += 1
        if boundary.marker {
            state.activeFrameTimestamp = nil
            state.activeFrameReceivedPacketCount = 0
            state.activeFrameExpectedPacketCount = nil
            state.activeFrameSequenceNumber = nil
        }
    }

    /// Use Apple's advertised packets-per-frame value when present. Standard
    /// RTP marker/timestamp accounting remains the fallback for peers that omit
    /// the version-2 frame extension.
    private func estimateDamagedFrame(
        state: StreamState,
        nearestSequence: UInt16,
        missingPacketCount: Int
    ) -> (timestamp: UInt32, packetCount: Int, sequenceNumber: UInt16?) {
        let nearestBoundary = state.pending[nearestSequence]
            .flatMap { frameBoundary(in: $0.data) }
        let timestamp = state.activeFrameTimestamp
            ?? nearestBoundary?.timestamp
            ?? 0
        let exactPacketCount = state.activeFrameExpectedPacketCount
            ?? nearestBoundary?.expectedPacketCount
        let frameSequenceNumber = state.activeFrameSequenceNumber
            ?? nearestBoundary?.sequenceNumber
        var received = state.activeFrameTimestamp == nil
            ? 0
            : state.activeFrameReceivedPacketCount
        var sequence = nearestSequence

        while let buffered = state.pending[sequence],
              let boundary = frameBoundary(in: buffered.data) {
            if received > 0, boundary.timestamp != timestamp { break }
            if let frameSequenceNumber,
               let sequenceNumber = boundary.sequenceNumber,
               sequenceNumber != frameSequenceNumber { break }
            received += 1
            if boundary.marker { break }
            sequence &+= 1
        }
        return (
            timestamp,
            max(missingPacketCount, exactPacketCount ?? (received + missingPacketCount)),
            frameSequenceNumber)
    }

    private static func signedDistance(_ sequence: UInt16, from reference: UInt16) -> Int {
        let distance = Int(sequence &- reference)
        return distance < 0x8000 ? distance : distance - 0x1_0000
    }

}
