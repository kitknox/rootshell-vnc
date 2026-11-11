import Foundation
import XCTest
@testable import RFBTransport

final class AppleMediaFeedbackTests: XCTestCase {
    func testCompoundRecoverySelectsLowestBaseSSRC() {
        XCTAssertEqual(
            appleMediaCompoundBaseSSRC([
                0x75b0_2a4e,
                0x75b0_2a4c,
                0x75b0_2a4f,
                0x75b0_2a4d,
            ]),
            0x75b0_2a4c)
        XCTAssertNil(appleMediaCompoundBaseSSRC([]))
    }

    func testFrameLossFeedbackWireLayoutMatchesPSFBAFBTypeSix() {
        let packet = appleMediaFrameLossPacket(
            senderSSRC: 0x1122_3344,
            mediaSSRC: 0x5566_7788,
            feedback: AppleMediaFrameLossFeedback(
                frameRTPTimestamp: 0x99aa_bbcc,
                frameSequenceNumber: 0xddee,
                framePacketCount: 0xf0,
                lostPacketCount: 0x0f))

        XCTAssertEqual(packet, Data([
            0x8f, 0xce, 0x00, 0x05,
            0x11, 0x22, 0x33, 0x44,
            0x55, 0x66, 0x77, 0x88,
            0x00, 0x00, 0x00, 0x06,
            0x99, 0xaa, 0xbb, 0xcc,
            0xdd, 0xee, 0xf0, 0x0f,
        ]))
    }

    func testFullIntraRequestMatchesRTCPFullIntraRequestWireLayout() {
        XCTAssertEqual(
            appleMediaFullIntraRequestPacket(
                senderSSRC: 0x1122_3344,
                mediaSSRC: 0x5566_7788,
                sequenceNumber: 9),
            Data([
                0x84, 0xce, 0x00, 0x04,
                0x11, 0x22, 0x33, 0x44,
                0x00, 0x00, 0x00, 0x00,
                0x55, 0x66, 0x77, 0x88,
                0x09, 0x00, 0x00, 0x00,
            ]))
    }

    func testLTRAcknowledgementMatchesNativeRTCPAPPWireLayout() {
        XCTAssertEqual(
            appleMediaLTRAcknowledgementPacket(
                senderSSRC: 0x1122_3344,
                rtpTimestamp: 0x5566_7788),
            Data([
                0x80, 0xcc, 0x00, 0x03,
                0x11, 0x22, 0x33, 0x44,
                0x00, 0x00, 0x00, 0x05,
                0x55, 0x66, 0x77, 0x88,
            ]))
    }

    func testReceiverReportCompoundAddsNativeEmptyCNAMESDES() {
        let sender: UInt32 = 0x1122_3344
        let rr = Data([
            0x81, 0xc9, 0x00, 0x07,
            0x11, 0x22, 0x33, 0x44,
        ] + Array(repeating: 0, count: 24))

        let compound = appleMediaReceiverReportCompound(
            receiverReport: rr,
            senderSSRC: sender)

        XCTAssertEqual(compound.count, 44)
        XCTAssertEqual(compound.prefix(32), rr)
        XCTAssertEqual(compound.suffix(12), Data([
            0x81, 0xca, 0x00, 0x02,
            0x11, 0x22, 0x33, 0x44,
            0x01, 0x00, 0x00, 0x00,
        ]))
    }

