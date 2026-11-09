import CoreGraphics
import XCTest
@testable import rootshellVNC

final class TrackpadCursorArtworkTests: XCTestCase {
    func testVectorRendersWithTransparentUnclippedCanvasAtEveryDisplayDensity() throws {
        for shape in TrackpadCursorArtwork.Shape.allCases {
            for density in [CGFloat(1), 2, 3] {
                for height in [CGFloat(8), 17, 32, 64] {
                    let factor = height / shape.visibleHeight * density
                    let image = try XCTUnwrap(TrackpadCursorArtwork.image(
                        for: shape, pixelHeight: shape.canvasSize.height * factor))
                    XCTAssertEqual(image.height, Int(ceil(shape.canvasSize.height * factor)))
                    let pixels = try rgba(image)
                    let opaque = stride(from: 3, to: pixels.count, by: 4).filter { pixels[$0] > 200 }
                    XCTAssertFalse(opaque.isEmpty, "\(shape) \(height)pt @\(density)x")
                    // Guard clipping at the largest render, where antialiasing
                    // doesn't make the margin less than a single pixel.
                    if height == 64 {
                        for x in 0..<image.width {
                            XCTAssertEqual(pixels[x * 4 + 3], 0)
                            XCTAssertEqual(pixels[((image.height - 1) * image.width + x) * 4 + 3], 0)
                        }
                        for y in 0..<image.height {
                            XCTAssertEqual(pixels[(y * image.width) * 4 + 3], 0)
                            XCTAssertEqual(pixels[(y * image.width + image.width - 1) * 4 + 3], 0)
                        }
                    }
                }
            }
        }
    }

    func testHotspotsHitVisibleArtworkAndImageIsNotVerticallyFlipped() throws {
        for shape in TrackpadCursorArtwork.Shape.allCases {
            let image = try XCTUnwrap(TrackpadCursorArtwork.image(for: shape, pixelHeight: 320))
            let pixels = try rgba(image)
            let scale = 320 / shape.canvasSize.height
            let x = Int(shape.hotspot.x * scale), y = Int(shape.hotspot.y * scale)
            // The dot's fill is translucent so the remote pointer shows through.
            XCTAssertGreaterThan(pixels[(y * image.width + x) * 4 + 3], shape == .dot ? 100 : 200)
        }
    }

    func testRendererRejectsInvalidAndExcessiveSizes() {
        for height in [CGFloat.nan, .infinity, 0, -1, 4097] {
            XCTAssertNil(TrackpadCursorArtwork.image(for: .arrow, pixelHeight: height))
        }
    }

    private func rgba(_ image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }
}
