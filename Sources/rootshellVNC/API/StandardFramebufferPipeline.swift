import CoreGraphics
import Foundation
import RFBProtocol
import RFBRendering
import RFBTransport

/// Off-MainActor coordinator for Standard-mode (including Apple Adaptive DCT)
/// decoding, dirty-rect IOSurface synchronization, and cadence throttling.
///
/// Runs all persistent codec work and dirty-rect surface copies on a dedicated
/// serial dispatch queue, returns transport credits immediately after decode
/// (without waiting for `@MainActor` or Core Animation), and coalesces
/// presentation handoffs so `@MainActor` only ever commits the newest frame.
final class StandardFramebufferPipeline: @unchecked Sendable {
    struct SideEffects: @unchecked Sendable {
        let generation: UInt64
        let renderer: FramebufferRenderer
        let transport: TransportSession
        let resizedWidth: UInt16?
        let resizedHeight: UInt16?
        let cursorUpdate: RemoteCursorUpdate?
        let issues: [String]
        let slowRenderDiagnostic: String?
    }

    struct PendingSurface: @unchecked Sendable {
        let surface: FramebufferPresentationSurface
        let generation: UInt64
        let renderer: FramebufferRenderer
        let transport: TransportSession
    }

    struct AsyncStreamBatchOutcome: @unchecked Sendable {
        let resizedWidth: UInt16?
        let resizedHeight: UInt16?
        let cursorUpdate: RemoteCursorUpdate?
        let issues: [String]
        let slowRenderDiagnostic: String?
        let hasPendingSurface: Bool
        let shouldScheduleTrailing: Bool
        let trailingDelayNanoseconds: UInt64
    }

    private let queue: DispatchQueue
    private let onSurfaceReady: @Sendable () -> Void
    private let onSideEffects: @Sendable (SideEffects) -> Void

    // Lock-protected configuration and MainActor handoff state.
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var activeRenderer: FramebufferRenderer?
    private var activeTransport: TransportSession?
    private var framebufferWidth: Int = 0
    private var framebufferHeight: Int = 0
    private var displayRegions: [CGRect] = []
    private var targetFrameRate: Int = 60
    private var directSinkArmed = false
    private var isSuspended = false
    private var displayedSurface: FramebufferPresentationSurface?
    private var previousDisplayedSurface: FramebufferPresentationSurface?
    private var drainingSurface: FramebufferPresentationSurface?
    private var pendingSurface: PendingSurface?
    private var surfaceDeliveryScheduled = false
    private var waitingForFreeSurface = false
    private var reservationVersion: UInt64 = 0

    // Accessed exclusively on `queue`.
    private var initialFrameTracker = StandardInitialFramePresentationTracker()
    private var hasPresentablePixels = false
    private var lastPublishAnchorNanos: UInt64 = 0
    private var lastSlowRenderDiagnosticNanos: UInt64 = 0
    private var trailingWorkItem: DispatchWorkItem?
    private var trailingDeadlineNanos: UInt64 = 0
    private var consecutiveExternalBusyRetries = 0
    private var consecutiveResourceFailureRetries = 0

    private static let fastExternalBusyRetries = 8
    private static let maximumExternalBusyRetryDelayNanoseconds: UInt64 = 250_000_000
    private static let maximumResourceFailureRetries = 2
    private static let resourceFailureRetryDelayNanoseconds: UInt64 = 100_000_000

    init(
        queue: DispatchQueue,
        onSurfaceReady: @escaping @Sendable () -> Void,
        onSideEffects: @escaping @Sendable (SideEffects) -> Void
    ) {
        self.queue = queue
        self.onSurfaceReady = onSurfaceReady
        self.onSideEffects = onSideEffects
    }