    func testSenderReportTimingRemainsScopedToItsRemoteSSRC() throws {
        let audioSSRC: UInt32 = 0x1122_3344
        let videoSSRC: UInt32 = 0x5566_7788
        let audioReport = Data([
            0x80, 0xc8, 0x00, 0x04,
            0x11, 0x22, 0x33, 0x44,
            0xaa, 0xbb, 0xcc, 0xdd,
            0xee, 0xff, 0x00, 0x01,
            0x00, 0x00, 0x00, 0x00,
        ])
        let videoReport = Data([
            0x80, 0xc8, 0x00, 0x04,
            0x55, 0x66, 0x77, 0x88,
            0x10, 0x20, 0x30, 0x40,
            0x50, 0x60, 0x70, 0x80,
            0x00, 0x00, 0x00, 0x00,
        ])
        let audioTiming = try XCTUnwrap(appleMediaSenderReportTiming(
            from: audioReport,
            arrivalNanos: 1_000_000_000))
        let videoTiming = try XCTUnwrap(appleMediaSenderReportTiming(
            from: videoReport,
            arrivalNanos: 2_000_000_000))
        let timings = [
            audioTiming.remoteSSRC: audioTiming,
            videoTiming.remoteSSRC: videoTiming,
        ]

        let audioReply = appleMediaReceiverReportTiming(
            for: audioSSRC,
            senderReports: timings,
            nowNanos: 2_500_000_000)
        let videoReply = appleMediaReceiverReportTiming(
            for: videoSSRC,
            senderReports: timings,
            nowNanos: 2_500_000_000)

        XCTAssertEqual(audioReply.lsr, 0xccdd_eeff)
        XCTAssertEqual(audioReply.dlsr, 98_304)
        XCTAssertEqual(audioTiming.ntpTimestamp, 0xaabb_ccdd_eeff_0001)
        XCTAssertEqual(audioTiming.rtpTimestamp, 0)
        XCTAssertEqual(videoReply.lsr, 0x3040_5060)
        XCTAssertEqual(videoReply.dlsr, 32_768)
        XCTAssertEqual(
            appleMediaReceiverReportTiming(
                for: 0x9999_9999,
                senderReports: timings,
                nowNanos: 2_500_000_000).lsr,
            0)
    }

    func testNativeScreenRateProfileIsTwentyToSixtyMegabits() {
        XCTAssertEqual(AppleMediaRateController.nativeScreenMinimumBitrateBps, 20_000_000)
        XCTAssertEqual(AppleMediaRateController.nativeScreenMaximumBitrateBps, 60_000_000)
    }

    func testBandwidthProfilesSelectTheMacsScreenModes() {
        XCTAssertEqual(AppleMediaBandwidthProfile.full.screenNegotiatorMode, 7)
        XCTAssertEqual(AppleMediaBandwidthProfile.full.minimumBitrateBps, 20_000_000)
        XCTAssertEqual(AppleMediaBandwidthProfile.full.maximumBitrateBps, 60_000_000)
        XCTAssertEqual(AppleMediaBandwidthProfile.constrained.screenNegotiatorMode, 5)
        XCTAssertEqual(AppleMediaBandwidthProfile.constrained.minimumBitrateBps, 333_000)
        XCTAssertEqual(AppleMediaBandwidthProfile.constrained.maximumBitrateBps, 6_000_000)
    }

    func testConstrainedRateControllerBacksOffToItsOwnFloor() {
        let profile = AppleMediaBandwidthProfile.constrained
        let controller = AppleMediaRateController(
            minTargetBps: profile.minimumBitrateBps,
            maxTargetBps: profile.maximumBitrateBps,
            initialTargetBps: 4_000_000)
        _ = controller.update(now: 0)
        XCTAssertEqual(controller.targetBitrateBps, 4_000_000)
        for step in 1...30 {
            let now = Double(step)
            controller.onConfirmedLoss(count: 1, now: now)
            _ = controller.update(now: now)
        }

        XCTAssertEqual(controller.targetBitrateBps, 333_000)
    }

    func testGenericNACKPacksContiguousAndSparseSequenceNumbers() {
        XCTAssertEqual(
            appleMediaGenericNACKEntries(missingSequences: [100, 101, 103, 117, 118]),
            [
                .init(packetID: 100, bitmask: 0x0005),
                .init(packetID: 117, bitmask: 0x0001),
            ])
    }

