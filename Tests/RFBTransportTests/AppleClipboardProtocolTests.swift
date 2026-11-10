import XCTest
import RFBProtocol
@testable import RFBTransport

final class AppleClipboardProtocolTests: XCTestCase {
    func testRemoteClipboardRequestWireFormat() {
        XCTAssertEqual(
            AppleClipboardProtocol.requestMessage(requestID: 0x0102_0304),
            Data([11, 0, 0, 0, 1, 2, 3, 4]))
    }

    func testAutomaticPasteboardWireFormat() {
        XCTAssertEqual(
            AppleClipboardProtocol.autoPasteboardMessage(enabled: true),
            Data([21, 0, 0, 1, 0, 0, 0, 0]))
        XCTAssertEqual(
            AppleClipboardProtocol.autoPasteboardMessage(enabled: false),
            Data([21, 0, 0, 2, 0, 0, 0, 0]))
    }

    func testUnpacksUTF8TextFlavor() throws {
        // A complete zlib stream containing one Apple packed-scrap item with
        // one public.utf8-plain-text flavor whose contents are "hello".
        let compressed = Data([
            120, 156, 99, 96, 96, 96, 100, 96, 96, 16, 43, 40, 77, 202,
            201, 76, 214, 43, 45, 73, 179, 208, 45, 200, 73, 204, 204,
            211, 45, 73, 173, 40, 97, 64, 0, 214, 140, 212, 156, 156, 124,
            0, 249, 124, 10, 152,
        ])

        XCTAssertEqual(
            try AppleClipboardProtocol.unpackText(
                compressed: compressed,
                uncompressedSize: 47),
            "hello")
    }

    func testPackedTextMessageHeaderAndRoundTrip() throws {
        let text = "hello, 🌎"
        let message = try AppleClipboardProtocol.packedTextMessage(text)

        XCTAssertEqual(message[0], AppleClipboardProtocol.packedScrapMessageType)
        XCTAssertEqual(message[2], 0, "Full clipboard data is not a promise")
        XCTAssertEqual(message.count, AppleClipboardProtocol.packedScrapHeaderSize
            + Int(AppleClipboardProtocol.uint32BE(message, at: 12)!))

        let uncompressedSize = Int(
            AppleClipboardProtocol.uint32BE(message, at: 8)!)
        let compressed = Data(message.dropFirst(
            AppleClipboardProtocol.packedScrapHeaderSize))
        XCTAssertEqual(
            try AppleClipboardProtocol.unpackText(
                compressed: compressed,
                uncompressedSize: uncompressedSize),
            text)
    }

    func testPackedTextMessageRoundTripsEmptyText() throws {
        let message = try AppleClipboardProtocol.packedTextMessage("")
        let uncompressedSize = Int(
            AppleClipboardProtocol.uint32BE(message, at: 8)!)
        let compressed = Data(message.dropFirst(
            AppleClipboardProtocol.packedScrapHeaderSize))

        XCTAssertEqual(
            try AppleClipboardProtocol.unpackText(
                compressed: compressed,
                uncompressedSize: uncompressedSize),
            "")
    }

    func testPackedTextMessageUsesNativeSyncFlushBoundary() throws {
        let message = try AppleClipboardProtocol.packedTextMessage("abcdef")
        let compressed = Data(message.dropFirst(
            AppleClipboardProtocol.packedScrapHeaderSize))

        // Apple's CopyPackedScrapData leaves its zlib stream open at a
        // Z_SYNC_FLUSH boundary instead of emitting Z_STREAM_END + Adler-32.
        // Block selection and total compressed length are implementation
        // details; only the empty stored-block marker is guaranteed.
        XCTAssertEqual(
            compressed.suffix(4),
            Data([0x00, 0x00, 0xFF, 0xFF]))
    }

    func testPackedTextMessageDrainsMultipleCompressionBuffers() throws {
        var state: UInt64 = 0x1234_5678_9ABC_DEF0
        var bytes = [UInt8]()
        bytes.reserveCapacity(128 * 1024)
        for _ in 0..<(128 * 1024) {
            state = state &* 6_364_136_223_846_793_005
                &+ 1_442_695_040_888_963_407
            bytes.append(UInt8((state >> 32) % 95) + 32)
        }
        let text = String(decoding: bytes, as: UTF8.self)
        let message = try AppleClipboardProtocol.packedTextMessage(text)
        let compressed = Data(message.dropFirst(
            AppleClipboardProtocol.packedScrapHeaderSize))
        let uncompressedSize = Int(
            AppleClipboardProtocol.uint32BE(message, at: 8)!)

        XCTAssertGreaterThan(
            compressed.count,
            ClipboardCompression.chunkSize)
        XCTAssertEqual(
            try AppleClipboardProtocol.unpackText(
                compressed: compressed,
                uncompressedSize: uncompressedSize),
            text)
    }

