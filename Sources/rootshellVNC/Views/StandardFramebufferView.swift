import CoreGraphics
import CoreVideo
import IOSurface
import QuartzCore
import RFBRendering
import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Per-view presentation layer owning a `CALayer` and `VNCBrightnessPresenter`
/// so multiple views can display the same ``StandardFramebufferLayerRenderer``
/// concurrently without competing for a single `CALayer`, and switching
/// sessions never mutates the live layer tree while presentation is prohibited.
@MainActor
final class StandardFramebufferLayerTarget {
    enum Content {
        case surface(FramebufferPresentationSurface)
        case image(CGImage)

        var dimensions: (width: CGFloat, height: CGFloat) {
            switch self {
            case .surface(let surface):
                return (CGFloat(surface.width), CGFloat(surface.height))
            case .image(let image):
                return (CGFloat(image.width), CGFloat(image.height))
            }
        }
    }

    private let brightnessPresenter = VNCBrightnessPresenter(contentsGravity: .resize)
    private let displayLayer = CALayer()
    var containerLayer: CALayer { brightnessPresenter.layer }
    var presentedLayerContents: Any? { displayLayer.contents }

    private var appliedContent: Content?
    private var cropRegion: CGRect?
    private var appliedCropRegion: CGRect?
    private var viewBounds: CGRect = .zero
    private var appliedViewBounds: CGRect = .zero
    private var pixelScale: CGFloat = 2
    private var appliedPixelScale: CGFloat = 2
    private var brightnessGain: Double = 1.0
    private var appliedBrightnessGain: Double = 1.0
    private var needsContentSync = false

    init() {
        containerLayer.masksToBounds = true
        containerLayer.contentsScale = pixelScale
        displayLayer.isOpaque = true
        displayLayer.contentsGravity = .resize
        displayLayer.magnificationFilter = .linear
        displayLayer.minificationFilter = .trilinear
        displayLayer.masksToBounds = true
        displayLayer.contentsScale = pixelScale
        containerLayer.addSublayer(displayLayer)
    }

    func setBrightnessGain(_ gain: Double, isBlocked: Bool) {
        guard brightnessGain != gain else { return }
        brightnessGain = gain
        guard !isBlocked else { return }
        applyBrightnessGainNow()
    }

    func setPixelScale(_ scale: CGFloat, isBlocked: Bool) {
        guard scale > 0, scale != pixelScale else { return }
        pixelScale = scale
        guard !isBlocked else { return }
        applyPixelScaleNow()
    }

    func setViewBounds(_ bounds: CGRect, isBlocked: Bool) {
        guard viewBounds != bounds else { return }
        viewBounds = bounds
        guard !isBlocked else { return }
        layoutNow()
    }

    func setCropRegion(_ region: CGRect?, isBlocked: Bool) {
        guard cropRegion != region else { return }
        cropRegion = region
        guard !isBlocked, let dimensions = appliedContent?.dimensions else { return }
        applyCropAndLayoutNow(width: dimensions.width, height: dimensions.height)
    }

    /// Synchronize this target with the renderer's shared content. If
    /// `isBlocked` is true, records that a sync is needed and leaves every
    /// `CALayer` completely untouched until `reconcile(content:)` runs.
    func sync(content: Content?, cropRegion: CGRect?, isBlocked: Bool) {
        self.cropRegion = cropRegion
        if isBlocked {
            needsContentSync = true
            return
        }
        needsContentSync = false
        commitNow(content: content)
    }

    /// Apply content pushed from a live renderer commit while keeping this
    /// target's own crop override if present, or adopting the renderer's crop.
    func commit(content: Content?, cropRegion: CGRect?) {
        self.cropRegion = cropRegion
        needsContentSync = false
        commitNow(content: content)
    }

    func reset(isBlocked: Bool) {
        cropRegion = nil
        if isBlocked {
            needsContentSync = true
            return
        }
        needsContentSync = false
        performLayerResetNow()
    }

