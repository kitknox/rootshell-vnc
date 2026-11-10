import Foundation
import RFBProtocol

/// The RFB ExtendedClipboard pseudo-encoding: cut text with a negative S32
/// length carries a flags word (formats in bits 0-15, one action in 24-31)
/// and an action-specific body.
enum ExtendedClipboardProtocol {
    static let maximumPayloadSize = AppleClipboardProtocol.maximumClipboardSize

    struct Formats: OptionSet, Hashable, Sendable {
        let rawValue: UInt32
        static let text = Formats(rawValue: 1 << 0)
        static let rtf = Formats(rawValue: 1 << 1)
        static let html = Formats(rawValue: 1 << 2)
        static let dib = Formats(rawValue: 1 << 3)
        static let mask: UInt32 = 0xFFFF

        /// Single-bit values in ascending order, the order used on the wire.
        var bits: [UInt32] {
            (0..<16).map { UInt32(1) << $0 }.filter { rawValue & $0 != 0 }
        }

        init(rawValue: UInt32) { self.rawValue = rawValue & Self.mask }

        init<S: Sequence>(bits: S) where S.Element == UInt32 {
            self.init(rawValue: bits.reduce(0, |))
        }
    }

    struct Actions: OptionSet, Hashable, Sendable {
        let rawValue: UInt32
        static let caps = Actions(rawValue: 1 << 24)
        static let request = Actions(rawValue: 1 << 25)
        static let peek = Actions(rawValue: 1 << 26)
        static let notify = Actions(rawValue: 1 << 27)
        static let provide = Actions(rawValue: 1 << 28)

        init(rawValue: UInt32) { self.rawValue = rawValue & 0xFF00_0000 }
    }

    enum Message: Equatable, Sendable {
        /// Formats and actions the sender accepts, with its maximum
        /// unsolicited provide size per format bit.
        case caps(Formats, Actions, maximumSizes: [UInt32: UInt32])
        case request(Formats)
        case peek
        case notify(Formats)
        /// Data per format bit.
        case provide([UInt32: Data])
    }

    static let clientFormats: Formats = [.text, .rtf, .html, .dib]
    static let clientActions: Actions = [.request, .peek, .notify, .provide]

    /// Zero sizes ask the server to announce every change with notify.
    static var clientCaps: Message {
        .caps(
            clientFormats,
            clientActions,
            maximumSizes: Dictionary(uniqueKeysWithValues: clientFormats.bits.map { ($0, 0) }))
    }

    // MARK: - Wire format

    static func parse(_ payload: Data) throws -> Message {
        let payload = Data(payload)
        guard let flags = AppleClipboardProtocol.uint32BE(payload, at: 0) else {
            throw VNCProtocolError.protocolViolation(
                "Extended clipboard message is truncated")
        }
        let formats = Formats(rawValue: flags)
        let actions = Actions(rawValue: flags)

        if actions.contains(.caps) {
            var sizes: [UInt32: UInt32] = [:]
            for (index, bit) in formats.bits.enumerated() {
                guard let size = AppleClipboardProtocol.uint32BE(
                    payload, at: 4 + index * 4) else {
                    throw VNCProtocolError.protocolViolation(
                        "Extended clipboard caps are truncated")
                }
                sizes[bit] = size
            }
            return .caps(formats, actions.subtracting(.caps), maximumSizes: sizes)
        }
        if actions.contains(.provide) {
            let stream = try ClipboardCompression.inflate(
                payload.dropFirst(4), outputLimit: maximumPayloadSize)
            var provided: [UInt32: Data] = [:]
            var cursor = 0
            for bit in formats.bits {
                guard let size = AppleClipboardProtocol.uint32BE(stream, at: cursor) else {
                    break
                }
                cursor += 4
                guard Int(size) <= stream.count - cursor else {
                    throw VNCProtocolError.protocolViolation(
                        "Extended clipboard data is truncated")
                }
                provided[bit] = Data(stream[cursor..<cursor + Int(size)])
                cursor += Int(size)
            }
            return .provide(provided)
        }
        if actions.contains(.notify) { return .notify(formats) }
        if actions.contains(.request) { return .request(formats) }
        if actions.contains(.peek) { return .peek }
        throw VNCProtocolError.protocolViolation(
            "Extended clipboard message has no known action")
    }

