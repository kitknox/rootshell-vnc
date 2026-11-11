import Compression
import Foundation
import RFBProtocol
import XCTest
@testable import RFBTransport

final class AppleMediaNegotiationTests: XCTestCase {
    func testMediaDisplayInfo2ControlEmitsLoginWindowState() async throws {
        let connection = ScriptedRFBConnection()
        let session = TransportSession(
            host: "scripted.test",
            port: 5900,
            password: "secret",
            preferredEncodings: [.appleH264, .unknown(1105)],
            connection: connection)

        // Apple media controls place the encoding at byte 14. The control
        // length word is retained as DisplayInfo2's leading length field.
        var payload = Data(repeating: 0, count: 36)
        payload[0] = 0x20
        payload[14] = 0x04
        payload[15] = 0x51
        payload[16] = 0
        payload[17] = 20
        payload[18] = 0
        payload[19] = 5
        payload[35] = 0x08

        let eventTask = Task { () -> AppleRemoteSessionState? in
            for await event in session.events {
                guard case .appleRemoteSessionState(let state) = event else {
                    continue
                }
                return state
            }
            return nil
        }
        let handled = try await session.ingestAppleMediaServerControlPayload(
            payload)
        let state = await eventTask.value

        XCTAssertTrue(handled)
        XCTAssertEqual(state?.loginWindowActive, false)
        XCTAssertEqual(state?.loginWindowLockScreenActive, true)
        XCTAssertEqual(state?.requiresLogin, true)
    }

    func testMediaDisplayInfo2EmitsLegacyRecordsAndAtomicLayout() async throws {
        let connection = ScriptedRFBConnection()
        let session = TransportSession(
            host: "scripted.test",
            port: 5900,
            password: "secret",
            preferredEncodings: [.appleH264, .unknown(1105)],
            connection: connection)
        let displays = [
            AppleDisplayInfo(
                displayIndex: 11,
                originX: 0,
                originY: 0,
                width: 1728,
                height: 1117,
                flags: 1),
            AppleDisplayInfo(
                displayIndex: 12,
                originX: 1728,
                originY: 0,
                width: 1920,
                height: 1080,
                flags: 0),
        ]

        let eventTask = Task {
            var records: [AppleDisplayInfo] = []
            for await event in session.events {
                switch event {
                case .displayInfo(let display):
                    records.append(display)
                case .appleDisplayLayout(let layout):
                    return (records, layout)
                default:
                    break
                }
            }
            return (records, [])
        }
        let handled = try await session.ingestAppleMediaServerControlPayload(
            appleMediaDisplayInfo2ControlTestPayload(displays: displays))
        let observed = await eventTask.value

        XCTAssertTrue(handled)
        XCTAssertEqual(observed.0, displays)
        XCTAssertEqual(observed.1, displays)
    }

    func testFindsTwoByteWrappedDecryptedRFBUpdate() {
        let update = Data([0, 0, 0, 1])
            + Self.rectangleHeader(encoding: 1104)
            + Data([0, 0, 0, 7, 0, 0, 0, 0])

        XCTAssertEqual(appleRFBServerMessageOffset(in: update), 0)
        XCTAssertEqual(
            appleRFBServerMessageOffset(in: Data([0x12, 0x34]) + update),
            2)
    }

