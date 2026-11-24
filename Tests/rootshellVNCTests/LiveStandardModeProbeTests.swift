import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Darwin
import os
@testable import RFBProtocol
@testable import RFBTransport
@testable import RFBRendering
@testable import rootshellVNC

/// Live probe for the classic (standard) RFB path against a real server.
///
/// Exercises exactly what the app's standard mode does — bgra8888 pixel
/// format, Tight quality 9 with lossless fallbacks, backpressured update requests
/// with credit acknowledgement, persistent Zlib/ZRLE decode — and reports
/// per-second update cadence, payload sizes, and encoding mix. Any
/// "Zlib rectangle decoded N bytes" / "Invalid ZRLE subencoding" issue is a
/// stream-desync canary and fails the test.
///
///   VNC_TEST_HOST=... VNC_TEST_USERNAME=... VNC_TEST_PASSWORD='...' \
///     swift test --filter LiveStandardModeProbeTests
///
/// Optional: VNC_PROBE_SECONDS=N (motion phase length, default 12),
/// VNC_PROBE_RTT_MS, VNC_PROBE_JITTER_MS, VNC_PROBE_LOSS_PERCENT,
/// VNC_PROBE_LOSS_RECOVERY_MS, VNC_PROBE_BANDWIDTH_KBPS, and
/// VNC_PROBE_UPSTREAM_KBPS apply deterministic loopback conditioning.
/// ROOTSHELL_VNC_FRAME_OUT_DIR=<dir> dumps decoded PNGs.
final class LiveStandardModeProbeTests: XCTestCase {

    func testCapturedAppleDCTReplay() throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["VNC_DCT_CAPTURE"], !path.isEmpty else {
            throw XCTSkip("Set VNC_DCT_CAPTURE to an ADCTCAP1 sequence")
        }
        let width = Int(env["VNC_DCT_WIDTH"] ?? "2976") ?? 2976
        let height = Int(env["VNC_DCT_HEIGHT"] ?? "1860") ?? 1860
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        var offset = 0
        func read(_ count: Int) throws -> Data {
            guard offset + count <= bytes.count else {
                throw AppleAdaptiveDCTError.malformed("Truncated ADCTCAP1 sequence")
            }
            defer { offset += count }
            return bytes[offset..<(offset + count)]
        }
        func readUInt16() throws -> UInt16 {
            let value = try read(2)
            return UInt16(value[value.startIndex]) << 8 | UInt16(value[value.startIndex + 1])
        }
        func readUInt32() throws -> UInt32 {
            let value = try read(4)
            return UInt32(value[value.startIndex]) << 24
                | UInt32(value[value.startIndex + 1]) << 16
                | UInt32(value[value.startIndex + 2]) << 8
                | UInt32(value[value.startIndex + 3])
        }
        XCTAssertEqual(String(decoding: try read(8), as: UTF8.self), "ADCTCAP1")
        let capturedCount = Int(try readUInt32())
        let count = min(
            capturedCount,
            Int(env["VNC_DCT_LIMIT"] ?? "\(capturedCount)") ?? capturedCount)
        let drawPixels = env["VNC_DCT_PARSE_ONLY"] != "1"
        let dumpIndices = Set(
            (env["VNC_DCT_DUMP_INDICES"] ?? "")
                .split(separator: ",")
                .compactMap { Int($0) })
        let dumpDirectory = env["VNC_DCT_DUMP_DIR"]
        let framebuffer = Framebuffer(width: width, height: height, pixelFormat: .bgra8888)
        let decoder = AppleAdaptiveDCTDecoder()
        for index in 0..<count {
            let rect = FramebufferRect(
                x: try readUInt16(), y: try readUInt16(),
                width: try readUInt16(), height: try readUInt16(),
                encoding: .appleMultiVariantScreenshare)
            let payload = try read(Int(try readUInt32()))
            let messageType = payload.count > 4
                ? String(payload[payload.startIndex + 4])
                : "truncated"
            print(
                "DCT REPLAY rect=\(index) type=\(messageType) "
                    + "xy=\(rect.x),\(rect.y) \(rect.width)x\(rect.height) "
                    + "bytes=\(payload.count)")
            try decoder.render(
                rect: rect, payload: payload, to: framebuffer,
                drawPixels: drawPixels)
            if dumpIndices.contains(index), let dumpDirectory,
               let image = framebuffer.createImage() {
                try FileManager.default.createDirectory(
                    atPath: dumpDirectory, withIntermediateDirectories: true)
                let url = URL(fileURLWithPath: dumpDirectory)
                    .appendingPathComponent("frame-\(index).png")
                if let destination = CGImageDestinationCreateWithURL(
                    url as CFURL, UTType.png.identifier as CFString, 1, nil) {
                    CGImageDestinationAddImage(destination, image, nil)
                    XCTAssertTrue(CGImageDestinationFinalize(destination))
                }
            }
        }
        if let output = env["VNC_DCT_REPLAY_RAW"] {
            try framebuffer.getPixels(
                x: 0, y: 0, width: width, height: height
            ).write(to: URL(fileURLWithPath: output))
        }
        if let output = env["VNC_DCT_REPLAY_PNG"], let image = framebuffer.createImage(),
           let destination = CGImageDestinationCreateWithURL(
                URL(fileURLWithPath: output) as CFURL,
                UTType.png.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(destination, image, nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
        }
    }

