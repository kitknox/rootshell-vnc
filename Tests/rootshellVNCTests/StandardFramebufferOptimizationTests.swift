import CoreGraphics
import CoreVideo
import Foundation
import IOSurface
import XCTest
@testable import RFBProtocol
@testable import RFBRendering
@testable import RFBTransport
@testable import rootshellVNC

final class StandardFramebufferOptimizationTests: XCTestCase {

    // MARK: - FramebufferSurfacePool

    func testSurfacePoolCopiesOnlyDirtyRectsAcrossSwaps() throws {
        let width = 128
        let height = 64
        let framebuffer = Framebuffer(width: width, height: height, pixelFormat: .bgra8888)
        let pool = FramebufferSurfacePool()

        // Initial fill of full framebuffer (blue).
        framebuffer.fillRect(x: 0, y: 0, width: width, height: height, pixel: Data([0xFF, 0x00, 0x00, 0xFF]))
        pool.markFullDirty(width: width, height: height)
        let first = try XCTUnwrap(pool.syncNextSurface(from: framebuffer, excluding: nil))
        XCTAssertEqual(pool.lastSyncedPixelCount, width * height)

        // Small 8x8 red update at (16, 8) -> allocates slot 2 (full sync on brand-new slot).
        framebuffer.fillRect(x: 16, y: 8, width: 8, height: 8, pixel: Data([0x00, 0x00, 0xFF, 0xFF]))
        pool.recordDirtyRects([CGRect(x: 16, y: 8, width: 8, height: 8)], width: width, height: height)
        let second = try XCTUnwrap(pool.syncNextSurface(from: framebuffer, excluding: first))
        XCTAssertTrue(second !== first)
        XCTAssertEqual(pixelBGRA(in: second, x: 16, y: 8), [0x00, 0x00, 0xFF, 0xFF])
        XCTAssertEqual(pixelBGRA(in: second, x: 0, y: 0), [0xFF, 0x00, 0x00, 0xFF])

        // Next small 8x8 green update at (40, 24) -> reuses slot 1 (excluding `second`).
        // Slot 1 only needs the two 8x8 dirty rects (128 pixels total), NOT 8192 pixels!
        framebuffer.fillRect(x: 40, y: 24, width: 8, height: 8, pixel: Data([0x00, 0xFF, 0x00, 0xFF]))
        pool.recordDirtyRects([CGRect(x: 40, y: 24, width: 8, height: 8)], width: width, height: height)
        let third = try XCTUnwrap(pool.syncNextSurface(from: framebuffer, excluding: second))
        XCTAssertTrue(third === first)
        XCTAssertEqual(pool.lastSyncedPixelCount, 128)
        XCTAssertEqual(pixelBGRA(in: third, x: 16, y: 8), [0x00, 0x00, 0xFF, 0xFF])
        XCTAssertEqual(pixelBGRA(in: third, x: 40, y: 24), [0x00, 0xFF, 0x00, 0xFF])
        XCTAssertEqual(pixelBGRA(in: third, x: 0, y: 0), [0xFF, 0x00, 0x00, 0xFF])
    }

    func testSurfacePoolForcesOpaqueAlphaForBGRXZeroPadding() throws {
        let framebuffer = Framebuffer(width: 4, height: 2, pixelFormat: .bgra8888)
        // Zero alpha padding byte (as sent by wayshare Raw/Zlib and DCT cmd-3 black).
        let row = Data([
            0x11, 0x22, 0x33, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0xAA, 0xBB, 0xCC, 0x00,
            0xFF, 0xFF, 0xFF, 0xFF,
        ])
        framebuffer.update(x: 0, y: 0, width: 4, height: 1, data: row)

        let pool = FramebufferSurfacePool()
        pool.markFullDirty(width: 4, height: 2)
        let surface = try XCTUnwrap(pool.syncNextSurface(from: framebuffer))

        XCTAssertEqual(pixelBGRA(in: surface, x: 0, y: 0), [0x11, 0x22, 0x33, 0xFF])
        XCTAssertEqual(pixelBGRA(in: surface, x: 1, y: 0), [0x00, 0x00, 0x00, 0xFF])
        XCTAssertEqual(pixelBGRA(in: surface, x: 2, y: 0), [0xAA, 0xBB, 0xCC, 0xFF])
        XCTAssertEqual(pixelBGRA(in: surface, x: 3, y: 0), [0xFF, 0xFF, 0xFF, 0xFF])
        // Framebuffer raw pixels remain untouched.
        XCTAssertEqual(framebuffer.getPixels(x: 0, y: 0, width: 4, height: 1), row)
    }

    func testSurfacePoolExpands16BitRGB555DirtyRectsToOpaqueBGRA() throws {
        let framebuffer = Framebuffer(width: 2, height: 1, pixelFormat: .rgb555)
        // Pure red (r=31, g=0, b=0 -> 0x7C00) and pure green (r=0, g=31, b=0 -> 0x03E0) LE.
        framebuffer.update(x: 0, y: 0, width: 2, height: 1, data: Data([0x00, 0x7C, 0xE0, 0x03]))

        let pool = FramebufferSurfacePool()
        pool.markFullDirty(width: 2, height: 1)
        let surface = try XCTUnwrap(pool.syncNextSurface(from: framebuffer))

        XCTAssertEqual(pixelBGRA(in: surface, x: 0, y: 0), [0x00, 0x00, 0xFF, 0xFF])
        XCTAssertEqual(pixelBGRA(in: surface, x: 1, y: 0), [0x00, 0xFF, 0x00, 0xFF])
    }

    func testSurfacePoolResetsOnFramebufferResize() throws {
        let framebuffer = Framebuffer(width: 16, height: 16, pixelFormat: .bgra8888)
        let pool = FramebufferSurfacePool()
        pool.markFullDirty(width: 16, height: 16)
        let before = try XCTUnwrap(pool.syncNextSurface(from: framebuffer))
        XCTAssertEqual(before.width, 16)

        framebuffer.resize(width: 32, height: 24)
        pool.markFullDirty(width: 32, height: 24)
        let after = try XCTUnwrap(pool.syncNextSurface(from: framebuffer))
        XCTAssertEqual(after.width, 32)
        XCTAssertEqual(after.height, 24)
    }

