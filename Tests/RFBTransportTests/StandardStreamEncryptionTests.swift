import CommonCrypto
import Foundation
import os
import RFBProtocol
import XCTest
@testable import RFBTransport

/// Standard-mode whole-stream encryption against a scripted Mac, and the
/// servers that must keep today's plain stream.
final class StandardStreamEncryptionTests: XCTestCase {

    fileprivate static let setEncryption = MessageWriter.writeAppleSetEncryption(level: 1)
    fileprivate static let decryptReceived = MessageWriter.writeAppleDecryptReceived()

    func testSetEncryptionWireBytes() {
        XCTAssertEqual(Self.setEncryption, Data([
            0x12, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        ]))
        XCTAssertEqual(Self.decryptReceived, Data([0x12, 0x00, 0x00, 0x02, 0x00, 0x01, 0x00, 0x00]))
    }

    func testMacSwitchesBothDirectionsAfterKeyUpdate() async throws {
        let mac = try await EncryptedMac.connect()
        let encryption = await mac.session.handshakeInfo.contentEncryption
        XCTAssertEqual(encryption, .appleComCryption(cipherMode: nil, keyLength: 128, mediaSRTP: false))

        // SetEncryption leads the first update request, so no pixels can
        // leave the Mac before the key update.
        try await mac.session.requestFramebufferUpdate(incremental: true)
        let sent = await mac.connection.sentBytes()
        let setEncryption = try XCTUnwrap(sent.range(of: Self.setEncryption))
        let firstRequest = try XCTUnwrap(sent.range(of: ClientMessage.framebufferUpdateRequest(
            incremental: false, x: 0, y: 0, width: 1920, height: 1080).serialize()))
        XCTAssertLessThan(setEncryption.lowerBound, firstRequest.lowerBound)

        // Plaintext up to and including command 2; ComCryption after it.
        let plaintext = try mac.clientPlaintextAfterSwitch(sent)
        XCTAssertEqual(plaintext.first, 3, "first encrypted message is an update request")
        await mac.session.disconnect()
    }

    /// Encryption order must be wire order: a second write waits in the
    /// session, unencrypted, while the first is held in the transport.
    func testEncryptedWritesStayInEncryptionOrder() async throws {
        let mac = try await EncryptedMac.connect()
        let session = mac.session
        await mac.connection.holdSends()
        let pointer = Task { try await session.sendPointerEvent(buttonMask: 0, x: 10, y: 20) }
        let request = Task { try await session.requestFramebufferUpdate(incremental: true) }
        for _ in 0..<200 where await mac.connection.heldSendCount == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        try await Task.sleep(for: .milliseconds(50))
        let held = await mac.connection.heldSendCount
        XCTAssertEqual(held, 1, "only one write may be in the transport at a time")
        await mac.connection.releaseSends()
        try await pointer.value
        try await request.value

        let plaintext = try mac.clientPlaintextAfterSwitch(await mac.connection.sentBytes())
        XCTAssertFalse(plaintext.isEmpty)
        await session.disconnect()
    }

    /// Neither connect() nor ServerInit completes until the key update has
    /// switched the stream, so a caller's first write is already encrypted.
    func testConnectWaitsForTheKeyUpdate() async throws {
        let mac = try await EncryptedMac.start(answersAtOnce: false)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(mac.didConnect.withLock { $0 }, "connect() returned before the key")
        XCTAssertFalse(mac.events.withLock { $0 }.contains { $0.hasPrefix("serverInit") || $0 == "operational" })

        await mac.answer()
        try await mac.connected()
        try await mac.session.sendClipboardText("secret-clip")
        let sent = await mac.connection.sentBytes()
        XCTAssertNil(sent.range(of: Data("secret-clip".utf8)), "clipboard left in plaintext")
        XCTAssertNotNil(try mac.clientPlaintextAfterSwitch(sent).range(of: Data("secret-clip".utf8)))
        try await mac.waitFor(["operational", "serverInit encrypted", "encrypted", "update raw"])
        await mac.session.disconnect()
    }

