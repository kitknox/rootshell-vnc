import XCTest
import Foundation
import CoreVideo
import CoreImage
#if canImport(AppKit)
import AppKit
#endif
import RFBProtocol
@testable import RFBTransport
@testable import RFBRendering
@testable import rootshellVNC

/// Live probe for High Performance on slow links: optional downlink
/// bottleneck in front of the UDP media, per-second receive rate, decoded
/// frame rate, loss and our advertised bandwidth, plus periodic PNGs.
///
///   VNC_TEST_HOST=... VNC_TEST_USERNAME=... VNC_TEST_PASSWORD='...' \
///   VNC_PROBE_CONSTRAINED=1 VNC_PROBE_DOWNLINK_SCHEDULE=0:20000,20:4000 \
///   swift test --filter LiveConstrainedMediaProbeTests
///
/// Optional: VNC_PROBE_LOGIN=1 (type the password at the lock screen),
/// VNC_PROBE_SECONDS=40, VNC_PROBE_QUEUE_MS=150, VNC_PROBE_DELAY_MS=0,
/// ROOTSHELL_VNC_FRAME_OUT_DIR=... with VNC_PROBE_DUMP_EVERY=5.
final class LiveConstrainedMediaProbeTests: XCTestCase {

    func testConstrainedHighPerformanceProbe() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["VNC_TEST_HOST"], !host.isEmpty,
              let pass = env["VNC_TEST_PASSWORD"], !pass.isEmpty else {
            throw XCTSkip("Set VNC_TEST_HOST and VNC_TEST_PASSWORD")
        }
        let user = env["VNC_TEST_USERNAME"] ?? ""
        let port = UInt16(env["VNC_TEST_PORT"] ?? "5900") ?? 5900
        let seconds = Int(env["VNC_PROBE_SECONDS"] ?? "40") ?? 40
        let dumpEvery = Int(env["VNC_PROBE_DUMP_EVERY"] ?? "5") ?? 5
        let outDir = env["ROOTSHELL_VNC_FRAME_OUT_DIR"]
        if let outDir {
            try? FileManager.default.createDirectory(
                atPath: outDir, withIntermediateDirectories: true)
        }
        let schedule = Self.parseSchedule(env["VNC_PROBE_DOWNLINK_SCHEDULE"])
        let queueMS = Int(env["VNC_PROBE_QUEUE_MS"] ?? "150") ?? 150
        let delayMS = Int(env["VNC_PROBE_DELAY_MS"] ?? "0") ?? 0
        let shaper = schedule.first.map {
            LiveDatagramShaper(configuration: .init(
                downlinkBitsPerSecond: $0.kbps * 1_000,
                queueMilliseconds: queueMS,
                oneWayDelayMilliseconds: delayMS))
        }

        let hp: [Encoding] = [
            .appleH264, .appleMultiVariantScreenshare, .zlib, .zrle,
            .encryptionInfo, .serverDisplayInfo, .mediaStreamOffer, .mediaStreamAnswer,
        ]
        let session = TransportSession(
            host: host, port: port, password: pass, username: user,
            preferredEncodings: hp,
            appleMediaBandwidthProfile: env["VNC_PROBE_CONSTRAINED"] == "1"
                ? .constrained : .full,
            datagramProvider: shaper?.provider)
        let manager = VideoStreamManager()
        let probe = ProbeState()

        // Unlike the app's escalating recovery, ask at most once a second.
        manager.onLossDetected = { [weak session] ssrc in
            guard probe.shouldRequestKeyframe(), let session else { return }
            probe.note("loss ssrc=\(ssrc.map { String($0 & 0xffff) } ?? "nil"); keyframe")
            Task { await session.requestVideoKeyframe(ssrc: ssrc) }
        }

        let eventTask = Task {
            for await event in session.events {
                switch event {
                case .mediaStreamOffer(let offer):
                    guard !probe.streamStarted else { continue }
                    probe.streamStarted = true
                    let tiles = await session.currentAppleMediaTilesPerFrame
                    probe.note("stream \(offer.streamID) tiles=\(tiles)")
                    manager.startStream(
                        streamID: offer.streamID,
                        width: 2976, height: 1860,
                        usesDecodingOrderNumbers: tiles > 1,
                        numberOfTiles: tiles
                    ) { pixelBuffer, ssrc in
                        probe.recordFrame(ssrc: ssrc, pixelBuffer: pixelBuffer)
                    }
                    await session.setAppleMediaRTPSink { packet in
                        probe.recordPacket(bytes: packet.count)
                        _ = manager.feedRTPData(packet)
                    }
                case .displayInfo(let display):
                    manager.updateFrameGeometry(
                        width: Int(display.width), height: Int(display.height))
                case .appleMediaUnavailable(let reason):
                    probe.note("MEDIA UNAVAILABLE: \(reason)")
                case .appleMediaRTPPacket, .framebufferUpdate, .udpDatagram,
                     .appleMediaControlRecord, .appleDisplayLayout:
                    break
                default:
                    break
                }
            }
        }

