import XCTest
import Foundation
import CoreVideo
@testable import rootshellVNC
import RFBProtocol
@testable import RFBRendering

final class AppleLoginScreenDetectorTests: XCTestCase {
    func testDetectsCentralEnterPasswordPhrase() {
        let result = AppleLoginScreenDetector.analyze([
            AppleLoginTextLine(
                text: "Touch ID or Enter Password",
                confidence: 0.94,
                bounds: CGRect(x: 0.35, y: 0.30, width: 0.30, height: 0.04)),
        ])

        XCTAssertTrue(result.isLoginScreen)
        XCTAssertEqual(result.evidence, "central password-entry phrase")
    }

    func testDetectsPasswordPhraseAtBottomOfModernLockScreen() {
        let result = AppleLoginScreenDetector.analyze([
            AppleLoginTextLine(
                text: "Touch ID or Enter Password",
                confidence: 0.98,
                bounds: CGRect(x: 0.38, y: 0.02, width: 0.24, height: 0.02)),
        ])

        XCTAssertTrue(result.isLoginScreen)
        XCTAssertEqual(result.evidence, "central password-entry phrase")
    }

    func testRejectsPasswordTextOutsideLoginRegion() {
        let result = AppleLoginScreenDetector.analyze([
            AppleLoginTextLine(
                text: "Enter Password",
                confidence: 0.99,
                bounds: CGRect(x: 0.02, y: 0.90, width: 0.15, height: 0.03)),
        ])

        XCTAssertFalse(result.isLoginScreen)
    }

    func testRejectsWeakPasswordMentionOnOrdinaryDesktop() {
        let result = AppleLoginScreenDetector.analyze([
            AppleLoginTextLine(
                text: "Change your password in Settings",
                confidence: 0.92,
                bounds: CGRect(x: 0.25, y: 0.45, width: 0.50, height: 0.04)),
        ])

        XCTAssertFalse(result.isLoginScreen)
        XCTAssertEqual(result.evidence, "weak password text only")
    }

    func testRejectsBareLowerCenterPasswordField() {
        let result = AppleLoginScreenDetector.analyze([
            AppleLoginTextLine(
                text: "Password",
                confidence: 0.90,
                bounds: CGRect(
                    x: 0.44, y: 0.31, width: 0.12, height: 0.03)),
        ])

        XCTAssertFalse(result.isLoginScreen)
        XCTAssertEqual(result.evidence, "weak password text only")
    }

    func testRejectsOrdinaryWebsitePasswordForm() {
        let result = AppleLoginScreenDetector.analyze([
            AppleLoginTextLine(
                text: "Email",
                confidence: 0.94,
                bounds: CGRect(
                    x: 0.40, y: 0.39, width: 0.20, height: 0.03)),
            AppleLoginTextLine(
                text: "Password",
                confidence: 0.96,
                bounds: CGRect(
                    x: 0.40, y: 0.32, width: 0.20, height: 0.03)),
            AppleLoginTextLine(
                text: "Sign In",
                confidence: 0.95,
                bounds: CGRect(
                    x: 0.45, y: 0.24, width: 0.10, height: 0.03)),
        ])

        XCTAssertFalse(result.isLoginScreen)
        XCTAssertEqual(result.evidence, "weak password text only")
    }

    func testGenericPasswordNeedsMultipleLoginActions() {
        let result = AppleLoginScreenDetector.analyze([
            AppleLoginTextLine(
                text: "Password",
                confidence: 0.90,
                bounds: CGRect(x: 0.44, y: 0.34, width: 0.12, height: 0.03)),
            AppleLoginTextLine(
                text: "Switch User",
                confidence: 0.88,
                bounds: CGRect(x: 0.38, y: 0.14, width: 0.10, height: 0.03)),
            AppleLoginTextLine(
                text: "Cancel",
                confidence: 0.89,
                bounds: CGRect(x: 0.52, y: 0.14, width: 0.08, height: 0.03)),
        ])

        XCTAssertTrue(result.isLoginScreen)
        XCTAssertEqual(result.evidence, "password and login-window actions")
    }
}

final class TightVNCCursorTests: XCTestCase {
    func testDecodesXCursorShapeAndHotspot() throws {
        let rect = FramebufferRect(
            x: 1, y: 0, width: 8, height: 1, encoding: .xCursor)
        // Foreground RGB, background RGB, source bits, visibility bits.
        let payload = Data([255, 255, 255, 0, 0, 0, 0x80, 0xC0])

        let update = try XCTUnwrap(RemoteCursorDecoder.decode(
            rect: rect, data: payload, pixelFormat: .bgra8888))
        guard case .shape(let cursor) = update else {
            return XCTFail("Expected a visible XCursor shape")
        }

        XCTAssertEqual(cursor.width, 8)
        XCTAssertEqual(cursor.height, 1)
        XCTAssertEqual(cursor.hotspotX, 1)
        XCTAssertEqual(cursor.hotspotY, 0)
        XCTAssertEqual(cursor.shapePath.boundingBoxOfPath, CGRect(
            x: -1, y: 0, width: 2, height: 1))
    }

    func testRejectsTruncatedXCursorPayload() {
        let rect = FramebufferRect(
            x: 0, y: 0, width: 8, height: 1, encoding: .xCursor)
        XCTAssertNil(RemoteCursorDecoder.decode(
            rect: rect,
            data: Data([255, 255, 255, 0, 0, 0, 0x80]),
            pixelFormat: .bgra8888))
    }

    func testDecodesAndRecallsAppleAlphaCursor() throws {
        let renderer = FramebufferRenderer(
            framebuffer: Framebuffer(
                width: 2, height: 1, pixelFormat: .bgra8888),
            pixelFormat: .bgra8888)
        let rect = FramebufferRect(
            x: 1, y: 0, width: 2, height: 1,
            encoding: .unknown(1104))
        // Inflates to two BGRA pixels followed by their alpha plane. Only the
        // first pixel is visible. The first UInt32 is Apple's cache ID.
        let compressed = Data([
            120, 156, 99, 96, 248, 207, 0, 65, 0, 14, 251, 2, 254,
        ])
        var definition = Data([0, 0, 0, 7, 0, 0, 0, 13])
        definition.append(compressed)

        let first = renderer.applyBatch([(rect, definition)], snapshot: false)
        guard case .shape(let cursor)? = first.cursorUpdate else {
            return XCTFail("Expected an Apple cursor shape")
        }
        XCTAssertEqual(cursor.hotspotX, 1)
        XCTAssertEqual(cursor.hotspotY, 0)
        XCTAssertEqual(cursor.shapePath.boundingBoxOfPath, CGRect(
            x: -1, y: 0, width: 1, height: 1))

        let reference = Data([0, 0, 0, 7, 0, 0, 0, 0])
        let recalled = renderer.applyBatch([(rect, reference)], snapshot: false)
        guard case .shape(let cached)? = recalled.cursorUpdate else {
            return XCTFail("Expected the cached Apple cursor shape")
        }
        XCTAssertTrue(cached.image === cursor.image)
    }

    func testRejectsTruncatedAppleAlphaCursor() {
        let rect = FramebufferRect(
            x: 0, y: 0, width: 1, height: 1,
            encoding: .unknown(1104))
        XCTAssertNil(RemoteCursorDecoder.decodeAppleCursorRecord(
            rect: rect,
            data: Data([0, 0, 0, 1, 0, 0, 0, 5, 120])))
    }
}

final class StandardFramebufferPipelineTests: XCTestCase {

    func testSameSizeFramebufferResizePreservesPixels() {
        let framebuffer = Framebuffer(
            width: 2, height: 1, pixelFormat: .bgra8888)
        let pixels = Data([
            0x10, 0x20, 0x30, 0xff,
            0x40, 0x50, 0x60, 0xff,
        ])
        framebuffer.update(x: 0, y: 0, width: 2, height: 1, data: pixels)

        framebuffer.resize(width: 2, height: 1)

        XCTAssertEqual(
            framebuffer.getPixels(x: 0, y: 0, width: 2, height: 1),
            pixels)
    }
    func testPortableEncodingsRemainPixelBearingForPresentation() {
        let pixelEncodings: [Encoding] = [
            .raw, .tight, .zlib, .zrle, .copyRect,
        ]
        for encoding in pixelEncodings {
            let rect = FramebufferRect(
                x: 0, y: 0, width: 8, height: 8,
                encoding: encoding)
            XCTAssertTrue(
                StandardFramebufferPresentationPolicy
                    .carriesFramebufferPixels([(rect, Data())]),
                "Expected \(encoding) to schedule framebuffer presentation")
        }

        let cursor = FramebufferRect(
            x: 0, y: 0, width: 8, height: 8, encoding: .cursor)
        XCTAssertFalse(
            StandardFramebufferPresentationPolicy
                .carriesFramebufferPixels([(cursor, Data())]))
    }

    func testInitialDCTPresentationWaitsForCompleteBaseCoverage() {
        var tracker = StandardInitialFramePresentationTracker()
        let control = dctRect(
            x: 0, y: 0, width: 0, height: 0, type: 2)
        XCTAssertFalse(tracker.ingest(
            [control], framebufferWidth: 16, framebufferHeight: 8))
        XCTAssertTrue(tracker.suppressesPresentation)

        XCTAssertFalse(tracker.ingest([
            dctRect(x: 0, y: 0, width: 8, height: 8, type: 0),
        ], framebufferWidth: 16, framebufferHeight: 8))
        XCTAssertEqual(tracker.uncoveredRegions, [
            CGRect(x: 8, y: 0, width: 8, height: 8),
        ])

        XCTAssertTrue(tracker.ingest([
            dctRect(x: 8, y: 0, width: 8, height: 8, type: 0),
        ], framebufferWidth: 16, framebufferHeight: 8))
        XCTAssertFalse(tracker.suppressesPresentation)
    }

    func testInitialFullDCTBasePresentsWithoutExtraDelay() {
        var tracker = StandardInitialFramePresentationTracker()
        XCTAssertTrue(tracker.ingest([
            dctRect(x: 0, y: 0, width: 16, height: 8, type: 0),
        ], framebufferWidth: 16, framebufferHeight: 8))
        XCTAssertFalse(tracker.suppressesPresentation)
    }

    func testReplacementConnectionStartsWithFreshDCTCoverage() {
        var tracker = StandardInitialFramePresentationTracker()
        XCTAssertTrue(tracker.ingest([
            dctRect(x: 0, y: 0, width: 16, height: 8, type: 0),
        ], framebufferWidth: 16, framebufferHeight: 8))

        tracker.reset()

        XCTAssertFalse(tracker.ingest([
            dctRect(x: 0, y: 0, width: 0, height: 0, type: 2),
            dctRect(x: 0, y: 0, width: 8, height: 8, type: 0),
        ], framebufferWidth: 16, framebufferHeight: 8))
        XCTAssertTrue(tracker.suppressesPresentation)
        XCTAssertEqual(tracker.uncoveredRegions, [
            CGRect(x: 8, y: 0, width: 8, height: 8),
        ])
    }

    func testDCTRefinementDoesNotClaimMissingInitialCoverage() {
        var tracker = StandardInitialFramePresentationTracker()
        XCTAssertFalse(tracker.ingest([
            dctRect(x: 0, y: 0, width: 16, height: 8, type: 2),
            dctRect(x: 0, y: 0, width: 16, height: 8, type: 1),
        ], framebufferWidth: 16, framebufferHeight: 8))
        XCTAssertEqual(tracker.uncoveredRegions, [
            CGRect(x: 0, y: 0, width: 16, height: 8),
        ])
    }

    func testPortableInitialRectangleDoesNotEnterDCTPresentationGate() {
        for encoding in [Encoding.raw, .tight, .zlib, .zrle, .copyRect] {
            var tracker = StandardInitialFramePresentationTracker()
            let rect = FramebufferRect(
                x: 0, y: 0, width: 8, height: 8,
                encoding: encoding)
            XCTAssertTrue(tracker.ingest(
                [(rect, Data())],
                framebufferWidth: 16,
                framebufferHeight: 8),
                "Portable \(encoding) must preserve immediate presentation")
            XCTAssertFalse(tracker.suppressesPresentation)
        }
    }

    func testProgressiveDCTPublishesEachDecodedRectangleDirectly() throws {
        let framebuffer = Framebuffer(
            width: 8, height: 8, pixelFormat: .bgra8888)
        let renderer = FramebufferRenderer(
            framebuffer: framebuffer, pixelFormat: .bgra8888)
        let rect = FramebufferRect(
            x: 0, y: 0, width: 8, height: 8,
            encoding: .appleMultiVariantScreenshare)

        // Type 0 writes directly to the presented framebuffer.
        let whiteBase = Data([
            0, 0, 0, 8, 0, 15, 25, 0, 0, 7, 0, 0,
        ])
        XCTAssertTrue(renderer.applyBatch(
            [(rect, whiteBase)], snapshot: false).issues.isEmpty)
        XCTAssertEqual(snapshotPixel(renderer, x: 0, y: 0), [255, 255, 255, 255])

        // A later type-0 base replaces the same region immediately.
        let blackBase = Data([
            0, 0, 0, 16, 0, 15, 25, 0, 0, 7, 0x30,
            0, 0, 0, 0, 0, 0, 0, 0, 0,
        ])
        XCTAssertTrue(renderer.applyBatch(
            [(rect, blackBase)], snapshot: false).issues.isEmpty)
        XCTAssertEqual(snapshotPixel(renderer, x: 0, y: 0), [0, 0, 0, 0])

        // Type 1 also writes directly; command zero leaves the base unchanged.
        let completion = Data([0, 0, 0, 4, 1, 0, 0, 0])
        XCTAssertTrue(renderer.applyBatch(
            [(rect, completion)], snapshot: false).issues.isEmpty)
        XCTAssertEqual(snapshotPixel(renderer, x: 0, y: 0), [0, 0, 0, 0])
    }

    func testAppleDCTBaseWaitsForEveryRefinementBand() {
        var tracker = AppleDCTRefinementTracker()
        XCTAssertTrue(tracker.ingest([
            dctRect(x: 752, y: 320, width: 3136, height: 2000, type: 0),
        ]))

        for y in stride(from: 320, to: 2240, by: 160) {
            XCTAssertTrue(tracker.ingest([
                dctRect(x: 752, y: y, width: 3136, height: 160, type: 1),
            ]))
        }
        XCTAssertFalse(tracker.ingest([
            dctRect(x: 752, y: 2240, width: 3136, height: 80, type: 1),
        ]))
    }

    func testPortableRectangleCompletesPendingDCTRegion() {
        var tracker = AppleDCTRefinementTracker()
        XCTAssertTrue(tracker.ingest([
            dctRect(x: 0, y: 0, width: 16, height: 16, type: 0),
        ]))
        let raw = FramebufferRect(
            x: 0, y: 0, width: 16, height: 16, encoding: .raw)
        XCTAssertFalse(tracker.ingest([(raw, Data())]))
    }

    func testNewOverlappingBaseReplacesOlderPendingRegion() {
        var tracker = AppleDCTRefinementTracker()
        XCTAssertTrue(tracker.ingest([
            dctRect(x: 0, y: 0, width: 16, height: 16, type: 0),
            dctRect(x: 0, y: 0, width: 16, height: 16, type: 0),
        ]))
        XCTAssertEqual(tracker.uncoveredRegions, [
            CGRect(x: 0, y: 0, width: 16, height: 16),
        ])
        XCTAssertFalse(tracker.ingest([
            dctRect(x: 0, y: 0, width: 16, height: 16, type: 1),
        ]))
    }

    func testProductionRendererPreservesZRLEStreamAcrossPresentedBatches() {
        let framebuffer = Framebuffer(
            width: 2,
            height: 1,
            pixelFormat: .bgra8888)
        let renderer = FramebufferRenderer(
            framebuffer: framebuffer,
            pixelFormat: .bgra8888)
        let chunks = [
            Data([
                0x78, 0x9c, 0x62, 0x64, 0x60, 0xf8,
                0x0f, 0x00, 0x00, 0x00, 0xff, 0xff,
            ]),
            Data([
                0x62, 0xfc, 0xcf, 0xc0, 0x00,
                0x00, 0x00, 0x00, 0xff, 0xff,
            ]),
        ]

        for (x, chunk) in chunks.enumerated() {
            let rect = FramebufferRect(
                x: UInt16(x), y: 0, width: 1, height: 1, encoding: .zrle)
            let result = renderer.applyBatch([(rect, wirePayload(chunk))])
            XCTAssertTrue(result.issues.isEmpty)
        }

        XCTAssertEqual(
            framebuffer.getPixels(x: 0, y: 0, width: 2, height: 1),
            Data([
                0x00, 0x00, 0xff, 0xff,
                0xff, 0x00, 0x00, 0xff,
            ]))
    }

    private func snapshotPixel(
        _ renderer: FramebufferRenderer,
        x: Int,
        y: Int
    ) -> [UInt8] {
        guard let image = renderer.snapshot(),
              let data = image.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { return [] }
        let offset = y * image.bytesPerRow + x * 4
        return Array(UnsafeBufferPointer(start: bytes + offset, count: 4))
    }

    func testAppleControlRectanglesDoNotBecomeRenderingIssues() {
        let renderer = FramebufferRenderer(
            framebuffer: Framebuffer(
                width: 1, height: 1, pixelFormat: .bgra8888),
            pixelFormat: .bgra8888)
        let rectangles = [1100, 1101, 1104, 1105].map { value in
            (FramebufferRect(
                x: 0, y: 0, width: 0, height: 0,
                encoding: .unknown(Int32(value))), Data())
        }

        XCTAssertTrue(renderer.applyBatch(rectangles, snapshot: false).issues.isEmpty)
    }

    private func wirePayload(_ compressed: Data) -> Data {
        let count = UInt32(compressed.count)
        var result = Data([
            UInt8((count >> 24) & 0xff),
            UInt8((count >> 16) & 0xff),
            UInt8((count >> 8) & 0xff),
            UInt8(count & 0xff),
        ])
        result.append(compressed)
        return result
    }

    private func dctRect(
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        type: UInt8
    ) -> (FramebufferRect, Data) {
        (FramebufferRect(
            x: UInt16(x), y: UInt16(y),
            width: UInt16(width), height: UInt16(height),
            encoding: .appleMultiVariantScreenshare),
         Data([0, 0, 0, 1, type]))
    }
}

// MARK: - VNCCredentials Tests

final class VNCCredentialsTests: XCTestCase {

    func testInitWithDefaultPort() {
        let creds = VNCCredentials(host: "192.168.1.1", password: "secret")
        XCTAssertEqual(creds.host, "192.168.1.1")
        XCTAssertEqual(creds.port, 5900)
        XCTAssertEqual(creds.password, "secret")
        XCTAssertNil(creds.username)
    }