    /// Flush any deferred content, scale, brightness, crop, or bounds updates
    /// once presentation is permitted again.
    func reconcile(content: Content?) {
        if appliedPixelScale != pixelScale {
            applyPixelScaleNow()
        }
        if needsContentSync {
            needsContentSync = false
            commitNow(content: content)
            return
        }
        if appliedBrightnessGain != brightnessGain {
            applyBrightnessGainNow()
        }
        if appliedViewBounds != viewBounds || appliedCropRegion != cropRegion {
            if let dimensions = appliedContent?.dimensions {
                applyCropAndLayoutNow(width: dimensions.width, height: dimensions.height)
            }
        }
    }

    private func applyPixelScaleNow() {
        appliedPixelScale = pixelScale
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        containerLayer.contentsScale = pixelScale
        displayLayer.contentsScale = pixelScale
        CATransaction.commit()
    }

    private func applyBrightnessGainNow() {
        appliedBrightnessGain = brightnessGain
        brightnessPresenter.setGain(brightnessGain)
        reconcilePresentationPathNow()
    }

    private func performLayerResetNow() {
        appliedContent = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.contents = nil
        displayLayer.contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        displayLayer.isHidden = false
        CATransaction.commit()
        appliedCropRegion = nil
        brightnessPresenter.reset()
        appliedBrightnessGain = brightnessGain
        brightnessPresenter.setGain(brightnessGain)
    }

    private func commitNow(content: Content?) {
        guard let content else {
            performLayerResetNow()
            return
        }
        appliedContent = content
        let dimensions = content.dimensions
        let contentsRect = normalizedContentsRect(
            width: dimensions.width,
            height: dimensions.height,
            cropRegion: cropRegion)

        let layerContents: Any?
        appliedBrightnessGain = brightnessGain
        switch content {
        case .surface(let surface):
            layerContents = surface.ioSurface ?? surface.makeCGImage()
            if let ioSurface = surface.ioSurface {
                brightnessPresenter.setSource(ioSurface, gain: brightnessGain)
            } else {
                brightnessPresenter.setSource(surface.fallbackPixelBuffer, gain: brightnessGain)
            }
        case .image(let image):
            layerContents = image
            brightnessPresenter.setSource(image, gain: brightnessGain)
        }
        let boosted = brightnessPresenter.isPresentingBoostedContent

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if appliedPixelScale != pixelScale {
            appliedPixelScale = pixelScale
            containerLayer.contentsScale = pixelScale
            displayLayer.contentsScale = pixelScale
        }
        displayLayer.contents = layerContents
        displayLayer.contentsRect = contentsRect
        displayLayer.isHidden = boosted
        if boosted {
            brightnessPresenter.layer.contentsRect = contentsRect
        }
        layoutLayers(width: dimensions.width, height: dimensions.height)
        appliedCropRegion = cropRegion
        appliedViewBounds = viewBounds
        CATransaction.commit()
    }

    private func applyCropAndLayoutNow(width: CGFloat, height: CGFloat) {
        let contentsRect = normalizedContentsRect(
            width: width, height: height, cropRegion: cropRegion)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.contentsRect = contentsRect
        if brightnessPresenter.isPresentingBoostedContent {
            brightnessPresenter.layer.contentsRect = contentsRect
        }
        layoutLayers(width: width, height: height)
        appliedCropRegion = cropRegion
        appliedViewBounds = viewBounds
        CATransaction.commit()
    }

    private func layoutNow() {
        guard let dimensions = appliedContent?.dimensions else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layoutLayers(width: dimensions.width, height: dimensions.height)
        appliedViewBounds = viewBounds
        CATransaction.commit()
    }

