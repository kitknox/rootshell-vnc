import Foundation
import Network
import NIOCore
@preconcurrency import NIOSSL
import NIOTLS
import NIOTransportServices
import RFBProtocol
import Security

public enum NetworkPathInterfaceKind: Sendable, Equatable {
    case cellular
    case wifi
    case wiredEthernet
    case loopback
    case other
}

public struct NetworkPathCharacteristics: Sendable, Equatable {
    public let interface: NetworkPathInterfaceKind
    public let usesOtherInterface: Bool
    public let isExpensive: Bool
    public let isConstrained: Bool

    public init(
        interface: NetworkPathInterfaceKind,
        usesOtherInterface: Bool,
        isExpensive: Bool,
        isConstrained: Bool
    ) {
        self.interface = interface
        self.usesOtherInterface = usesOtherInterface
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
    }
}

/// Async TCP byte stream backed by Network.framework through NIO Transport
/// Services. Keeping the channel in a NIO pipeline lets VeNCrypt insert an
/// NIOSSL handler after the plaintext RFB security negotiation (STARTTLS).
public actor TCPConnection: RFBConnection {
    private static let eventLoopGroup = NIOTSEventLoopGroup(
        loopCount: 1,
        defaultQoS: .userInitiated)

    private let host: String
    private let port: UInt16
    private let log = VNCLogger(category: "TCPConnection")
    private var channel: Channel?
    private var inboundHandler: InboundByteStreamHandler?
    private var inboundQueue: InboundByteQueue?
    private var disconnectHandler: (@Sendable (VNCProtocolError) -> Void)?
    private var connected = false
    private var isClosing = false

    /// Last known path, captured while the channel was alive.
    ///
    /// ``pathCharacteristics()`` reads the option off the channel, and the
    /// disconnect summary runs after the channel is gone, so every teardown
    /// line in a debug capture reported `interface=unknown`: the one field
    /// that would separate "Wi-Fi went away" from every other cause was never
    /// populated at the only moment it mattered.
    private var lastKnownPath: NetworkPathCharacteristics?

    /// Peer selected by Network.framework for the live connection, captured at
    /// connect time for the same reason.
    private var lastKnownRemoteEndpoint: String?

    /// User-space read buffer. RFB parsing does many small field-sized reads,
    /// so a single channel read is shared across subsequent parser requests.
    private var receiveBuffer = Data()
    private var receiveOffset = 0
    private static let compactionThreshold = 64 * 1024

    /// Backstop against a desynchronized or hostile RFB stream. The largest
    /// legitimate exact read is a raw full-screen rectangle (a 6K display at
    /// 4 bytes per pixel is ~100 MB), so anything past this is a garbage
    /// length field, and honoring it grows `receiveBuffer` until the Data
    /// reallocation fails with a fatal assertion rather than a throwable
    /// error. Refusing here turns that crash into a protocol violation the
    /// session teardown path already knows how to report.
    static let maxExactReadBytes = 256 * 1024 * 1024

    /// Dial retry tuning; injectable so tests don't sit through real backoffs.
    private let maxDialAttempts: Int
    private let dialRetryBackoffNanos: UInt64
    private let connectTimeoutSeconds: Int
    private let keepalive: KeepaliveSettings

    /// TCP keepalive tuning.
    ///
    /// This is the only "peer has gone silent" detector in the whole stack:
    /// there is no application-level read or idle timeout. In Apple's High
    /// Performance mode the video and rate-control traffic is UDP, and what
    /// remains on TCP is request/response (the client asks for the next update
    /// only after consuming one), so an idle remote desktop legitimately means
    /// an idle socket with no periodic traffic of any kind. The defaults must
    /// therefore tolerate a transient run of lost probes over a wireless leg
    /// rather than tearing down a working session, at the cost of taking
    /// longer to notice a genuinely dead peer.
    ///
    /// Defaults declare death after roughly `idle + interval * count` seconds
    /// of silence (20 + 60 = 80 s). The reconnect machinery takes over from
    /// there, so a slower verdict costs recovery latency on a real failure but
    /// buys immunity to false positives on a healthy idle session.
    public struct KeepaliveSettings: Sendable, Equatable {
        public var idleSeconds: Int
        public var intervalSeconds: Int
        public var probeCount: Int

        public init(idleSeconds: Int = 20, intervalSeconds: Int = 10, probeCount: Int = 6) {
            self.idleSeconds = max(1, idleSeconds)
            self.intervalSeconds = max(1, intervalSeconds)
            self.probeCount = max(1, probeCount)
        }

        /// Seconds of total silence before the socket is declared dead.
        public var deadPeerDetectionSeconds: Int {
            idleSeconds + intervalSeconds * probeCount
        }
    }

    public init(host: String, port: UInt16) {
        self.init(
            host: host, port: port,
            maxDialAttempts: 3,
            dialRetryBackoffNanos: 1_000_000_000,
            connectTimeoutSeconds: 10)
    }

    init(
        host: String,
        port: UInt16,
        maxDialAttempts: Int,
        dialRetryBackoffNanos: UInt64,
        connectTimeoutSeconds: Int,
        keepalive: KeepaliveSettings = KeepaliveSettings()
    ) {
        self.host = host
        self.port = port
        self.maxDialAttempts = max(1, maxDialAttempts)
        self.dialRetryBackoffNanos = dialRetryBackoffNanos
        self.connectTimeoutSeconds = max(1, connectTimeoutSeconds)
        self.keepalive = keepalive
    }

    public func connect() async throws {
        guard channel == nil else { return }
        isClosing = false
        receiveBuffer.removeAll(keepingCapacity: true)
        receiveOffset = 0

        // On-demand VPNs (Tailscale and friends) bring their tunnel up in
        // response to the first dial, which can fail before the route exists.
        // Retry briefly so the tunnel warmed by a failed attempt gets used,
        // instead of surfacing the failure and making the user reconnect.
        for attempt in 1...maxDialAttempts {
            let attemptStart = DispatchTime.now().uptimeNanoseconds
            do {
                try await dialOnce()
                return
            } catch {
                // Elapsed time discriminates failure modes: ~instant means
                // refused/unroutable, ~connectTimeout means the dial sat in
                // Network.framework's .waiting (cold DNS or path not ready).
                let elapsedMilliseconds =
                    (DispatchTime.now().uptimeNanoseconds &- attemptStart) / 1_000_000
                guard attempt < maxDialAttempts, !isClosing else {
                    log.error(
                        "Connect attempt \(attempt)/\(maxDialAttempts) to \(host):\(port) "
                            + "failed after \(elapsedMilliseconds)ms "
                            + "(\(error.localizedDescription)); giving up")
                    throw error
                }
                log.warning(
                    "Connect attempt \(attempt)/\(maxDialAttempts) to \(host):\(port) "
                        + "failed after \(elapsedMilliseconds)ms "
                        + "(\(error.localizedDescription)); retrying")
                try await Task.sleep(nanoseconds: UInt64(attempt) * dialRetryBackoffNanos)
                guard !isClosing else { throw error }
            }
        }
    }

    private func dialOnce() async throws {
        let handler = InboundByteStreamHandler { [weak self] error in
            Task { await self?.notifyUnexpectedDisconnect(error) }
        }
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = keepalive.idleSeconds
        tcpOptions.keepaliveInterval = keepalive.intervalSeconds
        tcpOptions.keepaliveCount = keepalive.probeCount
        tcpOptions.connectionTimeout = connectTimeoutSeconds

        let bootstrap = NIOTSConnectionBootstrap(group: Self.eventLoopGroup)
            .connectTimeout(.seconds(Int64(connectTimeoutSeconds)))
            .withQoS(.userInitiated)
            .tcpOptions(tcpOptions)
            // RFB framebuffer processing applies its own credit-based
            // backpressure. Read only when the parser needs another chunk so
            // a paused renderer also stops draining the kernel socket.
            .channelOption(ChannelOptions.autoRead, value: false)
            .channelOption(NIOTSChannelOptions.allowLocalEndpointReuse, value: true)
            .configureNWParameters { parameters in
                parameters.serviceClass = .responsiveData
            }
            .channelInitializer { channel in
                channel.pipeline.addHandler(handler)
            }

        log.info("Connecting to \(host):\(port)")
        do {
            let connectedChannel = try await bootstrap
                .connect(host: host, port: Int(port))
                .get()
            channel = connectedChannel
            inboundHandler = handler
            inboundQueue = handler.queue
            connected = true
            // Both of these populate the caches above as a side effect, which
            // is the point: the teardown summary runs after the channel is
            // dead and needs a value captured while it was not.
            let pathDescription = await pathCharacteristics()
                .map { String(describing: $0.interface) } ?? "unknown"
            let peerDescription = await remoteEndpointHost() ?? "unknown"
            log.info(
                "Connected to \(host):\(port) "
                    + "(keepalive idle=\(keepalive.idleSeconds)s "
                    + "interval=\(keepalive.intervalSeconds)s "
                    + "count=\(keepalive.probeCount), "
                    + "dead-peer verdict after ~\(keepalive.deadPeerDetectionSeconds)s of silence)")
            // Peer and interface on the record at connect time. Which of the
            // server's addresses Happy Eyeballs picked for a Bonjour name is
            // otherwise only inferable from the media path's own log line.
            log.info("Selected peer \(peerDescription) over \(pathDescription)")
        } catch {
            let protocolError = VNCProtocolError.ioError(
                "Connection failed: \(error.localizedDescription)")
            handler.finish(throwing: protocolError)
            throw protocolError
        }
    }

    public func read(exactly count: Int) async throws -> Data {
        guard count >= 0 else {
            throw VNCProtocolError.protocolViolation("Negative read length")
        }
        guard count <= Self.maxExactReadBytes else {
            throw VNCProtocolError.protocolViolation(
                "Server demanded a \(count)-byte read; refusing "
                    + "(stream desynchronized or hostile)")
        }
        while bufferedByteCount < count {
            try await fillBuffer()
        }
        return consumeBuffered(count)
    }

    public func read(upTo maxCount: Int) async throws -> Data {
        guard maxCount > 0 else {
            throw VNCProtocolError.protocolViolation("Read length must be positive")
        }
        if bufferedByteCount == 0 {
            try await fillBuffer()
        }
        return consumeBuffered(min(bufferedByteCount, maxCount))
    }

    private var bufferedByteCount: Int {
        receiveBuffer.count - receiveOffset
    }

    private func fillBuffer() async throws {
        guard let inboundQueue, let channel else {
            throw VNCProtocolError.connectionClosed
        }
        do {
            let data = try await inboundQueue.next {
                channel.read()
            }
            if !data.isEmpty { receiveBuffer.append(data) }
        } catch let error as VNCProtocolError {
            throw error
        } catch {
            throw VNCProtocolError.ioError("Read error: \(error.localizedDescription)")
        }
    }

    private func consumeBuffered(_ count: Int) -> Data {
        let start = receiveBuffer.startIndex + receiveOffset
        let result = receiveBuffer.subdata(in: start..<(start + count))
        receiveOffset += count
        if receiveOffset == receiveBuffer.count {
            receiveBuffer.removeAll(keepingCapacity: true)
            receiveOffset = 0
        } else if receiveOffset > Self.compactionThreshold {
            // removeFirst slices Data, keeping every received byte and walking
            // startIndex past Int32.max; removeSubrange compacts in place.
            receiveBuffer.removeSubrange(
                receiveBuffer.startIndex..<(receiveBuffer.startIndex + receiveOffset))
            receiveOffset = 0
        }
        return result
    }

    public func send(_ data: Data) async throws {
        guard let channel, channel.isActive else {
            throw VNCProtocolError.connectionClosed
        }
        var buffer = channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        do {
            try await channel.writeAndFlush(buffer).get()
        } catch {
            throw VNCProtocolError.ioError("Send error: \(error.localizedDescription)")
        }
        log.debug("Sent \(data.count) bytes")
    }

    public func close() async {
        isClosing = true
        log.info("Closing connection to \(host):\(port)")
        if let channel {
            try? await channel.close().get()
        }
        inboundHandler?.finish()
        channel = nil
        inboundHandler = nil
        inboundQueue = nil
        connected = false
        receiveBuffer.removeAll()
        receiveOffset = 0
        // Callers that want these read them from the teardown summary, which
        // runs before close. Past this point they would describe a connection
        // that no longer exists.
        lastKnownPath = nil
        lastKnownRemoteEndpoint = nil
    }

    public var isConnected: Bool { connected }

    public func setDisconnectHandler(
        _ handler: (@Sendable (VNCProtocolError) -> Void)?
    ) {
        disconnectHandler = handler
    }

    private func notifyUnexpectedDisconnect(_ error: VNCProtocolError) {
        connected = false
        guard !isClosing else { return }
        disconnectHandler?(error)
    }

    /// Current path if the channel is still alive, otherwise the last one seen
    /// while it was. A teardown summary asks for this after the channel has
    /// been torn down, and "the interface this connection was actually using"
    /// is still the answer it needs.
    public func pathCharacteristics() async -> NetworkPathCharacteristics? {
        guard let channel else { return lastKnownPath }
        guard let path = try? await channel
            .getOption(NIOTSChannelOptions.currentPath)
            .get() else { return lastKnownPath }
        let interface: NetworkPathInterfaceKind
        if path.usesInterfaceType(.cellular) {
            interface = .cellular
        } else if path.usesInterfaceType(.wiredEthernet) {
            interface = .wiredEthernet
        } else if path.usesInterfaceType(.wifi) {
            interface = .wifi
        } else if path.usesInterfaceType(.loopback) {
            interface = .loopback
        } else {
            interface = .other
        }
        let characteristics = NetworkPathCharacteristics(
            interface: interface,
            usesOtherInterface: path.usesInterfaceType(.other),
            isExpensive: path.isExpensive,
            isConstrained: path.isConstrained)
        // Refresh on every successful read so a mid-session path change is
        // what the teardown summary reports, not the connect-time snapshot.
        lastKnownPath = characteristics
        return characteristics
    }

    /// Return the concrete peer selected by Network.framework. In particular,
    /// this preserves IPv6 for a dual-stack Bonjour name instead of asking the
    /// UDP media path to perform a second, potentially different resolution.
    public func remoteEndpointHost() async -> String? {
        guard let channel,
              let path = try? await channel
                .getOption(NIOTSChannelOptions.currentPath)
                .get()
        else { return lastKnownRemoteEndpoint }

        guard let host = Self.numericHost(from: path.remoteEndpoint) else {
            return lastKnownRemoteEndpoint
        }
        lastKnownRemoteEndpoint = host
        return host
    }

    static func numericHost(from endpoint: NWEndpoint?) -> String? {
        guard case .hostPort(let host, _) = endpoint else { return nil }
        switch host {
        case .ipv4(let address):
            return address.debugDescription
        case .ipv6(let address):
            let literal = address.debugDescription
            // Link-local IPv6 is unusable without its zone. Network.framework
            // normally includes it in debugDescription, but append the path's
            // interface explicitly when needed.
            if !literal.contains("%"), let interface = address.interface {
                return "\(literal)%\(interface.name)"
            }
            return literal
        case .name:
            // A ready NWPath is expected to expose a numeric remote endpoint.
            // Do not return another hostname and reintroduce split resolution.
            return nil
        @unknown default:
            return nil
        }
    }

    public func supportsTLSUpgrade() async -> Bool { true }

    public func startTLS(configuration: RFBTLSConfiguration) async throws {
        guard let channel, let inboundHandler else {
            throw VNCProtocolError.connectionClosed
        }

        var tlsConfiguration = TLSConfiguration.makeClientConfiguration()
        tlsConfiguration.certificateVerification = .fullVerification
        tlsConfiguration.trustRoots = .default
        let context: NIOSSLContext
        do {
            context = try NIOSSLContext(configuration: tlsConfiguration)
        } catch {
            throw VNCProtocolError.ioError(
                "Could not initialize TLS: \(error.localizedDescription)")
        }

        let sslHandler: NIOSSLClientHandler
        do {
            let host = Self.unbracketedHost(configuration.serverHostname)
            let tlsServerName = Self.tlsServerName(for: host)
            let isIPAddress = tlsServerName == nil
            let validationHandler = configuration.certificateValidationHandler
            if validationHandler != nil || isIPAddress {
                sslHandler = try NIOSSLClientHandler(
                    context: context,
                    // NIOSSL intentionally rejects IP literals as SNI names.
                    // Certificate identity for literals is checked below by
                    // Security.framework using the original endpoint.
                    serverHostname: tlsServerName,
                    customVerificationCallback: { certificates, promise in
                        Self.validateCertificateChain(
                            certificates,
                            host: host,
                            port: configuration.serverPort,
                            validationHandler: validationHandler,
                            promise: promise)
                    })
            } else {
                sslHandler = try NIOSSLClientHandler(
                    context: context,
                    serverHostname: configuration.serverHostname)
            }
            let sendableHandler = SendableSSLHandler(sslHandler)
            inboundHandler.beginTLSHandshake()
            // Build and install the non-Sendable NIOSSL handler entirely on
            // the channel's event loop. Only the explicitly synchronized box
            // crosses from this actor to the event-loop closure.
            try await channel.eventLoop.submit {
                try channel.pipeline.syncOperations.addHandler(
                    sendableHandler.value,
                    position: .first)
            }.get()
            channel.read()
            try await inboundHandler.waitForTLSHandshake()
        } catch let error as VNCProtocolError {
            throw error
        } catch {
            throw VNCProtocolError.authenticationFailed(
                "TLS handshake failed: \(error.localizedDescription)")
        }
    }

    private nonisolated static func validateCertificateChain(
        _ certificates: [NIOSSLCertificate],
        host: String,
        port: UInt16,
        validationHandler: VNCCertificateValidationHandler?,
        promise: EventLoopPromise<NIOSSLVerificationResult>
    ) {
        let derChain: [Data]
        do {
            derChain = try certificates.map { Data(try $0.toDERBytes()) }
        } catch {
            promise.succeed(.failed)
            return
        }

        let queue = DispatchQueue(
            label: "com.rootshell.vnc.certificate-validation",
            qos: .userInitiated)
        queue.async {
            if platformTrusts(derChain: derChain, hostname: host) {
                promise.succeed(.certificateVerified)
                return
            }
            guard let validationHandler else {
                promise.succeed(.failed)
                return
            }
            Task {
                let request = VNCCertificateValidationRequest(
                    host: host,
                    port: port,
                    certificateChainDER: derChain)
                let result = await validationHandler(request)
                switch result {
                case .acceptOnce, .acceptAndStore:
                    promise.succeed(.certificateVerified)
                case .reject:
                    promise.succeed(.failed)
                }
            }
        }
    }

    private nonisolated static func platformTrusts(
        derChain: [Data],
        hostname: String
    ) -> Bool {
        let certificates = derChain.compactMap {
            SecCertificateCreateWithData(nil, $0 as CFData)
        }
        guard certificates.count == derChain.count, !certificates.isEmpty else {
            return false
        }
        let policy = SecPolicyCreateSSL(true, hostname as CFString)
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates(
            certificates as CFArray,
            policy,
            &trust) == errSecSuccess,
            let trust else { return false }
        return SecTrustEvaluateWithError(trust, nil)
    }

    private nonisolated static func unbracketedHost(_ host: String) -> String {
        guard host.first == "[", host.last == "]" else { return host }
        return String(host.dropFirst().dropLast())
    }

    private nonisolated static func isIPAddress(_ host: String) -> Bool {
        IPv4Address(host) != nil || IPv6Address(host) != nil
    }

    /// NIOSSL accepts DNS names for SNI/identity checking but rejects IP
    /// literals at handler construction time. IP identity is instead checked
    /// by ``platformTrusts(derChain:hostname:)``.
    nonisolated static func tlsServerName(for endpointHost: String) -> String? {
        let host = unbracketedHost(endpointHost)
        return isIPAddress(host) ? nil : host
    }
}

