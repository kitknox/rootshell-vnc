import Foundation
import RFBProtocol

/// The private pasteboard extension used by Apple's Screen Sharing client.
/// A packed scrap holds every pasteboard item and flavor; only the types in
/// ``ClipboardType`` are kept, and a malformed scrap never ends the session.
enum AppleClipboardProtocol {
    static let requestMessageType: UInt8 = 11
    static let autoPasteboardMessageType: UInt8 = 21
    static let packedScrapMessageType: UInt8 = 31
    static let packedScrapHeaderSize = 16
    static let maximumClipboardSize = 100 * 1024 * 1024
    /// Apple's viewer refuses to send more than this, compressed.
    static let maximumSendSize = 7 * 1024 * 1024

    static func requestMessage(requestID: UInt32 = 0) -> Data {
        var data = Data([requestMessageType, 0, 0, 0])
        appendUInt32BE(requestID, to: &data)
        return data
    }

    static func autoPasteboardMessage(enabled: Bool) -> Data {
        Data([
            autoPasteboardMessageType, 0,
            0, enabled ? 1 : 2,
            0, 0, 0, 0,
        ])
    }

    static func packedTextMessage(_ text: String) throws -> Data {
        try packedMessage(.text(text))
    }

    /// Serialize complete pasteboard data (byte two stays zero: not a
    /// promise). Representations are dropped as needed to fit Apple's send
    /// limit; plain text never is.
    static func packedMessage(_ content: ClipboardContent) throws -> Data {
        var candidate = content.fitted(maxBytes: maximumClipboardSize - 64 * 1024)
        for _ in 0..<4 {
            let scrap = pack(candidate)
            guard scrap.count <= maximumClipboardSize else { break }
            let compressed = try ClipboardCompression.deflate(
                scrap, finishStream: false, outputLimit: maximumClipboardSize)
            if !compressed.isEmpty, compressed.count <= maximumSendSize {
                var message = Data([
                    packedScrapMessageType, 0, 0, 0,
                    0, 0, 0, 0,
                ])
                appendUInt32BE(UInt32(scrap.count), to: &message)
                appendUInt32BE(UInt32(compressed.count), to: &message)
                message.append(compressed)
                return message
            }
            // Images barely compress, so scaling by the observed ratio lands
            // close to the limit in one more pass.
            let ratio = Double(maximumSendSize) / Double(compressed.count)
            let next = candidate.fitted(
                maxBytes: Int(Double(candidate.byteCount) * ratio * 0.95))
            guard next != candidate else { break }
            candidate = next
        }
        throw VNCProtocolError.protocolViolation(
            "Apple clipboard size is out of range")
    }

    static func pack(_ content: ClipboardContent) -> Data {
        var scrap = Data(capacity: content.byteCount + 64)
        for item in content.items {
            appendUInt32BE(UInt32(item.count), to: &scrap)
            for representation in item {
                let type = Data(representation.type.utf8)
                appendUInt32BE(UInt32(type.count), to: &scrap)
                scrap.append(type)
                appendUInt32BE(0, to: &scrap) // flavor flags
                appendUInt32BE(0, to: &scrap) // no UTI tags
                appendUInt32BE(UInt32(representation.data.count), to: &scrap)
                scrap.append(representation.data)
            }
        }
        return scrap
    }

    static func unpackContent(
        compressed: Data,
        uncompressedSize: Int
    ) throws -> ClipboardContent {
        guard uncompressedSize > 0,
              uncompressedSize <= maximumClipboardSize,
              !compressed.isEmpty,
              compressed.count <= maximumClipboardSize else {
            throw VNCProtocolError.protocolViolation(
                "Apple clipboard size is out of range")
        }

        // Native client uploads stop at a Z_SYNC_FLUSH boundary, while server
        // responses may also use a complete stream; this inflater accepts both.
        let inflater = try RFBZlibStreamInflater()
        let scrap = try inflater.decompress(
            compressed,
            maxOutputSize: uncompressedSize + 1)
        guard scrap.count == uncompressedSize else {
            throw VNCProtocolError.protocolViolation(
                "Apple clipboard decompressed length mismatch")
        }
        return try unpack(scrap)
    }

