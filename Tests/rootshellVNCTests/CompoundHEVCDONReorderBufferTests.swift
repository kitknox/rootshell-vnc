import Foundation
import XCTest
@testable import RFBRendering

final class CompoundHEVCDONReorderBufferTests: XCTestCase {
    func testStartupRestoresFourInterleavedBandsToGlobalDONOrder() {
        var reorder = CompoundHEVCDONReorderBuffer()
        XCTAssertTrue(reorder.enqueue([nal(102)]).orderedAccessUnits.isEmpty)
        XCTAssertTrue(reorder.enqueue([nal(100)]).orderedAccessUnits.isEmpty)
        XCTAssertTrue(reorder.enqueue([nal(103)]).orderedAccessUnits.isEmpty)

        let result = reorder.enqueue([nal(101)])
        XCTAssertEqual(result.startupOrder, [100, 101, 102, 103])
        XCTAssertEqual(result.orderedAccessUnits.map(\.don), [100, 101, 102, 103])
        XCTAssertTrue(result.skippedGaps.isEmpty)
    }

    func testPostStartupFuturePictureWaitsForMissingDON() {
        var reorder = startedBuffer(at: 100)
        XCTAssertTrue(reorder.enqueue([nal(105)]).orderedAccessUnits.isEmpty)

        let result = reorder.enqueue([nal(104)])
        XCTAssertEqual(result.orderedAccessUnits.map(\.don), [104, 105])
        XCTAssertTrue(result.skippedGaps.isEmpty)
    }

    func testStartupDoesNotAdvanceAfterFourDONsFromOnlyTwoBands() {
        var reorder = CompoundHEVCDONReorderBuffer(expectedSourceCount: 4)
        XCTAssertTrue(reorder.enqueue([nal(66, ssrc: 0)]).orderedAccessUnits.isEmpty)
        XCTAssertTrue(reorder.enqueue([nal(67, ssrc: 1)]).orderedAccessUnits.isEmpty)
        XCTAssertTrue(reorder.enqueue([nal(70, ssrc: 0)]).orderedAccessUnits.isEmpty)
        XCTAssertTrue(reorder.enqueue([nal(71, ssrc: 1)]).orderedAccessUnits.isEmpty)
        XCTAssertTrue(reorder.enqueue([nal(68, ssrc: 2)]).orderedAccessUnits.isEmpty)

        let result = reorder.enqueue([nal(69, ssrc: 3)])
        XCTAssertEqual(result.startupOrder, [66, 67, 68, 69, 70, 71])
        XCTAssertEqual(result.orderedAccessUnits.map(\.don), [66, 67, 68, 69, 70, 71])
        XCTAssertTrue(result.skippedGaps.isEmpty)
    }

    func testStartupOrderingHandlesDONWraparound() {
        var reorder = CompoundHEVCDONReorderBuffer()
        _ = reorder.enqueue([nal(1)])
        _ = reorder.enqueue([nal(.max)])
        _ = reorder.enqueue([nal(2)])
        let result = reorder.enqueue([nal(0)])

        XCTAssertEqual(result.startupOrder, [.max, 0, 1, 2])
        XCTAssertEqual(result.orderedAccessUnits.map(\.don), [.max, 0, 1, 2])
    }

    func testBoundedMissingDONSkipsInsteadOfFreezing() {
        var reorder = startedBuffer(at: 100)
        var final = CompoundHEVCDONReorderBuffer.Result()
        for don in UInt16(105)...UInt16(116) {
            final = reorder.enqueue([nal(don)])
        }

        XCTAssertEqual(final.skippedGaps, [
            .init(missingDON: 104, nextDON: 105, bufferedFrameCount: 12),
        ])
        XCTAssertEqual(final.orderedAccessUnits.map(\.don), Array(UInt16(105)...UInt16(116)))
    }

    func testLatePictureIsIgnoredAfterTimelineAdvanced() {
        var reorder = startedBuffer(at: 100)
        XCTAssertTrue(reorder.enqueue([nal(102)]).orderedAccessUnits.isEmpty)
    }

    func testMultipleSlicesWithOneDONBecomeOneCompleteAccessUnit() {
        var reorder = startedBuffer(at: 100)
        let firstSlice = nal(104, ssrc: 0, endOfAccessUnit: false)
        XCTAssertTrue(reorder.enqueue([firstSlice]).orderedAccessUnits.isEmpty)

        let finalSlice = nal(104, ssrc: 0, endOfAccessUnit: true)
        let result = reorder.enqueue([finalSlice])
        XCTAssertEqual(result.orderedAccessUnits.count, 1)
        XCTAssertEqual(result.orderedAccessUnits.first?.don, 104)
        XCTAssertEqual(result.orderedAccessUnits.first?.nals, [firstSlice, finalSlice])
    }