    func testDecryptedUpdateReachesCursorAfterDisplayInfo() async throws {
        let connection = ScriptedRFBConnection()
        let session = TransportSession(
            host: "scripted.test",
            port: 5900,
            password: "",
            preferredEncodings: [.appleH264, .unknown(1105), .unknown(1104)],
            connection: connection)

        var displayInfo = Data(repeating: 0, count: 78)
        displayInfo[0] = 0
        displayInfo[1] = 76
        var update = Data([0, 0, 0, 2])
        update.append(Self.rectangleHeader(encoding: 1105))
        update.append(displayInfo)
        update.append(Self.rectangleHeader(encoding: 1104))
        // Cache reference: identifier 7 followed by a zero compressed length.
        update.append(contentsOf: [0, 0, 0, 7, 0, 0, 0, 0])

        let eventTask = Task { () -> [Encoding] in
            for await event in session.events {
                guard case .framebufferUpdate(let rects) = event else { continue }
                return rects.map(\.0.encoding)
            }
            return []
        }
        try await session.ingestAppleDecryptedRFBPayload(update)

        let encodings = await eventTask.value
        XCTAssertEqual(encodings, [.unknown(1105), .unknown(1104)])

        // HEVC carries screen pixels, but the native hardware-cursor path
        // keeps polling this encrypted RFB channel for cursor pseudo-rects.
        try await session.finishFramebufferUpdate()
        let sent = await connection.sentBytes()
        XCTAssertEqual(sent.count, 10)
        XCTAssertEqual(Array(sent.prefix(2)), [3, 1])
    }

    func testPostAcceptEncodingsRetainAppleLocalCursorCapabilities() {
        let encodings = TransportSession.appleMediaPostAcceptEncodings(
            from: [.appleH264, .zlib, .raw, .unknown(1104), .unknown(1100)])

        XCTAssertTrue(encodings.contains(.unknown(1104)))
        XCTAssertTrue(encodings.contains(.unknown(1100)))
        XCTAssertTrue(encodings.contains(.cursor))
        XCTAssertLessThan(
            try XCTUnwrap(encodings.firstIndex(of: .unknown(1104))),
            try XCTUnwrap(encodings.firstIndex(of: .cursor)))
    }

    /// The post-accept list is rebuilt from `preferredEncodings`, so it needs
    /// the same "never advertise what the parsers cannot frame" guarantee as
    /// `VNCConfiguration.effectiveEncodings`.
    func testPostAcceptEncodingsRejectUnframeableContent() {
        let encodings = TransportSession.appleMediaPostAcceptEncodings(
            from: [.appleH264, .appleSubZlibThousands, .zlib, .raw])

        XCTAssertFalse(encodings.contains(.appleSubZlibThousands))
        XCTAssertTrue(encodings.contains(.appleH264))
        XCTAssertTrue(encodings.contains(.zlib))
        XCTAssertTrue(encodings.contains(.raw))
    }

    /// Asking the server to draw the pointer means advertising no cursor
    /// pseudo-encoding at all. 0x450 and 0x44c are Apple's cached alpha cursor
    /// records; the generic `.cursor` shape has to go with them, or the server
    /// still withholds the pointer from the picture.
    func testPostAcceptEncodingsDropCursorCapabilitiesWhenServerRendersCursor() {
        let encodings = TransportSession.appleMediaPostAcceptEncodings(
            from: [.appleH264, .zlib, .raw, .unknown(1104), .unknown(1100)],
            serverRendersCursor: true)

        XCTAssertFalse(encodings.contains(.unknown(1104)))
        XCTAssertFalse(encodings.contains(.unknown(1100)))
        XCTAssertFalse(encodings.contains(.cursor))
        XCTAssertFalse(encodings.contains(.xCursor))
        // The rest of the post-accept list is unaffected.
        XCTAssertTrue(encodings.contains(.appleH264))
        XCTAssertTrue(encodings.contains(.desktopSize))
        XCTAssertTrue(encodings.contains(.unknown(0x451)))
    }

    /// Bit 2 is the "viewer composites the cursor itself" requirement, so a
    /// server-rendered pointer is expressed by clearing it.
    func testReceiverFlagsClearCursorBitWhenServerSendsCursor() {
        XCTAssertEqual(
            appleMediaReceiverFlags(displayCount: 1, sendsCursor: true) & 0x04,
            0)
        XCTAssertEqual(
            appleMediaReceiverFlags(displayCount: 1, sendsCursor: false) & 0x04,
            0x04)
        // Clearing it must not disturb the 60-fps receiver bits.
        XCTAssertEqual(
            appleMediaReceiverFlags(
                displayCount: 2,
                supports60FPS: true,
                sendsCursor: true),
            0x03)
    }

