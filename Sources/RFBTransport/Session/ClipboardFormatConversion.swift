import CoreGraphics
import Foundation
import ImageIO

/// Microsoft's CF_HTML clipboard format: an ASCII header of byte offsets
/// in front of a UTF-8 document with fragment markers.
enum ClipboardHTMLFragment {
    private static let startMarker = "<!--StartFragment-->"
    private static let endMarker = "<!--EndFragment-->"

    static func wrap(_ html: Data) -> Data {
        let source = String(decoding: html, as: UTF8.self)
        let document: String
        if let bodyOpen = source.range(of: "<body", options: .caseInsensitive),
           let bodyTagEnd = source[bodyOpen.upperBound...].firstIndex(of: ">"),
           let bodyClose = source.range(
               of: "</body", options: [.caseInsensitive, .backwards]),
           bodyClose.lowerBound > bodyTagEnd {
            let contentStart = source.index(after: bodyTagEnd)
            document = String(source[..<contentStart]) + startMarker
                + String(source[contentStart..<bodyClose.lowerBound]) + endMarker
                + String(source[bodyClose.lowerBound...])
        } else {
            document = "<html><body>\r\n" + startMarker + source + endMarker
                + "\r\n</body>\r\n</html>"
        }

        let body = Data(document.utf8)
        let fragmentStart = body.range(of: Data(startMarker.utf8))!.upperBound
        let fragmentEnd = body.range(of: Data(endMarker.utf8))!.lowerBound
        func header(_ start: Int, _ end: Int, _ fragmentStart: Int, _ fragmentEnd: Int) -> String {
            func field(_ value: Int) -> String {
                let digits = String(value)
                return String(repeating: "0", count: max(0, 10 - digits.count)) + digits
            }
            return "Version:0.9\r\n"
                + "StartHTML:\(field(start))\r\n"
                + "EndHTML:\(field(end))\r\n"
                + "StartFragment:\(field(fragmentStart))\r\n"
                + "EndFragment:\(field(fragmentEnd))\r\n"
        }
        let headerLength = header(0, 0, 0, 0).utf8.count
        var result = Data(header(
            headerLength,
            headerLength + body.count,
            headerLength + fragmentStart,
            headerLength + fragmentEnd).utf8)
        result.append(body)
        return result
    }

    /// The copied fragment inside CF_HTML in the context it renders in (see
    /// ``contextualized(prefix:fragment:)``), or `data` unchanged when it has
    /// no header. Adds a UTF-8 charset declaration when the result has none.
    static func unwrap(_ data: Data) -> Data {
        let data = Data(data)
        guard data.starts(with: Data("Version:".utf8)) else { return data }

        let headerEnd = data.firstIndex(of: UInt8(ascii: "<")) ?? data.endIndex
        let header = String(decoding: data[..<headerEnd], as: UTF8.self)
        func offset(_ name: String) -> Int? {
            guard let line = header
                .split(whereSeparator: { $0 == "\r" || $0 == "\n" })
                .first(where: { $0.hasPrefix(name + ":") }) else { return nil }
            return Int(line.dropFirst(name.count + 1).trimmingCharacters(in: .whitespaces))
        }
        func valid(_ start: Int?, _ end: Int?) -> Range<Int>? {
            guard let start, let end, start >= 0, start < end, end <= data.count else {
                return nil
            }
            return start..<end
        }

        func betweenMarkers() -> Range<Int>? {
            guard let start = data.range(of: Data(startMarker.utf8))?.upperBound,
                  let end = data.range(
                      of: Data(endMarker.utf8), in: start..<data.endIndex)?.lowerBound
            else { return nil }
            return start..<end
        }

        let document = valid(offset("StartHTML"), offset("EndHTML"))
        var html: String
        if let fragment = valid(offset("StartFragment"), offset("EndFragment"))
            ?? betweenMarkers() {
            let documentStart = min(document?.lowerBound ?? headerEnd, fragment.lowerBound)
            html = contextualized(
                prefix: String(decoding: data[documentStart..<fragment.lowerBound], as: UTF8.self),
                fragment: String(decoding: data[fragment], as: UTF8.self))
        } else {
            html = String(decoding: data[document ?? headerEnd..<data.endIndex], as: UTF8.self)
        }
        if !html.lowercased().contains("charset") {
            html = "<meta charset=\"utf-8\">" + html
        }
        return Data(html.utf8)
    }