    func testSourceCountChangeRestartsStartupCollection() {
        var reorder = startedBuffer(at: 100)
        reorder.reconfigureExpectedSourceCount(2)

        XCTAssertTrue(reorder.enqueue([nal(104, ssrc: 0)]).orderedAccessUnits.isEmpty)
        XCTAssertTrue(reorder.enqueue([nal(105, ssrc: 1)]).orderedAccessUnits.isEmpty)
        XCTAssertTrue(reorder.enqueue([nal(106, ssrc: 0)]).orderedAccessUnits.isEmpty)
        let result = reorder.enqueue([nal(107, ssrc: 1)])

        XCTAssertEqual(result.startupOrder, [104, 105, 106, 107])
        XCTAssertEqual(result.orderedAccessUnits.map(\.don), [104, 105, 106, 107])
    }

    func testVideoGeometryUpdatesWithoutRestartingStream() {
        let manager = VideoStreamManager()
        manager.startStream(streamID: 1, width: 1920, height: 1080) { _, _ in }
        let generation = manager.decodeProgress.streamGeneration

        manager.updateFrameGeometry(width: 2560, height: 1440)

        XCTAssertEqual(manager.frameGeometrySnapshot.width, 2560)
        XCTAssertEqual(manager.frameGeometrySnapshot.height, 1440)
        XCTAssertEqual(manager.decodeProgress.streamGeneration, generation)
        XCTAssertTrue(manager.isStreamActive)
        manager.stopStream()
    }

    func testMediaReconfigurationKeepsStreamAndConnectionGenerationAlive() {
        let manager = VideoStreamManager()
        manager.startStream(streamID: 7, width: 2560, height: 1600) { _, _ in }
        let connectionGeneration = manager.decodeProgress.streamGeneration

        manager.prepareForStreamReconfiguration(mediaGeneration: 2)
        manager.prepareForStreamReconfiguration(mediaGeneration: 1)

        XCTAssertTrue(manager.isStreamActive)
        XCTAssertEqual(manager.currentMediaGeneration, 2)
        XCTAssertEqual(manager.decodeProgress.streamGeneration, connectionGeneration)
        XCTAssertEqual(manager.frameGeometrySnapshot.width, 2560)
        XCTAssertEqual(manager.frameGeometrySnapshot.height, 1600)
        XCTAssertEqual(manager.frameGeometrySnapshot.codedBandHeight, 0)
        manager.stopStream()
    }

    func testOneTileCodecGeometryUpdatesDesktopAfterMediaRenegotiation() {
        let manager = VideoStreamManager()
        manager.startStream(
            streamID: 7,
            width: 2976,
            height: 1860,
            usesDecodingOrderNumbers: false
        ) { _, _ in }
        let connectionGeneration = manager.decodeProgress.streamGeneration
        manager.prepareForStreamReconfiguration(mediaGeneration: 2)

        let update = manager.acceptCodedDimensions(width: 3808, height: 2380)

        XCTAssertEqual(
            update,
            VideoFrameGeometry(
                width: 3808,
                height: 2380,
                mediaGeneration: 2,
                streamGeneration: connectionGeneration))
        XCTAssertEqual(manager.frameGeometrySnapshot.width, 3808)
        XCTAssertEqual(manager.frameGeometrySnapshot.height, 2380)
        XCTAssertEqual(manager.frameGeometrySnapshot.codedBandHeight, 2380)
        XCTAssertEqual(manager.decodeProgress.streamGeneration, connectionGeneration)
        manager.stopStream()
    }

    func testExpectedBandCountRoundsUpPartialFinalBand() {
        XCTAssertEqual(
            VideoStreamManager.expectedBandCount(
                fullFrameHeight: 1200,
                codedBandHeight: 512),
            3)
    }

    func testNegotiatedTileCountCapsBandInferenceFromPhysicalDesktopUnion() {
        let manager = VideoStreamManager()
        manager.startStream(
            streamID: 1,
            width: 5120,
            height: 4844,
            usesDecodingOrderNumbers: true,
            numberOfTiles: 2
        ) { _, _ in }

        _ = manager.acceptCodedDimensions(width: 5120, height: 1440)

        XCTAssertEqual(manager.frameGeometrySnapshot.expectedBandCount, 2)
        manager.stopStream()
    }

    private func startedBuffer(at firstDON: UInt16) -> CompoundHEVCDONReorderBuffer {
        var reorder = CompoundHEVCDONReorderBuffer()
        _ = reorder.enqueue([nal(firstDON &+ 2)])
        _ = reorder.enqueue([nal(firstDON)])
        _ = reorder.enqueue([nal(firstDON &+ 3)])
        let result = reorder.enqueue([nal(firstDON &+ 1)])
        XCTAssertEqual(result.orderedAccessUnits.map(\.don), [firstDON, firstDON &+ 1, firstDON &+ 2, firstDON &+ 3])
        return reorder
    }

    private func nal(
        _ don: UInt16,
        ssrc: UInt32? = nil,
        endOfAccessUnit: Bool = true
    ) -> RTPDemuxer.DemuxedNAL {
        RTPDemuxer.DemuxedNAL(
            don: don,
            ssrc: ssrc ?? UInt32(don & 3),
            nal: Data([0x02, 0x01]),
            endOfAccessUnit: endOfAccessUnit)
    }
}