    func testStandardModeUpdateCadenceAndDecodeHealth() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["VNC_TEST_HOST"], !host.isEmpty,
              let pass = env["VNC_TEST_PASSWORD"], !pass.isEmpty else {
            throw XCTSkip("Set VNC_TEST_HOST and VNC_TEST_PASSWORD")
        }
        let user = env["VNC_TEST_USERNAME"] ?? ""
        let port = UInt16(env["VNC_TEST_PORT"] ?? "5900") ?? 5900
        let motionSeconds = Int(env["VNC_PROBE_SECONDS"] ?? "12") ?? 12
        let scenario = env["VNC_PROBE_SCENARIO"] ?? "custom"
        let outDir = env["ROOTSHELL_VNC_FRAME_OUT_DIR"]
        let downstreamRate = Int(env["VNC_PROBE_BANDWIDTH_KBPS"] ?? "")
            .flatMap { $0 > 0 ? max(1, $0 * 1_000 / 8) : nil }
        let upstreamRate = Int(env["VNC_PROBE_UPSTREAM_KBPS"] ?? "")
            .flatMap { $0 > 0 ? max(1, $0 * 1_000 / 8) : nil }
        let rttMilliseconds = max(0, Int(env["VNC_PROBE_RTT_MS"] ?? "0") ?? 0)
        let networkConditions = LiveNetworkConditions(
            downstreamBytesPerSecond: downstreamRate,
            upstreamBytesPerSecond: upstreamRate,
            oneWayDelayMilliseconds: (rttMilliseconds + 1) / 2,
            jitterMilliseconds: max(
                0, Int(env["VNC_PROBE_JITTER_MS"] ?? "0") ?? 0),
            lossPercent: max(
                0, Double(env["VNC_PROBE_LOSS_PERCENT"] ?? "0") ?? 0),
            lossRecoveryMilliseconds: max(
                0, Int(env["VNC_PROBE_LOSS_RECOVERY_MS"] ?? "200") ?? 200),
            seed: UInt64(env["VNC_PROBE_SEED"] ?? "12648430") ?? 12_648_430)
        var networkProxy: LiveNetworkConditioningProxy?
        let connectionHost: String
        let connectionPort: UInt16
        if networkConditions.isImpaired {
            let proxy = try LiveNetworkConditioningProxy(
                remoteHost: host, remotePort: port,
                conditions: networkConditions)
            networkProxy = proxy
            connectionHost = "127.0.0.1"
            connectionPort = proxy.localPort
            let downstreamLabel = env["VNC_PROBE_BANDWIDTH_KBPS"] ?? "unlimited"
            let upstreamLabel = env["VNC_PROBE_UPSTREAM_KBPS"] ?? "unlimited"
            print(
                "PROBE network rtt=\(rttMilliseconds)ms "
                    + "jitter=\(networkConditions.jitterMilliseconds)ms "
                    + "loss=\(networkConditions.lossPercent)% "
                    + "downstream=\(downstreamLabel)kbps "
                    + "upstream=\(upstreamLabel)kbps "
                    + "port=\(proxy.localPort)")
        } else {
            connectionHost = host
            connectionPort = port
        }
        defer { networkProxy?.stop() }

        // Mirror VNCConfiguration(videoQualityMode: .standard).effectiveEncodings.
        // VNC_PROBE_ENCODING=zlib/zrle selects a lossless A/B comparison.
        let encoding = env["VNC_PROBE_ENCODING"] ?? "tight"
        let preferred: [Encoding]
        switch encoding {
        case "dct":
            // Native Apple-capable ordering, including LastRect and the four
            // capability encodings required by the adaptive protocol.
            preferred = [
                .appleMultiVariantScreenshare, .tight, .lastRect,
                .zrle, .zlib, .copyRect,
                .unknown(1105), .unknown(1101), .unknown(1100), .unknown(1104),
                .raw, .unknown(-23),
            ]
        case "zlib": preferred = [.zlib, .zrle, .copyRect, .raw]
        case "zrle": preferred = [.zrle, .zlib, .copyRect, .raw]
        default: preferred = [.tight, .zlib, .zrle, .copyRect, .raw, .unknown(-23)]
        }
        let encodings = preferred
            + [.desktopSize, .extendedDesktopSize, .cursor]
        // VNC_PROBE_DEPTH=16 explicitly negotiates the optional rgb555 mode.
        let pixelFormat: PixelFormat =
            env["VNC_PROBE_DEPTH"] == "16" ? .rgb555 : .bgra8888
        let session = TransportSession(
            host: connectionHost, port: connectionPort, password: pass, username: user,
            preferredPixelFormat: pixelFormat,
            preferredEncodings: encodings)

