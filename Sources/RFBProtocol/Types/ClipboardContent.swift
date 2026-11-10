import Foundation

/// Pasteboard type identifiers bridged between the device and a remote server.
public enum ClipboardType {
    public static let utf8PlainText = "public.utf8-plain-text"
    public static let utf16PlainText = "public.utf16-plain-text"
    public static let rtf = "public.rtf"
    public static let flatRTFD = "com.apple.flat-rtfd"
    public static let html = "public.html"
    public static let png = "public.png"
    public static let jpeg = "public.jpeg"
    public static let tiff = "public.tiff"
    public static let gif = "com.compuserve.gif"
    public static let heic = "public.heic"
    /// Inbound only: an ExtendedClipboard DIB with its file header restored.
    public static let bmp = "com.microsoft.bmp"

    /// Types read from the local pasteboard and sent to a server.
    public static let outbound: Set<String> = [
        utf8PlainText, rtf, flatRTFD, html, png, jpeg, tiff, gif, heic,
    ]

    public static let images: Set<String> = [png, jpeg, tiff, gif, heic, bmp]

    /// Images that every receiving app is expected to read directly.
    public static let commonImages: Set<String> = [png, jpeg, gif]

    /// Canonical UTI for a pasteboard type name, MIME type, or legacy
    /// pasteboard name. `nil` when the type is not bridged.
    public static func canonical(_ name: String) -> String? {
        switch name {
        case utf8PlainText, "public.plain-text", "NSStringPboardType",
             "text/plain", "text/plain;charset=utf-8":
            return utf8PlainText
        case utf16PlainText:
            return utf16PlainText
        case rtf, "text/rtf", "application/rtf",
             "NeXT Rich Text Format v1.0 pasteboard type":
            return rtf
        case flatRTFD:
            return flatRTFD
        case html, "text/html", "Apple HTML pasteboard type":
            return html
        case png, "image/png", "Apple PNG pasteboard type":
            return png
        case jpeg, "image/jpeg":
            return jpeg
        case tiff, "image/tiff", "NeXT TIFF v4.0 pasteboard type":
            return tiff
        case gif, "image/gif":
            return gif
        case heic, "image/heic":
            return heic
        case bmp, "image/bmp":
            return bmp
        default:
            return nil
        }
    }
}

/// Clipboard data exchanged with a remote server: pasteboard items, each
/// holding its representations in the source's fidelity order.
public struct ClipboardContent: Sendable, Equatable {
    public struct Representation: Sendable, Equatable {
        public var type: String
        public var data: Data

        public init(type: String, data: Data) {
            self.type = type
            self.data = data
        }
    }

    public typealias Item = [Representation]

    public private(set) var items: [Item]

    public init(items: [Item]) {
        self.items = items.filter { !$0.isEmpty }
    }

    public static func text(_ text: String) -> ClipboardContent {
        ClipboardContent(items: [[
            Representation(type: ClipboardType.utf8PlainText, data: Data(text.utf8)),
        ]])
    }

    public var isEmpty: Bool { items.isEmpty }

    public var byteCount: Int {
        items.reduce(0) { total, item in
            item.reduce(total) { $0 + $1.data.count }
        }
    }

    /// Plain text of every item that has it, one item per line.
    public var plainText: String? {
        let texts = items.compactMap { item in
            item.first { $0.type == ClipboardType.utf8PlainText }
                .map { String(decoding: $0.data, as: UTF8.self) }
        }
        return texts.isEmpty ? nil : texts.joined(separator: "\n")
    }

    /// Whether any representation carries more than plain text.
    public var hasRichContent: Bool {
        items.contains { item in
            item.contains { $0.type != ClipboardType.utf8PlainText }
        }
    }

    public func contains(type: String) -> Bool {
        items.contains { item in item.contains { $0.type == type } }
    }

    /// Types and sizes only, safe to log.
    public var summary: String {
        items.map { item in
            item.map { "\($0.type)=\($0.data.count)" }.joined(separator: ",")
        }.joined(separator: " | ")
    }

    public func filtered(
        _ isIncluded: (Representation) -> Bool
    ) -> ClipboardContent {
        ClipboardContent(items: items.map { $0.filter(isIncluded) })
    }

    /// Drop representations until the content fits `maxBytes`: redundant
    /// images and RTFD first, then the largest remaining non-text data.
    /// Plain text is never dropped.
    public func fitted(maxBytes: Int) -> ClipboardContent {
        var result = self
        while result.byteCount > maxBytes,
              let victim = result.nextRepresentationToDrop() {
            result.items[victim.item].remove(at: victim.representation)
        }
        result.items.removeAll { $0.isEmpty }
        return result
    }

    private func nextRepresentationToDrop() -> (item: Int, representation: Int)? {
        func types(_ item: Item) -> Set<String> { Set(item.map(\.type)) }

        for (itemIndex, item) in items.enumerated() {
            let present = types(item)
            if !present.isDisjoint(with: [ClipboardType.png, ClipboardType.jpeg]),
               let index = item.firstIndex(where: {
                   [ClipboardType.tiff, ClipboardType.bmp, ClipboardType.heic]
                       .contains($0.type)
               }) {
                return (itemIndex, index)
            }
        }
        for (itemIndex, item) in items.enumerated()
        where types(item).contains(ClipboardType.rtf) {
            if let index = item.firstIndex(where: { $0.type == ClipboardType.flatRTFD }) {
                return (itemIndex, index)
            }
        }

        var largest: (item: Int, representation: Int, size: Int)?
        for (itemIndex, item) in items.enumerated() {
            for (index, representation) in item.enumerated()
            where representation.type != ClipboardType.utf8PlainText {
                if representation.data.count > (largest?.size ?? -1) {
                    largest = (itemIndex, index, representation.data.count)
                }
            }
        }
        return largest.map { ($0.item, $0.representation) }
    }
}

/// Which clipboard representations the connected server can receive.
public enum ClipboardContentSupport: Sendable, Equatable {
    /// Legacy cut text only.
    case plainText
    /// ExtendedClipboard: the formats both sides agreed on.
    case formats(Set<String>)
    /// Apple's packed pasteboard: every bridged type.
    case all

    public func accepts(_ type: String) -> Bool {
        switch self {
        case .plainText:
            return type == ClipboardType.utf8PlainText
        case .formats(let types):
            return type == ClipboardType.utf8PlainText || types.contains(type)
        case .all:
            return true
        }
    }

    public var acceptsRichContent: Bool {
        switch self {
        case .plainText:
            return false
        case .formats(let types):
            return !types.subtracting([ClipboardType.utf8PlainText]).isEmpty
        case .all:
            return true
        }
    }
}
