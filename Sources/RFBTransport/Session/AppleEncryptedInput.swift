import CommonCrypto
import Foundation

/// Mac servers' encrypted input event (command 0x10): `[0x10, flags]` and one
/// 16-byte event encrypted with AES-128-ECB under the session key. Mouse
/// events sent this way also mark the viewer as the owner of a drag on the Mac.
enum AppleEncryptedInput {
    static let messageType: UInt8 = 0x10
    /// Left, right and middle; scroll-wheel bits keep the RFB message.
    static let buttonBits: UInt8 = 0x07

    /// `[0x10, 0 (mouse)] + AES(payload)`; payload is six zero bytes, the
    /// microseconds since the last event, 0xff, buttons, x, y.
    static func mouseMessage(
        buttons: UInt8,
        x: UInt16,
        y: UInt16,
        timeDeltaMicroseconds: UInt32,
        key: Data
    ) -> Data? {
        var payload = Data(count: 6)
        payload.append(UInt8(timeDeltaMicroseconds >> 24))
        payload.append(UInt8(timeDeltaMicroseconds >> 16 & 0xff))
        payload.append(UInt8(timeDeltaMicroseconds >> 8 & 0xff))
        payload.append(UInt8(timeDeltaMicroseconds & 0xff))
        payload.append(0xff)
        payload.append(buttons)
        payload.append(UInt8(x >> 8))
        payload.append(UInt8(x & 0xff))
        payload.append(UInt8(y >> 8))
        payload.append(UInt8(y & 0xff))
        guard let encrypted = encrypt(payload, key: key) else { return nil }
        return Data([messageType, 0]) + encrypted
    }

    /// Flags 0 (keysym only): the Mac maps the keysym through its own layout,
    /// as for an RFB KeyEvent. Payload: 0xff, down, keysym, then zeros
    /// (time delta, keyboard type and key code are unused in this mode).
    static func keyMessage(down: Bool, keysym: UInt32, key: Data) -> Data? {
        var payload = Data([0xff, down ? 1 : 0])
        payload.append(UInt8(keysym >> 24))
        payload.append(UInt8(keysym >> 16 & 0xff))
        payload.append(UInt8(keysym >> 8 & 0xff))
        payload.append(UInt8(keysym & 0xff))
        payload.append(Data(count: 10))
        guard let encrypted = encrypt(payload, key: key) else { return nil }
        return Data([messageType, 0]) + encrypted
    }

    static func encrypt(_ block: Data, key: Data) -> Data? {
        guard block.count == kCCBlockSizeAES128, key.count == kCCKeySizeAES128 else { return nil }
        var output = Data(count: kCCBlockSizeAES128)
        var moved = 0
        let status = output.withUnsafeMutableBytes { outputBytes in
            block.withUnsafeBytes { blockBytes in
                key.withUnsafeBytes { keyBytes in
                    CCCrypt(
                        CCOperation(kCCEncrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionECBMode),
                        keyBytes.baseAddress, kCCKeySizeAES128,
                        nil,
                        blockBytes.baseAddress, kCCBlockSizeAES128,
                        outputBytes.baseAddress, kCCBlockSizeAES128,
                        &moved)
                }
            }
        }
        return status == kCCSuccess && moved == kCCBlockSizeAES128 ? output : nil
    }
}

/// Reusable AES-128-ECB cryptor for Apple encrypted input (command 0x10).
/// Keeps one expanded key schedule for the lifetime of the session key instead
/// of recreating a CommonCrypto context on every pointer/key event.
final class AppleEncryptedInputCipher: @unchecked Sendable {
    let key: Data
    private var cryptor: CCCryptorRef?

    init?(key: Data) {
        guard key.count == kCCKeySizeAES128 else { return nil }
        var ref: CCCryptorRef?
        let status = key.withUnsafeBytes { keyBytes in
            CCCryptorCreateWithMode(
                CCOperation(kCCEncrypt),
                CCMode(kCCModeECB),
                CCAlgorithm(kCCAlgorithmAES),
                CCPadding(ccNoPadding),
                nil,
                keyBytes.baseAddress,
                kCCKeySizeAES128,
                nil, 0, 0,
                CCModeOptions(0),
                &ref)
        }
        guard status == kCCSuccess, let ref else { return nil }
        self.key = key
        self.cryptor = ref
    }

    deinit {
        if let cryptor {
            CCCryptorRelease(cryptor)
        }
    }

    func mouseMessage(
        buttons: UInt8,
        x: UInt16,
        y: UInt16,
        timeDeltaMicroseconds: UInt32
    ) -> Data? {
        var block: (
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
        ) = (
            0, 0, 0, 0, 0, 0,
            UInt8(timeDeltaMicroseconds >> 24),
            UInt8((timeDeltaMicroseconds >> 16) & 0xff),
            UInt8((timeDeltaMicroseconds >> 8) & 0xff),
            UInt8(timeDeltaMicroseconds & 0xff),
            0xff,
            buttons,
            UInt8(x >> 8),
            UInt8(x & 0xff),
            UInt8(y >> 8),
            UInt8(y & 0xff)
        )
        return encryptFramedBlock(&block)
    }

    func keyMessage(down: Bool, keysym: UInt32) -> Data? {
        var block: (
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
        ) = (
            0xff,
            down ? 1 : 0,
            UInt8(keysym >> 24),
            UInt8((keysym >> 16) & 0xff),
            UInt8((keysym >> 8) & 0xff),
            UInt8(keysym & 0xff),
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        )
        return encryptFramedBlock(&block)
    }

    private func encryptFramedBlock(
        _ block: inout (
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
        )
    ) -> Data? {
        guard let cryptor else { return nil }
        var output = Data(count: 2 + kCCBlockSizeAES128)
        var moved = 0
        let status = output.withUnsafeMutableBytes { outBytes in
            guard let outBase = outBytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return CCCryptorStatus(kCCMemoryFailure)
            }
            outBase[0] = AppleEncryptedInput.messageType
            outBase[1] = 0
            return withUnsafeBytes(of: &block) { blockBytes in
                CCCryptorUpdate(
                    cryptor,
                    blockBytes.baseAddress,
                    kCCBlockSizeAES128,
                    outBase.advanced(by: 2),
                    kCCBlockSizeAES128,
                    &moved)
            }
        }
        return status == kCCSuccess && moved == kCCBlockSizeAES128 ? output : nil
    }
}