    /// Events from the update that carries the key reach the app after it
    /// is connected, never before ServerInit.
    func testFirstUpdateEventsFollowServerInit() async throws {
        let mac = try await EncryptedMac.start(reply: .keyWithDisplayInfo)
        try await mac.waitFor(["serverInit encrypted", "displayInfo", "encrypted", "update raw"])
        let log = mac.events.withLock { $0 }
        let serverInit = try XCTUnwrap(log.firstIndex(of: "serverInit encrypted"))
        let displayInfo = try XCTUnwrap(log.firstIndex(of: "displayInfo"))
        XCTAssertLessThan(serverInit, displayInfo)
        await mac.session.disconnect()
    }

    /// A key rect followed by slow pixels in the same update: nothing is
    /// published until the whole update is read and the switch is in place.
    func testKeyThenSlowPixelsPublishesAfterTheSwitch() async throws {
        let mac = try await EncryptedMac.start(reply: .keyWithPixels, answersAtOnce: false)
        // Update header, key rect, raw rect header and 2 of its 8 pixel bytes.
        let partial = 4 + (12 + 36) + 12 + 2
        await mac.connection.enqueueServerBytes(mac.reply.prefix(partial))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(mac.events.withLock { $0 }.contains { $0.hasPrefix("serverInit") })
        XCTAssertFalse(mac.didConnect.withLock { $0 })

        await mac.connection.enqueueServerBytes(mac.reply.dropFirst(partial))
        try await mac.connected()
        try await mac.waitFor(["serverInit encrypted", "update 1103 raw", "encrypted", "update raw"])
        await mac.session.disconnect()
    }

    /// A key after another rect still settles the update: nothing connects
    /// until the whole update is read and the switch is in place.
    func testPixelsThenSlowKeyPublishesAfterTheSwitch() async throws {
        let mac = try await EncryptedMac.start(reply: .pixelsThenKey, answersAtOnce: false)
        // Update header, raw rect, and the key rect header plus 4 bytes.
        let partial = 4 + (12 + 8) + 12 + 4
        await mac.connection.enqueueServerBytes(mac.reply.prefix(partial))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(mac.events.withLock { $0 }.contains { $0.hasPrefix("serverInit") })
        XCTAssertFalse(mac.didConnect.withLock { $0 })

        await mac.connection.enqueueServerBytes(mac.reply.dropFirst(partial))
        try await mac.connected()
        try await mac.waitFor(["serverInit encrypted", "update raw 1103", "encrypted", "update raw"])
        await mac.session.disconnect()
    }

    /// A peer that closes before the key update fails connect(): success is
    /// only a settled connection.
    func testConnectFailsWhenThePeerClosesBeforeTheKey() async throws {
        let mac = try await EncryptedMac.start(answersAtOnce: false)
        await mac.connection.finishServerStream()
        do {
            try await mac.connecting.value
            XCTFail("connect() succeeded without a settled negotiation")
        } catch {}
    }