    func testInitWithCustomPort() {
        let creds = VNCCredentials(host: "myserver.local", port: 5901, password: "pass")
        XCTAssertEqual(creds.host, "myserver.local")
        XCTAssertEqual(creds.port, 5901)
        XCTAssertEqual(creds.password, "pass")
        XCTAssertNil(creds.username)
    }

    func testInitWithUsername() {
        let creds = VNCCredentials(host: "10.0.0.1", port: 5900, password: "pass123", username: "admin")
        XCTAssertEqual(creds.host, "10.0.0.1")
        XCTAssertEqual(creds.port, 5900)
        XCTAssertEqual(creds.password, "pass123")
        XCTAssertEqual(creds.username, "admin")
    }

    func testInitWithAllCustomValues() {
        let creds = VNCCredentials(host: "vnc.example.com", port: 9999, password: "p@ssw0rd!", username: "user1")
        XCTAssertEqual(creds.host, "vnc.example.com")
        XCTAssertEqual(creds.port, 9999)
        XCTAssertEqual(creds.password, "p@ssw0rd!")
        XCTAssertEqual(creds.username, "user1")
    }

    func testEmptyHostAndPassword() {
        let creds = VNCCredentials(host: "", password: "")
        XCTAssertEqual(creds.host, "")
        XCTAssertEqual(creds.password, "")
    }

    func testLastConnectionRecordRoundTripsAllCredentialFields() throws {
        let credentials = VNCCredentials(
            host: "studio-mac.local",
            port: 5907,
            password: "correct horse battery staple",
            username: "kit")
        let encoded = try JSONEncoder().encode(
            LastConnectionRecord(credentials: credentials))
        let restored = try JSONDecoder().decode(
            LastConnectionRecord.self,
            from: encoded).credentials
        XCTAssertEqual(restored, credentials)
    }
}

// MARK: - VNCConfiguration Tests

final class VNCConfigurationTests: XCTestCase {

    func testDefaultValues() {
        let config = VNCConfiguration()
        XCTAssertNil(config.preferredPixelFormat)
        XCTAssertEqual(config.preferredEncodings, [.copyRect, .raw])
        XCTAssertTrue(config.enableHighPerformanceMode)
        XCTAssertEqual(config.videoQualityMode, .adaptive)
        XCTAssertEqual(config.displaySizingMode, .matchClient)
        XCTAssertEqual(config.displayMode, .oneDisplay)
        XCTAssertEqual(config.displayCount, 1)
        XCTAssertTrue(config.enableRemoteAudio)
        XCTAssertFalse(config.promptForLoginPasswordAtLoginWindow)
        XCTAssertEqual(config.targetFrameRate, 60)
        XCTAssertFalse(config.enableProtocolTrace)
        XCTAssertTrue(config.reconnectionPolicy.isEnabled)
        XCTAssertEqual(config.reconnectionPolicy.maximumAttempts, 8)
    }

    func testCustomValues() {
        let config = VNCConfiguration(
            preferredPixelFormat: .bgra8888,
            preferredEncodings: [.raw, .zrle],
            enableHighPerformanceMode: false,
            displaySizingMode: .remoteDisplay,
            displayCount: 2,
            enableRemoteAudio: false,
            promptForLoginPasswordAtLoginWindow: true,
            targetFrameRate: 60,
            enableProtocolTrace: true
        )
        XCTAssertEqual(config.preferredPixelFormat, .bgra8888)
        XCTAssertEqual(config.preferredEncodings, [.raw, .zrle])
        XCTAssertFalse(config.enableHighPerformanceMode)
        XCTAssertEqual(config.displaySizingMode, .remoteDisplay)
        XCTAssertEqual(config.displayMode, .allDisplaysCombined)
        XCTAssertEqual(config.displayCount, 2)
        XCTAssertFalse(config.enableRemoteAudio)
        XCTAssertTrue(config.promptForLoginPasswordAtLoginWindow)
        XCTAssertEqual(config.targetFrameRate, 60)
        XCTAssertTrue(config.enableProtocolTrace)
    }

    func testStandardModesRejectMatchClientSizing() {
        for qualityMode in [
            VNCConfiguration.VideoQualityMode.standard,
            .fullQuality,
        ] {
            var config = VNCConfiguration(
                videoQualityMode: qualityMode,
                displaySizingMode: .matchClient)
            XCTAssertEqual(config.displaySizingMode, .remoteDisplay)

            config.displaySizingMode = .matchClient
            XCTAssertEqual(config.displaySizingMode, .remoteDisplay)

            config.displayMode = .twoVirtualDisplays
            XCTAssertEqual(config.displayMode, .oneDisplay)
            XCTAssertEqual(config.displaySizingMode, .remoteDisplay)

            let virtualDisplayConfig = VNCConfiguration(
                videoQualityMode: qualityMode,
                displayMode: .twoVirtualDisplays)
            XCTAssertEqual(virtualDisplayConfig.displayMode, .oneDisplay)
            XCTAssertEqual(virtualDisplayConfig.displaySizingMode, .remoteDisplay)
        }

        var config = VNCConfiguration(displaySizingMode: .matchClient)
        config.videoQualityMode = .standard
        XCTAssertEqual(config.displaySizingMode, .remoteDisplay)
    }

    func testRemoteAudioIsEffectiveOnlyInHighPerformanceMatchClientMode() {
        var config = VNCConfiguration(
            videoQualityMode: .adaptive,
            displaySizingMode: .matchClient,
            enableRemoteAudio: true)
        XCTAssertTrue(config.supportsRemoteAudio)
        XCTAssertTrue(config.effectiveRemoteAudioPlaybackEnabled)

        config.displaySizingMode = .remoteDisplay
        XCTAssertFalse(config.supportsRemoteAudio)
        XCTAssertFalse(config.effectiveRemoteAudioPlaybackEnabled)

        config.videoQualityMode = .standard
        config.enableRemoteAudio = true
        XCTAssertFalse(config.supportsRemoteAudio)
        XCTAssertFalse(config.effectiveRemoteAudioPlaybackEnabled)
    }

    func testDisplayCountClamping() {
        XCTAssertEqual(VNCConfiguration(displayCount: 0).displayCount, 1)
        XCTAssertEqual(VNCConfiguration(displayCount: 3).displayCount, 2)

        var config = VNCConfiguration()
        config.displayCount = 99
        XCTAssertEqual(config.displayCount, 2)
        config.displayCount = -1
        XCTAssertEqual(config.displayCount, 1)
    }

    func testCompatibilityDisplayCountTwoAlwaysMeansCombined() {
        var config = VNCConfiguration(
            displaySizingMode: .matchClient,
            displayCount: 2)
        XCTAssertEqual(config.displayMode, .allDisplaysCombined)
        XCTAssertEqual(config.displaySizingMode, .remoteDisplay)

        config.displaySizingMode = .matchClient
        XCTAssertEqual(config.displayMode, .oneDisplay)
        XCTAssertEqual(config.displayCount, 1)

        config.displayCount = 2
        XCTAssertEqual(config.displayMode, .allDisplaysCombined)
        XCTAssertEqual(config.displaySizingMode, .remoteDisplay)
    }

    func testExplicitDisplayModeTakesPrecedenceOverCompatibilityCount() {
        let config = VNCConfiguration(
            displaySizingMode: .remoteDisplay,
            displayCount: 1,
            displayMode: .allDisplaysCombined)
        XCTAssertEqual(config.displayMode, .allDisplaysCombined)
        XCTAssertEqual(config.displayCount, 2)
    }

    func testTargetFrameRateClamping() {
        // Below minimum
        let low = VNCConfiguration(targetFrameRate: 0)
        XCTAssertEqual(low.targetFrameRate, 1)

        let negative = VNCConfiguration(targetFrameRate: -10)
        XCTAssertEqual(negative.targetFrameRate, 1)

        // Above maximum
        let high = VNCConfiguration(targetFrameRate: 200)
        XCTAssertEqual(high.targetFrameRate, 120)

        // Within range
        let normal = VNCConfiguration(targetFrameRate: 60)
        XCTAssertEqual(normal.targetFrameRate, 60)

        // At boundaries
        let atMin = VNCConfiguration(targetFrameRate: 1)
        XCTAssertEqual(atMin.targetFrameRate, 1)
        let atMax = VNCConfiguration(targetFrameRate: 120)
        XCTAssertEqual(atMax.targetFrameRate, 120)
    }

    func testEffectiveEncodingsIncludesHighPerformance() {
        let config = VNCConfiguration(
            preferredEncodings: [.zrle, .raw],
            enableHighPerformanceMode: true
        )
        let effective = config.effectiveEncodings
        XCTAssertTrue(effective.contains(.appleH264))
        XCTAssertTrue(effective.contains(.appleMultiVariantScreenshare))
        // Never advertise SubZlib: no rectangle parser can frame its payload,
        // so a server that takes us up on it desynchronizes the byte stream
        // and the session drops.
        XCTAssertFalse(effective.contains(.appleSubZlibThousands))
        XCTAssertTrue(effective.contains(.mediaStreamOffer))
        XCTAssertTrue(effective.contains(.mediaStreamAnswer))
        XCTAssertTrue(effective.contains(.encryptionInfo))
        XCTAssertTrue(effective.contains(.serverDisplayInfo))
        XCTAssertTrue(effective.contains(.desktopSize))
        XCTAssertTrue(effective.contains(.extendedDesktopSize))
        XCTAssertTrue(effective.contains(.unknown(1104)))
        XCTAssertTrue(effective.contains(.unknown(1100)))
        XCTAssertTrue(effective.contains(.cursor))
        XCTAssertTrue(effective.contains(.xCursor))
        XCTAssertTrue(effective.contains(.raw))
    }

    /// Server-rendered mode has to suppress every cursor pseudo-encoding on
    /// every path: Standard mode front-loads 1100 and 1104 with its own
    /// priorities, and `preferredEncodings` is caller-supplied.
    func testServerCursorRenderingDropsCursorEncodingsInEveryQualityMode() {
        for mode in VNCConfiguration.VideoQualityMode.allCases {
            let config = VNCConfiguration(
                preferredEncodings: [.zrle, .raw, .cursor, .xCursor],
                videoQualityMode: mode,
                cursorRendering: .server)
            let effective = config.effectiveEncodings

            XCTAssertFalse(effective.contains(.unknown(1104)), "\(mode)")
            XCTAssertFalse(effective.contains(.unknown(1100)), "\(mode)")
            XCTAssertFalse(effective.contains(.cursor), "\(mode)")
            XCTAssertFalse(effective.contains(.xCursor), "\(mode)")
            // DisplayInfo2 carries display layout and Login Window state, not
            // the pointer, so it survives.
            XCTAssertTrue(effective.contains(.unknown(1105)), "\(mode)")
            XCTAssertTrue(effective.contains(.raw), "\(mode)")
        }
    }

    /// The default must stay byte-for-byte what shipped before the option.
    ///
    /// These lists are the ones `effectiveEncodings` produced before the
    /// cursor rendering option existed, transcribed literally. Comparing the
    /// default against an explicitly `.client` configuration would only prove
    /// the two agree with each other, and would keep passing if both drifted.
    func testClientCursorRenderingIsTheDefaultAndKeepsCursorEncodings() {
        for mode in VNCConfiguration.VideoQualityMode.allCases {
            let shipped: [Encoding]
            switch mode {
            case .adaptive:
                shipped = [
                    .appleH264, .appleMultiVariantScreenshare, .zlib, .zrle,
                    .raw, .encryptionInfo, .serverDisplayInfo,
                    .mediaStreamOffer, .mediaStreamAnswer,
                    .desktopSize, .extendedDesktopSize,
                    .unknown(1105), .unknown(1104), .unknown(1100),
                    .cursor, .xCursor,
                ]
            case .standard:
                shipped = [
                    .appleMultiVariantScreenshare, .tight, .lastRect,
                    .zrle, .zlib, .copyRect,
                    .unknown(1105), .unknown(1101), .unknown(1100),
                    .unknown(1104), .raw, .unknown(-23),
                    .serverDisplayInfo, .desktopSize, .extendedDesktopSize,
                    .cursor, .xCursor,
                ]
            case .fullQuality:
                shipped = [
                    .copyRect, .zlib, .zrle, .raw,
                    .desktopSize, .extendedDesktopSize,
                    .unknown(1105), .unknown(1104), .unknown(1100),
                    .cursor, .xCursor,
                ]
            }

            let explicit = VNCConfiguration(
                preferredEncodings: [.zrle, .raw],
                videoQualityMode: mode,
                cursorRendering: .client)
            let byDefault = VNCConfiguration(
                preferredEncodings: [.zrle, .raw],
                videoQualityMode: mode)

            XCTAssertEqual(byDefault.cursorRendering, .client, "\(mode)")
            XCTAssertEqual(explicit.cursorRendering, .client, "\(mode)")
            XCTAssertEqual(byDefault.effectiveEncodings, shipped, "\(mode)")
            XCTAssertEqual(explicit.effectiveEncodings, shipped, "\(mode)")
        }
    }

    func testEffectiveEncodingsWithoutHighPerformance() {
        let config = VNCConfiguration(
            preferredEncodings: [.zrle, .raw],
            enableHighPerformanceMode: false
        )
        let effective = config.effectiveEncodings
        XCTAssertFalse(effective.contains(.appleH264))
        XCTAssertFalse(effective.contains(.appleMultiVariantScreenshare))
        XCTAssertFalse(effective.contains(.appleSubZlibThousands))
        XCTAssertFalse(effective.contains(.mediaStreamOffer))
        XCTAssertFalse(effective.contains(.mediaStreamAnswer))
        XCTAssertTrue(effective.contains(.desktopSize))
        XCTAssertTrue(effective.contains(.extendedDesktopSize))
        XCTAssertTrue(effective.contains(.unknown(1104)))
        XCTAssertTrue(effective.contains(.unknown(1100)))
        XCTAssertTrue(effective.contains(.cursor))
        XCTAssertTrue(effective.contains(.xCursor))
        XCTAssertTrue(effective.contains(.raw))
    }

    /// Advertising a pixel-carrying encoding that no rectangle parser can
    /// frame desynchronizes the byte stream the first time a server uses it,
    /// which surfaces as a mid-session drop and reconnect. Every advertised
    /// content encoding must therefore be one the parsers consume.
    ///
    /// Keep this list in step with the `switch rect.encoding` in
    /// `TransportSession.handleFramebufferUpdate` and its encrypted twin
    /// `drainAppleDecryptedFramebufferUpdate`.
    func testAdvertisedContentEncodingsAreAllParseable() {
        // Deliberately an independent literal rather than a re-read of
        // `hasKnownFramebufferFraming`: this is what catches an encoding being
        // declared parseable without a parser actually existing.
        let parseable: Set<Encoding> = [
            .raw, .copyRect, .zlib, .zrle, .tight,
            .appleMultiVariantScreenshare,
            // Classified as content, but its pixels ride the UDP media path;
            // the RFB channel only ever carries its marker rectangle.
            .appleH264,
        ]

        for mode in VNCConfiguration.VideoQualityMode.allCases {
            let config = VNCConfiguration(
                enableHighPerformanceMode: true,
                videoQualityMode: mode)
            let unparseable = config.effectiveEncodings
                .filter { $0.isFramebufferContent && !parseable.contains($0) }
            XCTAssertTrue(
                unparseable.isEmpty,
                "\(mode.rawValue) advertises content encodings with no parser: "
                    + unparseable.map { $0.displayName }.joined(separator: ", "))
        }

        let allContent: [Encoding] = [
            .raw, .copyRect, .rre, .hextile, .zlib, .tight, .zlibhex, .zrle,
            .appleJPEG, .appleMultiVariantScreenshare, .appleSubZlibThousands,
            .appleH264,
        ]
        for encoding in allContent where !parseable.contains(encoding) {
            XCTAssertTrue(
                encoding.isUnframeableContent,
                "\(encoding.displayName) has no parser but is not flagged unframeable")
        }
    }

    /// A caller can supply arbitrary `preferredEncodings`, so filtering only
    /// the lists `effectiveEncodings` injects would still let a host advertise
    /// an encoding the parsers cannot frame.
    func testCallerSuppliedUnparseableEncodingsAreFilteredOut() {
        for mode in VNCConfiguration.VideoQualityMode.allCases {
            let config = VNCConfiguration(
                preferredEncodings: [
                    .appleSubZlibThousands, .appleJPEG, .rre, .hextile,
                    .zlibhex, .zrle, .raw,
                ],
                enableHighPerformanceMode: true,
                videoQualityMode: mode)
            let effective = config.effectiveEncodings
            XCTAssertFalse(effective.contains(.appleSubZlibThousands), mode.rawValue)
            XCTAssertFalse(effective.contains(.appleJPEG), mode.rawValue)
            XCTAssertFalse(effective.contains(.rre), mode.rawValue)
            XCTAssertFalse(effective.contains(.hextile), mode.rawValue)
            XCTAssertFalse(effective.contains(.zlibhex), mode.rawValue)
            // The parseable ones survive.
            XCTAssertTrue(effective.contains(.zrle), mode.rawValue)
            XCTAssertTrue(effective.contains(.raw), mode.rawValue)
        }
    }

    func testFullQualityUsesNativeLosslessEncodingProfile() {
        let config = VNCConfiguration(videoQualityMode: .fullQuality)
        let effective = config.effectiveEncodings
        XCTAssertFalse(effective.contains(.appleH264))
        XCTAssertFalse(effective.contains(.appleMultiVariantScreenshare))
        XCTAssertFalse(effective.contains(.mediaStreamOffer))
        XCTAssertTrue(effective.contains(.zlib))
        XCTAssertTrue(effective.contains(.zrle))
        XCTAssertTrue(effective.contains(.unknown(1105)))
        XCTAssertTrue(effective.contains(.unknown(1104)))
        XCTAssertTrue(effective.contains(.unknown(1100)))
    }

    func testStandardUsesAppleDCTWithPortableFallbackProfile() {
        let config = VNCConfiguration(videoQualityMode: .standard)
        let effective = config.effectiveEncodings
        XCTAssertFalse(effective.contains(.appleH264))
        XCTAssertTrue(effective.contains(.appleMultiVariantScreenshare))
        XCTAssertFalse(effective.contains(.mediaStreamOffer))
        XCTAssertEqual(
            Array(effective.prefix(12)),
            [
                .appleMultiVariantScreenshare, .tight, .lastRect,
                .zrle, .zlib, .copyRect,
                .unknown(1105), .unknown(1101), .unknown(1100), .unknown(1104),
                .raw, .unknown(-23),
            ])
    }

    func testStandardDefaultsToFullColor() {
        let config = VNCConfiguration(videoQualityMode: .standard)
        XCTAssertEqual(config.effectivePixelFormat, .bgra8888)
    }

