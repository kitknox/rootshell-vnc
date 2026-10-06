import XCTest
import RFBProtocol
@testable import RFBTransport

/// Offline end-to-end coverage of `TransportSession` over a scripted
/// ``RFBConnection`` — the first tests that drive the real handshake and
/// read loop without a live VNC server.
final class TransportSessionScriptedTests: XCTestCase {

    private static let appleDCTEncodings: [Encoding] = [
        .appleMultiVariantScreenshare,
        .unknown(1105), .unknown(1104),
        .serverDisplayInfo, .raw,
    ]

    func testPasswordOnlyHighPerformanceSelectsConsoleBeforeMatchClientMedia() async throws {
        let encodings: [Encoding] = [
            .appleH264, .mediaStreamOffer, .serverDisplayInfo, .raw,
        ]
        var serverBytes = ProtocolVersion.apple.wireBytes()
        serverBytes.append(contentsOf: [1, SecurityType.vncAuthentication.rawValue])
        serverBytes.append(Data(repeating: 0x5a, count: 16)) // VNC challenge
        serverBytes.append(contentsOf: [0, 0, 0, 0]) // SecurityResult OK
        serverBytes.append(Self.appleServerInitMessage(
            width: 2880,
            height: 1800,
            name: "Password Only Mac"))
        serverBytes.append(Self.appleSessionActionAdvertisement(
            allowedActions: 0x0000_000f,
            machineName: "Password Only Mac"))
        serverBytes.append(contentsOf: [
            0x00, 0x50, // 80-byte result
            0x00, 0x01, // protocol version
            0x00, 0x00, // success
        ])
        serverBytes.append(Data(repeating: 0, count: 76))

        let fixture = try LoopbackRFBFixture(serverBytes: serverBytes)
        defer { fixture.close() }
        let session = TransportSession(
            host: "127.0.0.1",
            port: fixture.port,
            password: "vnc-password",
            preferredEncodings: encodings,
            requestsVirtualDisplays: true)

        try await session.connect()

        var expectedAfterAuth = Data([0xc1])
        expectedAfterAuth.append(Self.appleConsoleSessionSelectionMessage())
        expectedAfterAuth.append(ClientMessage.setPixelFormat(.bgra8888).serialize())
        expectedAfterAuth.append(ClientMessage.setEncodings(encodings).serialize())
        expectedAfterAuth.append(ClientMessage.framebufferUpdateRequest(
            incremental: false,
            x: 0,
            y: 0,
            width: 2880,
            height: 1800).serialize())

        let bytesBeforeClientInit = ProtocolVersion.apple.wireBytes().count
            + 1 // selected VNC security type
            + 16 // DES response to the server challenge
        let expectedCount = bytesBeforeClientInit + expectedAfterAuth.count
        let captured = await fixture.waitForClientBytes(atLeast: expectedCount)
        let sent = try XCTUnwrap(captured)

        var expectedPrefix = ProtocolVersion.apple.wireBytes()
        expectedPrefix.append(SecurityType.vncAuthentication.rawValue)
        XCTAssertEqual(sent.prefix(expectedPrefix.count), expectedPrefix)
        XCTAssertEqual(
            Data(sent.dropFirst(bytesBeforeClientInit).prefix(expectedAfterAuth.count)),
            expectedAfterAuth)
        // Password-only Pro Mode is triggered by encoding 1010. The keyed
        // Apple auth flow's legacy viewer-info/media-request messages would be
        // extra bytes here and cause the server to close before AVC message 1.
        let unexpectedExtraBytes = await fixture.waitForClientBytes(
            atLeast: expectedCount + 1,
            timeout: .milliseconds(200))
        XCTAssertNil(unexpectedExtraBytes)

        var mediaMessageOne = Data(repeating: 0, count: 36)
        mediaMessageOne[1] = 1 // version 1
        mediaMessageOne[3] = 1 // message 1
        mediaMessageOne[8] = UInt8(fixture.port >> 8)
        mediaMessageOne[9] = UInt8(fixture.port & 0xff)
        mediaMessageOne[14] = UInt8(fixture.port >> 8)
        mediaMessageOne[15] = UInt8(fixture.port & 0xff)
        var framedMediaMessage = Data([0, UInt8(mediaMessageOne.count)])
        framedMediaMessage.append(mediaMessageOne)
        try fixture.sendServerBytes(Self.framebufferUpdate([(
            Self.rectangleHeader(
                x: 0, y: 0, width: 0, height: 0,
                encoding: Encoding.appleH264.rawValue),
            framedMediaMessage,
        )]))

        let observedOffers = await Self.withTimeout(seconds: 2) {
            for await event in session.events {
                if case .mediaStreamOffer(let offer) = event {
                    return [offer]
                }
            }
            return []
        }
        let mediaOffer = observedOffers?.first
        XCTAssertEqual(mediaOffer?.messageType, 1)
        XCTAssertEqual(mediaOffer?.videoStream1UDPPort, fixture.port)
        XCTAssertEqual(mediaOffer?.width, 2880)
        XCTAssertEqual(mediaOffer?.height, 1800)

        await session.disconnect()
    }

    func testPasswordOnlyHighPerformanceRequestsConsoleWhenDirectConnectIsUnavailable() async throws {
        let encodings: [Encoding] = [
            .appleH264, .mediaStreamOffer, .serverDisplayInfo, .raw,
        ]
        var serverBytes = ProtocolVersion.apple.wireBytes()
        serverBytes.append(contentsOf: [1, SecurityType.vncAuthentication.rawValue])
        serverBytes.append(Data(repeating: 0x5a, count: 16))
        serverBytes.append(contentsOf: [0, 0, 0, 0])
        serverBytes.append(Self.appleServerInitMessage(
            width: 2560,
            height: 1440,
            name: "Current Console Mac"))
        // Actions 0 and 2 are offered. Action 1, the direct-console path used
        // by some hosts, is deliberately absent.
        serverBytes.append(Self.appleSessionActionAdvertisement(
            allowedActions: 0x0000_0005,
            machineName: "Current Console Mac"))
        serverBytes.append(contentsOf: [
            0x00, 0x50,
            0x00, 0x01,
            0x00,
        ])
        serverBytes.append(Data(repeating: 0, count: 77))

        let fixture = try LoopbackRFBFixture(serverBytes: serverBytes)
        defer { fixture.close() }
        let session = TransportSession(
            host: "127.0.0.1",
            port: fixture.port,
            password: "vnc-password",
            preferredEncodings: encodings)

        try await session.connect()

        let bytesBeforeClientInit = ProtocolVersion.apple.wireBytes().count
            + 1
            + 16
        var expectedAfterAuth = Data([0xc1])
        expectedAfterAuth.append(Self.appleConsoleSessionSelectionMessage(action: 0))
        expectedAfterAuth.append(ClientMessage.setPixelFormat(.bgra8888).serialize())
        expectedAfterAuth.append(ClientMessage.setEncodings(encodings).serialize())
        expectedAfterAuth.append(ClientMessage.framebufferUpdateRequest(
            incremental: false,
            x: 0,
            y: 0,
            width: 2560,
            height: 1440).serialize())
        let expectedCount = bytesBeforeClientInit + expectedAfterAuth.count
        let captured = await fixture.waitForClientBytes(atLeast: expectedCount)
        let sent = try XCTUnwrap(captured)
        XCTAssertEqual(
            Data(sent.dropFirst(bytesBeforeClientInit).prefix(expectedAfterAuth.count)),
            expectedAfterAuth)

        await session.disconnect()
    }

    func testPasswordOnlySessionSelectionReadsOneByteResultStatus() async throws {
        let encodings: [Encoding] = [.appleH264, .mediaStreamOffer, .raw]
        var serverBytes = ProtocolVersion.apple.wireBytes()
        serverBytes.append(contentsOf: [1, SecurityType.vncAuthentication.rawValue])
        serverBytes.append(Data(repeating: 0x5a, count: 16))
        serverBytes.append(contentsOf: [0, 0, 0, 0])
        serverBytes.append(Self.appleServerInitMessage(
            width: 1920,
            height: 1080,
            name: "Rejected Session Mac"))
        serverBytes.append(Self.appleSessionActionAdvertisement(
            allowedActions: 0x0000_0007,
            machineName: "Rejected Session Mac"))
        serverBytes.append(contentsOf: [
            0x00, 0x50,
            0x00, 0x01,
            0x02,
        ])
        serverBytes.append(Data(repeating: 0, count: 77))

        let fixture = try LoopbackRFBFixture(serverBytes: serverBytes)
        defer { fixture.close() }
        let session = TransportSession(
            host: "127.0.0.1",
            port: fixture.port,
            password: "vnc-password",
            preferredEncodings: encodings)

        do {
            try await session.connect()
            XCTFail("Expected the server to reject session selection")
        } catch let error as VNCProtocolError {
            XCTAssertEqual(
                error,
                .protocolViolation(
                    "Apple session selection failed (version=1, status=2)"))
        }
        await session.disconnect()
    }