        await session.setAppleMediaGenerationSink { generation, tiles in
            probe.note("media generation \(generation) tiles=\(tiles)")
            manager.prepareForStreamReconfiguration(
                mediaGeneration: generation, numberOfTiles: tiles)
        }
        try await session.connect()
        probe.note("connected")

        if env["VNC_PROBE_LOGIN"] == "1" {
            // Wake the display, then type exactly what the app's "Type
            // Password" sends: focus click, select-all + delete, keysyms.
            try await Task.sleep(for: .seconds(2))
            try? await session.sendPointerEvent(buttonMask: 0, x: 1488, y: 930)
            try? await session.sendPointerEvent(buttonMask: 1, x: 1488, y: 930)
            try? await session.sendPointerEvent(buttonMask: 0, x: 1488, y: 930)
            try await Task.sleep(for: .seconds(3))
            probe.note("typing password at the lock screen")
            let events = VNCSession.loginPasswordFocusInputEvents(x: 1488, y: 930)
                + VNCSession.loginPasswordInputEvents(password: pass)
            for event in events {
                switch event {
                case .key(let downFlag, let keysym):
                    try? await session.sendKeyEvent(downFlag: downFlag, key: keysym)
                case .pointer(let buttonMask, let x, let y):
                    try? await session.sendPointerEvent(buttonMask: buttonMask, x: x, y: y)
                case .pause(let nanoseconds):
                    try await Task.sleep(for: .nanoseconds(Int(nanoseconds)))
                default:
                    break
                }
            }
        }

        var lastFrames: [UInt32: Int] = [:]
        var lastBytes = 0
        var lastShaper = LiveDatagramShaper.Snapshot()
        var rateSamples: [Double] = []
        var fpsSamples: [Double] = []
        for tick in 1...seconds {
            if let step = schedule.last(where: { $0.second == tick }) {
                shaper?.update(.init(
                    downlinkBitsPerSecond: step.kbps * 1_000,
                    queueMilliseconds: queueMS,
                    oneWayDelayMilliseconds: delayMS))
                probe.note(">>> downlink \(step.kbps) kbps")
            }
            try await Task.sleep(for: .seconds(1))
            let frames = probe.frameCounts()
            let bytes = probe.byteTotal()
            let stats = await session.statisticsSnapshot()
            let shaped = shaper?.snapshot() ?? LiveDatagramShaper.Snapshot()
            let fps = frames.map { $0.value - lastFrames[$0.key, default: 0] }.max() ?? 0
            let mbps = Double(bytes - lastBytes) * 8 / 1_000_000
            rateSamples.append(mbps)
            fpsSamples.append(Double(fps))
            let loss = manager.lossStatsSnapshot
            probe.note(String(
                format: "t=%02d rx=%5.2fMbps fps=%2d bwe=%5.0fkbps drop=+%d maxQ=%3.0fms gaps=%d iraps=%d",
                tick, mbps, fps, stats.bandwidthEstimateKbps ?? 0,
                shaped.droppedPackets - lastShaper.droppedPackets,
                shaped.maxQueueMilliseconds,
                loss.gapsDetected, loss.irapsDecoded))
            lastFrames = frames
            lastBytes = bytes
            lastShaper = shaped
            if let outDir, dumpEvery > 0, tick % dumpEvery == 0 {
                probe.dumpLatestFrames(to: outDir, tag: String(format: "t%02d", tick))
            }
        }

