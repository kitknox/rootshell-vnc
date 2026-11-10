import CoreGraphics
import ImageIO
import XCTest
import RFBProtocol
@testable import RFBTransport

final class ExtendedClipboardProtocolTests: XCTestCase {
    private typealias Extended = ExtendedClipboardProtocol

    func testCapsListSizesInAscendingFormatOrder() throws {
        let message = try Extended.clientMessage(.caps(
            [.html, .text], [.request, .notify],
            maximumSizes: [4: 0x30, 1: 0x10]))

        XCTAssertEqual(Array(message.prefix(4)), [6, 0, 0, 0])
        let length = Int32(bitPattern: AppleClipboardProtocol.uint32BE(message, at: 4)!)
        XCTAssertEqual(Int(-length), message.count - 8)
        XCTAssertEqual(Array(message.dropFirst(8)), [
            0x0B, 0, 0, 0x05, // caps | request | notify, html | text
            0, 0, 0, 0x10,
            0, 0, 0, 0x30,
        ])
        XCTAssertEqual(
            try Extended.parse(Data(message.dropFirst(8))),
            .caps([.text, .html], [.request, .notify], maximumSizes: [1: 0x10, 4: 0x30]))
    }

    func testClientCapsAdvertiseZeroSizesForEveryFormat() throws {
        let message = try Extended.clientMessage(Extended.clientCaps)
        XCTAssertEqual(Array(message.dropFirst(8)), [
            0x1F, 0, 0, 0x0F, // caps request peek notify provide; text rtf html dib
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        ])
    }

    func testBodilessActionsRoundTrip() throws {
        for message: Extended.Message in [.request([.text, .dib]), .notify([.rtf]), .peek] {
            let wire = try Extended.clientMessage(message)
            XCTAssertEqual(wire.count, 12)
            XCTAssertEqual(try Extended.parse(Data(wire.dropFirst(8))), message)
        }
    }

    func testProvideIsOneFinishedZlibStream() throws {
        let provided: [UInt32: Data] = [
            1: Data("a\r\nb\0".utf8),
            2: Data("{\\rtf1 x}\0".utf8),
        ]
        let wire = try Extended.clientMessage(.provide(provided))
        let payload = Data(wire.dropFirst(8))
        XCTAssertEqual(Array(payload.prefix(4)), [0x10, 0, 0, 0x03])
        XCTAssertEqual(try Extended.parse(payload), .provide(provided))

        // A finished stream ends with an Adler-32 trailer, not a sync marker.
        XCTAssertNotEqual(Array(payload.suffix(4)), [0, 0, 0xFF, 0xFF])
        var stream = Data()
        AppleClipboardProtocol.appendUInt32BE(5, to: &stream)
        stream.append(Data("a\r\nb\0".utf8))
        AppleClipboardProtocol.appendUInt32BE(10, to: &stream)
        stream.append(Data("{\\rtf1 x}\0".utf8))
        XCTAssertEqual(
            try ClipboardCompression.inflate(Data(payload.dropFirst(4)), outputLimit: 1024),
            stream)
    }

    func testProvideAcceptsSyncFlushedStreams() throws {
        var stream = Data()
        AppleClipboardProtocol.appendUInt32BE(3, to: &stream)
        stream.append(Data("hi\0".utf8))
        var payload = Data([0x10, 0, 0, 0x01])
        payload.append(try ClipboardCompression.deflate(
            stream, finishStream: false, outputLimit: 1024))

        XCTAssertEqual(try Extended.parse(payload), .provide([1: Data("hi\0".utf8)]))
    }

    func testTextUsesCRLFAndATerminatingNUL() {
        let encoded = Extended.encode(.text("one\ntwo\r\nthree"), accepting: [.text])
        XCTAssertEqual(encoded, [1: Data("one\r\ntwo\r\nthree\0".utf8)])
        XCTAssertEqual(
            Extended.decode([1: Data("one\r\ntwo\0\0".utf8)]),
            .text("one\ntwo"))
    }