    // MARK: - AppleAdaptiveDCTDecoder Dirty Rects & Huffman LUT

    func testDCTType1SkipOnlyRefinementReportsNoDirtyRects() throws {
        let framebuffer = Framebuffer(width: 32, height: 16, pixelFormat: .bgra8888)
        let renderer = FramebufferRenderer(framebuffer: framebuffer, pixelFormat: .bgra8888)
        let rect = FramebufferRect(
            x: 0, y: 0, width: 32, height: 16, encoding: .appleMultiVariantScreenshare)

        // Type-1 with all 8 tiles using command 0 (skip) -> 16 zero bits (2 bytes).
        let skipOnly = Data([0, 0, 0, 5, 1, 0, 0, 0, 0])
        let result = renderer.applyBatch([(rect, skipOnly)], snapshot: false)
        XCTAssertTrue(result.issues.isEmpty)
        XCTAssertTrue(result.dirtyRects.isEmpty)
    }

    func testDCTType2QuantizationReportsNoDirtyRects() {
        let framebuffer = Framebuffer(width: 16, height: 16, pixelFormat: .bgra8888)
        let renderer = FramebufferRenderer(framebuffer: framebuffer, pixelFormat: .bgra8888)
        let rect = FramebufferRect(
            x: 0, y: 0, width: 0, height: 0, encoding: .appleMultiVariantScreenshare)
        let quant = Data([0, 0, 0, 129, 2]) + Data(repeating: 16, count: 128)
        let result = renderer.applyBatch([(rect, quant)], snapshot: false)
        XCTAssertTrue(result.issues.isEmpty)
        XCTAssertTrue(result.dirtyRects.isEmpty)
    }

    func testHuffman9BitLUTMatchesCanonicalTableForAll162Symbols() throws {
        var code = 0
        var valueIndex = 0
        try AppleAdaptiveDCTDecoder.luminanceACHuffmanLUT.withUnsafeBufferPointer { lut in
            for length in 1...16 {
                let count = AppleAdaptiveDCTDecoder.luminanceACCodeCounts[length - 1]
                for _ in 0..<count {
                    let expectedSymbol = AppleAdaptiveDCTDecoder.luminanceACValues[valueIndex]
                    // Pack `code` of `length` bits MSB-first into a 3-byte buffer.
                    let shifted = UInt32(code) << (24 - length)
                    let bytes = Data([
                        UInt8((shifted >> 16) & 0xff),
                        UInt8((shifted >> 8) & 0xff),
                        UInt8(shifted & 0xff),
                    ])
                    let decoded = try bytes.withUnsafeBytes { raw -> (UInt8, Int) in
                        var reader = AppleAdaptiveDCTDecoder.BitReader(raw)
                        let symbol = try reader.readLuminanceACHuffmanSymbol(lut: lut)
                        return (symbol, reader.bitOffset)
                    }
                    XCTAssertEqual(decoded.0, expectedSymbol, "length=\(length) code=\(code)")
                    XCTAssertEqual(decoded.1, length, "bitOffset length=\(length) code=\(code)")
                    code += 1
                    valueIndex += 1
                }
                code <<= 1
            }
        }
        XCTAssertEqual(valueIndex, 162)
    }

    // MARK: - StandardFramebufferLayerRenderer Presentation Gate

    @MainActor
    func testStandardLayerRendererRespectsPresentationProhibitionAndReconciles() throws {
        let originalGate = VNCPresentationPolicy.isPresentationProhibited
        defer { VNCPresentationPolicy.isPresentationProhibited = originalGate }

        var prohibited = true
        VNCPresentationPolicy.isPresentationProhibited = { prohibited }

        let framebuffer = Framebuffer(width: 16, height: 16, pixelFormat: .bgra8888)
        framebuffer.fillRect(x: 0, y: 0, width: 16, height: 16, pixel: Data([0x10, 0x20, 0x30, 0xFF]))
        let pool = FramebufferSurfacePool()
        pool.markFullDirty(width: 16, height: 16)
        let surface = try XCTUnwrap(pool.syncNextSurface(from: framebuffer))

        let renderer = StandardFramebufferLayerRenderer()
        renderer.present(surface, cropRegion: nil)
        XCTAssertEqual(renderer.frameCommitCount, 0)
        XCTAssertNil(renderer.latestPresentedSurface)

        prohibited = false
        renderer.presentPendingIfAny()
        XCTAssertEqual(renderer.frameCommitCount, 1)
        XCTAssertTrue(renderer.latestPresentedSurface === surface)
        XCTAssertNotNil(renderer.makeCurrentCGImage())
    }

    func testSurfacePoolReturnsNilWhenAllSlotsAreBusyInsteadOfOverwriting() throws {
        let framebuffer = Framebuffer(width: 32, height: 32, pixelFormat: .bgra8888)
        let pool = FramebufferSurfacePool(maximumSlotCount: 3)
        framebuffer.fillRect(x: 0, y: 0, width: 32, height: 32, pixel: Data([0x10, 0x20, 0x30, 0xFF]))
        pool.markFullDirty(width: 32, height: 32)

        let slot1 = try XCTUnwrap(pool.syncNextSurface(from: framebuffer, excluding: []))
        let slot2 = try XCTUnwrap(pool.syncNextSurface(from: framebuffer, excluding: [slot1]))
        let slot3 = try XCTUnwrap(pool.syncNextSurface(from: framebuffer, excluding: [slot1, slot2]))
        XCTAssertEqual(pool.allocatedSlotCount, 3)

        // With all 3 slots reserved (e.g., displayed + previous + pending),
        // the pool must refuse to overwrite any of them and return nil.
        framebuffer.fillRect(x: 0, y: 0, width: 8, height: 8, pixel: Data([0xFF, 0x00, 0x00, 0xFF]))
        pool.recordDirtyRects([CGRect(x: 0, y: 0, width: 8, height: 8)], width: 32, height: 32)
        XCTAssertNil(pool.syncNextSurface(from: framebuffer, excluding: [slot1, slot2, slot3]))
        XCTAssertEqual(pixelBGRA(in: slot1, x: 0, y: 0), [0x10, 0x20, 0x30, 0xFF])
        XCTAssertEqual(pixelBGRA(in: slot2, x: 0, y: 0), [0x10, 0x20, 0x30, 0xFF])
        XCTAssertEqual(pixelBGRA(in: slot3, x: 0, y: 0), [0x10, 0x20, 0x30, 0xFF])

        // Releasing slot1 lets the pool reuse it and apply the dirty rect.
        let reused = try XCTUnwrap(pool.syncNextSurface(from: framebuffer, excluding: [slot2, slot3]))
        XCTAssertTrue(reused === slot1)
        XCTAssertEqual(pixelBGRA(in: reused, x: 0, y: 0), [0xFF, 0x00, 0x00, 0xFF])
    }

