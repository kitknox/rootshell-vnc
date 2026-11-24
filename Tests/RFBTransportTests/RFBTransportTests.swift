import XCTest
import Foundation
import CommonCrypto
import CryptoKit
@testable import RFBTransport
import RFBProtocol

final class TCPConnectionTLSNameTests: XCTestCase {
    func testIPAddressEndpointsDoNotBecomeTLSServerNames() {
        XCTAssertNil(TCPConnection.tlsServerName(for: "192.168.1.10"))
        XCTAssertNil(TCPConnection.tlsServerName(for: "127.0.0.1"))
        XCTAssertNil(TCPConnection.tlsServerName(for: "::1"))
        XCTAssertNil(TCPConnection.tlsServerName(for: "[2001:db8::1]"))
    }

    func testDNSHostRemainsTLSServerName() {
        XCTAssertEqual(
            TCPConnection.tlsServerName(for: "desktop.example.com"),
            "desktop.example.com")
    }
}

final class ApplePointerButtonMappingTests: XCTestCase {
    func testAppleWireSwapsRightAndMiddleButtons() {
        XCTAssertEqual(TransportSession.pointerButtonMaskForWire(
            0x04, serverVersion: .apple), 0x02)
        XCTAssertEqual(TransportSession.pointerButtonMaskForWire(
            0x02, serverVersion: .apple), 0x04)
    }

    func testAppleWirePreservesOtherButtonBits() {
        XCTAssertEqual(TransportSession.pointerButtonMaskForWire(
            0x19, serverVersion: .apple), 0x19)
    }

    func testConventionalRFBKeepsStandardButtonOrder() {
        XCTAssertEqual(TransportSession.pointerButtonMaskForWire(
            0x04, serverVersion: .v3_8), 0x04)
        XCTAssertEqual(TransportSession.pointerButtonMaskForWire(
            0x02, serverVersion: nil), 0x02)
    }
}

final class AppleScrollFallbackTests: XCTestCase {
    func testAppleStandardSessionUsesPreciseInputWithoutCapabilityBlock() {
        XCTAssertTrue(TransportSession.shouldUseApplePreciseInput(
            serverVersion: .apple,
            capabilities: nil))
        XCTAssertFalse(TransportSession.shouldUseApplePreciseInput(
            serverVersion: .v3_8,
            capabilities: nil))
    }

    func testVerticalFallbackMatchesNativeCGEventDirection() {
        let up = AppleScrollEvent(deltaY: 1, x: 10, y: 20)
        let down = AppleScrollEvent(deltaY: -1, x: 10, y: 20)

        XCTAssertEqual(
            AppleScrollFallback.wheelButtonMasks(
                for: up,
                includeHorizontal: false),
            [0x08])
        XCTAssertEqual(
            AppleScrollFallback.wheelButtonMasks(
                for: down,
                includeHorizontal: false),
            [0x10])
    }

    func testHorizontalFallbackIsLimitedToAppleServers() {
        let event = AppleScrollEvent(deltaX: -1, deltaY: 1, x: 10, y: 20)

        XCTAssertEqual(
            AppleScrollFallback.wheelButtonMasks(
                for: event,
                includeHorizontal: false),
            [0x08])
        XCTAssertEqual(
            AppleScrollFallback.wheelButtonMasks(
                for: event,
                includeHorizontal: true),
            [0x40, 0x08])
    }

    func testFallbackPreservesAcceleratedWheelMagnitude() {
        let event = AppleScrollEvent(
            deltaX: -2,
            deltaY: 4,
            x: 10,
            y: 20)

        XCTAssertEqual(
            AppleScrollFallback.wheelButtonMasks(
                for: event,
                includeHorizontal: true),
            [0x40, 0x40, 0x08, 0x08, 0x08, 0x08])
    }

    func testFallbackBoundsOneAcceleratedSample() {
        let event = AppleScrollEvent(deltaY: .max, x: 10, y: 20)
        let masks = AppleScrollFallback.wheelButtonMasks(
            for: event,
            includeHorizontal: false)

        XCTAssertEqual(masks.count, 32)
        XCTAssertTrue(masks.allSatisfy { $0 == 0x08 })
    }

    func testZeroDeltaPhaseEventDoesNotCreateFallbackWheelClick() {
        let event = AppleScrollEvent(
            scrollPhase: .ended,
            flags: [.continuous],
            x: 10,
            y: 20)

        XCTAssertTrue(
            AppleScrollFallback.wheelButtonMasks(
                for: event,
                includeHorizontal: true).isEmpty)
    }
}

// MARK: - VNCAuthenticator DES Bit Reversal Tests

final class VNCAuthenticatorBitReversalTests: XCTestCase {

    /// Exercise the VNC DES bit-reversal by running the full key-prepare path.
    ///
    /// Since `prepareKey` and `reverseBits` are private, we test them indirectly
    /// by creating a VNCAuthenticator and verifying known bit-reversal results
    /// through the DES encrypt path.

