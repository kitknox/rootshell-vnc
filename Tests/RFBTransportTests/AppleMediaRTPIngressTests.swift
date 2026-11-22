import Foundation
import XCTest
@testable import RFBTransport

final class AppleMediaRTPIngressTests: XCTestCase {
    func testHandoffDrainsStartupPacketsInFIFOOrder() {
        let received = LockedPackets()
        var handoff = AppleMediaPacketHandoff(maximumPackets: 8, maximumBytes: 128)

        XCTAssertEqual(handoff.deliver(Data([1])), .buffered)
        XCTAssertEqual(handoff.deliver(Data([2])), .buffered)
        let result = handoff.installSink { packet, _ in received.append(packet) }
        XCTAssertEqual(result.packetCount, 2)
        XCTAssertEqual(result.byteCount, 2)
        XCTAssertFalse(result.overflowed)

        XCTAssertEqual(handoff.deliver(Data([3])), .delivered)
        XCTAssertEqual(received.values, [Data([1]), Data([2]), Data([3])])
    }

    func testHandoffOverflowPreservesOldestBootstrapPackets() {
        let received = LockedPackets()
        var handoff = AppleMediaPacketHandoff(maximumPackets: 2, maximumBytes: 2)

        XCTAssertEqual(handoff.deliver(Data([1])), .buffered)
        XCTAssertEqual(handoff.deliver(Data([2])), .buffered)
        XCTAssertEqual(handoff.deliver(Data([3])), .overflow)
        let result = handoff.installSink { packet, _ in received.append(packet) }

        XCTAssertTrue(result.overflowed)
        XCTAssertEqual(result.droppedPacketCount, 1)
        XCTAssertEqual(received.values, [Data([1]), Data([2])])
    }

    /// A repeated stream offer: the owner's sink for the previous stream is
    /// detached as the offer is published, and the new stream's first packets
    /// wait for the replacement sink instead of reaching the retired one.
    func testOfferScopedBatchSinkIsRetiredAndPacketsWaitForItsReplacement() {
        let previous = LockedPackets()
        let replacement = LockedPackets()
        var handoff = AppleMediaPacketHandoff(maximumPackets: 8, maximumBytes: 128)

        _ = handoff.installBatchSink(
            { packets in packets.forEach { previous.append($0.data) } },
            retiresOnStreamOffer: true)
        XCTAssertEqual(handoff.deliver(Data([1])), .delivered)

        XCTAssertTrue(handoff.retireOfferScopedSink())
        XCTAssertFalse(handoff.retireOfferScopedSink(), "Nothing is left to retire")
        XCTAssertEqual(handoff.deliver(Data([2])), .buffered)
        XCTAssertEqual(handoff.deliverBatch([(Data([3]), nil)]), .buffered)

        let drained = handoff.installBatchSink(
            { packets in packets.forEach { replacement.append($0.data) } },
            retiresOnStreamOffer: true)
        XCTAssertEqual(drained.packetCount, 2)
        XCTAssertEqual(handoff.deliver(Data([4])), .delivered)

        XCTAssertEqual(previous.values, [Data([1])])
        XCTAssertEqual(replacement.values, [Data([2]), Data([3]), Data([4])])
    }

    func testSinkNotScopedToAnOfferStaysAttachedAcrossOffers() {
        let received = LockedPackets()
        var handoff = AppleMediaPacketHandoff(maximumPackets: 8, maximumBytes: 128)

        _ = handoff.installBatchSink { packets in packets.forEach { received.append($0.data) } }
        XCTAssertFalse(handoff.retireOfferScopedSink())
        XCTAssertEqual(handoff.deliver(Data([1])), .delivered)

        _ = handoff.installSink { packet, _ in received.append(packet) }
        XCTAssertFalse(handoff.retireOfferScopedSink())
        XCTAssertEqual(handoff.deliver(Data([2])), .delivered)
        XCTAssertEqual(received.values, [Data([1]), Data([2])])
    }