    func testGenericNACKPackingHandlesSequenceWraparound() {
        XCTAssertEqual(
            appleMediaGenericNACKEntries(missingSequences: [.max, 0, 2]),
            [.init(packetID: .max, bitmask: 0x0005)])
    }

    func testRCTLWireLayoutMatchesNegotiatedMediaFields() {
        let data = AppleMediaRCTLFeedback(
            receiveQueueTargetMilliseconds: 100,
            echoTimestamp: 0x1234,
            totalReceivedKBytes: 0x2345,
            audioBurstyLoss: 3,
            cumulativeAudioReceivedPacketCount: 0x456,
            queuingDelayMilliseconds: 0x5678,
            sendTimestampQ10: 0x9abc,
            owrdQ13: 0xdef0,
            videoBurstyLoss: 5,
            cumulativeVideoReceivedPacketCount: 0x234,
            bandwidthEstimateKbps: 0x3456
        ).serialized()

        XCTAssertEqual(data, Data([
            0x85, 0x05, 0x00, 0x04,
            0x12, 0x34, 0x23, 0x45,
            0x34, 0x56, 0x56, 0x78,
            0x9a, 0xbc, 0xde, 0xf0,
            0x52, 0x34, 0x34, 0x56,
        ]))
    }

    func testRCTLClampsPackedReceiveStatistics() {
        let data = AppleMediaRCTLFeedback(
            receiveQueueTargetMilliseconds: .max,
            echoTimestamp: 0,
            totalReceivedKBytes: .max,
            audioBurstyLoss: .max,
            cumulativeAudioReceivedPacketCount: .max,
            queuingDelayMilliseconds: 0,
            sendTimestampQ10: 0,
            owrdQ13: 0,
            videoBurstyLoss: .max,
            cumulativeVideoReceivedPacketCount: .max,
            bandwidthEstimateKbps: .max
        ).serialized()

        XCTAssertEqual(data[1], .max)
        XCTAssertEqual(data[8], .max)
        XCTAssertEqual(data[9], .max)
        XCTAssertEqual(data[16], 0xff)
        XCTAssertEqual(data[17], 0xff)
    }

    func testRCTLUsesNativeLowPrecisionStandardRTPTimestamp() {
        XCTAssertEqual(
            appleMediaRCTLLowPrecisionEchoTimestamp(0x1234_5678),
            0x3456)
    }

    func testRCTLPacketIsStandaloneRTCPAPPReport() {
        let feedback = AppleMediaRCTLFeedback(
            receiveQueueTargetMilliseconds: 100,
            echoTimestamp: 0,
            totalReceivedKBytes: 0,
            audioBurstyLoss: 0,
            cumulativeAudioReceivedPacketCount: 0,
            queuingDelayMilliseconds: 0,
            sendTimestampQ10: 1,
            owrdQ13: 0,
            videoBurstyLoss: 0,
            cumulativeVideoReceivedPacketCount: 0,
            bandwidthEstimateKbps: 60_000)
        let packet = appleMediaRCTLPacket(
            senderSSRC: 0x1234_5678,
            feedback: feedback)

        XCTAssertEqual(packet.count, 32)
        XCTAssertEqual(packet.prefix(12), Data([
            0x80, 0xcc, 0x00, 0x07,
            0x12, 0x34, 0x56, 0x78,
            0x52, 0x43, 0x54, 0x4c,
        ]))
        XCTAssertEqual(packet.suffix(20), feedback.serialized())
    }

    func testAppleMediaRTPFrameExtensionMatchesCapturedScreenPacket() {
        // Prefix of a decrypted HEVC interoperability fixture. The apparent
        // 0x9311 "profile" is media-control
        // version/status plus flags/LTR bits.
        let packet = Data([
            0x90, 0x64, 0x30, 0x9f, 0, 0, 0, 0,
            0x07, 0x0d, 0xfa, 0x0e,
            0x93, 0x11, 0x00, 0x01, 0x00, 0x3c, 0x77, 0xc0,
        ])

        XCTAssertEqual(
            appleMediaRTPMediaControlInfo(packet),
            AppleMediaRTPMediaControlInfo(
                version: 2,
                cameraStatus: 0x13,
                ltrBits: 1,
                ltrTimestamp: nil,
                totalPacketsPerFrame: 60,
                frameSequenceNumber: 0x77c0))
    }

