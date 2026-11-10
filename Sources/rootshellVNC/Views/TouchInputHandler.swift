import SwiftUI
import RFBProtocol

/// Translates iOS/macOS touch and mouse gestures into VNC pointer events.
///
/// This handler converts high-level gesture callbacks (tap, drag, scroll)
/// into the low-level RFB pointer events expected by a VNC server.
///
/// VNC pointer events use a button mask bitmask:
/// - Bit 0 (0x01): Left button
/// - Bit 1 (0x02): Middle button
/// - Bit 2 (0x04): Right button
/// - Bit 3 (0x08): Scroll up (wheel up)
/// - Bit 4 (0x10): Scroll down (wheel down)
@MainActor
public struct TouchInputHandler {

    // MARK: - Types

    /// A closure that sends a pointer event to the VNC server.
    ///
    /// - Parameters:
    ///   - buttonMask: Bitmask of pressed buttons.
    ///   - x: X coordinate in framebuffer pixels.
    ///   - y: Y coordinate in framebuffer pixels.
    public typealias PointerEventHandler = @MainActor (UInt8, UInt16, UInt16) -> Void
    /// A closure that sends one continuous scroll sample. The session chooses
    /// precise Apple input or ordinary RFB wheel buttons from server capability
    /// negotiation.
    public typealias ScrollEventHandler = @MainActor (AppleScrollEvent) -> Void
    /// A closure that sends the native begin/end envelope around precise
    /// scrolling. Conventional RFB transports ignore these events.
    public typealias GestureEventHandler = @MainActor (AppleGestureEvent) -> Void

    // MARK: - Button mask constants

    /// Left mouse button.
    public nonisolated static let leftButton: UInt8 = 0x01
    /// Middle mouse button.
    public nonisolated static let middleButton: UInt8 = 0x02
    /// Right mouse button.
    public nonisolated static let rightButton: UInt8 = 0x04
    /// Scroll wheel up.
    public nonisolated static let scrollUp: UInt8 = 0x08
    /// Scroll wheel down.
    public nonisolated static let scrollDown: UInt8 = 0x10

    // MARK: - Properties

    private let sendPointerEvent: PointerEventHandler
    private let sendScrollEvent: ScrollEventHandler?
    private let sendGestureEvent: GestureEventHandler?

    // MARK: - Init

    /// Create a touch input handler that delegates pointer events to the given closure.
    ///
    /// - Parameter sendPointerEvent: A closure called with (buttonMask, x, y)
    ///   for each generated pointer event.
    public init(sendPointerEvent: @escaping PointerEventHandler) {
        self.sendPointerEvent = sendPointerEvent
        self.sendScrollEvent = nil
        self.sendGestureEvent = nil
    }

    public init(
        sendPointerEvent: @escaping PointerEventHandler,
        sendScrollEvent: @escaping ScrollEventHandler,
        sendGestureEvent: GestureEventHandler? = nil
    ) {
        self.sendPointerEvent = sendPointerEvent
        self.sendScrollEvent = sendScrollEvent
        self.sendGestureEvent = sendGestureEvent
    }

    // MARK: - Gesture Handlers

    /// Handle a single tap at the given framebuffer coordinates.
    ///
    /// Generates a left-button press followed by a release to simulate a click.
    ///
    /// - Parameters:
    ///   - x: X coordinate in framebuffer pixels.
    ///   - y: Y coordinate in framebuffer pixels.
    public func handleTap(x: UInt16, y: UInt16) {
        handleClick(.left, x: x, y: y)
    }

    /// Click `button` once: move, press, release.
    public func handleClick(_ button: RemotePointerButton, x: UInt16, y: UInt16) {
        sendPointerEvent(0, x, y)
        sendPointerEvent(button.mask, x, y)
        sendPointerEvent(0, x, y)
    }

    /// Middle-click, which browsers use to open links in a new tab.
    public func handleMiddleClick(x: UInt16, y: UInt16) {
        handleClick(.middle, x: x, y: y)
    }

    /// Handle a right-click (context menu) at the given framebuffer coordinates.
    ///
    /// Typically triggered by a two-finger tap on iOS or right-click on macOS.
    ///
    /// - Parameters:
    ///   - x: X coordinate in framebuffer pixels.
    ///   - y: Y coordinate in framebuffer pixels.
    public func handleRightClick(x: UInt16, y: UInt16) {
        handleClick(.right, x: x, y: y)
    }

