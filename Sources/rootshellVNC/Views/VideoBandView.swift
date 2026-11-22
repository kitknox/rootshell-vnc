import SwiftUI
import CoreVideo
import CoreMedia
import CoreImage
import QuartzCore
import AVFoundation
import RFBTransport

/// GPU renderer for Apple's high-performance HEVC screen bands.
///
/// Each RTP SSRC is a horizontal band of the screen. The bands are stitched
/// into one IOSurface-backed frame before presentation. Apple follows the same
/// single-surface model for compound HEVC; independent display layers can
/// consume the change-gated bands at different times and expose seams or
/// transiently incomplete surfaces even when every decoded band is clean.
@MainActor
public final class VideoBandLayerRenderer {

    /// Thread-safe snapshot of desktop dimensions, crop mode, suspension, and
    /// reset epoch so ``BandFrameCoalescer`` can composite bands off
    /// `@MainActor`, skip GPU work while suspended, and drop stale frames from
    /// before a disconnect or reset.
    struct CompositeConfiguration: Equatable, Sendable {
        var width: Int = 0
        var height: Int = 0
        var centersSinglePicture: Bool = false
        var isPresentationSuspended: Bool = false
        var resetEpoch: UInt64 = 0
    }

    private let compositeConfigLock = NSLock()
    private nonisolated(unsafe) var lockedCompositeConfig = CompositeConfiguration()
    /// Shared compositor used both off-MainActor by `BandFrameCoalescer` and
    /// synchronously by direct `setBands(_:)` callers.
    nonisolated let sharedCompositor = VideoBandCompositor()

    nonisolated var compositeConfiguration: CompositeConfiguration {
        compositeConfigLock.lock()
        defer { compositeConfigLock.unlock() }
        return lockedCompositeConfig
    }

    private let displayLayer = AVSampleBufferDisplayLayer()
    private let brightnessPresenter = VNCBrightnessPresenter(contentsGravity: .resize)
    /// The layer the host view displays. Boosted IOSurface contents live on
    /// this same layer, preserving the renderer's one atomic display sublayer.
    public var containerLayer: CALayer { brightnessPresenter.layer }
    private var bandBuffers: [UInt32: CVPixelBuffer] = [:]
    private var previousBandBuffers: [UInt32: CVPixelBuffer] = [:]
    private var displayedBuffer: CVPixelBuffer?
    private var previousDisplayedBuffer: CVPixelBuffer?
    private var cachedFormatDescription: CMVideoFormatDescription?
    private var screenWidth: CGFloat = 0
    private var screenHeight: CGFloat = 0
    private var centersSinglePicture = false
    private var resetEpoch: UInt64 = 0
    private var viewBounds: CGRect = .zero
    /// A media renegotiation can replace every SSRC. Retain the previous
    /// generation on screen while the server negotiates, then remove its
    /// layers in the same transaction that installs the first new frame.
    private var replaceLayersOnNextFrame = false
    /// Display pixel density. Hand-made CALayers default to 1.0, which renders
    /// at half resolution on a Retina display (blurry, "compressed"); this must
    /// track the screen's scale.
    private var pixelScale: CGFloat = 2
    private(set) var frameCommitCount: UInt64 = 0
    private(set) var streamGenerationCount: UInt64 = 0
    private(set) var lastCommitBandCount = 0
    private(set) var partialCommitCount: UInt64 = 0
    private var expectedBandCount = Int(AppleMediaVideoMode.negotiatedTilesPerFrame)
    private var brightnessGain = 1.0

    /// Called after a complete stitched surface has been committed. Consumers
    /// such as one-shot Vision analysis can inspect the exact full image
    /// without adding a second compositor or touching individual HEVC bands.
    var onFrameCommitted: ((CVPixelBuffer, UInt64) -> Void)?

    /// The last complete surface sent to the display: nil before the first
    /// frame and after a reset. For host snapshots; read only.
    public var latestComposedFrame: CVPixelBuffer? { displayedBuffer }

    var renderedBandCount: Int { bandBuffers.count }

    var renderedBandDimensions: [(width: Int, height: Int)] {
        bandBuffers.values.map {
            (CVPixelBufferGetWidth($0), CVPixelBufferGetHeight($0))
        }
    }

    public init() {
        lockedCompositeConfig.isPresentationSuspended = VNCPresentationPolicy.isPresentationProhibited()
        containerLayer.masksToBounds = true
        containerLayer.contentsScale = pixelScale
        displayLayer.videoGravity = .resize
        displayLayer.masksToBounds = true
        displayLayer.contentsScale = pixelScale
        containerLayer.addSublayer(displayLayer)
    }

