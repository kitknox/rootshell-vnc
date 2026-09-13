import SwiftUI
import CoreImage
import CoreVideo
import RFBProtocol
import RFBTransport
import RFBRendering
#if canImport(UIKit)
import UIKit
#endif

private actor MediaRecoveryCoordinator {
    private var active = false

    func begin() -> Bool {
        guard !active else { return false }
        active = true
        return true
    }

    func finish() {
        active = false
    }
}

/// Union the selected leading displays and translate the result into the
/// framebuffer's normalized coordinate space.
func normalizedSelectedDisplayRegion(
    _ regions: [CGRect],
    displayCount: Int
) -> CGRect? {
    guard let first = regions.first else { return nil }
    let all = regions.dropFirst().reduce(first) { $0.union($1) }
    let count = min(max(1, displayCount), regions.count)
    let selected = regions.prefix(count).dropFirst().reduce(first) {
        $0.union($1)
    }
    return selected.offsetBy(dx: -all.minX, dy: -all.minY)
}

/// Edge detector for Apple Login Window announcements. DisplayInfo2 is sent
/// repeatedly while a layout is stable, but a password prompt should only be
/// offered once per entry into the login or lock-screen state.
struct AppleLoginPromptTransitionTracker {
    private(set) var isLoginActive = false

    mutating func update(
        isLoginActive newValue: Bool,
        promptEnabled: Bool,
        canSendPassword: Bool
    ) -> Bool {
        let enteredLogin = newValue && !isLoginActive
        isLoginActive = newValue
        return enteredLogin && promptEnabled && canSendPassword
    }

    mutating func reset() {
        isLoginActive = false
    }
}

/// Holds one user-approved password-send intent across Match Client display
/// transitions. A token is valid only for the latest requested display target
/// and latest complete High Performance media generation.
struct LoginPasswordSendStabilityGate {
    struct Token: Sendable, Equatable {
        let displayRevision: UInt64
        let mediaGeneration: UInt64
    }

    private(set) var isPending = false
    private(set) var displayRevision: UInt64 = 0
    private(set) var stableCandidate: Token?
    private(set) var isTransportSettled = false
    /// Media generation of the newest final-size frame, retained across
    /// settlement edges so a commit that raced the settled signal can be
    /// revalidated by generation instead of discarded by arrival order.
    private(set) var latestEligibleFrameGeneration: UInt64?

    mutating func requestSend() -> Token? {
        isPending = true
        return isTransportSettled ? stableCandidate : nil
    }

    mutating func displayTargetChanged() {
        displayRevision &+= 1
        isTransportSettled = false
        stableCandidate = nil
        latestEligibleFrameGeneration = nil
    }

    mutating func transportSettled(_ settled: Bool) {
        guard settled != isTransportSettled else { return }
        isTransportSettled = settled
        // A frame committed before the transport finished draining queued
        // resize commands may belong to the capture graph being retired.
        displayRevision &+= 1
        stableCandidate = nil
    }

    /// A static Login Window may never commit another frame after the settled
    /// signal arrives, so waiting for one deadlocks the send. A frame that
    /// committed just before settlement is safe to reuse when it belongs to
    /// the media generation that is still live: the capture graph that
    /// produced it was not retired by the resize.
    mutating func adoptRetainedFrame(liveMediaGeneration: UInt64) -> Token? {
        guard isTransportSettled,
              stableCandidate == nil,
              latestEligibleFrameGeneration == liveMediaGeneration else {
            return nil
        }
        let token = Token(
            displayRevision: displayRevision,
            mediaGeneration: liveMediaGeneration)
        stableCandidate = token
        return isPending ? token : nil
    }

    /// A media generation replacement (server capture restart) retires every
    /// frame and any armed token without necessarily producing a settle edge:
    /// only a frame from the replacement generation may validate a send.
    mutating func mediaGenerationChanged() {
        displayRevision &+= 1
        stableCandidate = nil
        latestEligibleFrameGeneration = nil
    }

    mutating func noteEligibleFrame(mediaGeneration: UInt64) -> Token? {
        latestEligibleFrameGeneration = mediaGeneration
        guard isTransportSettled else { return nil }
        let token = Token(
            displayRevision: displayRevision,
            mediaGeneration: mediaGeneration)
        stableCandidate = token
        return isPending ? token : nil
    }

    mutating func consume(_ token: Token) -> Bool {
        guard isPending, stableCandidate == token else { return false }
        isPending = false
        return true
    }

    /// Deliver an explicit user request whose stability signals never
    /// converged. Callers are expected to have exhausted bounded retries
    /// first; an unconsumed pending click must not stay silent forever.
    mutating func forceConsumePending() -> Bool {
        guard isPending else { return false }
        isPending = false
        return true
    }

    /// Transport-scoped state always resets; the pending flag is the user's
    /// approval, not transport state, so an automatic reconnect preserves it
    /// and delivers once the replacement connection stabilizes.
    mutating func reset(preservePendingSend: Bool = false) {
        if !preservePendingSend {
            isPending = false
        }
        isTransportSettled = false
        displayRevision &+= 1
        stableCandidate = nil
        latestEligibleFrameGeneration = nil
    }
}

/// Assigns a monotonic sequence to sink emissions on the emitting executor so
/// a main-actor observer can drop hops that arrive out of order. Unstructured
/// `Task` hops preserve no ordering; a reordered settled=false landing after
/// its settled=true would otherwise latch a gate closed indefinitely.
final class SinkEventSequencer: @unchecked Sendable {
    private let lock = NSLock()
    private var lastValue: UInt64 = 0

    func next() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        lastValue &+= 1
        return lastValue
    }
}

private enum AppleLoginVisionFrame: @unchecked Sendable {
    case image(CGImage)
    case pixelBuffer(CVPixelBuffer)
}

private struct AppleLoginVisionOutcome: Sendable {
    let analysis: AppleLoginTextAnalysis?
    let errorDescription: String?
    let elapsedMilliseconds: UInt64
}

/// Tracks the portions of Apple DCT type-0 base images that have not yet been
/// covered by type-1 refinement rectangles. A large base is commonly followed
/// by many horizontal bands, not one refinement message.
struct AppleDCTRefinementTracker {
    private(set) var uncoveredRegions: [CGRect] = []

    var isAwaitingRefinement: Bool { !uncoveredRegions.isEmpty }

    mutating func reset() {
        uncoveredRegions.removeAll(keepingCapacity: true)
    }

    @discardableResult
    mutating func ingest(
        _ rects: [(FramebufferRect, Data)]
    ) -> Bool {
        for (rect, payload) in rects {
            let region = CGRect(
                x: Int(rect.x), y: Int(rect.y),
                width: Int(rect.width), height: Int(rect.height))
            guard !region.isEmpty else { continue }

            if rect.encoding == .appleMultiVariantScreenshare,
               payload.count >= 5 {
                switch payload[payload.startIndex + 4] {
                case 0: markBase(region)
                case 1: markRefined(region)
                default: break
                }
                continue
            }

            switch rect.encoding {
            case .raw, .zlib, .zrle, .tight, .copyRect:
                // A portable pixel rectangle supersedes any coarse DCT pixels
                // in the same region and needs no progressive refinement.
                markRefined(region)
            case .desktopSize, .extendedDesktopSize:
                reset()
            default:
                break
            }
        }
        return isAwaitingRefinement
    }

    private mutating func markBase(_ region: CGRect) {
        // A newer base replaces any older pending pixels in its area.
        uncoveredRegions = uncoveredRegions.flatMap {
            Self.subtract(region, from: $0)
        }
        uncoveredRegions.append(region)
    }

    private mutating func markRefined(_ region: CGRect) {
        uncoveredRegions = uncoveredRegions.flatMap {
            Self.subtract(region, from: $0)
        }
    }

    private static func subtract(
        _ coverage: CGRect,
        from source: CGRect
    ) -> [CGRect] {
        let intersection = source.intersection(coverage)
        guard !intersection.isNull, !intersection.isEmpty else {
            return [source]
        }
        guard intersection != source else { return [] }

        var remainder: [CGRect] = []
        if source.minY < intersection.minY {
            remainder.append(CGRect(
                x: source.minX, y: source.minY,
                width: source.width,
                height: intersection.minY - source.minY))
        }
        if intersection.maxY < source.maxY {
            remainder.append(CGRect(
                x: source.minX, y: intersection.maxY,
                width: source.width,
                height: source.maxY - intersection.maxY))
        }
        if source.minX < intersection.minX {
            remainder.append(CGRect(
                x: source.minX, y: intersection.minY,
                width: intersection.minX - source.minX,
                height: intersection.height))
        }
        if intersection.maxX < source.maxX {
            remainder.append(CGRect(
                x: intersection.maxX, y: intersection.minY,
                width: source.maxX - intersection.maxX,
                height: intersection.height))
        }
        return remainder
    }
}

enum StandardFramebufferPresentationPolicy {
    static func carriesFramebufferPixels(
        _ rects: [(FramebufferRect, Data)]
    ) -> Bool {
        rects.contains { rect, payload in
            if rect.encoding == .appleMultiVariantScreenshare {
                guard payload.count >= 5 else { return false }
                let messageType = payload[payload.startIndex + 4]
                return messageType == 0 || messageType == 1
            }
            switch rect.encoding {
            case .raw, .zlib, .zrle, .tight, .copyRect:
                return true
            default:
                return false
            }
        }
    }
}

/// Prevents a newly allocated framebuffer from being presented after only a
/// regional DCT bootstrap update. The decoder still applies every rectangle in
/// wire order; this gate affects only the first snapshot. Once initial type-0
/// or portable-pixel coverage spans the framebuffer, normal progressive
/// presentation remains enabled for the lifetime of the connection.
struct StandardInitialFramePresentationTracker {
    private(set) var uncoveredRegions: [CGRect] = []
    private var detectedDCTBootstrap = false
    private var completedInitialFrame = false
    private var trackedSize: CGSize = .zero

    var suppressesPresentation: Bool {
        detectedDCTBootstrap && !completedInitialFrame
    }

    mutating func reset() {
        uncoveredRegions.removeAll(keepingCapacity: true)
        detectedDCTBootstrap = false
        completedInitialFrame = false
        trackedSize = .zero
    }

    mutating func ingest(
        _ rects: [(FramebufferRect, Data)],
        framebufferWidth: Int,
        framebufferHeight: Int
    ) -> Bool {
        guard !completedInitialFrame else { return true }

        let resized = rects.compactMap { rect, _ -> CGSize? in
            guard (rect.encoding == .desktopSize
                    || rect.encoding == .extendedDesktopSize),
                  rect.isSuccessfulDesktopResize,
                  rect.width > 0, rect.height > 0 else { return nil }
            return CGSize(width: Int(rect.width), height: Int(rect.height))
        }.last
        let size = resized ?? CGSize(
            width: framebufferWidth,
            height: framebufferHeight)
        guard size.width > 0, size.height > 0 else {
            return !suppressesPresentation
        }

        let containsDCTBootstrap = rects.contains { rect, payload in
            guard rect.encoding == .appleMultiVariantScreenshare,
                  payload.count >= 5 else { return false }
            let type = payload[payload.startIndex + 4]
            return type == 0 || type == 1 || type == 2
        }
        if !detectedDCTBootstrap {
            guard containsDCTBootstrap else { return true }
            detectedDCTBootstrap = true
            trackedSize = size
            uncoveredRegions = [CGRect(origin: .zero, size: size)]
        } else if trackedSize != size {
            trackedSize = size
            uncoveredRegions = [CGRect(origin: .zero, size: size)]
        }

        for (rect, payload) in rects {
            let establishesPixels: Bool
            if rect.encoding == .appleMultiVariantScreenshare {
                establishesPixels = payload.count >= 5
                    && payload[payload.startIndex + 4] == 0
            } else {
                switch rect.encoding {
                case .raw, .zlib, .zrle, .tight:
                    establishesPixels = true
                default:
                    establishesPixels = false
                }
            }
            guard establishesPixels else { continue }
            let coverage = CGRect(
                x: Int(rect.x), y: Int(rect.y),
                width: Int(rect.width), height: Int(rect.height))
                .intersection(CGRect(origin: .zero, size: trackedSize))
            guard !coverage.isNull, !coverage.isEmpty else { continue }
            uncoveredRegions = uncoveredRegions.flatMap {
                Self.subtract(coverage, from: $0)
            }
        }

        if uncoveredRegions.isEmpty {
            completedInitialFrame = true
        }
        return completedInitialFrame
    }

    private static func subtract(
        _ coverage: CGRect,
        from source: CGRect
    ) -> [CGRect] {
        let intersection = source.intersection(coverage)
        guard !intersection.isNull, !intersection.isEmpty else {
            return [source]
        }
        guard intersection != source else { return [] }

        var remainder: [CGRect] = []
        if source.minY < intersection.minY {
            remainder.append(CGRect(
                x: source.minX, y: source.minY,
                width: source.width,
                height: intersection.minY - source.minY))
        }
        if intersection.maxY < source.maxY {
            remainder.append(CGRect(
                x: source.minX, y: intersection.maxY,
                width: source.width,
                height: source.maxY - intersection.maxY))
        }
        if source.minX < intersection.minX {
            remainder.append(CGRect(
                x: source.minX, y: intersection.minY,
                width: intersection.minX - source.minX,
                height: intersection.height))
        }
        if intersection.maxX < source.maxX {
            remainder.append(CGRect(
                x: intersection.maxX, y: intersection.minY,
                width: source.maxX - intersection.maxX,
                height: intersection.height))
        }
        return remainder
    }
}

/// Synchronizes video presentation with the remote audio playback clock.
/// RTCP Sender Reports place both RTP streams on the server's NTP clock, while
/// `AppleRemoteAudioPlayer` supplies the corresponding local playback point.
/// The result is an absolute deadline for each compressed video packet.
final class AppleMediaPlaybackSynchronizer: @unchecked Sendable {
    private let lock = NSLock()
    private var senderClocks: [UInt32: AppleMediaSenderClockMapping] = [:]
    private var audioTiming: AppleRemoteAudioPlaybackTiming?

    /// Feed compressed video shortly before its synchronized presentation
    /// point, leaving VideoToolbox and the main-thread renderer their measured
    /// decode/presentation lead.
    static let videoPipelineLeadNanos: UInt64 = 8_000_000
    private static let maximumSynchronizedDelayNanos: UInt64 = 500_000_000
    private static let ntpFractionScale = 4_294_967_296.0

    func reset() {
        lock.lock()
        senderClocks.removeAll(keepingCapacity: true)
        audioTiming = nil
        lock.unlock()
    }

    func noteSenderClock(_ mapping: AppleMediaSenderClockMapping) {
        lock.lock()
        senderClocks[mapping.remoteSSRC] = mapping
        lock.unlock()
    }

    func noteAudioPlayback(_ timing: AppleRemoteAudioPlaybackTiming) {
        lock.lock()
        audioTiming = timing
        lock.unlock()
    }

    func videoDelayNanos(
        for packet: Data,
        fallbackNanos: UInt64,
        nowNanos: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> UInt64 {
        guard let header = Self.rtpHeader(packet) else { return fallbackNanos }

        lock.lock()
        let videoClock = senderClocks[header.ssrc]
        let timing = audioTiming
        let audioClock = timing.flatMap { senderClocks[$0.ssrc] }
        lock.unlock()

        guard let videoClock, let timing, let audioClock else {
            return fallbackNanos
        }
        let audioMediaTime = Self.mediaTimeSeconds(
            rtpTimestamp: timing.rtpTimestamp,
            clockRate: Double(AppleRemoteAudioRTPDepacketizer.sampleRate),
            senderClock: audioClock)
        let videoMediaTime = Self.mediaTimeSeconds(
            rtpTimestamp: header.timestamp,
            clockRate: 24_000,
            senderClock: videoClock)
        let mediaDeltaNanos = (videoMediaTime - audioMediaTime) * 1_000_000_000
        guard mediaDeltaNanos.isFinite,
              mediaDeltaNanos >= Double(Int64.min),
              mediaDeltaNanos <= Double(Int64.max) else {
            return fallbackNanos
        }

        let target = Int64(clamping: timing.hostTimeNanos)
            + Int64(mediaDeltaNanos.rounded())
            - Int64(Self.videoPipelineLeadNanos)
        let now = Int64(clamping: nowNanos)
        guard target > now else { return 0 }
        let delay = UInt64(target - now)
        guard delay <= Self.maximumSynchronizedDelayNanos else {
            return fallbackNanos
        }
        return delay
    }

    private static func mediaTimeSeconds(
        rtpTimestamp: UInt32,
        clockRate: Double,
        senderClock: AppleMediaSenderClockMapping
    ) -> Double {
        let ntp = Double(senderClock.ntpTimestamp) / ntpFractionScale
        let delta = Int32(bitPattern: rtpTimestamp &- senderClock.rtpTimestamp)
        return ntp + Double(delta) / clockRate
    }

    private static func rtpHeader(
        _ packet: Data
    ) -> (timestamp: UInt32, ssrc: UInt32)? {
        guard packet.count >= 12 else { return nil }
        let base = packet.startIndex
        guard packet[base] >> 6 == 2 else { return nil }
        let timestamp = UInt32(packet[base + 4]) << 24
            | UInt32(packet[base + 5]) << 16
            | UInt32(packet[base + 6]) << 8
            | UInt32(packet[base + 7])
        let ssrc = UInt32(packet[base + 8]) << 24
            | UInt32(packet[base + 9]) << 16
            | UInt32(packet[base + 10]) << 8
            | UInt32(packet[base + 11])
        return (timestamp, ssrc)
    }
}

/// Coalesces the transport's per-packet callback into ordered media-queue
/// batches. A fullscreen reference picture can contain thousands of RTP
/// packets; scheduling one Dispatch block for each packet creates avoidable
/// allocator and queue pressure before the demuxer does any useful work.
final class OrderedMediaPacketCoalescer: @unchecked Sendable {
    private struct PendingPacket {
        let deadlineNanos: UInt64
        let data: Data
    }

    private let queue: DispatchQueue
    private let consume: @Sendable ([Data]) -> Void
    private let delayNanos: @Sendable (Data) -> UInt64
    private let lock = NSLock()
    private var pending: [PendingPacket] = []
    /// Logical start of the live queue. Removing the first element from a
    /// Swift Array shifts every remaining packet, which is particularly
    /// expensive while holding 100–240 ms of a multi-thousand-packet stream.
    /// Advance this cursor for ordinary drains and compact only occasionally.
    private var pendingHead = 0
    private var drainScheduled = false
    private var lastDeadlineNanos: UInt64 = 0
    private var scheduleGeneration: UInt64 = 0
    /// Packet callbacks for one access unit arrive in a tight burst. Treat
    /// deadlines within 1 ms as one batch rather than scheduling thousands of
    /// individual dispatch timers per second.
    private static let deadlineToleranceNanos: UInt64 = 1_000_000

    init(
        queue: DispatchQueue,
        delayNanos: @escaping @Sendable (Data) -> UInt64 = { _ in 0 },
        consume: @escaping @Sendable ([Data]) -> Void
    ) {
        self.queue = queue
        self.delayNanos = delayNanos
        self.consume = consume
    }

    func enqueue(_ packet: Data) {
        let candidateDeadline = DispatchTime.now().uptimeNanoseconds
            &+ delayNanos(packet)
        lock.lock()
        // A changing adaptive cushion must not allow a newer RTP packet to
        // overtake an older one whose longer deadline was already assigned.
        let deadline = max(candidateDeadline, lastDeadlineNanos)
        lastDeadlineNanos = deadline
        pending.append(PendingPacket(deadlineNanos: deadline, data: packet))
        let shouldSchedule = !drainScheduled
        if shouldSchedule { drainScheduled = true }
        let generation = scheduleGeneration
        let firstDeadline = pending[pendingHead].deadlineNanos
        lock.unlock()

        if shouldSchedule {
            scheduleDrain(at: firstDeadline, generation: generation)
        }
    }

    /// Drop packets belonging to a retired media generation. Any already
    /// scheduled drain becomes a no-op; the next enqueue establishes a fresh
    /// ordered timeline.
    func discardPending() {
        lock.lock()
        pending.removeAll(keepingCapacity: true)
        pendingHead = 0
        drainScheduled = false
        lastDeadlineNanos = 0
        scheduleGeneration &+= 1
        lock.unlock()
    }

    private func scheduleDrain(at deadline: UInt64, generation: UInt64) {
        queue.asyncAfter(
            deadline: DispatchTime(uptimeNanoseconds: deadline)
        ) { [self] in
            drain(generation: generation)
        }
    }

    private func drain(generation: UInt64) {
        lock.lock()
        guard generation == scheduleGeneration else {
            lock.unlock()
            return
        }
        guard pendingHead < pending.count else {
            pending.removeAll(keepingCapacity: true)
            pendingHead = 0
            drainScheduled = false
            lastDeadlineNanos = 0
            lock.unlock()
            return
        }

        let cutoff = DispatchTime.now().uptimeNanoseconds
            &+ Self.deadlineToleranceNanos
        var dueEnd = pendingHead
        while dueEnd < pending.count,
              pending[dueEnd].deadlineNanos <= cutoff {
            dueEnd += 1
        }
        guard dueEnd > pendingHead else {
            let nextDeadline = pending[pendingHead].deadlineNanos
            lock.unlock()
            scheduleDrain(at: nextDeadline, generation: generation)
            return
        }

        let batch = pending[pendingHead..<dueEnd].map(\.data)
        pendingHead = dueEnd
        let nextDeadline = pendingHead < pending.count
            ? pending[pendingHead].deadlineNanos
            : nil
        if nextDeadline == nil {
            pending.removeAll(keepingCapacity: true)
            pendingHead = 0
            drainScheduled = false
            lastDeadlineNanos = 0
        } else if pendingHead >= 4_096,
                  pendingHead * 2 >= pending.count {
            pending.removeFirst(pendingHead)
            pendingHead = 0
        }
        lock.unlock()

        consume(batch)
        if let nextDeadline {
            scheduleDrain(at: nextDeadline, generation: generation)
        }
    }
}

/// Main VNC session observable object for SwiftUI integration.
///
/// `VNCSession` is the primary entry point for consumers of the rootshellVNC
/// framework. It manages the connection lifecycle, framebuffer rendering,
/// and exposes observable state for SwiftUI views.
///
/// Usage:
/// ```swift
/// let session = VNCSession()
/// try await session.connect(credentials: VNCCredentials(
///     host: "192.168.1.100",
///     password: "secret"
/// ))
///
/// // In SwiftUI:
/// RemoteDesktopView(session: session)
/// ```
@MainActor
@Observable
public final class VNCSession {

    // MARK: - Observable State

    /// The current state of the VNC connection.
    public var connectionState: VNCConnectionState = .idle {
        didSet {
            guard oldValue != connectionState else { return }
            // Snapshot so an observer can remove itself while handling the
            // transition without mutating the dictionary being iterated.
            for observer in Array(connectionStateObservers.values) {
                observer(connectionState)
            }
        }
    }

    /// Human-readable description of the current connection-establishment
    /// phase (dialing, negotiating security, authenticating, …). `nil` once
    /// operational or when no attempt is in flight. Drives the connecting
    /// status overlay, which needs more granularity than the collapsed
    /// `.connecting` state.
    public private(set) var connectionPhaseDescription: String?

    /// Host label for status UI while a connection attempt is in flight.
    public var connectingHostLabel: String? { activeCredentials?.host }

    /// The name of the remote desktop as reported by the server.
    public var serverName: String = ""

    /// The width of the remote framebuffer in pixels.
    public var framebufferWidth: Int = 0

    /// The height of the remote framebuffer in pixels.
    public var framebufferHeight: Int = 0

    /// The latest rendered framebuffer image, suitable for display.
    public var currentImage: CGImage?

    /// The last protocol error that occurred, if any.
    public var lastError: VNCProtocolError?

    /// Whether the server is using high-performance (HEVC/H.264) mode.
    public var isHighPerformanceMode: Bool = false

    /// Native Apple clipboard controls negotiated for this connection.
    public private(set) var supportsRemoteClipboardRequest = false
    public private(set) var supportsRemoteSharedClipboardControl = false

    /// Whether the server offers curtain mode, in which the remote Mac's own
    /// display shows a lock screen while this viewer keeps control. Apple
    /// publishes this per DisplayInfo2, so it stays false until one arrives and
    /// can be withdrawn mid-session.
    public private(set) var supportsCurtainMode = false

    /// Whether the remote Mac is currently curtained. This mirrors the server's
    /// reported console state rather than what was last requested, so it is
    /// safe to present as the true privacy state.
    public private(set) var isCurtained = false

    /// Set when a curtain change was requested but the server never reported
    /// the matching state. Hosts surface this because silently failing to
    /// curtain leaves the remote screen visible to bystanders.
    public private(set) var curtainChangeFailed = false

    /// How long the server has to reflect a requested curtain change before it
    /// is reported as failed.
    ///
    /// Satisfying the request makes the remote Mac switch console sessions and
    /// restart its capture pipeline, and the confirming DisplayInfo2 only lands
    /// after that settles. Apple's own client schedules an 8s `dispatch_after`
    /// in the server before it re-checks, so anything near
    /// that budget reports false failures on changes that did work.
    static let curtainConfirmationTimeoutNanoseconds: UInt64 = 20_000_000_000

    @ObservationIgnored
    private var pendingCurtainRequest: Bool?
    @ObservationIgnored
    private var curtainConfirmationTask: Task<Void, Never>?