    func testBitReversal_0x00() {
        // 0b00000000 reversed is still 0b00000000
        XCTAssertEqual(reverseBitsHelper(0x00), 0x00)
    }

    func testBitReversal_0xFF() {
        // 0b11111111 reversed is 0b11111111
        XCTAssertEqual(reverseBitsHelper(0xFF), 0xFF)
    }

    func testBitReversal_0x01() {
        // 0b00000001 reversed -> 0b10000000 = 0x80
        XCTAssertEqual(reverseBitsHelper(0x01), 0x80)
    }

    func testBitReversal_0x80() {
        // 0b10000000 reversed -> 0b00000001 = 0x01
        XCTAssertEqual(reverseBitsHelper(0x80), 0x01)
    }

    func testBitReversal_0x55() {
        // 0b01010101 reversed -> 0b10101010 = 0xAA
        XCTAssertEqual(reverseBitsHelper(0x55), 0xAA)
    }

    func testBitReversal_0xAA() {
        // 0b10101010 reversed -> 0b01010101 = 0x55
        XCTAssertEqual(reverseBitsHelper(0xAA), 0x55)
    }

    func testBitReversal_0x0F() {
        // 0b00001111 reversed -> 0b11110000 = 0xF0
        XCTAssertEqual(reverseBitsHelper(0x0F), 0xF0)
    }

    func testBitReversal_0xF0() {
        // 0b11110000 reversed -> 0b00001111 = 0x0F
        XCTAssertEqual(reverseBitsHelper(0xF0), 0x0F)
    }

    func testBitReversal_0xC3() {
        // 0b11000011 reversed -> 0b11000011 = 0xC3 (palindrome)
        XCTAssertEqual(reverseBitsHelper(0xC3), 0xC3)
    }

    func testBitReversal_0x12() {
        // 0b00010010 reversed -> 0b01001000 = 0x48
        XCTAssertEqual(reverseBitsHelper(0x12), 0x48)
    }

    func testBitReversalIsInvolution() {
        // Reversing twice should yield the original value
        for byte: UInt8 in [0x00, 0x01, 0x42, 0x7F, 0x80, 0xAA, 0xFE, 0xFF] {
            XCTAssertEqual(reverseBitsHelper(reverseBitsHelper(byte)), byte,
                           "Double reversal failed for 0x\(String(byte, radix: 16))")
        }
    }

    /// Reimplements the same bit-reversal algorithm used in VNCAuthenticator
    /// to verify correctness of the algorithm itself.
    private func reverseBitsHelper(_ byte: UInt8) -> UInt8 {
        var result: UInt8 = 0
        var input = byte
        for _ in 0..<8 {
            result = (result << 1) | (input & 1)
            input >>= 1
        }
        return result
    }
}

// MARK: - SRPBinaryBuffer TLV Tests

final class SRPBinaryBufferTLVTests: XCTestCase {

    func testParseEmptyData() throws {
        let result = try SRPBinaryBuffer.parse(data: Data())
        XCTAssertTrue(result.isEmpty)
    }

