import Foundation
import XCTest
@testable import rootshellVNC

final class OrderedMediaPacketCoalescerTests: XCTestCase {
    private final class LockedBatches: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [[Data]] = []

        func append(_ batch: [Data]) {
            lock.lock()
            storage.append(batch)
            lock.unlock()
        }

        var snapshot: [[Data]] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    func testBurstUsesOneQueueBlockAndPreservesPacketOrder() {
        let queue = DispatchQueue(label: "OrderedMediaPacketCoalescerTests")
        queue.suspend()
        let consumed = expectation(description: "consumed burst")
        let batches = LockedBatches()
        let coalescer = OrderedMediaPacketCoalescer(queue: queue) { batch in
            batches.append(batch)
            consumed.fulfill()
        }

        let packets = (0..<2_048).map { value -> Data in
            var bigEndian = UInt32(value).bigEndian
            return Data(bytes: &bigEndian, count: MemoryLayout<UInt32>.size)
        }
        for packet in packets {
            coalescer.enqueue(packet)
        }
        queue.resume()

        wait(for: [consumed], timeout: 2)
        let snapshot = batches.snapshot
        XCTAssertEqual(snapshot.count, 1)
        XCTAssertEqual(snapshot.first, packets)
    }

    func testDelayHoldsCompressedVideoWithoutReorderingIt() {
        let queue = DispatchQueue(label: "OrderedMediaPacketCoalescerTests.delay")
        let consumed = expectation(description: "consumed delayed burst")
        let batches = LockedBatches()
        let started = DispatchTime.now().uptimeNanoseconds
        let coalescer = OrderedMediaPacketCoalescer(
            queue: queue,
            delayNanos: { _ in 80_000_000 }
        ) { batch in
            batches.append(batch)
            consumed.fulfill()
        }

        let packets = (0..<32).map { Data([UInt8($0)]) }
        for packet in packets {
            coalescer.enqueue(packet)
        }

        wait(for: [consumed], timeout: 1)
        let elapsed = DispatchTime.now().uptimeNanoseconds &- started
        XCTAssertGreaterThanOrEqual(elapsed, 70_000_000)
        XCTAssertEqual(batches.snapshot.flatMap { $0 }, packets)
    }

    /// Resolving a batch's delays parses RTP and takes the playback
    /// synchronizer's lock. Packets already due must stay drainable meanwhile.
    func testBatchEnqueueResolvesDelaysWithoutBlockingDrain() {
        let queue = DispatchQueue(label: "OrderedMediaPacketCoalescerTests.batchDelay")
        let first = Data([1])
        let second = Data([2])
        let delayEntered = DispatchSemaphore(value: 0)
        let releaseDelay = DispatchSemaphore(value: 0)
        let firstConsumed = expectation(description: "due packet drained during delay resolution")
        let secondConsumed = expectation(description: "second batch drained")
        let batches = LockedBatches()
        let coalescer = OrderedMediaPacketCoalescer(
            queue: queue,
            delayNanos: { packet in
                if packet == second {
                    delayEntered.signal()
                    releaseDelay.wait()
                }
                return 0
            }
        ) { batch in
            batches.append(batch)
            if batch == [first] {
                firstConsumed.fulfill()
            } else {
                secondConsumed.fulfill()
            }
        }

        // Queue the first packet's drain, then hold a second batch inside its
        // delay computation before letting that drain run.
        queue.suspend()
        coalescer.enqueue(contentsOf: [first])
        DispatchQueue.global(qos: .userInitiated).async {
            coalescer.enqueue(contentsOf: [second])
        }
        XCTAssertEqual(delayEntered.wait(timeout: .now() + 10), .success)
        queue.resume()

        wait(for: [firstConsumed], timeout: 10)
        releaseDelay.signal()
        wait(for: [secondConsumed], timeout: 10)
        XCTAssertEqual(batches.snapshot, [[first], [second]])
    }

    func testDiscardPendingInvalidatesRetiredGenerationTimer() {
        let queue = DispatchQueue(label: "OrderedMediaPacketCoalescerTests.generation")
        let consumed = expectation(description: "consumed current generation")
        let batches = LockedBatches()
        let coalescer = OrderedMediaPacketCoalescer(
            queue: queue,
            delayNanos: { _ in 40_000_000 }
        ) { batch in
            batches.append(batch)
            consumed.fulfill()
        }

        coalescer.enqueue(Data([0xaa]))
        coalescer.discardPending()
        coalescer.enqueue(Data([0xbb]))

        wait(for: [consumed], timeout: 1)
        usleep(30_000)
        XCTAssertEqual(batches.snapshot.flatMap { $0 }, [Data([0xbb])])
    }
}
