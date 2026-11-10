import XCTest
import Foundation
@testable import RFBRendering

/// Timing regression tests for the remote-audio playback path. These drive the
/// real AVSampleBufferRenderSynchronizer with wall-clock pacing, so they take a
/// few seconds; the failure they guard against — a stale render-clock reading
/// right after a timeline restart locking the player into an endless
/// underrun/rebuffer loop — only exists against the real asynchronous clock.
final class AppleRemoteAudioPlayerTests: XCTestCase {

    private var sequence: UInt16 = 0
    private var timestamp: UInt32 = 0

    /// Apple's mode-8 stream sends one complete codec access unit per RTP
    /// payload; a small opaque payload stands in for compressed audio.
    private func makeAudioPacket() -> Data {
        var packet = Data()
        packet.append(0x80) // V=2, no padding/extension/CSRC
        packet.append(AppleRemoteAudioRTPDepacketizer.payloadType)
        packet.append(contentsOf: [UInt8(sequence >> 8), UInt8(sequence & 0xff)])
        for shift in stride(from: 24, through: 0, by: -8) {
            packet.append(UInt8((timestamp >> UInt32(shift)) & 0xff))
        }
        packet.append(contentsOf: [0x4d, 0xe0, 0xa1, 0xfe]) // ssrc
        packet.append(contentsOf: [0x01, 0x40, 0x20, 0x06]) // access unit
        sequence &+= 1
        timestamp &+= UInt32(AppleRemoteAudioRTPDepacketizer.framesPerAccessUnit)
        return packet
    }

    private func sendBurst(_ count: Int, to player: AppleRemoteAudioPlayer) {
        for _ in 0..<count {
            player.enqueueRTPPacket(makeAudioPacket())
        }
    }

    /// Sends 70 ms bursts of seven 10 ms packets, mimicking the batched Wi-Fi
    /// delivery seen on the wire. Seven is deliberately coprime to the 10-AU
    /// preroll so playback starts mid-burst, with the next packet processed
    /// microseconds later — the window in which a restarted synchronizer still
    /// reports its previous timeline. The sleep is a shade under the burst's
    /// media duration: usleep overshoot must not starve the renderer, or
    /// drift would add underruns of its own to the assertions below.
    private func streamBursts(_ burstCount: Int, to player: AppleRemoteAudioPlayer) {
        for _ in 0..<burstCount {
            sendBurst(7, to: player)
            usleep(63_000)
        }
    }

    /// A media renegotiation calls reset() mid-stream. The restarted timeline
    /// must come back up without declaring underruns: the synchronizer applies
    /// setRate(_:time:) asynchronously, and reading the previous timeline's
    /// clock against fresh zero-based timestamps used to flush and rebuffer on
    /// the first packet after every restart, forever.
    func testRenegotiationRestartDoesNotStormUnderruns() throws {
        let player = try AppleRemoteAudioPlayer()
        defer { player.stop() }

        streamBursts(20, to: player)
        XCTAssertEqual(player.diagnosticsSnapshot().underrunCount, 0)

        player.reset()

        streamBursts(40, to: player)

        let diagnostics = player.diagnosticsSnapshot()
        XCTAssertEqual(
            diagnostics.underrunCount, 0,
            "restart after renegotiation must not misread the render clock as an underrun")
        XCTAssertTrue(diagnostics.isRunning)
        XCTAssertFalse(diagnostics.rendererFailed)
    }

