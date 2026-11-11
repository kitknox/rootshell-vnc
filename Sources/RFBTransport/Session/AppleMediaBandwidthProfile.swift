import Foundation

/// The bitrate range a Mac's High Performance encoder works in. The Mac takes
/// its floor from the screen offer's negotiator mode, not from the advertised
/// bandwidth, so a path below 20 Mbps needs mode 5.
public enum AppleMediaBandwidthProfile: String, Sendable, Equatable, CaseIterable {
    /// Screen Sharing's own range, 20 to 60 Mbps.
    case full
    /// 333 kbps to 6 Mbps, for cellular, relayed, and other slow paths.
    case constrained

    /// Negotiator mode of the screen offer.
    var screenNegotiatorMode: Int {
        switch self {
        case .full: 7
        case .constrained: 5
        }
    }

    /// The Mac's encoder floor for this mode.
    public var minimumBitrateBps: Double {
        switch self {
        case .full: 20_000_000
        case .constrained: 333_000
        }
    }

    /// The Mac's encoder ceiling for this mode.
    public var maximumBitrateBps: Double {
        switch self {
        case .full: AppleMediaRateController.nativeScreenMaximumBitrateBps
        case .constrained: 6_000_000
        }
    }
}
