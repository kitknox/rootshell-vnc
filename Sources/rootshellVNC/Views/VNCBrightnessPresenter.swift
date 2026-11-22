import CoreGraphics
import CoreImage
import CoreVideo
import IOSurface
import QuartzCore

/// Runtime gate for the modern per-layer EDR APIs. Keep every reference to
/// iOS/macOS 26 symbols inside the guarded helpers so the package remains safe
/// to load on its iOS 18 / macOS 15 deployment targets.
enum VNCBrightnessCapability {
    static var isEDRPresentationAvailable: Bool {
        #if os(visionOS)
        return false
        #else
        if #available(iOS 26.0, macCatalyst 26.0, macOS 26.0, *) {
            return true
        }
        return false
        #endif
    }

    static func effectiveGain(_ gain: Double, supported: Bool? = nil) -> Double {
        let isSupported = supported ?? isEDRPresentationAvailable
        guard isSupported else { return 1.0 }
        return min(max(gain, 1.0), 16.0)
    }

    @MainActor
    static func prepareForEDR(_ layer: CALayer) {
        #if !os(visionOS)
        if #available(iOS 26.0, macCatalyst 26.0, macOS 26.0, *) {
            layer.preferredDynamicRange = .high
        }
        #endif
    }

    @MainActor
    static func setContentHeadroom(_ gain: Double, on layer: CALayer) {
        #if !os(visionOS)
        if #available(iOS 26.0, macCatalyst 26.0, macOS 26.0, *) {
            layer.contentsHeadroom = CGFloat(gain)
        }
        #endif
    }
}

/// Converts an SDR image into an extended-linear, half-float IOSurface and
/// presents it on a CALayer. The normal VNC image/video renderer remains
/// visible underneath and this layer has no contents at neutral gain, keeping
/// the original SDR presentation path intact.
@MainActor
final class VNCBrightnessPresenter {
    let layer = CALayer()

