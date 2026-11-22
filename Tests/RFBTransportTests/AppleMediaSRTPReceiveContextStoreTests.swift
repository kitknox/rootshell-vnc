import CommonCrypto
import Foundation
import XCTest
@testable import RFBTransport

/// An SRTP receive context learns each source's rollover counter from the
/// packets it sees. These tests cover the session rebuilding its SRTP state
/// with unchanged keys after a source has wrapped its 16-bit sequence number.
/// All keys and packets are synthetic.
final class AppleMediaSRTPReceiveContextStoreTests: XCTestCase {

    // Synthetic 32-byte AES-256 master key + 14-byte master salt: 0x00...0x2d.
    private let key = Data((0..<46).map { UInt8($0) })

    func testProtectHelperReproducesTheKnownCipherSuite5Vector() throws {
        // Same vector as AppleSRTPContextTests.
        let protected = try XCTUnwrap(Data(base64Encoded:
            "kGASNAECAwQRIjNEvt4AAaChoqP5uBi2sP75CY69L33Z/+U/WzaVmrZS0yJWMzsBZefJem06t3Hqh9pN49XoRfBwPuON97n+31NigxWW"))
        let plaintext = try XCTUnwrap(Data(base64Encoded:
            "kGASNAECAwQRIjNEvt4AAaChoqMAAQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyAhIiMkJSYnKCkqKywtLi8="))
        XCTAssertEqual(try protect(plaintext, rolloverCounter: 0), protected)
    }

    func testRebuildWithUnchangedKeyKeepsRolloverCounterAcrossSequenceWrap() throws {
        var store = AppleMediaSRTPReceiveContextStore()
        store.beginRebuild()
        let original = try store.context(forMediaKey: key)
        store.finishRebuild()
        let decryptor = AppleMediaSRTPDecryptor()
        decryptor.configure(contexts: [original], expectsSRTP: true)

        // RTP sequences start at a random value, so a source can wrap within
        // its first packets. The session has delivered the last one before
        // the wrap...
        let beforeWrap = makeRTP(sequence: 65_535)
        XCTAssertEqual(
            try original.unprotect(protect(beforeWrap, rolloverCounter: 0)),
            beforeWrap)

        // ...and the read task has decrypted the first one after it, off the
        // actor, when the session rebuilds its SRTP state.
        let afterWrap = makeRTP(sequence: 0)
        let batch = decryptor.decryptBatch([PosixUDPDatagram(
            data: try protect(afterWrap, rolloverCounter: 1),
            arrivalNanos: 1)])
        guard case .decrypted(let rtp, _, _, let context, _)? = batch.items.first else {
            return XCTFail("Expected the post-wrap packet to be decrypted off-actor")
        }
        XCTAssertEqual(rtp, afterWrap)

        store.beginRebuild()
        let rebuilt = try store.context(forMediaKey: key)
        store.finishRebuild()
        XCTAssertTrue(rebuilt === original, "An unchanged key must keep its receive context")
        let rebuiltGeneration = decryptor.configure(contexts: [rebuilt], expectsSRTP: true)

        // The in-flight packet is still valid, and the source keeps decrypting.
        XCTAssertEqual(
            AppleMediaSRTPDecryptor.disposition(
                ofPacketAuthenticatedBy: context,
                batchGeneration: batch.generation,
                activeGeneration: rebuiltGeneration,
                activeContexts: [rebuilt]),
            .accept)
        let next = makeRTP(sequence: 1)
        XCTAssertEqual(try rebuilt.unprotect(protect(next, rolloverCounter: 1)), next)

        // What the store prevents: a context built afresh from the same key
        // has no rollover counter and rejects the source from here on.
        let fresh = try AppleSRTPContext(mediaKey: key)
        XCTAssertThrowsError(try fresh.unprotect(protect(afterWrap, rolloverCounter: 1)))
        XCTAssertThrowsError(try fresh.unprotect(protect(next, rolloverCounter: 1)))
    }

    func testRebuildRetiresContextsWhoseKeysAreGone() throws {
        let otherKey = Data((0..<46).map { UInt8($0 + 100) })
        var store = AppleMediaSRTPReceiveContextStore()

        store.beginRebuild()
        let first = try store.context(forMediaKey: key)
        XCTAssertTrue(try store.context(forMediaKey: key) === first)
        store.finishRebuild()

        // A rebuild that no longer names the key retires its context...
        store.beginRebuild()
        let other = try store.context(forMediaKey: otherKey)
        store.finishRebuild()
        XCTAssertFalse(other === first)

        // ...so it does not come back if the key ever reappears.
        store.beginRebuild()
        let second = try store.context(forMediaKey: key)
        store.finishRebuild()
        XCTAssertFalse(second === first)

        store.removeAll()
        store.beginRebuild()
        XCTAssertFalse(try store.context(forMediaKey: key) === second)
        store.finishRebuild()
    }