    private func layoutLayers(width: CGFloat, height: CGFloat) {
        guard viewBounds.width > 0, viewBounds.height > 0 else { return }
        let contentSize = effectiveContentSize(width: width, height: height)
        guard contentSize.width > 0, contentSize.height > 0 else { return }
        let fit = RemoteViewportState.fitScale(content: contentSize, into: viewBounds.size)
        let fitWidth = contentSize.width * fit.width
        let fitHeight = contentSize.height * fit.height
        let originX = viewBounds.minX + (viewBounds.width - fitWidth) / 2
        let originY = viewBounds.minY + (viewBounds.height - fitHeight) / 2
        let targetFrame = CGRect(x: originX, y: originY, width: fitWidth, height: fitHeight)
        if containerLayer.frame != targetFrame {
            containerLayer.frame = targetFrame
        }
        if displayLayer.frame != containerLayer.bounds {
            displayLayer.frame = containerLayer.bounds
        }
    }

    private func effectiveContentSize(width: CGFloat, height: CGFloat) -> CGSize {
        let fullBounds = CGRect(x: 0, y: 0, width: width, height: height)
        guard let cropRegion else { return fullBounds.size }
        let crop = cropRegion.integral.intersection(fullBounds)
        return crop.isEmpty ? fullBounds.size : crop.size
    }

    private func normalizedContentsRect(
        width fbWidth: CGFloat,
        height fbHeight: CGFloat,
        cropRegion: CGRect?
    ) -> CGRect {
        let fullUnit = CGRect(x: 0, y: 0, width: 1, height: 1)
        guard fbWidth > 0, fbHeight > 0, let cropRegion else { return fullUnit }
        let fullBounds = CGRect(x: 0, y: 0, width: fbWidth, height: fbHeight)
        let crop = cropRegion.integral.intersection(fullBounds)
        guard !crop.isEmpty, crop != fullBounds else { return fullUnit }

        let x = crop.minX / fbWidth
        let width = crop.width / fbWidth
        let height = crop.height / fbHeight
        // CALayer.contentsRect origin is top-left when contentsAreFlipped() is
        // true (UIKit) and bottom-left on non-flipped AppKit layers.
        let y = displayLayer.contentsAreFlipped()
            ? (crop.minY / fbHeight)
            : (1.0 - crop.maxY / fbHeight)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func reconcilePresentationPathNow() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let boosted = brightnessPresenter.isPresentingBoostedContent
        displayLayer.isHidden = boosted
        if boosted, let dimensions = appliedContent?.dimensions {
            brightnessPresenter.layer.contentsRect = normalizedContentsRect(
                width: dimensions.width,
                height: dimensions.height,
                cropRegion: cropRegion)
        }
        CATransaction.commit()
    }
}

/// Zero-copy GPU layer renderer for standard RFB / Apple Adaptive DCT mode.
///
/// Mirrors ``VideoBandLayerRenderer``: frames arrive as raw `IOSurface`-backed
/// ``FramebufferPresentationSurface``s synced by ``FramebufferSurfacePool`` off
/// the main thread (dirty rectangles only) and are assigned directly to
/// per-host `CALayer`s without per-frame `CGImage` copies, SwiftUI view
/// invalidations, or Lanczos resampling. Multiple views displaying the same
/// session share the decoded `IOSurface` across independent presentation layers.
@MainActor
public final class StandardFramebufferLayerRenderer {
    private struct WeakTarget {
        weak var value: StandardFramebufferLayerTarget?
    }

    private let primaryTarget = StandardFramebufferLayerTarget()
    private var attachedTargets: [ObjectIdentifier: WeakTarget] = [:]

    /// Primary layer for direct/standalone callers. Hosted SwiftUI views each
    /// own their own presentation layer and subscribe to shared surface updates.
    public var containerLayer: CALayer { primaryTarget.containerLayer }

    private var displayedSurface: FramebufferPresentationSurface?
    private var previousDisplayedSurface: FramebufferPresentationSurface?
    private var displayedImage: CGImage?
    private var pendingSuspendedSurface: FramebufferPresentationSurface?
    private var pendingSuspendedImage: CGImage?
    private var pendingSuspendedCrop: CGRect?
    private var pendingReset = false
    private var cropRegion: CGRect?

