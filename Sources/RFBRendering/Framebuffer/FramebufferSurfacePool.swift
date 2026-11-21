import CoreGraphics
import CoreVideo
import Foundation
import IOSurface
import RFBRenderingC

/// Compact dirty-rectangle tracker in integer framebuffer pixel coordinates.
/// Bounds per-slot tracking to a small fixed number of rectangles so high-rate
/// interactive bursts stay O(1) while typical typing/scrolling updates copy
/// only the modified region instead of the full framebuffer.
package struct FramebufferDirtyRegion: Sendable, Equatable {
    package struct IntRect: Sendable, Equatable {
        package var minX: Int
        package var minY: Int
        package var maxX: Int
        package var maxY: Int

        package var width: Int { maxX - minX }
        package var height: Int { maxY - minY }
        package var area: Int { width * height }

        package func overlapsOrTouches(_ other: IntRect) -> Bool {
            minX <= other.maxX && maxX >= other.minX
                && minY <= other.maxY && maxY >= other.minY
        }

        package func union(_ other: IntRect) -> IntRect {
            IntRect(
                minX: min(minX, other.minX),
                minY: min(minY, other.minY),
                maxX: max(maxX, other.maxX),
                maxY: max(maxY, other.maxY))
        }
    }

    private static let maximumRects = 16

    package private(set) var isFull = false
    package private(set) var rects: [IntRect] = []

    package init(full: Bool = false) {
        self.isFull = full
    }

    package var isEmpty: Bool {
        !isFull && rects.isEmpty
    }

    package mutating func clear() {
        isFull = false
        rects.removeAll(keepingCapacity: true)
    }

    package mutating func markFull() {
        isFull = true
        rects.removeAll(keepingCapacity: true)
    }

    package mutating func insert(
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        boundsWidth: Int,
        boundsHeight: Int
    ) {
        guard !isFull, boundsWidth > 0, boundsHeight > 0 else { return }
        let minX = max(0, x)
        let minY = max(0, y)
        let maxX = min(boundsWidth, x + width)
        let maxY = min(boundsHeight, y + height)
        guard minX < maxX, minY < maxY else { return }
        if minX == 0 && minY == 0 && maxX == boundsWidth && maxY == boundsHeight {
            markFull()
            return
        }
        insertClamped(IntRect(minX: minX, minY: minY, maxX: maxX, maxY: maxY))
    }

    package mutating func insert(
        _ rect: CGRect,
        boundsWidth: Int,
        boundsHeight: Int
    ) {
        guard !isFull, boundsWidth > 0, boundsHeight > 0,
              !rect.isNull, !rect.isEmpty else { return }
        let bounds = CGRect(x: 0, y: 0, width: boundsWidth, height: boundsHeight)
        let clipped = rect.intersection(bounds)
        guard !clipped.isNull, !clipped.isEmpty else { return }
        let integral = clipped.integral.intersection(bounds)
        guard !integral.isNull, !integral.isEmpty else { return }
        insert(
            x: Int(integral.minX),
            y: Int(integral.minY),
            width: Int(integral.width),
            height: Int(integral.height),
            boundsWidth: boundsWidth,
            boundsHeight: boundsHeight)
    }

    package func resolvedRects(width: Int, height: Int) -> [IntRect] {
        guard width > 0, height > 0 else { return [] }
        if isFull {
            return [IntRect(minX: 0, minY: 0, maxX: width, maxY: height)]
        }
        return rects
    }

    package func cgRects(width: Int, height: Int) -> [CGRect] {
        resolvedRects(width: width, height: height).map {
            CGRect(x: $0.minX, y: $0.minY, width: $0.width, height: $0.height)
        }
    }

    package func estimatedDirtyPixels(width: Int, height: Int) -> Int {
        if isFull { return width * height }
        return rects.reduce(0) { $0 + $1.area }
    }

    private mutating func insertClamped(_ incoming: IntRect) {
        var candidate = incoming
        var index = 0
        while index < rects.count {
            if rects[index].overlapsOrTouches(candidate) {
                candidate = candidate.union(rects[index])
                rects.remove(at: index)
            } else {
                index += 1
            }
        }
        if rects.count >= Self.maximumRects {
            let merged = rects.reduce(candidate) { $0.union($1) }
            rects.removeAll(keepingCapacity: true)
            rects.append(merged)
        } else {
            rects.append(candidate)
        }
    }
}

