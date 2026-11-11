import XCTest
@testable import RFBProtocol
@testable import RFBTransport

/// kitknox/rootshell#738: Network.framework's SOCKS client withheld the RFB
/// greeting when it shared a read with the CONNECT reply. The fixture sends its
/// whole script on accept, so every reply here arrives glued to what follows.
final class SOCKS5ProxyTests: XCTestCase {

    private let greeting = Data("RFB 003.889\n".utf8)

    func testGreetingThatSharesAReadWithTheConnectReplyIsDelivered() async throws {
        // Method selection, then the exact 22 bytes recorded in the report.
        let proxy = try LoopbackRFBFixture(
            serverBytes: bytes("0500") + bytes("050000017f0000013039524642203030332e3838390a"))
        defer { proxy.close() }
        let connection = makeConnection(
            host: "vnc-target.example.invalid", port: 5900, proxyPort: proxy.port)

        try await withTimeout(seconds: 10) { try await connection.connect() }
        let read = try await withTimeout(seconds: 5) { try await connection.read(exactly: 12) }
        XCTAssertEqual(read, greeting)

        let name = Array("vnc-target.example.invalid".utf8)
        let expected = bytes("050100") + Data([0x05, 0x01, 0x00, 0x03, UInt8(name.count)] + name + [0x17, 0x0C])
        let sent = await proxy.waitForClientBytes(atLeast: expected.count)
        XCTAssertEqual(sent, expected)

        let peer = await connection.remoteEndpointHost()
        let path = await connection.pathCharacteristics()
        XCTAssertNil(peer)
        XCTAssertNil(path)
        await connection.close()
    }

    func testDomainBoundAddressIsConsumedBeforeTheGreeting() async throws {
        let bound = Array("localhost".utf8)
        let reply = Data([0x05, 0x00, 0x00, 0x03, UInt8(bound.count)] + bound + [0x04, 0x38])
        let proxy = try LoopbackRFBFixture(serverBytes: bytes("0500") + reply + greeting)
        defer { proxy.close() }
        let connection = makeConnection(host: "vnc.example.invalid", port: 5900, proxyPort: proxy.port)

        try await withTimeout(seconds: 10) { try await connection.connect() }
        let read = try await withTimeout(seconds: 5) { try await connection.read(exactly: 12) }
        XCTAssertEqual(read, greeting)
        await connection.close()
    }

    func testRefusedConnectReportsTheProxyReason() async throws {
        let proxy = try LoopbackRFBFixture(serverBytes: bytes("0500") + bytes("05050001000000000000"))
        defer { proxy.close() }
        let connection = makeConnection(host: "vnc.example.invalid", port: 5900, proxyPort: proxy.port)

        do {
            try await withTimeout(seconds: 10) { try await connection.connect() }
            XCTFail("connect() should fail when the proxy refuses")
        } catch VNCProtocolError.ioError(let detail) {
            XCTAssertTrue(detail.contains("connection refused"), detail)
        }
        let connected = await connection.isConnected
        XCTAssertFalse(connected)
    }

    func testProxyRequiringAuthenticationFallsBackToTheSystemDial() async throws {
        let proxy = try LoopbackRFBFixture(serverBytes: bytes("05ff"))
        defer { proxy.close() }
        let server = try LoopbackRFBFixture(serverBytes: greeting)
        defer { server.close() }
        let connection = makeConnection(host: "127.0.0.1", port: server.port, proxyPort: proxy.port)

        try await withTimeout(seconds: 10) { try await connection.connect() }
        let read = try await withTimeout(seconds: 5) { try await connection.read(exactly: 12) }
        XCTAssertEqual(read, greeting)
        let peer = await connection.remoteEndpointHost()
        XCTAssertEqual(peer, "127.0.0.1")
        await connection.close()
    }

