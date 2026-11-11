#if canImport(UIKit)
import SwiftUI
import RFBProtocol
import UIKit

/// Input sinks for a ``RemoteScreenView``. Pointer coordinates are framebuffer
/// pixels with an RFB button mask, and keys are X11 keysyms, so non-RFB hosts
/// translate from the same events VNC sessions receive. With
/// `sendPhysicalKey` set, hardware keys arrive by HID usage instead.
public struct RemoteScreenInput {
    public var sendPointer: TouchInputHandler.PointerEventHandler
    public var sendScroll: TouchInputHandler.ScrollEventHandler
    public var sendKeysym: KeyboardInputHandler.KeyEventHandler
    public var sendPhysicalKey: KeyboardInputHandler.PhysicalKeyEventHandler?
    public var usesAppleModifierConvention: @MainActor () -> Bool

    public init(
        sendPointer: @escaping TouchInputHandler.PointerEventHandler,
        sendScroll: @escaping TouchInputHandler.ScrollEventHandler,
        sendKeysym: @escaping KeyboardInputHandler.KeyEventHandler,
        sendPhysicalKey: KeyboardInputHandler.PhysicalKeyEventHandler? = nil,
        usesAppleModifierConvention: @escaping @MainActor () -> Bool = { false }
    ) {
        self.sendPointer = sendPointer
        self.sendScroll = sendScroll
        self.sendKeysym = sendKeysym
        self.sendPhysicalKey = sendPhysicalKey
        self.usesAppleModifierConvention = usesAppleModifierConvention
    }
}

/// A decoded video surface with the package's touch, trackpad, keyboard,
/// zoom and HUD layer, for remote screens that are not RFB sessions.
public struct RemoteScreenView: View {
    private let renderer: VideoBandLayerRenderer
    private let framebufferSize: CGSize
    private let isInteractive: Bool
    private let isFullScreen: Bool
    private let toggleFullScreen: (() -> Void)?
    private let keyboardAvoidanceMode: VNCKeyboardAvoidanceMode
    /// Edges whose safe area the HUD keeps clear of. A host that covers a
    /// system region (a full-screen takeover over a side rail) drops its edge.
    private let hudSafeAreaEdges: Edge.Set
    private let pointerSpeed: Double
    private let cursorHeight: CGFloat
    private let serverRendersCursor: Bool
    private let showsLocalCursorDot: Bool
    private let touchGestures: RemoteTouchGestureConfiguration
    private let brightnessGain: Double
    private let disconnect: () -> Void
    private let hudMenuExtras: AnyView?
    private let touchHandler: TouchInputHandler
    private let keyboardHandler: KeyboardInputHandler

    @State private var viewport = RemoteViewportState()
    @State private var viewportPanningMode: RemoteViewportPanningMode
    @State private var pointerMode: RemotePointerMode
    @State private var keyboardActive = false
    @State private var hardwareKeyboardAttached = false
    @State private var keyboardCapture: VNCKeyboardCapture
    @State private var keyboardViewportMetrics = DockedKeyboardViewportMetrics()

    /// `showsLocalCursorDot` marks where local pointer input lands over a
    /// picture that already carries the pointer; it has no effect unless
    /// `serverRendersCursor` is set.
    public init<MenuExtras: View>(
        renderer: VideoBandLayerRenderer,
        framebufferSize: CGSize,
        isInteractive: Bool,
        input: RemoteScreenInput,
        keyboardCapture: VNCKeyboardCapture,
        isFullScreen: Bool = false,
        toggleFullScreen: (() -> Void)? = nil,
        keyboardAvoidanceMode: VNCKeyboardAvoidanceMode = .automatic,
        hudSafeAreaEdges: Edge.Set = .all,
        initialViewportPanningMode: RemoteViewportPanningMode = .edge,
        initialPointerMode: RemotePointerMode = .direct,
        pointerSpeed: Double = 1.0,
        cursorHeight: CGFloat = 17,
        serverRendersCursor: Bool = true,
        showsLocalCursorDot: Bool = false,
        touchGestures: RemoteTouchGestureConfiguration = .standard,
        brightnessGain: Double = 1.0,
        disconnect: @escaping () -> Void,
        @ViewBuilder hudMenuExtras: () -> MenuExtras
    ) {
        self.renderer = renderer
        self.framebufferSize = framebufferSize
        self.isInteractive = isInteractive
        self.isFullScreen = isFullScreen
        self.toggleFullScreen = toggleFullScreen
        self.keyboardAvoidanceMode = keyboardAvoidanceMode
        self.hudSafeAreaEdges = hudSafeAreaEdges
        self.pointerSpeed = pointerSpeed
        self.cursorHeight = cursorHeight
        self.serverRendersCursor = serverRendersCursor
        self.showsLocalCursorDot = showsLocalCursorDot
        self.touchGestures = touchGestures
        self.brightnessGain = brightnessGain
        self.disconnect = disconnect
        self.hudMenuExtras = AnyView(hudMenuExtras())
        self._viewportPanningMode = State(initialValue: initialViewportPanningMode)
        self._pointerMode = State(initialValue: initialPointerMode)
        self._keyboardCapture = State(initialValue: keyboardCapture)
        self.touchHandler = TouchInputHandler(
            sendPointerEvent: input.sendPointer,
            sendScrollEvent: input.sendScroll)
        self.keyboardHandler = KeyboardInputHandler(
            sendKeyEvent: input.sendKeysym,
            usesAppleModifierConvention: input.usesAppleModifierConvention,
            sendPhysicalKeyEvent: input.sendPhysicalKey)
    }