    func testDCTOddFramebufferWidthSolidCopyAndTwoColorAlignmentSafe() throws {
        // Odd width (19 px -> 76 bytes/row) places odd rows at 4-byte (non-8-byte)
        // boundaries even for full 8-pixel tiles at x=0 and x=8, verifying solid,
        // copy, and two-color tile writes never violate pointer alignment.
        let framebuffer = Framebuffer(width: 19, height: 16, pixelFormat: .bgra8888)
        let decoder = AppleAdaptiveDCTDecoder()

        var cmdBits: [UInt8] = []
        func appendBits(_ value: UInt32, count: Int, to dst: inout [UInt8]) {
            for shift in stride(from: count - 1, through: 0, by: -1) {
                dst.append(UInt8((value >> shift) & 1))
            }
        }
        func packBits(_ bits: [UInt8]) -> Data {
            var bytes = [UInt8](repeating: 0, count: max(1, (bits.count + 7) / 8))
            for (index, bit) in bits.enumerated() where bit != 0 {
                bytes[index / 8] |= UInt8(0x80 >> (index % 8))
            }
            return Data(bytes)
        }

        // Leading reserved bit before the 3-bit command stream.
        appendBits(0, count: 1, to: &cmdBits)
        // 3x2 tile grid (19x16 -> tiles (0,0)..(2,1)):
        // (0,0): cmd 0 (solid white, full 8px wide)
        appendBits(0, count: 3, to: &cmdBits); appendBits(0, count: 1, to: &cmdBits)
        // (1,0): cmd 3 (two-color black/white, full 8px wide, rowControl=0xFE: 7 uniform rows + 1 patterned row)
        appendBits(3, count: 3, to: &cmdBits); appendBits(0, count: 1, to: &cmdBits)
        // (2,0): cmd 0 (solid white, clipped 3px wide)
        appendBits(0, count: 3, to: &cmdBits); appendBits(0, count: 1, to: &cmdBits)
        // (0,1): cmd 2 (copy tile above (0,0), full 8px wide)
        appendBits(2, count: 3, to: &cmdBits); appendBits(0, count: 1, to: &cmdBits)
        // (1,1): cmd 1 (copy previous tile (0,1), full 8px wide)
        appendBits(1, count: 3, to: &cmdBits); appendBits(0, count: 1, to: &cmdBits)
        // (2,1): cmd 0 (solid white, clipped 3px wide)
        appendBits(0, count: 3, to: &cmdBits); appendBits(0, count: 1, to: &cmdBits)

        var dataBits: [UInt8] = []
        // Data for tile (1,0) cmd 3: rowControl=0xFE (rows 0..6 uniform first=0xFFFFFFFF, row 7 mask=0x00 -> second=0x00000000)
        appendBits(0xFE, count: 8, to: &dataBits)
        appendBits(0x00, count: 8, to: &dataBits)

        let cmdData = packBits(cmdBits)
        let dataStream = packBits(dataBits)
        let dataOffset = 6 + cmdData.count
        var body = Data()
        body.append(contentsOf: [
            0x00, // type 0
            0x00, // field1
            0x00, // field2
            UInt8((dataOffset >> 16) & 0xFF),
            UInt8((dataOffset >> 8) & 0xFF),
            UInt8(dataOffset & 0xFF),
        ])
        body.append(cmdData)
        body.append(dataStream)

        var framed = Data()
        var lengthBE = UInt32(body.count).bigEndian
        withUnsafeBytes(of: &lengthBE) { framed.append(contentsOf: $0) }
        framed.append(body)

        let rect = FramebufferRect(
            x: 0, y: 0, width: 19, height: 16,
            encoding: .appleMultiVariantScreenshare)
        let dirty = try decoder.render(rect: rect, payload: framed, to: framebuffer)
        XCTAssertEqual(dirty, CGRect(x: 0, y: 0, width: 19, height: 16))
        // Row 1 (byte offset 76, non-8-byte aligned) in tile (0,0) solid white:
        XCTAssertEqual(Array(framebuffer.getPixels(x: 0, y: 1, width: 1, height: 1)), [0xFF, 0xFF, 0xFF, 0xFF])
        // Row 7 (odd row) in tile (1,0) two-color black row:
        XCTAssertEqual(Array(framebuffer.getPixels(x: 8, y: 7, width: 1, height: 1)), [0x00, 0x00, 0x00, 0x00])
        // Row 9 (odd row) in tile (1,1) copied from (0,1) copied from (0,0) solid white:
        XCTAssertEqual(Array(framebuffer.getPixels(x: 8, y: 9, width: 1, height: 1)), [0xFF, 0xFF, 0xFF, 0xFF])
    }

    func testFramebufferRendererApplyRectAndApplyCopyRectUpdatePresentationSurface() throws {
        let framebuffer = Framebuffer(width: 16, height: 16, pixelFormat: .bgra8888)
        let renderer = FramebufferRenderer(framebuffer: framebuffer, pixelFormat: .bgra8888)

        // Initial sync so a surface slot exists and is clean.
        let first = try XCTUnwrap(renderer.syncPresentationSurface())

        // Public applyRect (raw 4x4 green at (0,0)).
        var greenPixels = Data(capacity: 4 * 4 * 4)
        for _ in 0..<16 {
            greenPixels.append(contentsOf: [0x00, 0xEE, 0x00, 0x00])
        }
        try renderer.applyRect(
            rect: FramebufferRect(x: 0, y: 0, width: 4, height: 4, encoding: .raw),
            data: greenPixels)
        let afterRaw = try XCTUnwrap(renderer.syncPresentationSurface(excluding: first))
        XCTAssertEqual(pixelBGRA(in: afterRaw, x: 1, y: 1), [0x00, 0xEE, 0x00, 0xFF])

        // Public applyCopyRect copies (0,0 4x4) -> (8,8).
        renderer.applyCopyRect(
            rect: FramebufferRect(x: 8, y: 8, width: 4, height: 4, encoding: .copyRect),
            srcX: 0, srcY: 0)
        let afterCopy = try XCTUnwrap(renderer.syncPresentationSurface(excluding: afterRaw))
        XCTAssertEqual(pixelBGRA(in: afterCopy, x: 9, y: 9), [0x00, 0xEE, 0x00, 0xFF])
    }

