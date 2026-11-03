import XCTest
import Foundation
@testable import RFBProtocol

final class PersistentZlibEncodingTests: XCTestCase {
    /// Two consecutive pieces produced by one RFC zlib stream, each terminated
    /// with Z_SYNC_FLUSH. This is the rectangle boundary used by RFB ZRLE.
    private let firstChunk = Data([
        0x78, 0x9c, 0x62, 0x64, 0x60, 0xf8,
        0x0f, 0x00, 0x00, 0x00, 0xff, 0xff,
    ])
    private let secondChunk = Data([
        0x62, 0xfc, 0xcf, 0xc0, 0x00,
        0x00, 0x00, 0x00, 0xff, 0xff,
    ])

    func testZRLEDecodesConsecutiveSyncFlushedRectangles() throws {
        let decoder = ZRLEDecoder()
        let rect = FramebufferRect(
            x: 0, y: 0, width: 1, height: 1, encoding: .zrle)

        var firstReader = MessageReader(data: wirePayload(firstChunk))
        XCTAssertEqual(
            try decoder.decode(
                reader: &firstReader,
                rect: rect,
                pixelFormat: .bgra8888),
            .pixels(Data([0x00, 0x00, 0xff, 0xff])))

        var secondReader = MessageReader(data: wirePayload(secondChunk))
        XCTAssertEqual(
            try decoder.decode(
                reader: &secondReader,
                rect: rect,
                pixelFormat: .bgra8888),
            .pixels(Data([0xff, 0x00, 0x00, 0xff])))
    }

    private func wirePayload(_ compressed: Data) -> Data {
        let count = UInt32(compressed.count)
        var result = Data([
            UInt8((count >> 24) & 0xff),
            UInt8((count >> 16) & 0xff),
            UInt8((count >> 8) & 0xff),
            UInt8(count & 0xff),
        ])
        result.append(compressed)
        return result
    }
}

final class AppleServerCapabilitiesTests: XCTestCase {
    func testParsesStructuredServerInitPrefixAndDesktopName() {
        var field = Data([
            0x00, 0x00,
            0x01, 0x02, 0x03, 0x04,
            0x00, 0x00, 0x01,
        ])
        field.append(Data(repeating: 0, count: 13))
        field.append(Data("Mac Studio".utf8))

        let capabilities = AppleServerCapabilities(serverInitNameField: field)
        XCTAssertEqual(capabilities?.serverFlags, 0x01020304)
        XCTAssertEqual(
            capabilities?.supportsServerCommand(
                AppleServerCapabilities.preciseScrollCommand),
            true)
        XCTAssertEqual(
            String(
                data: AppleServerCapabilities.desktopNameData(
                    fromServerInitNameField: field),
                encoding: .utf8),
            "Mac Studio")
    }

    func testCommandBitmapUsesMSBFirstBitOrder() {
        var bitmap = Data(repeating: 0, count: 16)
        bitmap[0] = 0x80
        bitmap[15] = 0x01
        let capabilities = AppleServerCapabilities(
            serverFlags: 0,
            serverCommandBitmap: bitmap)

        XCTAssertTrue(capabilities.supportsServerCommand(0))
        XCTAssertFalse(capabilities.supportsServerCommand(1))
        XCTAssertTrue(capabilities.supportsServerCommand(127))
    }

    func testSessionSelectionFlag() {
        let bitmap = Data(repeating: 0, count: 16)
        XCTAssertTrue(AppleServerCapabilities(
            serverFlags: 0x54, serverCommandBitmap: bitmap).announcesSessionSelection)
        XCTAssertFalse(AppleServerCapabilities(
            serverFlags: 0x52, serverCommandBitmap: bitmap).announcesSessionSelection)
    }

    func testRegularDesktopNameIsNotTreatedAsCapabilityPrefix() {
        let name = Data("Regular VNC server desktop".utf8)
        XCTAssertNil(AppleServerCapabilities(serverInitNameField: name))
        XCTAssertEqual(
            AppleServerCapabilities.desktopNameData(
                fromServerInitNameField: name),
            name)
    }
}

final class ProtocolVersionTests: XCTestCase {

    // MARK: - Parsing valid versions

    func testParse_v3_8() throws {
        let data = Data("RFB 003.008\n".utf8)
        let version = try ProtocolVersion(data: data)
        XCTAssertEqual(version.major, 3)
        XCTAssertEqual(version.minor, 8)
        XCTAssertFalse(version.isApple)
        XCTAssertEqual(version, ProtocolVersion.v3_8)
    }

    func testParse_v3_3() throws {
        let data = Data("RFB 003.003\n".utf8)
        let version = try ProtocolVersion(data: data)
        XCTAssertEqual(version.major, 3)
        XCTAssertEqual(version.minor, 3)
        XCTAssertFalse(version.isApple)
        XCTAssertEqual(version, ProtocolVersion.v3_3)
    }

    func testParse_v3_7() throws {
        let data = Data("RFB 003.007\n".utf8)
        let version = try ProtocolVersion(data: data)
        XCTAssertEqual(version.major, 3)
        XCTAssertEqual(version.minor, 7)
        XCTAssertFalse(version.isApple)
        XCTAssertEqual(version, ProtocolVersion.v3_7)
    }

    func testParse_apple889() throws {
        let data = Data("RFB 003.889\n".utf8)
        let version = try ProtocolVersion(data: data)
        XCTAssertEqual(version.major, 3)
        XCTAssertEqual(version.minor, 889)
        XCTAssertTrue(version.isApple)
        XCTAssertEqual(version, ProtocolVersion.apple)
    }

    // MARK: - Wire bytes round-trip

    func testWireBytesRoundTrip_v3_8() throws {
        let original = ProtocolVersion.v3_8
        let bytes = original.wireBytes()
        XCTAssertEqual(bytes.count, 12)
        XCTAssertEqual(String(data: bytes, encoding: .ascii), "RFB 003.008\n")

        let parsed = try ProtocolVersion(data: bytes)
        XCTAssertEqual(parsed, original)
    }

    func testWireBytesRoundTrip_v3_3() throws {
        let original = ProtocolVersion.v3_3
        let bytes = original.wireBytes()
        XCTAssertEqual(String(data: bytes, encoding: .ascii), "RFB 003.003\n")
        let parsed = try ProtocolVersion(data: bytes)
        XCTAssertEqual(parsed, original)
    }

    func testWireBytesRoundTrip_apple() throws {
        let original = ProtocolVersion.apple
        let bytes = original.wireBytes()
        XCTAssertEqual(String(data: bytes, encoding: .ascii), "RFB 003.889\n")
        let parsed = try ProtocolVersion(data: bytes)
        XCTAssertEqual(parsed, original)
    }

    // MARK: - Wire size

    func testWireSize() {
        XCTAssertEqual(ProtocolVersion.wireSize, 12)
    }

    // MARK: - isAtLeast

    func testIsAtLeast() {
        XCTAssertTrue(ProtocolVersion.v3_8.isAtLeast(.v3_8))
        XCTAssertTrue(ProtocolVersion.v3_8.isAtLeast(.v3_7))
        XCTAssertTrue(ProtocolVersion.v3_8.isAtLeast(.v3_3))
        XCTAssertFalse(ProtocolVersion.v3_3.isAtLeast(.v3_7))
        XCTAssertFalse(ProtocolVersion.v3_7.isAtLeast(.v3_8))
        XCTAssertTrue(ProtocolVersion.v3_3.isAtLeast(.v3_3))
        // Apple version has minor 889 which is numerically higher than 8
        XCTAssertTrue(ProtocolVersion.apple.isAtLeast(.v3_8))
    }

    // MARK: - Error cases

    func testParseTooShortThrows() {
        let data = Data("RFB 003.00".utf8) // only 10 bytes
        XCTAssertThrowsError(try ProtocolVersion(data: data)) { error in
            guard let protocolError = error as? VNCProtocolError else {
                XCTFail("Expected VNCProtocolError")
                return
            }
            if case .protocolViolation(let msg) = protocolError {
                XCTAssertTrue(msg.contains("too short"))
            } else {
                XCTFail("Expected protocolViolation error")
            }
        }
    }

    func testParseInvalidPrefixThrows() {
        let data = Data("VNC 003.008\n".utf8)
        XCTAssertThrowsError(try ProtocolVersion(data: data))
    }

    func testParseMissingSeparatorThrows() {
        let data = Data("RFB 003X008\n".utf8)
        XCTAssertThrowsError(try ProtocolVersion(data: data))
    }

    func testParseMissingNewlineThrows() {
        let data = Data("RFB 003.008X".utf8)
        XCTAssertThrowsError(try ProtocolVersion(data: data))
    }

    // MARK: - Description

    func testDescription() {
        XCTAssertEqual(ProtocolVersion.v3_8.description, "RFB 3.8")
        XCTAssertEqual(ProtocolVersion.apple.description, "RFB 3.889")
    }
}

// MARK: - SecurityType Tests

final class SecurityTypeTests: XCTestCase {

    func testKnownRawValues() {
        XCTAssertEqual(SecurityType.none.rawValue, 1)
        XCTAssertEqual(SecurityType.vncAuthentication.rawValue, 2)
        XCTAssertEqual(SecurityType.tight.rawValue, 16)
        XCTAssertEqual(SecurityType.vencrypt.rawValue, 19)
        XCTAssertEqual(SecurityType.apple30.rawValue, 30)
        XCTAssertEqual(SecurityType.macAuthentication.rawValue, 33)
        XCTAssertEqual(SecurityType.srp.rawValue, 35)
        XCTAssertEqual(SecurityType.appleSRP.rawValue, 36)
    }

    func testInitFromRawValue() {
        XCTAssertEqual(SecurityType(rawValue: 1), .none)
        XCTAssertEqual(SecurityType(rawValue: 2), .vncAuthentication)
        XCTAssertEqual(SecurityType(rawValue: 16), .tight)
        XCTAssertEqual(SecurityType(rawValue: 19), .vencrypt)
        XCTAssertEqual(SecurityType(rawValue: 30), .apple30)
        XCTAssertEqual(SecurityType(rawValue: 33), .macAuthentication)
        XCTAssertEqual(SecurityType(rawValue: 35), .srp)
        XCTAssertEqual(SecurityType(rawValue: 36), .appleSRP)
    }

    func testUnknownRawValue() {
        let sec = SecurityType(rawValue: 99)
        XCTAssertEqual(sec, .unknown(99))
        XCTAssertEqual(sec.rawValue, 99)
    }

    func testRoundTripThroughRawValue() {
        let allKnown: [SecurityType] = [
            .none, .vncAuthentication, .tight, .vencrypt, .apple30,
            .macAuthentication, .srp, .appleSRP,
        ]
        for type in allKnown {
            let recreated = SecurityType(rawValue: type.rawValue)
            XCTAssertEqual(recreated, type, "Round-trip failed for \(type)")
        }
    }

    func testNegotiationPriority() {
        XCTAssertEqual(SecurityType.none.negotiationPriority, 0)
        XCTAssertEqual(SecurityType.vncAuthentication.negotiationPriority, 1)
        XCTAssertEqual(SecurityType.apple30.negotiationPriority, 2)
        XCTAssertEqual(SecurityType.macAuthentication.negotiationPriority, 3)
        XCTAssertEqual(SecurityType.vencrypt.negotiationPriority, 4)
        // SRP not yet implemented (client-speaks-first protocol)
        XCTAssertNil(SecurityType.srp.negotiationPriority)
        XCTAssertNil(SecurityType.tight.negotiationPriority)
        XCTAssertEqual(SecurityType.appleSRP.negotiationPriority, 2)
        XCTAssertNil(SecurityType.unknown(99).negotiationPriority)
    }

