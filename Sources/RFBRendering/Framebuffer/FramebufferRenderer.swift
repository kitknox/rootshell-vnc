import Foundation
import CoreGraphics
import CoreVideo
import ImageIO
import RFBProtocol

// MARK: - Rendering Errors

/// Errors that can occur during framebuffer rendering operations.
public enum RenderingError: Error, Sendable, LocalizedError {
    case insufficientData(expected: Int, got: Int)
    case decompressionFailed(String)
    case unsupportedEncoding(Encoding)
    case invalidTileData(String)

    public var errorDescription: String? {
        switch self {
        case .insufficientData(let expected, let got):
            return "Insufficient data: expected \(expected) bytes, got \(got)"
        case .decompressionFailed(let detail):
            return "Decompression failed: \(detail)"
        case .unsupportedEncoding(let encoding):
            return "Unsupported encoding: \(encoding)"
        case .invalidTileData(let detail):
            return "Invalid tile data: \(detail)"
        }
    }
}

/// Result of applying one complete server framebuffer update off the UI actor.
public struct FramebufferRenderBatchResult: @unchecked Sendable {
    public let image: CGImage?
    public let resizedWidth: UInt16?
    public let resizedHeight: UInt16?
    /// Non-nil only when this update carried a Cursor pseudo-encoding rect.
    public let cursorUpdate: RemoteCursorUpdate?
    public let issues: [String]
    /// Tight pixel rectangles modified in the framebuffer by this batch.
    public let dirtyRects: [CGRect]

    public init(
        image: CGImage?,
        resizedWidth: UInt16?,
        resizedHeight: UInt16?,
        cursorUpdate: RemoteCursorUpdate?,
        issues: [String],
        dirtyRects: [CGRect] = []
    ) {
        self.image = image
        self.resizedWidth = resizedWidth
        self.resizedHeight = resizedHeight
        self.cursorUpdate = cursorUpdate
        self.issues = issues
        self.dirtyRects = dirtyRects
    }
}

// MARK: - FramebufferRenderer

/// Applies decoded encoding data to the framebuffer.
public final class FramebufferRenderer: @unchecked Sendable {

    private let framebuffer: Framebuffer
    private let pixelFormat: PixelFormat
    private var rawDecoder: RawEncodingRenderer
    private var zlibDecoder: ZlibEncodingRenderer
    private var zrleDecoder: ZRLEEncodingRenderer
    private var tightDecoder: TightEncodingRenderer
    private var appleDCTDecoder: AppleAdaptiveDCTDecoder
    private var appleCursorCache: [UInt32: RemoteCursor] = [:]
    private let surfacePool = FramebufferSurfacePool()

    public init(framebuffer: Framebuffer, pixelFormat: PixelFormat) {
        self.framebuffer = framebuffer
        self.pixelFormat = pixelFormat
        self.rawDecoder = RawEncodingRenderer()
        self.zlibDecoder = ZlibEncodingRenderer()
        self.zrleDecoder = ZRLEEncodingRenderer()
        self.tightDecoder = TightEncodingRenderer()
        self.appleDCTDecoder = AppleAdaptiveDCTDecoder()
    }

    /// Apply a rectangle update to the framebuffer.
    /// `data` contains the encoding-specific payload.
    public func applyRect(rect: FramebufferRect, data: Data) throws {
        if let dirty = try applyRectTrackingDirty(rect: rect, data: data) {
            surfacePool.recordDirtyRects(
                [dirty],
                width: framebuffer.width,
                height: framebuffer.height)
        }
    }

    private func applyRectTrackingDirty(
        rect: FramebufferRect,
        data: Data
    ) throws -> CGRect? {
        switch rect.encoding {
        case .raw:
            rawDecoder.render(
                rect: rect, data: data,
                to: framebuffer, pixelFormat: pixelFormat
            )
            return CGRect(
                x: Int(rect.x), y: Int(rect.y),
                width: Int(rect.width), height: Int(rect.height))
        case .zlib:
            try zlibDecoder.render(
                rect: rect, data: data,
                to: framebuffer, pixelFormat: pixelFormat
            )
            return CGRect(
                x: Int(rect.x), y: Int(rect.y),
                width: Int(rect.width), height: Int(rect.height))
        case .zrle:
            try zrleDecoder.render(
                rect: rect, data: data,
                to: framebuffer, pixelFormat: pixelFormat
            )
            return CGRect(
                x: Int(rect.x), y: Int(rect.y),
                width: Int(rect.width), height: Int(rect.height))
        case .tight:
            try tightDecoder.render(
                rect: rect, data: data,
                to: framebuffer, pixelFormat: pixelFormat
            )
            return CGRect(
                x: Int(rect.x), y: Int(rect.y),
                width: Int(rect.width), height: Int(rect.height))
        case .appleMultiVariantScreenshare:
            return try appleDCTDecoder.render(
                rect: rect, payload: data, to: framebuffer)
        default:
            throw RenderingError.unsupportedEncoding(rect.encoding)
        }
    }