    /// Handle pointer movement (e.g., during a drag gesture).
    ///
    /// Sends a pointer event with no buttons pressed, indicating cursor movement.
    ///
    /// - Parameters:
    ///   - x: X coordinate in framebuffer pixels.
    ///   - y: Y coordinate in framebuffer pixels.
    public func handleMove(x: UInt16, y: UInt16) {
        sendPointerEvent(0, x, y)
    }

    /// Handle a drag with `button` held down.
    ///
    /// - Parameters:
    ///   - x: X coordinate in framebuffer pixels.
    ///   - y: Y coordinate in framebuffer pixels.
    ///   - button: The button held through the drag.
    public func handleDrag(x: UInt16, y: UInt16, button: RemotePointerButton = .left) {
        sendPointerEvent(button.mask, x, y)
    }

    /// Handle a drag end (release every button).
    ///
    /// - Parameters:
    ///   - x: X coordinate in framebuffer pixels.
    ///   - y: Y coordinate in framebuffer pixels.
    public func handleDragEnd(x: UInt16, y: UInt16) {
        sendPointerEvent(0, x, y)
    }

    /// Handle a scroll event at the given framebuffer coordinates.
    ///
    /// Translates vertical scroll deltas into VNC scroll-wheel button events.
    /// Positive deltaY scrolls up and negative deltaY scrolls down, matching
    /// the CGEvent convention used by Apple's native RFB fallback.
    ///
    /// - Parameters:
    ///   - x: X coordinate in framebuffer pixels.
    ///   - y: Y coordinate in framebuffer pixels.
    ///   - deltaY: The vertical scroll amount. Positive = up, negative = down.
    public func handleScroll(x: UInt16, y: UInt16, deltaY: CGFloat) {
        // VNC uses button 4 (bit 3) for scroll up and button 5 (bit 4) for scroll down.
        // Each click of the wheel is a separate press+release pair.
        guard deltaY != 0 else { return }
        let magnitude = min(20, max(1, Int(abs(deltaY) / 10)))
        handleScroll(
            x: x,
            y: y,
            steps: deltaY > 0 ? magnitude : -magnitude)
    }

    /// Send an exact signed number of VNC wheel clicks. Positive values scroll
    /// up and negative values scroll down.
    public func handleScroll(x: UInt16, y: UInt16, steps: Int) {
        guard steps != 0 else { return }
        let magnitude = Int(min(UInt(20), steps.magnitude))
        let button: UInt8 = steps > 0 ? Self.scrollUp : Self.scrollDown

        for _ in 0..<magnitude {
            sendPointerEvent(button, x, y)
            sendPointerEvent(0, x, y)
        }
    }

    /// Forward a point-accurate continuous scroll sample. CoreGraphics carries
    /// point pixels alongside accelerated whole-wheel and signed 16.16 wheel
    /// units; the conversion below matches values measured from trackpad events.
    public func handleScroll(
        x: UInt16,
        y: UInt16,
        pointDeltaX: Int32,
        pointDeltaY: Int32,
        scrollPhase: AppleScrollEvent.Phase,
        momentumPhase: AppleScrollEvent.MomentumPhase = .none
    ) {
        handleScroll(
            x: x,
            y: y,
            pointDeltaX: pointDeltaX,
            pointDeltaY: pointDeltaY,
            coarseDeltaX: Self.coarseDelta(for: pointDeltaX),
            coarseDeltaY: Self.coarseDelta(for: pointDeltaY),
            scrollPhase: scrollPhase,
            momentumPhase: momentumPhase)
    }

    /// Forward a continuous scroll sample whose whole-wheel deltas were
    /// accumulated across the gesture (see `ScrollWheelUnitAccumulator`).
    /// Per-sample truncation would let a stream of small deltas either vanish
    /// or, worse, round each sample up to a full wheel line — line-based
    /// scrollers such as remote terminals read the coarse field and race away.
    public func handleScroll(
        x: UInt16,
        y: UInt16,
        pointDeltaX: Int32,
        pointDeltaY: Int32,
        coarseDeltaX: Int16,
        coarseDeltaY: Int16,
        scrollPhase: AppleScrollEvent.Phase,
        momentumPhase: AppleScrollEvent.MomentumPhase = .none
    ) {
        let event = AppleScrollEvent(
            deltaX: coarseDeltaX,
            deltaY: coarseDeltaY,
            fixedDeltaX: Self.fixed16_16(for: pointDeltaX),
            fixedDeltaY: Self.fixed16_16(for: pointDeltaY),
            pointDeltaX: pointDeltaX,
            pointDeltaY: pointDeltaY,
            scrollPhase: scrollPhase,
            momentumPhase: momentumPhase,
            flags: [.continuous, .directionInvertedFromDevice],
            x: x,
            y: y)

        if let sendScrollEvent {
            sendScrollEvent(event)
        } else if event.deltaY != 0 {
            handleScroll(x: x, y: y, steps: Int(event.deltaY))
        }
    }