    @MainActor
    func testStandardLayerRendererDefersBrightnessGainWhilePresentationProhibited() throws {
        let originalGate = VNCPresentationPolicy.isPresentationProhibited
        defer { VNCPresentationPolicy.isPresentationProhibited = originalGate }

        var prohibited = false
        VNCPresentationPolicy.isPresentationProhibited = { prohibited }

        let framebuffer = Framebuffer(width: 16, height: 16, pixelFormat: .bgra8888)
        framebuffer.fillRect(x: 0, y: 0, width: 16, height: 16, pixel: Data([0x40, 0x50, 0x60, 0xFF]))
        let pool = FramebufferSurfacePool()
        pool.markFullDirty(width: 16, height: 16)
        let surface = try XCTUnwrap(pool.syncNextSurface(from: framebuffer))

        let renderer = StandardFramebufferLayerRenderer()
        renderer.present(surface, cropRegion: nil)
        XCTAssertNil(renderer.containerLayer.contents)

        // Lock device, then request EDR brightness boost — must not commit
        // boosted layer contents while prohibited.
        prohibited = true
        renderer.setBrightnessGain(2.0)
        XCTAssertNil(renderer.containerLayer.contents)

        // Unlock and reconcile — deferred gain now applies cleanly.
        prohibited = false
        renderer.presentPendingIfAny()
        XCTAssertNotNil(renderer.makeCurrentCGImage())
    }

    @MainActor
    func testVNCSessionExplicitCurrentImageSetterUpdatesLayerRenderer() throws {
        let session = VNCSession()
        let framebuffer = Framebuffer(width: 8, height: 8, pixelFormat: .bgra8888)
        framebuffer.fillRect(x: 0, y: 0, width: 8, height: 8, pixel: Data([0x12, 0x34, 0x56, 0xFF]))
        let overrideImage = try XCTUnwrap(framebuffer.createImage())

        session.currentImage = overrideImage
        XCTAssertTrue(session.hasPresentedStandardPicture)
        XCTAssertTrue(session.currentImage === overrideImage)
        XCTAssertTrue(session.standardFramebufferRenderer.makeCurrentCGImage() === overrideImage)

        session.currentImage = nil
        XCTAssertFalse(session.hasPresentedStandardPicture)
        XCTAssertNil(session.currentImage)
        XCTAssertNil(session.standardFramebufferRenderer.makeCurrentCGImage())
    }

    func testStandardPipelineInvalidationReleasesResourcesAndRoutesResizesOutOfDirectPath() {
        let queue = DispatchQueue(label: "test.standard.pipeline.invalidation")
        let pipeline = StandardFramebufferPipeline(
            queue: queue,
            onSurfaceReady: {},
            onSideEffects: { _ in })

        weak var weakRenderer: FramebufferRenderer?
        weak var weakTransport: TransportSession?

        autoreleasepool {
            let framebuffer = Framebuffer(width: 16, height: 16, pixelFormat: .bgra8888)
            let renderer = FramebufferRenderer(framebuffer: framebuffer, pixelFormat: .bgra8888)
            let transport = TransportSession(host: "127.0.0.1", port: 5900, password: "pw")
            weakRenderer = renderer
            weakTransport = transport

            pipeline.configure(
                generation: 1,
                renderer: renderer,
                transport: transport,
                width: 16,
                height: 16,
                displayRegions: [],
                targetFrameRate: 60,
                directSinkArmed: true)

            // DesktopSize must bypass direct enqueue so rapid resizes remain
            // strictly ordered through the AsyncStream path.
            let resizeRect = FramebufferRect(
                x: 0, y: 0, width: 32, height: 32, encoding: .desktopSize)
            XCTAssertFalse(pipeline.enqueueDirect([(resizeRect, Data())], from: transport))

            pipeline.invalidate(newGeneration: 2)
        }

        queue.sync {}
        XCTAssertNil(weakRenderer)
        XCTAssertNil(weakTransport)
    }

    @MainActor
    func testVNCSessionConfigurationChangeUpdatesLivePipelineSettings() {
        let session = VNCSession(configuration: VNCConfiguration(
            targetFrameRate: 60,
            enableProtocolTrace: false))
        XCTAssertEqual(session.configuration.targetFrameRate, 60)
        XCTAssertFalse(session.configuration.enableProtocolTrace)

        session.configuration.targetFrameRate = 15
        session.configuration.enableProtocolTrace = true
        XCTAssertEqual(session.configuration.targetFrameRate, 15)
        XCTAssertTrue(session.configuration.enableProtocolTrace)
    }

    // MARK: - Offline Presentation Benchmark (Dirty-Rect Surface Sync vs CGContext.makeImage)