    func testAppleDHHasHigherPriorityThanVNC() {
        let dhPriority = SecurityType.apple30.negotiationPriority!
        let vncPriority = SecurityType.vncAuthentication.negotiationPriority!
        XCTAssertGreaterThan(dhPriority, vncPriority)
    }

    func testMacAuthenticationHasHigherPriorityThanAppleDH() {
        let macPriority = SecurityType.macAuthentication.negotiationPriority!
        let dhPriority = SecurityType.apple30.negotiationPriority!
        XCTAssertGreaterThan(macPriority, dhPriority)
    }

    func testAppleSRPWithoutMacTypesSignature() {
        XCTAssertTrue(SecurityType.offersAppleSRPWithoutMacTypes([.appleSRP]))
        XCTAssertTrue(SecurityType.offersAppleSRPWithoutMacTypes([.none, .appleSRP]))
        XCTAssertFalse(SecurityType.offersAppleSRPWithoutMacTypes([.apple30, .macAuthentication, .appleSRP]))
        XCTAssertFalse(SecurityType.offersAppleSRPWithoutMacTypes([.vncAuthentication]))
    }

    func testVeNCryptHasHighestSupportedNegotiationPriority() {
        let vencryptPriority = SecurityType.vencrypt.negotiationPriority!
        let macPriority = SecurityType.macAuthentication.negotiationPriority!
        XCTAssertGreaterThan(vencryptPriority, macPriority)
    }

    func testEquatable() {
        XCTAssertEqual(SecurityType.none, SecurityType.none)
        XCTAssertNotEqual(SecurityType.none, SecurityType.vncAuthentication)
        XCTAssertEqual(SecurityType.unknown(42), SecurityType.unknown(42))
        XCTAssertNotEqual(SecurityType.unknown(42), SecurityType.unknown(43))
    }

    func testHashable() {
        var set = Set<SecurityType>()
        set.insert(.none)
        set.insert(.vncAuthentication)
        set.insert(.none) // duplicate
        XCTAssertEqual(set.count, 2)
    }
}

// MARK: - PixelFormat Tests

final class PixelFormatTests: XCTestCase {

    func testBgra8888Preset() {
        let pf = PixelFormat.bgra8888
        XCTAssertEqual(pf.bitsPerPixel, 32)
        XCTAssertEqual(pf.depth, 24)
        XCTAssertFalse(pf.bigEndian)
        XCTAssertTrue(pf.trueColor)
        XCTAssertEqual(pf.redMax, 255)
        XCTAssertEqual(pf.greenMax, 255)
        XCTAssertEqual(pf.blueMax, 255)
        XCTAssertEqual(pf.redShift, 16)
        XCTAssertEqual(pf.greenShift, 8)
        XCTAssertEqual(pf.blueShift, 0)
        XCTAssertEqual(pf.bytesPerPixel, 4)
    }

    func testRgb888Preset() {
        let pf = PixelFormat.rgb888
        XCTAssertEqual(pf.bitsPerPixel, 32)
        XCTAssertEqual(pf.depth, 24)
        XCTAssertTrue(pf.bigEndian)
        XCTAssertTrue(pf.trueColor)
        XCTAssertEqual(pf.redMax, 255)
        XCTAssertEqual(pf.greenMax, 255)
        XCTAssertEqual(pf.blueMax, 255)
        XCTAssertEqual(pf.redShift, 16)
        XCTAssertEqual(pf.greenShift, 8)
        XCTAssertEqual(pf.blueShift, 0)
    }

    func testParse16Bytes() throws {
        // Construct a PixelFormat matching bgra8888:
        // bpp=32, depth=24, bigEndian=0, trueColor=1,
        // redMax=255, greenMax=255, blueMax=255,
        // redShift=16, greenShift=8, blueShift=0, padding=0,0,0
        var bytes = Data(count: 16)
        bytes[0] = 32    // bitsPerPixel
        bytes[1] = 24    // depth
        bytes[2] = 0     // big endian = false
        bytes[3] = 1     // true color = true
        bytes[4] = 0     // redMax high byte
        bytes[5] = 255   // redMax low byte
        bytes[6] = 0     // greenMax high byte
        bytes[7] = 255   // greenMax low byte
        bytes[8] = 0     // blueMax high byte
        bytes[9] = 255   // blueMax low byte
        bytes[10] = 16   // redShift
        bytes[11] = 8    // greenShift
        bytes[12] = 0    // blueShift
        bytes[13] = 0    // padding
        bytes[14] = 0
        bytes[15] = 0

        let pf = try PixelFormat(data: bytes)
        XCTAssertEqual(pf, PixelFormat.bgra8888)
    }

    func testRoundTripSerialization() throws {
        let original = PixelFormat.bgra8888
        let bytes = original.wireBytes()
        XCTAssertEqual(bytes.count, 16)

        let parsed = try PixelFormat(data: bytes)
        XCTAssertEqual(parsed, original)
    }

    func testRoundTripSerializationRGB888() throws {
        let original = PixelFormat.rgb888
        let bytes = original.wireBytes()
        XCTAssertEqual(bytes.count, 16)

        let parsed = try PixelFormat(data: bytes)
        XCTAssertEqual(parsed, original)
    }

    func testCustomPixelFormatRoundTrip() throws {
        let custom = PixelFormat(
            bitsPerPixel: 16,
            depth: 16,
            bigEndian: true,
            trueColor: true,
            redMax: 31,
            greenMax: 63,
            blueMax: 31,
            redShift: 11,
            greenShift: 5,
            blueShift: 0
        )
        let bytes = custom.wireBytes()
        let parsed = try PixelFormat(data: bytes)
        XCTAssertEqual(parsed, custom)
    }

    func testParseTooShortThrows() {
        let bytes = Data(count: 10) // need 16
        XCTAssertThrowsError(try PixelFormat(data: bytes))
    }

    func testBytesPerPixel() {
        XCTAssertEqual(PixelFormat.bgra8888.bytesPerPixel, 4)

        let pf16 = PixelFormat(
            bitsPerPixel: 16, depth: 16, bigEndian: false, trueColor: true,
            redMax: 31, greenMax: 63, blueMax: 31,
            redShift: 11, greenShift: 5, blueShift: 0
        )
        XCTAssertEqual(pf16.bytesPerPixel, 2)

        let pf8 = PixelFormat(
            bitsPerPixel: 8, depth: 8, bigEndian: false, trueColor: false,
            redMax: 0, greenMax: 0, blueMax: 0,
            redShift: 0, greenShift: 0, blueShift: 0
        )
        XCTAssertEqual(pf8.bytesPerPixel, 1)
    }

    func testWireSize() {
        XCTAssertEqual(PixelFormat.wireSize, 16)
    }

    func testBigEndianFlag() throws {
        var bytes = PixelFormat.bgra8888.wireBytes()
        bytes[2] = 1 // set big-endian
        let pf = try PixelFormat(data: bytes)
        XCTAssertTrue(pf.bigEndian)
    }

    func testTrueColorFlag() throws {
        var bytes = PixelFormat.bgra8888.wireBytes()
        bytes[3] = 0 // set false
        let pf = try PixelFormat(data: bytes)
        XCTAssertFalse(pf.trueColor)
    }
}

// MARK: - ServerInit Tests

final class ServerInitTests: XCTestCase {

    func testParseServerInit() throws {
        // Build a ServerInit message for 1920x1080 with name "Test Server"
        var data = Data()

        // framebuffer-width: 1920 = 0x0780
        data.append(contentsOf: [0x07, 0x80])
        // framebuffer-height: 1080 = 0x0438
        data.append(contentsOf: [0x04, 0x38])
        // pixel format: bgra8888
        data.append(PixelFormat.bgra8888.wireBytes())
        // name-length: 11 bytes = "Test Server"
        let nameBytes = Data("Test Server".utf8)
        let nameLen = UInt32(nameBytes.count)
        data.append(contentsOf: [
            UInt8((nameLen >> 24) & 0xFF),
            UInt8((nameLen >> 16) & 0xFF),
            UInt8((nameLen >> 8) & 0xFF),
            UInt8(nameLen & 0xFF),
        ])
        data.append(nameBytes)

        var reader = MessageReader(data: data)
        let si = try ServerInit(reader: &reader)

        XCTAssertEqual(si.framebufferWidth, 1920)
        XCTAssertEqual(si.framebufferHeight, 1080)
        XCTAssertEqual(si.pixelFormat, PixelFormat.bgra8888)
        XCTAssertEqual(si.name, "Test Server")
    }

    func testServerInitMinWireSize() {
        XCTAssertEqual(ServerInit.minWireSize, 24)
    }

    func testServerInitEquatable() {
        let si1 = ServerInit(framebufferWidth: 800, framebufferHeight: 600, pixelFormat: .bgra8888, name: "Test")
        let si2 = ServerInit(framebufferWidth: 800, framebufferHeight: 600, pixelFormat: .bgra8888, name: "Test")
        let si3 = ServerInit(framebufferWidth: 1024, framebufferHeight: 768, pixelFormat: .bgra8888, name: "Other")
        XCTAssertEqual(si1, si2)
        XCTAssertNotEqual(si1, si3)
    }

    func testParseEmptyName() throws {
        var data = Data()
        data.append(contentsOf: [0x03, 0x20]) // 800
        data.append(contentsOf: [0x02, 0x58]) // 600
        data.append(PixelFormat.bgra8888.wireBytes())
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x00]) // name length = 0

        var reader = MessageReader(data: data)
        let si = try ServerInit(reader: &reader)
        XCTAssertEqual(si.framebufferWidth, 800)
        XCTAssertEqual(si.framebufferHeight, 600)
        XCTAssertEqual(si.name, "")
    }
}

// MARK: - MessageReader Tests

final class MessageReaderTests: XCTestCase {

    func testReadUInt8() throws {
        let data = Data([0xAB])
        var reader = MessageReader(data: data)
        let value = try reader.readUInt8()
        XCTAssertEqual(value, 0xAB)
        XCTAssertEqual(reader.remaining, 0)
    }

    func testReadUInt16() throws {
        // 0x1234 big-endian
        let data = Data([0x12, 0x34])
        var reader = MessageReader(data: data)
        let value = try reader.readUInt16()
        XCTAssertEqual(value, 0x1234)
        XCTAssertEqual(reader.remaining, 0)
    }

    func testReadUInt32() throws {
        // 0xDEADBEEF big-endian
        let data = Data([0xDE, 0xAD, 0xBE, 0xEF])
        var reader = MessageReader(data: data)
        let value = try reader.readUInt32()
        XCTAssertEqual(value, 0xDEADBEEF)
        XCTAssertEqual(reader.remaining, 0)
    }

    func testReadInt32() throws {
        // -1 in big-endian two's complement = 0xFFFFFFFF
        let data = Data([0xFF, 0xFF, 0xFF, 0xFF])
        var reader = MessageReader(data: data)
        let value = try reader.readInt32()
        XCTAssertEqual(value, -1)
    }