    /// Content encryption negotiated by the active RFB transport. This excludes
    /// host-provided tunnels such as SSH and is nil while no transport is active.
    public private(set) var negotiatedContentEncryption: VNCContentEncryption?

    /// Structured command support advertised by an Apple RFB 3.889 server;
    /// nil for regular RFB servers.
    public private(set) var serverCapabilities: AppleServerCapabilities?

    /// Whether the negotiated server uses Apple's modifier-keysym convention,
    /// in which `Alt_L`/`Alt_R` mean Command and `Meta_L`/`Meta_R` mean Option
    /// (the reverse of standard X11). The keyboard layer reads this to send
    /// Option as `Meta_L` on Apple servers while standard servers keep `Alt_L`.
    /// Known once the handshake reaches ServerInit, before any typing.
    public private(set) var serverUsesAppleModifierConvention = false

    /// Number of independently decoded Apple video displays in the current
    /// media generation.
    public private(set) var activeVideoDisplayCount: Int = 1

    /// Server display rectangles, normalized into framebuffer coordinates and
    /// ordered as announced by the server (primary first). Standard mode uses
    /// these to present only the number of displays selected by the user.
    private(set) var remoteDisplayRegions: [CGRect] = []
    @ObservationIgnored
    private var remoteDisplayRegionByID: [UInt32: CGRect] = [:]
    @ObservationIgnored
    private var remoteDisplayRegionOrder: [UInt32] = []

    /// The remote cursor shape from the Cursor pseudo-encoding, adopted by
    /// the local system pointer. Nil when the server has not sent a shape
    /// (or sent an explicit empty one) — callers fall back to the default.
    public private(set) var remoteCursor: RemoteCursor?
    /// Distinguishes a pointer the server has not described yet from one
    /// it deliberately hid; `remoteCursor` is nil in both cases.
    public private(set) var remoteCursorPresence: RemoteCursorPresence = .undescribed

    /// Who draws the pointer on the connection that is open right now.
    ///
    /// The transport snapshots `configuration.cursorRendering` as it dials and
    /// negotiates its encodings from that snapshot, so flipping the
    /// configuration mid-session cannot change what the server is already
    /// doing. Anything deciding whether to draw a pointer locally has to
    /// follow the connection rather than the configuration, or a mid-session
    /// change leaves the user looking at two pointers or none. A session with
    /// no established connection reports the configured value, which is what
    /// the next dial will negotiate.
    public var activeCursorRendering: VNCCursorRendering {
        negotiatedCursorRendering ?? configuration.cursorRendering
    }

    /// The snapshot behind ``activeCursorRendering``, taken where the
    /// transport is created and cleared whenever the connection is torn down.
    private var negotiatedCursorRendering: VNCCursorRendering?

    /// Whether the server has requested a one-shot password confirmation for
    /// the current Apple Login Window episode. This remains pending until a
    /// host UI consumes it, so an event received during navigation is not lost.
    public private(set) var loginPasswordPromptPending = false

    // MARK: - Configuration

    /// The configuration for this session.
    public var configuration: VNCConfiguration

    // MARK: - Host Hooks

    /// Invoked on the main actor when the server publishes clipboard text via
    /// RFB ServerCutText or Apple's packed pasteboard extension. Container
    /// applications set this to route the
    /// remote clipboard into their own pasteboard handling; leaving it `nil`
    /// (the default) keeps the log-only behavior.
    @ObservationIgnored
    public var onServerClipboardText: ((String) -> Void)?

    /// Internal multicast used by package features such as shared clipboard.
    /// The public single callback above remains source-compatible for hosts
    /// that already consume raw ServerCutText events themselves.
    @ObservationIgnored
    private var serverClipboardObservers: [UUID: (String) -> Void] = [:]
    @ObservationIgnored
    private var connectionStateObservers: [UUID: (VNCConnectionState) -> Void] = [:]

    /// While `true`, Match Client display-size requests are deferred instead
    /// of sent. Container apps set this when the hosting view is occluded
    /// (hidden tab, backgrounded window) so transient layout changes never
    /// round-trip a resize to the server; clearing it applies the latest
    /// deferred size once, deduplicated against the last request.
    @ObservationIgnored
    public var suspendsRemoteDisplaySizeUpdates: Bool = false {
        didSet {
            guard oldValue, !suspendsRemoteDisplaySizeUpdates,
                  let deferred = deferredDisplaySizeUpdate else { return }
            deferredDisplaySizeUpdate = nil
            updateRemoteDisplaySize(
                viewSize: deferred.viewSize,
                displayScale: deferred.displayScale)
        }
    }

    /// While `true`, decoded frames are not presented: the Apple media band
    /// renderers stop committing to their display layers and the classic path
    /// stops publishing framebuffer snapshots. Container apps set this while
    /// the device may be locked, where any layer commit lands in the
    /// secure-mode lock snapshot and FrontBoard kills the process
    /// (0x2BAD45EC). Decoding continues so codec state stays warm; clearing
    /// suspension presents one reconciling frame.
    @ObservationIgnored
    public var suspendsDisplayPresentation: Bool = false {
        didSet {
            guard oldValue != suspendsDisplayPresentation else { return }
            videoBandRenderer.setPresentationSuspended(suspendsDisplayPresentation)
            secondaryVideoBandRenderer.setPresentationSuspended(suspendsDisplayPresentation)
            if !suspendsDisplayPresentation, renderer != nil {
                scheduleTrailingSnapshot(interval: 0)
            }
        }
    }

    /// Clear suspension AND present anything retained while the host's global
    /// presentation gate was armed. Needed for sessions created while the gate
    /// was already up (background launch on a locked device): their instance
    /// flag was never set, so clearing it is a `didSet` no-op and the retained
    /// frames would otherwise sit unpresented until the next network delta,
    /// which on a static remote screen never comes.
    public func reconcileDisplayPresentation() {
        suspendsDisplayPresentation = false
        videoBandRenderer.presentPendingBandsIfAny()
        secondaryVideoBandRenderer.presentPendingBandsIfAny()
        if renderer != nil, trailingSnapshotTask == nil {
            scheduleTrailingSnapshot(interval: 0)
        }
    }

    // MARK: - Internal

    private var transportSession: TransportSession?
    /// Credentials for the active connection. Kept private so UI code can
    /// offer credential actions without ever reading or displaying the secret.
    @ObservationIgnored
    private var activeCredentials: VNCCredentials?
    @ObservationIgnored
    private var appleLoginPromptTracker = AppleLoginPromptTransitionTracker()
    @ObservationIgnored
    private var appleLoginVisionTask: Task<Void, Never>?
    @ObservationIgnored
    private var appleLoginVisionRetryTask: Task<Void, Never>?
    @ObservationIgnored
    private var appleLoginVisionStabilityTask: Task<Void, Never>?
    @ObservationIgnored
    private var appleLoginVisionLatestFrame: (
        frame: AppleLoginVisionFrame,
        source: String,
        highPerformanceGeneration: UInt64?
    )?
    @ObservationIgnored
    private var appleLoginVisionAttemptCount = 0
    @ObservationIgnored
    private var appleLoginVisionLastAttemptNanos: UInt64 = 0
    @ObservationIgnored
    private var appleLoginVisionGeneration: UInt64 = 0
    @ObservationIgnored
    private var appleLoginVisionDetected = false
    @ObservationIgnored
    private var appleLoginVisionPromptOffered = false
    @ObservationIgnored
    private var appleLoginVisionHighPerformanceGeneration: UInt64?
    @ObservationIgnored
    var appleLoginVisionAnalysisOverrideForTesting:
        (@Sendable () throws -> AppleLoginTextAnalysis)?
    @ObservationIgnored
    private var appleServerProtocolObserved = false
    @ObservationIgnored
    private var loginPasswordSendGate = LoginPasswordSendStabilityGate()
    @ObservationIgnored
    private var loginPasswordSendStabilityTask: Task<Void, Never>?
    @ObservationIgnored
    private var loginPasswordSendScheduledToken:
        LoginPasswordSendStabilityGate.Token?
    @ObservationIgnored
    private var loginPasswordSendWatchdogTask: Task<Void, Never>?
    /// Uptime of the most recent display transition affecting the login
    /// send: a Match Client target change, a resize settlement edge, or a
    /// media generation replacement. A password send may only start after
    /// this has been quiet for the full hysteresis window, so a short stable
    /// gap between resize steps can never half-type a password into a
    /// capture that is about to restart.
    @ObservationIgnored
    private var lastLoginDisplayTransitionNanos: UInt64 = 0
    /// Renderer generation of the most recent committed frame; a change is a
    /// display transition even when no resize request produced it.
    @ObservationIgnored
    private var lastCommittedFrameGeneration: UInt64?
    /// Uptime of the most recent password delivery. Never used to authorize
    /// another send — only to debounce a login-state announcement that the
    /// unlock itself produces moments after a successful delivery.
    @ObservationIgnored
    private var lastLoginPasswordDeliveryNanos: UInt64 = 0
    @ObservationIgnored
    private var loginPasswordPromptRecheckTask: Task<Void, Never>?
    /// Uptime of the newest Apple session-state announcement, regardless of
    /// its content. Apple servers repeat DisplayInfo2 while a layout is
    /// stable, so "an announcement newer than X" is a liveness signal the
    /// prompt debounce can trust over stored state.
    @ObservationIgnored
    private var lastSessionStateAnnouncementNanos: UInt64 = 0
    /// Shared across transport generations: every settled emission funnels
    /// through this one counter, so ordering holds even across a sink
    /// reinstall while an old hop is still in flight.
    private let appleResizeSettledSequencer = SinkEventSequencer()
    @ObservationIgnored
    private var appleResizeSettledSequenceApplied: UInt64 = 0
    private var framebuffer: Framebuffer?
    private var renderer: FramebufferRenderer?
    var standardFramebufferSize: CGSize? { framebuffer?.size }
    private var videoStreamManager: VideoStreamManager?
    private var secondaryVideoStreamManager: VideoStreamManager?
    @ObservationIgnored
    private var remoteAudioPlayer: AppleRemoteAudioPlayer?
    @ObservationIgnored
    private var appleMediaPlaybackSynchronizer: AppleMediaPlaybackSynchronizer?
    private var eventTask: Task<Void, Never>?
    @ObservationIgnored
    private var remoteDisplayResizeTask: Task<Void, Never>?
    @ObservationIgnored
    private var lastRequestedClientDisplaySize: RemoteDisplaySize?
    /// Most recent client viewport, retained across connections so Match Client
    /// can be staged before Apple media setup starts. Without this, the server
    /// begins by encoding the physical display and a remote phone must receive
    /// a multi-megabyte reference picture before it can request its virtual
    /// display.
    @ObservationIgnored
    private var preparedClientDisplaySize: RemoteDisplaySize?
    /// Latest viewport reported while size updates were suspended.
    @ObservationIgnored
    private var deferredDisplaySizeUpdate: (viewSize: CGSize, displayScale: CGFloat)?
    /// Single drain task for the ordered input queue. Gesture callbacks are
    /// synchronous, but transport writes are async; one pump prevents a release
    /// from overtaking its press while coalescing stale movement samples.
    @ObservationIgnored
    private var inputTask: Task<Void, Never>?
    @ObservationIgnored
    private var inputGeneration: UInt64 = 0
    @ObservationIgnored
    private var inputQueue = SessionInputQueue()
    private let diagnostics = ConnectionDiagnostics()
    private let logger = VNCLogger(category: "Session")
    /// GPU renderer for the high-performance HEVC screen bands. The
    /// ``RemoteDesktopView`` displays this directly (zero-copy) instead of
    /// pushing a full-screen CGImage through SwiftUI every frame.
    @ObservationIgnored
    public let videoBandRenderer = VideoBandLayerRenderer()
    /// Independent renderer for the second Apple media stream. A second
    /// display is a separate HEVC reference chain, not another band of display
    /// one, and must never share its decoder or band compositor.
    @ObservationIgnored
    public let secondaryVideoBandRenderer = VideoBandLayerRenderer()
    var primaryVideoDecodeProgress: VideoStreamManager.DecodeProgress? {
        videoStreamManager?.decodeProgress
    }
    var secondaryVideoDecodeProgress: VideoStreamManager.DecodeProgress? {
        secondaryVideoStreamManager?.decodeProgress
    }
    func activeTransportVideoSourceCount() async -> Int {
        await transportSession?.videoSourceCount ?? 0
    }
    func activeTransportVideoReceiverIndexes() async -> [Int] {
        await transportSession?.videoSourceReceiverIndexes ?? []
    }
    func activeTransportMediaAnswerStreamLengths() async -> [Int] {
        await transportSession?.mediaAnswerStreamLengths ?? []
    }
    func activeTransportMediaControlDiagnostic() async -> String? {
        await transportSession?.mediaControlDiagnostic
    }
    /// Serial queue for feeding media packets to the decoder off the main
    /// thread. At ~3000 packets/s, demux + decode submission on the main actor
    /// backed up the whole pipeline; VideoStreamManager is thread-safe and a
    /// serial queue preserves packet order.
    @ObservationIgnored
    private let mediaQueue = DispatchQueue(label: "com.rootshell.vnc.media", qos: .userInitiated)
    /// Serial queue for persistent Zlib/ZRLE decode and framebuffer snapshots.
    /// Keeping it separate from HEVC and the main actor preserves codec order
    /// while input remains responsive during large standard-mode updates.
    @ObservationIgnored
    private let framebufferRenderQueue = DispatchQueue(
        label: "com.rootshell.vnc.framebuffer",
        qos: .userInitiated)
    @ObservationIgnored
    private var standardFramebufferGeometrySequence: UInt64 = 0
    @ObservationIgnored
    private var lastFramebufferRenderDiagnosticNanos: UInt64 = 0
    /// When the last framebuffer image was published to `currentImage`;
    /// drives the publish-only targetFrameRate throttle.
    @ObservationIgnored
    private var lastImagePublishNanos: UInt64 = 0
    @ObservationIgnored
    private var trailingSnapshotTask: Task<Void, Never>?
    @ObservationIgnored
    private var initialFramePresentationTracker =
        StandardInitialFramePresentationTracker()
    /// A zero-sized ServerInit lets Apple display records build the usable
    /// standard-mode union incrementally until a stronger resize source wins.
    @ObservationIgnored
    private var acceptsDeferredAppleDisplayGeometry = false
    /// Preserve ordered codec/control state that arrives before usable
    /// geometry. The transport credit is still returned; these rectangles are
    /// replayed ahead of the first renderable batch on the same generation.
    @ObservationIgnored
    private var deferredFramebufferRects: [(FramebufferRect, Data)] = []
    @ObservationIgnored
    private var deferredFramebufferBytes = 0
    private static let maximumDeferredFramebufferBytes = 64 * 1024 * 1024
    private static let maximumDeferredFramebufferRects = 512
    /// True only after this framebuffer generation has applied a pixel-bearing
    /// batch that satisfies its initial-coverage gate. Reconciliation must not
    /// snapshot a merely allocated (or retained retired) renderer before then.
    @ObservationIgnored
    private var standardFramebufferHasPresentablePixels = false
    /// Invalidates framebuffer render and snapshot work when a transport or
    /// renderer is replaced. The last complete `currentImage` may remain
    /// visible during reconnect, but no work from its retired generation may
    /// publish into the replacement connection.
    @ObservationIgnored
    private var framebufferPresentationGeneration: UInt64 = 0
    /// Rejects late geometry callbacks from a decoder retired by a newer AVC
    /// negotiation generation.
    @ObservationIgnored
    private var appliedMediaGeometryGeneration: UInt64 = 0
    @ObservationIgnored
    private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored
    private var intentionallyDisconnected = false
    @ObservationIgnored
    private var hasEstablishedConnection = false
    /// Sticky across automatic reconnects for this connection attempt. If a
    /// server accepts a one-picture offer but never starts a video source, the
    /// replacement transport retries its known native four-source profile.
    @ObservationIgnored
    private var appleMediaTilesPerFrameOverride: UInt64?
    /// Forced media reconnects since the last healthy media bootstrap. The
    /// video watchdogs tear down a control channel that is doing nothing
    /// wrong, so this bounds how many times a media-only fault is allowed to
    /// cost the user a working session.
    @ObservationIgnored
    private var consecutiveMediaBootstrapReconnects = 0
    /// After this many forced media reconnects with no healthy bootstrap in
    /// between, retrying is not working: a third attempt only re-enters the
    /// loop the user experiences as repeated "Connection interrupted". See
    /// ``failAfterMediaBootstrapExhausted(reason:)`` for what happens instead.
    private static let maximumConsecutiveMediaBootstrapReconnects = 2

    /// Media-stream restarts attempted on the live connection before falling
    /// back to a reconnect. One is enough to tell a damaged startup burst
    /// (which a fresh offer fixes) from a server that will not produce a
    /// decodable stream on this connection at all.
    private static let maximumConsecutiveMediaStreamRestarts = 1
    private var consecutiveMediaStreamRestarts = 0

    /// Set when automatic recovery gave up on purpose rather than running out
    /// of road: a non-retryable error, an exhausted media-bootstrap cap, or a
    /// policy that disables reconnection. Those failures are the user's to
    /// resolve through Retry, and nothing that merely happens to the app
    /// afterwards, an app switch included, may undo them.
    private var automaticRecoveryDeclined = false
    #if canImport(UIKit)
    @ObservationIgnored
    private var backgroundLifecycleTask: Task<Void, Never>?
    @ObservationIgnored
    private var foregroundLifecycleTask: Task<Void, Never>?
    @ObservationIgnored
    private var mediaWasBackgrounded = false

    /// Whether the session still had a live or recovering connection at the
    /// moment the app was backgrounded.
    ///
    /// This is the evidence that a terminal state found on the next foreground
    /// edge was produced *by* the background window: the session was not
    /// terminal going in and is terminal coming out, so the transition
    /// happened in between. Without it, resume recovery would revive any
    /// parked failure, including ones the user had already seen and left
    /// alone, simply because they switched apps.
    @ObservationIgnored
    private var wasLiveWhenBackgrounded = false

    /// Uptime deadline until which a connection loss is attributed to the
    /// process having been suspended rather than to the network.
    ///
    /// iOS reclaims the socket of a process it suspends, so the transport is
    /// already dead when the app comes back; the read loop just has not
    /// noticed yet. Discovering that a moment later and then serving the
    /// standard backoff spends about a second doing nothing, and burns a
    /// `retry n/8` slot on a failure the network had no part in. While this
    /// deadline is in the future, the first loss reconnects immediately and
    /// does not consume an attempt.
    @ObservationIgnored
    private var suspensionResumeDeadlineNanos: UInt64 = 0

    /// How long after a foreground edge a loss still counts as suspension
    /// fallout. The read loop typically surfaces the aborted socket within
    /// tens of milliseconds of resuming; this is deliberately generous
    /// without being long enough to swallow a genuine mid-use drop.
    private static let suspensionResumeGraceNanos: UInt64 = 3_000_000_000
    #endif

    // MARK: - Init

    /// Create a new VNC session with the given configuration.
    ///
    /// - Parameter configuration: Session configuration. Defaults to sensible values.
    public init(configuration: VNCConfiguration = VNCConfiguration()) {
        self.configuration = configuration
        videoBandRenderer.onFrameCommitted = {
            [weak self] pixelBuffer, streamGeneration in
            self?.noteCommittedFrameGenerationForLoginQuietClock(
                streamGeneration)
            self?.noteHighPerformanceFrameForPendingLoginPassword(
                pixelBuffer,
                mediaGeneration: streamGeneration)
            self?.considerAppleLoginVisionFrame(
                .pixelBuffer(pixelBuffer),
                source: "High Performance full frame",
                highPerformanceGeneration: streamGeneration)
        }
        #if canImport(UIKit)
        observeApplicationLifecycle()
        #endif
    }

    deinit {
        reconnectTask?.cancel()
        remoteAudioPlayer?.stop()
        #if canImport(UIKit)
        backgroundLifecycleTask?.cancel()
        foregroundLifecycleTask?.cancel()
        #endif
    }

    // MARK: - Connection

    /// Connect to a VNC server using the provided credentials.
    ///
    /// This method performs the full RFB handshake, including protocol version
    /// negotiation, security type selection, authentication, and ServerInit.
    /// On success, the session begins receiving framebuffer updates.
    ///
    /// - Parameter credentials: The server address, port, and authentication credentials.
    /// - Throws: ``VNCError`` if the connection or handshake fails.
    public func connect(credentials: VNCCredentials) async throws {
        guard connectionState.canConnect else {
            throw VNCError.alreadyConnected
        }

        // Belt-and-braces: the configuration self-heals this combination in
        // its property observers, so reaching this guard means a bug upstream.
        if configuration.transportProvider != nil,
           configuration.videoQualityMode == .adaptive {
            throw VNCError.unsupportedFeature(
                String(localized: "High Performance mode requires a direct network connection and is unavailable over a tunneled transport.", bundle: .module))
        }

        invalidateInputQueue()
        reconnectTask?.cancel()
        reconnectTask = nil
        intentionallyDisconnected = false
        hasEstablishedConnection = false
        consecutiveMediaBootstrapReconnects = 0
        consecutiveMediaStreamRestarts = 0
        automaticRecoveryDeclined = false
        connectionState = .connecting
        connectionPhaseDescription = String(localized: "Opening connection…", bundle: .module)
        activeCredentials = credentials
        resetAppleLoginPromptState()
        logger.debug(
            "Apple login prompt configured: enabled="
                + "\(configuration.promptForLoginPasswordAtLoginWindow) "
                + "passwordAvailable=\(!credentials.password.isEmpty) "
                + "quality=\(configuration.videoQualityMode.rawValue) "
                + "displayInfo2Requested="
                + "\(configuration.effectiveEncodings.contains(.unknown(1105)))")
        appleMediaTilesPerFrameOverride = nil
        lastError = nil
        currentImage = nil
        remoteCursor = nil
        remoteCursorPresence = .undescribed
        negotiatedCursorRendering = nil
        isHighPerformanceMode = false
        supportsRemoteClipboardRequest = false
        supportsRemoteSharedClipboardControl = false
        resetCurtainState()
        negotiatedContentEncryption = nil
        serverCapabilities = nil
        activeVideoDisplayCount = 1
        remoteDisplayRegions = []
        remoteDisplayRegionByID = [:]
        remoteDisplayRegionOrder = []
        invalidateStandardFramebufferPresentation()
        remoteDisplayResizeTask?.cancel()
        remoteDisplayResizeTask = nil
        lastRequestedClientDisplaySize = nil
        diagnostics.isHighPerformanceMode = false
        videoBandRenderer.reset()
        secondaryVideoBandRenderer.reset()
        diagnostics.reset()
        diagnostics.connectionStartTime = Date()
        remoteAudioPlayer?.stop()
        remoteAudioPlayer = nil
        appleMediaPlaybackSynchronizer = nil

        if configuration.enableProtocolTrace {
            diagnostics.protocolTrace = ProtocolTrace()
        }

        do {
            try await establishTransport(credentials: credentials)
            logger.info("Connection initiated to \(credentials.host):\(credentials.port)")
        } catch let error as VNCProtocolError {
            if intentionallyDisconnected {
                cleanupTransport(clearCredentials: true)
                connectionState = .disconnected
                throw CancellationError()
            }
            connectionState = .failed(error.localizedDescription)
            lastError = error
            diagnostics.lastError = error
            cleanupTransport(clearCredentials: true)
            throw mapProtocolError(error)
        } catch {
            if intentionallyDisconnected {
                cleanupTransport(clearCredentials: true)
                connectionState = .disconnected
                throw CancellationError()
            }
            let message = error.localizedDescription
            connectionState = .failed(message)
            cleanupTransport(clearCredentials: true)
            throw VNCError.connectionFailed(message)
        }
    }

    /// Disconnect from the current VNC server.
    ///
    /// Cancels all active tasks, closes the transport, and resets the session
    /// state. Safe to call even when not connected.
    public func disconnect() {
        guard connectionState != .idle && connectionState != .disconnected else { return }

        intentionallyDisconnected = true
        reconnectTask?.cancel()
        reconnectTask = nil
        connectionState = .disconnecting
        logger.info("Disconnecting")

        // Cancel background tasks
        eventTask?.cancel()
        eventTask = nil
        remoteDisplayResizeTask?.cancel()
        remoteDisplayResizeTask = nil
        lastRequestedClientDisplaySize = nil
        invalidateInputQueue()

        // Close the transport
        if let transport = transportSession {
            Task {
                await transport.disconnect()
            }
        }
        transportSession = nil
        activeCredentials = nil
        resetAppleLoginPromptState()

        // Clear rendering state
        framebuffer = nil
        renderer = nil
        currentImage = nil
        remoteCursor = nil
        remoteCursorPresence = .undescribed
        negotiatedCursorRendering = nil
        isHighPerformanceMode = false
        supportsRemoteClipboardRequest = false
        supportsRemoteSharedClipboardControl = false
        resetCurtainState()
        negotiatedContentEncryption = nil
        serverCapabilities = nil
        activeVideoDisplayCount = 1
        remoteDisplayRegions = []
        remoteDisplayRegionByID = [:]
        remoteDisplayRegionOrder = []
        invalidateStandardFramebufferPresentation()
        videoBandRenderer.reset()
        secondaryVideoBandRenderer.reset()
        videoStreamManager?.stopStream()
        videoStreamManager = nil
        secondaryVideoStreamManager?.stopStream()
        secondaryVideoStreamManager = nil
        remoteAudioPlayer?.stop()
        remoteAudioPlayer = nil
        appleMediaPlaybackSynchronizer = nil

        connectionPhaseDescription = nil
        connectionState = .disconnected
    }