        actor ProbeStats {
            var updates = 0
            var bytes = 0
            var rects = 0
            var encodingCounts: [String: Int] = [:]
            var payloadSizes: [Int] = []
            var issues: [String] = []
            var interUpdateGapsMs: [Double] = []
            var renderTimesMs: [Double] = []
            var lastUpdateNanos: UInt64 = 0
            var sawCursor = false
            var dctTypeCounts: [UInt8: Int] = [:]
            var refinementTracker = AppleDCTRefinementTracker()
            var refinementStartedNanos: UInt64 = 0
            var refinementTimesMs: [Double] = []
            var presentationSimulations = [0, 8, 16, 25, 33, 50].map {
                DCTPresentationTradeoffSimulation(holdMilliseconds: $0)
            }
            var firstDCT: Data?
            var firstDCTImage: Data?
            var dctCapture = Data("ADCTCAP1".utf8)
            var dctCaptureCount: UInt32 = 0

            func record(rects rectsWithData: [(FramebufferRect, Data)]) {
                let now = DispatchTime.now().uptimeNanoseconds
                for index in presentationSimulations.indices {
                    presentationSimulations[index].ingest(
                        rectsWithData, nowNanos: now)
                }
                updates += 1
                rects += rectsWithData.count
                var updateBytes = 0
                var containsDCTBase = false
                for (rect, data) in rectsWithData {
                    updateBytes += data.count
                    encodingCounts[String(describing: rect.encoding), default: 0] += 1
                    if rect.encoding == .cursor { sawCursor = true }
                    if rect.encoding == .appleMultiVariantScreenshare,
                       firstDCT == nil {
                        firstDCT = data
                    }
                    if rect.encoding == .appleMultiVariantScreenshare,
                       data.count > 4, data[data.startIndex + 4] == 0,
                       firstDCTImage == nil {
                        firstDCTImage = data
                    }
                    if rect.encoding == .appleMultiVariantScreenshare {
                        if data.count > 4 {
                            let type = data[data.startIndex + 4]
                            dctTypeCounts[type, default: 0] += 1
                            if type == 0 { containsDCTBase = true }
                        }
                        appendDCTCapture(rect: rect, payload: data)
                    }
                }
                if containsDCTBase {
                    refinementStartedNanos = now
                }
                let awaitsRefinement = refinementTracker.ingest(rectsWithData)
                if !awaitsRefinement, refinementStartedNanos != 0 {
                    refinementTimesMs.append(
                        Double(now &- refinementStartedNanos) / 1e6)
                    refinementStartedNanos = 0
                }
                bytes += updateBytes
                payloadSizes.append(updateBytes)
                if lastUpdateNanos != 0 {
                    interUpdateGapsMs.append(Double(now - lastUpdateNanos) / 1e6)
                }
                lastUpdateNanos = now
            }

            func recordRender(milliseconds: Double) {
                renderTimesMs.append(milliseconds)
            }

            func note(issues newIssues: [String]) {
                issues.append(contentsOf: newIssues)
            }

            func summary(label: String) -> String {
                let sorted = payloadSizes.sorted()
                let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
                let p95 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, sorted.count * 95 / 100)]
                let maxPayload = sorted.last ?? 0
                let gaps = interUpdateGapsMs.sorted()
                let medGap = gaps.isEmpty ? 0 : gaps[gaps.count / 2]
                let gapP95 = Self.percentile(gaps, percent: 95)
                let renderP95 = Self.percentile(renderTimesMs, percent: 95)
                let refinementP95 = Self.percentile(refinementTimesMs, percent: 95)
                return """
                [\(label)] updates=\(updates) rects=\(rects) totalKB=\(bytes / 1024) \
                payload median=\(median)B p95=\(p95)B max=\(maxPayload)B \
                interUpdate median=\(String(format: "%.1f", medGap))ms \
                p95=\(String(format: "%.1f", gapP95))ms \
                renderP95=\(String(format: "%.1f", renderP95))ms \
                refinementP95=\(String(format: "%.1f", refinementP95))ms \
                encodings=\(encodingCounts) dctTypes=\(dctTypeCounts) cursorRect=\(sawCursor) \
                issues=\(Array(Set(issues)).sorted())
                """
            }

            func resultFields(durationSeconds: Int) -> String {
                let gaps = interUpdateGapsMs.sorted()
                let refinement = refinementTimesMs.sorted()
                let render = renderTimesMs.sorted()
                let kilobitsPerSecond = durationSeconds > 0
                    ? Double(bytes * 8) / Double(durationSeconds * 1_000) : 0
                return String(
                    format: "updates=%d kbps=%.0f gapP50Ms=%.1f gapP95Ms=%.1f "
                        + "renderP95Ms=%.1f refineP50Ms=%.1f refineP95Ms=%.1f "
                        + "dct0=%d dct1=%d dct2=%d",
                    updates, kilobitsPerSecond,
                    Self.percentile(gaps, percent: 50),
                    Self.percentile(gaps, percent: 95),
                    Self.percentile(render, percent: 95),
                    Self.percentile(refinement, percent: 50),
                    Self.percentile(refinement, percent: 95),
                    dctTypeCounts[0, default: 0],
                    dctTypeCounts[1, default: 0],
                    dctTypeCounts[2, default: 0])
            }

            func presentationTradeoffFields() -> String {
                let now = DispatchTime.now().uptimeNanoseconds
                return presentationSimulations.indices.map { index in
                    presentationSimulations[index].resultFields(
                        nowNanos: now)
                }.joined(separator: " ")
            }

            func reset() {
                updates = 0; bytes = 0; rects = 0
                encodingCounts = [:]; payloadSizes = []
                interUpdateGapsMs = []; lastUpdateNanos = 0
                renderTimesMs = []; dctTypeCounts = [:]
                refinementTracker.reset()
                refinementStartedNanos = 0
                refinementTimesMs = []
                presentationSimulations = [0, 8, 16, 25, 33, 50].map {
                    DCTPresentationTradeoffSimulation(holdMilliseconds: $0)
                }
            }

            func firstDCTPayload() -> Data? {
                firstDCT
            }

            func firstDCTImagePayload() -> Data? {
                firstDCTImage
            }

            func dctCapturePayload() -> Data {
                var result = dctCapture
                result.replaceSubrange(8..<12, with: Self.bigEndianBytes(dctCaptureCount))
                return result
            }

            private func appendDCTCapture(rect: FramebufferRect, payload: Data) {
                if dctCapture.count == 8 {
                    dctCapture.append(contentsOf: [0, 0, 0, 0])
                }
                dctCapture.append(contentsOf: Self.bigEndianBytes(rect.x))
                dctCapture.append(contentsOf: Self.bigEndianBytes(rect.y))
                dctCapture.append(contentsOf: Self.bigEndianBytes(rect.width))
                dctCapture.append(contentsOf: Self.bigEndianBytes(rect.height))
                dctCapture.append(contentsOf: Self.bigEndianBytes(UInt32(payload.count)))
                dctCapture.append(payload)
                dctCaptureCount += 1
            }

            private static func bigEndianBytes<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
                withUnsafeBytes(of: value.bigEndian) { Array($0) }
            }

            private static func percentile(
                _ sorted: [Double], percent: Int
            ) -> Double {
                guard !sorted.isEmpty else { return 0 }
                let index = min(
                    sorted.count - 1,
                    max(0, sorted.count * percent / 100))
                return sorted[index]
            }
        }

        let stats = ProbeStats()
        let rendererBox = RendererBox()

        let eventTask = Task {
            for await event in session.events {
                switch event {
                case .serverInit(let si):
                    print("PROBE serverInit \(si.framebufferWidth)x\(si.framebufferHeight) name=\(si.name)")
                    rendererBox.configure(
                        width: Int(si.framebufferWidth),
                        height: Int(si.framebufferHeight),
                        pixelFormat: pixelFormat)
                case .framebufferUpdate(let rectsWithData):
                    if env["VNC_PROBE_DISPLAY_LAYOUT"] == "1" {
                        for (rect, payload) in rectsWithData
                        where rect.encoding == .unknown(1101)
                                || rect.encoding == .unknown(1105) {
                            let hex = payload.map {
                                String(format: "%02x", $0)
                            }.joined(separator: " ")
                            print(
                                "PROBE displayLayout encoding="
                                    + "\(rect.encoding.rawValue) bytes=\(payload.count) \(hex)")
                        }
                    }
                    await stats.record(rects: rectsWithData)
                    let renderStarted = DispatchTime.now().uptimeNanoseconds
                    if let result = rendererBox.apply(
                        rectsWithData,
                        includeDCT: env["VNC_PROBE_RENDER_DCT"] == "1") {
                        let renderFinished = DispatchTime.now().uptimeNanoseconds
                        await stats.recordRender(
                            milliseconds: Double(renderFinished &- renderStarted) / 1e6)
                        await stats.note(issues: result.issues)
                    }
                    try? await session.finishFramebufferUpdate()
                case .error(let error):
                    print("PROBE ERROR \(error)")
                case .stateChanged(let state):
                    print("PROBE state \(state)")
                default:
                    break
                }
            }
        }

        try await session.connect()

        // Phase 1: idle screen.
        try await Task.sleep(for: .seconds(4))
        let idleSummary = await stats.summary(label: "idle")
        let idleTradeoff = await stats.presentationTradeoffFields()
        print("PROBE \(idleSummary)")
        print(
            "PROBE TRADEOFF scenario=\(scenario) phase=idle "
                + idleTradeoff)
        await stats.reset()

        if let kbps = Int(env["VNC_PROBE_BANDWIDTH_AFTER_KBPS"] ?? ""),
           kbps > 0, let networkProxy {
            networkProxy.setDownstreamBytesPerSecond(
                max(1, kbps * 1_000 / 8))
            print("PROBE downstream limit changed to \(kbps)kbps")
        }

        if env["VNC_PROBE_LOGIN"] == "1" {
            // Opt-in only: focus loginwindow, submit the supplied test
            // credential, and capture the high-motion desktop transition.
            try? await session.sendPointerEvent(buttonMask: 0, x: 1488, y: 930)
            try? await session.sendPointerEvent(buttonMask: 1, x: 1488, y: 930)
            try? await session.sendPointerEvent(buttonMask: 0, x: 1488, y: 930)
            try? await Task.sleep(for: .seconds(1))
            for scalar in pass.unicodeScalars {
                try? await session.sendKeyEvent(
                    downFlag: true, key: UInt32(scalar.value))
                try? await session.sendKeyEvent(
                    downFlag: false, key: UInt32(scalar.value))
                try? await Task.sleep(for: .milliseconds(60))
            }
            try? await session.sendKeyEvent(downFlag: true, key: 0xFF0D)
            try? await session.sendKeyEvent(downFlag: false, key: 0xFF0D)
            try? await Task.sleep(for: .seconds(5))
        }

        // Phase 2: motion — sweep the pointer diagonally across the screen so
        // it crosses UI elements (cursor-shape changes and hover effects both
        // dirty the framebuffer).
        let deadline = Date().addingTimeInterval(TimeInterval(motionSeconds))
        var i = 0
        let exerciseScrolling = env["VNC_PROBE_SCROLL"] == "1"
        while Date() < deadline {
            if exerciseScrolling {
                try? await session.sendScrollEvent(AppleScrollEvent(
                    deltaY: -3,
                    fixedDeltaY: -3 << 16,
                    pointDeltaY: -24,
                    scrollPhase: i == 0 ? .began : .changed,
                    flags: [.continuous],
                    x: 1488,
                    y: 930))
            } else {
                let t = i % 40
                try? await session.sendPointerEvent(
                    buttonMask: 0,
                    x: UInt16(200 + t * 64),
                    y: UInt16(200 + t * 36))
            }
            try? await Task.sleep(for: .milliseconds(50))
            i += 1
        }
        if exerciseScrolling {
            try? await session.sendScrollEvent(AppleScrollEvent(
                scrollPhase: .ended,
                flags: [.continuous],
                x: 1488,
                y: 930))
        }
        let motionSummary = await stats.summary(label: "motion")
        let motionResultFields = await stats.resultFields(
            durationSeconds: motionSeconds)
        let motionTradeoff = await stats.presentationTradeoffFields()
        print("PROBE \(motionSummary)")
        print(
            "PROBE TRADEOFF scenario=\(scenario) phase=motion "
                + motionTradeoff)
        await stats.reset()

        if encoding == "dct" {
            // Static desktops may not answer incremental requests. Force one
            // complete post-motion frame so the capture includes the current
            // desktop's cache/refinement command mix.
            try? await session.requestFramebufferUpdate(incremental: false)
            try? await Task.sleep(for: .seconds(5))
            if let outDir, let dct = await stats.firstDCTPayload() {
                try? FileManager.default.createDirectory(
                    atPath: outDir, withIntermediateDirectories: true)
                try? dct.write(to: URL(
                    fileURLWithPath: outDir + "/adaptive_dct_first.bin"))
                if let image = await stats.firstDCTImagePayload() {
                    try? image.write(to: URL(
                        fileURLWithPath: outDir + "/adaptive_dct_type0.bin"))
                }
                let capture = await stats.dctCapturePayload()
                try? capture.write(to: URL(
                    fileURLWithPath: outDir + "/adaptive_dct_capture.bin"))
                rendererBox.dumpPNG(to: outDir + "/standard_probe_final.png")
            }
            let issues = await stats.issues
            let proxyFields: String
            if let snapshot = networkProxy?.snapshot() {
                proxyFields = "proxyDownPackets=\(snapshot.downstreamPackets) "
                    + "proxyDownLoss=\(snapshot.downstreamSimulatedLosses) "
                    + "proxyUpPackets=\(snapshot.upstreamPackets) "
                    + "proxyUpLoss=\(snapshot.upstreamSimulatedLosses)"
            } else {
                proxyFields = "proxyDownPackets=0 proxyDownLoss=0 "
                    + "proxyUpPackets=0 proxyUpLoss=0"
            }
            print(
                "PROBE RESULT scenario=\(scenario) "
                    + "rttMs=\(rttMilliseconds) "
                    + "jitterMs=\(networkConditions.jitterMilliseconds) "
                    + "lossPercent=\(networkConditions.lossPercent) "
                    + motionResultFields + " " + proxyFields)
            eventTask.cancel()
            await session.disconnect()
            XCTAssertTrue(issues.isEmpty, "decode issues (desync canary): \(issues.prefix(5))")
            return
        }

        // Phase 3: loop-alive + latency measurement. A static screen answers
        // incremental requests with silence (correct RFB), so force full
        // non-incremental updates and time request -> update-received. This
        // is the end-to-end number: server encode + transfer + client read.
        var fullUpdateMs: [Double] = []
        for round in 0..<5 {
            let before = await stats.updates
            let start = DispatchTime.now().uptimeNanoseconds
            try await session.requestFramebufferUpdate(incremental: false)
            var waited = 0
            while await stats.updates == before, waited < 100 {
                try? await Task.sleep(for: .milliseconds(100))
                waited += 1
            }
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
            let arrived = await stats.updates > before
            fullUpdateMs.append(elapsed)
            print("PROBE fullUpdate round=\(round) arrived=\(arrived) ms=\(String(format: "%.0f", elapsed))")
            XCTAssertTrue(arrived, "update loop is dead: non-incremental request got no response")
        }
        let fullSummary = await stats.summary(label: "full-updates")
        print("PROBE \(fullSummary)")
        print("PROBE fullUpdate median ms=\(fullUpdateMs.sorted()[fullUpdateMs.count / 2])")

        if let outDir {
            try? FileManager.default.createDirectory(
                atPath: outDir, withIntermediateDirectories: true)
            rendererBox.dumpPNG(to: outDir + "/standard_probe_final.png")
            if let dct = await stats.firstDCTPayload() {
                try? dct.write(to: URL(fileURLWithPath: outDir + "/adaptive_dct_first.bin"))
            }
        }

        let issues = await stats.issues
        eventTask.cancel()
        await session.disconnect()

        XCTAssertTrue(issues.isEmpty, "decode issues (desync canary): \(issues.prefix(5))")
    }

    /// A Standard session to a Mac switches to whole-stream encryption in
    /// both directions and keeps decoding updates and taking input.
    ///
    /// No screen content may arrive before the key update. The Mac closes
    /// the socket on a client record it cannot decrypt, so a session that
    /// survives encrypted requests and input proves both directions.
    /// VNC_PROBE_ENCODING=tight uses one-shot requests instead of adaptive
    /// DCT auto updates.
    func testStandardWholeStreamEncryption() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["VNC_TEST_HOST"], !host.isEmpty,
              let pass = env["VNC_TEST_PASSWORD"], !pass.isEmpty else {
            throw XCTSkip("Set VNC_TEST_HOST and VNC_TEST_PASSWORD")
        }
        VNCLogRelay.install(minimumLevel: .info) { _, category, message in
            guard category == "TransportSession" else { return }
            print("RELAY \(message.prefix(400))")
        }
        defer { VNCLogRelay.install(sink: nil) }

        let session = TransportSession(
            host: host, port: UInt16(env["VNC_TEST_PORT"] ?? "5900") ?? 5900,
            password: pass, username: env["VNC_TEST_USERNAME"] ?? "",
            preferredPixelFormat: .bgra8888,
            preferredEncodings: (env["VNC_PROBE_ENCODING"] == "tight" ? [] : [.appleMultiVariantScreenshare])
                + [
                    .tight, .lastRect, .zrle, .zlib, .copyRect,
                    .unknown(1105), .unknown(1101), .unknown(1100), .unknown(1104),
                    .raw, .desktopSize, .extendedDesktopSize, .cursor,
                ])
        let counter = OSAllocatedUnfairLock(initialState: (
            updates: 0, bytes: 0, errors: 0, encrypted: false,
            pixelRectsBefore: 0, pixelRectsAfter: 0))
        let eventTask = Task {
            for await event in session.events {
                switch event {
                case .standardStreamEncrypted:
                    counter.withLock { $0.encrypted = true }
                case .framebufferUpdate(let rects):
                    counter.withLock { state in
                        state.updates += 1
                        state.bytes += rects.reduce(0) { $0 + $1.1.count }
                        let pixelRects = rects.filter { $0.0.encoding.isFramebufferContent }.count
                        if state.encrypted {
                            state.pixelRectsAfter += pixelRects
                        } else {
                            state.pixelRectsBefore += pixelRects
                        }
                    }
                    try? await session.finishFramebufferUpdate()
                case .error(let error):
                    counter.withLock { $0.errors += 1 }
                    print("PROBE ERROR \(error)")
                default:
                    break
                }
            }
        }
        defer { eventTask.cancel() }

        try await session.connect()
        try await Task.sleep(for: .seconds(4))
        // Encrypted pointer input after the switch must not end the session.
        for step in 0..<40 {
            try await session.sendPointerEvent(
                buttonMask: 0, x: UInt16(600 + step * 10), y: UInt16(400 + step * 5))
            try await Task.sleep(for: .milliseconds(25))
        }
        try await Task.sleep(for: .seconds(2))
        let final = counter.withLock { $0 }
        let encryption = await session.handshakeInfo.contentEncryption
        print("PROBE encryption=\(encryption) errors=\(final.errors) "
            + "updates=\(final.updates) bytes=\(final.bytes) "
            + "pixelRects before=\(final.pixelRectsBefore) after=\(final.pixelRectsAfter)")
        await session.disconnect()

        guard case .appleComCryption(_, _, let mediaSRTP) = encryption else {
            return XCTFail("Standard session is not encrypted: \(encryption)")
        }
        XCTAssertFalse(mediaSRTP)
        XCTAssertEqual(final.errors, 0, "transport error before disconnect")
        XCTAssertEqual(final.pixelRectsBefore, 0, "screen content arrived before the key update")
        // Byte counts depend on whether the Mac's display is awake.
        XCTAssertGreaterThan(final.pixelRectsAfter, 0, "no screen content after the key update")
    }

    /// Match Client in Standard: the encrypted session still gets the Mac's
    /// confirmation that it will release the virtual display at disconnect.
    @MainActor
    func testStandardMatchClientReleaseUnderEncryption() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["VNC_TEST_HOST"], !host.isEmpty,
              let pass = env["VNC_TEST_PASSWORD"], !pass.isEmpty else {
            throw XCTSkip("Set VNC_TEST_HOST and VNC_TEST_PASSWORD")
        }
        let lines = OSAllocatedUnfairLock(initialState: [String]())
        VNCLogRelay.install(minimumLevel: .info) { _, category, message in
            guard category == "TransportSession" else { return }
            lines.withLock { $0.append(message) }
        }
        defer { VNCLogRelay.install(sink: nil) }

        let session = VNCSession(configuration: VNCConfiguration(
            videoQualityMode: .standard,
            displaySizingMode: .matchClient,
            enableRemoteAudio: false,
            reconnectionPolicy: VNCReconnectionPolicy(isEnabled: false, maximumAttempts: 0)))
        session.updateRemoteDisplaySize(viewSize: CGSize(width: 1512, height: 982), displayScale: 2)
        try await session.connect(credentials: VNCCredentials(
            host: host, port: UInt16(env["VNC_TEST_PORT"] ?? "5900") ?? 5900,
            password: pass, username: env["VNC_TEST_USERNAME"]))
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline, session.framebufferWidth == 0 || session.negotiatedContentEncryption == nil
            || session.negotiatedContentEncryption == VNCContentEncryption.none {
            try await Task.sleep(for: .milliseconds(100))
        }
        let encryption = session.negotiatedContentEncryption
        print("PROBE matchClient encryption=\(String(describing: encryption)) "
            + "framebuffer=\(session.framebufferWidth)x\(session.framebufferHeight)")
        try await Task.sleep(for: .seconds(3))
        session.disconnect()
        try await Task.sleep(for: .seconds(6))

        let log = lines.withLock { $0 }
        for line in log where line.contains("virtual display") || line.contains("Read loop error") {
            print("RELAY \(line.prefix(300))")
        }
        XCTAssertEqual(encryption, .appleComCryption(cipherMode: nil, keyLength: 128, mediaSRTP: false))
        XCTAssertTrue(log.contains("The server will release the virtual display at disconnect"))
    }

    /// Measures the actual high-level `currentImage` publication cadence. This
    /// complements the transport probe above by exercising the coalesced DCT
    /// trailing-snapshot logic used by the app.
    @MainActor
    func testConditionedStandardPresentationCadence() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["VNC_PROBE_PRESENTATION"] == "1" else {
            throw XCTSkip("Set VNC_PROBE_PRESENTATION=1 to run the presentation probe")
        }
        guard let host = env["VNC_TEST_HOST"], !host.isEmpty,
              let password = env["VNC_TEST_PASSWORD"], !password.isEmpty else {
            throw XCTSkip("Set VNC_TEST_HOST and VNC_TEST_PASSWORD")
        }
        let remotePort = UInt16(env["VNC_TEST_PORT"] ?? "5900") ?? 5900
        let rtt = max(0, Int(env["VNC_PROBE_RTT_MS"] ?? "0") ?? 0)
        let downstreamRate = Int(env["VNC_PROBE_BANDWIDTH_KBPS"] ?? "")
            .flatMap { $0 > 0 ? max(1, $0 * 1_000 / 8) : nil }
        let conditions = LiveNetworkConditions(
            downstreamBytesPerSecond: downstreamRate,
            upstreamBytesPerSecond: nil,
            oneWayDelayMilliseconds: (rtt + 1) / 2,
            jitterMilliseconds: max(
                0, Int(env["VNC_PROBE_JITTER_MS"] ?? "0") ?? 0),
            lossPercent: max(
                0, Double(env["VNC_PROBE_LOSS_PERCENT"] ?? "0") ?? 0),
            lossRecoveryMilliseconds: max(
                0, Int(env["VNC_PROBE_LOSS_RECOVERY_MS"] ?? "200") ?? 200),
            seed: UInt64(env["VNC_PROBE_SEED"] ?? "12648430") ?? 12_648_430)
        let proxy = conditions.isImpaired
            ? try LiveNetworkConditioningProxy(
                remoteHost: host, remotePort: remotePort,
                conditions: conditions)
            : nil
        defer { proxy?.stop() }

        let credentials = VNCCredentials(
            host: proxy == nil ? host : "127.0.0.1",
            port: proxy?.localPort ?? remotePort,
            password: password,
            username: env["VNC_TEST_USERNAME"])
        let session = VNCSession(configuration: VNCConfiguration(
            videoQualityMode: .standard,
            displaySizingMode: .remoteDisplay,
            displayCount: 1,
            enableRemoteAudio: false,
            targetFrameRate: 60,
            reconnectionPolicy: VNCReconnectionPolicy(
                isEnabled: false,
                maximumAttempts: 0)))
        try await session.connect(credentials: credentials)
        defer { session.disconnect() }

        let firstFrameDeadline = Date().addingTimeInterval(15)
        while session.currentImage == nil, Date() < firstFrameDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        if session.currentImage == nil {
            print(
                "PROBE FIRST_FRAME_TIMEOUT state=\(session.connectionState) "
                    + "framebuffer=\(session.framebufferWidth)x\(session.framebufferHeight) "
                    + "renderer=\(String(describing: session.standardFramebufferSize)) "
                    + "regions=\(session.remoteDisplayRegions) "
                    + "error=\(String(describing: session.lastError))")
            print(session.getDiagnostics().summary())
        }
        XCTAssertNotNil(session.currentImage, "Standard mode did not publish its first frame")

        let seconds = max(2, Int(env["VNC_PROBE_SECONDS"] ?? "6") ?? 6)
        let deadline = Date().addingTimeInterval(TimeInterval(seconds))
        var lastImage = session.currentImage
        var lastPublishNanos = DispatchTime.now().uptimeNanoseconds
        var publishGapsMs: [Double] = []
        var iteration = 0
        let exerciseScrolling = env["VNC_PROBE_SCROLL"] == "1"
        while Date() < deadline {
            if exerciseScrolling, iteration.isMultiple(of: 4) {
                session.sendScrollEvent(AppleScrollEvent(
                    deltaY: -3,
                    fixedDeltaY: -3 << 16,
                    pointDeltaY: -24,
                    scrollPhase: iteration == 0 ? .began : .changed,
                    flags: [.continuous],
                    x: 1488,
                    y: 930))
            } else if !exerciseScrolling, iteration.isMultiple(of: 10) {
                let step = (iteration / 10) % 40
                session.sendPointerEvent(
                    buttonMask: 0,
                    x: UInt16(200 + step * 64),
                    y: UInt16(200 + step * 36))
            }
            if let image = session.currentImage, image !== lastImage {
                let now = DispatchTime.now().uptimeNanoseconds
                publishGapsMs.append(Double(now &- lastPublishNanos) / 1e6)
                lastPublishNanos = now
                lastImage = image
            }
            iteration += 1
            try await Task.sleep(for: .milliseconds(5))
        }
        if exerciseScrolling {
            session.sendScrollEvent(AppleScrollEvent(
                scrollPhase: .ended,
                flags: [.continuous],
                x: 1488,
                y: 930))
        }

        let sorted = publishGapsMs.sorted()
        func percentile(_ percent: Int) -> Double {
            guard !sorted.isEmpty else { return 0 }
            return sorted[min(sorted.count - 1, sorted.count * percent / 100)]
        }
        let scenario = env["VNC_PROBE_SCENARIO"] ?? "custom"
        print(String(
            format: "PROBE PRESENTATION scenario=%@ publishes=%d "
                + "gapP50Ms=%.1f gapP95Ms=%.1f gapMaxMs=%.1f",
            scenario, sorted.count,
            percentile(50), percentile(95),
            sorted.last ?? 0))
        XCTAssertGreaterThan(
            sorted.count, 1,
            "Standard presentation stalled under the configured network conditions")
    }
}