    func testLTRFrameCompletionUsesApplePacketCountWithoutRTPMarker() {
        var tracker = AppleMediaLTRFrameCompletionTracker()
        let first = makeAppleMediaFramePacket(
            rtpSequence: 100,
            rtpTimestamp: 0x5566_7788,
            ssrc: 0x070d_fa0e,
            frameSequence: 0x77c0,
            totalPackets: 3,
            ltrBits: 1)
        let second = makeAppleMediaFramePacket(
            rtpSequence: 101,
            rtpTimestamp: 0x5566_7788,
            ssrc: 0x070d_fa0e,
            frameSequence: 0x77c0,
            totalPackets: 3,
            ltrBits: 1)
        let third = makeAppleMediaFramePacket(
            rtpSequence: 102,
            rtpTimestamp: 0x5566_7788,
            ssrc: 0x070d_fa0e,
            frameSequence: 0x77c0,
            totalPackets: 3,
            ltrBits: 1)

        XCTAssertEqual(first[1] & 0x80, 0)
        XCTAssertNil(tracker.insert(first))
        XCTAssertNil(tracker.insert(second))
        XCTAssertEqual(
            tracker.insert(third),
            AppleMediaLTRFrameAcknowledgement(
                ssrc: 0x070d_fa0e,
                rtpTimestamp: 0x5566_7788))
    }

    func testLTRFrameCompletionDoesNotCountDuplicatePackets() {
        var tracker = AppleMediaLTRFrameCompletionTracker()
        let first = makeAppleMediaFramePacket(
            rtpSequence: 100,
            frameSequence: 7,
            totalPackets: 2,
            ltrBits: 1)
        let second = makeAppleMediaFramePacket(
            rtpSequence: 101,
            frameSequence: 7,
            totalPackets: 2,
            ltrBits: 1)

        XCTAssertNil(tracker.insert(first))
        XCTAssertNil(tracker.insert(first))
        XCTAssertNotNil(tracker.insert(second))
        XCTAssertNil(tracker.insert(second))
    }

    func testNonLTRFrameIsNotAcknowledged() {
        var tracker = AppleMediaLTRFrameCompletionTracker()
        let packet = makeAppleMediaFramePacket(
            rtpSequence: 100,
            frameSequence: 7,
            totalPackets: 1,
            ltrBits: 0)

        XCTAssertNil(tracker.insert(packet))
    }

    func testAppleMediaRTPMediaControlParsesLTRTimestampAndFrameFields() {
        let packet = Data([
            0x90, 0x64, 0x30, 0x9f, 0, 0, 0, 0,
            0x07, 0x0d, 0xfa, 0x0e,
            0x80, 0xa3, 0x00, 0x02,
            0x78, 0x56, 0x34, 0x12,
            0x00, 0x2a, 0xbe, 0xef,
        ])

        XCTAssertEqual(
            appleMediaRTPMediaControlInfo(packet),
            AppleMediaRTPMediaControlInfo(
                version: 2,
                cameraStatus: 0,
                ltrBits: 0x0a,
                ltrTimestamp: 0x1234_5678,
                totalPacketsPerFrame: 42,
                frameSequenceNumber: 0xbeef))
    }

    func testAppleMediaRTPMediaControlRejectsTruncatedOptionalFields() {
        let packet = Data([
            0x90, 0x64, 0x30, 0x9f, 0, 0, 0, 0,
            0x07, 0x0d, 0xfa, 0x0e,
            0x80, 0x03, 0x00, 0x01,
            0x78, 0x56, 0x34, 0x12,
        ])
        XCTAssertNil(appleMediaRTPMediaControlInfo(packet))
    }