    /// Apply every rectangle in one server update in wire order and snapshot
    /// once. Keeping this operation on a serial rendering queue preserves the
    /// persistent Zlib/ZRLE dictionary without blocking the main actor.
    ///
    /// Pass `snapshot: false` to apply rects without paying for the
    /// full-framebuffer image copy — the result's `image` is nil and the
    /// caller publishes a later snapshot or IOSurface sync instead.
    public func applyBatch(
        _ rects: [(FramebufferRect, Data)],
        snapshot takeSnapshot: Bool = true
    ) -> FramebufferRenderBatchResult {
        var resizedWidth: UInt16?
        var resizedHeight: UInt16?
        var cursorUpdate: RemoteCursorUpdate?
        var issues: [String] = []
        var dirtyRegion = FramebufferDirtyRegion()

        for (rect, data) in rects {
            switch rect.encoding {
            case .copyRect:
                guard data.count >= 4 else {
                    issues.append("CopyRect payload is shorter than 4 bytes")
                    continue
                }
                let srcX = UInt16(data[data.startIndex]) << 8
                    | UInt16(data[data.startIndex + 1])
                let srcY = UInt16(data[data.startIndex + 2]) << 8
                    | UInt16(data[data.startIndex + 3])
                copyFramebufferRect(rect: rect, srcX: srcX, srcY: srcY)
                dirtyRegion.insert(
                    x: Int(rect.x), y: Int(rect.y),
                    width: Int(rect.width), height: Int(rect.height),
                    boundsWidth: framebuffer.width,
                    boundsHeight: framebuffer.height)

            case .desktopSize, .extendedDesktopSize:
                guard rect.isSuccessfulDesktopResize else { continue }
                handleDesktopResize(width: rect.width, height: rect.height)
                resizedWidth = rect.width
                resizedHeight = rect.height
                dirtyRegion.markFull()

            case .cursor, .xCursor:
                // Cosmetic: the local system pointer adopts this shape.
                // Never fail the update over a malformed cursor payload.
                if let update = RemoteCursorDecoder.decode(
                    rect: rect, data: data, pixelFormat: pixelFormat) {
                    cursorUpdate = update
                }

            case .unknown(let value) where value == 1104:
                // macOS sends alpha cursors through its own cached pseudo-
                // encoding. Empty records select an earlier cache entry.
                if let record = RemoteCursorDecoder.decodeAppleCursorRecord(
                    rect: rect, data: data) {
                    if let cursor = record.cursor {
                        appleCursorCache[record.identifier] = cursor
                    }
                    if let cursor = appleCursorCache[record.identifier] {
                        cursorUpdate = .shape(cursor)
                    }
                }

            case .lastRect, .encryptionInfo, .serverDisplayInfo,
                 .mediaStreamOffer, .mediaStreamAnswer:
                break

            case .unknown(let value)
                where value == 1100 || value == 1101
                    || value == 1105 || value == 1107
                    || value == 1109 || value == 1110:
                // Capability/control rectangles are consumed by
                // TransportSession and carry no framebuffer pixels.
                break

            default:
                do {
                    if let dirty = try applyRectTrackingDirty(rect: rect, data: data) {
                        dirtyRegion.insert(
                            dirty,
                            boundsWidth: framebuffer.width,
                            boundsHeight: framebuffer.height)
                    }
                } catch {
                    issues.append(
                        "Failed to apply rect (\(rect.encoding)): "
                            + error.localizedDescription)
                }
            }
        }

        let fbWidth = framebuffer.width
        let fbHeight = framebuffer.height
        let dirtyRects = dirtyRegion.cgRects(width: fbWidth, height: fbHeight)
        if dirtyRegion.isFull {
            surfacePool.markFullDirty(width: fbWidth, height: fbHeight)
        } else if !dirtyRects.isEmpty {
            surfacePool.recordDirtyRects(dirtyRects, width: fbWidth, height: fbHeight)
        }

        return FramebufferRenderBatchResult(
            image: takeSnapshot ? snapshot() : nil,
            resizedWidth: resizedWidth,
            resizedHeight: resizedHeight,
            cursorUpdate: cursorUpdate,
            issues: issues,
            dirtyRects: dirtyRects)
    }

    /// Synchronize the next idle `IOSurface`-backed presentation surface with
    /// only the rectangles modified since that surface was last synced.
    public func syncPresentationSurface(
        excluding displayed: FramebufferPresentationSurface? = nil
    ) -> FramebufferPresentationSurface? {
        surfacePool.syncNextSurface(from: framebuffer, excluding: displayed)
    }

    /// Synchronize the next idle `IOSurface`-backed presentation surface,
    /// excluding every surface currently reserved for handoff or presentation.
    public func syncPresentationSurface(
        excluding busySurfaces: [FramebufferPresentationSurface]
    ) -> FramebufferPresentationSurface? {
        surfacePool.syncNextSurface(from: framebuffer, excluding: busySurfaces)
    }

    /// Synchronize the next idle `IOSurface`-backed presentation surface,
    /// returning a structured ``FramebufferSurfaceSyncResult`` distinguishing
    /// busy-slot backpressure from resource allocation/lock failures.
    public func syncPresentationSurfaceResult(
        excluding busySurfaces: [FramebufferPresentationSurface] = []
    ) -> FramebufferSurfaceSyncResult {
        surfacePool.syncNextSurfaceResult(from: framebuffer, excluding: busySurfaces)
    }

    /// Apply a CopyRect (data contains srcX, srcY as 2 UInt16s).
    public func applyCopyRect(rect: FramebufferRect, srcX: UInt16, srcY: UInt16) {
        copyFramebufferRect(rect: rect, srcX: srcX, srcY: srcY)
        surfacePool.recordDirtyRects(
            [CGRect(
                x: Int(rect.x), y: Int(rect.y),
                width: Int(rect.width), height: Int(rect.height))],
            width: framebuffer.width,
            height: framebuffer.height)
    }

    private func copyFramebufferRect(rect: FramebufferRect, srcX: UInt16, srcY: UInt16) {
        framebuffer.copyRect(
            srcX: Int(srcX),
            srcY: Int(srcY),
            dstX: Int(rect.x),
            dstY: Int(rect.y),
            width: Int(rect.width),
            height: Int(rect.height)
        )
    }

