import XCTest
@testable import RFBRendering

final class AppleRemoteAudioLeadControllerTests: XCTestCase {
    private let ms: Int64 = 1_000_000
    private let packetNanos: UInt64 = 10_000_000

    /// Feeds one 10 ms arrival per call from `start`, returning the first
    /// adjustment and the time it was asked for.
    private func stream(
        _ controller: inout AppleRemoteAudioLeadController,
        slackNanos: Int64,
        from start: UInt64,
        seconds: Double
    ) -> (adjustment: AppleRemoteAudioLeadController.Adjustment, at: UInt64)? {
        let count = Int(seconds * 100)
        for index in 0..<count {
            let now = start + UInt64(index) * packetNanos
            if let adjustment = controller.noteArrival(slackNanos: slackNanos, nowNanos: now) {
                return (adjustment, now)
            }
        }
        return nil
    }

    func testExcessLeadDrainsOnlyOnceTheHorizonAgrees() throws {
        var controller = AppleRemoteAudioLeadController(rendererLeadNanos: 20 * ms)
        controller.restartTimeline(rendererLeadNanos: 20 * ms, nowNanos: 0)

        let result = try XCTUnwrap(
            stream(&controller, slackNanos: 100 * ms, from: 0, seconds: 6))
        XCTAssertGreaterThanOrEqual(result.at, 4_000_000_000)
        XCTAssertEqual(result.adjustment.rate, 1.04, accuracy: 0.0001)
        XCTAssertEqual(result.adjustment.leadChangeNanos, -65 * ms)
        XCTAssertEqual(
            Double(result.adjustment.durationNanos), 1_625_000_000, accuracy: 1_000)

        // Once drained, slack sitting at the floor is left alone.
        controller.finishAdjustment(nowNanos: result.at + result.adjustment.durationNanos)
        XCTAssertNil(stream(
            &controller,
            slackNanos: controller.floorNanos,
            from: result.at + result.adjustment.durationNanos,
            seconds: 10))
    }

    func testThinBucketRebuildsLeadAtOnce() throws {
        var controller = AppleRemoteAudioLeadController(rendererLeadNanos: 20 * ms)
        controller.restartTimeline(rendererLeadNanos: 20 * ms, nowNanos: 0)

        XCTAssertNil(controller.noteArrival(slackNanos: 30 * ms, nowNanos: 0))
        let result = try XCTUnwrap(
            stream(&controller, slackNanos: 100 * ms, from: packetNanos, seconds: 2))
        XCTAssertEqual(result.adjustment.rate, 0.96, accuracy: 0.0001)
        XCTAssertEqual(result.adjustment.leadChangeNanos, 5 * ms)
    }

    func testLateArrivalRebuildsMidDrainAndWidensHorizon() throws {
        var controller = AppleRemoteAudioLeadController(rendererLeadNanos: 20 * ms)
        controller.restartTimeline(rendererLeadNanos: 20 * ms, nowNanos: 0)
        let drain = try XCTUnwrap(
            stream(&controller, slackNanos: 100 * ms, from: 0, seconds: 6))
        XCTAssertLessThan(drain.adjustment.leadChangeNanos, 0)

        let rebuild = try XCTUnwrap(controller.noteArrival(
            slackNanos: 10 * ms,
            nowNanos: drain.at + packetNanos))
        XCTAssertEqual(rebuild.leadChangeNanos, 25 * ms)
        XCTAssertEqual(controller.horizonBuckets, 8)
        // Already rebuilding: a second late arrival changes nothing.
        XCTAssertNil(controller.noteArrival(
            slackNanos: 5 * ms,
            nowNanos: drain.at + 2 * packetNanos))
    }

    func testLeadFarAheadForAWholeBucketIsSkippedNotDrained() throws {
        var controller = AppleRemoteAudioLeadController(rendererLeadNanos: 20 * ms)
        controller.restartTimeline(rendererLeadNanos: 20 * ms, nowNanos: 0)

        let result = try XCTUnwrap(
            stream(&controller, slackNanos: 400 * ms, from: 0, seconds: 3))
        XCTAssertTrue(result.adjustment.skipsBacklog)
        XCTAssertLessThan(result.at, 1_100_000_000)
        XCTAssertFalse(controller.isAdjusting)

        // Clumped arrivals whose worst case is modest only drain.
        controller.restartTimeline(rendererLeadNanos: 20 * ms, nowNanos: 0)
        var first: AppleRemoteAudioLeadController.Adjustment?
        for index in 0..<600 where first == nil {
            first = controller.noteArrival(
                slackNanos: (index % 12 == 0 ? 150 : 450) * ms,
                nowNanos: UInt64(index) * packetNanos)
        }
        XCTAssertEqual(try XCTUnwrap(first).skipsBacklog, false)
    }

    func testUnderrunsWidenTheHorizonUntilPlaybackSettles() throws {
        var controller = AppleRemoteAudioLeadController(rendererLeadNanos: 20 * ms)
        controller.restartTimeline(rendererLeadNanos: 20 * ms, nowNanos: 0)
        controller.noteUnderrun(nowNanos: 0)
        controller.noteUnderrun(nowNanos: 0)
        XCTAssertEqual(controller.horizonBuckets, 16)

        // The drain now needs sixteen agreeing seconds instead of four.
        let result = try XCTUnwrap(
            stream(&controller, slackNanos: 100 * ms, from: 0, seconds: 30))
        XCTAssertGreaterThanOrEqual(result.at, 16_000_000_000)
        XCTAssertLessThan(result.at, 17_000_000_000)

        // A late-free minute halves it again.
        let settled = result.at + result.adjustment.durationNanos
        controller.finishAdjustment(nowNanos: settled)
        XCTAssertNil(stream(
            &controller,
            slackNanos: controller.floorNanos,
            from: settled,
            seconds: 50))
        XCTAssertEqual(controller.horizonBuckets, 8)
    }
}