    func testPackedClipboardSelectionUsesServerCommandBitmap() {
        var packedBitmap = Data(repeating: 0, count: 16)
        packedBitmap[3] = 0x01 // command 31, MSB-first numbering
        let packedCapabilities = capabilities(bitmap: packedBitmap)

        var legacyBitmap = Data(repeating: 0, count: 16)
        legacyBitmap[0] = 0x02 // command 6 only
        let legacyCapabilities = capabilities(bitmap: legacyBitmap)

        XCTAssertTrue(TransportSession.shouldUseApplePackedClipboard(
            capabilities: packedCapabilities))
        XCTAssertFalse(TransportSession.shouldUseApplePackedClipboard(
            capabilities: legacyCapabilities))
        XCTAssertFalse(TransportSession.shouldUseApplePackedClipboard(
            capabilities: nil))
    }

    /// wayshare's `pack_layout` vector: one item, one text flavor with a
    /// MIME tag. We read the tag and write flavors without tags.
    func testUnpacksWaysharePackLayoutAndPacksWithoutTags() throws {
        var vector = Data([0, 0, 0, 1, 0, 0, 0, 22])
        vector.append(Data("public.utf8-plain-text".utf8))
        vector.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 16])
        vector.append(Data("public.mime-type".utf8))
        vector.append(contentsOf: [0, 0, 0, 10])
        vector.append(Data("text/plain".utf8))
        vector.append(contentsOf: [0, 0, 0, 2, UInt8(ascii: "h"), UInt8(ascii: "i")])

        XCTAssertEqual(try AppleClipboardProtocol.unpack(vector), .text("hi"))

        var untagged = Data([0, 0, 0, 1, 0, 0, 0, 22])
        untagged.append(Data("public.utf8-plain-text".utf8))
        untagged.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 0])
        untagged.append(contentsOf: [0, 0, 0, 2, UInt8(ascii: "h"), UInt8(ascii: "i")])
        XCTAssertEqual(AppleClipboardProtocol.pack(.text("hi")), untagged)
    }

    func testMultiItemRichContentRoundTrips() throws {
        let content = ClipboardContent(items: [
            [
                .init(type: ClipboardType.rtf, data: Data("{\\rtf1 hi}".utf8)),
                .init(type: ClipboardType.html, data: Data("<b>hi</b>".utf8)),
                .init(type: ClipboardType.png, data: Data([0x89, 0x50, 0x4E, 0x47])),
                .init(type: ClipboardType.utf8PlainText, data: Data("hi".utf8)),
            ],
            [.init(type: ClipboardType.tiff, data: Data([0x4D, 0x4D, 0x00, 0x2A]))],
        ])
        let message = try AppleClipboardProtocol.packedMessage(content)
        let unpacked = try AppleClipboardProtocol.unpackContent(
            compressed: Data(message.dropFirst(AppleClipboardProtocol.packedScrapHeaderSize)),
            uncompressedSize: Int(AppleClipboardProtocol.uint32BE(message, at: 8)!))
        XCTAssertEqual(unpacked, content)
    }

    func testDynamicFlavorsAreIdentifiedByMIMETag() throws {
        let scrap = Self.scrap([[
            ("", [("public.mime-type", "image/png")], Data([1, 2])),
            ("dyn.ah62d4rv4gu8yc6durvwwaznwmuuha2pxsvw0e55bsmwca7d3sbwu",
             [("public.mime-type", "text/html")], Data("<i>x</i>".utf8)),
        ]])
        XCTAssertEqual(try AppleClipboardProtocol.unpack(scrap), ClipboardContent(items: [[
            .init(type: ClipboardType.png, data: Data([1, 2])),
            .init(type: ClipboardType.html, data: Data("<i>x</i>".utf8)),
        ]]))
    }

    func testUTF16TextBecomesUTF8AndFirstTextFlavorWins() throws {
        var utf16 = Data([0xFF, 0xFE])
        utf16.append("héllo".data(using: .utf16LittleEndian)!)
        let scrap = Self.scrap([[
            ("public.utf16-plain-text", [], utf16),
            ("public.utf8-plain-text", [], Data("ignored".utf8)),
        ]])
        XCTAssertEqual(try AppleClipboardProtocol.unpack(scrap), .text("héllo"))
    }

    func testUnbridgedFlavorsAndEmptyItemsAreDropped() throws {
        let scrap = Self.scrap([
            [
                ("com.apple.webarchive", [], Data([1])),
                ("public.file-url", [], Data("file:///tmp/a".utf8)),
            ],
            [("public.rtf", [], Data("{\\rtf1}".utf8))],
        ])
        XCTAssertEqual(try AppleClipboardProtocol.unpack(scrap), ClipboardContent(items: [[
            .init(type: ClipboardType.rtf, data: Data("{\\rtf1}".utf8)),
        ]]))
    }

    func testFittedDropsRedundantImagesThenRTFDThenLargestButKeepsText() {
        let content = ClipboardContent(items: [[
            .init(type: ClipboardType.flatRTFD, data: Data(count: 300)),
            .init(type: ClipboardType.rtf, data: Data(count: 100)),
            .init(type: ClipboardType.png, data: Data(count: 400)),
            .init(type: ClipboardType.tiff, data: Data(count: 1_000)),
            .init(type: ClipboardType.html, data: Data(count: 200)),
            .init(type: ClipboardType.utf8PlainText, data: Data(count: 2_000)),
        ]])
        func types(_ content: ClipboardContent) -> [String] {
            content.items.flatMap { $0.map(\.type) }
        }

        XCTAssertEqual(types(content.fitted(maxBytes: 3_100)), [
            ClipboardType.flatRTFD, ClipboardType.rtf, ClipboardType.png,
            ClipboardType.html, ClipboardType.utf8PlainText,
        ])
        XCTAssertEqual(types(content.fitted(maxBytes: 2_800)), [
            ClipboardType.rtf, ClipboardType.png, ClipboardType.html,
            ClipboardType.utf8PlainText,
        ])
        XCTAssertEqual(types(content.fitted(maxBytes: 2_400)), [
            ClipboardType.rtf, ClipboardType.html, ClipboardType.utf8PlainText,
        ])
        XCTAssertEqual(types(content.fitted(maxBytes: 0)), [ClipboardType.utf8PlainText])
    }

    func testPackedMessageDropsImagesThatExceedAppleSendLimit() throws {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        let noise = Data((0..<(8 * 1024 * 1024)).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return UInt8(truncatingIfNeeded: state >> 33)
        })
        let content = ClipboardContent(items: [[
            .init(type: ClipboardType.png, data: noise),
            .init(type: ClipboardType.rtf, data: Data("{\\rtf1 kept}".utf8)),
            .init(type: ClipboardType.utf8PlainText, data: Data("kept".utf8)),
        ]])

        let message = try AppleClipboardProtocol.packedMessage(content)
        XCTAssertLessThanOrEqual(
            message.count - AppleClipboardProtocol.packedScrapHeaderSize,
            AppleClipboardProtocol.maximumSendSize)
        let unpacked = try AppleClipboardProtocol.unpackContent(
            compressed: Data(message.dropFirst(AppleClipboardProtocol.packedScrapHeaderSize)),
            uncompressedSize: Int(AppleClipboardProtocol.uint32BE(message, at: 8)!))
        XCTAssertEqual(unpacked.items.flatMap { $0.map(\.type) }, [
            ClipboardType.rtf, ClipboardType.utf8PlainText,
        ])
    }

    private func capabilities(bitmap: Data) -> AppleServerCapabilities {
        var field = Data([0, 0, 0, 0, 0, 0])
        field.append(bitmap)
        return AppleServerCapabilities(serverInitNameField: field)!
    }

    private static func scrap(
        _ items: [[(uti: String, tags: [(String, String)], data: Data)]]
    ) -> Data {
        var scrap = Data()
        func append(_ value: Int) {
            AppleClipboardProtocol.appendUInt32BE(UInt32(value), to: &scrap)
        }
        func append(_ bytes: Data) {
            append(bytes.count)
            scrap.append(bytes)
        }
        for item in items {
            append(item.count)
            for flavor in item {
                append(Data(flavor.uti.utf8))
                append(0) // flags
                append(flavor.tags.count)
                for (tagClass, value) in flavor.tags {
                    append(Data(tagClass.utf8))
                    append(Data(value.utf8))
                }
                append(flavor.data)
            }
        }
        return scrap
    }
}
