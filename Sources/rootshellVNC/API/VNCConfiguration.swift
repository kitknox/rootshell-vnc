import Foundation
import RFBProtocol
import RFBTransport

/// Builds the byte-stream transport carrying one connection attempt.
///
/// The returned connection must be unconnected; the session calls
/// `connect()` on it. Throw to fail the attempt.
public typealias VNCTransportProvider =
    @Sendable (_ host: String, _ port: UInt16) async throws -> any RFBConnection

/// Opens a connected datagram socket carrying UDP media to `host:remotePort`
/// from `localPort`, for transports that bypass the OS network stack.
/// The returned descriptor is owned and closed by the session.
public typealias VNCDatagramProvider =
    @Sendable (_ host: String, _ remotePort: UInt16, _ localPort: UInt16) async throws -> Int32

/// Configuration options for a VNC session.
///
/// Use this to customize the behavior of a ``VNCSession`` before connecting.
/// All properties have sensible defaults.
public struct VNCConfiguration: Sendable {

    public typealias SecurityPolicy = VNCSecurityPolicy
    public typealias CertificateValidationRequest = VNCCertificateValidationRequest
    public typealias CertificateValidationResult = VNCCertificateValidationResult
    public typealias CertificateValidationHandler = VNCCertificateValidationHandler

    /// Security negotiation policy. Automatic is the zero-configuration
    /// default and adapts to Apple and conventional RFB servers.
    public var securityPolicy: VNCSecurityPolicy

    /// Called only when the platform trust store rejects a VeNCrypt X.509
    /// certificate. Hosts can implement TOFU without weakening validation for
    /// publicly trusted certificates.
    public var certificateValidationHandler: VNCCertificateValidationHandler?

    /// Compatibility display-count choices. A value of `2` means Apple's
    /// "all displays combined" topology; use ``DisplayMode`` when the exact
    /// native topology matters.
    public static let supportedDisplayCounts = 1...2

    /// How the server chooses the remote framebuffer dimensions.
    public enum DisplaySizingMode: String, Sendable, Equatable, CaseIterable, Identifiable {
        /// Keep the server's existing physical or virtual display size.
        case remoteDisplay
        /// Ask a capable server to render a display matching this client.
        case matchClient

        public var id: Self { self }

        public var title: String {
            switch self {
            case .remoteDisplay:
                String(localized: "Remote Display", bundle: .module, comment: "VNC display sizing mode")
            case .matchClient:
                String(localized: "Match Client", bundle: .module, comment: "VNC display sizing mode")
            }
        }

        public var explanation: String {
            switch self {
            case .remoteDisplay:
                String(localized: "Keep the remote computer's existing display dimensions.", bundle: .module)
            case .matchClient:
                String(localized: "Match this window or iPad aspect ratio. Supported Macs use a separate virtual display; other VNC servers resize only when they advertise support.", bundle: .module)
            }
        }
    }

    /// Native Apple display topology requested for the session.
    public enum DisplayMode: String, Sendable, Equatable, CaseIterable, Identifiable {
        /// Select one server display (the main display until a specific remote
        /// display is chosen after discovery).
        case oneDisplay
        /// Show the server's physical displays as one combined desktop.
        case allDisplaysCombined
        /// Create two client-sized virtual displays with independent streams.
        case twoVirtualDisplays

        public var id: Self { self }

        public var title: String {
            switch self {
            case .oneDisplay:
                String(localized: "One Display", bundle: .module, comment: "VNC display mode")
            case .allDisplaysCombined:
                String(localized: "All Displays (Combined)", bundle: .module, comment: "VNC display mode")
            case .twoVirtualDisplays:
                String(localized: "Two Virtual Displays", bundle: .module, comment: "VNC display mode")
            }
        }

        public var explanation: String {
            switch self {
            case .oneDisplay:
                String(localized: "Use one remote display for the lowest bandwidth and decoding load.", bundle: .module)
            case .allDisplaysCombined:
                String(localized: "Show the remote Mac's physical displays in one combined desktop, matching Apple Screen Sharing.", bundle: .module)
            case .twoVirtualDisplays:
                String(localized: "Ask a capable Mac for two client-sized virtual displays with independent High Performance video streams.", bundle: .module)
            }
        }

        fileprivate var count: Int {
            self == .oneDisplay ? 1 : 2
        }
    }