    func configure(
        generation: UInt64,
        renderer: FramebufferRenderer?,
        transport: TransportSession?,
        width: Int,
        height: Int,
        displayRegions: [CGRect],
        targetFrameRate: Int,
        directSinkArmed: Bool
    ) {
        lock.lock()
        self.generation = generation
        self.activeRenderer = renderer
        self.activeTransport = transport
        self.framebufferWidth = width
        self.framebufferHeight = height
        self.displayRegions = displayRegions
        self.targetFrameRate = max(1, targetFrameRate)
        self.directSinkArmed = directSinkArmed && renderer != nil && transport != nil
        lock.unlock()
    }

    func updateDisplayRegions(_ regions: [CGRect]) {
        lock.lock()
        self.displayRegions = regions
        lock.unlock()
    }

    func updateGeometry(width: Int, height: Int) {
        lock.lock()
        self.framebufferWidth = width
        self.framebufferHeight = height
        lock.unlock()
    }

    func setTargetFrameRate(_ fps: Int) {
        lock.lock()
        self.targetFrameRate = max(1, fps)
        lock.unlock()
    }

    func setDirectSinkArmed(_ armed: Bool) {
        lock.lock()
        self.directSinkArmed = armed && activeRenderer != nil && activeTransport != nil
        lock.unlock()
    }

    func setSuspended(_ suspended: Bool) {
        lock.lock()
        self.isSuspended = suspended
        lock.unlock()
    }

    func finishSurfaceDelivery(
        displayed: FramebufferPresentationSurface?,
        previous: FramebufferPresentationSurface?
    ) {
        lock.lock()
        self.displayedSurface = displayed
        self.previousDisplayedSurface = previous
        self.drainingSurface = nil
        self.reservationVersion &+= 1
        let retryTarget: (UInt64, FramebufferRenderer, TransportSession)?
        if waitingForFreeSurface,
           !isSuspended,
           let renderer = activeRenderer,
           let transport = activeTransport {
            waitingForFreeSurface = false
            retryTarget = (generation, renderer, transport)
        } else {
            retryTarget = nil
        }
        lock.unlock()

        if let (gen, renderer, transport) = retryTarget {
            scheduleReconciliation(
                delayNanoseconds: 0,
                generation: gen,
                renderer: renderer,
                transport: transport)
        }
    }

    func releaseDrainingSurface(allowRetry: Bool) {
        lock.lock()
        self.drainingSurface = nil
        self.reservationVersion &+= 1
        let retryTarget: (UInt64, FramebufferRenderer, TransportSession)?
        if allowRetry,
           waitingForFreeSurface,
           !isSuspended,
           let renderer = activeRenderer,
           let transport = activeTransport {
            waitingForFreeSurface = false
            retryTarget = (generation, renderer, transport)
        } else {
            if !allowRetry {
                waitingForFreeSurface = false
            }
            retryTarget = nil
        }
        lock.unlock()

        if let (gen, renderer, transport) = retryTarget {
            scheduleReconciliation(
                delayNanoseconds: 0,
                generation: gen,
                renderer: renderer,
                transport: transport)
        }
    }

    /// Wake a deferred sync when an asynchronous reader (such as detached
    /// Vision OCR) releases its retained `IOSurface` view.
    func notifyExternalReaderReleased() {
        lock.lock()
        reservationVersion &+= 1
        let retryTarget: (UInt64, FramebufferRenderer, TransportSession)?
        if waitingForFreeSurface,
           !isSuspended,
           let renderer = activeRenderer,
           let transport = activeTransport {
            waitingForFreeSurface = false
            retryTarget = (generation, renderer, transport)
        } else {
            retryTarget = nil
        }
        lock.unlock()

        if let (gen, renderer, transport) = retryTarget {
            scheduleReconciliation(
                delayNanoseconds: 0,
                generation: gen,
                renderer: renderer,
                transport: transport)
        }
    }

    func clearDisplayedSurfaces() {
        lock.lock()
        self.displayedSurface = nil
        self.previousDisplayedSurface = nil
        self.drainingSurface = nil
        self.reservationVersion &+= 1
        lock.unlock()
    }

