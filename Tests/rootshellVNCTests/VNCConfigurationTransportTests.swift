import XCTest
import CoreGraphics
import RFBProtocol
import RFBTransport
@testable import rootshellVNC

/// Minimal transport stub: dialing succeeds at the provider level and the
/// connection itself fails on connect, so session tests can observe provider
/// invocation without any network.
private struct StubTransportConnection: RFBConnection {
    func connect() async throws {
        throw VNCProtocolError.ioError("stub transport dial")
    }
    func read(exactly count: Int) async throws -> Data {
        throw VNCProtocolError.connectionClosed
    }
    func read(upTo maxCount: Int) async throws -> Data {
        throw VNCProtocolError.connectionClosed
    }
    func send(_ data: Data) async throws {}
    func close() async {}
    func setDisconnectHandler(
        _ handler: (@Sendable (VNCProtocolError) -> Void)?
    ) async {}

}

/// Records provider invocations across concurrency domains.
private final class ProviderRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(host: String, port: UInt16)] = []

    func record(host: String, port: UInt16) {
        lock.lock()
        calls.append((host, port))
        lock.unlock()
    }

    var recorded: [(host: String, port: UInt16)] {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}

private final class LockedLoginVisionAnalysis: @unchecked Sendable {
    private let lock = NSLock()
    private var detected = false
    private var invocations = 0

    func setDetected(_ value: Bool) {
        lock.lock()
        detected = value
        lock.unlock()
    }

    func analyze() -> AppleLoginTextAnalysis {
        lock.lock()
        invocations += 1
        let detected = detected
        lock.unlock()
        return AppleLoginTextAnalysis(
            isLoginScreen: detected,
            recognizedLineCount: detected ? 1 : 0,
            evidence: detected ? "test login" : "test desktop")
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return invocations
    }
}