    /// Immediately retry after automatic recovery has exhausted its attempts.
    public func retryConnection() {
        guard reconnectTask == nil,
              activeCredentials != nil,
              connectionState.canConnect else { return }
        intentionallyDisconnected = false
        // A deliberate retry earns a fresh media-recovery budget; otherwise a
        // session parked by `failAfterMediaBootstrapExhausted` would re-trip
        // the cap on its first watchdog and never get a real second chance.
        consecutiveMediaBootstrapReconnects = 0
        consecutiveMediaStreamRestarts = 0
        // The user asking for a retry is the resolution the declined states
        // were waiting for.
        automaticRecoveryDeclined = false
        scheduleReconnect(immediate: true)
    }

    /// Reconnect an active session using a replacement configuration while
    /// retaining the credentials already held by the session.
    ///
    /// This is intended for UI actions that change handshake-level options,
    /// such as the video transport or remote display sizing mode. The
    /// transition deliberately avoids `.disconnected`, so container apps can
    /// distinguish a configuration restart from an intentional close.
    ///
    /// - Returns: `true` when the restart was accepted. A session must be
    ///   connected, have retained credentials, and not already be reconnecting.
    @discardableResult
    public func reconnect(with configuration: VNCConfiguration) -> Bool {
        guard connectionState.isConnected,
              activeCredentials != nil,
              reconnectTask == nil else { return false }

        self.configuration = configuration
        intentionallyDisconnected = false
        // Handshake-level options changed (often precisely to escape a failing
        // video profile), so the media-recovery budget starts over.
        consecutiveMediaBootstrapReconnects = 0
        consecutiveMediaStreamRestarts = 0
        automaticRecoveryDeclined = false

        // Mirror the proven media-bootstrap recovery path: close the old
        // transport while the reconnect task performs ordered cleanup and
        // establishes a fresh transport with the replacement configuration.
        let transport = transportSession
        Task { await transport?.disconnect() }
        scheduleReconnect(immediate: true, minimumAttempts: 1)
        return true
    }

    // MARK: - Input Events

    /// Whether the active connection has a password available for the remote
    /// login window. The password itself is intentionally never exposed.
    public var canSendLoginPassword: Bool {
        connectionState.isConnected && !(activeCredentials?.password.isEmpty ?? true)
    }

    /// Apple may publish Login Window state just before its media offer. Treat
    /// that short negotiation window as High Performance too, otherwise an
    /// immediate confirmation can type into the display about to be retired.
    private var shouldDeferLoginPasswordForMatchClientStability: Bool {
        guard configuration.displaySizingMode == .matchClient else {
            return false
        }
        return isHighPerformanceMode
            || (configuration.videoQualityMode == .adaptive
                && appleServerProtocolObserved)
    }

    /// Consume a pending Apple Login Window password prompt.
    ///
    /// Returns `true` exactly once for each pending request. Consuming a
    /// request does not send input; the caller should first present its own
    /// confirmation UI and invoke ``sendLoginPassword()`` only if accepted.
    @discardableResult
    public func consumeLoginPasswordPromptRequest() -> Bool {
        guard loginPasswordPromptPending, canSendLoginPassword else {
            logger.debug(
                "Apple login prompt was not consumed: pending="
                    + "\(loginPasswordPromptPending) "
                    + "canSendPassword=\(canSendLoginPassword)")
            loginPasswordPromptPending = false
            return false
        }
        loginPasswordPromptPending = false
        logger.debug("Apple login prompt consumed by host UI")
        return true
    }

    /// Type the active connection's password and press Return. This mirrors
    /// the behavior of remote-desktop clients' “Type User Password” action.
    /// Callers should obtain confirmation before invoking this method.
    public func sendLoginPassword() {
        guard canSendLoginPassword, let password = activeCredentials?.password else { return }

        guard shouldDeferLoginPasswordForMatchClientStability else {
            sendLoginPasswordNow(password)
            return
        }

        let wasPending = loginPasswordSendGate.isPending
        let token = loginPasswordSendGate.requestSend()
        if let token {
            scheduleLoginPasswordSendAfterStability(token: token)
        } else {
            ensurePendingLoginPasswordProgress(reason: "user request")
        }
        if !wasPending {
            logger.info(
                "Password send queued until Match Client display is stable")
        }
    }

    private func sendLoginPasswordNow(_ password: String) {
        logger.info("Sending approved login password input")
        lastLoginPasswordDeliveryNanos = DispatchTime.now().uptimeNanoseconds

        let focusX = UInt16(clamping: framebufferWidth / 2)
        let focusY = UInt16(clamping: framebufferHeight / 2)
        let events = Self.loginPasswordFocusInputEvents(x: focusX, y: focusY)
            + Self.loginPasswordInputEvents(password: password)
        for event in events {
            switch event {
            case .key(let downFlag, let keysym):
                sendKeyEvent(downFlag: downFlag, key: keysym)
            case .pause:
                enqueueInput(event)
            case .pointer(let buttonMask, let x, let y):
                sendPointerEvent(buttonMask: buttonMask, x: x, y: y)
            case .scroll, .gesture, .clipboard, .clipboardRequest,
                 .sharedClipboard, .curtain:
                assertionFailure("Unexpected event in login password sequence")
            }
        }
    }

    /// Focus macOS Login Window before typing. Pointer events and the pause
    /// share the ordered input queue with the password, so no key can overtake
    /// the click that establishes the secure field's first responder. The
    /// select-all + backspace empties the secure field first: a delivery
    /// interrupted by a server capture restart can leave a partial password
    /// behind, and a later confirmed send must replace it, never append.
    nonisolated static func loginPasswordFocusInputEvents(
        x: UInt16,
        y: UInt16
    ) -> [SessionInputEvent] {
        [
            .pointer(buttonMask: 0, x: x, y: y),
            .pointer(buttonMask: 1, x: x, y: y),
            .pointer(buttonMask: 0, x: x, y: y),
            .pause(nanoseconds: 150_000_000),
            .key(downFlag: true, keysym: KeyboardInputHandler.keysymSuperL),
            .key(downFlag: true, keysym: 0x61),
            .key(downFlag: false, keysym: 0x61),
            .key(downFlag: false, keysym: KeyboardInputHandler.keysymSuperL),
            .key(downFlag: true, keysym: KeyboardInputHandler.keysymBackspace),
            .key(downFlag: false, keysym: KeyboardInputHandler.keysymBackspace),
            .pause(nanoseconds: 50_000_000),
        ]
    }

    /// Construct the exact ordered input sequence used by
    /// ``sendLoginPassword()``. Modifier releases prevent a locally held or
    /// remotely latched modifier from changing the password, while a small
    /// delay after each complete key tap gives login windows time to process
    /// secure text input without separating a key-down from its key-up.
    nonisolated static func loginPasswordInputEvents(
        password: String
    ) -> [SessionInputEvent] {
        let modifierKeysyms: [UInt32] = [
            KeyboardInputHandler.keysymCapsLock,
            KeyboardInputHandler.keysymShiftL,
            KeyboardInputHandler.keysymSuperL,
            KeyboardInputHandler.keysymAltL,
            KeyboardInputHandler.keysymControlL,
            KeyboardInputHandler.keysymControlR,
            KeyboardInputHandler.keysymSuperR,
            KeyboardInputHandler.keysymAltR,
            KeyboardInputHandler.keysymShiftR,
        ]
        let interKeyDelayNanoseconds: UInt64 = 5_000_000
        var events = modifierKeysyms.map {
            SessionInputEvent.key(downFlag: false, keysym: $0)
        }

        func appendKeyTap(_ keysym: UInt32) {
            guard keysym != 0 else { return }
            events.append(.key(downFlag: true, keysym: keysym))
            events.append(.key(downFlag: false, keysym: keysym))
            events.append(.pause(nanoseconds: interKeyDelayNanoseconds))
        }

        for character in password {
            appendKeyTap(KeyboardInputHandler.keysymForCharacter(character))
        }
        appendKeyTap(KeyboardInputHandler.keysymReturn)
        return events
    }

    /// Send a key press or release event to the VNC server.
    ///
    /// - Parameters:
    ///   - downFlag: `true` for key press, `false` for key release.
    ///   - key: The X11 keysym value for the key.
    public func sendKeyEvent(downFlag: Bool, key: UInt32) {
        guard connectionState.isConnected, transportSession != nil else { return }

        if isTraceEnabled {
            diagnostics.protocolTrace.recordSent(
                type: "KeyEvent",
                data: ClientMessage.keyEvent(downFlag: downFlag, key: key).serialize(),
                details: "key=0x\(String(key, radix: 16)) down=\(downFlag)"
            )
        }

        enqueueInput(.key(downFlag: downFlag, keysym: key))
    }

    /// Send a pointer (mouse/touch) event to the VNC server.
    ///
    /// - Parameters:
    ///   - buttonMask: Bitmask of pressed buttons (bit 0 = left, 1 = middle, 2 = right,
    ///     3 = scroll up, 4 = scroll down).
    ///   - x: The X coordinate in framebuffer pixels.
    ///   - y: The Y coordinate in framebuffer pixels.
    public func sendPointerEvent(buttonMask: UInt8, x: UInt16, y: UInt16) {
        guard connectionState.isConnected, transportSession != nil else { return }

        if isTraceEnabled {
            diagnostics.protocolTrace.recordSent(
                type: "PointerEvent",
                data: ClientMessage.pointerEvent(buttonMask: buttonMask, x: x, y: y).serialize(),
                details: "buttons=0x\(String(buttonMask, radix: 16)) pos=(\(x),\(y))"
            )
        }

        enqueueInput(.pointer(buttonMask: buttonMask, x: x, y: y))
    }

    /// Send one continuous scroll sample. Apple servers that advertise precise
    /// scrolling receive the full event; all other servers receive ordinary
    /// RFB wheel-button press/release events from the transport fallback.
    public func sendScrollEvent(_ event: AppleScrollEvent) {
        guard connectionState.isConnected, transportSession != nil else { return }

        if isTraceEnabled {
            diagnostics.protocolTrace.recordSent(
                type: "ScrollEvent",
                data: ClientMessage.appleScrollEvent(event).serialize(),
                details: "delta=(\(event.pointDeltaX),\(event.pointDeltaY)) phase=\(event.scrollPhase.rawValue) pos=(\(event.x),\(event.y))"
            )
        }

        enqueueInput(.scroll(event))
    }

    /// Send the begin/end envelope around a precise Apple scroll gesture.
    /// The transport ignores it for conventional RFB servers.
    public func sendGestureEvent(_ event: AppleGestureEvent) {
        guard connectionState.isConnected, transportSession != nil else { return }

        if isTraceEnabled {
            diagnostics.protocolTrace.recordSent(
                type: "GestureEvent",
                data: ClientMessage.appleGestureEvent(event).serialize(),
                details: "kind=\(event.kind.rawValue) source=\(event.sourceSubtype.rawValue) pos=(\(event.x),\(event.y))"
            )
        }

        enqueueInput(.gesture(event))
    }

    /// Send clipboard text to the VNC server.
    ///
    /// - Parameter text: The text to place on the server's clipboard.
    public func sendClipboardText(_ text: String) {
        guard connectionState.isConnected, transportSession != nil else { return }

        if isTraceEnabled {
            diagnostics.protocolTrace.recordSent(
                type: "ClientCutText",
                data: ClientMessage.clientCutText(text).serialize(),
                details: "length=\(text.utf8.count)"
            )
        }

        enqueueInput(.clipboard(text))
    }

    /// Request the current remote clipboard from a capable Apple server.
    public func requestRemoteClipboard() {
        guard connectionState.isConnected,
              transportSession != nil,
              supportsRemoteClipboardRequest else { return }
        enqueueInput(.clipboardRequest)
    }

    /// Control Apple's server-side automatic pasteboard notifications.
    public func setRemoteSharedClipboardEnabled(_ enabled: Bool) {
        guard connectionState.isConnected,
              transportSession != nil,
              supportsRemoteSharedClipboardControl else { return }
        enqueueInput(.sharedClipboard(enabled))
    }

    /// Curtain or uncurtain the remote Mac's own display.
    ///
    /// The note is shown on the curtained screen and is ignored when disabling.
    /// `isCurtained` does not change here — it follows the server's next
    /// DisplayInfo2, and `curtainChangeFailed` is set if that never confirms.
    public func setCurtainMode(_ enabled: Bool, message: String = "") {
        guard connectionState.isConnected,
              transportSession != nil,
              supportsCurtainMode else { return }
        curtainChangeFailed = false
        // The server only re-announces DisplayInfo2 when something changes, so
        // a request that is already satisfied would never be confirmed and
        // would raise a false privacy warning. Still send it: the note on a
        // curtained screen may differ.
        if isCurtained != enabled {
            startCurtainConfirmationWatchdog(expecting: enabled)
        }
        enqueueInput(.curtain(enabled: enabled, message: message))
    }

    /// Dismiss the failure notice after a host has presented it.
    public func acknowledgeCurtainFailure() {
        curtainChangeFailed = false
    }

    /// Apple never acknowledges the curtain command, so a request that the
    /// server declines is indistinguishable from one still in flight. Give the
    /// state change a grace period, then report the mismatch rather than
    /// leaving the toggle showing a privacy guarantee that does not hold.
    private func startCurtainConfirmationWatchdog(expecting enabled: Bool) {
        curtainConfirmationTask?.cancel()
        pendingCurtainRequest = enabled
        curtainConfirmationTask = Task { [weak self] in
            try? await Task.sleep(
                nanoseconds: Self.curtainConfirmationTimeoutNanoseconds)
            guard !Task.isCancelled, let self else { return }
            guard self.pendingCurtainRequest == enabled else { return }
            self.pendingCurtainRequest = nil
            self.curtainConfirmationTask = nil
            self.curtainChangeFailed = true
            self.logger.warning(
                "Curtain mode change to \(enabled) was not confirmed by the server")
        }
    }

    private func resetCurtainState() {
        curtainConfirmationTask?.cancel()
        curtainConfirmationTask = nil
        pendingCurtainRequest = nil
        supportsCurtainMode = false
        isCurtained = false
        curtainChangeFailed = false
    }

    func addServerClipboardObserver(
        _ observer: @escaping (String) -> Void
    ) -> UUID {
        let id = UUID()
        serverClipboardObservers[id] = observer
        return id
    }

    func removeServerClipboardObserver(_ id: UUID) {
        serverClipboardObservers.removeValue(forKey: id)
    }

    func addConnectionStateObserver(
        _ observer: @escaping (VNCConnectionState) -> Void
    ) -> UUID {
        let id = UUID()
        connectionStateObservers[id] = observer
        return id
    }

    func removeConnectionStateObserver(_ id: UUID) {
        connectionStateObservers.removeValue(forKey: id)
    }

    /// Debounce viewport/rotation changes and request a matching remote display
    /// when the user selected Match Client. The transport capability-gates both
    /// Apple's virtual-display command and standard RFB SetDesktopSize.
    func matchingClientDisplaySize(
        viewSize: CGSize,
        displayScale _: CGFloat
    ) -> RemoteDisplaySize? {
        guard configuration.displaySizingMode == .matchClient,
              ProcessInfo.processInfo.environment[
                "ROOTSHELL_VNC_DISABLE_MATCH_CLIENT"] != "1" else { return nil }
        let size = RemoteDisplaySize.matching(viewSize: viewSize)
        if RenderCommitStats.shared != nil, let size {
            VNCLogger(category: "RenderStats").debug(
                "DISPLAYREQ pixels=\(size.pixelWidth)x\(size.pixelHeight) "
                    + "points=\(size.pointWidth)x\(size.pointHeight)")
        }
        return size
    }

    public func updateRemoteDisplaySize(
        viewSize: CGSize,
        displayScale: CGFloat
    ) {
        if suspendsRemoteDisplaySizeUpdates {
            deferredDisplaySizeUpdate = (viewSize, displayScale)
            return
        }
        guard let requested = matchingClientDisplaySize(
            viewSize: viewSize,
            displayScale: displayScale) else { return }

        // ConnectionView supplies the viewport before connecting; the remote
        // desktop view keeps it current for window changes and device rotation.
        let displayTargetChanged = preparedClientDisplaySize != requested
        preparedClientDisplaySize = requested

        if displayTargetChanged,
           isHighPerformanceMode || loginPasswordSendGate.isPending {
            lastLoginDisplayTransitionNanos =
                DispatchTime.now().uptimeNanoseconds
            loginPasswordSendGate.displayTargetChanged()
            cancelScheduledLoginPasswordSend()
        }

        guard connectionState.isConnected,
              let transport = transportSession,
              requested != lastRequestedClientDisplaySize else { return }

        if isHighPerformanceMode {
            restartAppleLoginVisionForDisplayTransition(
                reason: "Match Client target changed")
        }
        lastRequestedClientDisplaySize = requested
        remoteDisplayResizeTask?.cancel()
        remoteDisplayResizeTask = Task { [weak self, weak transport] in
            do {
                try await Task.sleep(for: .milliseconds(120))
                try Task.checkCancellation()
                guard let self,
                      let transport,
                      self.transportSession === transport,
                      self.connectionState.isConnected,
                      self.configuration.displaySizingMode == .matchClient else { return }
                let disposition = try await transport.requestRemoteDisplaySize(
                    pixelWidth: requested.pixelWidth,
                    pixelHeight: requested.pixelHeight,
                    pointWidth: requested.pointWidth,
                    pointHeight: requested.pointHeight)
                self.logger.info(
                    "Client-sized display \(requested.pixelWidth)x"
                        + "\(requested.pixelHeight): \(String(describing: disposition))")
            } catch is CancellationError {
                return
            } catch {
                guard let self else { return }
                if self.lastRequestedClientDisplaySize == requested {
                    self.lastRequestedClientDisplaySize = nil
                }
                self.logger.warning(
                    "Failed to request client-sized display: "
                        + error.localizedDescription)
            }
        }
    }

    // MARK: - Diagnostics

    /// Get diagnostic information for the current or most recent connection.
    ///
    /// - Returns: A snapshot of connection diagnostics including handshake details,
    ///   timing information, and protocol trace data.
    public func getDiagnostics() -> ConnectionDiagnostics {
        diagnostics
    }

    /// Live traffic and decode statistics for the active connection, or nil
    /// when no transport is up. Poll while a diagnostics UI is visible; each
    /// call advances the snapshot's recent-rate window.
    public func currentStatistics() async -> VNCSessionStatistics? {
        guard let transport = transportSession else { return nil }
        let stats = await transport.statisticsSnapshot()
        guard transportSession === transport else { return nil }

        var framesSubmitted: UInt64 = 0
        var framesDecoded: UInt64 = 0
        var gaps = 0
        var droppedWhileGated = 0
        for manager in [videoStreamManager, secondaryVideoStreamManager].compactMap({ $0 }) {
            let progress = manager.decodeProgress
            framesSubmitted &+= progress.submittedFrameCount
            framesDecoded &+= progress.decoderOutputCount
            let loss = manager.lossStatsSnapshot
            gaps += loss.gapsDetected
            droppedWhileGated += loss.framesDroppedWhileGated
        }

        return VNCSessionStatistics(
            transport: stats,
            framesSubmitted: framesSubmitted,
            framesDecoded: framesDecoded,
            lossGapsDetected: gaps,
            framesDroppedWhileGated: droppedWhileGated,
            capturedAt: Date())
    }

    /// Populate handshake-derived diagnostics from the transport. Called on
    /// ServerInit and again when encryption facts upgrade (EncryptionInfo,
    /// media-stream start).
    private func refreshHandshakeDiagnostics(from transport: TransportSession) async {
        let handshake = await transport.handshakeInfo
        guard transportSession === transport else { return }
        diagnostics.serverVersion = handshake.serverReportedVersion
        diagnostics.clientVersion = handshake.negotiatedVersion
        diagnostics.offeredSecurityTypes = handshake.offeredSecurityTypes
        diagnostics.selectedSecurityType = handshake.selectedSecurityType
        diagnostics.contentEncryption = handshake.contentEncryption
        if negotiatedContentEncryption != handshake.contentEncryption {
            negotiatedContentEncryption = handshake.contentEncryption
        }
        serverCapabilities = handshake.appleServerCapabilities
        let usesAppleModifiers = handshake.negotiatedVersion?.isApple == true
        if serverUsesAppleModifierConvention != usesAppleModifiers {
            serverUsesAppleModifierConvention = usesAppleModifiers
        }
    }

    var liveMediaDebugSnapshot: (submitted: UInt64, outputs: UInt64) {
        let progress = videoStreamManager?.decodeProgress
        return (
            progress?.submittedFrameCount ?? 0,
            progress?.decoderOutputCount ?? 0)
    }

    // MARK: - Private: Event Processing

    private func startEventProcessing(transport: TransportSession) {
        eventTask = Task { [weak self] in
            for await event in transport.events {
                guard let self, !Task.isCancelled,
                      self.transportSession === transport else { break }
                await self.handleSessionEvent(event, from: transport)
            }
        }
    }

    private func handleSessionEvent(
        _ event: SessionEvent,
        from transport: TransportSession
    ) async {
        switch event {
        case .stateChanged(let protocolState):
            handleStateChanged(protocolState)

        case .serverInit(let serverInit):
            supportsRemoteClipboardRequest =
                await transport.supportsRemoteClipboardRequest
            supportsRemoteSharedClipboardControl =
                await transport.supportsRemoteSharedClipboardControl
            await refreshHandshakeDiagnostics(from: transport)
            await handleServerInit(serverInit)

        case .framebufferUpdate(let rects):
            // Returning the credit below requests the next incremental frame.
            // Keeping one update in flight prevents stale reference frames
            // from queueing while decode/presentation is busy.
            let streamIsUsable = await handleFramebufferUpdate(
                rects,
                from: transport)
            guard streamIsUsable else { return }

            do {
                // Applying a batch yields to the render queue. A reconnect can
                // replace the transport while that work is in flight, so only
                // return credit to the transport that emitted this update.
                guard transportSession === transport else { return }
                try await transport.finishFramebufferUpdate()
            } catch is CancellationError {
                break
            } catch {
                logger.warning(
                    "Failed to acknowledge framebuffer update: "
                        + error.localizedDescription)
            }

        case .clipboardText(let text):
            if isTraceEnabled {
                diagnostics.protocolTrace.recordReceived(
                    type: "ServerCutText",
                    data: Data(text.utf8),
                    details: "length=\(text.utf8.count)"
                )
            }
            onServerClipboardText?(text)
            // Snapshot the callbacks so observers may invalidate themselves
            // safely while handling an event.
            for observer in Array(serverClipboardObservers.values) {
                observer(text)
            }

        case .bell:
            logger.debug("Server bell")

        case .error(let error):
            handleError(error)

        case .encryptionInfo(let info):
            noteAppleServerProtocolObserved()
            logger.info("Encryption info: cipher=\(info.cipherMode) keyLen=\(info.keyLength)")
            diagnostics.encryptionMode = "Cipher mode \(info.cipherMode), key length \(info.keyLength)"
            await refreshHandshakeDiagnostics(from: transport)

        case .displayInfo(let info):
            noteAppleServerProtocolObserved()
            logger.info("Display info: \(info.width)x\(info.height) at (\(info.originX),\(info.originY))")
            // TransportSession emits the complete enclosing layout after all
            // per-record compatibility events. Apply geometry from that one
            // atomic snapshot so display zero cannot cause an intermediate
            // allocation before the rest of the topology arrives.

        case .appleDisplayLayout(let displays):
            noteAppleServerProtocolObserved()
            await updateRemoteDisplayRegions(displays)

        case .appleRemoteSessionState(let state):
            noteAppleServerProtocolObserved()
            handleAppleRemoteSessionState(state)

        case .desktopLayout(let layout):
            await updateRemoteDisplayRegions(layout.screens)

        case .mediaStreamOffer(let offer):
            noteAppleServerProtocolObserved()
            logger.info(
                "Media stream offer: stream=\(offer.streamID) type=\(offer.messageType ?? 0) "
                    + "audioPort=\(offer.audioStreamUDPPort ?? 0) "
                    + "videoPort=\(offer.videoStream1UDPPort ?? 0) "
                    + "displays=\(offer.videoStreamDisplayCount ?? 0) "
                    + "payloadBytes=\(offer.rawPayload.count)"
            )
            isHighPerformanceMode = true
            activeVideoDisplayCount = configuration.displaySizingMode == .matchClient
                ? min(configuration.displayCount,
                      offer.videoStreamDisplayCount ?? 1)
                : 1
            diagnostics.isHighPerformanceMode = true
            await startVideoStream(offer: offer)
            await refreshHandshakeDiagnostics(from: transport)

        case .udpDatagram(let datagram):
            routeAppleMediaRTPPacket(datagram)

        case .appleMediaRTPPacket(let packet):
            routeAppleMediaRTPPacket(packet)

        case .appleMediaUDPStarted(let localPort):
            logger.info("Apple media UDP started on local port \(localPort)")

        case .appleMediaControlRecord:
            break

        case .disconnected:
            handleDisconnected()
        }
    }

