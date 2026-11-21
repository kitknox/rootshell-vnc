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
    /// Whose shortcuts the HUD's Commands menu sends. Nil follows the
    /// modifier convention.
    public var commandPlatform: (@MainActor () -> RemoteCommandPlatform)?

    public init(
        sendPointer: @escaping TouchInputHandler.PointerEventHandler,
        sendScroll: @escaping TouchInputHandler.ScrollEventHandler,
        sendKeysym: @escaping KeyboardInputHandler.KeyEventHandler,
        sendPhysicalKey: KeyboardInputHandler.PhysicalKeyEventHandler? = nil,
        usesAppleModifierConvention: @escaping @MainActor () -> Bool = { false },
        commandPlatform: (@MainActor () -> RemoteCommandPlatform)? = nil
    ) {
        self.sendPointer = sendPointer
        self.sendScroll = sendScroll
        self.sendKeysym = sendKeysym
        self.sendPhysicalKey = sendPhysicalKey
        self.usesAppleModifierConvention = usesAppleModifierConvention
        self.commandPlatform = commandPlatform
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
    private let hudMenuExtras: VNCHUDMenuExtras
    #if canImport(UIKit)
    private var hudAccessory: HUDAccessory?
    private var screenPlaceholder: AnyView?
    #endif
    private let touchHandler: TouchInputHandler
    private let keyboardHandler: KeyboardInputHandler

    @State private var viewport = RemoteViewportState()
    /// Height at the bottom that a docked HUD bar keeps clear of the fitted screen.
    @State private var hudReserve: CGFloat = 0
    @State private var hudFrame = HUDFrameModel()
    @State private var viewportPanningMode: RemoteViewportPanningMode
    @State private var pointerMode: RemotePointerMode
    @State private var keyboardActive = false
    @State private var hardwareKeyboardAttached = false
    @State private var keyboardCapture: VNCKeyboardCapture
    @State private var keyboardViewportMetrics = DockedKeyboardViewportMetrics()

    /// `showsLocalCursorDot` marks where local pointer input lands over a
    /// picture that already carries the pointer; it has no effect unless
    /// `serverRendersCursor` is set. `hudMenuExtras` adds the host's own
    /// items to the HUD menu.
    public init(
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
        hudMenuExtras: VNCHUDMenuExtras = VNCHUDMenuExtras()
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
        self.hudMenuExtras = hudMenuExtras
        self._viewportPanningMode = State(initialValue: initialViewportPanningMode)
        self._pointerMode = State(initialValue: initialPointerMode)
        self._keyboardCapture = State(initialValue: keyboardCapture)
        self.touchHandler = TouchInputHandler(
            sendPointerEvent: input.sendPointer,
            sendScrollEvent: input.sendScroll)
        self.keyboardHandler = KeyboardInputHandler(
            sendKeyEvent: input.sendKeysym,
            usesAppleModifierConvention: input.usesAppleModifierConvention,
            sendPhysicalKeyEvent: input.sendPhysicalKey,
            commandPlatform: input.commandPlatform)
    }

    /// An accessory can stay visible without the software keyboard, so it
    /// keeps its measured clearance; otherwise a nonzero inset is stale.
    private var shouldReserveKeyboardInset: Bool {
        keyboardActive || keyboardCapture.inputViews.accessory != nil
    }

    /// Host content drawn over the remote picture and under the controls,
    /// in the box the fitted screen occupies. For what the host shows while
    /// there is no picture; it never takes touches.
    public func screenPlaceholder<Placeholder: View>(
        @ViewBuilder _ placeholder: () -> Placeholder
    ) -> Self {
        var copy = self
        copy.screenPlaceholder = AnyView(placeholder())
        return copy
    }

    #if canImport(UIKit)
    /// Adds host content to the HUD, inside its glass: `beside` the menu
    /// button, taking the button style to match, and `behind` the buttons
    /// across the whole bar, taking the width it may use. `buttonStyle` sizes
    /// every button from that width. `docksToBottom` pins the bar along the bottom and fits the
    /// screen above it, though zoomed content still shows through underneath.
    /// `providesKeyboardButton` drops the menu's own Show Keyboard item.
    public func hudAccessory<Behind: View, Beside: View>(
        isEnabled: Bool = true,
        docksToBottom: Bool = false,
        providesKeyboardButton: Bool = false,
        buttonStyle: @escaping (_ availableWidth: CGFloat) -> VNCHUDButtonStyle,
        @ViewBuilder behind: @escaping (_ availableWidth: CGFloat) -> Behind,
        @ViewBuilder beside: @escaping (_ buttonStyle: VNCHUDButtonStyle) -> Beside
    ) -> Self {
        guard isEnabled else { return self }
        var copy = self
        copy.hudAccessory = HUDAccessory(
            docksToBottom: docksToBottom,
            providesKeyboardButton: providesKeyboardButton,
            buttonStyle: buttonStyle,
            behind: { AnyView(behind($0)) },
            beside: { AnyView(beside($0)) })
        return copy
    }
    #endif

    public var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                // The fitted screen stops above a docked HUD bar. Zoomed in, it
                // still draws underneath: only the ZStack clips.
                let contentSize = CGSize(
                    width: geometry.size.width,
                    height: max(1, geometry.size.height - hudReserve))
                let hudMargin = HUDBar<EmptyView>.margin(for: hudAccessory)
                let hudWidth = HUDBar<EmptyView>.availableWidth(
                    containerWidth: geometry.size.width,
                    safeArea: geometry.safeAreaInsets,
                    safeAreaEdges: hudSafeAreaEdges,
                    margin: hudMargin)

                ZStack {
                    Color.black
                        .ignoresSafeArea()

                    VideoBandView(renderer: renderer, brightnessGain: brightnessGain)
                        .frame(width: contentSize.width, height: contentSize.height)
                        .scaleEffect(viewport.scale)
                        .offset(viewport.offset)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                    if let screenPlaceholder {
                        screenPlaceholder
                            .frame(width: contentSize.width, height: contentSize.height)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                            .allowsHitTesting(false)
                    }

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
                            .frame(width: contentSize.width, height: contentSize.height)
                            .contentShape(Rectangle())
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    }

                    DraggableHUDOverlay(
                        inset: hudMargin,
                        safeAreaEdges: hudSafeAreaEdges,
                        pinnedRowHeight: hudAccessory?.docksToBottom == true
                            ? hudAccessory?.buttonStyle(hudWidth).size.height : nil,
                        onReserveChange: { hudReserve = $0 },
                        onFrameChange: { [hudFrame] in hudFrame.frame = $0 }
                    ) {
                        HUDBar(accessory: hudAccessory, availableWidth: hudWidth) {
                            hudMenu
                        }
                    }
                    CompositionPreviewLayer(
                        keyboardCapture: keyboardCapture,
                        hudFrame: hudFrame,
                        margin: hudMargin,
                        safeArea: geometry.safeAreaInsets,
                        safeAreaEdges: hudSafeAreaEdges)
                }
                .clipped()
                .onChange(of: geometry.size) { _, newSize in
                    viewport.clampOffset(
                        viewSize: CGSize(width: newSize.width, height: max(1, newSize.height - hudReserve)),
                        framebufferSize: framebufferSize)
                }
                .onChange(of: framebufferSize) { _, newSize in
                    viewport.clampOffset(viewSize: contentSize, framebufferSize: newSize)
                }
                .onChange(of: hudReserve) { _, reserve in
                    viewport.clampOffset(
                        viewSize: CGSize(width: geometry.size.width, height: max(1, geometry.size.height - reserve)),
                        framebufferSize: framebufferSize)
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
        HUDMenu(
            keyboardCapture: keyboardCapture,
            keyboardHandler: keyboardHandler,
            keyboardActive: $keyboardActive,
            hardwareKeyboardAttached: hardwareKeyboardAttached,
            hostProvidesKeyboardButton: hudAccessory?.providesKeyboardButton ?? false,
            viewport: $viewport,
            viewportPanningMode: $viewportPanningMode,
            pointerMode: $pointerMode,
            isFullScreen: isFullScreen,
            toggleFullScreen: toggleFullScreen,
            extras: hudMenuExtras,
            disconnect: disconnect,
            sessionActions: { EmptyView() },
            sessionDisplay: { EmptyView() })
    }

    private func requestDictation() {
        keyboardCapture.capture()
        keyboardActive = true
    }
}
#endif