    func testStagedRemoteDisplayRequestMarksResizeUnsettled() async throws {
        let states = LockedResizeSettledStates()
        let session = TransportSession(
            host: "display.test",
            port: 5900,
            password: "",
            preferredEncodings: [.appleH264, .raw],
            requestsVirtualDisplays: true)
        await session.setAppleRemoteDisplayResizeSettledSink {
            states.append($0)
        }

        XCTAssertEqual(states.snapshot(), [true])
        let disposition = try await session.requestRemoteDisplaySize(
            pixelWidth: 2048,
            pixelHeight: 1536,
            pointWidth: 1024,
            pointHeight: 768)

        XCTAssertEqual(disposition, .waitingForServerSupport)
        XCTAssertEqual(states.snapshot(), [true, false])
    }

    /// `portableEncodings` rewrites the list for conventional servers rather
    /// than adding to it, so it has to honour the server-rendered choice too.
    /// Asserting the whole byte stream proves nothing else shifted with it.
    func testServerRenderedCursorOmitsCursorEncodingsForConventionalServer() async throws {
        let connection = ScriptedRFBConnection()
        var script = ProtocolVersion.v3_3.wireBytes()
        script.append(contentsOf: [0, 0, 0, SecurityType.none.rawValue])
        script.append(Self.serverInitMessage(
            width: 640, height: 480, name: "legacy-linux"))
        await connection.enqueueServerBytes(script)

        let session = TransportSession(
            host: "legacy-linux.test",
            port: 5900,
            password: "",
            preferredEncodings: [.copyRect, .raw],
            serverRendersCursor: true,
            connection: connection)
        try await session.connect()

        var expected = ProtocolVersion.v3_3.wireBytes()
        expected.append(0x01) // ClientInit, immediately after the version.
        expected.append(ClientMessage.setPixelFormat(.bgra8888).serialize())
        expected.append(ClientMessage.setEncodings([
            .copyRect, .raw, .zrle, .zlib,
            .desktopSize, .extendedDesktopSize,
        ]).serialize())
        expected.append(ClientMessage.framebufferUpdateRequest(
            incremental: false,
            x: 0, y: 0, width: 640, height: 480).serialize())
        let sent = await connection.sentBytes()
        XCTAssertEqual(sent, expected)
        await session.disconnect()
    }

    /// The Apple path keeps the configured list verbatim instead of rewriting
    /// it, so the suppression has to happen before that list is installed. A
    /// host that builds the transport itself takes the default encodings,
    /// which carry the portable cursor shapes.
    func testServerRenderedCursorOmitsCursorEncodingsFromDefaultAppleList() async throws {
        let connection = ScriptedRFBConnection()
        var script = ProtocolVersion.apple.wireBytes()
        script.append(contentsOf: [1, SecurityType.none.rawValue])
        script.append(contentsOf: [0, 0, 0, 0])
        script.append(Self.serverInitMessage(
            width: 640, height: 480, name: "apple-scripted"))
        await connection.enqueueServerBytes(script)

        let session = TransportSession(
            host: "scripted.test",
            port: 5900,
            password: "",
            serverRendersCursor: true,
            connection: connection)
        try await session.connect()

        // The default list with the two portable cursor shapes taken out and
        // nothing else disturbed.
        let cursorless = ClientMessage.setEncodings([
            .copyRect, .raw,
            .desktopSize, .extendedDesktopSize,
            .encryptionInfo, .serverDisplayInfo,
            .mediaStreamOffer, .mediaStreamAnswer,
        ]).serialize()
        let withCursors = ClientMessage.setEncodings(
            ConnectionStateMachine.defaultPreferredEncodings).serialize()
        let sent = await connection.sentBytes()

        XCTAssertEqual(Self.occurrenceCount(of: cursorless, in: sent), 1)
        XCTAssertEqual(Self.occurrenceCount(of: withCursors, in: sent), 0)
        await session.disconnect()
    }

    func testRFB33ServerSelectedNoneDoesNotSendSecuritySelectionByte() async throws {
        let connection = ScriptedRFBConnection()
        var script = ProtocolVersion.v3_3.wireBytes()
        script.append(contentsOf: [0, 0, 0, SecurityType.none.rawValue])
        script.append(Self.serverInitMessage(
            width: 640, height: 480, name: "legacy-linux"))
        await connection.enqueueServerBytes(script)

        let session = TransportSession(
            host: "legacy-linux.test",
            port: 5900,
            password: "",
            preferredEncodings: [.copyRect, .raw],
            connection: connection)
        try await session.connect()

        var expected = ProtocolVersion.v3_3.wireBytes()
        expected.append(0x01) // ClientInit, immediately after the version.
        expected.append(ClientMessage.setPixelFormat(.bgra8888).serialize())
        expected.append(ClientMessage.setEncodings([
            .copyRect, .raw, .zrle, .zlib, .cursor, .xCursor,
            .desktopSize, .extendedDesktopSize,
        ]).serialize())
        expected.append(ClientMessage.framebufferUpdateRequest(
            incremental: false,
            x: 0, y: 0, width: 640, height: 480).serialize())
        let sent = await connection.sentBytes()
        XCTAssertEqual(sent, expected)
        await session.disconnect()
    }