    func testNativeScreenSharingReceiverFlagsTrackSixtyFPSCapability() {
        XCTAssertEqual(appleMediaReceiverFlags(displayCount: 1), 0x04)
        XCTAssertEqual(appleMediaReceiverFlags(displayCount: 2), 0x04)
        XCTAssertEqual(
            appleMediaReceiverFlags(displayCount: 1, supports60FPS: true),
            0x05)
        XCTAssertEqual(
            appleMediaReceiverFlags(displayCount: 2, supports60FPS: true),
            0x07)
    }

    private static func rectangleHeader(encoding: Int32) -> Data {
        var data = Data(repeating: 0, count: FramebufferRect.wireSize)
        let raw = UInt32(bitPattern: encoding)
        data[8] = UInt8((raw >> 24) & 0xff)
        data[9] = UInt8((raw >> 16) & 0xff)
        data[10] = UInt8((raw >> 8) & 0xff)
        data[11] = UInt8(raw & 0xff)
        return data
    }

    func testReceiverFlagsKeepAppleRemoteDesktopIdentityDistinct() {
        XCTAssertEqual(
            appleMediaReceiverFlags(
                displayCount: 1,
                supports60FPS: true,
                client: .appleRemoteDesktop),
            0x0d)
        XCTAssertEqual(
            appleMediaReceiverFlags(
                displayCount: 1,
                supports60FPS: false,
                sendsCursor: true),
            0)
    }

    func testPublicDecoderUsesConventionalHEVCWithinLevel51FrameBudget() {
        XCTAssertEqual(
            AppleMediaVideoMode.activeTileCount(
                pixelWidth: 2400, pixelHeight: 1680),
            1)
        XCTAssertEqual(
            AppleMediaVideoMode.activeTileCount(
                pixelWidth: 3136, pixelHeight: 1584),
            1)
        XCTAssertEqual(
            AppleMediaVideoMode.activeTileCount(
                pixelWidth: 2048, pixelHeight: 2736),
            1)
        XCTAssertEqual(
            AppleMediaVideoMode.activeTileCount(
                pixelWidth: 5536, pixelHeight: 1392),
            1)
        XCTAssertEqual(
            AppleMediaVideoMode.activeTileCount(
                pixelWidth: 4096, pixelHeight: 2176),
            1)
        XCTAssertEqual(
            AppleMediaVideoMode.activeTileCount(
                pixelWidth: 5120, pixelHeight: 2880),
            4)
        XCTAssertEqual(
            AppleMediaNegotiationProfile.publicDecoderTilesPerFrame(
                pixelWidth: 3664, pixelHeight: 2176),
            1)
        XCTAssertEqual(
            AppleMediaNegotiationProfile.publicDecoderTilesPerFrame(
                pixelWidth: 5120, pixelHeight: 2880),
            4)
        XCTAssertEqual(AppleMediaVideoMode.negotiatedTilesPerFrame, 4)
    }

    func testAggregateDisplayAreaSelectsCompoundProfile() {
        let airPanel = 2976 * 1860
        let scaledExternalDisplay = 3008 * 1692

        XCTAssertEqual(
            AppleMediaVideoMode.negotiatedTilesPerFrame(
                totalLumaSamples: airPanel),
            1)
        XCTAssertEqual(
            AppleMediaVideoMode.negotiatedTilesPerFrame(
                totalLumaSamples: scaledExternalDisplay),
            1)
        XCTAssertEqual(
            AppleMediaVideoMode.negotiatedTilesPerFrame(
                totalLumaSamples: airPanel + scaledExternalDisplay),
            4)
    }

    func testOnlyCapturesBeyondOnePictureNeedFourTiles() {
        XCTAssertFalse(AppleMediaVideoMode.fitsOnePicture(totalLumaSamples: 5120 * 2880))
        XCTAssertTrue(AppleMediaVideoMode.fitsOnePicture(totalLumaSamples: 2048 * 1904))
        XCTAssertTrue(AppleMediaVideoMode.fitsOnePicture(totalLumaSamples: 2720 * 1872))
        XCTAssertFalse(AppleMediaVideoMode.fitsOnePicture(totalLumaSamples: 0))
    }