/// Successful in-memory RFB 3.8 connection used to exercise session-level
/// reconnects without exposing or persisting credentials in the test.
private actor SuccessfulRFBConnection: RFBConnection {
    private var serverBytes: Data
    private var readOffset = 0
    private var closed = false
    private var readWaiters: [CheckedContinuation<Void, Never>] = []
    private var sentFramebufferUpdateRequests = 0
    private var latestFramebufferUpdateRequest: Data?
    private let recordsFramebufferUpdateRequests: Bool

    init(
        name: String,
        width: UInt16 = 1024,
        height: UInt16 = 768,
        recordsFramebufferUpdateRequests: Bool = false
    ) {
        var script = Data("RFB 003.008\n".utf8)
        script.append(contentsOf: [1, SecurityType.none.rawValue])
        script.append(contentsOf: [0, 0, 0, 0])
        script.append(Self.serverInitMessage(
            width: width,
            height: height,
            name: name))
        self.serverBytes = script
        self.recordsFramebufferUpdateRequests =
            recordsFramebufferUpdateRequests
    }

    func connect() async throws {
        if closed { throw VNCProtocolError.connectionClosed }
    }

    func read(exactly count: Int) async throws -> Data {
        while true {
            if closed { throw VNCProtocolError.connectionClosed }
            if serverBytes.count - readOffset >= count {
                return consume(count)
            }
            await withCheckedContinuation { readWaiters.append($0) }
        }
    }

    func read(upTo maxCount: Int) async throws -> Data {
        while true {
            if closed { throw VNCProtocolError.connectionClosed }
            let available = serverBytes.count - readOffset
            if available > 0 { return consume(min(available, maxCount)) }
            await withCheckedContinuation { readWaiters.append($0) }
        }
    }

    func send(_ data: Data) async throws {
        if closed { throw VNCProtocolError.connectionClosed }
        if recordsFramebufferUpdateRequests, data.first == 3 {
            sentFramebufferUpdateRequests += 1
            latestFramebufferUpdateRequest = data
        }
    }

    func close() {
        closed = true
        let waiters = readWaiters
        readWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    func setDisconnectHandler(
        _ handler: (@Sendable (VNCProtocolError) -> Void)?
    ) async {}

    func enqueueServerBytes(_ data: Data) {
        serverBytes.append(data)
        let waiters = readWaiters
        readWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    func framebufferUpdateRequestCount() -> Int {
        sentFramebufferUpdateRequests
    }

    func lastFramebufferUpdateRequest() -> Data? {
        latestFramebufferUpdateRequest
    }

    private func consume(_ count: Int) -> Data {
        let start = serverBytes.startIndex + readOffset
        let result = serverBytes.subdata(in: start..<(start + count))
        readOffset += count
        return result
    }

    private nonisolated static func serverInitMessage(
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
}

private final class SuccessfulProviderRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(host: String, port: UInt16)] = []
    private var connections: [SuccessfulRFBConnection] = []
    private let width: UInt16
    private let height: UInt16
    private let recordsFramebufferUpdateRequests: Bool

    init(
        width: UInt16 = 1024,
        height: UInt16 = 768,
        recordsFramebufferUpdateRequests: Bool = false
    ) {
        self.width = width
        self.height = height
        self.recordsFramebufferUpdateRequests =
            recordsFramebufferUpdateRequests
    }

    func makeConnection(host: String, port: UInt16) -> any RFBConnection {
        lock.lock()
        calls.append((host, port))
        let attempt = calls.count
        let connection = SuccessfulRFBConnection(
            name: "attempt-\(attempt)",
            width: width,
            height: height,
            recordsFramebufferUpdateRequests:
                recordsFramebufferUpdateRequests)
        connections.append(connection)
        lock.unlock()
        return connection
    }

    var recorded: [(host: String, port: UInt16)] {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    var createdConnections: [SuccessfulRFBConnection] {
        lock.lock()
        defer { lock.unlock() }
        return connections
    }
}

final class VNCConfigurationTransportTests: XCTestCase {

    private static let stubProvider: VNCTransportProvider = { _, _ in
        StubTransportConnection()
    }

    func testInstallingProviderClampsAdaptiveToStandard() {
        var configuration = VNCConfiguration()
        XCTAssertEqual(configuration.videoQualityMode, .adaptive)
        XCTAssertEqual(configuration.displaySizingMode, .matchClient)

        configuration.transportProvider = Self.stubProvider

        XCTAssertEqual(configuration.videoQualityMode, .standard)
        // The quality clamp must run the existing mode couplings too.
        XCTAssertEqual(configuration.displaySizingMode, .remoteDisplay)
    }

    func testSelectingAdaptiveRevertsWhileProviderInstalled() {
        var configuration = VNCConfiguration(videoQualityMode: .standard)
        configuration.transportProvider = Self.stubProvider

        configuration.videoQualityMode = .adaptive

        XCTAssertEqual(configuration.videoQualityMode, .standard)
    }

    func testInitClampsAdaptiveWhenProviderSupplied() {
        let configuration = VNCConfiguration(
            videoQualityMode: .adaptive,
            transportProvider: Self.stubProvider)

        XCTAssertEqual(configuration.videoQualityMode, .standard)
        XCTAssertEqual(configuration.displaySizingMode, .remoteDisplay)
    }

    func testAvailableVideoQualityModesExcludeAdaptiveOverCustomTransport() {
        var configuration = VNCConfiguration()
        XCTAssertEqual(
            configuration.availableVideoQualityModes,
            VNCConfiguration.VideoQualityMode.allCases)

        configuration.transportProvider = Self.stubProvider
        XCTAssertEqual(
            configuration.availableVideoQualityModes,
            [.standard, .fullQuality])

        // Removing the provider restores the direct-transport choices.
        configuration.transportProvider = nil
        XCTAssertEqual(
            configuration.availableVideoQualityModes,
            VNCConfiguration.VideoQualityMode.allCases)
    }

    private static let stubDatagramProvider: VNCDatagramProvider = { _, _, _ in -1 }

    func testInitKeepsAdaptiveWithDatagramProvider() {
        let configuration = VNCConfiguration(
            videoQualityMode: .adaptive,
            transportProvider: Self.stubProvider,
            datagramProvider: Self.stubDatagramProvider)

        XCTAssertEqual(configuration.videoQualityMode, .adaptive)
        XCTAssertEqual(configuration.displaySizingMode, .matchClient)
        XCTAssertEqual(
            configuration.availableVideoQualityModes,
            VNCConfiguration.VideoQualityMode.allCases)
    }

    func testDatagramProviderSetFirstKeepsAdaptive() {
        var configuration = VNCConfiguration()
        configuration.datagramProvider = Self.stubDatagramProvider
        configuration.transportProvider = Self.stubProvider

        XCTAssertEqual(configuration.videoQualityMode, .adaptive)
    }

    func testRemovingDatagramProviderClampsAdaptive() {
        var configuration = VNCConfiguration(
            transportProvider: Self.stubProvider,
            datagramProvider: Self.stubDatagramProvider)

        configuration.datagramProvider = nil

        XCTAssertEqual(configuration.videoQualityMode, .standard)
        XCTAssertEqual(
            configuration.availableVideoQualityModes,
            [.standard, .fullQuality])
    }

    @MainActor
    func testSessionInvokesProviderWithCredentialsHostAndPort() async {
        let recorder = ProviderRecorder()
        var configuration = VNCConfiguration()
        configuration.transportProvider = { host, port in
            recorder.record(host: host, port: port)
            return StubTransportConnection()
        }

        let session = VNCSession(configuration: configuration)
        do {
            try await session.connect(credentials: VNCCredentials(
                host: "vnc.internal",
                port: 5901,
                password: "secret"))
            XCTFail("Expected connect to surface the stub transport failure")
        } catch let error as VNCError {
            guard case .connectionFailed = error else {
                XCTFail("Expected connectionFailed, got \(error)")
                return
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }

        let calls = recorder.recorded
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.host, "vnc.internal")
        XCTAssertEqual(calls.first?.port, 5901)
    }

    @MainActor
    func testSessionPublishesAndClearsNegotiatedContentEncryption() async throws {
        let connection = SuccessfulRFBConnection(name: "encryption-state")
        var configuration = VNCConfiguration(
            videoQualityMode: .standard,
            reconnectionPolicy: VNCReconnectionPolicy(
                isEnabled: false,
                maximumAttempts: 0))
        configuration.transportProvider = { _, _ in connection }
        let session = VNCSession(configuration: configuration)
        var encryptionAtConnected: VNCContentEncryption?
        let observerID = session.addConnectionStateObserver { state in
            if state.isConnected {
                encryptionAtConnected = session.negotiatedContentEncryption
            }
        }

        XCTAssertNil(session.negotiatedContentEncryption)
        try await session.connect(credentials: VNCCredentials(
            host: "plain.test",
            port: 5900,
            password: ""))

        let published = await waitUntil {
            session.negotiatedContentEncryption == VNCContentEncryption.none
        }
        XCTAssertTrue(published)
        XCTAssertEqual(encryptionAtConnected, VNCContentEncryption.none)

        session.removeConnectionStateObserver(observerID)
        session.disconnect()
        XCTAssertNil(session.negotiatedContentEncryption)
    }

    @MainActor
    func testSessionRecoversAllDeferredServerInitDimensionVariants() async throws {
        let recoveredWidth: UInt16 = 16
        let recoveredHeight: UInt16 = 8

        for (initialWidth, initialHeight) in [
            (UInt16(0), UInt16(0)),
            (recoveredWidth, UInt16(0)),
            (UInt16(0), recoveredHeight),
        ] {
            let connection = SuccessfulRFBConnection(
                name: "deferred-\(initialWidth)x\(initialHeight)",
                width: initialWidth,
                height: initialHeight,
                recordsFramebufferUpdateRequests: true)
            var configuration = VNCConfiguration(
                videoQualityMode: .standard,
                reconnectionPolicy: VNCReconnectionPolicy(
                    isEnabled: false,
                    maximumAttempts: 0))
            configuration.transportProvider = { _, _ in connection }
            let session = VNCSession(configuration: configuration)

            try await session.connect(credentials: VNCCredentials(
                host: "deferred.test",
                port: 5900,
                password: ""))
            var completed = await waitUntil {
                session.connectionState.isConnected
            }
            XCTAssertTrue(completed)
            XCTAssertNil(session.currentImage)

            var requestCount = await connection
                .framebufferUpdateRequestCount()
            await connection.enqueueServerBytes(Self.desktopSizeFramebufferUpdate(
                width: recoveredWidth,
                height: recoveredHeight))
            completed = await waitForFramebufferRequest(
                after: requestCount,
                on: connection)
            XCTAssertTrue(completed)
            XCTAssertEqual(session.framebufferWidth, Int(recoveredWidth))
            XCTAssertEqual(session.framebufferHeight, Int(recoveredHeight))
            XCTAssertNil(session.currentImage)

            requestCount = await connection.framebufferUpdateRequestCount()
            await connection.enqueueServerBytes(Self.rawFramebufferUpdate(
                x: 0, y: 0,
                width: recoveredWidth, height: recoveredHeight,
                byte: 0x5a))
            completed = await waitForFramebufferRequest(
                after: requestCount,
                on: connection)
            XCTAssertTrue(completed)
            completed = await waitUntil { session.currentImage != nil }
            XCTAssertTrue(completed)
            session.disconnect()
        }
    }

    @MainActor
    func testAppleServerDisplayInfoRecoversZeroServerInit() async throws {
        let connection = SuccessfulRFBConnection(
            name: "deferred-apple",
            width: 0,
            height: 0,
            recordsFramebufferUpdateRequests: true)
        var configuration = VNCConfiguration(
            videoQualityMode: .standard,
            reconnectionPolicy: VNCReconnectionPolicy(
                isEnabled: false,
                maximumAttempts: 0))
        configuration.transportProvider = { _, _ in connection }
        let session = VNCSession(configuration: configuration)

        try await session.connect(credentials: VNCCredentials(
            host: "mac.test",
            port: 5900,
            password: ""))
        var completed = await waitUntil {
            session.connectionState.isConnected
        }
        XCTAssertTrue(completed)
        XCTAssertNil(session.currentImage)

        let requestCount = await connection.framebufferUpdateRequestCount()
        await connection.enqueueServerBytes(Self.appleDisplayInfoFramebufferUpdate([
            AppleDisplayInfo(
                displayIndex: 0,
                originX: 0,
                originY: 0,
                width: 16,
                height: 8,
                flags: 0),
            AppleDisplayInfo(
                displayIndex: 1,
                originX: 16,
                originY: 0,
                width: 16,
                height: 8,
                flags: 0),
        ]))
        completed = await waitForFramebufferRequest(
            after: requestCount,
            on: connection)
        XCTAssertTrue(completed, "DisplayInfo must restart the RFB request loop")
        completed = await waitUntil {
            session.framebufferWidth == 32 && session.framebufferHeight == 8
        }
        XCTAssertTrue(completed)
        XCTAssertNil(session.currentImage)

        await connection.enqueueServerBytes(Self.rawFramebufferUpdate(
            x: 0, y: 0, width: 32, height: 8, byte: 0x6b))
        completed = await waitUntil { session.currentImage != nil }
        XCTAssertTrue(completed)

        let resizeRequestCount = await connection.framebufferUpdateRequestCount()
        await connection.enqueueServerBytes(Self.appleDisplayInfoFramebufferUpdate([
            AppleDisplayInfo(
                displayIndex: 0,
                originX: 0,
                originY: 0,
                width: 16,
                height: 8,
                flags: 0),
        ]))
        completed = await waitForFramebufferRequest(
            after: resizeRequestCount,
            on: connection)
        XCTAssertTrue(completed)
        completed = await waitUntil {
            session.framebufferWidth == 16 && session.framebufferHeight == 8
        }
        XCTAssertTrue(completed, "A complete classic layout must evict unplugged displays")
        let latestRequest = await connection.lastFramebufferUpdateRequest()
        XCTAssertEqual(
            latestRequest,
            ClientMessage.framebufferUpdateRequest(
                incremental: true,
                x: 0, y: 0,
                width: 16, height: 8).serialize(),
            "Transport and state-machine geometry must shrink with the layout")
        session.disconnect()
    }

    @MainActor
    func testPreGeometryCursorIsReplayedAfterDesktopSize() async throws {
        let connection = SuccessfulRFBConnection(
            name: "deferred-cursor",
            width: 0,
            height: 0)
        var configuration = VNCConfiguration(
            videoQualityMode: .standard,
            reconnectionPolicy: VNCReconnectionPolicy(
                isEnabled: false,
                maximumAttempts: 0))
        configuration.transportProvider = { _, _ in connection }
        let session = VNCSession(configuration: configuration)

        try await session.connect(credentials: VNCCredentials(
            host: "cursor.test",
            port: 5900,
            password: ""))
        var completed = await waitUntil { session.connectionState.isConnected }
        XCTAssertTrue(completed)

        var updates = Self.cursorFramebufferUpdate()
        updates.append(Self.desktopSizeFramebufferUpdate(width: 16, height: 8))
        await connection.enqueueServerBytes(updates)

        completed = await waitUntil {
            session.framebufferWidth == 16
                && session.framebufferHeight == 8
                && session.remoteCursor != nil
        }
        XCTAssertTrue(completed)
        session.disconnect()
    }

    @MainActor
    func testPreGeometryCompressedOverflowTerminatesStream() async throws {
        let connection = SuccessfulRFBConnection(
            name: "deferred-zlib-overflow",
            width: 0,
            height: 0)
        var configuration = VNCConfiguration(
            videoQualityMode: .standard,
            reconnectionPolicy: VNCReconnectionPolicy(
                isEnabled: false,
                maximumAttempts: 0))
        configuration.transportProvider = { _, _ in connection }
        let session = VNCSession(configuration: configuration)

        try await session.connect(credentials: VNCCredentials(
            host: "compressed-overflow.test",
            port: 5900,
            password: ""))
        var completed = await waitUntil { session.connectionState.isConnected }
        XCTAssertTrue(completed)

        // The session's pre-geometry limit is 512 rectangles. Zlib uses a
        // persistent inflater, so dropping rectangle 513 and continuing would
        // permanently desynchronize every later compressed update.
        await connection.enqueueServerBytes(
            Self.emptyZlibFramebufferUpdate(rectangleCount: 513))

        completed = await waitUntil {
            guard case .protocolViolation(let detail) = session.lastError else {
                return false
            }
            return detail.contains("persistent compression state")
        }
        XCTAssertTrue(completed)
        completed = await waitUntil { session.connectionState == .disconnected }
        XCTAssertTrue(completed, "Overflow must terminate instead of returning RFB credit")
    }

    @MainActor
    func testSessionPublishesAppleLoginPromptFromDisplayInfo2() async throws {
        let connection = SuccessfulRFBConnection(name: "apple-login")
        var configuration = VNCConfiguration(
            videoQualityMode: .standard,
            promptForLoginPasswordAtLoginWindow: true,
            reconnectionPolicy: VNCReconnectionPolicy(
                isEnabled: false,
                maximumAttempts: 0))
        configuration.transportProvider = { _, _ in connection }
        let session = VNCSession(configuration: configuration)

        try await session.connect(credentials: VNCCredentials(
            host: "apple.test",
            port: 5900,
            password: "secret"))
        let connected = await waitUntil {
            session.connectionState.isConnected
        }
        XCTAssertTrue(connected)

        await connection.enqueueServerBytes(
            Self.appleLoginFramebufferUpdate(screenFlags: 0x10))
        let prompted = await waitUntil {
            session.loginPasswordPromptPending
        }
        XCTAssertTrue(prompted)
        XCTAssertTrue(session.consumeLoginPasswordPromptRequest())
        XCTAssertFalse(session.consumeLoginPasswordPromptRequest())
        session.disconnect()
    }

    @MainActor
    func testVisionReplaysFrameThatPrecedesAppleMetadata() async throws {
        let connection = SuccessfulRFBConnection(name: "apple-vision-race")
        var configuration = VNCConfiguration(
            videoQualityMode: .standard,
            promptForLoginPasswordAtLoginWindow: true,
            reconnectionPolicy: VNCReconnectionPolicy(
                isEnabled: false,
                maximumAttempts: 0))
        configuration.transportProvider = { _, _ in connection }
        let session = VNCSession(configuration: configuration)
        session.appleLoginVisionAnalysisOverrideForTesting = {
            AppleLoginTextAnalysis(
                isLoginScreen: true,
                recognizedLineCount: 1,
                evidence: "test login")
        }

        try await session.connect(credentials: VNCCredentials(
            host: "apple.test",
            port: 5900,
            password: "secret"))
        let connected = await waitUntil {
            session.connectionState.isConnected
        }
        XCTAssertTrue(connected)

        session.considerAppleLoginVisionImageForTesting(Self.visionTestImage())
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(session.loginPasswordPromptPending)

        await connection.enqueueServerBytes(
            Self.appleDisplayInfoFramebufferUpdate([
                AppleDisplayInfo(
                    displayIndex: 1,
                    originX: 0,
                    originY: 0,
                    width: 1024,
                    height: 768,
                    flags: 0),
            ]))

        let prompted = await waitUntil {
            session.loginPasswordPromptPending
        }
        XCTAssertTrue(prompted)
        session.disconnect()
    }

    @MainActor
    func testVisionStopsAfterInitialAttemptsAreExhausted() async throws {
        let connection = SuccessfulRFBConnection(name: "apple-vision-bounded")
        var configuration = VNCConfiguration(
            videoQualityMode: .standard,
            promptForLoginPasswordAtLoginWindow: true,
            reconnectionPolicy: VNCReconnectionPolicy(
                isEnabled: false,
                maximumAttempts: 0))
        configuration.transportProvider = { _, _ in connection }
        let session = VNCSession(configuration: configuration)
        let analysis = LockedLoginVisionAnalysis()
        session.appleLoginVisionAnalysisOverrideForTesting = {
            analysis.analyze()
        }

        try await session.connect(credentials: VNCCredentials(
            host: "apple.test",
            port: 5900,
            password: "secret"))
        let connected = await waitUntil {
            session.connectionState.isConnected
        }
        XCTAssertTrue(connected)
        await connection.enqueueServerBytes(
            Self.appleDisplayInfoFramebufferUpdate([
                AppleDisplayInfo(
                    displayIndex: 1,
                    originX: 0,
                    originY: 0,
                    width: 1024,
                    height: 768,
                    flags: 0),
            ]))

        let image = Self.visionTestImage()
        session.considerAppleLoginVisionImageForTesting(image)
        let exhausted = await waitUntil(timeout: .seconds(3)) {
            analysis.count == 3
        }
        XCTAssertTrue(exhausted)
        XCTAssertFalse(session.loginPasswordPromptPending)

        analysis.setDetected(true)
        session.considerAppleLoginVisionImageForTesting(
            image,
            source: "frame after bounded scan")
        try? await Task.sleep(for: .milliseconds(250))
        XCTAssertFalse(session.loginPasswordPromptPending)
        XCTAssertEqual(
            analysis.count,
            3,
            "Vision must not continue scanning newer frames indefinitely")
        session.disconnect()
    }

    @MainActor
    func testVisionPromptsAgainAfterExplicitDisconnectAndReconnect() async throws {
        let recorder = SuccessfulProviderRecorder()
        var configuration = VNCConfiguration(
            videoQualityMode: .standard,
            promptForLoginPasswordAtLoginWindow: true,
            reconnectionPolicy: VNCReconnectionPolicy(
                isEnabled: false,
                maximumAttempts: 0))
        configuration.transportProvider = { host, port in
            recorder.makeConnection(host: host, port: port)
        }
        let session = VNCSession(configuration: configuration)
        session.appleLoginVisionAnalysisOverrideForTesting = {
            AppleLoginTextAnalysis(
                isLoginScreen: true,
                recognizedLineCount: 1,
                evidence: "test login")
        }
        let credentials = VNCCredentials(
            host: "apple.test",
            port: 5900,
            password: "secret")

        try await session.connect(credentials: credentials)
        var connected = await waitUntil {
            recorder.createdConnections.count == 1
                && session.connectionState.isConnected
        }
        XCTAssertTrue(connected)
        let firstConnection = try XCTUnwrap(
            recorder.createdConnections.first)
        await firstConnection.enqueueServerBytes(
            Self.appleDisplayInfoFramebufferUpdate([
                AppleDisplayInfo(
                    displayIndex: 1,
                    originX: 0,
                    originY: 0,
                    width: 1024,
                    height: 768,
                    flags: 0),
            ]))
        session.considerAppleLoginVisionImageForTesting(Self.visionTestImage())
        var prompted = await waitUntil {
            session.loginPasswordPromptPending
        }
        XCTAssertTrue(prompted)
        XCTAssertTrue(session.consumeLoginPasswordPromptRequest())
        session.sendLoginPassword()

        session.disconnect()
        XCTAssertEqual(session.connectionState, .disconnected)

        try await session.connect(credentials: credentials)
        connected = await waitUntil {
            recorder.createdConnections.count == 2
                && session.connectionState.isConnected
        }
        XCTAssertTrue(connected)
        let secondConnection = try XCTUnwrap(
            recorder.createdConnections.last)
        await secondConnection.enqueueServerBytes(
            Self.appleDisplayInfoFramebufferUpdate([
                AppleDisplayInfo(
                    displayIndex: 1,
                    originX: 0,
                    originY: 0,
                    width: 1024,
                    height: 768,
                    flags: 0),
            ]))
        session.considerAppleLoginVisionImageForTesting(
            Self.visionTestImage(),
            source: "second connection")

        prompted = await waitUntil(timeout: .seconds(2)) {
            session.loginPasswordPromptPending
        }
        XCTAssertTrue(
            prompted,
            "A previous connection's delivery debounce must not suppress "
                + "the next connection's login prompt")
        session.disconnect()
    }

    @MainActor
    func testSessionTracksCurtainStateFromDisplayInfo2() async throws {
        let connection = SuccessfulRFBConnection(name: "apple-curtain")
        var configuration = VNCConfiguration(
            videoQualityMode: .standard,
            reconnectionPolicy: VNCReconnectionPolicy(
                isEnabled: false,
                maximumAttempts: 0))
        configuration.transportProvider = { _, _ in connection }
        let session = VNCSession(configuration: configuration)

        try await session.connect(credentials: VNCCredentials(
            host: "apple.test",
            port: 5900,
            password: "secret"))
        let connected = await waitUntil {
            session.connectionState.isConnected
        }
        XCTAssertTrue(connected)

        // Curtain is never offered until the server says so.
        XCTAssertFalse(session.supportsCurtainMode)
        session.setCurtainMode(true, message: "ignored")

        // Offered, and the session is still drawn on the remote console.
        await connection.enqueueServerBytes(
            Self.appleLoginFramebufferUpdate(screenFlags: 0x02 | 0x04))
        let offered = await waitUntil { session.supportsCurtainMode }
        XCTAssertTrue(offered)
        XCTAssertFalse(session.isCurtained)

        // The server reports the session has left the console.
        await connection.enqueueServerBytes(
            Self.appleLoginFramebufferUpdate(screenFlags: 0x02))
        let curtained = await waitUntil { session.isCurtained }
        XCTAssertTrue(curtained)
        XCTAssertFalse(session.curtainChangeFailed)

        session.disconnect()
        XCTAssertFalse(session.supportsCurtainMode)
        XCTAssertFalse(session.isCurtained)
    }

    @MainActor
    func testReconnectAppliesConfigurationAndRetainsActiveCredentials() async throws {
        let recorder = SuccessfulProviderRecorder()
        var configuration = VNCConfiguration(
            videoQualityMode: .fullQuality,
            reconnectionPolicy: VNCReconnectionPolicy(
                isEnabled: false,
                maximumAttempts: 0))
        configuration.transportProvider = { host, port in
            recorder.makeConnection(host: host, port: port)
        }

        let session = VNCSession(configuration: configuration)
        try await session.connect(credentials: VNCCredentials(
            host: "vnc.internal",
            port: 5901,
            password: "secret"))
        let initiallyConnected = await waitUntil {
            session.connectionState.isConnected
        }
        XCTAssertTrue(initiallyConnected)

        // Model the negotiated state left by the High Performance transport
        // that the HUD is replacing with Standard mode.
        session.isHighPerformanceMode = true

        var replacement = session.configuration
        replacement.videoQualityMode = .standard
        XCTAssertTrue(session.reconnect(with: replacement))
        XCTAssertFalse(session.reconnect(with: replacement))

        let reconnected = await waitUntil {
            recorder.recorded.count == 2 && session.connectionState.isConnected
        }
        XCTAssertTrue(reconnected)
        XCTAssertEqual(session.configuration.videoQualityMode, .standard)
        XCTAssertFalse(session.isHighPerformanceMode)
        XCTAssertEqual(recorder.recorded.map(\.host), ["vnc.internal", "vnc.internal"])
        XCTAssertEqual(recorder.recorded.map(\.port), [5901, 5901])

        session.disconnect()
    }

    @MainActor
    func testReconnectWaitsForReplacementInitialFramebufferCoverage() async throws {
        let width: UInt16 = 16
        let height: UInt16 = 8
        let recorder = SuccessfulProviderRecorder(
            width: width,
            height: height,
            recordsFramebufferUpdateRequests: true)
        var configuration = VNCConfiguration(
            videoQualityMode: .standard,
            targetFrameRate: 1,
            reconnectionPolicy: VNCReconnectionPolicy(
                isEnabled: false,
                maximumAttempts: 0))
        configuration.transportProvider = { host, port in
            recorder.makeConnection(host: host, port: port)
        }

        let session = VNCSession(configuration: configuration)
        try await session.connect(credentials: VNCCredentials(
            host: "frame-generation.test",
            port: 5900,
            password: ""))
        var completed = await waitUntil {
            session.connectionState.isConnected
        }
        XCTAssertTrue(completed)
        let firstConnection = try XCTUnwrap(
            recorder.createdConnections.first)

        var requestCount = await firstConnection
            .framebufferUpdateRequestCount()
        await firstConnection.enqueueServerBytes(
            Self.dctQuantizationFramebufferUpdate())
        completed = await waitForFramebufferRequest(
            after: requestCount,
            on: firstConnection)
        XCTAssertTrue(completed)
        XCTAssertNil(session.currentImage)

        requestCount = await firstConnection.framebufferUpdateRequestCount()
        await firstConnection.enqueueServerBytes(Self.rawFramebufferUpdate(
            x: 0, y: 0,
            width: width, height: height,
            byte: 0x33))
        completed = await waitForFramebufferRequest(
            after: requestCount,
            on: firstConnection)
        XCTAssertTrue(completed)
        completed = await waitUntil { session.currentImage != nil }
        XCTAssertTrue(completed)
        let firstImage = try XCTUnwrap(session.currentImage)

        // Leave a cadence-delayed snapshot owned by the first connection.
        // It must be cancelled or generation-rejected after the reconnect.
        requestCount = await firstConnection.framebufferUpdateRequestCount()
        await firstConnection.enqueueServerBytes(Self.rawFramebufferUpdate(
            x: 0, y: 0,
            width: width, height: height,
            byte: 0x44))
        completed = await waitForFramebufferRequest(
            after: requestCount,
            on: firstConnection)
        XCTAssertTrue(completed)

        XCTAssertTrue(session.reconnect(with: session.configuration))
        completed = await waitUntil {
            recorder.createdConnections.count == 2
                && session.connectionState.isConnected
        }
        XCTAssertTrue(completed)
        let secondConnection = try XCTUnwrap(
            recorder.createdConnections.last)
        XCTAssertTrue(session.currentImage === firstImage)

        // A replacement renderer exists after ServerInit, but no pixels from
        // its generation do. Neither explicit reconciliation nor the
        // suspension edge may snapshot its zero-filled framebuffer.
        session.reconcileDisplayPresentation()
        session.suspendsDisplayPresentation = true
        session.suspendsDisplayPresentation = false
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(session.currentImage === firstImage)

        requestCount = await secondConnection.framebufferUpdateRequestCount()
        await secondConnection.enqueueServerBytes(
            Self.dctQuantizationFramebufferUpdate())
        completed = await waitForFramebufferRequest(
            after: requestCount,
            on: secondConnection)
        XCTAssertTrue(completed)

        // Half of the replacement base must neither satisfy the fresh gate nor
        // let the old connection's delayed snapshot publish the new buffer.
        requestCount = await secondConnection.framebufferUpdateRequestCount()
        await secondConnection.enqueueServerBytes(Self.rawFramebufferUpdate(
            x: 0, y: 0,
            width: width / 2, height: height,
            byte: 0x66))
        completed = await waitForFramebufferRequest(
            after: requestCount,
            on: secondConnection)
        XCTAssertTrue(completed)
        session.reconcileDisplayPresentation()
        session.suspendsDisplayPresentation = true
        session.suspendsDisplayPresentation = false
        try? await Task.sleep(for: .milliseconds(1_100))
        XCTAssertTrue(session.currentImage === firstImage)

        requestCount = await secondConnection.framebufferUpdateRequestCount()
        await secondConnection.enqueueServerBytes(Self.rawFramebufferUpdate(
            x: width / 2, y: 0,
            width: width / 2, height: height,
            byte: 0x77))
        completed = await waitForFramebufferRequest(
            after: requestCount,
            on: secondConnection)
        XCTAssertTrue(completed)
        completed = await waitUntil {
            guard let image = session.currentImage else { return false }
            return image !== firstImage
        }
        XCTAssertTrue(completed)

        session.disconnect()
    }

    private static func appleLoginFramebufferUpdate(
        screenFlags: UInt32
    ) -> Data {
        var payload = Data(repeating: 0, count: 20)
        payload[0] = 0
        payload[1] = 18
        payload[2] = 0
        payload[3] = 5
        payload[16] = UInt8((screenFlags >> 24) & 0xff)
        payload[17] = UInt8((screenFlags >> 16) & 0xff)
        payload[18] = UInt8((screenFlags >> 8) & 0xff)
        payload[19] = UInt8(screenFlags & 0xff)

        var update = Data([0, 0, 0, 1])
        update.append(contentsOf: [
            0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 4, 81,
        ])
        update.append(payload)
        return update
    }

    private static func appleDisplayInfoFramebufferUpdate(
        _ displays: [AppleDisplayInfo]
    ) -> Data {
        var update = Data([
            0, 0,
            UInt8((displays.count >> 8) & 0xff),
            UInt8(displays.count & 0xff),
        ])
        for display in displays {
            update.append(rectangleHeader(
                x: 0, y: 0, width: 0, height: 0,
                encoding: Encoding.serverDisplayInfo.rawValue))
            for value in [
                display.displayIndex,
                UInt32(bitPattern: display.originX),
                UInt32(bitPattern: display.originY),
                display.width,
                display.height,
                display.flags,
            ] {
                update.append(contentsOf: bigEndianBytes(value))
            }
        }
        return update
    }

    private static func cursorFramebufferUpdate() -> Data {
        var update = Data([0, 0, 0, 1])
        update.append(rectangleHeader(
            x: 0, y: 0, width: 1, height: 1,
            encoding: Encoding.cursor.rawValue))
        update.append(contentsOf: [0x00, 0x00, 0xff, 0xff, 0x80])
        return update
    }

    private static func dctQuantizationFramebufferUpdate() -> Data {
        var update = Data([0, 0, 0, 1])
        update.append(rectangleHeader(
            x: 0, y: 0, width: 0, height: 0,
            encoding: Encoding.appleMultiVariantScreenshare.rawValue))
        update.append(contentsOf: [0, 0, 0, 129, 2])
        update.append(Data(repeating: 0, count: 128))
        return update
    }

    private static func desktopSizeFramebufferUpdate(
        width: UInt16,
        height: UInt16
    ) -> Data {
        var update = Data([0, 0, 0, 1])
        update.append(rectangleHeader(
            x: 0, y: 0, width: width, height: height,
            encoding: Encoding.desktopSize.rawValue))
        return update
    }

    private static func rawFramebufferUpdate(
        x: UInt16,
        y: UInt16,
        width: UInt16,
        height: UInt16,
        byte: UInt8
    ) -> Data {
        var update = Data([0, 0, 0, 1])
        update.append(rectangleHeader(
            x: x, y: y, width: width, height: height,
            encoding: Encoding.raw.rawValue))
        update.append(Data(
            repeating: byte,
            count: Int(width) * Int(height) * 4))
        return update
    }

    private static func emptyZlibFramebufferUpdate(
        rectangleCount: UInt16
    ) -> Data {
        var update = Data([0, 0])
        update.append(contentsOf: bigEndianBytes(rectangleCount))
        for _ in 0..<rectangleCount {
            update.append(rectangleHeader(
                x: 0, y: 0, width: 1, height: 1,
                encoding: Encoding.zlib.rawValue))
            // A zero compressed-length is sufficient for transport framing;
            // no inflater sees it because geometry is deliberately absent.
            update.append(contentsOf: [0, 0, 0, 0])
        }
        return update
    }

    private static func rectangleHeader(
        x: UInt16,
        y: UInt16,
        width: UInt16,
        height: UInt16,
        encoding: Int32
    ) -> Data {
        let rawEncoding = UInt32(bitPattern: encoding)
        return Data([
            UInt8(x >> 8), UInt8(x & 0xff),
            UInt8(y >> 8), UInt8(y & 0xff),
            UInt8(width >> 8), UInt8(width & 0xff),
            UInt8(height >> 8), UInt8(height & 0xff),
            UInt8((rawEncoding >> 24) & 0xff),
            UInt8((rawEncoding >> 16) & 0xff),
            UInt8((rawEncoding >> 8) & 0xff),
            UInt8(rawEncoding & 0xff),
        ])
    }

    private static func bigEndianBytes<T: FixedWidthInteger>(
        _ value: T
    ) -> [UInt8] {
        withUnsafeBytes(of: value.bigEndian) { Array($0) }
    }

    private static func visionTestImage() -> CGImage {
        let bytes = Data([0, 0, 0, 0])
        let provider = CGDataProvider(data: bytes as CFData)!
        return CGImage(
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(
                rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent)!
    }

    @MainActor
    func testReconnectRejectsIdleSessionWithoutChangingConfiguration() {
        let session = VNCSession(configuration: VNCConfiguration(
            videoQualityMode: .standard))
        var replacement = session.configuration
        replacement.videoQualityMode = .fullQuality

        XCTAssertFalse(session.reconnect(with: replacement))
        XCTAssertEqual(session.configuration.videoQualityMode, .standard)
    }

    @MainActor
    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @MainActor
    private func waitForFramebufferRequest(
        after previousCount: Int,
        on connection: SuccessfulRFBConnection,
        timeout: Duration = .seconds(2)
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await connection.framebufferUpdateRequestCount()
                > previousCount {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await connection.framebufferUpdateRequestCount()
            > previousCount
    }
}