    /// Apply the host's global HDR brightness gain. The presenter internally
    /// forces this to neutral on pre-26 systems and retains the native
    /// AVSampleBufferDisplayLayer path when no boost is active.
    public func setBrightnessGain(_ gain: Double) {
        guard brightnessGain != gain else { return }
        brightnessGain = gain
        brightnessPresenter.setGain(gain)
        reconcilePresentationPath()
    }

    /// Set the backing scale to the host display's scale so the decoded frames
    /// render at native pixel density.
    public func setPixelScale(_ scale: CGFloat) {
        guard scale > 0, scale != pixelScale else { return }
        pixelScale = scale
        containerLayer.contentsScale = scale
        displayLayer.contentsScale = scale
    }

    public func setScreenSize(width: Int, height: Int) {
        screenWidth = CGFloat(width)
        screenHeight = CGFloat(height)
        compositeConfigLock.lock()
        lockedCompositeConfig.width = width
        lockedCompositeConfig.height = height
        compositeConfigLock.unlock()
        layout()
    }

    /// Low Bandwidth (mode 5) centers the screen in a padded picture; crop its
    /// middle rather than the top-left corner.
    public func setCentersPaddedPicture(_ centers: Bool) {
        centersSinglePicture = centers
        compositeConfigLock.lock()
        lockedCompositeConfig.centersSinglePicture = centers
        compositeConfigLock.unlock()
    }

    public func configureExpectedBandCount(_ count: Int) {
        expectedBandCount = max(1, count)
    }

    public func reset() {
        resetEpoch &+= 1
        compositeConfigLock.lock()
        lockedCompositeConfig.resetEpoch = resetEpoch
        compositeConfigLock.unlock()
        bandBuffers.removeAll()
        previousBandBuffers.removeAll()
        displayedBuffer = nil
        previousDisplayedBuffer = nil
        cachedFormatDescription = nil
        sharedCompositor.reset()
        replaceLayersOnNextFrame = false
        hasPendingSuspendedBands = false
        if isPresentationSuspended || VNCPresentationPolicy.isPresentationProhibited() {
            // Connection setup/teardown can run while the device is locked
            // (background launch, reconnect). The flush and brightness or
            // presentation-path mutations are layer commits the secure gate
            // must cover too, so they wait for resume.
            pendingDisplayFlush = true
            pendingPresenterReset = true
            return
        }
        pendingDisplayFlush = false
        pendingPresenterReset = false
        displayLayer.sampleBufferRenderer.flush(
            removingDisplayedImage: true,
            completionHandler: nil)
        brightnessPresenter.reset()
        brightnessPresenter.setGain(brightnessGain)
        reconcilePresentationPath()
    }

    public func beginStreamGeneration(
        expectedBandCount: Int = Int(AppleMediaVideoMode.negotiatedTilesPerFrame)
    ) {
        streamGenerationCount &+= 1
        self.expectedBandCount = expectedBandCount
        replaceLayersOnNextFrame = true
    }

    /// Push a synchronized screen-band set as one stitched display surface.
    /// `BandFrameCoalescer` freezes the inputs; the compositor then copies the
    /// retained static bands and dirty bands into a single atomic frame.
    public func setBands(_ buffers: [UInt32: CVPixelBuffer]) {
        presentPreparedBands(
            buffers,
            composedFrame: nil,
            composedConfig: nil)
    }

    /// Present a band snapshot whose GPU compositing already ran off
    /// `@MainActor`. Falls back to synchronous compositing if desktop geometry
    /// or band membership changed while the frame was in flight.
    func presentPreparedBands(
        _ buffers: [UInt32: CVPixelBuffer],
        composedFrame: CVPixelBuffer?,
        composedConfig: CompositeConfiguration?
    ) {
        if let composedConfig, composedConfig.resetEpoch != resetEpoch {
            // Frame was prepared before a disconnect/reset; discard it so it
            // cannot repopulate `latestComposedFrame` with a retired session.
            return
        }
        guard !buffers.isEmpty else { return }
        let prohibited = VNCPresentationPolicy.isPresentationProhibited()
        if isPresentationSuspended || prohibited {
            setLockedPresentationSuspended(true)
            recordBandsWhileSuspended(buffers)
            return
        }
        setLockedPresentationSuspended(false)
        frameCommitCount &+= 1
        lastCommitBandCount = buffers.count
        if buffers.count != expectedBandCount {
            partialCommitCount &+= 1
        }
        performPendingDisplayFlushIfNeeded()
        if replaceLayersOnNextFrame {
            displayLayer.sampleBufferRenderer.flush(
                removingDisplayedImage: true,
                completionHandler: nil)
            bandBuffers.removeAll()
            previousBandBuffers.removeAll()
            displayedBuffer = nil
            previousDisplayedBuffer = nil
            cachedFormatDescription = nil
            sharedCompositor.reset()
            replaceLayersOnNextFrame = false
        }
        for (ssrc, pixelBuffer) in buffers {
            previousBandBuffers[ssrc] = bandBuffers[ssrc]
            bandBuffers[ssrc] = pixelBuffer
        }
        hasPendingSuspendedBands = false

        let currentConfig = CompositeConfiguration(
            width: Int(screenWidth),
            height: Int(screenHeight),
            centersSinglePicture: centersSinglePicture,
            isPresentationSuspended: isPresentationSuspended)
        if let composedFrame,
           let composedConfig,
           composedConfig.width == currentConfig.width,
           composedConfig.height == currentConfig.height,
           composedConfig.centersSinglePicture == currentConfig.centersSinglePicture,
           buffers.count == bandBuffers.count {
            commitDisplayFrame(composedFrame)
        } else {
            presentComposedFrame()
        }
    }