    func testStandardAllowsExplicitThousandsOfColorsOverride() {
        let config = VNCConfiguration(
            preferredPixelFormat: .rgb555,
            videoQualityMode: .standard)
        XCTAssertEqual(config.effectivePixelFormat, .rgb555)
    }

    func testQualityModesExposeGUILabels() {
        XCTAssertEqual(
            VNCConfiguration.VideoQualityMode.allCases,
            [.adaptive, .standard, .fullQuality])
        XCTAssertEqual(VNCConfiguration.VideoQualityMode.adaptive.title, "High Performance")
        XCTAssertEqual(VNCConfiguration.VideoQualityMode.standard.title, "Standard")
        XCTAssertEqual(VNCConfiguration.VideoQualityMode.fullQuality.title, "Full Quality")
    }

    func testEffectiveEncodingsAlwaysIncludesRaw() {
        let config = VNCConfiguration(preferredEncodings: [.zrle, .tight])
        let effective = config.effectiveEncodings
        XCTAssertTrue(effective.contains(.raw))
    }

    func testEffectiveEncodingsDoesNotDuplicateRaw() {
        let config = VNCConfiguration(preferredEncodings: [.raw, .zrle])
        let effective = config.effectiveEncodings
        let rawCount = effective.filter { $0 == .raw }.count
        XCTAssertEqual(rawCount, 1)
    }

    func testEffectiveEncodingsDoesNotDuplicateDesktopSize() {
        let config = VNCConfiguration(
            preferredEncodings: [.desktopSize, .extendedDesktopSize, .raw])
        let effective = config.effectiveEncodings
        XCTAssertEqual(effective.filter { $0 == .desktopSize }.count, 1)
        XCTAssertEqual(effective.filter { $0 == .extendedDesktopSize }.count, 1)
    }

    func testDisplaySizingModesExposeGUIChoices() {
        XCTAssertEqual(
            VNCConfiguration.DisplaySizingMode.allCases,
            [.remoteDisplay, .matchClient])
        XCTAssertEqual(
            VNCConfiguration.DisplaySizingMode.matchClient.title,
            "Match Client")
    }
}

final class AppleLoginPromptTransitionTrackerTests: XCTestCase {
    func testPromptsOnlyWhenEnteringEnabledLoginState() {
        var tracker = AppleLoginPromptTransitionTracker()

        XCTAssertFalse(tracker.update(
            isLoginActive: false,
            promptEnabled: true,
            canSendPassword: true))
        XCTAssertTrue(tracker.update(
            isLoginActive: true,
            promptEnabled: true,
            canSendPassword: true))
        XCTAssertFalse(tracker.update(
            isLoginActive: true,
            promptEnabled: true,
            canSendPassword: true))
        XCTAssertFalse(tracker.update(
            isLoginActive: false,
            promptEnabled: true,
            canSendPassword: true))
        XCTAssertTrue(tracker.update(
            isLoginActive: true,
            promptEnabled: true,
            canSendPassword: true))
    }

    func testDisabledOrUnavailablePasswordSuppressesEntryPrompt() {
        var disabled = AppleLoginPromptTransitionTracker()
        XCTAssertFalse(disabled.update(
            isLoginActive: true,
            promptEnabled: false,
            canSendPassword: true))

        var missingPassword = AppleLoginPromptTransitionTracker()
        XCTAssertFalse(missingPassword.update(
            isLoginActive: true,
            promptEnabled: true,
            canSendPassword: false))
    }

    func testResetAllowsAConnectedReplacementToPrompt() {
        var tracker = AppleLoginPromptTransitionTracker()
        XCTAssertTrue(tracker.update(
            isLoginActive: true,
            promptEnabled: true,
            canSendPassword: true))
        tracker.reset()
        XCTAssertTrue(tracker.update(
            isLoginActive: true,
            promptEnabled: true,
            canSendPassword: true))
    }
}

final class DisplayPresentationTests: XCTestCase {
    private let displays = [
        CGRect(x: -1920, y: 0, width: 1920, height: 1080),
        CGRect(x: 0, y: 0, width: 2560, height: 1440),
    ]

    func testOneDisplayCropsStandardFramebufferToFirstScreen() {
        XCTAssertEqual(
            normalizedSelectedDisplayRegion(displays, displayCount: 1),
            CGRect(x: 0, y: 0, width: 1920, height: 1080))
    }

    func testTwoDisplaysPresentCompleteStandardFramebuffer() {
        XCTAssertEqual(
            normalizedSelectedDisplayRegion(displays, displayCount: 2),
            CGRect(x: 0, y: 0, width: 4480, height: 1440))
    }

    @MainActor
    func testHighPerformanceInputDoesNotAddUnselectedMonitorOffset() async throws {
        for origin in [CGPoint(x: 1920, y: 0), CGPoint(x: 0, y: 1080)] {
            let session = VNCSession(configuration: VNCConfiguration(
                videoQualityMode: .adaptive,
                displaySizingMode: .remoteDisplay))
            await session.updateRemoteDisplayRegions([
                AppleDisplayInfo(
                    displayIndex: 1, originX: Int32(origin.x), originY: Int32(origin.y),
                    width: 2560, height: 1440, flags: 0),
                AppleDisplayInfo(
                    displayIndex: 2, originX: 0, originY: 0,
                    width: 1920, height: 1080, flags: 0),
            ])
            session.isHighPerformanceMode = true

            XCTAssertEqual(session.presentedVideoDisplayRegions.first?.origin, .zero)
            XCTAssertEqual(session.presentedInputOrigin, .zero)
            // A half-size viewport must still target framebuffer pixel (20, 12).
            let point = try XCTUnwrap(RemoteViewportState().framebufferPoint(
                for: CGPoint(x: 10, y: 6),
                viewSize: CGSize(width: 1280, height: 720),
                framebufferSize: session.presentedFramebufferSize))
            XCTAssertEqual(CGPoint(
                x: point.x + session.presentedInputOrigin.x,
                y: point.y + session.presentedInputOrigin.y), CGPoint(x: 20, y: 12))

            // Rendering/cropping metadata retains the physical desktop origin.
            XCTAssertEqual(session.presentedFramebufferRegion?.origin, origin)
            session.isHighPerformanceMode = false
            XCTAssertEqual(session.presentedInputOrigin, origin,
                "Fallback to Standard must restore the framebuffer crop offset")
        }
    }

    @MainActor
    func testHighPerformanceInputOriginForOtherDisplayModes() async {
        for mode in [VNCConfiguration.DisplayMode.oneDisplay, .allDisplaysCombined,
                     .twoVirtualDisplays] {
            let session = VNCSession(configuration: VNCConfiguration(
                videoQualityMode: .adaptive,
                displaySizingMode: mode == .twoVirtualDisplays ? .matchClient : .remoteDisplay,
                displayMode: mode))
            await session.updateRemoteDisplayRegions([
                AppleDisplayInfo(
                    displayIndex: 1, originX: 0, originY: 0,
                    width: 2560, height: 1440, flags: 0),
                AppleDisplayInfo(
                    displayIndex: 2, originX: 2560, originY: 0,
                    width: 1920, height: 1080, flags: 0),
            ])
            session.isHighPerformanceMode = true
            XCTAssertEqual(session.presentedInputOrigin, .zero)
        }
    }

    @MainActor
    func testMatchClientInputIgnoresPreviousPhysicalDisplayOrigin() async {
        for count in [1, 2] {
            let session = VNCSession(configuration: VNCConfiguration(
                videoQualityMode: .adaptive,
                displaySizingMode: .matchClient,
                displayMode: count == 1 ? .oneDisplay : .twoVirtualDisplays))
            await session.updateRemoteDisplayRegions([
                AppleDisplayInfo(
                    displayIndex: 1, originX: 1920, originY: 1080,
                    width: 2560, height: 1440, flags: 0),
                AppleDisplayInfo(
                    displayIndex: 2, originX: 0, originY: 0,
                    width: 1920, height: 1080, flags: 0),
            ])
            session.isHighPerformanceMode = true
            XCTAssertEqual(session.presentedInputOrigin, .zero)
            XCTAssertNil(session.presentedFramebufferRegion)
        }
    }
}

final class VNCReconnectionPolicyTests: XCTestCase {
    func testExponentialBackoffIsCapped() {
        let policy = VNCReconnectionPolicy(
            initialDelay: 1,
            maximumDelay: 10,
            multiplier: 2,
            jitter: 0)

        XCTAssertEqual(policy.delay(forAttempt: 1), 1)
        XCTAssertEqual(policy.delay(forAttempt: 2), 2)
        XCTAssertEqual(policy.delay(forAttempt: 4), 8)
        XCTAssertEqual(policy.delay(forAttempt: 8), 10)
    }

    func testJitterStaysWithinConfiguredBounds() {
        let policy = VNCReconnectionPolicy(
            initialDelay: 10,
            maximumDelay: 30,
            jitter: 0.2)

        XCTAssertEqual(policy.delay(forAttempt: 1, randomUnit: 0), 8)
        XCTAssertEqual(policy.delay(forAttempt: 1, randomUnit: 0.5), 10)
        XCTAssertEqual(policy.delay(forAttempt: 1, randomUnit: 1), 12)
    }
}

final class AppleAdaptiveDCTDecoderTests: XCTestCase {
    func testCommandRunLengthGrammar() throws {
        // 0 => 1, 1+0011 => 5, 1+1111+00000111 => 24.
        try Data([0x4f, 0xe0, 0xe0]).withUnsafeBytes { bytes in
            var reader = AppleAdaptiveDCTDecoder.BitReader(bytes)
            XCTAssertEqual(try reader.readCommandRunLength(), 1)
            XCTAssertEqual(try reader.readCommandRunLength(), 5)
            XCTAssertEqual(try reader.readCommandRunLength(), 24)
        }
    }

    func testExtendedCommandRunLengthUsesBase128Groups() throws {
        // Escape plus 0x81,0x01 encodes 17 + 1 + (1 << 7) = 146.
        try Data([0xfc, 0x08, 0x08]).withUnsafeBytes { bytes in
            var reader = AppleAdaptiveDCTDecoder.BitReader(bytes)
            XCTAssertEqual(try reader.readCommandRunLength(), 146)
        }
    }

    func testBitReaderRejectsTruncatedCommand() throws {
        try Data([0xf8]).withUnsafeBytes { bytes in
            var reader = AppleAdaptiveDCTDecoder.BitReader(bytes)
            XCTAssertThrowsError(try reader.readCommandRunLength())
        }
    }

    func testSignedDCRiceGrammar() throws {
        // q=0 zero: 00; q=0 +1: 010; q=0 -1: 011;
        // q=1 magnitude 3 negative: 10 11.
        try Data([0x13, 0xb0]).withUnsafeBytes { bytes in
            var reader = AppleAdaptiveDCTDecoder.BitReader(bytes)
            XCTAssertEqual(try reader.readSignedDCRice(), 0)
            XCTAssertEqual(try reader.readSignedDCRice(), 1)
            XCTAssertEqual(try reader.readSignedDCRice(), -1)
            XCTAssertEqual(try reader.readSignedDCRice(), -3)
        }
    }

    func testYCC20ExpandsSixBitChroma() throws {
        // Y=0xab, Cb=0x15, Cr=0x2a.
        try Data([0xab, 0x56, 0xa0]).withUnsafeBytes { bytes in
            var reader = AppleAdaptiveDCTDecoder.BitReader(bytes)
            let color = try reader.readYCC20()
            XCTAssertEqual(color.y, 0xab)
            XCTAssertEqual(color.cb, 0x54)
            XCTAssertEqual(color.cr, 0xa8)
        }
    }

    func testSmallCoefficientAndZeroRunGrammar() throws {
        // 10 => +amplitude; 11 => -amplitude; 00 => zero;
        // 01 0 => EOB.
        try Data([0xb1, 0x00]).withUnsafeBytes { bytes in
            var reader = AppleAdaptiveDCTDecoder.BitReader(bytes)
            XCTAssertEqual(try reader.readSmallCoefficient(at: 1, amplitude: 8).value, 8)
            XCTAssertEqual(try reader.readSmallCoefficient(at: 2, amplitude: 8).value, -8)
            XCTAssertNil(try reader.readSmallCoefficient(at: 3, amplitude: 8).value)
            XCTAssertEqual(
                try reader.readSmallCoefficient(at: 4, amplitude: 8).nextIndex,
                64)
        }
    }

    func testSmallCoefficientLongZeroRun() throws {
        // 01 1 11 enters the long form; 111 then 010 adds 6+7+2.
        try Data([0x7f, 0x40]).withUnsafeBytes { bytes in
            var reader = AppleAdaptiveDCTDecoder.BitReader(bytes)
            let result = try reader.readSmallCoefficient(at: 3, amplitude: 2)
            XCTAssertEqual(result.nextIndex, 18)
            XCTAssertNil(result.value)
        }
    }

    func testType2InstallsBothQuantizationTables() throws {
        let decoder = AppleAdaptiveDCTDecoder()
        let luma = Array(UInt8(0)..<64)
        let chroma = Array(UInt8(64)..<128)
        var payload = Data([0, 0, 0, 129, 2])
        payload.append(contentsOf: luma)
        payload.append(contentsOf: chroma)

        XCTAssertNil(try decoder.ingest(payload))
        XCTAssertEqual(decoder.lumaQuantization, luma.map(UInt16.init))
        XCTAssertEqual(decoder.chromaQuantization, chroma.map(UInt16.init))
    }

    func testCapturedType0HeaderSeparatesCommandAndDataStreams() throws {
        // Forty-byte interoperability fixture for encoding 1011.
        var payload = Data([0, 0, 0, 36, 0, 15, 25, 0, 0, 10])
        payload.append(contentsOf: [0x54, 0x54, 0x36, 0x80])
        payload.append(Data(repeating: 0xA5, count: 26))

        let image = try XCTUnwrap(AppleAdaptiveDCTDecoder().ingest(payload))
        XCTAssertEqual(image.field1, 15)
        XCTAssertEqual(image.field2, 25)
        XCTAssertEqual(image.commandBytes, Data([0x54, 0x54, 0x36, 0x80]))
        XCTAssertEqual(image.dataBytes.count, 26)
    }

    func testPreviousTileCommandRepeatsAcrossLocalRowBoundary() throws {
        // Reserved bit, command 0 for one white tile, then command 1 with a
        // run of three. The third repeated tile starts a new local row.
        var payload = Data([0, 0, 0, 9, 0, 15, 25, 0, 0, 8])
        payload.append(contentsOf: [0x01, 0x88, 0x00])
        let framebuffer = Framebuffer(
            width: 16, height: 16, pixelFormat: .bgra8888)
        let rect = FramebufferRect(
            x: 0, y: 0, width: 16, height: 16,
            encoding: .appleMultiVariantScreenshare)

        try AppleAdaptiveDCTDecoder().render(
            rect: rect, payload: payload, to: framebuffer)

        XCTAssertEqual(
            framebuffer.getPixels(x: 0, y: 0, width: 16, height: 16),
            Data(repeating: 0xff, count: 16 * 16 * 4))
    }

    func testPreviousTileAtPartialRectRowUsesPreviousCommandTilePixels() throws {
        let framebuffer = Framebuffer(
            width: 24, height: 16, pixelFormat: .bgra8888)
        // The source for (8,8) is the preceding tile in command order,
        // (16,0), rather than the framebuffer tile immediately to its left.
        framebuffer.fillRect(
            x: 0, y: 8, width: 8, height: 8,
            pixel: Data([0x11, 0x22, 0x33, 0xff]))
        let rect = FramebufferRect(
            x: 8, y: 0, width: 16, height: 16,
            encoding: .appleMultiVariantScreenshare)
        // One white tile followed by three command-1 tiles.
        var payload = Data([0, 0, 0, 9, 0, 15, 25, 0, 0, 8])
        payload.append(contentsOf: [0x01, 0x88, 0x00])

        try AppleAdaptiveDCTDecoder().render(
            rect: rect, payload: payload, to: framebuffer)

        let expected = Data(repeating: 0xff, count: 8 * 8 * 4)
        XCTAssertEqual(
            framebuffer.getPixels(x: 8, y: 8, width: 8, height: 8),
            expected)
        XCTAssertEqual(
            framebuffer.getPixels(x: 16, y: 8, width: 8, height: 8),
            framebuffer.getPixels(x: 8, y: 8, width: 8, height: 8))
    }

    func testSolidReuseUsesIndependentSolidColorCache() throws {
        let framebuffer = Framebuffer(
            width: 16, height: 8, pixelFormat: .bgra8888)
        let rect = FramebufferRect(
            x: 0, y: 0, width: 16, height: 8,
            encoding: .appleMultiVariantScreenshare)
        // Command 4 run=2. Tile 0 subtype 0 defines a white solid color;
        // tile 1 subtype 1 reuses that independent solid-color cache.
        let payload = Data([
            0, 0, 0, 11, 0, 15, 25, 0, 0, 8,
            0x48, 0x00,
            0x3f, 0xe0, 0x81,
        ])

        try AppleAdaptiveDCTDecoder().render(
            rect: rect, payload: payload, to: framebuffer)

        let white = framebuffer.getPixels(x: 8, y: 0, width: 1, height: 1)
        XCTAssertEqual(
            framebuffer.getPixels(x: 0, y: 0, width: 1, height: 1),
            white)
        XCTAssertEqual(white[white.startIndex], white[white.startIndex + 1])
        XCTAssertEqual(white[white.startIndex + 1], white[white.startIndex + 2])
        XCTAssertGreaterThanOrEqual(white[white.startIndex], 0xfe)
        var expected = Data(capacity: 8 * 8 * 4)
        for _ in 0..<(8 * 8) { expected.append(white) }
        XCTAssertEqual(
            framebuffer.getPixels(x: 8, y: 0, width: 8, height: 8),
            expected)
    }

