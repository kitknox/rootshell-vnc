import CoreGraphics
import Foundation

/// Finger speed in view points per second, derived from the touch callbacks
/// themselves rather than from a recognizer's own velocity reading.
///
/// `TrackpadPointerModel` picks a point on its acceleration curve from this
/// number, so the figure has to be stable: a raw per-callback quotient swings
/// wildly because UIKit does not deliver touches on an even cadence, and every
/// swing becomes a visible change in cursor gain within a single stroke. A
/// light exponential average keeps the curve tracking the stroke instead of
/// the delivery schedule, while still reacting inside a few frames.
///
/// Intervals are floored rather than discarded: two callbacks a microsecond
/// apart would otherwise divide by nearly zero and report a flick the finger
/// never made.
struct TrackpadVelocityEstimator: Equatable, Sendable {
    /// Weight of the newest sample in the running average. Low enough to
    /// absorb cadence jitter, high enough that a deliberate acceleration is
    /// honoured within roughly three touch callbacks.
    static let smoothingFactor: CGFloat = 0.4
    /// Shortest interval treated as real elapsed time, in seconds.
    static let minimumInterval: Double = 0.001

    private(set) var velocity: CGFloat = 0
    private var lastTimestamp: Double?

    /// Folds one translation delta into the average and returns the speed to
    /// use for it. The first sample of a stroke has no interval to measure, so
    /// it reports zero: the opening motion is deliberately unaccelerated.
    @discardableResult
    mutating func record(
        translation: CGPoint,
        at timestamp: Double
    ) -> CGFloat {
        guard translation.x.isFinite, translation.y.isFinite,
              timestamp.isFinite else { return velocity }
        defer { lastTimestamp = timestamp }
        guard let lastTimestamp else { return velocity }

        let interval = max(timestamp - lastTimestamp, Self.minimumInterval)
        let sample = hypot(translation.x, translation.y) / CGFloat(interval)
        velocity += (sample - velocity) * Self.smoothingFactor
        return velocity
    }

    mutating func reset() {
        velocity = 0
        lastTimestamp = nil
    }
}

/// Converts a pane-local framebuffer coordinate into the coordinate the RFB
/// pointer event carries.
///
/// A pane shows one display out of a possibly larger server framebuffer, so
/// every position the viewport produces is local to that display and has to be
/// shifted by the pane's origin before it goes on the wire. This mirrors the
/// clamping the touch path applies, so a virtual cursor and a finger address
/// the same pixel.
enum TrackpadPointerWire {
    static func wirePoint(
        framebufferPoint point: (x: UInt16, y: UInt16),
        origin: CGPoint
    ) -> (x: UInt16, y: UInt16) {
        (coordinate(CGFloat(point.x) + origin.x),
         coordinate(CGFloat(point.y) + origin.y))
    }

    /// Inverse of `wirePoint`, used to seed a cursor from the last position
    /// the pane sent. Returns a fractional point because the model clamps and
    /// rounds it itself.
    static func framebufferPoint(
        wirePoint point: (x: UInt16, y: UInt16),
        origin: CGPoint
    ) -> CGPoint {
        guard origin.x.isFinite, origin.y.isFinite else {
            return CGPoint(x: CGFloat(point.x), y: CGFloat(point.y))
        }
        return CGPoint(
            x: CGFloat(point.x) - origin.x,
            y: CGFloat(point.y) - origin.y)
    }

    private static func coordinate(_ value: CGFloat) -> UInt16 {
        guard value.isFinite else { return 0 }
        return UInt16(min(CGFloat(UInt16.max), max(0, value)))
    }
}

/// Server cursor pixels are authoritative. An original arrow is used only
/// while relative input is waiting for its first server cursor description.
/// A picture with the pointer painted in gets at most a dot marking where
/// local input lands, ahead of the video.
enum TrackpadCursorStyle: Equatable, Sendable {
    case serverBitmap
    case fallbackArrow
    case localDot
    case hidden

    static func resolve(
        hasServerCursor: Bool,
        presence: RemoteCursorPresence,
        allowingFallback: Bool,
        serverRendersCursor: Bool,
        showsLocalDot: Bool = false
    ) -> Self {
        if serverRendersCursor {
            return allowingFallback && showsLocalDot ? .localDot : .hidden
        }
        guard presence != .hidden else { return .hidden }
        if hasServerCursor { return .serverBitmap }
        return allowingFallback && presence == .undescribed ? .fallbackArrow : .hidden
    }

    static let defaultCursorHeight: CGFloat = 17
    /// Local dot diameter at the default cursor height.
    static let defaultLocalDotDiameter: CGFloat = 10

    static func localDotDiameter(cursorHeight: CGFloat) -> CGFloat {
        defaultLocalDotDiameter * bitmapScale(cursorHeight: cursorHeight)
    }
    static let minimumCursorHeight: CGFloat = 8
    static let maximumCursorHeight: CGFloat = 64

    static func resolvedCursorHeight(_ requested: CGFloat) -> CGFloat {
        guard requested.isFinite else { return defaultCursorHeight }
        return min(maximumCursorHeight, max(minimumCursorHeight, requested))
    }

    /// Default size preserves each server pixel as one view point. The size
    /// preference applies a uniform multiplier to every shape and its hotspot;
    /// it never guesses an arrow or normalizes a short resize cursor's height.
    static func bitmapScale(cursorHeight: CGFloat) -> CGFloat {
        resolvedCursorHeight(cursorHeight) / defaultCursorHeight
    }

}

/// When the desktop starts moving to keep the virtual cursor in view.
///
/// Panning as soon as the cursor nears an edge pins it against that edge and
/// leaves the user reading a desktop that never settles. Holding a generous
/// central rectangle instead makes the viewport behave like a camera trailing
/// the pointer: it stays still while the cursor works in the middle of the
/// screen, and takes up the chase only once the cursor commits to a direction.
enum TrackpadFollowPolicy {
    /// Share of each axis reserved as an inset on that side, leaving a central
    /// dead zone of 60% x 60% where the cursor moves and the desktop does not.
    static let deadZoneInsetFraction: CGFloat = 0.2
}