    func testReadInt32_negativeEncoding() throws {
        // Encoding.cursor raw value is -239. As Int32 = -239
        // In UInt32 bit pattern: UInt32(bitPattern: Int32(-239)) = 4294967057 = 0xFFFFFF11
        let rawValue = UInt32(bitPattern: Int32(-239))
        let data = Data([
            UInt8((rawValue >> 24) & 0xFF),
            UInt8((rawValue >> 16) & 0xFF),
            UInt8((rawValue >> 8) & 0xFF),
            UInt8(rawValue & 0xFF),
        ])
        var reader = MessageReader(data: data)
        let value = try reader.readInt32()
        XCTAssertEqual(value, -239)
    }

    func testReadBytes() throws {
        let data = Data([0x01, 0x02, 0x03, 0x04, 0x05])
        var reader = MessageReader(data: data)
        let slice = try reader.readBytes(3)
        XCTAssertEqual(slice, Data([0x01, 0x02, 0x03]))
        XCTAssertEqual(reader.remaining, 2)
    }

    func testReadString() throws {
        // length-prefixed UTF-8 string: 5 bytes "Hello"
        let str = "Hello"
        let strData = Data(str.utf8)
        var data = Data()
        let len = UInt32(strData.count)
        data.append(contentsOf: [
            UInt8((len >> 24) & 0xFF),
            UInt8((len >> 16) & 0xFF),
            UInt8((len >> 8) & 0xFF),
            UInt8(len & 0xFF),
        ])
        data.append(strData)

        var reader = MessageReader(data: data)
        let result = try reader.readString()
        XCTAssertEqual(result, "Hello")
        XCTAssertEqual(reader.remaining, 0)
    }

    func testReadStringEmpty() throws {
        let data = Data([0x00, 0x00, 0x00, 0x00]) // length 0
        var reader = MessageReader(data: data)
        let result = try reader.readString()
        XCTAssertEqual(result, "")
    }

    func testPosition() throws {
        let data = Data([0x01, 0x02, 0x03, 0x04])
        var reader = MessageReader(data: data)
        XCTAssertEqual(reader.position, 0)
        _ = try reader.readUInt8()
        XCTAssertEqual(reader.position, 1)
        _ = try reader.readUInt16()
        XCTAssertEqual(reader.position, 3)
    }

    func testRemaining() throws {
        let data = Data([0x01, 0x02, 0x03, 0x04])
        var reader = MessageReader(data: data)
        XCTAssertEqual(reader.remaining, 4)
        _ = try reader.readUInt8()
        XCTAssertEqual(reader.remaining, 3)
        _ = try reader.readUInt16()
        XCTAssertEqual(reader.remaining, 1)
    }

    func testSkip() throws {
        let data = Data([0x01, 0x02, 0x03, 0x04])
        var reader = MessageReader(data: data)
        try reader.skip(2)
        XCTAssertEqual(reader.position, 2)
        let val = try reader.readUInt8()
        XCTAssertEqual(val, 0x03)
    }

    // MARK: - Short read errors

    func testReadUInt8ShortThrows() {
        let data = Data()
        var reader = MessageReader(data: data)
        XCTAssertThrowsError(try reader.readUInt8()) { error in
            XCTAssertTrue(error is MessageReaderError)
        }
    }

    func testReadUInt16ShortThrows() {
        let data = Data([0x01]) // only 1 byte, need 2
        var reader = MessageReader(data: data)
        XCTAssertThrowsError(try reader.readUInt16())
    }

    func testReadUInt32ShortThrows() {
        let data = Data([0x01, 0x02]) // only 2 bytes, need 4
        var reader = MessageReader(data: data)
        XCTAssertThrowsError(try reader.readUInt32())
    }

    func testReadBytesShortThrows() {
        let data = Data([0x01, 0x02])
        var reader = MessageReader(data: data)
        XCTAssertThrowsError(try reader.readBytes(5))
    }

    func testReadStringShortDataThrows() {
        // Claims length 100 but only has 2 bytes of payload
        let data = Data([0x00, 0x00, 0x00, 0x64, 0xAA, 0xBB])
        var reader = MessageReader(data: data)
        XCTAssertThrowsError(try reader.readString())
    }

    func testSkipShortThrows() {
        let data = Data([0x01])
        var reader = MessageReader(data: data)
        XCTAssertThrowsError(try reader.skip(5))
    }

    func testSequentialReads() throws {
        let data = Data([0x01, 0x00, 0x02, 0xDE, 0xAD, 0xBE, 0xEF])
        var reader = MessageReader(data: data)
        let byte = try reader.readUInt8()
        XCTAssertEqual(byte, 0x01)
        let short = try reader.readUInt16()
        XCTAssertEqual(short, 0x0002)
        let word = try reader.readUInt32()
        XCTAssertEqual(word, 0xDEADBEEF)
        XCTAssertEqual(reader.remaining, 0)
    }

    func testReadPixelFormat() throws {
        let pfBytes = PixelFormat.bgra8888.wireBytes()
        var reader = MessageReader(data: pfBytes)
        let pf = try reader.readPixelFormat()
        XCTAssertEqual(pf, PixelFormat.bgra8888)
    }
}

// MARK: - MessageWriter Tests

final class MessageWriterTests: XCTestCase {

    // MARK: - SetPixelFormat (type 0)

    func testWriteSetPixelFormat() {
        let data = MessageWriter.writeSetPixelFormat(.bgra8888)
        XCTAssertEqual(data.count, 20)
        XCTAssertEqual(data[0], 0) // message type
        XCTAssertEqual(data[1], 0) // padding
        XCTAssertEqual(data[2], 0)
        XCTAssertEqual(data[3], 0)
        // bytes 4-19 should be the pixel format
        let pfData = PixelFormat.bgra8888.wireBytes()
        XCTAssertEqual(Data(data[4..<20]), pfData)
    }

    // MARK: - SetEncodings (type 2)

    func testWriteSetEncodings() {
        let encodings: [Encoding] = [.raw, .copyRect, .zrle]
        let data = MessageWriter.writeSetEncodings(encodings)
        XCTAssertEqual(data[0], 2) // message type
        XCTAssertEqual(data[1], 0) // padding
        // number of encodings = 3 (big-endian UInt16)
        XCTAssertEqual(data[2], 0)
        XCTAssertEqual(data[3], 3)
        XCTAssertEqual(data.count, 4 + 3 * 4) // header + 3 Int32

        // Verify each encoding's raw value is correctly serialized as big-endian Int32
        // raw = 0 -> [0,0,0,0]
        XCTAssertEqual(data[4], 0)
        XCTAssertEqual(data[5], 0)
        XCTAssertEqual(data[6], 0)
        XCTAssertEqual(data[7], 0)

        // copyRect = 1 -> [0,0,0,1]
        XCTAssertEqual(data[8], 0)
        XCTAssertEqual(data[9], 0)
        XCTAssertEqual(data[10], 0)
        XCTAssertEqual(data[11], 1)

        // zrle = 16 -> [0,0,0,16]
        XCTAssertEqual(data[12], 0)
        XCTAssertEqual(data[13], 0)
        XCTAssertEqual(data[14], 0)
        XCTAssertEqual(data[15], 16)
    }

    func testWriteSetEncodingsEmpty() {
        let data = MessageWriter.writeSetEncodings([])
        XCTAssertEqual(data.count, 4)
        XCTAssertEqual(data[0], 2) // message type
        XCTAssertEqual(data[2], 0)
        XCTAssertEqual(data[3], 0) // count = 0
    }

    func testWriteSetEncodingsWithNegativeRawValues() {
        // Pseudo-encodings have negative raw values
        let encodings: [Encoding] = [.cursor] // raw = -239
        let data = MessageWriter.writeSetEncodings(encodings)
        XCTAssertEqual(data.count, 8)

        // -239 as Int32 bit pattern -> UInt32(bitPattern: -239) = 0xFFFFFF11
        let raw = UInt32(bitPattern: Int32(-239))
        XCTAssertEqual(data[4], UInt8((raw >> 24) & 0xFF))
        XCTAssertEqual(data[5], UInt8((raw >> 16) & 0xFF))
        XCTAssertEqual(data[6], UInt8((raw >> 8) & 0xFF))
        XCTAssertEqual(data[7], UInt8(raw & 0xFF))
    }

    // MARK: - FramebufferUpdateRequest (type 3)

    func testWriteFramebufferUpdateRequest() {
        let data = MessageWriter.writeFramebufferUpdateRequest(
            incremental: true, x: 0, y: 0, width: 1920, height: 1080
        )
        XCTAssertEqual(data.count, 10)
        XCTAssertEqual(data[0], 3)  // message type
        XCTAssertEqual(data[1], 1)  // incremental = true

        // x = 0 -> [0, 0]
        XCTAssertEqual(data[2], 0)
        XCTAssertEqual(data[3], 0)

        // y = 0 -> [0, 0]
        XCTAssertEqual(data[4], 0)
        XCTAssertEqual(data[5], 0)

        // width = 1920 = 0x0780
        XCTAssertEqual(data[6], 0x07)
        XCTAssertEqual(data[7], 0x80)

        // height = 1080 = 0x0438
        XCTAssertEqual(data[8], 0x04)
        XCTAssertEqual(data[9], 0x38)
    }

    func testWriteFramebufferUpdateRequestNonIncremental() {
        let data = MessageWriter.writeFramebufferUpdateRequest(
            incremental: false, x: 100, y: 200, width: 640, height: 480
        )
        XCTAssertEqual(data[0], 3)
        XCTAssertEqual(data[1], 0) // incremental = false
    }

    // MARK: - Apple AutoFrameBufferUpdate (type 9)

    func testWriteAppleAutoFramebufferUpdate() {
        let data = MessageWriter.writeAppleAutoFramebufferUpdate(
            intervalMilliseconds: 33,
            x: 0, y: 0, width: 2976, height: 1860)

        XCTAssertEqual(data, Data([
            0x09, 0x00, 0x00, 0x01,
            0x00, 0x00, 0x00, 0x21,
            0x00, 0x00, 0x00, 0x00,
            0x0b, 0xa0, 0x07, 0x44,
        ]))
    }

    func testWriteAppleAutoFramebufferUpdateDisableSentinel() {
        let data = ClientMessage.appleAutoFramebufferUpdate(
            intervalMilliseconds: -1,
            x: 1, y: 2, width: 3, height: 4).serialize()

        XCTAssertEqual(data[0], 9)
        XCTAssertEqual(Data(data[4..<8]), Data([0xff, 0xff, 0xff, 0xff]))
        XCTAssertEqual(Data(data[8..<16]), Data([
            0x00, 0x01, 0x00, 0x02, 0x00, 0x03, 0x00, 0x04,
        ]))
    }

    // MARK: - KeyEvent (type 4)

    func testWriteKeyEventDown() {
        let data = MessageWriter.writeKeyEvent(downFlag: true, key: 0xFF0D) // Return
        XCTAssertEqual(data.count, 8)
        XCTAssertEqual(data[0], 4)  // message type
        XCTAssertEqual(data[1], 1)  // down-flag = true
        XCTAssertEqual(data[2], 0)  // padding
        XCTAssertEqual(data[3], 0)

        // key = 0x0000FF0D
        XCTAssertEqual(data[4], 0x00)
        XCTAssertEqual(data[5], 0x00)
        XCTAssertEqual(data[6], 0xFF)
        XCTAssertEqual(data[7], 0x0D)
    }

