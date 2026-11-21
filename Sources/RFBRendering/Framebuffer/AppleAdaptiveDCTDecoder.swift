import CoreGraphics
import Foundation
import RFBProtocol
import RFBRenderingC

enum AppleAdaptiveDCTError: Error, LocalizedError {
    case malformed(String)
    case unsupportedMessageType(UInt8)

    var errorDescription: String? {
        switch self {
        case .malformed(let detail): detail
        case .unsupportedMessageType(let type):
            "Unsupported Apple Adaptive DCT message type \(type)"
        }
    }
}

/// Stateful decoder for Apple's registered RFB encoding 1011. The server
/// sends quantization changes (type 2) independently from image commands
/// (type 0), and later image commands may reference tiles decoded by any
/// earlier rectangle, so one instance must live for the whole connection.
final class AppleAdaptiveDCTDecoder {
    /// 64-bit MSB-aligned bit reader borrowed within an enclosing
    /// `Data.withUnsafeBytes` scope. Unread bits occupy the top `bitsLeft`
    /// positions of `reservoir`; the low `64 - bitsLeft` bits are always zero.
    struct BitReader {
        private let baseAddress: UnsafePointer<UInt8>?
        private let byteCount: Int
        private var nextByteOffset = 0
        private var reservoir: UInt64 = 0
        private var bitsLeft = 0

        var bitOffset: Int { nextByteOffset * 8 - bitsLeft }
        var remainingBitCount: Int { byteCount * 8 - bitOffset }

        init(_ bytes: UnsafeRawBufferPointer) {
            self.baseAddress = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self)
            self.byteCount = bytes.count
        }

        @inline(__always)
        private mutating func refill() {
            guard bitsLeft <= 56, let baseAddress else { return }
            if nextByteOffset &+ 8 <= byteCount {
                let loaded = UnsafeRawPointer(baseAddress.advanced(by: nextByteOffset))
                    .loadUnaligned(as: UInt64.self)
                    .bigEndian
                let bytesConsumed = (64 &- bitsLeft) >> 3
                let nextBits = bitsLeft &+ (bytesConsumed << 3)
                reservoir |= loaded >> bitsLeft
                // Keep the low (64 - nextBits) invalid bits strictly zero so
                // leading-zero scans never observe unread bytes.
                reservoir &= ~UInt64(0) << (64 &- nextBits)
                nextByteOffset &+= bytesConsumed
                bitsLeft = nextBits
                return
            }
            while bitsLeft <= 56 && nextByteOffset < byteCount {
                let byte = UInt64(baseAddress[nextByteOffset])
                reservoir |= byte << (56 &- bitsLeft)
                nextByteOffset &+= 1
                bitsLeft &+= 8
            }
        }

        @inline(__always)
        mutating func readBits(_ count: Int) throws -> UInt32 {
            guard count >= 0 && count <= 32 else {
                throw AppleAdaptiveDCTError.malformed(
                    "DCT command stream ended while reading \(count) bits")
            }
            guard count > 0 else { return 0 }
            if bitsLeft < count {
                refill()
                guard bitsLeft >= count else {
                    throw AppleAdaptiveDCTError.malformed(
                        "DCT command stream ended while reading \(count) bits")
                }
            }
            let value = UInt32(reservoir >> (64 &- count))
            reservoir <<= count
            bitsLeft &-= count
            return value
        }

        @inline(__always)
        mutating func readBit() throws -> UInt32 {
            if bitsLeft == 0 {
                refill()
                guard bitsLeft > 0 else {
                    throw AppleAdaptiveDCTError.malformed(
                        "DCT command stream ended while reading 1 bits")
                }
            }
            let bit = UInt32(reservoir >> 63)
            reservoir <<= 1
            bitsLeft &-= 1
            return bit
        }

        /// Apple encodes a command's tile count as 0 => one tile, followed by
        /// a compact 4-bit form for 2...16. The escape value 15 is followed
        /// by one to three little-endian base-128 groups and a bias of 17.
        @inline(__always)
        mutating func readCommandRunLength() throws -> Int {
            guard try readBit() != 0 else { return 1 }
            let short = Int(try readBits(4))
            guard short == 15 else { return short + 2 }

            var extended = 0
            for group in 0..<3 {
                let byte = Int(try readBits(8))
                extended |= (byte & 0x7f) << (group * 7)
                if byte & 0x80 == 0 { return extended + 17 }
            }
            return extended + 17
        }

        /// Signed Rice variant used for each plane's DC delta. Uses a single
        /// leading-zero scan (`clz`) over the inverted 64-bit reservoir.
        @inline(__always)
        mutating func readSignedDCRice() throws -> Int {
            if bitsLeft < 45 {
                refill()
            }
            let prefix = (~reservoir).leadingZeroBitCount
            if prefix >= 40 {
                throw AppleAdaptiveDCTError.malformed("DCT DC Rice prefix exceeds 39 bits")
            }
            if prefix == bitsLeft {
                throw AppleAdaptiveDCTError.malformed(
                    "DCT command stream ended while reading 1 bits")
            }

            // Fast path for prefix == 0 (0, +1, -1), the overwhelmingly common case.
            if prefix == 0 {
                if bitsLeft >= 3 {
                    let top = reservoir
                    if (top & (UInt64(1) << 62)) == 0 {
                        reservoir = top << 2
                        bitsLeft &-= 2
                        return 0
                    }
                    let isNegative = (top & (UInt64(1) << 61)) != 0
                    reservoir = top << 3
                    bitsLeft &-= 3
                    return isNegative ? -1 : 1
                }
                // Consume terminating 0 bit and fall back to checked reads near EOF.
                reservoir <<= 1
                bitsLeft &-= 1
                guard try readBit() != 0 else { return 0 }
                return try readBit() == 0 ? 1 : -1
            }

            let consumePrefix = prefix &+ 1
            reservoir <<= consumePrefix
            bitsLeft &-= consumePrefix

            let magnitude: Int
            let sign: UInt32
            switch prefix {
            case 1:
                let suffix = try readBits(2)
                magnitude = 2 + Int(suffix >> 1)
                sign = suffix & 1
            case 2:
                let suffix = try readBits(3)
                magnitude = 4 + Int(suffix >> 1)
                sign = suffix & 1
            default:
                let suffix = try readBits(4)
                magnitude = prefix * 8 + Int(suffix >> 1) - 16
                sign = suffix & 1
            }
            return sign == 0 ? magnitude : -magnitude
        }

        /// Large AC coefficient decoder using `clz` over the 64-bit reservoir.
        @inline(__always)
        mutating func readLargeACCoefficient(coefficient: Int) throws -> Int {
            let maximumPrefix = coefficient < 6 ? 34 : 20
            if bitsLeft < 40 {
                refill()
            }
            let prefix = (~reservoir).leadingZeroBitCount
            if prefix >= maximumPrefix {
                throw AppleAdaptiveDCTError.malformed("DCT AC prefix is too long")
            }
            if prefix == bitsLeft {
                throw AppleAdaptiveDCTError.malformed(
                    "DCT command stream ended while reading 1 bits")
            }
            let consumePrefix = prefix &+ 1
            reservoir <<= consumePrefix
            bitsLeft &-= consumePrefix

            let magnitude: Int
            let sign: UInt32
            if coefficient < 6 {
                if prefix <= 3 {
                    let suffix = try readBits(3)
                    magnitude = prefix * 4 + Int(suffix >> 1) + 2
                    sign = suffix & 1
                } else {
                    let suffix = try readBits(4)
                    magnitude = prefix * 8 + Int(suffix >> 1) - 14
                    sign = suffix & 1
                }
            } else if prefix == 0 {
                let suffix = try readBits(2)
                magnitude = 2 + Int(suffix >> 1)
                sign = suffix & 1
            } else if prefix == 1 {
                let suffix = try readBits(3)
                magnitude = 4 + Int(suffix >> 1)
                sign = suffix & 1
            } else {
                let suffix = try readBits(4)
                magnitude = prefix * 8 + Int(suffix >> 1) - 8
                sign = suffix & 1
            }
            return sign == 0 ? magnitude : -magnitude
        }