    func testType1RefinementAndBothCoefficientCacheCommands() throws {
        let framebuffer = Framebuffer(
            width: 24, height: 8, pixelFormat: .bgra8888)
        let decoder = AppleAdaptiveDCTDecoder()
        func rect(_ x: UInt16) -> FramebufferRect {
            FramebufferRect(
                x: x, y: 0, width: 8, height: 8,
                encoding: .appleMultiVariantScreenshare)
        }

        // Minimal all-zero type-0 coefficient tile.
        try decoder.render(
            rect: rect(0),
            payload: Data([0, 0, 0, 9, 0, 1, 1, 0, 0, 7, 0x50, 0, 0x10]),
            to: framebuffer)
        // Type 1 command 1 refines it and reserves coefficient-cache key 1.
        var refinement = Data([0, 0, 0, 132, 1, 15, 20, 0x40])
        refinement.append(Data(repeating: 0, count: 128))
        try decoder.render(rect: rect(0), payload: refinement, to: framebuffer)
        // Type-0 command 7 consumes the next implicit cache key.
        try decoder.render(
            rect: rect(8),
            payload: Data([0, 0, 0, 8, 0, 1, 1, 0, 0, 7, 0x70, 0]),
            to: framebuffer)
        // Type-0 command 6 names cache key 1 explicitly.
        try decoder.render(
            rect: rect(16),
            payload: Data([0, 0, 0, 9, 0, 1, 1, 0, 0, 7, 0x60, 0, 1]),
            to: framebuffer)

        let first = framebuffer.getPixels(x: 0, y: 0, width: 8, height: 8)
        XCTAssertEqual(
            first.prefix(32),
            Data([
                0x00, 0xf7, 0x00, 0xff, 0x54, 0xa8, 0x42, 0xff,
                0xc3, 0x72, 0x81, 0xff, 0x74, 0x87, 0x78, 0xff,
                0x6b, 0x94, 0x61, 0xff, 0x84, 0x8b, 0x6a, 0xff,
                0x7c, 0x86, 0x76, 0xff, 0x85, 0x85, 0x73, 0xff,
            ]))
        XCTAssertEqual(first, framebuffer.getPixels(x: 8, y: 0, width: 8, height: 8))
        XCTAssertEqual(first, framebuffer.getPixels(x: 16, y: 0, width: 8, height: 8))
    }

    func testCachedCoefficientCopyDoesNotBecomeDestinationRefinementState() throws {
        let framebuffer = Framebuffer(
            width: 24, height: 8, pixelFormat: .bgra8888)
        let decoder = AppleAdaptiveDCTDecoder()
        func rect(_ x: UInt16) -> FramebufferRect {
            FramebufferRect(
                x: x, y: 0, width: 8, height: 8,
                encoding: .appleMultiVariantScreenshare)
        }

        // Install a base tile, then refine it into cache key 1. Zero chroma
        // thresholds deliberately leave the cached tile eligible for another
        // refinement after it is copied elsewhere.
        try decoder.render(
            rect: rect(0),
            payload: Data([0, 0, 0, 9, 0, 1, 1, 0, 0, 7, 0x50, 0, 0x10]),
            to: framebuffer)
        let minimalRefinement = Data([0, 0, 0, 5, 1, 0, 0, 0x40, 0])
        try decoder.render(
            rect: rect(0), payload: minimalRefinement, to: framebuffer)

        // Copy key 1 to tile 1. Cache drawing does not install that cached
        // coefficient map as the destination tile's refinement state.
        try decoder.render(
            rect: rect(8),
            payload: Data([0, 0, 0, 8, 0, 1, 1, 0, 0, 7, 0x70, 0]),
            to: framebuffer)
        XCTAssertThrowsError(try decoder.render(
            rect: rect(8), payload: minimalRefinement, to: framebuffer)
        )
    }

    func testCacheDrawDoesNotReplacePreviousCoefficientPixels() throws {
        let framebuffer = Framebuffer(
            width: 32, height: 8, pixelFormat: .bgra8888)
        let decoder = AppleAdaptiveDCTDecoder()
        func rect(_ x: UInt16, width: UInt16 = 8) -> FramebufferRect {
            FramebufferRect(
                x: x, y: 0, width: width, height: 8,
                encoding: .appleMultiVariantScreenshare)
        }

        // Reserve coefficient-cache key 1 with a visibly refined tile.
        try decoder.render(
            rect: rect(0),
            payload: Data([0, 0, 0, 9, 0, 1, 1, 0, 0, 7, 0x50, 0, 0x10]),
            to: framebuffer)
        try decoder.render(
            rect: rect(0),
            payload: Data([0, 0, 0, 5, 1, 0, 0, 0x40, 0xa8]),
            to: framebuffer)

        // Decode a new command-5 tile, draw cache key 1, then reuse the
        // command-5 tile. The cache draw between them must not replace the
        // command-5 pixel predictor.
        try decoder.render(
            rect: rect(8, width: 24),
            payload: Data([
                0, 0, 0, 10, 0, 1, 1, 0, 0, 8,
                0x57, 0x50, 0, 0x14,
            ]),
            to: framebuffer)

        let first = framebuffer.getPixels(x: 8, y: 0, width: 8, height: 8)
        let cached = framebuffer.getPixels(x: 16, y: 0, width: 8, height: 8)
        let reused = framebuffer.getPixels(x: 24, y: 0, width: 8, height: 8)
        XCTAssertNotEqual(first, cached)
        XCTAssertEqual(first, reused)
    }

    func testPreviousTileCopyDoesNotInventDestinationCoefficientState() throws {
        let framebuffer = Framebuffer(
            width: 16, height: 8, pixelFormat: .bgra8888)
        let decoder = AppleAdaptiveDCTDecoder()

        // Command 5 installs a coefficient tile, then command 1 copies it to
        // the following tile in command order.
        try decoder.render(
            rect: FramebufferRect(
                x: 0, y: 0, width: 16, height: 8,
                encoding: .appleMultiVariantScreenshare),
            payload: Data([
                0, 0, 0, 10, 0, 1, 1, 0, 0, 8,
                0x51, 0, 0, 0x10,
            ]),
            to: framebuffer)

        // Pixel-copy commands do not install the source coefficient record at
        // the destination. A synthetic refinement that assumes they did is
        // therefore invalid.
        XCTAssertThrowsError(try decoder.render(
            rect: FramebufferRect(
                x: 8, y: 0, width: 8, height: 8,
                encoding: .appleMultiVariantScreenshare),
            payload: Data([0, 0, 0, 5, 1, 0, 0, 0x40, 0]),
            to: framebuffer))
    }

    func testType1CopyCommandRepeatsRefinedSourcePixels() throws {
        let framebuffer = Framebuffer(
            width: 16, height: 8, pixelFormat: .bgra8888)
        let decoder = AppleAdaptiveDCTDecoder()
        let fullRect = FramebufferRect(
            x: 0, y: 0, width: 16, height: 8,
            encoding: .appleMultiVariantScreenshare)

        // Define one coefficient tile, then make the second tile a type-0
        // previous-tile reference to it.
        try decoder.render(
            rect: fullRect,
            payload: Data([
                0, 0, 0, 10, 0, 1, 1, 0, 0, 8,
                0x51, 0, 0, 0x10,
            ]),
            to: framebuffer)
        XCTAssertEqual(
            framebuffer.getPixels(x: 0, y: 0, width: 8, height: 8),
            framebuffer.getPixels(x: 8, y: 0, width: 8, height: 8))

        // Refine tile 0 with nonzero chroma adjustments, then command 2 for
        // tile 1. The latter must recopy tile 0 after its refinement.
        try decoder.render(
            rect: fullRect,
            payload: Data([0, 0, 0, 5, 1, 0, 0, 0x40, 0xa8]),
            to: framebuffer)

        XCTAssertEqual(
            framebuffer.getPixels(x: 0, y: 0, width: 8, height: 8),
            framebuffer.getPixels(x: 8, y: 0, width: 8, height: 8))
    }

    func testType1CopyAtPartialRectRowUsesPreviousCommandTileGeneration() throws {
        let framebuffer = Framebuffer(
            width: 24, height: 16, pixelFormat: .bgra8888)
        let decoder = AppleAdaptiveDCTDecoder()
        let rect = FramebufferRect(
            x: 8, y: 0, width: 16, height: 16,
            encoding: .appleMultiVariantScreenshare)

        // One coefficient tile followed by three previous-command-tile
        // copies. The third tile crosses the rectangle's local row boundary.
        try decoder.render(
            rect: rect,
            payload: Data([
                0, 0, 0, 10, 0, 1, 1, 0, 0, 8,
                0x51, 0x88, 0, 0x10,
            ]),
            to: framebuffer)

        // Refine the first tile and repeat that result through all three copy
        // tiles. The row-boundary tile must validate against the preceding
        // command tile at (16,0), not the unrelated tile at (0,8).
        try decoder.render(
            rect: rect,
            payload: Data([0, 0, 0, 6, 1, 0, 0, 0x40, 0xaa, 0x80]),
            to: framebuffer)

        let expected = framebuffer.getPixels(
            x: 8, y: 0, width: 8, height: 8)
        XCTAssertEqual(
            expected,
            framebuffer.getPixels(x: 16, y: 0, width: 8, height: 8))
        XCTAssertEqual(
            expected,
            framebuffer.getPixels(x: 8, y: 8, width: 8, height: 8))
        XCTAssertEqual(
            expected,
            framebuffer.getPixels(x: 16, y: 8, width: 8, height: 8))
    }

    func testVerticalTileCopyDoesNotInventDestinationCoefficientState() throws {
        let framebuffer = Framebuffer(
            width: 8, height: 16, pixelFormat: .bgra8888)
        let decoder = AppleAdaptiveDCTDecoder()
        func rect(_ y: UInt16) -> FramebufferRect {
            FramebufferRect(
                x: 0, y: y, width: 8, height: 8,
                encoding: .appleMultiVariantScreenshare)
        }

        try decoder.render(
            rect: rect(0),
            payload: Data([0, 0, 0, 9, 0, 1, 1, 0, 0, 7, 0x50, 0, 0x10]),
            to: framebuffer)
        try decoder.render(
            rect: rect(8),
            payload: Data([0, 0, 0, 8, 0, 1, 1, 0, 0, 7, 0x20, 0]),
            to: framebuffer)
        XCTAssertThrowsError(try decoder.render(
            rect: rect(8),
            payload: Data([0, 0, 0, 5, 1, 0, 0, 0x40, 0]),
            to: framebuffer))
    }

    func testReusedType0TilePreservesMapForLaterRefinement() throws {
        let framebuffer = Framebuffer(
            width: 24, height: 8, pixelFormat: .bgra8888)
        let decoder = AppleAdaptiveDCTDecoder()

        // Command 5 run=2. The first tile defines a nonzero Y AC coefficient;
        // the second tile reuses the complete preceding coefficient map.
        try decoder.render(
            rect: FramebufferRect(
                x: 0, y: 0, width: 16, height: 8,
                encoding: .appleMultiVariantScreenshare),
            payload: Data([
                0, 0, 0, 11, 0, 1, 1, 0, 0, 8,
                0x58, 0x00, 0x00, 0x22, 0x80,
            ]),
            to: framebuffer)

        // Refine the reused tile, then draw the resulting implicit cache key
        // into the third tile. Parsing stays aligned only if the reused tile's
        // nonzero AC map was retained.
        try decoder.render(
            rect: FramebufferRect(
                x: 8, y: 0, width: 16, height: 8,
                encoding: .appleMultiVariantScreenshare),
            payload: Data([
                0, 0, 0, 6, 1, 0, 0, 0x41, 0x03, 0x80,
            ]),
            to: framebuffer)

        XCTAssertEqual(
            framebuffer.getPixels(x: 8, y: 0, width: 8, height: 8),
            framebuffer.getPixels(x: 16, y: 0, width: 8, height: 8))
    }
}

// MARK: - Apple Remote Audio Tests

final class AppleRemoteAudioRTPTests: XCTestCase {

    func testRFC3640PacketParsesMultipleAccessUnits() throws {
        let data = makeAudioRTPPacket(
            sequence: 0x1234,
            timestamp: 96_000,
            ssrc: 0x1020_3040,
            accessUnits: [Data([1, 2, 3]), Data([4, 5])])

        XCTAssertTrue(AppleRemoteAudioRTPDepacketizer.canHandle(data))
        let packet = try AppleRemoteAudioRTPDepacketizer.parse(
            data,
            packetization: .rfc3640)
        XCTAssertEqual(packet.sequenceNumber, 0x1234)
        XCTAssertEqual(packet.timestamp, 96_000)
        XCTAssertEqual(packet.ssrc, 0x1020_3040)
        XCTAssertEqual(packet.accessUnits, [Data([1, 2, 3]), Data([4, 5])])
    }

    func testCodecBundledPayloadIsOneCompleteAccessUnit() throws {
        var data = makeAudioRTPPacket(
            sequence: 1,
            timestamp: 0,
            ssrc: 1,
            accessUnits: [Data([1, 2, 3])])
        data.removeLast()

        let rtpPayload = Data(data.dropFirst(12))
        let packet = try AppleRemoteAudioRTPDepacketizer.parse(data)
        XCTAssertEqual(packet.accessUnits, [rtpPayload])
    }

    func testLiveModeEightInactiveFrameIsPreservedAsCodecAccessUnit() throws {
        let inactiveFrame = Data([0x00, 0x68, 0x34, 0x00])
        var data = Data([
            0x80, AppleRemoteAudioRTPDepacketizer.payloadType,
            0, 1, 0, 0, 1, 0, 0, 0, 0, 7,
        ])
        data.append(inactiveFrame)

        let packet = try AppleRemoteAudioRTPDepacketizer.parse(data)
        XCTAssertEqual(packet.accessUnits, [inactiveFrame])
    }

    func testReorderBufferRestoresShortNetworkReordering() {
        var buffer = AppleRemoteAudioRTPReorderBuffer()
        let ten = packet(sequence: 10)
        let eleven = packet(sequence: 11)
        let twelve = packet(sequence: 12)

        XCTAssertEqual(buffer.enqueue(ten).map(\.sequenceNumber), [10])
        XCTAssertTrue(buffer.enqueue(twelve).isEmpty)
        XCTAssertEqual(buffer.enqueue(eleven).map(\.sequenceNumber), [11, 12])
    }

    func testReorderBufferSkipsConfirmedLossInsteadOfFreezing() {
        var buffer = AppleRemoteAudioRTPReorderBuffer(gapConfirmationPacketCount: 3)
        XCTAssertEqual(buffer.enqueue(packet(sequence: 20)).map(\.sequenceNumber), [20])
        XCTAssertTrue(buffer.enqueue(packet(sequence: 22)).isEmpty)
        XCTAssertTrue(buffer.enqueue(packet(sequence: 23)).isEmpty)
        XCTAssertEqual(
            buffer.enqueue(packet(sequence: 24)).map(\.sequenceNumber),
            [22, 23, 24])
    }

    func testReorderBufferHandlesSequenceWraparound() {
        var buffer = AppleRemoteAudioRTPReorderBuffer()
        XCTAssertEqual(buffer.enqueue(packet(sequence: .max)).map(\.sequenceNumber), [.max])
        XCTAssertEqual(buffer.enqueue(packet(sequence: 0)).map(\.sequenceNumber), [0])
    }

    private func packet(sequence: UInt16) -> AppleRemoteAudioRTPPacket {
        AppleRemoteAudioRTPPacket(
            sequenceNumber: sequence,
            timestamp: UInt32(sequence) * 480,
            ssrc: 7,
            marker: true,
            accessUnits: [Data([UInt8(truncatingIfNeeded: sequence)])])
    }

    private func makeAudioRTPPacket(
        sequence: UInt16,
        timestamp: UInt32,
        ssrc: UInt32,
        accessUnits: [Data]
    ) -> Data {
        var data = Data([
            0x80, AppleRemoteAudioRTPDepacketizer.payloadType,
            UInt8(sequence >> 8), UInt8(sequence & 0xff),
            UInt8(timestamp >> 24), UInt8((timestamp >> 16) & 0xff),
            UInt8((timestamp >> 8) & 0xff), UInt8(timestamp & 0xff),
            UInt8(ssrc >> 24), UInt8((ssrc >> 16) & 0xff),
            UInt8((ssrc >> 8) & 0xff), UInt8(ssrc & 0xff),
        ])
        let headerBits = UInt16(accessUnits.count * 16)
        data.append(UInt8(headerBits >> 8))
        data.append(UInt8(headerBits & 0xff))
        for accessUnit in accessUnits {
            let header = UInt16(accessUnit.count) << 3
            data.append(UInt8(header >> 8))
            data.append(UInt8(header & 0xff))
        }
        for accessUnit in accessUnits { data.append(accessUnit) }
        return data
    }
}

// MARK: - Remote Display Size Tests

final class RemoteDisplaySizeTests: XCTestCase {

    func testPhoneViewportExpandsToUsableMacWorkspace() {
        XCTAssertEqual(
            RemoteDisplaySize.matching(
                viewSize: CGSize(width: 852, height: 393)),
            RemoteDisplaySize(
                pixelWidth: 2608,
                pixelHeight: 1200,
                pointWidth: 1304,
                pointHeight: 600))
    }

    func testIPadViewportProducesTwoTimesHiDPIFramebuffer() {
        XCTAssertEqual(
            RemoteDisplaySize.matching(
                viewSize: CGSize(width: 1366, height: 1024)),
            RemoteDisplaySize(
                pixelWidth: 2736,
                pixelHeight: 2048,
                pointWidth: 1368,
                pointHeight: 1024))
    }

    @MainActor
    func testIPadMatchClientRemainsRetinaInHighPerformanceMode() {
        let expected = RemoteDisplaySize(
            pixelWidth: 2736,
            pixelHeight: 2048,
            pointWidth: 1368,
            pointHeight: 1024)

        for reportedScale: CGFloat in [1, 1.5, 2, 3] {
            let session = VNCSession(configuration: VNCConfiguration(
                videoQualityMode: .adaptive,
                displaySizingMode: .matchClient))
            XCTAssertEqual(
                session.matchingClientDisplaySize(
                    viewSize: CGSize(width: 1366, height: 1024),
                    displayScale: reportedScale),
                expected,
                "Match Client should remain HiDPI when the window reports "
                    + "scale \(reportedScale)")
        }
    }

    func testSmallViewportUsesTwoTimesUsableWorkspace() {
        XCTAssertEqual(
            RemoteDisplaySize.matching(
                viewSize: CGSize(width: 1000, height: 700)),
            RemoteDisplaySize(
                pixelWidth: 2048,
                pixelHeight: 1440,
                pointWidth: 1024,
                pointHeight: 720))
    }

    func testFourKLandscapeViewportIsPreservedExactly() {
        XCTAssertEqual(
            RemoteDisplaySize.matching(
                viewSize: CGSize(width: 1920, height: 1080)),
            RemoteDisplaySize(
                pixelWidth: 3840,
                pixelHeight: 2160,
                pointWidth: 1920,
                pointHeight: 1080))
    }

    func testPortraitViewportIsNotReducedToLandscapeFourKBounds() {
        XCTAssertEqual(
            RemoteDisplaySize.matching(
                viewSize: CGSize(width: 1024, height: 1366)),
            RemoteDisplaySize(
                pixelWidth: 2048,
                pixelHeight: 2736,
                pointWidth: 1024,
                pointHeight: 1368))
    }

    func testArbitraryRetinaWindowShapesAlwaysUseExactTwoTimesBacking() throws {
        let viewSizes = [
            CGSize(width: 1197, height: 837),
            CGSize(width: 1024, height: 1366),
            CGSize(width: 2400, height: 1000),
            CGSize(width: 744, height: 1133),
        ]

        for viewSize in viewSizes {
            let size = try XCTUnwrap(RemoteDisplaySize.matching(
                viewSize: viewSize))
            XCTAssertEqual(size.pixelWidth, size.pointWidth * 2)
            XCTAssertEqual(size.pixelHeight, size.pointHeight * 2)
        }
    }