    public private(set) var isPresentationSuspended = false
    private(set) var frameCommitCount: UInt64 = 0

    /// The currently presented surface, or nil before the first frame or after
    /// a full reset.
    public var latestPresentedSurface: FramebufferPresentationSurface? { displayedSurface }

    /// The previously presented surface retained across one swap while Core
    /// Animation finishes compositing it.
    var previousPresentedSurface: FramebufferPresentationSurface? { previousDisplayedSurface }

    var isPresentationBlocked: Bool {
        isPresentationSuspended || VNCPresentationPolicy.isPresentationProhibited()
    }

    private var currentPresentedContent: StandardFramebufferLayerTarget.Content? {
        if let displayedSurface { return .surface(displayedSurface) }
        if let displayedImage { return .image(displayedImage) }
        return nil
    }

    public init() {}

    func attachTarget(
        _ target: StandardFramebufferLayerTarget,
        cropRegion: CGRect?,
        brightnessGain: Double
    ) {
        pruneDeadTargets()
        attachedTargets[ObjectIdentifier(target)] = WeakTarget(value: target)
        let blocked = isPresentationBlocked
        target.setBrightnessGain(brightnessGain, isBlocked: blocked)
        target.sync(
            content: currentPresentedContent,
            cropRegion: cropRegion ?? self.cropRegion,
            isBlocked: blocked)
    }

    func detachTarget(_ target: StandardFramebufferLayerTarget) {
        attachedTargets.removeValue(forKey: ObjectIdentifier(target))
    }

    public func setBrightnessGain(_ gain: Double) {
        primaryTarget.setBrightnessGain(gain, isBlocked: isPresentationBlocked)
    }

    public func setPixelScale(_ scale: CGFloat) {
        primaryTarget.setPixelScale(scale, isBlocked: isPresentationBlocked)
    }

    public func setViewBounds(_ bounds: CGRect) {
        primaryTarget.setViewBounds(bounds, isBlocked: isPresentationBlocked)
    }

    public func setCropRegion(_ region: CGRect?) {
        cropRegion = region
        primaryTarget.setCropRegion(region, isBlocked: isPresentationBlocked)
    }

    public func setPresentationSuspended(_ suspended: Bool) {
        guard isPresentationSuspended != suspended else { return }
        isPresentationSuspended = suspended
        if !suspended {
            presentPendingIfAny()
        }
    }

    public func presentPendingIfAny() {
        guard !isPresentationBlocked else { return }
        if pendingReset {
            pendingReset = false
            performResetAcrossTargets()
        }
        if let pending = pendingSuspendedSurface {
            let crop = pendingSuspendedCrop
            pendingSuspendedSurface = nil
            pendingSuspendedImage = nil
            pendingSuspendedCrop = nil
            commit(surface: pending, cropRegion: crop)
            return
        }
        if let pendingImage = pendingSuspendedImage {
            let crop = pendingSuspendedCrop
            pendingSuspendedSurface = nil
            pendingSuspendedImage = nil
            pendingSuspendedCrop = nil
            commit(image: pendingImage, cropRegion: crop)
            return
        }
        let content = currentPresentedContent
        primaryTarget.reconcile(content: content)
        forEachLiveTarget { target in
            target.reconcile(content: content)
        }
    }

    public func reset() {
        displayedSurface = nil
        previousDisplayedSurface = nil
        displayedImage = nil
        pendingSuspendedSurface = nil
        pendingSuspendedImage = nil
        pendingSuspendedCrop = nil
        cropRegion = nil
        if isPresentationBlocked {
            pendingReset = true
            primaryTarget.reset(isBlocked: true)
            forEachLiveTarget { $0.reset(isBlocked: true) }
            return
        }
        pendingReset = false
        performResetAcrossTargets()
    }