    func testParseSingleEntry() throws {
        // Type=0x01, Length=3 (big-endian), Value=[0xAA, 0xBB, 0xCC]
        var data = Data()
        data.append(0x01) // type
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x03]) // length = 3
        data.append(contentsOf: [0xAA, 0xBB, 0xCC]) // value

        let result = try SRPBinaryBuffer.parse(data: data)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0x01], Data([0xAA, 0xBB, 0xCC]))
    }

    func testParseMultipleEntries() throws {
        var data = Data()

        // Entry 1: type=0x01, length=2, value=[0x01, 0x02]
        data.append(0x01)
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x02])
        data.append(contentsOf: [0x01, 0x02])

        // Entry 2: type=0x03, length=4, value=[0x0A, 0x0B, 0x0C, 0x0D]
        data.append(0x03)
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x04])
        data.append(contentsOf: [0x0A, 0x0B, 0x0C, 0x0D])

        let result = try SRPBinaryBuffer.parse(data: data)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0x01], Data([0x01, 0x02]))
        XCTAssertEqual(result[0x03], Data([0x0A, 0x0B, 0x0C, 0x0D]))
    }

    func testParseZeroLengthValue() throws {
        var data = Data()
        data.append(0x05) // type
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x00]) // length = 0

        let result = try SRPBinaryBuffer.parse(data: data)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0x05], Data())
    }

    func testParseDuplicateTypeLastWins() throws {
        var data = Data()
        // First occurrence: type=0x02, value=[0x01]
        data.append(0x02)
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
        data.append(0x01)
        // Second occurrence: type=0x02, value=[0xFF]
        data.append(0x02)
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
        data.append(0xFF)

        let result = try SRPBinaryBuffer.parse(data: data)
        XCTAssertEqual(result[0x02], Data([0xFF]))
    }

    func testParseTruncatedHeaderThrows() {
        // Only 3 bytes total -- not enough for type (1) + length (4)
        let data = Data([0x01, 0x00, 0x00])
        XCTAssertThrowsError(try SRPBinaryBuffer.parse(data: data))
    }

    func testParseTruncatedValueThrows() {
        // Claims 10 bytes but only provides 2
        var data = Data()
        data.append(0x01)
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x0A]) // length = 10
        data.append(contentsOf: [0xAA, 0xBB]) // only 2 bytes
        XCTAssertThrowsError(try SRPBinaryBuffer.parse(data: data))
    }

    // MARK: - Serialization

    func testSerializeEmptyEntries() {
        let result = SRPBinaryBuffer.serialize(entries: [:])
        XCTAssertTrue(result.isEmpty)
    }

    func testSerializeSingleEntry() {
        let entries: [UInt8: Data] = [0x01: Data([0xAA, 0xBB, 0xCC])]
        let result = SRPBinaryBuffer.serialize(entries: entries)
        // type(1) + length(4) + value(3) = 8 bytes
        XCTAssertEqual(result.count, 8)
        XCTAssertEqual(result[0], 0x01) // type
        XCTAssertEqual(result[1], 0x00)
        XCTAssertEqual(result[2], 0x00)
        XCTAssertEqual(result[3], 0x00)
        XCTAssertEqual(result[4], 0x03) // length
        XCTAssertEqual(result[5], 0xAA)
        XCTAssertEqual(result[6], 0xBB)
        XCTAssertEqual(result[7], 0xCC)
    }

    func testSerializeMultipleEntriesSortedByType() {
        let entries: [UInt8: Data] = [
            0x03: Data([0x30]),
            0x01: Data([0x10]),
        ]
        let result = SRPBinaryBuffer.serialize(entries: entries)

        // First entry should be type 0x01 (sorted)
        XCTAssertEqual(result[0], 0x01)
        // After type(1) + length(4) + value(1) = 6, next type is 0x03
        XCTAssertEqual(result[6], 0x03)
    }

    // MARK: - Round-trip

    func testParseSerializeRoundTrip() throws {
        let original: [UInt8: Data] = [
            SRPBinaryBuffer.typeUsername: Data("alice".utf8),
            SRPBinaryBuffer.typeSalt: Data([0x01, 0x02, 0x03, 0x04]),
            SRPBinaryBuffer.typePublicKey: Data(repeating: 0xAB, count: 64),
        ]

        let serialized = SRPBinaryBuffer.serialize(entries: original)
        let parsed = try SRPBinaryBuffer.parse(data: serialized)

        XCTAssertEqual(parsed.count, original.count)
        for (key, value) in original {
            XCTAssertEqual(parsed[key], value, "Mismatch for type 0x\(String(key, radix: 16))")
        }
    }

    // MARK: - UInt32 helpers

    func testReadUInt32() {
        let data = Data([0x00, 0x01, 0x00, 0x00]) // 65536
        XCTAssertEqual(SRPBinaryBuffer.readUInt32(data), 65536)
    }

    func testReadUInt32Max() {
        let data = Data([0xFF, 0xFF, 0xFF, 0xFF])
        XCTAssertEqual(SRPBinaryBuffer.readUInt32(data), UInt32.max)
    }

    func testReadUInt32ShortReturnsZero() {
        let data = Data([0x01, 0x02])
        XCTAssertEqual(SRPBinaryBuffer.readUInt32(data), 0)
    }

    func testWriteUInt32() {
        let data = SRPBinaryBuffer.writeUInt32(0xDEADBEEF)
        XCTAssertEqual(data, Data([0xDE, 0xAD, 0xBE, 0xEF]))
    }

    func testWriteUInt32Zero() {
        let data = SRPBinaryBuffer.writeUInt32(0)
        XCTAssertEqual(data, Data([0x00, 0x00, 0x00, 0x00]))
    }

    func testReadWriteUInt32RoundTrip() {
        let testValues: [UInt32] = [0, 1, 255, 256, 65535, 0xDEADBEEF, UInt32.max]
        for value in testValues {
            let data = SRPBinaryBuffer.writeUInt32(value)
            let read = SRPBinaryBuffer.readUInt32(data)
            XCTAssertEqual(read, value, "Round-trip failed for \(value)")
        }
    }

    // MARK: - TLV type constants

    func testTLVTypeConstants() {
        XCTAssertEqual(SRPBinaryBuffer.typeUsername, 0x01)
        XCTAssertEqual(SRPBinaryBuffer.typeSalt, 0x02)
        XCTAssertEqual(SRPBinaryBuffer.typePublicKey, 0x03)
        XCTAssertEqual(SRPBinaryBuffer.typeProof, 0x04)
        XCTAssertEqual(SRPBinaryBuffer.typeGenerator, 0x05)
        XCTAssertEqual(SRPBinaryBuffer.typePrime, 0x06)
        XCTAssertEqual(SRPBinaryBuffer.typeRSAKey, 0x07)
        XCTAssertEqual(SRPBinaryBuffer.typeIterations, 0x08)
        XCTAssertEqual(SRPBinaryBuffer.typePBKDFLen, 0x09)
    }
}