    /// The screen profile uses 60 fps through 3840x2160 and 30 fps for larger
    /// areas such as 3840x2304 and 3696x2416. Oversized client viewports must be fitted into
    /// that 60 fps tier, preserving aspect ratio and exact 2x backing.
    func testClientViewportLargerThanUHDIsFittedIntoThe60FPSTier() {
        XCTAssertEqual(
            RemoteDisplaySize.matching(
                viewSize: CGSize(width: 2400, height: 1200)),
            RemoteDisplaySize(
                pixelWidth: 4064,
                pixelHeight: 2032,
                pointWidth: 2032,
                pointHeight: 1016))
    }

    /// The full-screen Catalyst window that originally negotiated a 3696x2416
    /// virtual display — and halved the server's frame rate — must stay under
    /// the UHD area while remaining HiDPI and aspect-correct.
    func testFullScreenCatalystWindowStaysInside60FPSTier() throws {
        let size = try XCTUnwrap(RemoteDisplaySize.matching(
            viewSize: CGSize(width: 1848, height: 1208)))

        XCTAssertLessThanOrEqual(
            Int(size.pixelWidth) * Int(size.pixelHeight), 3840 * 2160)
        XCTAssertEqual(size.pixelWidth, size.pointWidth * 2)
        XCTAssertEqual(size.pixelHeight, size.pointHeight * 2)
        XCTAssertEqual(
            Double(size.pixelWidth) / Double(size.pixelHeight),
            1848.0 / 1208.0,
            accuracy: 0.02)
    }

    func testClientViewportIsFittedInsideCompoundHEVCDecodeLimit() {
        XCTAssertEqual(
            RemoteDisplaySize.matching(
                viewSize: CGSize(width: 2784, height: 1632)),
            RemoteDisplaySize(
                pixelWidth: 3760,
                pixelHeight: 2192,
                pointWidth: 1880,
                pointHeight: 1096))
    }

    func testDecodeLimitFitAlsoProtectsTallClientWindows() {
        let size = RemoteDisplaySize.matching(
            viewSize: CGSize(width: 1800, height: 3000))

        XCTAssertEqual(size?.pixelWidth, 2224)
        XCTAssertEqual(size?.pixelHeight, 3712)
        XCTAssertEqual(size?.pixelWidth, size.map { $0.pointWidth * 2 })
        XCTAssertEqual(size?.pixelHeight, size.map { $0.pointHeight * 2 })
    }

    func testInvalidViewportIsIgnored() {
        XCTAssertNil(RemoteDisplaySize.matching(
            viewSize: CGSize(width: 0, height: 1024)))
        XCTAssertNil(RemoteDisplaySize.matching(
            viewSize: CGSize(width: 1024, height: CGFloat.infinity)))
    }
}

// MARK: - KeyboardInputHandler Tests

final class KeyboardInputHandlerTests: XCTestCase {

    // MARK: - Keysym constants

    func testKeysymConstants() {
        XCTAssertEqual(KeyboardInputHandler.keysymBackspace, 0xFF08)
        XCTAssertEqual(KeyboardInputHandler.keysymTab, 0xFF09)
        XCTAssertEqual(KeyboardInputHandler.keysymReturn, 0xFF0D)
        XCTAssertEqual(KeyboardInputHandler.keysymEscape, 0xFF1B)
        XCTAssertEqual(KeyboardInputHandler.keysymDelete, 0xFFFF)
        XCTAssertEqual(KeyboardInputHandler.keysymLeft, 0xFF51)
        XCTAssertEqual(KeyboardInputHandler.keysymUp, 0xFF52)
        XCTAssertEqual(KeyboardInputHandler.keysymRight, 0xFF53)
        XCTAssertEqual(KeyboardInputHandler.keysymDown, 0xFF54)
        XCTAssertEqual(KeyboardInputHandler.keysymHome, 0xFF50)
        XCTAssertEqual(KeyboardInputHandler.keysymEnd, 0xFF57)
        XCTAssertEqual(KeyboardInputHandler.keysymPageUp, 0xFF55)
        XCTAssertEqual(KeyboardInputHandler.keysymPageDown, 0xFF56)
        XCTAssertEqual(KeyboardInputHandler.keysymInsert, 0xFF63)
    }

    func testHardwareKeyboardHIDMapping() {
        XCTAssertEqual(
            KeyboardInputHandler.keysymForHIDUsage(0x28, characters: "\r"),
            KeyboardInputHandler.keysymReturn)
        XCTAssertEqual(
            KeyboardInputHandler.keysymForHIDUsage(0x50, characters: ""),
            KeyboardInputHandler.keysymLeft)
        XCTAssertEqual(
            KeyboardInputHandler.keysymForHIDUsage(0x4F, characters: ""),
            KeyboardInputHandler.keysymRight)
        XCTAssertEqual(
            KeyboardInputHandler.keysymForHIDUsage(0x51, characters: ""),
            KeyboardInputHandler.keysymDown)
        XCTAssertEqual(
            KeyboardInputHandler.keysymForHIDUsage(0x52, characters: ""),
            KeyboardInputHandler.keysymUp)
        XCTAssertEqual(
            KeyboardInputHandler.keysymForHIDUsage(0x3A, characters: ""),
            KeyboardInputHandler.keysymF1)
        XCTAssertEqual(
            KeyboardInputHandler.keysymForHIDUsage(0xE3, characters: ""),
            KeyboardInputHandler.keysymSuperL)
        XCTAssertEqual(
            KeyboardInputHandler.keysymForHIDUsage(0x04, characters: "A"),
            0x41)
        XCTAssertEqual(
            KeyboardInputHandler.keysymForHIDUsage(0x1E, characters: "!"),
            0x21)
    }

    func testControlChordUsesPrintableKeysymInsteadOfControlByte() {
        let characters = KeyboardInputHandler.hardwareCharacters(
            characters: "\u{03}",
            charactersIgnoringModifiers: "c",
            controlOrCommandDown: true)

        XCTAssertEqual(characters, "c")
        XCTAssertEqual(
            KeyboardInputHandler.keysymForHIDUsage(0x06, characters: characters),
            0x63)
    }

    @MainActor
    func testSupplementalControlCProducesCompleteRFBChord() {
        var transitions: [HardwareKeyboardTransition] = []
        let handler = KeyboardInputHandler { downFlag, keysym in
            transitions.append(HardwareKeyboardTransition(
                downFlag: downFlag,
                keysym: keysym))
        }

        XCTAssertTrue(handler.handleKeyTap(
            "c",
            supplementalModifiers: [.control]))
        XCTAssertEqual(transitions, [
            HardwareKeyboardTransition(
                downFlag: true,
                keysym: KeyboardInputHandler.keysymControlL),
            HardwareKeyboardTransition(downFlag: true, keysym: 0x63),
            HardwareKeyboardTransition(downFlag: false, keysym: 0x63),
            HardwareKeyboardTransition(
                downFlag: false,
                keysym: KeyboardInputHandler.keysymControlL),
        ])
    }

    @MainActor
    func testSupplementalModifiersUseStableReverseReleaseOrder() {
        var transitions: [HardwareKeyboardTransition] = []
        let handler = KeyboardInputHandler { downFlag, keysym in
            transitions.append(HardwareKeyboardTransition(
                downFlag: downFlag,
                keysym: keysym))
        }

        XCTAssertTrue(handler.handleKeysymTap(
            KeyboardInputHandler.keysymBackspace,
            supplementalModifiers: [.control, .option, .shift, .command]))
        XCTAssertEqual(transitions.map(\.keysym), [
            KeyboardInputHandler.keysymControlL,
            KeyboardInputHandler.keysymAltL,
            KeyboardInputHandler.keysymShiftL,
            KeyboardInputHandler.keysymSuperL,
            KeyboardInputHandler.keysymBackspace,
            KeyboardInputHandler.keysymBackspace,
            KeyboardInputHandler.keysymSuperL,
            KeyboardInputHandler.keysymShiftL,
            KeyboardInputHandler.keysymAltL,
            KeyboardInputHandler.keysymControlL,
        ])
        XCTAssertEqual(transitions.map(\.downFlag), [
            true, true, true, true, true,
            false, false, false, false, false,
        ])
    }

    @MainActor
    func testStandardRemoteCommandAliasesMatchScreensDefaults() {
        let expected: [RemoteCommand: RemoteCommandShortcut] = [
            .missionControl: RemoteCommandShortcut(
                input: .upArrow, modifiers: [.control, .option]),
            .applicationWindows: RemoteCommandShortcut(
                input: .downArrow, modifiers: [.control, .option]),
            .moveLeftASpace: RemoteCommandShortcut(
                input: .leftArrow, modifiers: [.control, .option]),
            .moveRightASpace: RemoteCommandShortcut(
                input: .rightArrow, modifiers: [.control, .option]),
            .forceQuit: RemoteCommandShortcut(
                input: .escape, modifiers: [.control, .option]),
            .lockScreen: RemoteCommandShortcut(
                input: .character("q"), modifiers: [.control, .option]),
            .logOutUser: RemoteCommandShortcut(
                input: .character("q"), modifiers: [.option, .shift]),
            .controlAltDelete: RemoteCommandShortcut(
                input: .delete, modifiers: [.control, .option]),
            .backslash: RemoteCommandShortcut(
                input: .character("7"), modifiers: [.control, .shift]),
            .insert: RemoteCommandShortcut(
                input: .character("8"), modifiers: [.control, .shift]),
        ]

        XCTAssertEqual(RemoteCommand.allCases.count, expected.count)
        for command in RemoteCommand.allCases {
            XCTAssertEqual(command.shortcut, expected[command])
        }
    }

    @MainActor
    func testRemoteCommandProducesCompleteChordInReverseReleaseOrder() async throws {
        var transitions: [HardwareKeyboardTransition] = []
        let handler = KeyboardInputHandler { downFlag, keysym in
            transitions.append(HardwareKeyboardTransition(
                downFlag: downFlag,
                keysym: keysym))
        }

        handler.handleRemoteCommand(.forceQuit)

        XCTAssertEqual(transitions, [
            HardwareKeyboardTransition(
                downFlag: true,
                keysym: KeyboardInputHandler.keysymSuperL),
            HardwareKeyboardTransition(
                downFlag: true,
                keysym: KeyboardInputHandler.keysymAltL),
            HardwareKeyboardTransition(
                downFlag: true,
                keysym: KeyboardInputHandler.keysymEscape),
        ])

        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(transitions, [
            HardwareKeyboardTransition(
                downFlag: true,
                keysym: KeyboardInputHandler.keysymSuperL),
            HardwareKeyboardTransition(
                downFlag: true,
                keysym: KeyboardInputHandler.keysymAltL),
            HardwareKeyboardTransition(
                downFlag: true,
                keysym: KeyboardInputHandler.keysymEscape),
            HardwareKeyboardTransition(
                downFlag: false,
                keysym: KeyboardInputHandler.keysymEscape),
            HardwareKeyboardTransition(
                downFlag: false,
                keysym: KeyboardInputHandler.keysymAltL),
            HardwareKeyboardTransition(
                downFlag: false,
                keysym: KeyboardInputHandler.keysymSuperL),
        ])
    }

    @MainActor
    func testCommandTapCompatibilityPathStillSendsCommandChord() async throws {
        var transitions: [HardwareKeyboardTransition] = []
        let handler = KeyboardInputHandler { downFlag, keysym in
            transitions.append(HardwareKeyboardTransition(
                downFlag: downFlag,
                keysym: keysym))
        }

        handler.handleCommandTap("h")
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(transitions, [
            HardwareKeyboardTransition(
                downFlag: true,
                keysym: KeyboardInputHandler.keysymSuperL),
            HardwareKeyboardTransition(downFlag: true, keysym: 0x68),
            HardwareKeyboardTransition(downFlag: false, keysym: 0x68),
            HardwareKeyboardTransition(
                downFlag: false,
                keysym: KeyboardInputHandler.keysymSuperL),
        ])
    }

    func testFunctionKeyConstants() {
        XCTAssertEqual(KeyboardInputHandler.keysymF1, 0xFFBE)
        XCTAssertEqual(KeyboardInputHandler.keysymF2, 0xFFBF)
        XCTAssertEqual(KeyboardInputHandler.keysymF3, 0xFFC0)
        XCTAssertEqual(KeyboardInputHandler.keysymF4, 0xFFC1)
        XCTAssertEqual(KeyboardInputHandler.keysymF5, 0xFFC2)
        XCTAssertEqual(KeyboardInputHandler.keysymF6, 0xFFC3)
        XCTAssertEqual(KeyboardInputHandler.keysymF7, 0xFFC4)
        XCTAssertEqual(KeyboardInputHandler.keysymF8, 0xFFC5)
        XCTAssertEqual(KeyboardInputHandler.keysymF9, 0xFFC6)
        XCTAssertEqual(KeyboardInputHandler.keysymF10, 0xFFC7)
        XCTAssertEqual(KeyboardInputHandler.keysymF11, 0xFFC8)
        XCTAssertEqual(KeyboardInputHandler.keysymF12, 0xFFC9)
    }

    func testModifierKeyConstants() {
        XCTAssertEqual(KeyboardInputHandler.keysymShiftL, 0xFFE1)
        XCTAssertEqual(KeyboardInputHandler.keysymShiftR, 0xFFE2)
        XCTAssertEqual(KeyboardInputHandler.keysymControlL, 0xFFE3)
        XCTAssertEqual(KeyboardInputHandler.keysymControlR, 0xFFE4)
        XCTAssertEqual(KeyboardInputHandler.keysymCapsLock, 0xFFE5)
        XCTAssertEqual(KeyboardInputHandler.keysymMetaL, 0xFFE7)
        XCTAssertEqual(KeyboardInputHandler.keysymMetaR, 0xFFE8)
        XCTAssertEqual(KeyboardInputHandler.keysymAltL, 0xFFE9)
        XCTAssertEqual(KeyboardInputHandler.keysymAltR, 0xFFEA)
    }

    // MARK: - Apple modifier convention (Option ⌥ = Meta, not Alt)

    func testOptionKeysymFollowsServerModifierConvention() {
        // Apple's Screen Sharing server maps Alt_L to Command and Meta_L to
        // Option, so Option must be sent as Meta on Apple servers and Alt on
        // standard X11 servers.
        XCTAssertEqual(
            KeyboardInputHandler.optionLeftKeysym(appleModifierConvention: true),
            KeyboardInputHandler.keysymMetaL)
        XCTAssertEqual(
            KeyboardInputHandler.optionRightKeysym(appleModifierConvention: true),
            KeyboardInputHandler.keysymMetaR)
        XCTAssertEqual(
            KeyboardInputHandler.optionLeftKeysym(appleModifierConvention: false),
            KeyboardInputHandler.keysymAltL)
        XCTAssertEqual(
            KeyboardInputHandler.optionRightKeysym(appleModifierConvention: false),
            KeyboardInputHandler.keysymAltR)

        // Supplemental (on-screen toolbar / software keyboard) modifiers.
        XCTAssertEqual(
            KeyboardInputHandler.keysyms(for: [.option], appleModifierConvention: true),
            [KeyboardInputHandler.keysymMetaL])
        XCTAssertEqual(
            KeyboardInputHandler.keysyms(for: [.option], appleModifierConvention: false),
            [KeyboardInputHandler.keysymAltL])

        // Physical hardware Option keys (HID usage 0xE2 / 0xE6).
        XCTAssertEqual(
            KeyboardInputHandler.keysymForHIDUsage(0xE2, characters: "", appleModifierConvention: true),
            KeyboardInputHandler.keysymMetaL)
        XCTAssertEqual(
            KeyboardInputHandler.keysymForHIDUsage(0xE6, characters: "", appleModifierConvention: true),
            KeyboardInputHandler.keysymMetaR)
        XCTAssertEqual(
            KeyboardInputHandler.keysymForHIDUsage(0xE2, characters: "", appleModifierConvention: false),
            KeyboardInputHandler.keysymAltL)
        XCTAssertEqual(
            KeyboardInputHandler.keysymForHIDUsage(0xE6, characters: "", appleModifierConvention: false),
            KeyboardInputHandler.keysymAltR)
    }

    @MainActor
    func testAppleOptionDeleteSendsMetaBackspaceNotCommand() {
        // Regression for issue #259: on-screen / software-keyboard Option-Delete
        // must reach an Apple Mac as Option-Delete (Meta_L), not Command-Delete.
        var transitions: [HardwareKeyboardTransition] = []
        let handler = KeyboardInputHandler(
            sendKeyEvent: { downFlag, keysym in
                transitions.append(HardwareKeyboardTransition(
                    downFlag: downFlag, keysym: keysym))
            },
            usesAppleModifierConvention: { true })

        XCTAssertTrue(handler.handleKeysymTap(
            KeyboardInputHandler.keysymBackspace,
            supplementalModifiers: [.option]))
        XCTAssertEqual(transitions, [
            HardwareKeyboardTransition(downFlag: true, keysym: KeyboardInputHandler.keysymMetaL),
            HardwareKeyboardTransition(downFlag: true, keysym: KeyboardInputHandler.keysymBackspace),
            HardwareKeyboardTransition(downFlag: false, keysym: KeyboardInputHandler.keysymBackspace),
            HardwareKeyboardTransition(downFlag: false, keysym: KeyboardInputHandler.keysymMetaL),
        ])
        XCTAssertFalse(
            transitions.contains { $0.keysym == KeyboardInputHandler.keysymSuperL },
            "Option-Delete must never emit Super_L (Command) on an Apple server")
    }

    @MainActor
    func testForceQuitUsesMetaOptionUnderAppleConvention() {
        // Force Quit is ⌘⌥⎋. With Alt_L=Command on Apple, the Option leg must be
        // Meta_L or the chord collapses to ⌘⎋.
        var transitions: [HardwareKeyboardTransition] = []
        let handler = KeyboardInputHandler(
            sendKeyEvent: { downFlag, keysym in
                transitions.append(HardwareKeyboardTransition(
                    downFlag: downFlag, keysym: keysym))
            },
            usesAppleModifierConvention: { true })

        handler.handleRemoteCommand(.forceQuit)

        XCTAssertEqual(transitions.prefix(3).map(\.keysym), [
            KeyboardInputHandler.keysymSuperL,
            KeyboardInputHandler.keysymMetaL,
            KeyboardInputHandler.keysymEscape,
        ])
    }

    // MARK: - Character to keysym mapping