    /// An overflow belongs to the buffering interval it happened in. It is
    /// reported once, to the sink that receives the truncated backlog, and not
    /// again to sinks installed after later intervals that lost nothing.
    func testOverflowIsReportedOnceToTheSinkThatDrainsIt() {
        var handoff = AppleMediaPacketHandoff(maximumPackets: 2, maximumBytes: 16)
        XCTAssertEqual(handoff.deliver(Data([1])), .buffered)
        XCTAssertEqual(handoff.deliver(Data([2])), .buffered)
        XCTAssertEqual(handoff.deliver(Data([3])), .overflow)

        // Detaching drains nothing and must not use up the report.
        let detached = handoff.installBatchSink(nil)
        XCTAssertFalse(detached.overflowed)
        XCTAssertEqual(detached.droppedPacketCount, 0)

        let first = handoff.installBatchSink({ _ in }, retiresOnStreamOffer: true)
        XCTAssertTrue(first.overflowed)
        XCTAssertEqual(first.droppedPacketCount, 1)
        XCTAssertEqual(first.packetCount, 2)

        // The next offer buffers within bounds.
        XCTAssertTrue(handoff.retireOfferScopedSink())
        XCTAssertEqual(handoff.deliver(Data([4])), .buffered)
        let second = handoff.installBatchSink({ _ in }, retiresOnStreamOffer: true)
        XCTAssertEqual(second.packetCount, 1)
        XCTAssertFalse(second.overflowed)
        XCTAssertEqual(second.droppedPacketCount, 0)
        XCTAssertFalse(handoff.overflowed)
    }

    func testHandoffPreservesDisplayRouteAcrossStartupDrain() {
        let received = LockedRoutedPackets()
        var handoff = AppleMediaPacketHandoff(maximumPackets: 8, maximumBytes: 128)

        XCTAssertEqual(
            handoff.deliver(Data([1]), displayIndex: 0),
            .buffered)
        XCTAssertEqual(
            handoff.deliver(Data([2]), displayIndex: 1),
            .buffered)
        _ = handoff.installSink { packet, displayIndex in
            received.append(packet, displayIndex: displayIndex)
        }

        XCTAssertEqual(received.values.map(\.0), [Data([1]), Data([2])])
        XCTAssertEqual(received.values.map(\.1), [0, 1])
    }

    func testStartupHoldRestoresPacketsThatArriveOutOfOrder() {
        var reorder = makeReorderBuffer()
        XCTAssertTrue(reorder.insert(packet: packet(11), ssrc: 1, sequence: 11, nowNanos: 0).packets.isEmpty)
        XCTAssertTrue(reorder.insert(packet: packet(10), ssrc: 1, sequence: 10, nowNanos: 1).packets.isEmpty)

        let result = reorder.flushExpired(nowNanos: 9)
        XCTAssertEqual(result.packets, [packet(10), packet(11)])
        XCTAssertTrue(result.gaps.isEmpty)
    }

    func testPostStartupReorderingDoesNotBecomeLoss() {
        var reorder = makeReorderBuffer()
        _ = reorder.insert(packet: packet(10), ssrc: 1, sequence: 10, nowNanos: 0)
        XCTAssertEqual(reorder.flushExpired(nowNanos: 8).packets, [packet(10)])

        XCTAssertTrue(reorder.insert(packet: packet(12), ssrc: 1, sequence: 12, nowNanos: 9).packets.isEmpty)
        let result = reorder.insert(packet: packet(11), ssrc: 1, sequence: 11, nowNanos: 10)
        XCTAssertEqual(result.packets, [packet(11), packet(12)])
        XCTAssertTrue(result.gaps.isEmpty)
        XCTAssertTrue(result.retransmissionRequests.isEmpty)
    }

    func testMissingPacketRequestsRetransmissionBeforeBecomingLoss() {
        var reorder = makeReorderBuffer()
        _ = reorder.insert(packet: packet(10), ssrc: 7, sequence: 10, nowNanos: 0)
        _ = reorder.flushExpired(nowNanos: 8)
        let initial = reorder.insert(packet: packet(12), ssrc: 7, sequence: 12, nowNanos: 9)
        XCTAssertEqual(initial.retransmissionRequests, [
            .init(ssrc: 7, missingSequences: [11]),
        ])

        XCTAssertTrue(reorder.flushExpired(nowNanos: 18).packets.isEmpty)
        XCTAssertEqual(reorder.flushExpired(nowNanos: 19).retransmissionRequests, [
            .init(ssrc: 7, missingSequences: [11]),
        ])
        let result = reorder.flushExpired(nowNanos: 39)
        XCTAssertEqual(result.packets, [packet(12)])
        XCTAssertEqual(result.gaps, [.init(ssrc: 7, missingPacketCount: 1)])
    }