private final class InboundByteStreamHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    let queue = InboundByteQueue()
    private let disconnect: @Sendable (VNCProtocolError) -> Void
    private let lock = NSLock()
    private var tlsResult: Result<Void, Error>?
    private var tlsContinuation: CheckedContinuation<Void, Error>?
    private var tlsHandshakePending = false
    private var didFinish = false

    init(disconnect: @escaping @Sendable (VNCProtocolError) -> Void) {
        self.disconnect = disconnect
    }

    func channelRead(context _: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        guard let bytes = buffer.readBytes(length: buffer.readableBytes),
              !bytes.isEmpty else { return }
        queue.yield(Data(bytes))
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case TLSUserEvent.handshakeCompleted = event {
            completeTLS(.success(()))
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        lock.lock()
        let continueTLSReads = tlsHandshakePending
        lock.unlock()
        if continueTLSReads {
            context.read()
        }
        context.fireChannelReadComplete()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        // Keep the structural form alongside the localized text. Network
        // framework reports `posix(ETIMEDOUT)` here when TCP keepalive gives
        // up on a silent peer, and that distinction (versus a peer-sent reset
        // or a protocol-level teardown) is the whole diagnosis for an
        // unexplained mid-session drop.
        let protocolError = VNCProtocolError.ioError(Self.describe(error))
        completeTLS(.failure(protocolError))
        finish(throwing: protocolError)
        disconnect(protocolError)
        context.close(promise: nil)
    }

    private static func describe(_ error: Error) -> String {
        let structural = String(describing: error)
        let localized = error.localizedDescription
        return structural == localized ? structural : "\(structural) (\(localized))"
    }

    func channelInactive(context: ChannelHandlerContext) {
        let error = VNCProtocolError.connectionClosed
        completeTLS(.failure(error))
        finish(throwing: error)
        disconnect(error)
        context.fireChannelInactive()
    }

    func waitForTLSHandshake() async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let tlsResult {
                lock.unlock()
                continuation.resume(with: tlsResult)
            } else {
                tlsContinuation = continuation
                lock.unlock()
            }
        }
    }

    func beginTLSHandshake() {
        lock.lock()
        tlsHandshakePending = true
        lock.unlock()
    }

    private func completeTLS(_ result: Result<Void, Error>) {
        lock.lock()
        guard tlsResult == nil else {
            lock.unlock()
            return
        }
        tlsResult = result
        tlsHandshakePending = false
        let continuation = tlsContinuation
        tlsContinuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    func finish(throwing error: Error? = nil) {
        lock.lock()
        guard !didFinish else {
            lock.unlock()
            return
        }
        didFinish = true
        lock.unlock()
        queue.finish(throwing: error ?? VNCProtocolError.connectionClosed)
    }
}

