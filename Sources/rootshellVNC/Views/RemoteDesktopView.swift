import SwiftUI
import RFBProtocol
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct DockedKeyboardViewportMetrics: Equatable {
    var containerSize: CGSize = .zero
    var keyboardInset: CGFloat = 0

    func effectiveInset(reservingObstruction: Bool) -> CGFloat {
        reservingObstruction ? keyboardInset : 0
    }

    func availableSize(reservingObstruction: Bool) -> CGSize {
        let effectiveInset = effectiveInset(
            reservingObstruction: reservingObstruction)
        return CGSize(
            width: containerSize.width,
            height: max(0, containerSize.height - effectiveInset))
    }

    func isApproximatelyEqual(
        to other: DockedKeyboardViewportMetrics
    ) -> Bool {
        abs(containerSize.width - other.containerSize.width) <= 0.5
            && abs(containerSize.height - other.containerSize.height) <= 0.5
            && abs(keyboardInset - other.keyboardInset) <= 0.5
    }
}

/// Chooses which layer owns keyboard and accessory clearance for the remote
/// viewport. Container apps with a shared pane layout can opt out of the
/// package spacer while the standalone view keeps automatic avoidance.
public enum VNCKeyboardAvoidanceMode: Equatable, Sendable {
    case automatic
    case hostManaged
}

/// Displays the remote desktop and provides one input/viewport layer for both
/// Adaptive video and Full Quality framebuffer rendering.
public struct RemoteDesktopView: View {
    @Bindable var session: VNCSession
    @Environment(\.displayScale) private var displayScale

    @State private var viewport = RemoteViewportState()
    @State private var viewportPanningMode: RemoteViewportPanningMode
    @State private var pointerMode: RemotePointerMode
    @State private var keyboardActive = false
    @State private var confirmPasswordSend = false
    @State private var curtainPromptPresented = false
    @State private var keyboardCapture: VNCKeyboardCapture
    #if canImport(UIKit)
    @State private var keyboardViewportMetrics = DockedKeyboardViewportMetrics()
    @State private var hardwareKeyboardAttached = false
    #endif

    #if !canImport(UIKit)
    @State private var lastFallbackMagnification: CGFloat = 1
    @State private var fallbackDragRemotePoint: CGPoint?
    #endif

    private let touchHandler: TouchInputHandler
    private let keyboardHandler: KeyboardInputHandler
    private let isFullScreen: Bool
    private let toggleFullScreen: (() -> Void)?
    private let hudMenuExtras: AnyView?
    private let keyboardAvoidanceMode: VNCKeyboardAvoidanceMode
    private let clipboardSynchronizer: VNCClipboardSynchronizer?
    private let onSharedClipboardUserChange: (@MainActor (Bool) -> Void)?
    private let hostOwnsRecoveryChrome: Bool
    private let brightnessGain: Double
    private let pointerSpeed: Double
    /// On-screen height of the locally drawn pointer, in view points. The
    /// host owns this because only it knows the display the desktop is being
    /// viewed on and what the user asked for.
    private let cursorHeight: CGFloat

    #if canImport(UIKit)
    /// A host-provided accessory can remain visible without the software
    /// keyboard, so it must keep its measured clearance. When neither is
    /// active, any nonzero layout-guide value is stale and must be ignored.
    private var shouldReserveKeyboardInset: Bool {
        keyboardActive || keyboardCapture.inputViews.accessory != nil
    }
    #endif

    public init(
        session: VNCSession,
        keyboardCapture: VNCKeyboardCapture? = nil,
        isFullScreen: Bool = false,
        toggleFullScreen: (() -> Void)? = nil,
        keyboardAvoidanceMode: VNCKeyboardAvoidanceMode = .automatic,
        clipboardSynchronizer: VNCClipboardSynchronizer? = nil,
        initialViewportPanningMode: RemoteViewportPanningMode = .edge,
        initialPointerMode: RemotePointerMode = .direct,
        pointerSpeed: Double = 1.0,
        cursorHeight: CGFloat = 17,
        onSharedClipboardUserChange: (@MainActor (Bool) -> Void)? = nil,
        hostOwnsRecoveryChrome: Bool = false,
        brightnessGain: Double = 1.0
    ) {
        self.init(
            session: session,
            keyboardCapture: keyboardCapture,
            isFullScreen: isFullScreen,
            toggleFullScreen: toggleFullScreen,
            keyboardAvoidanceMode: keyboardAvoidanceMode,
            clipboardSynchronizer: clipboardSynchronizer,
            initialViewportPanningMode: initialViewportPanningMode,
            initialPointerMode: initialPointerMode,
            pointerSpeed: pointerSpeed,
            cursorHeight: cursorHeight,
            onSharedClipboardUserChange: onSharedClipboardUserChange,
            hostOwnsRecoveryChrome: hostOwnsRecoveryChrome,
            brightnessGain: brightnessGain,
            hudMenuExtras: nil)
    }