    func testConfirmedGapReportsObservedRTPFrameTimestampAndPacketCount() {
        var reorder = makeReorderBuffer()
        let first = rtpPacket(
            sequence: 10,
            timestamp: 0x0102_0304,
            marker: false,
            payload: 1)
        let afterGap = rtpPacket(
            sequence: 12,
            timestamp: 0x0102_0304,
            marker: true,
            payload: 3)

        _ = reorder.insert(packet: first, ssrc: 7, sequence: 10, nowNanos: 0)
        XCTAssertEqual(reorder.flushExpired(nowNanos: 8).packets, [first])
        _ = reorder.insert(packet: afterGap, ssrc: 7, sequence: 12, nowNanos: 9)
        let result = reorder.flushExpired(nowNanos: 39)

        XCTAssertEqual(result.packets, [afterGap])
        XCTAssertEqual(result.gaps, [
            .init(
                ssrc: 7,
                missingPacketCount: 1,
                frameRTPTimestamp: 0x0102_0304,
                estimatedFramePacketCount: 3),
        ])
    }

    func testConfirmedGapUsesAdvertisedAppleFramePacketCount() {
        var reorder = makeReorderBuffer()
        let first = rtpPacketWithFrameExtension(
            sequence: 10,
            timestamp: 0x0102_0304,
            marker: false,
            totalPacketsPerFrame: 60,
            frameSequenceNumber: 0x77c0,
            payload: 1)
        let afterGap = rtpPacketWithFrameExtension(
            sequence: 12,
            timestamp: 0x0102_0304,
            marker: true,
            totalPacketsPerFrame: 60,
            frameSequenceNumber: 0x77c0,
            payload: 3)

        _ = reorder.insert(packet: first, ssrc: 7, sequence: 10, nowNanos: 0)
        XCTAssertEqual(reorder.flushExpired(nowNanos: 8).packets, [first])
        _ = reorder.insert(packet: afterGap, ssrc: 7, sequence: 12, nowNanos: 9)
        let result = reorder.flushExpired(nowNanos: 39)

        XCTAssertEqual(result.gaps, [
            .init(
                ssrc: 7,
                missingPacketCount: 1,
                frameRTPTimestamp: 0x0102_0304,
                estimatedFramePacketCount: 60,
                frameSequenceNumber: 0x77c0),
        ])
    }

    func testRetransmittedPacketClosesGapAndReleasesInOrder() {
        var reorder = makeReorderBuffer()
        _ = reorder.insert(packet: packet(10), ssrc: 7, sequence: 10, nowNanos: 0)
        _ = reorder.flushExpired(nowNanos: 8)
        _ = reorder.insert(packet: packet(12), ssrc: 7, sequence: 12, nowNanos: 9)

        let recovered = reorder.insert(
            packet: packet(11),
            ssrc: 7,
            sequence: 11,
            nowNanos: 12)
        XCTAssertEqual(recovered.packets, [packet(11), packet(12)])
        XCTAssertTrue(recovered.gaps.isEmpty)
        XCTAssertTrue(recovered.retransmissionRequests.isEmpty)
    }

    func testSiblingStreamWaitsBehindRecoverableCompoundGap() {
        var reorder = makeReorderBuffer()
        _ = reorder.insert(packet: packet(10), ssrc: 1, sequence: 10, nowNanos: 0)
        _ = reorder.insert(packet: packet(20), ssrc: 2, sequence: 20, nowNanos: 1)
        XCTAssertEqual(reorder.flushExpired(nowNanos: 9).packets, [packet(10), packet(20)])

        XCTAssertTrue(
            reorder.insert(packet: packet(12), ssrc: 1, sequence: 12, nowNanos: 10)
                .packets.isEmpty)
        XCTAssertTrue(
            reorder.insert(packet: packet(21), ssrc: 2, sequence: 21, nowNanos: 11)
                .packets.isEmpty,
            "a healthy sibling band must not advance the global HEVC timeline")

        let recovered = reorder.insert(
            packet: packet(11),
            ssrc: 1,
            sequence: 11,
            nowNanos: 12)
        XCTAssertEqual(
            recovered.packets,
            [packet(11), packet(12), packet(21)],
            "the repaired band must unblock its missing DON before held siblings")
        XCTAssertTrue(recovered.gaps.isEmpty)
    }