    private static let voidElements: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input", "link",
        "meta", "param", "source", "track", "wbr",
    ]
    private static let rawTextElements: Set<String> = [
        "script", "style", "textarea", "title", "xmp", "noscript",
    ]

    /// The fragment inside the document's head, body styles, and the elements
    /// still open where it starts, so class and inherited styles survive.
    /// Unselected siblings, text, and scripts before the fragment are dropped.
    static func contextualized(prefix: String, fragment: String) -> String {
        var head = ""
        var styles = ""
        var bodyTag = "<body>"
        var ancestors: [(name: String, tag: String)] = []
        var cursor = prefix.startIndex

        while let tagStart = prefix[cursor...].firstIndex(of: "<") {
            if prefix[tagStart...].hasPrefix("<!--") {
                cursor = prefix.range(of: "-->", range: tagStart..<prefix.endIndex)?
                    .upperBound ?? prefix.endIndex
                continue
            }
            guard let tagEnd = endOfTag(in: prefix, from: tagStart) else { break }
            let tag = String(prefix[tagStart..<tagEnd])
            cursor = tagEnd
            guard let (name, closing) = element(of: tag) else { continue }

            if closing {
                if let index = ancestors.lastIndex(where: { $0.name == name }) {
                    ancestors.removeSubrange(index...)
                }
                continue
            }
            switch name {
            case "html":
                continue
            case "head":
                let end = endOfElement("head", in: prefix, from: tagEnd) ?? prefix.endIndex
                head = String(prefix[tagStart..<end])
                cursor = end
            case "body":
                bodyTag = tag
                ancestors.removeAll()
            case "link":
                styles += tag
            case "style":
                let end = endOfElement("style", in: prefix, from: tagEnd) ?? prefix.endIndex
                styles += prefix[tagStart..<end]
                cursor = end
            case _ where rawTextElements.contains(name):
                cursor = endOfElement(name, in: prefix, from: tagEnd) ?? prefix.endIndex
            case _ where voidElements.contains(name) || tag.hasSuffix("/>"):
                continue
            default:
                ancestors.append((name, tag))
            }
        }

        if head.isEmpty {
            head = "<head>" + styles + "</head>"
        } else if !styles.isEmpty,
                  let close = head.range(of: "</head", options: [.caseInsensitive, .backwards]) {
            head.insert(contentsOf: styles, at: close.lowerBound)
        }
        let closings = ancestors.reversed().map { "</\($0.name)>" }.joined()
        return "<html>" + head + bodyTag + ancestors.map(\.tag).joined()
            + fragment + closings + "</body></html>"
    }

    /// Lowercased element name and whether the tag closes it; nil for
    /// doctypes and processing instructions.
    private static func element(of tag: String) -> (String, Bool)? {
        var body = tag.dropFirst()
        let closing = body.hasPrefix("/")
        if closing { body = body.dropFirst() }
        let name = body.prefix { $0.isLetter || $0.isNumber || $0 == "-" }.lowercased()
        return name.isEmpty ? nil : (name, closing)
    }

    /// Index after the `>` ending the tag at `start`, skipping quoted values.
    private static func endOfTag(in html: String, from start: String.Index) -> String.Index? {
        var quote: Character?
        var index = html.index(after: start)
        while index < html.endIndex {
            let character = html[index]
            if let open = quote {
                if character == open { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == ">" {
                return html.index(after: index)
            }
            index = html.index(after: index)
        }
        return nil
    }

    /// Index after the closing tag of `name`, searching from `start`.
    private static func endOfElement(
        _ name: String,
        in html: String,
        from start: String.Index
    ) -> String.Index? {
        guard let close = html.range(
            of: "</" + name, options: .caseInsensitive, range: start..<html.endIndex),
              let end = endOfTag(in: html, from: close.lowerBound) else { return nil }
        return end
    }
}

/// Clipboard images are decoded only when their header dimensions fit, so a
/// small, highly compressed file cannot demand gigabytes of pixels.
package enum ClipboardImageBudget {
    package static let maximumDecodedBytes = 100 * 1024 * 1024

    /// RGBA bytes the first image decodes to, read from its header.
    package static func decodedByteCount(of source: CGImageSource) -> Int? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else {
            return nil
        }
        let (pixels, pixelsOverflow) = width.multipliedReportingOverflow(by: height)
        let (bytes, bytesOverflow) = pixels.multipliedReportingOverflow(by: 4)
        return pixelsOverflow || bytesOverflow ? nil : bytes
    }

    /// The first image, or nil when it is unreadable or over `maximumBytes`.
    package static func image(
        from data: Data,
        maximumBytes: Int = maximumDecodedBytes
    ) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let bytes = decodedByteCount(of: source), bytes <= maximumBytes else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

/// Windows device-independent bitmaps for ExtendedClipboard's `dib` format.
enum ClipboardDIB {
    private static let v5HeaderSize = 124

    /// A 32-bit BITMAPV5 DIB (no file header) from any ImageIO-readable image.
    static func dib(fromImage data: Data) -> Data? {
        guard let image = ClipboardImageBudget.image(from: data) else { return nil }
        let width = image.width
        let height = image.height
        let rowBytes = width * 4
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: rowBytes,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                      | CGBitmapInfo.byteOrder32Little.rawValue),
              let pixels = context.data else {
            return nil
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var dib = Data(capacity: v5HeaderSize + rowBytes * height)
        appendLE(UInt32(v5HeaderSize), to: &dib)
        appendLE(UInt32(width), to: &dib)
        appendLE(UInt32(height), to: &dib) // positive: bottom-up rows
        appendLE(UInt16(1), to: &dib) // planes
        appendLE(UInt16(32), to: &dib) // bits per pixel
        appendLE(UInt32(3), to: &dib) // BI_BITFIELDS
        appendLE(UInt32(rowBytes * height), to: &dib)
        appendLE(UInt32(2835), to: &dib) // 72 dpi
        appendLE(UInt32(2835), to: &dib)
        appendLE(UInt32(0), to: &dib) // colors used
        appendLE(UInt32(0), to: &dib) // colors important
        appendLE(UInt32(0x00FF_0000), to: &dib) // red mask
        appendLE(UInt32(0x0000_FF00), to: &dib) // green mask
        appendLE(UInt32(0x0000_00FF), to: &dib) // blue mask
        appendLE(UInt32(0xFF00_0000), to: &dib) // alpha mask
        appendLE(UInt32(0x7352_4742), to: &dib) // LCS_sRGB
        dib.append(Data(count: 36 + 12)) // endpoints, gamma
        appendLE(UInt32(4), to: &dib) // LCS_GM_IMAGES
        dib.append(Data(count: 12)) // profile data, size, reserved

        let rows = UnsafeRawBufferPointer(start: pixels, count: rowBytes * height)
        for row in stride(from: height - 1, through: 0, by: -1) {
            dib.append(contentsOf: rows[row * rowBytes..<(row + 1) * rowBytes])
        }
        return dib
    }

    /// A BMP file for a header-less DIB, so ImageIO can decode it.
    static func bmpFile(fromDIB dib: Data) -> Data? {
        let dib = Data(dib)
        func uint16(_ offset: Int) -> Int? {
            guard offset + 2 <= dib.count else { return nil }
            return Int(dib[offset]) | Int(dib[offset + 1]) << 8
        }
        func uint32(_ offset: Int) -> Int? {
            guard offset + 4 <= dib.count else { return nil }
            return (0..<4).reduce(0) { $0 | Int(dib[offset + $1]) << (8 * $1) }
        }

        guard let headerSize = uint32(0), headerSize >= 12, headerSize <= dib.count else {
            return nil
        }
        let bitCount: Int
        var maskBytes = 0
        var colorsUsed = 0
        let colorEntrySize: Int
        if headerSize == 12 {
            guard let bits = uint16(10) else { return nil }
            bitCount = bits
            colorEntrySize = 3
        } else {
            guard let bits = uint16(14), let compression = uint32(16) else { return nil }
            bitCount = bits
            colorsUsed = uint32(32) ?? 0
            colorEntrySize = 4
            if headerSize == 40, compression == 3 { maskBytes = 12 }
            if headerSize == 40, compression == 6 { maskBytes = 16 }
        }
        let colorEntries = bitCount <= 8 && colorsUsed == 0 ? 1 << bitCount : colorsUsed
        let pixelOffset = 14 + headerSize + maskBytes + colorEntries * colorEntrySize
        guard pixelOffset - 14 <= dib.count else { return nil }

        var file = Data("BM".utf8)
        appendLE(UInt32(14 + dib.count), to: &file)
        appendLE(UInt32(0), to: &file) // reserved
        appendLE(UInt32(pixelOffset), to: &file)
        file.append(dib)
        return file
    }

    private static func appendLE<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
}