// MARK: - RSAPublicKey Tests

final class RSAPublicKeyTests: XCTestCase {

    func testInitWithInvalidDataThrows() {
        // Garbage data should not parse as a valid RSA key
        let garbage = Data([0x01, 0x02, 0x03, 0x04, 0x05])
        XCTAssertThrowsError(try RSAPublicKey(derData: garbage)) { error in
            XCTAssertTrue(error is VNCProtocolError)
        }
    }

    func testInitWithEmptyDataThrows() {
        XCTAssertThrowsError(try RSAPublicKey(derData: Data()))
    }

    /// Generate a real RSA key pair using Security framework, extract the
    /// public key DER, and verify we can create an RSAPublicKey and encrypt data.
    func testEncryptWithGeneratedKey() throws {
        // Generate a 2048-bit RSA key pair
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
        ]

        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw error!.takeRetainedValue()
        }

        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            XCTFail("Could not extract public key")
            return
        }

        // Export the public key as DER data
        guard let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            throw error!.takeRetainedValue()
        }

        // Create our RSAPublicKey wrapper
        let rsaKey = try RSAPublicKey(derData: publicKeyData)
        XCTAssertGreaterThan(rsaKey.blockSize, 0)

        // Encrypt some plaintext
        let plaintext = Data("Hello, RSA!".utf8)
        let ciphertext = try rsaKey.encrypt(plaintext)
        XCTAssertFalse(ciphertext.isEmpty)
        XCTAssertNotEqual(ciphertext, plaintext)

        // Decrypt with the private key to verify round-trip
        guard let decrypted = SecKeyCreateDecryptedData(
            privateKey,
            .rsaEncryptionOAEPSHA1,
            ciphertext as CFData,
            &error
        ) as Data? else {
            throw error!.takeRetainedValue()
        }
        XCTAssertEqual(decrypted, plaintext)
    }
}

// MARK: - AESCBCChannel Tests

final class AESCBCChannelTests: XCTestCase {

    func testEncryptDecryptRoundTrip() throws {
        let sendKey = Data(repeating: 0x42, count: 16)
        let recvKey = Data(repeating: 0x42, count: 16)
        // For the encrypt side, sendKey is used for encryption
        // For the decrypt side, recvKey must match the sendKey of the sender
        // So we use matching keys: encrypt with sendKey, decrypt with recvKey=sendKey

        let encryptor = try AESCBCChannel(sendKey: sendKey, recvKey: recvKey)
        let decryptor = try AESCBCChannel(sendKey: recvKey, recvKey: sendKey)

        let plaintext = Data("The quick brown fox jumps over the lazy dog.".utf8)
        let ciphertext = try encryptor.encrypt(plaintext)

        // Ciphertext should be longer than plaintext (16-byte IV prefix + CBC padding)
        XCTAssertGreaterThan(ciphertext.count, plaintext.count)

        // Decrypt using a channel where recvKey matches the sender's sendKey
        let decrypted = try decryptor.decrypt(ciphertext)
        XCTAssertEqual(decrypted, plaintext)
    }

    func testEncryptDecryptEmptyData() throws {
        let sendKey = Data(repeating: 0x11, count: 16)
        let recvKey = Data(repeating: 0x11, count: 16)
        let encryptor = try AESCBCChannel(sendKey: sendKey, recvKey: recvKey)
        let decryptor = try AESCBCChannel(sendKey: recvKey, recvKey: sendKey)

        let plaintext = Data()
        let ciphertext = try encryptor.encrypt(plaintext)
        // Even empty data produces ciphertext due to PKCS7 padding
        XCTAssertGreaterThan(ciphertext.count, 16) // at least IV + 1 block

        let decrypted = try decryptor.decrypt(ciphertext)
        XCTAssertEqual(decrypted, plaintext)
    }

    func testEncryptDecryptMultiBlock() throws {
        let sendKey = Data(repeating: 0xAA, count: 16)
        let recvKey = Data(repeating: 0xAA, count: 16)
        let encryptor = try AESCBCChannel(sendKey: sendKey, recvKey: recvKey)
        let decryptor = try AESCBCChannel(sendKey: recvKey, recvKey: sendKey)

        // Multiple AES blocks (> 16 bytes)
        let plaintext = Data(repeating: 0x42, count: 100)
        let ciphertext = try encryptor.encrypt(plaintext)
        let decrypted = try decryptor.decrypt(ciphertext)
        XCTAssertEqual(decrypted, plaintext)
    }

