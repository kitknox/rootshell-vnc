import CommonCrypto
import Foundation
import RFBProtocol

/// Receive-side SRTP unprotect for Apple's AVC media stream packets.
///
/// The media profile carries 46-byte keys and selects SRTP/SRTCP cipher suite
/// `5`: **AES_256_CM_HMAC_SHA1_80**, with a 32-byte AES-256 master
/// key followed by a 14-byte master salt (32 + 14 = 46), with an 80-bit
/// (10-byte) HMAC-SHA1 authentication tag. The server-to-viewer key
/// (`...EncryptionKeyServerToViewer`) is the one used to decrypt inbound video.
public final class AppleSRTPContext: @unchecked Sendable {
    private struct SSRCState {
        var roc: UInt32 = 0
        var highestSequence: UInt16?
    }

    private static let masterKeyLength = 32
    private static let masterSaltLength = 14

    private var hmacTemplate = CCHmacContext()
    private let saltBytes: (
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
    )
    private var cryptor: CCCryptorRef?
    private let tagLength = 10
    private let lock = NSLock()
    private var states: [UInt32: SSRCState] = [:]

    public init(mediaKey: Data) throws {
        let required = Self.masterKeyLength + Self.masterSaltLength
        guard mediaKey.count >= required else {
            throw VNCProtocolError.protocolViolation(
                "Apple SRTP media key must be at least \(required) bytes, got \(mediaKey.count)")
        }

        let masterKey = Data(mediaKey.prefix(Self.masterKeyLength))
        let masterSalt = Data(mediaKey.dropFirst(Self.masterKeyLength).prefix(Self.masterSaltLength))
        let encryptionKey = try Self.deriveSessionKey(masterKey: masterKey, masterSalt: masterSalt, label: 0x00, length: Self.masterKeyLength)
        let authenticationKey = try Self.deriveSessionKey(masterKey: masterKey, masterSalt: masterSalt, label: 0x01, length: 20)
        var template = CCHmacContext()
        authenticationKey.withUnsafeBytes { keyPtr in
            CCHmacInit(&template, CCHmacAlgorithm(kCCHmacAlgSHA1), keyPtr.baseAddress, authenticationKey.count)
        }
        self.hmacTemplate = template
        let salt = try Self.deriveSessionKey(masterKey: masterKey, masterSalt: masterSalt, label: 0x02, length: 14)
        let sBase = salt.startIndex
        self.saltBytes = (
            salt[sBase], salt[sBase + 1], salt[sBase + 2], salt[sBase + 3],
            salt[sBase + 4], salt[sBase + 5], salt[sBase + 6], salt[sBase + 7],
            salt[sBase + 8], salt[sBase + 9], salt[sBase + 10], salt[sBase + 11],
            salt[sBase + 12], salt[sBase + 13]
        )
        self.cryptor = try Self.makeCryptor(key: encryptionKey)
    }

    deinit {
        if let cryptor {
            CCCryptorRelease(cryptor)
        }
    }