    func invalidate(newGeneration: UInt64) {
        lock.lock()
        generation = newGeneration
        activeRenderer = nil
        activeTransport = nil
        displayedSurface = nil
        previousDisplayedSurface = nil
        drainingSurface = nil
        directSinkArmed = false
        pendingSurface = nil
        surfaceDeliveryScheduled = false
        waitingForFreeSurface = false
        reservationVersion &+= 1
        lock.unlock()

        queue.async { [self] in
            trailingWorkItem?.cancel()
            trailingWorkItem = nil
            trailingDeadlineNanos = 0
            initialFrameTracker.reset()
            hasPresentablePixels = false
            lastPublishAnchorNanos = 0
            consecutiveExternalBusyRetries = 0
            consecutiveResourceFailureRetries = 0
        }
    }

    /// Direct off-MainActor entry point installed via
    /// `TransportSession.setFramebufferUpdateSink`. Returns `false` whenever
    /// the batch must fall back to the `@MainActor` `AsyncStream` path.
    func enqueueDirect(
        _ rects: [(FramebufferRect, Data)],
        from transport: TransportSession
    ) -> Bool {
        // Desktop resizes mutate session geometry and media renderers on the
        // main actor; keep them strictly ordered through the AsyncStream path
        // so rapid shrink/grow bursts can never race or discard newer frames.
        if rects.contains(where: {
            $0.0.encoding == .desktopSize || $0.0.encoding == .extendedDesktopSize
        }) {
            return false
        }
        lock.lock()
        guard directSinkArmed,
              activeTransport === transport,
              let renderer = activeRenderer else {
            lock.unlock()
            return false
        }
        let gen = generation
        lock.unlock()

        queue.async { [self] in
            processDirectBatch(
                rects,
                generation: gen,
                renderer: renderer,
                transport: transport)
        }
        return true
    }