    private func makeAppleMediaFramePacket(
        rtpSequence: UInt16,
        rtpTimestamp: UInt32 = 0x0102_0304,
        ssrc: UInt32 = 0x1122_3344,
        frameSequence: UInt16,
        totalPackets: UInt16,
        ltrBits: UInt8
    ) -> Data {
        Data([
            0x90, 0x64,
            UInt8(rtpSequence >> 8), UInt8(rtpSequence & 0xff),
            UInt8(rtpTimestamp >> 24), UInt8((rtpTimestamp >> 16) & 0xff),
            UInt8((rtpTimestamp >> 8) & 0xff), UInt8(rtpTimestamp & 0xff),
            UInt8(ssrc >> 24), UInt8((ssrc >> 16) & 0xff),
            UInt8((ssrc >> 8) & 0xff), UInt8(ssrc & 0xff),
            0x93, ltrBits << 4 | 0x01, 0x00, 0x01,
            UInt8(totalPackets >> 8), UInt8(totalPackets & 0xff),
            UInt8(frameSequence >> 8), UInt8(frameSequence & 0xff),
        ])
    }

    func testRateControllerStartsAtAvailableCeilingAndHoldsWithoutLoss() {
        let controller = AppleMediaRateController(maxTargetBps: 60_000_000)
        XCTAssertEqual(controller.bandwidthEstimateBps, 60_000_000)
        XCTAssertEqual(controller.targetBitrateBps, 60_000_000)
        _ = controller.update(now: 0)

        for step in 0...10 {
            controller.onVideoPacket(
                ssrc: 1,
                rtpTimestamp: 0,
                bytes: 100_000,
                endOfFrame: true,
                now: Double(step) * 0.05)
        }
        _ = controller.update(now: 0.5)
        XCTAssertEqual(controller.bandwidthEstimateBps, 60_000_000)
        XCTAssertEqual(controller.targetBitrateBps, 60_000_000)

        _ = controller.update(now: 1.1)
        XCTAssertEqual(controller.bandwidthEstimateBps, 60_000_000)
        XCTAssertEqual(controller.targetBitrateBps, 60_000_000)
    }

    func testRateControllerCutsOnlyAfterConfirmedLoss() {
        let controller = AppleMediaRateController(maxTargetBps: 60_000_000)
        _ = controller.update(now: 0)
        controller.onConfirmedLoss(count: 1, now: 0.1)
        _ = controller.update(now: 0.1)

        XCTAssertEqual(controller.bandwidthEstimateBps, 45_000_000)
        XCTAssertEqual(controller.targetBitrateBps, 45_000_000)
        XCTAssertEqual(controller.owrdSeconds, 0)
    }

    func testRepeatedLossNeverDropsBelowNativeScreenMinimum() {
        let controller = AppleMediaRateController(maxTargetBps: 40_000_000)
        _ = controller.update(now: 0)
        for step in 1...8 {
            let now = Double(step)
            controller.onConfirmedLoss(count: 1, now: now)
            _ = controller.update(now: now)
        }

        XCTAssertEqual(
            controller.bandwidthEstimateBps,
            UInt32(AppleMediaRateController.nativeScreenMinimumBitrateBps))
        XCTAssertEqual(
            controller.targetBitrateBps,
            UInt32(AppleMediaRateController.nativeScreenMinimumBitrateBps))
    }

    func testSparseScreenDoesNotTurnObservedTrafficIntoCapacityCeiling() {
        let controller = AppleMediaRateController(maxTargetBps: 100_000_000)
        _ = controller.update(now: 0)
        controller.onVideoPacket(
            ssrc: 1,
            rtpTimestamp: 0,
            bytes: 1_000,
            now: 0.05)
        controller.onConfirmedLoss(count: 1, now: 0.1)
        _ = controller.update(now: 0.1)

        XCTAssertEqual(controller.bandwidthEstimateBps, 75_000_000)
        XCTAssertEqual(controller.targetBitrateBps, 75_000_000)
    }