        /// Returns Y, Cb, and Cr expanded to eight-bit lanes. Chroma is sent
        /// with six bits of precision and occupies the high six bits.
        @inline(__always)
        mutating func readYCC20() throws -> (y: UInt8, cb: UInt8, cr: UInt8) {
            let packed = try readBits(20)
            let y = UInt8((packed >> 12) & 0xff)
            let cb = UInt8(((packed >> 6) & 0x3f) << 2)
            let cr = UInt8((packed & 0x3f) << 2)
            return (y, cb, cr)
        }

        /// Decode one sparse low-amplitude coefficient. A nil value means
        /// the coefficient is zero; index 64 is the end-of-block sentinel.
        @inline(__always)
        mutating func readSmallCoefficient(
            at index: Int,
            amplitude: Int
        ) throws -> (nextIndex: Int, value: Int?) {
            if bitsLeft < 8 {
                refill()
            }
            if bitsLeft >= 5 {
                let code = Int(reservoir >> 62)
                switch code {
                case 0:
                    reservoir <<= 2
                    bitsLeft &-= 2
                    return (index &+ 1, nil)
                case 2:
                    reservoir <<= 2
                    bitsLeft &-= 2
                    return (index &+ 1, amplitude)
                case 3:
                    reservoir <<= 2
                    bitsLeft &-= 2
                    return (index &+ 1, -amplitude)
                default:
                    // code == 1: check third bit for EOB (0) vs skip (1).
                    if (reservoir & (UInt64(1) << 61)) == 0 {
                        reservoir <<= 3
                        bitsLeft &-= 3
                        return (64, nil)
                    }
                    let shortSkip = Int((reservoir >> 59) & 3)
                    reservoir <<= 5
                    bitsLeft &-= 5
                    if shortSkip != 3 {
                        return (index &+ shortSkip &+ 3, nil)
                    }
                    return try readExtendedZeroSkip(from: index)
                }
            }

            let code = try readBits(2)
            switch code {
            case 0:
                return (index &+ 1, nil)
            case 2:
                return (index &+ 1, amplitude)
            case 3:
                return (index &+ 1, -amplitude)
            default:
                guard try readBit() != 0 else { return (64, nil) }
                let shortSkip = Int(try readBits(2))
                guard shortSkip == 3 else {
                    return (index &+ shortSkip &+ 3, nil)
                }
                return try readExtendedZeroSkip(from: index)
            }
        }

        @inline(__always)
        private mutating func readExtendedZeroSkip(
            from index: Int
        ) throws -> (nextIndex: Int, value: Int?) {
            var skip = 6
            while true {
                let group = Int(try readBits(3))
                skip &+= group
                if group != 7 { break }
            }
            guard index &+ skip < 64 else {
                throw AppleAdaptiveDCTError.malformed(
                    "DCT zero run passes coefficient 63")
            }
            return (index &+ skip, nil)
        }

        /// Decode one JPEG luminance AC Huffman symbol using a 9-bit flat
        /// lookup table, falling back to canonical bit-by-bit decoding for
        /// 10..16-bit codes or end-of-stream checks.
        @inline(__always)
        mutating func readLuminanceACHuffmanSymbol(
            lut: UnsafeBufferPointer<UInt16>
        ) throws -> UInt8 {
            if bitsLeft < 24 {
                refill()
            }
            let entry = lut[Int(reservoir >> 55)]
            let length = Int(entry & 0xff)
            if length > 0 && length <= bitsLeft {
                reservoir <<= length
                bitsLeft &-= length
                return UInt8(entry >> 8)
            }
            return try readLuminanceACHuffmanSlow()
        }