    func testOfflinePresentationSyncVsCGImageBenchmark() throws {
        guard ProcessInfo.processInfo.environment["VNC_DCT_BENCHMARK"] == "1" else {
            throw XCTSkip("Set VNC_DCT_BENCHMARK=1 for offline presentation benchmarks")
        }
        let width = 2976
        let height = 1860
        let framebuffer = Framebuffer(width: width, height: height, pixelFormat: .bgra8888)
        let pool = FramebufferSurfacePool()
        framebuffer.fillRect(x: 0, y: 0, width: width, height: height, pixel: Data([0x20, 0x40, 0x60, 0xFF]))
        pool.markFullDirty(width: width, height: height)
        var displayed = try XCTUnwrap(pool.syncNextSurface(from: framebuffer))
        // Warm second slot too.
        pool.recordDirtyRects([CGRect(x: 0, y: 0, width: 64, height: 64)], width: width, height: height)
        displayed = try XCTUnwrap(pool.syncNextSurface(from: framebuffer, excluding: displayed))

        let scenarios: [(String, CGRect)] = [
            ("typing_64x64", CGRect(x: 400, y: 400, width: 64, height: 64)),
            ("scroll_600x400", CGRect(x: 200, y: 200, width: 600, height: 400)),
            ("full_2976x1860", CGRect(x: 0, y: 0, width: width, height: height)),
        ]

        for (name, rect) in scenarios {
            var cgTimes: [Double] = []
            var poolTimes: [Double] = []
            var retainedCGImage: CGImage?
            for iteration in 0..<6 {
                let colorByte = UInt8((iteration * 37 + 0x20) & 0xFF)
                let startCG = DispatchTime.now().uptimeNanoseconds
                framebuffer.fillRect(
                    x: Int(rect.minX), y: Int(rect.minY),
                    width: 8, height: 8,
                    pixel: Data([colorByte, 0x40, 0x60, 0xFF]))
                let image = framebuffer.createImage()
                // Force the pixel backing read that SwiftUI / CoreAnimation performs on a new CGImage.
                let byteCount = (image?.dataProvider?.data as Data?)?.count ?? 0
                retainedCGImage = image
                let cgMs = Double(DispatchTime.now().uptimeNanoseconds &- startCG) / 1e6
                XCTAssertGreaterThan(byteCount, 0)

                pool.recordDirtyRects([rect], width: width, height: height)
                let startPool = DispatchTime.now().uptimeNanoseconds
                if let next = pool.syncNextSurface(from: framebuffer, excluding: displayed) {
                    displayed = next
                }
                let poolMs = Double(DispatchTime.now().uptimeNanoseconds &- startPool) / 1e6

                if iteration > 0 {
                    cgTimes.append(cgMs)
                    poolTimes.append(poolMs)
                }
            }
            _ = retainedCGImage
            let cgMedian = cgTimes.sorted()[cgTimes.count / 2]
            let poolMedian = poolTimes.sorted()[poolTimes.count / 2]
            print(String(
                format: "PRESENT BENCH %@ cgImage_median_ms=%.3f dirtySurface_median_ms=%.3f speedup=%.1fx",
                name, cgMedian, poolMedian, poolMedian > 0 ? cgMedian / poolMedian : 0))
        }
    }

    func testSurfacePoolRespectsRetainedPixelBufferReaderViaIOSurfaceIsInUse() throws {
        let framebuffer = Framebuffer(width: 32, height: 32, pixelFormat: .bgra8888)
        let pool = FramebufferSurfacePool(maximumSlotCount: 2)
        framebuffer.fillRect(x: 0, y: 0, width: 32, height: 32, pixel: Data([0x11, 0x22, 0x33, 0xFF]))
        pool.markFullDirty(width: 32, height: 32)

        let slot1 = try XCTUnwrap(pool.syncNextSurface(from: framebuffer))
        guard slot1.ioSurface != nil else {
            // In restricted sandboxes where IOSurfaceCreate is denied, fallback
            // surfaces refuse zero-copy pixelBuffer pinning so callers take an
            // immutable CGImage instead.
            XCTAssertNil(slot1.makeRetainedPixelBufferForReading())
            return
        }

        XCTAssertFalse(slot1.isInUse)
        let slot2 = try XCTUnwrap(pool.syncNextSurface(from: framebuffer, excluding: [slot1]))
        XCTAssertTrue(slot2 !== slot1)

        // Simulate a detached Vision OCR task retaining a CVPixelBuffer view
        // over slot1 across swaps while slot2 is displayed.
        var ocrReader: CVPixelBuffer? = slot1.makeRetainedPixelBufferForReading()
        XCTAssertNotNil(ocrReader)
        XCTAssertTrue(slot1.isInUse)

        framebuffer.fillRect(x: 0, y: 0, width: 8, height: 8, pixel: Data([0xEE, 0xDD, 0xCC, 0xFF]))
        pool.recordDirtyRects([CGRect(x: 0, y: 0, width: 8, height: 8)], width: 32, height: 32)
        // Even though slot1 is NOT in `excluding`, IOSurfaceIsInUse must keep
        // the pool from overwriting it while OCR holds `ocrReader`.
        XCTAssertNil(pool.syncNextSurface(from: framebuffer, excluding: [slot2]))
        XCTAssertEqual(pixelBGRA(in: slot1, x: 0, y: 0), [0x11, 0x22, 0x33, 0xFF])

        // Releasing the OCR reader drops IOSurfaceIsInUse back to false and
        // allows slot1 to be recycled cleanly.
        ocrReader = nil
        XCTAssertFalse(slot1.isInUse)
        let recycled = try XCTUnwrap(pool.syncNextSurface(from: framebuffer, excluding: [slot2]))
        XCTAssertTrue(recycled === slot1)
        XCTAssertEqual(pixelBGRA(in: recycled, x: 0, y: 0), [0xEE, 0xDD, 0xCC, 0xFF])
    }

    @MainActor
    func testStandardLayerRendererDefersPixelScaleAndBoundsWhilePresentationProhibited() throws {
        let originalGate = VNCPresentationPolicy.isPresentationProhibited
        defer { VNCPresentationPolicy.isPresentationProhibited = originalGate }

        var prohibited = false
        VNCPresentationPolicy.isPresentationProhibited = { prohibited }

        let framebuffer = Framebuffer(width: 100, height: 100, pixelFormat: .bgra8888)
        framebuffer.fillRect(x: 0, y: 0, width: 100, height: 100, pixel: Data([0x30, 0x40, 0x50, 0xFF]))
        let pool = FramebufferSurfacePool()
        pool.markFullDirty(width: 100, height: 100)
        let surface = try XCTUnwrap(pool.syncNextSurface(from: framebuffer))

        let renderer = StandardFramebufferLayerRenderer()
        renderer.setPixelScale(2)
        renderer.setViewBounds(CGRect(x: 0, y: 0, width: 200, height: 200))
        renderer.present(surface, cropRegion: nil)
        XCTAssertEqual(renderer.containerLayer.contentsScale, 2)
        XCTAssertEqual(renderer.containerLayer.frame, CGRect(x: 0, y: 0, width: 200, height: 200))

        // Arm the presentation prohibition gate; scale and bounds changes must
        // not mutate the layer while locked.
        prohibited = true
        renderer.setPixelScale(3)
        renderer.setViewBounds(CGRect(x: 0, y: 0, width: 400, height: 400))
        XCTAssertEqual(renderer.containerLayer.contentsScale, 2)
        XCTAssertEqual(renderer.containerLayer.frame, CGRect(x: 0, y: 0, width: 200, height: 200))

        // Clearing the gate and reconciling applies the deferred scale & bounds.
        prohibited = false
        renderer.presentPendingIfAny()
        XCTAssertEqual(renderer.containerLayer.contentsScale, 3)
        XCTAssertEqual(renderer.containerLayer.frame, CGRect(x: 0, y: 0, width: 400, height: 400))
    }