/// A pooled BGRA presentation surface backed directly by a raw `IOSurfaceRef`
/// (with a CPU-backed `CVPixelBuffer` fallback in restricted/headless
/// environments where `IOSurfaceCreate` is unavailable).
///
/// Owning the raw `IOSurfaceRef` rather than holding a permanent `CVPixelBuffer`
/// wrapper keeps the surface's idle kernel use count at zero so
/// `IOSurfaceIsInUse(_:)` accurately reflects cross-process compositor
/// (WindowServer / Core Animation) reads as well as transient in-process
/// `CVPixelBuffer` readers (such as detached Vision OCR tasks).
public final class FramebufferPresentationSurface: @unchecked Sendable {
    public let width: Int
    public let height: Int
    public let ioSurface: IOSurfaceRef?
    /// Populated only when `IOSurfaceCreate` is unavailable.
    public let fallbackPixelBuffer: CVPixelBuffer?

    init(ioSurface: IOSurfaceRef, width: Int, height: Int) {
        self.ioSurface = ioSurface
        self.fallbackPixelBuffer = nil
        self.width = width
        self.height = height
    }

    init(fallbackPixelBuffer: CVPixelBuffer, width: Int, height: Int) {
        self.ioSurface = nil
        self.fallbackPixelBuffer = fallbackPixelBuffer
        self.width = width
        self.height = height
    }

    /// True if any process (including WindowServer / Core Animation) or any
    /// live `CVPixelBuffer` reader currently holds a kernel use count on the
    /// backing `IOSurface`.
    public var isInUse: Bool {
        guard let ioSurface else { return false }
        return IOSurfaceIsInUse(ioSurface)
    }

    /// Create a zero-copy `CVPixelBuffer` view over the backing `IOSurface`
    /// for asynchronous readers (such as detached Vision OCR).
    ///
    /// CoreVideo increments the `IOSurface` kernel use count while the
    /// returned `CVPixelBuffer` stays alive, causing `IOSurfaceIsInUse(_:)`
    /// to return `true` so ``FramebufferSurfacePool`` will never recycle or
    /// overwrite this surface until the reader releases it.
    ///
    /// Returns `nil` for CPU fallback surfaces; callers should fall back to
    /// ``makeCGImage()`` for an immutable snapshot.
    public func makeRetainedPixelBufferForReading() -> CVPixelBuffer? {
        guard let ioSurface else { return nil }
        var unmanaged: Unmanaged<CVPixelBuffer>?
        guard CVPixelBufferCreateWithIOSurface(
            kCFAllocatorDefault,
            ioSurface,
            nil,
            &unmanaged) == kCVReturnSuccess,
              let unmanaged else {
            return nil
        }
        return unmanaged.takeRetainedValue()
    }

    /// Create an immutable `CGImage` snapshot of this surface without locking
    /// ``Framebuffer``.
    public func makeCGImage() -> CGImage? {
        if let ioSurface {
            guard IOSurfaceLock(ioSurface, .readOnly, nil) == kIOSurfaceSuccess else {
                return nil
            }
            defer { IOSurfaceUnlock(ioSurface, .readOnly, nil) }
            let srcBase = IOSurfaceGetBaseAddress(ioSurface)
            let srcBytesPerRow = IOSurfaceGetBytesPerRow(ioSurface)
            return FramebufferSurfacePool.makeCGImageFromBGRA(
                srcBase: srcBase,
                width: width,
                height: height,
                srcBytesPerRow: srcBytesPerRow)
        }
        if let fallbackPixelBuffer {
            return FramebufferSurfacePool.makeCGImage(from: fallbackPixelBuffer)
        }
        return nil
    }
}