/// Replays one real DCT event stream against a candidate presentation hold.
/// `quality` is the fraction of the base rectangle area covered by refinement
/// before presentation; it is a protocol-level clarity proxy, not a PSNR score.
private struct DCTPresentationTradeoffSimulation {
    private struct Sample {
        let delayMilliseconds: Double
        let quality: Double
        let fullyRefined: Bool
    }

    let holdMilliseconds: Int
    private var tracker = AppleDCTRefinementTracker()
    private var pendingStartNanos: UInt64?
    private var deadlineNanos: UInt64 = 0
    private var maximumUnrefinedArea: Double = 0
    private var samples: [Sample] = []

    init(holdMilliseconds: Int) {
        self.holdMilliseconds = holdMilliseconds
    }

    mutating func ingest(
        _ rects: [(FramebufferRect, Data)],
        nowNanos: UInt64
    ) {
        expireIfNeeded(nowNanos: nowNanos)
        let wasAwaiting = tracker.isAwaitingRefinement
        let awaitsRefinement = tracker.ingest(rects)

        if !wasAwaiting, awaitsRefinement {
            pendingStartNanos = nowNanos
            deadlineNanos = nowNanos
                &+ UInt64(holdMilliseconds) * 1_000_000
            maximumUnrefinedArea = uncoveredArea
            expireIfNeeded(nowNanos: nowNanos)
            return
        }

        guard pendingStartNanos != nil else { return }
        maximumUnrefinedArea = max(maximumUnrefinedArea, uncoveredArea)
        if wasAwaiting, !awaitsRefinement {
            present(nowNanos: nowNanos, fullyRefined: true)
        }
    }