    func testWriteKeyEventUp() {
        let data = MessageWriter.writeKeyEvent(downFlag: false, key: 0x0061) // 'a'
        XCTAssertEqual(data[0], 4)
        XCTAssertEqual(data[1], 0) // down-flag = false
        XCTAssertEqual(data[4], 0x00)
        XCTAssertEqual(data[5], 0x00)
        XCTAssertEqual(data[6], 0x00)
        XCTAssertEqual(data[7], 0x61)
    }

    // MARK: - PointerEvent (type 5)

    func testWritePointerEvent() {
        let data = MessageWriter.writePointerEvent(buttonMask: 0x01, x: 500, y: 300)
        XCTAssertEqual(data.count, 6)
        XCTAssertEqual(data[0], 5)    // message type
        XCTAssertEqual(data[1], 0x01) // button mask (left button)

        // x = 500 = 0x01F4
        XCTAssertEqual(data[2], 0x01)
        XCTAssertEqual(data[3], 0xF4)

        // y = 300 = 0x012C
        XCTAssertEqual(data[4], 0x01)
        XCTAssertEqual(data[5], 0x2C)
    }

    func testWritePointerEventNoButtons() {
        let data = MessageWriter.writePointerEvent(buttonMask: 0, x: 0, y: 0)
        XCTAssertEqual(data[0], 5)
        XCTAssertEqual(data[1], 0)
    }

    func testWriteStandardSetDesktopSize() {
        let request = SetDesktopSizeRequest(
            width: 2732,
            height: 2048,
            screens: [SetDesktopSizeScreen(
                id: 0x0102_0304,
                width: 2732,
                height: 2048,
                flags: 0xaabb_ccdd)])

        XCTAssertEqual(MessageWriter.writeSetDesktopSize(request), Data([
            0xfb, 0x00, 0x0a, 0xac, 0x08, 0x00, 0x01, 0x00,
            0x01, 0x02, 0x03, 0x04,
            0x00, 0x00, 0x00, 0x00,
            0x0a, 0xac, 0x08, 0x00,
            0xaa, 0xbb, 0xcc, 0xdd,
        ]))
    }

    func testWriteAppleDisplayConfigurationUsesTypedNativeLayout() {
        let mode = AppleVirtualDisplayMode(
            pixelWidth: 2732,
            pixelHeight: 2048,
            pointWidth: 1366,
            pointHeight: 1024,
            refreshRate: 60,
            flags: 0x1122_3344)
        let display = AppleVirtualDisplay(
            name: "iPad",
            widthInMillimeters: 123.5,
            heightInMillimeters: 45.25,
            maximumPixelWidth: 3840,
            maximumPixelHeight: 2160,
            originX: 5,
            originY: 6,
            identifier: 7,
            modes: [mode])

        let data = MessageWriter.writeAppleDisplayConfiguration(
            AppleDisplayConfiguration(displays: [display]))

        // Command header: type 29, payload bytes after the first four bytes,
        // version 1, one display, and a reserved zero word.
        XCTAssertEqual(data.count, 196)
        XCTAssertEqual(Data(data[0..<12]), Data([
            0x1d, 0x00, 0x00, 0xc0,
            0x00, 0x01, 0x00, 0x01,
            0x00, 0x00, 0x00, 0x00,
        ]))

        // Fixed display record encoded field-for-field in command wire order.
        // The name occupies a zero-padded 120-byte field.
        XCTAssertEqual(Data(data[12..<14]), Data([0x00, 0xb8]))
        XCTAssertEqual(Data(data[14..<19]), Data([0x69, 0x50, 0x61, 0x64, 0x00]))
        XCTAssertEqual(Data(data[134..<142]), Data([
            0x00, 0x00, 0x00, 0x01,
            0x00, 0x00, 0x00, 0x00,
        ]))
        XCTAssertEqual(Data(data[142..<150]), Data([
            0x42, 0xf7, 0x00, 0x00,
            0x42, 0x35, 0x00, 0x00,
        ]))
        XCTAssertEqual(Data(data[150..<168]), Data([
            0x00, 0x00, 0x0f, 0x00,
            0x00, 0x00, 0x08, 0x70,
            0x00, 0x05, 0x00, 0x06,
            0x00, 0x00, 0x00, 0x07,
            0x00, 0x01,
        ]))

        // One 28-byte HiDPI mode: pixels, points, IEEE-754 refresh rate,
        // then flags, all in network byte order.
        XCTAssertEqual(Data(data[168..<196]), Data([
            0x00, 0x00, 0x0a, 0xac,
            0x00, 0x00, 0x08, 0x00,
            0x00, 0x00, 0x05, 0x56,
            0x00, 0x00, 0x04, 0x00,
            0x40, 0x4e, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x11, 0x22, 0x33, 0x44,
        ]))
    }

    func testWriteApplePreciseScrollEvent() {
        let event = AppleScrollEvent(
            deltaX: 0x1234,
            deltaY: -2,
            deltaZ: Int16.min,
            fixedDeltaX: 0x01020304,
            fixedDeltaY: -2,
            fixedDeltaZ: Int32.min,
            pointDeltaX: 0x11223344,
            pointDeltaY: -3,
            pointDeltaZ: Int32.max,
            scrollPhase: .changed,
            momentumPhase: .ended,
            scrollCount: 0x01020304,
            flags: [.instantMouser, .continuous],
            x: 0xabcd,
            y: 0x1234)

        XCTAssertEqual(MessageWriter.writeAppleScrollEvent(event), Data([
            0x17, 0x00, 0x00, 0x36, 0x00, 0x01, 0x00, 0x0b,
            0x12, 0x34, 0xff, 0xfe, 0x80, 0x00,
            0x01, 0x02, 0x03, 0x04,
            0xff, 0xff, 0xff, 0xfe,
            0x80, 0x00, 0x00, 0x00,
            0x11, 0x22, 0x33, 0x44,
            0xff, 0xff, 0xff, 0xfd,
            0x7f, 0xff, 0xff, 0xff,
            0x00, 0x00, 0x00, 0x02,
            0x00, 0x00, 0x00, 0x03,
            0x01, 0x02, 0x03, 0x04,
            0x00, 0x00, 0x00, 0x03,
            0xab, 0xcd, 0x12, 0x34,
        ]))
    }

    func testWriteAppleGestureScrollEventMatchesNativeSubtypeEightLayout() {
        let event = AppleGestureScrollEvent(
            deltaX: 1.5,
            deltaY: -2.25,
            deltaZ: 0.5,
            naturalScrolling: true,
            gesturePhase: .changed,
            x: 0xabcd,
            y: 0x1234)

        XCTAssertEqual(MessageWriter.writeAppleGestureScrollEvent(event), Data([
            0x17, 0x00, 0x00, 0x20, 0x00, 0x01, 0x00, 0x08,
            0x3f, 0xc0, 0x00, 0x00,
            0xc0, 0x10, 0x00, 0x00,
            0x3f, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x01,
            0x00, 0x00, 0x00, 0x02,
            0xe0, 0x1c, 0x00, 0x00,
            0xab, 0xcd, 0x12, 0x34,
        ]))
    }

    func testAppleScrollPhaseValuesMatchMeasuredCGEventFields() {
        XCTAssertEqual(AppleScrollEvent.Phase.began.rawValue, 1)
        XCTAssertEqual(AppleScrollEvent.Phase.changed.rawValue, 2)
        XCTAssertEqual(AppleScrollEvent.Phase.ended.rawValue, 4)
        XCTAssertEqual(AppleScrollEvent.Phase.cancelled.rawValue, 8)
        XCTAssertEqual(AppleScrollEvent.Phase.mayBegin.rawValue, 128)
        XCTAssertEqual(AppleScrollEvent.MomentumPhase.began.rawValue, 1)
        XCTAssertEqual(AppleScrollEvent.MomentumPhase.changed.rawValue, 2)
        XCTAssertEqual(AppleScrollEvent.MomentumPhase.ended.rawValue, 3)
    }

    func testWriteAppleGestureEnvelopeMatchesScreenSharing() {
        let begin = AppleGestureEvent(
            kind: .began,
            x: 0x1234,
            y: 0x5678)
        let end = AppleGestureEvent(
            kind: .ended,
            x: 0x1234,
            y: 0x5678)

        XCTAssertEqual(MessageWriter.writeAppleGestureEvent(begin), Data([
            0x17, 0x00, 0x00, 0x0c,
            0x00, 0x01, 0x00, 0x01,
            0x00, 0x00, 0x00, 0x03,
            0x12, 0x34, 0x56, 0x78,
        ]))
        XCTAssertEqual(MessageWriter.writeAppleGestureEvent(end), Data([
            0x17, 0x00, 0x00, 0x0c,
            0x00, 0x01, 0x00, 0x02,
            0x00, 0x00, 0x00, 0x03,
            0x12, 0x34, 0x56, 0x78,
        ]))
    }

    // MARK: - ClientCutText (type 6)

    func testWriteClientCutText() {
        let text = "Hello"
        let data = MessageWriter.writeClientCutText(text)
        XCTAssertEqual(data[0], 6) // message type
        XCTAssertEqual(data[1], 0) // padding
        XCTAssertEqual(data[2], 0)
        XCTAssertEqual(data[3], 0)

        // length = 5 as UInt32 big-endian
        XCTAssertEqual(data[4], 0)
        XCTAssertEqual(data[5], 0)
        XCTAssertEqual(data[6], 0)
        XCTAssertEqual(data[7], 5)

        // text bytes
        XCTAssertEqual(data.count, 8 + 5)
        XCTAssertEqual(String(data: Data(data[8..<13]), encoding: .utf8), "Hello")
    }

    func testWriteClientCutTextEmpty() {
        let data = MessageWriter.writeClientCutText("")
        XCTAssertEqual(data.count, 8)
        XCTAssertEqual(data[4], 0)
        XCTAssertEqual(data[5], 0)
        XCTAssertEqual(data[6], 0)
        XCTAssertEqual(data[7], 0)
    }

    // MARK: - Handshake messages

    func testWriteProtocolVersion() {
        let data = MessageWriter.writeProtocolVersion(.v3_8)
        XCTAssertEqual(data.count, 12)
        XCTAssertEqual(String(data: data, encoding: .ascii), "RFB 003.008\n")
    }

    func testWriteSecurityType() {
        let data = MessageWriter.writeSecurityType(.vncAuthentication)
        XCTAssertEqual(data.count, 1)
        XCTAssertEqual(data[0], 2)
    }
}

// MARK: - ClientMessage Tests

final class ClientMessageTests: XCTestCase {

    func testMessageTypeIDs() {
        XCTAssertEqual(ClientMessage.setPixelFormat(.bgra8888).messageType, 0)
        XCTAssertEqual(ClientMessage.setEncodings([.raw]).messageType, 2)
        XCTAssertEqual(ClientMessage.framebufferUpdateRequest(incremental: true, x: 0, y: 0, width: 100, height: 100).messageType, 3)
        XCTAssertEqual(ClientMessage.keyEvent(downFlag: true, key: 0x41).messageType, 4)
        XCTAssertEqual(ClientMessage.pointerEvent(buttonMask: 0, x: 0, y: 0).messageType, 5)
        XCTAssertEqual(ClientMessage.clientCutText("hi").messageType, 6)
        XCTAssertEqual(
            ClientMessage.appleScrollEvent(
                AppleScrollEvent(x: 0, y: 0)).messageType,
            0x17)
        XCTAssertEqual(
            ClientMessage.appleGestureEvent(
                AppleGestureEvent(kind: .began, x: 0, y: 0)).messageType,
            0x17)
    }

