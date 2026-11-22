import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import Metal
import simd

/// Thread-safe compositor for Apple High Performance HEVC screen bands.
///
/// - In 1-tile exact-match mode (single band whose dimensions match the desktop
///   and no centered-padding crop is needed), returns the decoded `CVPixelBuffer`
///   directly for zero-copy presentation on `AVSampleBufferDisplayLayer`.
/// - In multi-band (4-tile) or cropped/padded 1-tile mode, stitches and color-
///   converts all bands in a single Metal command buffer (`CVMetalTextureCache`
///   compute kernel for bi-planar 8-bit YCbCr `444f`/`444v`/`420f`/`420v`, or
///   DMA blit for `32BGRA`), with an automatic `CIContext` fallback for exotic
///   pixel formats or headless environments without Metal.
///
/// Designed to run on a dedicated background serial queue off `@MainActor` so
/// GPU scheduling and completion waits never stall touch/pointer/keyboard input.
///
/// The main thread still reaches this object: `reset()` on every disconnect or
/// renegotiation, and a synchronous `compose` when a prepared frame cannot be
/// used. Neither may wait behind the composite queue's slow work, so no lock is
/// held across shader compilation, and only `renderLock` is held across a GPU
/// wait:
/// - `stateLock` guards the destination pool and the published Metal state for
///   a few instructions at a time. It is the only lock `reset()` takes.
/// - `metalSetupLock` serializes the one-time shader compilation.
/// - `renderLock` serializes use of the shared texture cache while one frame
///   is encoded and completed, which bounds a main-thread compose to waiting
///   for at most the single frame already in flight.
final class VideoBandCompositor: @unchecked Sendable {

    /// How a `compose` call obtains the Metal pipelines, which are compiled
    /// once on first use and take tens to hundreds of milliseconds cold.
    enum MetalSetup {
        /// Compile on the calling thread if they are not ready. For the
        /// composite queue, where waiting stalls nothing but the first frame.
        case blocking
        /// Never compile or wait: use Metal only if it is already available,
        /// otherwise compose this frame with Core Image while the pipelines
        /// are built in the background. For the main thread.
        case background
    }

    private struct YCbCrParams {
        var row0: SIMD4<Float>
        var row1: SIMD4<Float>
        var row2: SIMD4<Float>
        var yOffset: Float
        var cbOffset: Float
        var crOffset: Float
        var chromaScaleX: Float
        var chromaScaleY: Float
        var chromaPhaseX: Float
        var chromaPhaseY: Float
        var srcOriginX: UInt32
        var srcOriginY: UInt32
        var dstOriginX: UInt32
        var dstOriginY: UInt32
        var copyWidth: UInt32
        var copyHeight: UInt32
    }

    private struct MetalState {
        let device: MTLDevice
        let commandQueue: MTLCommandQueue
        let textureCache: CVMetalTextureCache
        let ycbcrPipeline: MTLComputePipelineState
        let clearPipeline: MTLComputePipelineState
    }

    private static let metalShaderSource = #"""
        #include <metal_stdlib>
        using namespace metal;

        struct YCbCrParams {
            float4 row0;
            float4 row1;
            float4 row2;
            float yOffset;
            float cbOffset;
            float crOffset;
            float chromaScaleX;
            float chromaScaleY;
            float chromaPhaseX;
            float chromaPhaseY;
            uint srcOriginX;
            uint srcOriginY;
            uint dstOriginX;
            uint dstOriginY;
            uint copyWidth;
            uint copyHeight;
        };

        kernel void compositeBiPlanarYCbCrToBGRA(
            texture2d<float, access::read> lumaTex [[texture(0)]],
            texture2d<float, access::sample> chromaTex [[texture(1)]],
            texture2d<float, access::write> outTex [[texture(2)]],
            constant YCbCrParams &p [[buffer(0)]],
            uint2 gid [[thread_position_in_grid]]
        ) {
            if (gid.x >= p.copyWidth || gid.y >= p.copyHeight) {
                return;
            }
            constexpr sampler chromaSampler(
                coord::pixel,
                address::clamp_to_edge,
                filter::linear
            );
            uint2 srcCoord = uint2(p.srcOriginX + gid.x, p.srcOriginY + gid.y);
            float2 chromaCoord = float2(
                float(srcCoord.x) * p.chromaScaleX + p.chromaPhaseX,
                float(srcCoord.y) * p.chromaScaleY + p.chromaPhaseY
            );
            float y = lumaTex.read(srcCoord).r + p.yOffset;
            float2 cbcr = chromaTex.sample(chromaSampler, chromaCoord).rg;
            float cb = cbcr.x + p.cbOffset;
            float cr = cbcr.y + p.crOffset;

            float3 yuv = float3(y, cb, cr);
            float r = saturate(dot(p.row0.xyz, yuv));
            float g = saturate(dot(p.row1.xyz, yuv));
            float b = saturate(dot(p.row2.xyz, yuv));
            outTex.write(float4(r, g, b, 1.0), uint2(p.dstOriginX + gid.x, p.dstOriginY + gid.y));
        }