    private func handleStateChanged(_ protocolState: RFBProtocol.ConnectionState) {
        let newState = VNCConnectionState(from: protocolState)
        // Track the phase before the guards below: reconnect keeps the public
        // state pinned to .reconnecting while the replacement handshake
        // advances, but the overlay still wants the live phase text.
        connectionPhaseDescription = Self.phaseDescription(for: protocolState)
        // Keep the richer retry state visible while a replacement transport
        // progresses through its internal handshake states.
        if reconnectTask != nil {
            guard newState == .connected else { return }
        }
        // TransportSession emits its operational state before the ServerInit
        // event that publishes handshake metadata and creates the framebuffer.
        // Let handleServerInit own the public connected transition so observers
        // never see a partially initialized session.
        if newState == .connected {
            return
        }
        if hasEstablishedConnection, !intentionallyDisconnected,
           case .failed = newState {
            return
        }
        // Only update if it represents a meaningful change
        // (internal handshake states all map to .connecting)
        if newState != connectionState {
            connectionState = newState
        }
    }

    private static func phaseDescription(
        for protocolState: RFBProtocol.ConnectionState
    ) -> String? {
        switch protocolState {
        case .connecting:
            return String(localized: "Opening connection…", bundle: .module)
        case .waitingForProtocolVersion:
            return String(localized: "Negotiating protocol…", bundle: .module)
        case .waitingForSecurityTypes:
            return String(localized: "Negotiating security…", bundle: .module)
        case .authenticating:
            return String(localized: "Authenticating…", bundle: .module)
        case .waitingForAuthResult:
            return String(localized: "Verifying credentials…", bundle: .module)
        case .waitingForServerInit:
            return String(localized: "Starting remote session…", bundle: .module)
        case .idle, .operational, .disconnecting, .disconnected, .failed:
            return nil
        }
    }

    func handleServerInit(_ serverInit: ServerInit) async {
        logger.info("Connected: \(serverInit.name) (\(serverInit.framebufferWidth)x\(serverInit.framebufferHeight))")

        // ServerInit allocates a new framebuffer even when a reconnect kept
        // the previous complete image on screen. Its initial-frame coverage
        // and all queued presentation work are therefore a new generation.
        invalidateStandardFramebufferPresentation()

        serverName = serverInit.name
        framebufferWidth = Int(serverInit.framebufferWidth)
        framebufferHeight = Int(serverInit.framebufferHeight)
        acceptsDeferredAppleDisplayGeometry = framebufferWidth == 0
            || framebufferHeight == 0

        // Update diagnostics
        diagnostics.serverInit = serverInit
        diagnostics.handshakeCompleteTime = Date()

        // A capture backend can finish the RFB handshake before it knows the
        // desktop geometry (KDE/PipeWire and Apple's media path both do this
        // in the wild). Retire the previous renderer, but keep the connection
        // alive until a positive DesktopSize or media geometry arrives.
        framebuffer = nil
        renderer = nil
        if framebufferWidth > 0, framebufferHeight > 0 {
            _ = await applyStandardFramebufferGeometry(
                width: serverInit.framebufferWidth,
                height: serverInit.framebufferHeight)
        } else {
            logger.warning(
                "ServerInit has deferred framebuffer geometry "
                    + "\(framebufferWidth)x\(framebufferHeight); waiting for resize")
        }

        hasEstablishedConnection = true
        lastError = nil
        connectionState = .connected
    }

    /// A zero-sized ServerInit makes Apple's display layout authoritative for
    /// classic topology changes until DesktopSize, requested virtual geometry,
    /// or codec geometry provides a stronger source.
    private func installDeferredFramebufferFromRemoteDisplayLayoutIfPossible() async {
        guard acceptsDeferredAppleDisplayGeometry,
              configuration.displaySizingMode != .matchClient,
              let union = normalizedSelectedDisplayRegion(
                remoteDisplayRegions,
                displayCount: remoteDisplayRegions.count) else { return }
        let width = Int(union.width)
        let height = Int(union.height)
        guard width > 0, height > 0,
              width <= Int(UInt16.max), height <= Int(UInt16.max) else { return }
        await applyDesktopResizeMetadata(
            width: UInt16(width),
            height: UInt16(height))
    }

    func updateRemoteDisplayRegions(_ screens: [RFBScreenLayout]) async {
        guard !screens.isEmpty else { return }
        remoteDisplayRegionByID.removeAll(keepingCapacity: true)
        remoteDisplayRegionOrder = screens.map(\.id)
        remoteDisplayRegions = screens.map {
            let region = CGRect(
                x: Int($0.x), y: Int($0.y),
                width: Int($0.width), height: Int($0.height))
            remoteDisplayRegionByID[$0.id] = region
            return region
        }
        await installDeferredFramebufferFromRemoteDisplayLayoutIfPossible()
        applyDiscoveredRemoteMediaGeometry()
    }

    func updateRemoteDisplayRegions(
        _ displays: [AppleDisplayInfo]
    ) async {
        guard !displays.isEmpty else { return }
        remoteDisplayRegionByID.removeAll(keepingCapacity: true)
        remoteDisplayRegionOrder = displays.map(\.displayIndex)
        remoteDisplayRegions = displays.compactMap { display in
            guard display.width > 0, display.height > 0 else { return nil }
            let region = CGRect(
                x: Int(display.originX),
                y: Int(display.originY),
                width: Int(display.width),
                height: Int(display.height))
            remoteDisplayRegionByID[display.displayIndex] = region
            return region
        }
        await installDeferredFramebufferFromRemoteDisplayLayoutIfPossible()
        applyDiscoveredRemoteMediaGeometry()
    }

    /// ServerInit is the full physical desktop union, while Apple's media
    /// receiver targets the selected single or combined topology. Apply
    /// DisplayInfo as soon as it arrives so the band compositor and input
    /// aspect use the receiver's real geometry on first connections as well as
    /// reconnects.
    private func applyDiscoveredRemoteMediaGeometry() {
        guard isHighPerformanceMode,
              configuration.displaySizingMode == .remoteDisplay,
              let manager = videoStreamManager,
              !remoteDisplayRegions.isEmpty else { return }

        let selectedCount = min(
            max(1, configuration.displayCount),
            remoteDisplayRegions.count)
        guard let first = remoteDisplayRegions.first else { return }
        let selected = remoteDisplayRegions.prefix(selectedCount)
            .dropFirst()
            .reduce(first) { $0.union($1) }
        let width = Int(selected.width)
        let height = Int(selected.height)
        guard width > 0, height > 0 else { return }

        videoBandRenderer.setScreenSize(width: width, height: height)
        let queue = mediaQueue
        queue.async {
            manager.updateFrameGeometry(width: width, height: height)
        }
    }

    /// Selected framebuffer rectangle in the server's normalized desktop
    /// coordinates. Nil means the server has not described its monitor layout.
    var presentedFramebufferRegion: CGRect? {
        // Match Client replaces the physical monitor topology with equal-sized
        // virtual displays. DisplayInfo from the pre-reconfiguration desktop
        // can remain in flight, so its rectangles are not authoritative here.
        guard !(isHighPerformanceMode
                && configuration.displaySizingMode == .matchClient) else {
            return nil
        }
        return normalizedSelectedDisplayRegion(
            remoteDisplayRegions,
            displayCount: configuration.displayCount)
    }

    /// High Performance input is relative to the selected video canvas:
    /// Apple's server adds the active screen origin before HiDPI conversion.
    /// Standard framebuffer crops still need their offset within the desktop.
    var presentedInputOrigin: CGPoint {
        isHighPerformanceMode ? .zero : presentedFramebufferRegion?.origin ?? .zero
    }

    var presentedFramebufferSize: CGSize {
        presentedFramebufferRegion?.size ?? CGSize(
            width: framebufferWidth,
            height: framebufferHeight)
    }

    var presentedVideoDisplayRegions: [CGRect] {
        let count = max(1, activeVideoDisplayCount)
        if configuration.displaySizingMode != .matchClient,
           remoteDisplayRegions.count >= count {
            if count == 1,
               configuration.displayCount > 1,
               remoteDisplayRegions.count >= configuration.displayCount {
                // Apple's physical "All Displays" mode is one HEVC stream
                // whose format is the union of the selected monitor regions.
                // Present that stream once at the composite aspect ratio.
                let selected = Array(
                    remoteDisplayRegions.prefix(configuration.displayCount))
                guard let first = selected.first else { return [] }
                let union = selected.dropFirst().reduce(first) { $0.union($1) }
                return [CGRect(origin: .zero, size: union.size)]
            }
            let selected = Array(remoteDisplayRegions.prefix(count))
            guard let first = selected.first else { return [] }
            let union = selected.dropFirst().reduce(first) { $0.union($1) }
            return selected.map { $0.offsetBy(dx: -union.minX, dy: -union.minY) }
        }

        let totalWidth = max(1, framebufferWidth)
        let width = CGFloat(totalWidth) / CGFloat(count)
        let height = CGFloat(max(1, framebufferHeight))
        return (0..<count).map {
            CGRect(x: CGFloat($0) * width, y: 0, width: width, height: height)
        }
    }

    private func handleFramebufferUpdate(
        _ rects: [(FramebufferRect, Data)],
        from transport: TransportSession
    ) async -> Bool {
        guard transportSession === transport else { return false }

        for (rect, data) in rects {
            if isTraceEnabled {
                diagnostics.protocolTrace.recordReceived(
                    type: "FramebufferUpdate",
                    data: data,
                    details: "encoding=\(rect.encoding) rect=(\(rect.x),\(rect.y) \(rect.width)x\(rect.height))"
                )
            }

            if (rect.encoding == .desktopSize
                    || rect.encoding == .extendedDesktopSize),
               !rect.isSuccessfulDesktopResize {
                logger.warning(
                    "Ignoring rejected/invalid desktop resize status=\(rect.y) "
                        + "size=\(rect.width)x\(rect.height)")
            }
        }

        let announcedResize = rects.last(where: {
            $0.0.isSuccessfulDesktopResize
        })?.0
        if let resize = announcedResize {
            acceptsDeferredAppleDisplayGeometry = false
            // Publish the authoritative dimensions and install through the
            // same metadata path before initial-frame tracking sees this
            // batch. FramebufferRenderer's same-size resize is a locked no-op.
            if renderer == nil {
                await applyDesktopResizeMetadata(
                    width: resize.width,
                    height: resize.height)
            }
        }

        guard let renderer else {
            do {
                try deferFramebufferRectsUntilGeometry(rects)
                return true
            } catch let error as VNCProtocolError {
                await transport.terminateFromSessionConsumer(
                    error,
                    origin: "pre-geometry-framebuffer-buffer")
                return false
            } catch {
                let protocolError = VNCProtocolError.protocolViolation(
                    error.localizedDescription)
                await transport.terminateFromSessionConsumer(
                    protocolError,
                    origin: "pre-geometry-framebuffer-buffer")
                return false
            }
        }
        let renderRects: [(FramebufferRect, Data)]
        if deferredFramebufferRects.isEmpty {
            renderRects = rects
        } else {
            renderRects = deferredFramebufferRects + rects
            deferredFramebufferRects.removeAll(keepingCapacity: true)
            deferredFramebufferBytes = 0
        }
        let presentationGeneration = framebufferPresentationGeneration

        // Publish-only throttle: rects are always applied (persistent codec
        // state) and the transport credit is always returned, but the
        // full-framebuffer snapshot + image publish is capped at
        // targetFrameRate. A trailing snapshot guarantees the final state
        // always renders after a burst.
        let publishInterval = UInt64(
            1_000_000_000 / max(1, configuration.targetFrameRate))
        let renderStarted = DispatchTime.now().uptimeNanoseconds
        let publishDue = renderStarted &- lastImagePublishNanos >= publishInterval
        let carriesFramebufferPixels = StandardFramebufferPresentationPolicy
            .carriesFramebufferPixels(renderRects)
        let initialFramePresentationAllowed = initialFramePresentationTracker
            .ingest(
                renderRects,
                framebufferWidth: framebufferWidth,
                framebufferHeight: framebufferHeight)
        let displaySuspended = suspendsDisplayPresentation
            || VNCPresentationPolicy.isPresentationProhibited()
        let takeSnapshot = publishDue
            && carriesFramebufferPixels
            && initialFramePresentationAllowed
            && !displaySuspended
        let result = await withCheckedContinuation { continuation in
            framebufferRenderQueue.async {
                continuation.resume(
                    returning: renderer.applyBatch(
                        renderRects,
                        snapshot: takeSnapshot))
            }
        }
        // The old renderer must finish its serial codec work, but a transport
        // replacement while it ran retires every observable result from it.
        guard transportSession === transport,
              framebufferPresentationGeneration == presentationGeneration,
              self.renderer === renderer else { return false }
        if carriesFramebufferPixels && initialFramePresentationAllowed {
            standardFramebufferHasPresentablePixels = true
        }
        let renderFinished = DispatchTime.now().uptimeNanoseconds
        let renderMilliseconds = (renderFinished &- renderStarted) / 1_000_000
        if renderMilliseconds >= 100,
           (lastFramebufferRenderDiagnosticNanos == 0
                || renderFinished &- lastFramebufferRenderDiagnosticNanos
                    >= 1_000_000_000) {
            lastFramebufferRenderDiagnosticNanos = renderFinished
            let payloadBytes = renderRects.reduce(0) { $0 + $1.1.count }
            let encodings = renderRects.map { String(describing: $0.0.encoding) }
                .joined(separator: ",")
            logger.info(
                "Framebuffer decode/snapshot=\(renderMilliseconds)ms "
                    + "rects=\(renderRects.count) payload=\(payloadBytes)B "
                    + "encodings=\(encodings)")
        }

        for issue in result.issues {
            logger.warning("\(issue)")
        }
        if let width = result.resizedWidth,
           let height = result.resizedHeight {
            await applyDesktopResizeMetadata(width: width, height: height)
        }
        // Delivery-time recheck: the device can lock while applyBatch runs on
        // the render queue, making the pre-render gate sample stale. A
        // suppressed image falls through to the trailing-snapshot path, whose
        // task re-gates itself at publish time.
        if let image = result.image,
           !suspendsDisplayPresentation,
           !VNCPresentationPolicy.isPresentationProhibited() {
            trailingSnapshotTask?.cancel()
            trailingSnapshotTask = nil
            currentImage = image
            lastImagePublishNanos = DispatchTime.now().uptimeNanoseconds
            considerAppleLoginVisionFrame(
                .image(image),
                source: "Standard framebuffer snapshot")
        } else if (carriesFramebufferPixels && initialFramePresentationAllowed)
                    || displaySuspended {
            // Control-only DCT type 2 carries quantization tables, not pixels.
            // It must never publish the newly allocated black framebuffer or
            // anchor an image timer before the first image arrives.
            scheduleTrailingSnapshot(interval: publishInterval)
        }
        switch result.cursorUpdate {
        case .shape(let cursor):
            remoteCursor = cursor
            remoteCursorPresence = .described
        case .hidden:
            remoteCursor = nil
            remoteCursorPresence = .hidden
        case nil:
            break
        }
        return true
    }

    private func deferFramebufferRectsUntilGeometry(
        _ rects: [(FramebufferRect, Data)]
    ) throws {
        guard rects.count <= Self.maximumDeferredFramebufferRects
                - deferredFramebufferRects.count else {
            throw VNCProtocolError.protocolViolation(
                "Pre-geometry framebuffer backlog exceeded "
                    + "\(Self.maximumDeferredFramebufferRects) rectangles; "
                    + "terminating to preserve persistent compression state")
        }

        var resultingBytes = deferredFramebufferBytes
        for entry in rects {
            let (bytes, entryOverflow) = FramebufferRect.wireSize
                .addingReportingOverflow(entry.1.count)
            let (nextBytes, totalOverflow) = resultingBytes
                .addingReportingOverflow(bytes)
            guard !entryOverflow, !totalOverflow,
                  nextBytes <= Self.maximumDeferredFramebufferBytes else {
                throw VNCProtocolError.protocolViolation(
                    "Pre-geometry framebuffer backlog exceeded "
                        + "\(Self.maximumDeferredFramebufferBytes) bytes; "
                        + "terminating to preserve persistent compression state")
            }
            resultingBytes = nextBytes
        }
        deferredFramebufferRects.append(contentsOf: rects)
        deferredFramebufferBytes = resultingBytes
        if !rects.isEmpty {
            logger.debug(
                "Deferred \(deferredFramebufferRects.count) framebuffer rectangles "
                    + "until positive geometry arrives")
        }
    }

    /// Apply one live geometry transition to every consumer of framebuffer
    /// dimensions. The media stream remains connected; new SPS/PPS parameter
    /// sets reconfigure the public VideoToolbox session when they arrive.
    private func applyDesktopResizeMetadata(
        width: UInt16,
        height: UInt16,
        mediaDisplaySizeOverride: (width: Int, height: Int)? = nil
    ) async {
        let newWidth = Int(width)
        let newHeight = Int(height)
        guard newWidth > 0, newHeight > 0 else { return }
        let geometryChanged = await applyStandardFramebufferGeometry(
            width: width,
            height: height)
        guard geometryChanged || mediaDisplaySizeOverride != nil else { return }

        func mediaDisplaySize(at index: Int) -> (width: Int, height: Int) {
            if let mediaDisplaySizeOverride {
                return mediaDisplaySizeOverride
            }
            if isHighPerformanceMode,
               configuration.displaySizingMode != .matchClient,
               remoteDisplayRegions.indices.contains(index) {
                if index == 0,
                   activeVideoDisplayCount == 1,
                   configuration.displayCount > 1,
                   remoteDisplayRegions.count >= configuration.displayCount {
                    let selected = remoteDisplayRegions.prefix(
                        configuration.displayCount)
                    if let first = selected.first {
                        let union = selected.dropFirst().reduce(first) {
                            $0.union($1)
                        }
                        return (Int(union.width), Int(union.height))
                    }
                }
                let region = remoteDisplayRegions[index]
                return (Int(region.width), Int(region.height))
            }
            let width = activeVideoDisplayCount > 1
                ? newWidth / activeVideoDisplayCount
                : newWidth
            return (width, newHeight)
        }
        let primarySize = mediaDisplaySize(at: 0)
        videoBandRenderer.setScreenSize(
            width: primarySize.width,
            height: primarySize.height)
        if activeVideoDisplayCount > 1 {
            let secondarySize = mediaDisplaySize(at: 1)
            secondaryVideoBandRenderer.setScreenSize(
                width: secondarySize.width,
                height: secondarySize.height)
        }

        if let manager = videoStreamManager {
            let secondaryManager = secondaryVideoStreamManager
            let secondarySize = mediaDisplaySize(at: 1)
            mediaQueue.async {
                manager.updateFrameGeometry(
                    width: primarySize.width,
                    height: primarySize.height)
                secondaryManager?.updateFrameGeometry(
                    width: secondarySize.width,
                    height: secondarySize.height)
            }
        }
    }

    /// Keep the lossless framebuffer used for standard pixels, DCT control
    /// state, and cursor decoding synchronized without changing video decoder
    /// geometry. The physical All Displays media path needs this separation:
    /// its framebuffer is the display union while its codec raster may not be.
    @discardableResult
    private func applyStandardFramebufferGeometry(
        width: UInt16,
        height: UInt16
    ) async -> Bool {
        let newWidth = Int(width)
        let newHeight = Int(height)
        guard newWidth > 0, newHeight > 0 else { return false }
        let geometryChanged = newWidth != framebufferWidth
            || newHeight != framebufferHeight

        standardFramebufferGeometrySequence &+= 1
        let sequence = standardFramebufferGeometrySequence
        let presentationGeneration = framebufferPresentationGeneration
        let existingRenderer = renderer
        // Must match what the transport sent in SetPixelFormat — decoding
        // with the server's pre-negotiation format would corrupt every rect.
        let pixelFormat = configuration.effectivePixelFormat
        let installation: (Framebuffer, FramebufferRenderer)? =
            await withCheckedContinuation { continuation in
                framebufferRenderQueue.async {
                    if let existingRenderer {
                        existingRenderer.handleDesktopResize(
                            width: width,
                            height: height)
                        continuation.resume(returning: nil)
                    } else {
                        let framebuffer = Framebuffer(
                            width: newWidth,
                            height: newHeight,
                            pixelFormat: pixelFormat)
                        continuation.resume(returning: (
                            framebuffer,
                            FramebufferRenderer(
                                framebuffer: framebuffer,
                                pixelFormat: pixelFormat)))
                    }
                }
            }
        guard sequence == standardFramebufferGeometrySequence,
              presentationGeneration == framebufferPresentationGeneration else {
            return false
        }
        if let installation {
            guard renderer == nil else { return false }
            framebuffer = installation.0
            renderer = installation.1
            logger.info("Installed framebuffer at \(newWidth)x\(newHeight)")
        } else {
            guard renderer === existingRenderer else { return false }
        }
        if geometryChanged {
            logger.info(
                "Applying desktop resize \(framebufferWidth)x\(framebufferHeight) "
                    + "-> \(newWidth)x\(newHeight)")
            framebufferWidth = newWidth
            framebufferHeight = newHeight
        }
        return geometryChanged
    }

    func applyRequestedRemoteDisplayGeometry(_ requested: RemoteDisplaySize) async {
        acceptsDeferredAppleDisplayGeometry = false
        await applyDesktopResizeMetadata(
            width: requested.pixelWidth,
            height: requested.pixelHeight)
    }

    /// Apply the full-frame dimensions carried by the one-tile HEVC format.
    /// Apple's resize path can renegotiate AVC without emitting DesktopSize,
    /// so the public codec format is authoritative for both display layout and
    /// input-coordinate bounds in high-performance mode.
    private func applyMediaStreamGeometry(
        _ geometry: VideoFrameGeometry,
        from manager: VideoStreamManager
    ) async {
        guard videoStreamManager === manager else { return }
        guard manager.currentMediaGeneration == geometry.mediaGeneration else { return }
        guard geometry.mediaGeneration >= appliedMediaGeometryGeneration else { return }
        guard geometry.width > 0, geometry.height > 0,
              geometry.width <= Int(UInt16.max),
              geometry.height <= Int(UInt16.max) else { return }

        appliedMediaGeometryGeneration = geometry.mediaGeneration
        await applyAcceptedMediaStreamGeometry(geometry)
    }

    func applyAcceptedMediaStreamGeometry(_ geometry: VideoFrameGeometry) async {
        guard geometry.width > 0, geometry.height > 0,
              geometry.width <= Int(UInt16.max),
              geometry.height <= Int(UInt16.max) else { return }
        acceptsDeferredAppleDisplayGeometry = false
        if configuration.displaySizingMode != .matchClient,
           configuration.displayCount > 1,
           remoteDisplayRegions.count >= configuration.displayCount {
            // In Apple's physical All Displays mode the codec raster can stay
            // at the primary encoder size. ScreenConfiguration is the native
            // authority for the combined canvas and pointer coordinates.
            guard let union = normalizedSelectedDisplayRegion(
                remoteDisplayRegions,
                displayCount: configuration.displayCount) else { return }
            let width = Int(union.width)
            let height = Int(union.height)
            guard width > 0, height > 0,
                  width <= Int(UInt16.max), height <= Int(UInt16.max) else { return }
            videoBandRenderer.setScreenSize(width: width, height: height)
            await applyStandardFramebufferGeometry(
                width: UInt16(width),
                height: UInt16(height))
            return
        }
        videoBandRenderer.setScreenSize(
            width: geometry.width,
            height: geometry.height)

        // A physical multi-display session can contain unequal monitors. Its
        // server layout remains authoritative for the aggregate canvas; the
        // primary stream's format only describes display zero.
        guard activeVideoDisplayCount == 1
                || configuration.displaySizingMode == .matchClient else {
            return
        }
        let aggregateWidth = geometry.width * activeVideoDisplayCount
        guard aggregateWidth <= Int(UInt16.max) else { return }

        logger.info(
            "Applying HEVC media geometry \(aggregateWidth)x\(geometry.height) "
                + "generation=\(geometry.mediaGeneration)")
        await applyDesktopResizeMetadata(
            width: UInt16(aggregateWidth),
            height: UInt16(geometry.height),
            mediaDisplaySizeOverride: (
                width: geometry.width,
                height: geometry.height))
    }

    private func handleError(_ error: VNCProtocolError) {
        logger.error("Protocol error: \(error.localizedDescription)")
        lastError = error
        diagnostics.lastError = error
    }

    private func handleDisconnected() {
        logger.info("Disconnected")
        cleanupTransport(clearCredentials: intentionallyDisconnected)

        // A manual configuration restart or media-bootstrap recovery already
        // owns the replacement attempt. Do not publish `.disconnected` (which
        // host apps interpret as an intentional close) or enqueue a duplicate
        // reconnect when the retired transport reports its shutdown.
        if reconnectTask != nil { return }

        guard !intentionallyDisconnected,
              hasEstablishedConnection,
              activeCredentials != nil,
              configuration.reconnectionPolicy.isEnabled,
              configuration.reconnectionPolicy.maximumAttempts > 0 else {
            connectionState = .disconnected
            return
        }

        // A loss surfacing right after a foreground edge is the suspended
        // socket being noticed, not a network fault. Sleeping out the backoff
        // before redialing a server that was never unreachable just adds a
        // second of dead time to every app switch.
        #if canImport(UIKit)
        if consumeSuspensionResumeWindow() {
            // Uncounted for the same reason as the resume dial above: this
            // socket was reclaimed by iOS while the app was not running, so
            // charging the redial to the recovery budget would spend it on a
            // failure the network had no part in.
            scheduleReconnect(
                immediate: true,
                freeLeadingAttempt: true,
                cause: "app resumed; the suspended session's socket was reclaimed")
            return
        }
        #endif

        scheduleReconnect()
    }