    /// Cancelling a connect() that waits for the key ends the half-open
    /// session and throws CancellationError.
    func testCancellingConnectEndsTheNegotiation() async throws {
        let mac = try await EncryptedMac.start(answersAtOnce: false)
        try await Task.sleep(for: .milliseconds(20))
        mac.connecting.cancel()
        do {
            try await mac.connecting.value
            XCTFail("a cancelled connect() succeeded")
        } catch is CancellationError {
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
        // Disconnected: a write now fails instead of reaching the wire.
        do {
            try await mac.session.sendPointerEvent(buttonMask: 0, x: 1, y: 1)
            XCTFail("the session still writes after a cancelled connect()")
        } catch {}
    }

    /// A Mac whose first update carries no key declined SetEncryption: the app
    /// connects at once, unencrypted, and nothing is held back.
    func testMacThatDeclinesConnectsUnencrypted() async throws {
        let mac = try await EncryptedMac.start(reply: .plaintextPixels)
        try await mac.waitFor(["serverInit plain", "update raw"])
        try await mac.session.sendClipboardText("plain-clip")
        let sent = await mac.connection.sentBytes()
        XCTAssertNotNil(sent.range(of: Data("plain-clip".utf8)))
        XCTAssertNil(sent.range(of: Self.decryptReceived))
        let encryption = await mac.session.handshakeInfo.contentEncryption
        XCTAssertEqual(encryption, VNCContentEncryption.none)
        await mac.session.disconnect()
    }

    /// Pixels in the update that carries the key were read in plaintext, so
    /// they come before the switch is announced.
    func testPixelsBesideTheKeyArriveBeforeTheSwitch() async throws {
        let mac = try await EncryptedMac.start(reply: .keyWithPixels)
        try await mac.waitFor(["serverInit encrypted", "update 1103 raw", "encrypted", "update raw"])
        let log = mac.events.withLock { $0 }
        XCTAssertEqual(
            Array(log.filter { $0 != "operational" }.prefix(4)),
            ["serverInit encrypted", "update 1103 raw", "encrypted", "update raw"])
        await mac.session.disconnect()
    }

    /// A lost encrypted record breaks the CBC chain for good: the failed write
    /// ends the session itself, and later writes fail instead of desyncing.
    func testFailedEncryptedWriteEndsTheSession() async throws {
        let mac = try await EncryptedMac.connect()
        await mac.connection.failNextSend()
        do {
            try await mac.session.requestFramebufferUpdate(incremental: true)
            XCTFail("the scripted failure was not reported")
        } catch {}
        let afterFailure = await mac.connection.sentBytes()
        do {
            try await mac.session.sendPointerEvent(buttonMask: 0, x: 1, y: 1)
            XCTFail("a write after the failure went through")
        } catch {}
        let sent = await mac.connection.sentBytes()
        XCTAssertEqual(sent, afterFailure, "nothing reaches the wire after a failed record")
        try await mac.waitFor(["disconnected"])
    }

    func testNonAppleServerKeepsPlainStream() async throws {
        var script = ProtocolVersion.v3_8.wireBytes()
        script.append(contentsOf: [1, SecurityType.none.rawValue, 0, 0, 0, 0])
        script.append(Self.serverInit(nameField: Data("Linux".utf8)))
        try await assertPlainStream(script)
    }

    func testAppleServerWithoutKeyExchangeKeepsPlainStream() async throws {
        try await assertPlainStream(Self.appleHandshake(dhAuth: false, serverCommands: [0x12]))
    }

    func testAppleServerWithoutSetEncryptionKeepsPlainStream() async throws {
        try await assertPlainStream(Self.appleHandshake(dhAuth: true, serverCommands: []))
    }

    // MARK: - Helpers

    private func assertPlainStream(_ script: Data) async throws {
        let connection = ScriptedRFBConnection()
        await connection.enqueueServerBytes(script)
        let session = TransportSession(
            host: "server.test", port: 5900, password: "p", username: "u",
            preferredEncodings: [.raw], connection: connection)
        try await session.connect()
        try await session.requestFramebufferUpdate(incremental: true)

        let sent = await connection.sentBytes()
        XCTAssertNil(sent.range(of: Self.setEncryption))
        XCTAssertNil(sent.range(of: Self.decryptReceived))
        let encryption = await session.handshakeInfo.contentEncryption
        XCTAssertEqual(encryption, VNCContentEncryption.none)
        await session.disconnect()
    }

    /// Type 30 with a server public key of 1 makes the shared secret 1, so
    /// the session key is MD5(0x01) whatever the client's private key.
    fileprivate static func appleHandshake(dhAuth: Bool, serverCommands: [UInt8]) -> Data {
        var script = ProtocolVersion.apple.wireBytes()
        if dhAuth {
            script.append(contentsOf: [1, SecurityType.apple30.rawValue])
            script.append(contentsOf: [0x00, 0x02, 0x00, 0x10])
            script.append(Data(repeating: 0xFF, count: 16))
            script.append(Data(repeating: 0, count: 15) + Data([1]))
        } else {
            script.append(contentsOf: [1, SecurityType.none.rawValue])
        }
        script.append(contentsOf: [0, 0, 0, 0])

        var field = Data([0x00, 0x00, 0x00, 0x00, 0x00, 0x52])
        var bitmap = Data(repeating: 0, count: 16)
        for command in serverCommands {
            bitmap[Int(command) / 8] |= 0x80 >> (command % 8)
        }
        field.append(bitmap)
        field.append(Data("Mac".utf8))
        script.append(serverInit(nameField: field))
        return script
    }

    fileprivate static var sessionKey: Data {
        var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
        _ = CC_MD5([UInt8(1)], 1, &digest)
        return Data(digest)
    }

    /// 0x44f payload: mode 1, then the stream key and IV in AES-ECB under
    /// the session key.
    fileprivate static func keyUpdate(key: Data, iv: Data) -> Data {
        var payload = Data([0, 0, 0, 1])
        payload.append(ecbEncrypt(key + iv, key: sessionKey))
        return payload
    }

    fileprivate static func ecbEncrypt(_ data: Data, key: Data) -> Data {
        var output = Data(count: data.count)
        var moved = 0
        let status = output.withUnsafeMutableBytes { out in
            data.withUnsafeBytes { input in
                key.withUnsafeBytes { keyBytes in
                    CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionECBMode), keyBytes.baseAddress, key.count, nil,
                            input.baseAddress, data.count, out.baseAddress, data.count, &moved)
                }
            }
        }
        precondition(status == kCCSuccess && moved == data.count)
        return output
    }

    fileprivate static func framebufferUpdate(
        encoding: Int32, width: UInt16 = 0, height: UInt16 = 0, payload: Data
    ) -> Data {
        var data = Data([0, 0, 0, 1, 0, 0, 0, 0])
        data.append(contentsOf: [UInt8(width >> 8), UInt8(width & 0xFF),
                                 UInt8(height >> 8), UInt8(height & 0xFF)])
        let raw = UInt32(bitPattern: encoding)
        data.append(contentsOf: [UInt8(raw >> 24), UInt8((raw >> 16) & 0xFF),
                                 UInt8((raw >> 8) & 0xFF), UInt8(raw & 0xFF)])
        data.append(payload)
        return data
    }

    fileprivate static func serverInit(nameField: Data) -> Data {
        var data = Data([0x07, 0x80, 0x04, 0x38]) // 1920x1080
        data.append(PixelFormat.bgra8888.wireBytes())
        AppleClipboardProtocol.appendUInt32BE(UInt32(nameField.count), to: &data)
        data.append(nameField)
        return data
    }
}