    /// Points of motion per one whole wheel unit, matching values measured
    /// from public trackpad CGEvents.
    nonisolated static let pointsPerWheelUnit: Int64 = 10

    private nonisolated static func fixed16_16(for pointDelta: Int32) -> Int32 {
        // Integer division preserves the sign and total direction.
        Int32(clamping: Int64(pointDelta) * 65_536 / pointsPerWheelUnit)
    }

    private nonisolated static func coarseDelta(for pointDelta: Int32) -> Int16 {
        Int16(clamping: Int64(pointDelta) / pointsPerWheelUnit)
    }

    /// Forward the gesture envelope defined around
    /// precise scroll-wheel records.
    public func handleGesture(
        kind: AppleGestureEvent.Kind,
        x: UInt16,
        y: UInt16
    ) {
        sendGestureEvent?(AppleGestureEvent(kind: kind, x: x, y: y))
    }


    /// Handle a double-tap at the given framebuffer coordinates.
    ///
    /// Generates two consecutive left-button click sequences.
    ///
    /// - Parameters:
    ///   - x: X coordinate in framebuffer pixels.
    ///   - y: Y coordinate in framebuffer pixels.
    public func handleDoubleTap(x: UInt16, y: UInt16) {
        handleTap(x: x, y: y)
        handleTap(x: x, y: y)
    }
}

/// Converts fractional UIKit point movement to the integer point fields on the
/// wire without losing sub-point motion between callbacks.
struct ScrollPointAccumulator: Equatable, Sendable {
    private(set) var remainderX: CGFloat = 0
    private(set) var remainderY: CGFloat = 0

    mutating func consume(deltaX: CGFloat, deltaY: CGFloat) -> (x: Int32, y: Int32) {
        guard deltaX.isFinite, deltaY.isFinite else { return (0, 0) }
        remainderX += deltaX
        remainderY += deltaY
        let x = Self.consumeAxis(&remainderX)
        let y = Self.consumeAxis(&remainderY)
        return (x, y)
    }

    mutating func reset() {
        remainderX = 0
        remainderY = 0
    }

    private static func consumeAxis(_ remainder: inout CGFloat) -> Int32 {
        if remainder >= CGFloat(Int32.max) {
            remainder = 0
            return Int32.max
        }
        if remainder <= CGFloat(Int32.min) {
            remainder = 0
            return Int32.min
        }
        let whole = Int32(remainder.rounded(.towardZero))
        remainder -= CGFloat(whole)
        return whole
    }
}

/// Estimates a gesture's release velocity from displacement across a trailing
/// time window, matching how native scroll views derive their fling velocity.
///
/// A single frame pair is hostage to lift-off noise: a sub-point wobble in the
/// final few milliseconds reads as a fast fling in whatever direction the
/// finger rolled while leaving the glass, sending momentum spiraling opposite
/// to the drag. Displacement over the recent window keeps the tail aligned
/// with the gesture's real motion, and a still finger naturally decays the
/// window to zero so resting before lifting produces no fling.
struct ScrollReleaseVelocityEstimator: Equatable, Sendable {
    private struct Sample: Equatable {
        var timestamp: CFTimeInterval
        var position: CGPoint
    }

    /// Motion history considered when deriving the release velocity.
    static let window: CFTimeInterval = 0.1
    /// A release this long after the last recorded movement is a stationary
    /// lift, never a fling.
    static let maximumReleaseGap: CFTimeInterval = 0.15
    /// Velocity floor for very short gestures so two samples a millisecond
    /// apart cannot inflate into an enormous fling.
    private static let minimumSpan: CFTimeInterval = 0.02

    private var samples: [Sample] = []

    mutating func record(position: CGPoint, at timestamp: CFTimeInterval) {
        samples.append(Sample(timestamp: timestamp, position: position))
        // Keep one sample beyond the window so the measured span always
        // covers the full window once enough history exists.
        while samples.count > 2,
              samples[1].timestamp <= timestamp - Self.window {
            samples.removeFirst()
        }
    }

    mutating func reset() {
        samples.removeAll(keepingCapacity: true)
    }

    func releaseVelocity(at releaseTime: CFTimeInterval) -> CGPoint {
        guard let newest = samples.last,
              let oldest = samples.first,
              releaseTime - newest.timestamp <= Self.maximumReleaseGap else {
            return CGPoint(x: 0, y: 0)
        }
        let span = max(newest.timestamp - oldest.timestamp, Self.minimumSpan)
        return CGPoint(
            x: (newest.position.x - oldest.position.x) / CGFloat(span),
            y: (newest.position.y - oldest.position.y) / CGFloat(span))
    }
}