    /// A complete ClientCutText message carrying `message`.
    static func clientMessage(_ message: Message) throws -> Data {
        var payload = Data()
        switch message {
        case .caps(let formats, let actions, let sizes):
            append(formats.rawValue | actions.rawValue | Actions.caps.rawValue, to: &payload)
            for bit in formats.bits { append(sizes[bit] ?? 0, to: &payload) }
        case .request(let formats):
            append(formats.rawValue | Actions.request.rawValue, to: &payload)
        case .peek:
            append(Actions.peek.rawValue, to: &payload)
        case .notify(let formats):
            append(formats.rawValue | Actions.notify.rawValue, to: &payload)
        case .provide(let provided):
            let formats = Formats(bits: provided.keys)
            append(formats.rawValue | Actions.provide.rawValue, to: &payload)
            var stream = Data()
            for bit in formats.bits {
                let data = provided[bit] ?? Data()
                append(UInt32(data.count), to: &stream)
                stream.append(data)
            }
            payload.append(try ClipboardCompression.deflate(
                stream, finishStream: true, outputLimit: maximumPayloadSize))
        }

        guard payload.count <= maximumPayloadSize else {
            throw VNCProtocolError.protocolViolation(
                "Extended clipboard size is out of range")
        }
        var message = Data([6, 0, 0, 0])
        append(UInt32(bitPattern: -Int32(payload.count)), to: &message)
        message.append(payload)
        return message
    }

    // MARK: - Content conversion

    /// Bridged types a server accepting `formats` can receive.
    static func support(for formats: Formats) -> ClipboardContentSupport {
        var types: Set<String> = []
        if formats.contains(.text) { types.insert(ClipboardType.utf8PlainText) }
        if formats.contains(.rtf) { types.insert(ClipboardType.rtf) }
        if formats.contains(.html) { types.insert(ClipboardType.html) }
        if formats.contains(.dib) {
            types.formUnion(ClipboardType.images.subtracting([ClipboardType.bmp]))
        }
        return .formats(types)
    }

    /// Wire data per format. Image conversion is CPU-bound, so callers on
    /// the transport actor run this detached.
    static func encode(
        _ content: ClipboardContent,
        accepting formats: Formats
    ) -> [UInt32: Data] {
        let representations = content.items.flatMap { $0 }
        func first(_ type: String) -> Data? {
            representations.first { $0.type == type }?.data
        }

        var provided: [UInt32: Data] = [:]
        if formats.contains(.text), let text = content.plainText {
            let crlf = text
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\n", with: "\r\n")
            provided[Formats.text.rawValue] = nulTerminated(Data(crlf.utf8))
        }
        if formats.contains(.rtf), let rtf = first(ClipboardType.rtf) {
            provided[Formats.rtf.rawValue] = nulTerminated(rtf)
        }
        if formats.contains(.html), let html = first(ClipboardType.html) {
            provided[Formats.html.rawValue] = nulTerminated(ClipboardHTMLFragment.wrap(html))
        }
        if formats.contains(.dib),
           let image = representations.first(where: {
               ClipboardType.images.contains($0.type)
           }),
           let dib = ClipboardDIB.dib(fromImage: image.data) {
            provided[Formats.dib.rawValue] = dib
        }
        return provided
    }

    static func decode(_ provided: [UInt32: Data]) -> ClipboardContent {
        var item: ClipboardContent.Item = []
        if let rtf = provided[Formats.rtf.rawValue].map(trimmingNULs), !rtf.isEmpty {
            item.append(.init(type: ClipboardType.rtf, data: rtf))
        }
        if let html = provided[Formats.html.rawValue].map(trimmingNULs), !html.isEmpty {
            item.append(.init(
                type: ClipboardType.html,
                data: ClipboardHTMLFragment.unwrap(html)))
        }
        if let dib = provided[Formats.dib.rawValue],
           let bmp = ClipboardDIB.bmpFile(fromDIB: dib) {
            item.append(.init(type: ClipboardType.bmp, data: bmp))
        }
        if let data = provided[Formats.text.rawValue].map(trimmingNULs) {
            let text = (String(data: data, encoding: .utf8)
                ?? String(decoding: data, as: UTF8.self))
                .replacingOccurrences(of: "\r\n", with: "\n")
            item.append(.init(type: ClipboardType.utf8PlainText, data: Data(text.utf8)))
        }
        return ClipboardContent(items: [item])
    }

    private static func nulTerminated(_ data: Data) -> Data {
        data.last == 0 ? data : data + [0]
    }

    private static func trimmingNULs(_ data: Data) -> Data {
        var end = data.endIndex
        while end > data.startIndex, data[end - 1] == 0 { end -= 1 }
        return Data(data[data.startIndex..<end])
    }

    private static func append(_ value: UInt32, to data: inout Data) {
        AppleClipboardProtocol.appendUInt32BE(value, to: &data)
    }
}
