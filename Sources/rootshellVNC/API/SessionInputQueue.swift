import Foundation
import RFBProtocol

/// Ordered UI input waiting for the RFB control channel.
///
/// Pointer and scroll callbacks can arrive faster than an encrypted TCP write
/// completes. Keeping every intermediate position creates an ever-growing
/// latency tail: the remote cursor faithfully replays where the pointer used to
/// be. This queue preserves transitions and total scroll displacement while
/// coalescing only redundant samples within one uninterrupted input run.
enum SessionInputEvent: Sendable, Equatable {
    case key(downFlag: Bool, keysym: UInt32)
    /// An ordering barrier used for input sequences that remote login fields
    /// can otherwise process too quickly. This never produces an RFB message.
    case pause(nanoseconds: UInt64)
    case pointer(buttonMask: UInt8, x: UInt16, y: UInt16)
    case scroll(AppleScrollEvent)
    case gesture(AppleGestureEvent)
    case clipboard(ClipboardContent)
    case clipboardRequest
    case sharedClipboard(Bool)
    case curtain(enabled: Bool, message: String)
}

struct SessionInputQueue: Sendable {
    private(set) var pending: [SessionInputEvent] = []

    var count: Int { pending.count }
    var isEmpty: Bool { pending.isEmpty }

    mutating func enqueue(_ event: SessionInputEvent) {
        guard let last = pending.last else {
            pending.append(event)
            return
        }

        switch (last, event) {
        case let (
            .pointer(lastMask, _, _),
            .pointer(newMask, newX, newY)
        ) where lastMask == newMask:
            // Retain the first sample after a button transition so a delayed
            // drag still presses on the intended control. Thereafter only the
            // newest absolute position matters.
            if pending.count >= 2,
               case .pointer(let previousMask, _, _) = pending[pending.count - 2],
               previousMask == newMask {
                pending[pending.count - 1] = .pointer(
                    buttonMask: newMask,
                    x: newX,
                    y: newY)
            } else {
                pending.append(event)
            }

        case let (.scroll(lastScroll), .scroll(newScroll)):
            if let merged = lastScroll.mergingQueuedContinuousSample(newScroll) {
                pending[pending.count - 1] = .scroll(merged)
            } else {
                pending.append(event)
            }

        default:
            // Key transitions, button transitions, scroll lifecycle boundaries,
            // and clipboard and curtain messages are ordering barriers and are
            // never merged.
            pending.append(event)
        }
    }

    mutating func dequeue() -> SessionInputEvent? {
        guard !pending.isEmpty else { return nil }
        return pending.removeFirst()
    }

    func peek() -> SessionInputEvent? {
        pending.first
    }

    mutating func removeAll() {
        pending.removeAll(keepingCapacity: true)
    }
}

private extension AppleScrollEvent {
    func mergingQueuedContinuousSample(_ newer: AppleScrollEvent) -> AppleScrollEvent? {
        let changedScroll = scrollPhase == .changed
            && newer.scrollPhase == .changed
            && momentumPhase == .none
            && newer.momentumPhase == .none
        let changedMomentum = momentumPhase == .changed
            && newer.momentumPhase == .changed
            && scrollPhase == .none
            && newer.scrollPhase == .none
        guard changedScroll || changedMomentum else { return nil }

        return AppleScrollEvent(
            deltaX: Self.saturatingAdd(deltaX, newer.deltaX),
            deltaY: Self.saturatingAdd(deltaY, newer.deltaY),
            deltaZ: Self.saturatingAdd(deltaZ, newer.deltaZ),
            fixedDeltaX: Self.saturatingAdd(fixedDeltaX, newer.fixedDeltaX),
            fixedDeltaY: Self.saturatingAdd(fixedDeltaY, newer.fixedDeltaY),
            fixedDeltaZ: Self.saturatingAdd(fixedDeltaZ, newer.fixedDeltaZ),
            pointDeltaX: Self.saturatingAdd(pointDeltaX, newer.pointDeltaX),
            pointDeltaY: Self.saturatingAdd(pointDeltaY, newer.pointDeltaY),
            pointDeltaZ: Self.saturatingAdd(pointDeltaZ, newer.pointDeltaZ),
            scrollPhase: newer.scrollPhase,
            momentumPhase: newer.momentumPhase,
            scrollCount: scrollCount.addingReportingOverflow(newer.scrollCount).overflow
                ? .max
                : scrollCount + newer.scrollCount,
            flags: flags.union(newer.flags),
            x: newer.x,
            y: newer.y)
    }

    static func saturatingAdd(_ lhs: Int16, _ rhs: Int16) -> Int16 {
        Int16(clamping: Int32(lhs) + Int32(rhs))
    }

    static func saturatingAdd(_ lhs: Int32, _ rhs: Int32) -> Int32 {
        Int32(clamping: Int64(lhs) + Int64(rhs))
    }
}