    mutating func resultFields(nowNanos: UInt64) -> String {
        expireIfNeeded(nowNanos: nowNanos)
        let delays = samples.map(\.delayMilliseconds).sorted()
        let averageQuality = samples.isEmpty
            ? 0 : samples.reduce(0) { $0 + $1.quality } / Double(samples.count)
        let fullPercent = samples.isEmpty
            ? 0
            : Double(samples.filter(\.fullyRefined).count) * 100
                / Double(samples.count)
        return String(
            format: "h%dN=%d h%dDelayP95=%.1f h%dFullPct=%.0f h%dQualityPct=%.0f",
            holdMilliseconds, samples.count,
            holdMilliseconds, percentile(delays, percent: 95),
            holdMilliseconds, fullPercent,
            holdMilliseconds, averageQuality * 100)
    }

    private var uncoveredArea: Double {
        tracker.uncoveredRegions.reduce(0) { result, region in
            result + max(0, region.width) * max(0, region.height)
        }
    }

    private mutating func expireIfNeeded(nowNanos: UInt64) {
        guard pendingStartNanos != nil,
              nowNanos >= deadlineNanos else { return }
        present(nowNanos: deadlineNanos, fullyRefined: false)
        // Production presents the best available pixels and stops treating
        // later refinement bands as a reason to withhold another snapshot.
        tracker.reset()
    }