    /// Backing profile for the native client's connection mode and its
    /// Standard-mode quality setting.
    public enum VideoQualityMode: String, Sendable, Equatable, CaseIterable, Identifiable {
        /// Apple's High Performance connection mode. The server may lower
        /// bitrate and resolution under network pressure.
        case adaptive
        /// Apple's Standard connection mode with Adaptive quality selected.
        /// This uses the ordered TCP channel and avoids the HEVC/UDP media
        /// floor on constrained or UDP-hostile paths.
        case standard
        /// Apple's Standard connection mode with Full Quality selected, using
        /// lossless Zlib/ZRLE instead of adaptive DCT or HEVC video.
        case fullQuality

        public var id: Self { self }

        public var title: String {
            switch self {
            case .adaptive:
                String(localized: "High Performance", bundle: .module, comment: "VNC video quality mode")
            case .standard:
                String(localized: "Standard", bundle: .module, comment: "VNC video quality mode")
            case .fullQuality:
                String(localized: "Full Quality", bundle: .module, comment: "VNC video quality mode")
            }
        }

        public var explanation: String {
            switch self {
            case .adaptive:
                String(localized: "Low-latency HEVC over UDP for networks that can sustain the video stream.", bundle: .module)
            case .standard:
                String(localized: "Reliable compressed RFB over TCP for constrained networks, VPNs, and non-Mac servers.", bundle: .module)
            case .fullQuality:
                String(localized: "Lossless framebuffer updates with higher bandwidth and CPU use.", bundle: .module)
            }
        }
    }

    /// The backing connection-mode and quality profile to offer the server.
    public var videoQualityMode: VideoQualityMode {
        didSet {
            // High Performance needs UDP reachability; a tunneled transport
            // without a datagram path self-heals to Standard.
            if videoQualityMode == .adaptive, lacksDatagramPath {
                videoQualityMode = .standard
            }
            if videoQualityMode != .adaptive,
               displaySizingMode == .matchClient {
                displaySizingMode = .remoteDisplay
            }
        }
    }

    /// Host-supplied factory for the connection carrying the RFB byte stream
    /// (an SSH direct-tcpip channel, a tssh tunnel, ...). `nil` uses a direct
    /// TCP connection.
    ///
    /// The provider is invoked once per connection **attempt** — the built-in
    /// reconnection policy builds a fresh transport for every retry — so the
    /// host must re-establish or verify its underlying tunnel (for example the
    /// SSH session) on each call rather than handing out one dead channel.
    ///
    /// Apple's High Performance mode requires UDP reachability, so installing
    /// a provider without a ``datagramProvider`` clamps ``videoQualityMode``
    /// from `.adaptive` to `.standard` and removes `.adaptive` from
    /// ``availableVideoQualityModes``. Set ``datagramProvider`` first.
    public var transportProvider: VNCTransportProvider? {
        didSet {
            if lacksDatagramPath, videoQualityMode == .adaptive {
                videoQualityMode = .standard
            }
        }
    }

    /// Host-supplied UDP media path paired with ``transportProvider``. With
    /// both set, High Performance mode stays available over the tunnel.
    public var datagramProvider: VNCDatagramProvider? {
        didSet {
            if lacksDatagramPath, videoQualityMode == .adaptive {
                videoQualityMode = .standard
            }
        }
    }

    /// A custom byte-stream transport with no datagram path for UDP media.
    var lacksDatagramPath: Bool {
        transportProvider != nil && datagramProvider == nil
    }

    /// The quality modes selectable for the current transport. `.adaptive`
    /// is unavailable over a custom transport without a datagram path.
    public var availableVideoQualityModes: [VideoQualityMode] {
        !lacksDatagramPath
            ? VideoQualityMode.allCases
            : [.standard, .fullQuality]
    }

    /// Whether a capable server should render at the client viewport size.
    public var displaySizingMode: DisplaySizingMode {
        didSet {
            if videoQualityMode != .adaptive,
               displaySizingMode == .matchClient {
                displaySizingMode = .remoteDisplay
                return
            }
            guard oldValue != displaySizingMode else { return }
            if displaySizingMode == .matchClient,
               displayMode == .allDisplaysCombined {
                displayMode = .oneDisplay
            } else if displaySizingMode == .remoteDisplay,
                      displayMode == .twoVirtualDisplays {
                displayMode = .oneDisplay
            }
        }
    }

