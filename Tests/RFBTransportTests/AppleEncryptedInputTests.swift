import CommonCrypto
import XCTest
@testable import RFBTransport

final class AppleEncryptedInputTests: XCTestCase {
    private let key = Data((0..<16).map { UInt8($0 &* 17) })

    func testMouseMessageLayout() throws {
        let message = try XCTUnwrap(AppleEncryptedInput.mouseMessage(
            buttons: 1, x: 0x0102, y: 0x0304, timeDeltaMicroseconds: 0x0a0b0c0d, key: key))
        XCTAssertEqual(message.count, 18)
        XCTAssertEqual(Array(message.prefix(2)), [0x10, 0x00])
        XCTAssertEqual(
            try decrypt(Data(message.dropFirst(2))),
            Data([0, 0, 0, 0, 0, 0, 0x0a, 0x0b, 0x0c, 0x0d, 0xff, 1, 0x01, 0x02, 0x03, 0x04]))
    }

    func testKeyMessageLayout() throws {
        let message = try XCTUnwrap(AppleEncryptedInput.keyMessage(
            down: true, keysym: 0x0100_20ac, key: key))
        XCTAssertEqual(Array(message.prefix(2)), [0x10, 0x00]) // keysym only
        XCTAssertEqual(
            try decrypt(Data(message.dropFirst(2))),
            Data([0xff, 1, 0x01, 0x00, 0x20, 0xac]) + Data(count: 10))
        let up = try XCTUnwrap(AppleEncryptedInput.keyMessage(down: false, keysym: 0x61, key: key))
        XCTAssertEqual(try decrypt(Data(up.dropFirst(2))).prefix(6), Data([0xff, 0, 0, 0, 0, 0x61]))
    }

    func testRejectsWrongKeySize() {
        XCTAssertNil(AppleEncryptedInput.mouseMessage(
            buttons: 0, x: 0, y: 0, timeDeltaMicroseconds: 0, key: Data(count: 8)))
    }

    private func decrypt(_ block: Data) throws -> Data {
        var output = Data(count: 16)
        var moved = 0
        let status = output.withUnsafeMutableBytes { out in
            block.withUnsafeBytes { input in
                key.withUnsafeBytes { keyBytes in
                    CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionECBMode), keyBytes.baseAddress, 16, nil,
                            input.baseAddress, 16, out.baseAddress, 16, &moved)
                }
            }
        }
        XCTAssertEqual(status, CCCryptorStatus(kCCSuccess))
        return output
    }
}