    func testSilentProxyTimesOutWithoutReportingADisconnect() async throws {
        let proxy = try LoopbackRFBFixture(serverBytes: Data())
        defer { proxy.close() }
        let connection = makeConnection(
            host: "vnc.example.invalid", port: 5900, proxyPort: proxy.port, timeoutSeconds: 1)
        let disconnects = Counter()
        await connection.setDisconnectHandler { _ in disconnects.increment() }

        do {
            try await withTimeout(seconds: 10) { try await connection.connect() }
            XCTFail("connect() should time out against a silent proxy")
        } catch VNCProtocolError.ioError(let detail) {
            XCTAssertTrue(detail.contains("no answer within 1s"), detail)
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(disconnects.value, 0)
    }

    // MARK: - Encoding

    func testConnectRequestEncodesIPLiteralsAsAddresses() throws {
        XCTAssertEqual(
            try SOCKS5Handshake.connectRequest(host: "192.0.2.7", port: 5900),
            bytes("05010001c000020717" + "0c"))
        XCTAssertEqual(
            try SOCKS5Handshake.connectRequest(host: "[2001:db8::1]", port: 5900),
            bytes("050100042001" + "0db8" + String(repeating: "0", count: 22) + "01170c"))
    }

    func testOversizedHostnameIsRejected() {
        XCTAssertThrowsError(
            try SOCKS5Handshake.connectRequest(
                host: String(repeating: "a", count: 256), port: 5900))
    }

    func testReplyHeaderParsing() throws {
        XCTAssertEqual(try SOCKS5Handshake.boundAddress(afterReplyHeader: bytes("05000001")), .fixed(6))
        XCTAssertEqual(try SOCKS5Handshake.boundAddress(afterReplyHeader: bytes("05000004")), .fixed(18))
        XCTAssertEqual(try SOCKS5Handshake.boundAddress(afterReplyHeader: bytes("05000003")), .domain)
        XCTAssertThrowsError(try SOCKS5Handshake.boundAddress(afterReplyHeader: bytes("05040001"))) {
            XCTAssertEqual($0 as? SOCKS5Handshake.Failure, .rejected(4))
            XCTAssertEqual((($0 as? SOCKS5Handshake.Failure)?.reason), "connect failed: host unreachable")
        }
        XCTAssertThrowsError(try SOCKS5Handshake.checkMethodSelection(bytes("05ff"))) {
            XCTAssertEqual($0 as? SOCKS5Handshake.Failure, .noAcceptableMethod)
        }
    }

    // MARK: - System settings

    private let socksSettings: [String: Any] = [
        "SOCKSEnable": 1, "SOCKSProxy": "127.0.0.1", "SOCKSPort": 7891,
        "HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": 7890,
        "ExceptionsList": ["*.local", "bypass.example.com"],
    ]

    func testSystemSOCKSProxyIsPickedForARoutedHost() {
        XCTAssertEqual(
            SystemSOCKSProxy.endpoint(
                forHost: "vnc.example.com", port: 5900, settings: socksSettings as CFDictionary),
            SOCKS5ProxyEndpoint(host: "127.0.0.1", port: 7891))
    }

    func testBypassedHostsAndPACStayWithTheSystem() {
        for host in ["bypass.example.com", "mymac.local"] {
            XCTAssertNil(
                SystemSOCKSProxy.endpoint(
                    forHost: host, port: 5900, settings: socksSettings as CFDictionary),
                host)
        }
        var pac = socksSettings
        pac["ProxyAutoConfigEnable"] = 1
        pac["ProxyAutoConfigURLString"] = "http://127.0.0.1:9/proxy.pac"
        XCTAssertNil(
            SystemSOCKSProxy.endpoint(forHost: "vnc.example.com", port: 5900, settings: pac as CFDictionary))
        XCTAssertNil(
            SystemSOCKSProxy.endpoint(
                forHost: "vnc.example.com", port: 5900, settings: ["SOCKSEnable": 0] as CFDictionary))
    }

    func testScopedIPv6DestinationBuildsAURL() {
        XCTAssertEqual(
            SystemSOCKSProxy.destinationURL(host: "fe80::1%en0", port: 5900)?.absoluteString,
            "socks://[fe80::1%25en0]:5900")
    }

    // MARK: - Helpers

    private func makeConnection(
        host: String,
        port: UInt16,
        proxyPort: UInt16,
        timeoutSeconds: Int = 5
    ) -> TCPConnection {
        TCPConnection(
            host: host, port: port,
            maxDialAttempts: 1,
            dialRetryBackoffNanos: 50_000_000,
            connectTimeoutSeconds: timeoutSeconds,
            socksProxyResolver: { _, _ in SOCKS5ProxyEndpoint(host: "127.0.0.1", port: proxyPort) })
    }

    private func bytes(_ hex: String) -> Data {
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            data.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return data
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    func increment() { lock.withLock { count += 1 } }
}