    /// Get a snapshot of the current framebuffer.
    public func snapshot() -> CGImage? {
        framebuffer.createImage()
    }

    /// Handle desktop resize.
    public func handleDesktopResize(width: UInt16, height: UInt16) {
        framebuffer.resize(width: Int(width), height: Int(height))
        surfacePool.markFullDirty(width: framebuffer.width, height: framebuffer.height)
    }
}

// MARK: - Tight Encoding Renderer

/// Tight is the first portable classic-RFB fallback. It mixes
/// four persistent zlib streams with fill, palette, gradient and JPEG
/// subencodings, which lets a server send photographic/animated areas without
/// blocking later small UI updates behind a lossless full-screen rectangle.
final class TightEncodingRenderer {
    private var inflaters: [RFBZlibStreamInflater?] = (0..<4).map { _ in
        try? RFBZlibStreamInflater()
    }

    func render(
        rect: FramebufferRect,
        data: Data,
        to framebuffer: Framebuffer,
        pixelFormat: PixelFormat
    ) throws {
        guard !data.isEmpty else {
            throw RenderingError.insufficientData(expected: 1, got: 0)
        }
        var offset = data.startIndex
        let control = data[offset]
        offset += 1
        for stream in 0..<4 where control & (1 << stream) != 0 {
            try inflaters[stream]?.reset()
        }

        let compression = control >> 4
        let compact = usesCompactPixels(pixelFormat)
        let tightPixelSize = compact ? 3 : pixelFormat.bytesPerPixel
        switch compression {
        case 8:
            let pixel = try readPixel(
                data, offset: &offset, size: tightPixelSize,
                compact: compact)
            framebuffer.fillRect(
                x: Int(rect.x), y: Int(rect.y),
                width: Int(rect.width), height: Int(rect.height),
                pixel: pixel)

        case 9:
            let length = try readCompactLength(data, offset: &offset)
            guard length > 0, offset + length <= data.endIndex else {
                throw RenderingError.insufficientData(
                    expected: length, got: data.endIndex - offset)
            }
            try renderJPEG(
                Data(data[offset..<offset + length]), rect: rect,
                to: framebuffer)

        case 0...7:
            try renderBasic(
                compression: compression, rect: rect, data: data,
                offset: &offset, tightPixelSize: tightPixelSize,
                compact: compact, to: framebuffer,
                pixelFormat: pixelFormat)

        default:
            throw RenderingError.invalidTileData(
                "Unsupported Tight compression control \(compression)")
        }
    }

    private func renderBasic(
        compression: UInt8,
        rect: FramebufferRect,
        data: Data,
        offset: inout Data.Index,
        tightPixelSize: Int,
        compact: Bool,
        to framebuffer: Framebuffer,
        pixelFormat: PixelFormat
    ) throws {
        var filter: UInt8 = 0
        if compression & 0x04 != 0 {
            guard offset < data.endIndex else {
                throw RenderingError.insufficientData(expected: 1, got: 0)
            }
            filter = data[offset]
            offset += 1
        }

        let width = Int(rect.width)
        let height = Int(rect.height)
        var palette: [Data] = []
        let uncompressedSize: Int
        if filter == 1 {
            guard offset < data.endIndex else {
                throw RenderingError.insufficientData(expected: 1, got: 0)
            }
            let count = Int(data[offset]) + 1
            offset += 1
            palette.reserveCapacity(count)
            for _ in 0..<count {
                palette.append(try readPixel(
                    data, offset: &offset, size: tightPixelSize,
                    compact: compact))
            }
            uncompressedSize = count == 2
                ? ((width + 7) / 8) * height
                : width * height
        } else {
            uncompressedSize = width * height * tightPixelSize
        }

        let filtered: Data
        if uncompressedSize < 12 {
            guard offset + uncompressedSize <= data.endIndex else {
                throw RenderingError.insufficientData(
                    expected: uncompressedSize, got: data.endIndex - offset)
            }
            filtered = Data(data[offset..<offset + uncompressedSize])
            offset += uncompressedSize
        } else {
            let compressedLength = try readCompactLength(data, offset: &offset)
            guard offset + compressedLength <= data.endIndex else {
                throw RenderingError.insufficientData(
                    expected: compressedLength, got: data.endIndex - offset)
            }
            let stream = Int(compression & 0x03)
            guard let inflater = inflaters[stream] else {
                throw RenderingError.decompressionFailed(
                    "Failed to initialize Tight zlib stream \(stream)")
            }
            filtered = try inflater.decompress(
                Data(data[offset..<offset + compressedLength]),
                maxOutputSize: uncompressedSize)
            offset += compressedLength
            guard filtered.count == uncompressedSize else {
                throw RenderingError.decompressionFailed(
                    "Tight decoded \(filtered.count) bytes; expected \(uncompressedSize)")
            }
        }

        let pixels: Data
        switch filter {
        case 0:
            pixels = compact
                ? expandCompactRGB(filtered, pixelCount: width * height)
                : filtered
        case 1:
            pixels = try expandPalette(
                filtered, palette: palette, width: width, height: height,
                bytesPerPixel: framebuffer.bytesPerPixel)
        case 2:
            guard compact else {
                throw RenderingError.invalidTileData(
                    "Tight gradient requires 24-bit true color")
            }
            pixels = decodeGradient(filtered, width: width, height: height)
        default:
            throw RenderingError.invalidTileData(
                "Unsupported Tight filter \(filter)")
        }

        framebuffer.update(
            x: Int(rect.x), y: Int(rect.y), width: width, height: height,
            data: pixels)
    }