    // MARK: - Private: Helpers

    private func cleanupTransport(clearCredentials: Bool) {
        eventTask?.cancel()
        eventTask = nil
        remoteDisplayResizeTask?.cancel()
        remoteDisplayResizeTask = nil
        lastRequestedClientDisplaySize = nil
        invalidateInputQueue()
        transportSession = nil
        invalidateStandardFramebufferPresentation()
        if clearCredentials {
            activeCredentials = nil
        }
        // An automatic reconnect (credentials retained) tears the transport
        // down mid-bootstrap; the user's approved password send must outlive
        // it or a tap during bootstrap silently evaporates.
        resetAppleLoginPromptState(
            preservePendingPasswordSend: !clearCredentials)

        // These values describe the retired transport's negotiated media and
        // display topology. Keeping them across a configuration reconnect can
        // leave SwiftUI rendering the High Performance video path after the
        // replacement connection has negotiated Standard framebuffer mode.
        isHighPerformanceMode = false
        supportsRemoteClipboardRequest = false
        supportsRemoteSharedClipboardControl = false
        resetCurtainState()
        negotiatedContentEncryption = nil
        serverCapabilities = nil
        activeVideoDisplayCount = 1
        remoteDisplayRegions = []
        remoteDisplayRegionByID = [:]
        remoteDisplayRegionOrder = []
        remoteCursor = nil
        remoteCursorPresence = .undescribed
        negotiatedCursorRendering = nil
        diagnostics.isHighPerformanceMode = false

        videoStreamManager?.stopStream()
        videoStreamManager = nil
        secondaryVideoStreamManager?.stopStream()
        secondaryVideoStreamManager = nil
        remoteAudioPlayer?.stop()
        remoteAudioPlayer = nil
        appleMediaPlaybackSynchronizer = nil
    }

    /// Adopt the server's authoritative curtain facts and settle any request
    /// waiting on them.
    private func applyCurtainState(_ state: AppleRemoteSessionState) {
        if supportsCurtainMode != state.curtainToggleAvailable {
            supportsCurtainMode = state.curtainToggleAvailable
        }
        if isCurtained != state.curtained {
            isCurtained = state.curtained
        }
        if let requested = pendingCurtainRequest, requested == state.curtained {
            curtainConfirmationTask?.cancel()
            curtainConfirmationTask = nil
            pendingCurtainRequest = nil
            curtainChangeFailed = false
        }
    }

    private func handleAppleRemoteSessionState(
        _ state: AppleRemoteSessionState
    ) {
        lastSessionStateAnnouncementNanos = DispatchTime.now().uptimeNanoseconds
        applyCurtainState(state)
        let promptEnabled =
            configuration.promptForLoginPasswordAtLoginWindow
        let passwordAvailable = canSendLoginPassword
        let shouldPrompt = appleLoginPromptTracker.update(
            isLoginActive: state.requiresLogin,
            promptEnabled: promptEnabled,
            canSendPassword: passwordAvailable)
        logger.debug(
            "Apple login state reached session: loginWindow="
                + "\(state.loginWindowActive) "
                + "lockScreen=\(state.loginWindowLockScreenActive) "
                + "enabled=\(promptEnabled) "
                + "canSendPassword=\(passwordAvailable) "
                + "willPrompt=\(shouldPrompt)")
        if !state.requiresLogin {
            // Ordinary user locks deliberately arrive as false here. Preserve
            // a prompt established from the full-frame visual fallback.
            if !appleLoginVisionDetected {
                loginPasswordPromptPending = false
            }
        } else if shouldPrompt {
            appleLoginVisionAttemptCount = Self.appleLoginVisionMaximumAttempts
            appleLoginVisionRetryTask?.cancel()
            appleLoginVisionRetryTask = nil
            if loginPasswordSendGate.isPending {
                // The user already approved a send that is waiting for
                // display stability; a second dialog would double-type the
                // password. Treat the announcement as a delivery kick.
                logger.info(
                    "Login Window re-announced while a password send is "
                        + "queued; driving delivery instead of re-prompting")
                ensurePendingLoginPasswordProgress(
                    reason: "login window announced")
            } else {
                offerLoginPasswordPrompt(
                    source: "server entered Login Window state")
            }
        }
    }

    private func resetAppleLoginPromptState(
        preservePendingPasswordSend: Bool = false
    ) {
        appleLoginPromptTracker.reset()
        appleLoginVisionTask?.cancel()
        appleLoginVisionTask = nil
        appleLoginVisionRetryTask?.cancel()
        appleLoginVisionRetryTask = nil
        appleLoginVisionStabilityTask?.cancel()
        appleLoginVisionStabilityTask = nil
        appleLoginVisionLatestFrame = nil
        appleLoginVisionAttemptCount = 0
        appleLoginVisionLastAttemptNanos = 0
        appleLoginVisionGeneration &+= 1
        appleLoginVisionDetected = false
        appleLoginVisionPromptOffered = false
        appleLoginVisionHighPerformanceGeneration = nil
        appleServerProtocolObserved = false
        cancelScheduledLoginPasswordSend()
        cancelLoginPasswordSendWatchdog()
        loginPasswordPromptRecheckTask?.cancel()
        loginPasswordPromptRecheckTask = nil
        lastSessionStateAnnouncementNanos = 0
        // An explicit disconnect/new connect begins a new logical login
        // attempt, so a password delivered by the previous connection must
        // not suppress its prompt. Automatic transport recovery preserves
        // both the approved pending send and the short post-delivery debounce
        // because it is still the same remote login attempt.
        if !preservePendingPasswordSend {
            lastLoginPasswordDeliveryNanos = 0
        }
        loginPasswordSendGate.reset(
            preservePendingSend: preservePendingPasswordSend
                && !(activeCredentials?.password.isEmpty ?? true))
        loginPasswordPromptPending = false
    }

    private static let appleLoginVisionMaximumAttempts = 3
    private static let appleLoginVisionMinimumIntervalNanos: UInt64 = 700_000_000
    private static let appleLoginVisionHighPerformanceStabilityDelay =
        Duration.milliseconds(350)
    /// Continuous display quiet time required before the first key of a
    /// password send. Transport settlement plus a validated final-size frame
    /// arm the send; this hysteresis only defers it while transitions are
    /// still landing, so a tap on a long-quiet login screen types instantly.
    private static let loginPasswordQuietPeriodNanos: UInt64 = 700_000_000
    /// Bounded retry cadence for a pending send: re-attempt frame adoption or
    /// keyframe recovery, then force-deliver once the transport confirms no
    /// resize remains in flight (some servers never answer FIR, so a fresh
    /// frame can be genuinely unobtainable). Worst case ~2.8 s; the normal
    /// path sends the moment a final-size frame validates.
    private static let loginPasswordSendWatchdogInterval =
        Duration.milliseconds(700)
    private static let loginPasswordSendWatchdogMaxAttempts = 4
    /// A login-state signal inside this window after a delivery is vetted
    /// against fresh announcements before it may become a dialog: the unlock
    /// and the loginwindow→session capture handoff bounce the server's login
    /// state, sometimes with stale flags, and a full login can take tens of
    /// seconds.
    private static let loginPasswordPromptDebounceWindowNanos: UInt64 =
        30_000_000_000
    private static let loginPasswordPromptRecheckDelay =
        Duration.milliseconds(2_500)
    private static let loginPasswordPromptRecheckMaxRounds = 4

    /// The first committed frame of a replacement generation restarts the
    /// quiet clock: the visible content just changed wholesale, even when no
    /// resize request or settle edge announced it.
    private func noteCommittedFrameGenerationForLoginQuietClock(
        _ generation: UInt64
    ) {
        guard lastCommittedFrameGeneration != generation else { return }
        lastCommittedFrameGeneration = generation
        lastLoginDisplayTransitionNanos = DispatchTime.now().uptimeNanoseconds
    }

    /// A server capture restart announces a replacement media generation
    /// without necessarily staging a resize, so the settle-edge signals never
    /// see it. Restart the quiet clock and retire any armed send token; only
    /// a frame from the new generation may validate a send again.
    private func noteAppleMediaGenerationTransitionForLoginSend() {
        lastLoginDisplayTransitionNanos = DispatchTime.now().uptimeNanoseconds
        loginPasswordSendGate.mediaGenerationChanged()
        cancelScheduledLoginPasswordSend()
        if loginPasswordSendGate.isPending {
            ensurePendingLoginPasswordProgress(
                reason: "media generation replaced")
        }
    }

    private func noteHighPerformanceFrameForPendingLoginPassword(
        _ pixelBuffer: CVPixelBuffer,
        mediaGeneration: UInt64
    ) {
        guard isHighPerformanceMode,
              configuration.displaySizingMode == .matchClient,
              isEligibleHighPerformanceLoginVisionFrame(pixelBuffer),
              let token = loginPasswordSendGate.noteEligibleFrame(
                mediaGeneration: mediaGeneration) else { return }
        scheduleLoginPasswordSendAfterStability(token: token)
    }

    private func noteRemoteDisplayResizeSettled(
        _ settled: Bool,
        sequence: UInt64
    ) {
        guard sequence > appleResizeSettledSequenceApplied else { return }
        appleResizeSettledSequenceApplied = sequence
        if settled != loginPasswordSendGate.isTransportSettled {
            lastLoginDisplayTransitionNanos =
                DispatchTime.now().uptimeNanoseconds
        }
        loginPasswordSendGate.transportSettled(settled)
        let pending = loginPasswordSendGate.isPending
        logger.debug(
            "Match Client resize transport settled=\(settled) "
                + "passwordPending=\(pending)")
        if !settled {
            cancelScheduledLoginPasswordSend()
        } else {
            ensurePendingLoginPasswordProgress(reason: "resize settled")
        }
    }

    /// Offer the confirmation dialog, debouncing announcements that arrive
    /// in the wake of a delivery: the unlock and the session handoff bounce
    /// the server's login state — sometimes with stale flags — and those
    /// transients must not present a second dialog for a password that just
    /// landed. Display logic only — no path here ever sends the password
    /// without a fresh confirmation.
    private func offerLoginPasswordPrompt(source: String) {
        let sinceDelivery = DispatchTime.now().uptimeNanoseconds
            &- lastLoginPasswordDeliveryNanos
        if lastLoginPasswordDeliveryNanos != 0,
           sinceDelivery < Self.loginPasswordPromptDebounceWindowNanos {
            scheduleLoginPasswordPromptRecheck(source: source)
            return
        }
        loginPasswordPromptPending = true
        logger.info("Login password prompt offered (\(source))")
    }

    /// Only fresh evidence may resurrect the dialog after a delivery: the
    /// tracker's stored state was last written by the very announcement being
    /// vetted, so consulting it directly is circular. Apple servers repeat
    /// session-state announcements while a layout is stable, so wait for one
    /// that arrives after this deferral began — it reflects the actual
    /// outcome of the delivered password. Servers that never announce state
    /// have no stale-bounce problem; their prompt shows after one round.
    private func scheduleLoginPasswordPromptRecheck(source: String) {
        guard loginPasswordPromptRecheckTask == nil else { return }
        let deferralStartNanos = DispatchTime.now().uptimeNanoseconds
        logger.info(
            "Deferring login prompt arriving in a delivery's wake (\(source))")
        loginPasswordPromptRecheckTask = Task { [weak self] in
            for _ in 1...Self.loginPasswordPromptRecheckMaxRounds {
                try? await Task.sleep(
                    for: Self.loginPasswordPromptRecheckDelay)
                guard let self, !Task.isCancelled else { return }
                guard self.canSendLoginPassword,
                      !self.loginPasswordSendGate.isPending,
                      !self.loginPasswordPromptPending else {
                    self.loginPasswordPromptRecheckTask = nil
                    return
                }
                if self.lastSessionStateAnnouncementNanos == 0 {
                    self.loginPasswordPromptRecheckTask = nil
                    self.loginPasswordPromptPending = true
                    self.logger.info(
                        "Login prompt offered after deferral; this server "
                            + "does not announce session state (\(source))")
                    return
                }
                guard self.lastSessionStateAnnouncementNanos
                        > deferralStartNanos else {
                    continue
                }
                self.loginPasswordPromptRecheckTask = nil
                if self.appleLoginPromptTracker.isLoginActive {
                    self.loginPasswordPromptPending = true
                    self.logger.info(
                        "Fresh announcement confirms the login screen "
                            + "persists; prompting (\(source))")
                } else {
                    self.logger.info(
                        "Fresh announcement shows no login needed; the "
                            + "delivered password logged in — no second "
                            + "prompt")
                }
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.loginPasswordPromptRecheckTask = nil
            self.logger.info(
                "No fresh session-state evidence arrived after the "
                    + "delivery; staying silent (\(source))")
        }
    }

    /// Drive a queued password send forward without waiting for a frame a
    /// static Login Window may never produce: adopt the retained final-size
    /// frame when its media generation proves it live, otherwise ask the
    /// server for a fresh keyframe and let the normal commit path validate it.
    /// A bounded watchdog covers signals that never arrive.
    private func ensurePendingLoginPasswordProgress(reason: String) {
        guard loginPasswordSendGate.isPending else { return }
        if loginPasswordSendGate.isTransportSettled,
           loginPasswordSendStabilityTask == nil,
           let token = loginPasswordSendGate.adoptRetainedFrame(
               liveMediaGeneration: videoBandRenderer.streamGenerationCount) {
            logger.info(
                "Adopting final-size frame that preceded resize settlement "
                    + "(\(reason))")
            scheduleLoginPasswordSendAfterStability(token: token)
            return
        }
        if loginPasswordSendGate.isTransportSettled,
           loginPasswordSendGate.stableCandidate == nil {
            requestLoginPasswordKeyframe(reason: reason)
        }
        startLoginPasswordSendWatchdog()
    }

    private func requestLoginPasswordKeyframe(reason: String) {
        guard isHighPerformanceMode, let transport = transportSession else {
            return
        }
        logger.info(
            "Requesting keyframe so the pending password send can validate "
                + "the final display (\(reason))")
        Task { await transport.requestVideoKeyframe() }
    }

    /// Re-attempts adoption or keyframe recovery on a short cadence while a
    /// send stays pending, then force-delivers the user's explicit request
    /// once the transport itself confirms no resize is in flight. The happy
    /// path never waits on this timer.
    private func startLoginPasswordSendWatchdog() {
        guard loginPasswordSendWatchdogTask == nil else { return }
        loginPasswordSendWatchdogTask = Task { [weak self] in
            for attempt in 1...Self.loginPasswordSendWatchdogMaxAttempts {
                try? await Task.sleep(
                    for: Self.loginPasswordSendWatchdogInterval)
                guard let self, !Task.isCancelled else { return }
                guard self.loginPasswordSendGate.isPending else {
                    self.loginPasswordSendWatchdogTask = nil
                    return
                }
                if self.loginPasswordSendStabilityTask != nil { continue }
                // The settled sink can lose an edge; the transport's direct
                // answer is authoritative.
                if !self.loginPasswordSendGate.isTransportSettled,
                   let transport = self.transportSession,
                   await transport.isAppleRemoteDisplayResizeSettled {
                    self.noteRemoteDisplayResizeSettled(
                        true,
                        sequence: self.appleResizeSettledSequencer.next())
                    if self.loginPasswordSendStabilityTask != nil { continue }
                }
                guard self.loginPasswordSendGate.isTransportSettled else {
                    continue
                }
                if let token = self.loginPasswordSendGate.adoptRetainedFrame(
                    liveMediaGeneration:
                        self.videoBandRenderer.streamGenerationCount) {
                    self.scheduleLoginPasswordSendAfterStability(token: token)
                    continue
                }
                self.logger.warning(
                    "Password send still pending after resize "
                        + "(attempt \(attempt)); requesting keyframe")
                self.requestLoginPasswordKeyframe(
                    reason: "watchdog attempt \(attempt)")
            }
            guard let self, !Task.isCancelled else { return }
            self.loginPasswordSendWatchdogTask = nil
            guard self.loginPasswordSendGate.isPending,
                  self.loginPasswordSendStabilityTask == nil,
                  self.canSendLoginPassword,
                  let password = self.activeCredentials?.password else {
                return
            }
            let transportSettled: Bool
            if self.loginPasswordSendGate.isTransportSettled {
                transportSettled = true
            } else if let transport = self.transportSession {
                transportSettled =
                    await transport.isAppleRemoteDisplayResizeSettled
            } else {
                transportSettled = false
            }
            let quietElapsed = DispatchTime.now().uptimeNanoseconds
                &- self.lastLoginDisplayTransitionNanos
            let loginEvidenceCurrent =
                self.appleLoginPromptTracker.isLoginActive
                    || self.appleLoginVisionDetected
            // This is the only path that can type without a validated frame,
            // and the send is unrepeatable: the password crosses the wire at
            // most once per user confirmation. Never fire it into a display
            // that transitioned moments ago or shows no login screen.
            guard transportSettled,
                  quietElapsed >= Self.loginPasswordQuietPeriodNanos,
                  loginEvidenceCurrent,
                  self.loginPasswordSendGate.forceConsumePending() else {
                self.logger.warning(
                    "Queued password send is holding: settled="
                        + "\(transportSettled) "
                        + "quietMs=\(quietElapsed / 1_000_000) "
                        + "loginEvidence=\(loginEvidenceCurrent)")
                return
            }
            self.logger.warning(
                "Stability signals never converged after resize; sending "
                    + "login password now")
            self.sendLoginPasswordNow(password)
        }
    }

    private func cancelLoginPasswordSendWatchdog() {
        loginPasswordSendWatchdogTask?.cancel()
        loginPasswordSendWatchdogTask = nil
    }

    private func scheduleLoginPasswordSendAfterStability(
        token: LoginPasswordSendStabilityGate.Token
    ) {
        if loginPasswordSendScheduledToken == token,
           loginPasswordSendStabilityTask != nil {
            return
        }
        cancelScheduledLoginPasswordSend()
        let displayRevision = token.displayRevision
        let mediaGeneration = token.mediaGeneration
        logger.debug(
            "Final Match Client frame eligible for password send; "
                + "waiting for remote input readiness: "
                + "displayRevision=\(displayRevision) "
                + "mediaGeneration=\(mediaGeneration)")
        loginPasswordSendScheduledToken = token
        loginPasswordSendStabilityTask = Task { [weak self] in
            // Start typing only after the display has been quiet for the
            // full hysteresis window. A tap on an already-quiet login screen
            // proceeds immediately; near a resize cascade, every new
            // transition both extends this wait and invalidates the token,
            // so a send can never begin inside a short stable gap between
            // steps — that is how passwords got half-typed into a capture
            // about to restart.
            while !Task.isCancelled {
                guard let self else { return }
                let elapsed = DispatchTime.now().uptimeNanoseconds
                    &- self.lastLoginDisplayTransitionNanos
                if elapsed >= Self.loginPasswordQuietPeriodNanos { break }
                let remaining = Self.loginPasswordQuietPeriodNanos - elapsed
                try? await Task.sleep(for: .nanoseconds(Int64(remaining)))
            }
            guard let self, !Task.isCancelled else { return }
            self.loginPasswordSendStabilityTask = nil
            self.loginPasswordSendScheduledToken = nil
            guard self.isHighPerformanceMode,
                  self.configuration.displaySizingMode == .matchClient,
                  self.canSendLoginPassword,
                  let password = self.activeCredentials?.password else { return }
            guard self.loginPasswordSendGate.consume(token) else {
                // The token was superseded while this send was queued; keep
                // the user's request alive instead of dropping it silently.
                self.ensurePendingLoginPasswordProgress(
                    reason: "send token superseded")
                return
            }
            self.cancelLoginPasswordSendWatchdog()
            self.sendLoginPasswordNow(password)
        }
    }

    private func cancelScheduledLoginPasswordSend() {
        loginPasswordSendStabilityTask?.cancel()
        loginPasswordSendStabilityTask = nil
        loginPasswordSendScheduledToken = nil
    }

    /// Remember that a negotiated Apple-only message has arrived. Media UDP
    /// can deliver a complete frame before its control-channel layout record;
    /// replay the retained candidate when that race resolves rather than
    /// waiting for a second frame a static login screen may never produce.
    private func noteAppleServerProtocolObserved() {
        guard !appleServerProtocolObserved else { return }
        appleServerProtocolObserved = true
        guard appleLoginVisionLatestFrame != nil else { return }
        logger.debug(
            "Apple protocol observed after a retained login Vision candidate")
        driveAppleLoginVisionFromLatestCandidate()
    }

    /// Inspect a bounded burst of composited full frames. The cheap guards run
    /// on the main actor; Vision itself runs at utility priority. A later
    /// authoritative Apple login-state event does not require OCR.
    private func considerAppleLoginVisionFrame(
        _ frame: AppleLoginVisionFrame,
        source: String,
        highPerformanceGeneration: UInt64? = nil
    ) {
        guard configuration.promptForLoginPasswordAtLoginWindow,
              canSendLoginPassword else { return }

        if let highPerformanceGeneration {
            let previousGeneration = appleLoginVisionHighPerformanceGeneration
            if previousGeneration != highPerformanceGeneration {
                appleLoginVisionHighPerformanceGeneration =
                    highPerformanceGeneration
                if previousGeneration != nil {
                    restartAppleLoginVisionForDisplayTransition(
                        reason: "High Performance media generation changed")
                }
            }

            guard case .pixelBuffer(let pixelBuffer) = frame,
                  isEligibleHighPerformanceLoginVisionFrame(pixelBuffer)
            else { return }
        }

        appleLoginVisionLatestFrame = (
            frame,
            source,
            highPerformanceGeneration)
        guard appleServerProtocolObserved else {
            logger.debug(
                "Retaining login Vision candidate until Apple protocol is observed")
            return
        }
        driveAppleLoginVisionFromLatestCandidate()
    }

    func considerAppleLoginVisionImageForTesting(
        _ image: CGImage,
        source: String = "test"
    ) {
        considerAppleLoginVisionFrame(.image(image), source: source)
    }

    private func driveAppleLoginVisionFromLatestCandidate() {
        guard appleServerProtocolObserved,
              let latest = appleLoginVisionLatestFrame else { return }
        guard appleLoginVisionAttemptCount
                < Self.appleLoginVisionMaximumAttempts else { return }
        if let mediaGeneration = latest.highPerformanceGeneration {
            scheduleAppleLoginVisionAfterHighPerformanceStability(
                mediaGeneration: mediaGeneration)
        } else {
            startAppleLoginVision(
                latest.frame,
                source: latest.source)
        }
    }

    /// A Match Client resize can publish the old complete surface while a new
    /// virtual display is being negotiated. Never spend OCR work on a surface
    /// whose dimensions differ from the newest requested display.
    func isEligibleHighPerformanceLoginVisionFrame(
        _ pixelBuffer: CVPixelBuffer
    ) -> Bool {
        guard configuration.displaySizingMode == .matchClient,
              let expected = lastRequestedClientDisplaySize
                ?? preparedClientDisplaySize else { return true }
        return CVPixelBufferGetWidth(pixelBuffer) == Int(expected.pixelWidth)
            && CVPixelBufferGetHeight(pixelBuffer) == Int(expected.pixelHeight)
    }

    /// The first committed frame of a replacement generation is complete, but
    /// Match Client may immediately supersede that generation during window or
    /// display transitions. A short generation-scoped delay keeps Vision off
    /// those transient surfaces without requiring a second video frame from a
    /// static lock screen.
    private func scheduleAppleLoginVisionAfterHighPerformanceStability(
        mediaGeneration: UInt64
    ) {
        guard appleLoginVisionStabilityTask == nil,
              appleLoginVisionTask == nil,
              appleLoginVisionRetryTask == nil,
              appleLoginVisionAttemptCount
                < Self.appleLoginVisionMaximumAttempts else { return }
        let generation = appleLoginVisionGeneration
        appleLoginVisionStabilityTask = Task { [weak self] in
            try? await Task.sleep(
                for: Self.appleLoginVisionHighPerformanceStabilityDelay)
            guard let self, !Task.isCancelled,
                  generation == self.appleLoginVisionGeneration,
                  mediaGeneration
                    == self.appleLoginVisionHighPerformanceGeneration,
                  let latest = self.appleLoginVisionLatestFrame,
                  latest.highPerformanceGeneration == mediaGeneration else {
                return
            }
            self.appleLoginVisionStabilityTask = nil
            self.startAppleLoginVision(
                latest.frame,
                source: latest.source)
        }
    }

    private func restartAppleLoginVisionForDisplayTransition(reason: String) {
        guard !appleLoginPromptTracker.isLoginActive,
              !appleLoginVisionDetected,
              !appleLoginVisionPromptOffered else { return }
        appleLoginVisionTask?.cancel()
        appleLoginVisionTask = nil
        appleLoginVisionRetryTask?.cancel()
        appleLoginVisionRetryTask = nil
        appleLoginVisionStabilityTask?.cancel()
        appleLoginVisionStabilityTask = nil
        appleLoginVisionLatestFrame = nil
        appleLoginVisionAttemptCount = 0
        appleLoginVisionLastAttemptNanos = 0
        appleLoginVisionGeneration &+= 1
        logger.debug("Restarting Apple login Vision after \(reason)")
    }

    private func startAppleLoginVision(
        _ frame: AppleLoginVisionFrame,
        source: String
    ) {

        guard !appleLoginPromptTracker.isLoginActive,
              !appleLoginVisionDetected,
              !appleLoginVisionPromptOffered,
              appleLoginVisionAttemptCount
                < Self.appleLoginVisionMaximumAttempts,
              appleLoginVisionTask == nil else { return }

        let now = DispatchTime.now().uptimeNanoseconds
        guard appleLoginVisionLastAttemptNanos == 0
                || now &- appleLoginVisionLastAttemptNanos
                    >= Self.appleLoginVisionMinimumIntervalNanos else {
            return
        }

        appleLoginVisionAttemptCount += 1
        appleLoginVisionRetryTask?.cancel()
        appleLoginVisionRetryTask = nil
        appleLoginVisionLastAttemptNanos = now
        let attempt = appleLoginVisionAttemptCount
        let generation = appleLoginVisionGeneration
        let analysisOverride = appleLoginVisionAnalysisOverrideForTesting
        logger.debug(
            "Apple login Vision attempt \(attempt)/"
                + "\(Self.appleLoginVisionMaximumAttempts) source=\(source)")

        appleLoginVisionTask = Task { [weak self] in
            let outcome = await Task.detached(priority: .utility) {
                let started = DispatchTime.now().uptimeNanoseconds
                do {
                    let analysis: AppleLoginTextAnalysis
                    if let analysisOverride {
                        analysis = try analysisOverride()
                    } else {
                        switch frame {
                        case .image(let image):
                            analysis = try AppleLoginScreenDetector.recognize(
                                cgImage: image)
                        case .pixelBuffer(let pixelBuffer):
                            analysis = try AppleLoginScreenDetector.recognize(
                                pixelBuffer: pixelBuffer)
                        }
                    }
                    return AppleLoginVisionOutcome(
                        analysis: analysis,
                        errorDescription: nil,
                        elapsedMilliseconds:
                            (DispatchTime.now().uptimeNanoseconds &- started)
                                / 1_000_000)
                } catch {
                    return AppleLoginVisionOutcome(
                        analysis: nil,
                        errorDescription: error.localizedDescription,
                        elapsedMilliseconds:
                            (DispatchTime.now().uptimeNanoseconds &- started)
                                / 1_000_000)
                }
            }.value

            guard let self, !Task.isCancelled,
                  generation == self.appleLoginVisionGeneration else { return }
            self.appleLoginVisionTask = nil

            guard let analysis = outcome.analysis else {
                let errorText = outcome.errorDescription ?? "unknown error"
                self.logger.warning(
                    "Apple login Vision attempt \(attempt) failed after "
                        + "\(outcome.elapsedMilliseconds)ms: "
                        + errorText)
                if attempt < Self.appleLoginVisionMaximumAttempts {
                    self.scheduleAppleLoginVisionRetry(generation: generation)
                }
                return
            }
            self.logger.debug(
                "Apple login Vision result attempt=\(attempt) "
                    + "detected=\(analysis.isLoginScreen) "
                    + "lines=\(analysis.recognizedLineCount) "
                    + "evidence=\(analysis.evidence) "
                    + "elapsed=\(outcome.elapsedMilliseconds)ms")

            if analysis.isLoginScreen {
                self.appleLoginVisionDetected = true
                self.appleLoginVisionPromptOffered = true
                if self.loginPasswordSendGate.isPending {
                    self.logger.info(
                        "Apple lock screen detected while a password send is "
                            + "queued; driving delivery instead of "
                            + "re-prompting")
                    self.ensurePendingLoginPasswordProgress(
                        reason: "lock screen detected")
                } else {
                    self.offerLoginPasswordPrompt(
                        source: "lock screen detected from full-frame Vision")
                }
            } else if attempt == Self.appleLoginVisionMaximumAttempts {
                self.logger.debug(
                    "Apple login Vision exhausted initial full-frame attempts "
                        + "without a high-confidence lock-screen match")
            } else {
                self.scheduleAppleLoginVisionRetry(generation: generation)
            }
        }
    }

    private func scheduleAppleLoginVisionRetry(generation: UInt64) {
        guard appleLoginVisionAttemptCount < Self.appleLoginVisionMaximumAttempts,
              appleLoginVisionRetryTask == nil else { return }
        appleLoginVisionRetryTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard let self, !Task.isCancelled,
                  generation == self.appleLoginVisionGeneration,
                  let latest = self.appleLoginVisionLatestFrame else { return }
            self.appleLoginVisionRetryTask = nil
            self.startAppleLoginVision(
                latest.frame,
                source: latest.source + " retry")
        }
    }

