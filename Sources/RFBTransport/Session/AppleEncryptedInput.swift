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