/// A scripted Mac. It answers the SetEncryption burst (only when the burst
/// advertises 1103, for the key replies) at once or on `answer()`.
private struct EncryptedMac {
    enum Reply {
        /// Key update, then one raw update split across two encrypted records.
        case keyUpdate
        /// Key update and a raw rect in one plaintext update, then an
        /// encrypted raw update.
        case keyWithPixels
        /// The key and a ServerDisplayInfo rect in one update, then an
        /// encrypted raw update.
        case keyWithDisplayInfo
        /// A raw rect, then the key, in one plaintext update, then an
        /// encrypted raw update.
        case pixelsThenKey
        /// A Mac that is not encrypting: one plaintext raw update.
        case plaintextPixels
    }

    static let streamKey = Data((0..<16).map { UInt8($0 &* 7 &+ 1) })
    static let streamIV = Data((0..<16).map { UInt8($0 &* 11 &+ 3) })
    static let pixels = Data([1, 2, 3, 4, 5, 6, 7, 8])

    let session: TransportSession
    let connection: ScriptedRFBConnection
    /// "serverInit encrypted|plain", "update <encodings>", "encrypted" and
    /// "disconnected", in arrival order.
    let events: OSAllocatedUnfairLock<[String]>
    /// The bytes `answer()` sends.
    let reply: Data
    let connecting: Task<Void, Error>
    /// Set when connect() returns.
    let didConnect: OSAllocatedUnfairLock<Bool>