    func testConfirmedCompoundGapGatesBeforeHeldSiblingPackets() {
        var reorder = makeReorderBuffer()
        _ = reorder.insert(packet: packet(10), ssrc: 1, sequence: 10, nowNanos: 0)
        _ = reorder.insert(packet: packet(20), ssrc: 2, sequence: 20, nowNanos: 1)
        _ = reorder.flushExpired(nowNanos: 9)

        _ = reorder.insert(packet: packet(12), ssrc: 1, sequence: 12, nowNanos: 10)
        _ = reorder.insert(packet: packet(21), ssrc: 2, sequence: 21, nowNanos: 11)
        let confirmed = reorder.flushExpired(nowNanos: 40)

        XCTAssertEqual(confirmed.gaps, [.init(ssrc: 1, missingPacketCount: 1)])
        XCTAssertEqual(
            confirmed.packets,
            [packet(12), packet(21)],
            "the sequence jump must gate decoding before sibling packets are released")
    }

    func testSequenceWraparoundAndIndependentSSRCs() {
        var reorder = makeReorderBuffer()
        _ = reorder.insert(packet: packet(1), ssrc: 1, sequence: .max, nowNanos: 0)
        _ = reorder.insert(packet: packet(2), ssrc: 2, sequence: 40, nowNanos: 1)
        _ = reorder.insert(packet: packet(3), ssrc: 1, sequence: 0, nowNanos: 2)

        let result = reorder.flushExpired(nowNanos: 9)
        XCTAssertEqual(result.packets, [packet(1), packet(2), packet(3)])
        XCTAssertTrue(result.gaps.isEmpty)
    }

    func testKnownInterruptionAcceptsMoreThanHalfSequenceSpaceAsForwardGap() {
        var reorder = makeReorderBuffer()
        _ = reorder.insert(packet: packet(10), ssrc: 7, sequence: 10, nowNanos: 0)
        _ = reorder.flushExpired(nowNanos: 8)
        reorder.markMediaInterruption()

        let resumed = reorder.insert(
            packet: packet(40),
            ssrc: 7,
            sequence: 40_000,
            nowNanos: 9)

        XCTAssertEqual(resumed.packets, [packet(40)])
        XCTAssertEqual(resumed.gaps, [
            .init(ssrc: 7, missingPacketCount: 39_989),
        ])
    }

    func testLongMediaSilenceAcceptsLargeForwardGapWithoutLifecycleSignal() {
        var reorder = makeReorderBuffer()
        _ = reorder.insert(packet: packet(10), ssrc: 7, sequence: 10, nowNanos: 0)
        _ = reorder.flushExpired(nowNanos: 8)

        let resumed = reorder.insert(
            packet: packet(40),
            ssrc: 7,
            sequence: 40_000,
            nowNanos: 1_000_000_001)

        XCTAssertEqual(resumed.packets, [packet(40)])
        XCTAssertEqual(resumed.gaps.map(\.missingPacketCount), [39_989])
    }