    #if canImport(UIKit) || canImport(AppKit)
    @MainActor
    func testStandardFramebufferHostViewRebindsLayerOnRendererSwitchAndRespectsGate() throws {
        let originalGate = VNCPresentationPolicy.isPresentationProhibited
        defer { VNCPresentationPolicy.isPresentationProhibited = originalGate }

        var prohibited = false
        VNCPresentationPolicy.isPresentationProhibited = { prohibited }

        let fb1 = Framebuffer(width: 16, height: 16, pixelFormat: .bgra8888)
        fb1.fillRect(x: 0, y: 0, width: 16, height: 16, pixel: Data([0x10, 0x20, 0x30, 0xFF]))
        let pool1 = FramebufferSurfacePool()
        pool1.markFullDirty(width: 16, height: 16)
        let surface1 = try XCTUnwrap(pool1.syncNextSurface(from: fb1))

        let fb2 = Framebuffer(width: 16, height: 16, pixelFormat: .bgra8888)
        fb2.fillRect(x: 0, y: 0, width: 16, height: 16, pixel: Data([0xAA, 0xBB, 0xCC, 0xFF]))
        let pool2 = FramebufferSurfacePool()
        pool2.markFullDirty(width: 16, height: 16)
        let surface2 = try XCTUnwrap(pool2.syncNextSurface(from: fb2))

        let first = StandardFramebufferLayerRenderer()
        first.present(surface1, cropRegion: nil)
        let second = StandardFramebufferLayerRenderer()
        second.present(surface2, cropRegion: nil)

        let host = StandardFramebufferHostView(renderer: first)
        XCTAssertTrue(host.presentationTarget.containerLayer.superlayer === host.layer)
        let contentsBeforeSwitch = host.presentationTarget.presentedLayerContents as AnyObject?
        XCTAssertNotNil(contentsBeforeSwitch)

        // Switching renderers while the lock-screen gate is active must NOT
        // push the replacement renderer's frame into the live layer tree.
        prohibited = true
        host.bind(renderer: second)
        XCTAssertTrue(host.renderer === second)
        let contentsWhileProhibited = host.presentationTarget.presentedLayerContents as AnyObject?
        XCTAssertTrue(contentsWhileProhibited === contentsBeforeSwitch)

        // Once the gate clears and presentation reconciles, the new renderer's
        // frame commits into the host's own layer.
        prohibited = false
        second.presentPendingIfAny()
        let contentsAfterResume = host.presentationTarget.presentedLayerContents as AnyObject?
        XCTAssertNotNil(contentsAfterResume)
        XCTAssertFalse(contentsAfterResume === contentsBeforeSwitch)
    }

    @MainActor
    func testTwoHostViewsShareSessionSurfaceWithoutStealingEachOthersLayer() throws {
        let framebuffer = Framebuffer(width: 16, height: 16, pixelFormat: .bgra8888)
        framebuffer.fillRect(x: 0, y: 0, width: 16, height: 16, pixel: Data([0x40, 0x50, 0x60, 0xFF]))
        let pool = FramebufferSurfacePool()
        pool.markFullDirty(width: 16, height: 16)
        let surface = try XCTUnwrap(pool.syncNextSurface(from: framebuffer))

        let renderer = StandardFramebufferLayerRenderer()
        renderer.present(surface, cropRegion: nil)

        let host1 = StandardFramebufferHostView(renderer: renderer)
        XCTAssertTrue(host1.presentationTarget.containerLayer.superlayer === host1.layer)
        XCTAssertNotNil(host1.presentationTarget.presentedLayerContents)

        do {
            let host2 = StandardFramebufferHostView(renderer: renderer)
            XCTAssertTrue(host1.presentationTarget.containerLayer.superlayer === host1.layer)
            XCTAssertTrue(host2.presentationTarget.containerLayer.superlayer === host2.layer)
            XCTAssertFalse(host1.presentationTarget.containerLayer === host2.presentationTarget.containerLayer)
            XCTAssertNotNil(host2.presentationTarget.presentedLayerContents)
        }

        // After host2 closes, host1 still owns its layer and receives updates.
        XCTAssertTrue(host1.presentationTarget.containerLayer.superlayer === host1.layer)
        framebuffer.fillRect(x: 0, y: 0, width: 16, height: 16, pixel: Data([0x90, 0xA0, 0xB0, 0xFF]))
        pool.recordDirtyRects([CGRect(x: 0, y: 0, width: 16, height: 16)], width: 16, height: 16)
        let surface2 = try XCTUnwrap(pool.syncNextSurface(from: framebuffer, excluding: [surface]))
        renderer.present(surface2, cropRegion: nil)
        XCTAssertNotNil(host1.presentationTarget.presentedLayerContents)
    }
    #endif