    /// Fallback path used when updates arrive through `TransportSession.events`
    /// (e.g., protocol tracing enabled, pre-geometry deferral, or layout
    /// updates). Shares all codec, initial-coverage, and cadence state on
    /// `queue` with `enqueueDirect`.
    func processAsyncStreamBatch(
        _ rects: [(FramebufferRect, Data)],
        generation: UInt64,
        renderer: FramebufferRenderer,
        transport: TransportSession,
        displaySuspended: Bool
    ) async -> AsyncStreamBatchOutcome {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                continuation.resume(returning: runAsyncStreamBatchOnQueue(
                    rects,
                    generation: generation,
                    renderer: renderer,
                    transport: transport,
                    displaySuspended: displaySuspended))
            }
        }
    }

    /// Schedule a trailing surface sync on `queue` (for example after
    /// suspension clears or a busy surface slot is released).
    func scheduleReconciliation(
        delayNanoseconds: UInt64 = 0,
        generation: UInt64,
        renderer: FramebufferRenderer,
        transport: TransportSession
    ) {
        queue.async { [self] in
            scheduleTrailingSyncOnQueue(
                delayNanoseconds: delayNanoseconds,
                generation: generation,
                renderer: renderer,
                transport: transport)
        }
    }

    /// Atomically pop the latest coalesced surface ready for `@MainActor`
    /// presentation, keeping it reserved until `finishSurfaceDelivery` or
    /// `releaseDrainingSurface` runs.
    func drainPendingSurface() -> PendingSurface? {
        lock.lock()
        let surface = pendingSurface
        pendingSurface = nil
        surfaceDeliveryScheduled = false
        drainingSurface = surface?.surface
        lock.unlock()
        return surface
    }

    private func reservedSurfacesLocked() -> [FramebufferPresentationSurface] {
        var reserved: [FramebufferPresentationSurface] = []
        reserved.reserveCapacity(4)
        if let displayedSurface { reserved.append(displayedSurface) }
        if let previousDisplayedSurface { reserved.append(previousDisplayedSurface) }
        if let pending = pendingSurface?.surface { reserved.append(pending) }
        if let drainingSurface { reserved.append(drainingSurface) }
        return reserved
    }

    private enum SyncOutcome {
        case synced(FramebufferPresentationSurface)
        case retryAfter(UInt64)
        case stop
    }

    /// Synchronize an idle surface on `queue` without a missed-wakeup race:
    /// if all slots are busy, recheck `reservationVersion` under `lock` before
    /// arming `waitingForFreeSurface`. Distinct resource failures (allocation
    /// or lock errors) use a strict bounded retry cap rather than looping
    /// indefinitely at the target frame rate, while external-reader pins
    /// (`IOSurfaceIsInUse`) back off smoothly until the reader releases.
    private func syncIdleSurfaceOnQueue(
        generation: UInt64,
        renderer: FramebufferRenderer,
        transport: TransportSession,
        publishInterval: UInt64
    ) -> SyncOutcome {
        while true {
            lock.lock()
            guard self.generation == generation,
                  self.activeRenderer === renderer,
                  self.activeTransport === transport,
                  !self.isSuspended else {
                lock.unlock()
                return .stop
            }
            let reserved = reservedSurfacesLocked()
            let versionBefore = reservationVersion
            lock.unlock()

            switch renderer.syncPresentationSurfaceResult(excluding: reserved) {
            case .synced(let surface):
                consecutiveExternalBusyRetries = 0
                consecutiveResourceFailureRetries = 0
                return .synced(surface)

            case .allSlotsBusy(let externallyInUse):
                lock.lock()
                guard self.generation == generation,
                      self.activeRenderer === renderer,
                      self.activeTransport === transport,
                      !self.isSuspended else {
                    lock.unlock()
                    return .stop
                }
                if self.reservationVersion != versionBefore {
                    // MainActor or an external reader released a slot while we
                    // were checking; retry immediately instead of sleeping.
                    lock.unlock()
                    continue
                }
                // No release occurred since our snapshot; arming the waiter
                // here guarantees the next delivery or reader release sees
                // `waitingForFreeSurface`.
                waitingForFreeSurface = true
                lock.unlock()
                if externallyInUse {
                    consecutiveExternalBusyRetries &+= 1
                    let delay: UInt64
                    if consecutiveExternalBusyRetries <= Self.fastExternalBusyRetries {
                        delay = publishInterval
                    } else {
                        let shift = min(4, consecutiveExternalBusyRetries - Self.fastExternalBusyRetries)
                        let backedOff = max(publishInterval, 50_000_000) << UInt64(shift - 1)
                        delay = min(backedOff, Self.maximumExternalBusyRetryDelayNanoseconds)
                    }
                    return .retryAfter(delay)
                }
                return .stop

            case .resourceUnavailable:
                // Never treat a surface allocation or lock failure as an
                // externally busy slot; retry at most a small bounded number
                // of times with backoff so an idle desktop never spins.
                if consecutiveResourceFailureRetries < Self.maximumResourceFailureRetries {
                    consecutiveResourceFailureRetries += 1
                    return .retryAfter(max(publishInterval, Self.resourceFailureRetryDelayNanoseconds))
                }
                return .stop
            }
        }
    }

    // MARK: - Serial Render Queue Implementation

    private func processDirectBatch(
        _ rects: [(FramebufferRect, Data)],
        generation: UInt64,
        renderer: FramebufferRenderer,
        transport: TransportSession
    ) {
        lock.lock()
        let isCurrent = self.generation == generation
            && self.activeRenderer === renderer
            && self.activeTransport === transport
        let fbWidth = self.framebufferWidth
        let fbHeight = self.framebufferHeight
        let regions = self.displayRegions
        let fps = self.targetFrameRate
        let suspended = self.isSuspended
        lock.unlock()

        let renderStarted = DispatchTime.now().uptimeNanoseconds
        let result = renderer.applyBatch(rects, snapshot: false)

        // Return transport credit immediately on decode completion so TCP
        // reads of subsequent refinement bands overlap with presentation.
        if isCurrent {
            Task {
                try? await transport.finishDirectFramebufferUpdate()
            }
        }
        guard isCurrent else { return }

        let effectiveWidth = result.resizedWidth.map(Int.init) ?? fbWidth
        let effectiveHeight = result.resizedHeight.map(Int.init) ?? fbHeight
        if result.resizedWidth != nil || result.resizedHeight != nil {
            lock.lock()
            if self.generation == generation {
                self.framebufferWidth = effectiveWidth
                self.framebufferHeight = effectiveHeight
            }
            lock.unlock()
        }

        let carriesPixels = StandardFramebufferPresentationPolicy
            .carriesFramebufferPixels(rects)
        let initialAllowed = initialFrameTracker.ingest(
            rects,
            framebufferWidth: effectiveWidth,
            framebufferHeight: effectiveHeight,
            displayRegions: regions)
        if carriesPixels && initialAllowed {
            hasPresentablePixels = true
        }

        let slowDiagnostic = slowRenderDiagnosticIfNeeded(
            renderStarted: renderStarted,
            rects: rects)
        if result.resizedWidth != nil
            || result.cursorUpdate != nil
            || !result.issues.isEmpty
            || slowDiagnostic != nil {
            onSideEffects(SideEffects(
                generation: generation,
                renderer: renderer,
                transport: transport,
                resizedWidth: result.resizedWidth,
                resizedHeight: result.resizedHeight,
                cursorUpdate: result.cursorUpdate,
                issues: result.issues,
                slowRenderDiagnostic: slowDiagnostic))
        }

        let publishInterval = UInt64(1_000_000_000 / max(1, fps))
        let publishDue = lastPublishAnchorNanos == 0
            || (renderStarted &- lastPublishAnchorNanos >= publishInterval)

        if carriesPixels && initialAllowed && !suspended && publishDue {
            trailingWorkItem?.cancel()
            trailingWorkItem = nil
            trailingDeadlineNanos = 0
            consecutiveExternalBusyRetries = 0
            consecutiveResourceFailureRetries = 0
            switch syncIdleSurfaceOnQueue(
                generation: generation,
                renderer: renderer,
                transport: transport,
                publishInterval: publishInterval) {
            case .synced(let surface):
                lastPublishAnchorNanos = renderStarted
                enqueueCoalescedSurface(
                    surface,
                    generation: generation,
                    renderer: renderer,
                    transport: transport,
                    wakeMainActor: true)
            case .retryAfter(let delay):
                scheduleTrailingSyncOnQueue(
                    delayNanoseconds: delay,
                    generation: generation,
                    renderer: renderer,
                    transport: transport)
            case .stop:
                break
            }
        } else if carriesPixels && initialAllowed && !suspended {
            let now = DispatchTime.now().uptimeNanoseconds
            let elapsed = lastPublishAnchorNanos == 0 ? publishInterval : (now &- lastPublishAnchorNanos)
            let delay = publishInterval &- min(publishInterval, elapsed)
            scheduleTrailingSyncOnQueue(
                delayNanoseconds: delay,
                generation: generation,
                renderer: renderer,
                transport: transport)
        }
    }

    private func runAsyncStreamBatchOnQueue(
        _ rects: [(FramebufferRect, Data)],
        generation: UInt64,
        renderer: FramebufferRenderer,
        transport: TransportSession,
        displaySuspended: Bool
    ) -> AsyncStreamBatchOutcome {
        lock.lock()
        let isCurrent = self.generation == generation
            && self.activeRenderer === renderer
            && self.activeTransport === transport
        let fbWidth = self.framebufferWidth
        let fbHeight = self.framebufferHeight
        let regions = self.displayRegions
        let fps = self.targetFrameRate
        let suspended = displaySuspended || self.isSuspended
        lock.unlock()

        let renderStarted = DispatchTime.now().uptimeNanoseconds
        let result = renderer.applyBatch(rects, snapshot: false)
        let publishInterval = UInt64(1_000_000_000 / max(1, fps))

        guard isCurrent else {
            return AsyncStreamBatchOutcome(
                resizedWidth: result.resizedWidth,
                resizedHeight: result.resizedHeight,
                cursorUpdate: result.cursorUpdate,
                issues: result.issues,
                slowRenderDiagnostic: nil,
                hasPendingSurface: false,
                shouldScheduleTrailing: false,
                trailingDelayNanoseconds: publishInterval)
        }

        let effectiveWidth = result.resizedWidth.map(Int.init) ?? fbWidth
        let effectiveHeight = result.resizedHeight.map(Int.init) ?? fbHeight
        if result.resizedWidth != nil || result.resizedHeight != nil {
            lock.lock()
            if self.generation == generation {
                self.framebufferWidth = effectiveWidth
                self.framebufferHeight = effectiveHeight
            }
            lock.unlock()
        }

        let carriesPixels = StandardFramebufferPresentationPolicy
            .carriesFramebufferPixels(rects)
        let initialAllowed = initialFrameTracker.ingest(
            rects,
            framebufferWidth: effectiveWidth,
            framebufferHeight: effectiveHeight,
            displayRegions: regions)
        if carriesPixels && initialAllowed {
            hasPresentablePixels = true
        }

        let slowDiagnostic = slowRenderDiagnosticIfNeeded(
            renderStarted: renderStarted,
            rects: rects)

        let publishDue = lastPublishAnchorNanos == 0
            || (renderStarted &- lastPublishAnchorNanos >= publishInterval)

        var hasPendingSurface = false
        var shouldScheduleTrailing = false
        var trailingDelay = publishInterval
        if carriesPixels && initialAllowed && !suspended && publishDue {
            trailingWorkItem?.cancel()
            trailingWorkItem = nil
            trailingDeadlineNanos = 0
            consecutiveExternalBusyRetries = 0
            consecutiveResourceFailureRetries = 0
            switch syncIdleSurfaceOnQueue(
                generation: generation,
                renderer: renderer,
                transport: transport,
                publishInterval: publishInterval) {
            case .synced(let synced):
                lastPublishAnchorNanos = renderStarted
                // Route through the same single coalescing handoff slot as the
                // direct path so switching paths can never present an older
                // frame over a newer one or clobber a shared draining reservation.
                enqueueCoalescedSurface(
                    synced,
                    generation: generation,
                    renderer: renderer,
                    transport: transport,
                    wakeMainActor: false)
                hasPendingSurface = true
            case .retryAfter(let delay):
                shouldScheduleTrailing = true
                trailingDelay = delay
            case .stop:
                break
            }
        } else if carriesPixels && initialAllowed && !suspended {
            let now = DispatchTime.now().uptimeNanoseconds
            let elapsed = lastPublishAnchorNanos == 0 ? publishInterval : (now &- lastPublishAnchorNanos)
            trailingDelay = publishInterval &- min(publishInterval, elapsed)
            shouldScheduleTrailing = true
        }

        return AsyncStreamBatchOutcome(
            resizedWidth: result.resizedWidth,
            resizedHeight: result.resizedHeight,
            cursorUpdate: result.cursorUpdate,
            issues: result.issues,
            slowRenderDiagnostic: slowDiagnostic,
            hasPendingSurface: hasPendingSurface,
            shouldScheduleTrailing: shouldScheduleTrailing,
            trailingDelayNanoseconds: trailingDelay)
    }

    private func scheduleTrailingSyncOnQueue(
        delayNanoseconds: UInt64,
        generation: UInt64,
        renderer: FramebufferRenderer,
        transport: TransportSession
    ) {
        guard hasPresentablePixels,
              !initialFrameTracker.suppressesPresentation else { return }

        let now = DispatchTime.now().uptimeNanoseconds
        let requestedDeadline = delayNanoseconds == 0 ? now : (now &+ delayNanoseconds)
        if let existing = trailingWorkItem {
            // Keep an already-sooner retry; only replace if the new request
            // brings the deadline forward (e.g., an immediate reader-release
            // wakeup superseding a delayed backoff timer).
            guard requestedDeadline < trailingDeadlineNanos else { return }
            existing.cancel()
            trailingWorkItem = nil
            trailingDeadlineNanos = 0
        }

        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.trailingWorkItem = nil
            self.trailingDeadlineNanos = 0
            self.lock.lock()
            let fps = self.targetFrameRate
            self.lock.unlock()
            let publishInterval = UInt64(1_000_000_000 / max(1, fps))

            guard self.hasPresentablePixels,
                  !self.initialFrameTracker.suppressesPresentation else { return }

            switch self.syncIdleSurfaceOnQueue(
                generation: generation,
                renderer: renderer,
                transport: transport,
                publishInterval: publishInterval) {
            case .synced(let surface):
                self.lastPublishAnchorNanos = DispatchTime.now().uptimeNanoseconds
                self.enqueueCoalescedSurface(
                    surface,
                    generation: generation,
                    renderer: renderer,
                    transport: transport,
                    wakeMainActor: true)
            case .retryAfter(let delay):
                self.scheduleTrailingSyncOnQueue(
                    delayNanoseconds: delay,
                    generation: generation,
                    renderer: renderer,
                    transport: transport)
            case .stop:
                break
            }
        }
        trailingWorkItem = item
        trailingDeadlineNanos = requestedDeadline
        if delayNanoseconds == 0 {
            queue.async(execute: item)
        } else {
            let deadline = DispatchTime(uptimeNanoseconds: requestedDeadline)
            queue.asyncAfter(deadline: deadline, execute: item)
        }
    }

    private func enqueueCoalescedSurface(
        _ surface: FramebufferPresentationSurface,
        generation: UInt64,
        renderer: FramebufferRenderer,
        transport: TransportSession,
        wakeMainActor: Bool
    ) {
        lock.lock()
        guard self.generation == generation,
              self.activeRenderer === renderer,
              self.activeTransport === transport else {
            lock.unlock()
            return
        }
        waitingForFreeSurface = false
        pendingSurface = PendingSurface(
            surface: surface,
            generation: generation,
            renderer: renderer,
            transport: transport)
        let shouldWake = wakeMainActor && !surfaceDeliveryScheduled
        if shouldWake {
            surfaceDeliveryScheduled = true
        }
        lock.unlock()

        if shouldWake {
            onSurfaceReady()
        }
    }

    private func slowRenderDiagnosticIfNeeded(
        renderStarted: UInt64,
        rects: [(FramebufferRect, Data)]
    ) -> String? {
        let renderFinished = DispatchTime.now().uptimeNanoseconds
        let renderMilliseconds = (renderFinished &- renderStarted) / 1_000_000
        guard renderMilliseconds >= 100,
              lastSlowRenderDiagnosticNanos == 0
                || renderFinished &- lastSlowRenderDiagnosticNanos >= 1_000_000_000 else {
            return nil
        }
        lastSlowRenderDiagnosticNanos = renderFinished
        let payloadBytes = rects.reduce(0) { $0 + $1.1.count }
        let encodings = rects.map { String(describing: $0.0.encoding) }
            .joined(separator: ",")
        return "Framebuffer decode/sync=\(renderMilliseconds)ms "
            + "rects=\(rects.count) payload=\(payloadBytes)B "
            + "encodings=\(encodings)"
    }
}