    /// Escalation of last resort for a video bootstrap that never produced a
    /// decoded frame: some servers never re-send an IRAP for FIR, so a
    /// startup burst damaged by packet loss leaves the stream permanently
    /// dead. (Deliberately no capacity reduction on retry: the server ignores
    /// our advertised rate during bootstrap, and a lowered controller origin
    /// destabilizes large framebuffers.)
    private func noteMediaBootstrapHealthy() {
        if consecutiveMediaStreamRestarts > 0 {
            logger.info(
                "Media bootstrap healthy after \(consecutiveMediaStreamRestarts) "
                    + "stream restart(s); clearing the restart count")
            consecutiveMediaStreamRestarts = 0
        }
        guard consecutiveMediaBootstrapReconnects > 0 else { return }
        logger.info(
            "Media bootstrap healthy after \(consecutiveMediaBootstrapReconnects) "
                + "forced reconnect(s); clearing the escalation count")
        consecutiveMediaBootstrapReconnects = 0
    }

    /// Re-request the media stream on the connection we already have.
    ///
    /// A dead video bootstrap used to go straight to `forceMediaBootstrapReconnect`,
    /// which throws away a perfectly healthy control channel, re-runs the RFB
    /// handshake and authentication, and shows the user "Connection
    /// interrupted" to fix a video problem. Every stream offer bootstraps a
    /// fresh generation with its own parameter sets and IRAP, so asking for
    /// one is the same repair at a fraction of the cost.
    ///
    /// Returns whether a restart was issued. The fresh offer spawns a new
    /// startup watchdog, and the caller's generation check stands it down, so
    /// escalation to a reconnect still happens if the new generation fails
    /// too. `consecutiveMediaStreamRestarts` bounds the loop.
    private func requestMediaStreamRestart(reason: String) -> Bool {
        guard connectionState.isConnected,
              reconnectTask == nil,
              isHighPerformanceMode,
              let transport = transportSession else { return false }
        guard consecutiveMediaStreamRestarts
                < Self.maximumConsecutiveMediaStreamRestarts else { return false }

        consecutiveMediaStreamRestarts += 1
        logger.warning(
            "Video bootstrap failed (\(reason)); re-requesting the media "
                + "stream before dropping the connection")
        Task { await transport.restartAppleMediaStream() }
        return true
    }

    /// Stop automatic media recovery and hand the decision back to the user.
    ///
    /// Every watchdog that reaches ``forceMediaBootstrapReconnect`` has already
    /// retired its own task by the time it calls, and the two long-lived
    /// in-session ladders cannot cover for them: the decode-output stall
    /// detector needs compressed frames to keep being submitted, and the gated
    /// recovery escalator needs gated bands. A stream that never produced a
    /// video source has neither. Simply returning would therefore leave the
    /// session `.connected` on a permanently blank screen with nothing left
    /// retrying, which is worse than the reconnect loop this cap exists to
    /// break. Retire the transport and publish `.failed` instead, which is the
    /// state the UI offers a Retry button for.
    private func failAfterMediaBootstrapExhausted(reason: String) {
        let attempts = consecutiveMediaBootstrapReconnects
        logger.error(
            "Video bootstrap failed (\(reason)) after \(attempts) forced "
                + "reconnects; giving up on automatic recovery")

        // Order matters: cleanup cancels event processing and clears
        // `transportSession` first, so the retired transport's `.disconnected`
        // event cannot reach `handleDisconnected` and start the loop again.
        let transport = transportSession
        cleanupTransport(clearCredentials: false)
        Task { await transport?.disconnect() }
        // This cap exists to stop a reconnect loop. Reviving it on the next
        // foreground edge would restart the very loop it just broke.
        automaticRecoveryDeclined = true
        connectionState = .failed(String(
            localized: "The remote video stream could not start after \(attempts) attempts. Try again, or switch this connection to Standard mode.",
            bundle: .module))
    }

    private func forceMediaBootstrapReconnect(
        reason: String,
        retryTilesPerFrame: UInt64? = nil
    ) {
        guard connectionState.isConnected,
              reconnectTask == nil,
              activeCredentials != nil,
              configuration.reconnectionPolicy.isEnabled,
              configuration.reconnectionPolicy.maximumAttempts > 0 else {
            logger.error(
                "Video bootstrap failed (\(reason)) but automatic reconnection "
                    + "is unavailable; leaving the session as-is")
            return
        }

        // A media fault must not cost a healthy control channel indefinitely.
        // Reconnecting rebuilds the whole session to fix a video stream, and
        // if two attempts have not produced a healthy bootstrap, a third will
        // not either: it just re-enters the loop the user experiences as
        // repeated "Connection interrupted".
        guard consecutiveMediaBootstrapReconnects
                < Self.maximumConsecutiveMediaBootstrapReconnects else {
            failAfterMediaBootstrapExhausted(reason: reason)
            return
        }
        consecutiveMediaBootstrapReconnects += 1
        if let retryTilesPerFrame {
            appleMediaTilesPerFrameOverride = retryTilesPerFrame
            logger.warning(
                "Retrying Apple media with tilesPerFrame=\(retryTilesPerFrame)")
        }
        logger.error("Video bootstrap failed (\(reason)); reconnecting")
        let transport = transportSession
        Task { await transport?.disconnect() }
        scheduleReconnect(immediate: true)
    }

    private func establishTransport(credentials: VNCCredentials) async throws {
        // A custom transport is built fresh here for every attempt: the
        // reconnect loop lands on this path per retry, and the provider
        // contract requires a usable tunnel each time.
        let customConnection: (any RFBConnection)?
        if let provider = configuration.transportProvider {
            customConnection = try await provider(credentials.host, credentials.port)
        } else {
            customConnection = nil
        }
        // Read the pointer choice once, here, and publish the same value the
        // transport negotiates from. The configuration is mutable while a
        // session is live, and only a new dial can act on a change.
        let cursorRendering = configuration.cursorRendering
        let transport = TransportSession(
            host: credentials.host,
            port: credentials.port,
            password: credentials.password,
            username: credentials.username,
            preferredPixelFormat: configuration.effectivePixelFormat,
            preferredEncodings: configuration.effectiveEncodings,
            preferFullQualityVideo: configuration.videoQualityMode == .fullQuality,
            targetFrameRate: configuration.targetFrameRate,
            displayCount: configuration.displayCount,
            requestsVirtualDisplays:
                configuration.displaySizingMode == .matchClient,
            appleMediaTilesPerFrameOverride:
                appleMediaTilesPerFrameOverride,
            serverRendersCursor: cursorRendering == .server,
            connection: customConnection,
            securityPolicy: configuration.securityPolicy,
            certificateValidationHandler: configuration.certificateValidationHandler)
        negotiatedCursorRendering = cursorRendering
        transportSession = transport

        if configuration.displaySizingMode == .matchClient,
           let preparedClientDisplaySize {
            _ = try await transport.requestRemoteDisplaySize(
                pixelWidth: preparedClientDisplaySize.pixelWidth,
                pixelHeight: preparedClientDisplaySize.pixelHeight,
                pointWidth: preparedClientDisplaySize.pointWidth,
                pointHeight: preparedClientDisplaySize.pointHeight)
        }

        startEventProcessing(transport: transport)
        try await transport.connect()
    }

    /// - Parameters:
    ///   - immediate: Drop the backoff before the first counted attempt.
    ///   - minimumAttempts: Floor on the policy's attempt count, for dials the
    ///     user asked for explicitly and which must happen even under a policy
    ///     that disables automatic recovery.
    ///   - freeLeadingAttempt: Run one dial *before* the counted attempts that
    ///     does not consume the policy's budget. This exists for the dial made
    ///     on returning to the foreground: iOS reclaimed the socket while the
    ///     process was suspended, so redialing is bookkeeping, not recovery
    ///     from a network fault. Charging it to `maximumAttempts` would let a
    ///     one-attempt policy exhaust itself on a dial made before the network
    ///     had come back, leaving nothing for the real failure. It is a
    ///     supplement to the budget, never a substitute: it is only offered
    ///     when the policy already permits at least one attempt.
    ///   - cause: Overrides the reported reason when the transport error would
    ///     misattribute the drop.
    private func scheduleReconnect(
        immediate: Bool = false,
        minimumAttempts: Int = 0,
        freeLeadingAttempt: Bool = false,
        cause: String? = nil
    ) {
        guard reconnectTask == nil, let credentials = activeCredentials else { return }
        let policy = configuration.reconnectionPolicy
        let maximumAttempts = max(policy.maximumAttempts, minimumAttempts)
        guard maximumAttempts > 0 else {
            automaticRecoveryDeclined = true
            connectionState = .failed(String(
                localized: "Reconnection is disabled for this session.",
                bundle: .module))
            return
        }

        // Attempt 0 is the uncounted one; the policy's own budget is 1...max.
        let firstAttempt = freeLeadingAttempt ? 0 : 1

        reconnectTask = Task { [weak self] in
            guard let self else { return }
            defer { self.reconnectTask = nil }

            for attempt in firstAttempt...maximumAttempts {
                guard !Task.isCancelled, !self.intentionallyDisconnected else { return }
                let isUncountedAttempt = attempt == 0
                let delay = isUncountedAttempt || (immediate && attempt == 1)
                    ? 0
                    : policy.delay(forAttempt: attempt)
                // The uncounted dial still reports as attempt 1 to the UI,
                // which only needs to know that recovery is under way.
                self.connectionState = .reconnecting(
                    attempt: max(1, attempt),
                    delay: delay)
                let reportedCause = cause
                    ?? self.lastError?.localizedDescription
                    ?? "no transport error recorded"
                if isUncountedAttempt {
                    self.logger.warning(
                        "Connection lost (\(reportedCause)); reconnecting now "
                            + "without consuming the \(maximumAttempts)-attempt budget")
                } else {
                    self.logger.warning(
                        "Connection lost (\(reportedCause)); retry \(attempt)/\(maximumAttempts) in "
                            + String(format: "%.1f", delay) + "s")
                }

                do {
                    if delay > 0 {
                        let nanoseconds = min(
                            delay * 1_000_000_000,
                            Double(Int64.max))
                        try await Task.sleep(
                            for: .nanoseconds(Int64(nanoseconds)))
                    }
                    try Task.checkCancellation()
                    self.cleanupTransport(clearCredentials: false)
                    try await self.establishTransport(credentials: credentials)
                    // A connection that came back is not a declined one,
                    // whatever gave up before it.
                    self.automaticRecoveryDeclined = false
                    self.logger.info("Reconnected successfully")
                    return
                } catch is CancellationError {
                    return
                } catch let error as VNCProtocolError {
                    self.lastError = error
                    self.diagnostics.lastError = error
                    self.logger.warning(
                        "Reconnect attempt \(attempt) failed: \(error.localizedDescription)")
                    if let transport = self.transportSession {
                        await transport.disconnect()
                    }
                    if !Self.isRetryableConnectionError(error) {
                        self.cleanupTransport(clearCredentials: false)
                        // A bad password or an unsupported version does not
                        // become correct by dialing again, so this failure is
                        // the user's to resolve and must survive an app switch.
                        self.automaticRecoveryDeclined = true
                        self.connectionState = .failed(error.localizedDescription)
                        return
                    }
                } catch {
                    self.logger.warning(
                        "Reconnect attempt \(attempt) failed: \(error.localizedDescription)")
                    if let transport = self.transportSession {
                        await transport.disconnect()
                    }
                }
            }

            self.cleanupTransport(clearCredentials: false)
            self.connectionState = .failed(
                String(
                    localized: "Couldn’t reconnect after \(maximumAttempts) attempts. Check the network or server, then try again.",
                    bundle: .module))
        }
    }

    private static func isRetryableConnectionError(_ error: VNCProtocolError) -> Bool {
        switch error {
        case .connectionClosed, .timeout, .ioError, .protocolViolation,
             .unexpectedMessage:
            return true
        case .authenticationFailed, .unsupportedVersion, .unsupportedEncoding:
            return false
        }
    }

    /// Append input to one ordered, bounded pump. Redundant pointer positions
    /// and queued continuous-scroll samples are coalesced while button/key and
    /// gesture lifecycle transitions remain exact.
    private func enqueueInput(_ event: SessionInputEvent) {
        guard connectionState.isConnected,
              let transport = transportSession else { return }

        inputQueue.enqueue(event)
        startInputPumpIfNeeded(transport: transport)
    }

    private func startInputPumpIfNeeded(transport: TransportSession) {
        guard inputTask == nil else { return }

        let generation = inputGeneration
        inputTask = Task { [weak self, weak transport] in
            guard let self, let transport else { return }
            while !Task.isCancelled,
                  self.inputGeneration == generation,
                  self.transportSession === transport,
                  self.connectionState.isConnected,
                  let event = self.inputQueue.dequeue() {
                switch event {
                case .key, .pointer:
                    // Drain the whole run of basic key/pointer messages that
                    // is already waiting into one socket write; scroll,
                    // gesture, and clipboard boundaries end the run.
                    var batch = [Self.batchableInputEvent(event)!]
                    while batch.count < 64,
                          let next = self.inputQueue.peek(),
                          let batchable = Self.batchableInputEvent(next) {
                        _ = self.inputQueue.dequeue()
                        batch.append(batchable)
                    }
                    try? await transport.sendInputEvents(batch)
                case .pause(let nanoseconds):
                    try? await Task.sleep(
                        for: .nanoseconds(Int64(clamping: nanoseconds)))
                case .scroll(let event):
                    try? await transport.sendScrollEvent(event)
                case .gesture(let event):
                    try? await transport.sendGestureEvent(event)
                case .clipboard(let text):
                    do {
                        try await transport.sendClipboardText(text)
                    } catch {
                        self.logger.warning(
                            "Failed to send clipboard: "
                                + error.localizedDescription)
                    }
                case .clipboardRequest:
                    do {
                        try await transport.requestRemoteClipboard()
                    } catch {
                        self.logger.warning(
                            "Failed to request remote clipboard: "
                                + error.localizedDescription)
                    }
                case .sharedClipboard(let enabled):
                    do {
                        try await transport.setSharedClipboardEnabled(enabled)
                    } catch {
                        self.logger.warning(
                            "Failed to update shared clipboard state: "
                                + error.localizedDescription)
                    }
                case .curtain(let enabled, let message):
                    do {
                        try await transport.setCurtainEnabled(
                            enabled, message: message)
                    } catch {
                        self.logger.warning(
                            "Failed to change curtain mode: "
                                + error.localizedDescription)
                    }
                }
            }
            if self.inputGeneration == generation {
                self.inputTask = nil
                // An event can be enqueued after the loop observes an empty
                // queue but before this task clears itself. Close that lost-
                // wakeup window so clipboard control messages cannot remain
                // stranded until the next pointer or keyboard event.
                if !self.inputQueue.isEmpty,
                   self.transportSession === transport,
                   self.connectionState.isConnected {
                    self.startInputPumpIfNeeded(transport: transport)
                }
            }
        }
    }

    private func scheduleTrailingSnapshot(interval: UInt64) {
        guard trailingSnapshotTask == nil,
              !initialFramePresentationTracker.suppressesPresentation,
              standardFramebufferHasPresentablePixels,
              let renderer else { return }
        let presentationGeneration = framebufferPresentationGeneration
        let cadenceDelay = interval &- min(
            interval,
            DispatchTime.now().uptimeNanoseconds &- lastImagePublishNanos)
        trailingSnapshotTask = Task { [weak self] in
            try? await Task.sleep(for: .nanoseconds(Int64(cadenceDelay)))
            guard let self, !Task.isCancelled else { return }
            guard self.framebufferPresentationGeneration
                    == presentationGeneration,
                  self.renderer === renderer else { return }
            guard !self.initialFramePresentationTracker.suppressesPresentation
            else {
                self.trailingSnapshotTask = nil
                return
            }
            let queue = self.framebufferRenderQueue
            let image = await withCheckedContinuation { continuation in
                queue.async {
                    continuation.resume(returning: renderer.snapshot())
                }
            }
            guard !Task.isCancelled,
                  self.framebufferPresentationGeneration
                    == presentationGeneration,
                  self.renderer === renderer else { return }
            guard !self.initialFramePresentationTracker.suppressesPresentation
            else {
                self.trailingSnapshotTask = nil
                return
            }
            // Delivery-time presentation check: the device may have locked
            // while this task slept. The suspension-clear reconcile schedules
            // a fresh trailing snapshot.
            guard !self.suspendsDisplayPresentation,
                  !VNCPresentationPolicy.isPresentationProhibited() else {
                self.trailingSnapshotTask = nil
                return
            }
            if let image {
                self.currentImage = image
                self.lastImagePublishNanos = DispatchTime.now().uptimeNanoseconds
                self.considerAppleLoginVisionFrame(
                    .image(image),
                    source: "Standard trailing snapshot")
            }
            self.trailingSnapshotTask = nil
        }
    }

    /// Retire all standard-framebuffer presentation work without clearing the
    /// last complete image. Reconnect uses that image as a placeholder until
    /// the replacement generation establishes complete initial coverage.
    private func invalidateStandardFramebufferPresentation() {
        framebufferPresentationGeneration &+= 1
        trailingSnapshotTask?.cancel()
        trailingSnapshotTask = nil
        initialFramePresentationTracker.reset()
        standardFramebufferHasPresentablePixels = false
        lastImagePublishNanos = 0
        deferredFramebufferRects.removeAll(keepingCapacity: true)
        deferredFramebufferBytes = 0
    }

    private static func batchableInputEvent(
        _ event: SessionInputEvent
    ) -> ClientInputEvent? {
        switch event {
        case .key(let downFlag, let keysym):
            return .key(downFlag: downFlag, key: keysym)
        case .pointer(let buttonMask, let x, let y):
            return .pointer(buttonMask: buttonMask, x: x, y: y)
        case .pause, .scroll, .gesture, .clipboard, .clipboardRequest,
             .sharedClipboard, .curtain:
            return nil
        }
    }

    private func invalidateInputQueue() {
        inputGeneration &+= 1
        inputTask?.cancel()
        inputTask = nil
        inputQueue.removeAll()
    }

    #if canImport(UIKit)
    /// UIKit can suspend the process long enough for RTP to advance beyond the
    /// half-range rule normally used to distinguish a late UInt16 sequence.
    /// Preserve the live TCP/media session and mark only receive-side ordering
    /// state at both sides of the suspension boundary.
    private func observeApplicationLifecycle() {
        backgroundLifecycleTask = Task { @MainActor [weak self] in
            for await _ in NotificationCenter.default.notifications(
                named: UIApplication.didEnterBackgroundNotification
            ) {
                guard !Task.isCancelled, let self else { return }
                mediaWasBackgrounded = true
                switch connectionState {
                case .connected, .connecting, .reconnecting:
                    wasLiveWhenBackgrounded = true
                case .idle, .disconnecting, .disconnected, .failed:
                    wasLiveWhenBackgrounded = false
                }
                noteMediaInterruptionBoundary(requestRefresh: false)
            }
        }
        foregroundLifecycleTask = Task { @MainActor [weak self] in
            for await _ in NotificationCenter.default.notifications(
                named: UIApplication.willEnterForegroundNotification
            ) {
                guard !Task.isCancelled, let self else { return }
                guard mediaWasBackgrounded else { continue }
                mediaWasBackgrounded = false
                let wasLive = wasLiveWhenBackgrounded
                wasLiveWhenBackgrounded = false
                // Only a session that went into the background alive can have
                // been killed by the background.
                if wasLive { armSuspensionResumeWindow() }
                noteMediaInterruptionBoundary(requestRefresh: true)
                if wasLive { resumeReconnectIfTransportAlreadyLost() }
            }
        }
    }

    /// Attribute the next connection loss to the suspension we just came back
    /// from. See ``suspensionResumeDeadlineNanos``.
    private func armSuspensionResumeWindow() {
        suspensionResumeDeadlineNanos =
            DispatchTime.now().uptimeNanoseconds &+ Self.suspensionResumeGraceNanos
    }

    /// True while a loss should be treated as suspension fallout. Reading it
    /// consumes the window: one resume explains one drop, and a second drop
    /// moments later is a real failure that deserves the normal backoff.
    private func consumeSuspensionResumeWindow() -> Bool {
        guard suspensionResumeDeadlineNanos != 0,
              DispatchTime.now().uptimeNanoseconds < suspensionResumeDeadlineNanos else {
            suspensionResumeDeadlineNanos = 0
            return false
        }
        suspensionResumeDeadlineNanos = 0
        return true
    }

