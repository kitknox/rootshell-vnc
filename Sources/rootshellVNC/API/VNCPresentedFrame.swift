import CoreGraphics
import CoreVideo

/// The picture a session is presenting, for a host that keeps a snapshot of
/// it. It holds what ``RemoteDesktopView`` shows and nothing else: never a
/// display that is not selected, never fewer displays than are on screen.
public enum VNCPresentedFrame {
    /// Standard: the framebuffer, cropped to the selected display.
    case image(CGImage)
    /// High Performance: each display's last complete surface.
    case surfaces([Surface])

    public struct Surface {
        /// The display's surface. Its pixel format varies: `32BGRA` for
        /// stitched bands, or the decoder's bi-planar YCbCr surface (`444f`,
        /// `420v`, ...) for a single picture shown without a copy. Read it
        /// through a format-aware API such as `CIImage(cvPixelBuffer:)`, not
        /// as packed BGRA bytes.
        public let pixelBuffer: CVPixelBuffer
        /// Where the surface sits in the presented picture, in picture
        /// pixels with a top-left origin.
        public let region: CGRect
    }
}

extension VNCSession {
    /// Whether the view has a picture from this connection on screen. True
    /// as soon as any presented display draws, which can be before
    /// ``presentedFrame`` has every display: a host placeholder must come
    /// down then, even though there is no complete snapshot yet. The
    /// displays are separate streams, and either can be first.
    public var isPresentingPicture: Bool {
        guard isHighPerformanceMode else { return hasPresentedStandardPicture }
        if videoBandRenderer.latestComposedFrame != nil { return true }
        return presentedVideoDisplayRegions.count > 1
            && secondaryVideoBandRenderer.latestComposedFrame != nil
    }

    /// Nil until every presented display has a complete frame.
    public var presentedFrame: VNCPresentedFrame? {
        guard isHighPerformanceMode else {
            guard let image = currentImage else { return nil }
            return .image(Self.cropped(image, to: presentedFramebufferRegion))
        }

        guard let primary = videoBandRenderer.latestComposedFrame else { return nil }
        let regions = presentedVideoDisplayRegions
        guard regions.count > 1 else {
            return .surfaces([VNCPresentedFrame.Surface(
                pixelBuffer: primary,
                region: CGRect(
                    x: 0,
                    y: 0,
                    width: CVPixelBufferGetWidth(primary),
                    height: CVPixelBufferGetHeight(primary)))])
        }
        guard let secondary = secondaryVideoBandRenderer.latestComposedFrame else { return nil }
        return .surfaces([
            VNCPresentedFrame.Surface(pixelBuffer: primary, region: regions[0]),
            VNCPresentedFrame.Surface(pixelBuffer: secondary, region: regions[1]),
        ])
    }

    /// The same crop the Standard view applies before drawing.
    static func cropped(_ image: CGImage, to region: CGRect?) -> CGImage {
        guard let region else { return image }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let crop = region.integral.intersection(bounds)
        guard !crop.isEmpty, crop != bounds else { return image }
        return image.cropping(to: crop) ?? image
    }
}
