import CommonCrypto
import Foundation
import RFBProtocol

/// SRTCP protect/unprotect for Apple's AVC media control channel.
///
/// Apple's Screen Sharing RTCP is SRTCP with the same suite as its SRTP media
/// (cipher suite 5 = AES-256-CM / HMAC-SHA1-80): a 32-byte AES-256 master key
/// followed by a 14-byte master salt (the 46-byte media key). SRTCP derives its
/// own session keys with labels 3/4/5 and appends a 4-byte SRTCP index word
/// (E-flag + 31-bit index) plus a 10-byte auth tag.
///
/// The interoperability vector verifies that a server-to-viewer key
/// authenticates and decrypts a valid Sender Report.
public final class AppleSRTCPContext: @unchecked Sendable {

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
    private var sendIndex: UInt32 = 0

    public init(mediaKey: Data) throws {
        let required = Self.masterKeyLength + Self.masterSaltLength
        guard mediaKey.count >= required else {
            throw VNCProtocolError.protocolViolation(
                "Apple SRTCP media key must be at least \(required) bytes, got \(mediaKey.count)")
        }
        let masterKey = Data(mediaKey.prefix(Self.masterKeyLength))
        let masterSalt = Data(mediaKey.dropFirst(Self.masterKeyLength).prefix(Self.masterSaltLength))
        let encryptionKey = try Self.deriveSessionKey(masterKey: masterKey, masterSalt: masterSalt, label: 0x03, length: Self.masterKeyLength)
        let authenticationKey = try Self.deriveSessionKey(masterKey: masterKey, masterSalt: masterSalt, label: 0x04, length: 20)
        var template = CCHmacContext()
        authenticationKey.withUnsafeBytes { keyPtr in
            CCHmacInit(&template, CCHmacAlgorithm(kCCHmacAlgSHA1), keyPtr.baseAddress, authenticationKey.count)
        }
        self.hmacTemplate = template
        let salt = try Self.deriveSessionKey(masterKey: masterKey, masterSalt: masterSalt, label: 0x05, length: 14)
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

    /// Protect a plaintext RTCP compound packet as SRTCP (E-flag set, encrypted).
    ///
    /// The first 8 bytes (header + sender SSRC) stay in the clear; the remainder
    /// is AES-256-CM encrypted, then the SRTCP index word and HMAC-SHA1-80 tag
    /// are appended. `senderSSRC` must equal the RTCP packet's sender SSRC.
    public func protect(_ rtcp: Data, senderSSRC: UInt32) throws -> Data {
        guard rtcp.count >= 8 else {
            throw VNCProtocolError.protocolViolation("RTCP packet too short: \(rtcp.count)")
        }
        lock.lock()
        defer { lock.unlock() }

        sendIndex = (sendIndex + 1) & 0x7fff_ffff
        let index = sendIndex

        let bodyCount = rtcp.count - 8
        let authenticatedLength = 8 + bodyCount + 4
        let totalLength = authenticatedLength + tagLength
        var out = Data(count: totalLength)
        try out.withUnsafeMutableBytes { outRaw in
            guard let outBase = outRaw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                throw VNCProtocolError.ioError("SRTCP output buffer unavailable")
            }
            try rtcp.withUnsafeBytes { inRaw in
                guard let inBase = inRaw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    throw VNCProtocolError.ioError("RTCP input buffer unavailable")
                }
                outBase.update(from: inBase, count: 8)
                if bodyCount > 0 {
                    try transformLocked(
                        input: inBase.advanced(by: 8),
                        output: outBase.advanced(by: 8),
                        count: bodyCount,
                        ssrc: senderSSRC,
                        index: index)
                }
            }
            // SRTCP index word with E-flag set.
            let indexWord = index | 0x8000_0000
            let idxOffset = 8 + bodyCount
            outBase[idxOffset] = UInt8((indexWord >> 24) & 0xff)
            outBase[idxOffset + 1] = UInt8((indexWord >> 16) & 0xff)
            outBase[idxOffset + 2] = UInt8((indexWord >> 8) & 0xff)
            outBase[idxOffset + 3] = UInt8(indexWord & 0xff)

            var ctx = hmacTemplate
            CCHmacUpdate(&ctx, outBase, authenticatedLength)
            var mac: (
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
            ) = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
            withUnsafeMutableBytes(of: &mac) { macPtr in
                CCHmacFinal(&ctx, macPtr.baseAddress)
                let macBase = macPtr.baseAddress!.assumingMemoryBound(to: UInt8.self)
                outBase.advanced(by: authenticatedLength).update(from: macBase, count: tagLength)
            }
        }
        return out
    }

    /// Unprotect a server SRTCP packet (used for crypto validation/tests).
    public func unprotect(_ srtcp: Data) throws -> Data {
        guard srtcp.count >= 8 + 4 + tagLength else {
            throw VNCProtocolError.protocolViolation("SRTCP packet too short: \(srtcp.count)")
        }
        lock.lock()
        defer { lock.unlock() }

        let authenticatedLength = srtcp.count - tagLength
        let bodyCount = authenticatedLength - 12
        var out = Data(count: 8 + bodyCount)
        try out.withUnsafeMutableBytes { outRaw in
            guard let outBase = outRaw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                throw VNCProtocolError.ioError("SRTCP output buffer unavailable")
            }
            try srtcp.withUnsafeBytes { inRaw in
                guard let inBase = inRaw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    throw VNCProtocolError.ioError("SRTCP input buffer unavailable")
                }
                var ctx = hmacTemplate
                CCHmacUpdate(&ctx, inBase, authenticatedLength)
                var mac: (
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
                ) = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
                var diff: UInt8 = 0
                withUnsafeMutableBytes(of: &mac) { macPtr in
                    CCHmacFinal(&ctx, macPtr.baseAddress)
                    let expected = macPtr.baseAddress!.assumingMemoryBound(to: UInt8.self)
                    let actual = inBase.advanced(by: authenticatedLength)
                    for offset in 0..<tagLength {
                        diff |= expected[offset] ^ actual[offset]
                    }
                }
                guard diff == 0 else {
                    throw VNCProtocolError.protocolViolation("SRTCP authentication failed")
                }

                let idxOffset = authenticatedLength - 4
                let indexWord = UInt32(inBase[idxOffset]) << 24
                    | UInt32(inBase[idxOffset + 1]) << 16
                    | UInt32(inBase[idxOffset + 2]) << 8
                    | UInt32(inBase[idxOffset + 3])
                let index = indexWord & 0x7fff_ffff
                let ssrc = UInt32(inBase[4]) << 24
                    | UInt32(inBase[5]) << 16
                    | UInt32(inBase[6]) << 8
                    | UInt32(inBase[7])

                outBase.update(from: inBase, count: 8)
                if bodyCount > 0 {
                    try transformLocked(
                        input: inBase.advanced(by: 8),
                        output: outBase.advanced(by: 8),
                        count: bodyCount,
                        ssrc: ssrc,
                        index: index)
                }
            }
        }
        return out
    }

    // MARK: - AES-256-CM

    private func transformLocked(
        input: UnsafePointer<UInt8>,
        output: UnsafeMutablePointer<UInt8>,
        count: Int,
        ssrc: UInt32,
        index: UInt32
    ) throws {
        guard count > 0 else { return }
        guard let cryptor else {
            throw VNCProtocolError.ioError("SRTCP AES-CTR context is unavailable")
        }
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
            saltBytes.8,
            saltBytes.9,
            saltBytes.10 ^ UInt8((index >> 24) & 0xff),
            saltBytes.11 ^ UInt8((index >> 16) & 0xff),
            saltBytes.12 ^ UInt8((index >> 8) & 0xff),
            saltBytes.13 ^ UInt8(index & 0xff),
            0,
            0
        )
        let resetStatus = withUnsafeBytes(of: &iv) { ivPtr in
            CCCryptorReset(cryptor, ivPtr.baseAddress)
        }
        guard resetStatus == kCCSuccess else {
            throw VNCProtocolError.ioError("SRTCP AES-CTR reset failed: \(resetStatus)")
        }
        var moved = 0
        let updateStatus = CCCryptorUpdate(cryptor, input, count, output, count, &moved)
        guard updateStatus == kCCSuccess, moved == count else {
            throw VNCProtocolError.ioError("SRTCP AES-CTR update failed: \(updateStatus)")
        }
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
            throw VNCProtocolError.ioError("SRTCP AES-CTR init failed: \(status)")
        }
        return cryptorRef
    }

    private static func deriveSessionKey(masterKey: Data, masterSalt: Data, label: UInt8, length: Int) throws -> Data {
        guard masterSalt.count == 14 else {
            throw VNCProtocolError.protocolViolation("SRTCP master salt must be 14 bytes")
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
        var outputLength = 0
        let status = output.withUnsafeMutableBytes { outputPtr in
            key.withUnsafeBytes { keyPtr in
                block.withUnsafeBytes { blockPtr in
                    CCCrypt(
                        CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                        keyPtr.baseAddress, key.count, nil,
                        blockPtr.baseAddress, block.count,
                        outputPtr.baseAddress, kCCBlockSizeAES128, &outputLength)
                }
            }
        }
        guard status == kCCSuccess, outputLength == kCCBlockSizeAES128 else {
            throw VNCProtocolError.ioError("AES block encrypt failed: \(status)")
        }
        return output
    }
}