    /// Explicit native display topology. This distinguishes Apple's physical
    /// combined mode from its two-independent-virtual-display mode.
    public var displayMode: DisplayMode {
        didSet {
            switch displayMode {
            case .allDisplaysCombined:
                displaySizingMode = .remoteDisplay
            case .twoVirtualDisplays:
                if videoQualityMode == .adaptive {
                    displaySizingMode = .matchClient
                } else {
                    displayMode = .oneDisplay
                }
            case .oneDisplay:
                break
            }
        }
    }

    /// Compatibility display-count spelling for the native display topology.
    ///
    /// `1` selects one display and `2` selects Apple's combined physical-
    /// display desktop in both Standard and High Performance modes. Use
    /// ``displayMode`` to request an explicit topology. Values are clamped to
    /// `1...2`.
    public var displayCount: Int {
        get { displayMode.count }
        set {
            let count = Self.clampedDisplayCount(newValue)
            displayMode = count == 1
                ? .oneDisplay
                : .allDisplaysCombined
        }
    }

    /// Whether remote system audio should play on this device.
    ///
    /// Apple High Performance mode still negotiates its protocol-mandated
    /// audio receiver when this is `false`; the client discards those packets
    /// instead of creating an audio player.
    public var enableRemoteAudio: Bool

    /// Whether an Apple Login Window or visually detected lock screen should
    /// offer to type the saved connection password. The user must still
    /// confirm the existing password-send dialog before any input is sent.
    public var promptForLoginPasswordAtLoginWindow: Bool

    /// Who draws the remote pointer. Changing this changes which encodings the
    /// session advertises, so it takes effect only on a new connection.
    public var cursorRendering: VNCCursorRendering

    /// The pseudo-encodings that ask a server to deliver the pointer as a
    /// separate shape rather than drawn into the framebuffer. Advertising any
    /// one of them is what makes the server withhold the pointer, so
    /// server-rendered mode has to suppress all of them.
    static let clientCursorEncodings: [Encoding] = [
        .unknown(1104), .unknown(1100), .cursor, .xCursor,
    ]

    /// Whether the selected connection and sizing modes can carry remote
    /// system audio.
    var supportsRemoteAudio: Bool {
        videoQualityMode == .adaptive && displaySizingMode == .matchClient
    }

    /// Whether this session should create a remote-audio playback sink.
    var effectiveRemoteAudioPlaybackEnabled: Bool {
        supportsRemoteAudio && enableRemoteAudio
    }

    /// Preferred pixel format to request from the server.
    ///
    /// When `nil`, the session requests full-color BGRA8888.
    public var preferredPixelFormat: PixelFormat?

    /// Preferred encodings in priority order.
    ///
    /// The first encoding the server supports will be used. The list should
    /// always include `.raw` as a fallback, though it will be appended
    /// automatically if absent.
    public var preferredEncodings: [Encoding]

    /// Whether to request high-performance mode (HEVC/H.264) when available.
    ///
    /// When `true` and the server supports Apple HEVC or H.264 encodings,
    /// the session will negotiate hardware-accelerated video streaming.
    public var enableHighPerformanceMode: Bool

    /// Target frame rate for framebuffer update requests.
    ///
    /// The session will request incremental updates at approximately this rate.
    /// Valid range is 1...120; values outside this range are clamped.
    public var targetFrameRate: Int

    /// Whether to enable protocol tracing for debugging.
    ///
    /// When `true`, protocol message metadata is recorded with timestamps.
    /// Debug builds may also include bounded raw-byte prefixes; tracing is
    /// disabled by default in every build configuration.
    public var enableProtocolTrace: Bool

    /// Automatic retry behavior after an established TCP connection is lost.
    public var reconnectionPolicy: VNCReconnectionPolicy