    func testSerializeSetPixelFormat() {
        let msg = ClientMessage.setPixelFormat(.bgra8888)
        let data = msg.serialize()
        XCTAssertEqual(data.count, 20)
        XCTAssertEqual(data[0], 0)
    }

    func testSerializeSetEncodings() {
        let msg = ClientMessage.setEncodings([.raw, .zrle])
        let data = msg.serialize()
        XCTAssertEqual(data[0], 2)
        XCTAssertEqual(data.count, 4 + 2 * 4)
    }

    func testSerializeFramebufferUpdateRequest() {
        let msg = ClientMessage.framebufferUpdateRequest(incremental: false, x: 10, y: 20, width: 640, height: 480)
        let data = msg.serialize()
        XCTAssertEqual(data.count, 10)
        XCTAssertEqual(data[0], 3)
        XCTAssertEqual(data[1], 0) // non-incremental
    }

    func testSerializeKeyEvent() {
        let msg = ClientMessage.keyEvent(downFlag: true, key: 0x0041) // 'A'
        let data = msg.serialize()
        XCTAssertEqual(data.count, 8)
        XCTAssertEqual(data[0], 4)
        XCTAssertEqual(data[1], 1)
    }

    func testSerializePointerEvent() {
        let msg = ClientMessage.pointerEvent(buttonMask: 0x01, x: 100, y: 200)
        let data = msg.serialize()
        XCTAssertEqual(data.count, 6)
        XCTAssertEqual(data[0], 5)
        XCTAssertEqual(data[1], 0x01)
    }

    func testSerializeClientCutText() {
        let msg = ClientMessage.clientCutText("test")
        let data = msg.serialize()
        XCTAssertEqual(data[0], 6)
        XCTAssertEqual(data.count, 8 + 4)
    }

    func testEquatable() {
        let a = ClientMessage.keyEvent(downFlag: true, key: 65)
        let b = ClientMessage.keyEvent(downFlag: true, key: 65)
        let c = ClientMessage.keyEvent(downFlag: false, key: 65)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }
}

// MARK: - Encoding Tests

final class EncodingTests: XCTestCase {

    func testStandardEncodingRawValues() {
        XCTAssertEqual(Encoding.raw.rawValue, 0)
        XCTAssertEqual(Encoding.copyRect.rawValue, 1)
        XCTAssertEqual(Encoding.rre.rawValue, 2)
        XCTAssertEqual(Encoding.hextile.rawValue, 5)
        XCTAssertEqual(Encoding.zlib.rawValue, 6)
        XCTAssertEqual(Encoding.tight.rawValue, 7)
        XCTAssertEqual(Encoding.zlibhex.rawValue, 8)
        XCTAssertEqual(Encoding.zrle.rawValue, 16)
    }

    func testPseudoEncodingRawValues() {
        XCTAssertEqual(Encoding.cursor.rawValue, -239)
        XCTAssertEqual(Encoding.xCursor.rawValue, -240)
        XCTAssertEqual(Encoding.lastRect.rawValue, -224)
        XCTAssertEqual(Encoding.desktopSize.rawValue, -223)
        XCTAssertEqual(Encoding.extendedDesktopSize.rawValue, -308)
    }

    func testAppleEncodingRawValues() {
        XCTAssertEqual(Encoding.appleJPEG.rawValue, -1000)
        XCTAssertEqual(Encoding.apple1.rawValue, -261)
        XCTAssertEqual(Encoding.appleSubZlibThousands.rawValue, 1002)
        XCTAssertEqual(Encoding.appleH264.rawValue, 1010)
        XCTAssertEqual(Encoding.appleMultiVariantScreenshare.rawValue, 1011)
        XCTAssertEqual(Encoding.encryptionInfo.rawValue, -267)
        XCTAssertEqual(Encoding.serverDisplayInfo.rawValue, -300)
        XCTAssertEqual(Encoding.mediaStreamOffer.rawValue, 1103)
        XCTAssertEqual(Encoding.mediaStreamAnswer.rawValue, -302)
    }

    func testInitFromRawValue() {
        XCTAssertEqual(Encoding(rawValue: 0), .raw)
        XCTAssertEqual(Encoding(rawValue: 1), .copyRect)
        XCTAssertEqual(Encoding(rawValue: 16), .zrle)
        XCTAssertEqual(Encoding(rawValue: -239), .cursor)
        XCTAssertEqual(Encoding(rawValue: -240), .xCursor)
        XCTAssertEqual(Encoding(rawValue: -224), .lastRect)
        XCTAssertEqual(Encoding(rawValue: 1002), .appleSubZlibThousands)
        XCTAssertEqual(Encoding(rawValue: 1010), .appleH264)
        XCTAssertEqual(Encoding(rawValue: 1011), .appleMultiVariantScreenshare)
        XCTAssertEqual(Encoding(rawValue: 1103), .mediaStreamOffer)
        XCTAssertEqual(Encoding(rawValue: -301), .mediaStreamOffer)
    }

    func testUnknownEncoding() {
        let enc = Encoding(rawValue: 999)
        XCTAssertEqual(enc, .unknown(999))
        XCTAssertEqual(enc.rawValue, 999)
    }

    func testIsPseudo() {
        XCTAssertFalse(Encoding.raw.isPseudo)
        XCTAssertFalse(Encoding.zrle.isPseudo)
        XCTAssertTrue(Encoding.cursor.isPseudo)
        XCTAssertTrue(Encoding.xCursor.isPseudo)
        XCTAssertTrue(Encoding.desktopSize.isPseudo)
        XCTAssertFalse(Encoding.appleH264.isPseudo)
        XCTAssertTrue(Encoding.encryptionInfo.isPseudo)
    }

    func testRoundTripThroughRawValue() {
        let allKnown: [Encoding] = [
            .raw, .copyRect, .rre, .hextile, .zlib, .tight, .zlibhex, .zrle,
            .cursor, .xCursor, .desktopSize, .extendedDesktopSize,
            .appleJPEG, .apple1, .appleSubZlibThousands, .appleH264, .appleMultiVariantScreenshare,
            .encryptionInfo, .serverDisplayInfo, .mediaStreamOffer, .mediaStreamAnswer,
        ]
        for enc in allKnown {
            let recreated = Encoding(rawValue: enc.rawValue)
            XCTAssertEqual(recreated, enc, "Round-trip failed for encoding \(enc)")
        }
    }
}

// MARK: - ConnectionStateMachine Tests

final class ConnectionStateMachineTests: XCTestCase {

    // MARK: - Helper

    private func makeTestServerInit() -> ServerInit {
        ServerInit(
            framebufferWidth: 1920,
            framebufferHeight: 1080,
            pixelFormat: .bgra8888,
            name: "Test Server"
        )
    }

    // MARK: - Full handshake flow (v3.8 with VNC auth)

    func testFullHandshakeFlow() {
        var sm = ConnectionStateMachine()
        XCTAssertEqual(sm.state, .idle)

        // idle -> waitingForProtocolVersion
        let a1 = sm.handle(event: .connected)
        XCTAssertEqual(sm.state, .waitingForProtocolVersion)
        XCTAssertTrue(a1.isEmpty)

        // waitingForProtocolVersion -> waitingForSecurityTypes
        let a2 = sm.handle(event: .receivedProtocolVersion(.v3_8))
        XCTAssertEqual(sm.state, .waitingForSecurityTypes)
        XCTAssertEqual(sm.negotiatedVersion, .v3_8)
        XCTAssertEqual(a2.count, 1)
        if case .sendProtocolVersion(let v) = a2.first {
            XCTAssertEqual(v, .v3_8)
        } else {
            XCTFail("Expected sendProtocolVersion action")
        }

        // waitingForSecurityTypes -> authenticating (VNC Auth selected)
        let a3 = sm.handle(event: .receivedSecurityTypes([.none, .vncAuthentication]))
        // Should select vncAuthentication since it has higher priority than none
        XCTAssertEqual(sm.selectedSecurityType, .vncAuthentication)
        if case .authenticating(let secType) = sm.state {
            XCTAssertEqual(secType, .vncAuthentication)
        } else {
            XCTFail("Expected authenticating state, got \(sm.state)")
        }
        XCTAssertEqual(a3.count, 1)
        if case .sendSecurityType(let st) = a3.first {
            XCTAssertEqual(st, .vncAuthentication)
        } else {
            XCTFail("Expected sendSecurityType action")
        }

        // authenticating -> receive challenge
        let challenge = Data(repeating: 0xAB, count: 16)
        let a4 = sm.handle(event: .receivedAuthChallenge(challenge))
        XCTAssertEqual(a4.count, 1)
        if case .performAuthentication(let secType, let ch) = a4.first {
            XCTAssertEqual(secType, .vncAuthentication)
            XCTAssertEqual(ch, challenge)
        } else {
            XCTFail("Expected performAuthentication action")
        }

        // authenticating -> waitingForServerInit
        let a5 = sm.handle(event: .authenticationSucceeded)
        XCTAssertEqual(sm.state, .waitingForServerInit)
        XCTAssertEqual(a5.count, 1)
        if case .requestServerInit = a5.first {
            // good
        } else {
            XCTFail("Expected requestServerInit action")
        }

        // waitingForServerInit -> operational
        let si = makeTestServerInit()
        let a6 = sm.handle(event: .receivedServerInit(si))
        XCTAssertEqual(sm.state, .operational)
        XCTAssertEqual(sm.serverInit, si)
        // Should have 3 actions: setPixelFormat, setEncodings, fbUpdateRequest
        XCTAssertEqual(a6.count, 3)
    }

    // MARK: - connecting -> waitingForProtocolVersion

    func testConnectingToWaitingForVersion() {
        var sm = ConnectionStateMachine()
        sm.beginConnecting()
        XCTAssertEqual(sm.state, .connecting)

        let actions = sm.handle(event: .connected)
        XCTAssertEqual(sm.state, .waitingForProtocolVersion)
        XCTAssertTrue(actions.isEmpty)
    }

    // MARK: - Apple version echo

    func testAppleVersionEcho() {
        var sm = ConnectionStateMachine()
        _ = sm.handle(event: .connected)

        let actions = sm.handle(event: .receivedProtocolVersion(.apple))
        XCTAssertEqual(sm.negotiatedVersion, .apple)
        if case .sendProtocolVersion(let v) = actions.first {
            XCTAssertEqual(v, .apple)
        } else {
            XCTFail("Expected sendProtocolVersion with apple version")
        }
    }

    // MARK: - Handshake fact recording

    func testHandshakeFactsRecordedOnStandardPath() {
        var sm = ConnectionStateMachine()
        _ = sm.handle(event: .connected)
        _ = sm.handle(event: .receivedProtocolVersion(.v3_8))
        XCTAssertEqual(sm.serverReportedVersion, .v3_8)
        XCTAssertEqual(sm.negotiatedVersion, .v3_8)

        _ = sm.handle(event: .receivedSecurityTypes([.none, .vncAuthentication]))
        XCTAssertEqual(sm.offeredSecurityTypes, [.none, .vncAuthentication])
        XCTAssertEqual(sm.selectedSecurityType, .vncAuthentication)
    }

    func testHandshakeFactsRecordServerReportedVersionAboveNegotiated() {
        var sm = ConnectionStateMachine()
        _ = sm.handle(event: .connected)

        let futureVersion = ProtocolVersion(major: 4, minor: 1)
        _ = sm.handle(event: .receivedProtocolVersion(futureVersion))
        XCTAssertEqual(sm.serverReportedVersion, futureVersion)
        XCTAssertEqual(sm.negotiatedVersion, .v3_8)
    }

