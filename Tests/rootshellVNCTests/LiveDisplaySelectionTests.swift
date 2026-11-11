import CoreGraphics
import RFBProtocol
import XCTest
@testable import rootshellVNC

/// Opt-in end-to-end coverage for Apple's physical multi-display server.
///
///     VNC_TEST_DISPLAY_SELECTION=1 VNC_TEST_HOST=localhost \
///       VNC_TEST_USERNAME=... VNC_TEST_PASSWORD=... \
///       swift test --filter LiveDisplaySelectionTests
final class LiveDisplaySelectionTests: XCTestCase {
    @MainActor
    func testRepeatedStandardOneDisplayFirstFrame() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["VNC_TEST_STANDARD_FIRST_FRAME"] == "1" else {
            throw XCTSkip(
                "Set VNC_TEST_STANDARD_FIRST_FRAME=1 to run the repeated Standard first-frame probe")
        }
        guard let host = environment["VNC_TEST_HOST"], !host.isEmpty,
              let password = environment["VNC_TEST_PASSWORD"], !password.isEmpty else {
            throw XCTSkip("Set VNC_TEST_HOST and VNC_TEST_PASSWORD")
        }
        let credentials = VNCCredentials(
            host: host,
            port: UInt16(environment["VNC_TEST_PORT"] ?? "5900") ?? 5900,
            password: password,
            username: environment["VNC_TEST_USERNAME"])
        let attemptCount = max(
            1, Int(environment["VNC_TEST_STANDARD_ATTEMPTS"] ?? "5") ?? 5)
        let timeout = TimeInterval(
            environment["VNC_TEST_STANDARD_TIMEOUT"] ?? "15") ?? 15