    /// Creates a remote desktop view whose HUD menu shows extra items between
    /// the built-in viewport controls and the password/disconnect actions.
    ///
    /// The extras are captured once at init and type-erased; container apps
    /// that want live state in these items should pass views that read their
    /// own `@Observable` models so the hosted menu re-renders on change.
    public init<MenuExtras: View>(
        session: VNCSession,
        keyboardCapture: VNCKeyboardCapture? = nil,
        isFullScreen: Bool = false,
        toggleFullScreen: (() -> Void)? = nil,
        keyboardAvoidanceMode: VNCKeyboardAvoidanceMode = .automatic,
        clipboardSynchronizer: VNCClipboardSynchronizer? = nil,
        initialViewportPanningMode: RemoteViewportPanningMode = .edge,
        initialPointerMode: RemotePointerMode = .direct,
        pointerSpeed: Double = 1.0,
        cursorHeight: CGFloat = 17,
        onSharedClipboardUserChange: (@MainActor (Bool) -> Void)? = nil,
        hostOwnsRecoveryChrome: Bool = false,
        brightnessGain: Double = 1.0,
        @ViewBuilder hudMenuExtras: () -> MenuExtras
    ) {
        self.init(
            session: session,
            keyboardCapture: keyboardCapture,
            isFullScreen: isFullScreen,
            toggleFullScreen: toggleFullScreen,
            keyboardAvoidanceMode: keyboardAvoidanceMode,
            clipboardSynchronizer: clipboardSynchronizer,
            initialViewportPanningMode: initialViewportPanningMode,
            initialPointerMode: initialPointerMode,
            pointerSpeed: pointerSpeed,
            cursorHeight: cursorHeight,
            onSharedClipboardUserChange: onSharedClipboardUserChange,
            hostOwnsRecoveryChrome: hostOwnsRecoveryChrome,
            brightnessGain: brightnessGain,
            hudMenuExtras: AnyView(hudMenuExtras()))
    }

    private init(
        session: VNCSession,
        keyboardCapture: VNCKeyboardCapture?,
        isFullScreen: Bool,
        toggleFullScreen: (() -> Void)?,
        keyboardAvoidanceMode: VNCKeyboardAvoidanceMode,
        clipboardSynchronizer: VNCClipboardSynchronizer?,
        initialViewportPanningMode: RemoteViewportPanningMode,
        initialPointerMode: RemotePointerMode,
        pointerSpeed: Double,
        cursorHeight: CGFloat,
        onSharedClipboardUserChange: (@MainActor (Bool) -> Void)?,
        hostOwnsRecoveryChrome: Bool,
        brightnessGain: Double,
        hudMenuExtras: AnyView?
    ) {
        self.session = session
        self.hostOwnsRecoveryChrome = hostOwnsRecoveryChrome
        self.hudMenuExtras = hudMenuExtras
        self._viewportPanningMode = State(initialValue: initialViewportPanningMode)
        self._pointerMode = State(initialValue: initialPointerMode)
        self.pointerSpeed = pointerSpeed
        self.cursorHeight = cursorHeight
        self._keyboardCapture = State(
            initialValue: keyboardCapture ?? VNCKeyboardCapture())
        self.isFullScreen = isFullScreen
        self.toggleFullScreen = toggleFullScreen
        self.keyboardAvoidanceMode = keyboardAvoidanceMode
        self.clipboardSynchronizer = clipboardSynchronizer
        self.onSharedClipboardUserChange = onSharedClipboardUserChange
        self.brightnessGain = brightnessGain
        self.touchHandler = TouchInputHandler(
            sendPointerEvent: { [session] buttonMask, x, y in
                session.sendPointerEvent(buttonMask: buttonMask, x: x, y: y)
            },
            sendScrollEvent: { [session] event in
                session.sendScrollEvent(event)
            },
            sendGestureEvent: { [session] event in
                session.sendGestureEvent(event)
            })
        self.keyboardHandler = KeyboardInputHandler(
            sendKeyEvent: { [session] downFlag, key in
                session.sendKeyEvent(downFlag: downFlag, key: key)
            },
            usesAppleModifierConvention: { [session] in
                session.serverUsesAppleModifierConvention
            })
    }

    /// Reads the server's reported state, never a local optimistic one, so the
    /// switch cannot claim the remote screen is hidden when it isn't. Turning it
    /// on opens the message prompt first; turning it off is immediate, matching
    /// Apple's client.
    private var curtainBinding: Binding<Bool> {
        Binding(
            get: { session.isCurtained },
            set: { enabled in
                if enabled {
                    curtainPromptPresented = true
                } else {
                    session.setCurtainMode(false)
                }
            })
    }

    public var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                let framebufferSize = session.presentedFramebufferSize
                let framebufferOrigin = session.presentedInputOrigin