    func testHandshakeFactsRecordedOnServerSelectedPath() {
        var sm = ConnectionStateMachine()
        _ = sm.handle(event: .connected)
        _ = sm.handle(event: .receivedProtocolVersion(.v3_3))
        XCTAssertEqual(sm.serverReportedVersion, .v3_3)

        _ = sm.handle(event: .receivedServerSelectedSecurityType(.vncAuthentication))
        XCTAssertEqual(sm.offeredSecurityTypes, [.vncAuthentication])
        XCTAssertEqual(sm.selectedSecurityType, .vncAuthentication)
    }

    func testHandshakeFactsRecordedOnAppleEchoPath() {
        var sm = ConnectionStateMachine()
        _ = sm.handle(event: .connected)
        _ = sm.handle(event: .receivedProtocolVersion(.apple))
        XCTAssertEqual(sm.serverReportedVersion, .apple)
        XCTAssertEqual(sm.negotiatedVersion, .apple)
    }

    func testOfferedTypesRecordedEvenWhenSelectionFails() {
        var sm = ConnectionStateMachine(securityPolicy: .requireEncryption)
        _ = sm.handle(event: .connected)
        _ = sm.handle(event: .receivedProtocolVersion(.v3_8))
        _ = sm.handle(event: .receivedSecurityTypes([.vncAuthentication]))
        XCTAssertEqual(sm.offeredSecurityTypes, [.vncAuthentication])
        XCTAssertNil(sm.selectedSecurityType)
        if case .failed = sm.state {} else {
            XCTFail("Expected failed state, got \(sm.state)")
        }
    }

    // MARK: - Version negotiation

    func testNegotiateDown_v3_7() {
        var sm = ConnectionStateMachine()
        _ = sm.handle(event: .connected)

        let actions = sm.handle(event: .receivedProtocolVersion(.v3_7))
        XCTAssertEqual(sm.negotiatedVersion, .v3_7)
        if case .sendProtocolVersion(let v) = actions.first {
            XCTAssertEqual(v, .v3_7)
        } else {
            XCTFail("Expected sendProtocolVersion")
        }
    }

    func testNegotiateDown_v3_3() {
        var sm = ConnectionStateMachine()
        _ = sm.handle(event: .connected)

        let actions = sm.handle(event: .receivedProtocolVersion(.v3_3))
        XCTAssertEqual(sm.negotiatedVersion, .v3_3)
        if case .sendProtocolVersion(let v) = actions.first {
            XCTAssertEqual(v, .v3_3)
        } else {
            XCTFail("Expected sendProtocolVersion")
        }
    }

    func testUnsupportedVersionFails() {
        var sm = ConnectionStateMachine()
        _ = sm.handle(event: .connected)

        // Version 2.0 is below 3.3
        let oldVersion = ProtocolVersion(major: 2, minor: 0)
        let actions = sm.handle(event: .receivedProtocolVersion(oldVersion))
        if case .failed(let error) = sm.state {
            XCTAssertEqual(error, .unsupportedVersion)
        } else {
            XCTFail("Expected failed state")
        }
        XCTAssertEqual(actions.count, 1)
        if case .reportError(.unsupportedVersion) = actions.first {
            // good
        } else {
            XCTFail("Expected reportError(.unsupportedVersion)")
        }
    }

    // MARK: - Security type: none (v3.8 still waits for auth result)

    func testSecurityNone_v3_8() {
        var sm = ConnectionStateMachine()
        _ = sm.handle(event: .connected)
        _ = sm.handle(event: .receivedProtocolVersion(.v3_8))

        let actions = sm.handle(event: .receivedSecurityTypes([.none]))
        XCTAssertEqual(sm.selectedSecurityType, SecurityType.none)
        XCTAssertEqual(sm.state, .waitingForAuthResult)
        XCTAssertEqual(actions.count, 1)
        if case .sendSecurityType(.none) = actions.first {
            // good
        } else {
            XCTFail("Expected sendSecurityType(.none)")
        }
    }

    func testSecurityNone_v3_3() {
        var sm = ConnectionStateMachine()
        _ = sm.handle(event: .connected)
        _ = sm.handle(event: .receivedProtocolVersion(.v3_3))

        let actions = sm.handle(event: .receivedServerSelectedSecurityType(.none))
        XCTAssertEqual(sm.selectedSecurityType, SecurityType.none)
        XCTAssertEqual(sm.state, .waitingForServerInit)
        // In RFB 3.3 the server chooses the type. The client must not echo a
        // selection byte because that byte would be parsed as ClientInit.
        XCTAssertEqual(actions.count, 1)
        guard case .requestServerInit = actions.first else {
            return XCTFail("Expected requestServerInit without a security selection")
        }
    }

    func testAutomaticSecurityPrefersPortableVNCAuthOnConventionalServer() {
        var sm = ConnectionStateMachine()
        _ = sm.handle(event: .connected)
        _ = sm.handle(event: .receivedProtocolVersion(.v3_8))

        let actions = sm.handle(event: .receivedSecurityTypes([
            .vencrypt, .vncAuthentication, .none,
        ]))
        XCTAssertEqual(sm.selectedSecurityType, .vncAuthentication)
        XCTAssertEqual(actions.count, 1)
        guard case .sendSecurityType(.vncAuthentication) = actions.first else {
            return XCTFail("Expected portable VNC authentication")
        }
    }

    func testAutomaticSecurityKeepsMacAuthenticationWhenAppleSRPIsAlsoOffered() {
        var sm = ConnectionStateMachine(hasUsername: true)
        _ = sm.handle(event: .connected)
        _ = sm.handle(event: .receivedProtocolVersion(.apple))

        _ = sm.handle(event: .receivedSecurityTypes([.apple30, .macAuthentication, .appleSRP]))
        XCTAssertEqual(sm.selectedSecurityType, .macAuthentication)
    }

    func testAutomaticSecuritySelectsAppleSRPWhenItIsTheOnlyAppleType() {
        var sm = ConnectionStateMachine(hasUsername: true)
        _ = sm.handle(event: .connected)
        _ = sm.handle(event: .receivedProtocolVersion(.apple))

        let actions = sm.handle(event: .receivedSecurityTypes([.appleSRP]))
        XCTAssertEqual(sm.selectedSecurityType, .appleSRP)
        guard case .sendSecurityType(.appleSRP) = actions.first else {
            return XCTFail("Expected Apple SRP")
        }
    }

    func testAppleSRPOnlyServerWithoutUsernameAsksForOne() {
        var sm = ConnectionStateMachine()
        _ = sm.handle(event: .connected)
        _ = sm.handle(event: .receivedProtocolVersion(.apple))

        let actions = sm.handle(event: .receivedSecurityTypes([.appleSRP]))
        XCTAssertNil(sm.selectedSecurityType)
        guard case .reportError(.authenticationFailed(let reason)) = actions.first else {
            return XCTFail("Expected an authentication error")
        }
        XCTAssertEqual(reason, "This server requires a user name and password")
    }

    func testRequireEncryptionSelectsVeNCrypt() {
        var sm = ConnectionStateMachine(securityPolicy: .requireEncryption)
        _ = sm.handle(event: .connected)
        _ = sm.handle(event: .receivedProtocolVersion(.v3_8))

        let actions = sm.handle(event: .receivedSecurityTypes([
            .vncAuthentication, .vencrypt,
        ]))
        XCTAssertEqual(sm.selectedSecurityType, .vencrypt)
        XCTAssertEqual(actions.count, 1)
        guard case .sendSecurityType(.vencrypt) = actions.first else {
            return XCTFail("Expected VeNCrypt")
        }
    }

    func testRequireEncryptionRejectsUnencryptedRFB33ServerSelection() {
        for selected in [SecurityType.none, .vncAuthentication] {
            var sm = ConnectionStateMachine(securityPolicy: .requireEncryption)
            _ = sm.handle(event: .connected)
            _ = sm.handle(event: .receivedProtocolVersion(.v3_3))

            let actions = sm.handle(
                event: .receivedServerSelectedSecurityType(selected))
            XCTAssertNil(sm.selectedSecurityType)
            guard case .failed(.authenticationFailed) = sm.state else {
                return XCTFail("Expected requireEncryption to reject \(selected)")
            }
            XCTAssertEqual(actions.count, 1)
            guard case .reportError(.authenticationFailed) = actions.first else {
                return XCTFail("Expected an authentication policy error")
            }
        }
    }

    func testRequireEncryptionAcceptsVeNCryptRFB33ServerSelection() {
        var sm = ConnectionStateMachine(securityPolicy: .requireEncryption)
        _ = sm.handle(event: .connected)
        _ = sm.handle(event: .receivedProtocolVersion(.v3_3))

        let actions = sm.handle(
            event: .receivedServerSelectedSecurityType(.vencrypt))
        XCTAssertEqual(sm.selectedSecurityType, .vencrypt)
        XCTAssertEqual(sm.state, .authenticating(.vencrypt))
        XCTAssertTrue(actions.isEmpty)
    }

    // MARK: - Empty security types -> failure

    func testEmptySecurityTypesFails() {
        var sm = ConnectionStateMachine()
        _ = sm.handle(event: .connected)
        _ = sm.handle(event: .receivedProtocolVersion(.v3_8))

        let actions = sm.handle(event: .receivedSecurityTypes([]))
        if case .failed = sm.state {
            // good
        } else {
            XCTFail("Expected failed state")
        }
        XCTAssertEqual(actions.count, 1)
    }

    // MARK: - Auth failure

    func testAuthFailure() {
        var sm = ConnectionStateMachine()
        _ = sm.handle(event: .connected)
        _ = sm.handle(event: .receivedProtocolVersion(.v3_8))
        _ = sm.handle(event: .receivedSecurityTypes([.vncAuthentication]))

        let actions = sm.handle(event: .authenticationFailed("bad password"))
        if case .failed(let error) = sm.state {
            if case .authenticationFailed(let reason) = error {
                XCTAssertEqual(reason, "bad password")
            } else {
                XCTFail("Expected authenticationFailed error")
            }
        } else {
            XCTFail("Expected failed state")
        }
        XCTAssertEqual(actions.count, 1)
    }

    func testAuthFailureFromWaitingForAuthResult() {
        var sm = ConnectionStateMachine()
        _ = sm.handle(event: .connected)
        _ = sm.handle(event: .receivedProtocolVersion(.v3_8))
        _ = sm.handle(event: .receivedSecurityTypes([.none]))
        XCTAssertEqual(sm.state, .waitingForAuthResult)

        let actions = sm.handle(event: .authenticationFailed("denied"))
        if case .failed = sm.state {
            // good
        } else {
            XCTFail("Expected failed state")
        }
        XCTAssertEqual(actions.count, 1)
    }

    // MARK: - Connection lost

    func testConnectionLostFromAnyState() {
        var sm = ConnectionStateMachine()
        _ = sm.handle(event: .connected)
        _ = sm.handle(event: .receivedProtocolVersion(.v3_8))
        XCTAssertEqual(sm.state, .waitingForSecurityTypes)

        let actions = sm.handle(event: .connectionLost(.connectionClosed))
        if case .failed(let error) = sm.state {
            XCTAssertEqual(error, .connectionClosed)
        } else {
            XCTFail("Expected failed state")
        }
        XCTAssertEqual(actions.count, 1)
    }