    func testLargeBurstBehindOneHoleDoesNotRescanPendingPackets() {
        var reorder = AppleMediaRTPReorderBuffer(
            startupHoldNanos: 8,
            maximumGapWaitNanos: 1_000_000,
            nackRetryNanos: 100_000,
            maximumBufferedPacketsPerStream: 7_000)
        _ = reorder.insert(
            packet: numberedPacket(100),
            ssrc: 7,
            sequence: 100,
            nowNanos: 0)
        XCTAssertEqual(reorder.flushExpired(nowNanos: 8).packets, [numberedPacket(100)])
        let scansBeforeBurst = reorder.nearestFutureScanCount

        for sequence in UInt16(102)...UInt16(6_101) {
            let result = reorder.insert(
                packet: numberedPacket(sequence),
                ssrc: 7,
                sequence: sequence,
                nowNanos: 9)
            XCTAssertTrue(result.packets.isEmpty)
            XCTAssertTrue(result.gaps.isEmpty)
        }

        // One cached nearest-future sequence serves the whole burst. A scan
        // per packet is the quadratic regression that caused the 5K collapse.
        XCTAssertLessThanOrEqual(
            reorder.nearestFutureScanCount - scansBeforeBurst,
            2)

        let recovered = reorder.insert(
            packet: numberedPacket(101),
            ssrc: 7,
            sequence: 101,
            nowNanos: 10)
        XCTAssertEqual(recovered.packets.count, 6_001)
        XCTAssertEqual(recovered.packets.first, numberedPacket(101))
        XCTAssertEqual(recovered.packets.last, numberedPacket(6_101))
        XCTAssertTrue(recovered.gaps.isEmpty)
    }

    func testBoundedSequenceHistoryEvictsOldestWithoutLosingDuplicateDetection() {
        var history = BoundedRTPSequenceHistory(capacity: 3)
        XCTAssertTrue(history.insert(10))
        XCTAssertTrue(history.insert(11))
        XCTAssertFalse(history.insert(10))
        XCTAssertTrue(history.insert(12))
        XCTAssertTrue(history.insert(13))
        XCTAssertTrue(history.insert(10), "oldest sequence should be eligible after eviction")
        XCTAssertFalse(history.insert(13))
    }

    private func makeReorderBuffer() -> AppleMediaRTPReorderBuffer {
        AppleMediaRTPReorderBuffer(
            startupHoldNanos: 8,
            maximumGapWaitNanos: 30,
            nackRetryNanos: 10,
            maximumBufferedPacketsPerStream: 64)
    }

    private func packet(_ value: UInt8) -> Data { Data([value]) }

    private func numberedPacket(_ value: UInt16) -> Data {
        Data([UInt8(value >> 8), UInt8(value & 0xff)])
    }

    private func rtpPacket(
        sequence: UInt16,
        timestamp: UInt32,
        marker: Bool,
        payload: UInt8
    ) -> Data {
        Data([
            0x80,
            (marker ? 0x80 : 0x00) | 100,
            UInt8(sequence >> 8), UInt8(sequence & 0xff),
            UInt8((timestamp >> 24) & 0xff),
            UInt8((timestamp >> 16) & 0xff),
            UInt8((timestamp >> 8) & 0xff),
            UInt8(timestamp & 0xff),
            0x00, 0x00, 0x00, 0x07,
            payload,
        ])
    }

    private func rtpPacketWithFrameExtension(
        sequence: UInt16,
        timestamp: UInt32,
        marker: Bool,
        totalPacketsPerFrame: UInt16,
        frameSequenceNumber: UInt16,
        payload: UInt8
    ) -> Data {
        Data([
            0x90,
            (marker ? 0x80 : 0x00) | 100,
            UInt8(sequence >> 8), UInt8(sequence & 0xff),
            UInt8((timestamp >> 24) & 0xff),
            UInt8((timestamp >> 16) & 0xff),
            UInt8((timestamp >> 8) & 0xff),
            UInt8(timestamp & 0xff),
            0x00, 0x00, 0x00, 0x07,
            0x80, 0x01, 0x00, 0x01,
            UInt8(totalPacketsPerFrame >> 8),
            UInt8(totalPacketsPerFrame & 0xff),
            UInt8(frameSequenceNumber >> 8),
            UInt8(frameSequenceNumber & 0xff),
            payload,
        ])
    }
}

private final class LockedPackets: @unchecked Sendable {
    private let lock = NSLock()
    private var packets: [Data] = []

    func append(_ packet: Data) {
        lock.lock()
        packets.append(packet)
        lock.unlock()
    }

    var values: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return packets
    }
}

private final class LockedRoutedPackets: @unchecked Sendable {
    private let lock = NSLock()
    private var packets: [(Data, Int?)] = []

    func append(_ packet: Data, displayIndex: Int?) {
        lock.lock()
        packets.append((packet, displayIndex))
        lock.unlock()
    }

    var values: [(Data, Int?)] {
        lock.lock()
        defer { lock.unlock() }
        return packets
    }
}