    private func renderJPEG(
        _ jpeg: Data,
        rect: FramebufferRect,
        to framebuffer: Framebuffer
    ) throws {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw RenderingError.decompressionFailed("Invalid Tight JPEG image")
        }
        guard framebuffer.bytesPerPixel == 4 else {
            throw RenderingError.invalidTileData(
                "Tight JPEG requires a 32-bit destination")
        }
        let width = Int(rect.width)
        let height = Int(rect.height)
        var pixels = Data(count: width * height * 4)
        let created = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let base = bytes.baseAddress,
                  let context = CGContext(
                    data: base, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                        | CGBitmapInfo.byteOrder32Little.rawValue) else { return false }
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard created else {
            throw RenderingError.decompressionFailed(
                "Could not create Tight JPEG bitmap")
        }
        framebuffer.update(
            x: Int(rect.x), y: Int(rect.y), width: width, height: height,
            data: pixels)
    }

    private func expandPalette(
        _ indices: Data,
        palette: [Data],
        width: Int,
        height: Int,
        bytesPerPixel: Int
    ) throws -> Data {
        guard !palette.isEmpty else {
            throw RenderingError.invalidTileData("Empty Tight palette")
        }
        var output = Data(capacity: width * height * bytesPerPixel)
        if palette.count == 2 {
            let rowBytes = (width + 7) / 8
            guard indices.count >= rowBytes * height else {
                throw RenderingError.insufficientData(
                    expected: rowBytes * height, got: indices.count)
            }
            for row in 0..<height {
                for column in 0..<width {
                    let byte = indices[row * rowBytes + column / 8]
                    let index = Int((byte >> (7 - column % 8)) & 1)
                    output.append(palette[index])
                }
            }
        } else {
            guard indices.count >= width * height else {
                throw RenderingError.insufficientData(
                    expected: width * height, got: indices.count)
            }
            for index in indices.prefix(width * height) {
                let paletteIndex = min(Int(index), palette.count - 1)
                output.append(palette[paletteIndex])
            }
        }
        return output
    }

    private func decodeGradient(
        _ residuals: Data,
        width: Int,
        height: Int
    ) -> Data {
        var previous = [UInt8](repeating: 0, count: width * 3)
        var current = [UInt8](repeating: 0, count: width * 3)
        var output = Data(capacity: width * height * 4)
        var source = residuals.startIndex
        for _ in 0..<height {
            for x in 0..<width {
                for component in 0..<3 {
                    let position = x * 3 + component
                    let left = x == 0 ? 0 : Int(current[position - 3])
                    let up = Int(previous[position])
                    let upLeft = x == 0 ? 0 : Int(previous[position - 3])
                    let estimate = min(max(left + up - upLeft, min(left, up)), max(left, up))
                    current[position] = UInt8(truncatingIfNeeded:
                        estimate + Int(residuals[source]))
                    source += 1
                }
                output.append(current[x * 3 + 2]) // B
                output.append(current[x * 3 + 1]) // G
                output.append(current[x * 3])     // R
                output.append(0xFF)
            }
            swap(&previous, &current)
        }
        return output
    }

    private func expandCompactRGB(_ data: Data, pixelCount: Int) -> Data {
        var output = Data(capacity: pixelCount * 4)
        var offset = data.startIndex
        for _ in 0..<pixelCount {
            output.append(data[offset + 2])
            output.append(data[offset + 1])
            output.append(data[offset])
            output.append(0xFF)
            offset += 3
        }
        return output
    }

    private func readPixel(
        _ data: Data,
        offset: inout Data.Index,
        size: Int,
        compact: Bool
    ) throws -> Data {
        guard offset + size <= data.endIndex else {
            throw RenderingError.insufficientData(
                expected: size, got: data.endIndex - offset)
        }
        defer { offset += size }
        if compact {
            return Data([data[offset + 2], data[offset + 1], data[offset], 0xFF])
        }
        return Data(data[offset..<offset + size])
    }

    private func readCompactLength(
        _ data: Data,
        offset: inout Data.Index
    ) throws -> Int {
        var value = 0
        for index in 0..<3 {
            guard offset < data.endIndex else {
                throw RenderingError.insufficientData(expected: 1, got: 0)
            }
            let byte = data[offset]
            offset += 1
            value |= Int(byte & 0x7F) << (7 * index)
            if byte & 0x80 == 0 { return value }
        }
        return value
    }

    private func usesCompactPixels(_ format: PixelFormat) -> Bool {
        format.bitsPerPixel == 32 && format.depth == 24 && format.trueColor
            && format.redMax == 255 && format.greenMax == 255
            && format.blueMax == 255
    }
}

// MARK: - Raw Encoding Renderer

/// Renders Raw encoding data to framebuffer.
/// Raw encoding is simply pixel data in left-to-right, top-to-bottom order.
struct RawEncodingRenderer {

    func render(
        rect: FramebufferRect,
        data: Data,
        to framebuffer: Framebuffer,
        pixelFormat: PixelFormat
    ) {
        framebuffer.update(
            x: Int(rect.x),
            y: Int(rect.y),
            width: Int(rect.width),
            height: Int(rect.height),
            data: data
        )
    }
}

// MARK: - Zlib Encoding Renderer

/// Renders Zlib encoding data to framebuffer.
/// Maintains a persistent zlib decompression stream across rectangles,
/// as required by the RFB specification.
final class ZlibEncodingRenderer {
    private let inflater = try? RFBZlibStreamInflater()