    func testRFB33RequireEncryptionStopsBeforeUnencryptedClientInit() async {
        let connection = ScriptedRFBConnection()
        var script = ProtocolVersion.v3_3.wireBytes()
        script.append(contentsOf: [0, 0, 0, SecurityType.none.rawValue])
        await connection.enqueueServerBytes(script)

        let session = TransportSession(
            host: "legacy-linux.test",
            port: 5900,
            password: "",
            preferredEncodings: [.raw],
            connection: connection,
            securityPolicy: .requireEncryption)
        do {
            try await session.connect()
            XCTFail("Expected requireEncryption to reject RFB 3.3 None")
        } catch let error as VNCProtocolError {
            guard case .authenticationFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        // Only the version response is allowed. In particular, no ClientInit
        // byte may be sent after the policy rejection.
        let sent = await connection.sentBytes()
        XCTAssertEqual(sent, ProtocolVersion.v3_3.wireBytes())
        await session.disconnect()
    }

    func testRFB37NoneSkipsSecurityResultWithoutReportingUnexpectedMessage() async throws {
        let connection = ScriptedRFBConnection()
        var script = ProtocolVersion.v3_7.wireBytes()
        script.append(contentsOf: [1, SecurityType.none.rawValue])
        // RFB 3.7 None proceeds directly to ServerInit: there is no
        // SecurityResult between the security selection and this message.
        script.append(Self.serverInitMessage(
            width: 800, height: 600, name: "rfb37-none"))
        await connection.enqueueServerBytes(script)

        let session = TransportSession(
            host: "linux.example",
            port: 5900,
            password: "",
            preferredEncodings: [.copyRect, .raw],
            connection: connection)
        try await session.connect()

        let reachedServerInitWithoutError = await Self.withTimeout(seconds: 2) {
            for await event in session.events {
                switch event {
                case .serverInit:
                    return true
                case .error:
                    return false
                default:
                    break
                }
            }
            return false
        }
        XCTAssertEqual(reachedServerInitWithoutError, true)

        var expected = ProtocolVersion.v3_7.wireBytes()
        expected.append(SecurityType.none.rawValue)
        expected.append(0x01) // ClientInit, with no intervening result.
        expected.append(ClientMessage.setPixelFormat(.bgra8888).serialize())
        expected.append(ClientMessage.setEncodings([
            .copyRect, .raw, .zrle, .zlib, .cursor, .xCursor,
            .desktopSize, .extendedDesktopSize,
        ]).serialize())
        expected.append(ClientMessage.framebufferUpdateRequest(
            incremental: false,
            x: 0, y: 0, width: 800, height: 600).serialize())
        let sent = await connection.sentBytes()
        XCTAssertEqual(sent, expected)
        await session.disconnect()
    }

    func testRFB37VeNCryptConsumesSecurityResultAndPreservesLocalhostTLSIdentity() async throws {
        let connection = ScriptedRFBConnection()
        var script = ProtocolVersion.v3_7.wireBytes()
        script.append(contentsOf: [1, SecurityType.vencrypt.rawValue])
        // VeNCrypt 0.2 accepted, with X509None as the sole subtype.
        script.append(contentsOf: [0, 2, 0, 1])
        script.append(Self.uint32Bytes(260))
        script.append(contentsOf: [0, 0, 0, 0]) // RFB SecurityResult OK
        script.append(Self.serverInitMessage(
            width: 1024, height: 768, name: "rfb37-vencrypt"))
        await connection.enqueueServerBytes(script)

        let session = TransportSession(
            host: "localhost",
            port: 5900,
            password: "",
            preferredEncodings: [.copyRect, .raw],
            connection: connection,
            securityPolicy: .requireEncryption)
        try await session.connect()

        // The transport may dial/media-route localhost over IPv4, but TLS
        // must validate the certificate against the user-entered identity.
        let tlsEndpoint = await connection.upgradedTLSEndpoint()
        XCTAssertEqual(tlsEndpoint?.0, "localhost")
        XCTAssertEqual(tlsEndpoint?.1, 5900)

        var expected = ProtocolVersion.v3_7.wireBytes()
        expected.append(SecurityType.vencrypt.rawValue)
        expected.append(contentsOf: [0, 2]) // VeNCrypt version
        expected.append(Self.uint32Bytes(260)) // X509None
        expected.append(0x01) // ClientInit follows SecurityResult.
        expected.append(ClientMessage.setPixelFormat(.bgra8888).serialize())
        expected.append(ClientMessage.setEncodings([
            .copyRect, .raw, .zrle, .zlib, .cursor, .xCursor,
            .desktopSize, .extendedDesktopSize,
        ]).serialize())
        expected.append(ClientMessage.framebufferUpdateRequest(
            incremental: false,
            x: 0, y: 0, width: 1024, height: 768).serialize())
        let sent = await connection.sentBytes()
        XCTAssertEqual(sent, expected)
        await session.disconnect()
    }

    func testPlainRFB38HandshakeAndRawUpdateOverScriptedConnection() async throws {
        let connection = ScriptedRFBConnection()

        // Server script: version, one security type (None), SecurityResult OK,
        // then ServerInit. TransportSession reads these strictly in order.
        var script = Data("RFB 003.008\n".utf8)
        script.append(contentsOf: [1, SecurityType.none.rawValue])
        script.append(contentsOf: [0, 0, 0, 0])
        script.append(Self.serverInitMessage(
            width: 1024, height: 768, name: "scripted"))
        await connection.enqueueServerBytes(script)

        let session = TransportSession(
            host: "scripted.test",
            port: 5900,
            password: "",
            preferredEncodings: [.copyRect, .raw],
            connection: connection)
        try await session.connect()

        // The complete client half of the handshake, byte for byte: version
        // echo, security selection, ClientInit, then the post-init burst.
        var expectedClientBytes = ProtocolVersion.v3_8.wireBytes()
        expectedClientBytes.append(SecurityType.none.rawValue)
        expectedClientBytes.append(0x01) // ClientInit: shared session
        expectedClientBytes.append(
            ClientMessage.setPixelFormat(.bgra8888).serialize())
        expectedClientBytes.append(ClientMessage.setEncodings([
            .copyRect, .raw, .zrle, .zlib, .cursor, .xCursor,
            .desktopSize, .extendedDesktopSize,
        ]).serialize())
        expectedClientBytes.append(ClientMessage.framebufferUpdateRequest(
            incremental: false, x: 0, y: 0, width: 1024, height: 768
        ).serialize())
        let sent = await connection.sentBytes()
        XCTAssertEqual(sent, expectedClientBytes)

        // Raw-encoded FramebufferUpdate round trip through the read loop.
        let pixels = Data((1...8).map(UInt8.init)) // 2x1 at 4 bytes/pixel
        var update = Data([0, 0, 0, 1]) // type, padding, one rectangle
        update.append(Self.rectangleHeader(
            x: 0, y: 0, width: 2, height: 1, encoding: Encoding.raw.rawValue))
        update.append(pixels)
        await connection.enqueueServerBytes(update)

        let observed = await Self.withTimeout(seconds: 10) {
            () -> (ServerInit?, [(FramebufferRect, Data)]?) in
            var serverInit: ServerInit?
            for await event in session.events {
                switch event {
                case .serverInit(let received):
                    serverInit = received
                case .framebufferUpdate(let rects):
                    return (serverInit, rects)
                default:
                    break
                }
            }
            return (serverInit, nil)
        }

        let receivedServerInit = observed?.0
        let receivedUpdate = observed?.1
        XCTAssertNotNil(receivedUpdate)
        XCTAssertEqual(receivedServerInit?.framebufferWidth, 1024)
        XCTAssertEqual(receivedServerInit?.framebufferHeight, 768)
        XCTAssertEqual(receivedServerInit?.name, "scripted")
        XCTAssertEqual(receivedUpdate?.count, 1)
        XCTAssertEqual(
            receivedUpdate?.first?.0,
            FramebufferRect(x: 0, y: 0, width: 2, height: 1, encoding: .raw))
        XCTAssertEqual(receivedUpdate?.first?.1, pixels)

        await session.disconnect()
    }

    func testZeroSizedServerInitRecoversThroughDesktopSizeOnSameConnection() async throws {
        let connection = ScriptedRFBConnection()
        var script = ProtocolVersion.v3_8.wireBytes()
        script.append(contentsOf: [1, SecurityType.none.rawValue])
        script.append(contentsOf: [0, 0, 0, 0])
        script.append(Self.serverInitMessage(
            width: 0, height: 0, name: "deferred-capture"))
        await connection.enqueueServerBytes(script)

        let session = TransportSession(
            host: "deferred-capture.test",
            port: 5900,
            password: "",
            preferredEncodings: [.copyRect, .raw],
            connection: connection)
        try await session.connect()

        let initialRequest = ClientMessage.framebufferUpdateRequest(
            incremental: false, x: 0, y: 0, width: 0, height: 0).serialize()
        let initialBytes = await connection.sentBytes()
        XCTAssertTrue(initialBytes.suffix(initialRequest.count)
            .elementsEqual(initialRequest))

        let width: UInt16 = 1280
        let height: UInt16 = 720
        await connection.enqueueServerBytes(Self.framebufferUpdate([(
            Self.rectangleHeader(
                x: 0, y: 0, width: width, height: height,
                encoding: Encoding.desktopSize.rawValue),
            Data(),
        )]))

        let resized = await Self.withTimeout(seconds: 2) {
            for await event in session.events {
                if case .framebufferUpdate(let rects) = event {
                    return rects.last?.0.isSuccessfulDesktopResize == true
                }
            }
            return false
        }
        XCTAssertEqual(resized, true)

        try await session.finishFramebufferUpdate()
        let incrementalRequest = ClientMessage.framebufferUpdateRequest(
            incremental: true,
            x: 0, y: 0, width: width, height: height).serialize()
        let sentPositiveRequest = await Self.waitUntil {
            let bytes = await connection.sentBytes()
            return bytes.suffix(incrementalRequest.count)
                .elementsEqual(incrementalRequest)
        }
        XCTAssertTrue(sentPositiveRequest)
        await session.disconnect()
    }

    func testDesktopSizeDoesNotSuppressAppleDisplayEventsInSameUpdate() async throws {
        let connection = ScriptedRFBConnection()
        var script = ProtocolVersion.apple.wireBytes()
        script.append(contentsOf: [1, SecurityType.none.rawValue])
        script.append(contentsOf: [0, 0, 0, 0])
        script.append(Self.serverInitMessage(
            width: 0, height: 0, name: "apple-deferred"))
        await connection.enqueueServerBytes(script)

        let session = TransportSession(
            host: "apple-deferred.test",
            port: 5900,
            password: "",
            preferredEncodings: [.serverDisplayInfo, .desktopSize, .raw],
            connection: connection)
        try await session.connect()

        let display = AppleDisplayInfo(
            displayIndex: 7,
            originX: 0,
            originY: 0,
            width: 1280,
            height: 720,
            flags: 1)
        await connection.enqueueServerBytes(Self.framebufferUpdate([
            (
                Self.rectangleHeader(
                    x: 0, y: 0, width: 1280, height: 720,
                    encoding: Encoding.desktopSize.rawValue),
                Data()
            ),
            (
                Self.rectangleHeader(
                    x: 0, y: 0, width: 0, height: 0,
                    encoding: Encoding.serverDisplayInfo.rawValue),
                Self.appleDisplayInfoPayload(display)
            ),
        ]))

        let observed = await Self.withTimeout(seconds: 2) {
            var record: AppleDisplayInfo?
            var layout: [AppleDisplayInfo]?
            for await event in session.events {
                switch event {
                case .displayInfo(let info):
                    record = info
                case .appleDisplayLayout(let displays):
                    layout = displays
                case .framebufferUpdate:
                    return (record, layout)
                default:
                    break
                }
            }
            return (record, layout)
        }
        XCTAssertEqual(observed?.0, display)
        XCTAssertEqual(observed?.1, [display])

        try await session.finishFramebufferUpdate()
        let sentPositiveRequest = await Self.waitUntil {
            let request = ClientMessage.framebufferUpdateRequest(
                incremental: true,
                x: 0, y: 0, width: 1280, height: 720).serialize()
            let bytes = await connection.sentBytes()
            return bytes.suffix(request.count).elementsEqual(request)
        }
        XCTAssertTrue(sentPositiveRequest)
        await session.disconnect()
    }

    func testStandardDisplayInfo2EmitsLegacyRecordsAndAtomicLayout() async throws {
        let connection = ScriptedRFBConnection()
        var script = ProtocolVersion.apple.wireBytes()
        script.append(contentsOf: [1, SecurityType.none.rawValue])
        script.append(contentsOf: [0, 0, 0, 0])
        script.append(Self.serverInitMessage(
            width: 1920, height: 1080, name: "apple-display-info-2"))
        await connection.enqueueServerBytes(script)

        let session = TransportSession(
            host: "apple-display-info-2.test",
            port: 5900,
            password: "",
            preferredEncodings: [.unknown(1105), .raw],
            connection: connection)
        try await session.connect()

        let displays = [
            AppleDisplayInfo(
                displayIndex: 7,
                originX: 0,
                originY: 0,
                width: 1280,
                height: 720,
                flags: 1),
            AppleDisplayInfo(
                displayIndex: 9,
                originX: 1280,
                originY: 0,
                width: 640,
                height: 1080,
                flags: 0),
        ]
        await connection.enqueueServerBytes(Self.framebufferUpdate([(
            Self.rectangleHeader(
                x: 0, y: 0, width: 0, height: 0,
                encoding: 1105),
            appleDisplayInfo2TestPayload(displays: displays)
        )]))

        let observed = await Self.withTimeout(seconds: 2) {
            var records: [AppleDisplayInfo] = []
            var layout: [AppleDisplayInfo]?
            for await event in session.events {
                switch event {
                case .displayInfo(let display):
                    records.append(display)
                case .appleDisplayLayout(let displays):
                    layout = displays
                case .framebufferUpdate:
                    return (records, layout)
                default:
                    break
                }
            }
            return (records, layout)
        }
        XCTAssertEqual(observed?.0, displays)
        XCTAssertEqual(observed?.1, displays)

        try await session.finishFramebufferUpdate()
        await session.disconnect()
    }

    func testLastRectTerminatesUnknownLengthUpdateWithoutDesynchronizing() async throws {
        let connection = ScriptedRFBConnection()
        var script = ProtocolVersion.v3_8.wireBytes()
        script.append(contentsOf: [1, SecurityType.none.rawValue])
        script.append(contentsOf: [0, 0, 0, 0])
        script.append(Self.serverInitMessage(
            width: 800, height: 600, name: "tight-linux"))
        await connection.enqueueServerBytes(script)

        let session = TransportSession(
            host: "tight-linux.test",
            port: 5900,
            password: "",
            preferredEncodings: [.tight, .lastRect, .raw],
            connection: connection)
        try await session.connect()

        var update = Data([0, 0, 0xff, 0xff])
        update.append(Self.rectangleHeader(
            x: 0, y: 0, width: 0, height: 0,
            encoding: Encoding.lastRect.rawValue))
        update.append(2) // Bell is the next complete server message.
        await connection.enqueueServerBytes(update)

        let sawUpdateThenBell = await Self.withTimeout(seconds: 2) {
            var sawUpdate = false
            for await event in session.events {
                switch event {
                case .framebufferUpdate:
                    sawUpdate = true
                case .bell:
                    return sawUpdate
                case .error:
                    return false
                default:
                    break
                }
            }
            return false
        }
        XCTAssertEqual(sawUpdateThenBell, true)
        await session.disconnect()
    }

    /// The build-130 field crash: a zlib rect whose length prefix decodes to
    /// ~1.47 GB. The session must reject it as a protocol violation and tear
    /// down cleanly instead of buffering gigabytes until Data's reallocation
    /// dies with a fatal assertion.
    func testGiantZlibLengthPrefixTerminatesWithProtocolViolation() async throws {
        let connection = ScriptedRFBConnection()
        var script = ProtocolVersion.v3_8.wireBytes()
        script.append(contentsOf: [1, SecurityType.none.rawValue])
        script.append(contentsOf: [0, 0, 0, 0])
        script.append(Self.serverInitMessage(
            width: 800, height: 600, name: "desynced"))
        await connection.enqueueServerBytes(script)

        let session = TransportSession(
            host: "desynced.test",
            port: 5900,
            password: "",
            preferredEncodings: [.zlib, .raw],
            connection: connection)
        try await session.connect()

        var update = Data([0, 0, 0, 1]) // type, padding, one rectangle
        update.append(Self.rectangleHeader(
            x: 0, y: 0, width: 800, height: 600,
            encoding: Encoding.zlib.rawValue))
        // The exact garbage length observed in the field crash report.
        update.append(contentsOf: [0x57, 0xff, 0xf9, 0xc3])
        await connection.enqueueServerBytes(update)

        let observedError = await Self.withTimeout(seconds: 2) {
            () -> VNCProtocolError? in
            for await event in session.events {
                if case .error(let error) = event { return error }
            }
            return nil
        }
        guard case .protocolViolation = observedError else {
            return XCTFail("Expected protocolViolation, got \(String(describing: observedError))")
        }
        await session.disconnect()
    }

    func testGiantServerCutTextLengthTerminatesWithProtocolViolation() async throws {
        let connection = ScriptedRFBConnection()
        var script = ProtocolVersion.v3_8.wireBytes()
        script.append(contentsOf: [1, SecurityType.none.rawValue])
        script.append(contentsOf: [0, 0, 0, 0])
        script.append(Self.serverInitMessage(
            width: 640, height: 480, name: "hostile"))
        await connection.enqueueServerBytes(script)

        let session = TransportSession(
            host: "hostile.test",
            port: 5900,
            password: "",
            preferredEncodings: [.raw],
            connection: connection)
        try await session.connect()

        // ServerCutText declaring a ~4 GB clipboard payload.
        var cutText = Data([3, 0, 0, 0]) // type + padding(3)
        cutText.append(contentsOf: [0xff, 0xff, 0xff, 0xfe])
        await connection.enqueueServerBytes(cutText)

        let observedError = await Self.withTimeout(seconds: 2) {
            () -> VNCProtocolError? in
            for await event in session.events {
                if case .error(let error) = event { return error }
            }
            return nil
        }
        guard case .protocolViolation = observedError else {
            return XCTFail("Expected protocolViolation, got \(String(describing: observedError))")
        }
        await session.disconnect()
    }

    func testAppleStandardOneDisplayActivatesAutoUpdatesAfterEitherInitialRectangleOrder() async throws {
        let width: UInt16 = 2
        let height: UInt16 = 1
        let displayID: UInt32 = 0x1234_0007

        var displayInfo = Data(repeating: 0, count: 78)
        func write16(_ value: UInt16, at offset: Int) {
            displayInfo[offset] = UInt8(value >> 8)
            displayInfo[offset + 1] = UInt8(value & 0xff)
        }
        func write32(_ value: UInt32, at offset: Int) {
            displayInfo[offset] = UInt8(value >> 24)
            displayInfo[offset + 1] = UInt8((value >> 16) & 0xff)
            displayInfo[offset + 2] = UInt8((value >> 8) & 0xff)
            displayInfo[offset + 3] = UInt8(value & 0xff)
        }
        write16(76, at: 0)
        write16(1, at: 20)
        write32(displayID, at: 38)
        write16(0, at: 50)
        write16(0, at: 52)
        write16(height, at: 54)
        write16(width, at: 56)
        let displayRect = (
            Self.rectangleHeader(
                x: 0, y: 0, width: 0, height: 0,
                encoding: 1105),
            displayInfo
        )
        let dctBaseRect = (
            Self.rectangleHeader(
                x: 0, y: 0, width: width, height: height,
                encoding: Encoding.appleMultiVariantScreenshare.rawValue),
            Data([0, 0, 0, 1, 0])
        )
        var setDisplay = Data([0x0d, 0x00, 0x00, 0x00])
        setDisplay.append(Self.uint32Bytes(displayID))
        let fullRequest = ClientMessage.framebufferUpdateRequest(
            incremental: false,
            x: 0, y: 0, width: width, height: height
        ).serialize()
        let setEncodings = ClientMessage.setEncodings(Self.appleDCTEncodings).serialize()
        let autoUpdate = ClientMessage.appleAutoFramebufferUpdate(
            intervalMilliseconds: 0,
            x: 0, y: 0, width: width, height: height
        ).serialize()

        for displayInfoFirst in [true, false] {
            let ordering = displayInfoFirst ? "DisplayInfo before DCT" : "DCT before DisplayInfo"
            let connection = ScriptedRFBConnection()
            var script = ProtocolVersion.apple.wireBytes()
            script.append(contentsOf: [1, SecurityType.none.rawValue])
            script.append(contentsOf: [0, 0, 0, 0])
            script.append(Self.serverInitMessage(
                width: width, height: height, name: "apple-scripted"))
            script.append(Self.framebufferUpdate(
                displayInfoFirst
                    ? [displayRect, dctBaseRect]
                    : [dctBaseRect, displayRect]))
            await connection.enqueueServerBytes(script)

            let session = TransportSession(
                host: "scripted.test",
                port: 5900,
                password: "",
                preferredEncodings: Self.appleDCTEncodings,
                displayCount: 1,
                connection: connection)
            let updateTask = Task {
                for await event in session.events {
                    guard case .framebufferUpdate = event else { continue }
                    try? await session.finishFramebufferUpdate()
                    return true
                }
                return false
            }

            try await session.connect()

            let enabledAutoUpdates = await Self.waitUntil {
                let sent = await connection.sentBytes()
                return Self.occurrenceCount(of: autoUpdate, in: sent) == 1
            }
            XCTAssertTrue(enabledAutoUpdates, ordering)
            let receivedUpdate = await updateTask.value
            XCTAssertTrue(receivedUpdate, ordering)

            let sent = await connection.sentBytes()
            XCTAssertEqual(Self.occurrenceCount(of: fullRequest, in: sent), 1, ordering)
            XCTAssertEqual(Self.occurrenceCount(of: setDisplay, in: sent), 0, ordering)
            XCTAssertEqual(Self.occurrenceCount(of: autoUpdate, in: sent), 1, ordering)
            if let encodingsRange = sent.range(of: setEncodings),
               let fullRange = sent.range(of: fullRequest),
               let autoRange = sent.range(of: autoUpdate) {
                XCTAssertLessThan(encodingsRange.lowerBound, fullRange.lowerBound, ordering)
                XCTAssertLessThan(fullRange.lowerBound, autoRange.lowerBound, ordering)
            } else {
                XCTFail("Missing expected Apple bootstrap message: \(ordering)")
            }
            await session.disconnect()
        }
    }

    func testAppleStandardSoleDisplayAnnouncementDoesNotResetBootstrapSelection() async throws {
        let connection = ScriptedRFBConnection()
        let width: UInt16 = 2
        let height: UInt16 = 1

        var script = ProtocolVersion.apple.wireBytes()
        script.append(contentsOf: [1, SecurityType.none.rawValue])
        script.append(contentsOf: [0, 0, 0, 0])
        script.append(Self.serverInitMessage(
            width: width, height: height, name: "apple-scripted"))
        await connection.enqueueServerBytes(script)

        let session = TransportSession(
            host: "scripted.test",
            port: 5900,
            password: "",
            preferredEncodings: Self.appleDCTEncodings,
            displayCount: 1,
            connection: connection)
        let updateTask = Task {
            var updateCount = 0
            for await event in session.events {
                guard case .framebufferUpdate = event else { continue }
                updateCount += 1
                try? await session.finishFramebufferUpdate()
                if updateCount == 3 { return updateCount }
            }
            return updateCount
        }

        try await session.connect()

        var displayInfo = Data(repeating: 0, count: 78)
        func write16(_ value: UInt16, at offset: Int) {
            displayInfo[offset] = UInt8(value >> 8)
            displayInfo[offset + 1] = UInt8(value & 0xff)
        }
        func write32(_ value: UInt32, at offset: Int) {
            displayInfo[offset] = UInt8(value >> 24)
            displayInfo[offset + 1] = UInt8((value >> 16) & 0xff)
            displayInfo[offset + 2] = UInt8((value >> 8) & 0xff)
            displayInfo[offset + 3] = UInt8(value & 0xff)
        }
        write16(76, at: 0)
        write16(1, at: 20)
        write32(3, at: 38)
        write16(height, at: 54)
        write16(width, at: 56)
        await connection.enqueueServerBytes(Self.framebufferUpdate([
            (
                Self.rectangleHeader(
                    x: 0, y: 0, width: 0, height: 0,
                    encoding: 1105),
                displayInfo
            ),
        ]))

        let fullRequest = ClientMessage.framebufferUpdateRequest(
            incremental: false,
            x: 0, y: 0, width: width, height: height
        ).serialize()
        let retriedBootstrap = await Self.waitUntil {
            let sent = await connection.sentBytes()
            return Self.occurrenceCount(of: fullRequest, in: sent) == 2
        }
        XCTAssertTrue(retriedBootstrap)
        var sent = await connection.sentBytes()
        var setDisplay = Data([0x0d, 0x00, 0x00, 0x00])
        setDisplay.append(Self.uint32Bytes(3))
        XCTAssertEqual(Self.occurrenceCount(of: setDisplay, in: sent), 0)

        var dctControl = Data([0, 0, 0, 129, 2])
        dctControl.append(Data(repeating: 0, count: 128))
        await connection.enqueueServerBytes(Self.framebufferUpdate([
            (
                Self.rectangleHeader(
                    x: 0, y: 0, width: 0, height: 0,
                    encoding: Encoding.appleMultiVariantScreenshare.rawValue),
                dctControl
            ),
        ]))

        let autoUpdate = ClientMessage.appleAutoFramebufferUpdate(
            intervalMilliseconds: 0,
            x: 0, y: 0, width: width, height: height
        ).serialize()
        let requestedPixelBootstrap = await Self.waitUntil {
            let sent = await connection.sentBytes()
            return Self.occurrenceCount(of: fullRequest, in: sent) == 3
                && Self.occurrenceCount(of: autoUpdate, in: sent) == 1
        }
        XCTAssertTrue(requestedPixelBootstrap)
        sent = await connection.sentBytes()
        XCTAssertEqual(Self.occurrenceCount(of: autoUpdate, in: sent), 1)

        await connection.enqueueServerBytes(Self.framebufferUpdate([
            (
                Self.rectangleHeader(
                    x: 0, y: 0, width: width, height: height,
                    encoding: Encoding.appleMultiVariantScreenshare.rawValue),
                Data([0, 0, 0, 1, 0])
            ),
        ]))

        let enabledAutoUpdates = await Self.waitUntil {
            let sent = await connection.sentBytes()
            return Self.occurrenceCount(of: autoUpdate, in: sent) == 1
        }
        XCTAssertTrue(enabledAutoUpdates)
        let updateCount = await updateTask.value
        XCTAssertEqual(updateCount, 3)

        sent = await connection.sentBytes()
        XCTAssertEqual(Self.occurrenceCount(of: fullRequest, in: sent), 3)
        XCTAssertEqual(Self.occurrenceCount(of: setDisplay, in: sent), 0)
        XCTAssertEqual(Self.occurrenceCount(of: autoUpdate, in: sent), 1)
        await session.disconnect()
    }

    func testAppleDCTConfigurationUsesType3ForConventionalServer() async throws {
        let connection = ScriptedRFBConnection()
        let width: UInt16 = 2
        let height: UInt16 = 1
        var script = ProtocolVersion.v3_8.wireBytes()
        script.append(contentsOf: [1, SecurityType.none.rawValue])
        script.append(contentsOf: [0, 0, 0, 0])
        script.append(Self.serverInitMessage(
            width: width, height: height, name: "portable-server"))
        await connection.enqueueServerBytes(script)

        let session = TransportSession(
            host: "scripted.test",
            port: 5900,
            password: "",
            preferredEncodings: Self.appleDCTEncodings,
            connection: connection)
        try await session.connect()

        let fullRequest = ClientMessage.framebufferUpdateRequest(
            incremental: false,
            x: 0, y: 0, width: width, height: height
        ).serialize()
        let autoUpdate = ClientMessage.appleAutoFramebufferUpdate(
            intervalMilliseconds: 0,
            x: 0, y: 0, width: width, height: height
        ).serialize()
        let sent = await connection.sentBytes()
        XCTAssertEqual(Self.occurrenceCount(of: fullRequest, in: sent), 1)
        XCTAssertEqual(Self.occurrenceCount(of: autoUpdate, in: sent), 0)
        await session.disconnect()
    }

    func testAppleStandardOneDisplayActivatesAutoUpdatesAfterZeroSizedDCTControlBootstrap() async throws {
        let connection = ScriptedRFBConnection()
        let width: UInt16 = 2
        let height: UInt16 = 1
        let displayID: UInt32 = 7

        var displayInfo = Data()
        for value in [displayID, 0, 0, UInt32(width), UInt32(height), 1] {
            displayInfo.append(Self.uint32Bytes(value))
        }
        var script = ProtocolVersion.apple.wireBytes()
        script.append(contentsOf: [1, SecurityType.none.rawValue])
        script.append(contentsOf: [0, 0, 0, 0])
        script.append(Self.serverInitMessage(
            width: width, height: height, name: "apple-scripted"))
        var dctControl = Data([0, 0, 0, 129, 2])
        dctControl.append(Data(repeating: 0, count: 128))
        script.append(Self.framebufferUpdate([
            (
                Self.rectangleHeader(
                    x: 0, y: 0, width: 0, height: 0,
                    encoding: Encoding.serverDisplayInfo.rawValue),
                displayInfo
            ),
            (
                Self.rectangleHeader(
                    x: 0, y: 0, width: 0, height: 0,
                    encoding: Encoding.appleMultiVariantScreenshare.rawValue),
                // Type 2 installs two connection-wide quantization tables.
                // Its rectangle is a zero-sized control record, as observed
                // after the server wakes a sleeping display.
                dctControl
            ),
        ]))
        await connection.enqueueServerBytes(script)

        let session = TransportSession(
            host: "scripted.test",
            port: 5900,
            password: "",
            preferredEncodings: Self.appleDCTEncodings,
            displayCount: 1,
            connection: connection)
        let updateTask = Task {
            var updateCount = 0
            for await event in session.events {
                guard case .framebufferUpdate = event else { continue }
                updateCount += 1
                try? await session.finishFramebufferUpdate()
                if updateCount == 2 { return updateCount }
            }
            return updateCount
        }

        try await session.connect()

        let fullRequest = ClientMessage.framebufferUpdateRequest(
            incremental: false,
            x: 0, y: 0, width: width, height: height
        ).serialize()
        let autoUpdate = ClientMessage.appleAutoFramebufferUpdate(
            intervalMilliseconds: 0,
            x: 0, y: 0, width: width, height: height
        ).serialize()
        let requestedPixelBootstrap = await Self.waitUntil {
            let sent = await connection.sentBytes()
            return Self.occurrenceCount(of: fullRequest, in: sent) == 2
                && Self.occurrenceCount(of: autoUpdate, in: sent) == 1
        }
        XCTAssertTrue(requestedPixelBootstrap)
        var sent = await connection.sentBytes()
        XCTAssertEqual(Self.occurrenceCount(of: autoUpdate, in: sent), 1)

        await connection.enqueueServerBytes(Self.framebufferUpdate([
            (
                Self.rectangleHeader(
                    x: 0, y: 0, width: width, height: height,
                    encoding: Encoding.appleMultiVariantScreenshare.rawValue),
                Data([0, 0, 0, 1, 0])
            ),
        ]))

        let enabledAutoUpdates = await Self.waitUntil {
            let sent = await connection.sentBytes()
            return Self.occurrenceCount(of: autoUpdate, in: sent) == 1
        }
        XCTAssertTrue(enabledAutoUpdates)

        let updateCount = await updateTask.value
        XCTAssertEqual(updateCount, 2)

        sent = await connection.sentBytes()
        XCTAssertEqual(Self.occurrenceCount(of: fullRequest, in: sent), 2)
        XCTAssertEqual(Self.occurrenceCount(of: autoUpdate, in: sent), 1)
        await session.disconnect()
    }

    func testAppleStandardAccumulatesPartialDCTBaseCoverageBeforeAutoUpdates() async throws {
        let connection = ScriptedRFBConnection()
        let width: UInt16 = 4
        let height: UInt16 = 1

        var script = ProtocolVersion.apple.wireBytes()
        script.append(contentsOf: [1, SecurityType.none.rawValue])
        script.append(contentsOf: [0, 0, 0, 0])
        script.append(Self.serverInitMessage(
            width: width, height: height, name: "apple-partial-base"))
        await connection.enqueueServerBytes(script)

        let session = TransportSession(
            host: "scripted.test",
            port: 5900,
            password: "",
            preferredEncodings: Self.appleDCTEncodings,
            displayCount: 2,
            connection: connection)
        let updateTask = Task {
            var updateCount = 0
            for await event in session.events {
                guard case .framebufferUpdate = event else { continue }
                updateCount += 1
                try? await session.finishFramebufferUpdate()
                if updateCount == 2 { return updateCount }
            }
            return updateCount
        }
        try await session.connect()

        let fullRequest = ClientMessage.framebufferUpdateRequest(
            incremental: false,
            x: 0, y: 0, width: width, height: height
        ).serialize()
        let autoUpdate = ClientMessage.appleAutoFramebufferUpdate(
            intervalMilliseconds: 0,
            x: 0, y: 0, width: width, height: height
        ).serialize()
        await connection.enqueueServerBytes(Self.framebufferUpdate([
            (
                Self.rectangleHeader(
                    x: 0, y: 0, width: 2, height: height,
                    encoding: Encoding.appleMultiVariantScreenshare.rawValue),
                Data([0, 0, 0, 1, 0])
            ),
        ]))

        let requestedRemainder = await Self.waitUntil {
            let sent = await connection.sentBytes()
            return Self.occurrenceCount(of: fullRequest, in: sent) == 2
        }
        XCTAssertTrue(requestedRemainder)
        var sent = await connection.sentBytes()
        XCTAssertEqual(Self.occurrenceCount(of: autoUpdate, in: sent), 0)

        await connection.enqueueServerBytes(Self.framebufferUpdate([
            (
                Self.rectangleHeader(
                    x: 2, y: 0, width: 2, height: height,
                    encoding: Encoding.appleMultiVariantScreenshare.rawValue),
                Data([0, 0, 0, 1, 0])
            ),
        ]))

        let updateCount = await updateTask.value
        XCTAssertEqual(updateCount, 2)
        let enabledAutoUpdates = await Self.waitUntil {
            let sent = await connection.sentBytes()
            return Self.occurrenceCount(of: autoUpdate, in: sent) == 1
        }
        XCTAssertTrue(enabledAutoUpdates)
        sent = await connection.sentBytes()
        XCTAssertEqual(Self.occurrenceCount(of: fullRequest, in: sent), 2)
        XCTAssertEqual(Self.occurrenceCount(of: autoUpdate, in: sent), 1)
        await session.disconnect()
    }

    func testAppleStandardCombinedDisplayAcceptsInitialDCTReference() async throws {
        let connection = ScriptedRFBConnection()
        let width: UInt16 = 4
        let height: UInt16 = 1

        var script = ProtocolVersion.apple.wireBytes()
        script.append(contentsOf: [1, SecurityType.none.rawValue])
        script.append(contentsOf: [0, 0, 0, 0])
        script.append(Self.serverInitMessage(
            width: width, height: height, name: "apple-combined"))
        script.append(Self.framebufferUpdate([
            (
                Self.rectangleHeader(
                    x: 0, y: 0, width: width, height: height,
                    encoding: Encoding.appleMultiVariantScreenshare.rawValue),
                Data([0, 0, 0, 1, 0])
            ),
        ]))
        await connection.enqueueServerBytes(script)

        let encodings: [Encoding] = [
            .appleMultiVariantScreenshare,
            .unknown(1105), .unknown(1104),
            .serverDisplayInfo, .raw,
        ]
        let session = TransportSession(
            host: "scripted.test",
            port: 5900,
            password: "",
            preferredEncodings: encodings,
            displayCount: 2,
            connection: connection)
        let updateTask = Task {
            for await event in session.events {
                guard case .framebufferUpdate = event else { continue }
                try? await session.finishFramebufferUpdate()
                return true
            }
            return false
        }

        try await session.connect()

        let globalSetDisplay = Data([
            0x0d, 0x01, 0x00, 0x00,
            0xff, 0xff, 0xff, 0xff,
        ])
        let fullRequest = ClientMessage.framebufferUpdateRequest(
            incremental: false,
            x: 0, y: 0, width: width, height: height
        ).serialize()
        let autoUpdate = ClientMessage.appleAutoFramebufferUpdate(
            intervalMilliseconds: 0,
            x: 0, y: 0, width: width, height: height
        ).serialize()
        let enabledAutoUpdates = await Self.waitUntil {
            let sent = await connection.sentBytes()
            return sent.range(of: globalSetDisplay) != nil
                && sent.suffix(autoUpdate.count) == autoUpdate
        }
        XCTAssertTrue(enabledAutoUpdates)
        let receivedUpdate = await updateTask.value
        XCTAssertTrue(receivedUpdate)

        let sent = await connection.sentBytes()
        XCTAssertEqual(Self.occurrenceCount(of: fullRequest, in: sent), 1)
        XCTAssertEqual(Self.occurrenceCount(of: autoUpdate, in: sent), 1)
        if let displayRange = sent.range(of: globalSetDisplay),
           let fullRange = sent.range(of: fullRequest),
           let autoRange = sent.range(of: autoUpdate) {
            XCTAssertLessThan(displayRange.lowerBound, fullRange.lowerBound)
            XCTAssertLessThan(fullRange.lowerBound, autoRange.lowerBound)
        } else {
            XCTFail("Missing combined-display Apple bootstrap message")
        }

        await session.disconnect()
    }

    func testAppleDisplayInfo2EmitsDeduplicatedLoginStateChanges() async throws {
        let connection = ScriptedRFBConnection()
        var script = ProtocolVersion.apple.wireBytes()
        script.append(contentsOf: [1, SecurityType.none.rawValue])
        script.append(contentsOf: [0, 0, 0, 0])
        script.append(Self.serverInitMessage(
            width: 2, height: 1, name: "apple-login-state"))
        await connection.enqueueServerBytes(script)

        let session = TransportSession(
            host: "scripted.test",
            port: 5900,
            password: "secret",
            preferredEncodings: [.unknown(1105), .raw],
            connection: connection)
        let eventTask = Task { () -> [AppleRemoteSessionState] in
            var states: [AppleRemoteSessionState] = []
            for await event in session.events {
                switch event {
                case .appleRemoteSessionState(let state):
                    states.append(state)
                    if states.count == 3 { return states }
                case .framebufferUpdate:
                    try? await session.finishFramebufferUpdate()
                default:
                    break
                }
            }
            return states
        }
        try await session.connect()

        var updates = Data()
        for flags: UInt32 in [0, 0x10, 0x10, 0] {
            updates.append(Self.framebufferUpdate([(
                Self.rectangleHeader(
                    x: 0, y: 0, width: 0, height: 0,
                    encoding: 1105),
                Self.appleDisplayInfo2Payload(screenFlags: flags)
            )]))
        }
        await connection.enqueueServerBytes(updates)

        let states = await eventTask.value
        XCTAssertEqual(states.count, 3)
        XCTAssertFalse(states[0].requiresLogin)
        XCTAssertTrue(states[1].loginWindowActive)
        XCTAssertFalse(states[2].requiresLogin)
        await session.disconnect()
    }

    func testAppleClassicPortableFrameStillActivatesAutoUpdatesAfterFullFrame() async throws {
        let connection = ScriptedRFBConnection()
        let width: UInt16 = 2
        let height: UInt16 = 1
        let encodings: [Encoding] = [.unknown(1105), .unknown(1104), .raw]

        var script = ProtocolVersion.apple.wireBytes()
        script.append(contentsOf: [1, SecurityType.none.rawValue])
        script.append(contentsOf: [0, 0, 0, 0])
        script.append(Self.serverInitMessage(
            width: width, height: height, name: "apple-portable"))
        await connection.enqueueServerBytes(script)

        let session = TransportSession(
            host: "scripted.test",
            port: 5900,
            password: "",
            preferredEncodings: encodings,
            displayCount: 1,
            connection: connection)
        try await session.connect()

        let fullRequest = ClientMessage.framebufferUpdateRequest(
            incremental: false,
            x: 0, y: 0, width: width, height: height
        ).serialize()
        let autoUpdate = ClientMessage.appleAutoFramebufferUpdate(
            intervalMilliseconds: 0,
            x: 0, y: 0, width: width, height: height
        ).serialize()
        var sent = await connection.sentBytes()
        XCTAssertEqual(Self.occurrenceCount(of: fullRequest, in: sent), 1)
        XCTAssertEqual(Self.occurrenceCount(of: autoUpdate, in: sent), 0)

        let updateTask = Task {
            for await event in session.events {
                guard case .framebufferUpdate = event else { continue }
                try? await session.finishFramebufferUpdate()
                return true
            }
            return false
        }
        await connection.enqueueServerBytes(Self.framebufferUpdate([
            (
                Self.rectangleHeader(
                    x: 0, y: 0, width: width, height: height,
                    encoding: Encoding.raw.rawValue),
                Data(repeating: 0, count: Int(width) * Int(height) * 4)
            ),
        ]))

        let receivedUpdate = await updateTask.value
        XCTAssertTrue(receivedUpdate)
        let enabledAutoUpdates = await Self.waitUntil {
            let sent = await connection.sentBytes()
            return Self.occurrenceCount(of: autoUpdate, in: sent) == 1
        }
        XCTAssertTrue(enabledAutoUpdates)
        sent = await connection.sentBytes()
        XCTAssertEqual(Self.occurrenceCount(of: fullRequest, in: sent), 1)
        XCTAssertEqual(Self.occurrenceCount(of: autoUpdate, in: sent), 1)

        await session.disconnect()
    }

    func testConnectRefusesAppleMediaModeOverCustomTransport() async throws {
        let connection = ScriptedRFBConnection()
        await connection.enqueueServerBytes(ProtocolVersion.apple.wireBytes())
        let session = TransportSession(
            host: "scripted.test",
            port: 5900,
            password: "",
            preferredEncodings: [.appleH264, .zlib, .raw],
            connection: connection)

        do {
            try await session.connect()
            XCTFail("Expected connect() to refuse UDP media over a custom transport")
        } catch let error as VNCProtocolError {
            guard case .protocolViolation = error else {
                XCTFail("Expected protocolViolation, got \(error)")
                return
            }
        }
        // Refused before any handshake traffic.
        let sent = await connection.sentBytes()
        XCTAssertTrue(sent.isEmpty)
    }

    func testConnectAllowsAppleMediaModeOverCustomTransportWithDatagramPath() async throws {
        let connection = ScriptedRFBConnection()
        await connection.enqueueServerBytes(ProtocolVersion.apple.wireBytes())
        await connection.finishServerStream()
        let session = TransportSession(
            host: "scripted.test",
            port: 5900,
            password: "",
            preferredEncodings: [.appleH264, .zlib, .raw],
            connection: connection,
            datagramProvider: { _, _, _ in -1 })

        do {
            try await session.connect()
            XCTFail("Expected connect() to fail on server EOF")
        } catch let error as VNCProtocolError {
            // Gets past the media refusal and fails later on the closed stream.
            XCTAssertEqual(error, .connectionClosed)
        }
        let sent = await connection.sentBytes()
        XCTAssertFalse(sent.isEmpty)
    }

    func testConnectSurfacesConnectionClosedOnTruncatedHandshake() async throws {
        let connection = ScriptedRFBConnection()
        await connection.enqueueServerBytes(Data("RFB 0".utf8))
        await connection.finishServerStream()

        let session = TransportSession(
            host: "scripted.test",
            port: 5900,
            password: "",
            connection: connection)
        do {
            try await session.connect()
            XCTFail("Expected connect() to fail on server EOF")
        } catch let error as VNCProtocolError {
            XCTAssertEqual(error, .connectionClosed)
        }
    }

    // MARK: - Handshake info + statistics

    func testHandshakeInfoReportsVersionSecurityAndEncryption() async throws {
        let connection = ScriptedRFBConnection()
        var script = ProtocolVersion.v3_8.wireBytes()
        script.append(contentsOf: [1, SecurityType.none.rawValue])
        script.append(contentsOf: [0, 0, 0, 0])
        script.append(Self.serverInitMessage(
            width: 1024, height: 768, name: "scripted"))
        await connection.enqueueServerBytes(script)

        let session = TransportSession(
            host: "scripted.test",
            port: 5900,
            password: "",
            preferredEncodings: [.copyRect, .raw],
            connection: connection)
        try await session.connect()

        let info = await session.handshakeInfo
        XCTAssertEqual(info.serverReportedVersion, .v3_8)
        XCTAssertEqual(info.negotiatedVersion, .v3_8)
        XCTAssertEqual(info.offeredSecurityTypes, [SecurityType.none])
        XCTAssertEqual(info.selectedSecurityType, SecurityType.none)
        XCTAssertEqual(info.contentEncryption, .none)
        XCTAssertNil(info.appleServerCapabilities)
        await session.disconnect()
    }

    func testStatisticsSnapshotCountsFramebufferTraffic() async throws {
        let connection = ScriptedRFBConnection()
        var script = ProtocolVersion.v3_8.wireBytes()
        script.append(contentsOf: [1, SecurityType.none.rawValue])
        script.append(contentsOf: [0, 0, 0, 0])
        script.append(Self.serverInitMessage(
            width: 1024, height: 768, name: "scripted"))
        await connection.enqueueServerBytes(script)

        let session = TransportSession(
            host: "scripted.test",
            port: 5900,
            password: "",
            preferredEncodings: [.copyRect, .raw],
            connection: connection)
        try await session.connect()

        let initial = await session.statisticsSnapshot()
        XCTAssertEqual(initial.framebufferBytesReceived, 0)
        XCTAssertEqual(initial.framebufferUpdateCount, 0)
        XCTAssertEqual(initial.encodingUsage, [])
        XCTAssertNil(initial.recentInterval)
        XCTAssertFalse(initial.isHighPerformanceMode)

        // Update 1: one raw content rect (2x1, 8 payload bytes).
        let pixels = Data((1...8).map(UInt8.init))
        await connection.enqueueServerBytes(Self.framebufferUpdate([
            (Self.rectangleHeader(
                x: 0, y: 0, width: 2, height: 1,
                encoding: Encoding.raw.rawValue), pixels),
        ]))
        // Update 2: a copyRect content rect and a zero-sized cursor
        // pseudo-rect that must stay out of the encoding-usage map.
        await connection.enqueueServerBytes(Self.framebufferUpdate([
            (Self.rectangleHeader(
                x: 0, y: 0, width: 4, height: 4,
                encoding: Encoding.copyRect.rawValue), Data([0, 0, 0, 0])),
            (Self.rectangleHeader(
                x: 0, y: 0, width: 0, height: 0,
                encoding: Encoding.cursor.rawValue), Data()),
        ]))

        let sawBothUpdates = await Self.withTimeout(seconds: 10) {
            var updates = 0
            for await event in session.events {
                if case .framebufferUpdate = event {
                    updates += 1
                    if updates == 2 { return true }
                }
            }
            return false
        }
        XCTAssertEqual(sawBothUpdates, true)

        try await Task.sleep(for: .milliseconds(300))
        let stats = await session.statisticsSnapshot()
        XCTAssertEqual(stats.framebufferUpdateCount, 2)
        XCTAssertEqual(stats.framebufferRectCount, 3)
        // Update 1: 4 header + 12 rect header + 8 payload = 24 bytes.
        // Update 2: 4 header + (12 + 4) copyRect + (12 + 0) cursor = 32 bytes.
        XCTAssertEqual(stats.framebufferBytesReceived, 56)
        XCTAssertEqual(stats.encodingUsage, [
            EncodingUsage(encoding: .raw, rectangles: 1, bytes: 20),
            EncodingUsage(encoding: .copyRect, rectangles: 1, bytes: 16),
        ])
        XCTAssertNotNil(stats.recentInterval)
        let recentKbps = try XCTUnwrap(stats.recentBitrateKbps)
        XCTAssertGreaterThan(recentKbps, 0)
        XCTAssertNil(stats.recentPacketLossPercent)
        XCTAssertEqual(stats.mediaBytesReceived, 0)
        await session.disconnect()
    }

    // MARK: - Wire-format helpers

    private static func serverInitMessage(
        width: UInt16,
        height: UInt16,
        name: String
    ) -> Data {
        var data = Data()
        data.append(contentsOf: [UInt8(width >> 8), UInt8(width & 0xff)])
        data.append(contentsOf: [UInt8(height >> 8), UInt8(height & 0xff)])
        data.append(PixelFormat.bgra8888.wireBytes())
        let nameBytes = Data(name.utf8)
        let length = UInt32(nameBytes.count)
        data.append(contentsOf: [
            UInt8((length >> 24) & 0xff),
            UInt8((length >> 16) & 0xff),
            UInt8((length >> 8) & 0xff),
            UInt8(length & 0xff),
        ])
        data.append(nameBytes)
        return data
    }

    private static func appleServerInitMessage(
        width: UInt16,
        height: UInt16,
        name: String
    ) -> Data {
        var field = Data([
            0x00, 0x00,             // status/reserved
            0x00, 0x00, 0x00, 0x54, // Apple server flags
        ])
        field.append(Data(repeating: 0, count: 16)) // server-command bitmap
        field.append(Data(name.utf8))

        var data = Data()
        data.append(contentsOf: [UInt8(width >> 8), UInt8(width & 0xff)])
        data.append(contentsOf: [UInt8(height >> 8), UInt8(height & 0xff)])
        data.append(PixelFormat.bgra8888.wireBytes())
        data.append(uint32Bytes(UInt32(field.count)))
        data.append(field)
        return data
    }

    private static func appleSessionActionAdvertisement(
        allowedActions: UInt32,
        machineName: String
    ) -> Data {
        var message = Data([
            0x00, 0x4a,
            0x00, 0x01,
            UInt8((allowedActions >> 24) & 0xff),
            UInt8((allowedActions >> 16) & 0xff),
            UInt8((allowedActions >> 8) & 0xff),
            UInt8(allowedActions & 0xff),
            0x00, 0x00, 0x00, 0x00,
        ])
        var name = Data(machineName.utf8.prefix(63))
        name.append(Data(repeating: 0, count: 64 - name.count))
        message.append(name)
        return message
    }

    private static func appleConsoleSessionSelectionMessage(action: UInt8 = 1) -> Data {
        var request = Data(repeating: 0, count: 74)
        request[0] = 0x00
        request[1] = 0x48
        request[2] = 0x00
        request[3] = 0x01
        request[8] = action
        let clientName = Data("rootshell".utf8)
        request.replaceSubrange(10..<(10 + clientName.count), with: clientName)
        return request
    }

    private static func rectangleHeader(
        x: UInt16,
        y: UInt16,
        width: UInt16,
        height: UInt16,
        encoding: Int32
    ) -> Data {
        var data = Data()
        for value in [x, y, width, height] {
            data.append(contentsOf: [UInt8(value >> 8), UInt8(value & 0xff)])
        }
        let raw = UInt32(bitPattern: encoding)
        data.append(contentsOf: [
            UInt8((raw >> 24) & 0xff),
            UInt8((raw >> 16) & 0xff),
            UInt8((raw >> 8) & 0xff),
            UInt8(raw & 0xff),
        ])
        return data
    }

    private static func framebufferUpdate(
        _ rects: [(header: Data, payload: Data)]
    ) -> Data {
        var data = Data([
            0,
            0,
            UInt8((rects.count >> 8) & 0xff),
            UInt8(rects.count & 0xff),
        ])
        for rect in rects {
            data.append(rect.header)
            data.append(rect.payload)
        }
        return data
    }

    private static func uint32Bytes(_ value: UInt32) -> Data {
        Data([
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff),
        ])
    }