private final class InboundByteQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var buffered: [Data] = []
    private var waiter: CheckedContinuation<Data, Error>?
    private var terminalError: Error?

    func yield(_ data: Data) {
        lock.lock()
        guard terminalError == nil else {
            lock.unlock()
            return
        }
        if let waiter {
            self.waiter = nil
            lock.unlock()
            waiter.resume(returning: data)
        } else {
            buffered.append(data)
            lock.unlock()
        }
    }

    func next(onReadNeeded: @escaping @Sendable () -> Void) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if !buffered.isEmpty {
                let data = buffered.removeFirst()
                lock.unlock()
                continuation.resume(returning: data)
            } else if let terminalError {
                lock.unlock()
                continuation.resume(throwing: terminalError)
            } else {
                precondition(waiter == nil, "RFB byte stream supports one reader")
                waiter = continuation
                lock.unlock()
                onReadNeeded()
            }
        }
    }

    func finish(throwing error: Error) {
        lock.lock()
        guard terminalError == nil else {
            lock.unlock()
            return
        }
        terminalError = error
        let waiter = waiter
        self.waiter = nil
        lock.unlock()
        waiter?.resume(throwing: error)
    }
}

private final class SendableSSLHandler: @unchecked Sendable {
    let value: NIOSSLClientHandler

    init(_ value: NIOSSLClientHandler) {
        self.value = value
    }
}