    func render(
        rect: FramebufferRect,
        data: Data,
        to framebuffer: Framebuffer,
        pixelFormat: PixelFormat
    ) throws {
        // Zlib encoding wire format: 4-byte length prefix, then zlib-compressed raw pixel data
        guard data.count >= 4 else {
            throw RenderingError.insufficientData(expected: 4, got: data.count)
        }

        let compressedLength = Int(data[data.startIndex]) << 24
            | Int(data[data.startIndex + 1]) << 16
            | Int(data[data.startIndex + 2]) << 8
            | Int(data[data.startIndex + 3])

        let compressedData = data.dropFirst(4)
        guard compressedData.count >= compressedLength else {
            throw RenderingError.insufficientData(
                expected: compressedLength,
                got: compressedData.count
            )
        }

        let compressedSlice = compressedData.prefix(compressedLength)
        guard let inflater else {
            throw RenderingError.decompressionFailed(
                "Failed to initialize system zlib stream")
        }
        let expectedSize = Int(rect.width) * Int(rect.height)
            * pixelFormat.bytesPerPixel
        let decompressed: Data
        do {
            decompressed = try inflater.decompress(
                Data(compressedSlice),
                maxOutputSize: expectedSize)
        } catch {
            throw RenderingError.decompressionFailed(error.localizedDescription)
        }
        guard decompressed.count == expectedSize else {
            throw RenderingError.decompressionFailed(
                "Zlib rectangle decoded \(decompressed.count) bytes; expected \(expectedSize)")
        }

        framebuffer.update(
            x: Int(rect.x),
            y: Int(rect.y),
            width: Int(rect.width),
            height: Int(rect.height),
            data: decompressed
        )
    }
}

// MARK: - ZRLE Encoding Renderer

/// Renders ZRLE (Zlib Run-Length Encoding) data to framebuffer.
/// ZRLE compresses tile-based data with a persistent zlib stream.
///
/// Wire format: 4-byte length, then zlib-compressed tile data.
/// Tile data is processed in 64x64 pixel tiles, left-to-right, top-to-bottom.
final class ZRLEEncodingRenderer {
    private let inflater = try? RFBZlibStreamInflater()

