import Foundation
import RFBProtocol
import Security

/// Login-window and console state published by Apple's DisplayInfo2 extension.
public struct AppleRemoteSessionState: Sendable, Equatable {
    /// The macOS Login Window is the active server session.
    public let loginWindowActive: Bool

    /// The server is showing the Login Window as a lock screen.
    public let loginWindowLockScreenActive: Bool

    /// The server will accept curtain mode commands. This tracks the remote
    /// account's rights and console state, so it can change mid-session.
    public let curtainToggleAvailable: Bool

    /// The remote session is being drawn on the Mac's physical display.
    public let onConsole: Bool

    /// Whether the remote Mac is currently waiting at either login surface.
    public var requiresLogin: Bool {
        loginWindowActive || loginWindowLockScreenActive
    }

    /// Curtain mode is active: the session left the console, so the Mac's own
    /// display shows a lock screen instead of this session's content.
    public var curtained: Bool {
        !onConsole
    }

    public init(
        loginWindowActive: Bool,
        loginWindowLockScreenActive: Bool,
        curtainToggleAvailable: Bool = false,
        onConsole: Bool = true
    ) {
        self.loginWindowActive = loginWindowActive
        self.loginWindowLockScreenActive = loginWindowLockScreenActive
        self.curtainToggleAvailable = curtainToggleAvailable
        self.onConsole = onConsole
    }
}

/// One RTCP Sender Report mapping a remote RTP source onto the server's shared
/// NTP media clock. Audio and video use different RTP epochs and rates; this
/// mapping is the common clock needed for synchronized presentation.
public struct AppleMediaSenderClockMapping: Sendable, Equatable {
    public let remoteSSRC: UInt32
    public let ntpTimestamp: UInt64
    public let rtpTimestamp: UInt32

    public init(
        remoteSSRC: UInt32,
        ntpTimestamp: UInt64,
        rtpTimestamp: UInt32
    ) {
        self.remoteSSRC = remoteSSRC
        self.ntpTimestamp = ntpTimestamp
        self.rtpTimestamp = rtpTimestamp
    }
}

/// Decode the session-wide flags in Apple's DisplayInfo2 (encoding 1105).
/// The RFB payload includes a two-byte length prefix, so the structure's
/// version and screen-flags fields begin at byte offsets 2 and 16.
struct AppleDisplayInfo2SessionMetadata: Equatable {
    let version: UInt16
    let screenFlagsBigEndian: UInt32
    let screenFlagsLittleEndian: UInt32
    let hasLengthPrefix: Bool

    var state: AppleRemoteSessionState {
        // DisplayInfo2's geometry fields are network ordered, but macOS
        // releases have emitted screenFlags in both byte orders. Since this is
        // a bitset whose defined values occupy the low byte, checking both
        // interpretations is unambiguous and avoids rejecting either form.
        let flags = screenFlagsBigEndian | screenFlagsLittleEndian
        return AppleRemoteSessionState(
            loginWindowActive: flags & 0x10 != 0,
            loginWindowLockScreenActive: flags & 0x08 != 0,
            curtainToggleAvailable: flags & 0x02 != 0,
            onConsole: flags & 0x04 != 0)
    }
}

func appleDisplayInfo2SessionMetadata(
    _ payload: Data
) -> AppleDisplayInfo2SessionMetadata? {
    guard payload.count >= 18 else { return nil }
    let start = payload.startIndex
    func uint16BE(at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= payload.count else { return nil }
        return UInt16(payload[start + offset]) << 8
            | UInt16(payload[start + offset + 1])
    }
    func uint16LE(at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= payload.count else { return nil }
        return UInt16(payload[start + offset])
            | UInt16(payload[start + offset + 1]) << 8
    }
    func uint32BE(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= payload.count else { return nil }
        return UInt32(payload[start + offset]) << 24
            | UInt32(payload[start + offset + 1]) << 16
            | UInt32(payload[start + offset + 2]) << 8
            | UInt32(payload[start + offset + 3])
    }
    func uint32LE(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= payload.count else { return nil }
        return UInt32(payload[start + offset])
            | UInt32(payload[start + offset + 1]) << 8
            | UInt32(payload[start + offset + 2]) << 16
            | UInt32(payload[start + offset + 3]) << 24
    }
    func version(at offset: Int) -> UInt16? {
        if let value = uint16BE(at: offset), (4...16).contains(value) {
            return value
        }
        if let value = uint16LE(at: offset), (4...16).contains(value) {
            return value
        }
        return nil
    }

    let header: (version: UInt16, flagsOffset: Int, prefixed: Bool)
    if let value = version(at: 2), payload.count >= 20 {
        header = (value, 16, true)
    } else if let value = version(at: 0) {
        header = (value, 14, false)
    } else {
        return nil
    }
    guard let flagsBE = uint32BE(at: header.flagsOffset),
          let flagsLE = uint32LE(at: header.flagsOffset) else { return nil }
    return AppleDisplayInfo2SessionMetadata(
        version: header.version,
        screenFlagsBigEndian: flagsBE,
        screenFlagsLittleEndian: flagsLE,
        hasLengthPrefix: header.prefixed)
}

func appleDisplayInfo2RemoteSessionState(
    _ payload: Data
) -> AppleRemoteSessionState? {
    appleDisplayInfo2SessionMetadata(payload)?.state
}

/// Decode the stable display records in Apple's DisplayInfo2 (encoding 1105).
/// The payload includes its two-byte length prefix. Version 5 stores the
/// display count at byte 20 and places each 56-byte record's UInt32 display ID
/// at byte 38. Rectangles are `(minY, minX, maxY, maxX)`; the second rectangle
/// is in framebuffer pixels and is therefore used for rendering and input.
func appleDisplayInfo2Records(_ payload: Data) -> [AppleDisplayInfo] {
    guard payload.count >= 40 else { return [] }
    let start = payload.startIndex
    func uint16(at offset: Int) -> UInt16 {
        UInt16(payload[start + offset]) << 8
            | UInt16(payload[start + offset + 1])
    }
    func uint32(at offset: Int) -> UInt32 {
        UInt32(payload[start + offset]) << 24
            | UInt32(payload[start + offset + 1]) << 16
            | UInt32(payload[start + offset + 2]) << 8
            | UInt32(payload[start + offset + 3])
    }
    let count = Int(uint16(at: 20))
    guard count > 0, count <= 16 else { return [] }

    return (0..<count).compactMap { index in
        // The two-byte payload length precedes a 20-byte desktop header.
        // Each 56-byte display record stores its UInt32 display ID at +16
        // and its absolute pixel bounds at +28.
        let recordOffset = 22 + index * 56
        let boundsOffset = recordOffset + 28
        guard recordOffset + 39 < payload.count else { return nil }
        let id = uint32(at: recordOffset + 16)
        let minY = Int(uint16(at: boundsOffset))
        let minX = Int(uint16(at: boundsOffset + 2))
        let maxY = Int(uint16(at: boundsOffset + 4))
        let maxX = Int(uint16(at: boundsOffset + 6))
        guard maxX > minX, maxY > minY else { return nil }
        let flags = uint32(at: recordOffset + 36)
        return AppleDisplayInfo(
            displayIndex: id,
            originX: Int32(minX),
            originY: Int32(minY),
            width: UInt32(maxX - minX),
            height: UInt32(maxY - minY),
            flags: flags)
    }
}

/// Events emitted by the transport session for consumption by the UI layer.
public enum SessionEvent: Sendable {
    /// The connection state has changed.
    case stateChanged(ConnectionState)

    /// A framebuffer update with rectangle headers and associated pixel data.
    case framebufferUpdate([(FramebufferRect, Data)])

    /// The server rang the bell.
    case bell

    /// The server's clipboard text changed.
    case clipboardText(String)

    /// The handshake completed and the server sent its init message.
    case serverInit(ServerInit)

    /// A protocol error occurred.
    case error(VNCProtocolError)

    /// Apple encryption info pseudo-encoding received.
    case encryptionInfo(AppleEncryptionInfo)

    /// Apple display info pseudo-encoding received.
    case displayInfo(AppleDisplayInfo)

    /// One complete Apple display-layout snapshot. Classic ServerDisplayInfo
    /// records are accumulated for the enclosing framebuffer update first.
    case appleDisplayLayout([AppleDisplayInfo])

    /// Apple Login Window and lock-screen state changed.
    case appleRemoteSessionState(AppleRemoteSessionState)

    /// Standard RFB multi-screen layout received.
    case desktopLayout(ExtendedDesktopSizePayload)

    /// Apple media stream offer pseudo-encoding received.
    case mediaStreamOffer(AppleMediaStreamOffer)

    /// A UDP datagram from Apple's accelerated media stream path.
    case udpDatagram(Data)

    /// An RTP-shaped packet recovered from Apple's TCP media stream fallback.
    case appleMediaRTPPacket(Data)

    /// The Apple media UDP receive socket was opened.
    case appleMediaUDPStarted(localPort: UInt16)

    /// A TCP control stream chunk observed after accepting Apple's media stream.
    case appleMediaControlRecord(encryptedLength: Int, encryptedPrefix: Data, plaintextPrefix: Data?, decryptError: String?)

    /// The connection was closed.
    case disconnected
}

private struct AppleDCTCoverageRegion {
    let minX: Int
    let minY: Int
    let maxX: Int
    let maxY: Int

    func subtracting(_ covered: AppleDCTCoverageRegion) -> [AppleDCTCoverageRegion] {
        let intersectionMinX = max(minX, covered.minX)
        let intersectionMinY = max(minY, covered.minY)
        let intersectionMaxX = min(maxX, covered.maxX)
        let intersectionMaxY = min(maxY, covered.maxY)
        guard intersectionMinX < intersectionMaxX,
              intersectionMinY < intersectionMaxY else { return [self] }

        var remainder: [AppleDCTCoverageRegion] = []
        if minY < intersectionMinY {
            remainder.append(.init(
                minX: minX, minY: minY,
                maxX: maxX, maxY: intersectionMinY))
        }
        if intersectionMaxY < maxY {
            remainder.append(.init(
                minX: minX, minY: intersectionMaxY,
                maxX: maxX, maxY: maxY))
        }
        if minX < intersectionMinX {
            remainder.append(.init(
                minX: minX, minY: intersectionMinY,
                maxX: intersectionMinX, maxY: intersectionMaxY))
        }
        if intersectionMaxX < maxX {
            remainder.append(.init(
                minX: intersectionMaxX, minY: intersectionMinY,
                maxX: maxX, maxY: intersectionMaxY))
        }
        return remainder
    }
}

/// How a client-sized remote display request was handled by the transport.
public enum RemoteDisplayResizeDisposition: Sendable, Equatable {
    /// Apple's negotiated virtual-display command was sent.
    case appleVirtualDisplay
    /// Standard RFB SetDesktopSize was sent after capability announcement.
    case standardSetDesktopSize
    /// The request is retained until the server announces support.
    case waitingForServerSupport
}

private struct PendingRemoteDisplaySize: Sendable, Equatable {
    let pixelWidth: UInt16
    let pixelHeight: UInt16
    let pointWidth: UInt16
    let pointHeight: UInt16
}

/// Resolve the number of Apple media receiver streams without ever asking for
/// a display the server did not offer. Kept outside the actor so the negotiation
/// rule can be verified without a live VNC server.
func selectedAppleMediaDisplayCount(
    offered: Int?,
    requested: Int
) -> Int {
    min(max(1, offered ?? 1), min(2, max(1, requested)))
}

/// A basic key or pointer message eligible for single-write batching.
public enum ClientInputEvent: Sendable, Equatable {
    case key(downFlag: Bool, key: UInt32)
    case pointer(buttonMask: UInt8, x: UInt16, y: UInt16)
}

/// An actor that manages the full lifecycle of a VNC connection.
///
/// `TransportSession` owns an ``RFBConnection`` for network I/O (a direct
/// `TCPConnection` by default, or a host-injected tunnel), a
/// `ConnectionStateMachine` for protocol logic, and drives the RFB handshake
/// by reading from the connection, feeding events to the state machine, and
/// executing the resulting actions.
///
/// Consumers observe the session through the `events` `AsyncStream`.
/// Opens a connected datagram socket to `host:remotePort` from `localPort`.
/// The returned descriptor is owned and closed by the media channel.
public typealias AppleMediaDatagramProvider =
    @Sendable (_ host: String, _ remotePort: UInt16, _ localPort: UInt16) async throws -> Int32