                ZStack {
                    Color.black
                        .ignoresSafeArea()

                    desktopContent(in: geometry.size)
                        .scaleEffect(viewport.scale)
                        .offset(viewport.offset)

                    if session.connectionState.isConnected,
                       framebufferSize.width > 0,
                       framebufferSize.height > 0 {
                        interactionLayer(
                            viewSize: geometry.size,
                            framebufferSize: framebufferSize,
                            framebufferOrigin: framebufferOrigin)
                    }

                    viewportControls

                    VNCCurtainPrompt(
                        session: session,
                        isPresented: $curtainPromptPresented)

                    // Hosts that render their own reconnect/failure prompts
                    // suppress these; drawing both would stack duplicate
                    // cards now that the chrome is translucent.
                    if !hostOwnsRecoveryChrome {
                        recoveryOverlay
                    }
                }
                .clipped()
                .confirmationDialog(
                    String(localized: "Type the saved password?", bundle: .module),
                    isPresented: $confirmPasswordSend,
                    titleVisibility: .visible
                ) {
                    Button(String(localized: "Type Password and Log In", bundle: .module)) {
                        session.sendLoginPassword()
                    }
                    Button(String(localized: "Cancel", bundle: .module), role: .cancel) {}
                } message: {
                    Text(String(localized: "The password will be typed into the remote computer, followed by Return.", bundle: .module))
                }
                .onChange(of: geometry.size) { _, newSize in
                    viewport.clampOffset(
                        viewSize: newSize,
                        framebufferSize: framebufferSize)
                    #if !canImport(UIKit)
                    updateRemoteDisplaySize(for: newSize)
                    #endif
                }
                .onChange(of: framebufferSize) { _, newSize in
                    viewport.clampOffset(
                        viewSize: geometry.size,
                        framebufferSize: newSize)
                }
                .onAppear {
                    presentPendingLoginPasswordPrompt()
                    #if !canImport(UIKit)
                    updateRemoteDisplaySize(for: geometry.size)
                    #endif
                }
                .onChange(of: session.loginPasswordPromptPending) { _, pending in
                    if pending {
                        presentPendingLoginPasswordPrompt()
                    }
                }
                .onChange(of: displayScale) { _, _ in
                    #if canImport(UIKit)
                    updateRemoteDisplaySizeFromMeasuredContainer()
                    #else
                    updateRemoteDisplaySize(for: geometry.size)
                    #endif
                }
                .onChange(of: session.connectionState) { _, newState in
                    if newState.isConnected {
                        #if canImport(UIKit)
                        updateRemoteDisplaySizeFromMeasuredContainer()
                        #else
                        updateRemoteDisplaySize(for: geometry.size)
                        #endif
                    } else {
                        confirmPasswordSend = false
                        curtainPromptPresented = false
                    }
                }
                .onChange(of: session.configuration.displaySizingMode) { _, mode in
                    if mode == .matchClient {
                        #if canImport(UIKit)
                        updateRemoteDisplaySizeFromMeasuredContainer()
                        #else
                        updateRemoteDisplaySize(for: geometry.size)
                        #endif
                    }
                }
            }

            #if canImport(UIKit)
            if keyboardAvoidanceMode == .automatic {
                Color.clear
                    // Keyboard layout-guide callbacks can arrive out of order
                    // during dismissal/reparenting. Once neither the software
                    // keyboard nor an accessory is active, ignore stale data.
                    .frame(height: keyboardViewportMetrics.effectiveInset(
                        reservingObstruction: shouldReserveKeyboardInset))
                    .accessibilityHidden(true)
            }
            #endif
        }
        // Two-way sync with the host-visible keyboard request. The local
        // @State stays authoritative for HUD-driven changes; the equality
        // guards prevent onChange ping-pong between the two sources.
        .onChange(of: keyboardActive) { _, active in
            if keyboardCapture.softwareKeyboardRequested != active {
                keyboardCapture.softwareKeyboardRequested = active
            }
            #if canImport(UIKit)
            updateRemoteDisplaySizeFromMeasuredContainer()
            #endif
        }
        .onChange(of: keyboardCapture.softwareKeyboardRequested) { _, requested in
            if keyboardActive != requested {
                keyboardActive = requested
            }
        }
        #if canImport(UIKit)
        .background {
            DockedKeyboardInsetReader(metrics: $keyboardViewportMetrics)
        }
        // UIKit's layout guide distinguishes a bottom-docked keyboard from
        // floating and split keyboards; SwiftUI's safe area does not.
        .ignoresSafeArea(.keyboard)
        .onChange(of: keyboardViewportMetrics) { _, _ in
            updateRemoteDisplaySizeFromMeasuredContainer()
        }
        .onChange(of: keyboardAvoidanceMode) { _, _ in
            updateRemoteDisplaySizeFromMeasuredContainer()
        }
        .onChange(of: keyboardCapture.inputViewsGeneration) { _, _ in
            updateRemoteDisplaySizeFromMeasuredContainer()
        }
        #endif
    }

    @ViewBuilder
    private func desktopContent(in viewSize: CGSize) -> some View {
        if session.isHighPerformanceMode {
            #if canImport(UIKit)
            AdaptiveDisplayView(
                primaryRenderer: session.videoBandRenderer,
                secondaryRenderer: session.secondaryVideoBandRenderer,
                displayRegions: session.presentedVideoDisplayRegions,
                brightnessGain: brightnessGain)
                .frame(width: viewSize.width, height: viewSize.height)
            #else
            placeholderView
                .frame(width: viewSize.width, height: viewSize.height)
            #endif
        } else {
            StandardFramebufferContent(
                session: session,
                showsWaitingCard: !hostOwnsRecoveryChrome,
                brightnessGain: brightnessGain)
                .frame(width: viewSize.width, height: viewSize.height)
        }
    }

    @ViewBuilder
    private func interactionLayer(
        viewSize: CGSize,
        framebufferSize: CGSize,
        framebufferOrigin: CGPoint
    ) -> some View {
        #if canImport(UIKit)
        RemoteInteractionView(
            viewport: $viewport,
            viewportPanningMode: viewportPanningMode,
            pointerMode: pointerMode,
            pointerSpeed: pointerSpeed,
            cursorHeight: cursorHeight,
            serverRendersCursor: session.activeCursorRendering == .server,
            keyboardActive: $keyboardActive,
            hardwareKeyboardAttached: $hardwareKeyboardAttached,
            framebufferSize: framebufferSize,
            touchHandler: touchHandler,
            keyboardHandler: keyboardHandler,
            keyboardCapture: keyboardCapture,
            suspendsKeyboardCapture: curtainPromptPresented,
            framebufferOrigin: framebufferOrigin,
            requestPasswordSend: requestPasswordSend,
            requestDictation: requestDictation,
            toggleFullScreen: toggleFullScreen,
            disconnect: { session.disconnect() },
            // Apple's adaptive profile asks the server for cached cursor
            // images so the responsive local pointer can adopt their shape.
            remoteCursor: session.remoteCursor,
            remoteCursorPresence: session.remoteCursorPresence)
            .frame(width: viewSize.width, height: viewSize.height)
            .contentShape(Rectangle())
        #else
        Color.clear
            .contentShape(Rectangle())
            .gesture(fallbackTapGesture(
                viewSize: viewSize,
                framebufferSize: framebufferSize,
                framebufferOrigin: framebufferOrigin))
            .simultaneousGesture(fallbackDragGesture(
                viewSize: viewSize,
                framebufferSize: framebufferSize,
                framebufferOrigin: framebufferOrigin))
            .simultaneousGesture(fallbackMagnificationGesture(
                viewSize: viewSize,
                framebufferSize: framebufferSize))
        #endif
    }

    @ViewBuilder
    private var viewportControls: some View {
        #if canImport(UIKit)
        DraggableHUDOverlay {
            hudMenu
        }
        #else
        VStack {
            Spacer()
            HStack {
                Spacer()
                hudMenu
            }
            .padding(12)
        }
        .allowsHitTesting(true)
        #endif
    }

    @ViewBuilder
    private var hudMenu: some View {
        Menu {
            Button {
                requestPasswordSend()
            } label: {
                Label(String(localized: "Type User Password", bundle: .module), systemImage: "key.fill")
            }
            .disabled(!session.canSendLoginPassword)

            #if canImport(UIKit)
            if !hardwareKeyboardAttached {
                Button {
                    keyboardCapture.capture()
                    keyboardActive.toggle()
                } label: {
                    Label(
                        keyboardActive
                            ? String(localized: "Hide Keyboard", bundle: .module)
                            : String(localized: "Show Keyboard", bundle: .module),
                        systemImage: keyboardActive
                            ? "keyboard.chevron.compact.down" : "keyboard")
                }
            }

            if let hudMenuExtras {
                hudMenuExtras
            }

            keyboardCaptureControl
            Toggle(isOn: Binding(
                get: { keyboardCapture.controlOptionAsCommand },
                set: { keyboardCapture.controlOptionAsCommand = $0 }
            )) {
                Label(String(localized: "Control+Option as Command", bundle: .module), systemImage: "keyboard")
            }
            remoteCommandsMenu
            #endif

            displayMenu

            if let toggleFullScreen {
                Button(action: toggleFullScreen) {
                    Label(
                        isFullScreen
                            ? String(localized: "Exit Full Screen", bundle: .module)
                            : String(localized: "Enter Full Screen", bundle: .module),
                        systemImage: isFullScreen
                            ? "arrow.down.right.and.arrow.up.left"
                            : "arrow.up.left.and.arrow.down.right")
                }
            }

            if let clipboardSynchronizer {
                VNCClipboardMenu(
                    synchronizer: clipboardSynchronizer,
                    onSharedClipboardUserChange: onSharedClipboardUserChange
                )
            }

            Divider()

            Button(role: .destructive) {
                session.disconnect()
            } label: {
                Label(String(localized: "Close Connection", bundle: .module), systemImage: "xmark.circle")
            }
        } label: {
            Image(systemName: "line.3.horizontal")
                .font(.body.weight(.bold))
                .frame(width: 46, height: 46)
                .modifier(HUDButtonChromeModifier())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .accessibilityLabel(String(localized: "Remote Desktop Controls", bundle: .module))
        .help(String(localized: "Remote Desktop Controls", bundle: .module))
    }

    #if canImport(UIKit)
    @ViewBuilder
    private var keyboardCaptureControl: some View {
        if keyboardCapture.hasReservedHostShortcuts {
            if hardwareKeyboardAttached {
                Toggle(isOn: Binding(
                    get: { keyboardCapture.routesReservedHostShortcutsToVNC },
                    set: { keyboardCapture.routeReservedHostShortcutsToVNC($0) }
                )) {
                    Label(String(localized: "Route Reserved Shortcuts to VNC", bundle: .module), systemImage: "keyboard.badge.ellipsis")
                }
            }
        } else {
            Button {
                keyboardCapture.toggle()
                if !keyboardCapture.isCaptured {
                    keyboardActive = false
                }
            } label: {
                Label(
                    keyboardCapture.isCaptured
                        ? String(localized: "Release Keyboard Capture", bundle: .module)
                        : String(localized: "Capture Keyboard", bundle: .module),
                    systemImage: keyboardCapture.isCaptured
                        ? "keyboard.badge.ellipsis" : "keyboard")
            }
        }
    }

    private var remoteCommandsMenu: some View {
        Menu {
            Menu(String(localized: "Editing", bundle: .module)) {
                remoteShortcutButtons(RemoteMenuShortcut.editing)
            }
            Menu(String(localized: "Apps and Windows", bundle: .module)) {
                remoteShortcutButtons(RemoteMenuShortcut.applications)
            }
            Menu(String(localized: "Documents and Tabs", bundle: .module)) {
                remoteShortcutButtons(RemoteMenuShortcut.documents)
            }
            Menu(String(localized: "Special Keys", bundle: .module)) {
                remoteShortcutButtons(RemoteMenuShortcut.keys)
            }

            Section(String(localized: "Mac Specific", bundle: .module)) {
                ForEach(RemoteCommand.macSpecific) { command in
                    Button(command.title) {
                        keyboardHandler.handleRemoteCommand(command)
                    }
                }
            }

            Section(String(localized: "Other Commands", bundle: .module)) {
                Button(String(localized: "Dictate", bundle: .module)) {
                    requestDictation()
                }

                ForEach(RemoteCommand.otherCommands) { command in
                    Button(command.title) {
                        keyboardHandler.handleRemoteCommand(command)
                    }
                }
            }
        } label: {
            Label(
                String(localized: "Commands", bundle: .module),
                systemImage: "command")
        }
    }

    private func remoteShortcutButtons(_ shortcuts: [RemoteMenuShortcut]) -> some View {
        ForEach(shortcuts) { shortcut in
            Button(shortcut.menuTitle) {
                keyboardHandler.handleShortcutTap(shortcut.character, modifiers: shortcut.modifiers)
            }
        }
    }
    #endif

    /// Viewport controls and remote-display privacy belong together. Grouping
    /// them keeps the top level short without hiding any capability.
    @ViewBuilder
    private var displayMenu: some View {
        Menu {
            Menu {
                ForEach(RemoteViewportPanningMode.allCases, id: \.self) { mode in
                    Button {
                        viewportPanningMode = mode
                    } label: {
                        Label(
                            viewportPanningModeTitle(mode),
                            systemImage: viewportPanningMode == mode
                                ? "checkmark"
                                : viewportPanningModeImage(mode))
                    }
                    .disabled(viewportPanningMode == mode)
                }
            } label: {
                Label(
                    String(localized: "Screen Panning", bundle: .module),
                    systemImage: "cursorarrow.motionlines")
            }

            Menu {
                ForEach(RemotePointerMode.allCases, id: \.self) { mode in
                    Button {
                        pointerMode = mode
                    } label: {
                        Label(
                            pointerModeTitle(mode),
                            systemImage: pointerMode == mode
                                ? "checkmark"
                                : pointerModeImage(mode))
                    }
                    .disabled(pointerMode == mode)
                }
            } label: {
                Label(
                    String(localized: "Pointer", bundle: .module),
                    systemImage: "cursorarrow.rays")
            }

            Button {
                viewport.reset()
            } label: {
                Label(String(localized: "Fit Screen", bundle: .module), systemImage: "arrow.down.right.and.arrow.up.left")
            }
            .disabled(viewport.isIdentity)

            if session.supportsCurtainMode {
                Toggle(isOn: curtainBinding) {
                    Label(
                        String(localized: "Curtain Mode", bundle: .module),
                        systemImage: session.isCurtained
                            ? "eye.slash.fill"
                            : "eye.slash")
                }
            }
        } label: {
            Label(
                String(localized: "Display", bundle: .module),
                systemImage: "display")
        }
    }

    private func requestPasswordSend() {
        guard session.canSendLoginPassword else { return }
        confirmPasswordSend = true
    }

    private func presentPendingLoginPasswordPrompt() {
        guard session.loginPasswordPromptPending else { return }
        guard session.consumeLoginPasswordPromptRequest() else { return }
        confirmPasswordSend = true
    }

    private func requestDictation() {
        keyboardCapture.capture()
        keyboardActive = true
    }

    private var placeholderView: some View {
        VStack(spacing: 16) {
            switch session.connectionState {
            case .connecting:
                ProgressView().controlSize(.large)
                Text(String(localized: "Connecting...", bundle: .module)).foregroundStyle(.secondary)
            case .connected:
                ProgressView().controlSize(.large)
                Text(String(localized: "Waiting for framebuffer...", bundle: .module)).foregroundStyle(.secondary)
            case .reconnecting(let attempt, _):
                ProgressView().controlSize(.large)
                Text(String(localized: "Reconnecting (attempt \(attempt))...", bundle: .module))
                    .foregroundStyle(.secondary)
            case .failed(let reason):
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(.red)
                Text(String(localized: "Connection Failed", bundle: .module)).font(.headline)
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            case .disconnected:
                Image(systemName: "rectangle.slash")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text(String(localized: "Disconnected", bundle: .module)).foregroundStyle(.secondary)
            case .idle, .disconnecting:
                Image(systemName: "desktopcomputer")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text(String(localized: "No Active Connection", bundle: .module)).foregroundStyle(.secondary)
            }
        }
    }

    private func viewportPanningModeTitle(
        _ mode: RemoteViewportPanningMode
    ) -> String {
        switch mode {
        case .edge:
            return String(
                localized: "When Pointer Reaches Edge",
                bundle: .module)
        case .continuous:
            return String(
                localized: "Continuously with Pointer",
                bundle: .module)
        }
    }

    private func viewportPanningModeImage(
        _ mode: RemoteViewportPanningMode
    ) -> String {
        switch mode {
        case .edge:
            return "arrow.up.left.and.arrow.down.right"
        case .continuous:
            return "cursorarrow.rays"
        }
    }

    private func pointerModeTitle(_ mode: RemotePointerMode) -> String {
        switch mode {
        case .direct:
            return String(localized: "Touch", bundle: .module)
        case .trackpad:
            return String(localized: "Trackpad", bundle: .module)
        }
    }

    private func pointerModeImage(_ mode: RemotePointerMode) -> String {
        switch mode {
        case .direct:
            return "hand.point.up.left"
        case .trackpad:
            return "rectangle.and.hand.point.up.left"
        }
    }

    @ViewBuilder
    private var recoveryOverlay: some View {
        switch session.connectionState {
        case .reconnecting:
            ConnectionStatusOverlay(session: session)

        case .failed(let reason):
            VStack(spacing: 10) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.title)
                Text(String(localized: "Unable to reconnect", bundle: .module)).font(.headline)
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                HStack {
                    Button(String(localized: "Try Again", bundle: .module)) { session.retryConnection() }
                        .buttonStyle(.borderedProminent)
                    Button(String(localized: "Disconnect", bundle: .module), role: .destructive) { session.disconnect() }
                        .buttonStyle(.bordered)
                }
            }
            .padding(20)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .padding()

        default:
            EmptyView()
        }
    }

    private func updateRemoteDisplaySize(for viewSize: CGSize) {
        session.updateRemoteDisplaySize(
            viewSize: viewSize,
            displayScale: displayScale)
    }

    #if canImport(UIKit)
    private func updateRemoteDisplaySizeFromMeasuredContainer() {
        let size = keyboardAvoidanceMode == .automatic
            ? keyboardViewportMetrics.availableSize(
                reservingObstruction: shouldReserveKeyboardInset)
            : keyboardViewportMetrics.containerSize
        guard size.width > 0, size.height > 0 else { return }
        updateRemoteDisplaySize(for: size)
    }
    #endif

    #if !canImport(UIKit)
    private func fallbackTapGesture(
        viewSize: CGSize,
        framebufferSize: CGSize,
        framebufferOrigin: CGPoint
    ) -> some Gesture {
        SpatialTapGesture()
            .onEnded { value in
                guard let point = remotePoint(
                    value.location,
                    viewSize: viewSize,
                    framebufferSize: framebufferSize,
                    framebufferOrigin: framebufferOrigin) else { return }
                touchHandler.handleTap(x: point.x, y: point.y)
            }
    }

    private func fallbackDragGesture(
        viewSize: CGSize,
        framebufferSize: CGSize,
        framebufferOrigin: CGPoint
    ) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                guard let point = remotePoint(
                    value.location,
                    viewSize: viewSize,
                    framebufferSize: framebufferSize,
                    framebufferOrigin: framebufferOrigin) else { return }
                fallbackDragRemotePoint = CGPoint(x: CGFloat(point.x), y: CGFloat(point.y))
                touchHandler.handleDrag(x: point.x, y: point.y)
            }
            .onEnded { value in
                let mapped = remotePoint(
                    value.location,
                    viewSize: viewSize,
                    framebufferSize: framebufferSize,
                    framebufferOrigin: framebufferOrigin)
                let finalPoint = mapped ?? fallbackDragRemotePoint.map({
                    (x: UInt16($0.x), y: UInt16($0.y))
                })
                fallbackDragRemotePoint = nil
                guard let finalPoint else { return }
                touchHandler.handleDragEnd(x: finalPoint.x, y: finalPoint.y)
            }
    }

    private func fallbackMagnificationGesture(
        viewSize: CGSize,
        framebufferSize: CGSize
    ) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let incremental = value.magnification / lastFallbackMagnification
                viewport.zoom(
                    by: incremental,
                    around: value.startAnchor.point(in: viewSize),
                    viewSize: viewSize,
                    framebufferSize: framebufferSize)
                lastFallbackMagnification = value.magnification
            }
            .onEnded { _ in
                lastFallbackMagnification = 1
            }
    }

    private func remotePoint(
        _ point: CGPoint,
        viewSize: CGSize,
        framebufferSize: CGSize,
        framebufferOrigin: CGPoint = .zero
    ) -> (x: UInt16, y: UInt16)? {
        guard let mapped = viewport.framebufferPoint(
            for: point,
            viewSize: viewSize,
            framebufferSize: framebufferSize) else { return nil }
        return (
            UInt16(min(CGFloat(UInt16.max), mapped.x + framebufferOrigin.x)),
            UInt16(min(CGFloat(UInt16.max), mapped.y + framebufferOrigin.y)))
    }
    #endif
}