    private mutating func present(
        nowNanos: UInt64,
        fullyRefined: Bool
    ) {
        guard let start = pendingStartNanos else { return }
        let quality: Double
        if fullyRefined {
            quality = 1
        } else if maximumUnrefinedArea > 0 {
            quality = max(
                0, min(1, 1 - uncoveredArea / maximumUnrefinedArea))
        } else {
            quality = 0
        }
        samples.append(Sample(
            delayMilliseconds: Double(nowNanos &- start) / 1e6,
            quality: quality,
            fullyRefined: fullyRefined))
        pendingStartNanos = nil
        deadlineNanos = 0
        maximumUnrefinedArea = 0
    }

    private func percentile(
        _ sorted: [Double],
        percent: Int
    ) -> Double {
        guard !sorted.isEmpty else { return 0 }
        return sorted[min(
            sorted.count - 1,
            max(0, sorted.count * percent / 100))]
    }
}

final class DCTPresentationTradeoffSimulationTests: XCTestCase {
    func testCompletionInsideHoldPresentsFullyRefinedFrame() {
        var simulation = DCTPresentationTradeoffSimulation(
            holdMilliseconds: 25)
        simulation.ingest(
            [dctRect(y: 0, height: 100, type: 0)],
            nowNanos: 0)
        simulation.ingest(
            [dctRect(y: 0, height: 100, type: 1)],
            nowNanos: 10_000_000)

        let result = simulation.resultFields(nowNanos: 30_000_000)
        XCTAssertTrue(result.contains("h25N=1"))
        XCTAssertTrue(result.contains("h25DelayP95=10.0"))
        XCTAssertTrue(result.contains("h25FullPct=100"))
        XCTAssertTrue(result.contains("h25QualityPct=100"))
    }