    func testPublicAirSizedOfferRequestsConventionalSinglePictureHEVC() throws {
        let tiles = AppleMediaNegotiationProfile.publicDecoderTilesPerFrame(
            pixelWidth: 3664,
            pixelHeight: 2176)
        let profile = AppleMediaNegotiationProfile(
            framebufferWidth: 3664,
            framebufferHeight: 2176,
            supportsHDR: false,
            tilesPerFrame: tiles)
        let screen = try XCTUnwrap(ProtoMessage(profile.mediaBlob(
            kind: .screen,
            ssrc: 1,
            ntpTimestamp: 2
        )).message(5))

        XCTAssertEqual(screen.varint(6), 1)
    }

    func testMediaMessageOneAnswerCyclesCreateDistinctGenerations() {
        var tracker = AppleMediaNegotiationGenerationTracker()

        XCTAssertEqual(
            tracker.beginMessageOne(),
            .init(generation: 1, isReconfiguration: false))
        XCTAssertNil(tracker.beginMessageOne())
        XCTAssertTrue(tracker.finishMessageTwo())
        XCTAssertFalse(tracker.finishMessageTwo())

        XCTAssertEqual(
            tracker.beginMessageOne(),
            .init(generation: 2, isReconfiguration: true))
        XCTAssertTrue(tracker.isAwaitingAnswer)
    }

    func testScreenBlobCarriesFreshSessionIdentityAndNamedCapabilities() throws {
        let profile = AppleMediaNegotiationProfile(
            framebufferWidth: 2940,
            framebufferHeight: 1860,
            supportsHDR: false
        )
        let timestamp: UInt64 = 0x1122_3344_5566_7788
        let blob = profile.mediaBlob(
            kind: .screen,
            ssrc: 0xa1b2_c3d4,
            ntpTimestamp: timestamp
        )
        let root = try ProtoMessage(blob)

        XCTAssertEqual(root.varint(1), 1) // allowDynamicMaxBitrate
        XCTAssertEqual(root.varint(2), 1) // content-preserving resize
        XCTAssertEqual(root.string(6), "Viceroy 1.7.0")
        XCTAssertEqual(root.varint(13), timestamp)
        XCTAssertEqual(root.varint(14), 2)
        XCTAssertEqual(root.varint(16), 0)
        XCTAssertEqual(root.varint(18), 1)
        let bandwidthSettings = root.messages(9)
        XCTAssertEqual(bandwidthSettings.count, 10)
        XCTAssertEqual(
            bandwidthSettings.map {
                [$0.varint(1) ?? .max, $0.varint(2) ?? .max, $0.varint(3) ?? 0]
            },
            [
                [4_074, 0, 16_384],
                [4, 6_500, 0],
                [0, 40_000_000, 12_288],
                [0, 60_000_000, 262_144],
                [0, 20_000_000, 98_304],
                [0, 100_000_000, 1_048_576],
                [0, 6_000_000, 131_072],
                [0, 75_000_000, 524_288],
                [16, 4_100, 0],
                [1, 299, 0],
            ])

        let screen = try XCTUnwrap(root.message(5))
        XCTAssertEqual(screen.varint(1), 0xa1b2_c3d4)
        XCTAssertEqual(screen.varint(2), 0)
        XCTAssertEqual(screen.varint(6), 4)
        XCTAssertEqual(screen.varint(7), 1)
        XCTAssertEqual(screen.varint(8), 63)
        XCTAssertEqual(screen.varint(9), 1)
        XCTAssertEqual(screen.varint(12), 1)

        let payloads = screen.messages(3)
        XCTAssertEqual(payloads.count, 2)
        XCTAssertEqual(payloads[0].varint(1), 123)
        XCTAssertEqual(payloads[0].messages(2).count, 4)
        XCTAssertTrue(payloads[0].string(3)?.contains("AR:16/9,5/8;") == true)
        XCTAssertTrue(payloads[0].string(3)?.contains("XR:16/9,5/8;") == true)
        XCTAssertEqual(payloads[1].varint(1), 100)
        XCTAssertEqual(payloads[1].messages(2).count, 2)
        XCTAssertTrue(payloads[1].string(3)?.contains("AR:16/9,5/8;") == true)
        XCTAssertTrue(payloads[1].string(3)?.contains("XR:16/9,5/8;") == true)
    }