/// Shared HUD submenu used by both the package demo and container apps.
/// Hosts the curtain prompts on their own, deliberately frame-independent view.
///
/// `RemoteDesktopView.body` re-evaluates on every decoded frame, and an alert
/// whose text field is bound to state up there is rebuilt on each keystroke,
/// which drops keyboard focus after every character. Keeping the draft message
/// as this view's own state, and reading nothing that changes per frame, means
/// typing only invalidates this zero-sized view.
private struct VNCCurtainPrompt: View {
    @Bindable var session: VNCSession
    @Binding var isPresented: Bool
    @State private var message = ""

    private var failureBinding: Binding<Bool> {
        Binding(
            get: { session.curtainChangeFailed },
            set: { presented in
                if !presented { session.acknowledgeCurtainFailure() }
            })
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .alert(
                String(localized: "Turn On Curtain Mode?", bundle: .module),
                isPresented: $isPresented
            ) {
                TextField(
                    String(localized: "optional message", bundle: .module),
                    text: $message)
                Button(String(localized: "Curtain", bundle: .module)) {
                    session.setCurtainMode(true, message: message)
                    message = ""
                }
                Button(String(localized: "Cancel", bundle: .module), role: .cancel) {
                    message = ""
                }
            } message: {
                Text(String(localized: "The remote computer's own display will be hidden while you keep control. Anyone at that computer sees a lock screen with your message.", bundle: .module))
            }
            .alert(
                String(localized: "Curtain Mode Did Not Change", bundle: .module),
                isPresented: failureBinding
            ) {
                Button(String(localized: "OK", bundle: .module), role: .cancel) {}
            } message: {
                Text(String(localized: "The remote computer did not confirm the change, so its display may still be visible to anyone nearby.", bundle: .module))
            }
    }
}