    func testTimeoutReportsPartialRefinementCoverage() {
        var simulation = DCTPresentationTradeoffSimulation(
            holdMilliseconds: 25)
        simulation.ingest(
            [dctRect(y: 0, height: 100, type: 0)],
            nowNanos: 0)
        simulation.ingest(
            [dctRect(y: 0, height: 50, type: 1)],
            nowNanos: 10_000_000)

        let result = simulation.resultFields(nowNanos: 30_000_000)
        XCTAssertTrue(result.contains("h25N=1"))
        XCTAssertTrue(result.contains("h25DelayP95=25.0"))
        XCTAssertTrue(result.contains("h25FullPct=0"))
        XCTAssertTrue(result.contains("h25QualityPct=50"))
    }

    func testZeroHoldPresentsBaseWithoutArtificialDelay() {
        var simulation = DCTPresentationTradeoffSimulation(
            holdMilliseconds: 0)
        simulation.ingest(
            [dctRect(y: 0, height: 100, type: 0)],
            nowNanos: 1_000_000)

        let result = simulation.resultFields(nowNanos: 1_000_000)
        XCTAssertTrue(result.contains("h0N=1"))
        XCTAssertTrue(result.contains("h0DelayP95=0.0"))
        XCTAssertTrue(result.contains("h0QualityPct=0"))
    }