    /// A genuine delivery stall is at most one underrun: the audio-driven
    /// render clock may simply pause at the media edge (zero), or a late
    /// reading re-anchors the timeline in place (one). Either way playback
    /// must still be running afterwards and the event must not cascade the
    /// way the old flush/preroll recovery did (five underruns and a stopped
    /// synchronizer from a single 600 ms stall).
    func testDeliveryStallDoesNotCascadeOrStopPlayback() throws {
        let player = try AppleRemoteAudioPlayer()
        defer { player.stop() }

        streamBursts(20, to: player)

        // Stall well past the accumulated jitter cushion, then resume the
        // same RTP timeline as a burst, the way overtaken Wi-Fi audio arrives.
        usleep(600_000)

        streamBursts(20, to: player)

        let diagnostics = player.diagnosticsSnapshot()
        XCTAssertLessThanOrEqual(diagnostics.underrunCount, 1)
        XCTAssertTrue(diagnostics.isRunning)
        XCTAssertFalse(diagnostics.rendererFailed)
    }

    /// An underrun-inflated cushion must decay back to the 100 ms base after
    /// clean playback, so a transient Wi-Fi glitch cannot permanently leave
    /// audio a quarter second late on every later restart.
    func testInflatedCushionDecaysAfterCleanPlayback() throws {
        let player = try AppleRemoteAudioPlayer()
        defer { player.stop() }

        player.setPrerollTargetForTesting(
            AppleRemoteAudioPlayer.maximumPrerollAccessUnitTarget,
            decayIntervalNanos: 200_000_000)

        streamBursts(60, to: player) // ~4 s of clean 10 ms packets

        let diagnostics = player.diagnosticsSnapshot()
        XCTAssertTrue(diagnostics.isRunning)
        XCTAssertEqual(diagnostics.underrunCount, 0)
        XCTAssertEqual(
            diagnostics.prerollAccessUnitTarget,
            AppleRemoteAudioPlayer.basePrerollAccessUnitTarget,
            "clean playback must decay the cushion back to its base")
    }

    /// A lead far above what arrivals need drains by playing slightly fast,
    /// on the real synchronizer, without an underrun or a stopped renderer.
    func testExcessLeadDrainsThroughRateWithoutUnderruns() throws {
        let player = try AppleRemoteAudioPlayer()
        defer { player.stop() }

        player.setPrerollTargetForTesting(
            AppleRemoteAudioPlayer.maximumPrerollAccessUnitTarget)

        streamRealTime(seconds: 6.5, to: player) // four 1 s slack windows, then a drain

        let diagnostics = player.diagnosticsSnapshot()
        XCTAssertGreaterThanOrEqual(diagnostics.rateAdjustmentCount, 1)
        XCTAssertEqual(diagnostics.underrunCount, 0)
        XCTAssertEqual(diagnostics.backlogDropCount, 0)
        XCTAssertTrue(diagnostics.isRunning)
        XCTAssertFalse(diagnostics.rendererFailed)
    }

    /// Buffered audio that stays far ahead of playback for a full second is
    /// skipped, and playback resumes from the packets that follow it.
    func testBacklogBurstRestartsAtTheLiveEdge() throws {
        let player = try AppleRemoteAudioPlayer()
        defer { player.stop() }

        streamRealTime(seconds: 1, to: player)
        sendBurst(80, to: player) // 800 ms of audio at once
        streamRealTime(seconds: 3, to: player)

        let diagnostics = player.diagnosticsSnapshot()
        XCTAssertGreaterThanOrEqual(diagnostics.backlogDropCount, 1)
        XCTAssertTrue(diagnostics.isRunning)
        XCTAssertFalse(diagnostics.rendererFailed)
    }

    /// Sends 10 ms packets paced by the wall clock, so the lead neither
    /// grows nor shrinks on its own.
    private func streamRealTime(seconds: Double, to player: AppleRemoteAudioPlayer) {
        let start = DispatchTime.now().uptimeNanoseconds
        var sent: UInt64 = 0
        while true {
            let elapsed = DispatchTime.now().uptimeNanoseconds - start
            if Double(elapsed) >= seconds * 1_000_000_000 { return }
            while sent * 10_000_000 <= elapsed {
                player.enqueueRTPPacket(makeAudioPacket())
                sent += 1
            }
            usleep(2_000)
        }
    }
}