    func testEncodeKeepsOnlyAcceptedFormats() {
        let content = ClipboardContent(items: [[
            .init(type: ClipboardType.rtf, data: Data("{\\rtf1}".utf8)),
            .init(type: ClipboardType.html, data: Data("<p>x</p>".utf8)),
            .init(type: ClipboardType.utf8PlainText, data: Data("x".utf8)),
        ]])
        XCTAssertEqual(
            Set(Extended.encode(content, accepting: [.text, .rtf]).keys),
            [1, 2])
        XCTAssertEqual(
            Extended.support(for: [.text, .dib]),
            .formats([
                ClipboardType.utf8PlainText, ClipboardType.png, ClipboardType.jpeg,
                ClipboardType.tiff, ClipboardType.gif, ClipboardType.heic,
            ]))
    }

    func testHTMLFragmentHeaderOffsetsPointIntoTheDocument() throws {
        let source = Data("<html><head></head><body><b>bold</b></body></html>".utf8)
        let wrapped = ClipboardHTMLFragment.wrap(source)
        let text = String(decoding: wrapped, as: UTF8.self)
        func offset(_ name: String) -> Int {
            let line = text.split(separator: "\r\n").first { $0.hasPrefix(name + ":") }!
            return Int(line.dropFirst(name.count + 1))!
        }

        XCTAssertTrue(text.hasPrefix("Version:0.9\r\nStartHTML:0000000105\r\n"))
        let bytes = [UInt8](wrapped)
        XCTAssertEqual(
            String(decoding: bytes[offset("StartHTML")..<offset("EndHTML")], as: UTF8.self),
            "<html><head></head><body><!--StartFragment--><b>bold</b>"
                + "<!--EndFragment--></body></html>")
        XCTAssertEqual(
            String(decoding: bytes[offset("StartFragment")..<offset("EndFragment")], as: UTF8.self),
            "<b>bold</b>")
        XCTAssertEqual(offset("EndHTML"), bytes.count)

        let unwrapped = String(decoding: ClipboardHTMLFragment.unwrap(wrapped), as: UTF8.self)
        XCTAssertEqual(
            unwrapped,
            "<meta charset=\"utf-8\"><html><head></head><body><b>bold</b></body></html>")
    }

    func testHTMLUnwrapKeepsOnlyTheCopiedFragment() {
        let document = "<html><body>before <!--StartFragment-->selected<!--EndFragment-->"
            + " after</body></html>"
        let fragmentStart = document.range(of: "<!--StartFragment-->")!.upperBound
        let fragmentEnd = document.range(of: "<!--EndFragment-->")!.lowerBound
        let headerLength = 105
        let start = headerLength + document[..<fragmentStart].utf8.count
        let end = headerLength + document[..<fragmentEnd].utf8.count
        func cfHTML(fragment: (Int, Int)) -> Data {
            func field(_ value: Int) -> String {
                value < 0 ? "-000000001" : String(format: "%010d", value)
            }
            return Data(("Version:0.9\r\n"
                + "StartHTML:\(field(headerLength))\r\n"
                + "EndHTML:\(field(headerLength + document.utf8.count))\r\n"
                + "StartFragment:\(field(fragment.0))\r\n"
                + "EndFragment:\(field(fragment.1))\r\n"
                + document).utf8)
        }

        let withOffsets = cfHTML(fragment: (start, end))
        XCTAssertEqual(withOffsets.count, headerLength + document.utf8.count)
        XCTAssertEqual(
            String(decoding: ClipboardHTMLFragment.unwrap(withOffsets), as: UTF8.self),
            "<meta charset=\"utf-8\"><html><head></head><body>selected</body></html>")

        // Without fragment offsets, the markers still bound the selection.
        XCTAssertEqual(
            String(decoding: ClipboardHTMLFragment.unwrap(cfHTML(fragment: (-1, -1))), as: UTF8.self),
            "<meta charset=\"utf-8\"><html><head></head><body>selected</body></html>")
    }