    /// Stop committing frames to the display while the host is in a state
    /// where presentation could land inside the secure-mode lock snapshot.
    /// Decoded bands keep accumulating so the codec and generation state stay
    /// warm; clearing suspension composes one reconciling frame so the screen
    /// is fresh at unlock instead of stale until the next delta.
    public private(set) var isPresentationSuspended = false
    private var pendingDisplayFlush = false
    private var pendingPresenterReset = false
    private var hasPendingSuspendedBands = false

    public func setPresentationSuspended(_ suspended: Bool) {
        guard isPresentationSuspended != suspended else { return }
        isPresentationSuspended = suspended
        setLockedPresentationSuspended(suspended || VNCPresentationPolicy.isPresentationProhibited())
        if suspended {
            // Discard queued-but-unpresented samples. Best-effort narrowing:
            // samples carry display-immediately timing so at most ~one frame
            // is in flight, mirroring the terminal path's accepted post-drain
            // residual window. The displayed image stays: removing it would
            // itself be a visible commit.
            displayLayer.sampleBufferRenderer.flush(
                removingDisplayedImage: false,
                completionHandler: nil)
        } else {
            presentPendingBandsAfterResume()
        }
    }

    private func setLockedPresentationSuspended(_ suspended: Bool) {
        compositeConfigLock.lock()
        lockedCompositeConfig.isPresentationSuspended = suspended
        compositeConfigLock.unlock()
    }

    /// Present bands retained while presentation was blocked by the host's
    /// global gate alone. Renderers on panes created while the gate was
    /// already armed never see a true-to-false transition of the instance
    /// flag, so `setPresentationSuspended(false)` is a guarded no-op there.
    public func presentPendingBandsIfAny() {
        guard !isPresentationSuspended else { return }
        presentPendingBandsAfterResume()
    }

    private func recordBandsWhileSuspended(_ buffers: [UInt32: CVPixelBuffer]) {
        if replaceLayersOnNextFrame {
            // Pure-state part of the renegotiation reset; the display-layer
            // flush is itself a layer commit, so it waits for resume.
            bandBuffers.removeAll()
            previousBandBuffers.removeAll()
            cachedFormatDescription = nil
            sharedCompositor.reset()
            replaceLayersOnNextFrame = false
            pendingDisplayFlush = true
        }
        for (ssrc, pixelBuffer) in buffers {
            previousBandBuffers[ssrc] = bandBuffers[ssrc]
            bandBuffers[ssrc] = pixelBuffer
        }
        hasPendingSuspendedBands = true
    }

    private func presentPendingBandsAfterResume() {
        // The instance flag can clear while the host-level gate is still
        // armed (a tab switch driven by remote traffic on a locked device).
        // Leave the pending state set; the next setBands that passes the
        // gate composes from the full retained band set.
        guard !VNCPresentationPolicy.isPresentationProhibited() else {
            setLockedPresentationSuspended(true)
            return
        }
        setLockedPresentationSuspended(false)
        performPendingDisplayFlushIfNeeded()
        guard hasPendingSuspendedBands, !bandBuffers.isEmpty else { return }
        hasPendingSuspendedBands = false
        frameCommitCount &+= 1
        lastCommitBandCount = bandBuffers.count
        presentComposedFrame()
    }

    /// Display-layer half of a renegotiation or full reset that arrived while
    /// suspended, deferred because the flush is itself a layer commit.
    private func performPendingDisplayFlushIfNeeded() {
        guard pendingDisplayFlush else { return }
        displayLayer.sampleBufferRenderer.flush(
            removingDisplayedImage: true,
            completionHandler: nil)
        displayedBuffer = nil
        previousDisplayedBuffer = nil
        pendingDisplayFlush = false
        if pendingPresenterReset {
            brightnessPresenter.reset()
            brightnessPresenter.setGain(brightnessGain)
            reconcilePresentationPath()
            pendingPresenterReset = false
        }
    }