    /// A session suspended long enough for iOS to reclaim its socket is
    /// already dead on the foreground edge, but nothing has run to observe it.
    /// `noteMediaInterruptionBoundary` cannot help here: it requires
    /// `connectionState.isConnected`, which is exactly what a session parked
    /// mid-recovery across the background window no longer is. Start the
    /// replacement now rather than waiting for a watchdog.
    ///
    /// Only called when the session was still live going into the background,
    /// so a terminal state found here was necessarily reached during that
    /// window. That is the whole licence for reviving it: a failure the user
    /// already saw, and left parked, is not made stale by an app switch.
    private func resumeReconnectIfTransportAlreadyLost() {
        guard !intentionallyDisconnected,
              hasEstablishedConnection,
              activeCredentials != nil,
              reconnectTask == nil,
              configuration.reconnectionPolicy.isEnabled,
              // The dial is a supplement to the policy's budget, never a way
              // around a policy that permits no attempts at all.
              configuration.reconnectionPolicy.maximumAttempts > 0 else { return }

        // Recovery that stopped on purpose stays stopped. Running out of
        // attempts while the process was suspended is not that: those dials
        // were spent on a network the app was not running to reach.
        guard !automaticRecoveryDeclined else {
            logger.info(
                "App resumed with the session parked by a declined recovery; "
                    + "leaving it for the user to retry")
            return
        }

        switch connectionState {
        case .disconnected, .failed:
            break
        case .idle, .connecting, .connected, .reconnecting, .disconnecting:
            return
        }

        _ = consumeSuspensionResumeWindow()
        scheduleReconnect(
            immediate: true,
            freeLeadingAttempt: true,
            cause: "app resumed; the suspended session's socket was reclaimed")
    }

    private func noteMediaInterruptionBoundary(requestRefresh: Bool) {
        guard connectionState.isConnected,
              let transport = transportSession else { return }

        if isHighPerformanceMode {
            videoStreamManager?.noteMediaInterruption()
            secondaryVideoStreamManager?.noteMediaInterruption()
            remoteAudioPlayer?.reset()
        }

        Task { [transport] in
            if self.isHighPerformanceMode {
                await transport.noteAppleMediaInterruption()
            }
            guard requestRefresh else { return }

            // A suspended connection can remain nominally alive while its
            // receive/media pipeline has stopped making progress. Do not wait
            // for a new RTP packet to initiate recovery: a static desktop may
            // not produce one. Explicitly solicit fresh state on foreground.
            if self.isHighPerformanceMode {
                await transport.requestVideoKeyframe()
            }
            try? await transport.requestFramebufferUpdate(incremental: false)
        }
    }

    #endif

    private var isTraceEnabled: Bool {
        configuration.enableProtocolTrace
    }

    private func startVideoStream(offer: AppleMediaStreamOffer) async {
        let manager = videoStreamManager ?? VideoStreamManager()
        videoStreamManager = manager
        videoBandRenderer.reset()
        secondaryVideoBandRenderer.reset()

        if configuration.effectiveRemoteAudioPlaybackEnabled {
            let synchronizationClock =
                appleMediaPlaybackSynchronizer ?? AppleMediaPlaybackSynchronizer()
            appleMediaPlaybackSynchronizer = synchronizationClock
            if remoteAudioPlayer == nil {
                do {
                    remoteAudioPlayer = try AppleRemoteAudioPlayer {
                        [weak synchronizationClock] timing in
                        synchronizationClock?.noteAudioPlayback(timing)
                    }
                } catch {
                        logger.error("Could not initialize remote audio: \(error.localizedDescription)")
                }
            }
        } else {
            remoteAudioPlayer?.stop()
            remoteAudioPlayer = nil
            appleMediaPlaybackSynchronizer = nil
        }

        let fallbackWidth = framebufferWidth > 0 ? framebufferWidth : Int(offer.width)
        let fallbackHeight = framebufferHeight > 0 ? framebufferHeight : Int(offer.height)
        func displaySize(at index: Int) -> (width: Int, height: Int) {
            if index == 0,
               activeVideoDisplayCount == 1,
               configuration.displaySizingMode != .matchClient,
               configuration.displayCount > 1,
               remoteDisplayRegions.count >= configuration.displayCount {
                let selected = remoteDisplayRegions.prefix(
                    configuration.displayCount)
                if let first = selected.first {
                    let union = selected.dropFirst().reduce(first) {
                        $0.union($1)
                    }
                    return (Int(union.width), Int(union.height))
                }
            }
            if remoteDisplayRegions.indices.contains(index) {
                let region = remoteDisplayRegions[index]
                return (Int(region.width), Int(region.height))
            }
            if configuration.displaySizingMode == .matchClient,
               let preparedClientDisplaySize {
                return (
                    Int(preparedClientDisplaySize.pixelWidth),
                    Int(preparedClientDisplaySize.pixelHeight))
            }
            return (fallbackWidth, fallbackHeight)
        }
        let primarySize = displaySize(at: 0)
        let width = primarySize.width
        let height = primarySize.height
        let initialTileCount = await transportSession?.currentAppleMediaTilesPerFrame
            ?? Int(AppleMediaVideoMode.negotiatedTilesPerFrame)
        videoBandRenderer.setScreenSize(width: width, height: height)
        videoBandRenderer.configureExpectedBandCount(initialTileCount)

        let renderer = videoBandRenderer
        // Coalesced main-thread delivery. A Task per decoded frame has no FIFO
        // guarantee (an older band frame could land after a newer one — visible
        // as flicker/regression) and floods the main thread at 240+ frames/sec
        // across bands. Instead: stage the newest buffer per band under a lock
        // and drain all staged bands in ONE main-queue hop (FIFO by definition);
        // under main-thread load intermediate frames are simply superseded.
        let coalescer = BandFrameCoalescer(
            renderer: renderer,
            expectedSourceCount: initialTileCount)
        // Diagnostic tap: with ROOTSHELL_VNC_FRAME_OUT_DIR set, periodically
        // save the EXACT decoded buffers handed to the renderer, so decode
        // output and on-screen result can be compared for the same session.
        let frameDumper = DiagnosticFrameDumper.fromEnvironment()
        let decodedBands = DecodedBandTracker()
        let callback: VideoStreamManager.FrameCallback = { pixelBuffer, ssrc in
            frameDumper?.maybeDump(pixelBuffer, ssrc: ssrc)
            decodedBands.record(ssrc)
            coalescer.submit(ssrc: ssrc, pixelBuffer: pixelBuffer)
        }

        appliedMediaGeometryGeneration = 1
        manager.onFrameGeometryChange = { [weak self, weak manager] geometry in
            guard let manager else { return }
            Task { @MainActor [weak self, weak manager] in
                guard let self, let manager else { return }
                await self.applyMediaStreamGeometry(geometry, from: manager)
            }
        }

        manager.startStream(
            streamID: offer.streamID,
            width: width,
            height: height,
            // Match the initial tiled offer generated by RFBTransport. DON
            // restores the compound frame's global decode order; later media
            // generations can switch between one and multiple tiles.
            usesDecodingOrderNumbers:
                initialTileCount > 1,
            numberOfTiles: initialTileCount,
            frameCallback: callback
        )

        let secondaryManager: VideoStreamManager?
        let secondaryCoalescer: BandFrameCoalescer?
        let secondaryDecodedBands: DecodedBandTracker?
        if activeVideoDisplayCount > 1 {
            let secondManager = secondaryVideoStreamManager ?? VideoStreamManager()
            secondaryVideoStreamManager = secondManager
            let secondSize = displaySize(at: 1)
            secondaryVideoBandRenderer.setScreenSize(
                width: secondSize.width,
                height: secondSize.height)
            secondaryVideoBandRenderer.configureExpectedBandCount(initialTileCount)
            let secondCoalescer = BandFrameCoalescer(
                renderer: secondaryVideoBandRenderer,
                expectedSourceCount: initialTileCount)
            let secondDecodedBands = DecodedBandTracker()
            secondManager.onFrameGeometryChange = { [weak self] geometry in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.secondaryVideoBandRenderer.setScreenSize(
                        width: geometry.width,
                        height: geometry.height)
                }
            }
            secondManager.startStream(
                streamID: offer.streamID,
                width: secondSize.width,
                height: secondSize.height,
                usesDecodingOrderNumbers: initialTileCount > 1,
                numberOfTiles: initialTileCount
            ) { pixelBuffer, ssrc in
                secondDecodedBands.record(ssrc)
                secondCoalescer.submit(ssrc: ssrc, pixelBuffer: pixelBuffer)
            }
            secondaryManager = secondManager
            secondaryCoalescer = secondCoalescer
            secondaryDecodedBands = secondDecodedBands
        } else {
            secondaryVideoStreamManager?.stopStream()
            secondaryVideoStreamManager = nil
            secondaryManager = nil
            secondaryCoalescer = nil
            secondaryDecodedBands = nil
        }

        let streamGeneration = manager.decodeProgress.streamGeneration
        // Ownership takes two counters, not one. A replacement stream bumps
        // `streamGeneration`; an in-session renegotiation arrives through the
        // generation sink, which bumps only `mediaGeneration` and starts its
        // own per-generation watchdog. Checking `streamGeneration` alone lets
        // this watchdog act on a stream that a successor already owns.
        let startingMediaGeneration = manager.currentMediaGeneration
        let recoveryCoordinator = MediaRecoveryCoordinator()

        // Startup liveness watchdog. Recovery stays in the negotiated media
        // protocol first (FIR for a fresh intra picture); if the bootstrap is
        // still dead after the retries — some servers never answer FIR with
        // an IRAP, so a damaged startup burst is unrecoverable in-session —
        // escalate to a reconnect with a reduced initial capacity.
        if let transport = transportSession {
            let watchdogManager = manager
            let log = logger
            Task { [weak self, weak transport, weak watchdogManager, recoveryCoordinator] in
                var firAttempts = 0
                var lastStatus = (decoded: 0, sources: 0)
                for tick in 1...14 {
                    try? await Task.sleep(for: .seconds(1))
                    guard let transport, let m = watchdogManager, m.isStreamActive else { return }
                    // This watchdog owns display zero's decoder. The transport
                    // source count includes every negotiated display, so use
                    // this display's negotiated band count here.
                    let sources = initialTileCount
                    let decoded = decodedBands.count
                    lastStatus = (decoded, sources)
                    if sources > 0 && decoded >= sources {
                        if firAttempts > 0 {
                            log.info("Dead-band watchdog: recovered, \(decoded)/\(sources) bands decoding")
                        }
                        self?.noteMediaBootstrapHealthy()
                        return
                    }
                    // Some servers accept tilesPerFrame=1 in message 2 but
                    // never instantiate a video RTP source for it. This is a
                    // profile rejection, not packet loss, so FIR cannot help.
                    // Retry quickly with the native compound capability.
                    if sources == 1, decoded == 0, tick >= 3,
                       await transport.videoSourceCount == 0 {
                        self?.forceMediaBootstrapReconnect(
                            reason: "one-picture profile produced no video source",
                            retryTilesPerFrame: 4)
                        return
                    }
                    guard firAttempts < 3,
                          await transport.isReadyForVideoKeyframeRecovery() || tick >= 6,
                          await recoveryCoordinator.begin() else {
                        continue
                    }
                    firAttempts += 1
                    log.warning("Startup media watchdog: \(decoded)/\(sources) sources decoding "
                        + "(attempt \(firAttempts)); requesting native FIR after rate settled")
                    await transport.requestVideoKeyframe()
                    await recoveryCoordinator.finish()
                }
                guard let self,
                      let m = watchdogManager, m.isStreamActive,
                      m.decodeProgress.streamGeneration == streamGeneration,
                      m.currentMediaGeneration == startingMediaGeneration else { return }
                let reason = "\(lastStatus.decoded)/\(lastStatus.sources) bands decoding "
                    + "after \(firAttempts) FIR attempts"

                // Try the cheap repair first. A fresh stream offer carries new
                // parameter sets and an IRAP, which is what a damaged startup
                // burst actually needs; dropping the whole connection for it
                // costs a handshake, authentication and a media renegotiation,
                // and surfaces to the user as a dropped session. If the new
                // generation fails too, its own watchdog escalates from here.
                if self.requestMediaStreamRestart(reason: reason) {
                    // A server that simply ignores the re-request produces
                    // neither, so no replacement watchdog is ever spawned.
                    // Returning unconditionally here would leave the session
                    // `.connected` on a blank screen with nothing retrying,
                    // which is the exact failure `failAfterMediaBootstrapExhausted`
                    // exists to avoid. Hold the escalation open until a
                    // successor actually takes ownership.
                    for _ in 1...5 {
                        try? await Task.sleep(for: .seconds(1))
                        guard let current = watchdogManager,
                              current.isStreamActive else { return }
                        // Either counter moving means a successor owns this
                        // stream and will escalate on its own if it fails. A
                        // whole new stream offer bumps `streamGeneration`; an
                        // in-session renegotiation bumps only `mediaGeneration`
                        // and starts its own per-generation watchdog, whose FIR
                        // ladder runs longer than the wait here.
                        guard current.decodeProgress.streamGeneration == streamGeneration,
                              current.currentMediaGeneration == startingMediaGeneration
                        else { return }
                        // The re-request can also be answered with a fresh
                        // IRAP inside the current generation, in which case
                        // the bands simply start decoding and there is
                        // nothing left to escalate.
                        if lastStatus.sources > 0, decodedBands.count >= lastStatus.sources {
                            log.info(
                                "Dead-band watchdog: recovered after a media "
                                    + "stream re-request")
                            self.noteMediaBootstrapHealthy()
                            return
                        }
                    }
                    log.error(
                        "Media stream re-request produced no replacement "
                            + "generation; escalating to a reconnect")
                }

                self.forceMediaBootstrapReconnect(
                    reason: reason,
                    retryTilesPerFrame:
                        lastStatus.sources == 1 && lastStatus.decoded == 0 ? 4 : nil)
            }
        }

        // Long-running decode-output watchdog. A static desktop naturally
        // produces no decode submissions, so silence by itself is not a fault.
        // If submitted pictures stop producing output, rebuild only the public
        // decoder and request a fresh intra picture on the existing session.
        if let transport = transportSession {
            let watchdogManager = manager
            let log = logger
            let recoveryQueue = mediaQueue
            Task { [weak transport, weak watchdogManager] in
                var detector = DecodeOutputStallDetector()
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard let transport,
                          let m = watchdogManager,
                          m.isStreamActive else { return }
                    let progress = m.decodeProgress
                    guard progress.streamGeneration == streamGeneration else { return }
                    // Loss recovery deliberately withholds dependent compound
                    // pictures until the base IDR. Rebuilding the decoder here
                    // races the FIR loop and discards every recovery picture.
                    if m.hasGatedBands {
                        detector = DecodeOutputStallDetector()
                        continue
                    }
                    if detector.observe(
                        submittedFrameCount: progress.submittedFrameCount,
                        deliveredFrameCount: decodedBands.frameCount,
                        nowNanos: DispatchTime.now().uptimeNanoseconds
                    ) {
                        log.warning("Decode-output stall while compressed frames continue; "
                            + "rebuilding decoder in media session")
                        recoveryQueue.async { [transport, m] in
                            guard m.recoverDecoderAfterOutputStall() else {
                                return
                            }
                            Task { [transport] in
                                await transport.requestVideoKeyframe()
                            }
                        }
                    }
                }
            }
        }

        // Transport-confirmed RTP loss sends native AFB type-6 feedback before
        // releasing the post-gap packet. If no video is displayed afterwards,
        // The media fail-safe escalates to PSFB FIR and resets expected
        // decoding order. A persistent supervisor keyed off the gate state
        // mirrors that two-stage behavior. It must not be an event-driven
        // task: markLossLocked only fires onLossDetected for a *fresh* latch,
        // so a per-event task that exits with the gate still latched could
        // never be restarted and the display stayed frozen forever.
        if let transport = transportSession {
            let recoveryManager = manager
            let log = logger
            let recoveryQueue = mediaQueue
            let latestLossSSRC = LatestLossSSRC()
            manager.onLossDetected = { [weak transport, latestLossSSRC] ssrc in
                latestLossSSRC.record(ssrc)
                guard let transport else { return }
                Task { [transport] in
                    // By the time the demuxer sees a sequence gap, transport
                    // retransmission has already failed. The server answers a
                    // keyframe request with a recovery IDR_N_LP + parameter
                    // sets (verified live 2026-07-12), which the surviving
                    // decoder session picks up directly — no rebuild needed.
                    // The transport rate-limits repeated requests.
                    await transport.requestVideoKeyframe(ssrc: ssrc)
                    if !(await transport.hasObservedVideoLossFeedback(ssrc: ssrc)) {
                        log.warning("Compressed stream gated without a matching "
                            + "observed RTP loss report")
                    }
                }
            }
            Task { [weak transport, weak recoveryManager, recoveryCoordinator, latestLossSSRC] in
                var escalator = GatedRecoveryEscalator()
                var episodeActive = false
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard let transport,
                          let m = recoveryManager,
                          m.isStreamActive else { return }
                    guard m.decodeProgress.streamGeneration == streamGeneration else { return }
                    guard m.hasGatedBands else {
                        // Steady state costs one lock acquisition; skip the
                        // transport actor hop entirely while healthy.
                        if episodeActive {
                            episodeActive = false
                            escalator = GatedRecoveryEscalator()
                            await transport.noteVideoRecoveryComplete()
                            log.info("Recovery gate cleared; capacity restores via normal ramp")
                        }
                        continue
                    }
                    episodeActive = true
                    let ready = await transport.isReadyForVideoKeyframeRecovery(displayGated: true)
                    let action = escalator.observe(
                        gated: true,
                        readyForKeyframe: ready,
                        nowNanos: DispatchTime.now().uptimeNanoseconds)
                    guard action != .none else { continue }
                    // A busy coordinator (startup watchdog mid-FIR) is not a
                    // failure; the uncommitted action is re-offered next tick.
                    guard await recoveryCoordinator.begin() else { continue }
                    let actionNanos = DispatchTime.now().uptimeNanoseconds
                    if action == .rebuildDecoderAndFIR {
                        escalator.noteDecoderRebuilt(nowNanos: actionNanos)
                    }
                    escalator.noteFIRRequested(nowNanos: actionNanos)

                    switch action {
                    case .backoffThenFIR, .rebuildDecoderAndFIR:
                        // Step the advertised bitrate down and give the server
                        // one RCTL interval to apply it, so the retry IDR is
                        // smaller than the burst that was just shredded.
                        await transport.applyVideoRecoveryBackoff()
                        try? await Task.sleep(for: .milliseconds(250))
                    case .none, .requestFIR:
                        break
                    }
                    if action == .rebuildDecoderAndFIR {
                        log.warning("Recovery gate persisted through FIR retries; "
                            + "rebuilding decoder in media session")
                        await withCheckedContinuation { continuation in
                            recoveryQueue.async {
                                _ = m.recoverDecoderAfterOutputStall()
                                continuation.resume()
                            }
                        }
                    }
                    log.warning("No video displayed after RTP loss; applying native FIR "
                        + "fail-safe (attempt \(escalator.firAttempts))")
                    await withCheckedContinuation { continuation in
                        recoveryQueue.async {
                            m.resetExpectedDecodingOrderForRecovery()
                            continuation.resume()
                        }
                    }
                    await transport.requestVideoKeyframe(ssrc: latestLossSSRC.take())
                    await recoveryCoordinator.finish()
                }
            }
        } else {
            manager.onLossDetected = nil
        }

        // VideoToolbox can accept a damaged sample synchronously and report its
        // missing-reference failure later. Rebuild it on the serial media queue,
        // retain the last rendered surface, and use native FIR to refresh it.
        if let transport = transportSession {
            let recoveryQueue = mediaQueue
            let recoveryManager = manager
            manager.onDecoderFailure = { [weak transport, weak recoveryManager] failure in
                guard let transport, let recoveryManager else { return }
                // The rebuild is paced by VideoStreamManager's cooldown: a
                // session rebuilt mid-reference-loss fails every dependent
                // picture until intra refresh completes, so hammering rebuilds
                // per failure churned 30+ VT sessions a second. Retry on a
                // timer instead until either the rebuild lands or the latch
                // clears with the stream still healthy.
                Task { [weak transport, weak recoveryManager] in
                    for attempt in 1...8 {
                        guard let transport,
                              let recoveryManager,
                              recoveryManager.isStreamActive,
                              recoveryManager.hasLatchedDecoderFailure else { return }
                        let rebuilt = await withCheckedContinuation { continuation in
                            recoveryQueue.async {
                                continuation.resume(
                                    returning: recoveryManager.recoverDecoderInSession())
                            }
                        }
                        if rebuilt {
                            await transport.requestVideoKeyframe(ssrc: failure.ssrc)
                            return
                        }
                        try? await Task.sleep(for: .milliseconds(150 * attempt))
                    }
                }
            }
        } else {
            manager.onDecoderFailure = nil
        }

        // Fast path for the high-rate video RTP: deliver decrypted packets
        // straight from the transport's background executor onto the media queue,
        // bypassing the main-actor `events` stream. Routing ~3000 packets/sec
        // through the main thread both burned CPU and made us fall behind and
        // drop packets.
        //
        // Installed SYNCHRONOUSLY (awaited) inside offer handling, before the
        // event loop touches the next event. The previous fire-and-forget Task
        // raced the stream start: the first packets — parameter sets and the
        // session's initial IRAP — could flow through the (buffered, slower)
        // events path while later packets took the sink path, reordering the
        // stream right at the decoder bootstrap. One scramble there and every
        // band renders garbage for the rest of the session, because this
        // stream could not be recovered without its negotiated loss feedback.
        // This was the GUI-only "macroblock mess": headless probes that
        // awaited the sink install decoded the same stream pixel-perfectly.
        if let transport = transportSession {
            let queue = mediaQueue
            let sinkManager = manager // VideoStreamManager is Sendable
            let sinkAudioPlayer = remoteAudioPlayer
            let playbackSynchronizer = appleMediaPlaybackSynchronizer
            let generationCoalescer = coalescer
            let generationLog = logger
            let videoDelay: @Sendable (Data) -> UInt64 = { packet in
                let fallback = sinkAudioPlayer?.recommendedVideoDelayNanos ?? 0
                return playbackSynchronizer?.videoDelayNanos(
                    for: packet,
                    fallbackNanos: fallback) ?? fallback
            }
            let videoPacketCoalescer = OrderedMediaPacketCoalescer(
                queue: queue,
                delayNanos: videoDelay
            ) { packets in
                if let stats = RenderCommitStats.shared {
                    for packet in packets {
                        stats.noteVideoPacket(bytes: packet.count)
                        let result = sinkManager.feedRTPData(packet)
                        stats.noteSubmittedAccessUnits(result.decodedNALUnitCount)
                    }
                } else {
                    for packet in packets {
                        sinkManager.feedRTPData(packet)
                    }
                }
            }
            let secondaryVideoPacketCoalescer = secondaryManager.map { manager in
                OrderedMediaPacketCoalescer(
                    queue: queue,
                    delayNanos: videoDelay
                ) { packets in
                    for packet in packets {
                        manager.feedRTPData(packet)
                    }
                }
            }
            secondaryManager?.onLossDetected = { [weak transport] ssrc in
                guard let transport else { return }
                Task { await transport.requestVideoKeyframe(ssrc: ssrc) }
            }
            secondaryManager?.onDecoderFailure = { [weak transport, weak secondaryManager] failure in
                guard let transport, let secondaryManager else { return }
                queue.async {
                    _ = secondaryManager.recoverDecoderInSession()
                    Task { await transport.requestVideoKeyframe(ssrc: failure.ssrc) }
                }
            }
            let generationTransitionKick: @Sendable () -> Void = {
                [weak self] in
                let session = self
                Task { @MainActor in
                    session?.noteAppleMediaGenerationTransitionForLoginSend()
                }
            }
            await transport.setAppleMediaSenderClockSink {
                [weak playbackSynchronizer] mapping in
                playbackSynchronizer?.noteSenderClock(mapping)
            }
            await transport.setAppleMediaGenerationSink { generation, numberOfTiles in
                generationTransitionKick()
                playbackSynchronizer?.reset()
                videoPacketCoalescer.discardPending()
                secondaryVideoPacketCoalescer?.discardPending()
                queue.async {
                    sinkManager.prepareForStreamReconfiguration(
                        mediaGeneration: generation,
                        numberOfTiles: numberOfTiles)
                    decodedBands.reset()
                    generationCoalescer.beginStreamGeneration(
                        generation,
                        expectedSourceCount: numberOfTiles)
                    if let secondaryManager,
                       let secondaryCoalescer,
                       let secondaryDecodedBands {
                        secondaryManager.prepareForStreamReconfiguration(
                            mediaGeneration: generation,
                            numberOfTiles: numberOfTiles)
                        secondaryDecodedBands.reset()
                        secondaryCoalescer.beginStreamGeneration(
                            generation,
                            expectedSourceCount: numberOfTiles)
                    }

                    // The connection-level startup watchdog cannot validate a
                    // replacement generation: its SSRC set belongs to retired
                    // media. Require every new tile to decode before declaring
                    // this generation live, otherwise the atomic renderer can
                    // retain the old whole-screen frame forever.
                    Task { [weak self, weak transport, weak sinkManager, recoveryCoordinator] in
                        for attempt in 1...8 {
                            try? await Task.sleep(for: .seconds(1))
                            guard let transport,
                                  let manager = sinkManager,
                                  manager.isStreamActive,
                                  manager.currentMediaGeneration == generation else { return }
                            let decoded = decodedBands.count
                            if decoded >= numberOfTiles {
                                if attempt > 1 {
                                    generationLog.info(
                                        "Media generation \(generation) ready: "
                                            + "\(decoded)/\(numberOfTiles) tiles decoded")
                                }
                                await MainActor.run { [weak self] in
                                    self?.noteMediaBootstrapHealthy()
                                }
                                return
                            }
                            if numberOfTiles == 1, decoded == 0, attempt >= 3,
                               await transport.videoSourceCount == 0 {
                                await MainActor.run { [weak self] in
                                    self?.forceMediaBootstrapReconnect(
                                        reason: "one-picture reconfiguration produced no video source",
                                        retryTilesPerFrame: 4)
                                }
                                return
                            }
                            let ready = await transport.isReadyForVideoKeyframeRecovery()
                            guard (ready || attempt >= 4),
                                  await recoveryCoordinator.begin() else { continue }
                            generationLog.warning(
                                "Media generation \(generation) has \(decoded)/"
                                    + "\(numberOfTiles) decoded tiles; requesting FIR "
                                    + "attempt \(attempt)")
                            await transport.requestVideoKeyframe()
                            await recoveryCoordinator.finish()
                        }
                        // Still dead after the FIR ladder: this generation's
                        // bootstrap was lost and the server will not replace
                        // it in-session. Reconnect with a gentler burst.
                        guard let manager = sinkManager,
                              manager.isStreamActive,
                              manager.currentMediaGeneration == generation else { return }
                        let decoded = decodedBands.count
                        guard decoded < numberOfTiles else { return }
                        await MainActor.run { [weak self] in
                            self?.forceMediaBootstrapReconnect(
                                reason: "generation \(generation): \(decoded)/"
                                    + "\(numberOfTiles) tiles decoding",
                                retryTilesPerFrame:
                                    numberOfTiles == 1 && decoded == 0 ? 4 : nil)
                        }
                    }
                }
                // A media generation installs fresh SRTP keys for audio as
                // well as video. Reset once at that real codec boundary; the
                // repeated stream-offer path above intentionally does not.
                sinkAudioPlayer?.reset()
            }
            await transport.setAppleRemoteDisplaySizeSink { [weak self] width, height in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.acceptsDeferredAppleDisplayGeometry = false
                    await self.applyDesktopResizeMetadata(
                        width: width,
                        height: height)
                }
            }
            let settledSequencer = appleResizeSettledSequencer
            await transport.setAppleRemoteDisplayResizeSettledSink {
                [weak self] settled in
                // Sequence on the emitting executor: the main-actor hops
                // below carry no ordering of their own.
                let sequence = settledSequencer.next()
                Task { @MainActor [weak self] in
                    self?.noteRemoteDisplayResizeSettled(
                        settled, sequence: sequence)
                }
            }
            await transport.setAppleMediaRoutedRTPSink { packet, displayIndex in
                if AppleRemoteAudioPlayer.canHandleRTPPacket(packet) {
                    sinkAudioPlayer?.enqueueRTPPacket(packet)
                } else if displayIndex == 1,
                          let secondaryVideoPacketCoalescer {
                    secondaryVideoPacketCoalescer.enqueue(packet)
                } else {
                    videoPacketCoalescer.enqueue(packet)
                }
            }
        }
    }

    /// Route decrypted Apple media without allowing system audio to enter the
    /// HEVC demuxer. This also covers the brief event-stream path before the
    /// transport installs its direct high-rate sink.
    private func routeAppleMediaRTPPacket(_ packet: Data) {
        if AppleRemoteAudioPlayer.canHandleRTPPacket(packet) {
            remoteAudioPlayer?.enqueueRTPPacket(packet)
        } else {
            let manager = videoStreamManager
            mediaQueue.async { manager?.feedRTPData(packet) }
        }
    }


    private func mapProtocolError(_ error: VNCProtocolError) -> VNCError {
        switch error {
        case .authenticationFailed(let reason):
            return .authenticationFailed(reason)
        case .connectionClosed:
            return .connectionFailed(String(localized: "Connection closed by server", bundle: .module))
        case .timeout:
            return .connectionFailed(String(localized: "Connection timed out", bundle: .module))
        case .ioError(let detail):
            return .connectionFailed(detail)
        case .unsupportedVersion:
            return .unsupportedFeature(String(localized: "Server protocol version not supported", bundle: .module))
        case .unsupportedEncoding(let id):
            return .unsupportedFeature(String(localized: "Encoding \(id) not supported", bundle: .module))
        default:
            return .protocolError(error)
        }
    }
}