    /// Create a VNC session configuration.
    ///
    /// - Parameters:
    ///   - preferredPixelFormat: Pixel format to request, or `nil` for full-color BGRA8888.
    ///   - preferredEncodings: Encodings in priority order.
    ///   - enableHighPerformanceMode: Whether to enable HEVC when available.
    ///   - targetFrameRate: Desired frame rate for update requests.
    ///   - enableProtocolTrace: Whether to record protocol messages.
    ///   - transportProvider: Optional factory for a host-supplied tunnel
    ///     transport; clamps `.adaptive` quality to `.standard` unless
    ///     `datagramProvider` is also given.
    ///   - datagramProvider: Optional UDP media path for the tunnel.
    public init(
        preferredPixelFormat: PixelFormat? = nil,
        preferredEncodings: [Encoding] = [.copyRect, .raw],
        enableHighPerformanceMode: Bool = true,
        videoQualityMode: VideoQualityMode = .adaptive,
        displaySizingMode: DisplaySizingMode = .matchClient,
        displayCount: Int = 1,
        displayMode: DisplayMode? = nil,
        enableRemoteAudio: Bool = true,
        promptForLoginPasswordAtLoginWindow: Bool = false,
        cursorRendering: VNCCursorRendering = .client,
        targetFrameRate: Int = 60,
        enableProtocolTrace: Bool = false,
        reconnectionPolicy: VNCReconnectionPolicy = VNCReconnectionPolicy(),
        transportProvider: VNCTransportProvider? = nil,
        datagramProvider: VNCDatagramProvider? = nil,
        securityPolicy: VNCSecurityPolicy = .automatic,
        certificateValidationHandler: VNCCertificateValidationHandler? = nil
    ) {
        self.preferredPixelFormat = preferredPixelFormat
        self.preferredEncodings = preferredEncodings
        self.enableHighPerformanceMode = enableHighPerformanceMode
        // Property observers do not run during init; apply the custom-
        // transport clamp here so every later derivation sees the final mode.
        let videoQualityMode = transportProvider != nil
            && datagramProvider == nil
            && videoQualityMode == .adaptive
            ? .standard
            : videoQualityMode
        self.videoQualityMode = videoQualityMode
        self.transportProvider = transportProvider
        self.datagramProvider = datagramProvider
        let requestedDisplayMode = displayMode ?? (
            Self.clampedDisplayCount(displayCount) == 1
                ? .oneDisplay
                : .allDisplaysCombined)
        let resolvedDisplayMode = if videoQualityMode != .adaptive,
                                     requestedDisplayMode == .twoVirtualDisplays {
            DisplayMode.oneDisplay
        } else {
            requestedDisplayMode
        }
        self.displaySizingMode = switch resolvedDisplayMode {
        case .allDisplaysCombined: .remoteDisplay
        case .twoVirtualDisplays: .matchClient
        case .oneDisplay:
            videoQualityMode == .adaptive ? displaySizingMode : .remoteDisplay
        }
        self.displayMode = resolvedDisplayMode
        self.enableRemoteAudio = enableRemoteAudio
        self.promptForLoginPasswordAtLoginWindow =
            promptForLoginPasswordAtLoginWindow
        self.cursorRendering = cursorRendering
        self.targetFrameRate = max(1, min(120, targetFrameRate))
        self.enableProtocolTrace = enableProtocolTrace
        self.reconnectionPolicy = reconnectionPolicy
        self.securityPolicy = securityPolicy
        self.certificateValidationHandler = certificateValidationHandler
    }

    private static func clampedDisplayCount(_ count: Int) -> Int {
        min(supportedDisplayCounts.upperBound,
            max(supportedDisplayCounts.lowerBound, count))
    }

    /// The interval between frame requests, derived from ``targetFrameRate``.
    var frameRequestInterval: Duration {
        .milliseconds(1000 / max(1, targetFrameRate))
    }

    /// The pixel format the session negotiates and decodes with.
    ///
    /// An explicit ``preferredPixelFormat`` always wins (pass `.rgb555` for
    /// 16-bit "thousands" color, which typically produces substantially smaller
    /// ZRLE payloads when bandwidth, not color, is the constraint).
    /// The default stays full color in every mode.
    var effectivePixelFormat: PixelFormat {
        preferredPixelFormat ?? .bgra8888
    }