private struct VNCClipboardMenu: View {
    @Bindable var synchronizer: VNCClipboardSynchronizer
    let onSharedClipboardUserChange: (@MainActor (Bool) -> Void)?

    private var sharedClipboardBinding: Binding<Bool> {
        Binding(
            get: { synchronizer.sharedClipboardEnabled },
            set: { enabled in
                synchronizer.sharedClipboardEnabled = enabled
                onSharedClipboardUserChange?(enabled)
            }
        )
    }

    var body: some View {
        Menu {
            Button {
                synchronizer.getClipboard()
            } label: {
                Label(String(localized: "Get Clipboard", bundle: .module), systemImage: "arrow.down.doc")
            }
            .disabled(!synchronizer.canGetClipboard)

            Button {
                synchronizer.sendClipboard()
            } label: {
                Label(String(localized: "Send Clipboard", bundle: .module), systemImage: "arrow.up.doc")
            }
            .disabled(!synchronizer.canSendClipboard)

            Divider()

            Toggle(isOn: sharedClipboardBinding) {
                Label(String(localized: "Shared Clipboard", bundle: .module), systemImage: "arrow.triangle.2.circlepath")
            }
        } label: {
            Label(String(localized: "Clipboard", bundle: .module), systemImage: "doc.on.clipboard")
        }
    }
}