    func testKeysymForASCIICharacters() {
        // ASCII printable: keysym == code point
        XCTAssertEqual(KeyboardInputHandler.keysymForCharacter("a"), 0x61)
        XCTAssertEqual(KeyboardInputHandler.keysymForCharacter("A"), 0x41)
        XCTAssertEqual(KeyboardInputHandler.keysymForCharacter("z"), 0x7A)
        XCTAssertEqual(KeyboardInputHandler.keysymForCharacter("Z"), 0x5A)
        XCTAssertEqual(KeyboardInputHandler.keysymForCharacter("0"), 0x30)
        XCTAssertEqual(KeyboardInputHandler.keysymForCharacter("9"), 0x39)
        XCTAssertEqual(KeyboardInputHandler.keysymForCharacter(" "), 0x20)
        XCTAssertEqual(KeyboardInputHandler.keysymForCharacter("!"), 0x21)
        XCTAssertEqual(KeyboardInputHandler.keysymForCharacter("~"), 0x7E)
        XCTAssertEqual(KeyboardInputHandler.keysymForCharacter("@"), 0x40)
    }

    func testKeysymForLatin1Supplement() {
        // Latin-1 supplement: keysym == code point
        XCTAssertEqual(KeyboardInputHandler.keysymForCharacter("\u{00A9}"), 0x00A9) // copyright
        XCTAssertEqual(KeyboardInputHandler.keysymForCharacter("\u{00E9}"), 0x00E9) // e-acute
        XCTAssertEqual(KeyboardInputHandler.keysymForCharacter("\u{00FF}"), 0x00FF) // y-diaeresis
        XCTAssertEqual(KeyboardInputHandler.keysymForCharacter("\u{00A0}"), 0x00A0) // non-breaking space
    }

    func testKeysymForUnicodeCharacters() {
        // Unicode characters above 0xFF use the 0x01000000 prefix
        let euro = Character("\u{20AC}") // Euro sign
        XCTAssertEqual(KeyboardInputHandler.keysymForCharacter(euro), 0x01000000 | 0x20AC)

        let snowman = Character("\u{2603}") // snowman
        XCTAssertEqual(KeyboardInputHandler.keysymForCharacter(snowman), 0x01000000 | 0x2603)

        let smiley = Character("\u{1F600}") // grinning face
        XCTAssertEqual(KeyboardInputHandler.keysymForCharacter(smiley), 0x01000000 | 0x1F600)
    }

    func testKeysymForControlCharacters() {
        // Backspace (0x08) -> keysymBackspace
        XCTAssertEqual(KeyboardInputHandler.keysymForCharacter("\u{08}"), KeyboardInputHandler.keysymBackspace)
        // Tab (0x09) -> keysymTab
        XCTAssertEqual(KeyboardInputHandler.keysymForCharacter("\u{09}"), KeyboardInputHandler.keysymTab)
        // Carriage return (0x0D) -> keysymReturn
        XCTAssertEqual(KeyboardInputHandler.keysymForCharacter("\r"), KeyboardInputHandler.keysymReturn)
        // Newline (0x0A) -> keysymReturn
        XCTAssertEqual(KeyboardInputHandler.keysymForCharacter("\n"), KeyboardInputHandler.keysymReturn)
        // Escape (0x1B) -> keysymEscape
        XCTAssertEqual(KeyboardInputHandler.keysymForCharacter("\u{1B}"), KeyboardInputHandler.keysymEscape)
        // DEL (0x7F) -> keysymDelete
        XCTAssertEqual(KeyboardInputHandler.keysymForCharacter("\u{7F}"), KeyboardInputHandler.keysymDelete)
    }

    // MARK: - Function key helper

    func testKeysymForFunctionKey() {
        XCTAssertEqual(KeyboardInputHandler.keysymForFunctionKey(1), KeyboardInputHandler.keysymF1)
        XCTAssertEqual(KeyboardInputHandler.keysymForFunctionKey(12), KeyboardInputHandler.keysymF12)
        XCTAssertEqual(KeyboardInputHandler.keysymForFunctionKey(6), KeyboardInputHandler.keysymF6)
    }

    func testKeysymForFunctionKeyOutOfRange() {
        XCTAssertEqual(KeyboardInputHandler.keysymForFunctionKey(0), 0)
        XCTAssertEqual(
            KeyboardInputHandler.keysymForFunctionKey(24),
            KeyboardInputHandler.keysymF1 + 23)
        XCTAssertEqual(KeyboardInputHandler.keysymForFunctionKey(25), 0)
        XCTAssertEqual(KeyboardInputHandler.keysymForFunctionKey(-1), 0)
    }

    func testFunctionKeysAreConsecutive() {
        // F1 through F12 should be consecutive keysym values
        for i in 1...12 {
            let expected = KeyboardInputHandler.keysymF1 + UInt32(i - 1)
            XCTAssertEqual(KeyboardInputHandler.keysymForFunctionKey(i), expected)
        }
    }
}

final class HardwareKeyboardStateTests: XCTestCase {
    func testControlCProducesModifierAndPrintableKeysymTransitions() {
        var state = HardwareKeyboardState()
        let transitions = [
            state.press(
                usage: 0xE0,
                keysym: KeyboardInputHandler.keysymControlL),
            state.press(usage: 0x06, keysym: 0x63),
            state.release(usage: 0x06),
            state.release(usage: 0xE0),
        ].compactMap { $0 }

        XCTAssertEqual(transitions, [
            HardwareKeyboardTransition(
                downFlag: true,
                keysym: KeyboardInputHandler.keysymControlL),
            HardwareKeyboardTransition(downFlag: true, keysym: 0x63),
            HardwareKeyboardTransition(downFlag: false, keysym: 0x63),
            HardwareKeyboardTransition(
                downFlag: false,
                keysym: KeyboardInputHandler.keysymControlL),
        ])
    }

    func testPressRepeatAndReleaseRetainPressTimeKeysym() {
        var state = HardwareKeyboardState()

        XCTAssertEqual(
            state.press(usage: 0x04, keysym: 0x41),
            HardwareKeyboardTransition(downFlag: true, keysym: 0x41))
        XCTAssertNil(state.press(usage: 0x04, keysym: 0x61))
        XCTAssertEqual(
            state.repeatedPress(usage: 0x04),
            HardwareKeyboardTransition(downFlag: true, keysym: 0x41))
        XCTAssertEqual(
            state.release(usage: 0x04),
            HardwareKeyboardTransition(downFlag: false, keysym: 0x41))
        XCTAssertNil(state.release(usage: 0x04))
    }

    func testSupplementalModifiersStayDownAcrossOverlappingKeys() {
        var state = SupplementalHardwareModifierState()

        XCTAssertEqual(state.begin(
            usage: 0x06,
            keysyms: [KeyboardInputHandler.keysymControlL]), [
                HardwareKeyboardTransition(
                    downFlag: true,
                    keysym: KeyboardInputHandler.keysymControlL),
            ])
        XCTAssertTrue(state.begin(
            usage: 0x07,
            keysyms: [KeyboardInputHandler.keysymControlL]).isEmpty)
        XCTAssertTrue(state.end(usage: 0x06).isEmpty)
        XCTAssertEqual(state.end(usage: 0x07), [
            HardwareKeyboardTransition(
                downFlag: false,
                keysym: KeyboardInputHandler.keysymControlL),
        ])
    }

    func testSupplementalModifierReleaseAllUsesReverseActivationOrder() {
        var state = SupplementalHardwareModifierState()
        _ = state.begin(
            usage: 0x06,
            keysyms: [
                KeyboardInputHandler.keysymControlL,
                KeyboardInputHandler.keysymAltL,
            ])

        XCTAssertEqual(state.releaseAll(), [
            HardwareKeyboardTransition(
                downFlag: false,
                keysym: KeyboardInputHandler.keysymAltL),
            HardwareKeyboardTransition(
                downFlag: false,
                keysym: KeyboardInputHandler.keysymControlL),
        ])
        XCTAssertTrue(state.releaseAll().isEmpty)
    }

    func testReleaseAllUsesReversePressOrderAndOnlyReleasesOnce() {
        var state = HardwareKeyboardState()
        _ = state.press(usage: 0xE0, keysym: KeyboardInputHandler.keysymControlL)
        _ = state.press(usage: 0x06, keysym: 0x63)

        XCTAssertEqual(state.releaseAll(), [
            HardwareKeyboardTransition(downFlag: false, keysym: 0x63),
            HardwareKeyboardTransition(
                downFlag: false,
                keysym: KeyboardInputHandler.keysymControlL),
        ])
        XCTAssertTrue(state.releaseAll().isEmpty)
    }

    func testFunctionKeysThroughF24AndAdditionalHIDKeys() {
        XCTAssertEqual(
            KeyboardInputHandler.keysymForHIDUsage(0x68, characters: ""),
            KeyboardInputHandler.keysymForFunctionKey(13))
        XCTAssertEqual(
            KeyboardInputHandler.keysymForHIDUsage(0x73, characters: ""),
            KeyboardInputHandler.keysymForFunctionKey(24))
        XCTAssertEqual(
            KeyboardInputHandler.keysymForHIDUsage(0x58, characters: ""),
            KeyboardInputHandler.keysymReturn)
        XCTAssertEqual(
            KeyboardInputHandler.keysymForHIDUsage(0x53, characters: ""),
            KeyboardInputHandler.keysymNumLock)
    }
}

// MARK: - ProtocolTrace Tests

final class ProtocolTraceTests: XCTestCase {

    func testRecordSentEntry() {
        let trace = ProtocolTrace(maxEntries: 100)
        trace.recordSent(type: "KeyEvent", data: Data([0x04, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x61]))

        let entries = trace.getEntries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].direction, .sent)
        XCTAssertEqual(entries[0].messageType, "KeyEvent")
        XCTAssertEqual(entries[0].byteCount, 8)
    }

    func testRecordReceivedEntry() {
        let trace = ProtocolTrace(maxEntries: 100)
        trace.recordReceived(type: "FramebufferUpdate", data: Data(repeating: 0, count: 1024))

        let entries = trace.getEntries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].direction, .received)
        XCTAssertEqual(entries[0].messageType, "FramebufferUpdate")
        XCTAssertEqual(entries[0].byteCount, 1024)
    }

    func testRecordMultipleEntries() {
        let trace = ProtocolTrace(maxEntries: 100)
        trace.recordSent(type: "KeyEvent", data: Data([0x01]))
        trace.recordReceived(type: "Bell", data: Data([0x02]))
        trace.recordSent(type: "PointerEvent", data: Data([0x03]))

        let entries = trace.getEntries()
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries[0].messageType, "KeyEvent")
        XCTAssertEqual(entries[1].messageType, "Bell")
        XCTAssertEqual(entries[2].messageType, "PointerEvent")
    }

    func testRecordWithDetails() {
        let trace = ProtocolTrace(maxEntries: 100)
        trace.recordSent(type: "SetEncodings", data: Data(repeating: 0, count: 12), details: "3 encodings")

        let entries = trace.getEntries()
        XCTAssertEqual(entries[0].details, "3 encodings")
    }

    func testMaxEntriesEviction() {
        let trace = ProtocolTrace(maxEntries: 3)
        trace.recordSent(type: "Msg1", data: Data([0x01]))
        trace.recordSent(type: "Msg2", data: Data([0x02]))
        trace.recordSent(type: "Msg3", data: Data([0x03]))
        trace.recordSent(type: "Msg4", data: Data([0x04]))

        let entries = trace.getEntries()
        XCTAssertEqual(entries.count, 3)
        // Oldest entry (Msg1) should be evicted
        XCTAssertEqual(entries[0].messageType, "Msg2")
        XCTAssertEqual(entries[1].messageType, "Msg3")
        XCTAssertEqual(entries[2].messageType, "Msg4")
    }

    func testCount() {
        let trace = ProtocolTrace(maxEntries: 100)
        XCTAssertEqual(trace.count, 0)
        trace.recordSent(type: "A", data: Data([0]))
        XCTAssertEqual(trace.count, 1)
        trace.recordReceived(type: "B", data: Data([0]))
        XCTAssertEqual(trace.count, 2)
    }

    func testClear() {
        let trace = ProtocolTrace(maxEntries: 100)
        trace.recordSent(type: "A", data: Data([0]))
        trace.recordReceived(type: "B", data: Data([0]))
        XCTAssertEqual(trace.count, 2)

        trace.clear()
        XCTAssertEqual(trace.count, 0)
        XCTAssertTrue(trace.getEntries().isEmpty)
    }

    func testExportJSON() throws {
        let trace = ProtocolTrace(maxEntries: 100)
        trace.recordSent(type: "KeyEvent", data: Data([0x04, 0x01]))
        trace.recordReceived(type: "Bell", data: Data([0x02]))

        let jsonData = try trace.exportJSON()
        XCTAssertFalse(jsonData.isEmpty)

        // Verify it's valid JSON
        let decoded = try JSONSerialization.jsonObject(with: jsonData)
        guard let array = decoded as? [[String: Any]] else {
            XCTFail("Expected JSON array")
            return
        }
        XCTAssertEqual(array.count, 2)

        // Verify fields exist
        let first = array[0]
        XCTAssertNotNil(first["timestamp"])
        XCTAssertNotNil(first["direction"])
        XCTAssertNotNil(first["messageType"])
        XCTAssertNotNil(first["byteCount"])
    }

    func testExportJSONEmpty() throws {
        let trace = ProtocolTrace(maxEntries: 100)
        let jsonData = try trace.exportJSON()
        let decoded = try JSONSerialization.jsonObject(with: jsonData)
        guard let array = decoded as? [Any] else {
            XCTFail("Expected JSON array")
            return
        }
        XCTAssertTrue(array.isEmpty)
    }

    func testTimestampsAreChronological() {
        let trace = ProtocolTrace(maxEntries: 100)
        trace.recordSent(type: "First", data: Data([0]))
        // Small delay to ensure different timestamps
        trace.recordSent(type: "Second", data: Data([0]))

        let entries = trace.getEntries()
        XCTAssertEqual(entries.count, 2)
        XCTAssertLessThanOrEqual(entries[0].timestamp, entries[1].timestamp)
    }

    func testDirectionEnum() {
        XCTAssertEqual(ProtocolTrace.TraceEntry.Direction.sent.rawValue, "sent")
        XCTAssertEqual(ProtocolTrace.TraceEntry.Direction.received.rawValue, "received")
    }
}

// MARK: - ConnectionDiagnostics Tests

final class ConnectionDiagnosticsTests: XCTestCase {

    func testInitialState() {
        let diag = ConnectionDiagnostics()
        XCTAssertNil(diag.serverVersion)
        XCTAssertNil(diag.clientVersion)
        XCTAssertTrue(diag.offeredSecurityTypes.isEmpty)
        XCTAssertNil(diag.selectedSecurityType)
        XCTAssertNil(diag.serverInit)
        XCTAssertNil(diag.encryptionMode)
        XCTAssertFalse(diag.isHighPerformanceMode)
        XCTAssertNil(diag.connectionStartTime)
        XCTAssertNil(diag.handshakeCompleteTime)
        XCTAssertNil(diag.lastError)
        XCTAssertNil(diag.handshakeDuration)
    }

    func testSetProperties() {
        let diag = ConnectionDiagnostics()

        diag.serverVersion = .v3_8
        XCTAssertEqual(diag.serverVersion, .v3_8)

        diag.clientVersion = .v3_8
        XCTAssertEqual(diag.clientVersion, .v3_8)

        diag.offeredSecurityTypes = [.none, .vncAuthentication]
        XCTAssertEqual(diag.offeredSecurityTypes.count, 2)

        diag.selectedSecurityType = .vncAuthentication
        XCTAssertEqual(diag.selectedSecurityType, .vncAuthentication)

        let si = ServerInit(framebufferWidth: 1920, framebufferHeight: 1080, pixelFormat: .bgra8888, name: "Test")
        diag.serverInit = si
        XCTAssertEqual(diag.serverInit, si)

        diag.encryptionMode = "AES-128-CBC"
        XCTAssertEqual(diag.encryptionMode, "AES-128-CBC")

        diag.isHighPerformanceMode = true
        XCTAssertTrue(diag.isHighPerformanceMode)

        diag.lastError = .connectionClosed
        XCTAssertEqual(diag.lastError, .connectionClosed)
    }

    func testHandshakeDuration() {
        let diag = ConnectionDiagnostics()
        XCTAssertNil(diag.handshakeDuration)

        let start = Date()
        diag.connectionStartTime = start
        XCTAssertNil(diag.handshakeDuration) // no end time yet

        let end = start.addingTimeInterval(1.5)
        diag.handshakeCompleteTime = end
        XCTAssertNotNil(diag.handshakeDuration)
        XCTAssertEqual(diag.handshakeDuration!, 1.5, accuracy: 0.001)
    }

    func testReset() {
        let diag = ConnectionDiagnostics()
        diag.serverVersion = .v3_8
        diag.clientVersion = .v3_8
        diag.offeredSecurityTypes = [.none]
        diag.selectedSecurityType = SecurityType.none
        diag.serverInit = ServerInit(framebufferWidth: 800, framebufferHeight: 600, pixelFormat: .bgra8888, name: "T")
        diag.encryptionMode = "AES"
        diag.isHighPerformanceMode = true
        diag.connectionStartTime = Date()
        diag.handshakeCompleteTime = Date()
        diag.lastError = .timeout

        diag.reset()

        XCTAssertNil(diag.serverVersion)
        XCTAssertNil(diag.clientVersion)
        XCTAssertTrue(diag.offeredSecurityTypes.isEmpty)
        XCTAssertNil(diag.selectedSecurityType)
        XCTAssertNil(diag.serverInit)
        XCTAssertNil(diag.encryptionMode)
        XCTAssertFalse(diag.isHighPerformanceMode)
        XCTAssertNil(diag.connectionStartTime)
        XCTAssertNil(diag.handshakeCompleteTime)
        XCTAssertNil(diag.lastError)
    }

    func testSummaryContainsBasicInfo() {
        let diag = ConnectionDiagnostics()
        diag.serverVersion = .v3_8
        diag.clientVersion = .v3_8
        diag.offeredSecurityTypes = [.none, .vncAuthentication]
        diag.selectedSecurityType = .vncAuthentication

        let si = ServerInit(framebufferWidth: 1920, framebufferHeight: 1080, pixelFormat: .bgra8888, name: "TestServer")
        diag.serverInit = si
        diag.encryptionMode = "ChaCha20-Poly1305"

        let summary = diag.summary()
        XCTAssertTrue(summary.contains("VNC Connection Diagnostics"))
        XCTAssertTrue(summary.contains("Server Version"))
        XCTAssertTrue(summary.contains("Client Version"))
        XCTAssertTrue(summary.contains("Offered Security Types"))
        XCTAssertTrue(summary.contains("Selected Security Type"))
        XCTAssertTrue(summary.contains("TestServer"))
        XCTAssertTrue(summary.contains("1920x1080"))
        XCTAssertTrue(summary.contains("ChaCha20-Poly1305"))
    }