        kernel void clearBlackBGRA(
            texture2d<float, access::write> outTex [[texture(0)]],
            uint2 gid [[thread_position_in_grid]]
        ) {
            if (gid.x >= outTex.get_width() || gid.y >= outTex.get_height()) {
                return;
            }
            outTex.write(float4(0.0, 0.0, 0.0, 1.0), gid);
        }
        """#

    private static let metalSetupQueue = DispatchQueue(
        label: "com.rootshell.vnc.band.metal-setup",
        qos: .userInitiated)

    private let stateLock = NSLock()
    private let metalSetupLock = NSLock()
    private let renderLock = NSLock()
    private let coreImageContextLock = NSLock()
    /// Guarded by `stateLock`.
    private var metalSetupTriggered = false
    private var metalSetupFinished = false
    private var metalStateStorage: MetalState?
    private var pool: CVPixelBufferPool?
    private var poolWidth = 0
    private var poolHeight = 0
    /// Guarded by `coreImageContextLock`.
    private var coreImageContextStorage: CIContext?
    private let sRGBColorSpace = CGColorSpace(name: CGColorSpace.sRGB)
    private let metalSetupWillBeginForTesting: (@Sendable () -> Void)?

    /// - Parameter metalSetupWillBeginForTesting: Test hook that runs on the
    ///   compiling thread immediately before shader compilation, so a test can
    ///   hold the compositor in that state.
    init(metalSetupWillBeginForTesting: (@Sendable () -> Void)? = nil) {
        self.metalSetupWillBeginForTesting = metalSetupWillBeginForTesting
    }

    /// Diagnostics/test hook: true when Metal compositing is active on this host.
    var isMetalAvailable: Bool {
        metalState(.blocking) != nil
    }

    /// Diagnostics/test hook: whether Metal shader compilation has been triggered.
    var isMetalInitializedForTesting: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return metalSetupTriggered
    }

    private func metalState(_ setup: MetalSetup) -> MetalState? {
        stateLock.lock()
        if metalSetupFinished {
            let state = metalStateStorage
            stateLock.unlock()
            return state
        }
        let firstTrigger = !metalSetupTriggered
        metalSetupTriggered = true
        stateLock.unlock()

        if case .background = setup {
            if firstTrigger {
                Self.metalSetupQueue.async { [weak self] in
                    _ = self?.metalState(.blocking)
                }
            }
            return nil
        }

        metalSetupLock.lock()
        defer { metalSetupLock.unlock() }
        stateLock.lock()
        if metalSetupFinished {
            let state = metalStateStorage
            stateLock.unlock()
            return state
        }
        stateLock.unlock()

        metalSetupWillBeginForTesting?()
        let state = Self.makeMetalState()
        stateLock.lock()
        metalStateStorage = state
        metalSetupFinished = true
        stateLock.unlock()
        return state
    }

    private func coreImageContext() -> CIContext {
        coreImageContextLock.lock()
        defer { coreImageContextLock.unlock() }
        if let context = coreImageContextStorage { return context }
        let context = CIContext(options: [.cacheIntermediates: false])
        coreImageContextStorage = context
        return context
    }

    /// Drop the destination pool. Safe to call from the main thread at any
    /// time: it takes only `stateLock`, so it never waits for a composite or
    /// for shader compilation, and it never compiles shaders itself. The
    /// texture cache needs no flush here because every Metal composite evicts
    /// the wrappers it created before returning.
    func reset() {
        stateLock.lock()
        pool = nil
        poolWidth = 0
        poolHeight = 0
        stateLock.unlock()
    }

    /// Compose one display frame from the active SSRC-keyed screen bands.
    /// Returns the single source buffer directly (zero-copy) when 1-tile exact
    /// dimensions match and no centered-padding crop is needed.
    func compose(
        bands: [UInt32: CVPixelBuffer],
        width: Int,
        height: Int,
        centersSinglePicture: Bool = false,
        metalSetup: MetalSetup = .blocking
    ) -> CVPixelBuffer? {
        guard !bands.isEmpty, width > 0, height > 0 else { return nil }

        // Zero-copy passthrough for exact-match 1-tile frames: AVSampleBufferDisplayLayer
        // natively displays bi-planar YCbCr (`444f`, `420f`, `420v`, `&8f4`) and
        // `32BGRA` directly on the display engine with zero GPU shader/copy cost.
        if bands.count == 1, let onlyBuffer = bands.values.first {
            let sourceWidth = CVPixelBufferGetWidth(onlyBuffer)
            let sourceHeight = CVPixelBufferGetHeight(onlyBuffer)
            let leftInset = centersSinglePicture ? max(0, (sourceWidth - width) / 2) : 0
            let topInset = centersSinglePicture ? max(0, (sourceHeight - height) / 2) : 0
            if sourceWidth == width && sourceHeight == height && leftInset == 0 && topInset == 0 {
                return onlyBuffer
            }
        }

        guard let destination = makeDestination(width: width, height: height) else {
            return nil
        }

        let sortedBands = bands.sorted(by: { $0.key < $1.key })
        let centered = centersSinglePicture && sortedBands.count == 1

        if sortedBands.allSatisfy({ Self.isMetalSupportedFormat(CVPixelBufferGetPixelFormatType($0.value)) }),
           let metal = metalState(metalSetup),
           composeWithMetal(
               metal: metal,
               sortedBands: sortedBands,
               destination: destination,
               width: width,
               height: height,
               centered: centered
           ) {
            return destination
        }

        composeWithCoreImage(
            sortedBands: sortedBands,
            destination: destination,
            width: width,
            height: height,
            centered: centered
        )
        return destination
    }

    /// Exposed for accuracy regression tests comparing Metal vs Core Image output.
    func composeWithCoreImageForTesting(
        bands: [UInt32: CVPixelBuffer],
        width: Int,
        height: Int,
        centersSinglePicture: Bool = false
    ) -> CVPixelBuffer? {
        guard !bands.isEmpty, width > 0, height > 0 else { return nil }
        guard let destination = makeDestination(width: width, height: height) else {
            return nil
        }
        let sortedBands = bands.sorted(by: { $0.key < $1.key })
        composeWithCoreImage(
            sortedBands: sortedBands,
            destination: destination,
            width: width,
            height: height,
            centered: centersSinglePicture && sortedBands.count == 1
        )
        return destination
    }

    // MARK: - Metal Path

    private struct Placement {
        let buffer: CVPixelBuffer
        let format: OSType
        let srcOriginX: Int
        let srcOriginY: Int
        let dstOriginY: Int
        let copyWidth: Int
        let copyHeight: Int
    }

    private func composeWithMetal(
        metal: MetalState,
        sortedBands: [(key: UInt32, value: CVPixelBuffer)],
        destination: CVPixelBuffer,
        width: Int,
        height: Int,
        centered: Bool
    ) -> Bool {
        renderLock.lock()
        defer { renderLock.unlock() }
        // The texture wrappers live only inside this call, so the flush below
        // evicts all of them whether the composite completed or bailed out.
        let completed = encodeAndCompleteMetalComposite(
            metal: metal,
            sortedBands: sortedBands,
            destination: destination,
            width: width,
            height: height,
            centered: centered)
        CVMetalTextureCacheFlush(metal.textureCache, 0)
        return completed
    }

    private func encodeAndCompleteMetalComposite(
        metal: MetalState,
        sortedBands: [(key: UInt32, value: CVPixelBuffer)],
        destination: CVPixelBuffer,
        width: Int,
        height: Int,
        centered: Bool
    ) -> Bool {
        var placements: [Placement] = []
        placements.reserveCapacity(sortedBands.count)
        var top = 0
        var fullyCovered = true
        var uniformColorSignature: BandColorSignature?

        for (_, pixelBuffer) in sortedBands {
            guard top < height else { break }
            let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
            guard Self.isMetalSupportedFormat(format),
                  let signature = Self.extractMetalSafeColorSignature(pixelBuffer) else {
                return false
            }
            if let existing = uniformColorSignature {
                guard existing == signature else {
                    // Mixed color spaces across bands require Core Image color conversion.
                    return false
                }
            } else {
                uniformColorSignature = signature
            }
            let sourceWidth = CVPixelBufferGetWidth(pixelBuffer)
            let sourceHeight = CVPixelBufferGetHeight(pixelBuffer)
            let leftInset = centered ? max(0, (sourceWidth - width) / 2) : 0
            let topInset = centered ? max(0, (sourceHeight - height) / 2) : 0
            let copyWidth = min(width, sourceWidth - leftInset)
            let copyHeight = min(sourceHeight - topInset, height - top)
            guard copyWidth > 0, copyHeight > 0 else {
                top += sourceHeight
                continue
            }
            if copyWidth < width {
                fullyCovered = false
            }
            placements.append(Placement(
                buffer: pixelBuffer,
                format: format,
                srcOriginX: leftInset,
                srcOriginY: topInset,
                dstOriginY: top,
                copyWidth: copyWidth,
                copyHeight: copyHeight))
            top += sourceHeight
        }
        if top < height {
            fullyCovered = false
        }

        // Keep CVMetalTexture wrappers alive until the command buffer completes.
        var retainedCVTextures: [CVMetalTexture] = []
        retainedCVTextures.reserveCapacity(1 + placements.count * 2)

        guard let dstCVTex = makeMetalTexture(
            cache: metal.textureCache,
            pixelBuffer: destination,
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            planeIndex: 0
        ), let dstTexture = CVMetalTextureGetTexture(dstCVTex) else {
            return false
        }
        retainedCVTextures.append(dstCVTex)

        guard let commandBuffer = metal.commandQueue.makeCommandBuffer() else {
            return false
        }

        if !fullyCovered {
            guard let clearEncoder = commandBuffer.makeComputeCommandEncoder() else {
                return false
            }
            clearEncoder.setComputePipelineState(metal.clearPipeline)
            clearEncoder.setTexture(dstTexture, index: 0)
            dispatch2D(
                encoder: clearEncoder,
                pipeline: metal.clearPipeline,
                width: width,
                height: height)
            clearEncoder.endEncoding()
        }

        // Batch consecutive compute placements into a single compute encoder and
        // consecutive BGRA placements into a single blit encoder.
        var computeEncoder: MTLComputeCommandEncoder?
        var blitEncoder: MTLBlitCommandEncoder?

        func finishEncoders() {
            computeEncoder?.endEncoding()
            computeEncoder = nil
            blitEncoder?.endEncoding()
            blitEncoder = nil
        }

        for placement in placements {
            if placement.format == kCVPixelFormatType_32BGRA {
                if let enc = computeEncoder {
                    enc.endEncoding()
                    computeEncoder = nil
                }
                let srcW = CVPixelBufferGetWidth(placement.buffer)
                let srcH = CVPixelBufferGetHeight(placement.buffer)
                guard let srcCVTex = makeMetalTexture(
                    cache: metal.textureCache,
                    pixelBuffer: placement.buffer,
                    pixelFormat: .bgra8Unorm,
                    width: srcW,
                    height: srcH,
                    planeIndex: 0
                ), let srcTexture = CVMetalTextureGetTexture(srcCVTex) else {
                    finishEncoders()
                    return false
                }
                retainedCVTextures.append(srcCVTex)
                if blitEncoder == nil {
                    blitEncoder = commandBuffer.makeBlitCommandEncoder()
                }
                guard let blit = blitEncoder else {
                    finishEncoders()
                    return false
                }
                blit.copy(
                    from: srcTexture,
                    sourceSlice: 0,
                    sourceLevel: 0,
                    sourceOrigin: MTLOrigin(x: placement.srcOriginX, y: placement.srcOriginY, z: 0),
                    sourceSize: MTLSize(width: placement.copyWidth, height: placement.copyHeight, depth: 1),
                    to: dstTexture,
                    destinationSlice: 0,
                    destinationLevel: 0,
                    destinationOrigin: MTLOrigin(x: 0, y: placement.dstOriginY, z: 0))
            } else {
                if let enc = blitEncoder {
                    enc.endEncoding()
                    blitEncoder = nil
                }
                let lumaW = CVPixelBufferGetWidthOfPlane(placement.buffer, 0)
                let lumaH = CVPixelBufferGetHeightOfPlane(placement.buffer, 0)
                let chromaW = CVPixelBufferGetWidthOfPlane(placement.buffer, 1)
                let chromaH = CVPixelBufferGetHeightOfPlane(placement.buffer, 1)
                guard lumaW > 0, lumaH > 0, chromaW > 0, chromaH > 0,
                      let lumaCVTex = makeMetalTexture(
                          cache: metal.textureCache,
                          pixelBuffer: placement.buffer,
                          pixelFormat: .r8Unorm,
                          width: lumaW,
                          height: lumaH,
                          planeIndex: 0
                      ),
                      let chromaCVTex = makeMetalTexture(
                          cache: metal.textureCache,
                          pixelBuffer: placement.buffer,
                          pixelFormat: .rg8Unorm,
                          width: chromaW,
                          height: chromaH,
                          planeIndex: 1
                      ),
                      let lumaTex = CVMetalTextureGetTexture(lumaCVTex),
                      let chromaTex = CVMetalTextureGetTexture(chromaCVTex) else {
                    finishEncoders()
                    return false
                }
                retainedCVTextures.append(lumaCVTex)
                retainedCVTextures.append(chromaCVTex)

                if computeEncoder == nil {
                    guard let enc = commandBuffer.makeComputeCommandEncoder() else {
                        finishEncoders()
                        return false
                    }
                    enc.setComputePipelineState(metal.ycbcrPipeline)
                    enc.setTexture(dstTexture, index: 2)
                    computeEncoder = enc
                }
                guard let enc = computeEncoder else {
                    finishEncoders()
                    return false
                }

                guard var params = Self.makeYCbCrParams(
                    pixelBuffer: placement.buffer,
                    format: placement.format,
                    placement: placement) else {
                    finishEncoders()
                    return false
                }
                enc.setTexture(lumaTex, index: 0)
                enc.setTexture(chromaTex, index: 1)
                enc.setBytes(&params, length: MemoryLayout<YCbCrParams>.stride, index: 0)
                dispatch2D(
                    encoder: enc,
                    pipeline: metal.ycbcrPipeline,
                    width: placement.copyWidth,
                    height: placement.copyHeight)
            }
        }

        finishEncoders()

        // Propagate the bands' exact color primaries/transfer/gamma/CGColorSpace
        // so wide-gamut (e.g. Display P3, BT.2020) and explicit-gamma stitched
        // frames match single-tile passthrough instead of being mislabeled as sRGB.
        applyColorAttachments(
            signature: uniformColorSignature,
            sourceBuffer: placements.first?.buffer,
            to: destination)

        // Swift may end a local's lifetime at its last use, so pin the texture
        // wrappers explicitly until the GPU has finished reading them.
        return withExtendedLifetime(retainedCVTextures) {
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            return commandBuffer.status == .completed
        }
    }

    private struct BandColorSignature: Equatable {
        let primaries: String?
        let transfer: String?
        let gammaLevel: Double?
        let cgColorSpaceName: String?
    }

    /// Returns a color signature if the buffer can be accurately composited in
    /// Metal while preserving source primaries, transfer function, and gamma;
    /// returns `nil` for HDR transfer curves or arbitrary ICC profiles that
    /// require color-managed Core Image conversion.
    private static func extractMetalSafeColorSignature(
        _ pixelBuffer: CVPixelBuffer
    ) -> BandColorSignature? {
        if CVBufferCopyAttachment(pixelBuffer, kCVImageBufferICCProfileKey, nil) != nil {
            return nil
        }

        let primaries = attachmentString(pixelBuffer, kCVImageBufferColorPrimariesKey)
        let transfer = attachmentString(pixelBuffer, kCVImageBufferTransferFunctionKey)
        let gammaLevel = attachmentDouble(pixelBuffer, kCVImageBufferGammaLevelKey)

        if let transfer {
            let isHDRTransfer = transfer == (kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String)
                || transfer == (kCVImageBufferTransferFunction_ITU_R_2100_HLG as String)
                || transfer == (kCVImageBufferTransferFunction_Linear as String)
            if isHDRTransfer {
                return nil
            }
        }

        var cgColorSpaceName: String?
        if let csAttachment = CVBufferCopyAttachment(
            pixelBuffer,
            kCVImageBufferCGColorSpaceKey,
            nil),
           CFGetTypeID(csAttachment) == CGColorSpace.typeID {
            let cs = csAttachment as! CGColorSpace
            guard let name = cs.name as String? else {
                // Unnamed / custom ICC-backed CGColorSpace: route through Core Image.
                return nil
            }
            cgColorSpaceName = name
        }

        return BandColorSignature(
            primaries: primaries,
            transfer: transfer,
            gammaLevel: gammaLevel,
            cgColorSpaceName: cgColorSpaceName)
    }

    private func applyColorAttachments(
        signature: BandColorSignature?,
        sourceBuffer: CVPixelBuffer?,
        to destination: CVPixelBuffer
    ) {
        CVBufferRemoveAttachment(destination, kCVImageBufferColorPrimariesKey)
        CVBufferRemoveAttachment(destination, kCVImageBufferTransferFunctionKey)
        CVBufferRemoveAttachment(destination, kCVImageBufferGammaLevelKey)
        CVBufferRemoveAttachment(destination, kCVImageBufferCGColorSpaceKey)
        CVBufferRemoveAttachment(destination, kCVImageBufferYCbCrMatrixKey)
        CVBufferRemoveAttachment(destination, kCVImageBufferICCProfileKey)

        if let sourceBuffer,
           let signature,
           signature.primaries != nil
            || signature.transfer != nil
            || signature.gammaLevel != nil
            || signature.cgColorSpaceName != nil {
            if let primaries = CVBufferCopyAttachment(sourceBuffer, kCVImageBufferColorPrimariesKey, nil) {
                CVBufferSetAttachment(destination, kCVImageBufferColorPrimariesKey, primaries, .shouldPropagate)
            }
            if let transfer = CVBufferCopyAttachment(sourceBuffer, kCVImageBufferTransferFunctionKey, nil) {
                CVBufferSetAttachment(destination, kCVImageBufferTransferFunctionKey, transfer, .shouldPropagate)
            }
            if let gamma = CVBufferCopyAttachment(sourceBuffer, kCVImageBufferGammaLevelKey, nil) {
                CVBufferSetAttachment(destination, kCVImageBufferGammaLevelKey, gamma, .shouldPropagate)
            }
            if let cs = CVBufferCopyAttachment(sourceBuffer, kCVImageBufferCGColorSpaceKey, nil) {
                CVBufferSetAttachment(destination, kCVImageBufferCGColorSpaceKey, cs, .shouldPropagate)
            }
        } else if let sRGBColorSpace {
            CVBufferSetAttachment(
                destination,
                kCVImageBufferCGColorSpaceKey,
                sRGBColorSpace,
                .shouldPropagate)
        }
    }

    private static func attachmentString(
        _ pixelBuffer: CVPixelBuffer,
        _ key: CFString
    ) -> String? {
        guard let value = CVBufferCopyAttachment(pixelBuffer, key, nil),
              CFGetTypeID(value) == CFStringGetTypeID() else {
            return nil
        }
        return value as? String
    }

    private static func attachmentDouble(
        _ pixelBuffer: CVPixelBuffer,
        _ key: CFString
    ) -> Double? {
        guard let value = CVBufferCopyAttachment(pixelBuffer, key, nil),
              let number = value as? NSNumber else {
            return nil
        }
        return number.doubleValue
    }

    private func dispatch2D(
        encoder: MTLComputeCommandEncoder,
        pipeline: MTLComputePipelineState,
        width: Int,
        height: Int
    ) {
        let tgWidth = min(16, max(1, pipeline.threadExecutionWidth))
        let tgHeight = min(16, max(1, pipeline.maxTotalThreadsPerThreadgroup / tgWidth))
        let threadsPerGroup = MTLSize(width: tgWidth, height: tgHeight, depth: 1)
        let threadgroups = MTLSize(
            width: (width + tgWidth - 1) / tgWidth,
            height: (height + tgHeight - 1) / tgHeight,
            depth: 1)
        encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerGroup)
    }

    private func makeMetalTexture(
        cache: CVMetalTextureCache,
        pixelBuffer: CVPixelBuffer,
        pixelFormat: MTLPixelFormat,
        width: Int,
        height: Int,
        planeIndex: Int
    ) -> CVMetalTexture? {
        var textureOut: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            cache,
            pixelBuffer,
            nil,
            pixelFormat,
            width,
            height,
            planeIndex,
            &textureOut)
        guard status == kCVReturnSuccess else { return nil }
        return textureOut
    }

    /// Uncompressed formats directly readable by `CVMetalTextureCache`.
    /// Lossless-compressed Apple Silicon IOSurfaces (`&8f4`, etc.) route
    /// directly to Core Image's hardware compressed-surface path without
    /// compiling Metal shaders or failing texture-cache binding.
    private static func isMetalSupportedFormat(_ format: OSType) -> Bool {
        switch format {
        case kCVPixelFormatType_32BGRA,
             kCVPixelFormatType_444YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            return true
        default:
            return false
        }
    }

    private static func makeYCbCrParams(
        pixelBuffer: CVPixelBuffer,
        format: OSType,
        placement: Placement
    ) -> YCbCrParams? {
        let isFullRange = format == kCVPixelFormatType_444YpCbCr8BiPlanarFullRange
            || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        let is420 = format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            || format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange

        // Resolve chroma sampling coordinates in Metal pixel space (texel center
        // at i + 0.5). For 4:4:4 each luma sample has a 1:1 chroma texel. For
        // 4:2:0 honor `kCVImageBufferChromaLocationTopFieldKey` so cosited
        // (Left/TopLeft) and centered (Center) sources align with Core Image.
        let chromaScaleX: Float
        let chromaScaleY: Float
        let chromaPhaseX: Float
        let chromaPhaseY: Float
        if is420 {
            chromaScaleX = 0.5
            chromaScaleY = 0.5
            if let loc = attachmentString(pixelBuffer, kCVImageBufferChromaLocationTopFieldKey) {
                if loc == (kCVImageBufferChromaLocation_Left as String) {
                    // Cosited horizontally (even X), centered vertically.
                    chromaPhaseX = 0.5
                    chromaPhaseY = 0.25
                } else if loc == (kCVImageBufferChromaLocation_Center as String) {
                    // Centered horizontally and vertically.
                    chromaPhaseX = 0.25
                    chromaPhaseY = 0.25
                } else if loc == (kCVImageBufferChromaLocation_TopLeft as String) {
                    // Cosited horizontally and vertically.
                    chromaPhaseX = 0.5
                    chromaPhaseY = 0.5
                } else if loc == (kCVImageBufferChromaLocation_Top as String) {
                    // Centered horizontally, cosited at top row.
                    chromaPhaseX = 0.25
                    chromaPhaseY = 0.5
                } else if loc == (kCVImageBufferChromaLocation_BottomLeft as String) {
                    // Cosited horizontally, aligned to odd/bottom row.
                    chromaPhaseX = 0.5
                    chromaPhaseY = 0.0
                } else if loc == (kCVImageBufferChromaLocation_Bottom as String) {
                    // Centered horizontally, aligned to odd/bottom row.
                    chromaPhaseX = 0.25
                    chromaPhaseY = 0.0
                } else {
                    // DV420 (alternating vertical Cb/Cr) and unknown sitings:
                    // route through Core Image.
                    return nil
                }
            } else {
                // Default 4:2:0 siting (H.264/HEVC Left).
                chromaPhaseX = 0.5
                chromaPhaseY = 0.25
            }
        } else {
            chromaScaleX = 1.0
            chromaScaleY = 1.0
            chromaPhaseX = 0.5
            chromaPhaseY = 0.5
        }

        // Base full-range ITU-R YCbCr -> RGB coefficients.
        let rCr: Float
        let gCb: Float
        let gCr: Float
        let bCb: Float

        let matrixAttachment = CVBufferCopyAttachment(
            pixelBuffer,
            kCVImageBufferYCbCrMatrixKey,
            nil)
        if let matrixCF = matrixAttachment {
            guard CFGetTypeID(matrixCF) == CFStringGetTypeID() else { return nil }
            let matrixStr = matrixCF as! CFString
            if CFStringCompare(matrixStr, kCVImageBufferYCbCrMatrix_ITU_R_709_2, []) == .compareEqualTo {
                rCr = 1.574800
                gCb = -0.187324
                gCr = -0.468124
                bCb = 1.855600
            } else if CFStringCompare(matrixStr, kCVImageBufferYCbCrMatrix_ITU_R_601_4, []) == .compareEqualTo {
                rCr = 1.402000
                gCb = -0.344136
                gCr = -0.714136
                bCb = 1.772000
            } else if CFStringCompare(matrixStr, kCVImageBufferYCbCrMatrix_ITU_R_2020, []) == .compareEqualTo {
                rCr = 1.474600
                gCb = -0.164553
                gCr = -0.571353
                bCb = 1.881400
            } else {
                // Explicit non-709/601/2020 matrix (e.g. SMPTE 240M): route
                // through Core Image instead of applying Rec. 709 coefficients.
                return nil
            }
        } else {
            // Untagged default for HD / macOS Screen Sharing HEVC.
            rCr = 1.574800
            gCb = -0.187324
            gCr = -0.468124
            bCb = 1.855600
        }

        let yScale: Float = isFullRange ? 1.0 : (255.0 / 219.0)
        let cScale: Float = isFullRange ? 1.0 : (255.0 / 224.0)
        let yOffset: Float = isFullRange ? 0.0 : (-16.0 / 255.0)
        let chromaOffset: Float = -128.0 / 255.0

        return YCbCrParams(
            row0: SIMD4<Float>(yScale, 0.0, rCr * cScale, 0.0),
            row1: SIMD4<Float>(yScale, gCb * cScale, gCr * cScale, 0.0),
            row2: SIMD4<Float>(yScale, bCb * cScale, 0.0, 0.0),
            yOffset: yOffset,
            cbOffset: chromaOffset,
            crOffset: chromaOffset,
            chromaScaleX: chromaScaleX,
            chromaScaleY: chromaScaleY,
            chromaPhaseX: chromaPhaseX,
            chromaPhaseY: chromaPhaseY,
            srcOriginX: UInt32(placement.srcOriginX),
            srcOriginY: UInt32(placement.srcOriginY),
            dstOriginX: 0,
            dstOriginY: UInt32(placement.dstOriginY),
            copyWidth: UInt32(placement.copyWidth),
            copyHeight: UInt32(placement.copyHeight)
        )
    }

    private static func makeMetalState() -> MetalState? {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            return nil
        }
        var cacheOut: CVMetalTextureCache?
        let cacheStatus = CVMetalTextureCacheCreate(
            kCFAllocatorDefault,
            nil,
            device,
            nil,
            &cacheOut)
        guard cacheStatus == kCVReturnSuccess, let textureCache = cacheOut else {
            return nil
        }
        guard let library = try? device.makeLibrary(source: metalShaderSource, options: nil),
              let ycbcrFn = library.makeFunction(name: "compositeBiPlanarYCbCrToBGRA"),
              let clearFn = library.makeFunction(name: "clearBlackBGRA"),
              let ycbcrPipeline = try? device.makeComputePipelineState(function: ycbcrFn),
              let clearPipeline = try? device.makeComputePipelineState(function: clearFn) else {
            return nil
        }
        return MetalState(
            device: device,
            commandQueue: commandQueue,
            textureCache: textureCache,
            ycbcrPipeline: ycbcrPipeline,
            clearPipeline: clearPipeline)
    }

    // MARK: - Core Image Fallback

    private func composeWithCoreImage(
        sortedBands: [(key: UInt32, value: CVPixelBuffer)],
        destination: CVPixelBuffer,
        width: Int,
        height: Int,
        centered: Bool
    ) {
        let outputBounds = CGRect(x: 0, y: 0, width: width, height: height)
        var frame = CIImage(color: .black).cropped(to: outputBounds)
        var top = 0

        for (_, pixelBuffer) in sortedBands {
            guard top < height else { break }
            let sourceWidth = CVPixelBufferGetWidth(pixelBuffer)
            let sourceHeight = CVPixelBufferGetHeight(pixelBuffer)
            let leftInset = centered ? max(0, (sourceWidth - width) / 2) : 0
            let topInset = centered ? max(0, (sourceHeight - height) / 2) : 0
            let validHeight = min(sourceHeight - topInset, height - top)
            guard sourceWidth > 0, validHeight > 0 else { continue }

            let source = CIImage(cvPixelBuffer: pixelBuffer)
            let crop = CGRect(
                x: source.extent.minX + CGFloat(leftInset),
                y: source.extent.maxY - CGFloat(topInset + validHeight),
                width: min(CGFloat(width), source.extent.width - CGFloat(leftInset)),
                height: CGFloat(validHeight))
            let destinationBottom = height - top - validHeight
            let placed = source
                .cropped(to: crop)
                .transformed(by: CGAffineTransform(
                    translationX: -crop.minX,
                    y: CGFloat(destinationBottom) - crop.minY))
            frame = placed.composited(over: frame)
            top += sourceHeight
        }

        // The Metal path writes the bands' own R'G'B' values and tags the
        // frame with their color attachments. Produce the same frame here when
        // the bands share one such description: a main-thread compose uses
        // this path until the Metal pipelines are ready, and on a static
        // desktop that frame can stay on screen. Converting to sRGB instead
        // would clip wide-gamut bands and leave the frame untagged.
        let sharedColor = Self.sharedTaggedColor(of: sortedBands)
        coreImageContext().render(
            frame,
            to: destination,
            bounds: outputBounds,
            colorSpace: sharedColor?.colorSpace ?? sRGBColorSpace)
        applyColorAttachments(
            signature: sharedColor?.signature,
            sourceBuffer: sharedColor?.sourceBuffer,
            to: destination)
    }

    /// The color description every band carries, when there is exactly one,
    /// it is one the Metal path would propagate, and Core Video can express it
    /// as a color space to render into.
    private static func sharedTaggedColor(
        of sortedBands: [(key: UInt32, value: CVPixelBuffer)]
    ) -> (signature: BandColorSignature, sourceBuffer: CVPixelBuffer, colorSpace: CGColorSpace)? {
        guard let first = sortedBands.first?.value,
              let signature = extractMetalSafeColorSignature(first),
              signature.primaries != nil
                || signature.transfer != nil
                || signature.gammaLevel != nil
                || signature.cgColorSpaceName != nil,
              sortedBands.dropFirst().allSatisfy({
                  extractMetalSafeColorSignature($0.value) == signature
              }) else {
            return nil
        }

        if let attached = CVBufferCopyAttachment(first, kCVImageBufferCGColorSpaceKey, nil),
           CFGetTypeID(attached) == CGColorSpace.typeID {
            return (signature, first, attached as! CGColorSpace)
        }
        guard let attachments = CVBufferCopyAttachments(first, .shouldPropagate) else {
            return nil
        }
        if let colorSpace = CVImageBufferCreateColorSpaceFromAttachments(attachments)?
            .takeRetainedValue() {
            return (signature, first, colorSpace)
        }
        // Core Video may decline to describe a buffer that has no YCbCr
        // matrix, which RGB bands never carry. The matrix has no bearing on
        // the RGB color space, so supply one and ask again.
        guard CFDictionaryGetValue(
            attachments,
            Unmanaged.passUnretained(kCVImageBufferYCbCrMatrixKey).toOpaque()) == nil,
              let completed = CFDictionaryCreateMutableCopy(nil, 0, attachments) else {
            return nil
        }
        CFDictionarySetValue(
            completed,
            Unmanaged.passUnretained(kCVImageBufferYCbCrMatrixKey).toOpaque(),
            Unmanaged.passUnretained(kCVImageBufferYCbCrMatrix_ITU_R_709_2).toOpaque())
        guard let colorSpace = CVImageBufferCreateColorSpaceFromAttachments(completed)?
            .takeRetainedValue() else {
            return nil
        }
        return (signature, first, colorSpace)
    }

    // MARK: - Destination Pool

    private func makeDestination(width: Int, height: Int) -> CVPixelBuffer? {
        stateLock.lock()
        defer { stateLock.unlock() }
        if pool == nil || poolWidth != width || poolHeight != height {
            let poolAttributes: [String: Any] = [
                kCVPixelBufferPoolMinimumBufferCountKey as String: 4,
            ]
            let pixelAttributes: [String: Any] = [
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
            var newPool: CVPixelBufferPool?
            guard CVPixelBufferPoolCreate(
                kCFAllocatorDefault,
                poolAttributes as CFDictionary,
                pixelAttributes as CFDictionary,
                &newPool) == kCVReturnSuccess,
                  let newPool else { return nil }
            pool = newPool
            poolWidth = width
            poolHeight = height
        }

        guard let pool else { return nil }
        var destination: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(
            kCFAllocatorDefault,
            pool,
            &destination) == kCVReturnSuccess else { return nil }
        return destination
    }
}