    func testScreenCodecCapabilitiesMatchNativeNegotiatorBytes() throws {
        let profile = AppleMediaNegotiationProfile(
            framebufferWidth: 2976,
            framebufferHeight: 1860,
            supportsHDR: false)
        let root = try ProtoMessage(profile.mediaBlob(
            kind: .screen,
            ssrc: 0,
            ntpTimestamp: 1))
        let actual = try XCTUnwrap(root.bytes(5))

        // Captured from the app-configured native Screen Sharing negotiation
        // after removing only the session-specific SSRC field. A bare private
        // negotiator uses 8:5, but real sessions produce 16:9 here and in the
        // server's resulting VCVideoStreamConfig.
        let nativeCapabilities = try XCTUnwrap(dataFromHex(
            "10001a7f087b120a0801100118c387032000120a0801100218c387032000" +
            "120a0801100118c387032000120a0801100218c3870320001a49464c533b" +
            "4d533a2d313b4c463a2d313b4c54523b43414241433b504f533a303b45" +
            "4f443a313b4854533a323b52523a333b41523a31362f392c352f383b58" +
            "523a31362f392c352f383b20011a5e0864120a0801100118c387032000" +
            "120a0801100218c3870320001a40464c533b4c463a2d313b504f533a35" +
            "3b454f443a313b4854533a323b52523a333b504f53453a343b41523a31" +
            "362f392c352f383b58523a31362f392c352f383b200e30043801403f48" +
            "016001"))
        XCTAssertEqual(actual, Data([0x08, 0x00]) + nativeCapabilities)
    }

    func testSmallCaptureCanExplicitlyAdvertiseNativeFourTileCapability() throws {
        let profile = AppleMediaNegotiationProfile(
            framebufferWidth: 2400,
            framebufferHeight: 1680,
            supportsHDR: false)
        let screen = try XCTUnwrap(ProtoMessage(profile.mediaBlob(
            kind: .screen,
            ssrc: 1,
            ntpTimestamp: 2
        )).message(5))

        XCTAssertEqual(screen.varint(6), 4)
        XCTAssertEqual(
            AppleMediaVideoMode.activeTileCount(
                pixelWidth: 2400,
                pixelHeight: 1680),
            1)
    }

    func testHDRServerCapabilityChangesAdvertisedHDRBitmap() throws {
        let sdr = AppleMediaNegotiationProfile(
            framebufferWidth: 1920,
            framebufferHeight: 1080,
            supportsHDR: false
        )
        let hdr = AppleMediaNegotiationProfile(
            framebufferWidth: 1920,
            framebufferHeight: 1080,
            supportsHDR: true
        )
        let sdrScreen = try XCTUnwrap(ProtoMessage(sdr.mediaBlob(
            kind: .screen,
            ssrc: 1,
            ntpTimestamp: 2
        )).message(5))
        let hdrScreen = try XCTUnwrap(ProtoMessage(hdr.mediaBlob(
            kind: .screen,
            ssrc: 1,
            ntpTimestamp: 2
        )).message(5))

        XCTAssertEqual(sdrScreen.varint(9), 1)
        XCTAssertEqual(hdrScreen.varint(9), 9)
    }

    func testScreenNegotiationMatchesNativeAppAccessAndVideoTransport() throws {
        let profile = AppleMediaNegotiationProfile(
            framebufferWidth: 2556,
            framebufferHeight: 1179,
            supportsHDR: false)
        let root = try ProtoMessage(profile.mediaBlob(
            kind: .screen,
            ssrc: 1,
            ntpTimestamp: 2))

        XCTAssertEqual(root.varint(18), 1)
        let screen = try XCTUnwrap(root.message(5))
        for payload in screen.messages(3) {
            for rule in payload.messages(2) {
                XCTAssertEqual(rule.varint(1), 1)
            }
        }
    }