/// Converts integer point deltas into whole wheel units without losing the
/// sub-unit points between samples. Emitting truncated-with-carry whole
/// units keeps a gesture's coarse total equal to its point total divided by
/// `TouchInputHandler.pointsPerWheelUnit`, mirroring how real trackpad
/// CGEvents relate the two representations. Remainders are kept in exact
/// integer point space.
struct ScrollWheelUnitAccumulator: Equatable, Sendable {
    private(set) var remainderX: Int64 = 0
    private(set) var remainderY: Int64 = 0

    mutating func consume(pointDeltaX: Int32, pointDeltaY: Int32) -> (x: Int16, y: Int16) {
        remainderX += Int64(pointDeltaX)
        remainderY += Int64(pointDeltaY)
        let x = Self.consumeAxis(&remainderX)
        let y = Self.consumeAxis(&remainderY)
        return (x, y)
    }

    mutating func reset() {
        remainderX = 0
        remainderY = 0
    }

    private static func consumeAxis(_ remainder: inout Int64) -> Int16 {
        let wholeUnits = remainder / TouchInputHandler.pointsPerWheelUnit
        let clamped = Int16(clamping: wholeUnits)
        if Int64(clamped) != wholeUnits {
            remainder = 0
            return clamped
        }
        remainder -= wholeUnits * TouchInputHandler.pointsPerWheelUnit
        return clamped
    }
}

/// Holds the first few points of a scroll long enough to distinguish a
/// deliberate horizontal swipe from ordinary two-dimensional scrolling.
///
/// AppKit's fluid swipe tracking (used by controls such as Mail's message-row
/// actions) abandons a horizontal swipe when the opening samples contain
/// enough vertical movement. Direct iPad touches are substantially noisier
/// than a Mac trackpad. Once horizontal intent is clear, keep that physical
/// gesture on the horizontal axis. Vertical and genuinely diagonal scrolling
/// remain unrestricted.
struct HorizontalScrollIntentFilter: Equatable, Sendable {
    private enum State: Equatable, Sendable {
        case undecided
        case horizontal
        case unrestricted
    }

    private static let decisionDistance: CGFloat = 4
    private static let horizontalDominance: CGFloat = 1.25
    private static let verticalDominance: CGFloat = 2
    private static let unrestrictedDecisionDistance: CGFloat = 8

    private var state: State = .undecided
    private var pendingX: CGFloat = 0
    private var pendingY: CGFloat = 0

    var isHorizontallyLocked: Bool {
        state == .horizontal
    }

    mutating func consume(deltaX: CGFloat, deltaY: CGFloat) -> CGPoint {
        guard deltaX.isFinite, deltaY.isFinite else { return CGPoint(x: 0, y: 0) }

        switch state {
        case .horizontal:
            return CGPoint(x: deltaX, y: 0)
        case .unrestricted:
            return CGPoint(x: deltaX, y: deltaY)
        case .undecided:
            pendingX += deltaX
            pendingY += deltaY

            let absoluteX = abs(pendingX)
            let absoluteY = abs(pendingY)
            guard max(absoluteX, absoluteY) >= Self.decisionDistance else {
                return CGPoint(x: 0, y: 0)
            }

            if absoluteX >= absoluteY * Self.horizontalDominance {
                state = .horizontal
                return drain(horizontalOnly: true)
            }

            // Keep clearly vertical starts responsive, but do not lock an
            // ambiguous opening wobble to unrestricted scrolling after only
            // a few points. A finger can easily begin at (3, 4) before its
            // horizontal intent becomes apparent.
            if absoluteY >= absoluteX * Self.verticalDominance
                || max(absoluteX, absoluteY) >= Self.unrestrictedDecisionDistance {
                state = .unrestricted
                return drain(horizontalOnly: false)
            }
            return CGPoint(x: 0, y: 0)
        }
    }

    mutating func flush() -> CGPoint {
        guard state == .undecided else { return CGPoint(x: 0, y: 0) }
        state = .unrestricted
        return drain(horizontalOnly: false)
    }

    mutating func reset() {
        state = .undecided
        pendingX = 0
        pendingY = 0
    }

    private mutating func drain(horizontalOnly: Bool) -> CGPoint {
        let result = CGPoint(
            x: pendingX,
            y: horizontalOnly ? 0 : pendingY)
        pendingX = 0
        pendingY = 0
        return result
    }
}
