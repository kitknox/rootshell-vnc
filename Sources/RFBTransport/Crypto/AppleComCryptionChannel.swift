import CommonCrypto
import CryptoKit
import Foundation
import RFBProtocol

/// Apple's stateful AES wrapper used for bulk encrypted RFB/UDP packets.
///
/// The encrypted record is block-aligned AES-CBC output. After decrypting, the
/// plaintext contains:
/// `[UInt16 payloadLength][payload][optional reserved gap][padding][SHA1(packetID || preceding bytes)]`.
///
/// On TCP each record is prefixed by a big-endian U16 record length. The CBC
/// state chains across records, so the two cryptors live for the channel.
/// The pointer-based core encrypts in place and decrypts payloads straight
/// into the caller's buffer, so bulk Standard-mode screen data is not copied
/// between buffers on its way through.
final class AppleComCryptionChannel: @unchecked Sendable {
    struct Record: Sendable {
        let packetID: UInt32
        let payload: Data
        let plaintextPrefix: Data
    }

    private static let checksumLength = 20
    private static let block = kCCBlockSizeAES128

    /// Largest payload whose record still fits a U16 record length.
    static let maxPayloadPerRecord = 65_520 - 2 - checksumLength

    private let decryptor: CCCryptorRef
    private let encryptor: CCCryptorRef
    private let lock = NSLock()
    private var hasMatchedPacketID = false

    init(key: Data, iv: Data? = nil) throws {
        guard key.count == kCCKeySizeAES128 else {
            throw VNCProtocolError.ioError("Apple ComCryption requires a 16-byte AES key, got \(key.count)")
        }
        if let iv, iv.count != Self.block {
            throw VNCProtocolError.ioError("Apple ComCryption IV must be 16 bytes, got \(iv.count)")
        }

        var decryptor: CCCryptorRef?
        let decryptStatus = Self.createCBC(
            operation: kCCDecrypt, key: key, iv: iv, cryptor: &decryptor)
        guard decryptStatus == kCCSuccess, let decryptor else {
            throw VNCProtocolError.ioError("Failed to create Apple ComCryption decryptor: status \(decryptStatus)")
        }

        var encryptor: CCCryptorRef?
        let encryptStatus = Self.createCBC(
            operation: kCCEncrypt, key: key, iv: iv, cryptor: &encryptor)
        guard encryptStatus == kCCSuccess, let encryptor else {
            CCCryptorRelease(decryptor)
            throw VNCProtocolError.ioError("Failed to create Apple ComCryption encryptor: status \(encryptStatus)")
        }

        self.decryptor = decryptor
        self.encryptor = encryptor
    }

    deinit {
        CCCryptorRelease(decryptor)
        CCCryptorRelease(encryptor)
    }

    // MARK: - Data API