    func testPrivateAndOverlayHostDetection() {
        XCTAssertTrue(AppleMediaNetworkProfile.isPrivateOrOverlayHost("192.168.58.66"))
        XCTAssertTrue(AppleMediaNetworkProfile.isPrivateOrOverlayHost("100.100.20.30"))
        XCTAssertTrue(AppleMediaNetworkProfile.isPrivateOrOverlayHost("mac.tail123.ts.net"))
        XCTAssertTrue(AppleMediaNetworkProfile.isPrivateOrOverlayHost("MAC.TAIL123.TS.NET."))
        XCTAssertFalse(AppleMediaNetworkProfile.isPrivateOrOverlayHost("203.0.113.8"))
    }

    func testTailscaleTCPPeerKeepsHostnameForAdaptiveUDP() {
        XCTAssertEqual(
            TransportSession.selectAppleMediaRemoteHost(
                dialHost: "mac.tail123.ts.net",
                connectedPeer: "100.100.20.30"),
            "mac.tail123.ts.net")
        XCTAssertEqual(
            TransportSession.selectAppleMediaRemoteHost(
                dialHost: "mac.tail123.ts.net",
                connectedPeer: "fd7a:115c:a1e0::1234"),
            "mac.tail123.ts.net")
        XCTAssertEqual(
            TransportSession.selectAppleMediaRemoteHost(
                dialHost: "MAC.TAIL123.TS.NET.",
                connectedPeer: "fd7a:115c:a1e0::1234%utun4"),
            "MAC.TAIL123.TS.NET.")

        XCTAssertEqual(
            TransportSession.selectAppleMediaRemoteAddressFamily(
                dialHost: "mac.tail123.ts.net",
                connectedPeer: "100.100.20.30"),
            .ipv4)
        XCTAssertEqual(
            TransportSession.selectAppleMediaRemoteAddressFamily(
                dialHost: "mac.tail123.ts.net",
                connectedPeer: "fd7a:115c:a1e0::1234%utun4"),
            .ipv6)
    }

    func testAdaptiveUDPKeepsExactPeerOutsideTailscaleException() {
        XCTAssertEqual(
            TransportSession.selectAppleMediaRemoteHost(
                dialHost: "dual-stack-host.local",
                connectedPeer: "fd00::1234"),
            "fd00::1234")
        XCTAssertEqual(
            TransportSession.selectAppleMediaRemoteHost(
                dialHost: "fd00::1234",
                connectedPeer: "fd00::1234"),
            "fd00::1234")
        XCTAssertEqual(
            TransportSession.selectAppleMediaRemoteHost(
                dialHost: "fallback.example",
                connectedPeer: nil),
            "fallback.example")
        XCTAssertNil(
            TransportSession.selectAppleMediaRemoteAddressFamily(
                dialHost: "dual-stack-host.local",
                connectedPeer: "fd00::1234"))
        XCTAssertNil(
            TransportSession.selectAppleMediaRemoteAddressFamily(
                dialHost: "mac.tail123.ts.net",
                connectedPeer: nil))
    }

    func testCellularVPNUsesConservativeCapacityPriorWithoutChangingNegotiation() {
        let profile = AppleMediaNetworkProfile.detect(
            from: NetworkPathCharacteristics(
                interface: .cellular,
                usesOtherInterface: true,
                isExpensive: true,
                isConstrained: false),
            remoteHost: "mac.tail123.ts.net")

        XCTAssertEqual(profile.initialCapacityBps, 6_000_000)
        XCTAssertTrue(profile.name.hasSuffix("over private/VPN"))
    }