    func render(
        rect: FramebufferRect,
        data: Data,
        to framebuffer: Framebuffer,
        pixelFormat: PixelFormat
    ) throws {
        guard data.count >= 4 else {
            throw RenderingError.insufficientData(expected: 4, got: data.count)
        }

        let compressedLength = Int(data[data.startIndex]) << 24
            | Int(data[data.startIndex + 1]) << 16
            | Int(data[data.startIndex + 2]) << 8
            | Int(data[data.startIndex + 3])

        let compressedData = data.dropFirst(4)
        guard compressedData.count >= compressedLength else {
            throw RenderingError.insufficientData(
                expected: compressedLength,
                got: compressedData.count
            )
        }

        let compressedSlice = compressedData.prefix(compressedLength)
        guard let inflater else {
            throw RenderingError.decompressionFailed(
                "Failed to initialize system zlib stream")
        }
        let totalPixels = Int(rect.width) * Int(rect.height)
        let maximumTileBytes = totalPixels * pixelFormat.bytesPerPixel
            + totalPixels + 65_536
        let tileData: Data
        do {
            tileData = try inflater.decompress(
                Data(compressedSlice),
                maxOutputSize: maximumTileBytes)
        } catch {
            throw RenderingError.decompressionFailed(error.localizedDescription)
        }

        // ZRLE uses "CPIXELs" — for 32bpp true-colour with certain conditions,
        // CPIXELs are 3 bytes; otherwise they are bytesPerPixel bytes.
        let usesCompactPixel = pixelFormat.bitsPerPixel == 32
            && pixelFormat.trueColor
            && pixelFormat.depth <= 24
        let cpixelSize = usesCompactPixel ? 3 : pixelFormat.bytesPerPixel

        var offset = tileData.startIndex
        let rectX = Int(rect.x)
        let rectY = Int(rect.y)
        let rectW = Int(rect.width)
        let rectH = Int(rect.height)

        // This is the format negotiated by the production client and by
        // ordinary 32-bit true-colour RFB servers. Decode straight from the
        // inflated tile stream into the framebuffer under one lock instead of
        // building a Data allocation per tile and locking once per tile/row.
        if cpixelSize == 3 && framebuffer.bytesPerPixel == 4 {
            try renderCompactBGRATiles(
                tileData,
                rectX: rectX,
                rectY: rectY,
                rectWidth: rectW,
                rectHeight: rectH,
                to: framebuffer)
            return
        }

        // Process tiles in 64x64 blocks
        var tileY = 0
        while tileY < rectH {
            let tileHeight = min(64, rectH - tileY)
            var tileX = 0

            while tileX < rectW {
                let tileWidth = min(64, rectW - tileX)

                guard offset < tileData.endIndex else {
                    throw RenderingError.invalidTileData("Ran out of tile data")
                }

                let subencoding = Int(tileData[offset])
                offset += 1

                if subencoding == 0 {
                    // Raw CPIXEL data
                    let needed = tileWidth * tileHeight * cpixelSize
                    guard offset + needed <= tileData.endIndex else {
                        throw RenderingError.invalidTileData(
                            "Raw tile needs \(needed) bytes"
                        )
                    }

                    let pixels = expandCPixels(
                        tileData[offset ..< offset + needed],
                        count: tileWidth * tileHeight,
                        cpixelSize: cpixelSize,
                        pixelFormat: pixelFormat
                    )
                    framebuffer.update(
                        x: rectX + tileX,
                        y: rectY + tileY,
                        width: tileWidth,
                        height: tileHeight,
                        data: pixels
                    )
                    offset += needed

                } else if subencoding == 1 {
                    // Solid tile — single CPIXEL fills the entire tile
                    guard offset + cpixelSize <= tileData.endIndex else {
                        throw RenderingError.invalidTileData("Solid tile needs \(cpixelSize) bytes")
                    }
                    let pixel = expandSingleCPixel(
                        tileData[offset ..< offset + cpixelSize],
                        cpixelSize: cpixelSize,
                        pixelFormat: pixelFormat
                    )
                    framebuffer.fillRect(
                        x: rectX + tileX,
                        y: rectY + tileY,
                        width: tileWidth,
                        height: tileHeight,
                        pixel: pixel
                    )
                    offset += cpixelSize

                } else if subencoding >= 2 && subencoding <= 16 {
                    // Packed palette: subencoding = palette size
                    let paletteSize = subencoding
                    let paletteBytes = paletteSize * cpixelSize
                    guard offset + paletteBytes <= tileData.endIndex else {
                        throw RenderingError.invalidTileData("Palette needs \(paletteBytes) bytes")
                    }

                    // Read palette
                    var palette: [Data] = []
                    palette.reserveCapacity(paletteSize)
                    for i in 0 ..< paletteSize {
                        let pOffset = offset + i * cpixelSize
                        let expanded = expandSingleCPixel(
                            tileData[pOffset ..< pOffset + cpixelSize],
                            cpixelSize: cpixelSize,
                            pixelFormat: pixelFormat
                        )
                        palette.append(expanded)
                    }
                    offset += paletteBytes

                    // Determine bits per index
                    let bitsPerIndex: Int
                    if paletteSize <= 2 {
                        bitsPerIndex = 1
                    } else if paletteSize <= 4 {
                        bitsPerIndex = 2
                    } else {
                        bitsPerIndex = 4
                    }

                    // Read packed pixel indices
                    let indicesPerByte = 8 / bitsPerIndex
                    let mask = (1 << bitsPerIndex) - 1

                    let bpp = framebuffer.bytesPerPixel
                    var pixelRow = Data(capacity: tileWidth * bpp)

                    for row in 0 ..< tileHeight {
                        pixelRow.removeAll(keepingCapacity: true)

                        var byteIndex = 0
                        for col in 0 ..< tileWidth {
                            let posInByte = col % indicesPerByte
                            if posInByte == 0 && col > 0 {
                                byteIndex += 1
                            }

                            guard offset + byteIndex < tileData.endIndex else {
                                throw RenderingError.invalidTileData(
                                    "Ran out of packed palette data"
                                )
                            }

                            let byte = Int(tileData[offset + byteIndex])
                            let shift = (indicesPerByte - 1 - posInByte) * bitsPerIndex
                            let index = (byte >> shift) & mask

                            if index < palette.count {
                                pixelRow.append(palette[index])
                            } else {
                                // Invalid index; fill with black
                                pixelRow.append(
                                    contentsOf: [UInt8](repeating: 0, count: bpp)
                                )
                            }
                        }

                        // Each row is padded to a byte boundary
                        let bytesForRow = (tileWidth * bitsPerIndex + 7) / 8
                        offset += bytesForRow

                        framebuffer.update(
                            x: rectX + tileX,
                            y: rectY + tileY + row,
                            width: tileWidth,
                            height: 1,
                            data: pixelRow
                        )
                    }

                } else if subencoding == 128 {
                    // Plain RLE
                    let bpp = framebuffer.bytesPerPixel
                    var pixels = Data(capacity: tileWidth * tileHeight * bpp)
                    var pixelsRemaining = tileWidth * tileHeight

                    while pixelsRemaining > 0 {
                        guard offset + cpixelSize <= tileData.endIndex else {
                            throw RenderingError.invalidTileData("RLE ran out of pixel data")
                        }

                        let pixel = expandSingleCPixel(
                            tileData[offset ..< offset + cpixelSize],
                            cpixelSize: cpixelSize,
                            pixelFormat: pixelFormat
                        )
                        offset += cpixelSize

                        // Read run length
                        var runLength = 1
                        while offset < tileData.endIndex {
                            let byte = Int(tileData[offset])
                            offset += 1
                            runLength += byte
                            if byte != 255 { break }
                        }

                        runLength = min(runLength, pixelsRemaining)
                        for _ in 0 ..< runLength {
                            pixels.append(pixel)
                        }
                        pixelsRemaining -= runLength
                    }

                    framebuffer.update(
                        x: rectX + tileX,
                        y: rectY + tileY,
                        width: tileWidth,
                        height: tileHeight,
                        data: pixels
                    )

                } else if subencoding >= 130 {
                    // Palette RLE: subencoding - 128 = palette size
                    let paletteSize = subencoding - 128
                    let paletteBytes = paletteSize * cpixelSize
                    guard offset + paletteBytes <= tileData.endIndex else {
                        throw RenderingError.invalidTileData(
                            "Palette RLE needs \(paletteBytes) bytes"
                        )
                    }

                    var palette: [Data] = []
                    palette.reserveCapacity(paletteSize)
                    for i in 0 ..< paletteSize {
                        let pOffset = offset + i * cpixelSize
                        let expanded = expandSingleCPixel(
                            tileData[pOffset ..< pOffset + cpixelSize],
                            cpixelSize: cpixelSize,
                            pixelFormat: pixelFormat
                        )
                        palette.append(expanded)
                    }
                    offset += paletteBytes

                    let bpp = framebuffer.bytesPerPixel
                    var pixels = Data(capacity: tileWidth * tileHeight * bpp)
                    var pixelsRemaining = tileWidth * tileHeight

                    while pixelsRemaining > 0 {
                        guard offset < tileData.endIndex else {
                            throw RenderingError.invalidTileData("Palette RLE ran out of data")
                        }

                        let indexByte = Int(tileData[offset])
                        offset += 1

                        let paletteIndex = indexByte & 0x7F
                        let pixel: Data
                        if paletteIndex < palette.count {
                            pixel = palette[paletteIndex]
                        } else {
                            pixel = Data(repeating: 0, count: bpp)
                        }

                        if (indexByte & 0x80) != 0 {
                            // Run-length encoded entry
                            var runLength = 1
                            while offset < tileData.endIndex {
                                let byte = Int(tileData[offset])
                                offset += 1
                                runLength += byte
                                if byte != 255 { break }
                            }
                            runLength = min(runLength, pixelsRemaining)
                            for _ in 0 ..< runLength {
                                pixels.append(pixel)
                            }
                            pixelsRemaining -= runLength
                        } else {
                            // Single pixel
                            pixels.append(pixel)
                            pixelsRemaining -= 1
                        }
                    }

                    framebuffer.update(
                        x: rectX + tileX,
                        y: rectY + tileY,
                        width: tileWidth,
                        height: tileHeight,
                        data: pixels
                    )

                } else {
                    // Subencoding 17-127 and 129 are unused/invalid
                    throw RenderingError.invalidTileData(
                        "Invalid ZRLE subencoding: \(subencoding)"
                    )
                }

                tileX += 64
            }
            tileY += 64
        }
    }