    public func unprotect(_ packet: Data) throws -> Data {
        lock.lock()
        defer { lock.unlock() }

        let totalCount = packet.count
        guard totalCount >= 12 + tagLength else {
            throw VNCProtocolError.protocolViolation("SRTP packet too short: \(totalCount)")
        }

        return try packet.withUnsafeBytes { rawBuffer -> Data in
            guard let basePtr = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                throw VNCProtocolError.protocolViolation("SRTP packet buffer unavailable")
            }
            let firstByte = basePtr[0]
            guard (firstByte >> 6) == 2 else {
                throw VNCProtocolError.protocolViolation("SRTP packet has invalid RTP version")
            }

            let sequence = UInt16(basePtr[2]) << 8 | UInt16(basePtr[3])
            let ssrc = UInt32(basePtr[8]) << 24
                | UInt32(basePtr[9]) << 16
                | UInt32(basePtr[10]) << 8
                | UInt32(basePtr[11])

            var state = states[ssrc] ?? SSRCState()
            let roc = estimatedROC(for: sequence, state: state)
            let encryptedLength = totalCount - tagLength
            try verifyAuthentication(basePtr: basePtr, authenticatedLength: encryptedLength, roc: roc)

            let headerLength = try Self.payloadOffset(basePtr: basePtr, totalCount: totalCount)
            guard headerLength <= encryptedLength else {
                throw VNCProtocolError.protocolViolation("SRTP packet has invalid payload bounds")
            }

            let packetIndex = (UInt64(roc) << 16) | UInt64(sequence)
            let rtp = try decryptPacket(
                basePtr: basePtr,
                headerLength: headerLength,
                encryptedLength: encryptedLength,
                ssrc: ssrc,
                packetIndex: packetIndex)

            updateState(&state, sequence: sequence, roc: roc)
            states[ssrc] = state

            return rtp
        }
    }

    private func verifyAuthentication(
        basePtr: UnsafePointer<UInt8>,
        authenticatedLength: Int,
        roc: UInt32
    ) throws {
        var ctx = hmacTemplate
        CCHmacUpdate(&ctx, basePtr, authenticatedLength)
        var rocBE = roc.bigEndian
        withUnsafeBytes(of: &rocBE) { bytes in
            CCHmacUpdate(&ctx, bytes.baseAddress, 4)
        }
        var mac: (
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
        ) = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        var difference: UInt8 = 0
        withUnsafeMutableBytes(of: &mac) { macPtr in
            CCHmacFinal(&ctx, macPtr.baseAddress)
            let expected = macPtr.baseAddress!.assumingMemoryBound(to: UInt8.self)
            let actual = basePtr.advanced(by: authenticatedLength)
            for offset in 0..<tagLength {
                difference |= expected[offset] ^ actual[offset]
            }
        }
        guard difference == 0 else {
            throw VNCProtocolError.protocolViolation("SRTP authentication failed")
        }
    }

    private func decryptPacket(
        basePtr: UnsafePointer<UInt8>,
        headerLength: Int,
        encryptedLength: Int,
        ssrc: UInt32,
        packetIndex: UInt64
    ) throws -> Data {
        let payloadCount = encryptedLength - headerLength
        let rawOut = UnsafeMutableRawPointer.allocate(
            byteCount: max(1, encryptedLength),
            alignment: 1)
        var transferredOwnership = false
        defer {
            if !transferredOwnership {
                rawOut.deallocate()
            }
        }
        if headerLength > 0 {
            rawOut.copyMemory(from: basePtr, byteCount: headerLength)
        }

        if payloadCount > 0 {
            // AES-CM is AES-CTR with a big-endian counter whose low 16 bits are the
            // per-block counter. RTP payloads are well under 2^16 blocks, so a
            // single hardware AES-CTR pass (initial counter = block 0) produces the
            // same keystream as stepping the counter block by block.
            var iv: (
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
            ) = (
                saltBytes.0,
                saltBytes.1,
                saltBytes.2,
                saltBytes.3,
                saltBytes.4 ^ UInt8((ssrc >> 24) & 0xff),
                saltBytes.5 ^ UInt8((ssrc >> 16) & 0xff),
                saltBytes.6 ^ UInt8((ssrc >> 8) & 0xff),
                saltBytes.7 ^ UInt8(ssrc & 0xff),
                saltBytes.8 ^ UInt8((packetIndex >> 40) & 0xff),
                saltBytes.9 ^ UInt8((packetIndex >> 32) & 0xff),
                saltBytes.10 ^ UInt8((packetIndex >> 24) & 0xff),
                saltBytes.11 ^ UInt8((packetIndex >> 16) & 0xff),
                saltBytes.12 ^ UInt8((packetIndex >> 8) & 0xff),
                saltBytes.13 ^ UInt8(packetIndex & 0xff),
                0,
                0
            )

            guard let cryptor else {
                throw VNCProtocolError.ioError("AES-CTR context is unavailable")
            }
            let resetStatus = withUnsafeBytes(of: &iv) { ivPtr in
                CCCryptorReset(cryptor, ivPtr.baseAddress)
            }
            guard resetStatus == kCCSuccess else {
                throw VNCProtocolError.ioError("AES-CTR reset failed: \(resetStatus)")
            }

            var moved = 0
            let updateStatus = CCCryptorUpdate(
                cryptor,
                basePtr.advanced(by: headerLength),
                payloadCount,
                rawOut.advanced(by: headerLength),
                payloadCount,
                &moved)
            guard updateStatus == kCCSuccess, moved == payloadCount else {
                throw VNCProtocolError.ioError("AES-CTR update failed: \(updateStatus)")
            }
        }

        transferredOwnership = true
        return Data(
            bytesNoCopy: rawOut,
            count: encryptedLength,
            deallocator: .custom { ptr, _ in ptr.deallocate() })
    }

    private static func makeCryptor(key: Data) throws -> CCCryptorRef {
        let zeroIV = [UInt8](repeating: 0, count: kCCBlockSizeAES128)
        var cryptorRef: CCCryptorRef?
        let status = zeroIV.withUnsafeBytes { ivPtr in
            key.withUnsafeBytes { keyPtr in
                CCCryptorCreateWithMode(
                    CCOperation(kCCEncrypt), CCMode(kCCModeCTR), CCAlgorithm(kCCAlgorithmAES),
                    CCPadding(ccNoPadding), ivPtr.baseAddress, keyPtr.baseAddress, key.count,
                    nil, 0, 0, CCModeOptions(kCCModeOptionCTR_BE), &cryptorRef)
            }
        }
        guard status == kCCSuccess, let cryptorRef else {
            throw VNCProtocolError.ioError("AES-CTR init failed: \(status)")
        }
        return cryptorRef
    }

    private func estimatedROC(for sequence: UInt16, state: SSRCState) -> UInt32 {
        guard let highestSequence = state.highestSequence else { return state.roc }
        // RFC 3711 Appendix A ROC guess. Use signed arithmetic so the
        // wraparound comparisons never underflow UInt32.
        let maxSeq = Int64(highestSequence)
        let seq = Int64(sequence)
        let roc = Int64(state.roc)
        if maxSeq < 0x8000 {
            if seq - maxSeq > 0x8000, roc > 0 {
                return UInt32(roc - 1)
            }
            return state.roc
        }
        if maxSeq - seq > 0x8000 {
            return UInt32(min(roc + 1, Int64(UInt32.max)))
        }
        return state.roc
    }

    private func updateState(_ state: inout SSRCState, sequence: UInt16, roc: UInt32) {
        if let highest = state.highestSequence,
           highest > 0xf000,
           sequence < 0x0fff,
           roc == state.roc + 1 {
            state.roc = roc
        }
        if state.highestSequence == nil || sequenceIsNewer(sequence, than: state.highestSequence!) {
            state.highestSequence = sequence
        }
    }

    private func sequenceIsNewer(_ sequence: UInt16, than previous: UInt16) -> Bool {
        let distance = sequence &- previous
        return distance != 0 && distance < 0x8000
    }

    private static func payloadOffset(
        basePtr: UnsafePointer<UInt8>,
        totalCount: Int
    ) throws -> Int {
        let csrcCount = Int(basePtr[0] & 0x0f)
        let hasExtension = (basePtr[0] & 0x10) != 0
        var offset = 12 + csrcCount * 4
        guard offset <= totalCount else {
            throw VNCProtocolError.protocolViolation("RTP CSRC header exceeds packet length")
        }

        if hasExtension {
            guard offset + 4 <= totalCount else {
                throw VNCProtocolError.protocolViolation("RTP extension header exceeds packet length")
            }
            let extensionLength = Int(UInt16(basePtr[offset + 2]) << 8 | UInt16(basePtr[offset + 3]))
            offset += 4 + extensionLength * 4
            guard offset <= totalCount else {
                throw VNCProtocolError.protocolViolation("RTP extension payload exceeds packet length")
            }
        }

        return offset
    }

    private static func deriveSessionKey(masterKey: Data, masterSalt: Data, label: UInt8, length: Int) throws -> Data {
        guard masterSalt.count == 14 else {
            throw VNCProtocolError.protocolViolation("SRTP master salt must be 14 bytes")
        }

        var input = Data(count: 16)
        input[7] = label
        for i in 0..<masterSalt.count {
            input[i] ^= masterSalt[masterSalt.startIndex + i]
        }

        var output = Data(capacity: length)
        var counter: UInt16 = 0
        while output.count < length {
            var block = input
            block[14] = UInt8((counter >> 8) & 0xff)
            block[15] = UInt8(counter & 0xff)
            output.append(try aesEncrypt(block: block, key: masterKey))
            counter &+= 1
        }
        return Data(output.prefix(length))
    }

    private static func aesEncrypt(block: Data, key: Data) throws -> Data {
        guard block.count == kCCBlockSizeAES128 else {
            throw VNCProtocolError.protocolViolation("AES block must be 16 bytes")
        }
        guard key.count == kCCKeySizeAES128 || key.count == kCCKeySizeAES256 else {
            throw VNCProtocolError.protocolViolation("AES key must be 16 or 32 bytes, got \(key.count)")
        }

        var output = Data(count: kCCBlockSizeAES128)
        let outputCapacity = output.count
        var outputLength = 0
        let status = output.withUnsafeMutableBytes { outputPtr in
            key.withUnsafeBytes { keyPtr in
                block.withUnsafeBytes { blockPtr in
                    CCCrypt(
                        CCOperation(kCCEncrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionECBMode),
                        keyPtr.baseAddress,
                        key.count,
                        nil,
                        blockPtr.baseAddress,
                        block.count,
                        outputPtr.baseAddress,
                        outputCapacity,
                        &outputLength
                    )
                }
            }
        }
        guard status == kCCSuccess, outputLength == kCCBlockSizeAES128 else {
            throw VNCProtocolError.ioError("AES block encrypt failed: \(status)")
        }
        return output
    }
}