    public func present(_ surface: FramebufferPresentationSurface, cropRegion: CGRect?) {
        if isPresentationBlocked {
            pendingSuspendedSurface = surface
            pendingSuspendedImage = nil
            pendingSuspendedCrop = cropRegion
            return
        }
        if pendingReset {
            pendingReset = false
            performResetAcrossTargets()
        }
        pendingSuspendedSurface = nil
        pendingSuspendedImage = nil
        pendingSuspendedCrop = nil
        commit(surface: surface, cropRegion: cropRegion)
    }

    /// Present an explicit `CGImage` override (for callers that assign
    /// `VNCSession.currentImage` directly).
    public func present(image: CGImage, cropRegion: CGRect?) {
        if isPresentationBlocked {
            pendingSuspendedImage = image
            pendingSuspendedSurface = nil
            pendingSuspendedCrop = cropRegion
            return
        }
        if pendingReset {
            pendingReset = false
            performResetAcrossTargets()
        }
        pendingSuspendedSurface = nil
        pendingSuspendedImage = nil
        pendingSuspendedCrop = nil
        commit(image: image, cropRegion: cropRegion)
    }

    /// Lazily create an immutable `CGImage` snapshot of the currently presented
    /// surface (used only when an external caller or test reads
    /// `VNCSession.currentImage` / `presentedFrame`).
    public func makeCurrentCGImage() -> CGImage? {
        if let displayedImage { return displayedImage }
        return displayedSurface?.makeCGImage()
    }

    private func performResetAcrossTargets() {
        primaryTarget.reset(isBlocked: false)
        forEachLiveTarget { $0.reset(isBlocked: false) }
    }

    private func commit(surface: FramebufferPresentationSurface, cropRegion: CGRect?) {
        frameCommitCount &+= 1
        self.cropRegion = cropRegion
        displayedImage = nil
        previousDisplayedSurface = displayedSurface
        displayedSurface = surface

        let content = StandardFramebufferLayerTarget.Content.surface(surface)
        primaryTarget.commit(content: content, cropRegion: cropRegion)
        forEachLiveTarget { target in
            target.commit(content: content, cropRegion: cropRegion)
        }
    }

    private func commit(image: CGImage, cropRegion: CGRect?) {
        frameCommitCount &+= 1
        self.cropRegion = cropRegion
        previousDisplayedSurface = nil
        displayedSurface = nil
        displayedImage = image

        let content = StandardFramebufferLayerTarget.Content.image(image)
        primaryTarget.commit(content: content, cropRegion: cropRegion)
        forEachLiveTarget { target in
            target.commit(content: content, cropRegion: cropRegion)
        }
    }

    private func pruneDeadTargets() {
        attachedTargets = attachedTargets.filter { $0.value.value != nil }
    }

    private func forEachLiveTarget(_ body: (StandardFramebufferLayerTarget) -> Void) {
        var deadKeys: [ObjectIdentifier] = []
        for (key, wrapper) in attachedTargets {
            if let target = wrapper.value {
                body(target)
            } else {
                deadKeys.append(key)
            }
        }
        for key in deadKeys {
            attachedTargets.removeValue(forKey: key)
        }
    }
}

#if canImport(UIKit)
final class StandardFramebufferHostView: UIView {
    private(set) var renderer: StandardFramebufferLayerRenderer
    let presentationTarget = StandardFramebufferLayerTarget()