    private func dctRect(
        y: UInt16,
        height: UInt16,
        type: UInt8
    ) -> (FramebufferRect, Data) {
        (
            FramebufferRect(
                x: 0, y: y, width: 100, height: height,
                encoding: .appleMultiVariantScreenshare),
            Data([0, 0, 0, 0, type])
        )
    }
}

/// Non-Sendable renderer confined to a serial queue, mirroring VNCSession's
/// framebufferRenderQueue usage.
private final class RendererBox: @unchecked Sendable {
    private let queue = DispatchQueue(label: "probe.render")
    private var renderer: FramebufferRenderer?
    private var framebuffer: Framebuffer?
    private var pixelFormat: PixelFormat = .bgra8888

    func configure(width: Int, height: Int, pixelFormat: PixelFormat) {
        queue.sync {
            self.pixelFormat = pixelFormat
            let fb = Framebuffer(width: width, height: height, pixelFormat: pixelFormat)
            framebuffer = fb
            renderer = FramebufferRenderer(framebuffer: fb, pixelFormat: pixelFormat)
        }
    }

    func apply(
        _ rects: [(FramebufferRect, Data)],
        includeDCT: Bool = false
    ) -> FramebufferRenderBatchResult? {
        queue.sync {
            guard let renderer else { return nil }
            let decodable = rects.filter {
                includeDCT || $0.0.encoding != .appleMultiVariantScreenshare
            }
            if let resize = rects.first(where: { $0.0.isSuccessfulDesktopResize }) {
                let fb = Framebuffer(
                    width: Int(resize.0.width),
                    height: Int(resize.0.height),
                    pixelFormat: pixelFormat)
                framebuffer = fb
                self.renderer = FramebufferRenderer(framebuffer: fb, pixelFormat: pixelFormat)
                return self.renderer?.applyBatch(decodable, snapshot: false)
            }
            return renderer.applyBatch(decodable, snapshot: false)
        }
    }

    func dumpPNG(to path: String) {
        queue.sync {
            guard let image = renderer?.snapshot(),
                  let dest = CGImageDestinationCreateWithURL(
                    URL(fileURLWithPath: path) as CFURL,
                    UTType.png.identifier as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(dest, image, nil)
            CGImageDestinationFinalize(dest)
        }
    }
}