    func testSummaryMinimalInfo() {
        let diag = ConnectionDiagnostics()
        let summary = diag.summary()
        XCTAssertTrue(summary.contains("VNC Connection Diagnostics"))
        XCTAssertTrue(summary.contains("High-Performance Mode: false"))
    }

    func testSummaryWithError() {
        let diag = ConnectionDiagnostics()
        diag.lastError = .authenticationFailed("bad password")
        let summary = diag.summary()
        XCTAssertTrue(summary.contains("Last Error"))
        XCTAssertTrue(summary.contains("bad password"))
    }

    func testSummaryWithHandshakeDuration() {
        let diag = ConnectionDiagnostics()
        let start = Date()
        diag.connectionStartTime = start
        diag.handshakeCompleteTime = start.addingTimeInterval(0.250)

        let summary = diag.summary()
        XCTAssertTrue(summary.contains("Handshake Duration"))
        XCTAssertTrue(summary.contains("0.250"))
    }

    func testSummaryShowsTraceEntryCount() {
        let diag = ConnectionDiagnostics()
        diag.protocolTrace.recordSent(type: "Test", data: Data([0]))
        diag.protocolTrace.recordSent(type: "Test2", data: Data([1]))

        let summary = diag.summary()
        XCTAssertTrue(summary.contains("Trace Entries: 2"))
    }
}

// MARK: - VNCConnectionState Tests

final class VNCConnectionStateTests: XCTestCase {

    func testCanConnect() {
        XCTAssertTrue(VNCConnectionState.idle.canConnect)
        XCTAssertTrue(VNCConnectionState.disconnected.canConnect)
        XCTAssertTrue(VNCConnectionState.failed("error").canConnect)

        XCTAssertFalse(VNCConnectionState.connecting.canConnect)
        XCTAssertFalse(VNCConnectionState.connected.canConnect)
        XCTAssertFalse(VNCConnectionState.reconnecting(attempt: 2, delay: 2).canConnect)
        XCTAssertFalse(VNCConnectionState.disconnecting.canConnect)
    }

    func testIsConnected() {
        XCTAssertTrue(VNCConnectionState.connected.isConnected)
        XCTAssertFalse(VNCConnectionState.idle.isConnected)
        XCTAssertFalse(VNCConnectionState.connecting.isConnected)
        XCTAssertFalse(VNCConnectionState.reconnecting(attempt: 1, delay: 1).isConnected)
        XCTAssertFalse(VNCConnectionState.disconnecting.isConnected)
        XCTAssertFalse(VNCConnectionState.disconnected.isConnected)
        XCTAssertFalse(VNCConnectionState.failed("err").isConnected)
    }

    func testIsConnecting() {
        XCTAssertTrue(VNCConnectionState.connecting.isConnecting)
        XCTAssertTrue(VNCConnectionState.reconnecting(attempt: 1, delay: 1).isConnecting)
        XCTAssertFalse(VNCConnectionState.idle.isConnecting)
        XCTAssertFalse(VNCConnectionState.connected.isConnecting)
    }

    func testEquatable() {
        XCTAssertEqual(VNCConnectionState.idle, VNCConnectionState.idle)
        XCTAssertEqual(VNCConnectionState.connected, VNCConnectionState.connected)
        XCTAssertEqual(VNCConnectionState.failed("a"), VNCConnectionState.failed("a"))
        XCTAssertNotEqual(VNCConnectionState.idle, VNCConnectionState.connecting)
        XCTAssertNotEqual(VNCConnectionState.failed("a"), VNCConnectionState.failed("b"))
    }

    func testInitFromProtocolState() {
        XCTAssertEqual(VNCConnectionState(from: .idle), .idle)
        XCTAssertEqual(VNCConnectionState(from: .connecting), .connecting)
        XCTAssertEqual(VNCConnectionState(from: .waitingForProtocolVersion), .connecting)
        XCTAssertEqual(VNCConnectionState(from: .waitingForSecurityTypes), .connecting)
        XCTAssertEqual(VNCConnectionState(from: .authenticating(.vncAuthentication)), .connecting)
        XCTAssertEqual(VNCConnectionState(from: .waitingForAuthResult), .connecting)
        XCTAssertEqual(VNCConnectionState(from: .waitingForServerInit), .connecting)
        XCTAssertEqual(VNCConnectionState(from: .operational), .connected)
        XCTAssertEqual(VNCConnectionState(from: .disconnecting), .disconnecting)
        XCTAssertEqual(VNCConnectionState(from: .disconnected), .disconnected)

        if case .failed = VNCConnectionState(from: .failed(.connectionClosed)) {
            // good
        } else {
            XCTFail("Expected .failed state")
        }
    }
}

// MARK: - Video Band Geometry Tests

final class VideoBandGeometryTests: XCTestCase {

    @MainActor
    func testAcceptedMatchClientGeometryUpdatesSessionAndGPUAspectTogether() async throws {
        let session = VNCSession(configuration: VNCConfiguration(
            videoQualityMode: .adaptive,
            displaySizingMode: .matchClient))
        session.framebufferWidth = 2976
        session.framebufferHeight = 1860
        session.videoBandRenderer.setViewBounds(
            CGRect(x: 0, y: 0, width: 1000, height: 1000))
        session.videoBandRenderer.setScreenSize(width: 2976, height: 1860)
        let requested = try XCTUnwrap(RemoteDisplaySize.matching(
            viewSize: CGSize(width: 1024, height: 1366)))

        await session.applyRequestedRemoteDisplayGeometry(requested)

        XCTAssertEqual(session.framebufferWidth, Int(requested.pixelWidth))
        XCTAssertEqual(session.framebufferHeight, Int(requested.pixelHeight))
        let frame = session.videoBandRenderer.containerLayer.frame
        XCTAssertEqual(
            frame.width / frame.height,
            CGFloat(requested.pixelWidth) / CGFloat(requested.pixelHeight),
            accuracy: 0.0001,
            "The GUI must aspect-fit using the accepted Match Client geometry")
    }

    @MainActor
    func testAdaptiveAuthoritativeGeometryCreatesAndResizesCursorFramebuffer() async throws {
        let session = VNCSession(configuration: VNCConfiguration(
            videoQualityMode: .adaptive,
            displaySizingMode: .matchClient))
        XCTAssertNil(session.standardFramebufferSize)

        let initial = try XCTUnwrap(RemoteDisplaySize.matching(
            viewSize: CGSize(width: 1024, height: 1366)))
        await session.applyRequestedRemoteDisplayGeometry(initial)

        XCTAssertEqual(
            session.standardFramebufferSize,
            CGSize(width: Int(initial.pixelWidth), height: Int(initial.pixelHeight)),
            "Authoritative geometry must install the renderer used by cursor updates")

        let resized = try XCTUnwrap(RemoteDisplaySize.matching(
            viewSize: CGSize(width: 1366, height: 1024)))
        await session.applyRequestedRemoteDisplayGeometry(resized)

        XCTAssertEqual(
            session.standardFramebufferSize,
            CGSize(width: Int(resized.pixelWidth), height: Int(resized.pixelHeight)),
            "A live Adaptive resize must keep the cursor framebuffer in sync")
    }

    @MainActor
    func testAdaptiveAllDisplaysGeometryInstallsUnionCursorFramebuffer() async {
        let session = VNCSession(configuration: VNCConfiguration(
            videoQualityMode: .adaptive,
            displayCount: 2,
            displayMode: .allDisplaysCombined))
        await session.updateRemoteDisplayRegions([
            RFBScreenLayout(
                id: 1, x: 0, y: 0,
                width: 16, height: 8, flags: 0),
            RFBScreenLayout(
                id: 2, x: 16, y: 0,
                width: 16, height: 8, flags: 0),
        ])
        XCTAssertNil(session.standardFramebufferSize)

        await session.applyAcceptedMediaStreamGeometry(VideoFrameGeometry(
            width: 16,
            height: 8,
            mediaGeneration: 1))

        XCTAssertEqual(session.framebufferWidth, 32)
        XCTAssertEqual(session.framebufferHeight, 8)
        XCTAssertEqual(
            session.standardFramebufferSize,
            CGSize(width: 32, height: 8),
            "All Displays must install the union renderer used by cursor updates")
    }

    @MainActor
    func testAdaptiveDeferredDisplayLayoutInstallsFallbackFramebuffer() async {
        let session = VNCSession(configuration: VNCConfiguration(
            videoQualityMode: .adaptive,
            displayCount: 2,
            displayMode: .allDisplaysCombined))
        await session.handleServerInit(ServerInit(
            framebufferWidth: 0,
            framebufferHeight: 0,
            pixelFormat: .bgra8888,
            name: "deferred-adaptive"))

        await session.updateRemoteDisplayRegions([
            AppleDisplayInfo(
                displayIndex: 1,
                originX: 0,
                originY: 0,
                width: 16,
                height: 8,
                flags: 0),
            AppleDisplayInfo(
                displayIndex: 2,
                originX: 16,
                originY: 0,
                width: 16,
                height: 8,
                flags: 0),
        ])

        XCTAssertEqual(session.framebufferWidth, 32)
        XCTAssertEqual(session.framebufferHeight, 8)
        XCTAssertEqual(
            session.standardFramebufferSize,
            CGSize(width: 32, height: 8),
            "DisplayInfo must make 2D fallback/cursor updates consumable before HEVC")
    }

    @MainActor
    func testLiveScreenResizeRecomputesAspectFitContainer() {
        let renderer = VideoBandLayerRenderer()
        renderer.setViewBounds(CGRect(x: 0, y: 0, width: 1000, height: 1000))
        renderer.setScreenSize(width: 1920, height: 1080)

        XCTAssertEqual(renderer.containerLayer.frame.width, 1000, accuracy: 0.001)
        XCTAssertEqual(renderer.containerLayer.frame.height, 562.5, accuracy: 0.001)
        XCTAssertEqual(renderer.containerLayer.frame.minY, 218.75, accuracy: 0.001)

        renderer.setScreenSize(width: 1000, height: 1000)

        XCTAssertEqual(renderer.containerLayer.frame.minX, 0, accuracy: 0.001)
        XCTAssertEqual(renderer.containerLayer.frame.minY, 0, accuracy: 0.001)
        XCTAssertEqual(renderer.containerLayer.frame.width, 1000, accuracy: 0.001)
        XCTAssertEqual(renderer.containerLayer.frame.height, 1000, accuracy: 0.001)
    }

    @MainActor
    func testNewMediaGenerationRetainsOldFrameUntilAtomicReplacement() throws {
        let renderer = VideoBandLayerRenderer()
        renderer.setViewBounds(CGRect(x: 0, y: 0, width: 100, height: 100))
        renderer.setScreenSize(width: 100, height: 100)

        renderer.setBands([1: try makePixelBuffer(width: 100, height: 100)])
        XCTAssertEqual(renderer.containerLayer.sublayers?.count, 1)

        renderer.beginStreamGeneration()
        XCTAssertEqual(
            renderer.containerLayer.sublayers?.count,
            1,
            "The last complete frame should remain visible during negotiation")

        renderer.setBands([2: try makePixelBuffer(width: 100, height: 100)])
        XCTAssertEqual(
            renderer.containerLayer.sublayers?.count,
            1,
            "The first new frame must replace, not accumulate with, old SSRC layers")
    }

    @MainActor
    func testCommittedHighPerformanceFrameIsAvailableForVision() throws {
        let renderer = VideoBandLayerRenderer()
        renderer.setScreenSize(width: 100, height: 100)
        var committedSize: CGSize?
        renderer.onFrameCommitted = { buffer, _ in
            committedSize = CGSize(
                width: CVPixelBufferGetWidth(buffer),
                height: CVPixelBufferGetHeight(buffer))
        }

        renderer.setBands([1: try makePixelBuffer(width: 100, height: 100)])

        XCTAssertEqual(committedSize, CGSize(width: 100, height: 100))
    }

    @MainActor
    func testCommittedHighPerformanceFrameIdentifiesMediaGeneration() throws {
        let renderer = VideoBandLayerRenderer()
        renderer.setScreenSize(width: 100, height: 100)
        var committedGenerations: [UInt64] = []
        renderer.onFrameCommitted = { _, generation in
            committedGenerations.append(generation)
        }

        renderer.setBands([1: try makePixelBuffer(width: 100, height: 100)])
        renderer.beginStreamGeneration()
        renderer.setBands([2: try makePixelBuffer(width: 100, height: 100)])

        XCTAssertEqual(committedGenerations, [0, 1])
    }

    @MainActor
    func testMatchClientVisionRejectsRetiredSizeFrame() throws {
        let session = VNCSession(configuration: VNCConfiguration(
            videoQualityMode: .adaptive,
            displaySizingMode: .matchClient))
        let viewSize = CGSize(width: 1000, height: 700)
        let expected = try XCTUnwrap(
            RemoteDisplaySize.matching(viewSize: viewSize))
        session.updateRemoteDisplaySize(viewSize: viewSize, displayScale: 2)

        let matching = try makePixelBuffer(
            width: Int(expected.pixelWidth),
            height: Int(expected.pixelHeight))
        let retired = try makePixelBuffer(width: 2976, height: 1860)

        XCTAssertTrue(
            session.isEligibleHighPerformanceLoginVisionFrame(matching))
        XCTAssertFalse(
            session.isEligibleHighPerformanceLoginVisionFrame(retired))
    }

    @MainActor
    func testPartialFinalBandIsStitchedAndClippedToDesktop() throws {
        let renderer = VideoBandLayerRenderer()
        renderer.setViewBounds(CGRect(x: 0, y: 0, width: 100, height: 110))
        renderer.setScreenSize(width: 100, height: 110)
        renderer.setBands([
            10: try makePixelBuffer(width: 100, height: 30),
            11: try makePixelBuffer(width: 100, height: 30),
            12: try makePixelBuffer(width: 100, height: 30),
            13: try makePixelBuffer(width: 100, height: 30),
        ])

        let frames = try XCTUnwrap(renderer.containerLayer.sublayers).map(\.frame)
        XCTAssertEqual(
            frames.count,
            1,
            "Compound bands must be presented through one atomic display layer")
        let stitchedFrame = try XCTUnwrap(frames.first)
        XCTAssertEqual(stitchedFrame.height, 110, accuracy: 0.001)
        XCTAssertEqual(stitchedFrame.maxY, 110, accuracy: 0.001)
        XCTAssertEqual(renderer.containerLayer.bounds.height, 110, accuracy: 0.001)
        XCTAssertTrue(renderer.containerLayer.masksToBounds)
    }

    private func makePixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            nil,
            &buffer)
        XCTAssertEqual(status, kCVReturnSuccess)
        return try XCTUnwrap(buffer)
    }
}

// MARK: - TouchInputHandler Tests

final class TouchInputHandlerTests: XCTestCase {

    // MARK: - Button mask constants

    func testButtonMaskConstants() {
        XCTAssertEqual(TouchInputHandler.leftButton, 0x01)
        XCTAssertEqual(TouchInputHandler.middleButton, 0x02)
        XCTAssertEqual(TouchInputHandler.rightButton, 0x04)
        XCTAssertEqual(TouchInputHandler.scrollUp, 0x08)
        XCTAssertEqual(TouchInputHandler.scrollDown, 0x10)
    }

    // MARK: - Tap generates move + press + release

    @MainActor
    func testHandleTap() {
        var events: [(UInt8, UInt16, UInt16)] = []
        let handler = TouchInputHandler { mask, x, y in
            events.append((mask, x, y))
        }

        handler.handleTap(x: 100, y: 200)
        XCTAssertEqual(events.count, 3)
        // Move
        XCTAssertEqual(events[0].0, 0)
        XCTAssertEqual(events[0].1, 100)
        XCTAssertEqual(events[0].2, 200)
        // Press
        XCTAssertEqual(events[1].0, TouchInputHandler.leftButton)
        XCTAssertEqual(events[1].1, 100)
        XCTAssertEqual(events[1].2, 200)
        // Release
        XCTAssertEqual(events[2].0, 0)
        XCTAssertEqual(events[2].1, 100)
        XCTAssertEqual(events[2].2, 200)
    }

    @MainActor
    func testHandleRightClick() {
        var events: [(UInt8, UInt16, UInt16)] = []
        let handler = TouchInputHandler { mask, x, y in
            events.append((mask, x, y))
        }

        handler.handleRightClick(x: 50, y: 75)
        XCTAssertEqual(events.count, 3)
        // Move
        XCTAssertEqual(events[0].0, 0)
        // Press right button
        XCTAssertEqual(events[1].0, TouchInputHandler.rightButton)
        // Release
        XCTAssertEqual(events[2].0, 0)
    }