    private static let kernelSource = #"""
        kernel vec4 vncBrightness(__sample color, float gain) {
            if (gain <= 1.0) {
                return color;
            }

            float alpha = color.a;
            vec3 base = color.rgb / max(alpha, 0.0001);
            float brightness = max(base.r, max(base.g, base.b));
            float highlightWeight = smoothstep(0.18, 0.82, brightness);
            float appliedGain = mix(1.0, gain, highlightWeight);
            vec3 boosted = color.rgb * appliedGain;

            float amount = 1.0 + (appliedGain - 1.0) * 0.5;
            float outputLuma = dot(boosted, vec3(0.2126, 0.7152, 0.0722));
            boosted = max(mix(vec3(outputLuma), boosted, amount), vec3(0.0));
            return vec4(boosted, alpha);
        }
        """#

    private let extendedColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
    private let sourceColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private lazy var context = CIContext(options: [
        .cacheIntermediates: false,
        .workingColorSpace: extendedColorSpace,
        .workingFormat: CIFormat.RGBAh,
    ])
    private lazy var kernel = CIColorKernel(source: Self.kernelSource)

    private enum Source {
        case cgImage(CGImage)
        case pixelBuffer(CVPixelBuffer)
        case ioSurface(IOSurfaceRef)
    }

    private var latestSource: Source?
    private var requestedGain = 1.0
    private var pool: CVPixelBufferPool?
    private var poolSize = CGSize.zero
    private var displayedBuffer: CVPixelBuffer?
    private var previousDisplayedBuffer: CVPixelBuffer?

    init(contentsGravity: CALayerContentsGravity) {
        layer.contentsGravity = contentsGravity
        layer.magnificationFilter = .linear
        layer.minificationFilter = .linear
        layer.masksToBounds = true
        VNCBrightnessCapability.prepareForEDR(layer)
    }

    var isPresentingBoostedContent: Bool { layer.contents != nil }
    var presentedPixelFormat: OSType? {
        displayedBuffer.map(CVPixelBufferGetPixelFormatType)
    }

    func setSource(_ image: CGImage?, gain: Double) {
        latestSource = image.map(Source.cgImage)
        requestedGain = gain
        let effective = VNCBrightnessCapability.effectiveGain(gain)
        if effective <= 1.0 {
            if isPresentingBoostedContent { clearBoostedContent() }
            return
        }
        renderLatestSource(effectiveGain: effective)
    }

    func setSource(_ pixelBuffer: CVPixelBuffer?, gain: Double) {
        latestSource = pixelBuffer.map(Source.pixelBuffer)
        requestedGain = gain
        let effective = VNCBrightnessCapability.effectiveGain(gain)
        if effective <= 1.0 {
            if isPresentingBoostedContent { clearBoostedContent() }
            return
        }
        renderLatestSource(effectiveGain: effective)
    }

    func setSource(_ ioSurface: IOSurfaceRef?, gain: Double) {
        latestSource = ioSurface.map(Source.ioSurface)
        requestedGain = gain
        let effective = VNCBrightnessCapability.effectiveGain(gain)
        if effective <= 1.0 {
            if isPresentingBoostedContent { clearBoostedContent() }
            return
        }
        renderLatestSource(effectiveGain: effective)
    }

    func setGain(_ gain: Double) {
        guard requestedGain != gain else { return }
        requestedGain = gain
        let effective = VNCBrightnessCapability.effectiveGain(gain)
        if effective <= 1.0 {
            if isPresentingBoostedContent { clearBoostedContent() }
            return
        }
        renderLatestSource(effectiveGain: effective)
    }

    func reset() {
        latestSource = nil
        requestedGain = 1.0
        if isPresentingBoostedContent || displayedBuffer != nil {
            clearBoostedContent()
        }
        pool = nil
        poolSize = .zero
    }

    private func renderLatestSource(effectiveGain gain: Double) {
        guard gain > 1.0,
              let sourceModel = latestSource,
              let kernel else {
            if isPresentingBoostedContent { clearBoostedContent() }
            return
        }
        let source: CIImage
        switch sourceModel {
        case .cgImage(let image):
            source = CIImage(cgImage: image, options: [.colorSpace: sourceColorSpace])
        case .pixelBuffer(let pixelBuffer):
            let hasNativeColorMetadata = CVPixelBufferGetPlaneCount(pixelBuffer) >= 2
                || CVBufferCopyAttachment(pixelBuffer, kCVImageBufferColorPrimariesKey, nil) != nil
                || CVBufferCopyAttachment(pixelBuffer, kCVImageBufferCGColorSpaceKey, nil) != nil
                || CVBufferCopyAttachment(pixelBuffer, kCVImageBufferICCProfileKey, nil) != nil
                || CVBufferCopyAttachment(pixelBuffer, kCVImageBufferGammaLevelKey, nil) != nil
            if hasNativeColorMetadata {
                // Honor the pixel buffer's own YCbCr matrix and color-space
                // attachments (e.g. `444f`, `&8f4`, Display P3 BGRA); override
                // with sRGB only for untagged RGB buffers.
                source = CIImage(cvPixelBuffer: pixelBuffer)
            } else {
                source = CIImage(cvPixelBuffer: pixelBuffer, options: [.colorSpace: sourceColorSpace])
            }
        case .ioSurface(let ioSurface):
            source = CIImage(ioSurface: ioSurface, options: [.colorSpace: sourceColorSpace])
        }

        let sourceExtent = source.extent.integral
        let width = Int(sourceExtent.width)
        let height = Int(sourceExtent.height)
        guard width > 0, height > 0,
              let destination = makeDestination(width: width, height: height)
        else {
            clearBoostedContent()
            return
        }

        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let normalizedSource = source
            .cropped(to: sourceExtent)
            .transformed(by: CGAffineTransform(
                translationX: -sourceExtent.minX,
                y: -sourceExtent.minY))
        guard let output = kernel.apply(
            extent: bounds,
            roiCallback: { _, rect in rect },
            arguments: [normalizedSource, Float(gain)])
        else {
            clearBoostedContent()
            return
        }

        context.render(
            output,
            to: destination,
            bounds: bounds,
            colorSpace: extendedColorSpace)
        tag(destination, headroom: gain)

        previousDisplayedBuffer = displayedBuffer
        displayedBuffer = destination
        VNCBrightnessCapability.setContentHeadroom(gain, on: layer)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contents = ioSurface(for: destination)
        CATransaction.commit()
    }

    private func clearBoostedContent() {
        VNCBrightnessCapability.setContentHeadroom(1.0, on: layer)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contents = nil
        CATransaction.commit()
        displayedBuffer = nil
        previousDisplayedBuffer = nil
    }

    private func makeDestination(width: Int, height: Int) -> CVPixelBuffer? {
        let size = CGSize(width: width, height: height)
        if pool == nil || poolSize != size {
            let poolAttributes: [String: Any] = [
                kCVPixelBufferPoolMinimumBufferCountKey as String: 3,
            ]
            let pixelAttributes: [String: Any] = [
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_64RGBAHalf,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfaceCoreAnimationCompatibilityKey as String: true,
            ]
            var newPool: CVPixelBufferPool?
            guard CVPixelBufferPoolCreate(
                kCFAllocatorDefault,
                poolAttributes as CFDictionary,
                pixelAttributes as CFDictionary,
                &newPool) == kCVReturnSuccess,
                  let newPool else { return nil }
            pool = newPool
            poolSize = size
        }

        guard let pool else { return nil }
        var destination: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(
            kCFAllocatorDefault,
            pool,
            &destination) == kCVReturnSuccess else { return nil }
        return destination
    }

    private func tag(_ pixelBuffer: CVPixelBuffer, headroom: Double) {
        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferCGColorSpaceKey,
            extendedColorSpace,
            .shouldPropagate)

        guard let surface = ioSurface(for: pixelBuffer) else { return }
        if let propertyList = extendedColorSpace.copyPropertyList() {
            IOSurfaceSetValue(surface, kIOSurfaceColorSpace, propertyList)
        } else if let name = extendedColorSpace.name {
            IOSurfaceSetValue(surface, kIOSurfaceColorSpace, name)
        }
        IOSurfaceSetValue(
            surface,
            kIOSurfaceContentHeadroom,
            NSNumber(value: headroom))
    }

    private func ioSurface(for pixelBuffer: CVPixelBuffer) -> IOSurfaceRef? {
        CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue()
    }
}