    func testSurfacePoolSyncResultDistinguishesBusyFromResourceFailure() throws {
        let framebuffer = Framebuffer(width: 16, height: 16, pixelFormat: .bgra8888)
        let pool = FramebufferSurfacePool(maximumSlotCount: 2)
        framebuffer.fillRect(x: 0, y: 0, width: 16, height: 16, pixel: Data([0x10, 0x20, 0x30, 0xFF]))
        pool.markFullDirty(width: 16, height: 16)

        let slot1 = try XCTUnwrap(pool.syncNextSurface(from: framebuffer))
        let slot2 = try XCTUnwrap(pool.syncNextSurface(from: framebuffer, excluding: [slot1]))

        // Reserved exclusively by our own handoff -> externallyInUse == false.
        let busyResult = pool.syncNextSurfaceResult(from: framebuffer, excluding: [slot1, slot2])
        if case .allSlotsBusy(let externallyInUse) = busyResult {
            XCTAssertFalse(externallyInUse)
        } else {
            XCTFail("Expected .allSlotsBusy(externallyInUse: false), got \(busyResult)")
        }

        // Pin slot1 via IOSurfaceIsInUse -> externallyInUse == true when ioSurface is present.
        if let ocrReader = slot1.makeRetainedPixelBufferForReading() {
            let externalBusy = pool.syncNextSurfaceResult(from: framebuffer, excluding: [slot2])
            if case .allSlotsBusy(let externallyInUse) = externalBusy {
                XCTAssertTrue(externallyInUse)
            } else {
                XCTFail("Expected .allSlotsBusy(externallyInUse: true), got \(externalBusy)")
            }
            _ = ocrReader
        }
    }

    func testDirectAndAsyncStreamPathsShareSingleCoalescedHandoffWithoutOutOfOrderOverwrite() async throws {
        let queue = DispatchQueue(label: "test.standard.pipeline.ordering")
        let pipeline = StandardFramebufferPipeline(
            queue: queue,
            onSurfaceReady: {},
            onSideEffects: { _ in })
        let framebuffer = Framebuffer(width: 16, height: 16, pixelFormat: .bgra8888)
        let renderer = FramebufferRenderer(framebuffer: framebuffer, pixelFormat: .bgra8888)
        let transport = TransportSession(host: "127.0.0.1", port: 5900, password: "pw")

        pipeline.configure(
            generation: 1,
            renderer: renderer,
            transport: transport,
            width: 16,
            height: 16,
            displayRegions: [],
            targetFrameRate: 1_000,
            directSinkArmed: true)

        func rawSolidRect(b: UInt8, g: UInt8, r: UInt8) -> (FramebufferRect, Data) {
            var bytes = Data(capacity: 16 * 16 * 4)
            for _ in 0..<(16 * 16) {
                bytes.append(contentsOf: [b, g, r, 0xFF])
            }
            return (FramebufferRect(x: 0, y: 0, width: 16, height: 16, encoding: .raw), bytes)
        }

        // Direct frame 1 (red) runs on queue and stages in pendingSurface
        // without MainActor having drained it yet.
        XCTAssertTrue(pipeline.enqueueDirect([rawSolidRect(b: 0x00, g: 0x00, r: 0xFF)], from: transport))
        // Ensure publishInterval (1ms at 1000fps) elapses so frame 2 also syncs.
        try await Task.sleep(for: .milliseconds(5))

        // AsyncStream frame 2 (green) runs on queue and replaces pendingSurface
        // in the same coalescing slot.
        let outcome = await pipeline.processAsyncStreamBatch(
            [rawSolidRect(b: 0x00, g: 0xFF, r: 0x00)],
            generation: 1,
            renderer: renderer,
            transport: transport,
            displaySuspended: false)
        XCTAssertTrue(outcome.hasPendingSurface)

        // First drain must yield ONLY the newer green frame; a late second
        // drain from the earlier direct-path wakeup must see nil.
        let drained = try XCTUnwrap(pipeline.drainPendingSurface())
        XCTAssertEqual(pixelBGRA(in: drained.surface, x: 0, y: 0), [0x00, 0xFF, 0x00, 0xFF])
        XCTAssertNil(pipeline.drainPendingSurface())
        pipeline.finishSurfaceDelivery(displayed: drained.surface, previous: nil)
        pipeline.invalidate(newGeneration: 2)
    }

    func testAsyncStreamTrailingDelayReflectsRemainingCadenceWindow() async throws {
        let queue = DispatchQueue(label: "test.standard.pipeline.cadence")
        let pipeline = StandardFramebufferPipeline(
            queue: queue,
            onSurfaceReady: {},
            onSideEffects: { _ in })
        let framebuffer = Framebuffer(width: 8, height: 8, pixelFormat: .bgra8888)
        let renderer = FramebufferRenderer(framebuffer: framebuffer, pixelFormat: .bgra8888)
        let transport = TransportSession(host: "127.0.0.1", port: 5900, password: "pw")

        pipeline.configure(
            generation: 1,
            renderer: renderer,
            transport: transport,
            width: 8,
            height: 8,
            displayRegions: [],
            targetFrameRate: 10, // 100 ms interval
            directSinkArmed: false)

        let rawRect = (
            FramebufferRect(x: 0, y: 0, width: 8, height: 8, encoding: .raw),
            Data(repeating: 0xFF, count: 8 * 8 * 4))

        let first = await pipeline.processAsyncStreamBatch(
            [rawRect], generation: 1, renderer: renderer, transport: transport, displaySuspended: false)
        XCTAssertTrue(first.hasPendingSurface)
        if let pending = pipeline.drainPendingSurface() {
            pipeline.finishSurfaceDelivery(displayed: pending.surface, previous: nil)
        }

        // Wait 60 ms into the 100 ms window; remaining trailing delay must be
        // ~40 ms, well below a full 100 ms interval.
        try await Task.sleep(for: .milliseconds(60))
        let second = await pipeline.processAsyncStreamBatch(
            [rawRect], generation: 1, renderer: renderer, transport: transport, displaySuspended: false)
        XCTAssertFalse(second.hasPendingSurface)
        XCTAssertTrue(second.shouldScheduleTrailing)
        XCTAssertLessThan(second.trailingDelayNanoseconds, 80_000_000)
        pipeline.invalidate(newGeneration: 2)
    }