    /// Connected, switched, and the first encrypted update decoded.
    static func connect() async throws -> EncryptedMac {
        let mac = try await start()
        try await mac.waitFor(["encrypted", "update raw"])
        return mac
    }

    static func start(reply kind: Reply = .keyUpdate, answersAtOnce: Bool = true) async throws -> EncryptedMac {
        typealias Tests = StandardStreamEncryptionTests
        let keyRect = rect(encoding: 1103, payload: Tests.keyUpdate(key: streamKey, iv: streamIV))
        let pixelRect = rect(encoding: 0, width: 2, height: 1, payload: pixels)
        let encryptedUpdate = try encrypted(update(pixelRect))
        let reply: Data
        switch kind {
        case .keyUpdate: reply = update(keyRect) + encryptedUpdate
        case .keyWithPixels: reply = update(keyRect, pixelRect) + encryptedUpdate
        case .pixelsThenKey: reply = update(pixelRect, keyRect) + encryptedUpdate
        case .keyWithDisplayInfo:
            var display = Data(count: 24) // index 0 at 0,0, 1920x1080
            display[14] = 0x07; display[15] = 0x80; display[18] = 0x04; display[19] = 0x38
            reply = update(keyRect, rect(encoding: -300, payload: display)) + encryptedUpdate
        case .plaintextPixels: reply = update(pixelRect)
        }

        let connection = ScriptedRFBConnection()
        await connection.enqueueServerBytes(Tests.appleHandshake(dhAuth: true, serverCommands: [0x12]))
        let needsAdvertisement = kind != .plaintextPixels
        let answered = OSAllocatedUnfairLock(initialState: false)
        await connection.setOnSend { data in
            guard answersAtOnce,
                  data.range(of: Tests.setEncryption) != nil,
                  !needsAdvertisement || advertisedEncodings(inBurst: data).contains(1103),
                  answered.withLock({ done in defer { done = true }; return !done }) else {
                return nil
            }
            return reply
        }

        let session = TransportSession(
            host: "mac.test", port: 5900, password: "p", username: "u",
            preferredEncodings: [.raw], connection: connection)
        let events = OSAllocatedUnfairLock(initialState: [String]())
        Task {
            for await event in session.events {
                switch event {
                case .serverInit:
                    let encrypted = await session.handshakeInfo.contentEncryption != .none
                    events.withLock { $0.append(encrypted ? "serverInit encrypted" : "serverInit plain") }
                case .standardStreamEncrypted:
                    events.withLock { $0.append("encrypted") }
                case .disconnected:
                    events.withLock { $0.append("disconnected") }
                case .stateChanged(let state) where state == .operational:
                    events.withLock { $0.append("operational") }
                case .displayInfo:
                    events.withLock { $0.append("displayInfo") }
                case .framebufferUpdate(let rects):
                    let names = rects.map { $0.0.encoding == .raw ? "raw" : "\($0.0.encoding.rawValue)" }
                    events.withLock { $0.append("update " + names.joined(separator: " ")) }
                    // The credit releases the next update request.
                    try? await session.finishFramebufferUpdate()
                default:
                    continue
                }
            }
        }
        // connect() returns once encryption is settled, so a held reply
        // keeps it waiting.
        let didConnect = OSAllocatedUnfairLock(initialState: false)
        let connecting = Task {
            try await session.connect()
            didConnect.withLock { $0 = true }
        }
        let mac = EncryptedMac(
            session: session, connection: connection, events: events,
            reply: reply, connecting: connecting, didConnect: didConnect)
        if answersAtOnce { try await mac.connected() }
        return mac
    }