        let average = rateSamples.reduce(0, +) / Double(max(1, rateSamples.count))
        let averageFPS = fpsSamples.reduce(0, +) / Double(max(1, fpsSamples.count))
        probe.note(String(
            format: "SUMMARY rx avg %.2f Mbps peak %.2f Mbps, decoded avg %.1f fps",
            average, rateSamples.max() ?? 0, averageFPS))
        eventTask.cancel()
        await session.disconnect()
        manager.stopStream()
        shaper?.stop()
    }

    /// The app's path end to end: a Low Bandwidth Match Client session at a size
    /// the Mac pads, then `sendLoginPassword()` at the lock screen. Watch the
    /// Mac's `CGSSessionScreenIsLocked` (ioreg) to see the unlock.
    ///   VNC_PROBE_VNCSESSION=1 [VNC_PROBE_BANDWIDTH=full] plus VNC_TEST_* vars.
    @MainActor
    func testLowBandwidthMatchClientSessionTypesPassword() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["VNC_PROBE_VNCSESSION"] == "1",
              let host = env["VNC_TEST_HOST"], !host.isEmpty,
              let pass = env["VNC_TEST_PASSWORD"], !pass.isEmpty else {
            throw XCTSkip("Set VNC_PROBE_VNCSESSION=1, VNC_TEST_HOST and VNC_TEST_PASSWORD")
        }
        VNCLogRelay.install(minimumLevel: .debug) { _, category, message in
            guard category == "Session" else { return }
            print("LOG \(Date()) \(message.prefix(220))")
        }
        defer { VNCLogRelay.install(sink: nil) }
        let session = VNCSession(configuration: VNCConfiguration(
            videoQualityMode: .adaptive,
            highPerformanceBandwidth: env["VNC_PROBE_BANDWIDTH"] == "full" ? .full : .constrained,
            displaySizingMode: .matchClient,
            reconnectionPolicy: VNCReconnectionPolicy(isEnabled: false, maximumAttempts: 0)))
        session.updateRemoteDisplaySize(
            viewSize: CGSize(width: 1512, height: 982),
            displayScale: 2)
        try await session.connect(credentials: VNCCredentials(
            host: host,
            port: UInt16(env["VNC_TEST_PORT"] ?? "5900") ?? 5900,
            password: pass,
            username: env["VNC_TEST_USERNAME"]))
        defer { session.disconnect() }

        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline, session.videoBandRenderer.frameCommitCount < 5 {
            try await Task.sleep(for: .milliseconds(200))
        }
        try await Task.sleep(for: .seconds(Int(env["VNC_PROBE_SEND_DELAY"] ?? "12") ?? 12))
        print("PROBE framebuffer=\(session.framebufferWidth)x\(session.framebufferHeight) "
            + "decoded=\(session.videoBandRenderer.renderedBandDimensions) "
            + "commits=\(session.videoBandRenderer.frameCommitCount) "
            + "canSend=\(session.canSendLoginPassword)")
        session.sendLoginPassword()
        print("PROBE password send requested at \(Date())")
        try await Task.sleep(for: .seconds(15))
        print("PROBE done at \(Date())")
    }

    private static func parseSchedule(_ spec: String?) -> [(second: Int, kbps: Int)] {
        guard let spec, !spec.isEmpty else { return [] }
        return spec.split(separator: ",").compactMap { item in
            let parts = item.split(separator: ":").compactMap { Int($0) }
            return parts.count == 2 ? (parts[0], parts[1]) : nil
        }.sorted { $0.second < $1.second }
    }

    private final class ProbeState: @unchecked Sendable {
        private let lock = NSLock()
        private var frames: [UInt32: Int] = [:]
        private var latest: [UInt32: CVPixelBuffer] = [:]
        private var bytes = 0
        private let started = DispatchTime.now().uptimeNanoseconds
        private let ciContext = CIContext()
        private var lastKeyframeRequest: UInt64 = 0
        var streamStarted = false

        func shouldRequestKeyframe() -> Bool {
            let now = DispatchTime.now().uptimeNanoseconds
            lock.lock()
            defer { lock.unlock() }
            guard now &- lastKeyframeRequest >= 1_000_000_000 else { return false }
            lastKeyframeRequest = now
            return true
        }

        func note(_ message: String) {
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9
            print(String(format: "PROBE %6.2f %@", elapsed, message))
        }

        func recordPacket(bytes count: Int) {
            lock.lock()
            bytes += count
            lock.unlock()
        }

        func recordFrame(ssrc: UInt32, pixelBuffer: CVPixelBuffer) {
            lock.lock()
            frames[ssrc, default: 0] += 1
            latest[ssrc] = pixelBuffer
            lock.unlock()
        }

        func frameCounts() -> [UInt32: Int] {
            lock.lock()
            defer { lock.unlock() }
            return frames
        }

        func byteTotal() -> Int {
            lock.lock()
            defer { lock.unlock() }
            return bytes
        }

        func dumpLatestFrames(to dir: String, tag: String) {
            let snapshot: [UInt32: CVPixelBuffer] = {
                lock.lock()
                defer { lock.unlock() }
                return latest
            }()
            #if canImport(AppKit)
            for (ssrc, pixelBuffer) in snapshot {
                let image = CIImage(cvPixelBuffer: pixelBuffer)
                guard let cgImage = ciContext.createCGImage(image, from: image.extent) else {
                    continue
                }
                let url = URL(fileURLWithPath: dir)
                    .appendingPathComponent("\(tag)_band\(ssrc & 0xffff).png")
                try? NSBitmapImageRep(cgImage: cgImage)
                    .representation(using: .png, properties: [:])?
                    .write(to: url)
            }
            #endif
        }
    }
}