    func testRateControllerDoesNotRampDuringIdleCooldown() {
        let controller = AppleMediaRateController(maxTargetBps: 40_000_000)
        _ = controller.update(now: 0)
        controller.onConfirmedLoss(count: 1, now: 0.1)
        _ = controller.update(now: 0.1)
        XCTAssertEqual(controller.bandwidthEstimateBps, 30_000_000)

        _ = controller.update(now: 10)
        XCTAssertEqual(controller.bandwidthEstimateBps, 30_000_000)
    }

    func testRateControllerProbesGraduallyOnlyUnderUtilization() {
        let controller = AppleMediaRateController(maxTargetBps: 40_000_000)
        _ = controller.update(now: 0)
        controller.onConfirmedLoss(count: 1, now: 0.1)
        _ = controller.update(now: 0.1)

        for step in 0..<5 {
            controller.onVideoPacket(
                ssrc: 1,
                rtpTimestamp: UInt32(step),
                bytes: 500_000,
                now: 5.1 + Double(step) * 0.1)
        }
        _ = controller.update(now: 5.6)
        XCTAssertEqual(controller.bandwidthEstimateBps, 33_000_000)
    }

    func testRateControllerDoesNotBackOffForLosslessFrameBurstQueueing() {
        let controller = AppleMediaRateController(maxTargetBps: 40_000_000)
        _ = controller.update(now: 0)
        for interval in 1...20 {
            let now = Double(interval) * 0.1
            controller.onVideoPacket(
                ssrc: 1,
                rtpTimestamp: UInt32(interval),
                bytes: 250_000,
                queueDelaySeconds: 0.044,
                now: now)
            _ = controller.update(now: now)
        }

        XCTAssertEqual(controller.bandwidthEstimateBps, 40_000_000)
        XCTAssertEqual(controller.peakQueueDelaySeconds, 0.044, accuracy: 0.000_001)
    }

    func testRateControllerOWRDTracksPositiveReceiveClockDrift() {
        let controller = AppleMediaRateController(maxTargetBps: 60_000_000)
        let startTimestamp: UInt32 = 1_000
        let startTime = 100.0
        XCTAssertEqual(AppleMediaRateController.screenRTPClockRate, 24_000)

        // Native 60-fps screen traffic advances by 400 ticks on its 24 kHz
        // RTP clock. The first timestamp primes the feedback-only receiver;
        // the next two establish equal-rate send and receive clocks.
        for frame in 0..<3 {
            controller.onVideoPacket(
                ssrc: 1,
                rtpTimestamp: startTimestamp + UInt32(frame * 400),
                bytes: 1_200,
                now: startTime + Double(frame) / 60)
        }
        XCTAssertLessThan(controller.owrdSeconds, 0.001)

        // Add 20 ms of receiver-side delay. The native 10%/0.01% EMA pair
        // reports roughly 2 ms on the first delayed sample.
        controller.onVideoPacket(
            ssrc: 1,
            rtpTimestamp: startTimestamp + 1_200,
            bytes: 1_200,
            now: startTime + 3.0 / 60 + 0.020)
        XCTAssertGreaterThan(controller.owrdSeconds, 0.001)
        XCTAssertLessThan(controller.owrdSeconds, 0.003)
    }