#if canImport(UIKit)
/// Reports only the space occupied by a keyboard docked to the bottom edge.
/// UIKit collapses this guide for floating, split, and detached keyboards.
private struct DockedKeyboardInsetReader: UIViewRepresentable {
    @Binding var metrics: DockedKeyboardViewportMetrics

    func makeUIView(context: Context) -> DockedKeyboardInsetView {
        let view = DockedKeyboardInsetView()
        view.onMetricsChange = { newMetrics in
            context.coordinator.setMetrics(newMetrics)
        }
        return view
    }

    func updateUIView(
        _ uiView: DockedKeyboardInsetView,
        context: Context
    ) {
        context.coordinator.parent = self
        uiView.setNeedsLayout()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    @MainActor
    final class Coordinator {
        var parent: DockedKeyboardInsetReader

        init(parent: DockedKeyboardInsetReader) {
            self.parent = parent
        }

        func setMetrics(_ metrics: DockedKeyboardViewportMetrics) {
            guard !parent.metrics.isApproximatelyEqual(to: metrics) else { return }
            parent.metrics = metrics
        }
    }
}

@MainActor
private final class DockedKeyboardInsetView: UIView {
    var onMetricsChange: ((DockedKeyboardViewportMetrics) -> Void)?
    private var lastReportedMetrics: DockedKeyboardViewportMetrics?
    private let keyboardTopProbe = UIView(frame: .zero)
    private var keyboardTransitionInProgress = false
    private var metricsPublishGeneration: UInt = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear

