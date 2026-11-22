import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import XCTest
@testable import RFBProtocol
@testable import RFBRendering
@testable import RFBTransport
@testable import rootshellVNC

final class HighPerformanceOptimizationTests: XCTestCase {

    // MARK: - Helpers

    private func makeIOSurfaceBGRA(
        width: Int,
        height: Int,
        fill: (_ x: Int, _ y: Int) -> (b: UInt8, g: UInt8, r: UInt8, a: UInt8)
    ) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &buffer)
        guard status == kCVReturnSuccess, let pb = buffer else {
            throw XCTSkip("IOSurface CVPixelBuffer unavailable in this environment (status=\(status))")
        }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pb)).assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(pb)
        for y in 0..<height {
            for x in 0..<width {
                let c = fill(x, y)
                let p = base + y * stride + x * 4
                p[0] = c.b
                p[1] = c.g
                p[2] = c.r
                p[3] = c.a
            }
        }
        return pb
    }

    private func makeBiPlanarYCbCr(
        width: Int,
        height: Int,
        format: OSType,
        ycbcrMatrix: CFString = kCVImageBufferYCbCrMatrix_ITU_R_709_2,
        primaries: CFString? = nil,
        transfer: CFString? = nil,
        luma: UInt8,
        cb: UInt8,
        cr: UInt8
    ) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            format,
            attrs as CFDictionary,
            &buffer)
        guard status == kCVReturnSuccess, let pb = buffer else {
            throw XCTSkip("IOSurface YCbCr CVPixelBuffer unavailable (status=\(status))")
        }
        CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, ycbcrMatrix, .shouldPropagate)
        if let primaries {
            CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, primaries, .shouldPropagate)
        }
        if let transfer {
            CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, transfer, .shouldPropagate)
        }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }

        let yBase = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(pb, 0)).assumingMemoryBound(to: UInt8.self)
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        let yW = CVPixelBufferGetWidthOfPlane(pb, 0)
        let yH = CVPixelBufferGetHeightOfPlane(pb, 0)
        for row in 0..<yH {
            memset(yBase + row * yStride, Int32(luma), yW)
        }

        let uvBase = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(pb, 1)).assumingMemoryBound(to: UInt8.self)
        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
        let uvW = CVPixelBufferGetWidthOfPlane(pb, 1)
        let uvH = CVPixelBufferGetHeightOfPlane(pb, 1)
        for row in 0..<uvH {
            let rowPtr = uvBase + row * uvStride
            for col in 0..<uvW {
                rowPtr[col * 2] = cb
                rowPtr[col * 2 + 1] = cr
            }
        }
        return pb
    }

    private func readBGRAPixel(_ pb: CVPixelBuffer, x: Int, y: Int) throws -> (b: Int, g: Int, r: Int, a: Int) {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pb)).assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(pb)
        let p = base + y * stride + x * 4
        return (Int(p[0]), Int(p[1]), Int(p[2]), Int(p[3]))
    }

    // MARK: - VideoBandCompositor Tests

    func testCompositorResetDoesNotCompileMetalShadersWhenUnused() {
        let compositor = VideoBandCompositor()
        XCTAssertFalse(compositor.isMetalInitializedForTesting)
        compositor.reset()
        XCTAssertFalse(
            compositor.isMetalInitializedForTesting,
            "Resetting an unused compositor must not trigger Metal shader compilation")
    }

    func testCompositorSingleTileExactMatchIsZeroCopyPassthrough() throws {
        let compositor = VideoBandCompositor()
        let single = try makeBiPlanarYCbCr(
            width: 64,
            height: 48,
            format: kCVPixelFormatType_444YpCbCr8BiPlanarFullRange,
            luma: 180,
            cb: 128,
            cr: 128)
        let output = try XCTUnwrap(compositor.compose(bands: [100: single], width: 64, height: 48))
        XCTAssertTrue(output === single, "Exact-match 1-tile frame must pass through zero-copy")
        XCTAssertFalse(
            compositor.isMetalInitializedForTesting,
            "1-tile zero-copy passthrough must not initialize Metal pipelines")
    }

    func testMetalCompositorMatchesCoreImageForBiPlanarYCbCrFormats() throws {
        let compositor = VideoBandCompositor()
        guard compositor.isMetalAvailable else {
            throw XCTSkip("Metal unavailable in this environment")
        }

        let cases: [(OSType, CFString, UInt8, UInt8, UInt8)] = [
            (kCVPixelFormatType_444YpCbCr8BiPlanarFullRange, kCVImageBufferYCbCrMatrix_ITU_R_709_2, 160, 96, 180),
            (kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVImageBufferYCbCrMatrix_ITU_R_709_2, 120, 170, 90),
            (kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVImageBufferYCbCrMatrix_ITU_R_601_4, 140, 110, 160),
        ]

        let ciContext = CIContext(options: [.cacheIntermediates: false])
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

        for (format, matrix, luma, cb, cr) in cases {
            let band0 = try makeBiPlanarYCbCr(
                width: 32,
                height: 16,
                format: format,
                ycbcrMatrix: matrix,
                primaries: kCVImageBufferColorPrimaries_ITU_R_709_2,
                transfer: kCVImageBufferTransferFunction_sRGB,
                luma: luma,
                cb: cb,
                cr: cr)
            let band1 = try makeBiPlanarYCbCr(
                width: 32,
                height: 16,
                format: format,
                ycbcrMatrix: matrix,
                primaries: kCVImageBufferColorPrimaries_ITU_R_709_2,
                transfer: kCVImageBufferTransferFunction_sRGB,
                luma: 90,
                cb: 150,
                cr: 110)

            let metalOut = try XCTUnwrap(
                compositor.compose(bands: [1: band0, 2: band1], width: 32, height: 28))
            let ciOut = try XCTUnwrap(
                compositor.composeWithCoreImageForTesting(bands: [1: band0, 2: band1], width: 32, height: 28))

            XCTAssertEqual(CVPixelBufferGetWidth(metalOut), 32)
            XCTAssertEqual(CVPixelBufferGetHeight(metalOut), 28)

            let topMetal = try readBGRAPixel(metalOut, x: 16, y: 8)
            let topCI = try readBGRAPixel(ciOut, x: 16, y: 8)
            XCTAssertLessThanOrEqual(abs(topMetal.r - topCI.r), 2, "Red mismatch for format \(format)")
            XCTAssertLessThanOrEqual(abs(topMetal.g - topCI.g), 2, "Green mismatch for format \(format)")
            XCTAssertLessThanOrEqual(abs(topMetal.b - topCI.b), 2, "Blue mismatch for format \(format)")
            XCTAssertEqual(topMetal.a, 255)

            let botMetal = try readBGRAPixel(metalOut, x: 16, y: 20)
            let botCI = try readBGRAPixel(ciOut, x: 16, y: 20)
            XCTAssertLessThanOrEqual(abs(botMetal.r - botCI.r), 2)
            XCTAssertLessThanOrEqual(abs(botMetal.g - botCI.g), 2)
            XCTAssertLessThanOrEqual(abs(botMetal.b - botCI.b), 2)
        }

        // Also verify color-managed visual equivalence when source transfer is Rec.709
        // (Metal preserves native Rec.709 transfer + attachment; Core Image converts to sRGB).
        let rec709Band0 = try makeBiPlanarYCbCr(
            width: 32,
            height: 16,
            format: kCVPixelFormatType_444YpCbCr8BiPlanarFullRange,
            ycbcrMatrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
            primaries: kCVImageBufferColorPrimaries_ITU_R_709_2,
            transfer: kCVImageBufferTransferFunction_ITU_R_709_2,
            luma: 150,
            cb: 110,
            cr: 170)
        let rec709Band1 = try makeBiPlanarYCbCr(
            width: 32,
            height: 16,
            format: kCVPixelFormatType_444YpCbCr8BiPlanarFullRange,
            ycbcrMatrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
            primaries: kCVImageBufferColorPrimaries_ITU_R_709_2,
            transfer: kCVImageBufferTransferFunction_ITU_R_709_2,
            luma: 150,
            cb: 110,
            cr: 170)
        let metalRec709 = try XCTUnwrap(
            compositor.compose(bands: [1: rec709Band0, 2: rec709Band1], width: 32, height: 32))
        let ciRec709 = try XCTUnwrap(
            compositor.composeWithCoreImageForTesting(bands: [1: rec709Band0, 2: rec709Band1], width: 32, height: 32))

        // Render Metal's Rec.709-tagged output into sRGB via Core Image and compare.
        let metalRenderedToSRGB = try makeIOSurfaceBGRA(width: 32, height: 32) { _, _ in (0, 0, 0, 0) }
        ciContext.render(
            CIImage(cvPixelBuffer: metalRec709),
            to: metalRenderedToSRGB,
            bounds: CGRect(x: 0, y: 0, width: 32, height: 32),
            colorSpace: srgb)
        let visualMetal = try readBGRAPixel(metalRenderedToSRGB, x: 16, y: 8)
        let visualCI = try readBGRAPixel(ciRec709, x: 16, y: 8)
        XCTAssertLessThanOrEqual(abs(visualMetal.r - visualCI.r), 2)
        XCTAssertLessThanOrEqual(abs(visualMetal.g - visualCI.g), 2)
        XCTAssertLessThanOrEqual(abs(visualMetal.b - visualCI.b), 2)
    }

    func testMetalCompositorPreservesDisplayP3PrimariesAcrossStitchedBands() throws {
        let compositor = VideoBandCompositor()
        guard compositor.isMetalAvailable else {
            throw XCTSkip("Metal unavailable in this environment")
        }

        let band0 = try makeBiPlanarYCbCr(
            width: 32,
            height: 16,
            format: kCVPixelFormatType_444YpCbCr8BiPlanarFullRange,
            ycbcrMatrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
            primaries: kCVImageBufferColorPrimaries_P3_D65,
            transfer: kCVImageBufferTransferFunction_sRGB,
            luma: 128,
            cb: 128,
            cr: 220)
        let band1 = try makeBiPlanarYCbCr(
            width: 32,
            height: 16,
            format: kCVPixelFormatType_444YpCbCr8BiPlanarFullRange,
            ycbcrMatrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
            primaries: kCVImageBufferColorPrimaries_P3_D65,
            transfer: kCVImageBufferTransferFunction_sRGB,
            luma: 128,
            cb: 220,
            cr: 128)

        let stitched = try XCTUnwrap(compositor.compose(bands: [1: band0, 2: band1], width: 32, height: 32))
        let primaries = CVBufferCopyAttachment(stitched, kCVImageBufferColorPrimariesKey, nil) as? String
        let transfer = CVBufferCopyAttachment(stitched, kCVImageBufferTransferFunctionKey, nil) as? String
        XCTAssertEqual(primaries, kCVImageBufferColorPrimaries_P3_D65 as String)
        XCTAssertEqual(transfer, kCVImageBufferTransferFunction_sRGB as String)
    }

    func testMetalCompositorPreservesExplicitGammaLevelAndMatchesCoreImage() throws {
        let compositor = VideoBandCompositor()
        guard compositor.isMetalAvailable else {
            throw XCTSkip("Metal unavailable in this environment")
        }

        func makeGammaBand(gamma: Double, luma: UInt8) throws -> CVPixelBuffer {
            let pb = try makeBiPlanarYCbCr(
                width: 32,
                height: 16,
                format: kCVPixelFormatType_444YpCbCr8BiPlanarFullRange,
                ycbcrMatrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                primaries: kCVImageBufferColorPrimaries_ITU_R_709_2,
                transfer: kCVImageBufferTransferFunction_UseGamma,
                luma: luma,
                cb: 128,
                cr: 128)
            CVBufferSetAttachment(
                pb,
                kCVImageBufferGammaLevelKey,
                NSNumber(value: gamma),
                .shouldPropagate)
            return pb
        }

        let b0 = try makeGammaBand(gamma: 2.2, luma: 150)
        let b1 = try makeGammaBand(gamma: 2.2, luma: 150)
        let stitched = try XCTUnwrap(compositor.compose(bands: [1: b0, 2: b1], width: 32, height: 32))
        let outTransfer = CVBufferCopyAttachment(stitched, kCVImageBufferTransferFunctionKey, nil) as? String
        let outGamma = (CVBufferCopyAttachment(stitched, kCVImageBufferGammaLevelKey, nil) as? NSNumber)?.doubleValue
        XCTAssertEqual(outTransfer, kCVImageBufferTransferFunction_UseGamma as String)
        XCTAssertEqual(outGamma ?? 0, 2.2, accuracy: 0.0001)

        // Mismatched gamma across bands must fall back to Core Image instead of
        // tagging both bands with one band's gamma.
        let bDiff = try makeGammaBand(gamma: 1.8, luma: 150)
        let mixed = try XCTUnwrap(compositor.compose(bands: [1: b0, 2: bDiff], width: 32, height: 32))
        XCTAssertNil(CVBufferCopyAttachment(mixed, kCVImageBufferGammaLevelKey, nil))
    }

    func testMetalCompositor420ChromaLocationMatchesCoreImageAcrossEdges() throws {
        let compositor = VideoBandCompositor()
        guard compositor.isMetalAvailable else {
            throw XCTSkip("Metal unavailable in this environment")
        }

        func makePattern420(chromaLocation: CFString) throws -> CVPixelBuffer {
            var buffer: CVPixelBuffer?
            let attrs: [String: Any] = [
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
            let status = CVPixelBufferCreate(
                kCFAllocatorDefault,
                32,
                16,
                kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                attrs as CFDictionary,
                &buffer)
            guard status == kCVReturnSuccess, let pb = buffer else {
                throw XCTSkip("IOSurface 420f unavailable")
            }
            CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
            CVBufferSetAttachment(pb, kCVImageBufferChromaLocationTopFieldKey, chromaLocation, .shouldPropagate)
            CVBufferSetAttachment(pb, kCVImageBufferChromaLocationBottomFieldKey, chromaLocation, .shouldPropagate)

            CVPixelBufferLockBaseAddress(pb, [])
            defer { CVPixelBufferUnlockBaseAddress(pb, []) }
            let yBase = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(pb, 0)).assumingMemoryBound(to: UInt8.self)
            let yStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
            for row in 0..<16 {
                memset(yBase + row * yStride, 140, 32)
            }
            let uvBase = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(pb, 1)).assumingMemoryBound(to: UInt8.self)
            let uvStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
            // Sharp horizontal & vertical chroma step at chroma col 8, row 4.
            for cy in 0..<8 {
                let rowPtr = uvBase + cy * uvStride
                for cx in 0..<16 {
                    let rightHalf = cx >= 8
                    let bottomHalf = cy >= 4
                    rowPtr[cx * 2] = rightHalf ? 200 : 70
                    rowPtr[cx * 2 + 1] = bottomHalf ? 190 : 80
                }
            }
            return pb
        }

        // 1. Center chroma siting: Metal bilinear upsampling matches Core Image
        // across both the horizontal and vertical chroma boundaries.
        let centerB0 = try makePattern420(chromaLocation: kCVImageBufferChromaLocation_Center)
        let centerB1 = try makePattern420(chromaLocation: kCVImageBufferChromaLocation_Center)
        let centerMetal = try XCTUnwrap(compositor.compose(bands: [1: centerB0, 2: centerB1], width: 32, height: 32))
        let centerCI = try XCTUnwrap(compositor.composeWithCoreImageForTesting(bands: [1: centerB0, 2: centerB1], width: 32, height: 32))

        for y in 6...10 {
            for x in 14...18 {
                let m = try readBGRAPixel(centerMetal, x: x, y: y)
                let c = try readBGRAPixel(centerCI, x: x, y: y)
                XCTAssertLessThanOrEqual(abs(m.r - c.r), 3, "Center R mismatch at (\(x),\(y))")
                XCTAssertLessThanOrEqual(abs(m.g - c.g), 3, "Center G mismatch at (\(x),\(y))")
                XCTAssertLessThanOrEqual(abs(m.b - c.b), 3, "Center B mismatch at (\(x),\(y))")
            }
        }

        // 2. Left chroma siting (H.264/HEVC cosited X, centered Y): even column
        // x=16 sits directly on chroma sample cx=8 (full right chroma), while
        // odd column x=15 sits halfway between cx=7 and cx=8.
        let leftB0 = try makePattern420(chromaLocation: kCVImageBufferChromaLocation_Left)
        let leftB1 = try makePattern420(chromaLocation: kCVImageBufferChromaLocation_Left)
        let leftMetal = try XCTUnwrap(compositor.compose(bands: [1: leftB0, 2: leftB1], width: 32, height: 32))

        let leftX14 = try readBGRAPixel(leftMetal, x: 14, y: 4)
        let leftX15 = try readBGRAPixel(leftMetal, x: 15, y: 4)
        let leftX16 = try readBGRAPixel(leftMetal, x: 16, y: 4)
        let leftX17 = try readBGRAPixel(leftMetal, x: 17, y: 4)
        let centerX16 = try readBGRAPixel(centerMetal, x: 16, y: 4)
        // At x=16, Left is fully on cx=8 (saturated blue = 255) whereas Center
        // blends 25% cx=7 + 75% cx=8 (~213), proving siting is honored.
        XCTAssertEqual(leftX16.b, leftX17.b)
        XCTAssertGreaterThan(leftX16.b, centerX16.b + 30)
        XCTAssertGreaterThan(leftX15.b, leftX14.b + 80)
        XCTAssertLessThan(leftX15.b, leftX16.b - 80)

        // 3. TopLeft chroma siting (cosited X and Y): even row y=8 sits
        // directly on cy=4 (full bottom Cr), while odd row y=7 sits halfway.
        let topLeftB0 = try makePattern420(chromaLocation: kCVImageBufferChromaLocation_TopLeft)
        let topLeftB1 = try makePattern420(chromaLocation: kCVImageBufferChromaLocation_TopLeft)
        let topLeftMetal = try XCTUnwrap(compositor.compose(bands: [1: topLeftB0, 2: topLeftB1], width: 32, height: 32))
        let tlY6 = try readBGRAPixel(topLeftMetal, x: 4, y: 6)
        let tlY7 = try readBGRAPixel(topLeftMetal, x: 4, y: 7)
        let tlY8 = try readBGRAPixel(topLeftMetal, x: 4, y: 8)
        let tlY9 = try readBGRAPixel(topLeftMetal, x: 4, y: 9)
        XCTAssertEqual(tlY8.r, tlY9.r)
        XCTAssertGreaterThan(tlY7.r, tlY6.r + 60)
        XCTAssertLessThan(tlY7.r, tlY8.r - 60)

        // 4. DV420 chroma siting and SMPTE 240M matrix must route through Core
        // Image and produce exact byte-for-byte parity with Core Image output.
        let dv0 = try makePattern420(chromaLocation: kCVImageBufferChromaLocation_DV420)
        let dv1 = try makePattern420(chromaLocation: kCVImageBufferChromaLocation_DV420)
        let dvOut = try XCTUnwrap(compositor.compose(bands: [1: dv0, 2: dv1], width: 32, height: 32))
        let dvCI = try XCTUnwrap(compositor.composeWithCoreImageForTesting(bands: [1: dv0, 2: dv1], width: 32, height: 32))
        let dvPix = try readBGRAPixel(dvOut, x: 16, y: 8)
        let dvCIPix = try readBGRAPixel(dvCI, x: 16, y: 8)
        XCTAssertEqual(dvPix.r, dvCIPix.r)
        XCTAssertEqual(dvPix.g, dvCIPix.g)
        XCTAssertEqual(dvPix.b, dvCIPix.b)

        let smpte0 = try makeBiPlanarYCbCr(
            width: 32,
            height: 16,
            format: kCVPixelFormatType_444YpCbCr8BiPlanarFullRange,
            ycbcrMatrix: kCVImageBufferYCbCrMatrix_SMPTE_240M_1995,
            primaries: kCVImageBufferColorPrimaries_ITU_R_709_2,
            transfer: kCVImageBufferTransferFunction_sRGB,
            luma: 150,
            cb: 90,
            cr: 190)
        let smpte1 = try makeBiPlanarYCbCr(
            width: 32,
            height: 16,
            format: kCVPixelFormatType_444YpCbCr8BiPlanarFullRange,
            ycbcrMatrix: kCVImageBufferYCbCrMatrix_SMPTE_240M_1995,
            primaries: kCVImageBufferColorPrimaries_ITU_R_709_2,
            transfer: kCVImageBufferTransferFunction_sRGB,
            luma: 150,
            cb: 90,
            cr: 190)
        let smpteOut = try XCTUnwrap(compositor.compose(bands: [1: smpte0, 2: smpte1], width: 32, height: 32))
        let smpteCI = try XCTUnwrap(compositor.composeWithCoreImageForTesting(bands: [1: smpte0, 2: smpte1], width: 32, height: 32))
        let smptePix = try readBGRAPixel(smpteOut, x: 16, y: 8)
        let smpteCIPix = try readBGRAPixel(smpteCI, x: 16, y: 8)
        XCTAssertEqual(smptePix.r, smpteCIPix.r)
        XCTAssertEqual(smptePix.g, smpteCIPix.g)
        XCTAssertEqual(smptePix.b, smpteCIPix.b)
    }

    @MainActor
    func testDisconnectOrRendererResetDropsInFlightPreparedFrame() throws {
        let renderer = VideoBandLayerRenderer()
        renderer.setScreenSize(width: 32, height: 32)
        renderer.configureExpectedBandCount(2)

        let coalescer = BandFrameCoalescer(renderer: renderer, expectedSourceCount: 2)
        let b0 = try makeIOSurfaceBGRA(width: 32, height: 16) { _, _ in (0, 0, 255, 255) }
        let b1 = try makeIOSurfaceBGRA(width: 32, height: 16) { _, _ in (0, 255, 0, 255) }

        // Submit frames and wait synchronously on the main thread until the
        // background compositor has actually finished compositing and staged
        // the prepared frame onto `DispatchQueue.main`. Because we stay on the
        // main thread, the queued main-thread presentation callback cannot run
        // until after `invalidate()` and `reset()` complete.
        coalescer.submit(ssrc: 1, pixelBuffer: b0)
        coalescer.submit(ssrc: 2, pixelBuffer: b1)

        let stageDeadline = Date().addingTimeInterval(2.0)
        while !coalescer.hasPendingPresentationForTesting && Date() < stageDeadline {
            Thread.sleep(forTimeInterval: 0.002)
        }
        XCTAssertTrue(
            coalescer.hasPendingPresentationForTesting,
            "Background compositor must stage the prepared frame before disconnect is simulated")

        let preResetConfig = renderer.compositeConfiguration
        coalescer.invalidate()
        renderer.reset()

        // Let the already-queued main-thread callback execute now.
        let exp = expectation(description: "queued presentation callback drained")
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 2.0)

        XCTAssertNil(
            renderer.latestComposedFrame,
            "Prepared frame from before disconnect/reset must not repopulate latestComposedFrame")
        XCTAssertEqual(renderer.renderedBandCount, 0)

        // Also verify `resetEpoch` independently rejects a stale prepared frame
        // even if delivered directly to the renderer.
        renderer.presentPreparedBands(
            [1: b0, 2: b1],
            composedFrame: b0,
            composedConfig: preResetConfig)
        XCTAssertNil(renderer.latestComposedFrame)
        XCTAssertEqual(renderer.renderedBandCount, 0)
    }

    func testFeedRTPBatchErrorFollowedByGapRespectsRecoveryCooldown() {
        final class LossCounter: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0
            func increment() { lock.lock(); value += 1; lock.unlock() }
            var count: Int { lock.lock(); defer { lock.unlock() }; return value }
        }

        let manager = VideoStreamManager()
        let counter = LossCounter()
        manager.onLossDetected = { _ in counter.increment() }
        manager.startStream(
            streamID: 1,
            width: 64,
            height: 64,
            usesDecodingOrderNumbers: false,
            numberOfTiles: 1) { _, _ in }
        defer { manager.stopStream() }

        func makeVideoRTP(seq: UInt16) -> Data {
            // V=2, PT=100, SSRC=0x12345678, 2-byte non-VCL payload (AUD type 35)
            Data([
                0x80, 100,
                UInt8(seq >> 8), UInt8(seq & 0xff),
                0x00, 0x00, 0x00, 0x01,
                0x12, 0x34, 0x56, 0x78,
                0x46, 0x01,
            ])
        }

        // Valid packet seq=1 establishes sequence tracking; malformed packet
        // triggers `gateAllBands(nowNanos:)` via parse error; subsequent gap
        // seq=5 in the same batch must NOT wrap cooldown and fire recovery twice.
        let malformed = Data([0x00, 0x01])
        manager.feedRTPBatch([makeVideoRTP(seq: 1), malformed, makeVideoRTP(seq: 5)])
        XCTAssertEqual(
            counter.count,
            1,
            "Error + sequence gap in the same RTP batch must respect loss recovery cooldown")
    }

    func testMetalCompositorStitchesFourBGRABandsAndCropsBottomPadding() throws {
        let compositor = VideoBandCompositor()
        let colors: [(UInt8, UInt8, UInt8)] = [
            (0, 0, 255),   // band 0: red
            (0, 255, 0),   // band 1: green
            (255, 0, 0),   // band 2: blue
            (0, 255, 255), // band 3: yellow
        ]
        var bands: [UInt32: CVPixelBuffer] = [:]
        for (idx, c) in colors.enumerated() {
            bands[UInt32(10 + idx)] = try makeIOSurfaceBGRA(width: 32, height: 16) { _, _ in
                (c.0, c.1, c.2, 255)
            }
        }
        // 4 bands * 16 = 64 coded rows; desktop height is 58 (6 padded bottom rows cropped).
        let stitched = try XCTUnwrap(compositor.compose(bands: bands, width: 32, height: 58))
        XCTAssertEqual(CVPixelBufferGetWidth(stitched), 32)
        XCTAssertEqual(CVPixelBufferGetHeight(stitched), 58)

        let p0 = try readBGRAPixel(stitched, x: 4, y: 4)
        let p1 = try readBGRAPixel(stitched, x: 4, y: 20)
        let p2 = try readBGRAPixel(stitched, x: 4, y: 36)
        let p3 = try readBGRAPixel(stitched, x: 4, y: 52)
        XCTAssertEqual(p0.r, 255); XCTAssertEqual(p0.g, 0); XCTAssertEqual(p0.b, 0)
        XCTAssertEqual(p1.r, 0); XCTAssertEqual(p1.g, 255); XCTAssertEqual(p1.b, 0)
        XCTAssertEqual(p2.r, 0); XCTAssertEqual(p2.g, 0); XCTAssertEqual(p2.b, 255)
        XCTAssertEqual(p3.r, 255); XCTAssertEqual(p3.g, 255); XCTAssertEqual(p3.b, 0)
    }

    @MainActor
    func testBrightnessPresenterHandlesNative444fPixelBuffer() throws {
        guard VNCBrightnessCapability.isEDRPresentationAvailable else {
            throw XCTSkip("EDR presentation requires macOS 26 / iOS 26")
        }
        let presenter = VNCBrightnessPresenter(contentsGravity: .resize)
        let yuv = try makeBiPlanarYCbCr(
            width: 32,
            height: 32,
            format: kCVPixelFormatType_444YpCbCr8BiPlanarFullRange,
            luma: 210,
            cb: 128,
            cr: 128)
        presenter.setSource(yuv, gain: 2.0)
        XCTAssertTrue(presenter.isPresentingBoostedContent)
        XCTAssertEqual(presenter.presentedPixelFormat, kCVPixelFormatType_64RGBAHalf)
    }

    @MainActor
    func testBandFrameCoalescerSkipsCompositingWhileSuspendedAndComposesOnResume() throws {
        let renderer = VideoBandLayerRenderer()
        renderer.setScreenSize(width: 32, height: 32)
        renderer.configureExpectedBandCount(2)
        renderer.setPresentationSuspended(true)

        let coalescer = BandFrameCoalescer(renderer: renderer, expectedSourceCount: 2)
        let b0 = try makeIOSurfaceBGRA(width: 32, height: 16) { _, _ in (0, 0, 255, 255) }
        let b1 = try makeIOSurfaceBGRA(width: 32, height: 16) { _, _ in (0, 255, 0, 255) }
        coalescer.submit(ssrc: 1, pixelBuffer: b0)
        coalescer.submit(ssrc: 2, pixelBuffer: b1)

        // Drain compositeQueue + main queue.
        let exp = expectation(description: "suspended delivery")
        DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + 0.08) {
            DispatchQueue.main.async { exp.fulfill() }
        }
        wait(for: [exp], timeout: 2.0)

        XCTAssertEqual(renderer.frameCommitCount, 0)
        XCTAssertNil(renderer.latestComposedFrame)
        XCTAssertFalse(
            renderer.sharedCompositor.isMetalInitializedForTesting,
            "Suspended presentation must not run Metal compositing in the background")

        renderer.setPresentationSuspended(false)
        XCTAssertEqual(renderer.frameCommitCount, 1)
        XCTAssertNotNil(renderer.latestComposedFrame)
    }

    @MainActor
    func testBandFrameCoalescerGenerationResetCannotBeOvertakenByRetiredCallback() throws {
        let renderer = VideoBandLayerRenderer()
        renderer.setScreenSize(width: 32, height: 32)
        renderer.configureExpectedBandCount(2)

        let coalescer = BandFrameCoalescer(renderer: renderer, expectedSourceCount: 2)
        let old0 = try makeIOSurfaceBGRA(width: 32, height: 16) { _, _ in (0, 0, 255, 255) }
        let old1 = try makeIOSurfaceBGRA(width: 32, height: 16) { _, _ in (0, 0, 255, 255) }
        let new0 = try makeIOSurfaceBGRA(width: 32, height: 16) { _, _ in (0, 255, 0, 255) }
        let new1 = try makeIOSurfaceBGRA(width: 32, height: 16) { _, _ in (0, 255, 0, 255) }

        // Submit generation 0 frames, then immediately switch to generation 2
        // and submit replacement frames with different SSRCs while main is busy.
        coalescer.submit(ssrc: 1, pixelBuffer: old0)
        coalescer.submit(ssrc: 2, pixelBuffer: old1)
        coalescer.beginStreamGeneration(2, expectedSourceCount: 2)
        coalescer.submit(ssrc: 10, pixelBuffer: new0)
        coalescer.submit(ssrc: 11, pixelBuffer: new1)

        let exp = expectation(description: "generation handoff")
        DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + 0.15) {
            DispatchQueue.main.async { exp.fulfill() }
        }
        wait(for: [exp], timeout: 2.0)

        // Renderer must have reset its band map before applying the new SSRCs,
        // so only the 2 new bands exist (never 4 mixed old+new bands).
        XCTAssertEqual(renderer.renderedBandCount, 2)
        XCTAssertEqual(renderer.streamGenerationCount, 1)
        let frame = try XCTUnwrap(renderer.latestComposedFrame)
        let top = try readBGRAPixel(frame, x: 4, y: 4)
        let bot = try readBGRAPixel(frame, x: 4, y: 20)
        XCTAssertEqual(top.g, 255)
        XCTAssertEqual(bot.g, 255)
    }

    // MARK: - RTPDemuxer & Reassembly Tests

    func testRTPDemuxerLargeMultiFragmentInterleavedFUReassembly() throws {
        let demuxer = RTPDemuxer(usesDecodingOrderNumbers: true)
        let ssrcs: [UInt32] = [0x1001, 0x1002, 0x1003, 0x1004]
        let fragmentsPerSSRC = 80
        let chunkSize = 1100
        var expectedBySSRC: [UInt32: Data] = [:]
        var seqBySSRC: [UInt32: UInt16] = [:]
        for ssrc in ssrcs {
            seqBySSRC[ssrc] = 100
            var expected = Data([0x28, 0x01]) // HEVC IDR_N_LP (type 20) header
            for frag in 0..<fragmentsPerSSRC {
                let fill = UInt8((Int(ssrc & 0xff) &+ frag) & 0xff)
                expected.append(Data(repeating: fill, count: chunkSize))
            }
            expectedBySSRC[ssrc] = expected
        }

        var completed: [UInt32: Data] = [:]
        for frag in 0..<fragmentsPerSSRC {
            for ssrc in ssrcs {
                let seq = seqBySSRC[ssrc]!
                seqBySSRC[ssrc] = seq &+ 1
                var rtp = Data([
                    0x80, 100,
                    UInt8(seq >> 8), UInt8(seq & 0xff),
                    0x00, 0x01, 0x02, 0x03,
                    UInt8((ssrc >> 24) & 0xff),
                    UInt8((ssrc >> 16) & 0xff),
                    UInt8((ssrc >> 8) & 0xff),
                    UInt8(ssrc & 0xff),
                ])
                // FU PayloadHdr (type 49 = 0x62, 0x01)
                rtp.append(0x62)
                rtp.append(0x01)
                var fuHeader: UInt8 = 20 // IDR_N_LP
                if frag == 0 { fuHeader |= 0x80 }
                if frag == fragmentsPerSSRC - 1 { fuHeader |= 0x40 }
                rtp.append(fuHeader)
                // 2-byte DONL
                rtp.append(0x00)
                rtp.append(UInt8(ssrc & 0xff))
                let fill = UInt8((Int(ssrc & 0xff) &+ frag) & 0xff)
                rtp.append(Data(repeating: fill, count: chunkSize))

                let parsed = try RTPDemuxer.parsePacket(rtp)
                let nals = demuxer.feedPacket(parsed)
                if frag < fragmentsPerSSRC - 1 {
                    XCTAssertTrue(nals.isEmpty)
                } else {
                    XCTAssertEqual(nals.count, 1)
                    completed[ssrc] = nals[0].nal
                }
            }
        }

        XCTAssertEqual(completed.count, ssrcs.count)
        for ssrc in ssrcs {
            XCTAssertEqual(completed[ssrc], expectedBySSRC[ssrc])
        }
    }

    // MARK: - AppleMediaSRTPDecryptor Generation Fencing Tests

    func testSRTPDecryptorGenerationBumpsOnConfigureAndClear() throws {
        let decryptor = AppleMediaSRTPDecryptor()
        let keyA = Data((0..<46).map { UInt8($0 + 1) })
        let keyB = Data((0..<46).map { UInt8($0 + 100) })
        let ctxA = try AppleSRTPContext(mediaKey: keyA)
        let ctxB = try AppleSRTPContext(mediaKey: keyB)

        let gen1 = decryptor.configure(contexts: [ctxA], expectsSRTP: true)
        let gen2 = decryptor.configure(contexts: [ctxB], expectsSRTP: true)
        let gen3 = decryptor.clear()

        XCTAssertGreaterThan(gen1, 0)
        XCTAssertGreaterThan(gen2, gen1)
        XCTAssertGreaterThan(gen3, gen2)

        // When cleared, decryptBatch tags items with gen3 and returns .raw.
        let sample = PosixUDPDatagram(data: Data(repeating: 0x80, count: 24), arrivalNanos: 1234)
        let batch = decryptor.decryptBatch([sample])
        XCTAssertEqual(batch.generation, gen3)
        XCTAssertEqual(batch.items.count, 1)
        if case .raw(let data, let arrival) = batch.items[0] {
            XCTAssertEqual(data, sample.data)
            XCTAssertEqual(arrival, 1234)
        } else {
            XCTFail("Expected .raw when no SRTP contexts are configured")
        }
    }

    // MARK: - AppleMediaRTPReorderBuffer Fast Path & LTR Completion Tests

    func testReorderBufferInOrderFastPathAndLTRCompletion() {
        var buffer = AppleMediaRTPReorderBuffer(startupHoldNanos: 1_000_000)
        var tracker = AppleMediaLTRFrameCompletionTracker()
        let ssrc: UInt32 = 0xAABB_CCDD

        func makeAppleRTP(seq: UInt16, ts: UInt32, totalPackets: UInt16, frameSeq: UInt16) -> Data {
            // V=2, X=1 (0x90), PT=100
            Data([
                0x90, 100,
                UInt8(seq >> 8), UInt8(seq & 0xff),
                UInt8((ts >> 24) & 0xff), UInt8((ts >> 16) & 0xff),
                UInt8((ts >> 8) & 0xff), UInt8(ts & 0xff),
                UInt8((ssrc >> 24) & 0xff), UInt8((ssrc >> 16) & 0xff),
                UInt8((ssrc >> 8) & 0xff), UInt8(ssrc & 0xff),
                // Extension header: version=2 (0x80), flags=frameExtension(0x01) + ltrBits=1(0x10) => 0x11, words=1
                0x80, 0x11, 0x00, 0x01,
                UInt8(totalPackets >> 8), UInt8(totalPackets & 0xff),
                UInt8(frameSeq >> 8), UInt8(frameSeq & 0xff),
                0xaa, 0xbb,
            ])
        }

        // First packet buffers during startup hold.
        let p0 = makeAppleRTP(seq: 1, ts: 9000, totalPackets: 3, frameSeq: 1)
        let r0 = buffer.insert(packet: p0, ssrc: ssrc, sequence: 1, nowNanos: 1_000_000)
        XCTAssertTrue(r0.packets.isEmpty)

        // Second packet crosses startup hold -> releases seq 1 and 2.
        let p1 = makeAppleRTP(seq: 2, ts: 9000, totalPackets: 3, frameSeq: 1)
        let r1 = buffer.insert(packet: p1, ssrc: ssrc, sequence: 2, nowNanos: 3_000_000)
        XCTAssertEqual(r1.packets, [p0, p1])
        XCTAssertNil(tracker.insert(r1.packets[0]))
        XCTAssertNil(tracker.insert(r1.packets[1]))

        // Third packet hits the steady-state O(1) in-order fast path and completes the LTR frame.
        let p2 = makeAppleRTP(seq: 3, ts: 9000, totalPackets: 3, frameSeq: 1)
        let r2 = buffer.insert(packet: p2, ssrc: ssrc, sequence: 3, nowNanos: 4_000_000)
        XCTAssertEqual(r2.packets, [p2])
        XCTAssertTrue(r2.gaps.isEmpty)
        XCTAssertTrue(r2.retransmissionRequests.isEmpty)
        let ack = tracker.insert(p2)
        XCTAssertEqual(ack, AppleMediaLTRFrameAcknowledgement(ssrc: ssrc, rtpTimestamp: 9000))
    }

    // MARK: - OrderedMediaPacketCoalescer Batch Tests

    func testOrderedMediaPacketCoalescerBatchEnqueuePreservesOrder() {
        final class Collector: @unchecked Sendable {
            private let lock = NSLock()
            private var items: [Data] = []
            func append(_ batch: [Data]) -> Int {
                lock.lock()
                defer { lock.unlock() }
                items.append(contentsOf: batch)
                return items.count
            }
            var snapshot: [Data] {
                lock.lock()
                defer { lock.unlock() }
                return items
            }
        }

        let queue = DispatchQueue(label: "com.rootshell.vnc.test.coalescer")
        let exp = expectation(description: "received all batch packets")
        let collector = Collector()

        let coalescer = OrderedMediaPacketCoalescer(queue: queue) { batch in
            if collector.append(batch) == 20 {
                exp.fulfill()
            }
        }

        let input = (0..<20).map { Data([UInt8($0)]) }
        coalescer.enqueue(contentsOf: Array(input[0..<10]))
        coalescer.enqueue(contentsOf: Array(input[10..<20]))

        wait(for: [exp], timeout: 2.0)
        XCTAssertEqual(collector.snapshot, input)
    }

    // MARK: - PosixUDPChannel FIFO Waiter Fairness Tests

    func testPosixUDPChannelServicesBatchAndSingleWaitersInStrictFIFOOrder() async throws {
        var fds: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_DGRAM, 0, &fds) == 0 else {
            throw XCTSkip("socketpair unavailable")
        }
        let senderFD = fds[0]
        defer { Darwin.close(senderFD) }

        let channel = PosixUDPChannel(adoptingConnectedDescriptor: fds[1], label: "fifo-fairness")
        try await channel.start()

        // Register a batch waiter FIRST, then a single waiter SECOND.
        let batchTask = Task { try await channel.receiveDatagramBatch(maxCount: 2) }
        try await Task.sleep(for: .milliseconds(20))
        let singleTask = Task { try await channel.receiveDatagram() }
        try await Task.sleep(for: .milliseconds(20))

        // Send 3 datagrams sequentially; the earlier batch waiter must get the
        // first packet(s) and must NOT be starved by the later single waiter.
        for byte: UInt8 in [1, 2, 3] {
            var b = byte
            _ = Darwin.send(senderFD, &b, 1, 0)
            try await Task.sleep(for: .milliseconds(5))
        }

        let batch = try await batchTask.value
        let single = try await singleTask.value
        await channel.close()

        XCTAssertFalse(batch.isEmpty)
        XCTAssertEqual(batch[0].data, Data([1]), "Earlier batch waiter must receive datagram #1 before later single waiter")
        let nextExpected: UInt8 = batch.count == 1 ? 2 : 3
        XCTAssertEqual(single.data, Data([nextExpected]))
    }
}