/// Outcome of attempting to synchronize a presentation surface from
/// ``FramebufferSurfacePool``. Distinguishes busy slots from allocation or
/// lock failures so callers never spin indefinitely on a persistent resource
/// error.
public enum FramebufferSurfaceSyncResult: @unchecked Sendable {
    case synced(FramebufferPresentationSurface)
    /// Every slot in the pool is currently busy. `externallyInUse` is `true`
    /// when at least one slot was skipped because `IOSurfaceIsInUse(_:)`
    /// reported an active compositor or asynchronous reader.
    case allSlotsBusy(externallyInUse: Bool)
    /// Surface allocation, lock, or framebuffer geometry failed.
    case resourceUnavailable
}

/// Thread-safe pool of raw `IOSurface`-backed BGRA presentation surfaces for
/// zero-copy Core Animation display of standard RFB framebuffers.
///
/// Each slot tracks the dirty regions accumulated since it was last synchronized
/// from ``Framebuffer``. Intermediate decode batches only update per-slot dirty
/// metadata; pixel copying happens strictly at presentation time and only for
/// the rectangles that changed.
///
/// Slot reuse respects both explicit caller reservations (for buffers in flight
/// or awaiting Core Animation commit) and Apple's cross-process
/// `IOSurfaceIsInUse(_:)` contract (for buffers still being read by WindowServer
/// or by detached Vision OCR `CVPixelBuffer`s).
public final class FramebufferSurfacePool: @unchecked Sendable {
    private final class Slot {
        let surface: FramebufferPresentationSurface
        var dirty: FramebufferDirtyRegion

        init(surface: FramebufferPresentationSurface) {
            self.surface = surface
            self.dirty = FramebufferDirtyRegion(full: true)
        }
    }

    private let lock = NSLock()
    private let maximumSlotCount: Int
    private var width = 0
    private var height = 0
    private var slots: [Slot] = []
    private var _lastSyncedPixelCount: Int = 0

