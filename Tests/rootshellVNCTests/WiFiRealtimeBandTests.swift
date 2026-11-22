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

/// Connects to a live server over the network and runs the REAL-TIME media
/// pipeline exactly like the app (transport → RTP sink → VideoStreamManager →
/// HEVCDecoder), then reports per-band frame counts and detects "green" frames
/// (decoder concealment output with no valid reference). This reproduces the
/// connect-time green garbage that offline decode of a full capture cannot.
///
///   VNC_TEST_HOST=192.0.2.10 VNC_TEST_USERNAME=test-user VNC_TEST_PASSWORD='...' \
///   swift test --filter WiFiRealtimeBandTests
final class WiFiRealtimeBandTests: XCTestCase {

    @MainActor
    func testMatchClientRetinaSurvivesArbitraryLiveResizes() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["VNC_TEST_HOST"], !host.isEmpty,
              let pass = env["VNC_TEST_PASSWORD"], !pass.isEmpty else {
            throw XCTSkip("Set VNC_TEST_HOST and VNC_TEST_PASSWORD")
        }
        let credentials = VNCCredentials(
            host: host,
            port: UInt16(env["VNC_TEST_PORT"] ?? "5900") ?? 5900,
            password: pass,
            username: env["VNC_TEST_USERNAME"])
        let session = VNCSession(configuration: VNCConfiguration(
            videoQualityMode: .adaptive,
            displaySizingMode: .matchClient,
            enableRemoteAudio: false))
        let viewSizes = [
            CGSize(width: 1197, height: 837),
            CGSize(width: 1283, height: 779),
            CGSize(width: 1024, height: 1366),
            // Exact wide Retina geometry from the GUI session that eventually
            // overflowed the per-datagram actor handoff.
            CGSize(width: 2768, height: 696),
        ]

        session.updateRemoteDisplaySize(viewSize: viewSizes[0], displayScale: 2)
        try await session.connect(credentials: credentials)
        defer { session.disconnect() }

        try await waitForRenderedBands(
            session,
            expectedSize: try XCTUnwrap(
                RemoteDisplaySize.matching(viewSize: viewSizes[0])),
            expectedBandCount: expectedBandCount(for: viewSizes[0]),
            afterCommit: 0,
            timeoutSeconds: 15)
        XCTAssertTrue(session.isHighPerformanceMode)
        XCTAssertEqual(
            session.videoBandRenderer.renderedBandCount,
            expectedBandCount(for: viewSizes[0]))
        try await assertContinuesAtomicRendering(
            session,
            expectedBandCount: expectedBandCount(for: viewSizes[0]))

        for viewSize in viewSizes.dropFirst() {
            let priorCommit = session.videoBandRenderer.frameCommitCount
            let priorGeneration = session.videoBandRenderer.streamGenerationCount
            session.updateRemoteDisplaySize(viewSize: viewSize, displayScale: 2)
            try await waitForRenderedBands(
                session,
                expectedSize: try XCTUnwrap(
                    RemoteDisplaySize.matching(viewSize: viewSize)),
                expectedBandCount: expectedBandCount(for: viewSize),
                afterCommit: priorCommit,
                afterGeneration: priorGeneration,
                timeoutSeconds: 15)
            XCTAssertEqual(
                session.videoBandRenderer.renderedBandCount,
                expectedBandCount(for: viewSize),
                "Match Client resize to \(viewSize) must render its negotiated Retina tiles")
            try await assertContinuesAtomicRendering(
                session,
                expectedBandCount: expectedBandCount(for: viewSize))
        }

        // Opt-in soak at the exact >4K-axis geometry. Check progress throughout
        // the hold so an initial clean frame followed by a frozen/corrupt tile
        // cannot pass merely because the final counters are non-zero.
        let wideHoldSeconds = Double(env["VNC_TEST_WIDE_HOLD_SECONDS"] ?? "0") ?? 0
        let wideHoldDeadline = Date().addingTimeInterval(wideHoldSeconds)
        while Date() < wideHoldDeadline {
            let priorCommit = session.videoBandRenderer.frameCommitCount
            try await Task.sleep(for: .seconds(min(
                5,
                max(0.1, wideHoldDeadline.timeIntervalSinceNow))))
            XCTAssertGreaterThan(
                session.videoBandRenderer.frameCommitCount,
                priorCommit,
                "Wide Retina multi-tile rendering froze during the soak")
            XCTAssertEqual(session.videoBandRenderer.renderedBandCount, 2)
            XCTAssertEqual(session.videoBandRenderer.partialCommitCount, 0)
        }