    // MARK: - Synthetic SRTP sender (AES_256_CM_HMAC_SHA1_80)

    /// V=2, PT=100, SSRC=0x0A0B0C0D, 16-byte payload.
    private func makeRTP(sequence: UInt16) -> Data {
        Data([
            0x80, 100,
            UInt8(sequence >> 8), UInt8(sequence & 0xff),
            0x00, 0x00, 0x10, 0x00,
            0x0A, 0x0B, 0x0C, 0x0D,
        ]) + Data((0..<16).map { UInt8($0) })
    }

    private func protect(_ rtp: Data, rolloverCounter: UInt32) throws -> Data {
        let packet = [UInt8](rtp)
        let masterKey = [UInt8](key.prefix(32))
        let masterSalt = [UInt8](key.dropFirst(32).prefix(14))
        let encryptionKey = try deriveSessionKey(masterKey, masterSalt, label: 0x00, length: 32)
        let authenticationKey = try deriveSessionKey(masterKey, masterSalt, label: 0x01, length: 20)
        let salt = try deriveSessionKey(masterKey, masterSalt, label: 0x02, length: 14)

        var headerLength = 12 + Int(packet[0] & 0x0f) * 4
        if packet[0] & 0x10 != 0 {
            let words = Int(packet[headerLength + 2]) << 8 | Int(packet[headerLength + 3])
            headerLength += 4 + words * 4
        }
        let sequence = UInt64(packet[2]) << 8 | UInt64(packet[3])
        let packetIndex = UInt64(rolloverCounter) << 16 | sequence

        var iv = salt + [0, 0]
        for offset in 0..<4 {
            iv[4 + offset] ^= packet[8 + offset]
        }
        for offset in 0..<6 {
            iv[8 + offset] ^= UInt8((packetIndex >> UInt64(8 * (5 - offset))) & 0xff)
        }

        var cryptor: CCCryptorRef?
        guard CCCryptorCreateWithMode(
            CCOperation(kCCEncrypt), CCMode(kCCModeCTR), CCAlgorithm(kCCAlgorithmAES),
            CCPadding(ccNoPadding), iv, encryptionKey, encryptionKey.count,
            nil, 0, 0, CCModeOptions(kCCModeOptionCTR_BE), &cryptor) == kCCSuccess,
              let cryptor else {
            throw XCTSkip("AES-CTR unavailable")
        }
        defer { CCCryptorRelease(cryptor) }
        let payload = Array(packet[headerLength...])
        var encrypted = [UInt8](repeating: 0, count: payload.count)
        var moved = 0
        guard CCCryptorUpdate(
            cryptor, payload, payload.count, &encrypted, encrypted.count, &moved) == kCCSuccess,
              moved == payload.count else {
            throw XCTSkip("AES-CTR update failed")
        }

        let authenticated = Array(packet[..<headerLength]) + encrypted
        let rolloverBytes = (0..<4).map { UInt8((rolloverCounter >> UInt32(8 * (3 - $0))) & 0xff) }
        var mac = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        let macInput = authenticated + rolloverBytes
        CCHmac(
            CCHmacAlgorithm(kCCHmacAlgSHA1),
            authenticationKey, authenticationKey.count,
            macInput, macInput.count,
            &mac)
        return Data(authenticated + mac.prefix(10))
    }

    /// RFC 3711 key derivation with the AES-CM PRF and a zero derivation rate.
    private func deriveSessionKey(
        _ masterKey: [UInt8],
        _ masterSalt: [UInt8],
        label: UInt8,
        length: Int
    ) throws -> [UInt8] {
        var input = masterSalt + [0, 0]
        input[7] ^= label
        var output: [UInt8] = []
        var counter: UInt16 = 0
        while output.count < length {
            var block = input
            block[14] = UInt8(counter >> 8)
            block[15] = UInt8(counter & 0xff)
            var encrypted = [UInt8](repeating: 0, count: kCCBlockSizeAES128)
            var moved = 0
            guard CCCrypt(
                CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES),
                CCOptions(kCCOptionECBMode),
                masterKey, masterKey.count, nil,
                block, block.count,
                &encrypted, encrypted.count, &moved) == kCCSuccess else {
                throw XCTSkip("AES-ECB unavailable")
            }
            output += encrypted
            counter &+= 1
        }
        return Array(output.prefix(length))
    }
}