    init(
        renderer: StandardFramebufferLayerRenderer,
        cropRegion: CGRect? = nil,
        brightnessGain: Double = 1.0
    ) {
        self.renderer = renderer
        super.init(frame: .zero)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        layer.addSublayer(presentationTarget.containerLayer)
        renderer.attachTarget(
            presentationTarget,
            cropRegion: cropRegion,
            brightnessGain: brightnessGain)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func bind(
        renderer newRenderer: StandardFramebufferLayerRenderer,
        cropRegion: CGRect? = nil,
        brightnessGain: Double = 1.0
    ) {
        if renderer !== newRenderer {
            renderer.detachTarget(presentationTarget)
            renderer = newRenderer
            newRenderer.attachTarget(
                presentationTarget,
                cropRegion: cropRegion,
                brightnessGain: brightnessGain)
        } else {
            let blocked = renderer.isPresentationBlocked
            presentationTarget.setBrightnessGain(brightnessGain, isBlocked: blocked)
            presentationTarget.setCropRegion(cropRegion, isBlocked: blocked)
        }
        applyCurrentGeometry()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        applyCurrentGeometry()
    }

    private func applyCurrentGeometry() {
        #if os(visionOS)
        let scale = traitCollection.displayScale
        #else
        let scale = window?.screen.scale ?? traitCollection.displayScale
        #endif
        let blocked = renderer.isPresentationBlocked
        if scale > 0 { presentationTarget.setPixelScale(scale, isBlocked: blocked) }
        presentationTarget.setViewBounds(bounds, isBlocked: blocked)
    }
}

/// SwiftUI wrapper that displays a Standard-mode framebuffer on the GPU via
/// ``StandardFramebufferLayerRenderer``.
struct StandardFramebufferView: UIViewRepresentable {
    let renderer: StandardFramebufferLayerRenderer
    let cropRegion: CGRect?
    let brightnessGain: Double

    func makeUIView(context: Context) -> UIView {
        StandardFramebufferHostView(
            renderer: renderer,
            cropRegion: cropRegion,
            brightnessGain: brightnessGain)
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        if let host = uiView as? StandardFramebufferHostView {
            host.bind(
                renderer: renderer,
                cropRegion: cropRegion,
                brightnessGain: brightnessGain)
        }
    }
}
#elseif canImport(AppKit)
final class StandardFramebufferHostView: NSView {
    private(set) var renderer: StandardFramebufferLayerRenderer
    let presentationTarget = StandardFramebufferLayerTarget()

    init(
        renderer: StandardFramebufferLayerRenderer,
        cropRegion: CGRect? = nil,
        brightnessGain: Double = 1.0
    ) {
        self.renderer = renderer
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.addSublayer(presentationTarget.containerLayer)
        renderer.attachTarget(
            presentationTarget,
            cropRegion: cropRegion,
            brightnessGain: brightnessGain)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func bind(
        renderer newRenderer: StandardFramebufferLayerRenderer,
        cropRegion: CGRect? = nil,
        brightnessGain: Double = 1.0
    ) {
        if renderer !== newRenderer {
            renderer.detachTarget(presentationTarget)
            renderer = newRenderer
            newRenderer.attachTarget(
                presentationTarget,
                cropRegion: cropRegion,
                brightnessGain: brightnessGain)
        } else {
            let blocked = renderer.isPresentationBlocked
            presentationTarget.setBrightnessGain(brightnessGain, isBlocked: blocked)
            presentationTarget.setCropRegion(cropRegion, isBlocked: blocked)
        }
        applyCurrentGeometry()
    }

    override func layout() {
        super.layout()
        applyCurrentGeometry()
    }

    private func applyCurrentGeometry() {
        let scale = window?.backingScaleFactor ?? 2
        let blocked = renderer.isPresentationBlocked
        if scale > 0 { presentationTarget.setPixelScale(scale, isBlocked: blocked) }
        presentationTarget.setViewBounds(bounds, isBlocked: blocked)
    }
}

/// SwiftUI wrapper that displays a Standard-mode framebuffer on the GPU via
/// ``StandardFramebufferLayerRenderer``.
struct StandardFramebufferView: NSViewRepresentable {
    let renderer: StandardFramebufferLayerRenderer
    let cropRegion: CGRect?
    let brightnessGain: Double

    func makeNSView(context: Context) -> NSView {
        StandardFramebufferHostView(
            renderer: renderer,
            cropRegion: cropRegion,
            brightnessGain: brightnessGain)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let host = nsView as? StandardFramebufferHostView {
            host.bind(
                renderer: renderer,
                cropRegion: cropRegion,
                brightnessGain: brightnessGain)
        }
    }
}
#endif