    func testBearerSetsInitialPriorOnlyWhileCeilingUsesSixtyMbpsTier() {
        // A large virtual display was pinned at bwe=40000kbps and starved the
        // encoder (pulsing macroblocks with zero loss). The ceiling is the
        // 60 Mbps negotiated screen tier on every bearer — modern Wi-Fi often
        // outruns wired — while the bearer keeps its conservative prior.
        XCTAssertEqual(
            AppleMediaRateController.nativeScreenMaximumBitrateBps, 60_000_000)

        let wired = AppleMediaNetworkProfile.detect(
            from: NetworkPathCharacteristics(
                interface: .wiredEthernet,
                usesOtherInterface: false,
                isExpensive: false,
                isConstrained: false),
            remoteHost: "192.0.2.10")
        XCTAssertEqual(wired.initialCapacityBps, 60_000_000)

        let wifi = AppleMediaNetworkProfile.detect(
            from: NetworkPathCharacteristics(
                interface: .wifi,
                usesOtherInterface: false,
                isExpensive: false,
                isConstrained: false),
            remoteHost: "192.0.2.10")
        XCTAssertEqual(wifi.initialCapacityBps, 20_000_000)
    }

    func testAudioBlobCarriesAudioSettingsInsteadOfScreenSettings() throws {
        let profile = AppleMediaNegotiationProfile(
            framebufferWidth: 2048,
            framebufferHeight: 1536,
            supportsHDR: false
        )
        let root = try ProtoMessage(profile.mediaBlob(
            kind: .audio,
            ssrc: 0x1234_5678,
            ntpTimestamp: 9
        ))
        let audio = try XCTUnwrap(root.message(3))

        XCTAssertNil(try root.message(5))
        XCTAssertEqual(audio.varint(1), 0x1234_5678)
        XCTAssertEqual(audio.varint(2), 0)
        XCTAssertEqual(audio.varint(3), 0)
        XCTAssertEqual(audio.varint(4), 24_191)
        XCTAssertEqual(audio.varint(5), 0)
        XCTAssertEqual(audio.varint(6), 0)
    }

    func testOfferIsBinaryPlistWithValidCompressedProtobufAndEndpoint() throws {
        let profile = AppleMediaNegotiationProfile(
            framebufferWidth: 1920,
            framebufferHeight: 1200,
            supportsHDR: false
        )
        let endpoint = AppleMediaNegotiationProfile.Endpoint(
            productIdentifier: "iPad99,1",
            mediaSoftwareVersion: "42",
            operatingSystemBuild: "99A1"
        )
        let callID = UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!
        let offer = try profile.makeOffer(
            kind: .screen,
            mode: 7,
            ssrc: 7,
            ntpTimestamp: 8,
            callID: callID,
            endpoint: endpoint
        )
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: offer, options: [], format: nil)
                as? [String: Any]
        )

        XCTAssertEqual(plist["avcMediaStreamNegotiatorMode"] as? Int, 7)
        XCTAssertEqual(
            plist["avcMediaStreamOptionCallID"] as? String,
            callID.uuidString
        )
        let compressed = try XCTUnwrap(plist["avcMediaStreamNegotiatorMediaBlob"] as? Data)
        XCTAssertEqual(compressed.prefix(2), Data([0x78, 0xda]))
        XCTAssertGreaterThan(compressed.count, 6)
        let decoded = try ProtoMessage(zlibDecompress(compressed))
        XCTAssertEqual(decoded.varint(13), 8)
        XCTAssertEqual(try decoded.message(5)?.varint(1), 7)

        let endpointMessage = try ProtoMessage(XCTUnwrap(
            plist["avcMediaStreamOptionRemoteEndpointInfo"] as? Data
        ))
        XCTAssertEqual(endpointMessage.varint(1), 0)
        XCTAssertEqual(endpointMessage.varint(2), 1)
        XCTAssertEqual(endpointMessage.string(3), "iPad99,1")
        XCTAssertEqual(endpointMessage.string(4), "42")
        XCTAssertEqual(endpointMessage.string(5), "99A1")
    }

    func testNativeCodecAspectCapabilitiesDoNotTrackFramebufferShape() {
        let ipad = AppleMediaNegotiationProfile(
            framebufferWidth: 2732,
            framebufferHeight: 2048,
            supportsHDR: false)
        let wide = AppleMediaNegotiationProfile(
            framebufferWidth: 1920,
            framebufferHeight: 1080,
            supportsHDR: false)

        XCTAssertEqual(ipad.aspectRatio, .screenCodec)
        XCTAssertEqual(wide.aspectRatio, .screenCodec)
        XCTAssertEqual(ipad.aspectRatio.featureListValue, "16/9,5/8")
    }

    func testNTPConversion() {
        XCTAssertEqual(
            AppleMediaNegotiationProfile.ntpTimestamp(for: Date(timeIntervalSince1970: 0)),
            UInt64(2_208_988_800) << 32
        )
    }
}