    func testExternalReaderReleaseWakesDeferredSurfaceSync() async throws {
        let framebuffer = Framebuffer(width: 8, height: 8, pixelFormat: .bgra8888)
        let renderer = FramebufferRenderer(framebuffer: framebuffer, pixelFormat: .bgra8888)
        let transport = TransportSession(host: "127.0.0.1", port: 5900, password: "pw")

        // Pin all 4 pool slots via retained CVPixelBuffer readers (or skip on
        // sandboxed CPU fallback where IOSurfaceCreate is unavailable).
        var pinnedReaders: [CVPixelBuffer] = []
        for _ in 0..<4 {
            framebuffer.fillRect(x: 0, y: 0, width: 8, height: 8, pixel: Data([0x10, 0x20, 0x30, 0xFF]))
            let s = try XCTUnwrap(renderer.syncPresentationSurface())
            guard let pb = s.makeRetainedPixelBufferForReading() else {
                return
            }
            pinnedReaders.append(pb)
        }

        let queue = DispatchQueue(label: "test.standard.pipeline.wakeup")
        let readyExp = expectation(description: "pipeline wakes when external reader releases")
        readyExp.assertForOverFulfill = false
        let pipeline = StandardFramebufferPipeline(
            queue: queue,
            onSurfaceReady: {
                readyExp.fulfill()
            },
            onSideEffects: { _ in })

        pipeline.configure(
            generation: 1,
            renderer: renderer,
            transport: transport,
            width: 8,
            height: 8,
            displayRegions: [],
            targetFrameRate: 1, // 1s retry window so advancing the timer is measurable
            directSinkArmed: false)

        let rawRect = (
            FramebufferRect(x: 0, y: 0, width: 8, height: 8, encoding: .raw),
            Data(repeating: 0xAA, count: 8 * 8 * 4))
        let outcome = await pipeline.processAsyncStreamBatch(
            [rawRect], generation: 1, renderer: renderer, transport: transport, displaySuspended: false)
        XCTAssertFalse(outcome.hasPendingSurface)
        XCTAssertTrue(outcome.shouldScheduleTrailing)

        // Schedule the delayed trailing retry (mirroring VNCSession's production
        // sequence) and make sure it is armed on `queue` before releasing.
        pipeline.scheduleReconciliation(
            delayNanoseconds: outcome.trailingDelayNanoseconds,
            generation: 1,
            renderer: renderer,
            transport: transport)
        queue.sync {}

        // Release one external reader and notify pipeline -> must advance the
        // 1s scheduled timer and wake immediately (< 350 ms).
        let started = DispatchTime.now().uptimeNanoseconds
        pinnedReaders.removeLast()
        pipeline.notifyExternalReaderReleased()
        await fulfillment(of: [readyExp], timeout: 0.35)
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds &- started) / 1e6
        XCTAssertLessThan(elapsedMs, 350, "Expected immediate wakeup instead of waiting for 1s timer")
        XCTAssertNotNil(pipeline.drainPendingSurface())
        pipeline.invalidate(newGeneration: 2)
    }

    func testSurfacePoolRecordDirtyRectsClipsInfiniteRectWithoutCrashing() throws {
        let framebuffer = Framebuffer(width: 16, height: 16, pixelFormat: .bgra8888)
        let pool = FramebufferSurfacePool()
        framebuffer.fillRect(x: 0, y: 0, width: 16, height: 16, pixel: Data([0x01, 0x02, 0x03, 0xFF]))
        pool.markFullDirty(width: 16, height: 16)
        let first = try XCTUnwrap(pool.syncNextSurface(from: framebuffer))

        // Passing CGRect.infinite after a slot exists must clip safely to bounds
        // rather than trapping on Int(CGRect.infinite.minX).
        framebuffer.fillRect(x: 0, y: 0, width: 16, height: 16, pixel: Data([0x44, 0x55, 0x66, 0xFF]))
        pool.recordDirtyRects([.infinite], width: 16, height: 16)
        let second = try XCTUnwrap(pool.syncNextSurface(from: framebuffer, excluding: [first]))
        XCTAssertEqual(pixelBGRA(in: second, x: 0, y: 0), [0x44, 0x55, 0x66, 0xFF])
        XCTAssertEqual(pixelBGRA(in: second, x: 15, y: 15), [0x44, 0x55, 0x66, 0xFF])
    }

    func testSurfacePoolMakeCGImageRejectsNonBGRAPixelBufferSafely() throws {
        var oneChannel: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            32,
            16,
            kCVPixelFormatType_OneComponent8,
            nil,
            &oneChannel)
        XCTAssertEqual(status, kCVReturnSuccess)
        let buffer = try XCTUnwrap(oneChannel)
        XCTAssertNil(FramebufferSurfacePool.makeCGImage(from: buffer))
    }

    func testSurfacePoolConcurrentRecordSyncAndResetIsThreadSafe() {
        let framebuffer = Framebuffer(width: 64, height: 64, pixelFormat: .bgra8888)
        let pool = FramebufferSurfacePool(maximumSlotCount: 3)
        framebuffer.fillRect(x: 0, y: 0, width: 64, height: 64, pixel: Data([0x22, 0x33, 0x44, 0xFF]))

        let group = DispatchGroup()
        let q1 = DispatchQueue(label: "test.pool.writer", attributes: .concurrent)
        let q2 = DispatchQueue(label: "test.pool.syncer", attributes: .concurrent)
        for i in 0..<25 {
            group.enter()
            q1.async {
                pool.recordDirtyRects([CGRect(x: (i * 4) % 48, y: 0, width: 8, height: 8)], width: 64, height: 64)
                if i % 10 == 9 {
                    pool.reset()
                }
                group.leave()
            }
            group.enter()
            q2.async {
                _ = pool.syncNextSurface(from: framebuffer)
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
    }

    private func pixelBGRA(in surface: FramebufferPresentationSurface, x: Int, y: Int) -> [UInt8] {
        if let ioSurface = surface.ioSurface {
            IOSurfaceLock(ioSurface, .readOnly, nil)
            defer { IOSurfaceUnlock(ioSurface, .readOnly, nil) }
            let stride = IOSurfaceGetBytesPerRow(ioSurface)
            let ptr = IOSurfaceGetBaseAddress(ioSurface)
                .assumingMemoryBound(to: UInt8.self)
                .advanced(by: y * stride + x * 4)
            return [ptr[0], ptr[1], ptr[2], ptr[3]]
        }
        guard let buffer = surface.fallbackPixelBuffer else { return [] }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return [] }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let ptr = base.assumingMemoryBound(to: UInt8.self).advanced(by: y * stride + x * 4)
        return [ptr[0], ptr[1], ptr[2], ptr[3]]
    }
}