    private static func appleDisplayInfoPayload(
        _ display: AppleDisplayInfo
    ) -> Data {
        var data = Data()
        for value in [
            display.displayIndex,
            UInt32(bitPattern: display.originX),
            UInt32(bitPattern: display.originY),
            display.width,
            display.height,
            display.flags,
        ] {
            data.append(uint32Bytes(value))
        }
        return data
    }

    private static func appleDisplayInfo2Payload(
        screenFlags: UInt32
    ) -> Data {
        var data = Data(repeating: 0, count: 20)
        data[0] = 0
        data[1] = 18
        data[2] = 0
        data[3] = 5
        data[16] = UInt8((screenFlags >> 24) & 0xff)
        data[17] = UInt8((screenFlags >> 16) & 0xff)
        data[18] = UInt8((screenFlags >> 8) & 0xff)
        data[19] = UInt8(screenFlags & 0xff)
        return data
    }

    private static func occurrenceCount(of pattern: Data, in data: Data) -> Int {
        let patternBytes = [UInt8](pattern)
        let bytes = [UInt8](data)
        guard !patternBytes.isEmpty, patternBytes.count <= bytes.count else { return 0 }

        return (0...(bytes.count - patternBytes.count)).reduce(into: 0) { count, offset in
            if bytes[offset..<(offset + patternBytes.count)].elementsEqual(patternBytes) {
                count += 1
            }
        }
    }

    private static func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }

    /// Bound an event-stream wait so a protocol bug fails the test instead of
    /// hanging the suite. Returns nil on timeout.
    private static func withTimeout<Result: Sendable>(
        seconds: Int,
        _ operation: @escaping @Sendable () async -> Result
    ) async -> Result? {
        await withTaskGroup(of: Result?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}

private final class LockedResizeSettledStates: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Bool] = []

    func append(_ value: Bool) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    func snapshot() -> [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}