        for attempt in 1...attemptCount {
            let session = VNCSession(configuration: VNCConfiguration(
                videoQualityMode: .standard,
                displaySizingMode: .remoteDisplay,
                displayCount: 1,
                enableRemoteAudio: false,
                reconnectionPolicy: VNCReconnectionPolicy(
                    isEnabled: false,
                    maximumAttempts: 0)))
            let started = Date()
            try await session.connect(credentials: credentials)

            let deadline = started.addingTimeInterval(timeout)
            var receivedNonBlackFrame = false
            while Date() < deadline {
                if let image = session.currentImage,
                   Self.containsNonBlackPixel(image) {
                    receivedNonBlackFrame = true
                    break
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            let elapsed = Date().timeIntervalSince(started)
            print(
                "STANDARD FIRST FRAME attempt=\(attempt)/\(attemptCount) "
                    + "nonBlack=\(receivedNonBlackFrame) "
                    + "elapsed=\(String(format: "%.2f", elapsed))s "
                    + "framebuffer=\(session.framebufferWidth)x\(session.framebufferHeight)")
            session.disconnect()
            XCTAssertTrue(
                receivedNonBlackFrame,
                "Standard one-display attempt \(attempt) remained black for \(timeout)s")
            try await Task.sleep(for: .milliseconds(500))
        }
    }

    @MainActor
    func testStandardOneDisplayAndAdaptiveTwoDisplays() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["VNC_TEST_DISPLAY_SELECTION"] == "1" else {
            throw XCTSkip("Set VNC_TEST_DISPLAY_SELECTION=1 to run the live display probe")
        }
        let relaysLogs = environment["VNC_TEST_LOGS"] == "1"
        if relaysLogs {
            VNCLogRelay.install(minimumLevel: .debug) { level, category, message in
                print("[\(level.name)] [\(category)] \(message)")
            }
        }
        defer {
            if relaysLogs {
                VNCLogRelay.install(sink: nil)
            }
        }
        guard let host = environment["VNC_TEST_HOST"], !host.isEmpty,
              let password = environment["VNC_TEST_PASSWORD"], !password.isEmpty else {
            throw XCTSkip("Set VNC_TEST_HOST and VNC_TEST_PASSWORD")
        }
        let credentials = VNCCredentials(
            host: host,
            port: UInt16(environment["VNC_TEST_PORT"] ?? "5900") ?? 5900,
            password: password,
            username: environment["VNC_TEST_USERNAME"])
        let mode = environment["VNC_TEST_DISPLAY_SELECTION_MODE"] ?? "all"

        if mode != "adaptive" {
            let twoDisplayStandard = try await standardGeometry(
                displayCount: 2,
                credentials: credentials)
            let oneDisplayStandard = try await standardGeometry(
                displayCount: 1,
                credentials: credentials)
            print(
                "DISPLAY PROBE standard two=\(twoDisplayStandard) "
                    + "one=\(oneDisplayStandard)")
            XCTAssertLessThan(
                oneDisplayStandard.width * oneDisplayStandard.height,
                twoDisplayStandard.width * twoDisplayStandard.height,
                "Standard displayCount=1 must not present the two-display composite")
        }
        guard mode != "standard" else { return }

        let adaptiveSizingMode: VNCConfiguration.DisplaySizingMode =
            environment["VNC_TEST_DISPLAY_SIZING_MODE"] == "matchClient"
                ? .matchClient : .remoteDisplay
        let adaptiveDisplayCount = min(
            2,
            max(1, Int(environment["VNC_TEST_DISPLAY_COUNT"] ?? "2") ?? 2))
        let enablesRemoteAudio = environment["VNC_TEST_REMOTE_AUDIO"] == "1"
        let adaptive = VNCSession(configuration: VNCConfiguration(
            videoQualityMode: .adaptive,
            displaySizingMode: adaptiveSizingMode,
            displayCount: adaptiveDisplayCount,
            enableRemoteAudio: enablesRemoteAudio,
            reconnectionPolicy: VNCReconnectionPolicy(
                isEnabled: false,
                maximumAttempts: 0)))
        if adaptiveSizingMode == .matchClient {
            adaptive.updateRemoteDisplaySize(
                viewSize: CGSize(width: 1512, height: 982),
                displayScale: 2)
        }
        try await adaptive.connect(credentials: credentials)
        defer { adaptive.disconnect() }

        let adaptiveTimeout = TimeInterval(
            environment["VNC_TEST_ADAPTIVE_TIMEOUT"] ?? "25") ?? 25
        let expectedActiveDisplayCount = adaptiveSizingMode == .matchClient
            ? adaptiveDisplayCount : 1
        let deadline = Date().addingTimeInterval(adaptiveTimeout)
        while Date() < deadline {
            if adaptive.activeVideoDisplayCount == expectedActiveDisplayCount,
               adaptive.videoBandRenderer.frameCommitCount > 0,
               (expectedActiveDisplayCount == 1
                    || adaptive.secondaryVideoBandRenderer.frameCommitCount > 0) {
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        let adaptiveWidth = adaptive.framebufferWidth
        let adaptiveHeight = adaptive.framebufferHeight
        let adaptiveRegions = adaptive.remoteDisplayRegions
        let primaryCommits = adaptive.videoBandRenderer.frameCommitCount
        let secondaryCommits = adaptive.secondaryVideoBandRenderer.frameCommitCount
        let primaryProgress = adaptive.primaryVideoDecodeProgress
        let secondaryProgress = adaptive.secondaryVideoDecodeProgress
        let sourceCount = await adaptive.activeTransportVideoSourceCount()
        let receiverIndexes = await adaptive.activeTransportVideoReceiverIndexes()
        let answerLengths = await adaptive.activeTransportMediaAnswerStreamLengths()
        let controlDiagnostic = await adaptive.activeTransportMediaControlDiagnostic()
        let statistics = await adaptive.currentStatistics()
        print("DISPLAY PROBE adaptive framebuffer=\(adaptiveWidth)x\(adaptiveHeight)")
        print("DISPLAY PROBE adaptive regions=\(adaptiveRegions)")
        print(
            "DISPLAY PROBE adaptive commits primary=\(primaryCommits) "
                + "secondary=\(secondaryCommits)")
        print(
            "DISPLAY PROBE adaptive sources=\(sourceCount) "
                + "receivers=\(receiverIndexes) "
                + "answerLengths=\(answerLengths) "
                + "control=\(controlDiagnostic ?? "none") "
                + "audioPackets=\(statistics?.transport.audioPacketsReceived ?? 0) "
                + "primaryProgress=\(String(describing: primaryProgress))")
        print(
            "DISPLAY PROBE adaptive secondaryProgress="
                + String(describing: secondaryProgress))
        XCTAssertEqual(
            adaptive.activeVideoDisplayCount,
            expectedActiveDisplayCount)
        if !enablesRemoteAudio {
            XCTAssertGreaterThan(
                answerLengths.first ?? 0,
                0,
                "Apple requires an audio receiver offer even when playback is disabled")
        }
        XCTAssertGreaterThan(adaptive.videoBandRenderer.frameCommitCount, 0)
        if adaptive.activeVideoDisplayCount > 1 {
            XCTAssertGreaterThan(
                adaptive.secondaryVideoBandRenderer.frameCommitCount,
                0)
            XCTAssertEqual(adaptive.presentedVideoDisplayRegions.count, 2)
        } else {
            // Remote Mac's Displays mode uses one composite HEVC
            // receiver. Two independent receivers are the virtual-display
            // (Match Client) mode.
            XCTAssertEqual(adaptive.presentedVideoDisplayRegions.count, 1)
            let expectedRegionSize: CGSize
            if adaptiveDisplayCount > 1 {
                expectedRegionSize = CGSize(
                    width: adaptiveWidth,
                    height: adaptiveHeight)
            } else {
                expectedRegionSize = try XCTUnwrap(adaptiveRegions.first).size
            }
            XCTAssertEqual(
                adaptive.presentedVideoDisplayRegions.first?.size,
                expectedRegionSize)
        }
    }

    /// Standard (TCP) Match Client: the Mac must render a virtual display at
    /// the viewport size and follow a later window resize.
    @MainActor
    func testStandardMatchClientFollowsViewport() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["VNC_TEST_STANDARD_MATCH_CLIENT"] == "1" else {
            throw XCTSkip("Set VNC_TEST_STANDARD_MATCH_CLIENT=1 to run the Standard Match Client probe")
        }
        guard let host = environment["VNC_TEST_HOST"], !host.isEmpty,
              let password = environment["VNC_TEST_PASSWORD"], !password.isEmpty else {
            throw XCTSkip("Set VNC_TEST_HOST and VNC_TEST_PASSWORD")
        }
        let relaysLogs = environment["VNC_TEST_LOGS"] == "1"
        if relaysLogs {
            VNCLogRelay.install(minimumLevel: .debug) { level, category, message in
                print("[\(level.name)] [\(category)] \(message)")
            }
        }
        defer {
            if relaysLogs {
                VNCLogRelay.install(sink: nil)
            }
        }
        let credentials = VNCCredentials(
            host: host,
            port: UInt16(environment["VNC_TEST_PORT"] ?? "5900") ?? 5900,
            password: password,
            username: environment["VNC_TEST_USERNAME"])
        let quality: VNCConfiguration.VideoQualityMode =
            environment["VNC_TEST_FULL_QUALITY"] == "1" ? .fullQuality : .standard
        let session = VNCSession(configuration: VNCConfiguration(
            videoQualityMode: quality,
            displaySizingMode: .matchClient,
            displayCount: 1,
            enableRemoteAudio: false,
            reconnectionPolicy: VNCReconnectionPolicy(
                isEnabled: false,
                maximumAttempts: 0)))
        XCTAssertEqual(session.configuration.displaySizingMode, .matchClient)

        // Each step is sent 150 ms apart; the last step is a drag-like burst
        // that must settle on its final size.
        let steps: [[CGSize]] = [
            [CGSize(width: 1280, height: 800)],
            [CGSize(width: 1100, height: 900)],
            [CGSize(width: 1512, height: 982)],
            [
                CGSize(width: 1000, height: 700),
                CGSize(width: 1200, height: 750),
                CGSize(width: 1400, height: 850),
                CGSize(width: 1300, height: 820),
            ],
        ]
        session.updateRemoteDisplaySize(viewSize: steps[0][0], displayScale: 2)
        try await session.connect(credentials: credentials)
        defer { session.disconnect() }

        let timeout = TimeInterval(environment["VNC_TEST_STANDARD_TIMEOUT"] ?? "20") ?? 20
        for (index, sizes) in steps.enumerated() {
            let viewSize = try XCTUnwrap(sizes.last)
            let expected = try XCTUnwrap(RemoteDisplaySize.matching(viewSize: viewSize))
            let started = Date()
            if index > 0 {
                for size in sizes {
                    session.updateRemoteDisplaySize(viewSize: size, displayScale: 2)
                    try await Task.sleep(for: .milliseconds(150))
                }
            }
            var matched = false
            while Date().timeIntervalSince(started) < timeout {
                if session.framebufferWidth == Int(expected.pixelWidth),
                   session.framebufferHeight == Int(expected.pixelHeight),
                   let image = session.currentImage,
                   image.width == Int(expected.pixelWidth),
                   Self.containsNonBlackPixel(image) {
                    matched = true
                    break
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            print(
                "STANDARD MATCH CLIENT step=\(index) view=\(viewSize) "
                    + "expected=\(expected.pixelWidth)x\(expected.pixelHeight) "
                    + "framebuffer=\(session.framebufferWidth)x\(session.framebufferHeight) "
                    + "image=\(session.currentImage.map { "\($0.width)x\($0.height)" } ?? "none") "
                    + "elapsed=\(String(format: "%.2f", Date().timeIntervalSince(started)))s")
            XCTAssertTrue(
                matched,
                "Standard Match Client step \(index) did not render "
                    + "\(expected.pixelWidth)x\(expected.pixelHeight)")
        }
    }

    @MainActor
    private func standardGeometry(
        displayCount: Int,
        credentials: VNCCredentials
    ) async throws -> CGSize {
        let session = VNCSession(configuration: VNCConfiguration(
            videoQualityMode: .standard,
            displaySizingMode: .remoteDisplay,
            displayCount: displayCount,
            enableRemoteAudio: false,
            reconnectionPolicy: VNCReconnectionPolicy(
                isEnabled: false,
                maximumAttempts: 0)))
        try await session.connect(credentials: credentials)

        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if session.currentImage != nil,
               session.presentedFramebufferSize.width > 0,
               session.presentedFramebufferSize.height > 0 {
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        let result = session.presentedFramebufferSize
        print(
            "DISPLAY PROBE standard count=\(displayCount) "
                + "framebuffer=\(session.framebufferWidth)x\(session.framebufferHeight) "
                + "presented=\(result) regions=\(session.remoteDisplayRegions)")
        session.disconnect()
        try await Task.sleep(for: .milliseconds(500))
        return result
    }

    /// Standard mode negotiates BGRA8888. Ignore the alpha byte so a fully
    /// opaque black framebuffer does not count as rendered desktop content.
    private static func containsNonBlackPixel(_ image: CGImage) -> Bool {
        guard image.bitsPerPixel == 32,
              let providerData = image.dataProvider?.data,
              let bytes = CFDataGetBytePtr(providerData) else { return false }
        for row in 0..<image.height {
            let rowStart = row * image.bytesPerRow
            for column in 0..<image.width {
                let pixel = rowStart + column * 4
                if bytes[pixel] != 0 || bytes[pixel + 1] != 0
                    || bytes[pixel + 2] != 0 {
                    return true
                }
            }
        }
        return false
    }
}