    static func unpackText(
        compressed: Data,
        uncompressedSize: Int
    ) throws -> String? {
        try unpackContent(
            compressed: compressed,
            uncompressedSize: uncompressedSize).plainText
    }

    /// Items are concatenated without an item count.
    static func unpack(_ scrap: Data) throws -> ClipboardContent {
        var cursor = scrap.startIndex
        var items: [ClipboardContent.Item] = []
        while cursor < scrap.endIndex {
            let flavorCount = try readUInt32BE(scrap, cursor: &cursor)
            guard flavorCount <= 4_096 else {
                throw VNCProtocolError.protocolViolation(
                    "Apple clipboard flavor count is out of range")
            }

            var item: ClipboardContent.Item = []
            for _ in 0..<flavorCount {
                // Dynamic types arrive with an empty UTI and a MIME tag.
                var names = [try readPackedString(scrap, cursor: &cursor)]
                _ = try readUInt32BE(scrap, cursor: &cursor) // flavor flags
                let tagCount = try readUInt32BE(scrap, cursor: &cursor)
                guard tagCount <= 4_096 else {
                    throw VNCProtocolError.protocolViolation(
                        "Apple clipboard UTI tag count is out of range")
                }
                for _ in 0..<tagCount {
                    _ = try readPackedString(scrap, cursor: &cursor)
                    names.append(try readPackedString(scrap, cursor: &cursor))
                }

                let length = Int(try readUInt32BE(scrap, cursor: &cursor))
                guard length <= scrap.endIndex - cursor else {
                    throw VNCProtocolError.protocolViolation(
                        "Truncated Apple clipboard flavor")
                }
                let data = Data(scrap[cursor..<cursor + length])
                cursor += length

                guard let type = names.lazy.compactMap(ClipboardType.canonical).first,
                      let representation = normalized(type: type, data: data),
                      !item.contains(where: { $0.type == representation.type })
                else { continue }
                item.append(representation)
            }
            items.append(item)
        }
        return ClipboardContent(items: items)
    }

    static func uint32BE(_ data: Data, at index: Int) -> UInt32? {
        guard index >= data.startIndex, index + 4 <= data.endIndex else {
            return nil
        }
        return UInt32(data[index]) << 24
            | UInt32(data[index + 1]) << 16
            | UInt32(data[index + 2]) << 8
            | UInt32(data[index + 3])
    }

    /// Text flavors become UTF-8; other bridged types pass through.
    private static func normalized(
        type: String,
        data: Data
    ) -> ClipboardContent.Representation? {
        switch type {
        case ClipboardType.utf16PlainText:
            let text: String?
            if data.starts(with: [0xFE, 0xFF]) || data.starts(with: [0xFF, 0xFE]) {
                text = String(data: data, encoding: .utf16)
            } else {
                text = String(data: data, encoding: .utf16BigEndian)
                    ?? String(data: data, encoding: .utf16LittleEndian)
            }
            return text.map { .init(type: ClipboardType.utf8PlainText, data: Data($0.utf8)) }
        case ClipboardType.utf8PlainText:
            let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
            return text.map { .init(type: type, data: Data($0.utf8)) }
        default:
            return .init(type: type, data: data)
        }
    }

    private static func readPackedString(
        _ data: Data,
        cursor: inout Int
    ) throws -> String {
        let length = Int(try readUInt32BE(data, cursor: &cursor))
        guard length <= data.endIndex - cursor else {
            throw VNCProtocolError.protocolViolation(
                "Truncated Apple clipboard UTI")
        }
        let bytes = Data(data[cursor..<cursor + length])
        cursor += length
        guard let string = String(data: bytes, encoding: .utf8) else {
            throw VNCProtocolError.protocolViolation(
                "Invalid Apple clipboard UTI")
        }
        return string
    }

    private static func readUInt32BE(
        _ data: Data,
        cursor: inout Int
    ) throws -> UInt32 {
        guard let value = uint32BE(data, at: cursor) else {
            throw VNCProtocolError.protocolViolation(
                "Truncated Apple clipboard scrap")
        }
        cursor += 4
        return value
    }

    static func appendUInt32BE(_ value: UInt32, to data: inout Data) {
        data.append(UInt8((value >> 24) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }
}