    // MARK: - User disconnect

    func testUserDisconnect() {
        var sm = ConnectionStateMachine()
        _ = sm.handle(event: .connected)
        _ = sm.handle(event: .receivedProtocolVersion(.v3_8))

        let actions = sm.handle(event: .userRequestedDisconnect)
        XCTAssertEqual(sm.state, .disconnecting)
        XCTAssertEqual(actions.count, 1)
        if case .disconnect = actions.first {
            // good
        } else {
            XCTFail("Expected disconnect action")
        }
    }

    func testUserDisconnectFromOperational() {
        var sm = ConnectionStateMachine()
        _ = sm.handle(event: .connected)
        _ = sm.handle(event: .receivedProtocolVersion(.v3_8))
        _ = sm.handle(event: .receivedSecurityTypes([.none]))
        _ = sm.handle(event: .authenticationSucceeded)
        _ = sm.handle(event: .receivedServerInit(makeTestServerInit()))
        XCTAssertEqual(sm.state, .operational)

        let actions = sm.handle(event: .userRequestedDisconnect)
        XCTAssertEqual(sm.state, .disconnecting)
        if case .disconnect = actions.first {
            // good
        } else {
            XCTFail("Expected disconnect action")
        }
    }

    // MARK: - Operational events

    func testOperationalFramebufferUpdate() {
        var sm = ConnectionStateMachine()
        _ = sm.handle(event: .connected)
        _ = sm.handle(event: .receivedProtocolVersion(.v3_8))
        _ = sm.handle(event: .receivedSecurityTypes([.none]))
        _ = sm.handle(event: .authenticationSucceeded)
        _ = sm.handle(event: .receivedServerInit(makeTestServerInit()))
        XCTAssertEqual(sm.state, .operational)

        let rect = FramebufferRect(x: 0, y: 0, width: 100, height: 100, encoding: .raw)
        let actions = sm.handle(event: .receivedFramebufferUpdate([rect]))
        // Should have updateFramebuffer + sendFramebufferUpdateRequest
        XCTAssertEqual(actions.count, 2)
    }

    func testDesktopResizeChangesAllSubsequentUpdateRequestBounds() {
        var sm = ConnectionStateMachine()
        _ = sm.handle(event: .connected)
        _ = sm.handle(event: .receivedProtocolVersion(.v3_8))
        _ = sm.handle(event: .receivedSecurityTypes([.none]))
        _ = sm.handle(event: .authenticationSucceeded)
        _ = sm.handle(event: .receivedServerInit(makeTestServerInit()))

        let resize = FramebufferRect(
            x: 0, y: 0, width: 2560, height: 1440, encoding: .desktopSize)
        let resizeActions = sm.handle(event: .receivedFramebufferUpdate([resize]))
        XCTAssertEqual(sm.framebufferWidth, 2560)
        XCTAssertEqual(sm.framebufferHeight, 1440)
        guard case .sendFramebufferUpdateRequest(let incremental, let width, let height)
                = resizeActions.last else {
            return XCTFail("Expected update request after resize")
        }
        XCTAssertTrue(incremental)
        XCTAssertEqual(width, 2560)
        XCTAssertEqual(height, 1440)

        let raw = FramebufferRect(x: 0, y: 0, width: 10, height: 10, encoding: .raw)
        let nextActions = sm.handle(event: .receivedFramebufferUpdate([raw]))
        guard case .sendFramebufferUpdateRequest(_, let nextWidth, let nextHeight)
                = nextActions.last else {
            return XCTFail("Expected subsequent update request")
        }
        XCTAssertEqual(nextWidth, 2560)
        XCTAssertEqual(nextHeight, 1440)
    }

    func testExtensionGeometryChangesSubsequentUpdateRequestBounds() {
        var sm = ConnectionStateMachine()
        _ = sm.handle(event: .connected)
        _ = sm.handle(event: .receivedProtocolVersion(.v3_8))
        _ = sm.handle(event: .receivedSecurityTypes([.none]))
        _ = sm.handle(event: .authenticationSucceeded)
        _ = sm.handle(event: .receivedServerInit(ServerInit(
            framebufferWidth: 0,
            framebufferHeight: 0,
            pixelFormat: .bgra8888,
            name: "deferred")))

        sm.acceptFramebufferGeometry(
            width: 2560,
            height: 1440)
        let actions = sm.handle(event: .receivedFramebufferUpdate([]))

        XCTAssertEqual(sm.framebufferWidth, 2560)
        XCTAssertEqual(sm.framebufferHeight, 1440)
        guard case .sendFramebufferUpdateRequest(
            let incremental, let width, let height) = actions.last else {
            return XCTFail("Expected update request after extension geometry")
        }
        XCTAssertTrue(incremental)
        XCTAssertEqual(width, 2560)
        XCTAssertEqual(height, 1440)
    }

    func testRejectedExtendedDesktopResizeDoesNotChangeRequestBounds() {
        var sm = ConnectionStateMachine()
        _ = sm.handle(event: .connected)
        _ = sm.handle(event: .receivedProtocolVersion(.v3_8))
        _ = sm.handle(event: .receivedSecurityTypes([.none]))
        _ = sm.handle(event: .authenticationSucceeded)
        _ = sm.handle(event: .receivedServerInit(makeTestServerInit()))

        // ExtendedDesktopSize uses y as the response status; 1 is failure.
        let rejected = FramebufferRect(
            x: 1, y: 1, width: 2560, height: 1440, encoding: .extendedDesktopSize)
        let actions = sm.handle(event: .receivedFramebufferUpdate([rejected]))
        XCTAssertEqual(sm.framebufferWidth, 1920)
        XCTAssertEqual(sm.framebufferHeight, 1080)
        guard case .sendFramebufferUpdateRequest(_, let width, let height) = actions.last else {
            return XCTFail("Expected update request")
        }
        XCTAssertEqual(width, 1920)
        XCTAssertEqual(height, 1080)
    }

    func testOperationalBell() {
        var sm = ConnectionStateMachine()
        _ = sm.handle(event: .connected)
        _ = sm.handle(event: .receivedProtocolVersion(.v3_8))
        _ = sm.handle(event: .receivedSecurityTypes([.none]))
        _ = sm.handle(event: .authenticationSucceeded)
        _ = sm.handle(event: .receivedServerInit(makeTestServerInit()))

        let actions = sm.handle(event: .receivedBell)
        XCTAssertEqual(actions.count, 1)
        if case .notifyBell = actions.first {
            // good
        } else {
            XCTFail("Expected notifyBell action")
        }
    }

    func testOperationalClipboard() {
        var sm = ConnectionStateMachine()
        _ = sm.handle(event: .connected)
        _ = sm.handle(event: .receivedProtocolVersion(.v3_8))
        _ = sm.handle(event: .receivedSecurityTypes([.none]))
        _ = sm.handle(event: .authenticationSucceeded)
        _ = sm.handle(event: .receivedServerInit(makeTestServerInit()))

        let actions = sm.handle(event: .receivedServerCutText("clipboard text"))
        XCTAssertEqual(actions.count, 1)
        if case .notifyClipboard(let text) = actions.first {
            XCTAssertEqual(text, "clipboard text")
        } else {
            XCTFail("Expected notifyClipboard action")
        }
    }

    func testOperationalMediaStreamOffer() {
        var sm = ConnectionStateMachine()
        _ = sm.handle(event: .connected)
        _ = sm.handle(event: .receivedProtocolVersion(.v3_8))
        _ = sm.handle(event: .receivedSecurityTypes([.none]))
        _ = sm.handle(event: .authenticationSucceeded)
        _ = sm.handle(event: .receivedServerInit(makeTestServerInit()))

        let offer = AppleMediaStreamOffer(
            streamID: 42, codecType: 0x68766331, width: 1920, height: 1080, frameRate: 30
        )
        let actions = sm.handle(event: .receivedMediaStreamOffer(offer))
        XCTAssertEqual(actions.count, 1)
        if case .sendMediaStreamAnswer(let answer) = actions.first {
            XCTAssertEqual(answer.streamID, 42)
            XCTAssertTrue(answer.accepted)
        } else {
            XCTFail("Expected sendMediaStreamAnswer action")
        }
    }

    func testOperationalEncryptionInfo() {
        var sm = ConnectionStateMachine()
        _ = sm.handle(event: .connected)
        _ = sm.handle(event: .receivedProtocolVersion(.v3_8))
        _ = sm.handle(event: .receivedSecurityTypes([.none]))
        _ = sm.handle(event: .authenticationSucceeded)
        _ = sm.handle(event: .receivedServerInit(makeTestServerInit()))

        let info = AppleEncryptionInfo(cipherMode: 1, keyLength: 128)
        let actions = sm.handle(event: .receivedEncryptionInfo(info))
        XCTAssertEqual(actions.count, 1)
        if case .sendEncryptionResponse = actions.first {
            // good
        } else {
            XCTFail("Expected sendEncryptionResponse action")
        }
    }

    // MARK: - Unexpected event

    func testUnexpectedEventReportsError() {
        var sm = ConnectionStateMachine()
        // In idle state, receiving ServerInit is unexpected
        let actions = sm.handle(event: .receivedServerInit(makeTestServerInit()))
        XCTAssertEqual(actions.count, 1)
        if case .reportError(.unexpectedMessage) = actions.first {
            // good
        } else {
            XCTFail("Expected reportError(.unexpectedMessage)")
        }
    }

    // MARK: - Default init values

    func testDefaultInitValues() {
        let sm = ConnectionStateMachine()
        XCTAssertEqual(sm.state, .idle)
        XCTAssertNil(sm.negotiatedVersion)
        XCTAssertNil(sm.selectedSecurityType)
        XCTAssertNil(sm.serverInit)
        XCTAssertEqual(sm.preferredPixelFormat, .bgra8888)
        XCTAssertFalse(sm.preferredEncodings.isEmpty)
    }
}

// MARK: - FramebufferRect Tests

final class FramebufferRectTests: XCTestCase {

    func testParseFromReader() throws {
        // x=10(0x000A), y=20(0x0014), width=640(0x0280), height=480(0x01E0),
        // encoding=raw(0x00000000)
        let data = Data([
            0x00, 0x0A, // x = 10
            0x00, 0x14, // y = 20
            0x02, 0x80, // width = 640
            0x01, 0xE0, // height = 480
            0x00, 0x00, 0x00, 0x00, // encoding = raw (0)
        ])
        var reader = MessageReader(data: data)
        let rect = try FramebufferRect(reader: &reader)
        XCTAssertEqual(rect.x, 10)
        XCTAssertEqual(rect.y, 20)
        XCTAssertEqual(rect.width, 640)
        XCTAssertEqual(rect.height, 480)
        XCTAssertEqual(rect.encoding, .raw)
    }

    func testPixelCount() {
        let rect = FramebufferRect(x: 0, y: 0, width: 100, height: 200, encoding: .raw)
        XCTAssertEqual(rect.pixelCount, 20_000)
    }

    func testWireSize() {
        XCTAssertEqual(FramebufferRect.wireSize, 12)
    }
}

// MARK: - VNCProtocolError Tests

final class VNCProtocolErrorTests: XCTestCase {