        private mutating func readLuminanceACHuffmanSlow() throws -> UInt8 {
            var code = 0
            var firstCode = 0
            var valueIndex = 0
            var length = 1
            while length <= 16 {
                code = (code << 1) | Int(try readBit())
                let count = AppleAdaptiveDCTDecoder.luminanceACCodeCounts[length - 1]
                let delta = code - firstCode
                if delta >= 0 && delta < count {
                    return AppleAdaptiveDCTDecoder.luminanceACValues[valueIndex + delta]
                }
                valueIndex += count
                firstCode = (firstCode + count) << 1
                length += 1
            }
            throw AppleAdaptiveDCTError.malformed("Invalid DCT refinement Huffman code")
        }
    }

    struct ImageMessage {
        let field1: UInt8
        let field2: UInt8
        let commandBytes: Data
        let dataBytes: Data
    }

    private(set) var lumaQuantization: [UInt16]
    private(set) var chromaQuantization: [UInt16]
    private var framebufferWidth = 0
    private var framebufferHeight = 0
    /// Contiguous, connection-owned map + metadata storage (no redundant
    /// 384-byte coefficient arrays; refinement reads only maps and metadata).
    private var tileStates = TileMapStorage(count: 0)
    private let scratchCoefficients: UnsafeMutableBufferPointer<Int16>
    private let scratchMaps: UnsafeMutableBufferPointer<Int8>
    private var baseUpdateGeneration: UInt64 = 0
    // Allocate 256-slot coefficient pages lazily when refinement populates the cache ring.
    private var coefficientCache = [CacheCoefficientStorage?](repeating: nil, count: 254)
    private var cacheWriteIndex = 0
    private var cacheReadIndex = 0
    private var cachedSolidColor: UInt32?
    private var cachedPaletteFirst: UInt32?
    private var cachedPaletteSecond: UInt32?

    init() {
        lumaQuantization = Self.defaultLuma.map(UInt16.init)
        chromaQuantization = Self.defaultChroma.map(UInt16.init)
        // 2 scratch coefficient blocks: [0] predictor, [1] zero fallback for cache miss.
        scratchCoefficients = .allocate(capacity: 2 * 192)
        scratchCoefficients.initialize(repeating: 0)
        // 2 scratch map blocks: [0] predictor map, [1] refinement map.
        scratchMaps = .allocate(capacity: 2 * 99)
        scratchMaps.initialize(repeating: 0)
    }

    deinit {
        scratchCoefficients.deinitialize()
        scratchCoefficients.deallocate()
        scratchMaps.deinitialize()
        scratchMaps.deallocate()
    }

    /// Remove the RFB UInt32 length prefix and apply a control message, or
    /// return the separated command/data streams for a type-0 image message.
    func ingest(_ payload: Data) throws -> ImageMessage? {
        guard payload.count >= 5 else {
            throw AppleAdaptiveDCTError.malformed("DCT payload is shorter than 5 bytes")
        }
        let base = payload.startIndex
        let length =
            Int(payload[base]) << 24
            | Int(payload[base + 1]) << 16
            | Int(payload[base + 2]) << 8
            | Int(payload[base + 3])
        guard length == payload.count - 4 else {
            throw AppleAdaptiveDCTError.malformed(
                "DCT length \(length) does not match \(payload.count - 4) bytes")
        }
        let message = payload.dropFirst(4)
        let type = message[message.startIndex]
        switch type {
        case 0:
            guard message.count >= 7 else {
                throw AppleAdaptiveDCTError.malformed("Type-0 message is shorter than 7 bytes")
            }
            let start = message.startIndex
            let dataOffset =
                Int(message[start + 3]) << 16
                | Int(message[start + 4]) << 8
                | Int(message[start + 5])
            guard dataOffset >= 6, dataOffset < message.count else {
                throw AppleAdaptiveDCTError.malformed(
                    "Type-0 data offset \(dataOffset) is outside \(message.count) bytes")
            }
            return ImageMessage(
                field1: message[start + 1],
                field2: message[start + 2],
                commandBytes: Data(message[(start + 6)..<(start + dataOffset)]),
                dataBytes: Data(message[(start + dataOffset)...]))

        case 1:
            // render() routes type 1 to the progressive-refinement/cache path
            // before calling ingest(). Keep direct ingestion side-effect free.
            return nil

        case 2:
            guard message.count == 129 else {
                throw AppleAdaptiveDCTError.malformed(
                    "Type-2 quantization message is \(message.count) bytes, expected 129")
            }
            lumaQuantization = message.dropFirst().prefix(64).map(UInt16.init)
            chromaQuantization = message.dropFirst(65).prefix(64).map(UInt16.init)
            return nil

        default:
            throw AppleAdaptiveDCTError.unsupportedMessageType(type)
        }
    }

    /// Decode the currently implemented type-0, type-1, and type-2 commands
    /// directly into the framebuffer. Returns the tight modified pixel bounds
    /// (or `nil` if no framebuffer pixels were written, such as type-2
    /// quantization tables or all-skip type-1 refinement).
    @discardableResult
    func render(
        rect: FramebufferRect,
        payload: Data,
        to framebuffer: Framebuffer,
        drawPixels: Bool = true
    ) throws -> CGRect? {
        guard payload.count >= 5 else {
            throw AppleAdaptiveDCTError.malformed("DCT payload is shorter than 5 bytes")
        }
        let base = payload.startIndex
        let length =
            Int(payload[base]) << 24
            | Int(payload[base + 1]) << 16
            | Int(payload[base + 2]) << 8
            | Int(payload[base + 3])
        guard length == payload.count - 4 else {
            throw AppleAdaptiveDCTError.malformed(
                "DCT length \(length) does not match \(payload.count - 4) bytes")
        }

        let messageType = payload[base + 4]
        switch messageType {
        case 1:
            return try renderRefinement(
                rect: rect, payload: payload, messageLength: length,
                to: framebuffer, drawPixels: drawPixels)

        case 2:
            guard length == 129 else {
                throw AppleAdaptiveDCTError.malformed(
                    "Type-2 quantization message is \(length) bytes, expected 129")
            }
            payload.withUnsafeBytes { bytes in
                for i in 0..<64 {
                    lumaQuantization[i] = UInt16(bytes[5 + i])
                    chromaQuantization[i] = UInt16(bytes[69 + i])
                }
            }
            return nil

        case 0:
            guard length >= 7 else {
                throw AppleAdaptiveDCTError.malformed("Type-0 message is shorter than 7 bytes")
            }
            let field1 = Int(payload[base + 5])
            let field2 = Int(payload[base + 6])
            let dataOffset =
                Int(payload[base + 7]) << 16
                | Int(payload[base + 8]) << 8
                | Int(payload[base + 9])
            guard dataOffset >= 6, dataOffset < length else {
                throw AppleAdaptiveDCTError.malformed(
                    "Type-0 data offset \(dataOffset) is outside \(length) bytes")
            }
            guard framebuffer.bytesPerPixel == 4 else {
                throw AppleAdaptiveDCTError.malformed("Apple DCT requires a 32-bit framebuffer")
            }
            ensureFramebuffer(width: framebuffer.width, height: framebuffer.height)

            // Borrow command and data streams directly from payload (zero copy).
            defer { withExtendedLifetime(self) {} }
            return try payload.withUnsafeBytes { payloadBytes in
                let commandBytes = UnsafeRawBufferPointer(
                    rebasing: payloadBytes[10..<(4 + dataOffset)])
                let dataBytes = UnsafeRawBufferPointer(
                    rebasing: payloadBytes[(4 + dataOffset)...])
                return try renderType0(
                    rect: rect,
                    field1: field1,
                    field2: field2,
                    commandBytes: commandBytes,
                    dataBytes: dataBytes,
                    to: framebuffer,
                    drawPixels: drawPixels)
            }

        default:
            throw AppleAdaptiveDCTError.unsupportedMessageType(messageType)
        }
    }

    private func renderType0(
        rect: FramebufferRect,
        field1: Int,
        field2: Int,
        commandBytes: UnsafeRawBufferPointer,
        dataBytes: UnsafeRawBufferPointer,
        to framebuffer: Framebuffer,
        drawPixels: Bool
    ) throws -> CGRect? {
        try withRenderBuffers { kernel, fallbackPixels in
            var commands = BitReader(commandBytes)
            var data = BitReader(dataBytes)
            // The bitstream starts at byte zero with one reserved bit followed by
            // seven command bits.
            _ = try commands.readBit()
            let rectX = Int(rect.x)
            let rectY = Int(rect.y)
            let tilesWide = (Int(rect.width) + 7) / 8
            let tilesHigh = (Int(rect.height) + 7) / 8
            let tileCount = tilesWide * tilesHigh
            let framebufferTilesWide = (framebufferWidth + 7) / 8
            baseUpdateGeneration &+= 1
            let updateGeneration = baseUpdateGeneration

            var tileNumber = 0
            var localX = 0
            var localY = 0
            var pixelX = rectX
            var pixelY = rectY
            var prevPixelX = rectX
            var prevPixelY = rectY
            var prevGlobalIndex = 0

            let predictor = UnsafeMutableBufferPointer(rebasing: scratchCoefficients[0..<192])
            let predictorMap = UnsafeMutableBufferPointer(rebasing: scratchMaps[0..<99])
            memset(predictor.baseAddress!, 0, 192 * 2)
            memset(predictorMap.baseAddress!, 0, 99)
            var predictorQuality = 0
            var hasLastDCTPixels = false
            var lastDCTFullTile = false
            var lastDCTPixelX = 0
            var lastDCTPixelY = 0

            var dirtyRect: CGRect?
            try framebuffer.withUnsafeMutablePixelBytes { base, width, height, bytesPerRow, _ in
                while tileNumber < tileCount {
                    let command = Int(try commands.readBits(3))
                    let run = min(try commands.readCommandRunLength(), tileCount - tileNumber)
                    var runRemaining = run
                    while runRemaining > 0 {
                        runRemaining &-= 1
                        let globalIndex = (pixelY >> 3) * framebufferTilesWide + (pixelX >> 3)
                        recordBaseTile(at: globalIndex, generation: updateGeneration)
                        switch command {
                        case 0:
                            renderSolidTile(
                                0xffff_ffff, x: pixelX, y: pixelY, base: base,
                                width: width, height: height, bytesPerRow: bytesPerRow)

                        case 1:
                            guard tileNumber > 0 else {
                                throw AppleAdaptiveDCTError.malformed(
                                    "DCT previous-tile command appears before the first tile")
                            }
                            copyTile(
                                fromX: prevPixelX, fromY: prevPixelY,
                                toX: pixelX, toY: pixelY,
                                base: base, width: width, height: height,
                                bytesPerRow: bytesPerRow)
                            recordCopySource(
                                validationSource: prevGlobalIndex,
                                pixelSource: prevGlobalIndex,
                                for: globalIndex)

                        case 2:
                            guard pixelY >= 8 else {
                                throw AppleAdaptiveDCTError.malformed(
                                    "DCT vertical-copy command appears at tile \(tileNumber) "
                                        + "(\(localX),\(localY))")
                            }
                            copyTile(
                                fromX: pixelX, fromY: pixelY - 8,
                                toX: pixelX, toY: pixelY,
                                base: base, width: width, height: height,
                                bytesPerRow: bytesPerRow)
                            let sourceGlobalIndex = globalIndex - framebufferTilesWide
                            recordCopySource(
                                validationSource: sourceGlobalIndex,
                                pixelSource: sourceGlobalIndex,
                                for: globalIndex)

                        case 3:
                            try renderTwoColorTile(
                                reader: &data, first: 0xffff_ffff, second: 0x0000_0000,
                                x: pixelX, y: pixelY, base: base, width: width,
                                height: height, bytesPerRow: bytesPerRow)

                        case 4:
                            let subtype = Int(try data.readBits(2))
                            switch subtype {
                            case 0:
                                let color = try readBGRAColor(&data)
                                cachedSolidColor = color
                                renderSolidTile(
                                    color, x: pixelX, y: pixelY, base: base,
                                    width: width, height: height, bytesPerRow: bytesPerRow)
                            case 1:
                                guard let cachedSolidColor else {
                                    throw AppleAdaptiveDCTError.malformed(
                                        "DCT fill reuses a color before defining it")
                                }
                                renderSolidTile(
                                    cachedSolidColor, x: pixelX, y: pixelY, base: base,
                                    width: width, height: height, bytesPerRow: bytesPerRow)
                            case 2:
                                let first = try readBGRAColor(&data)
                                let second = try readBGRAColor(&data)
                                cachedPaletteFirst = first
                                cachedPaletteSecond = second
                                try renderTwoColorTile(
                                    reader: &data, first: first, second: second,
                                    x: pixelX, y: pixelY, base: base, width: width,
                                    height: height, bytesPerRow: bytesPerRow)
                            default:
                                guard let cachedPaletteFirst, let cachedPaletteSecond else {
                                    throw AppleAdaptiveDCTError.malformed(
                                        "DCT two-color fill reuses a palette before defining it")
                                }
                                try renderTwoColorTile(
                                    reader: &data, first: cachedPaletteFirst,
                                    second: cachedPaletteSecond,
                                    x: pixelX, y: pixelY, base: base, width: width,
                                    height: height, bytesPerRow: bytesPerRow)
                            }

                        case 5:
                            let reusesPrevious = try data.readBit() != 0
                            var hasLumaAC = true
                            if !reusesPrevious {
                                memset(predictorMap.baseAddress!, 0, 99)
                                do {
                                    let decoded = try decodeNewTile(
                                        reader: &data,
                                        predictor: predictor,
                                        map: predictorMap,
                                        lowCutoff: field1,
                                        highCutoff: field2,
                                        zigzag: kernel.zigzag)
                                    predictorQuality = decoded.quality
                                    hasLumaAC = decoded.hasLumaAC
                                } catch {
                                    throw AppleAdaptiveDCTError.malformed(
                                        "DCT tile \(tileNumber) command 5 failed at data bit "
                                            + "\(data.bitOffset): \(error.localizedDescription)")
                                }
                            }
                            storeTileState(
                                map: predictorMap,
                                quality: predictorQuality,
                                cbCount: 1,
                                crCount: 1,
                                at: globalIndex)
                            if drawPixels {
                                let tileW = min(8, width - pixelX)
                                let tileH = min(8, height - pixelY)
                                if pixelX >= 0, pixelY >= 0, tileW > 0, tileH > 0 {
                                    if reusesPrevious && hasLastDCTPixels {
                                        if lastDCTFullTile {
                                            copyTile(
                                                fromX: lastDCTPixelX, fromY: lastDCTPixelY,
                                                toX: pixelX, toY: pixelY,
                                                base: base, width: width, height: height,
                                                bytesPerRow: bytesPerRow)
                                        } else {
                                            renderPixelTile(
                                                fallbackPixels, x: pixelX, y: pixelY, base: base,
                                                width: width, height: height, bytesPerRow: bytesPerRow)
                                        }
                                    } else {
                                        let flags: UInt8 = UInt8(RFB_DCT_FLAG_CHROMA_DC_ONLY)
                                            | (hasLumaAC ? 0 : UInt8(RFB_DCT_FLAG_LUMA_DC_ONLY))
                                        if tileW == 8 && tileH == 8 {
                                            let dst = base.advanced(by: pixelY * bytesPerRow + pixelX * 4)
                                                .assumingMemoryBound(to: UInt8.self)
                                            rfb_apple_dct_tile_bgra_stride(
                                                dst, bytesPerRow, 8, 8,
                                                predictor.baseAddress, kernel.luma, kernel.chroma,
                                                flags)
                                            lastDCTFullTile = true
                                            lastDCTPixelX = pixelX
                                            lastDCTPixelY = pixelY
                                            hasLastDCTPixels = true
                                        } else {
                                            rfb_apple_dct_tile_bgra_stride(
                                                UnsafeMutableRawPointer(fallbackPixels.baseAddress!)
                                                    .assumingMemoryBound(to: UInt8.self),
                                                8 * 4, 8, 8,
                                                predictor.baseAddress, kernel.luma, kernel.chroma,
                                                flags)
                                            renderPixelTile(
                                                fallbackPixels, x: pixelX, y: pixelY, base: base,
                                                width: width, height: height, bytesPerRow: bytesPerRow)
                                            lastDCTFullTile = false
                                            hasLastDCTPixels = true
                                        }
                                    }
                                }
                            }

                        case 6, 7:
                            let cacheIndex: Int
                            if command == 6 {
                                cacheIndex = Int(try data.readBits(16))
                            } else {
                                cacheIndex = nextCacheIndex(after: cacheReadIndex)
                            }
                            let cachedCoefficients = try cachedTileCoefficients(at: cacheIndex)
                            if drawPixels {
                                let tileW = min(8, width - pixelX)
                                let tileH = min(8, height - pixelY)
                                if pixelX >= 0, pixelY >= 0, tileW > 0, tileH > 0 {
                                    let dst = base.advanced(by: pixelY * bytesPerRow + pixelX * 4)
                                        .assumingMemoryBound(to: UInt8.self)
                                    rfb_apple_dct_tile_bgra_stride(
                                        dst, bytesPerRow, Int32(tileW), Int32(tileH),
                                        cachedCoefficients, kernel.luma, kernel.chroma, 0)
                                }
                            }

                        default:
                            throw AppleAdaptiveDCTError.malformed(
                                "Invalid DCT tile command \(command)")
                        }

                        prevPixelX = pixelX
                        prevPixelY = pixelY
                        prevGlobalIndex = globalIndex
                        tileNumber &+= 1
                        localX &+= 1
                        if localX == tilesWide {
                            localX = 0
                            localY &+= 1
                            pixelX = rectX
                            pixelY &+= 8
                        } else {
                            pixelX &+= 8
                        }
                    }
                }

                if tileCount > 0 {
                    let minX = max(0, rectX)
                    let minY = max(0, rectY)
                    let maxX = min(width, rectX + tilesWide * 8)
                    let maxY = min(height, rectY + tilesHigh * 8)
                    if minX < maxX, minY < maxY {
                        dirtyRect = CGRect(
                            x: minX, y: minY, width: maxX - minX, height: maxY - minY)
                    }
                }
            }
            return dirtyRect
        }
    }

    private func ensureFramebuffer(width: Int, height: Int) {
        guard width != framebufferWidth || height != framebufferHeight else { return }
        framebufferWidth = width
        framebufferHeight = height
        let count = ((width + 7) / 8) * ((height + 7) / 8)
        tileStates = TileMapStorage(count: count)
        baseUpdateGeneration = 0
        // The coefficient cache stays: the Mac keeps its cache keys across
        // display size changes within a connection.
    }

    @inline(__always)
    private func storeTileState(
        map: UnsafeMutableBufferPointer<Int8>,
        quality: Int,
        cbCount: UInt8,
        crCount: UInt8,
        at index: Int
    ) {
        guard index >= 0, index < tileStates.count else { return }
        tileStates.store(map: map, quality: quality, cbCount: cbCount, crCount: crCount, at: index)
    }

    @inline(__always)
    private func recordBaseTile(at index: Int, generation: UInt64) {
        guard index >= 0, index < tileStates.count else { return }
        tileStates.metadata[index].generation = generation
        tileStates.metadata[index].validationSource = -1
        tileStates.metadata[index].pixelSource = -1
    }

    @inline(__always)
    private func recordCopySource(
        validationSource: Int?, pixelSource: Int, for destination: Int
    ) {
        guard destination >= 0, destination < tileStates.count,
            pixelSource >= 0, pixelSource < tileStates.count
        else { return }
        tileStates.metadata[destination].validationSource = validationSource ?? -1
        tileStates.metadata[destination].pixelSource = pixelSource
    }

    /// Connection-owned map and copy-reference metadata per framebuffer tile.
    /// Does not retain 384-byte coefficient arrays because type-1 refinement
    /// only consumes the 99-byte zigzag map and metadata.
    private final class TileMapStorage {
        struct Metadata {
            var quality = -1
            var cbCount: UInt8 = 0
            var crCount: UInt8 = 0
            // Copy references are valid only within the same base generation.
            var validationSource = -1
            var pixelSource = -1
            var generation: UInt64 = 0
        }

        let count: Int
        let maps: UnsafeMutableBufferPointer<Int8>
        let metadata: UnsafeMutableBufferPointer<Metadata>

        init(count: Int) {
            self.count = count
            maps = .allocate(capacity: count * 99)
            metadata = .allocate(capacity: count)
            maps.initialize(repeating: 0)
            metadata.initialize(repeating: Metadata())
        }

        deinit {
            maps.deinitialize()
            maps.deallocate()
            metadata.deinitialize()
            metadata.deallocate()
        }

        @inline(__always)
        func mapPointer(at index: Int) -> UnsafeMutablePointer<Int8> {
            maps.baseAddress!.advanced(by: index * 99)
        }

        @inline(__always)
        func store(
            map: UnsafeMutableBufferPointer<Int8>,
            quality: Int,
            cbCount: UInt8,
            crCount: UInt8,
            at index: Int
        ) {
            memmove(maps.baseAddress!.advanced(by: index * 99), map.baseAddress!, 99)
            metadata[index].quality = quality
            metadata[index].cbCount = cbCount
            metadata[index].crCount = crCount
        }
    }

    /// 256-slot coefficient page for the 64,999-entry DCT refinement cache ring.
    /// Stores only the 192 `Int16` coefficients per slot plus a 256-bit presence
    /// mask; cache reads never inspect maps or metadata.
    private final class CacheCoefficientStorage {
        static let pageSize = 256
        private let coefficients: UnsafeMutableBufferPointer<Int16>
        private var present0: UInt64 = 0
        private var present1: UInt64 = 0
        private var present2: UInt64 = 0
        private var present3: UInt64 = 0

        init() {
            coefficients = .allocate(capacity: Self.pageSize * 192)
            coefficients.initialize(repeating: 0)
        }

        deinit {
            coefficients.deinitialize()
            coefficients.deallocate()
        }

        @inline(__always)
        func claimSlot(_ slot: Int) -> UnsafeMutablePointer<Int16> {
            let bit = UInt64(1) << (slot & 63)
            switch slot >> 6 {
            case 0: present0 |= bit
            case 1: present1 |= bit
            case 2: present2 |= bit
            default: present3 |= bit
            }
            return coefficients.baseAddress!.advanced(by: slot * 192)
        }

        @inline(__always)
        func pointerIfPresent(at slot: Int) -> UnsafePointer<Int16>? {
            let bit = UInt64(1) << (slot & 63)
            let word: UInt64
            switch slot >> 6 {
            case 0: word = present0
            case 1: word = present1
            case 2: word = present2
            default: word = present3
            }
            guard (word & bit) != 0 else { return nil }
            return UnsafePointer(coefficients.baseAddress!.advanced(by: slot * 192))
        }
    }

    @inline(__always)
    private func claimCacheSlot(at index: Int) -> UnsafeMutablePointer<Int16> {
        let page = index >> 8
        let storage: CacheCoefficientStorage
        if let existing = coefficientCache[page] {
            storage = existing
        } else {
            storage = CacheCoefficientStorage()
            coefficientCache[page] = storage
        }
        return storage.claimSlot(index & 0xff)
    }

    @inline(__always)
    private func cachedTileCoefficients(at index: Int) throws -> UnsafePointer<Int16> {
        guard index > 0, index < 65_000 else {
            throw AppleAdaptiveDCTError.malformed(
                "DCT coefficient-cache tile \(index) is outside the valid range")
        }
        cacheReadIndex = index
        if let pointer = coefficientCache[index >> 8]?.pointerIfPresent(at: index & 0xff) {
            return pointer
        }
        // Unpopulated cache key resolves to an all-zero coefficient block.
        return UnsafePointer(scratchCoefficients.baseAddress!.advanced(by: 192))
    }

    @inline(__always)
    private func nextCacheIndex(after index: Int) -> Int {
        index >= 64_999 ? 1 : index + 1
    }

    private func renderRefinement(
        rect: FramebufferRect,
        payload: Data,
        messageLength: Int,
        to framebuffer: Framebuffer,
        drawPixels: Bool
    ) throws -> CGRect? {
        guard messageLength >= 4 else {
            throw AppleAdaptiveDCTError.malformed("Malformed DCT type-1 message length")
        }
        guard framebuffer.bytesPerPixel == 4 else {
            throw AppleAdaptiveDCTError.malformed("Apple DCT requires a 32-bit framebuffer")
        }
        let base = payload.startIndex
        let threshold1 = Int(payload[base + 5])
        let threshold2 = Int(payload[base + 6])
        guard threshold1 < 16, threshold2 < 21 else {
            throw AppleAdaptiveDCTError.malformed(
                "DCT refinement thresholds \(threshold1),\(threshold2) exceed Apple limits")
        }
        defer { withExtendedLifetime(self) {} }
        return try payload.withUnsafeBytes { payloadBytes in
            try withRenderBuffers { kernel, _ in
                var bits = BitReader(UnsafeRawBufferPointer(rebasing: payloadBytes[7...]))
                ensureFramebuffer(width: framebuffer.width, height: framebuffer.height)
                let rectX = Int(rect.x)
                let rectY = Int(rect.y)
                let tilesWide = (Int(rect.width) + 7) / 8
                let tilesHigh = (Int(rect.height) + 7) / 8
                let tileCount = tilesWide * tilesHigh
                let framebufferTilesWide = (framebufferWidth + 7) / 8
                let refinementMap = UnsafeMutableBufferPointer(rebasing: scratchMaps[99..<198])

                var dirtyMinX = Int.max
                var dirtyMinY = Int.max
                var dirtyMaxX = Int.min
                var dirtyMaxY = Int.min

                try framebuffer.withUnsafeMutablePixelBytes { raw, width, height, bytesPerRow, _ in
                    var tileNumber = 0
                    var localX = 0
                    var pixelX = rectX
                    var pixelY = rectY
                    while tileNumber < tileCount {
                        let globalIndex = (pixelY >> 3) * framebufferTilesWide + (pixelX >> 3)
                        guard globalIndex >= 0 && globalIndex < tileStates.count else {
                            throw AppleAdaptiveDCTError.malformed(
                                "DCT refinement tile lies outside the framebuffer")
                        }
                        let command = Int(try bits.readBits(2))
                        switch command {
                        case 0:
                            break

                        case 1:
                            let refined = try refineTile(
                                at: globalIndex,
                                reader: &bits,
                                threshold1: threshold1,
                                threshold2: threshold2,
                                map: refinementMap,
                                kernel: kernel)
                            storeTileState(
                                map: refinementMap,
                                quality: refined.quality,
                                cbCount: UInt8(threshold2 + 1),
                                crCount: UInt8(threshold1 + 1),
                                at: globalIndex)
                            if drawPixels {
                                let tileW = min(8, width - pixelX)
                                let tileH = min(8, height - pixelY)
                                if pixelX >= 0, pixelY >= 0, tileW > 0, tileH > 0 {
                                    let dst = raw.advanced(by: pixelY * bytesPerRow + pixelX * 4)
                                        .assumingMemoryBound(to: UInt8.self)
                                    rfb_apple_dct_tile_bgra_stride(
                                        dst, bytesPerRow, Int32(tileW), Int32(tileH),
                                        refined.coefficients, kernel.luma, kernel.chroma,
                                        refined.flags)
                                }
                            }
                            if pixelX < dirtyMinX { dirtyMinX = pixelX }
                            if pixelY < dirtyMinY { dirtyMinY = pixelY }
                            let endX = pixelX + 8
                            let endY = pixelY + 8
                            if endX > dirtyMaxX { dirtyMaxX = endX }
                            if endY > dirtyMaxY { dirtyMaxY = endY }

                        case 2:
                            let metadata = tileStates.metadata[globalIndex]
                            let validationSource = metadata.validationSource
                            let pixelSource = metadata.pixelSource
                            if validationSource >= 0, pixelSource >= 0,
                                tileStates.metadata[validationSource].generation == metadata.generation
                            {
                                let sourcePixelX = (pixelSource % framebufferTilesWide) * 8
                                let sourcePixelY = (pixelSource / framebufferTilesWide) * 8
                                if drawPixels {
                                    copyTile(
                                        fromX: sourcePixelX, fromY: sourcePixelY,
                                        toX: pixelX, toY: pixelY,
                                        base: raw, width: width, height: height,
                                        bytesPerRow: bytesPerRow)
                                }
                                if pixelX < dirtyMinX { dirtyMinX = pixelX }
                                if pixelY < dirtyMinY { dirtyMinY = pixelY }
                                let endX = pixelX + 8
                                let endY = pixelY + 8
                                if endX > dirtyMaxX { dirtyMaxX = endX }
                                if endY > dirtyMaxY { dirtyMaxY = endY }
                            }

                        case 3:
                            let cacheIndex: Int
                            if try bits.readBit() != 0 {
                                cacheIndex = nextCacheIndex(after: cacheReadIndex)
                            } else {
                                cacheIndex = Int(try bits.readBits(16))
                            }
                            guard cacheIndex > 0, cacheIndex < 65_000 else {
                                throw AppleAdaptiveDCTError.malformed(
                                    "DCT refinement tile \(globalIndex) read invalid cache key "
                                        + "\(cacheIndex) at bit \(bits.bitOffset)")
                            }
                            let cachedCoefficients = try cachedTileCoefficients(at: cacheIndex)
                            if drawPixels {
                                let tileW = min(8, width - pixelX)
                                let tileH = min(8, height - pixelY)
                                if pixelX >= 0, pixelY >= 0, tileW > 0, tileH > 0 {
                                    let dst = raw.advanced(by: pixelY * bytesPerRow + pixelX * 4)
                                        .assumingMemoryBound(to: UInt8.self)
                                    rfb_apple_dct_tile_bgra_stride(
                                        dst, bytesPerRow, Int32(tileW), Int32(tileH),
                                        cachedCoefficients, kernel.luma, kernel.chroma, 0)
                                }
                            }
                            if pixelX < dirtyMinX { dirtyMinX = pixelX }
                            if pixelY < dirtyMinY { dirtyMinY = pixelY }
                            let endX = pixelX + 8
                            let endY = pixelY + 8
                            if endX > dirtyMaxX { dirtyMaxX = endX }
                            if endY > dirtyMaxY { dirtyMaxY = endY }

                        default:
                            break
                        }

                        tileNumber &+= 1
                        localX &+= 1
                        if localX == tilesWide {
                            localX = 0
                            pixelX = rectX
                            pixelY &+= 8
                        } else {
                            pixelX &+= 8
                        }
                    }

                    if dirtyMinX < dirtyMaxX && dirtyMinY < dirtyMaxY {
                        let minX = max(0, dirtyMinX)
                        let minY = max(0, dirtyMinY)
                        let maxX = min(width, dirtyMaxX)
                        let maxY = min(height, dirtyMaxY)
                        if minX < maxX && minY < maxY {
                            dirtyMinX = minX
                            dirtyMinY = minY
                            dirtyMaxX = maxX
                            dirtyMaxY = maxY
                        } else {
                            dirtyMinX = Int.max
                        }
                    }
                }

                guard dirtyMinX < dirtyMaxX && dirtyMinY < dirtyMaxY else { return nil }
                return CGRect(
                    x: dirtyMinX,
                    y: dirtyMinY,
                    width: dirtyMaxX - dirtyMinX,
                    height: dirtyMaxY - dirtyMinY)
            }
        }
    }

    /// Refine tile `index` directly into the next coefficient-cache slot so no
    /// intermediate 384-byte scratch copy occurs.
    @inline(__always)
    private func refineTile(
        at index: Int,
        reader: inout BitReader,
        threshold1: Int,
        threshold2: Int,
        map: UnsafeMutableBufferPointer<Int8>,
        kernel: Kernel
    ) throws -> (coefficients: UnsafePointer<Int16>, quality: Int, flags: UInt8) {
        guard index >= 0 && index < tileStates.count else {
            throw AppleAdaptiveDCTError.malformed(
                "DCT refinement tile \(index) has no coefficient state")
        }
        let info = tileStates.metadata[index]
        guard info.quality >= 0 else {
            throw AppleAdaptiveDCTError.malformed(
                "DCT refinement tile \(index) has no coefficient state")
        }
        guard info.cbCount == 1, info.crCount == 1 else {
            throw AppleAdaptiveDCTError.malformed(
                "DCT refinement tile \(index) at bit \(reader.bitOffset) requires "
                    + "single-coefficient chroma predictors; found "
                    + "Cb=\(info.cbCount), Cr=\(info.crCount)")
        }

        let old = tileStates.mapPointer(at: index)
        memset(map.baseAddress!, 0, 99)
        map[0] = old[0]
        let targetY = Int(try reader.readBits(6))
        let oldY = info.quality
        var next = min(oldY, targetY + 1)
        if oldY > 14 {
            if targetY == 0 {
                next = 1
            } else if next >= 2 {
                var coefficient = 1
                while coefficient < next {
                    map[coefficient] = try adjustByOne(old[coefficient], reader: &reader)
                    coefficient &+= 1
                }
            }
            if next <= targetY {
                var coefficient = next
                let limit = min(targetY, 63)
                while coefficient <= limit {
                    map[coefficient] = try adjustOrRead(
                        old[coefficient], bits: 3, reader: &reader)
                    coefficient &+= 1
                }
            }
        } else {
            if next >= 2 {
                var coefficient = 1
                while coefficient < next {
                    map[coefficient] = try adjustOrRead(
                        old[coefficient], bits: 3, reader: &reader)
                    coefficient &+= 1
                }
            } else {
                next = 1
            }
            if next <= targetY {
                var coefficient = next
                let limit = min(targetY, 63)
                while coefficient <= limit {
                    map[coefficient] = try adjustOrRead(
                        old[coefficient], bits: 4, reader: &reader)
                    coefficient &+= 1
                }
            }
        }

        map[84] = try adjustByOne(old[84], reader: &reader)
        let crHasAC = try decodeLuminanceACHuffman(
            reader: &reader, into: map, base: 84, maximum: threshold1, lut: kernel.huffmanLUT)
        map[64] = try adjustByOne(old[64], reader: &reader)
        let cbHasAC = try decodeLuminanceACHuffman(
            reader: &reader, into: map, base: 64, maximum: threshold2, lut: kernel.huffmanLUT)

        // Advance the cache ring and scatter directly into the cache slot.
        cacheWriteIndex = nextCacheIndex(after: cacheWriteIndex)
        let values = claimCacheSlot(at: cacheWriteIndex)
        memset(values, 0, 192 * 2)

        let zigzag = kernel.zigzag
        let lumaLimit = min(63, targetY)
        values[0] = Int16(map[0])
        var hasLumaAC = false
        var c = 1
        while c <= lumaLimit {
            let v = map[c]
            if v != 0 {
                values[zigzag[c]] = Int16(v)
                hasLumaAC = true
            }
            c &+= 1
        }
        values[64] = Int16(map[64])
        if cbHasAC {
            c = 1
            let cbLimit = min(19, threshold2)
            while c <= cbLimit {
                let v = map[64 + c]
                if v != 0 {
                    values[64 + zigzag[c]] = Int16(v)
                }
                c &+= 1
            }
        }
        values[128] = Int16(map[84])
        if crHasAC {
            c = 1
            let crLimit = min(14, threshold1)
            while c <= crLimit {
                let v = map[84 + c]
                if v != 0 {
                    values[128 + zigzag[c]] = Int16(v)
                }
                c &+= 1
            }
        }

        var flags: UInt8 = 0
        if !cbHasAC && !crHasAC {
            flags |= UInt8(RFB_DCT_FLAG_CHROMA_DC_ONLY)
        }
        if !hasLumaAC {
            flags |= UInt8(RFB_DCT_FLAG_LUMA_DC_ONLY)
        }
        let quality = min(64, targetY + 1)
        return (UnsafePointer(values), quality, flags)
    }

    @inline(__always)
    private func adjustByOne(
        _ coefficient: Int8, reader: inout BitReader
    ) throws -> Int8 {
        let adjustment = Int(try reader.readBit())
        let value = Int(coefficient)
        if value > 0 { return Int8(clamping: value + adjustment) }
        if value < 0 { return Int8(clamping: value - adjustment) }
        guard adjustment != 0 else { return 0 }
        return try reader.readBit() == 0 ? 1 : -1
    }

    @inline(__always)
    private func adjustOrRead(
        _ coefficient: Int8, bits: Int, reader: inout BitReader
    ) throws -> Int8 {
        let value = Int(coefficient)
        guard value != 0 else {
            return Int8(clamping: try reader.readSignedDCRice())
        }
        let adjustment = Int(try reader.readBits(bits))
        let signedAdjustment = value < 0 ? -adjustment : adjustment
        return Int8(clamping: value + signedAdjustment)
    }

    @inline(__always)
    private func decodeNewTile(
        reader: inout BitReader,
        predictor: UnsafeMutableBufferPointer<Int16>,
        map: UnsafeMutableBufferPointer<Int8>,
        lowCutoff: Int,
        highCutoff: Int,
        zigzag: UnsafeBufferPointer<Int>
    ) throws -> (quality: Int, hasLumaAC: Bool) {
        let reuseChroma = try reader.readBit() != 0
        let cutoff = try reader.readBit() != 0 ? highCutoff : lowCutoff
        let previousY = predictor[0]
        let previousCb = predictor[64]
        let previousCr = predictor[128]
        // Only luma (64 Int16s = 128 bytes) can have AC terms in type-0;
        // chroma AC lanes stay zero permanently on the predictor buffer.
        memset(predictor.baseAddress!, 0, 64 * 2)
        if reuseChroma {
            predictor[64] = previousCb
            predictor[128] = previousCr
        } else {
            predictor[64] = Int16(clamping: (halfTowardZero(previousCb) - (try reader.readSignedDCRice())) * 2)
            predictor[128] = Int16(clamping: (halfTowardZero(previousCr) - (try reader.readSignedDCRice())) * 2)
        }
        predictor[0] = Int16(clamping: Int(previousY) - (try reader.readSignedDCRice()))
        map[0] = Int8(truncatingIfNeeded: predictor[0])
        map[64] = Int8(truncatingIfNeeded: predictor[64])
        map[84] = Int8(truncatingIfNeeded: predictor[128])

        var hasLumaAC = false
        var coefficient = 1
        let lowAmp = cutoff < 15 ? 8 : 2
        let highAmp = cutoff < 15 ? 16 : 8
        let lowShift = cutoff < 15 ? 3 : 1
        let highShift = cutoff < 15 ? 4 : 3
        while coefficient < 64 {
            if try reader.readBit() == 0 {
                let amplitude = coefficient < cutoff ? lowAmp : highAmp
                let result = try reader.readSmallCoefficient(
                    at: coefficient, amplitude: amplitude)
                if let value = result.value {
                    predictor[zigzag[coefficient]] = Int16(clamping: value)
                    map[coefficient] = Int8(truncatingIfNeeded: value)
                    hasLumaAC = true
                }
                coefficient = result.nextIndex
                continue
            }

            let raw = try reader.readLargeACCoefficient(coefficient: coefficient)
            let shift = coefficient < cutoff ? lowShift : highShift
            let stored = Int8(truncatingIfNeeded: raw << shift)
            map[coefficient] = stored
            if stored != 0 {
                predictor[zigzag[coefficient]] = Int16(stored)
                hasLumaAC = true
            }
            coefficient &+= 1
        }
        return (cutoff, hasLumaAC)
    }

    @inline(__always)
    private func halfTowardZero(_ value: Int16) -> Int {
        Int(value) / 2
    }

    @inline(__always)
    private func readBGRAColor(_ reader: inout BitReader) throws -> UInt32 {
        let color = try reader.readYCC20()
        return bgra(y: color.y, cb: color.cb, cr: color.cr)
    }

    @inline(__always)
    private func renderSolidTile(
        _ color: UInt32, x: Int, y: Int, base: UnsafeMutableRawPointer,
        width: Int, height: Int, bytesPerRow: Int
    ) {
        let maxX = min(x + 8, width)
        let maxY = min(y + 8, height)
        guard x >= 0, y >= 0, x < maxX, y < maxY else { return }
        let leColor = color.littleEndian
        if maxX - x == 8 {
            var row = y
            var rowPtr = base.advanced(by: row * bytesPerRow + x * 4)
            while row < maxY {
                let pixels = rowPtr.assumingMemoryBound(to: UInt32.self)
                pixels[0] = leColor
                pixels[1] = leColor
                pixels[2] = leColor
                pixels[3] = leColor
                pixels[4] = leColor
                pixels[5] = leColor
                pixels[6] = leColor
                pixels[7] = leColor
                rowPtr = rowPtr.advanced(by: bytesPerRow)
                row &+= 1
            }
            return
        }
        var row = y
        while row < maxY {
            let pixels = base.advanced(by: row * bytesPerRow).assumingMemoryBound(to: UInt32.self)
            var column = x
            while column < maxX {
                pixels[column] = leColor
                column &+= 1
            }
            row &+= 1
        }
    }

    @inline(__always)
    private func copyTile(
        fromX: Int, fromY: Int, toX: Int, toY: Int,
        base: UnsafeMutableRawPointer, width: Int, height: Int, bytesPerRow: Int
    ) {
        let pixelCount = min(8, width - max(fromX, toX))
        let rowCount = min(8, min(height - fromY, height - toY))
        guard fromX >= 0, fromY >= 0, toX >= 0, toY >= 0,
            pixelCount > 0, rowCount > 0
        else { return }
        if pixelCount == 8 && (fromY != toY || abs(fromX - toX) >= 8) {
            var srcRow = base.advanced(by: fromY * bytesPerRow + fromX * 4)
            var dstRow = base.advanced(by: toY * bytesPerRow + toX * 4)
            var remaining = rowCount
            while remaining > 0 {
                memcpy(dstRow, srcRow, 32)
                srcRow = srcRow.advanced(by: bytesPerRow)
                dstRow = dstRow.advanced(by: bytesPerRow)
                remaining &-= 1
            }
            return
        }
        var row = rowCount
        while row > 0 {
            row &-= 1
            let source = base.advanced(by: (fromY + row) * bytesPerRow + fromX * 4)
            let destination = base.advanced(by: (toY + row) * bytesPerRow + toX * 4)
            memmove(destination, source, pixelCount * 4)
        }
    }

    @inline(__always)
    private func renderTwoColorTile(
        reader: inout BitReader, first: UInt32, second: UInt32,
        x: Int, y: Int, base: UnsafeMutableRawPointer,
        width: Int, height: Int, bytesPerRow: Int
    ) throws {
        var rowControl = UInt8(try reader.readBits(8))
        let firstLE = first.littleEndian
        let secondLE = second.littleEndian
        let fullWidth = x + 8 <= width
        var row = 0
        while row < 8 {
            let isUniformFirst = rowControl & 0x80 != 0
            let mask = isUniformFirst ? 0 : UInt8(try reader.readBits(8))
            rowControl <<= 1
            if y + row < height {
                let rowPtr = base.advanced(by: (y + row) * bytesPerRow + x * 4)
                if isUniformFirst && fullWidth {
                    let pixels = rowPtr.assumingMemoryBound(to: UInt32.self)
                    pixels[0] = firstLE
                    pixels[1] = firstLE
                    pixels[2] = firstLE
                    pixels[3] = firstLE
                    pixels[4] = firstLE
                    pixels[5] = firstLE
                    pixels[6] = firstLE
                    pixels[7] = firstLE
                } else if fullWidth {
                    let pixels = rowPtr.assumingMemoryBound(to: UInt32.self)
                    pixels[0] = (mask & 0x80) == 0 ? secondLE : firstLE
                    pixels[1] = (mask & 0x40) == 0 ? secondLE : firstLE
                    pixels[2] = (mask & 0x20) == 0 ? secondLE : firstLE
                    pixels[3] = (mask & 0x10) == 0 ? secondLE : firstLE
                    pixels[4] = (mask & 0x08) == 0 ? secondLE : firstLE
                    pixels[5] = (mask & 0x04) == 0 ? secondLE : firstLE
                    pixels[6] = (mask & 0x02) == 0 ? secondLE : firstLE
                    pixels[7] = (mask & 0x01) == 0 ? secondLE : firstLE
                } else {
                    let pixels = rowPtr.assumingMemoryBound(to: UInt32.self)
                    var column = 0
                    let maxCol = width - x
                    while column < 8 && column < maxCol {
                        pixels[column] = isUniformFirst
                            ? firstLE
                            : (mask & (0x80 >> column) == 0 ? secondLE : firstLE)
                        column &+= 1
                    }
                }
            }
            row &+= 1
        }
    }

    @inline(__always)
    private func decodeLuminanceACHuffman(
        reader: inout BitReader,
        into map: UnsafeMutableBufferPointer<Int8>,
        base: Int,
        maximum: Int,
        lut: UnsafeBufferPointer<UInt16>
    ) throws -> Bool {
        guard maximum > 0 else { return false }
        var hasAC = false
        var coefficient = 1
        while coefficient <= maximum {
            let symbol = try reader.readLuminanceACHuffmanSymbol(lut: lut)
            let zeroRun = Int(symbol >> 4)
            let amplitudeBits = Int(symbol & 0x0f)
            if amplitudeBits == 0 {
                if zeroRun == 15 {
                    coefficient &+= 16
                    continue
                }
                return hasAC
            }
            coefficient &+= zeroRun
            var amplitude = Int(try reader.readBits(amplitudeBits))
            let midpoint = 1 << (amplitudeBits - 1)
            if amplitude < midpoint {
                amplitude -= (1 << amplitudeBits) - 1
            }
            let destination = base + coefficient
            if destination >= 0 && destination < map.count {
                let stored = Int8(clamping: amplitude)
                map[destination] = stored
                if stored != 0 { hasAC = true }
            }
            coefficient &+= 1
        }
        return hasAC
    }

    private struct Kernel {
        let luma: UnsafePointer<UInt16>
        let chroma: UnsafePointer<UInt16>
        let zigzag: UnsafeBufferPointer<Int>
        let huffmanLUT: UnsafeBufferPointer<UInt16>
    }

    private func withRenderBuffers<Result>(
        _ body: (Kernel, UnsafeMutableBufferPointer<UInt32>) throws -> Result
    ) rethrows -> Result {
        try lumaQuantization.withUnsafeBufferPointer { luma in
            try chromaQuantization.withUnsafeBufferPointer { chroma in
                try Self.zigzag.withUnsafeBufferPointer { zigzag in
                    try Self.luminanceACHuffmanLUT.withUnsafeBufferPointer { lut in
                        try withUnsafeTemporaryAllocation(of: UInt32.self, capacity: 64) { pixels in
                            pixels.initialize(repeating: 0)
                            return try body(
                                Kernel(
                                    luma: luma.baseAddress!,
                                    chroma: chroma.baseAddress!,
                                    zigzag: zigzag,
                                    huffmanLUT: lut),
                                pixels)
                        }
                    }
                }
            }
        }
    }

    @inline(__always)
    private func renderPixelTile(
        _ tile: UnsafeMutableBufferPointer<UInt32>, x: Int, y: Int,
        base: UnsafeMutableRawPointer, width: Int, height: Int, bytesPerRow: Int
    ) {
        let columns = min(8, width - x)
        let rows = min(8, height - y)
        guard x >= 0, y >= 0, columns > 0, rows > 0 else { return }
        // Supported Apple architectures are little-endian, as is BGRA storage.
        var row = 0
        while row < rows {
            memcpy(
                base.advanced(by: (y + row) * bytesPerRow + x * 4),
                tile.baseAddress!.advanced(by: row * 8), columns * 4)
            row &+= 1
        }
    }

    @inline(__always)
    private func bgra(y: UInt8, cb: UInt8, cr: UInt8) -> UInt32 {
        let yFixed = (Int(y) << 20) + (1 << 19)
        let cbSigned = Int(cb) - 128
        let crSigned = Int(cr) - 128
        let red = UInt32(UInt8(clamping: (yFixed + crSigned * (5_743 << 8)) >> 20))
        let greenTerm = (cbSigned * -(1_410 << 8)) & ~0xffff
        let green = UInt32(UInt8(clamping: (yFixed + crSigned * -(2_925 << 8) + greenTerm) >> 20))
        let blue = UInt32(UInt8(clamping: (yFixed + cbSigned * (7_258 << 8)) >> 20))
        return 0xff00_0000 | red << 16 | green << 8 | blue
    }

    private static let zigzag = [
        0, 1, 8, 16, 9, 2, 3, 10,
        17, 24, 32, 25, 18, 11, 4, 5,
        12, 19, 26, 33, 40, 48, 41, 34,
        27, 20, 13, 6, 7, 14, 21, 28,
        35, 42, 49, 56, 57, 50, 43, 36,
        29, 22, 15, 23, 30, 37, 44, 51,
        58, 59, 52, 45, 38, 31, 39, 46,
        53, 60, 61, 54, 47, 55, 62, 63,
    ]

    // The refinement stream uses the standard JPEG luminance AC table.
    // These canonical counts/values are equivalent to the 13-node lookup
    // table embedded in compatible Adaptive DCT decoders.
    static let luminanceACCodeCounts = [
        0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 125,
    ]
    static let luminanceACValues: [UInt8] = [
        0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12,
        0x21, 0x31, 0x41, 0x06, 0x13, 0x51, 0x61, 0x07,
        0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xa1, 0x08,
        0x23, 0x42, 0xb1, 0xc1, 0x15, 0x52, 0xd1, 0xf0,
        0x24, 0x33, 0x62, 0x72, 0x82, 0x09, 0x0a, 0x16,
        0x17, 0x18, 0x19, 0x1a, 0x25, 0x26, 0x27, 0x28,
        0x29, 0x2a, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39,
        0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49,
        0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59,
        0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69,
        0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79,
        0x7a, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89,
        0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98,
        0x99, 0x9a, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7,
        0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6,
        0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3, 0xc4, 0xc5,
        0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2, 0xd3, 0xd4,
        0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda, 0xe1, 0xe2,
        0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea,
        0xf1, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8,
        0xf9, 0xfa,
    ]

    /// 9-bit flat lookup table for `luminanceACCodeCounts`/`luminanceACValues`.
    /// Each non-zero entry packs `(UInt16(symbol) << 8) | UInt16(bitLength)`.
    static let luminanceACHuffmanLUT: [UInt16] = {
        var table = [UInt16](repeating: 0, count: 512)
        var code = 0
        var valueIndex = 0
        for length in 1...9 {
            let count = luminanceACCodeCounts[length - 1]
            let shift = 9 - length
            let span = 1 << shift
            for _ in 0..<count {
                let symbol = luminanceACValues[valueIndex]
                let entry = (UInt16(symbol) << 8) | UInt16(length)
                let base = code << shift
                for offset in 0..<span {
                    table[base + offset] = entry
                }
                code += 1
                valueIndex += 1
            }
            code <<= 1
        }
        return table
    }()

    /// JPEG-derived default quantization values for this encoding profile.
    private static let defaultLuma: [UInt8] = [
        16, 11, 11, 14, 24, 22, 24, 33,
        11, 12, 11, 11, 26, 18, 19, 23,
        13, 13, 14, 24, 20, 21, 22, 28,
        13, 17, 14, 21, 23, 25, 34, 34,
        17, 22, 18, 25, 31, 32, 34, 44,
        24, 20, 17, 27, 35, 40, 44, 54,
        30, 35, 28, 30, 34, 44, 54, 64,
        35, 30, 33, 38, 45, 55, 65, 75,
    ]
    private static let defaultChroma: [UInt8] = [
        19, 19, 24, 47, 76, 99, 99, 99,
        19, 21, 26, 66, 99, 99, 99, 99,
        24, 26, 56, 99, 99, 99, 99, 99,
        47, 66, 99, 99, 99, 99, 99, 99,
        76, 99, 99, 99, 99, 99, 99, 99,
        99, 99, 99, 99, 99, 99, 99, 99,
        99, 99, 99, 99, 99, 99, 99, 99,
        99, 99, 99, 99, 99, 99, 99, 99,
    ]
}