    @MainActor
    func testHandleMove() {
        var events: [(UInt8, UInt16, UInt16)] = []
        let handler = TouchInputHandler { mask, x, y in
            events.append((mask, x, y))
        }

        handler.handleMove(x: 300, y: 400)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].0, 0) // no buttons
        XCTAssertEqual(events[0].1, 300)
        XCTAssertEqual(events[0].2, 400)
    }

    @MainActor
    func testHandleDrag() {
        var events: [(UInt8, UInt16, UInt16)] = []
        let handler = TouchInputHandler { mask, x, y in
            events.append((mask, x, y))
        }

        handler.handleDrag(x: 150, y: 250)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].0, TouchInputHandler.leftButton)
        XCTAssertEqual(events[0].1, 150)
        XCTAssertEqual(events[0].2, 250)
    }

    @MainActor
    func testHandleDragEnd() {
        var events: [(UInt8, UInt16, UInt16)] = []
        let handler = TouchInputHandler { mask, x, y in
            events.append((mask, x, y))
        }

        handler.handleDragEnd(x: 200, y: 300)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].0, 0) // no buttons (released)
    }

    @MainActor
    func testDragSequenceKeepsLeftButtonPressedUntilRelease() {
        var events: [(UInt8, UInt16, UInt16)] = []
        let handler = TouchInputHandler { mask, x, y in
            events.append((mask, x, y))
        }

        handler.handleDrag(x: 100, y: 200)
        handler.handleDrag(x: 140, y: 240)
        handler.handleDrag(x: 180, y: 280)
        handler.handleDragEnd(x: 180, y: 280)

        XCTAssertEqual(events.map { $0.0 }, [
            TouchInputHandler.leftButton,
            TouchInputHandler.leftButton,
            TouchInputHandler.leftButton,
            0,
        ])
        XCTAssertEqual(events.map { $0.1 }, [100, 140, 180, 180])
        XCTAssertEqual(events.map { $0.2 }, [200, 240, 280, 280])
    }

    @MainActor
    func testHandleDoubleTap() {
        var events: [(UInt8, UInt16, UInt16)] = []
        let handler = TouchInputHandler { mask, x, y in
            events.append((mask, x, y))
        }

        handler.handleDoubleTap(x: 100, y: 100)
        // Double tap = 2 taps, each tap = 3 events (move + press + release)
        XCTAssertEqual(events.count, 6)
    }

    @MainActor
    func testHandleScrollDown() {
        var events: [(UInt8, UInt16, UInt16)] = []
        let handler = TouchInputHandler { mask, x, y in
            events.append((mask, x, y))
        }

        // Negative CGEvent deltaY = scroll down
        handler.handleScroll(x: 100, y: 100, deltaY: -10)
        // At least one press+release pair
        XCTAssertGreaterThanOrEqual(events.count, 2)
        // Verify we get scrollDown button
        let pressEvents = events.filter { $0.0 == TouchInputHandler.scrollDown }
        XCTAssertFalse(pressEvents.isEmpty)
    }

    @MainActor
    func testHandleScrollUp() {
        var events: [(UInt8, UInt16, UInt16)] = []
        let handler = TouchInputHandler { mask, x, y in
            events.append((mask, x, y))
        }

        // Positive CGEvent deltaY = scroll up
        handler.handleScroll(x: 100, y: 100, deltaY: 10)
        let pressEvents = events.filter { $0.0 == TouchInputHandler.scrollUp }
        XCTAssertFalse(pressEvents.isEmpty)
    }

    @MainActor
    func testHandleScrollLargeDelta() {
        var events: [(UInt8, UInt16, UInt16)] = []
        let handler = TouchInputHandler { mask, x, y in
            events.append((mask, x, y))
        }

        // Large delta should produce multiple scroll steps
        handler.handleScroll(x: 100, y: 100, deltaY: 50)
        let pressEvents = events.filter { $0.0 == TouchInputHandler.scrollUp }
        XCTAssertGreaterThanOrEqual(pressEvents.count, 5) // 50/10 = 5 steps
    }

    @MainActor
    func testExactScrollSteps() {
        var events: [(UInt8, UInt16, UInt16)] = []
        let handler = TouchInputHandler { mask, x, y in
            events.append((mask, x, y))
        }

        handler.handleScroll(x: 20, y: 30, steps: -3)

        XCTAssertEqual(events.count, 6)
        XCTAssertEqual(events.map(\.0), [
            TouchInputHandler.scrollDown, 0,
            TouchInputHandler.scrollDown, 0,
            TouchInputHandler.scrollDown, 0,
        ])
    }

    @MainActor
    func testPreciseScrollPreservesPointsPhaseAndDirection() {
        var scrollEvents: [AppleScrollEvent] = []
        let handler = TouchInputHandler(
            sendPointerEvent: { _, _, _ in
                XCTFail("Precise input should go through the scroll event path")
            },
            sendScrollEvent: { scrollEvents.append($0) })

        handler.handleScroll(
            x: 20,
            y: 30,
            pointDeltaX: 1,
            pointDeltaY: -4,
            scrollPhase: .changed)

        XCTAssertEqual(scrollEvents.count, 1)
        let event = scrollEvents[0]
        // Sub-wheel-unit motion must not round up to a whole wheel line;
        // line-based scrollers read the coarse field at sample rate.
        XCTAssertEqual(event.deltaX, 0)
        XCTAssertEqual(event.deltaY, 0)
        XCTAssertEqual(event.pointDeltaX, 1)
        XCTAssertEqual(event.pointDeltaY, -4)
        XCTAssertEqual(event.fixedDeltaX, 6_553)
        XCTAssertEqual(event.fixedDeltaY, -26_214)
        XCTAssertEqual(event.scrollPhase, .changed)
        XCTAssertEqual(event.flags, [.continuous, .directionInvertedFromDevice])
        XCTAssertEqual(event.x, 20)
        XCTAssertEqual(event.y, 30)
    }

    @MainActor
    func testPreciseScrollGestureEnvelopeUsesTouchSource() {
        var gestureEvents: [AppleGestureEvent] = []
        let handler = TouchInputHandler(
            sendPointerEvent: { _, _, _ in },
            sendScrollEvent: { _ in },
            sendGestureEvent: { gestureEvents.append($0) })

        handler.handleGesture(kind: .began, x: 20, y: 30)
        handler.handleGesture(kind: .ended, x: 21, y: 31)

        XCTAssertEqual(gestureEvents, [
            AppleGestureEvent(kind: .began, x: 20, y: 30),
            AppleGestureEvent(kind: .ended, x: 21, y: 31),
        ])
    }

    @MainActor
    func testPreciseScrollDeltaRepresentationsSaturateSafely() {
        var scrollEvents: [AppleScrollEvent] = []
        let handler = TouchInputHandler(
            sendPointerEvent: { _, _, _ in },
            sendScrollEvent: { scrollEvents.append($0) })

        handler.handleScroll(
            x: 1,
            y: 2,
            pointDeltaX: .max,
            pointDeltaY: .min,
            scrollPhase: .changed)

        XCTAssertEqual(scrollEvents[0].deltaX, .max)
        XCTAssertEqual(scrollEvents[0].deltaY, .min)
        XCTAssertEqual(scrollEvents[0].fixedDeltaX, .max)
        XCTAssertEqual(scrollEvents[0].fixedDeltaY, .min)
    }

    @MainActor
    func testPreciseScrollCarriesExplicitCoarseDeltas() {
        var scrollEvents: [AppleScrollEvent] = []
        let handler = TouchInputHandler(
            sendPointerEvent: { _, _, _ in
                XCTFail("Precise input should go through the scroll event path")
            },
            sendScrollEvent: { scrollEvents.append($0) })

        handler.handleScroll(
            x: 20,
            y: 30,
            pointDeltaX: 4,
            pointDeltaY: -7,
            coarseDeltaX: 0,
            coarseDeltaY: -1,
            scrollPhase: .changed)

        XCTAssertEqual(scrollEvents.count, 1)
        XCTAssertEqual(scrollEvents[0].deltaX, 0)
        XCTAssertEqual(scrollEvents[0].deltaY, -1)
        XCTAssertEqual(scrollEvents[0].pointDeltaX, 4)
        XCTAssertEqual(scrollEvents[0].pointDeltaY, -7)
    }

    func testReleaseVelocityIgnoresLiftOffReversalWobble() {
        var estimator = ScrollReleaseVelocityEstimator()

        // A steady 120 Hz upward drag at 600 pt/s...
        var position = CGPoint(x: 0, y: 0)
        var timestamp: CFTimeInterval = 10
        estimator.record(position: position, at: timestamp)
        for _ in 0..<24 {
            timestamp += 1.0 / 120.0
            position.y -= 5
            estimator.record(position: position, at: timestamp)
        }
        // ...followed by a tiny reversal wobble as the finger leaves the glass.
        timestamp += 0.004
        position.y += 1
        estimator.record(position: position, at: timestamp)

        let velocity = estimator.releaseVelocity(at: timestamp + 0.002)
        // The single-sample estimate would be +250 pt/s (the wobble). The
        // windowed estimate must remain close to the real drag velocity.
        XCTAssertLessThan(velocity.y, -400)
    }

    func testReleaseVelocityIsZeroAfterRestingBeforeLift() {
        var estimator = ScrollReleaseVelocityEstimator()

        var position = CGPoint(x: 0, y: 0)
        var timestamp: CFTimeInterval = 10
        estimator.record(position: position, at: timestamp)
        for _ in 0..<12 {
            timestamp += 1.0 / 120.0
            position.y += 8
            estimator.record(position: position, at: timestamp)
        }

        // The finger rests for 300 ms, then lifts: no fling.
        let velocity = estimator.releaseVelocity(at: timestamp + 0.3)
        XCTAssertEqual(velocity.x, 0)
        XCTAssertEqual(velocity.y, 0)
    }

    func testReleaseVelocityMatchesSteadyDrag() {
        var estimator = ScrollReleaseVelocityEstimator()

        var position = CGPoint(x: 0, y: 0)
        var timestamp: CFTimeInterval = 5
        estimator.record(position: position, at: timestamp)
        for _ in 0..<60 {
            timestamp += 1.0 / 60.0
            position.y += 10
            estimator.record(position: position, at: timestamp)
        }

        let velocity = estimator.releaseVelocity(at: timestamp)
        XCTAssertEqual(velocity.y, 600, accuracy: 20)
        XCTAssertEqual(velocity.x, 0)
    }

    func testReleaseVelocityClampsVeryShortGestures() {
        var estimator = ScrollReleaseVelocityEstimator()

        // Two samples one millisecond apart must not read as a 2000 pt/s
        // fling; the minimum span damps the estimate.
        estimator.record(position: CGPoint(x: 0, y: 0), at: 3)
        estimator.record(position: CGPoint(x: 0, y: 2), at: 3.001)

        let velocity = estimator.releaseVelocity(at: 3.001)
        XCTAssertEqual(velocity.y, 100, accuracy: 0.001)
    }

    func testReleaseVelocityResetClearsHistory() {
        var estimator = ScrollReleaseVelocityEstimator()

        estimator.record(position: CGPoint(x: 0, y: 0), at: 1)
        estimator.record(position: CGPoint(x: 0, y: 50), at: 1.05)
        estimator.reset()

        let velocity = estimator.releaseVelocity(at: 1.06)
        XCTAssertEqual(velocity.x, 0)
        XCTAssertEqual(velocity.y, 0)
    }

    func testWheelUnitAccumulatorAggregatesSlowDrag() {
        var accumulator = ScrollWheelUnitAccumulator()

        // A slow 120 Hz drag of 3 points per sample must produce one wheel
        // unit per ten points of travel, not one per sample.
        var totalY: Int = 0
        for _ in 0..<30 {
            totalY += Int(accumulator.consume(pointDeltaX: 0, pointDeltaY: 3).y)
        }
        XCTAssertEqual(totalY, 9)
        XCTAssertEqual(accumulator.remainderY, 0)
    }

    func testWheelUnitAccumulatorPassesFlingSampleThrough() {
        var accumulator = ScrollWheelUnitAccumulator()

        let fling = accumulator.consume(pointDeltaX: 0, pointDeltaY: -200)
        XCTAssertEqual(fling.y, -20)
        XCTAssertEqual(accumulator.remainderY, 0)
    }

    func testWheelUnitAccumulatorHandlesReversalAndReset() {
        var accumulator = ScrollWheelUnitAccumulator()

        XCTAssertEqual(accumulator.consume(pointDeltaX: 6, pointDeltaY: 0).x, 0)
        XCTAssertEqual(accumulator.consume(pointDeltaX: -9, pointDeltaY: 0).x, 0)
        XCTAssertEqual(accumulator.remainderX, -3)
        XCTAssertEqual(accumulator.consume(pointDeltaX: -8, pointDeltaY: 0).x, -1)

        accumulator.reset()
        XCTAssertEqual(accumulator.remainderX, 0)
        let afterReset = accumulator.consume(pointDeltaX: 9, pointDeltaY: 9)
        XCTAssertEqual(afterReset.x, 0)
        XCTAssertEqual(afterReset.y, 0)
    }

    func testWheelUnitAccumulatorSaturatesSafely() {
        var accumulator = ScrollWheelUnitAccumulator()

        let saturated = accumulator.consume(pointDeltaX: .max, pointDeltaY: .min)
        XCTAssertEqual(saturated.x, .max)
        XCTAssertEqual(saturated.y, .min)
        XCTAssertEqual(accumulator.remainderX, 0)
        XCTAssertEqual(accumulator.remainderY, 0)
    }

    func testScrollPointAccumulatorPreservesSubpointMovement() {
        var accumulator = ScrollPointAccumulator()

        XCTAssertEqual(accumulator.consume(deltaX: 0.4, deltaY: -0.6).x, 0)
        let second = accumulator.consume(deltaX: 0.7, deltaY: -0.6)
        XCTAssertEqual(second.x, 1)
        XCTAssertEqual(second.y, -1)
        XCTAssertEqual(accumulator.remainderX, 0.1, accuracy: 0.0001)
        XCTAssertEqual(accumulator.remainderY, -0.2, accuracy: 0.0001)
    }

    func testHorizontalScrollIntentDropsOpeningVerticalJitter() {
        var filter = HorizontalScrollIntentFilter()

        assertPoint(filter.consume(deltaX: 2, deltaY: 0.8), x: 0, y: 0)
        assertPoint(filter.consume(deltaX: 3, deltaY: 0.7), x: 5, y: 0)
        XCTAssertTrue(filter.isHorizontallyLocked)
        assertPoint(filter.consume(deltaX: 4, deltaY: -2), x: 4, y: 0)
    }

    func testAmbiguousTouchOpeningCanResolveHorizontally() {
        var filter = HorizontalScrollIntentFilter()

        assertPoint(filter.consume(deltaX: 3, deltaY: 4), x: 0, y: 0)
        assertPoint(filter.consume(deltaX: 4, deltaY: 0), x: 7, y: 0)
    }

    func testVerticalAndDiagonalScrollRemainUnrestricted() {
        var vertical = HorizontalScrollIntentFilter()
        assertPoint(vertical.consume(deltaX: 1, deltaY: 5), x: 1, y: 5)
        XCTAssertFalse(vertical.isHorizontallyLocked)
        assertPoint(vertical.consume(deltaX: 2, deltaY: 3), x: 2, y: 3)

        var diagonal = HorizontalScrollIntentFilter()
        assertPoint(diagonal.consume(deltaX: 3, deltaY: 3), x: 0, y: 0)
        assertPoint(diagonal.consume(deltaX: 5, deltaY: 5), x: 8, y: 8)
    }

    func testShortUndecidedScrollFlushesWithoutLosingMovement() {
        var filter = HorizontalScrollIntentFilter()

        assertPoint(filter.consume(deltaX: 1.5, deltaY: -1), x: 0, y: 0)
        assertPoint(filter.flush(), x: 1.5, y: -1)
        assertPoint(filter.flush(), x: 0, y: 0)
    }

    private func assertPoint(
        _ point: CGPoint,
        x: CGFloat,
        y: CGFloat,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(point.x, x, accuracy: 0.0001, file: file, line: line)
        XCTAssertEqual(point.y, y, accuracy: 0.0001, file: file, line: line)
    }

    func testInputQueueCoalescesStalePointerPositionsButKeepsRunStart() {
        var queue = SessionInputQueue()
        queue.enqueue(.pointer(buttonMask: 1, x: 10, y: 20))
        queue.enqueue(.pointer(buttonMask: 1, x: 11, y: 21))
        queue.enqueue(.pointer(buttonMask: 1, x: 12, y: 22))
        queue.enqueue(.pointer(buttonMask: 1, x: 13, y: 23))
        queue.enqueue(.pointer(buttonMask: 0, x: 13, y: 23))

        XCTAssertEqual(queue.pending, [
            .pointer(buttonMask: 1, x: 10, y: 20),
            .pointer(buttonMask: 1, x: 13, y: 23),
            .pointer(buttonMask: 0, x: 13, y: 23),
        ])
    }

    func testInputQueueMergesOnlyContinuousScrollSamples() {
        func scroll(
            _ y: Int32,
            phase: AppleScrollEvent.Phase,
            x: UInt16
        ) -> SessionInputEvent {
            .scroll(AppleScrollEvent(
                deltaY: y == 0 ? 0 : (y > 0 ? 1 : -1),
                pointDeltaY: y,
                scrollPhase: phase,
                scrollCount: 1,
                flags: [.continuous],
                x: x,
                y: 20))
        }

        var queue = SessionInputQueue()
        queue.enqueue(scroll(0, phase: .began, x: 10))
        queue.enqueue(scroll(3, phase: .changed, x: 11))
        queue.enqueue(scroll(4, phase: .changed, x: 12))
        queue.enqueue(scroll(0, phase: .ended, x: 12))

        XCTAssertEqual(queue.count, 3)
        guard case .scroll(let merged) = queue.pending[1] else {
            return XCTFail("Expected merged continuous scroll")
        }
        XCTAssertEqual(merged.deltaY, 2)
        XCTAssertEqual(merged.pointDeltaY, 7)
        XCTAssertEqual(merged.scrollCount, 2)
        XCTAssertEqual(merged.x, 12)
        XCTAssertEqual(merged.scrollPhase, .changed)
    }

    func testInputQueueKeepsGestureEnvelopeAsScrollOrderingBarrier() {
        let changed = AppleScrollEvent(
            pointDeltaY: 3,
            scrollPhase: .changed,
            flags: [.continuous],
            x: 10,
            y: 20)
        let end = AppleGestureEvent(kind: .ended, x: 10, y: 20)
        var queue = SessionInputQueue()

        queue.enqueue(.scroll(changed))
        queue.enqueue(.gesture(end))
        queue.enqueue(.scroll(changed))

        XCTAssertEqual(queue.pending, [
            .scroll(changed),
            .gesture(end),
            .scroll(changed),
        ])
    }

    @MainActor
    func testCoordinatePassthrough() {
        var events: [(UInt8, UInt16, UInt16)] = []
        let handler = TouchInputHandler { mask, x, y in
            events.append((mask, x, y))
        }

        // Test edge coordinates
        handler.handleMove(x: 0, y: 0)
        handler.handleMove(x: UInt16.max, y: UInt16.max)
        handler.handleMove(x: 1920, y: 1080)

        XCTAssertEqual(events[0].1, 0)
        XCTAssertEqual(events[0].2, 0)
        XCTAssertEqual(events[1].1, UInt16.max)
        XCTAssertEqual(events[1].2, UInt16.max)
        XCTAssertEqual(events[2].1, 1920)
        XCTAssertEqual(events[2].2, 1080)
    }
}

// MARK: - VNCError Tests

final class VNCErrorTests: XCTestCase {

    func testErrorDescriptions() {
        XCTAssertNotNil(VNCError.notConnected.errorDescription)
        XCTAssertNotNil(VNCError.alreadyConnected.errorDescription)
        XCTAssertNotNil(VNCError.connectionFailed("test").errorDescription)
        XCTAssertNotNil(VNCError.authenticationFailed("test").errorDescription)
        XCTAssertNotNil(VNCError.protocolError(.connectionClosed).errorDescription)
        XCTAssertNotNil(VNCError.framebufferError("test").errorDescription)
        XCTAssertNotNil(VNCError.unsupportedFeature("test").errorDescription)
    }

    func testErrorDescriptionsContainDetails() {
        XCTAssertTrue(VNCError.connectionFailed("timeout").errorDescription!.contains("timeout"))
        XCTAssertTrue(VNCError.authenticationFailed("bad pw").errorDescription!.contains("bad pw"))
        XCTAssertTrue(VNCError.framebufferError("alloc").errorDescription!.contains("alloc"))
        XCTAssertTrue(VNCError.unsupportedFeature("H.265").errorDescription!.contains("H.265"))
    }
}