    /// An accessory can stay visible without the software keyboard, so it
    /// keeps its measured clearance; otherwise a nonzero inset is stale.
    private var shouldReserveKeyboardInset: Bool {
        keyboardActive || keyboardCapture.inputViews.accessory != nil
    }

    public var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                ZStack {
                    Color.black
                        .ignoresSafeArea()

                    VideoBandView(renderer: renderer, brightnessGain: brightnessGain)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .scaleEffect(viewport.scale)
                        .offset(viewport.offset)

                    if isInteractive,
                       framebufferSize.width > 0,
                       framebufferSize.height > 0 {
                        RemoteInteractionView(
                            viewport: $viewport,
                            viewportPanningMode: viewportPanningMode,
                            pointerMode: pointerMode,
                            pointerSpeed: pointerSpeed,
                            cursorHeight: cursorHeight,
                            serverRendersCursor: serverRendersCursor,
                            showsLocalCursorDot: showsLocalCursorDot,
                            touchGestures: touchGestures,
                            keyboardActive: $keyboardActive,
                            hardwareKeyboardAttached: $hardwareKeyboardAttached,
                            framebufferSize: framebufferSize,
                            touchHandler: touchHandler,
                            keyboardHandler: keyboardHandler,
                            keyboardCapture: keyboardCapture,
                            suspendsKeyboardCapture: false,
                            framebufferOrigin: .zero,
                            requestPasswordSend: {},
                            requestDictation: requestDictation,
                            toggleFullScreen: toggleFullScreen,
                            disconnect: disconnect,
                            remoteCursor: nil,
                            remoteCursorPresence: .undescribed)
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .contentShape(Rectangle())
                    }

                    DraggableHUDOverlay(safeAreaEdges: hudSafeAreaEdges) {
                        hudMenu
                    }
                }
                .clipped()
                .onChange(of: geometry.size) { _, newSize in
                    viewport.clampOffset(viewSize: newSize, framebufferSize: framebufferSize)
                }
                .onChange(of: framebufferSize) { _, newSize in
                    viewport.clampOffset(viewSize: geometry.size, framebufferSize: newSize)
                }
            }

            if keyboardAvoidanceMode == .automatic {
                Color.clear
                    .frame(height: keyboardViewportMetrics.effectiveInset(
                        reservingObstruction: shouldReserveKeyboardInset))
                    .accessibilityHidden(true)
            }
        }
        .onChange(of: keyboardActive) { _, active in
            if keyboardCapture.softwareKeyboardRequested != active {
                keyboardCapture.softwareKeyboardRequested = active
            }
        }
        .onChange(of: keyboardCapture.softwareKeyboardRequested) { _, requested in
            if keyboardActive != requested {
                keyboardActive = requested
            }
        }
        .background {
            DockedKeyboardInsetReader(metrics: $keyboardViewportMetrics)
        }
        .ignoresSafeArea(.keyboard)
    }

    private var hudMenu: some View {
        Menu {
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

            Divider()

            Button(role: .destructive, action: disconnect) {
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
            Label(String(localized: "Commands", bundle: .module), systemImage: "command")
        }
    }

    private func remoteShortcutButtons(_ shortcuts: [RemoteMenuShortcut]) -> some View {
        ForEach(shortcuts) { shortcut in
            Button(shortcut.menuTitle) {
                keyboardHandler.handleShortcutTap(shortcut.character, modifiers: shortcut.modifiers)
            }
        }
    }

    private var displayMenu: some View {
        Menu {
            Menu {
                ForEach(RemoteViewportPanningMode.allCases, id: \.self) { mode in
                    Button {
                        viewportPanningMode = mode
                    } label: {
                        Label(
                            mode == .edge
                                ? String(localized: "When Pointer Reaches Edge", bundle: .module)
                                : String(localized: "Continuously with Pointer", bundle: .module),
                            systemImage: viewportPanningMode == mode
                                ? "checkmark"
                                : (mode == .edge ? "arrow.up.left.and.arrow.down.right" : "cursorarrow.rays"))
                    }
                    .disabled(viewportPanningMode == mode)
                }
            } label: {
                Label(String(localized: "Screen Panning", bundle: .module), systemImage: "cursorarrow.motionlines")
            }

            Menu {
                ForEach(RemotePointerMode.allCases, id: \.self) { mode in
                    Button {
                        pointerMode = mode
                    } label: {
                        Label(
                            mode == .direct
                                ? String(localized: "Touch", bundle: .module)
                                : String(localized: "Trackpad", bundle: .module),
                            systemImage: pointerMode == mode
                                ? "checkmark"
                                : (mode == .direct ? "hand.point.up.left" : "rectangle.and.hand.point.up.left"))
                    }
                    .disabled(pointerMode == mode)
                }
            } label: {
                Label(String(localized: "Pointer", bundle: .module), systemImage: "cursorarrow.rays")
            }

            Button {
                viewport.reset()
            } label: {
                Label(String(localized: "Fit Screen", bundle: .module), systemImage: "arrow.down.right.and.arrow.up.left")
            }
            .disabled(viewport.isIdentity)
        } label: {
            Label(String(localized: "Display", bundle: .module), systemImage: "display")
        }
    }

    private func requestDictation() {
        keyboardCapture.capture()
        keyboardActive = true
    }
}
#endif