    /// The full list of encodings to advertise to the server, including
    /// pseudo-encodings for desktop resize and high-performance mode.
    public var effectiveEncodings: [Encoding] {
        // Drop anything whose payload the rectangle parsers cannot frame,
        // before any mode-specific list is layered on. `preferredEncodings` is
        // caller-supplied, so filtering only the lists this property injects
        // would still let a host advertise, say, Apple SubZlib (1002) and
        // desynchronize the stream. See `Encoding.hasKnownFramebufferFraming`.
        var encodings = preferredEncodings.filter { !$0.isUnframeableContent }

        // Apple's default/high quality mode offers AVC first. Its Full Quality
        // mode does not negotiate AVC at all: the native binary's exact video
        // list is [Zlib (6), ZRLE (16)]. Keep those semantics instead of trying
        // to manufacture a "lossless HEVC" profile that the protocol lacks.
        //
        // Apple SubZlib (1002) is deliberately absent even though the native
        // viewer advertises it: no rectangle parser here can frame its
        // payload. Restore it only together with a real implementation.
        if enableHighPerformanceMode, videoQualityMode == .adaptive {
            let proModeEncodings: [Encoding] = [
                .appleH264, .appleMultiVariantScreenshare, .zlib, .zrle,
            ]
            for encoding in proModeEncodings.reversed() where !encodings.contains(encoding) {
                encodings.insert(encoding, at: 0)
            }
            for encoding in [Encoding.encryptionInfo, .serverDisplayInfo, .mediaStreamOffer, .mediaStreamAnswer] {
                if !encodings.contains(encoding) {
                    encodings.append(encoding)
                }
            }
        } else if videoQualityMode == .standard {
            // Prefer Apple's low-latency adaptive DCT path with portable
            // full-color fallbacks for servers that do not support it.
            let standardEncodings: [Encoding] = [
                .appleMultiVariantScreenshare, .tight, .lastRect,
                .zrle, .zlib, .copyRect,
                .unknown(1105), .unknown(1101), .unknown(1100), .unknown(1104),
                .raw, .unknown(-23),
            ]
            for encoding in standardEncodings.reversed() {
                encodings.removeAll { $0 == encoding }
                encodings.insert(encoding, at: 0)
            }
            // Apple's SetDisplay message selects a physical display by the ID
            // announced through ServerDisplayInfo. Standard mode needs the
            // same metadata as adaptive mode when the user requests one
            // monitor instead of the combined desktop.
            if !encodings.contains(.serverDisplayInfo) {
                encodings.append(.serverDisplayInfo)
            }
        } else if videoQualityMode == .fullQuality {
            // Full Quality targets fast local networks: bandwidth is
            // plentiful, so prefer Zlib's cheaper encode/decode over ZRLE's
            // tighter compression (matches the native binary's [Zlib, ZRLE]).
            let fullQualityEncodings: [Encoding] = [
                .copyRect, .zlib, .zrle, .raw,
            ]
            for encoding in fullQualityEncodings.reversed() {
                encodings.removeAll { $0 == encoding }
                encodings.insert(encoding, at: 0)
            }
        }

        // Advertise both the legacy notification and the bidirectional screen
        // layout extension. SetDesktopSize is sent only after a server proves
        // support by returning ExtendedDesktopSize.
        if !encodings.contains(.desktopSize) {
            encodings.append(.desktopSize)
        }
        if !encodings.contains(.extendedDesktopSize) {
            encodings.append(.extendedDesktopSize)
        }

        // DisplayInfo2 carries both display layout and the real Login Window
        // state (ordinary user locks require the visual fallback). macOS also
        // uses its cached CursorImageAlpha record instead of the standard RFB
        // cursor shape. Advertise all three in every quality
        // mode; other VNC servers simply ignore these pseudo-encodings.
        for encoding in [Encoding.unknown(1105), .unknown(1104), .unknown(1100)] {
            if !encodings.contains(encoding) {
                encodings.append(encoding)
            }
        }

        // Always include the portable cursor pseudo-encodings as fallbacks.
        if !encodings.contains(.cursor) {
            encodings.append(.cursor)
        }
        // TightVNC 1.x commonly uses its older two-color XCursor path even
        // though newer servers support the standard full-color Cursor shape.
        if !encodings.contains(.xCursor) {
            encodings.append(.xCursor)
        }

        // Strip the cursor pseudo-encodings in one place rather than gating
        // each list above: Standard mode front-loads 1100 and 1104 with its
        // own priorities, and `preferredEncodings` is caller-supplied, so a
        // per-site condition would leave a way for one to survive. Running
        // only in server mode keeps the client list byte-identical.
        //
        // DisplayInfo2 (1105) is deliberately not in this set. It carries
        // display layout and Login Window state, nothing about the pointer.
        if cursorRendering == .server {
            encodings.removeAll { Self.clientCursorEncodings.contains($0) }
        }

        // Ensure raw is present as ultimate fallback
        if !encodings.contains(.raw) {
            encodings.append(.raw)
        }

        return encodings
    }
}