    func testEquatable() {
        XCTAssertEqual(VNCProtocolError.connectionClosed, VNCProtocolError.connectionClosed)
        XCTAssertEqual(VNCProtocolError.timeout, VNCProtocolError.timeout)
        XCTAssertEqual(VNCProtocolError.unexpectedMessage, VNCProtocolError.unexpectedMessage)
        XCTAssertEqual(VNCProtocolError.unsupportedVersion, VNCProtocolError.unsupportedVersion)
        XCTAssertEqual(
            VNCProtocolError.authenticationFailed("test"),
            VNCProtocolError.authenticationFailed("test")
        )
        XCTAssertNotEqual(
            VNCProtocolError.authenticationFailed("a"),
            VNCProtocolError.authenticationFailed("b")
        )
    }

    func testErrorDescription() {
        XCTAssertNotNil(VNCProtocolError.connectionClosed.errorDescription)
        XCTAssertNotNil(VNCProtocolError.timeout.errorDescription)
        XCTAssertNotNil(VNCProtocolError.unexpectedMessage.errorDescription)
        XCTAssertNotNil(VNCProtocolError.protocolViolation("detail").errorDescription)
        XCTAssertTrue(VNCProtocolError.authenticationFailed("bad pwd").errorDescription!.contains("bad pwd"))
        XCTAssertTrue(VNCProtocolError.unsupportedEncoding(999).errorDescription!.contains("999"))
        XCTAssertTrue(VNCProtocolError.ioError("oops").errorDescription!.contains("oops"))
    }
}

// MARK: - ServerMessage Tests

final class ServerMessageTests: XCTestCase {

    func testMessageTypeIDs() {
        let fbUpdate = ServerMessage.framebufferUpdate(rectangles: [])
        XCTAssertEqual(fbUpdate.messageType, 0)

        let colorMap = ServerMessage.setColorMapEntries(firstColor: 0, colors: [])
        XCTAssertEqual(colorMap.messageType, 1)

        XCTAssertEqual(ServerMessage.bell.messageType, 2)

        let cutText = ServerMessage.serverCutText("hi")
        XCTAssertEqual(cutText.messageType, 3)
    }

    func testParseFramebufferUpdateSingleRect() throws {
        // Build a framebuffer update payload after the message-type byte:
        // [padding] [num-rects UInt16] [rect header 12 bytes]
        var data = Data()
        data.append(0) // padding
        data.append(contentsOf: [0x00, 0x01]) // 1 rectangle
        // Rectangle: x=0, y=0, w=100(0x0064), h=50(0x0032), encoding=raw(0)
        data.append(contentsOf: [0x00, 0x00]) // x
        data.append(contentsOf: [0x00, 0x00]) // y
        data.append(contentsOf: [0x00, 0x64]) // width = 100
        data.append(contentsOf: [0x00, 0x32]) // height = 50
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x00]) // encoding = raw

        var reader = MessageReader(data: data)
        let msg = try ServerMessage.parseFramebufferUpdate(reader: &reader)
        if case .framebufferUpdate(let rects) = msg {
            XCTAssertEqual(rects.count, 1)
            XCTAssertEqual(rects[0].width, 100)
            XCTAssertEqual(rects[0].height, 50)
            XCTAssertEqual(rects[0].encoding, .raw)
        } else {
            XCTFail("Expected framebufferUpdate message")
        }
    }

    func testParseServerCutText() throws {
        // After message-type: [padding x3] [length UInt32] [text]
        var data = Data()
        data.append(contentsOf: [0, 0, 0]) // padding
        let text = "clipboard"
        let textBytes = Data(text.utf8)
        let len = UInt32(textBytes.count)
        data.append(contentsOf: [
            UInt8((len >> 24) & 0xFF),
            UInt8((len >> 16) & 0xFF),
            UInt8((len >> 8) & 0xFF),
            UInt8(len & 0xFF),
        ])
        data.append(textBytes)

        var reader = MessageReader(data: data)
        let msg = try ServerMessage.parseServerCutText(reader: &reader)
        if case .serverCutText(let result) = msg {
            XCTAssertEqual(result, "clipboard")
        } else {
            XCTFail("Expected serverCutText message")
        }
    }
}

// MARK: - AppleMessages Tests

final class AppleMessagesTests: XCTestCase {

    func testExtendedDesktopSizePayloadConsumesEveryScreenRecord() throws {
        let payload = Data([
            0x02, 0x00, 0x00, 0x00,
            // Screen 7: 1920x1080 at (0, 0), primary flag.
            0x00, 0x00, 0x00, 0x07,
            0x00, 0x00, 0x00, 0x00,
            0x07, 0x80, 0x04, 0x38,
            0x00, 0x00, 0x00, 0x01,
            // Screen 9: 1280x1024 at (1920, 0).
            0x00, 0x00, 0x00, 0x09,
            0x07, 0x80, 0x00, 0x00,
            0x05, 0x00, 0x04, 0x00,
            0x00, 0x00, 0x00, 0x00,
        ])

        XCTAssertEqual(
            payload.count,
            ExtendedDesktopSizePayload.wireSize(screenCount: 2))
        let layout = try ExtendedDesktopSizePayload(data: payload)
        XCTAssertEqual(layout.screens.count, 2)
        XCTAssertEqual(
            layout.screens[0],
            RFBScreenLayout(
                id: 7, x: 0, y: 0, width: 1920, height: 1080, flags: 1))
        XCTAssertEqual(
            layout.screens[1],
            RFBScreenLayout(
                id: 9, x: 1920, y: 0, width: 1280, height: 1024, flags: 0))
    }

    func testExtendedDesktopSizePayloadRejectsTruncation() {
        let truncated = Data([0x01, 0, 0, 0, 0, 0, 0])
        XCTAssertThrowsError(try ExtendedDesktopSizePayload(data: truncated))
    }

    func testAppleEncryptionInfoRoundTrip() throws {
        let info = AppleEncryptionInfo(cipherMode: 0x00000001, keyLength: 128)
        let bytes = info.wireBytes()
        XCTAssertEqual(bytes.count, 8)

        var reader = MessageReader(data: bytes)
        let parsed = try AppleEncryptionInfo(reader: &reader)
        XCTAssertEqual(parsed.cipherMode, info.cipherMode)
        XCTAssertEqual(parsed.keyLength, info.keyLength)
    }

    func testAppleMediaStreamAnswerRoundTrip() throws {
        let answer = AppleMediaStreamAnswer(streamID: 42, accepted: true)
        let bytes = answer.wireBytes()
        XCTAssertEqual(bytes.count, 8)
        XCTAssertEqual(bytes, Data([0x12, 0x00, 0x00, 0x02, 0x00, 0x2A, 0x00, 0x00]))

        var reader = MessageReader(data: bytes)
        let parsed = try AppleMediaStreamAnswer(reader: &reader)
        XCTAssertEqual(parsed.streamID, 42)
        XCTAssertTrue(parsed.accepted)
    }

    func testAppleMediaStreamAnswerRejected() throws {
        let answer = AppleMediaStreamAnswer(streamID: 99, accepted: false)
        let bytes = answer.wireBytes()
        var reader = MessageReader(data: bytes)
        let parsed = try AppleMediaStreamAnswer(reader: &reader)
        XCTAssertEqual(parsed.streamID, 99)
        XCTAssertFalse(parsed.accepted)
    }

    func testAppleMediaStreamOfferPreservesOpaquePayload() throws {
        let payload = Data([
            0x00, 0x00, 0x00, 0x01,
            0x07, 0xfb, 0x93, 0xb0,
            0x36, 0xff, 0x77, 0x50,
            0x38, 0xe0, 0x45, 0xd9,
            0xce, 0xf3, 0xf4, 0xb2,
            0x78, 0x8e, 0x6d, 0xf5,
            0x1f, 0x77, 0xb7, 0x4f,
            0x2c, 0x59, 0xde, 0xc9,
            0xe1, 0x4c, 0xb2, 0x34,
        ])
        var reader = MessageReader(data: payload)
        let offer = try AppleMediaStreamOffer(reader: &reader)
        XCTAssertEqual(offer.streamID, 1)
        XCTAssertEqual(offer.rawPayload.count, AppleMediaStreamOffer.wirePayloadSize)
        XCTAssertEqual(offer.rawPayload, payload)
        XCTAssertEqual(offer.messageVersion, 0)
        XCTAssertEqual(offer.messageType, 1)
        XCTAssertEqual(offer.audioStreamUDPPort, 0x36ff)
        XCTAssertEqual(offer.audioStreamFlags, 0x775038e0)
        XCTAssertEqual(offer.videoStream1UDPPort, 0x45d9)
        XCTAssertEqual(offer.videoStream1Flags, 0xcef3f4b2)
        XCTAssertEqual(offer.videoStream2UDPPort, 0x788e)
        XCTAssertEqual(offer.videoStreamDisplayCount, 2)
        XCTAssertEqual(offer.codecType, 0)
        XCTAssertEqual(offer.width, 0)
        XCTAssertEqual(offer.height, 0)
    }

    func testAppleMediaStreamOfferUsesSecondaryReceiverPortForDisplayCount() throws {
        var payload = Data(
            repeating: 0,
            count: AppleMediaStreamOffer.wirePayloadSize)
        payload[14] = 0x17
        payload[15] = 0x0d
        payload[20] = 0x17
        payload[21] = 0x0e
        var reader = MessageReader(data: payload)
        let two = try AppleMediaStreamOffer(reader: &reader)
        XCTAssertEqual(two.videoStreamDisplayCount, 2)

        payload[20] = 0
        payload[21] = 0
        reader = MessageReader(data: payload)
        let one = try AppleMediaStreamOffer(reader: &reader)
        XCTAssertEqual(one.videoStreamDisplayCount, 1)
    }

    func testAppleMediaStreamConfigurationWireBytes() {
        let bytes = MessageWriter.writeAppleMediaStreamConfiguration()
        XCTAssertEqual(bytes, Data([
            0x21, 0x00, 0x00, 0x3e,
            0x00, 0x01, 0x00, 0x00,
            0x00, 0x02, 0x00, 0x00,
            0x00, 0x06, 0x00, 0x00,
            0x00, 0x02, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x1a, 0x00, 0x00,
            0x00, 0x03, 0x00, 0x00,
            0x00, 0x01, 0xb0, 0x00,
            0x0c, 0x03, 0x90, 0x00,
            0x00, 0x00, 0x00, 0x40,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00,
        ]))
    }

    func testAppleViewerInfoMapsAcceptedServerMessagesMSBFirst() {
        let bytes = MessageWriter.writeAppleViewerInfo(
            acceptedServerMessages: [0, 2, 3, 0x14, 0x1f])
        XCTAssertEqual(bytes.count, 66)
        // Same header and identity as the High Performance message.
        XCTAssertEqual(
            bytes.prefix(34),
            MessageWriter.writeAppleMediaStreamConfiguration().prefix(34))
        var map = Data(repeating: 0, count: 32)
        map[0] = 0xb0
        map[2] = 0x08
        map[3] = 0x01
        XCTAssertEqual(Data(bytes.suffix(32)), map)
    }

    func testAppleMediaStreamRequestWireBytes() {
        let bytes = MessageWriter.writeAppleMediaStreamRequest()
        XCTAssertEqual(bytes.count, 16)
        XCTAssertEqual(
            bytes,
            Data([
                0x12, 0x00, 0x00, 0x01,
                0x00, 0x01, 0x00, 0x01,
                0x00, 0x00, 0x00, 0x01,
                0x0a, 0x00, 0x00, 0x01,
            ])
        )
    }
}