        // Reproduce a real window drag: each update lives longer than the UI
        // debounce, but arrives before the preceding AVC generation is ready.
        // The transport must send the first command, coalesce the middle one,
        // and apply only the final size after the first generation is live.
        let dragSizes = [
            CGSize(width: 1872, height: 1048),
            CGSize(width: 1856, height: 872),
            CGSize(width: 1912, height: 1144),
        ]
        let generationBeforeDrag = session.videoBandRenderer.streamGenerationCount
        let commitBeforeDrag = session.videoBandRenderer.frameCommitCount
        for size in dragSizes {
            session.updateRemoteDisplaySize(viewSize: size, displayScale: 2)
            try await Task.sleep(for: .milliseconds(250))
        }
        let finalDragSize = try XCTUnwrap(RemoteDisplaySize.matching(
            viewSize: try XCTUnwrap(dragSizes.last)))
        try await waitForRenderedBands(
            session,
            expectedSize: finalDragSize,
            expectedBandCount: expectedBandCount(for: try XCTUnwrap(dragSizes.last)),
            afterCommit: commitBeforeDrag,
            afterGeneration: generationBeforeDrag,
            timeoutSeconds: 20)
        XCTAssertLessThanOrEqual(
            session.videoBandRenderer.streamGenerationCount - generationBeforeDrag,
            2,
            "A resize burst must coalesce instead of starting one media generation per size")
        try await assertContinuesAtomicRendering(
            session,
            expectedBandCount: expectedBandCount(for: try XCTUnwrap(dragSizes.last)))
    }

    func testRealtimeBandHealthOverNetwork() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["VNC_TEST_HOST"], !host.isEmpty,
              let pass = env["VNC_TEST_PASSWORD"], !pass.isEmpty else {
            throw XCTSkip("Set VNC_TEST_HOST and VNC_TEST_PASSWORD")
        }
        let user = env["VNC_TEST_USERNAME"] ?? ""
        let port = UInt16(env["VNC_TEST_PORT"] ?? "5900") ?? 5900

        let hp: [Encoding] = [
            .appleH264, .appleMultiVariantScreenshare, .zlib, .zrle,
            .encryptionInfo, .serverDisplayInfo, .mediaStreamOffer, .mediaStreamAnswer,
        ]
        let session = TransportSession(host: host, port: port, password: pass, username: user, preferredEncodings: hp)
        let manager = VideoStreamManager()
        let stats = BandStats()

        if env["VNC_TEST_MATCH_CLIENT"] == "1" {
            _ = try await session.requestRemoteDisplaySize(
                pixelWidth: 2400,
                pixelHeight: 1680,
                pointWidth: 1200,
                pointHeight: 840)
        }

        // Optionally dump live-decoded frames over time to see drift accumulate.
        let frameOutDir = env["ROOTSHELL_VNC_FRAME_OUT_DIR"]
        if let d = frameOutDir { try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true) }
        let ciContext = CIContext()
        let frameCounter = BandStats.Counter()

        let eventTask = Task {
            for await event in session.events {
                if env["VNC_TEST_MATCH_CLIENT"] == "1" {
                    switch event {
                    case .appleMediaRTPPacket, .udpDatagram, .framebufferUpdate:
                        break
                    default:
                        print("MATCH CLIENT EVENT: \(event)")
                    }
                }
                if case .mediaStreamOffer = event {
                    manager.startStream(streamID: 1, width: 2976, height: 1860) { pixelBuffer, ssrc in
                        stats.record(ssrc: ssrc, green: isGreen(pixelBuffer))
                        // Save one frame per SSRC every ~2s of frames so we can
                        // compare early vs late (live drift).
                        if let dir = frameOutDir {
                            let n = frameCounter.next()
                            if n % 96 == 0, n / 96 < 20 {
                                let ci = CIImage(cvPixelBuffer: pixelBuffer)
                                let url = URL(fileURLWithPath: dir).appendingPathComponent("live_\(n)_ssrc\(ssrc).png")
                                #if canImport(AppKit)
                                if let cg = ciContext.createCGImage(ci, from: ci.extent) {
                                    let rep = NSBitmapImageRep(cgImage: cg)
                                    try? rep.representation(using: .png, properties: [:])?.write(to: url)
                                }
                                #endif
                            }
                        }
                    }
                    await session.setAppleMediaRTPSink { packet in
                        _ = manager.feedRTPData(packet)
                    }
                }
            }
        }

        try await session.connect()
        let waitSeconds = Double(env["VNC_TEST_WAIT_SECONDS"] ?? "8") ?? 8
        try await Task.sleep(for: .seconds(waitSeconds))
        eventTask.cancel()
        await session.disconnect()
        manager.stopStream()
        try await Task.sleep(for: .seconds(0.3))

        let snapshot = stats.report()
        let progress = manager.decodeProgress
        print(
            "decode submissions=\(progress.submittedFrameCount) "
                + "outputs=\(progress.decoderOutputCount) "
                + "videoSources=\(await session.videoSourceCount) "
                + "loss=\(manager.lossStatsSnapshot)")
        XCTAssertGreaterThan(
            snapshot.totalFrames,
            0,
            "The live Adaptive pipeline must decode at least one video frame")
    }

    @MainActor
    private func waitForRenderedBands(
        _ session: VNCSession,
        expectedSize: RemoteDisplaySize,
        expectedBandCount: Int,
        afterCommit: UInt64,
        afterGeneration: UInt64? = nil,
        timeoutSeconds: Double
    ) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if session.videoBandRenderer.frameCommitCount > afterCommit,
               afterGeneration.map({
                   session.videoBandRenderer.streamGenerationCount > $0
               }) ?? true,
               session.videoBandRenderer.renderedBandCount == expectedBandCount,
               session.framebufferWidth == Int(expectedSize.pixelWidth),
               session.framebufferHeight == Int(expectedSize.pixelHeight),
               session.videoBandRenderer.renderedBandDimensions.allSatisfy({
                   $0.width == Int(expectedSize.pixelWidth)
               }) {
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        let renderer = session.videoBandRenderer
        let framebuffer = "\(session.framebufferWidth)x\(session.framebufferHeight)"
        let commits = "commits=\(renderer.frameCommitCount)"
        let bands = "bands=\(renderer.renderedBandCount)"
        let generations = "generations=\(renderer.streamGenerationCount)"
        let media = "media=\(session.liveMediaDebugSnapshot)"
        let dimensions = "dims=\(renderer.renderedBandDimensions)"
        let details = [
            commits, bands, generations, media,
            "framebuffer=\(framebuffer)", dimensions,
        ].joined(separator: " ")
        XCTFail("Timed out waiting for Match Client tiles; \(details)")
    }

    @MainActor
    private func assertContinuesAtomicRendering(
        _ session: VNCSession,
        expectedBandCount: Int
    ) async throws {
        let priorCommit = session.videoBandRenderer.frameCommitCount
        try await Task.sleep(for: .seconds(1))
        XCTAssertGreaterThan(
            session.videoBandRenderer.frameCommitCount,
            priorCommit,
            "Match Client tiles must continue rendering after the first image")
        XCTAssertEqual(
            session.videoBandRenderer.lastCommitBandCount,
            expectedBandCount)
        XCTAssertEqual(
            session.videoBandRenderer.partialCommitCount,
            0,
            "The Metal/Core Animation handoff must never publish a partial tile set")
    }

    private func expectedBandCount(for viewSize: CGSize) -> Int {
        guard let size = RemoteDisplaySize.matching(viewSize: viewSize) else { return 1 }
        return AppleMediaVideoMode.activeTileCount(
            pixelWidth: Int(size.pixelWidth),
            pixelHeight: Int(size.pixelHeight))
    }

    private final class BandStats: @unchecked Sendable {
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var n = 0
            func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
        }
        private let lock = NSLock()
        private var total: [UInt32: Int] = [:]
        private var green: [UInt32: Int] = [:]
        private var firstGreenAfterGood: [UInt32: Bool] = [:]
        private var lastWasGood: [UInt32: Bool] = [:]

        func record(ssrc: UInt32, green isG: Bool) {
            lock.lock(); defer { lock.unlock() }
            total[ssrc, default: 0] += 1
            if isG { green[ssrc, default: 0] += 1 }
        }
        func report() -> (totalFrames: Int, greenFrames: Int) {
            lock.lock(); defer { lock.unlock() }
            print("=== REALTIME BAND HEALTH ===")
            print("distinct bands (SSRCs) that produced frames: \(total.count)")
            for (ssrc, n) in total.sorted(by: { $0.key < $1.key }) {
                let g = green[ssrc, default: 0]
                print(String(format: "  band ssrc=%u frames=%d green=%d (%.0f%%)",
                             ssrc & 0xffff, n, g, 100.0 * Double(g) / Double(max(1, n))))
            }
            let allGreen = green.values.reduce(0, +)
            let allTotal = total.values.reduce(0, +)
            print("TOTAL frames=\(allTotal) green=\(allGreen)")
            return (allTotal, allGreen)
        }
    }
}