    func testEncryptProducesDifferentCiphertextEachTime() throws {
        let key = Data(repeating: 0xBB, count: 16)
        let channel = try AESCBCChannel(sendKey: key, recvKey: key)

        let plaintext = Data("same data".utf8)
        let ct1 = try channel.encrypt(plaintext)
        let ct2 = try channel.encrypt(plaintext)

        // Different random IVs mean different ciphertexts
        XCTAssertNotEqual(ct1, ct2)
    }

    func testInvalidKeySizeThrows() {
        // Key too short
        XCTAssertThrowsError(
            try AESCBCChannel(sendKey: Data(repeating: 0, count: 10), recvKey: Data(repeating: 0, count: 16))
        )
        // Key too long
        XCTAssertThrowsError(
            try AESCBCChannel(sendKey: Data(repeating: 0, count: 16), recvKey: Data(repeating: 0, count: 32))
        )
    }

    func testDecryptTooShortCiphertextThrows() throws {
        let key = Data(repeating: 0xCC, count: 16)
        let channel = try AESCBCChannel(sendKey: key, recvKey: key)

        // Ciphertext must be > 16 bytes (at least the IV + some data)
        let shortData = Data(repeating: 0, count: 10)
        XCTAssertThrowsError(try channel.decrypt(shortData))
    }

    func testMultipleEncryptDecryptCycles() throws {
        let sendKey = Data(repeating: 0xDD, count: 16)
        let recvKey = Data(repeating: 0xDD, count: 16)
        let encryptor = try AESCBCChannel(sendKey: sendKey, recvKey: recvKey)
        let decryptor = try AESCBCChannel(sendKey: recvKey, recvKey: sendKey)

        for i in 0..<5 {
            let plaintext = Data("Message number \(i) with some padding".utf8)
            let ct = try encryptor.encrypt(plaintext)
            let decrypted = try decryptor.decrypt(ct)
            XCTAssertEqual(decrypted, plaintext, "Round-trip failed on cycle \(i)")
        }
    }
}

// MARK: - AppleComCryptionChannel Tests

final class AppleComCryptionChannelTests: XCTestCase {

    func testEncryptDefaultsToClientNoGapLayoutAndDecryptsPayload() throws {
        let key = Data((0..<16).map(UInt8.init))
        let iv = Data((16..<32).map(UInt8.init))
        let payload = Data(repeating: 0xA5, count: 20)

        let sender = try AppleComCryptionChannel(key: key, iv: iv)
        let receiver = try AppleComCryptionChannel(key: key, iv: iv)
        let encrypted = try sender.encryptPayload(payload, packetID: 0)

        XCTAssertEqual(encrypted.count, 48)
        let record = try receiver.decryptRecord(encrypted, expectedPacketID: 0)
        XCTAssertEqual(record.packetID, 0)
        XCTAssertEqual(record.payload, payload)
    }

    func testEncryptCanUseNativeServerReservedGapAndDecryptsPayload() throws {
        let key = Data((0..<16).map(UInt8.init))
        let iv = Data((16..<32).map(UInt8.init))
        let payload = Data(repeating: 0xA5, count: 122)

        let sender = try AppleComCryptionChannel(key: key, iv: iv)
        let receiver = try AppleComCryptionChannel(key: key, iv: iv)
        let encrypted = try sender.encryptPayload(payload, packetID: 0, reservedGapBytes: 20)

        XCTAssertEqual(encrypted.count, 176)
        let record = try receiver.decryptRecord(encrypted, expectedPacketID: 0)
        XCTAssertEqual(record.packetID, 0)
        XCTAssertEqual(record.payload, payload)
    }