    func testRateControllerOWRDIgnoresBackwardCompoundTimestamp() {
        let controller = AppleMediaRateController(maxTargetBps: 60_000_000)
        controller.onVideoPacket(
            ssrc: 1, rtpTimestamp: 10_000, bytes: 1_200, now: 100)
        controller.onVideoPacket(
            ssrc: 1, rtpTimestamp: 10_400, bytes: 1_200, now: 100.017)
        controller.onVideoPacket(
            ssrc: 1, rtpTimestamp: 10_800, bytes: 1_200, now: 100.034)
        let before = controller.owrdSeconds

        // Another compound SSRC can deliver the preceding frame after a
        // newer timestamp has already advanced the shared stream clock.
        controller.onVideoPacket(
            ssrc: 2, rtpTimestamp: 10_400, bytes: 1_200, now: 100.060)
        XCTAssertEqual(controller.owrdSeconds, before)
    }

    func testRateControllerResetsOWRDForNewMediaClockOrigin() {
        let controller = AppleMediaRateController(maxTargetBps: 60_000_000)
        for frame in 0..<4 {
            controller.onVideoPacket(
                ssrc: 1,
                rtpTimestamp: 1_000 + UInt32(frame * 400),
                bytes: 1_200,
                now: 100 + Double(frame) / 60 + (frame == 3 ? 0.020 : 0))
        }
        XCTAssertGreaterThan(controller.owrdSeconds, 0)

        controller.resetMediaGenerationMeasurements()
        XCTAssertEqual(controller.owrdSeconds, 0)

        // A completely unrelated new RTP origin must establish a fresh
        // baseline rather than producing a saturated delay sample.
        controller.onVideoPacket(
            ssrc: 2, rtpTimestamp: 0xf000_0000, bytes: 1_200, now: 200)
        controller.onVideoPacket(
            ssrc: 2, rtpTimestamp: 0xf000_0190, bytes: 1_200, now: 200.017)
        XCTAssertEqual(controller.owrdSeconds, 0)
    }

    func testRoutePriorCanProbeQuicklyToFullCapacityBeforeCongestion() {
        let controller = AppleMediaRateController(
            maxTargetBps: 40_000_000,
            initialTargetBps: 12_000_000)
        _ = controller.update(now: 0)

        for probe in 1...4 {
            let start = Double(probe) * 0.5
            for packet in 0..<5 {
                controller.onVideoPacket(
                    ssrc: 1,
                    rtpTimestamp: UInt32(probe * 10 + packet),
                    bytes: 500_000,
                    now: start - 0.4 + Double(packet) * 0.1)
            }
            _ = controller.update(now: start)
        }

        XCTAssertGreaterThan(controller.bandwidthEstimateBps, 35_000_000)
        XCTAssertLessThanOrEqual(controller.bandwidthEstimateBps, 40_000_000)
    }

    func testKeyframeRecoveryWaitsForOvershootAndQuietLossInterval() {
        let controller = AppleMediaRateController(
            maxTargetBps: 40_000_000,
            initialTargetBps: 8_000_000)
        _ = controller.update(now: 0)
        controller.onConfirmedLoss(count: 10, now: 0.1)
        _ = controller.update(now: 0.1)
        controller.onVideoPacket(
            ssrc: 1,
            rtpTimestamp: 1,
            bytes: 1_000_000,
            now: 0.2)

        XCTAssertFalse(controller.isReadyForKeyframeRecovery(now: 0.3))
        XCTAssertFalse(controller.isReadyForKeyframeRecovery(now: 0.8))
        XCTAssertTrue(controller.isReadyForKeyframeRecovery(now: 1.0))
    }

    func testRecoveryBackoffStepsCapacityDownWithoutDelayingReadiness() {
        let controller = AppleMediaRateController(maxTargetBps: 40_000_000)
        _ = controller.update(now: 0)
        controller.onConfirmedLoss(count: 1, now: 0.1)
        _ = controller.update(now: 0.1)
        XCTAssertEqual(controller.bandwidthEstimateBps, 30_000_000)

        XCTAssertTrue(controller.forceRecoveryBackoff(now: 0.5))
        XCTAssertEqual(controller.bandwidthEstimateBps, 22_500_000)
        XCTAssertEqual(controller.targetBitrateBps, 22_500_000)

        // The step-down must not refresh the congestion clock: readiness is
        // still measured from the loss at 0.1, not from the backoff at 0.5.
        XCTAssertTrue(controller.isReadyForKeyframeRecovery(now: 0.9))
    }

