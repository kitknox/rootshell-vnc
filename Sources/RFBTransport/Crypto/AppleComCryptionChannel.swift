import CommonCrypto
import CryptoKit
import Foundation
import RFBProtocol

/// Apple's stateful AES wrapper used for bulk encrypted RFB/UDP packets.
///
/// The encrypted record is block-aligned AES-CBC output. After decrypting, the
/// plaintext contains:
/// `[UInt16 payloadLength][payload][optional reserved gap][padding][SHA1(packetID || preceding bytes)]`.
final class AppleComCryptionChannel: @unchecked Sendable {
    struct Record: Sendable {
        let packetID: UInt32
        let payload: Data
        let plaintextPrefix: Data
    }

    private var decryptor: CCCryptorRef?
    private var encryptor: CCCryptorRef?
    private let lock = NSLock()
    private var hasMatchedPacketID = false

    init(key: Data, iv: Data? = nil) throws {
        guard key.count == kCCKeySizeAES128 else {
            throw VNCProtocolError.ioError("Apple ComCryption requires a 16-byte AES key, got \(key.count)")
        }
        if let iv, iv.count != kCCBlockSizeAES128 {
            throw VNCProtocolError.ioError("Apple ComCryption IV must be 16 bytes, got \(iv.count)")
        }

        var decryptor: CCCryptorRef?
        let decryptStatus = Self.createCBC(
            operation: kCCDecrypt,
            key: key,
            iv: iv,
            cryptor: &decryptor
        )

        guard decryptStatus == kCCSuccess, let decryptor else {
            throw VNCProtocolError.ioError("Failed to create Apple ComCryption decryptor: status \(decryptStatus)")
        }

        var encryptor: CCCryptorRef?
        let encryptStatus = Self.createCBC(
            operation: kCCEncrypt,
            key: key,
            iv: iv,
            cryptor: &encryptor
        )

        guard encryptStatus == kCCSuccess, let encryptor else {
            CCCryptorRelease(decryptor)
            throw VNCProtocolError.ioError("Failed to create Apple ComCryption encryptor: status \(encryptStatus)")
        }

        self.decryptor = decryptor
        self.encryptor = encryptor
    }

    deinit {
        if let decryptor {
            CCCryptorRelease(decryptor)
        }
        if let encryptor {
            CCCryptorRelease(encryptor)
        }
    }

    func encryptPayload(_ payload: Data, packetID: UInt32, reservedGapBytes: Int = 0) throws -> Data {
        lock.lock()
        defer { lock.unlock() }

        guard payload.count <= Int(UInt16.max) else {
            throw VNCProtocolError.ioError("Apple ComCryption payload too large: \(payload.count)")
        }
        guard reservedGapBytes >= 0 else {
            throw VNCProtocolError.ioError("Apple ComCryption reserved gap cannot be negative")
        }
        guard let encryptor else {
            throw VNCProtocolError.ioError("Apple ComCryption encryptor is unavailable")
        }

        let unpaddedLength = 2 + payload.count + reservedGapBytes
        let remainder = (unpaddedLength + 20) % kCCBlockSizeAES128
        let paddingLength = remainder == 0 ? 0 : (kCCBlockSizeAES128 - remainder)
        let plaintextLength = unpaddedLength + paddingLength + 20

        var plaintext = Data(capacity: plaintextLength)
        plaintext.append(UInt8((payload.count >> 8) & 0xFF))
        plaintext.append(UInt8(payload.count & 0xFF))
        plaintext.append(payload)
        let zeroCount = reservedGapBytes + paddingLength
        if zeroCount > 0 {
            plaintext.append(contentsOf: repeatElement(UInt8(0), count: zeroCount))
        }

        var hasher = Insecure.SHA1()
        var packetIDBE = packetID.bigEndian
        withUnsafeBytes(of: &packetIDBE) { hasher.update(bufferPointer: $0) }
        plaintext.withUnsafeBytes { hasher.update(bufferPointer: $0) }
        let digest = hasher.finalize()
        digest.withUnsafeBytes { bytes in
            plaintext.append(bytes.bindMemory(to: UInt8.self))
        }

        let rawOut = UnsafeMutableRawPointer.allocate(byteCount: plaintext.count, alignment: 1)
        var transferred = false
        defer {
            if !transferred { rawOut.deallocate() }
        }
        var outLength = 0
        let status = plaintext.withUnsafeBytes { plaintextPtr in
            CCCryptorUpdate(
                encryptor,
                plaintextPtr.baseAddress,
                plaintext.count,
                rawOut,
                plaintext.count,
                &outLength
            )
        }

        guard status == kCCSuccess, outLength == plaintext.count else {
            throw VNCProtocolError.ioError(
                "Apple ComCryption encrypt failed: status \(status) bytesWritten \(outLength)")
        }

        transferred = true
        return Data(
            bytesNoCopy: rawOut,
            count: outLength,
            deallocator: .custom { ptr, _ in ptr.deallocate() })
    }