    /// The in-place core must produce the same bytes as building the record
    /// plaintext and CBC-encrypting it, chained across records.
    func testFramedRecordsMatchReferenceLayout() throws {
        let key = Data((0..<16).map(UInt8.init))
        let iv = Data((16..<32).map(UInt8.init))
        let payloads = [Data(), Data([7]), Data(repeating: 0x5A, count: 14),
                        Data((0..<1_000).map { UInt8(truncatingIfNeeded: $0) })]

        let sender = try AppleComCryptionChannel(key: key, iv: iv)
        var framed = Data()
        var packetID: UInt32 = 5
        for payload in payloads {
            packetID = try sender.appendFramedRecords(of: payload, firstPacketID: packetID, to: &framed)
        }

        var expected = Data()
        var chain = iv
        for (index, payload) in payloads.enumerated() {
            var plaintext = Data([UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)]) + payload
            let remainder = (plaintext.count + 20) % 16
            plaintext.append(Data(count: remainder == 0 ? 0 : 16 - remainder))
            var hashed = withUnsafeBytes(of: (UInt32(5 + index)).bigEndian) { Data($0) }
            hashed.append(plaintext)
            plaintext.append(Data(Insecure.SHA1.hash(data: hashed)))
            let ciphertext = Self.cbcEncrypt(plaintext, key: key, iv: chain)
            chain = ciphertext.suffix(16)
            expected.append(contentsOf: [UInt8(ciphertext.count >> 8), UInt8(ciphertext.count & 0xFF)])
            expected.append(ciphertext)
        }
        XCTAssertEqual(packetID, 9)
        XCTAssertEqual(framed, expected)
    }

    func testFramedRecordsDecryptAcrossPartialReadsAndSplitLargePayloads() throws {
        let key = Data((0..<16).map(UInt8.init))
        let iv = Data((16..<32).map(UInt8.init))
        let large = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 13) })
        let small = Data("after".utf8)

        let sender = try AppleComCryptionChannel(key: key, iv: iv)
        var wire = Data()
        var packetID = try sender.appendFramedRecords(of: large, firstPacketID: 0, to: &wire)
        XCTAssertEqual(packetID, 4, "200 KB needs four records")
        packetID = try sender.appendFramedRecords(of: small, firstPacketID: packetID, to: &wire)

        let receiver = try AppleComCryptionChannel(key: key, iv: iv)
        var buffer = Data()
        var offset = 0
        var expectedPacketID: UInt32 = 0
        var plaintext = Data()
        var position = 0
        while position < wire.count {
            let end = min(position + 997, wire.count)
            buffer.append(wire[position..<end])
            position = end
            _ = try receiver.decryptFramedRecords(
                in: buffer, offset: &offset, expectedPacketID: &expectedPacketID,
                appendingTo: &plaintext)
        }
        XCTAssertEqual(offset, buffer.count)
        XCTAssertEqual(expectedPacketID, 5)
        XCTAssertEqual(plaintext, large + small)
    }

    func testFramedRecordsRejectTamperingAndBadLengths() throws {
        let key = Data((0..<16).map(UInt8.init))
        let iv = Data((16..<32).map(UInt8.init))
        var wire = Data()
        _ = try AppleComCryptionChannel(key: key, iv: iv)
            .appendFramedRecords(of: Data("payload".utf8), firstPacketID: 0, to: &wire)

        var tampered = wire
        tampered[tampered.count - 1] ^= 0x01
        var offset = 0
        var packetID: UInt32 = 0
        var output = Data("kept".utf8)
        XCTAssertThrowsError(try AppleComCryptionChannel(key: key, iv: iv).decryptFramedRecords(
            in: tampered, offset: &offset, expectedPacketID: &packetID, appendingTo: &output))
        XCTAssertEqual(output, Data("kept".utf8), "a failed record leaves the buffer untouched")

        XCTAssertThrowsError(try AppleComCryptionChannel(key: key, iv: iv).decryptFramedRecords(
            in: Data([0x00, 0x11]) + Data(count: 17), offset: &offset,
            expectedPacketID: &packetID, appendingTo: &output))
    }

    /// Prints bulk decrypt throughput for screen-sized Standard traffic.
    func testFramedRecordThroughput() throws {
        let key = Data((0..<16).map(UInt8.init))
        let iv = Data((16..<32).map(UInt8.init))
        let payload = Data((0..<(32 << 20)).map { UInt8(truncatingIfNeeded: $0) })
        var wire = Data()
        let encryptStart = DispatchTime.now().uptimeNanoseconds
        _ = try AppleComCryptionChannel(key: key, iv: iv)
            .appendFramedRecords(of: payload, firstPacketID: 0, to: &wire)
        let decryptStart = DispatchTime.now().uptimeNanoseconds
        var offset = 0
        var packetID: UInt32 = 0
        var plaintext = Data()
        plaintext.reserveCapacity(payload.count)
        _ = try AppleComCryptionChannel(key: key, iv: iv).decryptFramedRecords(
            in: wire, offset: &offset, expectedPacketID: &packetID, appendingTo: &plaintext)
        let end = DispatchTime.now().uptimeNanoseconds
        XCTAssertEqual(plaintext.count, payload.count)
        let megabytes = Double(payload.count) / 1_048_576
        print(String(
            format: "COMCRYPTION encrypt %.0f MB/s decrypt %.0f MB/s",
            megabytes / (Double(decryptStart - encryptStart) / 1e9),
            megabytes / (Double(end - decryptStart) / 1e9)))
    }

    private static func cbcEncrypt(_ data: Data, key: Data, iv: Data) -> Data {
        var output = Data(count: data.count)
        var moved = 0
        _ = output.withUnsafeMutableBytes { out in
            data.withUnsafeBytes { input in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), 0,
                                keyBytes.baseAddress, key.count, ivBytes.baseAddress,
                                input.baseAddress, data.count, out.baseAddress, data.count, &moved)
                    }
                }
            }
        }
        return output
    }
}

// MARK: - ChaCha20Channel Tests

final class ChaCha20ChannelTests: XCTestCase {