    /// Number of currently allocated surfaces (for testing).
    package var allocatedSlotCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return slots.count
    }

    /// Total pixels copied in the most recent `syncNextSurface` call (for testing).
    package var lastSyncedPixelCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _lastSyncedPixelCount
    }

    public init(maximumSlotCount: Int = 4) {
        self.maximumSlotCount = max(2, maximumSlotCount)
    }

    public func reset() {
        lock.lock()
        slots.removeAll(keepingCapacity: false)
        width = 0
        height = 0
        _lastSyncedPixelCount = 0
        lock.unlock()
    }

    /// Record dirty pixel rectangles into every existing slot without touching
    /// any IOSurface memory.
    public func recordDirtyRects(_ rects: [CGRect], width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        if width != self.width || height != self.height {
            resetForGeometryLocked(width: width, height: height)
            return
        }
        guard !rects.isEmpty else { return }
        for slot in slots {
            for rect in rects {
                slot.dirty.insert(rect, boundsWidth: width, boundsHeight: height)
            }
        }
    }

    /// Mark the entire framebuffer dirty across all slots.
    public func markFullDirty(width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        if width != self.width || height != self.height {
            resetForGeometryLocked(width: width, height: height)
            return
        }
        for slot in slots {
            slot.dirty.markFull()
        }
    }

    /// Synchronize the next idle presentation surface from `framebuffer`,
    /// copying only the dirty rectangles accumulated for that slot since its
    /// last sync. Returns `nil` if every slot is currently reserved or in use.
    public func syncNextSurface(
        from framebuffer: Framebuffer,
        excluding displayed: FramebufferPresentationSurface? = nil
    ) -> FramebufferPresentationSurface? {
        syncNextSurface(
            from: framebuffer,
            excluding: displayed.map { [$0] } ?? [])
    }

    /// Synchronize the next idle presentation surface from `framebuffer`,
    /// excluding every surface in `busySurfaces` and every surface currently
    /// reported in use by `IOSurfaceIsInUse(_:)`. Returns `nil` when every slot
    /// is busy or a surface could not be allocated/locked.
    public func syncNextSurface(
        from framebuffer: Framebuffer,
        excluding busySurfaces: [FramebufferPresentationSurface]
    ) -> FramebufferPresentationSurface? {
        switch syncNextSurfaceResult(from: framebuffer, excluding: busySurfaces) {
        case .synced(let surface):
            return surface
        case .allSlotsBusy, .resourceUnavailable:
            return nil
        }
    }

    /// Synchronize the next idle presentation surface from `framebuffer`,
    /// returning a structured ``FramebufferSurfaceSyncResult`` that separates
    /// busy-slot backpressure from resource allocation/lock failures.
    public func syncNextSurfaceResult(
        from framebuffer: Framebuffer,
        excluding busySurfaces: [FramebufferPresentationSurface] = []
    ) -> FramebufferSurfaceSyncResult {
        // Lock ordering is always `Framebuffer.lock` -> `FramebufferSurfacePool.lock`
        // (no other method acquires `Framebuffer.lock`), preventing deadlocks.
        framebuffer.withUnsafeMutablePixelBytes { srcBase, fbW, fbH, srcBytesPerRow, bytesPerPixel in
            lock.lock()
            defer { lock.unlock() }

            guard fbW > 0, fbH > 0 else { return .resourceUnavailable }
            if fbW != width || fbH != height {
                resetForGeometryLocked(width: fbW, height: fbH)
            }

            let slot: Slot
            switch selectSlotLocked(
                width: fbW,
                height: fbH,
                excluding: busySurfaces) {
            case .selected(let chosen):
                slot = chosen
            case .allSlotsBusy(let externallyInUse):
                return .allSlotsBusy(externallyInUse: externallyInUse)
            case .allocationFailed:
                return .resourceUnavailable
            }

            let dirtyRects = slot.dirty.resolvedRects(width: fbW, height: fbH)
            guard !dirtyRects.isEmpty else {
                _lastSyncedPixelCount = 0
                return .synced(slot.surface)
            }

            let srcBytes = srcBase.assumingMemoryBound(to: UInt8.self)
            let copiedPixels: Int?
            if let ioSurface = slot.surface.ioSurface {
                copiedPixels = Self.blitDirtyRects(
                    dirtyRects,
                    srcBytes: srcBytes,
                    srcBytesPerRow: srcBytesPerRow,
                    bytesPerPixel: bytesPerPixel,
                    into: ioSurface)
            } else if let fallback = slot.surface.fallbackPixelBuffer {
                copiedPixels = Self.blitDirtyRects(
                    dirtyRects,
                    srcBytes: srcBytes,
                    srcBytesPerRow: srcBytesPerRow,
                    bytesPerPixel: bytesPerPixel,
                    into: fallback)
            } else {
                copiedPixels = nil
            }

            guard let copiedPixels else { return .resourceUnavailable }
            slot.dirty.clear()
            _lastSyncedPixelCount = copiedPixels
            return .synced(slot.surface)
        }
    }

    /// Create an immutable `CGImage` copy from an existing 32-bit BGRA
    /// `CVPixelBuffer` without touching or locking ``Framebuffer``.
    /// Returns `nil` for non-BGRA, planar, or under-strided pixel buffers.
    public static func makeCGImage(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA,
              !CVPixelBufferIsPlanar(pixelBuffer) else {
            return nil
        }
        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else {
            return nil
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let srcBytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard width > 0, height > 0,
              let srcBase = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return nil
        }
        return makeCGImageFromBGRA(
            srcBase: srcBase,
            width: width,
            height: height,
            srcBytesPerRow: srcBytesPerRow)
    }

    fileprivate static func makeCGImageFromBGRA(
        srcBase: UnsafeRawPointer,
        width: Int,
        height: Int,
        srcBytesPerRow: Int
    ) -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        let (dstBytesPerRow, rowOverflow) = width.multipliedReportingOverflow(by: 4)
        guard !rowOverflow, srcBytesPerRow >= dstBytesPerRow else { return nil }
        let (totalBytes, totalOverflow) = dstBytesPerRow.multipliedReportingOverflow(by: height)
        guard !totalOverflow else { return nil }
        var copy = Data(count: totalBytes)
        copy.withUnsafeMutableBytes { dstBuffer in
            guard let dstBase = dstBuffer.baseAddress else { return }
            if srcBytesPerRow == dstBytesPerRow {
                memcpy(dstBase, srcBase, totalBytes)
            } else {
                for row in 0..<height {
                    memcpy(
                        dstBase.advanced(by: row * dstBytesPerRow),
                        srcBase.advanced(by: row * srcBytesPerRow),
                        dstBytesPerRow)
                }
            }
        }

        guard let provider = CGDataProvider(data: copy as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: dstBytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(
                rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent)
    }

    private func resetForGeometryLocked(width: Int, height: Int) {
        slots.removeAll(keepingCapacity: false)
        self.width = width
        self.height = height
        _lastSyncedPixelCount = 0
    }

    private enum SlotSelection {
        case selected(Slot)
        case allSlotsBusy(externallyInUse: Bool)
        case allocationFailed
    }

    private func selectSlotLocked(
        width: Int,
        height: Int,
        excluding busySurfaces: [FramebufferPresentationSurface]
    ) -> SlotSelection {
        var bestIdle: Slot?
        var bestDirtyPixels = Int.max
        var sawExternalInUse = false
        for slot in slots {
            if busySurfaces.contains(where: { $0 === slot.surface }) { continue }
            if slot.surface.isInUse {
                sawExternalInUse = true
                continue
            }
            let pixels = slot.dirty.estimatedDirtyPixels(width: width, height: height)
            if pixels < bestDirtyPixels {
                bestDirtyPixels = pixels
                bestIdle = slot
            }
        }
        if let bestIdle {
            return .selected(bestIdle)
        }

        if slots.count < maximumSlotCount {
            if let created = allocateSlotLocked(width: width, height: height) {
                slots.append(created)
                return .selected(created)
            }
            return .allocationFailed
        }

        // Every slot is reserved (in-flight handoff, active/previous front
        // buffer) or still in use by an external reader (WindowServer / Core
        // Animation or detached Vision OCR). Never overwrite an in-use slot.
        return .allSlotsBusy(externallyInUse: sawExternalInUse)
    }

    private func allocateSlotLocked(width: Int, height: Int) -> Slot? {
        let bytesPerElement = 4
        let rawRowBytes = width * bytesPerElement
        let alignedRowBytes = Int(IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, rawRowBytes))
        let bytesPerRow = max(rawRowBytes, alignedRowBytes > 0 ? alignedRowBytes : rawRowBytes)
        let allocSize = bytesPerRow * height
        let properties: [String: Any] = [
            kIOSurfaceWidth as String: width,
            kIOSurfaceHeight as String: height,
            kIOSurfaceBytesPerElement as String: bytesPerElement,
            kIOSurfaceBytesPerRow as String: bytesPerRow,
            kIOSurfaceAllocSize as String: allocSize,
            kIOSurfacePixelFormat as String: kCVPixelFormatType_32BGRA,
        ]
        if let ioSurface = IOSurfaceCreate(properties as CFDictionary) {
            return Slot(surface: FramebufferPresentationSurface(
                ioSurface: ioSurface,
                width: width,
                height: height))
        }
        // Fallback for restricted/headless environments where IOSurfaceCreate
        // is unavailable: allocate a plain CPU-backed BGRA CVPixelBuffer.
        var fallbackBuffer: CVPixelBuffer?
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            nil,
            &fallbackBuffer) == kCVReturnSuccess,
              let fallbackBuffer else {
            return nil
        }
        return Slot(surface: FramebufferPresentationSurface(
            fallbackPixelBuffer: fallbackBuffer,
            width: width,
            height: height))
    }

    private static func blitDirtyRects(
        _ dirtyRects: [FramebufferDirtyRegion.IntRect],
        srcBytes: UnsafePointer<UInt8>,
        srcBytesPerRow: Int,
        bytesPerPixel: Int,
        into ioSurface: IOSurfaceRef
    ) -> Int? {
        guard IOSurfaceLock(ioSurface, [], nil) == kIOSurfaceSuccess else {
            return nil
        }
        defer { IOSurfaceUnlock(ioSurface, [], nil) }
        let dstBytes = IOSurfaceGetBaseAddress(ioSurface).assumingMemoryBound(to: UInt8.self)
        let dstBytesPerRow = IOSurfaceGetBytesPerRow(ioSurface)
        return copyRects(
            dirtyRects,
            srcBytes: srcBytes,
            srcBytesPerRow: srcBytesPerRow,
            bytesPerPixel: bytesPerPixel,
            dstBytes: dstBytes,
            dstBytesPerRow: dstBytesPerRow)
    }

    private static func blitDirtyRects(
        _ dirtyRects: [FramebufferDirtyRegion.IntRect],
        srcBytes: UnsafePointer<UInt8>,
        srcBytesPerRow: Int,
        bytesPerPixel: Int,
        into pixelBuffer: CVPixelBuffer
    ) -> Int? {
        guard CVPixelBufferLockBaseAddress(pixelBuffer, []) == kCVReturnSuccess else {
            return nil
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let dstBase = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return nil
        }
        let dstBytes = dstBase.assumingMemoryBound(to: UInt8.self)
        let dstBytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        return copyRects(
            dirtyRects,
            srcBytes: srcBytes,
            srcBytesPerRow: srcBytesPerRow,
            bytesPerPixel: bytesPerPixel,
            dstBytes: dstBytes,
            dstBytesPerRow: dstBytesPerRow)
    }

    private static func copyRects(
        _ dirtyRects: [FramebufferDirtyRegion.IntRect],
        srcBytes: UnsafePointer<UInt8>,
        srcBytesPerRow: Int,
        bytesPerPixel: Int,
        dstBytes: UnsafeMutablePointer<UInt8>,
        dstBytesPerRow: Int
    ) -> Int {
        var copiedPixels = 0
        for rect in dirtyRects {
            let rectW = rect.width
            let rectH = rect.height
            guard rectW > 0, rectH > 0 else { continue }
            copiedPixels += rectW * rectH
            let dstRow0 = dstBytes.advanced(by: rect.minY * dstBytesPerRow + rect.minX * 4)
            if bytesPerPixel == 4 {
                let srcRow0 = srcBytes.advanced(by: rect.minY * srcBytesPerRow + rect.minX * 4)
                rfb_copy_bgrx_to_opaque_bgra(
                    dstRow0,
                    dstBytesPerRow,
                    srcRow0,
                    srcBytesPerRow,
                    Int32(rectW),
                    Int32(rectH))
            } else if bytesPerPixel == 2 {
                let srcRow0 = srcBytes.advanced(by: rect.minY * srcBytesPerRow + rect.minX * 2)
                copyXRGB1555ToOpaqueBGRA(
                    dstRow0: dstRow0,
                    dstStride: dstBytesPerRow,
                    srcRow0: srcRow0,
                    srcStride: srcBytesPerRow,
                    width: rectW,
                    height: rectH)
            }
        }
        return copiedPixels
    }

    private static func copyXRGB1555ToOpaqueBGRA(
        dstRow0: UnsafeMutablePointer<UInt8>,
        dstStride: Int,
        srcRow0: UnsafePointer<UInt8>,
        srcStride: Int,
        width: Int,
        height: Int
    ) {
        for row in 0..<height {
            let src = srcRow0.advanced(by: row * srcStride)
            let dst = dstRow0.advanced(by: row * dstStride)
            for col in 0..<width {
                let lo = UInt16(src[col * 2])
                let hi = UInt16(src[col * 2 + 1])
                let pixel = lo | (hi << 8)
                let r5 = UInt8((pixel >> 10) & 0x1F)
                let g5 = UInt8((pixel >> 5) & 0x1F)
                let b5 = UInt8(pixel & 0x1F)
                let out = col * 4
                dst[out] = (b5 << 3) | (b5 >> 2)
                dst[out + 1] = (g5 << 3) | (g5 >> 2)
                dst[out + 2] = (r5 << 3) | (r5 >> 2)
                dst[out + 3] = 0xFF
            }
        }
    }
}