    // MARK: - CPIXEL expansion

    /// Fast path for the standard 3-byte BGR CPIXEL to 4-byte BGRA format.
    /// Tile decoding writes through a UInt32 pointer, eliminating intermediate
    /// pixels, rows, and tile buffers from the latency-sensitive path.
    private func renderCompactBGRATiles(
        _ tileData: Data,
        rectX: Int,
        rectY: Int,
        rectWidth: Int,
        rectHeight: Int,
        to framebuffer: Framebuffer
    ) throws {
        try framebuffer.withUnsafeMutablePixelBytes {
            destination, framebufferWidth, framebufferHeight, bytesPerRow, bytesPerPixel in
            guard bytesPerPixel == 4,
                  rectX >= 0, rectY >= 0,
                  rectWidth >= 0, rectHeight >= 0,
                  rectX + rectWidth <= framebufferWidth,
                  rectY + rectHeight <= framebufferHeight else {
                throw RenderingError.invalidTileData(
                    "ZRLE rectangle lies outside the framebuffer")
            }

            try tileData.withUnsafeBytes { rawTileBytes in
                guard let source = rawTileBytes.baseAddress?
                    .assumingMemoryBound(to: UInt8.self) else {
                    if rectWidth == 0 || rectHeight == 0 { return }
                    throw RenderingError.invalidTileData("Empty ZRLE tile data")
                }

                let sourceCount = rawTileBytes.count
                var offset = 0
                var tileY = 0
                while tileY < rectHeight {
                    let tileHeight = min(64, rectHeight - tileY)
                    var tileX = 0

                    while tileX < rectWidth {
                        let tileWidth = min(64, rectWidth - tileX)
                        let tilePixels = tileWidth * tileHeight
                        guard offset < sourceCount else {
                            throw RenderingError.invalidTileData(
                                "Ran out of compact ZRLE tile data")
                        }
                        let subencoding = Int(source[offset])
                        offset += 1

                        @inline(__always)
                        func pixel(at sourceOffset: Int) -> UInt32 {
                            UInt32(source[sourceOffset])
                                | (UInt32(source[sourceOffset + 1]) << 8)
                                | (UInt32(source[sourceOffset + 2]) << 16)
                                | 0xFF00_0000
                        }

                        @inline(__always)
                        func destinationRow(_ row: Int) -> UnsafeMutablePointer<UInt32> {
                            destination.advanced(
                                by: (rectY + tileY + row) * bytesPerRow
                                    + (rectX + tileX) * 4)
                                .assumingMemoryBound(to: UInt32.self)
                        }

                        @inline(__always)
                        func writeRun(
                            _ value: UInt32,
                            startingAt start: Int,
                            count: Int
                        ) {
                            var remaining = count
                            var position = start
                            while remaining > 0 {
                                let row = position / tileWidth
                                let column = position % tileWidth
                                let span = min(remaining, tileWidth - column)
                                let rowPointer = destinationRow(row)
                                for index in 0..<span {
                                    rowPointer[column + index] = value
                                }
                                position += span
                                remaining -= span
                            }
                        }

                        switch subencoding {
                        case 0:
                            let needed = tilePixels * 3
                            guard offset + needed <= sourceCount else {
                                throw RenderingError.invalidTileData(
                                    "Raw compact tile needs \(needed) bytes")
                            }
                            for row in 0..<tileHeight {
                                let rowPointer = destinationRow(row)
                                var sourceOffset = offset + row * tileWidth * 3
                                for column in 0..<tileWidth {
                                    rowPointer[column] = pixel(at: sourceOffset)
                                    sourceOffset += 3
                                }
                            }
                            offset += needed

                        case 1:
                            guard offset + 3 <= sourceCount else {
                                throw RenderingError.invalidTileData(
                                    "Solid compact tile needs 3 bytes")
                            }
                            let value = pixel(at: offset)
                            offset += 3
                            writeRun(value, startingAt: 0, count: tilePixels)

                        case 2...16:
                            let paletteSize = subencoding
                            let paletteByteCount = paletteSize * 3
                            guard offset + paletteByteCount <= sourceCount else {
                                throw RenderingError.invalidTileData(
                                    "Compact palette needs \(paletteByteCount) bytes")
                            }
                            var palette = [UInt32](
                                repeating: 0, count: paletteSize)
                            for index in 0..<paletteSize {
                                palette[index] = pixel(at: offset + index * 3)
                            }
                            offset += paletteByteCount

                            let bitsPerIndex: Int
                            switch paletteSize {
                            case 2: bitsPerIndex = 1
                            case 3...4: bitsPerIndex = 2
                            default: bitsPerIndex = 4
                            }
                            let indicesPerByte = 8 / bitsPerIndex
                            let mask = (1 << bitsPerIndex) - 1
                            let bytesForRow = (tileWidth * bitsPerIndex + 7) / 8
                            guard offset + bytesForRow * tileHeight <= sourceCount else {
                                throw RenderingError.invalidTileData(
                                    "Ran out of compact packed-palette data")
                            }

                            for row in 0..<tileHeight {
                                let rowPointer = destinationRow(row)
                                let packedRow = offset + row * bytesForRow
                                for column in 0..<tileWidth {
                                    let packed = Int(source[
                                        packedRow + column / indicesPerByte])
                                    let position = column % indicesPerByte
                                    let shift = (indicesPerByte - 1 - position)
                                        * bitsPerIndex
                                    let index = (packed >> shift) & mask
                                    rowPointer[column] = index < palette.count
                                        ? palette[index] : 0
                                }
                            }
                            offset += bytesForRow * tileHeight

                        case 128:
                            var pixelsWritten = 0
                            while pixelsWritten < tilePixels {
                                guard offset + 3 <= sourceCount else {
                                    throw RenderingError.invalidTileData(
                                        "Compact RLE ran out of pixel data")
                                }
                                let value = pixel(at: offset)
                                offset += 3
                                var runLength = 1
                                var foundRunEnd = false
                                while offset < sourceCount {
                                    let byte = Int(source[offset])
                                    offset += 1
                                    runLength += byte
                                    if byte != 255 {
                                        foundRunEnd = true
                                        break
                                    }
                                }
                                guard foundRunEnd else {
                                    throw RenderingError.invalidTileData(
                                        "Compact RLE has an incomplete run")
                                }
                                let clippedRun = min(
                                    runLength, tilePixels - pixelsWritten)
                                writeRun(
                                    value,
                                    startingAt: pixelsWritten,
                                    count: clippedRun)
                                pixelsWritten += clippedRun
                            }

                        case 130...255:
                            let paletteSize = subencoding - 128
                            let paletteByteCount = paletteSize * 3
                            guard offset + paletteByteCount <= sourceCount else {
                                throw RenderingError.invalidTileData(
                                    "Compact RLE palette needs \(paletteByteCount) bytes")
                            }
                            var palette = [UInt32](
                                repeating: 0, count: paletteSize)
                            for index in 0..<paletteSize {
                                palette[index] = pixel(at: offset + index * 3)
                            }
                            offset += paletteByteCount

                            var pixelsWritten = 0
                            while pixelsWritten < tilePixels {
                                guard offset < sourceCount else {
                                    throw RenderingError.invalidTileData(
                                        "Compact palette RLE ran out of data")
                                }
                                let indexByte = Int(source[offset])
                                offset += 1
                                let paletteIndex = indexByte & 0x7F
                                let value = paletteIndex < palette.count
                                    ? palette[paletteIndex] : 0
                                var runLength = 1
                                if indexByte & 0x80 != 0 {
                                    var foundRunEnd = false
                                    while offset < sourceCount {
                                        let byte = Int(source[offset])
                                        offset += 1
                                        runLength += byte
                                        if byte != 255 {
                                            foundRunEnd = true
                                            break
                                        }
                                    }
                                    guard foundRunEnd else {
                                        throw RenderingError.invalidTileData(
                                            "Compact palette RLE has an incomplete run")
                                    }
                                }
                                let clippedRun = min(
                                    runLength, tilePixels - pixelsWritten)
                                writeRun(
                                    value,
                                    startingAt: pixelsWritten,
                                    count: clippedRun)
                                pixelsWritten += clippedRun
                            }

                        default:
                            throw RenderingError.invalidTileData(
                                "Invalid ZRLE subencoding: \(subencoding)")
                        }

                        tileX += 64
                    }
                    tileY += 64
                }
            }
        }
    }