    func answer() async {
        await connection.enqueueServerBytes(reply)
    }

    /// Waits up to 2 s for connect() to return.
    func connected() async throws {
        for _ in 0..<400 where !didConnect.withLock({ $0 }) {
            try await Task.sleep(for: .milliseconds(5))
        }
        if !didConnect.withLock({ $0 }) {
            // Bounded: a missing key reply fails the test instead of hanging.
            await connection.close()
            XCTFail("connect() never returned; events \(events.withLock { $0 })")
        }
        try await connecting.value
    }

    /// Waits up to 2 s for `expected` to appear, in order, in the event log.
    func waitFor(_ expected: [String]) async throws {
        for _ in 0..<400 {
            let log = events.withLock { $0 }
            var remaining = expected[...]
            for entry in log where entry == remaining.first { remaining = remaining.dropFirst() }
            if remaining.isEmpty { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("events \(events.withLock { $0 }) never showed \(expected)")
    }

    /// Everything the client sent after command 2, decrypted as the Mac would.
    func clientPlaintextAfterSwitch(_ sent: Data) throws -> Data {
        let switchPoint = try XCTUnwrap(sent.range(of: StandardStreamEncryptionTests.decryptReceived))
        let encrypted = Data(sent[switchPoint.upperBound...])
        let macReceives = try AppleComCryptionChannel(key: Self.streamKey, iv: Self.streamIV)
        var offset = 0
        var packetID: UInt32 = 0
        var plaintext = Data()
        _ = try macReceives.decryptFramedRecords(
            in: encrypted, offset: &offset, expectedPacketID: &packetID, appendingTo: &plaintext)
        XCTAssertEqual(offset, encrypted.count, "everything after command 2 is whole records")
        return plaintext
    }

    private static func rect(encoding: Int32, width: UInt16 = 0, height: UInt16 = 0, payload: Data) -> Data {
        // framebufferUpdate builds a one-rect update; drop its 4-byte header.
        StandardStreamEncryptionTests.framebufferUpdate(
            encoding: encoding, width: width, height: height, payload: payload).dropFirst(4)
    }

    private static func update(_ rects: Data...) -> Data {
        var data = Data([0, 0, 0, UInt8(rects.count)])
        rects.forEach { data.append($0) }
        return data
    }

    /// The update split across two records, packet IDs 0 and 1.
    private static func encrypted(_ update: Data) throws -> Data {
        let macSends = try AppleComCryptionChannel(key: streamKey, iv: streamIV)
        var records = Data()
        let next = try macSends.appendFramedRecords(of: update.prefix(9), firstPacketID: 0, to: &records)
        _ = try macSends.appendFramedRecords(of: update.dropFirst(9), firstPacketID: next, to: &records)
        return records
    }

    /// The burst opens with SetPixelFormat (20 bytes), then SetEncodings.
    private static func advertisedEncodings(inBurst data: Data) -> [Int32] {
        let bytes = [UInt8](data)
        let start = bytes.first == 0 ? 20 : 0
        guard bytes.count >= start + 4, bytes[start] == 2 else { return [] }
        let count = Int(bytes[start + 2]) << 8 | Int(bytes[start + 3])
        guard bytes.count >= start + 4 + count * 4 else { return [] }
        return (0..<count).map { index in
            let at = start + 4 + index * 4
            return Int32(bitPattern: UInt32(bytes[at]) << 24 | UInt32(bytes[at + 1]) << 16
                | UInt32(bytes[at + 2]) << 8 | UInt32(bytes[at + 3]))
        }
    }
}