        // The default is already false, but make the intended floating and
        // split-keyboard behavior explicit.
        keyboardLayoutGuide.followsUndockedKeyboard = false
        if #available(iOS 17.0, *) {
            // An absent or detached keyboard should report zero rather than
            // the device's bottom safe-area inset.
            keyboardLayoutGuide.usesBottomSafeArea = false
        }

        keyboardTopProbe.isHidden = true
        keyboardTopProbe.translatesAutoresizingMaskIntoConstraints = false
        addSubview(keyboardTopProbe)
        NSLayoutConstraint.activate([
            keyboardTopProbe.topAnchor.constraint(
                equalTo: keyboardLayoutGuide.topAnchor),
            keyboardTopProbe.leadingAnchor.constraint(equalTo: leadingAnchor),
            keyboardTopProbe.widthAnchor.constraint(equalToConstant: 0),
            keyboardTopProbe.heightAnchor.constraint(equalToConstant: 0),
        ])

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardFrameWillChange),
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardFrameDidChange),
            name: UIResponder.keyboardDidChangeFrameNotification,
            object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardDidHide),
            name: UIResponder.keyboardDidHideNotification,
            object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        if !keyboardTransitionInProgress {
            publishCurrentMetrics()
        }
    }

    @objc private func keyboardFrameWillChange() {
        keyboardTransitionInProgress = true
    }

    @objc private func keyboardFrameDidChange() {
        keyboardTransitionInProgress = false
        setNeedsLayout()
        layoutIfNeeded()
        publishCurrentMetrics()
    }

    @objc private func keyboardDidHide() {
        keyboardTransitionInProgress = false
        publishMetrics(keyboardInset: 0)
    }

    private func publishCurrentMetrics() {
        let inset = max(0, bounds.maxY - keyboardTopProbe.frame.minY)
        publishMetrics(keyboardInset: inset)
    }

    private func publishMetrics(keyboardInset: CGFloat) {
        let metrics = DockedKeyboardViewportMetrics(
            containerSize: bounds.size,
            keyboardInset: keyboardInset)
        guard lastReportedMetrics?.isApproximatelyEqual(to: metrics) != true else {
            return
        }
        lastReportedMetrics = metrics
        metricsPublishGeneration &+= 1
        let generation = metricsPublishGeneration

        // Avoid publishing SwiftUI state during a UIKit layout pass.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.metricsPublishGeneration == generation else { return }
            self.onMetricsChange?(metrics)
        }
    }
}
#endif

/// Circle chrome for the HUD menu button: Liquid Glass on current OS
/// releases and a material fallback where the glass API is unavailable.
/// Deliberately not host-tinted — the button floats over live desktop
/// content, where adaptive glass fits better than theme colors.
private struct HUDButtonChromeModifier: ViewModifier {
    func body(content: Content) -> some View {
        #if os(visionOS)
        content.background(.ultraThinMaterial, in: Circle())
        #else
        if #available(iOS 26.0, macOS 26.0, macCatalyst 26.0, *) {
            content.glassEffect(.regular, in: Circle())
        } else {
            content.background(.ultraThinMaterial, in: Circle())
        }
        #endif
    }
}