/// Carries a decoded pixel buffer across the (main-actor) hop to the renderer.
/// CVPixelBuffer isn't Sendable, but we hand off ownership and only touch it on
/// the main thread.
struct SendablePixelBuffer: @unchecked Sendable {
    let buffer: CVPixelBuffer
    init(_ buffer: CVPixelBuffer) { self.buffer = buffer }
}

/// Diagnostic: saves periodic PNGs of decoded band buffers exactly as they are
/// handed to the renderer. Capture is strictly opt-in through
/// `ROOTSHELL_VNC_FRAME_OUT_DIR=<dir>`; ordinary Debug and Release sessions do
/// not write screen contents to disk.
/// Lets a live GUI session's decode output be compared against what the screen
/// shows, isolating decode-path vs display-path corruption. PNG encoding runs
/// on a background queue so the tap doesn't perturb delivery timing.
final class DiagnosticFrameDumper: @unchecked Sendable {
    private let dir: String
    private let lock = NSLock()
    private var perBandCounter: [UInt32: Int] = [:]
    private var dumpsRemaining = 60
    private let queue = DispatchQueue(label: "com.rootshell.vnc.framedump", qos: .utility)
    private let ciContext = CIContext()

    static func fromEnvironment() -> DiagnosticFrameDumper? {
        let fileManager = FileManager.default
        let environment = ProcessInfo.processInfo.environment
        guard let root = configuredRoot(environment: environment) else { return nil }

        let sessionDirectory = root.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true)
        do {
            try fileManager.createDirectory(
                at: sessionDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        } catch {
            VNCLogger(category: "FrameCapture").warning(
                "Could not create decoded-frame capture directory: \(error.localizedDescription)")
            return nil
        }
        VNCLogger(category: "FrameCapture").info(
            "Capturing decoded frames in \(sessionDirectory.path)")
        return DiagnosticFrameDumper(dir: sessionDirectory.path)
    }

    static func configuredRoot(environment: [String: String]) -> URL? {
        #if DEBUG
        guard let explicit = VNCDiagnostics.value(
            for: "ROOTSHELL_VNC_FRAME_OUT_DIR",
            environment: environment) else { return nil }
        return URL(fileURLWithPath: explicit, isDirectory: true)
        #else
        nil
        #endif
    }

    private init(dir: String) {
        self.dir = dir
    }

    func maybeDump(_ pixelBuffer: CVPixelBuffer, ssrc: UInt32) {
        #if DEBUG
        lock.lock()
        let n = perBandCounter[ssrc, default: 0]
        perBandCounter[ssrc] = n + 1
        // One dump per band every ~2 s of frames, bounded for the session.
        guard n % 120 == 0, dumpsRemaining > 0 else {
            lock.unlock()
            return
        }
        dumpsRemaining -= 1
        lock.unlock()

        let box = SendablePixelBuffer(pixelBuffer)
        let path = "\(dir)/gui_n\(n)_band\(ssrc & 0xffff).png"
        queue.async { [ciContext] in
            guard FileManager.default.createFile(
                atPath: path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]) else { return }
            let ci = CIImage(cvPixelBuffer: box.buffer)
            guard let cg = ciContext.createCGImage(ci, from: ci.extent),
                  let dest = CGImageDestinationCreateWithURL(
                    URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(dest, cg, nil)
            CGImageDestinationFinalize(dest)
        }
        #endif
    }
}

/// Tracks which video sources (bands) have delivered at least one decoded
/// frame; the dead-band watchdog compares this against the transport's count.
final class DecodedBandTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var ssrcs: Set<UInt32> = []
    private var frames: UInt64 = 0

    func record(_ ssrc: UInt32) {
        lock.lock()
        ssrcs.insert(ssrc)
        frames &+= 1
        lock.unlock()
    }

    func reset() {
        lock.lock()
        ssrcs.removeAll(keepingCapacity: true)
        frames = 0
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return ssrcs.count
    }

    var frameCount: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return frames
    }
}

/// Detects a decoder/display wedge from progress counters. The detector is
/// deliberately ignorant of pixels: it fires only when new compressed access
/// units are submitted but delivered-frame progress remains unchanged.
struct DecodeOutputStallDetector {
    private var previousSubmittedFrameCount: UInt64 = 0
    private var previousDeliveredFrameCount: UInt64 = 0
    private var stalledSinceNanos: UInt64?
    private var lastRecoveryNanos: UInt64 = 0

    let stallThresholdNanos: UInt64
    let recoveryCooldownNanos: UInt64

    init(
        stallThresholdNanos: UInt64 = 1_000_000_000,
        recoveryCooldownNanos: UInt64 = 2_000_000_000
    ) {
        self.stallThresholdNanos = stallThresholdNanos
        self.recoveryCooldownNanos = recoveryCooldownNanos
    }

    mutating func observe(
        submittedFrameCount: UInt64,
        deliveredFrameCount: UInt64,
        nowNanos: UInt64
    ) -> Bool {
        let submissionsAdvanced = submittedFrameCount > previousSubmittedFrameCount
        let outputAdvanced = deliveredFrameCount > previousDeliveredFrameCount
        previousSubmittedFrameCount = submittedFrameCount
        previousDeliveredFrameCount = deliveredFrameCount

        if outputAdvanced {
            stalledSinceNanos = nil
            return false
        }
        guard submissionsAdvanced else { return false }
        guard let stalledSinceNanos else {
            self.stalledSinceNanos = nowNanos
            return false
        }
        guard nowNanos &- stalledSinceNanos >= stallThresholdNanos else { return false }
        guard lastRecoveryNanos == 0
                || nowNanos &- lastRecoveryNanos >= recoveryCooldownNanos else { return false }
        lastRecoveryNanos = nowNanos
        return true
    }
}

/// Escalation policy for a latched recovery gate. Pure timing state: the
/// caller performs the actions and commits them via the note methods, so an
/// action that could not run (busy recovery coordinator) is re-offered on the
/// next observation instead of being silently consumed.
///
/// Ladder: 2 s grace for NACK/AFB retransmission, first FIR when the rate
/// controller settles (bounded at 4 s — a busy screen may never settle), then
/// escalating retries that first step the advertised bitrate down, and a
/// decoder rebuild as last resort. Every threshold is an absolute bound on
/// gate age; nothing in the ladder can defer recovery indefinitely.
struct GatedRecoveryEscalator {
    enum Action: Equatable {
        case none
        case requestFIR
        case backoffThenFIR
        case rebuildDecoderAndFIR
    }

    private var gateObservedSinceNanos: UInt64?
    private var lastFIRNanos: UInt64?
    private var lastRebuildNanos: UInt64 = 0
    private(set) var firAttempts = 0

    let graceNanos: UInt64
    let forcedFirstFIRNanos: UInt64
    let retryIntervalsNanos: [UInt64]
    let rebuildGateAgeNanos: UInt64
    let rebuildAttemptThreshold: Int
    let rebuildCooldownNanos: UInt64

    init(
        graceNanos: UInt64 = 2_000_000_000,
        forcedFirstFIRNanos: UInt64 = 4_000_000_000,
        retryIntervalsNanos: [UInt64] = [1_500_000_000, 2_000_000_000, 3_000_000_000],
        rebuildGateAgeNanos: UInt64 = 12_000_000_000,
        rebuildAttemptThreshold: Int = 5,
        rebuildCooldownNanos: UInt64 = 10_000_000_000
    ) {
        self.graceNanos = graceNanos
        self.forcedFirstFIRNanos = forcedFirstFIRNanos
        self.retryIntervalsNanos = retryIntervalsNanos
        self.rebuildGateAgeNanos = rebuildGateAgeNanos
        self.rebuildAttemptThreshold = rebuildAttemptThreshold
        self.rebuildCooldownNanos = rebuildCooldownNanos
    }

    mutating func observe(gated: Bool, readyForKeyframe: Bool, nowNanos: UInt64) -> Action {
        guard gated else {
            gateObservedSinceNanos = nil
            lastFIRNanos = nil
            firAttempts = 0
            return .none
        }
        let since: UInt64
        if let existing = gateObservedSinceNanos {
            since = existing
        } else {
            gateObservedSinceNanos = nowNanos
            since = nowNanos
        }
        let gateAge = nowNanos &- since
        guard gateAge >= graceNanos else { return .none }

        guard let lastFIRNanos else {
            // First FIR: prefer waiting for the rate controller to settle,
            // but a busy screen can stay unsettled forever — bound it.
            return (readyForKeyframe || gateAge >= forcedFirstFIRNanos)
                ? .requestFIR
                : .none
        }
        let intervalIndex = min(max(firAttempts - 1, 0), retryIntervalsNanos.count - 1)
        guard nowNanos &- lastFIRNanos >= retryIntervalsNanos[intervalIndex] else {
            return .none
        }
        if gateAge >= rebuildGateAgeNanos || firAttempts >= rebuildAttemptThreshold,
           lastRebuildNanos == 0 || nowNanos &- lastRebuildNanos >= rebuildCooldownNanos {
            return .rebuildDecoderAndFIR
        }
        // Retries do not wait for readiness — the bound is the point. The
        // caller steps the advertised bitrate down first so the retry IDR is
        // smaller and deliverable while motion continues.
        return .backoffThenFIR
    }

    mutating func noteFIRRequested(nowNanos: UInt64) {
        lastFIRNanos = nowNanos
        firAttempts += 1
    }

    /// A rebuild re-enters the retry ladder with a fresh decoder; the FIR
    /// that accompanies it is counted separately via noteFIRRequested.
    mutating func noteDecoderRebuilt(nowNanos: UInt64) {
        lastRebuildNanos = nowNanos
        firAttempts = 0
    }
}

/// Latest loss-affected SSRC handed from the media queue to the recovery
/// supervisor. The recovery gate is global and the server sends its recovery
/// IDR on the base SSRC, so the value is advisory: transport always routes FIR
/// to the base video channel while retaining this value for diagnostics.
final class LatestLossSSRC: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt32?

    func record(_ ssrc: UInt32?) {
        guard let ssrc else { return }
        lock.lock()
        value = ssrc
        lock.unlock()
    }

    func take() -> UInt32? {
        lock.lock()
        defer { lock.unlock() }
        let taken = value
        value = nil
        return taken
    }
}

/// Retains a complete compound HEVC surface set. Moving bands are frozen into
/// one coherent publish set; Apple change-gates static tiles, so the bounded
/// fallback may pair a dirty tile with the last displayed static surface.
struct AtomicBandFrameAccumulator<Value> {
    let expectedSourceCount: Int
    private var sources: Set<UInt32> = []
    private var latest: [UInt32: Value] = [:]
    private var pendingSources: Set<UInt32> = []
    /// Freeze a synchronized surface set as soon as every band has advanced.
    /// Later decoder callbacks belong to the next set and must not overwrite
    /// one member of this set before the main thread presents it.
    private var synchronizedFrame: [UInt32: Value]?

    init(expectedSourceCount: Int) {
        self.expectedSourceCount = expectedSourceCount
    }

    mutating func submit(source: UInt32, value: Value) {
        sources.insert(source)
        latest[source] = value
        pendingSources.insert(source)
        promoteSynchronizedFrameIfPossible()
    }

    var hasSynchronizedFrame: Bool {
        synchronizedFrame != nil
    }

    var hasCompletePendingSnapshot: Bool {
        sources.count == expectedSourceCount
            && sources.allSatisfy { latest[$0] != nil }
            && !pendingSources.isEmpty
    }

    mutating func takeSynchronizedFrame() -> [UInt32: Value]? {
        guard let frame = synchronizedFrame else { return nil }
        synchronizedFrame = nil
        promoteSynchronizedFrameIfPossible()
        return frame
    }

    /// Bounded-latency escape hatch for Apple's change-gated tiles. If only a
    /// dirty band emits, publish it with the retained static bands after the
    /// coalescing deadline instead of waiting forever.
    mutating func takeLatestPendingSnapshot() -> [UInt32: Value]? {
        guard synchronizedFrame == nil, hasCompletePendingSnapshot else {
            return nil
        }
        pendingSources.removeAll(keepingCapacity: true)
        return latest.filter { sources.contains($0.key) }
    }

    private mutating func promoteSynchronizedFrameIfPossible() {
        guard synchronizedFrame == nil,
              sources.count == expectedSourceCount,
              pendingSources.count == expectedSourceCount else { return }
        synchronizedFrame = latest.filter { sources.contains($0.key) }
        pendingSources.removeAll(keepingCapacity: true)
    }
}

/// Env-gated (`ROOTSHELL_VNC_RENDER_STATS=1`) per-second render-path telemetry.
/// Prints decoded-frame arrivals, commit counts by path, main-thread hop
/// latency, and `setBands` duration — the GUI-only stretch of the pipeline
/// that headless probes cannot observe.
final class RenderCommitStats: @unchecked Sendable {
    static let shared: RenderCommitStats? =
        VNCDiagnostics.isEnabled("ROOTSHELL_VNC_RENDER_STATS")
            ? RenderCommitStats()
            : nil

    private let lock = NSLock()
    private var framesIn = 0
    private var immediateCommits = 0
    private var fallbackCommits = 0
    private var committedBands = 0
    private var hopLatenciesNanos: [UInt64] = []
    private var setBandsDurationsNanos: [UInt64] = []
    private var videoPackets = 0
    private var videoBytes = 0
    private var submittedAccessUnits = 0
    private var tick = 0
    private let timer: DispatchSourceTimer

    private init() {
        timer = DispatchSource.makeTimerSource(
            queue: DispatchQueue(label: "com.rootshell.vnc.render-stats"))
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.emit() }
        timer.resume()
    }

    func noteFrameIn() {
        lock.lock(); framesIn += 1; lock.unlock()
    }

    func noteVideoPacket(bytes: Int) {
        lock.lock(); videoPackets += 1; videoBytes += bytes; lock.unlock()
    }

    func noteSubmittedAccessUnits(_ count: Int) {
        guard count > 0 else { return }
        lock.lock(); submittedAccessUnits += count; lock.unlock()
    }

    func noteCommit(
        immediate: Bool,
        bandCount: Int,
        hopLatencyNanos: UInt64,
        setBandsNanos: UInt64
    ) {
        lock.lock()
        if immediate { immediateCommits += 1 } else { fallbackCommits += 1 }
        committedBands += bandCount
        if hopLatenciesNanos.count < 4096 { hopLatenciesNanos.append(hopLatencyNanos) }
        if setBandsDurationsNanos.count < 4096 { setBandsDurationsNanos.append(setBandsNanos) }
        lock.unlock()
    }

    private func emit() {
        lock.lock()
        tick += 1
        let t = tick
        let frames = framesIn
        let immediate = immediateCommits
        let fallback = fallbackCommits
        let bands = committedBands
        let hops = hopLatenciesNanos.sorted()
        let durations = setBandsDurationsNanos.sorted()
        let packets = videoPackets
        let kilobytes = videoBytes / 1024
        let submitted = submittedAccessUnits
        framesIn = 0
        immediateCommits = 0
        fallbackCommits = 0
        committedBands = 0
        videoPackets = 0
        videoBytes = 0
        submittedAccessUnits = 0
        hopLatenciesNanos.removeAll(keepingCapacity: true)
        setBandsDurationsNanos.removeAll(keepingCapacity: true)
        lock.unlock()

        func ms(_ sorted: [UInt64], _ p: Double) -> Double {
            guard !sorted.isEmpty else { return 0 }
            let idx = min(sorted.count - 1, Int(Double(sorted.count) * p))
            return Double(sorted[idx]) / 1_000_000
        }
        VNCLogger(category: "RenderStats").debug(String(
            format: "RSTAT t=%03d pkts=%d kB=%d sub=%d in=%d commits=%d (imm=%d fb=%d) bands=%d "
                + "hop p50=%.1fms p95=%.1fms max=%.1fms "
                + "setBands p50=%.2fms max=%.2fms",
            t, packets, kilobytes, submitted,
            frames, immediate + fallback, immediate, fallback, bands,
            ms(hops, 0.5), ms(hops, 0.95), ms(hops, 1.0),
            ms(durations, 0.5), ms(durations, 1.0)))
    }
}

/// Delivers synchronized decoded screen bands to the main-thread renderer.
/// Complete moving-band sets use one immediate FIFO main-queue hop. A short
/// deadline prevents a genuinely static/change-gated band from adding stalls.
final class BandFrameCoalescer: @unchecked Sendable {
    private let lock = NSLock()
    private var accumulator = AtomicBandFrameAccumulator<CVPixelBuffer>(
        expectedSourceCount: Int(AppleMediaVideoMode.negotiatedTilesPerFrame))
    private var immediateHopScheduled = false
    private var fallbackHopScheduled = false
    private var streamGeneration: UInt64 = 0
    private let renderer: VideoBandLayerRenderer
    /// Half a 60 Hz refresh and roughly one 120 Hz refresh. Normally every
    /// moving band arrives first and is presented immediately; this deadline
    /// applies only when the server suppresses an unchanged band.
    private let fallbackDelay = DispatchTimeInterval.milliseconds(8)

    init(
        renderer: VideoBandLayerRenderer,
        expectedSourceCount: Int = Int(AppleMediaVideoMode.negotiatedTilesPerFrame)
    ) {
        self.renderer = renderer
        accumulator = AtomicBandFrameAccumulator(
            expectedSourceCount: expectedSourceCount)
    }

    /// Drop decoded values staged from the retired media generation and queue
    /// the visual handoff before any subsequently submitted frame can queue its
    /// own main-thread hop. The renderer keeps showing its last committed
    /// surfaces until that first replacement frame exists.
    func beginStreamGeneration(
        _ generation: UInt64,
        expectedSourceCount: Int
    ) {
        lock.lock()
        streamGeneration = generation
        accumulator = AtomicBandFrameAccumulator<CVPixelBuffer>(
            expectedSourceCount: expectedSourceCount)
        immediateHopScheduled = false
        fallbackHopScheduled = false
        lock.unlock()

        DispatchQueue.main.async { [renderer] in
            MainActor.assumeIsolated {
                renderer.beginStreamGeneration(
                    expectedBandCount: expectedSourceCount)
            }
        }
    }

    func submit(ssrc: UInt32, pixelBuffer: CVPixelBuffer) {
        RenderCommitStats.shared?.noteFrameIn()
        lock.lock()
        accumulator.submit(source: ssrc, value: pixelBuffer)
        let shouldScheduleImmediate = accumulator.hasSynchronizedFrame
            && !immediateHopScheduled
        let shouldScheduleFallback = accumulator.hasCompletePendingSnapshot
            && !fallbackHopScheduled
        let generation = streamGeneration
        if shouldScheduleImmediate { immediateHopScheduled = true }
        if shouldScheduleFallback { fallbackHopScheduled = true }
        lock.unlock()

        if shouldScheduleImmediate {
            scheduleImmediateRendererHop(generation: generation)
        }
        if shouldScheduleFallback {
            scheduleFallbackRendererHop(generation: generation)
        }
    }

    private func scheduleImmediateRendererHop(generation: UInt64) {
        let scheduledNanos = DispatchTime.now().uptimeNanoseconds
        DispatchQueue.main.async { [self] in
            let hopLatency = DispatchTime.now().uptimeNanoseconds &- scheduledNanos
            lock.lock()
            guard generation == streamGeneration else {
                // This hop was queued by the retired media generation. Its
                // accumulator was deliberately discarded; leave the new
                // generation's scheduled-hop state untouched.
                lock.unlock()
                return
            }
            let frames = accumulator.takeSynchronizedFrame()
            immediateHopScheduled = false
            let scheduleNext = accumulator.hasSynchronizedFrame
            if scheduleNext { immediateHopScheduled = true }
            let scheduleFallback = accumulator.hasCompletePendingSnapshot
                && !fallbackHopScheduled
            if scheduleFallback { fallbackHopScheduled = true }
            lock.unlock()
            if let frames, !frames.isEmpty {
                let started = DispatchTime.now().uptimeNanoseconds
                MainActor.assumeIsolated {
                    renderer.setBands(frames)
                }
                RenderCommitStats.shared?.noteCommit(
                    immediate: true,
                    bandCount: frames.count,
                    hopLatencyNanos: hopLatency,
                    setBandsNanos: DispatchTime.now().uptimeNanoseconds &- started)
            }
            if scheduleNext {
                scheduleImmediateRendererHop(generation: generation)
            }
            if scheduleFallback {
                scheduleFallbackRendererHop(generation: generation)
            }
        }
    }

    private func scheduleFallbackRendererHop(generation: UInt64) {
        let deadlineNanos = DispatchTime.now().uptimeNanoseconds
            &+ UInt64(8_000_000)
        DispatchQueue.main.asyncAfter(deadline: .now() + fallbackDelay) { [self] in
            let now = DispatchTime.now().uptimeNanoseconds
            let hopLatency = now > deadlineNanos ? now &- deadlineNanos : 0
            lock.lock()
            guard generation == streamGeneration else {
                lock.unlock()
                return
            }
            let frames = accumulator.takeLatestPendingSnapshot()
            fallbackHopScheduled = false
            lock.unlock()
            guard let frames, !frames.isEmpty else { return }
            let started = DispatchTime.now().uptimeNanoseconds
            MainActor.assumeIsolated {
                renderer.setBands(frames)
            }
            RenderCommitStats.shared?.noteCommit(
                immediate: false,
                bandCount: frames.count,
                hopLatencyNanos: hopLatency,
                setBandsNanos: DispatchTime.now().uptimeNanoseconds &- started)
        }
    }
}