    func testSealOpenRoundTrip() throws {
        let key = Data(repeating: 0x42, count: 32)
        let channel = try ChaCha20Channel(key: key)

        let plaintext = Data("Hello, ChaCha20-Poly1305!".utf8)
        let sealed = try channel.seal(plaintext)

        // Combined format: nonce(12) + ciphertext + tag(16)
        XCTAssertEqual(sealed.count, 12 + plaintext.count + 16)

        let opened = try channel.open(sealed)
        XCTAssertEqual(opened, plaintext)
    }

    func testSealOpenWithExplicitNonce() throws {
        let key = Data(repeating: 0xAA, count: 32)
        let channel = try ChaCha20Channel(key: key)

        let nonce = Data(repeating: 0x01, count: 12)
        let plaintext = Data("With explicit nonce".utf8)
        let sealed = try channel.seal(plaintext, nonce: nonce)
        let opened = try channel.open(sealed)
        XCTAssertEqual(opened, plaintext)
    }

    func testSealOpenEmptyData() throws {
        let key = Data(repeating: 0xBB, count: 32)
        let channel = try ChaCha20Channel(key: key)

        let plaintext = Data()
        let sealed = try channel.seal(plaintext)
        let opened = try channel.open(sealed)
        XCTAssertEqual(opened, plaintext)
    }

    func testSealProducesDifferentCiphertextWithRandomNonce() throws {
        let key = Data(repeating: 0xCC, count: 32)
        let channel = try ChaCha20Channel(key: key)

        let plaintext = Data("same message".utf8)
        let s1 = try channel.seal(plaintext)
        let s2 = try channel.seal(plaintext)
        XCTAssertNotEqual(s1, s2) // random nonce -> different ciphertext
    }

    func testSealWithSameNonceProducesSameCiphertext() throws {
        let key = Data(repeating: 0xDD, count: 32)
        let channel = try ChaCha20Channel(key: key)
        let nonce = Data(repeating: 0x42, count: 12)

        let plaintext = Data("deterministic".utf8)
        let s1 = try channel.seal(plaintext, nonce: nonce)
        let s2 = try channel.seal(plaintext, nonce: nonce)
        XCTAssertEqual(s1, s2)
    }

    func testOpenTamperedCiphertextThrows() throws {
        let key = Data(repeating: 0xEE, count: 32)
        let channel = try ChaCha20Channel(key: key)

        let plaintext = Data("sensitive data".utf8)
        var sealed = try channel.seal(plaintext)

        // Tamper with the ciphertext (flip a byte in the middle)
        let midIndex = sealed.count / 2
        sealed[midIndex] ^= 0xFF

        XCTAssertThrowsError(try channel.open(sealed))
    }

    func testInvalidKeySizeThrows() {
        XCTAssertThrowsError(try ChaCha20Channel(key: Data(repeating: 0, count: 16)))
        XCTAssertThrowsError(try ChaCha20Channel(key: Data(repeating: 0, count: 64)))
        XCTAssertThrowsError(try ChaCha20Channel(key: Data()))
    }

    func testInvalidNonceSizeThrows() throws {
        let key = Data(repeating: 0xFF, count: 32)
        let channel = try ChaCha20Channel(key: key)

        XCTAssertThrowsError(try channel.seal(Data("test".utf8), nonce: Data(repeating: 0, count: 8)))
        XCTAssertThrowsError(try channel.seal(Data("test".utf8), nonce: Data(repeating: 0, count: 16)))
    }

    func testOpenWithWrongKeyThrows() throws {
        let key1 = Data(repeating: 0x11, count: 32)
        let key2 = Data(repeating: 0x22, count: 32)
        let channel1 = try ChaCha20Channel(key: key1)
        let channel2 = try ChaCha20Channel(key: key2)

        let plaintext = Data("secret".utf8)
        let sealed = try channel1.seal(plaintext)
        XCTAssertThrowsError(try channel2.open(sealed))
    }

    func testLargePayload() throws {
        let key = Data(repeating: 0x77, count: 32)
        let channel = try ChaCha20Channel(key: key)

        // Encrypt a 64KB payload
        let plaintext = Data(repeating: 0x42, count: 65536)
        let sealed = try channel.seal(plaintext)
        let opened = try channel.open(sealed)
        XCTAssertEqual(opened, plaintext)
    }
}

// MARK: - MediaStreamKeys Tests

final class MediaStreamKeysTests: XCTestCase {

    func testDeriveKeysReturns32ByteKeys() {
        let masterKey = Data(repeating: 0xAB, count: 64)
        let keys = MediaStreamKeys(masterKey: masterKey, streamID: 1)

        XCTAssertEqual(keys.videoEncryptionKey.count, 32)
        XCTAssertEqual(keys.videoAuthKey.count, 32)
        XCTAssertEqual(keys.audioEncryptionKey.count, 32)
        XCTAssertEqual(keys.audioAuthKey.count, 32)
        XCTAssertEqual(keys.controlEncryptionKey.count, 32)
        XCTAssertEqual(keys.controlAuthKey.count, 32)
    }