    func testHTMLFragmentKeepsStylesAndOpenAncestorsButNotSiblings() {
        let prefix = "<!DOCTYPE html><html><head><base href=\"https://example.com/\">"
            + "<style>.red { color: red }</style></head><body class=\"page\">"
            + "<p>skip <b>this</b></p><img src=\"skip.png\"><script>let x = \"<div>\"</script>"
            + "<style>.big { font-size: 2em }</style>"
            + "<div class=\"big\" title=\"a > b\"><span class=\"red\">unselected "
            + "<!--StartFragment-->"
        XCTAssertEqual(
            ClipboardHTMLFragment.contextualized(prefix: prefix, fragment: "red <i>text</i>"),
            "<html><head><base href=\"https://example.com/\"><style>.red { color: red }</style>"
                + "<style>.big { font-size: 2em }</style></head><body class=\"page\">"
                + "<div class=\"big\" title=\"a > b\"><span class=\"red\">red <i>text</i>"
                + "</span></div></body></html>")
    }

    func testHTMLFragmentWrapsBareMarkupAndPassesPlainHTMLThrough() {
        let wrapped = String(
            decoding: ClipboardHTMLFragment.wrap(Data("<i>é</i>".utf8)), as: UTF8.self)
        XCTAssertTrue(wrapped.hasSuffix(
            "<html><body>\r\n<!--StartFragment--><i>é</i><!--EndFragment-->\r\n</body>\r\n</html>"))

        let plain = Data("<meta charset=\"utf-8\"><p>x</p>".utf8)
        XCTAssertEqual(ClipboardHTMLFragment.unwrap(plain), plain)
    }

    func testDIBRoundTripsThroughBMPFileHeader() throws {
        let png = try Self.pngImage(pixels: [
            [0xFF00_00FF, 0xFF00_FF00], // red, green
            [0xFFFF_0000, 0xFFFF_FFFF], // blue, white
        ])
        let dib = try XCTUnwrap(ClipboardDIB.dib(fromImage: png))
        XCTAssertEqual(dib.count, 124 + 2 * 2 * 4)
        XCTAssertEqual(Array(dib.prefix(4)), [124, 0, 0, 0])

        let bmp = try XCTUnwrap(ClipboardDIB.bmpFile(fromDIB: dib))
        XCTAssertEqual(Array(bmp.prefix(2)), Array("BM".utf8))
        XCTAssertEqual(Array(bmp[10..<14]), [138, 0, 0, 0]) // 14 + 124
        XCTAssertEqual(try Self.rgbaPixels(of: bmp), [
            [0xFF00_00FF, 0xFF00_FF00],
            [0xFFFF_0000, 0xFFFF_FFFF],
        ])
    }

    func testBMPFileHeaderAccountsForBitfieldMasksAndPalettes() {
        var bitfields = Data(count: 40)
        bitfields[0] = 40
        bitfields[14] = 32
        bitfields[16] = 3 // BI_BITFIELDS after a v3 header
        XCTAssertEqual(
            ClipboardDIB.bmpFile(fromDIB: bitfields + Data(count: 16)).map { Array($0[10..<14]) },
            [66, 0, 0, 0])

        var paletted = Data(count: 40)
        paletted[0] = 40
        paletted[14] = 8
        XCTAssertEqual(
            ClipboardDIB.bmpFile(fromDIB: paletted + Data(count: 1024)).map { Array($0[10..<14]) },
            [0x36, 0x04, 0, 0]) // 14 + 40 + 256 * 4
    }

    // MARK: - Images

    /// Rows of 0xAABBGGRR pixels.
    private static func pngImage(pixels: [[UInt32]]) throws -> Data {
        let height = pixels.count
        let width = pixels[0].count
        var bytes = pixels.flatMap { row in
            row.flatMap { pixel in (0..<4).map { UInt8(truncatingIfNeeded: pixel >> (8 * $0)) } }
        }
        let image = try XCTUnwrap(bytes.withUnsafeMutableBytes { buffer in
            CGContext(
                data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        })
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            output, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private static func rgbaPixels(of data: Data) throws -> [[UInt32]] {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return (0..<height).map { row in
            (0..<width).map { column in
                let base = (row * width + column) * 4
                return (0..<4).reduce(0) { $0 | UInt32(bytes[base + $1]) << (8 * $1) }
            }
        }
    }
}