    func decryptRecord(_ encrypted: Data, expectedPacketID: UInt32) throws -> Record {
        lock.lock()
        defer { lock.unlock() }

        guard encrypted.count >= 32, encrypted.count % kCCBlockSizeAES128 == 0 else {
            throw VNCProtocolError.ioError("Apple ComCryption record length is not block-aligned: \(encrypted.count)")
        }
        guard let decryptor else {
            throw VNCProtocolError.ioError("Apple ComCryption decryptor is unavailable")
        }

        var output = [UInt8](repeating: 0, count: encrypted.count)
        var outLength = 0
        let status = encrypted.withUnsafeBytes { encryptedPtr in
            CCCryptorUpdate(
                decryptor,
                encryptedPtr.baseAddress,
                encrypted.count,
                &output,
                output.count,
                &outLength
            )
        }

        guard status == kCCSuccess, outLength == encrypted.count else {
            throw VNCProtocolError.ioError(
                "Apple ComCryption decrypt failed: status \(status) bytesWritten \(outLength)")
        }

        let plaintext = Data(output.prefix(outLength))
        let packetID = try matchingPacketID(for: plaintext, expectedPacketID: expectedPacketID)
        let payloadLength = Int(UInt16(plaintext[plaintext.startIndex]) << 8
            | UInt16(plaintext[plaintext.startIndex + 1]))
        let payloadStart = plaintext.startIndex + 2
        let payloadEnd = payloadStart + payloadLength
        guard payloadEnd <= plaintext.endIndex - 20 else {
            throw VNCProtocolError.ioError(
                "Apple ComCryption plaintext length \(payloadLength) exceeds record \(plaintext.count)")
        }

        hasMatchedPacketID = true
        return Record(
            packetID: packetID,
            payload: Data(plaintext[payloadStart..<payloadEnd]),
            plaintextPrefix: Data(plaintext.prefix(64))
        )
    }

    private func matchingPacketID(for plaintext: Data, expectedPacketID: UInt32) throws -> UInt32 {
        guard plaintext.count >= 22 else {
            throw VNCProtocolError.ioError("Apple ComCryption plaintext too short: \(plaintext.count)")
        }

        let payloadLength = Int(UInt16(plaintext[plaintext.startIndex]) << 8
            | UInt16(plaintext[plaintext.startIndex + 1]))
        guard payloadLength + 2 <= plaintext.count - 20 else {
            throw VNCProtocolError.ioError(
                "Apple ComCryption payload length \(payloadLength) exceeds plaintext \(plaintext.count)")
        }

        var candidates = [expectedPacketID]
        if !hasMatchedPacketID {
            candidates.append(contentsOf: 0..<8)
        }

        var seen = Set<UInt32>()
        for packetID in candidates where seen.insert(packetID).inserted {
            if checksumMatches(plaintext: plaintext, packetID: packetID) {
                return packetID
            }
        }

        throw VNCProtocolError.ioError("Apple ComCryption checksum mismatch")
    }

    private func checksumMatches(plaintext: Data, packetID: UInt32) -> Bool {
        let checksumStart = plaintext.endIndex - 20
        var input = Data(capacity: 4 + checksumStart)
        input.append(UInt8((packetID >> 24) & 0xFF))
        input.append(UInt8((packetID >> 16) & 0xFF))
        input.append(UInt8((packetID >> 8) & 0xFF))
        input.append(UInt8(packetID & 0xFF))
        input.append(plaintext[plaintext.startIndex..<checksumStart])

        let digest = Insecure.SHA1.hash(data: input)
        return Data(digest) == plaintext[checksumStart..<plaintext.endIndex]
    }

    private static func createCBC(
        operation: Int,
        key: Data,
        iv: Data?,
        cryptor: inout CCCryptorRef?
    ) -> CCCryptorStatus {
        key.withUnsafeBytes { keyPtr in
            if let iv {
                return iv.withUnsafeBytes { ivPtr in
                    CCCryptorCreateWithMode(
                        CCOperation(operation),
                        CCMode(kCCModeCBC),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCPadding(ccNoPadding),
                        ivPtr.baseAddress,
                        keyPtr.baseAddress,
                        kCCKeySizeAES128,
                        nil, 0, 0,
                        CCModeOptions(0),
                        &cryptor
                    )
                }
            }

            return CCCryptorCreateWithMode(
                CCOperation(operation),
                CCMode(kCCModeCBC),
                CCAlgorithm(kCCAlgorithmAES),
                CCPadding(ccNoPadding),
                nil,
                keyPtr.baseAddress,
                kCCKeySizeAES128,
                nil, 0, 0,
                CCModeOptions(0),
                &cryptor
            )
        }
    }
}
