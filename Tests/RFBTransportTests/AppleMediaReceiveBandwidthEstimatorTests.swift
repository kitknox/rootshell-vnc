import XCTest
@testable import RFBTransport

final class AppleMediaReceiveBandwidthEstimatorTests: XCTestCase {
    private func rows(_ vectors: String) -> [[Substring]] {
        vectors.split(separator: "\n").map {
            $0.split(separator: ",", omittingEmptySubsequences: false)
        }
    }

    private func assertMatchesNativeEstimator(
        _ vectors: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var estimator = AppleMediaReceiveBandwidthEstimator()
        for (index, row) in rows(vectors).enumerated() {
            estimator.calculate(
                time: Double(row[0])!,
                rtpTimestamp: UInt32(row[1])!,
                sizeBytes: Int(row[2])!,
                inTrain: true,
                endOfFrame: row[3] == "1")
            let expected = Double(row[4])!
            // Recorded arrival times carry nine decimals, so allow 1 ppm.
            XCTAssertEqual(
                estimator.estimateBps, expected,
                accuracy: max(1, expected * 1e-6),
                "row \(index)", file: file, line: line)
            XCTAssertEqual(
                estimator.state.rawValue, Int(row[5])!,
                "row \(index)", file: file, line: line)
        }
    }

    func testStepDownFollowsNativeDivergenceRules() {
        assertMatchesNativeEstimator(AppleMediaBandwidthEstimatorVectors.step100To20To25)
    }

    func testTimestampWrapReorderAndDuplicateMatchNative() {
        assertMatchesNativeEstimator(AppleMediaBandwidthEstimatorVectors.wrapReorderDuplicate)
    }

    func testProbingGateMatchesNativeRCTLValues() {
        var estimator = AppleMediaReceiveBandwidthEstimator()
        var checked = 0
        for (index, row) in rows(AppleMediaBandwidthEstimatorVectors.gated40To15).enumerated() {
            estimator.notePacket(
                arrivalSeconds: Double(row[0])!,
                rtpTimestamp: UInt32(row[1])!,
                sizeBytes: Int(row[2])!,
                marker: row[3] == "1",
                startsProbe: [2, 3, 6].contains(Int(row[4])!))
            guard let expected = Int(row[5]) else { continue }
            checked += 1
            // One 8 kbps packing step absorbs the recorded-time rounding.
            XCTAssertLessThanOrEqual(
                abs(Int(estimator.rctlKbps) - expected), 8, "row \(index)")
        }
        XCTAssertEqual(checked, 120)
    }

    func testEstimateIsCappedAndPackedWithStableBit() {
        var estimator = AppleMediaReceiveBandwidthEstimator()
        // Three 300 Mbps trains of 20 packets: the first sets the estimate,
        // the re-applied sample smooths it at the 60 Mbps cap.
        for frame in 0..<3 {
            let start = 10.0 + Double(frame) / 60
            for packet in 0..<20 {
                estimator.calculate(
                    time: start + Double(packet) * 1_200 * 8 / 300_000_000,
                    rtpTimestamp: 1_000 + UInt32(frame) * 400,
                    sizeBytes: 1_200,
                    inTrain: true,
                    endOfFrame: packet == 19)
            }
        }
        XCTAssertEqual(estimator.estimateBps, 60_000_000, accuracy: 1)
        XCTAssertEqual(estimator.rctlKbps, 60_001)
    }

    func testProbeStartsOnFragmentationUnitsAndVCLNALUnits() {
        XCTAssertTrue(AppleMediaReceiveBandwidthEstimator.startsProbe(payloadFirstByte: 49 << 1))
        XCTAssertTrue(AppleMediaReceiveBandwidthEstimator.startsProbe(payloadFirstByte: 1 << 1))
        XCTAssertFalse(AppleMediaReceiveBandwidthEstimator.startsProbe(payloadFirstByte: 48 << 1))
        XCTAssertFalse(AppleMediaReceiveBandwidthEstimator.startsProbe(payloadFirstByte: 33 << 1))
    }

    func testPayloadOffsetSkipsHeaderExtension() {
        var packet = Data([0x90, 100, 0, 1, 0, 0, 0, 1, 0, 0, 0, 2])
        packet.append(contentsOf: [0xbe, 0xde, 0x00, 0x01, 1, 2, 3, 4])
        packet.append(contentsOf: [49 << 1, 1, 0x80])
        XCTAssertEqual(
            AppleMediaReceiveBandwidthEstimator.rtpPayloadFirstByte(packet),
            49 << 1)
    }
}