    func testRecoveryBackoffSharesTheLossBackoffRateLimit() {
        let controller = AppleMediaRateController(maxTargetBps: 40_000_000)
        _ = controller.update(now: 0)
        controller.onConfirmedLoss(count: 1, now: 0.1)
        _ = controller.update(now: 0.1)
        XCTAssertEqual(controller.bandwidthEstimateBps, 30_000_000)

        // Within one 0.25 s AIMD window the loss decrease and the recovery
        // decrease must not compound.
        XCTAssertFalse(controller.forceRecoveryBackoff(now: 0.2))
        XCTAssertEqual(controller.bandwidthEstimateBps, 30_000_000)
        XCTAssertTrue(controller.forceRecoveryBackoff(now: 0.4))
        XCTAssertEqual(controller.bandwidthEstimateBps, 22_500_000)
    }

    func testRepeatedRecoveryBackoffClampsAtRecoveryFloor() {
        let controller = AppleMediaRateController(maxTargetBps: 40_000_000)
        _ = controller.update(now: 0)
        for step in 1...8 {
            _ = controller.forceRecoveryBackoff(now: Double(step))
        }
        // Default recovery floor equals the native screen minimum; only an
        // explicit ROOTSHELL_VNC_RC_RECOVERY_MIN_KBPS may go below it.
        XCTAssertEqual(
            controller.bandwidthEstimateBps,
            UInt32(AppleMediaRateController.nativeScreenMinimumBitrateBps))
        XCTAssertEqual(controller.recoveryAttemptCount, 8)

        controller.noteRecoveryComplete()
        XCTAssertEqual(controller.recoveryAttemptCount, 0)
        XCTAssertEqual(
            controller.bandwidthEstimateBps,
            UInt32(AppleMediaRateController.nativeScreenMinimumBitrateBps))
    }

    func testGatedKeyframeReadinessUsesShortQuietInterval() {
        let controller = AppleMediaRateController(maxTargetBps: 40_000_000)
        _ = controller.update(now: 0)
        controller.onConfirmedLoss(count: 1, now: 0.1)
        _ = controller.update(now: 0.1)

        // Gated: quiet interval shortens to 0.25 s after the last congestion.
        XCTAssertFalse(controller.isReadyForKeyframeRecovery(now: 0.3, displayGated: true))
        XCTAssertTrue(controller.isReadyForKeyframeRecovery(now: 0.36, displayGated: true))
        // Ungated keeps the conservative 0.75 s window.
        XCTAssertFalse(controller.isReadyForKeyframeRecovery(now: 0.36))
        XCTAssertTrue(controller.isReadyForKeyframeRecovery(now: 0.86))
    }

    func testGatedReadinessVetoedByLocalQueueDelayWithoutCapacityChange() {
        let controller = AppleMediaRateController(maxTargetBps: 40_000_000)
        _ = controller.update(now: 0)
        controller.onVideoPacket(
            ssrc: 1,
            rtpTimestamp: 1,
            bytes: 1_000,
            queueDelaySeconds: 0.08,
            now: 0.05)
        _ = controller.update(now: 0.1)

        // Local ingress backlog defers a gated IDR request but must never
        // reduce the advertised capacity (the anti-thrash contract).
        XCTAssertFalse(controller.isReadyForKeyframeRecovery(now: 0.2, displayGated: true))
        XCTAssertEqual(controller.bandwidthEstimateBps, 40_000_000)
        XCTAssertTrue(controller.isReadyForKeyframeRecovery(now: 0.2))

        // Once the backlog drains the gated request may proceed.
        _ = controller.update(now: 0.2)
        XCTAssertTrue(controller.isReadyForKeyframeRecovery(now: 0.3, displayGated: true))
    }
}