    private func presentComposedFrame() {
        let width = Int(screenWidth)
        let height = Int(screenHeight)
        guard width > 0, height > 0,
              let frame = sharedCompositor.compose(
                bands: bandBuffers,
                width: width,
                height: height,
                centersSinglePicture: centersSinglePicture) else { return }
        commitDisplayFrame(frame)
    }

    private func commitDisplayFrame(_ frame: CVPixelBuffer) {
        // The display renderer can retain an enqueued sample beyond this call.
        // Keep two explicit generations as well so neither Core Animation nor
        // Core Image can observe a pool surface after it has been recycled.
        previousDisplayedBuffer = displayedBuffer
        displayedBuffer = frame
        brightnessPresenter.setSource(frame, gain: brightnessGain)
        reconcilePresentationPath()

        let videoRenderer = displayLayer.sampleBufferRenderer
        if videoRenderer.status == .failed {
            videoRenderer.flush()
        }
        if let sampleBuffer = makeDisplaySample(from: frame) {
            videoRenderer.enqueue(sampleBuffer)
        }
        onFrameCommitted?(frame, streamGenerationCount)
    }

    /// Wrap an already-decoded image buffer without copying its pixels. Caches
    /// the `CMVideoFormatDescription` only while Core Media confirms every
    /// attachment (clean aperture, pixel aspect ratio, ICC profile, color
    /// primaries, transfer function, and dimensions) matches the new buffer.
    private func makeDisplaySample(
        from pixelBuffer: CVPixelBuffer
    ) -> CMSampleBuffer? {
        let formatDescription: CMVideoFormatDescription
        if let cached = cachedFormatDescription,
           CMVideoFormatDescriptionMatchesImageBuffer(cached, imageBuffer: pixelBuffer) {
            formatDescription = cached
        } else {
            var created: CMVideoFormatDescription?
            guard CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescriptionOut: &created) == noErr,
                  let created else {
                return nil
            }
            cachedFormatDescription = created
            formatDescription = created
        }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: .invalid,
            decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer) == noErr,
              let sampleBuffer else {
            return nil
        }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(
                CFArrayGetValueAtIndex(attachments, 0),
                to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dictionary,
                Unmanaged.passUnretained(
                    kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sampleBuffer
    }

    /// The host view's bounds. Drives aspect-fit layout.
    public func setViewBounds(_ bounds: CGRect) {
        viewBounds = bounds
        layout()
    }

    /// Position the one stitched desktop surface. Coded band padding has
    /// already been clipped by `VideoBandCompositor`.
    public func layout() {
        guard screenWidth > 0, screenHeight > 0, viewBounds.width > 0, viewBounds.height > 0 else { return }

        // Aspect-fit the native screen into the view, filling on a near-match.
        let scale = RemoteViewportState.fitScale(
            content: CGSize(width: screenWidth, height: screenHeight),
            into: viewBounds.size)
        let fitWidth = screenWidth * scale.width
        let fitHeight = screenHeight * scale.height
        let originX = viewBounds.minX + (viewBounds.width - fitWidth) / 2
        let originY = viewBounds.minY + (viewBounds.height - fitHeight) / 2

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        containerLayer.frame = CGRect(x: originX, y: originY, width: fitWidth, height: fitHeight)
        displayLayer.frame = containerLayer.bounds
        CATransaction.commit()
    }

    private func reconcilePresentationPath() {
        let shouldHide = brightnessPresenter.isPresentingBoostedContent
        guard displayLayer.isHidden != shouldHide else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.isHidden = shouldHide
        CATransaction.commit()
    }
}

#if canImport(UIKit)
import UIKit

/// Hosts a ``VideoBandLayerRenderer`` and keeps its container layer sized.
private final class BandHostView: UIView {
    let renderer: VideoBandLayerRenderer

    init(renderer: VideoBandLayerRenderer) {
        self.renderer = renderer
        super.init(frame: .zero)
        backgroundColor = .black
        layer.addSublayer(renderer.containerLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        #if os(visionOS)
        let scale = traitCollection.displayScale
        #else
        let scale = window?.screen.scale ?? traitCollection.displayScale
        #endif
        if scale > 0 { renderer.setPixelScale(scale) }
        renderer.setViewBounds(bounds)
    }
}

/// SwiftUI wrapper that displays a session's decoded screen bands on the GPU.
public struct VideoBandView: UIViewRepresentable {
    private let renderer: VideoBandLayerRenderer
    private let brightnessGain: Double

    public init(renderer: VideoBandLayerRenderer, brightnessGain: Double = 1.0) {
        self.renderer = renderer
        self.brightnessGain = brightnessGain
    }

    public func makeUIView(context: Context) -> UIView {
        renderer.setBrightnessGain(brightnessGain)
        return BandHostView(renderer: renderer)
    }

    public func updateUIView(_ uiView: UIView, context: Context) {
        renderer.setBrightnessGain(brightnessGain)
    }
}
#endif