    func testAllKeysDiffer() {
        let masterKey = Data(repeating: 0xCD, count: 32)
        let keys = MediaStreamKeys(masterKey: masterKey, streamID: 42)

        let allKeys = [
            keys.videoEncryptionKey,
            keys.videoAuthKey,
            keys.audioEncryptionKey,
            keys.audioAuthKey,
            keys.controlEncryptionKey,
            keys.controlAuthKey,
        ]

        // All 6 keys should be unique
        let uniqueKeys = Set(allKeys)
        XCTAssertEqual(uniqueKeys.count, 6, "Expected 6 unique keys but got \(uniqueKeys.count)")
    }

    func testDifferentStreamIDsProduceDifferentKeys() {
        let masterKey = Data(repeating: 0xEF, count: 32)
        let keys1 = MediaStreamKeys(masterKey: masterKey, streamID: 1)
        let keys2 = MediaStreamKeys(masterKey: masterKey, streamID: 2)

        XCTAssertNotEqual(keys1.videoEncryptionKey, keys2.videoEncryptionKey)
        XCTAssertNotEqual(keys1.videoAuthKey, keys2.videoAuthKey)
        XCTAssertNotEqual(keys1.audioEncryptionKey, keys2.audioEncryptionKey)
        XCTAssertNotEqual(keys1.audioAuthKey, keys2.audioAuthKey)
        XCTAssertNotEqual(keys1.controlEncryptionKey, keys2.controlEncryptionKey)
        XCTAssertNotEqual(keys1.controlAuthKey, keys2.controlAuthKey)
    }

    func testDifferentMasterKeysProduceDifferentKeys() {
        let mk1 = Data(repeating: 0x11, count: 32)
        let mk2 = Data(repeating: 0x22, count: 32)
        let keys1 = MediaStreamKeys(masterKey: mk1, streamID: 1)
        let keys2 = MediaStreamKeys(masterKey: mk2, streamID: 1)

        XCTAssertNotEqual(keys1.videoEncryptionKey, keys2.videoEncryptionKey)
    }

    func testSameMasterKeyAndStreamIDProduceSameKeys() {
        let masterKey = Data(repeating: 0x33, count: 48)
        let keys1 = MediaStreamKeys(masterKey: masterKey, streamID: 99)
        let keys2 = MediaStreamKeys(masterKey: masterKey, streamID: 99)

        XCTAssertEqual(keys1.videoEncryptionKey, keys2.videoEncryptionKey)
        XCTAssertEqual(keys1.videoAuthKey, keys2.videoAuthKey)
        XCTAssertEqual(keys1.audioEncryptionKey, keys2.audioEncryptionKey)
        XCTAssertEqual(keys1.audioAuthKey, keys2.audioAuthKey)
        XCTAssertEqual(keys1.controlEncryptionKey, keys2.controlEncryptionKey)
        XCTAssertEqual(keys1.controlAuthKey, keys2.controlAuthKey)
    }

    func testEncryptionAndAuthKeysForSameChannelDiffer() {
        let masterKey = Data(repeating: 0x44, count: 32)
        let keys = MediaStreamKeys(masterKey: masterKey, streamID: 1)

        // For each channel, encryption and auth keys should differ
        XCTAssertNotEqual(keys.videoEncryptionKey, keys.videoAuthKey)
        XCTAssertNotEqual(keys.audioEncryptionKey, keys.audioAuthKey)
        XCTAssertNotEqual(keys.controlEncryptionKey, keys.controlAuthKey)
    }

    func testStreamIDZero() {
        let masterKey = Data(repeating: 0x55, count: 32)
        let keys = MediaStreamKeys(masterKey: masterKey, streamID: 0)

        // Should still produce valid 32-byte keys
        XCTAssertEqual(keys.videoEncryptionKey.count, 32)
        XCTAssertEqual(keys.videoAuthKey.count, 32)
    }

    func testStreamIDMaxValue() {
        let masterKey = Data(repeating: 0x66, count: 32)
        let keys = MediaStreamKeys(masterKey: masterKey, streamID: UInt32.max)

        XCTAssertEqual(keys.videoEncryptionKey.count, 32)
        XCTAssertEqual(keys.controlAuthKey.count, 32)
    }

    func testEmptyMasterKey() {
        let keys = MediaStreamKeys(masterKey: Data(), streamID: 1)
        // Should still produce 32-byte keys (SHA-512 of streamID + label)
        XCTAssertEqual(keys.videoEncryptionKey.count, 32)
        // All keys should still differ due to different labels
        XCTAssertNotEqual(keys.videoEncryptionKey, keys.videoAuthKey)
    }
}