public actor TransportSession {

    // MARK: - Properties

    private let tcp: any RFBConnection
    /// Whether the connection was injected by the host instead of the default
    /// direct TCP path. Apple's High Performance media mode needs UDP
    /// reachability and is refused over a custom transport without a datagram path.
    private let usesCustomTransport: Bool
    /// Host-supplied UDP media path for custom transports.
    private let datagramProvider: AppleMediaDatagramProvider?
    private var stateMachine: ConnectionStateMachine
    /// Address used to establish direct TCP.
    private let dialHost: String
    /// Remote used for Apple UDP media. This normally becomes the concrete TCP
    /// peer. Tailscale names stay as hostnames so iOS Network Extension routing
    /// retains the endpoint identity used to establish the cellular VPN path.
    private var appleMediaRemoteHost: String
    /// When media keeps a Tailscale hostname, constrain its lookup to TCP's
    /// selected family so DNS route setup cannot split TCP and UDP.
    private var appleMediaRemoteAddressFamily: PosixUDPAddressFamily?
    /// Original endpoint identity used for TLS certificate validation, even
    /// when UDP media targets the TCP connection's resolved numeric peer.
    private let tlsIdentityHost: String
    private let port: UInt16
    private let password: String
    private let username: String?
    /// Optional reconnect-time profile choice. A server that declines the
    /// conventional one-picture profile is retried with its native compound
    /// capability without changing the application-wide negotiation policy.
    private let appleMediaTilesPerFrameOverride: UInt64?
    private let certificateValidationHandler: VNCCertificateValidationHandler?
    /// Environment-backed diagnostics and experiment switches are launch-time
    /// configuration. Materializing ProcessInfo.environment copies and bridges
    /// the complete process environment, so never do it on the RTP hot path.
    private nonisolated let runtimeEnvironment: [String: String]
    private nonisolated let appleMediaDecodedRTPDumpPath: String?
    private nonisolated let appleMediaDecodedRTPDumpIncludesTimestamps: Bool
    private nonisolated let appleMediaUDPDatagramDumpPath: String?
    private nonisolated let appleMediaOutgoingRTCPDumpPath: String?
    private let rctlEnabled: Bool
    private let rateControlEnabled: Bool
    private var continuation: AsyncStream<SessionEvent>.Continuation?
    /// Single ordered handoff for all decrypted media RTP. It buffers startup
    /// packets until the decoder sink is ready and drains them atomically, so
    /// the former AsyncStream/direct-path boundary cannot reorder the IRAP burst.
    private var appleMediaPacketHandoff = AppleMediaPacketHandoff()
    /// Ordered notification for a fresh AVC media generation. The app installs
    /// this beside the RTP sink so its decoder reset is queued before any RTP
    /// from the new keys/SSRC can overtake it.
    private var appleMediaGenerationSink: (@Sendable (UInt64, Int) -> Void)?
    private var appleMediaSenderClockSink:
        (@Sendable (AppleMediaSenderClockMapping) -> Void)?
    private var appleRemoteDisplaySizeSink: (@Sendable (UInt16, UInt16) -> Void)?
    private var appleRemoteDisplayResizeSettledSink:
        (@Sendable (Bool) -> Void)?
    private var activeAppleMediaTilesPerFrame = Int(
        AppleMediaVideoMode.negotiatedTilesPerFrame)
    /// Physical or virtual screen geometry announced by Apple's encrypted
    /// DisplayInfo2 control record, in the server's display order.
    private var appleMediaDisplayInfos: [AppleDisplayInfo] = []
    /// Classic Apple display records arrive one rectangle at a time. Retain
    /// them while a zero-sized ServerInit is waiting for a usable union so the
    /// state machine and request loop advance with the same geometry as the
    /// session renderer.
    private var deferredAppleDisplayLayoutByID: [UInt32: AppleDisplayInfo] = [:]
    /// Remains true for classic servers whose initial 0-sized ServerInit makes
    /// complete ServerDisplayInfo batches authoritative for later topology
    /// changes. DesktopSize or requested virtual geometry supersedes it.
    private var usesDeferredAppleDisplayLayout = false
    /// Aggregate surface of the capture graph currently being negotiated.
    /// Initial media setup uses every physical display announced by
    /// DisplayInfo2. Command 29 replaces that graph with the requested virtual
    /// display surface, so its area must replace—not accumulate with—the
    /// physical workload for the following media generation.
    private var appleMediaActiveCaptureLumaSamples = 0
    /// Per-SSRC packet jitter buffer. UDP reordering is repaired here before an
    /// HEVC fragmentation unit reaches the decoder.
    private var appleMediaRTPReorderBuffer = AppleMediaRTPReorderBuffer()
    private var appleMediaRTPReorderFlushTask: Task<Void, Never>?
    private var appleMediaRTPReorderScheduledDeadlineNanos: UInt64?
    private var readTask: Task<Void, Never>?
    private var handshakeComplete = false
    private var isDisconnecting = false
    private var terminalDisconnectHandled = false
    private var framebufferRequestSentNanos: UInt64 = 0

    /// Cumulative standard-path framebuffer traffic (headers + payloads) and
    /// per-encoding content-rectangle breakdown, for `statisticsSnapshot()`.
    private var framebufferBytesReceived: UInt64 = 0
    private var framebufferUpdateCount: UInt64 = 0
    private var framebufferRectCount: UInt64 = 0
    private var framebufferEncodingTraffic: [Encoding: (rectangles: UInt64, bytes: UInt64)] = [:]
    /// Previous `statisticsSnapshot()` sample for the recent-rate window.
    /// Updated at most every quarter second, so two concurrent pollers would
    /// share (and shorten) each other's windows — there is one sheet.
    private var statsPreviousSample: (nanos: UInt64, bytes: UInt64, packets: UInt64, lost: UInt64)?
    /// Server's EncryptionInfo record, retained for `handshakeInfo`.
    private var lastAppleEncryptionInfo: AppleEncryptionInfo?

    /// Updates yielded to the consumer but not yet acknowledged via
    /// finishFramebufferUpdate(). Bounds the undecoded backlog: persistent
    /// Zlib/ZRLE streams mean updates can never be dropped, so backpressure
    /// comes from withholding the next request instead.
    private var unacknowledgedUpdates = 0
    /// Set when an update finished reading while the pipeline was full; the
    /// deferred incremental request goes out on the next acknowledgement.
    private var deferredUpdateRequest = false
    /// Whether this connection negotiated Apple's adaptive DCT encoding.
    private let appleDCTRequested: Bool
    private let appleClassicAutoUpdateRequested: Bool

    /// Whether the server was asked to draw the pointer into the picture. The
    /// client then advertises no cursor pseudo-encoding, so every list this
    /// session builds has to leave them out too, not just the configured one.
    private let serverRendersCursor: Bool
    /// Last DisplayInfo2 session state emitted to the UI layer. Apple can send
    /// this metadata with every layout/control refresh, so suppress identical
    /// events at the transport boundary.
    private var lastAppleRemoteSessionState: AppleRemoteSessionState?
    /// A type-2 quantization update commonly precedes the initial DCT image.
    /// It makes the decoder ready for the type-9 stream; the activation path
    /// follows that subscription with one explicit full-frame request.
    private var awaitingAppleDCTBootstrap: Bool
    private var appleDCTInitialUncoveredRegions: [AppleDCTCoverageRegion] = []
    private var pendingAppleDCTAutoUpdateActivation = false
    private var pendingAppleDCTInitialFullFrameRequest = false
    private var pendingAppleClassicAutoUpdateActivation = false
    private var appleAutoUpdateActive = false
    private var appleAutoUpdateRefreshTask: Task<Void, Never>?
    /// Auto-update delivery still retains exactly one decode credit. Pausing
    /// socket reads at this boundary applies TCP backpressure to the encoder,
    /// which both bounds stale-frame latency and gives the server an honest
    /// bandwidth signal for its DCT quality controller.
    private var framebufferCreditWaiter: CheckedContinuation<Void, Never>?
    private let maxUnacknowledgedUpdates = 1
    private var udpReadTasks: [Task<Void, Never>] = []
    private var udpChannels: [PosixUDPChannel] = []
    private let log = VNCLogger(category: "TransportSession")
    /// The profile requested Apple's accelerated media mode. It becomes active
    /// only after the server proves it is an Apple RFB 3.889 endpoint.
    private let requestedAppleMediaStream: Bool
    private var requestAppleMediaStream = false
    /// Legacy direct-transport switch for disabling adaptive rate control. The
    /// public Full Quality mode never enters the lossy media path at all.
    private var appleMediaNetworkProfile: AppleMediaNetworkProfile = .unknown
    // NOTE (2026-07-12): do NOT scale the initial advertised capacity by
    // framebuffer area. The server ignores the RCTL estimate while sending its
    // bootstrap IRAP, but the reduced value still leaks into
    // keyframe-recovery readiness and the ramp origin — at 5K it slowed and
    // destabilized the bootstrap the scaling was meant to protect.
    private var sentAppleMediaStreamConfiguration = false
    private var sentAppleMediaServerConfiguration = false
    private var sentAppleMediaPostAcceptEncodings = false
    private var sentAppleMediaPostAcceptViewerInfo = false
    private var sentAppleMediaPostAnswerViewerInfo = false
    private var sentAppleMediaReconfigurationRequest = false
    private var sentAppleMediaInitialSetDisplay = false
    private var sentAppleMediaAutoFrameUpdate = false
    private var appleMediaGenerationTracker = AppleMediaNegotiationGenerationTracker()
    private var acceptedAppleMediaStream = false
    private var drainedAppleMediaControlBytes = 0
    private var appleMediaControlBuffer = Data()
    private var appleDecryptedRFBBuffer = Data()

    // MARK: Liveness accounting
    //
    // These exist to answer one question after an unexplained mid-session
    // drop: was the control channel starved, or was it busy right up to the
    // moment it died? In High Performance mode video and rate control are UDP
    // and what stays on TCP is request/response, so an idle remote desktop
    // produces a long control-channel silence that is entirely normal, and is
    // exactly the condition TCP keepalive acts on.

    /// Uptime nanoseconds when the handshake completed.
    private var connectionEstablishedNanos: UInt64 = 0
    /// Uptime nanoseconds when the read loop last received control-channel
    /// bytes. Zero until the first post-handshake read completes.
    private var lastControlChannelByteNanos: UInt64 = 0
    /// Total bytes the read loop has taken off the control channel.
    private var controlChannelBytesReceived: UInt64 = 0
    /// Uptime nanoseconds of the last control-channel write, and the running
    /// byte total. Keepalive only arms once both directions are quiet.
    private var lastControlChannelSendNanos: UInt64 = 0
    private var controlChannelBytesSent: UInt64 = 0
    private var emittedAppleMediaControlDiagnostics = 0
    private var latestAppleMediaControlDiagnostic: String?
    private var appleSessionKey: Data?
    private var appleEncryptedControlChannel: AESCBCChannel?
    private var appleMediaComCryptionChannel: AppleComCryptionChannel?
    private var applePreviousMediaComCryptionChannel: AppleComCryptionChannel?
    private var applePreviousMediaServerPacketID: UInt32 = 0
    private var appleMediaServerPacketID: UInt32 = 0
    private var appleMediaClientPacketID: UInt32 = 0

    /// Password-only VNC authentication proves access without producing the
    /// Apple session key used by the encrypted media control channel. In that
    /// case the server keeps using ordinary plaintext RFB framing after media
    /// acceptance. Apple DH/SRP authentication installs one of these channels
    /// and switches the read loop to length-framed encrypted records.
    private var hasEncryptedAppleMediaControl: Bool {
        appleMediaComCryptionChannel != nil || appleEncryptedControlChannel != nil
    }
    private var pendingAppleMediaRTPStream: PendingAppleMediaRTPStream?
    private var confirmedAppleMediaRTPStream: ConfirmedAppleMediaRTPStream?
    private var appleMediaSRTPKeys: AppleMediaSRTPKeys?
    /// SRTP receive contexts for every server-to-viewer key (audio, video,
    /// video2). Incoming datagrams are matched to a context by SSRC.
    private var appleMediaSRTPContexts: [AppleSRTPContext] = []
    private var appleMediaSRTPContextBySSRC: [UInt32: AppleSRTPContext] = [:]
    private struct AppleMediaFeedbackRoute {
        let receiveContext: AppleSRTPContext
        let sendRTCPContext: AppleSRTCPContext
        let receiveRTCPContext: AppleSRTCPContext
        let localSSRC: UInt32
        let streamIndex: Int
    }

    /// Each negotiated display has independent SRTP/SRTCP keys and its own
    /// receiver SSRC. Remember the receive context that authenticated an
    /// incoming source so feedback uses that display's matching send context.
    private var appleMediaFeedbackRoutes: [AppleMediaFeedbackRoute] = []
    private var appleMediaFeedbackRouteByRemoteSSRC: [UInt32: AppleMediaFeedbackRoute] = [:]
    /// Audio uses its own SRTP keys and sends the native one-second RR+SDES
    /// heartbeat on the audio socket. It must not be mixed into the 20 Hz
    /// screen-video RCTL route.
    private var appleMediaAudioFeedbackRoute: AppleMediaFeedbackRoute?
    private var appleMediaAudioLocalSSRC: UInt32 = 0
    private var appleMediaAudioRemoteSSRC: UInt32?
    private var appleMediaAudioChannel: PosixUDPChannel?
    private var appleMediaAudioRTCPTask: Task<Void, Never>?
    private var appleMediaVideoLocalSSRCs: [UInt32] = []
    /// Audio, video-one, and video-two offer lengths returned by the most
    /// recent native AVC message two. Kept as a live-probe diagnostic so a
    /// rejected second offer is distinguishable from RTP routing failure.
    private var appleMediaAnswerStreamLengths: [Int] = []
    /// Primary receiver SSRC retained as a plaintext/debugging fallback.
    private var appleMediaLocalSSRC: UInt32 = 0
    /// Video SSRCs seen on the media path and the channel each arrived on, so
    /// keyframe requests go back on the right connected socket.
    private var appleMediaVideoSSRCChannels: [UInt32: PosixUDPChannel] = [:]
    /// Native primes each new compound-video generation with one RR +
    /// empty-CNAME SDES report for every dependent tile source. The base source
    /// is covered by RCTL; the other three SSRCs need their own reception
    /// bootstrap before the encoder starts ordinary inter prediction.
    private var appleMediaSentBootstrapVideoReceiverReport = false
    /// Apple carries tile-subframe completion in its RTP media-control
    /// extension rather than the ordinary RTP marker bit.
    private var appleMediaLTRFrameCompletionTracker =
        AppleMediaLTRFrameCompletionTracker()
    private var appleMediaLTRAcknowledgementsSinceDiagnostic = 0
    private var appleLastKeyframeRequestNanos: UInt64 = 0
    /// Most recent native frame-loss report for each source. This lets the
    /// decoder confirm that its gated source corresponds to observed RTP loss.
    private var appleMediaLastFrameLossFeedback: [UInt32: AppleMediaFrameLossFeedback] = [:]
    private var appleMediaMostRecentFrameLossSSRC: UInt32?
    /// RTP-shaped datagrams no configured SRTP key could authenticate (dropped).
    private var appleMediaUnprotectFailures: UInt64 = 0
    /// True once the session is known to be encrypted (ComCryption configured),
    /// i.e. SRTP keys WILL arrive on the control channel.
    private var appleMediaExpectsSRTP = false
    /// Media datagrams that arrived before the SRTP keys did (bounded ring),
    /// replayed in order the moment the contexts are configured.
    private var appleMediaPreKeyDatagrams: [(Data, PosixUDPChannel)] = []
    private var appleKeyframeRequestTask: Task<Void, Never>?
    /// Per-SSRC reception stats for Receiver Reports sent back through the
    /// matching display feedback route.
    private var appleMediaReceptionStats: [UInt32: AppleMediaReceptionStats] = [:]
    /// Sender Report timing is scoped to its remote SSRC. Audio and every
    /// video source have independent RTCP timelines and must never
    /// acknowledge one another's reports.
    private var appleMediaSenderReports:
        [UInt32: AppleMediaSenderReportTiming] = [:]
    /// Low-precision form of the standard RTP timestamp echoed by RCTL.
    /// This is unrelated to the RTP media-control extension and RTCP LSR.
    private var appleMediaLastRTPEchoTimestampQ10: UInt16 = 0
    private var appleRCTLPreviousRTPTimestamp: UInt32?
    private var appleRCTLTotalPacketsReceived: UInt32 = 0
    private var appleRCTLAudioPacketsReceived: UInt32 = 0
    private var appleRCTLTotalBytesReceived: UInt64 = 0
    private var appleRCTLMaximumQueueDelayNanos: UInt64 = 0
    /// RTCP APP "RCTL" rate-control feedback (drives the server's adaptive
    /// encoder bitrate). This profile sends it at approximately 20 Hz; without
    /// it the server encodes at a constant maximum bitrate. The burst-loss
    /// accumulator resets after each report; the receive count is cumulative.
    private var appleRCTLFeedbackTask: Task<Void, Never>?
    private var appleRCTLPacketsInterval: Int = 0
    private var appleRCTLLostInterval: Int = 0
    private var appleRCTLBurstLostInterval: Int = 0
    private var appleRCTLLastDiagnosticNanos: UInt64 = 0
    private var appleMediaIngressPacketsSinceDiagnostic = 0
    private var appleMediaIngressProcessingNanosSinceDiagnostic: UInt64 = 0
    private var appleMediaIngressMaximumBatchSinceDiagnostic = 0
    /// Receiver-side capacity estimator used to populate RCTL. Apple's
    /// feedback-only screen receiver sends RCTL by itself.
    private var appleMediaRateController: AppleMediaRateController?
    private var appleRTCPReportTask: Task<Void, Never>?

    private struct AppleMediaReceptionStats {
        var baseSeq: UInt32 = 0
        var maxSeq: UInt16 = 0
        var cycles: UInt32 = 0
        var received: UInt32 = 0
        var expectedPrior: UInt32 = 0
        /// Loss is not reported to the sender until the reorder window has
        /// expired. Computing RR loss from the newest sequence seen turns an
        /// ordinary out-of-order burst into hundreds of packets of apparent
        /// loss while those packets are still queued locally.
        var confirmedLost: UInt32 = 0
        var confirmedLostPrior: UInt32 = 0
        var recentSequences = BoundedRTPSequenceHistory(capacity: 256)
        var initialized = false
    }
    private var appleMediaDisplayCount: Int = 1
    /// User-selected upper bound shared by Apple display selection, HEVC
    /// receiver negotiation, and virtual display configuration.
    private let requestedDisplayCount: Int
    /// Viewer refresh-rate preference. Apple's media-configuration flags only
    /// advertise the 60-fps receiver capability when this is at least 60;
    /// explicitly configured lower-rate paths leave those bits clear.
    private let requestedFrameRate: Int
    /// Whether the selected mode asks Apple to create client-sized virtual
    /// displays. Physical "All Displays" is one combined receiver; multiple
    /// independent receivers belong to this virtual-display path.
    private let requestsVirtualDisplays: Bool
    /// Message-1 bit advertised by the server. The native viewer only adds the
    /// HDR capability option to its video negotiator when this bit is present.
    private var appleMediaSupportsHDR = false
    private var appleMediaUDPBindings: [AppleMediaUDPBinding] = []
    private let appleMediaControlBufferLimit = 64 * 1024

    /// Memory backstop on the post-decrypt RFB reassembly buffer.
    ///
    /// This is deliberately derived from what the protocol actually permits
    /// rather than picked as a round number, because messages are allowed to
    /// span encrypted records: a partially reassembled message is normal, and
    /// discarding one below its legal maximum corrupts a valid session. The
    /// two largest legal messages are a packed clipboard scrap (capped at
    /// ``AppleClipboardProtocol/maximumClipboardSize``) and a framebuffer
    /// update, whose worst case is full-screen Raw. Two full frames of
    /// headroom covers an update whose rectangles overlap.
    ///
    /// Exceeding this therefore means the drain has genuinely stopped
    /// consuming, and dropping the buffer is the only way to make progress.
    /// The precise wedge detector is the unframeable-encoding branch in
    /// ``drainAppleDecryptedFramebufferUpdate``; this only bounds memory.
    private var appleDecryptedRFBBufferLimit: Int {
        let fullFrameBytes = Int(fbWidth) * Int(fbHeight) * pixelFormat.bytesPerPixel
        return max(
            AppleClipboardProtocol.maximumClipboardSize,
            fullFrameBytes * 2) + 1024 * 1024
    }

    private struct AppleMediaUDPBinding: Equatable {
        let localPort: UInt16?
        let remotePort: UInt16
    }

    private struct AppleMediaRTPHeader {
        let payloadType: UInt8
        let sequenceNumber: UInt16
        let timestamp: UInt32
        let ssrc: UInt32
        let marker: Bool
    }

    private struct PendingAppleMediaRTPStream {
        let payloadType: UInt8
        let ssrc: UInt32
        var lastSequenceNumber: UInt16
        var packets: [Data]
    }

    private struct ConfirmedAppleMediaRTPStream {
        let payloadType: UInt8
        let ssrc: UInt32
        var lastSequenceNumber: UInt16
    }

    private struct AppleMediaSRTPKeys {
        let audioViewerToServer: Data
        let audioServerToViewer: Data
        let videoViewerToServer: Data
        let videoServerToViewer: Data
        let video2ViewerToServer: Data?
        let video2ServerToViewer: Data?
    }

    /// The current framebuffer width (set after ServerInit).
    private var fbWidth: UInt16 = 0
    /// The current framebuffer height (set after ServerInit).
    private var fbHeight: UInt16 = 0
    /// The negotiated pixel format.
    private var pixelFormat: PixelFormat = .bgra8888
    /// Structured command support advertised by an Apple RFB 3.889 server.
    /// This remains nil for regular RFB servers, which therefore use standard
    /// wheel-button input.
    private var appleServerCapabilities: AppleServerCapabilities?
    private var appleClipboardRequestID: UInt32 = 0
    private var appleSharedClipboardEnabled = false
    /// A regular RFB server may receive SetDesktopSize only after it sends an
    /// ExtendedDesktopSize rectangle. Retain that screen identity and any
    /// early client-size request until the announcement arrives.
    private var standardDesktopLayout: ExtendedDesktopSizePayload?
    private var pendingRemoteDisplaySize: PendingRemoteDisplaySize?
    private var lastSentRemoteDisplaySize: PendingRemoteDisplaySize?
    /// Command 29 starts a complete AVC generation. Sending another command
    /// before every expected RTP source from that generation is live makes the
    /// server retire its capture graph mid-startup. Keep only the newest drag
    /// size queued until the current generation proves ready.
    private var appleDisplayReconfigurationGeneration: UInt64?
    /// Stable virtual-display capability envelope. Changing these maxima in
    /// the same command that installs a mode can renegotiate the backing scale;
    /// requests wider than the old 3840 value intermittently
    /// landed on a 1× surface even though the mode explicitly described 2×.
    private let appleVirtualDisplayMaximumPixelWidth: UInt32 = 8_192
    private let appleVirtualDisplayMaximumPixelHeight: UInt32 = 8_192
    /// A staged virtual-display replacement must wait until the initial Apple
    /// media graph emits video. Message 2 only completes control negotiation;
    /// replacing the display before the first RTP packet can retire the
    /// physical capture graph before it has installed a source.
    private var completedInitialAppleMediaNegotiation = false
    /// Catalyst replaces ConnectionView with the live desktop immediately
    /// after the first source arrives. Those two views can report slightly
    /// different viewport sizes a few milliseconds apart. Native Screen
    /// Sharing installs one virtual display; sending both sizes makes the
    /// server build and retire two complete four-band HEVC generations. Give
    /// the live view's request a short opportunity to replace the staged size
    /// before issuing the first display command.
    private static let initialVirtualDisplayCoalescingDelay = Duration.milliseconds(350)
    /// Non-wheel pointer buttons currently held, preserved across fallback
    /// wheel press/release pairs just like the native client.
    private var pointerButtonMask: UInt8 = 0

    /// The async stream of session events for consumers.
    public nonisolated let events: AsyncStream<SessionEvent>

    // MARK: - Init

    /// Create a transport session for the given server.
    ///
    /// - Parameters:
    ///   - host: The server hostname or IP address.
    ///   - port: The server port (typically 5900).
    ///   - password: The VNC password for authentication.
    ///   - username: Optional username for Apple DH/SRP authentication.
    ///   - connection: Optional host-provided transport (an SSH or tssh
    ///     tunnel). When `nil`, a direct `TCPConnection` to `host:port` is
    ///     used. Apple's High Performance (UDP media) mode is refused over a
    ///     custom transport unless `datagramProvider` is set.
    ///   - datagramProvider: Optional host-provided UDP media path.
    public init(
        host: String,
        port: UInt16,
        password: String,
        username: String? = nil,
        preferredPixelFormat: PixelFormat = .bgra8888,
        preferredEncodings: [Encoding]? = nil,
        preferFullQualityVideo: Bool = false,
        targetFrameRate: Int = 60,
        displayCount: Int = 1,
        requestsVirtualDisplays: Bool = false,
        appleMediaTilesPerFrameOverride: UInt64? = nil,
        serverRendersCursor: Bool = false,
        connection: (any RFBConnection)? = nil,
        datagramProvider: AppleMediaDatagramProvider? = nil,
        securityPolicy: VNCSecurityPolicy = .automatic,
        certificateValidationHandler: VNCCertificateValidationHandler? = nil
    ) {
        let environment = ProcessInfo.processInfo.environment
        self.runtimeEnvironment = environment
        self.appleMediaTilesPerFrameOverride = appleMediaTilesPerFrameOverride
        #if DEBUG
        self.appleMediaDecodedRTPDumpPath = VNCDiagnostics.value(
            for: "ROOTSHELL_VNC_DUMP_DECODED_RTP", environment: environment)
        self.appleMediaDecodedRTPDumpIncludesTimestamps =
            VNCDiagnostics.isEnabled(
                "ROOTSHELL_VNC_DUMP_RTP_TIMED", environment: environment)
        self.appleMediaUDPDatagramDumpPath = VNCDiagnostics.value(
            for: "ROOTSHELL_VNC_DUMP_MEDIA_UDP", environment: environment)
        self.appleMediaOutgoingRTCPDumpPath = VNCDiagnostics.value(
            for: "ROOTSHELL_VNC_DUMP_OUTGOING_RTCP", environment: environment)
        #else
        self.appleMediaDecodedRTPDumpPath = nil
        self.appleMediaDecodedRTPDumpIncludesTimestamps = false
        self.appleMediaUDPDatagramDumpPath = nil
        self.appleMediaOutgoingRTCPDumpPath = nil
        #endif
        self.rctlEnabled = environment["ROOTSHELL_VNC_DISABLE_RCTL"] != "1"
        self.rateControlEnabled = !preferFullQualityVideo
            && environment["ROOTSHELL_VNC_DISABLE_RATE_CONTROL"] != "1"
        self.usesCustomTransport = connection != nil
        self.datagramProvider = datagramProvider
        self.tcp = connection ?? TCPConnection(host: host, port: port)
        // Suppress the cursor shape encodings once, here, before anything is
        // derived from the list. `preferredEncodings` is caller-supplied and
        // the default list carries the portable shapes, so a host that builds
        // this transport directly would otherwise still ask the server for a
        // pointer it has just said it wants drawn into the picture.
        let configuredEncodings = Self.suppressingCursorShapes(
            preferredEncodings ?? ConnectionStateMachine.defaultPreferredEncodings,
            when: serverRendersCursor)
        let shouldUseAppleDCT =
            configuredEncodings.contains(.appleMultiVariantScreenshare)
                && !configuredEncodings.contains(.appleH264)
        // 1104 stands in for "Apple classic adaptive profile" here. A
        // server-rendered cursor suppresses that encoding for an unrelated
        // reason, so accept the deliberate omission rather than silently
        // dropping back to plain framebuffer request pacing.
        let shouldUseAppleClassicAutoUpdate =
            !preferFullQualityVideo
                && !configuredEncodings.contains(.appleH264)
                && configuredEncodings.contains(.unknown(1105))
                && (configuredEncodings.contains(.unknown(1104))
                    || serverRendersCursor)
        self.stateMachine = ConnectionStateMachine(
            preferredPixelFormat: preferredPixelFormat,
            preferredEncodings: configuredEncodings,
            securityPolicy: securityPolicy,
            hasUsername: username?.isEmpty == false
        )
        self.dialHost = host
        self.appleMediaRemoteHost = host
        self.appleMediaRemoteAddressFamily = nil
        self.tlsIdentityHost = host
        self.port = port
        self.password = password
        self.username = username
        self.certificateValidationHandler = certificateValidationHandler
        self.requestedDisplayCount = min(2, max(1, displayCount))
        self.requestedFrameRate = max(1, min(120, targetFrameRate))
        self.requestsVirtualDisplays = requestsVirtualDisplays
        self.requestedAppleMediaStream = configuredEncodings.contains(.appleH264)
        self.appleDCTRequested = shouldUseAppleDCT
        self.appleClassicAutoUpdateRequested = shouldUseAppleClassicAutoUpdate
        self.serverRendersCursor = serverRendersCursor
        self.awaitingAppleDCTBootstrap = shouldUseAppleDCT

        var cont: AsyncStream<SessionEvent>.Continuation!
        self.events = AsyncStream<SessionEvent> { continuation in
            cont = continuation
        }
        self.continuation = cont
    }

    // MARK: - Public API

    /// Start the connection and perform the RFB protocol handshake.
    ///
    /// After a successful handshake, a background read loop is started that
    /// processes incoming server messages and emits events.
    public func connect() async throws {
        log.info("Starting connection")

        isDisconnecting = false
        terminalDisconnectHandled = false
        handshakeComplete = false
        framebufferBytesReceived = 0
        framebufferUpdateCount = 0
        framebufferRectCount = 0
        framebufferEncodingTraffic = [:]
        statsPreviousSample = nil
        lastAppleEncryptionInfo = nil
        connectionEstablishedNanos = 0
        lastControlChannelByteNanos = 0
        controlChannelBytesReceived = 0
        lastControlChannelSendNanos = 0
        controlChannelBytesSent = 0
        await tcp.setDisconnectHandler { [weak self] error in
            Task { await self?.handleUnexpectedTCPDisconnect(error) }
        }

        // Transition state machine
        stateMachine.beginConnecting()
        emitState()

        // Establish TCP
        try await tcp.connect()
        if let connectedPeer = await tcp.remoteEndpointHost() {
            appleMediaRemoteHost = Self.selectAppleMediaRemoteHost(
                dialHost: dialHost,
                connectedPeer: connectedPeer)
            appleMediaRemoteAddressFamily = Self.selectAppleMediaRemoteAddressFamily(
                dialHost: dialHost,
                connectedPeer: connectedPeer)
            if appleMediaRemoteHost == connectedPeer {
                log.info("Apple media UDP peer matched to TCP peer \(connectedPeer)")
            } else {
                log.info(
                    "Apple media UDP retaining Tailscale hostname \(dialHost) "
                        + "instead of numeric TCP peer \(connectedPeer)")
            }
        } else if !usesCustomTransport {
            log.warning(
                "TCP transport did not expose its numeric peer; Apple media UDP "
                    + "will resolve \(dialHost) independently")
        }
        appleMediaNetworkProfile = AppleMediaNetworkProfile.detect(
            from: await tcp.pathCharacteristics(),
            remoteHost: dialHost)
        log.info(
            "Apple media bearer=\(appleMediaNetworkProfile.name) "
                + "initialBWE=\(Int(appleMediaNetworkProfile.initialCapacityBps / 1_000))kbps "
                + "screenTransport=local")
        let actions = stateMachine.handle(event: .connected)
        emitState()
        try await executeActions(actions)

        // Perform handshake
        try await performHandshake()
        handshakeComplete = true
        connectionEstablishedNanos = DispatchTime.now().uptimeNanoseconds

        // Start the message read loop
        readTask = Task { [weak self] in
            await self?.readLoop()
        }
    }

    /// Tailscale MagicDNS names deliberately keep the resolver in the UDP
    /// path. Replacing that endpoint identity with TCP's numeric peer leaves
    /// iOS cellular sessions connected but without symmetric high-performance
    /// UDP media. `PosixUDPChannel` resolves the retained name in the exact
    /// address family selected by TCP.
    static func selectAppleMediaRemoteHost(
        dialHost: String,
        connectedPeer: String?
    ) -> String {
        guard let connectedPeer else { return dialHost }
        if AppleMediaNetworkProfile.isTailscaleDNSHost(dialHost) {
            return dialHost
        }
        return connectedPeer
    }

    static func selectAppleMediaRemoteAddressFamily(
        dialHost: String,
        connectedPeer: String?
    ) -> PosixUDPAddressFamily? {
        guard AppleMediaNetworkProfile.isTailscaleDNSHost(dialHost),
              let connectedPeer else {
            return nil
        }
        return PosixUDPAddressFamily(numericHost: connectedPeer)
    }

    /// Send a key event to the server.
    public func sendKeyEvent(downFlag: Bool, key: UInt32) async throws {
        let msg = ClientMessage.keyEvent(downFlag: downFlag, key: key)
        try await sendClientPayload(msg.serialize())
    }

    /// Send a run of key/pointer events as one socket write. The queue-side
    /// coalescing already bounds the run length; batching what remains keeps
    /// a burst (typed text, pointer transitions) to a single send instead of
    /// one awaited write per 6-8 byte message.
    public func sendInputEvents(_ events: [ClientInputEvent]) async throws {
        guard !events.isEmpty else { return }
        var payload = Data()
        for event in events {
            switch event {
            case .key(let downFlag, let key):
                payload.append(ClientMessage.keyEvent(
                    downFlag: downFlag, key: key).serialize())
            case .pointer(let buttonMask, let x, let y):
                let wireButtonMask = Self.pointerButtonMaskForWire(
                    buttonMask,
                    serverVersion: stateMachine.negotiatedVersion)
                pointerButtonMask = buttonMask
                payload.append(ClientMessage.pointerEvent(
                    buttonMask: wireButtonMask, x: x, y: y).serialize())
            }
        }
        try await sendClientPayload(payload)
    }

    /// Send a pointer (mouse/touch) event to the server.
    public func sendPointerEvent(buttonMask: UInt8, x: UInt16, y: UInt16) async throws {
        pointerButtonMask = buttonMask
        let msg = ClientMessage.pointerEvent(
            buttonMask: Self.pointerButtonMaskForWire(
                buttonMask,
                serverVersion: stateMachine.negotiatedVersion),
            x: x,
            y: y)
        try await sendClientPayload(msg.serialize())
    }

    /// Apple RFB 3.889 uses native macOS button ordering: right is bit 1 and
    /// middle is bit 2. Keep the public API in standard RFB semantics and
    /// perform that adjustment only at the Apple wire boundary.
    static func pointerButtonMaskForWire(
        _ buttonMask: UInt8,
        serverVersion: ProtocolVersion?
    ) -> UInt8 {
        guard serverVersion?.isApple == true else { return buttonMask }
        let otherButtons = buttonMask & ~UInt8(0x06)
        let middleAsApple = (buttonMask & 0x02) << 1
        let rightAsApple = (buttonMask & 0x04) >> 1
        return otherButtons | middleAsApple | rightAsApple
    }

    /// Send precise scrolling when the Apple server explicitly advertises the
    /// command. Apple's Standard `0x1` ServerInit omits the structured command
    /// bitmap, but an RFB 3.889 server still implements the same precise-input
    /// extension used by its media connection. Conventional servers retain
    /// ordinary RFB wheel-button events.
    public func sendScrollEvent(_ event: AppleScrollEvent) async throws {
        if supportsApplePreciseInput {
            var payload = ClientMessage.appleScrollEvent(event).serialize()
            if event.momentumPhase == .none, event.scrollPhase != .none {
                payload.append(ClientMessage.appleGestureScrollEvent(
                    AppleGestureScrollEvent(
                        deltaX: Float(event.pointDeltaX),
                        deltaY: Float(event.pointDeltaY),
                        naturalScrolling: true,
                        gesturePhase: event.scrollPhase,
                        x: event.x,
                        y: event.y)
                ).serialize())
            }
            try await sendClientPayload(payload)
            return
        }

        let isAppleServer = stateMachine.negotiatedVersion?.isApple == true
        let wheelMasks = AppleScrollFallback.wheelButtonMasks(
            for: event,
            includeHorizontal: isAppleServer)
        guard !wheelMasks.isEmpty else { return }

        // RFB messages are self-framing on the TCP byte stream. Batch this
        // sample's press/release pairs so accelerated scrolling does not turn
        // into dozens of actor hops and socket writes while retaining every
        // individual wheel transition on the wire.
        var payload = Data(capacity: wheelMasks.count * 12)
        for wheelMask in wheelMasks {
            payload.append(ClientMessage.pointerEvent(
                buttonMask: Self.pointerButtonMaskForWire(
                    pointerButtonMask | wheelMask,
                    serverVersion: stateMachine.negotiatedVersion),
                x: event.x,
                y: event.y).serialize())
            payload.append(ClientMessage.pointerEvent(
                buttonMask: Self.pointerButtonMaskForWire(
                    pointerButtonMask,
                    serverVersion: stateMachine.negotiatedVersion),
                x: event.x,
                y: event.y).serialize())
        }
        try await sendClientPayload(payload)
    }

    /// Send the native begin/end gesture envelope for both Apple Standard and
    /// media connections. Conventional RFB servers have no equivalent message;
    /// their wheel fallback remains unchanged.
    public func sendGestureEvent(_ event: AppleGestureEvent) async throws {
        guard supportsApplePreciseInput else { return }
        try await sendClientPayload(
            ClientMessage.appleGestureEvent(event).serialize())
    }

    private var supportsApplePreciseInput: Bool {
        Self.shouldUseApplePreciseInput(
            serverVersion: stateMachine.negotiatedVersion,
            capabilities: appleServerCapabilities)
    }

    static func shouldUseApplePreciseInput(
        serverVersion: ProtocolVersion?,
        capabilities: AppleServerCapabilities?
    ) -> Bool {
        capabilities?.supportsServerCommand(
            AppleServerCapabilities.preciseScrollCommand) == true
            || serverVersion?.isApple == true
    }

    static func shouldUseApplePackedClipboard(
        capabilities: AppleServerCapabilities?
    ) -> Bool {
        capabilities?.supportsServerCommand(
            AppleClipboardProtocol.packedScrapMessageType) == true
    }

    /// Send clipboard text to the server.
    public func sendClipboardText(_ text: String) async throws {
        let payload: Data
        if Self.shouldUseApplePackedClipboard(
            capabilities: appleServerCapabilities) {
            payload = try AppleClipboardProtocol.packedTextMessage(text)
        } else {
            payload = ClientMessage.clientCutText(text).serialize()
        }
        try await sendClientPayload(payload)
    }

    public var supportsRemoteClipboardRequest: Bool {
        // These legacy pasteboard commands are part of Apple's RFB 3.889
        // dialect in both Standard and High Performance sessions. The newer
        // command bitmap is not authoritative for them and may omit them.
        stateMachine.negotiatedVersion?.isApple == true
    }

    public var supportsRemoteSharedClipboardControl: Bool {
        stateMachine.negotiatedVersion?.isApple == true
    }

    /// Ask a capable Apple Screen Sharing server for its current pasteboard.
    public func requestRemoteClipboard() async throws {
        guard supportsRemoteClipboardRequest else { return }
        appleClipboardRequestID &+= 1
        try await sendClientPayload(AppleClipboardProtocol.requestMessage(
            requestID: appleClipboardRequestID))
    }

    /// Enable or disable Apple's automatic remote-pasteboard notifications.
    public func setSharedClipboardEnabled(_ enabled: Bool) async throws {
        guard supportsRemoteSharedClipboardControl else { return }
        let previousValue = appleSharedClipboardEnabled
        appleSharedClipboardEnabled = enabled
        do {
            try await sendClientPayload(
                AppleClipboardProtocol.autoPasteboardMessage(enabled: enabled))
        } catch {
            appleSharedClipboardEnabled = previousValue
            throw error
        }
    }

    /// Whether the server has advertised that it will accept curtain mode
    /// commands. Apple publishes this in DisplayInfo2 rather than the ServerInit
    /// command bitmap, and withdraws it when the session may not leave the
    /// console, so an absent DisplayInfo2 means "not offered".
    ///
    /// The remote Mac must have **Remote Management** enabled (System Settings ›
    /// General › Sharing). Plain Screen Sharing is not enough: such a server
    /// negotiates RFB 3.889 and sends DisplayInfo2 as usual but leaves the
    /// curtain bit clear forever, which is a correct "no", not a decode bug.
    /// Verified against a real Mac 2026-07-24.
    public var supportsCurtainMode: Bool {
        stateMachine.negotiatedVersion?.isApple == true
            && lastAppleRemoteSessionState?.curtainToggleAvailable == true
    }

    /// Hide or restore the remote session on the Mac's physical display.
    ///
    /// The note is shown on the curtained Mac and is only meaningful when
    /// enabling, matching Apple's client. Success is not acknowledged here: the
    /// server reports the resulting state in its next DisplayInfo2.
    public func setCurtainEnabled(
        _ enabled: Bool,
        message: String
    ) async throws {
        guard supportsCurtainMode else { return }
        try await sendClientPayload(
            AppleCurtainProtocol.sessionVisibilityMessage(
                visible: !enabled,
                message: enabled ? message : ""))
    }

    /// Number of distinct video RTP sources (screen bands) seen this session.
    public var videoSourceCount: Int {
        appleMediaVideoSSRCChannels.count
    }

    /// Diagnostic mapping from authenticated remote video SSRCs to negotiated
    /// receiver numbers (1 or 2).
    public var videoSourceReceiverIndexes: [Int] {
        appleMediaFeedbackRouteByRemoteSSRC.values
            .map(\.streamIndex)
            .sorted()
    }

    public var mediaAnswerStreamLengths: [Int] {
        appleMediaAnswerStreamLengths
    }

    public var mediaControlDiagnostic: String? {
        latestAppleMediaControlDiagnostic
    }

    /// Negotiated handshake facts. Meaningful once the connection reaches
    /// ServerInit; the encryption facet upgrades again when Apple's
    /// EncryptionInfo record and ComCryption channel arrive.
    public var handshakeInfo: TransportHandshakeInfo {
        let contentEncryption: VNCContentEncryption
        if stateMachine.selectedSecurityType == .vencrypt {
            contentEncryption = .tlsX509
        } else if appleEncryptedControlChannel != nil {
            contentEncryption = .appleComCryption(
                cipherMode: lastAppleEncryptionInfo?.cipherMode,
                keyLength: lastAppleEncryptionInfo?.keyLength,
                mediaSRTP: appleMediaExpectsSRTP)
        } else {
            contentEncryption = .none
        }
        return TransportHandshakeInfo(
            serverReportedVersion: stateMachine.serverReportedVersion,
            negotiatedVersion: stateMachine.negotiatedVersion,
            offeredSecurityTypes: stateMachine.offeredSecurityTypes,
            selectedSecurityType: stateMachine.selectedSecurityType,
            contentEncryption: contentEncryption,
            appleServerCapabilities: appleServerCapabilities)
    }

    /// Live traffic statistics. The recent-rate window spans the time since
    /// the previous call (at most one sample per quarter second).
    public func statisticsSnapshot() -> TransportStatistics {
        let mediaPackets = UInt64(appleRCTLTotalPacketsReceived)
        let lostCumulative = appleMediaReceptionStats.values
            .reduce(UInt64(0)) { $0 + UInt64($1.confirmedLost) }
        let totalBytes = appleRCTLTotalBytesReceived &+ framebufferBytesReceived

        let nowNanos = DispatchTime.now().uptimeNanoseconds
        var recentInterval: TimeInterval?
        var recentBitrateKbps: Double?
        var recentPacketLossPercent: Double?
        if let previous = statsPreviousSample {
            let elapsed = Double(nowNanos &- previous.nanos) / 1_000_000_000
            if elapsed >= 0.25 {
                recentInterval = elapsed
                // These counters are not monotonic across a media restart:
                // a renegotiation or a teardown re-anchors them at zero. The
                // deltas were computed with wrapping subtraction, so a reset
                // between two samples produced a near-UInt64.max difference
                // and one capture logged bitrate=89769818264695kbps next to a
                // disconnect. Treat any backwards step as a re-anchor and
                // publish no rate for that window rather than a fictional one.
                let didReset = totalBytes < previous.bytes
                    || mediaPackets < previous.packets
                    || lostCumulative < previous.lost
                if !didReset {
                    recentBitrateKbps =
                        Double(totalBytes - previous.bytes) * 8 / elapsed / 1_000
                    let packetDelta = mediaPackets - previous.packets
                    let lostDelta = lostCumulative - previous.lost
                    let expected = packetDelta + lostDelta
                    if expected > 0 {
                        recentPacketLossPercent = Double(lostDelta) / Double(expected) * 100
                    }
                } else {
                    recentInterval = nil
                }
                statsPreviousSample = (nowNanos, totalBytes, mediaPackets, lostCumulative)
            }
        } else {
            statsPreviousSample = (nowNanos, totalBytes, mediaPackets, lostCumulative)
        }

        let nowSeconds = Double(nowNanos) / 1_000_000_000
        let controller = appleMediaRateController
        let encodingUsage = framebufferEncodingTraffic
            .map { EncodingUsage(encoding: $0.key, rectangles: $0.value.rectangles, bytes: $0.value.bytes) }
            .sorted { $0.bytes > $1.bytes }

        return TransportStatistics(
            isHighPerformanceMode: acceptedAppleMediaStream,
            mediaBytesReceived: appleRCTLTotalBytesReceived,
            mediaPacketsReceived: mediaPackets,
            audioPacketsReceived: UInt64(appleRCTLAudioPacketsReceived),
            packetsLostCumulative: lostCumulative,
            bandwidthEstimateKbps: controller.map { Double($0.bandwidthEstimateBps) / 1_000 },
            throughputKbps: controller.map { $0.throughputBps(now: nowSeconds) / 1_000 },
            queueDelayMilliseconds: controller.map { $0.peakQueueDelaySeconds * 1_000 },
            oneWayRelativeDelayMilliseconds: controller.map { $0.owrdSeconds * 1_000 },
            videoSourceCount: videoSourceCount,
            framebufferBytesReceived: framebufferBytesReceived,
            framebufferUpdateCount: framebufferUpdateCount,
            framebufferRectCount: framebufferRectCount,
            encodingUsage: encodingUsage,
            recentInterval: recentInterval,
            recentBitrateKbps: recentBitrateKbps,
            recentPacketLossPercent: recentPacketLossPercent,
            secondsSinceControlChannelByte:
                Self.secondsSince(lastControlChannelByteNanos, now: nowNanos),
            controlChannelBytesReceived: controlChannelBytesReceived,
            secondsSinceControlChannelSend:
                Self.secondsSince(lastControlChannelSendNanos, now: nowNanos),
            controlChannelBytesSent: controlChannelBytesSent,
            secondsSinceVideoRTPPacket:
                Self.secondsSince(appleMediaLastVideoIngestNanos, now: nowNanos),
            connectionUptime:
                Self.secondsSince(connectionEstablishedNanos, now: nowNanos))
    }

    public var currentAppleMediaTilesPerFrame: Int {
        activeAppleMediaTilesPerFrame
    }

    /// Install the in-session media-generation boundary callback. This is
    /// separate from connection state: a display resize renegotiates AVC while
    /// the RFB session and its input/control channel remain alive.
    public func setAppleMediaGenerationSink(
        _ sink: (@Sendable (UInt64, Int) -> Void)?
    ) {
        appleMediaGenerationSink = sink
    }

    public func setAppleMediaSenderClockSink(
        _ sink: (@Sendable (AppleMediaSenderClockMapping) -> Void)?
    ) {
        appleMediaSenderClockSink = sink
        guard let sink else { return }
        // Sink installation can race the first Sender Report during stream
        // bootstrap. Replay the latest per-source mappings so exact A/V sync
        // does not wait for the server's next reporting interval.
        for timing in appleMediaSenderReports.values {
            sink(AppleMediaSenderClockMapping(
                remoteSSRC: timing.remoteSSRC,
                ntpTimestamp: timing.ntpTimestamp,
                rtpTimestamp: timing.rtpTimestamp))
        }
    }

    public func setAppleRemoteDisplaySizeSink(
        _ sink: (@Sendable (UInt16, UInt16) -> Void)?
    ) {
        appleRemoteDisplaySizeSink = sink
    }

    /// Reports whether every staged Apple virtual-display request has reached
    /// a media generation with all expected RTP sources. A complete decoded
    /// frame is still required by the UI before input is considered safe.
    public func setAppleRemoteDisplayResizeSettledSink(
        _ sink: (@Sendable (Bool) -> Void)?
    ) {
        appleRemoteDisplayResizeSettledSink = sink
        sink?(isAppleRemoteDisplayResizeSettled)
    }

    /// Request a framebuffer update from the server.
    public func requestFramebufferUpdate(incremental: Bool) async throws {
        if appleAutoUpdateActive {
            // A type-3 request competes with the active type-9 subscription and
            // can make the server enqueue a second reference frame. Renewing
            // the subscription requests current geometry without creating a
            // parallel polling loop.
            try await sendAppleAutoFrameUpdate()
            return
        }
        try await sendOneShotFramebufferUpdateRequest(incremental: incremental)
    }

    private func sendOneShotFramebufferUpdateRequest(
        incremental: Bool
    ) async throws {
        let msg = ClientMessage.framebufferUpdateRequest(
            incremental: incremental,
            x: 0, y: 0,
            width: fbWidth,
            height: fbHeight
        )
        try await sendClientPayload(msg.serialize())
        framebufferRequestSentNanos = DispatchTime.now().uptimeNanoseconds
    }

    /// Acknowledge that the consumer finished decoding and presenting one
    /// framebuffer update. Standard RFB encodings carry persistent codec
    /// state, so updates must not be dropped; this credit return is the
    /// backpressure that bounds the undecoded backlog. With a single
    /// standard-RFB credit, the next request is deliberately
    /// deferred until this acknowledgement so stale frames cannot queue.
    public func finishFramebufferUpdate() async throws {
        unacknowledgedUpdates = max(0, unacknowledgedUpdates - 1)
        defer { resumeFramebufferCreditWaiterIfPossible() }

        if pendingAppleDCTAutoUpdateActivation {
            pendingAppleDCTAutoUpdateActivation = false
            let requestInitialFullFrame = pendingAppleDCTInitialFullFrameRequest
            pendingAppleDCTInitialFullFrameRequest = false
            deferredUpdateRequest = false
            appleAutoUpdateActive = true
            do {
                try await sendAppleAutoFrameUpdate()
                // Type 9 is change-gated and may initially emit only dirty
                // regions. Once it is active, a non-incremental type-3 request
                // produces the reference image that initializes untouched
                // framebuffer pixels as well.
                if requestInitialFullFrame {
                    try await sendOneShotFramebufferUpdateRequest(
                        incremental: false)
                }
            } catch {
                appleAutoUpdateActive = false
                pendingAppleDCTAutoUpdateActivation = true
                pendingAppleDCTInitialFullFrameRequest =
                    requestInitialFullFrame
                throw error
            }
            startAppleAutoUpdateRefreshTask()
            log.info("Enabled Apple DCT adaptive auto updates")
            return
        }

        if pendingAppleClassicAutoUpdateActivation {
            pendingAppleClassicAutoUpdateActivation = false
            deferredUpdateRequest = false
            appleAutoUpdateActive = true
            do {
                try await sendAppleAutoFrameUpdate()
            } catch {
                appleAutoUpdateActive = false
                pendingAppleClassicAutoUpdateActivation = true
                throw error
            }
            startAppleAutoUpdateRefreshTask()
            log.info("Enabled Apple classic auto updates")
            return
        }

        if appleAutoUpdateActive {
            deferredUpdateRequest = false
            return
        }

        if appleDCTRequested,
           awaitingAppleDCTBootstrap,
           stateMachine.negotiatedVersion?.isApple == true {
            deferredUpdateRequest = false
            try await requestFramebufferUpdate(incremental: false)
            return
        }

        guard deferredUpdateRequest else { return }
        deferredUpdateRequest = false
        try await requestFramebufferUpdate(incremental: true)
    }

    /// Request one remote display matching the client viewport. Apple servers
    /// use the capability-gated virtual-display command behind Dynamic
    /// Resolution; regular servers use standard SetDesktopSize only after
    /// announcing ExtendedDesktopSize support.
    public func requestRemoteDisplaySize(
        pixelWidth: UInt16,
        pixelHeight: UInt16,
        pointWidth: UInt16,
        pointHeight: UInt16
    ) async throws -> RemoteDisplayResizeDisposition {
        let requested = PendingRemoteDisplaySize(
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            pointWidth: pointWidth,
            pointHeight: pointHeight)
        guard requested != lastSentRemoteDisplaySize else {
            emitAppleRemoteDisplayResizeSettled()
            return appleServerCapabilities?.supportsServerCommand(
                AppleServerCapabilities.displayConfigurationCommand) == true
                ? .appleVirtualDisplay
                : .standardSetDesktopSize
        }

        pendingRemoteDisplaySize = requested
        emitAppleRemoteDisplayResizeSettled()
        if appleServerCapabilities?.supportsServerCommand(
            AppleServerCapabilities.displayConfigurationCommand) == true {
            if requestAppleMediaStream,
               !completedInitialAppleMediaNegotiation {
                log.info(
                    "Deferring staged virtual display \(pixelWidth)x\(pixelHeight) "
                        + "until initial Apple media negotiation completes")
                return .appleVirtualDisplay
            }
            if appleDisplayReconfigurationGeneration != nil {
                log.info(
                    "Coalescing virtual display \(pixelWidth)x\(pixelHeight) "
                        + "while media reconfiguration is in flight")
                return .appleVirtualDisplay
            }
            try await sendAppleVirtualDisplaySize(requested)
            return .appleVirtualDisplay
        }
        if standardDesktopLayout != nil {
            try await sendStandardDesktopSize(requested)
            return .standardSetDesktopSize
        }

        log.info(
            "Retaining client-sized display request \(pixelWidth)x\(pixelHeight) "
                + "until the server announces resize support")
        return .waitingForServerSupport
    }

    /// Disconnect from the server.
    public func disconnect() async {
        log.info("Disconnecting")
        isDisconnecting = true
        terminalDisconnectHandled = true
        readTask?.cancel()
        readTask = nil
        appleAutoUpdateRefreshTask?.cancel()
        appleAutoUpdateRefreshTask = nil
        framebufferCreditWaiter?.resume()
        framebufferCreditWaiter = nil
        appleMediaGenerationSink = nil
        appleMediaSenderClockSink = nil
        appleRemoteDisplaySizeSink = nil
        appleRemoteDisplayResizeSettledSink = nil
        await stopAppleMediaUDP()
        await tcp.close()
        let actions = stateMachine.handle(event: .userRequestedDisconnect)
        emitState()
        for action in actions {
            await executeActionNoThrow(action)
        }
        continuation?.yield(.disconnected)
        continuation?.finish()
    }

    /// Terminate an operational connection when its session consumer can no
    /// longer preserve the ordered RFB stream. Unlike a user disconnect, this
    /// publishes the failure reason and drives the normal reconnect policy.
    package func terminateFromSessionConsumer(
        _ error: VNCProtocolError,
        origin: String
    ) async {
        continuation?.yield(.error(error))
        await terminateUnexpectedConnection(error, origin: origin)
    }

    // MARK: - Handshake

    private func performHandshake() async throws {
        // Step 1: Read server protocol version (12 bytes)
        let versionData = try await readControlChannel(exactly: ProtocolVersion.wireSize)
        let serverVersion = try ProtocolVersion(data: versionData)
        log.info("Server version: \(serverVersion)")

        requestAppleMediaStream = requestedAppleMediaStream && serverVersion.isApple
        if requestAppleMediaStream, usesCustomTransport, datagramProvider == nil {
            throw VNCProtocolError.protocolViolation(
                "High Performance (UDP media) mode cannot run over a custom transport")
        }
        if requestedAppleMediaStream, !serverVersion.isApple {
            stateMachine.preferredEncodings = Self.portableEncodings(
                from: stateMachine.preferredEncodings,
                preferTight: true,
                serverRendersCursor: serverRendersCursor)
            log.info("Conventional RFB server detected; using portable Standard mode")
        } else if !serverVersion.isApple {
            stateMachine.preferredEncodings = Self.portableEncodings(
                from: stateMachine.preferredEncodings,
                preferTight: stateMachine.preferredEncodings.contains(.tight),
                serverRendersCursor: serverRendersCursor)
        }

        let actions1 = stateMachine.handle(event: .receivedProtocolVersion(serverVersion))
        emitState()
        try await executeActions(actions1)

        // Step 2: Read security types
        if serverVersion.isAtLeast(.v3_7) || serverVersion.isApple {
            try await readSecurityTypes37()
        } else {
            try await readSecurityTypes33()
        }

        // Step 3: Read security result
        // Apple auth types (30, 33) have server-specific result handling.
        // For standard RFB 3.7, None alone omits SecurityResult; every
        // authenticating type, including VeNCrypt, must consume it before
        // ServerInit.
        let selectedType = stateMachine.selectedSecurityType
        if selectedType == .macAuthentication {
            // Type 33: MacAuthenticator reads its own auth result internally.
            // The server also sends a second VNC SecurityResult afterward.
            try await readSecurityResult(canReadReason: false)
        } else if selectedType == .apple30 {
            // Type 30 DH: server sends a 4-byte result after the DH exchange
            try await readSecurityResult(canReadReason: false)
        } else {
            let negotiatedVersion = stateMachine.negotiatedVersion ?? .v3_8
            if negotiatedVersion.isAtLeast(.v3_8) {
                try await readSecurityResult(canReadReason: true)
            } else if selectedType != SecurityType.none {
                try await readSecurityResult(canReadReason: false)
            }
        }

        // Step 4: Read ServerInit
        // Note: ClientInit (shared=1 byte) is sent by executeAction(.requestServerInit)
        // which is triggered by the state machine's authenticationSucceeded action.
        // We must NOT send it again here.
        try await readServerInit()
    }

    private func readSecurityTypes37() async throws {
        let countData = try await readControlChannel(exactly: 1)
        let count = Int(countData[countData.startIndex])

        if count == 0 {
            // Server rejected us; read the reason string
            let reason = try await readReasonString()
            throw VNCProtocolError.authenticationFailed(reason)
        }

        let typesData = try await readControlChannel(exactly: count)
        let types = typesData.map { SecurityType(rawValue: $0) }
        log.info("Server offers security types: \(types)")

        let actions = stateMachine.handle(event: .receivedSecurityTypes(types))
        emitState()
        try await executeActions(actions)
        try throwIfHandshakeFailed()

        // If we selected an authenticating type, perform the auth now
        if case .authenticating(let secType) = stateMachine.state {
            try await performAuthentication(secType)
        }
    }

    /// Whether the security type byte for the current auth has already been sent.
    /// For Type 33, the MacAuthenticator combines it with the first message.
    private var securityTypeSentSeparately = true

    private func readSecurityTypes33() async throws {
        let secData = try await readControlChannel(exactly: 4)
        var reader = MessageReader(data: secData)
        let secTypeRaw = try reader.readUInt32()

        if secTypeRaw == 0 {
            let reason = try await readReasonString()
            throw VNCProtocolError.authenticationFailed(reason)
        }

        let secType = SecurityType(rawValue: UInt8(secTypeRaw & 0xFF))
        let actions = stateMachine.handle(
            event: .receivedServerSelectedSecurityType(secType))
        emitState()
        try await executeActions(actions)
        try throwIfHandshakeFailed()

        if case .authenticating(let st) = stateMachine.state {
            try await performAuthentication(st)
        }
    }

    private func throwIfHandshakeFailed() throws {
        guard case .failed(let error) = stateMachine.state else { return }
        throw error
    }

    /// The pseudo-encodings that ask a server to deliver the pointer as a
    /// separate shape instead of drawing it into the picture: the two portable
    /// RFB shapes and macOS's cached CursorImageAlpha records. Advertising any
    /// single one of them is enough to make the server withhold the pointer,
    /// so a server-rendered pointer means suppressing all four.
    private nonisolated static let cursorShapeEncodings: [Encoding] = [
        .cursor, .xCursor, .unknown(1104), .unknown(1100),
    ]

    /// Filters ``cursorShapeEncodings`` out of a list bound for the wire.
    ///
    /// Every list this session advertises passes through here rather than each
    /// site testing the flag on its own: the initial list is caller-supplied
    /// and the later rewrites are built from it, so a per-site condition would
    /// leave a way for one cursor encoding to survive.
    private nonisolated static func suppressingCursorShapes(
        _ encodings: [Encoding],
        when serverRendersCursor: Bool
    ) -> [Encoding] {
        guard serverRendersCursor else { return encodings }
        return encodings.filter { !cursorShapeEncodings.contains($0) }
    }

    private nonisolated static func portableEncodings(
        from configured: [Encoding],
        preferTight: Bool,
        serverRendersCursor: Bool = false
    ) -> [Encoding] {
        var result: [Encoding] = []
        func append(_ encoding: Encoding) {
            if !result.contains(encoding) { result.append(encoding) }
        }

        if preferTight {
            append(.tight)
            append(.lastRect)
        }
        for encoding in configured {
            switch encoding {
            case .tight, .lastRect, .zrle, .zlib, .copyRect, .raw:
                append(encoding)
            default:
                break
            }
        }
        append(.zrle)
        append(.zlib)
        append(.copyRect)
        append(.raw)
        append(.cursor)
        append(.xCursor)
        append(.desktopSize)
        append(.extendedDesktopSize)
        // This list is a rewrite, not an addition, so the cursor fallbacks
        // have to be withheld here as well or a conventional server would
        // start sending shapes the configured list already declined.
        return suppressingCursorShapes(result, when: serverRendersCursor)
    }

    private func performAuthentication(_ securityType: SecurityType) async throws {
        let authenticator: Authenticator

        switch securityType {
        case .vncAuthentication:
            authenticator = VNCAuthenticator(password: password)
        case .apple30:
            authenticator = DHAuthenticator(
                username: username ?? "user",
                password: password
            )
        case .macAuthentication:
            var macAuth = MacAuthenticator(
                username: username ?? "user",
                password: password
            )
            macAuth.securityTypeAlreadySent = securityTypeSentSeparately
            authenticator = macAuth
        case .vencrypt:
            authenticator = VeNCryptAuthenticator(
                host: tlsIdentityHost,
                port: port,
                username: username,
                password: password,
                certificateValidationHandler: certificateValidationHandler
            )
        case .srp:
            authenticator = SRPAuthenticator(
                username: username ?? "user",
                password: password
            )
        case .none:
            // No authentication needed
            return
        default:
            throw VNCProtocolError.authenticationFailed(
                "Unsupported security type for authentication: \(securityType)")
        }

        let authResult = try await authenticator.authenticate(connection: tcp)
        appleSessionKey = authResult.appleSessionKey
        log.info("Authentication completed for \(securityType)")
    }

    private func readSecurityResult(canReadReason: Bool) async throws {
        let resultData = try await readControlChannel(exactly: 4)
        var reader = MessageReader(data: resultData)
        let result = try reader.readUInt32()

        if result == 0 {
            let actions = stateMachine.handle(event: .authenticationSucceeded)
            emitState()
            try await executeActions(actions)
        } else {
            var reason = "Authentication failed (result=\(result))"
            if canReadReason {
                if let reasonStr = try? await readReasonString() {
                    reason = reasonStr
                }
            }
            let actions = stateMachine.handle(event: .authenticationFailed(reason))
            emitState()
            for action in actions {
                await executeActionNoThrow(action)
            }
            throw VNCProtocolError.authenticationFailed(reason)
        }
    }

    private func sendClientInit() async throws {
        // ClientInit mode 0xc1 is required for media connections.
        // Password-only VNC auth receives an additional length-framed session
        // action advertisement after ServerInit; `readServerInit` consumes it
        // before ordinary RFB negotiation.
        let flags: UInt8 = requestAppleMediaStream ? 0xc1 : 0x01
        try await sendControlChannel(Data([flags]))
        log.debug("Sent ClientInit flags=0x\(String(flags, radix: 16))")
    }

    private func readServerInit() async throws {
        // Read the fixed-size portion: width(2) + height(2) + pixelFormat(16) + nameLength(4) = 24
        log.info("Reading ServerInit (\(ServerInit.minWireSize) bytes)...")
        let headerData = try await readControlChannel(exactly: ServerInit.minWireSize)
        log.debug("ServerInit raw header: \(headerData.map { String(format: "%02x", $0) }.joined(separator: " "))")
        var reader = MessageReader(data: headerData)
        let width = try reader.readUInt16()
        let height = try reader.readUInt16()
        let pf = try reader.readPixelFormat()
        let nameLen = try reader.readUInt32()

        guard Int(nameLen) <= Self.maxTextFieldBytes else {
            throw oversizedPayloadError(
                Int(nameLen), limit: Self.maxTextFieldBytes, context: "ServerInit name")
        }
        let serverInitNameField = try await readControlChannel(exactly: Int(nameLen))
        var nameData = serverInitNameField
        if stateMachine.negotiatedVersion?.isApple == true,
           let capabilities = AppleServerCapabilities(
               serverInitNameField: serverInitNameField) {
            appleServerCapabilities = capabilities
            nameData = AppleServerCapabilities.desktopNameData(
                fromServerInitNameField: serverInitNameField)
            let preciseScroll = capabilities.supportsServerCommand(
                AppleServerCapabilities.preciseScrollCommand)
            let dynamicDisplay = capabilities.supportsServerCommand(
                AppleServerCapabilities.displayConfigurationCommand)
            log.info(
                "Apple ServerInit capabilities: flags=0x\(String(capabilities.serverFlags, radix: 16)) "
                    + "preciseScroll=\(preciseScroll) dynamicDisplay=\(dynamicDisplay)")
        } else {
            appleServerCapabilities = nil
        }
        let name = String(data: nameData, encoding: .utf8)
            ?? String(data: nameData, encoding: .isoLatin1)
            ?? ""

        let serverInit = ServerInit(
            framebufferWidth: width,
            framebufferHeight: height,
            pixelFormat: pf,
            name: name
        )

        self.fbWidth = width
        self.fbHeight = height
        usesDeferredAppleDisplayLayout = width == 0 || height == 0
        deferredAppleDisplayLayoutByID.removeAll(keepingCapacity: true)
        resetAppleDCTBootstrapCoverage()
        activeAppleMediaTilesPerFrame = selectedAppleMediaTilesPerFrame(
            pixelWidth: Int(width), pixelHeight: Int(height))
        self.pixelFormat = pf

        log.info("ServerInit: \(width)x\(height) '\(name)'")

        if requestAppleMediaStream,
           stateMachine.selectedSecurityType == .vncAuthentication {
            try await selectPasswordOnlyAppleSession()
        }

        // A client-sized request may have been staged before connecting. Send
        // Apple's virtual-display description as soon as ServerInit confirms
        // support and, critically, before SetEncodings starts media setup. This
        // prevents a constrained remote viewer from first receiving a physical
        // 5K reference frame and only resizing after the video path is already
        // congested.
        if !requestAppleMediaStream,
           let pendingRemoteDisplaySize,
           appleServerCapabilities?.supportsServerCommand(
               AppleServerCapabilities.displayConfigurationCommand) == true {
            try await sendAppleVirtualDisplaySize(pendingRemoteDisplaySize)
        }

        let actions = stateMachine.handle(event: .receivedServerInit(serverInit))
        emitState()
        // High Performance still begins with the ordinary post-ServerInit
        // negotiation. `executeActions` flushes SetPixelFormat/SetEncodings
        // before the authentication-specific media setup. Password-only Pro
        // Mode then waits for encoding-1010 AVC message 1; keyed Apple auth
        // sends its legacy media configuration and request. Skipping the
        // ordinary actions leaves the control stream immediately desynchronized.
        try await executeActions(actions)

        continuation?.yield(.serverInit(serverInit))
    }

    /// ClientInit mode `0xc1` adds a session-selection
    /// exchange when authentication type 2 supplied no Apple session key.
    /// The server advertises the allowed session actions and its machine name,
    /// then expects a 74-byte selection command before SetEncodings/media setup.
    private func selectPasswordOnlyAppleSession() async throws {
        let lengthData = try await readControlChannel(exactly: 2)
        let payloadLength = Int(lengthData[lengthData.startIndex]) << 8
            | Int(lengthData[lengthData.startIndex + 1])
        guard payloadLength >= 10,
              payloadLength <= Self.maxAuxiliaryPayloadBytes else {
            throw oversizedPayloadError(
                payloadLength,
                limit: Self.maxAuxiliaryPayloadBytes,
                context: "Apple session list")
        }
        let payload = try await readControlChannel(exactly: payloadLength)
        let advertisementVersion = UInt16(payload[payload.startIndex]) << 8
            | UInt16(payload[payload.startIndex + 1])
        guard advertisementVersion == 1 else {
            throw VNCProtocolError.protocolViolation(
                "Unsupported Apple session selection version \(advertisementVersion)")
        }
        let actionMask = UInt32(payload[payload.startIndex + 2]) << 24
            | UInt32(payload[payload.startIndex + 3]) << 16
            | UInt32(payload[payload.startIndex + 4]) << 8
            | UInt32(payload[payload.startIndex + 5])
        // Prefer a direct console connection when the server offers it. Some
        // login states offer only action 0, which requests the current console
        // session through the same password-authenticated exchange. Action 2
        // has a different, larger request body and is not valid here.
        let selection: UInt8
        if actionMask & (1 << 1) != 0 {
            selection = 1
        } else if actionMask & (1 << 0) != 0 {
            selection = 0
        } else {
            throw VNCProtocolError.protocolViolation(
                "Apple server offered no supported console action for password-only High Performance")
        }
        let machineNameField = payload.dropFirst(10).prefix(64)
        let machineNameBytes = machineNameField.prefix { $0 != 0 }
        let machineName = String(bytes: machineNameBytes, encoding: .utf8)

        var request = Data(repeating: 0, count: 74)
        request[0] = 0x00
        request[1] = 0x48 // 72-byte payload
        request[2] = 0x00
        request[3] = 0x01 // protocol version
        request[8] = selection // connect to the offered console session
        // This is only the viewer's display label. Keep it deterministic and
        // platform-neutral so the wire request is identical on macOS,
        // Mac Catalyst, iPhone, and iPad.
        let clientName = Data("rootshell".utf8)
        request.replaceSubrange(10..<(10 + clientName.count), with: clientName)
        try await sendControlChannel(request)

        let resultLengthData = try await readControlChannel(exactly: 2)
        let resultLength = Int(resultLengthData[resultLengthData.startIndex]) << 8
            | Int(resultLengthData[resultLengthData.startIndex + 1])
        guard resultLength >= 3,
              resultLength <= Self.maxAuxiliaryPayloadBytes else {
            throw oversizedPayloadError(
                resultLength,
                limit: Self.maxAuxiliaryPayloadBytes,
                context: "Apple session selection result")
        }
        let result = try await readControlChannel(exactly: resultLength)
        let resultVersion = UInt16(result[result.startIndex]) << 8
            | UInt16(result[result.startIndex + 1])
        let status = result[result.startIndex + 2]
        guard resultVersion == 1, status == 0 else {
            throw VNCProtocolError.protocolViolation(
                "Apple session selection failed (version=\(resultVersion), status=\(status))")
        }
        log.info(
            "Selected password-only Apple console session with action \(selection)"
                + "\(machineName.map { " on \($0)" } ?? "")")
    }

    private func readReasonString() async throws -> String {
        let lenData = try await readControlChannel(exactly: 4)
        var reader = MessageReader(data: lenData)
        let len = Int(try reader.readUInt32())
        guard len > 0 else { return "Unknown error" }
        guard len <= Self.maxTextFieldBytes else {
            throw oversizedPayloadError(
                len, limit: Self.maxTextFieldBytes, context: "Server failure reason")
        }
        let textData = try await readControlChannel(exactly: len)
        return String(data: textData, encoding: .utf8) ?? "Unknown error"
    }

    // MARK: - Message read loop

    private func readLoop() async {
        while !Task.isCancelled {
            do {
                if acceptedAppleMediaStream, hasEncryptedAppleMediaControl {
                    try await drainAppleMediaControlRecord()
                    continue
                }

                let typeData = try await readControlChannel(exactly: 1)
                let messageType = typeData[typeData.startIndex]

                switch messageType {
                case 0: // FramebufferUpdate
                    try await handleFramebufferUpdate()
                case 1: // SetColorMapEntries
                    try await handleSetColorMapEntries()
                case 2: // Bell
                    await handleBell()
                case 3: // ServerCutText
                    try await handleServerCutText()
                case AppleClipboardProtocol.packedScrapMessageType:
                    try await handleApplePackedClipboard()
                case 0x14:
                    try await handleAppleAutoPasteboardInfo()
                default:
                    log.warning("Unknown server message type: \(messageType)")
                    throw VNCProtocolError.protocolViolation(
                        "Unknown server message type: \(messageType)")
                }
            } catch is CancellationError {
                break
            } catch let error as VNCProtocolError {
                log.error("Read loop error: \(error.localizedDescription)")
                continuation?.yield(.error(error))
                await terminateUnexpectedConnection(error)
                break
            } catch {
                log.error("Read loop error: \(error.localizedDescription)")
                let protocolError = VNCProtocolError.ioError(error.localizedDescription)
                continuation?.yield(.error(protocolError))
                await terminateUnexpectedConnection(protocolError)
                break
            }
        }
    }

    private func handleUnexpectedTCPDisconnect(_ error: VNCProtocolError) async {
        // During the handshake, the awaited read path owns error propagation
        // back to connect(). After ServerInit, this state callback is the
        // authoritative fallback when iOS resumes a suspended failed socket.
        guard handshakeComplete,
              !isDisconnecting,
              !terminalDisconnectHandled else { return }
        log.error("TCP state reported connection loss: \(error.localizedDescription)")
        continuation?.yield(.error(error))
        await terminateUnexpectedConnection(error, origin: "tcp-state")
    }

    /// Every control-channel read funnels through these two wrappers, so the
    /// liveness counters see real bytes rather than one tick per message.
    /// Counting only message-type bytes would report silence while a large
    /// framebuffer or clipboard payload was still streaming in, which is
    /// exactly the reading the disconnect diagnostics must not get wrong.
    ///
    /// Granularity is one read: a single very large `read(exactly:)` updates
    /// the timestamp only when it completes, because the byte stream does not
    /// expose partial progress.
    private func readControlChannel(exactly count: Int) async throws -> Data {
        let data = try await tcp.read(exactly: count)
        noteControlChannelActivity(byteCount: data.count)
        return data
    }

    private func readControlChannel(upTo maxCount: Int) async throws -> Data {
        let data = try await tcp.read(upTo: maxCount)
        noteControlChannelActivity(byteCount: data.count)
        return data
    }

    /// Every server-declared payload length is bounds-checked (a plain
    /// integer comparison) before it turns into a `read(exactly:)`. A garbage
    /// 32-bit length (from a stream desync or a hostile server) otherwise
    /// makes the connection buffer gigabytes until the Data reallocation dies
    /// with a fatal assertion instead of a throwable error. This factory only
    /// runs in the failure branch, where the teardown path wants an error
    /// naming the offending message.
    private func oversizedPayloadError(
        _ length: Int,
        limit: Int,
        context: String
    ) -> VNCProtocolError {
        .protocolViolation(
            "\(context) declared \(length) payload bytes (limit \(limit)); "
                + "treating as stream desynchronization")
    }

    /// Framebuffer payloads scale with the negotiated screen, so the limit
    /// does too: twice the current full-screen raw size, floored generously
    /// for the pre-ServerInit window and mid-negotiation format changes.
    private var maxFramebufferPayloadBytes: Int {
        max(64 * 1024 * 1024, Int(fbWidth) * Int(fbHeight) * pixelFormat.bytesPerPixel * 2)
    }

    /// Cursors, cursor caches, and cut text are small auxiliary payloads.
    private static let maxAuxiliaryPayloadBytes = 16 * 1024 * 1024

    /// Reason strings and desktop names are short human-readable text.
    private static let maxTextFieldBytes = 64 * 1024

    /// Outbound counterpart. TCP keepalive probes only start once the socket
    /// has been idle in *both* directions, so an inbound-only measure would
    /// call a session "starved" while our own input events were still keeping
    /// the connection warm, and point the diagnosis at the wrong cause.
    private func sendControlChannel(_ data: Data) async throws {
        try await tcp.send(data)
        guard !data.isEmpty else { return }
        lastControlChannelSendNanos = DispatchTime.now().uptimeNanoseconds
        controlChannelBytesSent &+= UInt64(data.count)
    }

    private func noteControlChannelActivity(byteCount: Int) {
        guard byteCount > 0 else { return }
        lastControlChannelByteNanos = DispatchTime.now().uptimeNanoseconds
        controlChannelBytesReceived &+= UInt64(byteCount)
    }

    private static func secondsSince(_ nanos: UInt64, now: UInt64) -> Double? {
        guard nanos != 0, now >= nanos else { return nil }
        return Double(now &- nanos) / 1_000_000_000
    }

    private static func format(_ seconds: Double?) -> String {
        guard let seconds else { return "never" }
        return String(format: "%.1fs", seconds)
    }

    /// One line that explains an unsolicited teardown well enough to act on.
    ///
    /// The three causes that produce the same "Connection interrupted" card are
    /// only distinguishable here: a keepalive verdict on a socket idle in both
    /// directions (long `sinceControlByte` *and* `sinceControlSend`, with
    /// `posix(ETIMEDOUT)`), a peer-initiated close, or a protocol parse failure
    /// (the error names the message or encoding). Media liveness is included
    /// because in High Performance mode a healthy UDP stream alongside a dead
    /// TCP channel is itself the finding.
    private func logDisconnectSummary(_ error: VNCProtocolError, origin: String) async {
        let now = DispatchTime.now().uptimeNanoseconds
        let path = await tcp.pathCharacteristics()
        let interface = path.map { characteristics -> String in
            var description = String(describing: characteristics.interface)
            if characteristics.isExpensive { description += ",expensive" }
            if characteristics.isConstrained { description += ",constrained" }
            return description
        } ?? "unknown"

        log.error(
            "Connection terminated: origin=\(origin) "
                + "error=\(error.localizedDescription) "
                + "connectedFor=\(Self.format(Self.secondsSince(connectionEstablishedNanos, now: now))) "
                + "sinceControlByte=\(Self.format(Self.secondsSince(lastControlChannelByteNanos, now: now))) "
                + "sinceControlSend=\(Self.format(Self.secondsSince(lastControlChannelSendNanos, now: now))) "
                + "controlBytesIn=\(controlChannelBytesReceived) "
                + "controlBytesOut=\(controlChannelBytesSent) "
                + "sinceVideoRTP=\(Self.format(Self.secondsSince(appleMediaLastVideoIngestNanos, now: now))) "
                + "highPerformance=\(acceptedAppleMediaStream) "
                + "videoSources=\(appleMediaVideoSSRCChannels.count) "
                + "interface=\(interface)")
    }

    private func terminateUnexpectedConnection(
        _ error: VNCProtocolError,
        origin: String = "read-loop"
    ) async {
        guard !isDisconnecting, !terminalDisconnectHandled else { return }
        terminalDisconnectHandled = true
        await logDisconnectSummary(error, origin: origin)
        readTask?.cancel()
        appleAutoUpdateRefreshTask?.cancel()
        appleAutoUpdateRefreshTask = nil
        framebufferCreditWaiter?.resume()
        framebufferCreditWaiter = nil
        _ = stateMachine.handle(event: .connectionLost(error))
        emitState()
        await stopAppleMediaUDP()
        await tcp.close()
        continuation?.yield(.disconnected)
        continuation?.finish()
    }

    private func handleFramebufferUpdate() async throws {
        // padding(1) + numberOfRectangles(2) = 3 bytes
        let headerData = try await readControlChannel(exactly: 3)
        let rectCount = UInt16(headerData[headerData.startIndex + 1]) << 8
                      | UInt16(headerData[headerData.startIndex + 2])

        var rectsWithData: [(FramebufferRect, Data)] = []
        rectsWithData.reserveCapacity(Int(rectCount))
        var pendingResize: FramebufferRect?
        var classicAppleDisplayLayout: [AppleDisplayInfo] = []
        var completeAppleDisplayLayout: [AppleDisplayInfo]?

        for _ in 0..<rectCount {
            let rectData = try await readControlChannel(exactly: FramebufferRect.wireSize)
            var reader = MessageReader(data: rectData)
            let rect = try FramebufferRect(reader: &reader)

            // TightVNC-compatible servers may declare 0xffff rectangles and
            // terminate the update with LastRect. It is header-only and must
            // stop parsing immediately or the next server message is mistaken
            // for another rectangle header.
            if rect.encoding == .lastRect {
                break
            }

            let pixelData: Data

            switch rect.encoding {
            case .raw:
                let byteCount = Int(rect.width) * Int(rect.height) * pixelFormat.bytesPerPixel
                guard byteCount <= maxFramebufferPayloadBytes else {
                    throw oversizedPayloadError(
                        byteCount, limit: maxFramebufferPayloadBytes,
                        context: "Raw rect \(rect.width)x\(rect.height)")
                }
                if byteCount > 0 {
                    pixelData = try await readControlChannel(exactly: byteCount)
                } else {
                    pixelData = Data()
                }

            case .zlib, .zrle:
                // Wire format: UInt32 compressedLength, then compressedLength bytes.
                // We read the length prefix + compressed data and forward both to the
                // renderer so it can decompress using its persistent zlib stream.
                let lenData = try await readControlChannel(exactly: 4)
                let compressedLen = Int(lenData[lenData.startIndex]) << 24
                    | Int(lenData[lenData.startIndex + 1]) << 16
                    | Int(lenData[lenData.startIndex + 2]) << 8
                    | Int(lenData[lenData.startIndex + 3])
                guard compressedLen <= maxFramebufferPayloadBytes else {
                    throw oversizedPayloadError(
                        compressedLen, limit: maxFramebufferPayloadBytes,
                        context: "\(rect.encoding.displayName) rect")
                }
                let compressedData = compressedLen > 0
                    ? try await readControlChannel(exactly: compressedLen)
                    : Data()
                // Forward length prefix + compressed bytes so the renderer can parse
                var fullPayload = Data(capacity: 4 + compressedLen)
                fullPayload.append(lenData)
                fullPayload.append(compressedData)
                pixelData = fullPayload

            case .tight:
                pixelData = try await readTightRectanglePayload(rect: rect)

            case .appleMultiVariantScreenshare:
                // Apple Adaptive DCT (1011) is framed as a big-endian UInt32
                // byte count followed by one self-typed codec message.
                let lengthData = try await readControlChannel(exactly: 4)
                let length = Int(lengthData[lengthData.startIndex]) << 24
                    | Int(lengthData[lengthData.startIndex + 1]) << 16
                    | Int(lengthData[lengthData.startIndex + 2]) << 8
                    | Int(lengthData[lengthData.startIndex + 3])
                guard length <= maxFramebufferPayloadBytes else {
                    throw oversizedPayloadError(
                        length, limit: maxFramebufferPayloadBytes,
                        context: "Apple Adaptive DCT record")
                }
                var fullPayload = lengthData
                if length > 0 {
                    fullPayload.append(try await readControlChannel(exactly: length))
                }
                pixelData = fullPayload

            case .copyRect:
                // 4 bytes: srcX(2) + srcY(2)
                pixelData = try await readControlChannel(exactly: 4)

            case .desktopSize:
                pixelData = Data()

            case .extendedDesktopSize:
                // ExtendedDesktopSize is not payload-free: one count byte and
                // three padding bytes are followed by 16 bytes per screen.
                // Consume it in full or the next RFB message begins mid-layout.
                var payload = try await readControlChannel(exactly: ExtendedDesktopSizePayload.headerWireSize)
                let payloadSize = ExtendedDesktopSizePayload.wireSize(screenCount: payload[payload.startIndex])
                let remaining = payloadSize - ExtendedDesktopSizePayload.headerWireSize
                if remaining > 0 {
                    payload.append(try await readControlChannel(exactly: remaining))
                }
                let layout = try ExtendedDesktopSizePayload(data: payload)
                try await noteStandardDesktopSizeSupport(layout)
                continuation?.yield(.desktopLayout(layout))
                pixelData = payload

            case .encryptionInfo:
                // Apple encryption pseudo-encoding: read 8 bytes
                let eiData = try await readControlChannel(exactly: 8)
                var eiReader = MessageReader(data: eiData)
                let info = try AppleEncryptionInfo(reader: &eiReader)
                lastAppleEncryptionInfo = info
                continuation?.yield(.encryptionInfo(info))
                // Feed to state machine for response path (Finding 6)
                let eiActions = stateMachine.handle(event: .receivedEncryptionInfo(info))
                try await executeActions(eiActions)
                pixelData = Data()

            case .serverDisplayInfo:
                // Apple display info pseudo-encoding: read 24 bytes
                let diData = try await readControlChannel(exactly: 24)
                var diReader = MessageReader(data: diData)
                let info = try AppleDisplayInfo(reader: &diReader)
                classicAppleDisplayLayout.append(info)
                // Preserve the original public per-record event contract.
                // The batched layout event below is additive and is used for
                // atomic topology replacement/geometry recovery.
                continuation?.yield(.displayInfo(info))
                try await sendAppleStandardDisplaySelectionIfNeeded(
                    displayID: info.displayIndex)
                // Feed to state machine (informational, no response)
                let _ = stateMachine.handle(event: .receivedAppleDisplayInfo(info))
                pixelData = Data()

            case .mediaStreamOffer:
                // Apple RFBMediaStreamMessage1: current macOS payload is 36 bytes.
                let offerData = try await readControlChannel(exactly: AppleMediaStreamOffer.wirePayloadSize)
                try await handleAppleMediaStreamOfferPayload(offerData)
                pixelData = offerData

            case .appleH264:
                // In password-only capability mode macOS carries the initial
                // media-stream message 1 inside encoding 1010, prefixed by a
                // UInt16 payload size. It is not a payload-free marker.
                var payload = try await readControlChannel(exactly: 2)
                let length = Int(payload[payload.startIndex]) << 8
                    | Int(payload[payload.startIndex + 1])
                guard length <= Self.maxAuxiliaryPayloadBytes else {
                    throw oversizedPayloadError(
                        length,
                        limit: Self.maxAuxiliaryPayloadBytes,
                        context: "Apple HEVC control rectangle")
                }
                if length > 0 {
                    payload.append(try await readControlChannel(exactly: length))
                }
                let offerData = Data(payload.dropFirst(2))
                var avcPayload = Data([0x00, 0x00, 0x03, 0xf2])
                avcPayload.append(payload)
                let handledAVCMessage = try await
                    handleAppleAVCServerMediaMessageIfPresent(avcPayload)
                try await sendAppleMediaPostAnswerViewerInfoIfNeeded(for: avcPayload)
                if !handledAVCMessage,
                   offerData.count == AppleMediaStreamOffer.wirePayloadSize,
                   findAppleAVCMediaMessage(in: avcPayload)?.messageType != 2 {
                    try await handleAppleMediaStreamOfferPayload(offerData)
                }
                pixelData = payload

            case .cursor:
                // Cursor pseudo-encoding: pixel data + bitmask
                let pixelBytes = Int(rect.width) * Int(rect.height) * pixelFormat.bytesPerPixel
                let maskBytes = Int((Int(rect.width) + 7) / 8) * Int(rect.height)
                let totalBytes = pixelBytes + maskBytes
                guard totalBytes <= Self.maxAuxiliaryPayloadBytes else {
                    throw oversizedPayloadError(
                        totalBytes, limit: Self.maxAuxiliaryPayloadBytes,
                        context: "Cursor rect \(rect.width)x\(rect.height)")
                }
                if totalBytes > 0 {
                    pixelData = try await readControlChannel(exactly: totalBytes)
                } else {
                    pixelData = Data()
                }

            case .xCursor:
                // TightVNC XCursor: foreground/background RGB triplets,
                // followed by one source bitmap and one visibility bitmap.
                let rowBytes = (Int(rect.width) + 7) / 8
                let bitmapBytes = rowBytes * Int(rect.height)
                let totalBytes = bitmapBytes == 0 ? 0 : 6 + bitmapBytes * 2
                guard totalBytes <= Self.maxAuxiliaryPayloadBytes else {
                    throw oversizedPayloadError(
                        totalBytes, limit: Self.maxAuxiliaryPayloadBytes,
                        context: "XCursor rect \(rect.width)x\(rect.height)")
                }
                if totalBytes > 0 {
                    pixelData = try await readControlChannel(exactly: totalBytes)
                } else {
                    pixelData = Data()
                }

            case .unknown(let value) where value == 1100:
                // Apple cursor-position notification; coordinates are carried
                // by the rectangle header.
                pixelData = Data()

            case .unknown(let value) where value == 1101:
                // Legacy Apple display layout: 10-byte header followed by
                // 28 bytes per display. The count is the final UInt16.
                var payload = try await readControlChannel(exactly: 10)
                let count = Int(payload[payload.startIndex + 8]) << 8
                    | Int(payload[payload.startIndex + 9])
                if count > 0 {
                    payload.append(try await readControlChannel(exactly: count * 28))
                }
                pixelData = payload

            case .unknown(let value) where value == 1104:
                // Apple cursor cache record: id + payload byte count.
                var payload = try await readControlChannel(exactly: 8)
                let length = Int(payload[payload.startIndex + 4]) << 24
                    | Int(payload[payload.startIndex + 5]) << 16
                    | Int(payload[payload.startIndex + 6]) << 8
                    | Int(payload[payload.startIndex + 7])
                guard length <= Self.maxAuxiliaryPayloadBytes else {
                    throw oversizedPayloadError(
                        length, limit: Self.maxAuxiliaryPayloadBytes,
                        context: "Apple cursor cache record")
                }
                if length > 0 {
                    payload.append(try await readControlChannel(exactly: length))
                }
                pixelData = payload

            case .unknown(let value) where value == 1105:
                // Apple DisplayInfo2: a UInt16 byte count followed by the
                // complete display-layout structure.
                var payload = try await readControlChannel(exactly: 2)
                let length = Int(payload[payload.startIndex]) << 8
                    | Int(payload[payload.startIndex + 1])
                if length > 0 {
                    payload.append(try await readControlChannel(exactly: length))
                }
                if acceptedAppleMediaStream {
                    try await handleAppleMediaDisplayInfo2(payload)
                } else {
                    emitAppleRemoteSessionState(
                        from: payload,
                        source: "standard RFB 1105")
                    let displayInfos = appleDisplayInfo2Records(payload)
                    completeAppleDisplayLayout = displayInfos
                    emitAppleDisplayInfoCompatibilityEvents(displayInfos)
                    if let firstDisplay = displayInfos.first {
                        try await sendAppleStandardDisplaySelectionIfNeeded(
                            displayID: firstDisplay.displayIndex,
                            announcedDisplayCount: displayInfos.count)
                    }
                }
                pixelData = payload

            case .unknown(let value)
                where value == 1107 || value == 1109 || value == 1110:
                // Password-only VNC authentication has no Apple session key,
                // so High Performance control rectangles continue on the
                // ordinary RFB stream instead of moving into encrypted record
                // framing. These records use the same UInt16 length prefix as
                // their decrypted counterparts.
                var payload = try await readControlChannel(exactly: 2)
                let length = Int(payload[payload.startIndex]) << 8
                    | Int(payload[payload.startIndex + 1])
                guard length <= Self.maxAuxiliaryPayloadBytes else {
                    throw oversizedPayloadError(
                        length, limit: Self.maxAuxiliaryPayloadBytes,
                        context: "Apple media control (value)")
                }
                if length > 0 {
                    payload.append(try await readControlChannel(exactly: length))
                }
                if value == 1109 {
                    try await sendAppleMediaInitialSetDisplayIfNeeded()
                    try await sendAppleMediaAutoFrameUpdateIfNeeded()
                } else if value == 1110 {
                    try await sendAppleMediaInitialSetDisplayIfNeeded()
                    try await sendAppleMediaAutoFrameUpdateIfNeeded()
                    try await sendAppleMediaServerConfigurationIfNeeded()
                }
                pixelData = payload

            default:
                // A rectangle whose encoding carries pixel content also
                // carries payload bytes on the wire. Skipping it consumes
                // zero of them, so the very next byte read as a message type
                // is really payload: the stream is desynchronized from here
                // on and the failure surfaces one message later as a
                // baffling "unknown server message type". Fail here instead,
                // where the log can name the encoding that did it.
                if rect.encoding.isUnframeableContent {
                    throw VNCProtocolError.protocolViolation(
                        "Unsupported framebuffer encoding "
                            + "\(rect.encoding.rawValue) (\(rect.encoding.displayName)) "
                            + "for rect \(rect.width)x\(rect.height); "
                            + "its payload cannot be framed without desynchronizing the stream")
                }
                // What is left is pseudo-encodings, Apple metadata records,
                // and `.appleH264`'s marker rectangle, none of which carry a
                // payload the parser must consume. Skipping an unrecognized
                // one is the pre-existing best guess.
                log.warning("Unhandled encoding \(rect.encoding.rawValue) for rect \(rect.width)x\(rect.height)")
                pixelData = Data()
            }

            rectsWithData.append((rect, pixelData))
            if rect.isSuccessfulDesktopResize {
                pendingResize = rect
            }
        }

        if let resize = pendingResize {
            usesDeferredAppleDisplayLayout = false
            try await acceptFramebufferResize(width: resize.width, height: resize.height)
        }

        if let completeAppleDisplayLayout,
           !completeAppleDisplayLayout.isEmpty {
            // DesktopSize wins geometry when both occur in one update, but
            // consumers still need the Apple layout metadata (including the
            // signal that this is an Apple server).
            if pendingResize == nil {
                try await commitDeferredAppleDisplayLayout(
                    completeAppleDisplayLayout,
                    replacingLayout: true)
            }
            continuation?.yield(.appleDisplayLayout(completeAppleDisplayLayout))
        } else if !classicAppleDisplayLayout.isEmpty {
            // ServerDisplayInfo records in one framebuffer update are one
            // complete classic layout snapshot. Commit once after parsing so
            // control writes cannot interleave with the update payload.
            if pendingResize == nil {
                try await commitDeferredAppleDisplayLayout(
                    classicAppleDisplayLayout,
                    replacingLayout: true)
            }
            continuation?.yield(.appleDisplayLayout(classicAppleDisplayLayout))
        }

        let receivedPortableFullFrame = rectsWithData.contains(where: { rect, _ in
               (rect.encoding == .tight || rect.encoding == .zlib
                    || rect.encoding == .zrle || rect.encoding == .raw)
                   && rect.x == 0 && rect.y == 0
                   && rect.width >= fbWidth && rect.height >= fbHeight
           })
        if appleClassicAutoUpdateRequested,
                  !appleDCTRequested,
                  stateMachine.negotiatedVersion?.isApple == true,
                  !appleAutoUpdateActive,
                  receivedPortableFullFrame {
            pendingAppleClassicAutoUpdateActivation = true
            log.debug("Received initial portable framebuffer for adaptive updates")
        }

        recordAppleDCTBootstrapCoverage(from: rectsWithData)

        // Statistics: message header (type + padding + count) plus one wire
        // header per rectangle; payloads retain their wire framing, so this
        // tracks bytes on the socket closely.
        framebufferUpdateCount &+= 1
        framebufferRectCount &+= UInt64(rectsWithData.count)
        framebufferBytesReceived &+= UInt64(4 + rectsWithData.count * FramebufferRect.wireSize)
        for (rect, payload) in rectsWithData {
            framebufferBytesReceived &+= UInt64(payload.count)
            if rect.encoding.isFramebufferContent {
                var traffic = framebufferEncodingTraffic[rect.encoding] ?? (0, 0)
                traffic.rectangles &+= 1
                traffic.bytes &+= UInt64(FramebufferRect.wireSize + payload.count)
                framebufferEncodingTraffic[rect.encoding] = traffic
            }
        }

        let now = DispatchTime.now().uptimeNanoseconds
        if framebufferRequestSentNanos != 0 {
            let milliseconds = (now &- framebufferRequestSentNanos) / 1_000_000
            if milliseconds >= 100 {
                let payloadBytes = rectsWithData.reduce(0) { $0 + $1.1.count }
                let encodings = rectsWithData.map { rect, payload in
                    var description = String(describing: rect.encoding)
                    if rect.encoding == .appleMultiVariantScreenshare,
                       payload.count >= 5 {
                        description += "(type=\(payload[payload.startIndex + 4]) "
                            + "\(rect.x),\(rect.y) \(rect.width)x\(rect.height))"
                    }
                    return description
                }.joined(separator: ",")
                log.info(
                    "Framebuffer server/network wait=\(milliseconds)ms "
                        + "rects=\(rectsWithData.count) payload=\(payloadBytes)B "
                        + "encodings=\(encodings)")
            }
            framebufferRequestSentNanos = 0
        }

        continuation?.yield(.framebufferUpdate(rectsWithData))

        // Pipeline the next incremental request the moment this update is
        // fully off the wire, so the server can produce the next update while
        // this one crosses the event stream and decodes. Apple keeps this RFB
        // request loop alive after HEVC starts: pixels move to the media path,
        // while local hardware-cursor shapes remain cursor pseudo-rectangles
        // on the encrypted control channel.
        let rects = rectsWithData.map(\.0)
        unacknowledgedUpdates += 1
        let actions = stateMachine.handle(event: .receivedFramebufferUpdate(rects))
        for action in actions {
            if case .sendFramebufferUpdateRequest = action,
               unacknowledgedUpdates >= maxUnacknowledgedUpdates {
                deferredUpdateRequest = true
                continue
            }
            try await executeAction(action)
        }

        if appleAutoUpdateActive
            || pendingAppleDCTAutoUpdateActivation
            || pendingAppleClassicAutoUpdateActivation {
            await waitForFramebufferCreditIfNeeded()
        }
    }

    /// Consume one complete Tight rectangle while retaining its compact wire
    /// framing for the renderer. A wrong byte count here desynchronizes the
    /// entire RFB stream, so derive the basic-filter payload size exactly as
    /// specified instead of scanning for the next message boundary.
    private func readTightRectanglePayload(rect: FramebufferRect) async throws -> Data {
        let controlData = try await readControlChannel(exactly: 1)
        let control = controlData[controlData.startIndex]
        let compression = control >> 4
        var payload = controlData
        let tightPixelSize = pixelFormat.bitsPerPixel == 32
            && pixelFormat.depth == 24
            && pixelFormat.trueColor
            && pixelFormat.redMax == 255
            && pixelFormat.greenMax == 255
            && pixelFormat.blueMax == 255
            ? 3 : pixelFormat.bytesPerPixel

        switch compression {
        case 8: // Fill
            payload.append(try await readControlChannel(exactly: tightPixelSize))

        case 9: // JPEG
            let (lengthBytes, length) = try await readTightCompactLength()
            payload.append(lengthBytes)
            if length > 0 { payload.append(try await readControlChannel(exactly: length)) }

        case 0...7: // Basic compression, optionally with an explicit filter.
            var filter: UInt8 = 0
            if compression & 0x04 != 0 {
                let filterData = try await readControlChannel(exactly: 1)
                filter = filterData[filterData.startIndex]
                payload.append(filterData)
            }

            let width = Int(rect.width)
            let height = Int(rect.height)
            let uncompressedSize: Int
            if filter == 1 {
                let paletteSizeData = try await readControlChannel(exactly: 1)
                payload.append(paletteSizeData)
                let paletteSize = Int(paletteSizeData[paletteSizeData.startIndex]) + 1
                payload.append(try await readControlChannel(exactly: paletteSize * tightPixelSize))
                uncompressedSize = paletteSize == 2
                    ? ((width + 7) / 8) * height
                    : width * height
            } else {
                uncompressedSize = width * height * tightPixelSize
            }

            if uncompressedSize < 12 {
                if uncompressedSize > 0 {
                    payload.append(try await readControlChannel(exactly: uncompressedSize))
                }
            } else {
                let (lengthBytes, length) = try await readTightCompactLength()
                payload.append(lengthBytes)
                if length > 0 { payload.append(try await readControlChannel(exactly: length)) }
            }

        default:
            throw VNCProtocolError.protocolViolation(
                "Unsupported Tight compression control \(compression)")
        }
        return payload
    }

    private func readTightCompactLength() async throws -> (Data, Int) {
        var bytes = Data()
        var value = 0
        for index in 0..<3 {
            let byteData = try await readControlChannel(exactly: 1)
            let byte = byteData[byteData.startIndex]
            bytes.append(byte)
            value |= Int(byte & 0x7F) << (7 * index)
            if byte & 0x80 == 0 { return (bytes, value) }
        }
        return (bytes, value)
    }

    private func handleSetColorMapEntries() async throws {
        // padding(1) + firstColor(2) + numberOfColors(2) = 5 bytes
        let headerData = try await readControlChannel(exactly: 5)
        let numColors = UInt16(headerData[headerData.startIndex + 3]) << 8
                      | UInt16(headerData[headerData.startIndex + 4])
        // Each color is 6 bytes (r,g,b as UInt16)
        let _ = try await readControlChannel(exactly: Int(numColors) * 6)
        // Color map entries are passed through but not currently surfaced as session events
    }

    private func handleBell() async {
        let actions = stateMachine.handle(event: .receivedBell)
        for action in actions { await executeActionNoThrow(action) }
    }

    private func handleServerCutText() async throws {
        // padding(3) + length(4) = 7 bytes
        let headerData = try await readControlChannel(exactly: 7)
        let length = UInt32(headerData[headerData.startIndex + 3]) << 24
                   | UInt32(headerData[headerData.startIndex + 4]) << 16
                   | UInt32(headerData[headerData.startIndex + 5]) << 8
                   | UInt32(headerData[headerData.startIndex + 6])

        guard Int(length) <= Self.maxAuxiliaryPayloadBytes else {
            throw oversizedPayloadError(
                Int(length), limit: Self.maxAuxiliaryPayloadBytes,
                context: "ServerCutText")
        }
        let textData = try await readControlChannel(exactly: Int(length))
        let text = String(data: textData, encoding: .utf8)
            ?? String(data: textData, encoding: .isoLatin1)
            ?? ""

        let actions = stateMachine.handle(event: .receivedServerCutText(text))
        for action in actions { await executeActionNoThrow(action) }
    }

    private func handleApplePackedClipboard() async throws {
        // readLoop already consumed the type byte.
        let header = try await readControlChannel(
            exactly: AppleClipboardProtocol.packedScrapHeaderSize - 1)
        let uncompressedLength = Int(
            AppleClipboardProtocol.uint32BE(
                header, at: header.startIndex + 7) ?? 0)
        let compressedLength = Int(
            AppleClipboardProtocol.uint32BE(
                header, at: header.startIndex + 11) ?? 0)
        guard uncompressedLength <= AppleClipboardProtocol.maximumClipboardSize,
              compressedLength <= AppleClipboardProtocol.maximumClipboardSize else {
            throw VNCProtocolError.protocolViolation(
                "Apple clipboard size is out of range")
        }

        let compressed = try await readControlChannel(exactly: compressedLength)
        decodeApplePackedClipboard(
            compressed,
            uncompressedLength: uncompressedLength)
    }

    private func handleAppleAutoPasteboardInfo() async throws {
        // Apple sends this fixed eight-byte notification after command 21 has
        // enabled automatic pasteboard updates. It announces a change; the
        // viewer must still issue command 11 to fetch the packed scrap.
        _ = try await readControlChannel(exactly: 7)
        guard appleSharedClipboardEnabled else { return }
        do {
            try await requestRemoteClipboard()
        } catch {
            // Clipboard synchronization is auxiliary. A failed automatic
            // request must not terminate an otherwise healthy display session.
            log.warning(
                "Unable to request changed Apple clipboard: "
                    + error.localizedDescription)
        }
    }

    /// Packed scrap contents are optional auxiliary data. Once their framing
    /// has been consumed, a malformed or unsupported flavor must not terminate
    /// the screen-sharing connection.
    private func decodeApplePackedClipboard(
        _ compressed: Data,
        uncompressedLength: Int
    ) {
        do {
            if let text = try AppleClipboardProtocol.unpackText(
                compressed: compressed,
                uncompressedSize: uncompressedLength) {
                continuation?.yield(.clipboardText(text))
            } else {
                log.debug("Apple clipboard contained no supported text flavor")
            }
        } catch {
            log.warning(
                "Ignoring unsupported Apple clipboard payload: "
                    + error.localizedDescription)
        }
    }

    // MARK: - Action execution

    /// Execute a list of ConnectionActions. Some are async (sending data), some are sync.
    ///
    /// Consecutive plain client messages (the post-ServerInit burst of
    /// SetPixelFormat + SetEncodings + first update request) are coalesced
    /// into one socket write so the server receives them in a single
    /// segment — the first framebuffer arrives one RTT sooner.
    private func executeActions(_ actions: [ConnectionAction]) async throws {
        var pending = Data()

        for action in actions {
            switch action {
            case .sendSetPixelFormat(let pf):
                pending.append(ClientMessage.setPixelFormat(pf).serialize())
                self.pixelFormat = pf
                log.debug("Queued SetPixelFormat")

            case .sendSetEncodings(let encodings):
                if requestAppleMediaStream && !sentAppleMediaStreamConfiguration {
                    if requestedDisplayCount > 1,
                       !sentAppleMediaInitialSetDisplay {
                        // Display selection must precede media message one.
                        // Otherwise only the first video receiver is created,
                        // and the desktops are combined into that receiver
                        // when the late SetDisplay arrives.
                        pending.append(appleSetDisplayMessage(
                            isGlobal: true,
                            displayID: 0))
                        sentAppleMediaInitialSetDisplay = true
                    }
                    pending.append(ClientMessage.setEncodings(encodings).serialize())
                    log.debug("Queued SetEncodings (\(encodings.count) encodings)")
                    if !pending.isEmpty {
                        try await sendClientPayload(pending)
                        pending = Data()
                    }
                    try await sendAppleMediaStreamSetupIfNeeded()
                } else {
                    pending.append(ClientMessage.setEncodings(encodings).serialize())
                    log.debug("Queued SetEncodings (\(encodings.count) encodings)")
                    if requestedDisplayCount > 1,
                       (appleServerCapabilities != nil
                           || stateMachine.negotiatedVersion?.isApple == true),
                       !sentAppleMediaInitialSetDisplay {
                    // Apple's Standard viewer sends SetDisplay in the initial
                    // client burst. SetDesktopSize changes monitor topology;
                    // it does not select which existing monitor(s) the server
                    // should encode. Byte 1 is the server's
                    // combineAllDisplaysFlag, so one display must explicitly
                    // clear it or the server keeps returning the composite.
                    pending.append(appleSetDisplayMessage(
                        isGlobal: requestedDisplayCount > 1,
                        displayID: 0))
                    sentAppleMediaInitialSetDisplay = true
                    }
                }

            case .sendFramebufferUpdateRequest(let incremental, let width, let height):
                pending.append(ClientMessage.framebufferUpdateRequest(
                    incremental: incremental,
                    x: 0, y: 0,
                    width: width,
                    height: height
                ).serialize())
                framebufferRequestSentNanos = DispatchTime.now().uptimeNanoseconds

            default:
                if !pending.isEmpty {
                    try await sendClientPayload(pending)
                    pending = Data()
                }
                try await executeAction(action)
            }
        }
        if !pending.isEmpty {
            try await sendClientPayload(pending)
        }
    }

    private func executeAction(_ action: ConnectionAction) async throws {
        switch action {
        case .sendProtocolVersion(let version):
            try await sendControlChannel(version.wireBytes())
            log.debug("Sent protocol version: \(version)")

        case .sendSecurityType(let type):
            if type == .macAuthentication {
                // Type 33: Don't send the type byte separately.
                // MacAuthenticator will combine it with the RSA1 request
                // in a single TCP write (macOS server requires this).
                securityTypeSentSeparately = false
                log.debug("Security type \(type) will be sent with first auth message")
            } else {
                try await sendControlChannel(Data([type.rawValue]))
                securityTypeSentSeparately = true
                log.debug("Sent security type: \(type)")
            }

        case .performAuthentication(let secType, _):
            try await performAuthentication(secType)

        case .sendAuthResponse(let data):
            try await sendControlChannel(data)

        case .requestServerInit:
            try await sendClientInit()

        case .sendSetPixelFormat(let pf):
            let msg = ClientMessage.setPixelFormat(pf)
            try await sendControlChannel(msg.serialize())
            self.pixelFormat = pf
            log.debug("Sent SetPixelFormat")

        case .sendSetEncodings(let encodings):
            let msg = ClientMessage.setEncodings(encodings)
            try await sendControlChannel(msg.serialize())
            log.debug("Sent SetEncodings (\(encodings.count) encodings)")
            if requestAppleMediaStream && !sentAppleMediaStreamConfiguration {
                try await sendAppleMediaStreamSetupIfNeeded()
            }

        case .sendFramebufferUpdateRequest(let incremental, let width, let height):
            let msg = ClientMessage.framebufferUpdateRequest(
                incremental: incremental,
                x: 0, y: 0,
                width: width,
                height: height
            )
            try await sendClientPayload(msg.serialize())
            framebufferRequestSentNanos = DispatchTime.now().uptimeNanoseconds

        case .updateFramebuffer:
            // Handled via the event stream, no additional action needed
            break

        case .notifyBell:
            continuation?.yield(.bell)

        case .notifyClipboard(let text):
            continuation?.yield(.clipboardText(text))

        case .reportError(let error):
            continuation?.yield(.error(error))

        case .disconnect:
            await stopAppleMediaUDP()
            await tcp.close()
            continuation?.yield(.disconnected)

        case .sendEncryptionResponse:
            // Encryption setup is handled separately when the pseudo-encoding is processed
            break

        case .sendMediaStreamAnswer(let answer):
            // Send the media stream answer as a pseudo-encoding response
            dumpAppleMediaClientRecordIfRequested(answer.wireBytes())
            try await sendControlChannel(answer.wireBytes())
            if answer.accepted {
                let isInitialAcceptance = !acceptedAppleMediaStream
                acceptedAppleMediaStream = true
                if isInitialAcceptance {
                    drainedAppleMediaControlBytes = 0
                    appleMediaControlBuffer.removeAll(keepingCapacity: true)
                    appleDecryptedRFBBuffer.removeAll(keepingCapacity: true)
                }
                emittedAppleMediaControlDiagnostics = 0
                appleMediaServerPacketID = 0
                appleMediaClientPacketID = 0
                sentAppleMediaPostAcceptViewerInfo = false
                sentAppleMediaPostAnswerViewerInfo = false
                sentAppleMediaAutoFrameUpdate = false
                rebuildAppleMediaSRTPContexts()
                if let key = appleSessionKey, appleEncryptedControlChannel == nil {
                    appleEncryptedControlChannel = try? AESCBCChannel(sendKey: key, recvKey: key)
                }
                try await sendAppleMediaPostAcceptEncodingsIfNeeded()
            }
            log.debug("Sent media stream answer for stream \(answer.streamID)")
        }
    }

    private func sendAppleMediaPostAcceptEncodingsIfNeeded() async throws {
        guard requestAppleMediaStream, !sentAppleMediaPostAcceptEncodings else { return }
        let payload = ClientMessage.setEncodings(appleMediaPostAcceptEncodings()).serialize()
        try await sendAppleMediaControlPayload(payload)
        sentAppleMediaPostAcceptEncodings = true
        log.debug("Sent Apple media post-accept SetEncodings length=\(payload.count)")
        try await sendAppleMediaPostAcceptViewerInfoIfNeeded()
    }

    private func sendAppleMediaPostAcceptViewerInfoIfNeeded() async throws {
        guard requestAppleMediaStream, !sentAppleMediaPostAcceptViewerInfo else { return }
        let payload = appleMediaStreamConfiguration(localPort: appleMediaConfigurationUDPPort())
        try await sendAppleMediaControlPayload(payload)
        sentAppleMediaPostAcceptViewerInfo = true
        log.debug("Sent Apple media post-accept viewer info length=\(payload.count)")
    }

    private func sendAppleMediaPostAnswerViewerInfoIfNeeded(for payload: Data) async throws {
        guard requestAppleMediaStream,
              isAppleAVCMediaAnswerPayload(payload) else { return }
        if let lengths = appleAVCMediaAnswerStreamLengths(payload) {
            appleMediaAnswerStreamLengths = lengths
            log.info(
                "Apple AVC message 2 accepted offer lengths "
                    + "audio=\(lengths[0]) video=\(lengths[1]) video2=\(lengths[2])")
        }
        _ = appleMediaGenerationTracker.finishMessageTwo()
        guard !sentAppleMediaPostAnswerViewerInfo else { return }
        let viewerInfo = appleMediaStreamConfiguration(localPort: appleMediaConfigurationUDPPort())
        try await sendAppleMediaControlPayload(viewerInfo)
        sentAppleMediaPostAnswerViewerInfo = true
        log.debug("Sent Apple media post-answer viewer info length=\(viewerInfo.count)")

    }

    private func applyStagedVirtualDisplayAfterInitialVideo() async {
        do {
            try await Task.sleep(for: Self.initialVirtualDisplayCoalescingDelay)
        } catch {
            return
        }
        guard !isDisconnecting,
              appleDisplayReconfigurationGeneration == nil,
              let pendingRemoteDisplaySize,
              pendingRemoteDisplaySize != lastSentRemoteDisplaySize,
              appleServerCapabilities?.supportsServerCommand(
                AppleServerCapabilities.displayConfigurationCommand) == true else { return }
        do {
            log.info(
                "Initial Apple video source live; applying coalesced staged virtual display "
                    + "\(pendingRemoteDisplaySize.pixelWidth)x"
                    + "\(pendingRemoteDisplaySize.pixelHeight)")
            try await sendAppleVirtualDisplaySize(pendingRemoteDisplaySize)
        } catch {
            log.error(
                "Could not apply staged virtual display after initial video: "
                    + error.localizedDescription)
        }
    }

    private func applyQueuedVirtualDisplayAfterMediaReady() async {
        guard appleDisplayReconfigurationGeneration == nil,
              let pendingRemoteDisplaySize,
              pendingRemoteDisplaySize != lastSentRemoteDisplaySize else { return }
        do {
            log.info(
                "Media reconfiguration live; applying coalesced virtual display "
                    + "\(pendingRemoteDisplaySize.pixelWidth)x"
                    + "\(pendingRemoteDisplaySize.pixelHeight)")
            try await sendAppleVirtualDisplaySize(pendingRemoteDisplaySize)
        } catch {
            log.error(
                "Could not apply coalesced virtual display: "
                    + error.localizedDescription)
        }
    }

    private func appleMediaPostAcceptEncodings() -> [Encoding] {
        Self.appleMediaPostAcceptEncodings(
            from: stateMachine.preferredEncodings,
            serverRendersCursor: serverRendersCursor)
    }

    static func appleMediaPostAcceptEncodings(
        from preferredEncodings: [Encoding],
        serverRendersCursor: Bool = false
    ) -> [Encoding] {
        // The native viewer also lists SubZlib (1002) here. We do not, because
        // no rectangle parser in this package can frame its payload: sending
        // it invites a rectangle that desynchronizes the stream. Re-add it
        // only alongside a real implementation. The `isUnframeableContent`
        // filter below is the belt to this list's braces, and covers anything
        // a caller injected through `preferredEncodings`.
        let nativeViewerEncodingRawValues: Set<Int32> = [
            0, 1, 6, 16,
            1000, 1001, 1010, 1011,
        ]
        // appleH264 (1010) selects the HEVC-over-UDP high-performance path.
        // This method is only reached for the native adaptive profile; public
        // Full Quality mode omits the media offer before a session is created.
        let baseEncodings = preferredEncodings.filter {
            nativeViewerEncodingRawValues.contains($0.rawValue)
                && !$0.isUnframeableContent
        }

        // Prefer macOS's cached alpha cursor over the generic RFB shape.
        // Standard mode advertises the same priority; putting .cursor
        // first makes AppleVNCServer choose its limited fallback path.
        // Asking for none of them leaves the pointer in the HEVC picture.
        let cursorEncodings: [Encoding] = serverRendersCursor
            ? []
            : [.unknown(0x450), .unknown(0x44c), .cursor]

        return baseEncodings + cursorEncodings + [
            .desktopSize,
            .unknown(0x44d),
            .unknown(0x451),
            .unknown(0x453),
            .unknown(0x455),
            .unknown(0x456),
        ]
    }

    private func handleAppleMediaServerControlIfPresent(_ payload: Data) async throws -> Bool {
        if appleDecryptedRFBBuffer.isEmpty,
           let messageOffset = appleRFBServerMessageOffset(in: payload) {
            if messageOffset == 0 {
                return false
            }
            // Some HEVC control records retain a two-byte inner envelope after
            // decryption. The RFB message itself starts at byte two (which is
            // why the legacy control scanner also checks encoding offset 16).
            try await ingestAppleDecryptedRFBPayload(Data(
                payload[payload.startIndex + messageOffset..<payload.endIndex]))
            return true
        }

        // A framebuffer update carrying CursorImageAlpha has the value 0x450
        // at byte 14 too. Do not mistake an RFB record (or its continuation)
        // for the similarly numbered media-control envelope.
        guard appleDecryptedRFBBuffer.isEmpty,
              payload.first.map({ !isAppleRFBServerMessageType($0) }) == true
        else { return false }
        guard let control = appleMediaServerControl(payload) else { return false }
        if control.encoding == 0x451 {
            log.debug(
                "Received High Performance DisplayInfo2 control "
                    + "length=\(control.body.count)")
        } else {
            log.debug("Received Apple media server control encoding=0x\(String(control.encoding, radix: 16)) length=\(control.body.count)")
        }
        if control.encoding == 0x450 {
            try await requestAppleMediaReconfigurationIfNeeded()
        } else if control.encoding == 0x451 {
            try await handleAppleMediaDisplayInfo2(control.body)
        } else if control.encoding == 0x455 {
            try await sendAppleMediaInitialSetDisplayIfNeeded()
            try await sendAppleMediaAutoFrameUpdateIfNeeded()
        } else if control.encoding == 0x456 {
            try await sendAppleMediaInitialSetDisplayIfNeeded()
            try await sendAppleMediaAutoFrameUpdateIfNeeded()
            try await sendAppleMediaServerConfigurationIfNeeded()
        }
        return true
    }

    /// Ingest one decrypted Apple media-control payload. Kept internal so the
    /// wire-equivalent High Performance path can be exercised without a live
    /// encrypted media session.
    func ingestAppleMediaServerControlPayload(_ payload: Data) async throws -> Bool {
        try await handleAppleMediaServerControlIfPresent(payload)
    }

    private func handleAppleMediaDisplayInfo2(_ payload: Data) async throws {
        emitAppleRemoteSessionState(
            from: payload,
            source: "High Performance 0x451")
        let displays = appleDisplayInfo2Records(payload)
        guard !displays.isEmpty else { return }
        try await commitDeferredAppleDisplayLayout(
            displays, replacingLayout: true)
        appleMediaDisplayInfos = displays
        let aggregateLumaSamples = displays.reduce(into: 0) { total, display in
            let width = Int(display.width)
            let height = Int(display.height)
            guard width > 0, height > 0,
                  width <= Int.max / height,
                  total <= Int.max - width * height else {
                total = Int.max
                return
            }
            total += width * height
        }
        appleMediaActiveCaptureLumaSamples = aggregateLumaSamples
        let first = displays[0]
        activeAppleMediaTilesPerFrame = selectedAppleMediaTilesPerFrame(
            pixelWidth: Int(first.width),
            pixelHeight: Int(first.height))
        appleMediaDisplayCount = requestsVirtualDisplays
                && lastSentRemoteDisplaySize != nil
            ? min(requestedDisplayCount, displays.count)
            : 1
        emitAppleDisplayInfoCompatibilityEvents(displays)
        continuation?.yield(.appleDisplayLayout(displays))
        log.info(
            "Apple media DisplayInfo2 announced \(displays.count) screens: "
                + displays.map { "\($0.width)x\($0.height)" }
                    .joined(separator: ", ")
                + "; captureLuma=\(aggregateLumaSamples) "
                + "tiles=\(activeAppleMediaTilesPerFrame)")
    }

    /// Preserve the original per-record event contract for every source of
    /// DisplayInfo2. The complete layout event remains additive and gives new
    /// consumers an atomic topology snapshot.
    private func emitAppleDisplayInfoCompatibilityEvents(
        _ displays: [AppleDisplayInfo]
    ) {
        for display in displays {
            continuation?.yield(.displayInfo(display))
        }
    }

    private func emitAppleRemoteSessionState(
        from payload: Data,
        source: String
    ) {
        guard let metadata = appleDisplayInfo2SessionMetadata(payload) else {
            let first = payload.prefix(20).map {
                String(format: "%02x", $0)
            }.joined(separator: " ")
            log.debug(
                "Could not decode Apple login flags from \(source): "
                    + "bytes=\(payload.count) header=\(first)")
            return
        }
        let state = metadata.state
        guard state != lastAppleRemoteSessionState else {
            log.debug(
                "Apple login state unchanged from \(source): "
                    + "loginWindow=\(state.loginWindowActive) "
                    + "lockScreen=\(state.loginWindowLockScreenActive)")
            return
        }
        lastAppleRemoteSessionState = state
        log.debug(
            "Apple login state changed from \(source): "
                + "loginWindow=\(state.loginWindowActive) "
                + "lockScreen=\(state.loginWindowLockScreenActive) "
                + "canCurtain=\(state.curtainToggleAvailable) "
                + "onConsole=\(state.onConsole) "
                + "version=\(metadata.version) "
                + "flagsBE=0x\(String(metadata.screenFlagsBigEndian, radix: 16)) "
                + "flagsLE=0x\(String(metadata.screenFlagsLittleEndian, radix: 16)) "
                + "lengthPrefix=\(metadata.hasLengthPrefix) "
                + "payloadBytes=\(payload.count)")
        continuation?.yield(.appleRemoteSessionState(state))
    }

    private func requestAppleMediaReconfigurationIfNeeded() async throws {
        guard requestAppleMediaStream,
              requestedDisplayCount > 1,
              appleDisplayReconfigurationGeneration != nil,
              !sentAppleMediaReconfigurationRequest else { return }
        sentAppleMediaReconfigurationRequest = true
        try await sendAppleMediaControlPayload(
            ClientMessage.appleMediaStreamRequest.serialize())
        log.info("Requested Apple media renegotiation for virtual displays")
    }

    private func sendAppleMediaInitialSetDisplayIfNeeded() async throws {
        guard !sentAppleMediaInitialSetDisplay else { return }
        if requestsVirtualDisplays {
            sentAppleMediaInitialSetDisplay = true
            return
        }
        let combinesAllDisplays: Bool
        switch runtimeEnvironment["ROOTSHELL_VNC_SET_DISPLAY_MODE"] {
        case "single": combinesAllDisplays = false
        case "global": combinesAllDisplays = true
        case "skip": return
        default: combinesAllDisplays = requestedDisplayCount > 1
        }
        let displayID: UInt32
        if combinesAllDisplays {
            displayID = 0
        } else {
            guard let firstDisplay = appleMediaDisplayInfos.first else {
                // DisplayInfo2 normally precedes 0x455/0x456. If it does not,
                // wait for a later control record rather than sending display
                // ID zero, which is not a portable alias for the main screen.
                return
            }
            displayID = firstDisplay.displayIndex
        }
        sentAppleMediaInitialSetDisplay = true
        try await sendAppleMediaControlPayload(appleSetDisplayMessage(
            isGlobal: combinesAllDisplays,
            displayID: displayID))
    }

    private func sendAppleStandardDisplaySelectionIfNeeded(
        displayID: UInt32,
        announcedDisplayCount: Int? = nil
    ) async throws {
        guard !requestAppleMediaStream,
              requestedDisplayCount == 1,
              !sentAppleMediaInitialSetDisplay else { return }
        sentAppleMediaInitialSetDisplay = true
        if announcedDisplayCount == 1 {
            // Screens leaves activeDisplay unset when the server announces a
            // sole display. Forcing SetDisplay here resets AppleVNCServer's
            // caches while it is satisfying the initial full-frame request,
            // which can leave it returning DisplayInfo2 indefinitely.
            log.info("Using Apple server default for sole announced display ID \(displayID)")
            return
        }
        resetAppleDCTBootstrapCoverage()
        // A non-global SetDisplay requires the server's real display ID. Zero
        // is not a portable synonym for the main monitor; the server validates
        // this UInt32 against its active display list.
        try await sendClientPayload(appleSetDisplayMessage(
            isGlobal: false,
            displayID: displayID))
        log.info("Selected Apple display ID \(displayID)")
    }

    private func resetAppleDCTBootstrapCoverage() {
        guard appleDCTRequested, fbWidth > 0, fbHeight > 0 else { return }
        awaitingAppleDCTBootstrap = true
        pendingAppleDCTAutoUpdateActivation = false
        pendingAppleDCTInitialFullFrameRequest = false
        appleDCTInitialUncoveredRegions = [AppleDCTCoverageRegion(
            minX: 0,
            minY: 0,
            maxX: Int(fbWidth),
            maxY: Int(fbHeight))]
    }

    private func recordAppleDCTBootstrapCoverage(
        from rectsWithData: [(FramebufferRect, Data)]
    ) {
        guard appleDCTRequested,
              stateMachine.negotiatedVersion?.isApple == true,
              awaitingAppleDCTBootstrap else { return }
        if appleDCTInitialUncoveredRegions.isEmpty {
            resetAppleDCTBootstrapCoverage()
        }

        for (rect, payload) in rectsWithData where
            rect.encoding == .appleMultiVariantScreenshare
                && payload.count >= 5 {
            let messageType = payload[payload.startIndex + 4]
            if messageType == 2, payload.count == 133 {
                // Type 2 only installs the connection-wide luma and chroma
                // quantization tables. Apple legitimately sends this control
                // record as a 0x0 rectangle. Activate the change-gated stream
                // first; its activation path then requests the complete base.
                awaitingAppleDCTBootstrap = false
                pendingAppleDCTAutoUpdateActivation = true
                pendingAppleDCTInitialFullFrameRequest = true
                log.debug("Received Apple DCT bootstrap quantization tables")
                return
            }
            guard messageType == 0 else { continue }
            let covered = AppleDCTCoverageRegion(
                minX: min(Int(rect.x), Int(fbWidth)),
                minY: min(Int(rect.y), Int(fbHeight)),
                maxX: min(Int(rect.x) + Int(rect.width), Int(fbWidth)),
                maxY: min(Int(rect.y) + Int(rect.height), Int(fbHeight)))
            appleDCTInitialUncoveredRegions = appleDCTInitialUncoveredRegions
                .flatMap { $0.subtracting(covered) }
        }

        guard appleDCTInitialUncoveredRegions.isEmpty else { return }
        awaitingAppleDCTBootstrap = false
        pendingAppleDCTAutoUpdateActivation = true
        log.debug("Received complete Apple DCT bootstrap coverage")
    }

    private func appleSetDisplayMessage(isGlobal: Bool, displayID: UInt32) -> Data {
        var data = Data(count: 8)
        data[0] = 0x0d
        data[1] = isGlobal ? 1 : 0
        writeUInt32BE(isGlobal ? UInt32.max : displayID, into: &data, at: 4)
        return data
    }

    private func sendAppleMediaAutoFrameUpdateIfNeeded() async throws {
        guard !sentAppleMediaAutoFrameUpdate else { return }
        sentAppleMediaAutoFrameUpdate = true
        // The interval is a max-fps cap (0 = uncapped, 16 ≈ 62 fps); frame
        // delivery is change-gated regardless, so it does not affect idle bitrate.
        let interval = runtimeEnvironment["ROOTSHELL_VNC_AUTOFRAME_INTERVAL_MS"]
            .flatMap { Int32($0) } ?? 16
        try await sendAppleMediaControlPayload(appleAutoFrameUpdateMessage(intervalMilliseconds: interval))
    }

    private func sendAppleAutoFrameUpdate() async throws {
        guard appleDCTRequested || appleClassicAutoUpdateRequested,
              stateMachine.negotiatedVersion?.isApple == true else { return }
        try await sendClientPayload(
            appleAutoFrameUpdateMessage(
                intervalMilliseconds: 0))
        framebufferRequestSentNanos = DispatchTime.now().uptimeNanoseconds
    }

    private func startAppleAutoUpdateRefreshTask() {
        guard appleAutoUpdateRefreshTask == nil else { return }
        appleAutoUpdateRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(10))
                    guard !Task.isCancelled, let self else { return }
                    try await self.refreshAppleAutoUpdate()
                } catch is CancellationError {
                    return
                } catch {
                    guard let self else { return }
                    await self.logAppleAutoUpdateRefreshFailure(error)
                }
            }
        }
    }

    private func refreshAppleAutoUpdate() async throws {
        guard appleAutoUpdateActive, !isDisconnecting else { return }
        try await sendAppleAutoFrameUpdate()
    }

    private func logAppleAutoUpdateRefreshFailure(_ error: Error) {
        log.warning(
            "Failed to renew Apple auto updates: "
                + error.localizedDescription)
    }

    private func waitForFramebufferCreditIfNeeded() async {
        guard unacknowledgedUpdates >= maxUnacknowledgedUpdates else { return }
        await withCheckedContinuation { continuation in
            if unacknowledgedUpdates < maxUnacknowledgedUpdates {
                continuation.resume()
            } else {
                precondition(framebufferCreditWaiter == nil)
                framebufferCreditWaiter = continuation
            }
        }
    }

    private func resumeFramebufferCreditWaiterIfPossible() {
        guard unacknowledgedUpdates < maxUnacknowledgedUpdates,
              let waiter = framebufferCreditWaiter else { return }
        framebufferCreditWaiter = nil
        waiter.resume()
    }

    /// Commit server-announced geometry before any subsequent update request.
    /// An active Apple media subscription carries explicit capture bounds, so
    /// resend that same understood control message with the new dimensions;
    /// this keeps the existing media session and decoder timeline intact.
    private func acceptFramebufferResize(width: UInt16, height: UInt16) async throws {
        guard width > 0, height > 0 else { return }
        guard width != fbWidth || height != fbHeight else { return }

        let oldWidth = fbWidth
        let oldHeight = fbHeight
        fbWidth = width
        fbHeight = height
        log.info("Framebuffer resized \(oldWidth)x\(oldHeight) -> \(width)x\(height)")

        if awaitingAppleDCTBootstrap {
            resetAppleDCTBootstrapCoverage()
        }

        if appleAutoUpdateActive {
            try await sendAppleAutoFrameUpdate()
            log.debug("Updated Apple DCT frame subscription to \(width)x\(height)")
        }

        guard acceptedAppleMediaStream, sentAppleMediaAutoFrameUpdate else { return }
        let interval = runtimeEnvironment["ROOTSHELL_VNC_AUTOFRAME_INTERVAL_MS"]
            .flatMap { Int32($0) } ?? 16
        try await sendAppleMediaControlPayload(
            appleAutoFrameUpdateMessage(intervalMilliseconds: interval))
        log.debug("Updated Apple media frame subscription to \(width)x\(height)")
    }

    /// Promote Apple's display-layout extension into real transport geometry
    /// when ServerInit could not provide any. Updating both local request
    /// bounds and the protocol state machine before the enclosing framebuffer
    /// update completes lets its normal credit return issue the next request.
    private func commitDeferredAppleDisplayLayout(
        _ displays: [AppleDisplayInfo],
        replacingLayout: Bool
    ) async throws {
        guard usesDeferredAppleDisplayLayout, !displays.isEmpty else { return }
        if replacingLayout {
            deferredAppleDisplayLayoutByID.removeAll(keepingCapacity: true)
        }
        for display in displays {
            deferredAppleDisplayLayoutByID[display.displayIndex] = display
        }

        // Match Client's requested virtual surface outranks physical
        // DisplayInfo2 metadata that can still be in flight during setup.
        if requestsVirtualDisplays,
           let requested = pendingRemoteDisplaySize ?? lastSentRemoteDisplaySize {
            try await acceptFramebufferResize(
                width: requested.pixelWidth,
                height: requested.pixelHeight)
            stateMachine.acceptFramebufferGeometry(
                width: requested.pixelWidth,
                height: requested.pixelHeight)
            return
        }

        let valid = deferredAppleDisplayLayoutByID.values.filter {
            $0.width > 0 && $0.height > 0
        }
        guard let first = valid.first else { return }
        var minX = Int64(first.originX)
        var minY = Int64(first.originY)
        var maxX = minX + Int64(first.width)
        var maxY = minY + Int64(first.height)
        for display in valid.dropFirst() {
            let x = Int64(display.originX)
            let y = Int64(display.originY)
            minX = min(minX, x)
            minY = min(minY, y)
            maxX = max(maxX, x + Int64(display.width))
            maxY = max(maxY, y + Int64(display.height))
        }
        let width = maxX - minX
        let height = maxY - minY
        guard width > 0, height > 0,
              width <= Int64(UInt16.max), height <= Int64(UInt16.max) else { return }

        let acceptedWidth = UInt16(width)
        let acceptedHeight = UInt16(height)
        try await acceptFramebufferResize(
            width: acceptedWidth,
            height: acceptedHeight)
        stateMachine.acceptFramebufferGeometry(
            width: acceptedWidth,
            height: acceptedHeight)
    }

    private func appleAutoFrameUpdateMessage(intervalMilliseconds: Int32) -> Data {
        ClientMessage.appleAutoFramebufferUpdate(
            intervalMilliseconds: intervalMilliseconds,
            x: 0, y: 0,
            width: fbWidth, height: fbHeight).serialize()
    }

    private func noteStandardDesktopSizeSupport(
        _ layout: ExtendedDesktopSizePayload
    ) async throws {
        standardDesktopLayout = layout
        guard let pendingRemoteDisplaySize,
              appleServerCapabilities?.supportsServerCommand(
                AppleServerCapabilities.displayConfigurationCommand) != true else { return }
        try await sendStandardDesktopSize(pendingRemoteDisplaySize)
    }

    private func sendStandardDesktopSize(
        _ requested: PendingRemoteDisplaySize
    ) async throws {
        // SetDesktopSize changes the server's monitor topology; it is not a
        // display-selection mechanism. Keep Match Client to one screen and
        // select existing standard-mode displays in the presentation layer.
        let existing = standardDesktopLayout?.screens.first
        let screen = SetDesktopSizeScreen(
            id: existing?.id ?? 0,
            width: requested.pixelWidth,
            height: requested.pixelHeight,
            flags: existing?.flags ?? 0)
        let request = SetDesktopSizeRequest(
            width: requested.pixelWidth,
            height: requested.pixelHeight,
            screens: [screen])
        let message = ClientMessage.setDesktopSize(request)
        try await sendClientPayload(message.serialize())
        lastSentRemoteDisplaySize = requested
        pendingRemoteDisplaySize = nil
        emitAppleRemoteDisplayResizeSettled()
        appleRemoteDisplaySizeSink?(
            request.width,
            request.height)
        log.info(
            "Requested standard remote desktop \(request.width)x\(request.height)")
    }

    private func sendAppleVirtualDisplaySize(
        _ requested: PendingRemoteDisplaySize
    ) async throws {
        // The display command describes a 2× virtual display with both pixel
        // and point dimensions. A nominal 110 points/inch gives the virtual display
        // a stable physical size without affecting its explicit HiDPI mode.
        let millimetersPerPoint = Float(25.4 / 110.0)
        let mode = AppleVirtualDisplayMode(
            pixelWidth: UInt32(requested.pixelWidth),
            pixelHeight: UInt32(requested.pixelHeight),
            pointWidth: UInt32(requested.pointWidth),
            pointHeight: UInt32(requested.pointHeight))
        // These are fixed capability maxima, not the active mode or an active
        // resolution cap. The requested pixel/point pair below selects 2×.
        let displays = (0..<requestedDisplayCount).map { index in
            AppleVirtualDisplay(
                name: requestedDisplayCount == 1
                    ? "rootshell Virtual Display"
                    : "rootshell Virtual Display \(index + 1)",
                widthInMillimeters: Float(requested.pointWidth) * millimetersPerPoint,
                heightInMillimeters: Float(requested.pointHeight) * millimetersPerPoint,
                maximumPixelWidth: appleVirtualDisplayMaximumPixelWidth,
                maximumPixelHeight: appleVirtualDisplayMaximumPixelHeight,
                originX: UInt16(Int(requested.pixelWidth) * index),
                identifier: UInt32(7 + index),
                modes: [mode])
        }
        let previousCaptureLumaSamples = appleMediaActiveCaptureLumaSamples
        let previousTilesPerFrame = activeAppleMediaTilesPerFrame
        let requestedDisplayLumaSamples = Int(requested.pixelWidth)
            * Int(requested.pixelHeight)
        appleMediaActiveCaptureLumaSamples = requestedDisplayLumaSamples
            * displays.count
        // Keep decoder packetization aligned with the replacement capture
        // graph, not the physical topology that generation one is retiring.
        activeAppleMediaTilesPerFrame = selectedAppleMediaTilesPerFrame(
            pixelWidth: Int(requested.pixelWidth),
            pixelHeight: Int(requested.pixelHeight))
        let message = ClientMessage.appleDisplayConfiguration(
            AppleDisplayConfiguration(displays: displays))
        // The Apple media re-offer that follows command 29 is generated from
        // these session dimensions. ServerInit is not repeated for a virtual
        // display change, so retaining the physical framebuffer here would
        // advertise decoder geometry for the retired capture source.
        let previousWidth = fbWidth
        let previousHeight = fbHeight
        let previousDisplayCount = appleMediaDisplayCount
        fbWidth = requested.pixelWidth
        fbHeight = requested.pixelHeight
        appleMediaDisplayCount = displays.count
        if requestAppleMediaStream {
            appleDisplayReconfigurationGeneration =
                appleMediaGenerationTracker.generation &+ 1
            sentAppleMediaReconfigurationRequest = false
        }
        do {
            try await sendClientPayload(message.serialize())
        } catch {
            fbWidth = previousWidth
            fbHeight = previousHeight
            appleMediaDisplayCount = previousDisplayCount
            appleMediaActiveCaptureLumaSamples = previousCaptureLumaSamples
            activeAppleMediaTilesPerFrame = previousTilesPerFrame
            appleDisplayReconfigurationGeneration = nil
            throw error
        }
        lastSentRemoteDisplaySize = requested
        pendingRemoteDisplaySize = nil
        emitAppleRemoteDisplayResizeSettled()
        let aggregateWidth = UInt16(min(
            Int(UInt16.max),
            Int(requested.pixelWidth) * displays.count))
        appleRemoteDisplaySizeSink?(
            aggregateWidth,
            requested.pixelHeight)
        log.info(
            "Requested Apple dynamic virtual display \(requested.pixelWidth)x"
                + "\(requested.pixelHeight) pixels (\(requested.pointWidth)x"
                + "\(requested.pointHeight) points), count=\(displays.count) "
                + "captureLuma=\(appleMediaActiveCaptureLumaSamples) "
                + "tiles=\(activeAppleMediaTilesPerFrame)")
    }

    /// Public so a client with a queued input intent can query the
    /// authoritative answer on demand; sink emissions can race their
    /// main-actor delivery.
    public var isAppleRemoteDisplayResizeSettled: Bool {
        pendingRemoteDisplaySize == nil
            && appleDisplayReconfigurationGeneration == nil
    }

    private func emitAppleRemoteDisplayResizeSettled() {
        appleRemoteDisplayResizeSettledSink?(
            isAppleRemoteDisplayResizeSettled)
    }

    private nonisolated func appleMediaServerControl(_ payload: Data) -> (encoding: UInt16, body: Data)? {
        parseAppleMediaServerControl(payload, encodingOffset: 14)
            ?? parseAppleMediaServerControl(payload, encodingOffset: 16)
    }

    private nonisolated func parseAppleMediaServerControl(
        _ payload: Data,
        encodingOffset: Int
    ) -> (encoding: UInt16, body: Data)? {
        guard payload.count >= encodingOffset + 4 else { return nil }
        guard let encoding = readUInt16BE(payload, at: encodingOffset),
              let bodyLength = readUInt16BE(payload, at: encodingOffset + 2) else { return nil }

        let bodyStart = payload.startIndex + encodingOffset + 2
        let bodyEnd = bodyStart + Int(bodyLength)
        guard bodyEnd <= payload.endIndex else { return nil }

        switch encoding {
        case 0x450, 0x451, 0x453, 0x455, 0x456:
            return (encoding, Data(payload[bodyStart..<bodyEnd]))
        default:
            return nil
        }
    }

    private func sendClientPayload(_ payload: Data) async throws {
        if acceptedAppleMediaStream {
            let label = hasEncryptedAppleMediaControl
                ? "client encrypted payload"
                : "client plaintext media payload"
            traceAppleMediaClientPayload(label: label, payload: payload)
            try await sendAppleMediaControlPayload(payload)
        } else {
            if requestAppleMediaStream {
                traceAppleMediaClientPayload(label: "client plaintext payload", payload: payload)
            }
            try await sendControlChannel(payload)
        }
    }

    private func sendAppleMediaControlPayload(_ payload: Data) async throws {
        dumpAppleMediaClientRecordIfRequested(payload)
        if let channel = appleMediaComCryptionChannel {
            let encrypted = try channel.encryptPayload(payload, packetID: appleMediaClientPacketID)
            appleMediaClientPacketID &+= 1
            guard encrypted.count <= Int(UInt16.max) else {
                throw VNCProtocolError.protocolViolation(
                    "Apple ComCryption client payload too large: \(encrypted.count) bytes")
            }

            var framed = Data(capacity: 2 + encrypted.count)
            framed.append(UInt8((encrypted.count >> 8) & 0xFF))
            framed.append(UInt8(encrypted.count & 0xFF))
            framed.append(encrypted)
            traceAppleMediaClientFrame(label: "client ComCryption frame", payload: payload, framed: framed)
            try await sendControlChannel(framed)
            return
        }

        if appleEncryptedControlChannel == nil,
           stateMachine.selectedSecurityType != .vncAuthentication {
            try ensureAppleEncryptedControlChannel()
        }

        guard let channel = appleEncryptedControlChannel else {
            // VNC Authentication (type 2) has no key-exchange step. Apple
            // servers therefore retain ordinary RFB framing for the media
            // control messages until/unless an encrypted transition is
            // explicitly negotiated.
            traceAppleMediaClientPayload(
                label: "client plaintext media control", payload: payload)
            try await sendControlChannel(payload)
            return
        }

        let encrypted = try channel.encrypt(payload)
        guard encrypted.count <= Int(UInt16.max) else {
            throw VNCProtocolError.protocolViolation(
                "Apple encrypted client payload too large: \(encrypted.count) bytes")
        }

        var framed = Data(capacity: 2 + encrypted.count)
        framed.append(UInt8((encrypted.count >> 8) & 0xFF))
        framed.append(UInt8(encrypted.count & 0xFF))
        framed.append(encrypted)
        traceAppleMediaClientFrame(label: "client AES frame", payload: payload, framed: framed)
        try await sendControlChannel(framed)
    }

    private nonisolated func traceAppleMediaClientPayload(label: String, payload: Data) {
        guard VNCDiagnostics.isEnabled(
            "ROOTSHELL_VNC_TRACE_APPLE_MEDIA_SEND",
            environment: runtimeEnvironment) else { return }
        VNCLogger(category: "AppleMediaTrace").debug(
            "Apple media send: \(label) payloadLength=\(payload.count) "
                + "prefix=\(hexDump(payload.prefix(96)))")
    }

    private nonisolated func traceAppleMediaClientFrame(label: String, payload: Data, framed: Data) {
        guard VNCDiagnostics.isEnabled(
            "ROOTSHELL_VNC_TRACE_APPLE_MEDIA_SEND",
            environment: runtimeEnvironment) else { return }
        VNCLogger(category: "AppleMediaTrace").debug(
            "Apple media send: \(label) payloadLength=\(payload.count) "
                + "frameLength=\(framed.count) payloadPrefix=\(hexDump(payload.prefix(96))) "
                + "framePrefix=\(hexDump(framed.prefix(96)))")
    }

    private nonisolated func hexDump(_ data: some Collection<UInt8>) -> String {
        data.map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    private func ensureAppleEncryptedControlChannel() throws {
        guard appleEncryptedControlChannel == nil else { return }
        guard let key = appleSessionKey else {
            throw VNCProtocolError.protocolViolation("Apple session key is unavailable")
        }
        appleEncryptedControlChannel = try AESCBCChannel(sendKey: key, recvKey: key)
    }

    private func drainAppleMediaControlRecord() async throws {
        let chunk = try await readControlChannel(upTo: 4096)
        dumpAppleMediaTCPChunkIfRequested(chunk)
        drainedAppleMediaControlBytes += chunk.count
        appleMediaControlBuffer.append(chunk)

        var plaintextPrefix: Data?
        var decryptError: String?

        if appleMediaComCryptionChannel != nil || appleEncryptedControlChannel != nil {
            while let encryptedRecord = nextAppleEncryptedControlRecord() {
                if appleMediaComCryptionChannel != nil {
                    do {
                        let record = try decryptAppleMediaComCryptionRecord(encryptedRecord)
                        dumpAppleMediaPlaintextIfRequested(record.payload)
                        dumpAppleMediaServerRecordIfRequested(record.payload)
                        plaintextPrefix = record.plaintextPrefix
                        decryptError = describeAppleMediaPlaintext(record.payload)
                        if try await handleAppleMediaServerControlIfPresent(record.payload) {
                            continue
                        }
                        let isAVCMediaRecord = findAppleAVCMediaMessage(
                            in: record.payload) != nil
                        _ = try await handleAppleAVCServerMediaMessageIfPresent(record.payload)
                        try await sendAppleMediaPostAnswerViewerInfoIfNeeded(for: record.payload)
                        let startsRFBRecord = record.payload.first.map(
                            isAppleRFBServerMessageType) ?? false
                        let isRFBRecord = !appleDecryptedRFBBuffer.isEmpty
                            || startsRFBRecord
                        if !isAVCMediaRecord, isRFBRecord {
                            try await ingestAppleDecryptedRFBPayload(record.payload)
                        }

                        let candidatePackets = extractAppleMediaRTPPackets(from: record.payload)
                        for packet in confirmedAppleMediaRTPPackets(from: candidatePackets) {
                            emitAppleMediaRTPPacket(packet)
                        }
                        continue
                    } catch {
                        if encryptedRecord.count >= 1024 {
                            decryptError = "Apple ComCryption: \(error.localizedDescription)"
                            continue
                        }
                    }
                }

                if let channel = appleEncryptedControlChannel {
                    do {
                        let plaintext = try channel.decrypt(encryptedRecord)
                        dumpAppleMediaServerRecordIfRequested(plaintext)
                        plaintextPrefix = Data(plaintext.prefix(64))
                        decryptError = describeAppleMediaPlaintext(plaintext)
                        if try await handleAppleMediaServerControlIfPresent(plaintext) {
                            continue
                        }
                        let isAVCMediaRecord = findAppleAVCMediaMessage(
                            in: plaintext) != nil
                        _ = try await handleAppleAVCServerMediaMessageIfPresent(plaintext)
                        try await sendAppleMediaPostAnswerViewerInfoIfNeeded(for: plaintext)
                        let startsRFBRecord = plaintext.first.map(
                            isAppleRFBServerMessageType) ?? false
                        let isRFBRecord = !appleDecryptedRFBBuffer.isEmpty
                            || startsRFBRecord
                        if !isAVCMediaRecord, isRFBRecord {
                            try await ingestAppleDecryptedRFBPayload(plaintext)
                        }
                        let candidatePackets = extractAppleMediaRTPPackets(from: plaintext)
                        for packet in confirmedAppleMediaRTPPackets(from: candidatePackets) {
                            emitAppleMediaRTPPacket(packet)
                        }
                    } catch {
                        decryptError = error.localizedDescription
                    }
                } else {
                    decryptError = "Apple encrypted channel is unavailable"
                }
            }

            if plaintextPrefix == nil, decryptError == nil {
                if let pendingLength = pendingAppleEncryptedRecordLength() {
                    decryptError = "waiting for encrypted record: buffered=\(appleMediaControlBuffer.count) expected=\(pendingLength)"
                } else if let channel = appleEncryptedControlChannel,
                          let candidate = tryAppleMediaBlockStreamDecrypt(channel: channel) {
                    plaintextPrefix = candidate.plaintextPrefix
                    decryptError = candidate.diagnostic
                } else {
                    decryptError = describeAppleMediaEncryptedBuffer()
                }
            }

            if appleMediaControlBuffer.count > appleMediaControlBufferLimit {
                let retained = Data(appleMediaControlBuffer.suffix(4096))
                appleMediaControlBuffer = retained
                if decryptError == nil {
                    decryptError = "buffer exceeded \(appleMediaControlBufferLimit) bytes without a complete encrypted record"
                }
            }
        }

        emitAppleMediaControlDiagnostic(
            encryptedLength: chunk.count,
            encryptedPrefix: Data(chunk.prefix(64)),
            plaintextPrefix: plaintextPrefix,
            decryptError: decryptError
        )
        latestAppleMediaControlDiagnostic = decryptError

        if drainedAppleMediaControlBytes <= 4096 {
            log.debug("Drained Apple media TCP control stream chunk \(chunk.count) bytes")
        }
    }

    private func drainAppleDecryptedRFBBuffer() async throws {
        while true {
            guard appleDecryptedRFBBuffer.count >= 1 else { return }
            let base = appleDecryptedRFBBuffer.startIndex
            let messageType = appleDecryptedRFBBuffer[base]

            switch messageType {
            case 0:
                guard try await drainAppleDecryptedFramebufferUpdate() else { return }
            case 2:
                appleDecryptedRFBBuffer.removeSubrange(base..<base + 1)
                continuation?.yield(.bell)
            case 3:
                guard try drainAppleDecryptedServerCutText() else { return }
            case AppleClipboardProtocol.packedScrapMessageType:
                guard try drainAppleDecryptedPackedClipboard() else { return }
            case 0x14:
                guard base + 8 <= appleDecryptedRFBBuffer.endIndex else {
                    return
                }
                appleDecryptedRFBBuffer.removeSubrange(base..<base + 8)
                if appleSharedClipboardEnabled {
                    do {
                        try await requestRemoteClipboard()
                    } catch {
                        log.warning(
                            "Unable to request changed Apple clipboard: "
                                + error.localizedDescription)
                    }
                }
            default:
                return
            }
        }
    }

    /// Feed one authenticated control-channel payload into the ordinary RFB
    /// message parser. Apple may split an update across encrypted records, so
    /// incomplete data remains buffered for the next call.
    func ingestAppleDecryptedRFBPayload(_ payload: Data) async throws {
        appleDecryptedRFBBuffer.append(payload)
        try await drainAppleDecryptedRFBBuffer()
        let limit = appleDecryptedRFBBufferLimit
        if appleDecryptedRFBBuffer.count > limit {
            log.error(
                "Apple decrypted RFB buffer exceeded the protocol maximum of "
                    + "\(limit) bytes without draining "
                    + "(\(appleDecryptedRFBBuffer.count) buffered); "
                    + "discarding to restore progress")
            appleDecryptedRFBBuffer.removeAll(keepingCapacity: false)
        }
    }

    private nonisolated func isAppleRFBServerMessageType(
        _ messageType: UInt8
    ) -> Bool {
        switch messageType {
        case 0, 2, 3, 0x14,
             AppleClipboardProtocol.packedScrapMessageType:
            return true
        default:
            return false
        }
    }

    private func drainAppleDecryptedFramebufferUpdate() async throws -> Bool {
        let base = appleDecryptedRFBBuffer.startIndex
        guard base + 4 <= appleDecryptedRFBBuffer.endIndex else { return false }

        let rectCount = Int(UInt16(appleDecryptedRFBBuffer[base + 2]) << 8
            | UInt16(appleDecryptedRFBBuffer[base + 3]))
        var offset = base + 4
        var rectsWithData: [(FramebufferRect, Data)] = []
        rectsWithData.reserveCapacity(rectCount)
        var pendingResize: FramebufferRect?

        for _ in 0..<rectCount {
            guard offset + FramebufferRect.wireSize <= appleDecryptedRFBBuffer.endIndex else { return false }
            var reader = MessageReader(data: Data(appleDecryptedRFBBuffer[offset..<offset + FramebufferRect.wireSize]))
            let rect = try FramebufferRect(reader: &reader)
            offset += FramebufferRect.wireSize

            let pixelDataLength: Int
            switch rect.encoding {
            case .raw:
                pixelDataLength = Int(rect.width) * Int(rect.height) * pixelFormat.bytesPerPixel
            case .zlib, .zrle:
                guard offset + 4 <= appleDecryptedRFBBuffer.endIndex else { return false }
                let b0 = UInt32(appleDecryptedRFBBuffer[offset]) << 24
                let b1 = UInt32(appleDecryptedRFBBuffer[offset + 1]) << 16
                let b2 = UInt32(appleDecryptedRFBBuffer[offset + 2]) << 8
                let b3 = UInt32(appleDecryptedRFBBuffer[offset + 3])
                let compressedLength = Int(b0 | b1 | b2 | b3)
                pixelDataLength = 4 + compressedLength
            case .copyRect:
                pixelDataLength = 4
            case .desktopSize:
                pixelDataLength = 0
            case .extendedDesktopSize:
                guard offset + ExtendedDesktopSizePayload.headerWireSize
                        <= appleDecryptedRFBBuffer.endIndex else { return false }
                pixelDataLength = ExtendedDesktopSizePayload.wireSize(
                    screenCount: appleDecryptedRFBBuffer[offset])
            case .mediaStreamOffer:
                pixelDataLength = AppleMediaStreamOffer.wirePayloadSize
            case .appleH264:
                guard offset + 2 <= appleDecryptedRFBBuffer.endIndex else {
                    return false
                }
                let length = Int(appleDecryptedRFBBuffer[offset]) << 8
                    | Int(appleDecryptedRFBBuffer[offset + 1])
                pixelDataLength = 2 + length
            case .encryptionInfo, .serverDisplayInfo, .mediaStreamAnswer:
                pixelDataLength = 0
            case .cursor:
                let pixelBytes = Int(rect.width) * Int(rect.height) * pixelFormat.bytesPerPixel
                let maskBytes = Int((Int(rect.width) + 7) / 8) * Int(rect.height)
                pixelDataLength = pixelBytes + maskBytes
            case .xCursor:
                let rowBytes = (Int(rect.width) + 7) / 8
                let bitmapBytes = rowBytes * Int(rect.height)
                pixelDataLength = bitmapBytes == 0 ? 0 : 6 + bitmapBytes * 2
            case .unknown(let value) where value == 1100:
                pixelDataLength = 0
            case .unknown(let value) where value == 1101:
                guard offset + 10 <= appleDecryptedRFBBuffer.endIndex else {
                    return false
                }
                let count = Int(appleDecryptedRFBBuffer[offset + 8]) << 8
                    | Int(appleDecryptedRFBBuffer[offset + 9])
                pixelDataLength = 10 + count * 28
            case .unknown(let value) where value == 1104:
                guard offset + 8 <= appleDecryptedRFBBuffer.endIndex else {
                    return false
                }
                let b0 = UInt32(appleDecryptedRFBBuffer[offset + 4]) << 24
                let b1 = UInt32(appleDecryptedRFBBuffer[offset + 5]) << 16
                let b2 = UInt32(appleDecryptedRFBBuffer[offset + 6]) << 8
                let b3 = UInt32(appleDecryptedRFBBuffer[offset + 7])
                pixelDataLength = 8 + Int(b0 | b1 | b2 | b3)
            case .unknown(let value)
                where value == 1105 || value == 1107
                    || value == 1109 || value == 1110:
                // Apple HEVC control rectangles carry a UInt16 byte count.
                // They can share a framebuffer update with CursorImageAlpha;
                // consuming every preceding rectangle is required to reach it.
                guard offset + 2 <= appleDecryptedRFBBuffer.endIndex else {
                    return false
                }
                let length = Int(appleDecryptedRFBBuffer[offset]) << 8
                    | Int(appleDecryptedRFBBuffer[offset + 1])
                pixelDataLength = 2 + length
            default:
                // `false` means "incomplete, wait for more bytes", which is
                // only true for an encoding whose framing we know. For a
                // content encoding we cannot frame, no amount of further data
                // resolves it: the drain wedges permanently and the decrypted
                // buffer grows forever behind it. Throwing does not help here
                // either, because the control-record reader treats decrypt and
                // parse failures as non-fatal. Name it and resynchronize: the
                // ingest heuristic only feeds records that begin with a known
                // RFB message type once the buffer is empty, so dropping the
                // wedged bytes lets the channel pick up the next clean record.
                if rect.encoding.isUnframeableContent {
                    log.error(
                        "Unsupported framebuffer encoding "
                            + "\(rect.encoding.rawValue) (\(rect.encoding.displayName)) "
                            + "on the Apple control channel for rect "
                            + "\(rect.width)x\(rect.height); "
                            + "dropping \(appleDecryptedRFBBuffer.count) buffered bytes to resynchronize")
                    appleDecryptedRFBBuffer.removeAll(keepingCapacity: true)
                }
                return false
            }

            guard offset + pixelDataLength <= appleDecryptedRFBBuffer.endIndex else { return false }
            let pixelData = Data(appleDecryptedRFBBuffer[offset..<offset + pixelDataLength])
            offset += pixelDataLength
            if rect.encoding == .extendedDesktopSize {
                let layout = try ExtendedDesktopSizePayload(data: pixelData)
                try await noteStandardDesktopSizeSupport(layout)
            } else if rect.encoding == .mediaStreamOffer {
                try await handleAppleMediaStreamOfferPayload(pixelData)
            } else if rect.encoding == .appleH264,
                      pixelData.count == AppleMediaStreamOffer.wirePayloadSize + 2 {
                try await handleAppleMediaStreamOfferPayload(
                    Data(pixelData.dropFirst(2)))
            } else if case .unknown(let value) = rect.encoding {
                switch value {
                case 1104:
                    try await requestAppleMediaReconfigurationIfNeeded()
                case 1105:
                    try await handleAppleMediaDisplayInfo2(pixelData)
                case 1109:
                    try await sendAppleMediaInitialSetDisplayIfNeeded()
                    try await sendAppleMediaAutoFrameUpdateIfNeeded()
                case 1110:
                    try await sendAppleMediaInitialSetDisplayIfNeeded()
                    try await sendAppleMediaAutoFrameUpdateIfNeeded()
                    try await sendAppleMediaServerConfigurationIfNeeded()
                default:
                    break
                }
            }
            rectsWithData.append((rect, pixelData))
            if rect.isSuccessfulDesktopResize {
                pendingResize = rect
            }
        }

        appleDecryptedRFBBuffer.removeSubrange(base..<offset)
        if let resize = pendingResize {
            usesDeferredAppleDisplayLayout = false
            try await acceptFramebufferResize(width: resize.width, height: resize.height)
        }
        // Match the ordinary framebuffer path's single-update credit. The
        // consumer applies cursor/layout metadata, then finishFramebufferUpdate
        // sends the next encrypted incremental request.
        unacknowledgedUpdates += 1
        deferredUpdateRequest = true
        continuation?.yield(.framebufferUpdate(rectsWithData))
        return true
    }

    private func handleAppleMediaStreamOfferPayload(_ offerData: Data) async throws {
        var offerReader = MessageReader(data: offerData)
        let offer = try AppleMediaStreamOffer(reader: &offerReader)
        if !isAppleMediaComCryptionTransition(offer.rawPayload) {
            // DisplayInfo2 is authoritative for the stream display count; keep
            // the offer-field interpretation only for old virtual-display servers.
            if appleMediaDisplayInfos.isEmpty,
               requestsVirtualDisplays {
                appleMediaDisplayCount = selectedAppleMediaDisplayCount(
                    offered: offer.videoStreamDisplayCount,
                    requested: requestedDisplayCount)
            }
            appleMediaSupportsHDR = offer.videoStream1Flags.map { flags in
                flags & 0x02 != 0
            } ?? false
        }
        try configureAppleMediaComCryptionIfPresent(offer.rawPayload)
        try await configureAppleMediaUDP(for: offer)
        continuation?.yield(.mediaStreamOffer(offer))
        let actions = stateMachine.handle(event: .receivedMediaStreamOffer(offer))
        try await executeActions(actions)
    }

    private func drainAppleDecryptedServerCutText() throws -> Bool {
        let base = appleDecryptedRFBBuffer.startIndex
        guard base + 8 <= appleDecryptedRFBBuffer.endIndex else { return false }
        let length = Int(UInt32(appleDecryptedRFBBuffer[base + 4]) << 24
            | UInt32(appleDecryptedRFBBuffer[base + 5]) << 16
            | UInt32(appleDecryptedRFBBuffer[base + 6]) << 8
            | UInt32(appleDecryptedRFBBuffer[base + 7]))
        guard base + 8 + length <= appleDecryptedRFBBuffer.endIndex else { return false }

        let textData = Data(appleDecryptedRFBBuffer[base + 8..<base + 8 + length])
        let text = String(data: textData, encoding: .utf8)
            ?? String(data: textData, encoding: .isoLatin1)
            ?? ""
        appleDecryptedRFBBuffer.removeSubrange(base..<base + 8 + length)
        continuation?.yield(.clipboardText(text))
        return true
    }

    private func drainAppleDecryptedPackedClipboard() throws -> Bool {
        let base = appleDecryptedRFBBuffer.startIndex
        let headerSize = AppleClipboardProtocol.packedScrapHeaderSize
        guard base + headerSize <= appleDecryptedRFBBuffer.endIndex else {
            return false
        }

        let uncompressedLength = Int(
            AppleClipboardProtocol.uint32BE(
                appleDecryptedRFBBuffer, at: base + 8) ?? 0)
        let compressedLength = Int(
            AppleClipboardProtocol.uint32BE(
                appleDecryptedRFBBuffer, at: base + 12) ?? 0)
        guard uncompressedLength <= AppleClipboardProtocol.maximumClipboardSize,
              compressedLength <= AppleClipboardProtocol.maximumClipboardSize else {
            throw VNCProtocolError.protocolViolation(
                "Apple clipboard size is out of range")
        }

        let messageEnd = base + headerSize + compressedLength
        guard messageEnd <= appleDecryptedRFBBuffer.endIndex else {
            return false
        }
        let compressed = Data(appleDecryptedRFBBuffer[
            base + headerSize..<messageEnd])
        appleDecryptedRFBBuffer.removeSubrange(base..<messageEnd)
        decodeApplePackedClipboard(
            compressed,
            uncompressedLength: uncompressedLength)
        return true
    }

    private func configureAppleMediaComCryptionIfPresent(_ payload: Data) throws {
        guard isAppleMediaComCryptionTransition(payload) else { return }

        let base = payload.startIndex
        let encryptedKey = Data(payload[base + 4..<base + 20])
        let encryptedIV = Data(payload[base + 20..<base + 36])
        guard !encryptedKey.allSatisfy({ $0 == 0 }),
              !encryptedIV.allSatisfy({ $0 == 0 }) else {
            return
        }

        try ensureAppleEncryptedControlChannel()
        guard let channel = appleEncryptedControlChannel else {
            throw VNCProtocolError.protocolViolation(
                "Apple encrypted channel is unavailable")
        }
        let key = try channel.decryptECBBlock(encryptedKey)
        let iv = try channel.decryptECBBlock(encryptedIV)
        applePreviousMediaComCryptionChannel = appleMediaComCryptionChannel
        applePreviousMediaServerPacketID = appleMediaServerPacketID
        appleMediaComCryptionChannel = try AppleComCryptionChannel(key: key, iv: iv)
        appleMediaServerPacketID = 0
        appleMediaClientPacketID = 0
        // Encrypted session: SRTP keys will follow on the control channel, so
        // early media datagrams must be buffered, not dropped as undecryptable.
        appleMediaExpectsSRTP = true
        log.debug("Configured Apple media ComCryption from 0x44f encryption info")
    }

    private nonisolated func isAppleMediaComCryptionTransition(_ payload: Data) -> Bool {
        guard payload.count >= 36 else { return false }
        let base = payload.startIndex
        let mode = UInt32(payload[base]) << 24
            | UInt32(payload[base + 1]) << 16
            | UInt32(payload[base + 2]) << 8
            | UInt32(payload[base + 3])
        return mode == 1
    }

    private func decryptAppleMediaComCryptionRecord(
        _ encryptedRecord: Data
    ) throws -> AppleComCryptionChannel.Record {
        if let previous = applePreviousMediaComCryptionChannel {
            do {
                let record = try previous.decryptRecord(
                    encryptedRecord,
                    expectedPacketID: applePreviousMediaServerPacketID)
                applePreviousMediaServerPacketID = record.packetID &+ 1
                return record
            } catch {
                // Old-channel records are contiguous. Its first authentication
                // failure is the generation boundary; discard the now-advanced
                // CBC state and try the untouched replacement channel.
                applePreviousMediaComCryptionChannel = nil
            }
        }
        guard let channel = appleMediaComCryptionChannel else {
            throw VNCProtocolError.protocolViolation("Apple media ComCryption channel is unavailable")
        }

        let record = try channel.decryptRecord(encryptedRecord, expectedPacketID: appleMediaServerPacketID)
        appleMediaServerPacketID = record.packetID &+ 1
        return record
    }

    private nonisolated func dumpAppleMediaTCPChunkIfRequested(_ chunk: Data) {
        #if DEBUG
        guard let path = VNCDiagnostics.value(
            for: "ROOTSHELL_VNC_DUMP_MEDIA_TCP",
            environment: runtimeEnvironment) else { return }
        appendPrivateDiagnosticData(chunk, to: path)
        #endif
    }

    private nonisolated func dumpAppleMediaPlaintextIfRequested(_ payload: Data) {
        #if DEBUG
        guard let path = VNCDiagnostics.value(
            for: "ROOTSHELL_VNC_DUMP_MEDIA_PLAINTEXT",
            environment: runtimeEnvironment) else { return }
        appendPrivateDiagnosticData(payload, to: path)
        #endif
    }

    /// Append each decrypted server control record to a file, length-framed
    /// (4-byte big-endian length prefix + payload) so individual records can be
    /// split back out. Use to capture the exact server->client media-config
    /// records (0x451/0x455/0x456 and the AVC media message) from a real server.
    private nonisolated func dumpAppleMediaServerRecordIfRequested(_ payload: Data) {
        #if DEBUG
        guard let path = VNCDiagnostics.value(
            for: "ROOTSHELL_VNC_DUMP_SERVER_RECORDS",
            environment: runtimeEnvironment) else { return }
        let framed = appleMediaDumpFrame(direction: 0x53 /* 'S' */, payload: payload)
        appendPrivateDiagnosticData(framed, to: path)
        #endif
    }

    /// Frame a dumped media record: [dir:1][monotonic ns:8 BE][len:4 BE][payload].
    /// The timestamp lets the client- and server-record dumps be merge-sorted
    /// into the exact bidirectional wire order.
    private nonisolated func appleMediaDumpFrame(direction: UInt8, payload: Data) -> Data {
        let ts = DispatchTime.now().uptimeNanoseconds
        let count = UInt32(payload.count)
        var framed = Data([direction])
        for shift in stride(from: 56, through: 0, by: -8) {
            framed.append(UInt8((ts >> UInt64(shift)) & 0xff))
        }
        for shift in [24, 16, 8, 0] {
            framed.append(UInt8((count >> UInt32(shift)) & 0xff))
        }
        framed.append(payload)
        return framed
    }

    /// Append each outgoing client media record (plaintext, before encryption)
    /// to a file, length-framed, so the full bidirectional media negotiation
    /// order can be reconstructed alongside the server-record dump.
    private nonisolated func dumpAppleMediaClientRecordIfRequested(_ payload: Data) {
        #if DEBUG
        guard let path = VNCDiagnostics.value(
            for: "ROOTSHELL_VNC_DUMP_CLIENT_RECORDS",
            environment: runtimeEnvironment) else { return }
        let framed = appleMediaDumpFrame(direction: 0x43 /* 'C' */, payload: payload)
        appendPrivateDiagnosticData(framed, to: path)
        #endif
    }

    private func tryAppleMediaBlockStreamDecrypt(
        channel: AESCBCChannel
    ) -> (plaintextPrefix: Data, diagnostic: String)? {
        guard appleMediaControlBuffer.count >= 32 else { return nil }

        for offset in 0..<min(16, appleMediaControlBuffer.count) {
            let start = appleMediaControlBuffer.startIndex + offset
            let candidateLength = appleMediaControlBuffer.endIndex - start
            guard candidateLength >= 32, candidateLength % 16 == 0 else { continue }

            let encrypted = Data(appleMediaControlBuffer[start..<appleMediaControlBuffer.endIndex])
            guard let plaintext = try? channel.decryptNoPadding(encrypted) else { continue }

            let candidatePackets = extractAppleMediaRTPPackets(from: plaintext)
            let packets = confirmedAppleMediaRTPPackets(from: candidatePackets)
            for packet in packets {
                emitAppleMediaRTPPacket(packet)
            }

            let diagnostic = describeAppleMediaPlaintext(plaintext)
                ?? "plaintext scan: \(plaintext.count) bytes"
            if !packets.isEmpty {
                appleMediaControlBuffer.removeSubrange(
                    appleMediaControlBuffer.startIndex..<appleMediaControlBuffer.endIndex)
                return (Data(plaintext.prefix(64)), "block stream offset=\(offset) \(diagnostic)")
            }

            if looksLikeAppleMediaPlaintext(plaintext) {
                return (Data(plaintext.prefix(64)), "block stream offset=\(offset) \(diagnostic)")
            }
        }

        return nil
    }

    private func pendingAppleEncryptedRecordLength() -> Int? {
        guard appleMediaControlBuffer.count >= 2 else { return nil }
        let base = appleMediaControlBuffer.startIndex
        let length = Int(UInt16(appleMediaControlBuffer[base]) << 8
            | UInt16(appleMediaControlBuffer[base + 1]))
        guard length >= 32, length % 16 == 0 else { return nil }
        let totalLength = 2 + length
        return appleMediaControlBuffer.count < totalLength ? totalLength : nil
    }

    private func looksLikeAppleMediaPlaintext(_ data: Data) -> Bool {
        guard data.count >= 12 else { return false }
        let bytes = [UInt8](data.prefix(min(data.count, 512)))
        for offset in bytes.indices where offset + 12 <= bytes.count {
            if bytes[offset] == 0x80 || bytes[offset] == 0x90 {
                let payloadType = bytes[offset + 1] & 0x7F
                if payloadType >= 96 {
                    return true
                }
            }
        }
        return false
    }

    private func nextAppleEncryptedControlRecord() -> Data? {
        while appleMediaControlBuffer.count >= 2 {
            let base = appleMediaControlBuffer.startIndex
            let length = Int(UInt16(appleMediaControlBuffer[base]) << 8
                | UInt16(appleMediaControlBuffer[base + 1]))

            guard length >= 32,
                  length <= UInt16.max,
                  length % 16 == 0 else {
                return nil
            }

            let recordEnd = base + 2 + length
            guard recordEnd <= appleMediaControlBuffer.endIndex else {
                return nil
            }

            let encrypted = Data(appleMediaControlBuffer[base + 2..<recordEnd])
            appleMediaControlBuffer.removeSubrange(base..<recordEnd)
            return encrypted
        }

        return nil
    }

    private func describeAppleMediaEncryptedBuffer() -> String {
        guard !appleMediaControlBuffer.isEmpty else {
            return "encrypted stream scan: empty buffer"
        }

        let bytes = [UInt8](appleMediaControlBuffer.prefix(min(appleMediaControlBuffer.count, 2048)))
        let firstU16: String
        if bytes.count >= 2 {
            let value = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
            firstU16 = "\(value)"
        } else {
            firstU16 = "n/a"
        }

        let firstU32: String
        if bytes.count >= 4 {
            let value = UInt32(bytes[0]) << 24
                | UInt32(bytes[1]) << 16
                | UInt32(bytes[2]) << 8
                | UInt32(bytes[3])
            firstU32 = "\(value)"
        } else {
            firstU32 = "n/a"
        }

        var rawRTPOffsets: [String] = []
        for offset in bytes.indices where offset + 12 <= bytes.count && (bytes[offset] == 0x80 || bytes[offset] == 0x90) {
            let payloadType = bytes[offset + 1] & 0x7F
            if payloadType >= 96 {
                let sequence = UInt16(bytes[offset + 2]) << 8 | UInt16(bytes[offset + 3])
                rawRTPOffsets.append("@\(offset):pt=\(payloadType),seq=\(sequence)")
                if rawRTPOffsets.count == 4 { break }
            }
        }

        return "encrypted stream scan: buffered=\(appleMediaControlBuffer.count) "
            + "firstU16=\(firstU16) firstU32=\(firstU32) "
            + "blockAligned=\(appleMediaControlBuffer.count % 16 == 0) "
            + "rawRTP=\(rawRTPOffsets.isEmpty ? "none" : rawRTPOffsets.joined(separator: ";"))"
    }

    private func describeAppleMediaPlaintext(_ data: Data) -> String? {
        if let mediaControlDescription = describeAppleAVCMediaControlPlaintext(data) {
            return mediaControlDescription
        }
        if let control = appleMediaServerControl(data) {
            return "Apple media server control: encoding=0x\(String(control.encoding, radix: 16)) bodyLength=\(control.body.count)"
        }
        if let shortControlDescription = describeAppleMediaShortControlPayload(data) {
            return shortControlDescription
        }

        guard data.count >= 12 else {
            return "plaintext scan: too short for RTP"
        }

        let bytes = [UInt8](data.prefix(min(data.count, 2048)))
        var rtpOffsets: [String] = []
        for offset in bytes.indices where offset + 12 <= bytes.count && (bytes[offset] & 0xC0) == 0x80 {
            let payloadType = bytes[offset + 1] & 0x7F
            let sequence = UInt16(bytes[offset + 2]) << 8 | UInt16(bytes[offset + 3])
            let timestamp = UInt32(bytes[offset + 4]) << 24
                | UInt32(bytes[offset + 5]) << 16
                | UInt32(bytes[offset + 6]) << 8
                | UInt32(bytes[offset + 7])
            rtpOffsets.append("@\(offset):pt=\(payloadType),seq=\(sequence),ts=\(timestamp)")
            if rtpOffsets.count == 4 { break }
        }

        var framedOffsets: [String] = []
        for offset in bytes.indices {
            if offset + 2 + 12 <= bytes.count {
                let length = Int(UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1]))
                let start = offset + 2
                if length >= 12,
                   start + length <= bytes.count,
                   (bytes[start] & 0xC0) == 0x80 {
                    framedOffsets.append("u16@\(offset):len=\(length)")
                }
            }
            if offset + 4 + 12 <= bytes.count {
                let length = Int(UInt32(bytes[offset]) << 24
                    | UInt32(bytes[offset + 1]) << 16
                    | UInt32(bytes[offset + 2]) << 8
                    | UInt32(bytes[offset + 3]))
                let start = offset + 4
                if length >= 12,
                   length <= 4096,
                   start + length <= bytes.count,
                   (bytes[start] & 0xC0) == 0x80 {
                    framedOffsets.append("u32@\(offset):len=\(length)")
                }
            }
            if framedOffsets.count == 4 { break }
        }

        var parts = ["plaintext scan: \(data.count) bytes"]
        parts.append("rtpOffsets=\(rtpOffsets.isEmpty ? "none" : rtpOffsets.joined(separator: ";"))")
        parts.append("framed=\(framedOffsets.isEmpty ? "none" : framedOffsets.joined(separator: ";"))")
        return parts.joined(separator: " ")
    }

    private nonisolated func describeAppleMediaShortControlPayload(_ data: Data) -> String? {
        guard data.count == 8 else { return nil }
        let bytes = [UInt8](data)
        let messageType = bytes[0]
        guard messageType == 0x14 else { return nil }

        let field1 = UInt16(bytes[2]) << 8 | UInt16(bytes[3])
        let field2 = UInt16(bytes[4]) << 8 | UInt16(bytes[5])
        let field3 = UInt16(bytes[6]) << 8 | UInt16(bytes[7])
        return "Apple media short control: type=0x14 field1=\(field1) field2=\(field2) field3=\(field3)"
    }

    private func describeAppleAVCMediaControlPlaintext(_ data: Data) -> String? {
        guard data.count >= 36 else { return nil }

        let plistMagic = Data("bplist00".utf8)
        let plistOffsets = ranges(of: plistMagic, in: data).map(\.lowerBound)
        guard !plistOffsets.isEmpty else { return nil }

        let firstPlistOffset = plistOffsets[0]
        let messageType = readUInt16BE(data, at: firstPlistOffset - 18)
        let streamCount = readUInt16BE(data, at: firstPlistOffset - 16)
        let prefixLength = readUInt16BE(data, at: 0)

        var parts = [
            "AVC media control: \(data.count) bytes",
            "prefixLength=\(prefixLength.map(String.init) ?? "n/a")",
            "messageType=\(messageType.map(String.init) ?? "n/a")",
            "streams=\(streamCount.map(String.init) ?? "n/a")",
            "plistOffsets=\(plistOffsets.map(String.init).joined(separator: ","))",
        ]

        var parsedEnd = data.startIndex
        for (index, offset) in plistOffsets.enumerated() {
            let upperBound = index + 1 < plistOffsets.count ? plistOffsets[index + 1] : data.endIndex
            guard let range = validPropertyListRange(in: data, from: offset, upperBound: upperBound) else {
                parts.append("plist\(index)=invalid")
                continue
            }
            parsedEnd = max(parsedEnd, range.upperBound)
            parts.append("plist\(index)=\(describeAVCAnswerPlist(Data(data[range])))")
        }

        if parsedEnd < data.endIndex {
            parts.append("trailerBytes=\(data.distance(from: parsedEnd, to: data.endIndex))")
        }

        return parts.joined(separator: " ")
    }

    private func isAppleAVCMediaAnswerPayload(_ data: Data) -> Bool {
        guard data.count >= 36 else { return false }
        let plistMagic = Data("bplist00".utf8)
        guard let firstPlistOffset = ranges(of: plistMagic, in: data).first?.lowerBound,
              let messageType = readUInt16BE(data, at: firstPlistOffset - 18) else {
            return false
        }
        return messageType == 2
    }

    private nonisolated func appleAVCMediaAnswerStreamLengths(_ payload: Data) -> [Int]? {
        guard let message = findAppleAVCMediaMessage(in: payload),
              message.messageType == 2,
              let audio = readUInt16BE(message.body, at: 8),
              let video = readUInt16BE(message.body, at: 10),
              let video2 = readUInt16BE(message.body, at: 12) else {
            return nil
        }
        return [Int(audio), Int(video), Int(video2)]
    }

    private nonisolated func validPropertyListRange(
        in data: Data,
        from offset: Data.Index,
        upperBound: Data.Index
    ) -> Range<Data.Index>? {
        guard offset < upperBound else { return nil }
        if (try? PropertyListSerialization.propertyList(
            from: Data(data[offset..<upperBound]),
            options: [],
            format: nil
        )) != nil {
            return offset..<upperBound
        }

        var end = upperBound
        while data.distance(from: offset, to: end) >= 8 {
            if (try? PropertyListSerialization.propertyList(
                from: Data(data[offset..<end]),
                options: [],
                format: nil
            )) != nil {
                return offset..<end
            }
            end = data.index(before: end)
        }
        return nil
    }

    private nonisolated func describeAVCAnswerPlist(_ data: Data) -> String {
        guard let plist = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any] else {
            return "invalidPlist(\(data.count) bytes)"
        }

        let mediaBlobLength = (plist["avcMediaStreamNegotiatorMediaBlob"] as? Data)?.count
        let endpointLength = (plist["avcMediaStreamOptionRemoteEndpointInfo"] as? Data)?.count
        let mode = plist["avcMediaStreamNegotiatorMode"] as? Int
        var fields: [String] = ["plistBytes=\(data.count)"]
        if let mediaBlobLength { fields.append("mediaBlob=\(mediaBlobLength)") }
        if let endpointLength { fields.append("endpoint=\(endpointLength)") }
        if let mode { fields.append("mode=\(mode)") }
        return fields.joined(separator: ",")
    }

    private nonisolated func ranges(of needle: Data, in haystack: Data) -> [Range<Data.Index>] {
        guard !needle.isEmpty, haystack.count >= needle.count else { return [] }
        var ranges: [Range<Data.Index>] = []
        var searchStart = haystack.startIndex
        while searchStart < haystack.endIndex,
              let range = haystack[searchStart..<haystack.endIndex].range(of: needle) {
            ranges.append(range)
            searchStart = range.lowerBound + 1
        }
        return ranges
    }

    private nonisolated func readUInt16BE(_ data: Data, at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 1 < data.count else { return nil }
        let index = data.startIndex + offset
        return UInt16(data[index]) << 8 | UInt16(data[index + 1])
    }

    private func confirmedAppleMediaRTPPackets(from packets: [Data]) -> [Data] {
        var confirmedPackets: [Data] = []

        for packet in packets {
            guard let header = parseAppleMediaRTPHeader(packet) else { continue }

            if var stream = confirmedAppleMediaRTPStream {
                guard header.ssrc == stream.ssrc,
                      header.payloadType == stream.payloadType,
                      isPlausibleNextRTPSequence(header.sequenceNumber, after: stream.lastSequenceNumber) else {
                    continue
                }

                stream.lastSequenceNumber = header.sequenceNumber
                confirmedAppleMediaRTPStream = stream
                confirmedPackets.append(packet)
                continue
            }

            if var pending = pendingAppleMediaRTPStream,
               header.ssrc == pending.ssrc,
               header.payloadType == pending.payloadType,
               isPlausibleNextRTPSequence(header.sequenceNumber, after: pending.lastSequenceNumber) {
                pending.lastSequenceNumber = header.sequenceNumber
                pending.packets.append(packet)

                if pending.packets.count >= 2 {
                    confirmedAppleMediaRTPStream = ConfirmedAppleMediaRTPStream(
                        payloadType: pending.payloadType,
                        ssrc: pending.ssrc,
                        lastSequenceNumber: pending.lastSequenceNumber
                    )
                    confirmedPackets.append(contentsOf: pending.packets)
                    pendingAppleMediaRTPStream = nil
                } else {
                    pendingAppleMediaRTPStream = pending
                }
            } else {
                pendingAppleMediaRTPStream = PendingAppleMediaRTPStream(
                    payloadType: header.payloadType,
                    ssrc: header.ssrc,
                    lastSequenceNumber: header.sequenceNumber,
                    packets: [packet]
                )
            }
        }

        return confirmedPackets
    }

    private func isPlausibleNextRTPSequence(_ sequence: UInt16, after previous: UInt16) -> Bool {
        let distance = sequence &- previous
        return distance > 0 && distance < 256
    }

    private func extractAppleMediaRTPPackets(from data: Data) -> [Data] {
        if looksLikeRTPPacket(data) {
            return [data]
        }

        for offset in 0...min(16, data.count) {
            let start = data.startIndex + offset
            if let packets = parseLengthPrefixedAppleMediaPackets(data[start..<data.endIndex], lengthByteCount: 2),
               !packets.isEmpty {
                return packets
            }
            if let packets = parseLengthPrefixedAppleMediaPackets(data[start..<data.endIndex], lengthByteCount: 4),
               !packets.isEmpty {
                return packets
            }
        }

        return []
    }

    private func parseLengthPrefixedAppleMediaPackets(
        _ slice: Data.SubSequence,
        lengthByteCount: Int
    ) -> [Data]? {
        guard lengthByteCount == 2 || lengthByteCount == 4 else { return nil }

        var packets: [Data] = []
        var offset = slice.startIndex

        while offset < slice.endIndex {
            guard offset + lengthByteCount <= slice.endIndex else { return nil }

            let length: Int
            if lengthByteCount == 2 {
                length = Int(UInt16(slice[offset]) << 8 | UInt16(slice[offset + 1]))
            } else {
                length = Int(UInt32(slice[offset]) << 24
                    | UInt32(slice[offset + 1]) << 16
                    | UInt32(slice[offset + 2]) << 8
                    | UInt32(slice[offset + 3]))
            }

            guard length >= 12, length <= 16_384 else { return nil }
            let packetStart = offset + lengthByteCount
            let packetEnd = packetStart + length
            guard packetEnd <= slice.endIndex else { return nil }

            let packet = Data(slice[packetStart..<packetEnd])
            guard looksLikeRTPPacket(packet) else { return nil }
            packets.append(packet)
            offset = packetEnd
        }

        return offset == slice.endIndex ? packets : nil
    }

    private func looksLikeRTPPacket(_ data: Data) -> Bool {
        parseAppleMediaRTPHeader(data) != nil
    }

    private func parseAppleMediaRTPHeader(_ data: Data) -> AppleMediaRTPHeader? {
        guard data.count >= 12 else { return nil }
        let base = data.startIndex
        // This RTP/SRTP profile uses the minimal RTP header
        // (`0x80`) and payload type in the dynamic/video range. A loose
        // version-bit check has too many false positives in encrypted media.
        guard data[base] == 0x80 || data[base] == 0x90 else { return nil }

        let csrcCount = Int(data[base] & 0x0F)
        let hasExtension = (data[base] >> 4) & 0x01 == 1
        let payloadType = data[base + 1] & 0x7F
        guard payloadType >= 96 else { return nil }

        var payloadOffset = 12 + csrcCount * 4
        guard data.count >= payloadOffset else { return nil }

        if hasExtension {
            guard data.count >= payloadOffset + 4 else { return nil }
            let extensionLength = Int(UInt16(data[base + payloadOffset + 2]) << 8
                | UInt16(data[base + payloadOffset + 3]))
            payloadOffset += 4 + extensionLength * 4
            guard data.count >= payloadOffset else { return nil }
        }

        guard data.count > payloadOffset else { return nil }

        let sequenceNumber = UInt16(data[base + 2]) << 8
            | UInt16(data[base + 3])
        let timestamp = UInt32(data[base + 4]) << 24
            | UInt32(data[base + 5]) << 16
            | UInt32(data[base + 6]) << 8
            | UInt32(data[base + 7])
        let ssrc = UInt32(data[base + 8]) << 24
            | UInt32(data[base + 9]) << 16
            | UInt32(data[base + 10]) << 8
            | UInt32(data[base + 11])

        return AppleMediaRTPHeader(
            payloadType: payloadType,
            sequenceNumber: sequenceNumber,
            timestamp: timestamp,
            ssrc: ssrc,
            marker: (data[base + 1] & 0x80) != 0
        )
    }

    private func emitAppleMediaControlDiagnostic(
        encryptedLength: Int,
        encryptedPrefix: Data,
        plaintextPrefix: Data?,
        decryptError: String?
    ) {
        guard emittedAppleMediaControlDiagnostics < 8 else { return }
        emittedAppleMediaControlDiagnostics += 1
        continuation?.yield(.appleMediaControlRecord(
            encryptedLength: encryptedLength,
            encryptedPrefix: encryptedPrefix,
            plaintextPrefix: plaintextPrefix,
            decryptError: decryptError
        ))
    }

    /// Execute an action without throwing, swallowing any errors.
    /// Used in contexts where we cannot propagate errors (e.g., disconnect, bell).
    private func executeActionNoThrow(_ action: ConnectionAction) async {
        do {
            try await executeAction(action)
        } catch {
            log.error("Action execution failed (non-throwing context): \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers

    private func emitState() {
        continuation?.yield(.stateChanged(stateMachine.state))
    }

    private func configuredAppleMediaUDPPort() -> UInt16? {
        guard let value = runtimeEnvironment["ROOTSHELL_VNC_MEDIA_LOCAL_UDP_PORT"],
               let port = UInt16(value) else {
            return nil
        }
        return port
    }

    private func appleMediaConfigurationUDPPort() -> UInt16 {
        configuredAppleMediaUDPPort() ?? 5900
    }

    private func configureAppleMediaUDP(for offer: AppleMediaStreamOffer) async throws {
        if let overridePort = configuredAppleMediaUDPPort() {
            try await startAppleMediaStreamUDPIfNeeded(bindings: [
                AppleMediaUDPBinding(localPort: overridePort, remotePort: overridePort)
            ])
            return
        }

        let remotePorts = isAppleMediaComCryptionTransition(offer.rawPayload)
            ? []
            : uniqueNonZeroPorts(
                offer.videoStream1UDPPort,
                offer.audioStreamUDPPort,
                offer.videoStream2UDPPort
            )
        let bindings = (remotePorts.isEmpty ? [5900] : remotePorts).map { remotePort in
            AppleMediaUDPBinding(
                localPort: remotePort,
                remotePort: remotePort
            )
        }
        if remotePorts.isEmpty {
            log.debug("Binding Apple media UDP on default port 5900")
        } else {
            log.debug("Binding Apple media UDP on offered ports \(remotePorts)")
        }
        try await startAppleMediaStreamUDPIfNeeded(bindings: bindings)
    }

    private nonisolated func uniqueNonZeroPorts(_ values: UInt16?...) -> [UInt16] {
        var ports: [UInt16] = []
        for value in values {
            guard let port = value, port != 0, !ports.contains(port) else { continue }
            ports.append(port)
        }
        return ports
    }

    private func appleMediaStreamConfiguration(localPort: UInt16) -> Data {
        var data = ClientMessage.appleMediaStreamConfiguration.serialize()
        guard let offsetValue = runtimeEnvironment["ROOTSHELL_VNC_MEDIA_CONFIG_PORT_OFFSET"],
              let offset = Int(offsetValue),
              offset >= 0,
              offset + 1 < data.count else {
            return data
        }

        data[offset] = UInt8((localPort >> 8) & 0xFF)
        data[offset + 1] = UInt8(localPort & 0xFF)
        log.debug("Patched Apple media configuration UDP port \(localPort) at byte offset \(offset)")
        return data
    }

    private func sendAppleMediaStreamSetupIfNeeded() async throws {
        guard !sentAppleMediaStreamConfiguration else { return }

        // VNC Authentication enters Pro Mode through encoding 1010 itself.
        // After the ClientInit/session-selection exchange,
        // the native viewer advertises its encodings and requests a frame; the
        // server then supplies AVC media message 1 in an encoding-1010
        // rectangle. The legacy 66-byte viewer-info message and 16-byte media
        // request belong to the keyed Apple authentication handshake. Sending
        // them here makes a password-only server reject the session before it
        // can emit message 1.
        if stateMachine.selectedSecurityType == .vncAuthentication {
            sentAppleMediaStreamConfiguration = true
            log.debug("Awaiting password-only Apple AVC media message 1")
            return
        }

        let mediaUDPPort = appleMediaConfigurationUDPPort()
        try await sendControlChannel(appleMediaStreamConfiguration(localPort: mediaUDPPort))
        try await sendControlChannel(ClientMessage.appleMediaStreamRequest.serialize())
        sentAppleMediaStreamConfiguration = true
        log.debug("Sent Apple media stream configuration and request udpPort=\(mediaUDPPort)")
    }

    /// Ask the server to restart the Apple media stream. Every stream offer
    /// bootstraps a fresh generation with parameter sets and an IRAP, so this
    /// is the recovery of last resort when the initial bootstrap was damaged
    /// on a server that never re-sends an IDR for FIR.
    public func restartAppleMediaStream() async {
        guard sentAppleMediaStreamConfiguration else { return }
        do {
            // Must go through the payload dispatcher, not the raw channel.
            // Once the media stream is accepted the control channel carries
            // length-framed ComCryption records, so writing a bare client
            // message into it desynchronizes the stream: the server does not
            // see a restart request, and may drop the session outright.
            // `sendClientPayload` picks plaintext or encrypted from
            // `acceptedAppleMediaStream`, which is exactly the distinction
            // that matters here, and matches how the equivalent
            // renegotiation request is sent.
            try await sendClientPayload(ClientMessage.appleMediaStreamRequest.serialize())
            log.warning("Re-requested Apple media stream (bootstrap recovery)")
        } catch {
            log.error("Could not re-request Apple media stream: \(error.localizedDescription)")
        }
    }

    private func sendAppleMediaServerConfigurationIfNeeded() async throws {
        guard !sentAppleMediaServerConfiguration else { return }

        let configuration = try appleMediaServerConfigurationMessage()
        if rateControlEnabled, appleMediaRateController == nil {
            appleMediaRateController = AppleMediaRateController(
                maxTargetBps: appleMediaRateControllerMaxBps,
                initialTargetBps: appleMediaNetworkProfile.initialCapacityBps)
        }
        rebuildAppleMediaSRTPContexts()
        try await sendAppleMediaControlPayload(configuration)
        sentAppleMediaServerConfiguration = true
        log.debug("Sent Apple media server configuration message length=\(configuration.count)")
    }

    private func appleMediaServerConfigurationMessage() throws -> Data {
        // Apple's compound media configuration requires a mode-8 receiver in
        // its first slot. This is a wire-protocol requirement, independent of
        // whether the client renders the received audio. Playback policy
        // belongs to VNCSession and must not change this offer: omitting or
        // disabling the slot causes the server to reject the whole compound
        // configuration, including UDP HEVC video.
        let generatedAudioOffer = try appleAVCMediaStreamOffer(mode: 8)
        let generatedVideoOffer = try appleAVCMediaStreamOffer(
            mode: 7,
            displayIndex: 0)
        let generatedVideo2Offer = appleMediaDisplayCount > 1
            ? try appleAVCMediaStreamOffer(mode: 7, displayIndex: 1)
            : nil
        let audioOffer = generatedAudioOffer.data
        let videoOffer = generatedVideoOffer.data
        let video2Offer = generatedVideo2Offer?.data

        // The FIR sender field uses the receiver's negotiated local RTP SSRC.
        // Using an unrelated random SSRC produces a valid
        // SRTCP packet that the server does not associate with this receiver.
        appleMediaAudioLocalSSRC = generatedAudioOffer.ssrc
        appleMediaVideoLocalSSRCs = [generatedVideoOffer.ssrc]
        if let generatedVideo2Offer {
            appleMediaVideoLocalSSRCs.append(generatedVideo2Offer.ssrc)
        }
        appleMediaLocalSSRC = generatedVideoOffer.ssrc
        log.debug(
            "Using negotiated screen receiver SSRCs "
                + appleMediaVideoLocalSSRCs.map { "0x\(String($0, radix: 16))" }
                    .joined(separator: ", ")
                + " for RTCP")
        let audioSendKey = try randomBytes(count: 46)
        let audioReceiveKey = try randomBytes(count: 46)
        let videoSendKey = try randomBytes(count: 46)
        let videoReceiveKey = try randomBytes(count: 46)
        let video2SendKey: Data? = video2Offer == nil ? nil : try randomBytes(count: 46)
        let video2ReceiveKey: Data? = video2Offer == nil ? nil : try randomBytes(count: 46)
        appleMediaSRTPKeys = AppleMediaSRTPKeys(
            audioViewerToServer: audioSendKey,
            audioServerToViewer: audioReceiveKey,
            videoViewerToServer: videoSendKey,
            videoServerToViewer: videoReceiveKey,
            video2ViewerToServer: video2SendKey,
            video2ServerToViewer: video2ReceiveKey
        )
        dumpAppleMediaSRTPKeysIfRequested(
            [audioSendKey, audioReceiveKey, videoSendKey, videoReceiveKey,
             video2SendKey ?? Data(), video2ReceiveKey ?? Data()])

        let fixedHeaderLength = 0xdc
        let video2Length = (video2Offer?.count ?? 0)
        let video2KeyLength = video2Offer == nil ? 0 : 92
        let totalLength = fixedHeaderLength + audioOffer.count + videoOffer.count + video2KeyLength + video2Length
        guard totalLength <= Int(UInt16.max) else {
            throw VNCProtocolError.protocolViolation("Apple media server configuration too large: \(totalLength)")
        }
        guard audioOffer.count <= Int(UInt16.max),
              videoOffer.count <= Int(UInt16.max),
              video2Length <= Int(UInt16.max) else {
            throw VNCProtocolError.protocolViolation("Apple media offer too large")
        }

        var message = Data(count: totalLength)
        message[0] = 0x1c
        writeUInt16BE(UInt16(totalLength - 4), into: &message, at: 2)
        writeUInt16BE(3, into: &message, at: 4)
        let receiverFlags = appleMediaReceiverFlags(
            displayCount: appleMediaDisplayCount,
            supports60FPS: requestedFrameRate >= 60,
            sendsCursor: serverRendersCursor)
        writeUInt32BE(receiverFlags, into: &message, at: 6)
        writeUInt16BE(UInt16(audioOffer.count), into: &message, at: 10)
        writeUInt16BE(UInt16(videoOffer.count), into: &message, at: 12)
        writeUInt16BE(UInt16(video2Length), into: &message, at: 14)

        let uuidBytes = UUID().bytes
        message.replaceSubrange(0x14..<0x24, with: uuidBytes)
        message.replaceSubrange(0x24..<0x52, with: audioSendKey)
        message.replaceSubrange(0x52..<0x80, with: audioReceiveKey)

        var offset = 0x80
        message.replaceSubrange(offset..<offset + audioOffer.count, with: audioOffer)
        offset += audioOffer.count
        message.replaceSubrange(offset..<offset + 46, with: videoSendKey)
        offset += 46
        message.replaceSubrange(offset..<offset + 46, with: videoReceiveKey)
        offset += 46
        message.replaceSubrange(offset..<offset + videoOffer.count, with: videoOffer)
        offset += videoOffer.count
        if let video2Offer, let video2SendKey, let video2ReceiveKey {
            message.replaceSubrange(offset..<offset + 46, with: video2SendKey)
            offset += 46
            message.replaceSubrange(offset..<offset + 46, with: video2ReceiveKey)
            offset += 46
            message.replaceSubrange(offset..<offset + video2Offer.count, with: video2Offer)
        }
        log.debug(
            "Apple media receiver flags=0x\(String(receiverFlags, radix: 16)) "
                + "client=RemoteDesktopScreenSharing displays=\(appleMediaDisplayCount) "
                + "targetFPS=\(requestedFrameRate)")
        return message
    }

    private struct GeneratedAppleMediaOffer {
        let data: Data
        let ssrc: UInt32
    }

    private func appleAVCMediaStreamOffer(
        mode: Int,
        displayIndex: Int? = nil
    ) throws -> GeneratedAppleMediaOffer {
        // Mode 8 is Apple's system-audio profile and mode 7 is its screen-video
        // profile. Full Quality is not another media mode; it leaves AVC and
        // requests lossless RFB encodings.
        var negotiatorMode = mode
        if mode != 8, let override = runtimeEnvironment["ROOTSHELL_VNC_AVC_MODE"]
            .flatMap(Int.init) {
            negotiatorMode = override
        }

        let random = try randomBytes(count: 4)
        var ssrc = random.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        if ssrc == 0 { ssrc = 1 }
        let displayInfo = displayIndex.flatMap { index in
            appleMediaDisplayInfos.indices.contains(index)
                ? appleMediaDisplayInfos[index]
                : nil
        }
        let profileWidth = displayInfo.map { UInt16(clamping: $0.width) }
            ?? fbWidth
        let profileHeight = displayInfo.map { UInt16(clamping: $0.height) }
            ?? fbHeight
        let profile = AppleMediaNegotiationProfile(
            framebufferWidth: profileWidth,
            framebufferHeight: profileHeight,
            supportsHDR: appleMediaSupportsHDR,
            tilesPerFrame: UInt64(selectedAppleMediaTilesPerFrame(
                pixelWidth: Int(profileWidth),
                pixelHeight: Int(profileHeight)))
        )
        log.debug(
            "Generated Apple media \(mode == 8 ? "audio" : "screen") offer "
                + "ssrc=\(ssrc) aspect=\(profile.aspectRatio.landscapeWidth)/"
                + "\(profile.aspectRatio.landscapeHeight) "
                + "display=\(displayIndex.map { String($0 + 1) } ?? "audio") "
                + "hdr=\(appleMediaSupportsHDR) tiles=\(profile.tilesPerFrame)"
        )
        let data = try profile.makeOffer(
            kind: mode == 8 ? .audio : .screen,
            mode: negotiatorMode,
            ssrc: ssrc,
            ntpTimestamp: AppleMediaNegotiationProfile.ntpTimestamp()
        )
        return GeneratedAppleMediaOffer(data: data, ssrc: ssrc)
    }

    private func selectedAppleMediaTilesPerFrame(
        pixelWidth: Int,
        pixelHeight: Int
    ) -> Int {
        if let override = appleMediaTilesPerFrameOverride,
           (1...4).contains(override) {
            return Int(override)
        }
        if pixelWidth > 0, pixelHeight > 0,
           pixelWidth <= Int.max / pixelHeight {
            let selectedDisplayLumaSamples = pixelWidth * pixelHeight
            return Int(AppleMediaVideoMode.negotiatedTilesPerFrame(
                totalLumaSamples: max(
                    selectedDisplayLumaSamples,
                    appleMediaActiveCaptureLumaSamples)))
        }
        return 4
    }

    private func randomBytes(count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw VNCProtocolError.ioError("SecRandomCopyBytes failed: \(status)")
        }
        return data
    }

    private func writeUInt16BE(_ value: UInt16, into data: inout Data, at offset: Int) {
        data[offset] = UInt8((value >> 8) & 0xff)
        data[offset + 1] = UInt8(value & 0xff)
    }

    private func writeUInt32BE(_ value: UInt32, into data: inout Data, at offset: Int) {
        data[offset] = UInt8((value >> 24) & 0xff)
        data[offset + 1] = UInt8((value >> 16) & 0xff)
        data[offset + 2] = UInt8((value >> 8) & 0xff)
        data[offset + 3] = UInt8(value & 0xff)
    }

    /// Server-offered media ports override, e.g. `ROOTSHELL_VNC_MEDIA_PORTS=5900,5901`.
    private nonisolated func configuredAppleMediaPortOverride() -> [UInt16]? {
        guard let value = runtimeEnvironment["ROOTSHELL_VNC_MEDIA_PORTS"] else {
            return nil
        }
        let ports = value.split(separator: ",").compactMap { UInt16($0.trimmingCharacters(in: .whitespaces)) }
        return ports.isEmpty ? nil : ports
    }

    /// Detect the server's AVC media message (`0x3f2` pseudo-rectangle) inside a
    /// decrypted ComCryption payload. Message type 1 carries the server's per-
    /// stream UDP ports; when present we (re)open the media UDP sockets to those
    /// ports. Returns true if a type-1 message was consumed.
    private func handleAppleAVCServerMediaMessageIfPresent(_ payload: Data) async throws -> Bool {
        guard let message = findAppleAVCMediaMessage(in: payload) else { return false }
        guard message.messageType == 1 else { return false }

        let isPasswordOnlyBootstrap = !acceptedAppleMediaStream
            && stateMachine.selectedSecurityType == .vncAuthentication

        guard let transition = appleMediaGenerationTracker.beginMessageOne() else {
            log.warning("Ignoring duplicate AVC media message 1 while its answer is pending")
            return true
        }
        beginAppleMediaGeneration(transition)

        // VNC Authentication (type 2) does not have the earlier encrypted
        // RFBMediaStreamOffer/Answer exchange. Its encoding-1010 message 1 is
        // the point at which the native viewer enters High Performance mode.
        // Keep the ordinary RFB stream in that mode while the AVC messages and
        // UDP media negotiation continue in plaintext.
        if !acceptedAppleMediaStream {
            acceptedAppleMediaStream = true
            emittedAppleMediaControlDiagnostics = 0
            appleMediaServerPacketID = 0
            appleMediaClientPacketID = 0
        }

        let ports = configuredAppleMediaPortOverride() ?? appleMediaServerPorts(from: message.body)
        guard !ports.isEmpty else {
            log.debug("Server AVC media type-1 had no usable UDP ports (body=\(message.body.count) bytes)")
            return true
        }

        let bindings = ports.map { AppleMediaUDPBinding(localPort: $0, remotePort: $0) }
        log.debug("Server AVC media type-1 offered UDP ports \(ports); opening symmetric sockets")
        try await startAppleMediaStreamUDPIfNeeded(bindings: bindings)

        if isPasswordOnlyBootstrap {
            // Keyed Apple authentication publishes an earlier encoding-1103
            // RFBMediaStreamOffer, which is what creates VNCSession's decoder
            // and installs its direct RTP sink. Password-only authentication
            // enters the same media protocol at encoding 1010 message 1 and
            // never sends 1103. Publish the equivalent semantic event here;
            // without it transport successfully receives/decrypts RTP while
            // the UI remains at "Waiting for first screen update" forever.
            let audioPort = ports.first
            let videoPort = ports.count > 1 ? ports[1] : ports.first
            let offer = AppleMediaStreamOffer(
                streamID: 0,
                codecType: 0x6876_6331, // 'hvc1'
                width: UInt32(fbWidth),
                height: UInt32(fbHeight),
                frameRate: UInt32(clamping: requestedFrameRate),
                rawPayload: message.body,
                messageVersion: 1,
                messageType: 1,
                audioStreamUDPPort: audioPort,
                videoStream1UDPPort: videoPort,
                videoStreamDisplayCount: appleMediaDisplayCount)
            continuation?.yield(.mediaStreamOffer(offer))
            log.info("Published password-only Apple media offer for decoder startup")
        }

        // A type-1 AVC media message is the request for a fresh client media
        // configuration. The client must create its offers and keys, then
        // enqueue that configuration before message 2 arrives. Waiting
        // for the separate 0x456 control record happened to work at startup,
        // where it follows type 1 almost immediately, but a display resize
        // does not send 0x456 first: the server retransmits type 1 while it is
        // waiting for this response. Keep the 0x456 call site as an idempotent
        // compatibility path; this call owns the actual negotiation response.
        try await sendAppleMediaServerConfigurationIfNeeded()
        return true
    }

    /// Begin one message-1/answer media cycle. All fields reset here are
    /// scoped to the encoded media generation; the TCP/RFB connection, input
    /// path, UDP sockets, and installed RTP sink remain intact.
    private func beginAppleMediaGeneration(
        _ transition: AppleMediaNegotiationGenerationTracker.Transition
    ) {
        sentAppleMediaServerConfiguration = false
        sentAppleMediaPostAnswerViewerInfo = false
        sentAppleMediaInitialSetDisplay = false
        sentAppleMediaAutoFrameUpdate = false

        appleMediaRTPReorderFlushTask?.cancel()
        appleMediaRTPReorderFlushTask = nil
        appleMediaRTPReorderScheduledDeadlineNanos = nil
        appleMediaRTPReorderBuffer.reset()
        appleMediaLastVideoIngestNanos = 0
        appleMediaLastVideoReleaseNanos = 0
        pendingAppleMediaRTPStream = nil
        confirmedAppleMediaRTPStream = nil

        // Message 2 installs fresh keys. Clear the old contexts now so an
        // early new-generation IRAP is buffered instead of being rejected by
        // authentication against the previous generation's keys.
        appleMediaSRTPKeys = nil
        appleMediaSRTPContexts.removeAll(keepingCapacity: true)
        appleMediaSRTPContextBySSRC.removeAll(keepingCapacity: true)
        appleMediaFeedbackRoutes.removeAll(keepingCapacity: true)
        appleMediaFeedbackRouteByRemoteSSRC.removeAll(keepingCapacity: true)
        appleMediaAudioFeedbackRoute = nil
        appleMediaAudioRemoteSSRC = nil
        appleMediaAudioChannel = nil
        appleMediaAudioLocalSSRC = 0
        appleMediaVideoLocalSSRCs.removeAll(keepingCapacity: true)
        appleMediaExpectsSRTP = true
        appleMediaPreKeyDatagrams.removeAll(keepingCapacity: true)
        appleMediaUnprotectFailures = 0

        appleMediaVideoSSRCChannels.removeAll(keepingCapacity: true)
        appleMediaSentBootstrapVideoReceiverReport = false
        appleMediaLTRFrameCompletionTracker.reset()
        appleMediaLTRAcknowledgementsSinceDiagnostic = 0
        appleMediaReceptionStats.removeAll(keepingCapacity: true)
        appleMediaLastFrameLossFeedback.removeAll(keepingCapacity: true)
        appleMediaMostRecentFrameLossSSRC = nil
        appleMediaSenderReports.removeAll(keepingCapacity: true)
        appleMediaLastRTPEchoTimestampQ10 = 0
        appleRCTLPreviousRTPTimestamp = nil
        appleRCTLTotalPacketsReceived = 0
        appleRCTLAudioPacketsReceived = 0
        appleRCTLTotalBytesReceived = 0
        appleRCTLMaximumQueueDelayNanos = 0
        appleRCTLPacketsInterval = 0
        appleRCTLLostInterval = 0
        appleRCTLBurstLostInterval = 0
        appleRCTLLastDiagnosticNanos = 0
        appleMediaIngressPacketsSinceDiagnostic = 0
        appleMediaIngressProcessingNanosSinceDiagnostic = 0
        appleMediaIngressMaximumBatchSinceDiagnostic = 0
        // A display resize installs fresh media keys and SSRCs but does not
        // change the network path. Preserve the capacity learned by generation
        // one; resetting to the route prior here can immediately lose the new
        // generation's reference picture on a constrained path.
        if transition.isReconfiguration {
            appleMediaRateController?.resetMediaGenerationMeasurements()
        } else {
            appleMediaRateController = nil
        }
        appleLastKeyframeRequestNanos = 0
        appleMediaLocalSSRC = 0

        if transition.isReconfiguration {
            log.info(
                "Beginning in-session Apple media generation \(transition.generation)")
            appleMediaGenerationSink?(
                transition.generation,
                activeAppleMediaTilesPerFrame)
        }
    }

    /// Locate a `0x3f2` AVC media pseudo-rectangle body inside a payload.
    private nonisolated func findAppleAVCMediaMessage(in payload: Data) -> (messageType: UInt16, body: Data)? {
        let marker = Data([0x00, 0x00, 0x03, 0xf2])
        guard let markerRange = payload.range(of: marker) else { return nil }
        let lengthStart = markerRange.upperBound
        guard lengthStart + 2 <= payload.endIndex else { return nil }
        let bodyLength = Int(payload[lengthStart]) << 8 | Int(payload[lengthStart + 1])
        let bodyStart = lengthStart + 2
        let bodyEnd = bodyStart + bodyLength
        guard bodyLength >= 4, bodyEnd <= payload.endIndex else { return nil }
        let body = Data(payload[bodyStart..<bodyEnd])
        let messageType = UInt16(body[body.startIndex + 2]) << 8 | UInt16(body[body.startIndex + 3])
        return (messageType, body)
    }

    /// Extract plausible per-stream UDP ports from a type-1 media message body.
    /// The message variants place 16-bit ports at two stride schemes
    /// (0x08/0x0e/0x14 and 0x0a/0x10/0x16); collect every nonzero
    /// candidate so we bind whichever the server actually uses.
    private nonisolated func appleMediaServerPorts(from body: Data) -> [UInt16] {
        let candidateOffsets = [0x08, 0x0a, 0x0e, 0x10, 0x14, 0x16]
        var ports: [UInt16] = []
        for offset in candidateOffsets {
            guard offset + 1 < body.count else { continue }
            let index = body.startIndex + offset
            let port = UInt16(body[index]) << 8 | UInt16(body[index + 1])
            if port >= 1024, !ports.contains(port) {
                ports.append(port)
            }
        }
        return ports
    }

    private func startAppleMediaStreamUDPIfNeeded(bindings: [AppleMediaUDPBinding]) async throws {
        var requestedBindings: [AppleMediaUDPBinding] = []
        for binding in bindings where !requestedBindings.contains(binding) {
            requestedBindings.append(binding)
        }

        if appleMediaUDPBindings == requestedBindings {
            return
        }

        // Incremental update: KEEP channels whose binding is unchanged and only
        // add/remove the difference. The old full stop-and-restart (media setup
        // grows the binding set from [5900] to [5900, 5901] mid-handshake)
        // closed the video channel while the server's first media burst was in
        // flight and dropped whatever sat in its receive buffer. When a band's
        // startup IRAP was in that window — a timing race, so it struck
        // intermittently — that band stayed black or corrupt for the entire
        // session, because this stream NEVER sends another IRAP.
        var keptBindings: [AppleMediaUDPBinding] = []
        var keptChannels: [PosixUDPChannel] = []
        var keptTasks: [Task<Void, Never>] = []
        for (index, binding) in appleMediaUDPBindings.enumerated() {
            if requestedBindings.contains(binding) {
                keptBindings.append(binding)
                if index < udpChannels.count { keptChannels.append(udpChannels[index]) }
                if index < udpReadTasks.count { keptTasks.append(udpReadTasks[index]) }
            } else {
                if index < udpReadTasks.count { udpReadTasks[index].cancel() }
                if index < udpChannels.count {
                    let closing = udpChannels[index]
                    // Unbind any SSRC routed to the channel being closed.
                    for (ssrc, channel) in appleMediaVideoSSRCChannels where channel === closing {
                        appleMediaVideoSSRCChannels.removeValue(forKey: ssrc)
                    }
                    await closing.close()
                }
            }
        }
        udpChannels = keptChannels
        udpReadTasks = keptTasks
        appleMediaUDPBindings = keptBindings

        for binding in requestedBindings where !keptBindings.contains(binding) {
            appleMediaUDPBindings.append(binding)
            try await startAppleMediaUDPChannel(binding: binding)
        }
    }

    private func startAppleMediaUDPChannel(binding: AppleMediaUDPBinding) async throws {
        // Configure the symmetric-port media socket (address family follows
        // the selected media peer: normally TCP's exact numeric endpoint, or
        // TCP-family-constrained resolution for a Tailscale hostname):
        //   socket(family, DGRAM) + SO_REUSEADDR + SO_REUSEPORT
        //   + bind(wildcard:port) + connect(serverIP:port)
        // Symmetric RTP uses the same port both ends; SO_REUSEPORT is what lets
        // the viewer bind a UDP port the server already holds (loopback / same
        // machine). Network.framework does not reliably expose SO_REUSEPORT,
        // which is why the previous unconnected listener never received on
        // loopback.
        let channel: PosixUDPChannel
        if let datagramProvider {
            let fd = try await datagramProvider(
                appleMediaRemoteHost,
                binding.remotePort,
                binding.localPort ?? binding.remotePort)
            channel = PosixUDPChannel(
                adoptingConnectedDescriptor: fd,
                label: "\(appleMediaRemoteHost):\(binding.remotePort)")
        } else {
            channel = PosixUDPChannel(
                localPort: binding.localPort,
                remoteHost: appleMediaRemoteHost,
                remotePort: binding.remotePort,
                remoteAddressFamily: appleMediaRemoteAddressFamily,
                enableReusePort: true
            )
        }
        try await channel.start()
        udpChannels.append(channel)
        let actualPort = await channel.localPort ?? binding.localPort ?? 0
        continuation?.yield(.appleMediaUDPStarted(localPort: actualPort))
        log.debug("Started Apple media UDP localPort=\(actualPort) remotePort=\(binding.remotePort)")

        let readTask = Task { [weak self, channel] in
            while !Task.isCancelled {
                do {
                    let datagrams = try await channel.receiveDatagramBatch()
                    await self?.handleAppleMediaUDPDatagrams(
                        datagrams,
                        from: channel)
                } catch is CancellationError {
                    break
                } catch {
                    self?.log.warning("UDP media receive ended: \(error.localizedDescription)")
                    break
                }
            }
        }
        udpReadTasks.append(readTask)
    }

    /// Keep a socket-drain batch on this actor until every packet has been
    /// authenticated and delivered. This preserves wire order while amortizing
    /// actor scheduling across the hundreds of RTP fragments in a Retina tile.
    private func handleAppleMediaUDPDatagrams(
        _ datagrams: [PosixUDPDatagram],
        from channel: PosixUDPChannel
    ) {
        let processingStart = DispatchTime.now().uptimeNanoseconds
        for datagram in datagrams {
            handleAppleMediaUDPDatagram(
                datagram.data,
                arrivalNanos: datagram.arrivalNanos,
                from: channel)
        }
        let processingEnd = DispatchTime.now().uptimeNanoseconds
        appleMediaIngressPacketsSinceDiagnostic += datagrams.count
        appleMediaIngressProcessingNanosSinceDiagnostic &+= processingEnd &- processingStart
        appleMediaIngressMaximumBatchSinceDiagnostic = max(
            appleMediaIngressMaximumBatchSinceDiagnostic,
            datagrams.count)
    }

    private nonisolated func isLoopbackHost(_ host: String) -> Bool {
        host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    private func stopAppleMediaUDP() async {
        appleMediaRTPReorderFlushTask?.cancel()
        appleMediaRTPReorderFlushTask = nil
        appleMediaRTPReorderScheduledDeadlineNanos = nil
        appleMediaRTPReorderBuffer.reset()
        appleMediaPacketHandoff.reset()
        appleKeyframeRequestTask?.cancel()
        appleKeyframeRequestTask = nil
        appleRTCPReportTask?.cancel()
        appleRTCPReportTask = nil
        appleMediaAudioRTCPTask?.cancel()
        appleMediaAudioRTCPTask = nil
        appleRCTLFeedbackTask?.cancel()
        appleRCTLFeedbackTask = nil
        appleRCTLPacketsInterval = 0
        appleRCTLLostInterval = 0
        appleRCTLBurstLostInterval = 0
        appleRCTLLastDiagnosticNanos = 0
        appleMediaIngressPacketsSinceDiagnostic = 0
        appleMediaIngressProcessingNanosSinceDiagnostic = 0
        appleMediaIngressMaximumBatchSinceDiagnostic = 0
        appleMediaRateController = nil
        appleMediaLastRTPEchoTimestampQ10 = 0
        appleRCTLPreviousRTPTimestamp = nil
        appleRCTLTotalPacketsReceived = 0
        appleRCTLAudioPacketsReceived = 0
        appleRCTLTotalBytesReceived = 0
        appleRCTLMaximumQueueDelayNanos = 0
        appleMediaVideoSSRCChannels.removeAll()
        appleMediaSentBootstrapVideoReceiverReport = false
        appleMediaLTRFrameCompletionTracker.reset()
        appleMediaLTRAcknowledgementsSinceDiagnostic = 0
        appleMediaReceptionStats.removeAll()
        appleMediaSenderReports.removeAll()
        appleMediaLastFrameLossFeedback.removeAll()
        appleMediaMostRecentFrameLossSSRC = nil
        appleMediaPreKeyDatagrams.removeAll()
        appleMediaSRTPKeys = nil
        appleMediaSRTPContexts.removeAll()
        appleMediaSRTPContextBySSRC.removeAll()
        appleMediaFeedbackRoutes.removeAll()
        appleMediaFeedbackRouteByRemoteSSRC.removeAll()
        appleMediaAudioFeedbackRoute = nil
        appleMediaAudioLocalSSRC = 0
        appleMediaAudioRemoteSSRC = nil
        appleMediaAudioChannel = nil
        appleMediaVideoLocalSSRCs.removeAll()
        appleMediaLocalSSRC = 0
        appleLastKeyframeRequestNanos = 0
        for task in udpReadTasks {
            task.cancel()
        }
        udpReadTasks.removeAll()

        for channel in udpChannels {
            await channel.close()
        }
        udpChannels.removeAll()
        appleMediaUDPBindings.removeAll()
    }

    /// Build one SRTP receive context per server-to-viewer key so every media
    /// stream (audio, video, video2) can be decrypted; contexts are matched to
    /// packets by SSRC on first use.
    private func rebuildAppleMediaSRTPContexts() {
        guard let keys = appleMediaSRTPKeys else { return }
        appleMediaSRTPContexts.removeAll(keepingCapacity: true)
        appleMediaSRTPContextBySSRC.removeAll(keepingCapacity: true)
        appleMediaFeedbackRoutes.removeAll(keepingCapacity: true)
        appleMediaFeedbackRouteByRemoteSSRC.removeAll(keepingCapacity: true)

        func addVideoRoute(
            streamIndex: Int,
            serverToViewer: Data?,
            viewerToServer: Data?,
            localSSRC: UInt32?
        ) {
            guard let serverToViewer,
                  let viewerToServer,
                  let localSSRC,
                  serverToViewer.count >= 46,
                  viewerToServer.count >= 46,
                  let receiveContext = try? AppleSRTPContext(mediaKey: serverToViewer),
                  let sendRTCPContext = try? AppleSRTCPContext(mediaKey: viewerToServer),
                  let receiveRTCPContext = try? AppleSRTCPContext(mediaKey: serverToViewer)
            else { return }
            appleMediaSRTPContexts.append(receiveContext)
            appleMediaFeedbackRoutes.append(AppleMediaFeedbackRoute(
                receiveContext: receiveContext,
                sendRTCPContext: sendRTCPContext,
                receiveRTCPContext: receiveRTCPContext,
                localSSRC: localSSRC,
                streamIndex: streamIndex))
        }

        addVideoRoute(
            streamIndex: 1,
            serverToViewer: keys.videoServerToViewer,
            viewerToServer: keys.videoViewerToServer,
            localSSRC: appleMediaVideoLocalSSRCs.first)
        addVideoRoute(
            streamIndex: 2,
            serverToViewer: keys.video2ServerToViewer,
            viewerToServer: keys.video2ViewerToServer,
            localSSRC: appleMediaVideoLocalSSRCs.count > 1
                ? appleMediaVideoLocalSSRCs[1]
                : nil)

        if keys.audioServerToViewer.count >= 46,
           keys.audioViewerToServer.count >= 46,
           appleMediaAudioLocalSSRC != 0,
           let audioContext = try? AppleSRTPContext(mediaKey: keys.audioServerToViewer),
           let sendRTCPContext = try? AppleSRTCPContext(
                mediaKey: keys.audioViewerToServer),
           let receiveRTCPContext = try? AppleSRTCPContext(
                mediaKey: keys.audioServerToViewer) {
            appleMediaSRTPContexts.append(audioContext)
            appleMediaAudioFeedbackRoute = AppleMediaFeedbackRoute(
                receiveContext: audioContext,
                sendRTCPContext: sendRTCPContext,
                receiveRTCPContext: receiveRTCPContext,
                localSSRC: appleMediaAudioLocalSSRC,
                streamIndex: 0)
        }
        if appleMediaLocalSSRC == 0 {
            appleMediaLocalSSRC = generateAppleMediaLocalSSRC()
        }
        log.debug(
            "Configured \(appleMediaSRTPContexts.count) Apple media SRTP receive contexts, "
                + "videoFeedbackRoutes=\(appleMediaFeedbackRoutes.count)")

        // Replay any media that raced ahead of the keys, in arrival order.
        // This is what makes startup deterministic: the burst right after the
        // key record carries every band's ONLY IRAP, and losing any prefix of
        // it left that band dead for the whole session.
        if !appleMediaPreKeyDatagrams.isEmpty, !appleMediaSRTPContexts.isEmpty {
            let buffered = appleMediaPreKeyDatagrams
            appleMediaPreKeyDatagrams.removeAll()
            log.info("Replaying \(buffered.count) media datagrams buffered before SRTP keys arrived")
            for (datagram, channel) in buffered {
                handleAppleMediaUDPDatagram(
                    datagram,
                    // Waiting for the control-plane key record is not receiver
                    // congestion. Start arrival accounting when replay begins.
                    arrivalNanos: DispatchTime.now().uptimeNanoseconds,
                    from: channel)
            }
        }
    }

    private func generateAppleMediaLocalSSRC() -> UInt32 {
        guard let bytes = try? randomBytes(count: 4) else { return 0x5253_4801 }
        let base = bytes.startIndex
        var value: UInt32 = 0
        value = (value << 8) | UInt32(bytes[base])
        value = (value << 8) | UInt32(bytes[base + 1])
        value = (value << 8) | UInt32(bytes[base + 2])
        value = (value << 8) | UInt32(bytes[base + 3])
        return value
    }

    private var appleMediaFIRSeq: UInt8 = 0

    /// No-video-displayed recovery uses reduced-size PSFB FIR, followed by a
    /// reset of expected decoding order. Do not layer PLI and legacy FIR
    /// variants into the same packet; this profile uses RFC 5104 FIR.
    private func sendAppleMediaKeyframeRequest(mediaSSRC: UInt32, on channel: PosixUDPChannel) async {
        guard let route = appleMediaFeedbackRoute(forRemoteSSRC: mediaSSRC) else { return }
        let sender = route.localSSRC
        appleMediaFIRSeq &+= 1
        let packet = appleMediaFullIntraRequestPacket(
            senderSSRC: sender,
            mediaSSRC: mediaSSRC,
            sequenceNumber: appleMediaFIRSeq)

        guard let protected = try? route.sendRTCPContext.protect(
            packet,
            senderSSRC: sender) else { return }
        dumpAppleMediaOutgoingRTCPIfRequested(plaintext: packet, protected: protected)
        try? await channel.send(protected)
        log.warning("Sent native no-video-displayed FIR media ssrc=0x\(String(mediaSSRC, radix: 16)) "
            + "feedbackStream=\(route.streamIndex) sequence=\(self.appleMediaFIRSeq)")
    }


    /// Emit a media RTP packet (post-SRTP for UDP, post-extraction for TCP),
    /// optionally dumping the exact bytes the video decoder will receive.
    /// Install a fast-path sink for decrypted video RTP. Pass `nil` to revert to
    /// buffering packets until a new sink is installed.
    public func setAppleMediaRTPSink(_ sink: (@Sendable (Data) -> Void)?) {
        let routedSink: (@Sendable (Data, Int?) -> Void)?
        if let sink {
            routedSink = { packet, _ in
                sink(packet)
            }
        } else {
            routedSink = nil
        }
        setAppleMediaRoutedRTPSink(routedSink)
    }

    /// Install a media sink that also identifies which negotiated display owns
    /// each video packet. Audio packets have no display index.
    public func setAppleMediaRoutedRTPSink(
        _ sink: (@Sendable (Data, Int?) -> Void)?
    ) {
        let drained = appleMediaPacketHandoff.installSink(sink)
        if drained.packetCount > 0 {
            log.info("Drained \(drained.packetCount) ordered startup RTP packets "
                + "(\(drained.byteCount) bytes) into the media sink")
        }
        if drained.overflowed {
            log.error("Media startup buffer overflowed; dropped \(drained.droppedPacketCount) newest packets")
            requestAppleMediaRecoveryAfterIngressOverflow()
        }
    }

    /// Preserve the live control/media session across app suspension while
    /// teaching the RTP reorderer that the next sequence can legitimately be
    /// more than half a UInt16 space ahead.
    public func noteAppleMediaInterruption() {
        appleMediaRTPReorderFlushTask?.cancel()
        appleMediaRTPReorderFlushTask = nil
        appleMediaRTPReorderScheduledDeadlineNanos = nil
        appleMediaRTPReorderBuffer.markMediaInterruption()
        log.warning("Marked Apple media RTP stream interrupted; awaiting measured resume gap")
    }

    private func emitAppleMediaRTPPacket(_ packet: Data) {
        dumpAppleMediaDecodedRTPIfRequested(packet)
        let displayIndex = appleMediaRTPSSRC(packet)
            .flatMap { appleMediaFeedbackRouteByRemoteSSRC[$0] }
            .map { max(0, $0.streamIndex - 1) }
        if appleMediaPacketHandoff.deliver(
            packet,
            displayIndex: displayIndex
        ) == .overflow {
            log.error("Media ingress overflow while waiting for decoder sink")
        }
    }

    private func requestAppleMediaRecoveryAfterIngressOverflow() {
        requestAppleMediaKeyframeRateLimited()
        Task { [weak self] in
            try? await self?.requestFramebufferUpdate(incremental: false)
        }
    }

    private nonisolated func dumpAppleMediaOutgoingRTCPIfRequested(plaintext: Data, protected: Data) {
        #if DEBUG
        guard let path = appleMediaOutgoingRTCPDumpPath else { return }
        let line = "RTCP plaintext=\(plaintext.map { String(format: "%02x", $0) }.joined()) "
            + "protected=\(protected.map { String(format: "%02x", $0) }.joined())\n"
        if let data = line.data(using: .utf8) {
            appendPrivateDiagnosticData(data, to: path)
        }
        #endif
    }

    private nonisolated func dumpAppleMediaDecodedRTPIfRequested(_ packet: Data) {
        #if DEBUG
        guard let path = appleMediaDecodedRTPDumpPath else { return }
        var framed = Data()
        // Optional 8-byte big-endian nanosecond timestamp prefix for bitrate-over-
        // time analysis (ROOTSHELL_VNC_DUMP_RTP_TIMED=1).
        if appleMediaDecodedRTPDumpIncludesTimestamps {
            let t = DispatchTime.now().uptimeNanoseconds
            for shift in stride(from: 56, through: 0, by: -8) {
                framed.append(UInt8((t >> UInt64(shift)) & 0xFF))
            }
        }
        framed.append(UInt8((packet.count >> 8) & 0xFF))
        framed.append(UInt8(packet.count & 0xFF))
        framed.append(packet)
        appendPrivateDiagnosticData(framed, to: path)
        #endif
    }

    private func handleAppleMediaUDPDatagram(
        _ datagram: Data,
        arrivalNanos: UInt64,
        from channel: PosixUDPChannel
    ) {
        dumpAppleMediaUDPDatagramIfRequested(datagram)

        if isAppleMediaRTCPPacket(datagram) {
            handleAppleMediaServerSenderReport(
                datagram,
                arrivalNanos: arrivalNanos)
            continuation?.yield(.udpDatagram(datagram))
            return
        }

        guard let ssrc = appleMediaRTPSSRC(datagram) else {
            continuation?.yield(.udpDatagram(datagram))
            return
        }

        // STARTUP RACE: the server begins blasting the initial media burst —
        // parameter sets plus each band's one-and-only IRAP — immediately
        // after it sends the key control record, racing our processing of that
        // record. Any RTP that lands before the SRTP contexts exist used to be
        // undecryptable and lost; when a band's IRAP was in that prefix, the
        // band stayed dead/corrupt for the ENTIRE session (this stream never
        // repeats an IRAP), intermittently by pure timing. Buffer pre-key
        // datagrams and replay them in arrival order the moment keys arrive.
        if appleMediaSRTPContexts.isEmpty, appleMediaExpectsSRTP {
            if appleMediaPreKeyDatagrams.count >= 4096 {
                appleMediaPreKeyDatagrams.removeFirst()
            }
            appleMediaPreKeyDatagrams.append((datagram, channel))
            return
        }

        // Fast path: SSRC already bound to a context.
        if let context = appleMediaSRTPContextBySSRC[ssrc],
           let packet = try? context.unprotect(datagram) {
            bindAppleMediaFeedbackRouteIfAvailable(
                receiveContext: context,
                remoteSSRC: ssrc)
            acceptAppleMediaRTPPacket(
                packet,
                wireByteCount: datagram.count,
                arrivalNanos: arrivalNanos,
                from: channel)
            return
        }

        // Otherwise find the context whose key authenticates this SSRC.
        for context in appleMediaSRTPContexts {
            if let packet = try? context.unprotect(datagram) {
                appleMediaSRTPContextBySSRC[ssrc] = context
                bindAppleMediaFeedbackRouteIfAvailable(
                    receiveContext: context,
                    remoteSSRC: ssrc)
                acceptAppleMediaRTPPacket(
                    packet,
                    wireByteCount: datagram.count,
                    arrivalNanos: arrivalNanos,
                    from: channel)
                return
            }
        }

        // SRTP is configured but no key authenticates this packet: it is
        // ciphertext (or noise) and must NEVER travel toward the decoder —
        // VNCSession's .udpDatagram path used to feed these to the demuxer,
        // where the encrypted payload parsed as garbage NAL units and
        // permanently re-corrupted the video (~2 pkts/s on a live server).
        // Only a session with no SRTP contexts (plaintext/loopback debugging)
        // still forwards raw datagrams.
        if !appleMediaSRTPContexts.isEmpty {
            appleMediaUnprotectFailures &+= 1
            if appleMediaUnprotectFailures & 0xFF == 1 { // log 1st, then every 256th
                log.warning("Dropped undecryptable media datagram ssrc=0x\(String(ssrc, radix: 16)) "
                    + "count=\(self.appleMediaUnprotectFailures)")
            }
            return
        }

        acceptAppleMediaRTPPacket(
            datagram,
            wireByteCount: datagram.count,
            arrivalNanos: arrivalNanos,
            from: channel)
    }

    private func bindAppleMediaFeedbackRouteIfAvailable(
        receiveContext: AppleSRTPContext,
        remoteSSRC: UInt32
    ) {
        guard appleMediaFeedbackRouteByRemoteSSRC[remoteSSRC] == nil,
              let route = appleMediaFeedbackRoutes.first(where: {
                  $0.receiveContext === receiveContext
              }) else { return }
        appleMediaFeedbackRouteByRemoteSSRC[remoteSSRC] = route
        log.info(
            "Bound remote video ssrc=0x\(String(remoteSSRC, radix: 16)) "
                + "to feedback stream=\(route.streamIndex) localSSRC=0x"
                + String(route.localSSRC, radix: 16))
    }

    private func appleMediaFeedbackRoute(
        forRemoteSSRC remoteSSRC: UInt32
    ) -> AppleMediaFeedbackRoute? {
        appleMediaFeedbackRouteByRemoteSSRC[remoteSSRC]
            ?? appleMediaFeedbackRoutes.first
    }

    /// Test-only deterministic loss injection
    /// (`ROOTSHELL_VNC_TEST_DROP_VIDEO_AFTER_PACKETS=N` or `N:K`): after N
    /// accepted video packets, drop the next K (default 1), upstream of all
    /// reception bookkeeping, so the full native recovery chain runs as for
    /// real loss. A single dropped packet is healed silently by RTP
    /// retransmission; a burst defeats RTX and exercises confirmed-loss
    /// feedback plus keyframe recovery.
    private lazy var testVideoPacketDropCountdown: Int = {
        guard let spec = runtimeEnvironment[
            "ROOTSHELL_VNC_TEST_DROP_VIDEO_AFTER_PACKETS"] else { return Int.min }
        // One injection per process: a recovery reconnect must not be
        // re-damaged, or the recovery loop under test could never converge.
        guard !Self.testVideoPacketDropConsumed else { return Int.min }
        Self.testVideoPacketDropConsumed = true
        let parts = spec.split(separator: ":")
        if parts.count == 2, let after = Int(parts[0]), let burst = Int(parts[1]) {
            testVideoPacketDropBurst = max(1, burst)
            return after
        }
        return Int(spec) ?? Int.min
    }()
    private var testVideoPacketDropBurst = 1
    private nonisolated(unsafe) static var testVideoPacketDropConsumed = false

    /// Accept one decrypted RTP packet. Video packets pass through the bounded
    /// per-SSRC jitter buffer; non-video media can be delivered immediately.
    private func acceptAppleMediaRTPPacket(
        _ packet: Data,
        wireByteCount: Int,
        arrivalNanos: UInt64,
        from channel: PosixUDPChannel
    ) {
        guard let header = parseAppleMediaRTPHeader(packet) else { return }
        guard header.payloadType == 100 else {
            // The only non-video RTP source in this profile is remote audio.
            // Native acknowledges it with a one-source RR+empty-CNAME SDES
            // compound packet every second; without that heartbeat the sender
            // logs an RTCP timeout with a NaN last-receive timestamp.
            appleMediaAudioRemoteSSRC = header.ssrc
            appleMediaAudioChannel = channel
            if updateAppleMediaReceptionStats(
                ssrc: header.ssrc,
                sequence: header.sequenceNumber) {
                appleRCTLAudioPacketsReceived &+= 1
                appleRCTLTotalBytesReceived &+= UInt64(max(0, wireByteCount))
                startAppleMediaAudioRTCPFeedbackLoop()
            }
            emitAppleMediaRTPPacket(packet)
            return
        }
        if testVideoPacketDropCountdown != Int.min {
            if testVideoPacketDropCountdown > 0 {
                testVideoPacketDropCountdown -= 1
            } else {
                testVideoPacketDropBurst -= 1
                if testVideoPacketDropBurst <= 0 {
                    testVideoPacketDropCountdown = Int.min
                }
                log.warning("TEST loss injection: dropping video RTP packet pre-ingress "
                    + "(remaining burst \(max(0, testVideoPacketDropBurst)))")
                return
            }
        }

        let isNew = appleMediaVideoSSRCChannels[header.ssrc] == nil
        appleMediaVideoSSRCChannels[header.ssrc] = channel
        if isNew {
            log.info("First video RTP for ssrc=0x\(String(header.ssrc, radix: 16))")
        }
        let requiredInitialSources = activeAppleMediaTilesPerFrame
            * appleMediaDisplayCount
        if !completedInitialAppleMediaNegotiation,
           appleMediaVideoSSRCChannels.count >= requiredInitialSources {
            completedInitialAppleMediaNegotiation = true
            Task { [weak self] in
                await self?.applyStagedVirtualDisplayAfterInitialVideo()
            }
        }
        if let awaitedGeneration = appleDisplayReconfigurationGeneration,
           appleMediaGenerationTracker.generation >= awaitedGeneration,
           appleMediaVideoSSRCChannels.count
                >= activeAppleMediaTilesPerFrame * appleMediaDisplayCount {
            appleDisplayReconfigurationGeneration = nil
            if let pendingRemoteDisplaySize,
               pendingRemoteDisplaySize != lastSentRemoteDisplaySize {
                Task { [weak self] in
                    await self?.applyQueuedVirtualDisplayAfterMediaReady()
                }
            } else {
                emitAppleRemoteDisplayResizeSettled()
            }
        }

        let processingNanos = DispatchTime.now().uptimeNanoseconds
        let ingressQueueDelayNanos = processingNanos >= arrivalNanos
            ? processingNanos - arrivalNanos
            : 0
        let nowNanos = arrivalNanos
        let unique = updateAppleMediaReceptionStats(
            ssrc: header.ssrc,
            sequence: header.sequenceNumber)
        if unique {
            appleRCTLTotalPacketsReceived &+= 1
            appleRCTLTotalBytesReceived &+= UInt64(max(0, wireByteCount))
            appleRCTLMaximumQueueDelayNanos = max(
                appleRCTLMaximumQueueDelayNanos,
                ingressQueueDelayNanos)
            appleRCTLPacketsInterval += 1
            updateAppleRCTLEchoTimestamp(header.timestamp)
            startAppleTestFIRLoopIfRequested()
            startAppleRCTLFeedbackLoop()

            if rateControlEnabled {
                let controller = appleMediaRateController ?? {
                    let created = AppleMediaRateController(
                        maxTargetBps: appleMediaRateControllerMaxBps,
                        initialTargetBps: appleMediaNetworkProfile.initialCapacityBps)
                    appleMediaRateController = created
                    return created
                }()
                let now = Double(arrivalNanos) / 1_000_000_000
                controller.onVideoPacket(
                    ssrc: header.ssrc,
                    rtpTimestamp: header.timestamp,
                    bytes: wireByteCount,
                    endOfFrame: header.marker,
                    queueDelaySeconds: Double(ingressQueueDelayNanos) / 1_000_000_000,
                    now: now)
                controller.update(now: now)
            }

            // Wait until the complete compound source set is known. Apple's
            // client then emits three 58-byte RR+SDES packets for a four-tile
            // display: one for each source after the base (lowest) SSRC. Our
            // previous first-packet shortcut reported only the base tile,
            // leaving all dependent bands without their native bootstrap.
            if !appleMediaSentBootstrapVideoReceiverReport,
               appleMediaVideoSSRCChannels.count >= requiredInitialSources {
                appleMediaSentBootstrapVideoReceiverReport = true
                let sourcesByStream = Dictionary(grouping:
                    appleMediaVideoSSRCChannels.keys.compactMap { remoteSSRC in
                        appleMediaFeedbackRouteByRemoteSSRC[remoteSSRC].map {
                            ($0.streamIndex, remoteSSRC)
                        }
                    },
                    by: { $0.0 })
                let dependentSources = sourcesByStream.values.flatMap { sources in
                    sources.map(\.1).sorted().dropFirst()
                }
                Task { [weak self] in
                    await self?.sendAppleMediaBootstrapReceiverReports(
                        mediaSSRCs: dependentSources)
                }
            }
        }

        let ingestClockNanos = DispatchTime.now().uptimeNanoseconds
        appleMediaLastVideoIngestNanos = ingestClockNanos
        if appleMediaLastVideoReleaseNanos == 0 {
            // Arm the dead-man from first ingest so a from-birth stall (never
            // a single released packet) is also detected.
            appleMediaLastVideoReleaseNanos = ingestClockNanos
        }
        let result = appleMediaRTPReorderBuffer.insert(
            packet: packet,
            ssrc: header.ssrc,
            sequence: header.sequenceNumber,
            nowNanos: nowNanos)
        processAppleMediaReorderResult(result)
        scheduleAppleMediaReorderFlush(nowNanos: nowNanos)
    }

    private func processAppleMediaReorderResult(_ result: AppleMediaRTPReorderBuffer.Result) {
        for request in result.retransmissionRequests {
            guard let channel = appleMediaVideoSSRCChannels[request.ssrc] else { continue }
            Task { [weak self] in
                await self?.sendAppleMediaNACK(
                    missingSequences: request.missingSequences,
                    mediaSSRC: request.ssrc,
                    on: channel)
            }
        }

        for gap in result.gaps {
            appleRCTLLostInterval += gap.missingPacketCount
            appleRCTLBurstLostInterval = max(
                appleRCTLBurstLostInterval,
                gap.missingPacketCount)
            if var stats = appleMediaReceptionStats[gap.ssrc] {
                stats.confirmedLost &+= UInt32(clamping: gap.missingPacketCount)
                appleMediaReceptionStats[gap.ssrc] = stats
            }

            if rateControlEnabled {
                let controller = appleMediaRateController ?? {
                    let created = AppleMediaRateController(
                        maxTargetBps: appleMediaRateControllerMaxBps,
                        initialTargetBps: appleMediaNetworkProfile.initialCapacityBps)
                    appleMediaRateController = created
                    return created
                }()
                let now = Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
                controller.onConfirmedLoss(count: gap.missingPacketCount, now: now)
                controller.update(now: now)
            }

            guard let channel = appleMediaVideoSSRCChannels[gap.ssrc] else { continue }
            let feedback = AppleMediaFrameLossFeedback(
                frameRTPTimestamp: gap.frameRTPTimestamp,
                frameSequenceNumber: gap.frameSequenceNumber ?? 0,
                framePacketCount: UInt8(clamping: max(
                    gap.missingPacketCount,
                    gap.estimatedFramePacketCount)),
                lostPacketCount: UInt8(clamping: gap.missingPacketCount))
            appleMediaLastFrameLossFeedback[gap.ssrc] = feedback
            appleMediaMostRecentFrameLossSSRC = gap.ssrc
            log.warning("Confirmed video RTP loss ssrc=0x\(String(gap.ssrc, radix: 16)) "
                + "missing=\(gap.missingPacketCount) framePackets=\(feedback.framePacketCount) "
                + "frameTimestamp=\(feedback.frameRTPTimestamp) "
                + "frameSequence=\(gap.frameSequenceNumber.map(String.init) ?? "unknown")")
            Task { [weak self] in
                await self?.sendAppleMediaFrameLossFeedback(
                    feedback,
                    mediaSSRC: gap.ssrc,
                    on: channel)
            }
        }

        let packets = result.packets
        if !packets.isEmpty {
            appleMediaLastVideoReleaseNanos = DispatchTime.now().uptimeNanoseconds
        }
        for packet in packets {
            acknowledgeAppleMediaLTRIfNeeded(packet)
            emitAppleMediaRTPPacket(packet)
        }
    }

    /// Acknowledge a fully received, ordered LTR-marked tile subframe. Apple
    /// does not set RTP's marker bit for this profile; packet count and frame
    /// sequence in its public wire extension define completion instead.
    private func acknowledgeAppleMediaLTRIfNeeded(_ packet: Data) {
        guard let acknowledgement =
                appleMediaLTRFrameCompletionTracker.insert(packet),
              let channel = appleMediaVideoSSRCChannels[acknowledgement.ssrc]
        else {
            return
        }
        Task { [weak self] in
            await self?.sendAppleMediaLTRAcknowledgement(
                rtpTimestamp: acknowledgement.rtpTimestamp,
                mediaSSRC: acknowledgement.ssrc,
                on: channel)
        }
    }

    private func sendAppleMediaLTRAcknowledgement(
        rtpTimestamp: UInt32,
        mediaSSRC: UInt32,
        on channel: PosixUDPChannel
    ) async {
        guard let route = appleMediaFeedbackRoute(forRemoteSSRC: mediaSSRC)
        else { return }
        let app = appleMediaLTRAcknowledgementPacket(
            senderSSRC: route.localSSRC,
            rtpTimestamp: rtpTimestamp)
        guard let protected = try? route.sendRTCPContext.protect(
            app,
            senderSSRC: route.localSSRC) else { return }
        dumpAppleMediaOutgoingRTCPIfRequested(
            plaintext: app,
            protected: protected)
        do {
            try await channel.send(protected)
            appleMediaLTRAcknowledgementsSinceDiagnostic += 1
        } catch {
            return
        }
    }

    /// Send negotiated frame-loss feedback (PSFB AFB type 6). This identifies
    /// the damaged frame so an LTR-enabled sender can repair or refresh the
    /// shared reference chain; that recovery need not be a conventional IDR.
    private func sendAppleMediaFrameLossFeedback(
        _ feedback: AppleMediaFrameLossFeedback,
        mediaSSRC: UInt32,
        on channel: PosixUDPChannel
    ) async {
        guard let route = appleMediaFeedbackRoute(forRemoteSSRC: mediaSSRC) else { return }
        let sender = route.localSSRC
        let packet = appleMediaFrameLossPacket(
            senderSSRC: sender,
            mediaSSRC: mediaSSRC,
            feedback: feedback)

        guard let protected = try? route.sendRTCPContext.protect(
            packet,
            senderSSRC: sender) else { return }
        dumpAppleMediaOutgoingRTCPIfRequested(plaintext: packet, protected: protected)
        try? await channel.send(protected)
        log.warning("Sent media frame-loss feedback ssrc=0x\(String(mediaSSRC, radix: 16)) "
            + "frameSequence=\(feedback.frameSequenceNumber) "
            + "framePackets=\(feedback.framePacketCount) "
            + "lost=\(feedback.lostPacketCount) feedbackStream=\(route.streamIndex)")
    }

    /// Confirm that a decode gate corresponds to transport-observed packet
    /// loss before arming the no-video-displayed FIR fail-safe.
    public func hasObservedVideoLossFeedback(ssrc requestedSSRC: UInt32? = nil) -> Bool {
        if let requestedSSRC,
           appleMediaLastFrameLossFeedback[requestedSSRC] != nil {
            return appleMediaVideoSSRCChannels[requestedSSRC] != nil
        }
        guard let recent = appleMediaMostRecentFrameLossSSRC else { return false }
        return appleMediaLastFrameLossFeedback[recent] != nil
            && appleMediaVideoSSRCChannels[recent] != nil
    }

    /// Whether the receive controller considers the path quiet enough for a
    /// large recovery IDR. Sending FIR while packets are still being lost just
    /// creates another undecodable burst and prolongs the black screen.
    /// `displayGated` relaxes the quiet requirement: with every band gated the
    /// screen is frozen anyway, so recovery latency dominates the tradeoff.
    public func isReadyForVideoKeyframeRecovery(displayGated: Bool = false) -> Bool {
        guard let controller = appleMediaRateController else { return true }
        return controller.isReadyForKeyframeRecovery(
            now: Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000,
            displayGated: displayGated)
    }

    /// Proactively step the advertised receive capacity down before retrying a
    /// recovery IDR, and flush one RCTL packet so the reduced estimate is on
    /// the wire ahead of the FIR rather than up to 50 ms behind it.
    public func applyVideoRecoveryBackoff() async {
        guard rateControlEnabled, let controller = appleMediaRateController else { return }
        let now = Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
        guard controller.forceRecoveryBackoff(now: now) else { return }
        log.warning(
            "Recovery backoff before FIR retry: advertising "
                + "\(controller.bandwidthEstimateBps / 1_000) kbps "
                + "(attempt \(controller.recoveryAttemptCount))")
        await sendAppleMediaRCTLFeedback()
    }

    /// The recovery gate cleared; end the controller's recovery episode so the
    /// normal floor and utilization-gated ramp resume.
    public func noteVideoRecoveryComplete() {
        appleMediaRateController?.noteRecoveryComplete()
    }

    /// Ask the server to retransmit missing RTP packets while the per-SSRC
    /// jitter buffer holds newer packets. The media profile supports NACK and
    /// retransmission; without this step a single lost fragment
    /// becomes a missing HEVC picture and corrupts its dependent pictures.
    private func sendAppleMediaNACK(
        missingSequences: [UInt16],
        mediaSSRC: UInt32,
        on channel: PosixUDPChannel
    ) async {
        guard let route = appleMediaFeedbackRoute(forRemoteSSRC: mediaSSRC) else { return }
        let entries = appleMediaGenericNACKEntries(missingSequences: missingSequences)
        guard !entries.isEmpty else { return }

        let sender = route.localSSRC
        var packet = Data()
        packet.append(0x81) // V=2, P=0, FMT=1 (Generic NACK)
        packet.append(0xcd) // PT=205 (RTPFB)
        let length = UInt16(2 + entries.count)
        packet.append(UInt8(length >> 8))
        packet.append(UInt8(length & 0xff))
        appendUInt32BE(sender, to: &packet)
        appendUInt32BE(mediaSSRC, to: &packet)
        for entry in entries {
            packet.append(UInt8(entry.packetID >> 8))
            packet.append(UInt8(entry.packetID & 0xff))
            packet.append(UInt8(entry.bitmask >> 8))
            packet.append(UInt8(entry.bitmask & 0xff))
        }

        guard let protected = try? route.sendRTCPContext.protect(
            packet,
            senderSSRC: sender) else { return }
        dumpAppleMediaOutgoingRTCPIfRequested(plaintext: packet, protected: protected)
        try? await channel.send(protected)
        log.debug("Requested RTP retransmission ssrc=0x\(String(mediaSSRC, radix: 16)) "
            + "missing=\(missingSequences.count) feedbackStream=\(route.streamIndex)")
    }

    private func scheduleAppleMediaReorderFlush(nowNanos: UInt64) {
        guard let deadline = appleMediaRTPReorderBuffer.nextDeadlineNanos else {
            appleMediaRTPReorderFlushTask?.cancel()
            appleMediaRTPReorderFlushTask = nil
            appleMediaRTPReorderScheduledDeadlineNanos = nil
            return
        }
        if let scheduled = appleMediaRTPReorderScheduledDeadlineNanos,
           scheduled <= deadline,
           appleMediaRTPReorderFlushTask != nil {
            return
        }

        appleMediaRTPReorderFlushTask?.cancel()
        appleMediaRTPReorderScheduledDeadlineNanos = deadline
        // `nowNanos` is the socket arrival time. When ingress is catching up it
        // may be far behind the monotonic clock, so an already-expired loss
        // deadline must fire immediately instead of sleeping another 300 ms.
        let clockNow = DispatchTime.now().uptimeNanoseconds
        let delay = deadline > clockNow ? deadline - clockNow : 0
        appleMediaRTPReorderFlushTask = Task { [weak self] in
            try? await Task.sleep(for: .nanoseconds(Int64(min(delay, UInt64(Int64.max)))))
            guard !Task.isCancelled else { return }
            await self?.flushAppleMediaRTPReorderBuffer()
        }
    }

    private func flushAppleMediaRTPReorderBuffer() {
        appleMediaRTPReorderFlushTask = nil
        appleMediaRTPReorderScheduledDeadlineNanos = nil
        let now = DispatchTime.now().uptimeNanoseconds
        let result = appleMediaRTPReorderBuffer.flushExpired(nowNanos: now)
        processAppleMediaReorderResult(result)
        scheduleAppleMediaReorderFlush(nowNanos: now)
    }

    /// Request a fresh IDR for the video stream, from outside the transport.
    /// Used by the decode pipeline's recovery paths when startup, a damaged
    /// reference chain, or an asynchronous decoder failure needs a fresh IRAP.
    ///
    /// Compound HEVC has one shared reference timeline. Apple emits its
    /// recovery IDR on the base (lowest) remote SSRC even when RTP was lost on
    /// a sibling band. The affected SSRC is therefore diagnostic only; sending
    /// FIR to it leaves the shared decoder chain poisoned indefinitely.
    /// A light 150 ms floor guards against concurrent recovery triggers.
    public func requestVideoKeyframe(ssrc requestedSSRC: UInt32? = nil) async {
        guard let (ssrc, channel) = appleMediaCompoundBaseVideoSource() else { return }
        if let requestedSSRC, requestedSSRC != ssrc {
            log.debug(
                "Routing compound HEVC recovery from affected ssrc=0x"
                    + "\(String(requestedSSRC, radix: 16)) to base ssrc=0x"
                    + "\(String(ssrc, radix: 16))")
        }
        let now = DispatchTime.now().uptimeNanoseconds
        guard now &- appleLastKeyframeRequestNanos > 150_000_000 else { return }
        appleLastKeyframeRequestNanos = now
        await sendAppleMediaKeyframeRequest(mediaSSRC: ssrc, on: channel)
    }

    /// Send a keyframe request at most once per second so bursty loss doesn't
    /// trigger a flood of IDRs.
    private func requestAppleMediaKeyframeRateLimited() {
        guard let (ssrc, channel) = appleMediaCompoundBaseVideoSource() else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        guard now &- appleLastKeyframeRequestNanos > 1_000_000_000 else { return }
        appleLastKeyframeRequestNanos = now
        Task { [weak self] in
            await self?.sendAppleMediaKeyframeRequest(mediaSSRC: ssrc, on: channel)
        }
    }

    private func appleMediaCompoundBaseVideoSource() -> (UInt32, PosixUDPChannel)? {
        guard let ssrc = appleMediaCompoundBaseSSRC(
            Array(appleMediaVideoSSRCChannels.keys)),
              let channel = appleMediaVideoSSRCChannels[ssrc] else {
            return nil
        }
        return (ssrc, channel)
    }

    // MARK: - RTCP Receiver Reports (bitrate feedback)

    /// Update per-SSRC reception counters used to build Receiver Reports.
    @discardableResult
    private func updateAppleMediaReceptionStats(ssrc: UInt32, sequence: UInt16) -> Bool {
        var stats = appleMediaReceptionStats[ssrc] ?? AppleMediaReceptionStats()
        if !stats.recentSequences.insert(sequence) {
            return false
        }

        if !stats.initialized {
            stats.baseSeq = UInt32(sequence)
            stats.maxSeq = sequence
            stats.received = 1
            stats.initialized = true
        } else {
            let forwardDelta = sequence &- stats.maxSeq // UInt16 wraparound
            if forwardDelta < 0x8000 {
                if sequence < stats.maxSeq { stats.cycles &+= 0x1_0000 } // wrapped past 0xffff
                stats.maxSeq = sequence
            }
            stats.received &+= 1
        }
        appleMediaReceptionStats[ssrc] = stats
        return true
    }

    /// Parse the server's SRTCP Sender Report to capture the LSR/DLSR round-trip
    /// timestamp the server needs to estimate RTT.
    private func handleAppleMediaServerSenderReport(
        _ datagram: Data,
        arrivalNanos: UInt64
    ) {
        var decoded: Data?
        var routes = appleMediaFeedbackRoutes
        if let appleMediaAudioFeedbackRoute {
            routes.append(appleMediaAudioFeedbackRoute)
        }
        for route in routes {
            if let rtcp = try? route.receiveRTCPContext.unprotect(datagram) {
                decoded = rtcp
                break
            }
        }
        guard let rtcp = decoded,
              let timing = appleMediaSenderReportTiming(
                from: rtcp,
                arrivalNanos: arrivalNanos) else { return }
        appleMediaSenderReports[timing.remoteSSRC] = timing
        appleMediaSenderClockSink?(AppleMediaSenderClockMapping(
            remoteSSRC: timing.remoteSSRC,
            ntpTimestamp: timing.ntpTimestamp,
            rtpTimestamp: timing.rtpTimestamp))
    }

    /// Native's feedback-only screen profile does not layer periodic RFC 3550
    /// Receiver Reports on top of RCTL. The wire capture contains one 46-byte
    /// protected RCTL packet every 50 ms and no additional one-second burst;
    /// sending one RR per compound SSRC created four same-sized packets at
    /// once and periodically perturbed the sender. Keep only the opt-in FIR
    /// diagnostic timer here.
    private func startAppleTestFIRLoopIfRequested() {
        guard appleRTCPReportTask == nil else { return }
        guard runtimeEnvironment["ROOTSHELL_VNC_TEST_FIR"] == "1" else { return }
        appleRTCPReportTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                await self?.sendTestKeyframeRequest()
            }
        }
    }

    /// Diagnostic: force a keyframe request so we can verify the server honors
    /// our FIR (a fresh IDR should appear in the stream after each one).
    private func sendTestKeyframeRequest() async {
        guard let (ssrc, channel) = appleMediaCompoundBaseVideoSource() else { return }
        await sendAppleMediaKeyframeRequest(mediaSSRC: ssrc, on: channel)
    }

    /// Start the RTCP APP "RCTL" rate-control feedback loop. Native Screen
    /// Sharing sends this timer-driven feedback every 50 ms while media is
    /// active. Keep the diagnostic override for controlled wire experiments.
    private func startAppleRCTLFeedbackLoop() {
        guard appleRCTLFeedbackTask == nil else { return }
        guard rctlEnabled else { return }
        let intervalMilliseconds = max(
            50,
            runtimeEnvironment["ROOTSHELL_VNC_RCTL_INTERVAL_MS"]
                .flatMap(Int.init) ?? 50)
        let intervalNanos = UInt64(intervalMilliseconds) * 1_000_000
        appleRCTLFeedbackTask = Task { [weak self] in
            var nextDeadline = DispatchTime.now().uptimeNanoseconds &+ intervalNanos
            while !Task.isCancelled {
                let beforeSleep = DispatchTime.now().uptimeNanoseconds
                if nextDeadline > beforeSleep {
                    try? await Task.sleep(
                        nanoseconds: nextDeadline - beforeSleep)
                }
                if Task.isCancelled { return }
                await self?.recoverWedgedAppleMediaReorderBufferIfNeeded()
                await self?.sendAppleMediaRCTLFeedback()

                // Keep the native timer's absolute 20 Hz phase instead of
                // adding actor/serialization time to every 50 ms sleep. If a
                // large RTP burst made us miss slots, skip those deadlines;
                // emitting a catch-up feedback burst would itself perturb the
                // encoder's rate controller.
                let afterSend = DispatchTime.now().uptimeNanoseconds
                repeat {
                    nextDeadline &+= intervalNanos
                } while nextDeadline <= afterSend
            }
        }
    }

    /// Timestamps for the video release dead-man below.
    private var appleMediaLastVideoIngestNanos: UInt64 = 0
    private var appleMediaLastVideoReleaseNanos: UInt64 = 0

    /// Dead-man for a wedged jitter buffer: video RTP is being ingested but
    /// nothing has been released downstream for well over the maximum gap
    /// wait. This can occur when a confirmed loss lands inside a media
    /// renegotiation window: subsequent packets remain queued and
    /// the display stayed black while audio continued. Resetting the buffer
    /// re-anchors sequence tracking; the resulting jump surfaces as a normal
    /// loss and heals through keyframe recovery.
    private func recoverWedgedAppleMediaReorderBufferIfNeeded() {
        let now = DispatchTime.now().uptimeNanoseconds
        guard appleMediaLastVideoIngestNanos != 0,
              now &- appleMediaLastVideoIngestNanos < 500_000_000,
              appleMediaLastVideoReleaseNanos != 0,
              now &- appleMediaLastVideoReleaseNanos > 1_500_000_000 else { return }
        log.error(
            "Video jitter buffer stalled (ingest live, no release for >1.5 s, "
                + "\(appleMediaRTPReorderBuffer.queuedPacketCount) queued); resetting")
        appleMediaRTPReorderFlushTask?.cancel()
        appleMediaRTPReorderFlushTask = nil
        appleMediaRTPReorderScheduledDeadlineNanos = nil
        appleMediaRTPReorderBuffer.reset()
        appleMediaLastVideoReleaseNanos = now
    }

    /// Apply the feedback-only RTP receive-accounting rules. Update the echo
    /// only when a forward-moving RTP timestamp begins, then send the
    /// low-precision form selected by Apple's video-stream configuration.
    private func updateAppleRCTLEchoTimestamp(_ timestamp: UInt32) {
        guard let previous = appleRCTLPreviousRTPTimestamp else {
            appleRCTLPreviousRTPTimestamp = timestamp
            return
        }
        let distance = timestamp &- previous
        guard distance != 0, distance < 0x8000_0000 else { return }
        appleRCTLPreviousRTPTimestamp = timestamp
        appleMediaLastRTPEchoTimestampQ10 =
            appleMediaRCTLLowPrecisionEchoTimestamp(timestamp)
    }

    /// Build and send one RTCP APP "RCTL" rate-control feedback packet:
    /// `80 CC 00 07 [SSRC] "RCTL" [20-byte payload]`, SRTCP-protected. The
    /// 20-byte payload carries our measured received bitrate (kbps), loss,
    /// one-way delay and timestamps so the server can size its encoder to us.
    private func sendAppleMediaRCTLFeedback() async {
        guard !appleMediaFeedbackRoutes.isEmpty,
              !appleMediaFeedbackRouteByRemoteSSRC.isEmpty else { return }

        let targets: [(AppleMediaFeedbackRoute, [PosixUDPChannel])]
        // Compound HEVC exposes four remote SSRCs for one display, but all
        // four map to the same feedback route. RCTL is a receiver/display
        // report, not a per-tile report. Resolve exactly one observed video
        // channel per feedback stream. Native waits for the first video RTP
        // before sending its first RCTL; sending an unresolved route to every
        // UDP channel also feeds video control data to the audio parser.
        var resolvedByStream:
            [Int: (AppleMediaFeedbackRoute, [PosixUDPChannel])] = [:]
        for (remoteSSRC, route) in appleMediaFeedbackRouteByRemoteSSRC {
            guard resolvedByStream[route.streamIndex] == nil,
                  let channel = appleMediaVideoSSRCChannels[remoteSSRC]
            else { continue }
            resolvedByStream[route.streamIndex] = (route, [channel])
        }
        targets = resolvedByStream.values.sorted {
            $0.0.streamIndex < $1.0.streamIndex
        }
        guard targets.contains(where: { !$0.1.isEmpty }) else { return }

        let now = DispatchTime.now().uptimeNanoseconds
        let intervalPackets = appleRCTLPacketsInterval
        let intervalLost = appleRCTLLostInterval
        let burst = appleRCTLBurstLostInterval
        appleRCTLPacketsInterval = 0
        appleRCTLLostInterval = 0
        appleRCTLBurstLostInterval = 0

        let nowSeconds = Double(now) / 1_000_000_000
        if let controller = appleMediaRateController {
            controller.update(now: nowSeconds)
        }

        // RCTL carries estimated receive capacity. It is the feedback input to
        // the peer's encoder controller, not an observed activity bitrate.
        // Start a healthy LAN at the native 60 Mbps ceiling, but continue to
        // advertise the controller's loss-backed estimate. Pinning LAN RCTL at
        // 60 Mbps after confirmed loss let a Retina intra-refresh burst exceed
        // 150 Mbps while the receiver was already dropping packets. Apple's
        // clean 60 Mbps sessions stay at the ceiling because they remain
        // lossless; the ceiling is a prior, not an override of measured loss.
        let estimatedKbps: Double
        if !rateControlEnabled {
            estimatedKbps = 65_535
        } else {
            estimatedKbps = Double(appleMediaRateController?.bandwidthEstimateBps
                ?? UInt32(appleMediaRateControllerMaxBps)) / 1_000
        }
        let bweKbps = runtimeEnvironment["ROOTSHELL_VNC_RCTL_BWE_KBPS"]
            .flatMap(Double.init) ?? estimatedKbps
        let bwe = UInt16(min(65_535, max(0, bweKbps.rounded())))

        let burstyLoss = UInt8(min(15, burst))
        let expectedPackets = max(0, intervalPackets) + max(0, intervalLost)
        let lossPercent: UInt8 = expectedPackets == 0
            ? 0
            : UInt8(min(100, Int((Double(max(0, intervalLost)) * 100
                / Double(expectedPackets)).rounded())))
        // These counts are sampled at serialization time. Latching a count at
        // the first packet of an RTP timestamp leaves the rest of a large HEVC
        // access unit unreported and makes VCRC infer loss that never occurred.
        let cumulativeVideoReceivedPacketCount = UInt16(
            truncatingIfNeeded: appleRCTLTotalPacketsReceived)
        let cumulativeAudioReceivedPacketCount = UInt16(
            truncatingIfNeeded: appleRCTLAudioPacketsReceived)
        let totalReceivedKBytes = UInt16(
            truncatingIfNeeded: appleRCTLTotalBytesReceived / 1_024)
        let owrdSeconds = appleMediaRateController?.owrdSeconds ?? 0
        let owrd = UInt16(min(65535, (owrdSeconds * 8192).rounded()))
        let ts = UInt16(truncatingIfNeeded: Int(nowSeconds * 1024))          // Q10 s
        let echo = appleMediaLastRTPEchoTimestampQ10
        let queuingDelayMilliseconds = UInt16(min(
            UInt64(UInt16.max),
            appleRCTLMaximumQueueDelayNanos / 1_000_000))
        appleRCTLMaximumQueueDelayNanos = 0
        let feedback = AppleMediaRCTLFeedback(
            receiveQueueTargetMilliseconds: 100,
            echoTimestamp: echo,
            totalReceivedKBytes: totalReceivedKBytes,
            audioBurstyLoss: 0,
            cumulativeAudioReceivedPacketCount: cumulativeAudioReceivedPacketCount,
            queuingDelayMilliseconds: queuingDelayMilliseconds,
            sendTimestampQ10: ts,
            owrdQ13: owrd,
            videoBurstyLoss: burstyLoss,
            cumulativeVideoReceivedPacketCount: cumulativeVideoReceivedPacketCount,
            bandwidthEstimateKbps: bwe)

        if intervalLost > 0 {
            log.warning(
                "RCTL congestion feedback bwe=\(bwe)kbps receivedPackets="
                    + "\(intervalPackets) lostPackets=\(intervalLost) "
                    + "loss=\(lossPercent)% burst=\(burstyLoss)")
        }

        if appleRCTLLastDiagnosticNanos == 0
            || now &- appleRCTLLastDiagnosticNanos >= 1_000_000_000 {
            appleRCTLLastDiagnosticNanos = now
            let receivedKbps = Int(
                (appleMediaRateController?.throughputBps(now: nowSeconds) ?? 0) / 1_000)
            let queuePeakMilliseconds = Int(
                (appleMediaRateController?.peakQueueDelaySeconds ?? 0) * 1_000)
            let ingressPackets = appleMediaIngressPacketsSinceDiagnostic
            let ingressProcessingMilliseconds =
                appleMediaIngressProcessingNanosSinceDiagnostic / 1_000_000
            let ingressMaximumBatch = appleMediaIngressMaximumBatchSinceDiagnostic
            let ltrAcknowledgements = appleMediaLTRAcknowledgementsSinceDiagnostic
            appleMediaIngressPacketsSinceDiagnostic = 0
            appleMediaIngressProcessingNanosSinceDiagnostic = 0
            appleMediaIngressMaximumBatchSinceDiagnostic = 0
            appleMediaLTRAcknowledgementsSinceDiagnostic = 0
            log.info(
                "RCTL bwe=\(bwe)kbps received=\(receivedKbps)kbps "
                    + "echoQ10=\(echo) queue=\(queuingDelayMilliseconds)ms "
                    + "loss=\(lossPercent)% "
                    + "burst=\(burstyLoss) "
                    + "packetCount=\(cumulativeVideoReceivedPacketCount & 0x0fff) "
                    + "ingressQueuePeak=\(queuePeakMilliseconds)ms "
                    + "ingressPackets=\(ingressPackets) ingressCPU="
                    + "\(ingressProcessingMilliseconds)ms maxBatch=\(ingressMaximumBatch) "
                    + "ltrACKs=\(ltrAcknowledgements) "
                    + "reorderQueued=\(appleMediaRTPReorderBuffer.queuedPacketCount)")
        }

        // The feedback-only profile sends an RCTL APP packet by itself;
        // ordinary Receiver Reports have their own 1 Hz loop below.
        for (route, channels) in targets {
            let app = appleMediaRCTLPacket(
                senderSSRC: route.localSSRC,
                feedback: feedback)
            guard let protected = try? route.sendRTCPContext.protect(
                app,
                senderSSRC: route.localSSRC) else { continue }
            dumpAppleMediaOutgoingRTCPIfRequested(
                plaintext: app,
                protected: protected)
            // Before RTP identifies the display socket, send each display's
            // own SRTCP packet on every candidate. Afterwards the authenticated
            // receive mapping selects one route and one channel.
            for channel in channels {
                try? await channel.send(protected)
            }
        }

    }

    /// Ceiling for the receive-capacity estimator (bps). The bearer only sets
    /// the initial prior; the ceiling is the 60 Mbps negotiated screen tier on
    /// every path. RCTL serializes kbps as UInt16; estimates above that only
    /// delay a later loss response because several reductions would still
    /// encode as the same saturated value.
    private var appleMediaRateControllerMaxBps: Double {
        AppleMediaRateController.nativeScreenMaximumBitrateBps
    }

    private func startAppleMediaAudioRTCPFeedbackLoop() {
        guard appleMediaAudioRTCPTask == nil else { return }
        appleMediaAudioRTCPTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                await self?.sendAppleMediaAudioReceiverReport()
            }
        }
    }

    /// Audio retains ordinary RTCP liveness even though screen video uses
    /// standalone RCTL. This is the native 58-byte protected UDP packet:
    /// 32-byte RR + 12-byte empty-CNAME SDES + 14-byte SRTCP trailer.
    private func sendAppleMediaAudioReceiverReport() async {
        guard let route = appleMediaAudioFeedbackRoute,
              let remoteSSRC = appleMediaAudioRemoteSSRC,
              let channel = appleMediaAudioChannel,
              let rr = buildAppleMediaReceiverReport(
                senderSSRC: route.localSSRC,
                mediaSSRC: remoteSSRC) else { return }
        let compound = appleMediaReceiverReportCompound(
            receiverReport: rr,
            senderSSRC: route.localSSRC)
        guard let protected = try? route.sendRTCPContext.protect(
            compound,
            senderSSRC: route.localSSRC) else { return }
        dumpAppleMediaOutgoingRTCPIfRequested(
            plaintext: compound,
            protected: protected)
        try? await channel.send(protected)
    }

    private func sendAppleMediaReceiverReport() async {
        for (mediaSSRC, channel) in appleMediaVideoSSRCChannels {
            guard let route = appleMediaFeedbackRoute(forRemoteSSRC: mediaSSRC),
                  let rr = buildAppleMediaReceiverReport(
                    senderSSRC: route.localSSRC,
                    mediaSSRC: mediaSSRC),
                  let protected = try? route.sendRTCPContext.protect(
                    rr,
                    senderSSRC: route.localSSRC) else { continue }
            try? await channel.send(protected)
        }
    }

    /// Match the peer-compatible compound generation bootstrap: each
    /// dependent source gets a one-source Receiver Report followed by the
    /// 12-byte empty-CNAME SDES packet. Standalone aggregate RCTL then runs at
    /// 20 Hz.
    private func sendAppleMediaBootstrapReceiverReports(
        mediaSSRCs: [UInt32]
    ) async {
        for mediaSSRC in mediaSSRCs {
            guard let route = appleMediaFeedbackRoute(forRemoteSSRC: mediaSSRC),
                  let channel = appleMediaVideoSSRCChannels[mediaSSRC],
                  let rr = buildAppleMediaReceiverReport(
                    senderSSRC: route.localSSRC,
                    mediaSSRC: mediaSSRC) else { continue }
            let compound = appleMediaReceiverReportCompound(
                receiverReport: rr,
                senderSSRC: route.localSSRC)
            guard let protected = try? route.sendRTCPContext.protect(
                compound,
                senderSSRC: route.localSSRC) else { continue }
            dumpAppleMediaOutgoingRTCPIfRequested(
                plaintext: compound,
                protected: protected)
            try? await channel.send(protected)
            log.debug(
                "Sent Apple media dependent-tile bootstrap RR+SDES ssrc=0x"
                    + "\(String(mediaSSRC, radix: 16)) feedbackStream="
                    + "\(route.streamIndex)")
        }
    }

    /// Build an RTCP Receiver Report (RFC 3550) reporting reception quality for
    /// each video source, so the server's congestion controller can size the
    /// bitrate to the link.
    private func buildAppleMediaReceiverReport(
        senderSSRC: UInt32,
        mediaSSRC: UInt32? = nil
    ) -> Data? {
        let sources = appleMediaReceptionStats.filter { ssrc, stats in
            stats.initialized && (mediaSSRC == nil || mediaSSRC == ssrc)
        }
        guard !sources.isEmpty else { return nil }

        let now = DispatchTime.now().uptimeNanoseconds

        let reportCount = min(sources.count, 31)
        let lengthWords = 1 + 6 * reportCount // total 32-bit words - 1

        var rr = Data()
        rr.append(0x80 | UInt8(reportCount)) // V=2, P=0, RC
        rr.append(201) // PT = Receiver Report
        rr.append(UInt8((lengthWords >> 8) & 0xff))
        rr.append(UInt8(lengthWords & 0xff))
        appendUInt32BE(senderSSRC, to: &rr)

        for (ssrc, original) in sources.prefix(reportCount) {
            var stats = original
            let srTiming = appleMediaReceiverReportTiming(
                for: ssrc,
                senderReports: appleMediaSenderReports,
                nowNanos: now)
            let extendedMax = stats.cycles | UInt32(stats.maxSeq)
            let expected = extendedMax &- stats.baseSeq &+ 1
            let expectedInterval = expected &- stats.expectedPrior
            let confirmedLostInterval = stats.confirmedLost &- stats.confirmedLostPrior
            var fraction: UInt8 = 0
            if expectedInterval != 0 && confirmedLostInterval > 0 {
                let ratio = (UInt64(confirmedLostInterval) << 8)
                    / UInt64(expectedInterval)
                fraction = UInt8(min(UInt64(255), ratio))
            }
            let cumulativeLost = min(stats.confirmedLost, 0xff_ffff)

            stats.expectedPrior = expected
            stats.confirmedLostPrior = stats.confirmedLost
            appleMediaReceptionStats[ssrc] = stats

            appendUInt32BE(ssrc, to: &rr)
            appendUInt32BE((UInt32(fraction) << 24) | cumulativeLost, to: &rr)
            appendUInt32BE(extendedMax, to: &rr)
            appendUInt32BE(0, to: &rr) // interarrival jitter (RTP timestamps are 0; not meaningful)
            appendUInt32BE(srTiming.lsr, to: &rr)
            appendUInt32BE(srTiming.dlsr, to: &rr)
        }
        return rr
    }

    private nonisolated func appendUInt32BE(_ value: UInt32, to data: inout Data) {
        data.append(UInt8((value >> 24) & 0xff))
        data.append(UInt8((value >> 16) & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8(value & 0xff))
    }

    private nonisolated func appleMediaRTPSSRC(_ datagram: Data) -> UInt32? {
        guard datagram.count >= 12 else { return nil }
        let base = datagram.startIndex
        guard (datagram[base] >> 6) == 2 else { return nil }
        return UInt32(datagram[base + 8]) << 24
            | UInt32(datagram[base + 9]) << 16
            | UInt32(datagram[base + 10]) << 8
            | UInt32(datagram[base + 11])
    }

    private nonisolated func dumpAppleMediaSRTPKeysIfRequested(_ keys: [Data]) {
        #if DEBUG
        guard let path = VNCDiagnostics.value(
            for: "ROOTSHELL_VNC_DUMP_SRTP_KEYS",
            environment: runtimeEnvironment) else { return }
        var blob = Data()
        for key in keys {
            blob.append(UInt8(key.count))
            blob.append(key)
        }
        writePrivateDiagnosticData(blob, to: path)
        #endif
    }

    private nonisolated func dumpAppleMediaUDPDatagramIfRequested(_ datagram: Data) {
        #if DEBUG
        guard let path = appleMediaUDPDatagramDumpPath else { return }
        var framed = Data()
        framed.append(UInt8((datagram.count >> 8) & 0xFF))
        framed.append(UInt8(datagram.count & 0xFF))
        framed.append(datagram)
        appendPrivateDiagnosticData(framed, to: path)
        #endif
    }

    #if DEBUG
    private nonisolated func appendPrivateDiagnosticData(_ data: Data, to path: String) {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: path) {
            guard fileManager.createFile(
                atPath: path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]) else { return }
        }
        guard let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) else {
            return
        }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
        try? handle.close()
    }

    private nonisolated func writePrivateDiagnosticData(_ data: Data, to path: String) {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: path) {
            guard fileManager.createFile(
                atPath: path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]) else { return }
        }
        guard let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) else {
            return
        }
        try? handle.truncate(atOffset: 0)
        try? handle.write(contentsOf: data)
        try? handle.close()
    }
    #endif

    private nonisolated func isAppleMediaRTCPPacket(_ data: Data) -> Bool {
        guard data.count >= 2 else { return false }
        let packetType = data[data.startIndex + 1]
        return packetType >= 192 && packetType <= 223
    }
}

private extension UUID {
    var bytes: [UInt8] {
        withUnsafeBytes(of: uuid) { Array($0) }
    }
}
