import Foundation
import XCTest
import RFBRendering
import RFBTransport
@testable import rootshellVNC

final class AppleMediaPlaybackSynchronizerTests: XCTestCase {
    func testSeparateRTPEpochsResolveOntoSharedSenderClock() {
        let synchronizer = AppleMediaPlaybackSynchronizer()
        let ntp: UInt64 = 0xe000_0000_8000_0000
        let audioSSRC: UInt32 = 0x1111_1111
        let videoSSRC: UInt32 = 0x2222_2222

        synchronizer.noteSenderClock(AppleMediaSenderClockMapping(
            remoteSSRC: audioSSRC,
            ntpTimestamp: ntp,
            rtpTimestamp: 1_000))
        synchronizer.noteSenderClock(AppleMediaSenderClockMapping(
            remoteSSRC: videoSSRC,
            ntpTimestamp: ntp,
            rtpTimestamp: 90_000))

        // Both RTP values below represent 10 ms after the shared NTP point,
        // despite using unrelated epochs and 48/24 kHz clock rates.
        synchronizer.noteAudioPlayback(AppleRemoteAudioPlaybackTiming(
            ssrc: audioSSRC,
            rtpTimestamp: 1_480,
            hostTimeNanos: 1_000_000_000))
        let videoPacket = makeRTPPacket(
            timestamp: 90_240,
            ssrc: videoSSRC)

        XCTAssertEqual(
            synchronizer.videoDelayNanos(for: videoPacket, nowNanos: 900_000_000),
            92_000_000)
        // Far-behind audio caps the wait; audio gone for over a second ends it.
        XCTAssertEqual(
            synchronizer.videoDelayNanos(for: videoPacket, nowNanos: 1),
            AppleMediaPlaybackSynchronizer.maximumSynchronizedDelayNanos)
        XCTAssertEqual(
            synchronizer.videoDelayNanos(for: videoPacket, nowNanos: 2_100_000_000),
            0)
    }

    func testVideoDoesNotWaitUntilBothSenderClocksAndAudioTimingExist() {
        let synchronizer = AppleMediaPlaybackSynchronizer()
        let packet = makeRTPPacket(timestamp: 1, ssrc: 2)

        XCTAssertEqual(synchronizer.videoDelayNanos(for: packet, nowNanos: 1), 0)
    }

    private func makeRTPPacket(timestamp: UInt32, ssrc: UInt32) -> Data {
        Data([
            0x80, 100, 0, 1,
            UInt8(timestamp >> 24),
            UInt8((timestamp >> 16) & 0xff),
            UInt8((timestamp >> 8) & 0xff),
            UInt8(timestamp & 0xff),
            UInt8(ssrc >> 24),
            UInt8((ssrc >> 16) & 0xff),
            UInt8((ssrc >> 8) & 0xff),
            UInt8(ssrc & 0xff),
        ])
    }
}