/// Owns the hot standard-framebuffer observation so publishing a new image
/// does not invalidate the parent view that owns the HUD Menu.
private struct StandardFramebufferContent: View {
    @Bindable var session: VNCSession
    /// False when the host renders its own connected-but-no-frame prompt.
    let showsWaitingCard: Bool
    let brightnessGain: Double

    var body: some View {
        if let image = session.currentImage {
            let displayedImage = cropped(image) ?? image
            Image(decorative: displayedImage, scale: 1)
                .interpolation(.high)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .overlay {
                    #if canImport(UIKit) || canImport(AppKit)
                    VNCEDRImageView(
                        image: displayedImage,
                        brightnessGain: brightnessGain)
                        .allowsHitTesting(false)
                    #endif
                }
        } else if showsWaitingCard, session.connectionState.isConnected {
            // Handshake finished but no framebuffer content has been
            // published. The reconnect/failure overlays own the other states.
            ConnectionStatusCard(
                title: String(localized: "Waiting for first screen update…", bundle: .module),
                detail: session.connectingHostLabel,
                actionLabel: String(localized: "Cancel", bundle: .module),
                actionRole: .cancel
            ) { session.disconnect() }
        }
    }

    private func cropped(_ image: CGImage) -> CGImage? {
        guard let region = session.presentedFramebufferRegion else { return nil }
        let imageBounds = CGRect(
            x: 0, y: 0,
            width: image.width, height: image.height)
        let crop = region.integral.intersection(imageBounds)
        guard !crop.isEmpty, crop != imageBounds else { return nil }
        return image.cropping(to: crop)
    }
}

#if canImport(UIKit)
/// Keeps each display in its own decoder-backed renderer and positions it in
/// the server's normalized desktop coordinate space.
private struct AdaptiveDisplayView: View {
    let primaryRenderer: VideoBandLayerRenderer
    let secondaryRenderer: VideoBandLayerRenderer
    let displayRegions: [CGRect]
    let brightnessGain: Double

    var body: some View {
        GeometryReader { geometry in
            let regions = displayRegions.isEmpty
                ? [CGRect(origin: .zero, size: geometry.size)]
                : displayRegions
            let union = regions.dropFirst().reduce(regions[0]) { $0.union($1) }
            let scale = min(
                geometry.size.width / max(1, union.width),
                geometry.size.height / max(1, union.height))
            let origin = CGPoint(
                x: (geometry.size.width - union.width * scale) / 2,
                y: (geometry.size.height - union.height * scale) / 2)

            ZStack(alignment: .topLeading) {
                videoDisplay(
                    renderer: primaryRenderer,
                    region: regions[0],
                    scale: scale,
                    origin: origin)
                if regions.count > 1 {
                    videoDisplay(
                        renderer: secondaryRenderer,
                        region: regions[1],
                        scale: scale,
                        origin: origin)
                }
            }
        }
        .background(Color.black)
    }

    private func videoDisplay(
        renderer: VideoBandLayerRenderer,
        region: CGRect,
        scale: CGFloat,
        origin: CGPoint
    ) -> some View {
        VideoBandView(
            renderer: renderer,
            brightnessGain: brightnessGain)
            .frame(
                width: region.width * scale,
                height: region.height * scale)
            .offset(
                x: origin.x + region.minX * scale,
                y: origin.y + region.minY * scale)
    }
}
#endif

#if canImport(UIKit)
private struct VNCEDRImageView: UIViewRepresentable {
    let image: CGImage
    let brightnessGain: Double

    func makeUIView(context: Context) -> VNCEDRImageHostView {
        let view = VNCEDRImageHostView()
        view.update(image: image, gain: brightnessGain)
        return view
    }

    func updateUIView(_ uiView: VNCEDRImageHostView, context: Context) {
        uiView.update(image: image, gain: brightnessGain)
    }
}

@MainActor
private final class VNCEDRImageHostView: UIView {
    private let presenter = VNCBrightnessPresenter(contentsGravity: .resizeAspect)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        layer.addSublayer(presenter.layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(image: CGImage, gain: Double) {
        presenter.setSource(image, gain: gain)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        presenter.layer.frame = bounds
        CATransaction.commit()
    }
}
#elseif canImport(AppKit)
private struct VNCEDRImageView: NSViewRepresentable {
    let image: CGImage
    let brightnessGain: Double

    func makeNSView(context: Context) -> VNCEDRImageHostView {
        let view = VNCEDRImageHostView()
        view.update(image: image, gain: brightnessGain)
        return view
    }

    func updateNSView(_ nsView: VNCEDRImageHostView, context: Context) {
        nsView.update(image: image, gain: brightnessGain)
    }
}

@MainActor
private final class VNCEDRImageHostView: NSView {
    private let presenter = VNCBrightnessPresenter(contentsGravity: .resizeAspect)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.addSublayer(presenter.layer)
    }

    convenience init() { self.init(frame: .zero) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(image: CGImage, gain: Double) {
        presenter.setSource(image, gain: gain)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        presenter.layer.frame = bounds
        CATransaction.commit()
    }
}
#endif

#if !canImport(UIKit)
private extension UnitPoint {
    func point(in size: CGSize) -> CGPoint {
        CGPoint(x: x * size.width, y: y * size.height)
    }
}
#endif