private struct ProtoMessage {
    enum Value {
        case varint(UInt64)
        case bytes(Data)
    }

    private var fields: [UInt64: [Value]] = [:]

    init(_ data: Data) throws {
        var index = data.startIndex
        while index < data.endIndex {
            let key = try Self.readVarint(data, index: &index)
            let field = key >> 3
            switch key & 0x07 {
            case 0:
                fields[field, default: []].append(.varint(
                    try Self.readVarint(data, index: &index)
                ))
            case 2:
                let length = try Self.readVarint(data, index: &index)
                guard length <= UInt64(data.distance(from: index, to: data.endIndex)),
                      let end = data.index(index, offsetBy: Int(length), limitedBy: data.endIndex) else {
                    throw ProtoError.truncated
                }
                fields[field, default: []].append(.bytes(Data(data[index..<end])))
                index = end
            default:
                throw ProtoError.unsupportedWireType
            }
        }
    }

    func varint(_ field: UInt64) -> UInt64? {
        guard case .varint(let value)? = fields[field]?.first else { return nil }
        return value
    }

    func string(_ field: UInt64) -> String? {
        guard case .bytes(let value)? = fields[field]?.first else { return nil }
        return String(data: value, encoding: .utf8)
    }

    func bytes(_ field: UInt64) -> Data? {
        guard case .bytes(let value)? = fields[field]?.first else { return nil }
        return value
    }

    func message(_ field: UInt64) throws -> ProtoMessage? {
        guard case .bytes(let value)? = fields[field]?.first else { return nil }
        return try ProtoMessage(value)
    }

    func messages(_ field: UInt64) -> [ProtoMessage] {
        (fields[field] ?? []).compactMap {
            guard case .bytes(let value) = $0 else { return nil }
            return try? ProtoMessage(value)
        }
    }

    private static func readVarint(_ data: Data, index: inout Data.Index) throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while index < data.endIndex, shift < 64 {
            let byte = data[index]
            index = data.index(after: index)
            result |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
        throw ProtoError.truncated
    }
}

private enum ProtoError: Error {
    case truncated
    case unsupportedWireType
    case decompressionFailed
}

private func dataFromHex(_ value: String) -> Data? {
    guard value.count.isMultiple(of: 2) else { return nil }
    var result = Data(capacity: value.count / 2)
    var index = value.startIndex
    while index < value.endIndex {
        let end = value.index(index, offsetBy: 2)
        guard let byte = UInt8(value[index..<end], radix: 16) else { return nil }
        result.append(byte)
        index = end
    }
    return result
}

private func zlibDecompress(_ input: Data) throws -> Data {
    guard input.count > 6, input.prefix(2) == Data([0x78, 0xda]) else {
        throw ProtoError.decompressionFailed
    }
    // `Compression` consumes raw DEFLATE; strip the RFC 1950 header/checksum.
    let deflate = Data(input.dropFirst(2).dropLast(4))
    var capacity = 1024
    while capacity <= 1_048_576 {
        var output = Data(count: capacity)
        let written = output.withUnsafeMutableBytes { outputBytes in
            deflate.withUnsafeBytes { inputBytes in
                compression_decode_buffer(
                    outputBytes.bindMemory(to: UInt8.self).baseAddress!,
                    capacity,
                    inputBytes.bindMemory(to: UInt8.self).baseAddress!,
                    deflate.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        if written > 0 {
            output.count = written
            return output
        }
        capacity *= 2
    }
    throw ProtoError.decompressionFailed
}