    /// Expand a CPIXEL (compact pixel) to a full pixel in framebuffer format.
    /// For 32bpp true-colour, CPIXELs are 3 bytes in little-endian order: B, G, R
    /// and we expand to 4-byte BGRA.
    private func expandSingleCPixel(
        _ data: Data.SubSequence,
        cpixelSize: Int,
        pixelFormat: PixelFormat
    ) -> Data {
        if cpixelSize == 3 && pixelFormat.bytesPerPixel == 4 {
            // 3-byte CPIXEL -> 4-byte BGRA
            let base = data.startIndex
            var pixel = Data(count: 4)
            pixel[0] = data[base]       // Blue
            pixel[1] = data[base + 1]   // Green
            pixel[2] = data[base + 2]   // Red
            pixel[3] = 0xFF             // Alpha
            return pixel
        } else {
            return Data(data)
        }
    }

    /// Expand multiple CPIXELs to full pixels.
    private func expandCPixels(
        _ data: Data.SubSequence,
        count: Int,
        cpixelSize: Int,
        pixelFormat: PixelFormat
    ) -> Data {
        if cpixelSize == 3 && pixelFormat.bytesPerPixel == 4 {
            var result = Data(capacity: count * 4)
            var offset = data.startIndex
            for _ in 0 ..< count {
                result.append(data[offset])         // Blue
                result.append(data[offset + 1])     // Green
                result.append(data[offset + 2])     // Red
                result.append(0xFF)                  // Alpha
                offset += 3
            }
            return result
        } else {
            return Data(data)
        }
    }

}