/// Sample a grid of pixels; a decoder-concealment "green" frame has G strongly
/// dominant over R and B across the whole frame. Handles `32BGRA`, uncompressed
/// bi-planar YCbCr (`444f`, `444v`, `420f`, `420v`), and Apple Silicon
/// lossless-compressed IOSurface formats (`&8f4`, etc.).
private let greenCheckCIContext = CIContext(options: [.cacheIntermediates: false])

private func isGreen(_ pb: CVPixelBuffer) -> Bool {
    let format = CVPixelBufferGetPixelFormatType(pb)
    let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
    guard w > 0, h > 0 else { return false }

    if format == kCVPixelFormatType_32BGRA {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return false }
        let stride = CVPixelBufferGetBytesPerRow(pb)
        let ptr = base.assumingMemoryBound(to: UInt8.self)
        var greenish = 0, samples = 0
        var y = 8
        while y < h {
            var x = 8
            while x < w {
                let p = y * stride + x * 4
                let b = Int(ptr[p]), g = Int(ptr[p + 1]), r = Int(ptr[p + 2])
                if g > 90 && g > r + 40 && g > b + 40 { greenish += 1 }
                samples += 1
                x += 64
            }
            y += 32
        }
        return samples > 0 && greenish * 100 / samples > 80
    }

    // For uncompressed linear bi-planar YCbCr we can sample planes directly;
    // for lossless-compressed formats (e.g. `&8f4`), downsample via Core Image
    // into a small 32x16 RGBA grid so compressed tile layouts are never read raw.
    switch format {
    case kCVPixelFormatType_444YpCbCr8BiPlanarFullRange,
         kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange,
         kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
         kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard CVPixelBufferGetPlaneCount(pb) >= 2,
              let yBase = CVPixelBufferGetBaseAddressOfPlane(pb, 0),
              let uvBase = CVPixelBufferGetBaseAddressOfPlane(pb, 1) else {
            return false
        }
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
        let uvWidth = CVPixelBufferGetWidthOfPlane(pb, 1)
        let uvHeight = CVPixelBufferGetHeightOfPlane(pb, 1)
        let shiftX = uvWidth < w ? 1 : 0
        let shiftY = uvHeight < h ? 1 : 0
        let yPtr = yBase.assumingMemoryBound(to: UInt8.self)
        let uvPtr = uvBase.assumingMemoryBound(to: UInt8.self)
        var greenish = 0, samples = 0
        var y = 8
        while y < h {
            var x = 8
            while x < w {
                let luma = Double(yPtr[y * yStride + x])
                let cx = min(x >> shiftX, max(0, uvWidth - 1))
                let cy = min(y >> shiftY, max(0, uvHeight - 1))
                let cb = Double(uvPtr[cy * uvStride + cx * 2]) - 128.0
                let cr = Double(uvPtr[cy * uvStride + cx * 2 + 1]) - 128.0
                let r = Int(max(0.0, min(255.0, luma + 1.5748 * cr)))
                let g = Int(max(0.0, min(255.0, luma - 0.1873 * cb - 0.4681 * cr)))
                let b = Int(max(0.0, min(255.0, luma + 1.8556 * cb)))
                if g > 90 && g > r + 40 && g > b + 40 { greenish += 1 }
                samples += 1
                x += 64
            }
            y += 32
        }
        return samples > 0 && greenish * 100 / samples > 80

    default:
        let gridW = 32
        let gridH = 16
        let ci = CIImage(cvPixelBuffer: pb)
        let scaled = ci.transformed(by: CGAffineTransform(
            scaleX: CGFloat(gridW) / CGFloat(w),
            y: CGFloat(gridH) / CGFloat(h)))
        var rgba = [UInt8](repeating: 0, count: gridW * gridH * 4)
        greenCheckCIContext.render(
            scaled,
            toBitmap: &rgba,
            rowBytes: gridW * 4,
            bounds: CGRect(x: 0, y: 0, width: gridW, height: gridH),
            format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        var greenish = 0
        let samples = gridW * gridH
        for i in 0..<samples {
            let r = Int(rgba[i * 4])
            let g = Int(rgba[i * 4 + 1])
            let b = Int(rgba[i * 4 + 2])
            if g > 90 && g > r + 40 && g > b + 40 { greenish += 1 }
        }
        return samples > 0 && greenish * 100 / samples > 80
    }
}