    func encryptPayload(_ payload: Data, packetID: UInt32, reservedGapBytes: Int = 0) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        var output = Data()
        try payload.withUnsafeBytes { raw in
            try appendRecord(raw, packetID: packetID, reservedGapBytes: reservedGapBytes,
                             framed: false, to: &output)
        }
        return output
    }

    func decryptRecord(_ encrypted: Data, expectedPacketID: UInt32) throws -> Record {
        lock.lock()
        defer { lock.unlock() }
        var payload = Data(capacity: encrypted.count)
        let (packetID, prefix) = try encrypted.withUnsafeBytes { raw in
            try decryptRecord(raw, expectedPacketID: expectedPacketID,
                              appendingPayloadTo: &payload, capturePrefix: true)
        }
        return Record(packetID: packetID, payload: payload, plaintextPrefix: prefix ?? Data())
    }

    // MARK: - Framed stream API

    /// Appends `payload` as U16-framed records, splitting only when it would
    /// not fit one record. Returns the next client packet ID.
    func appendFramedRecords(
        of payload: Data,
        firstPacketID: UInt32,
        to output: inout Data
    ) throws -> UInt32 {
        lock.lock()
        defer { lock.unlock() }
        var packetID = firstPacketID
        try payload.withUnsafeBytes { raw in
            var position = 0
            repeat {
                let chunk = UnsafeRawBufferPointer(rebasing: raw[position..<min(
                    position + Self.maxPayloadPerRecord, raw.count)])
                try appendRecord(chunk, packetID: packetID, reservedGapBytes: 0,
                                 framed: true, to: &output)
                packetID &+= 1
                position += chunk.count
            } while position < raw.count
        }
        return packetID
    }

    /// Decrypts up to `maxRecords` complete U16-framed records in `buffer`
    /// from byte `offset` on, appending payloads to `output`, and advances
    /// `offset` and `expectedPacketID` past them. A trailing partial record is
    /// left for the next call. Returns the number of payload bytes appended.
    func decryptFramedRecords(
        in buffer: Data,
        offset: inout Int,
        expectedPacketID: inout UInt32,
        appendingTo output: inout Data,
        maxRecords: Int = .max
    ) throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        let startCount = output.count
        try buffer.withUnsafeBytes { raw in
            var position = offset
            var records = 0
            defer { offset = position }
            while records < maxRecords, raw.count - position >= 2 {
                let length = Int(raw[position]) << 8 | Int(raw[position + 1])
                guard length >= 2 * Self.block, length % Self.block == 0 else {
                    throw VNCProtocolError.protocolViolation(
                        "Encrypted record length \(length) is not a whole AES record "
                            + "(stream desynchronized)")
                }
                guard raw.count - position - 2 >= length else { break }
                let record = UnsafeRawBufferPointer(
                    rebasing: raw[position + 2..<position + 2 + length])
                let (packetID, _) = try decryptRecord(
                    record, expectedPacketID: expectedPacketID,
                    appendingPayloadTo: &output, capturePrefix: false)
                expectedPacketID = packetID &+ 1
                position += 2 + length
                records += 1
            }
        }
        return output.count - startCount
    }

    // MARK: - Core

    /// Builds the plaintext in `output`, then encrypts it in place. Caller
    /// holds the lock.
    private func appendRecord(
        _ payload: UnsafeRawBufferPointer,
        packetID: UInt32,
        reservedGapBytes: Int,
        framed: Bool,
        to output: inout Data
    ) throws {
        guard payload.count <= Int(UInt16.max) else {
            throw VNCProtocolError.ioError("Apple ComCryption payload too large: \(payload.count)")
        }
        guard reservedGapBytes >= 0 else {
            throw VNCProtocolError.ioError("Apple ComCryption reserved gap cannot be negative")
        }
        let unpaddedLength = 2 + payload.count + reservedGapBytes
        let remainder = (unpaddedLength + Self.checksumLength) % Self.block
        let paddingLength = remainder == 0 ? 0 : Self.block - remainder
        let length = unpaddedLength + paddingLength + Self.checksumLength
        if framed, length > Int(UInt16.max) {
            throw VNCProtocolError.protocolViolation(
                "Apple encrypted client payload too large: \(length) bytes")
        }

        let start = output.count
        let header = framed ? 2 : 0
        // Growing `count` zero-fills the reserved gap and the padding.
        output.count = start + header + length
        try output.withUnsafeMutableBytes { out in
            if framed {
                out[start] = UInt8(length >> 8)
                out[start + 1] = UInt8(length & 0xFF)
            }
            let plaintext = out.baseAddress! + start + header
            plaintext.storeBytes(of: UInt16(payload.count).bigEndian, as: UInt16.self)
            if let source = payload.baseAddress, !payload.isEmpty {
                (plaintext + 2).copyMemory(from: source, byteCount: payload.count)
            }
            let checksumStart = length - Self.checksumLength
            var hasher = Insecure.SHA1()
            Self.hashPacketID(packetID, into: &hasher)
            hasher.update(bufferPointer: UnsafeRawBufferPointer(start: plaintext, count: checksumStart))
            hasher.finalize().withUnsafeBytes { digest in
                (plaintext + checksumStart).copyMemory(
                    from: digest.baseAddress!, byteCount: Self.checksumLength)
            }
            try Self.update(encryptor, plaintext, length, plaintext)
        }
    }

    /// Decrypts the first block to scratch and the rest straight into
    /// `output` so the payload lands contiguously; only the first block's
    /// 14 payload bytes are copied. Caller holds the lock.
    private func decryptRecord(
        _ encrypted: UnsafeRawBufferPointer,
        expectedPacketID: UInt32,
        appendingPayloadTo output: inout Data,
        capturePrefix: Bool
    ) throws -> (packetID: UInt32, plaintextPrefix: Data?) {
        let block = Self.block
        let count = encrypted.count
        guard count >= 2 * block, count % block == 0 else {
            throw VNCProtocolError.ioError("Apple ComCryption record length is not block-aligned: \(count)")
        }
        let start = output.count
        // Plaintext = 2-byte length ‖ output[start ..< start + count - 2].
        output.count = start + count - 2
        do {
            let result = try withUnsafeTemporaryAllocation(
                byteCount: block, alignment: block
            ) { first -> (UInt32, Int, Data?) in
                try output.withUnsafeMutableBytes { out in
                    let body = out.baseAddress! + start
                    try Self.update(decryptor, encrypted.baseAddress!, block, first.baseAddress!)
                    body.copyMemory(from: first.baseAddress! + 2, byteCount: block - 2)
                    try Self.update(decryptor, encrypted.baseAddress! + block, count - block,
                                    body + block - 2)

                    let payloadLength = Int(first[0]) << 8 | Int(first[1])
                    let checksumStart = count - Self.checksumLength
                    guard payloadLength + 2 <= checksumStart else {
                        throw VNCProtocolError.ioError(
                            "Apple ComCryption payload length \(payloadLength) exceeds record \(count)")
                    }
                    let header = UnsafeRawBufferPointer(rebasing: first[0..<2])
                    let packetID = try matchingPacketID(
                        header: header,
                        body: UnsafeRawBufferPointer(start: body, count: checksumStart - 2),
                        checksum: UnsafeRawBufferPointer(
                            start: body + checksumStart - 2, count: Self.checksumLength),
                        expectedPacketID: expectedPacketID)
                    var prefix: Data?
                    if capturePrefix {
                        prefix = Data(header)
                        prefix?.append(contentsOf: UnsafeRawBufferPointer(
                            start: body, count: min(62, count - 2)))
                    }
                    return (packetID, payloadLength, prefix)
                }
            }
            output.count = start + result.1
            return (result.0, result.2)
        } catch {
            output.count = start
            throw error
        }
    }

    private func matchingPacketID(
        header: UnsafeRawBufferPointer,
        body: UnsafeRawBufferPointer,
        checksum: UnsafeRawBufferPointer,
        expectedPacketID: UInt32
    ) throws -> UInt32 {
        var candidates = [expectedPacketID]
        if !hasMatchedPacketID {
            candidates.append(contentsOf: 0..<8)
        }
        var seen = Set<UInt32>()
        for packetID in candidates where seen.insert(packetID).inserted {
            var hasher = Insecure.SHA1()
            Self.hashPacketID(packetID, into: &hasher)
            hasher.update(bufferPointer: header)
            hasher.update(bufferPointer: body)
            if hasher.finalize().withUnsafeBytes({ $0.elementsEqual(checksum) }) {
                hasMatchedPacketID = true
                return packetID
            }
        }
        throw VNCProtocolError.ioError("Apple ComCryption checksum mismatch")
    }

    private static func hashPacketID(_ packetID: UInt32, into hasher: inout Insecure.SHA1) {
        var packetIDBE = packetID.bigEndian
        withUnsafeBytes(of: &packetIDBE) { hasher.update(bufferPointer: $0) }
    }

    /// CommonCrypto allows `input` and `output` to be the same buffer.
    private static func update(
        _ cryptor: CCCryptorRef,
        _ input: UnsafeRawPointer,
        _ count: Int,
        _ output: UnsafeMutableRawPointer
    ) throws {
        var moved = 0
        let status = CCCryptorUpdate(cryptor, input, count, output, count, &moved)
        guard status == kCCSuccess, moved == count else {
            throw VNCProtocolError.ioError(
                "Apple ComCryption AES failed: status \(status) bytesWritten \(moved)")
        }
    }

    private static func createCBC(
        operation: Int,
        key: Data,
        iv: Data?,
        cryptor: inout CCCryptorRef?
    ) -> CCCryptorStatus {
        key.withUnsafeBytes { keyPtr in
            guard let iv else {
                return CCCryptorCreateWithMode(
                    CCOperation(operation), CCMode(kCCModeCBC), CCAlgorithm(kCCAlgorithmAES),
                    CCPadding(ccNoPadding), nil, keyPtr.baseAddress, kCCKeySizeAES128,
                    nil, 0, 0, CCModeOptions(0), &cryptor)
            }
            return iv.withUnsafeBytes { ivPtr in
                CCCryptorCreateWithMode(
                    CCOperation(operation), CCMode(kCCModeCBC), CCAlgorithm(kCCAlgorithmAES),
                    CCPadding(ccNoPadding), ivPtr.baseAddress, keyPtr.baseAddress, kCCKeySizeAES128,
                    nil, 0, 0, CCModeOptions(0), &cryptor)
            }
        }
    }
}
