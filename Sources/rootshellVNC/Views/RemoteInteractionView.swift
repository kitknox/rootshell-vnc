#if canImport(UIKit)
import SwiftUI
import UIKit
#if targetEnvironment(macCatalyst)
import AppKit
#endif
import RFBProtocol
import RFBRendering
import GameController

/// Transparent UIKit input surface shared by Adaptive and Full Quality modes.
/// UIKit is used here because SwiftUI gestures do not expose mouse buttons,
/// hover, scroll-wheel events, touch counts, or key-up events consistently.
struct RemoteInteractionView: UIViewRepresentable {
    @Binding var viewport: RemoteViewportState
    let viewportPanningMode: RemoteViewportPanningMode
    let pointerMode: RemotePointerMode
    let pointerSpeed: Double
    let cursorHeight: CGFloat
    let serverRendersCursor: Bool
    /// Dot over a server-drawn pointer; see `RemoteScreenView`.
    let showsLocalCursorDot: Bool
    let touchGestures: RemoteTouchGestureConfiguration
    @Binding var keyboardActive: Bool
    @Binding var hardwareKeyboardAttached: Bool

    let framebufferSize: CGSize
    let touchHandler: TouchInputHandler
    let keyboardHandler: KeyboardInputHandler
    let keyboardCapture: VNCKeyboardCapture
    /// Set while a modal prompt owns the keyboard. Keyboard capture re-claims
    /// first responder on every update, and this view updates once per decoded
    /// frame, so without this a text field in an alert loses focus after each
    /// character the user types.
    let suspendsKeyboardCapture: Bool
    let framebufferOrigin: CGPoint
    let requestPasswordSend: () -> Void
    let requestDictation: () -> Void
    let toggleFullScreen: (() -> Void)?
    let disconnect: () -> Void
    let remoteCursor: RemoteCursor?
    let remoteCursorPresence: RemoteCursorPresence

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> RemoteInputUIView {
        let view = RemoteInputUIView(
            touchHandler: touchHandler,
            keyboardHandler: keyboardHandler,
            keyboardCapture: keyboardCapture,
            requestPasswordSend: requestPasswordSend,
            requestDictation: requestDictation,
            toggleFullScreen: toggleFullScreen,
            disconnect: disconnect)
        view.onViewportChange = { [weak coordinator = context.coordinator] state in
            coordinator?.parent.viewport = state
        }
        view.onKeyboardActiveChange = { [weak coordinator = context.coordinator] active in
            coordinator?.parent.keyboardActive = active
        }
        view.onHardwareKeyboardAttachedChange = {
            [weak coordinator = context.coordinator] attached in
            guard let coordinator else { return }
            coordinator.parent.hardwareKeyboardAttached = attached
            if attached {
                coordinator.parent.keyboardActive = false
            }
        }
        DispatchQueue.main.async { [weak view] in
            view?.publishHardwareKeyboardAvailability()
        }
        return view
    }

    func updateUIView(_ uiView: RemoteInputUIView, context: Context) {
        context.coordinator.parent = self
        uiView.update(
            framebufferSize: framebufferSize,
            viewport: viewport,
            viewportPanningMode: viewportPanningMode,
            pointerMode: pointerMode,
            pointerSpeed: pointerSpeed,
            cursorHeight: cursorHeight,
            serverRendersCursor: serverRendersCursor,
            showsLocalCursorDot: showsLocalCursorDot,
            touchGestures: touchGestures,
            keyboardActive: keyboardActive,
            keyboardCaptured: keyboardCapture.isCaptured
                && !suspendsKeyboardCapture,
            inputViewsGeneration: keyboardCapture.inputViewsGeneration,
            controlOptionAsCommand: keyboardCapture.controlOptionAsCommand,
            framebufferOrigin: framebufferOrigin,
            requestPasswordSend: requestPasswordSend,
            requestDictation: requestDictation,
            toggleFullScreen: toggleFullScreen,
            disconnect: disconnect,
            remoteCursor: remoteCursor,
            remoteCursorPresence: remoteCursorPresence)
    }

    @MainActor
    final class Coordinator {
        var parent: RemoteInteractionView

        init(parent: RemoteInteractionView) {
            self.parent = parent
        }
    }
}

@MainActor
final class RemoteInputUIView: UIView, UIKeyInput, UIGestureRecognizerDelegate,
    UIPointerInteractionDelegate {
    var onViewportChange: ((RemoteViewportState) -> Void)?
    var onKeyboardActiveChange: ((Bool) -> Void)?
    var onHardwareKeyboardAttachedChange: ((Bool) -> Void)?

    private let touchHandler: TouchInputHandler
    private let keyboardHandler: KeyboardInputHandler
    private let keyboardCapture: VNCKeyboardCapture
    private var requestPasswordSend: () -> Void
    private var requestDictation: () -> Void
    private var toggleFullScreen: (() -> Void)?
    private var disconnect: () -> Void
    private lazy var hardwareKeyboard = HardwareKeyboardController(
        keyboardHandler: keyboardHandler,
        routeModifier: { [weak self] transition, usage in
            self?.routePhysicalModifier(transition, usage: usage)
        })
    private var framebufferSize: CGSize = .zero
    private var framebufferOrigin: CGPoint = .zero
    private var viewport = RemoteViewportState()
    private var viewportPanningMode = RemoteViewportPanningMode.edge
    private(set) var pointerMode: RemotePointerMode = .direct
    private(set) var pointerSpeed: Double = 1.0
    /// On-screen height for the locally drawn pointer, in view points.
    private(set) var cursorHeight = TrackpadCursorStyle.defaultCursorHeight
    /// Whether the server composites the pointer into the framebuffer it
    /// sends. When it does, this view draws no cursor of its own, except
    /// the local dot when `showsLocalCursorDot` asks for one.
    private(set) var serverRendersCursor = false
    private(set) var showsLocalCursorDot = false
    /// Virtual cursor driven by relative finger motion. Non-nil exactly while
    /// `.trackpad` is active, so its absence is also what keeps every relative
    /// path inert in `.direct`.
    private var trackpadModel: TrackpadPointerModel?
    private var trackpadVelocity = TrackpadVelocityEstimator()
    /// Recognizer translation already folded into the cursor. The recognizer
    /// reports cumulative translation; relative motion needs the difference
    /// between callbacks.
    private var trackpadConsumedTranslation = CGPoint.zero
    /// What the server has said about its pointer. A pointer nobody has
    /// described yet earns a locally drawn arrow so relative input has
    /// something to aim; one the server hid must show nothing.
    private var remoteCursorPresence = RemoteCursorPresence.undescribed
    /// Bumped whenever the server's shape changes, so a redraw decision can
    /// compare shapes without holding on to the previous image.
    private var remoteCursorShapeRevision: UInt64 = 0
    /// Cursors the server has described so far, by canvas and hotspot,
    /// so each distinct size is logged once rather than on every
    /// change back to it.
    private var loggedTrackpadCursorShapes: Set<String> = []
    /// Not gated behind the input trace flag: it fires once per view, and the
    /// question it answers can only be checked on a device.
    private static let trackpadCursorLog = VNCLogger(category: "TrackpadCursor")
    private var softwareKeyboardRequested = false
    private var acceptsHardwareInput = true
    private var lastSeenInputViewsGeneration: UInt64 = 0
    private var lastPointerPoint: (x: UInt16, y: UInt16)?
    private var remoteCursor: RemoteCursor?
    private var pointerDragActive = false
    private var touchHoldDragLastPoint: (x: UInt16, y: UInt16)?
    private var touchHoldDragActive = false
    /// The button the current touch hold presses: one finger holds left,
    /// two hold right, three hold middle.
    private var touchHoldDragButton = RemotePointerButton.left
    private var touchGestures = RemoteTouchGestureConfiguration.standard
    private var swipeTracker = MultiFingerSwipeTracker()
    private lazy var buttonIndicator = TouchButtonIndicatorView()
    /// A mouse or trackpad press of a button other than primary. UIKit gives
    /// those no recognizer, so raw touches (iPad, visionOS) or GameController
    /// (Catalyst middle button) drive it from press to release.
    private var physicalButtonPress: PhysicalButtonPress?
    private var lastKnownFramebufferPoint: (x: UInt16, y: UInt16)?
    private var lastScrollPoint: (x: UInt16, y: UInt16)?
    private var scrollPointAccumulator = ScrollPointAccumulator()
    private var wheelUnitAccumulator = ScrollWheelUnitAccumulator()
    private var horizontalScrollIntentFilter = HorizontalScrollIntentFilter()
    private var previousScrollTranslation = CGPoint.zero
    private var directScrollPhaseActive = false
    private var momentumScrollPhaseActive = false
    /// Where the pointer rested when a fling began; moving off it ends the fling.
    private var momentumPointerAnchor: CGPoint?
    private var lastPointerViewLocation: CGPoint?
    private weak var activeScrollRecognizer: UIGestureRecognizer?
    private var activeScrollUsesDirectTouch = false
    private var releaseVelocityEstimator = ScrollReleaseVelocityEstimator()
    private var previousScrollTimestamp: CFTimeInterval = 0
    private var syntheticMomentumVelocity = CGPoint.zero
    private var syntheticMomentumLastTimestamp: CFTimeInterval = 0
    private var momentumDisplayLink: CADisplayLink?
    private var edgeScrollPointerLocation: CGPoint?
    private var edgeScrollLastTimestamp: CFTimeInterval = 0
    /// The button an edge-scroll step holds, or nil while only hovering.
    private var edgeScrollDragButton: RemotePointerButton?
    private var edgeScrollDisplayLink: CADisplayLink?
    private var pointerDragIsPencil = false
    /// Last pencil drag position and time, for barrel-tap right-clicks on
    /// non-hover-capable hardware. Deliberately separate from lastPointerPoint,
    /// which mouse/trackpad input also writes.
    private var lastPencilFramebufferPoint: (x: UInt16, y: UInt16)?
    private var lastPencilContactTimestamp: CFTimeInterval = 0
    /// The view that saw the most recent pencil contact, process-wide. UIKit
    /// delivers a barrel tap to every visible UIPencilInteraction, so without
    /// hover data only the last-touched pane may respond.
    private static weak var lastPencilContactView: RemoteInputUIView?
    /// A direct touch that lands during a fling catches it, exactly like
    /// touching a decelerating native scroll view: the fling stops and that
    /// touch must never click or hold-drag. Set at the catching touch-down,
    /// cleared by the next touch-down or by whichever recognizer consumes it.
    private var momentumCatchPending = false
    private var momentumCatchTimestamp: CFTimeInterval = 0
    private let suppressedInputView = UIView(frame: .zero)
    private var consumedRemoteAliasUsages: Set<UInt32> = []
    private var universalKeys = UniversalCommandKeyState()
    /// Supplemental toolbar modifiers held around each physical key or pointer
    /// press until it ends. Reference counts keep overlapping presses from
    /// releasing a shared synthetic modifier too early.
    private var supplementalModifierState = SupplementalHardwareModifierState()
    private var modifierPressRoutes = ModifierPressRoutes()
    private var nextPointerModifierOwner: UInt64 = 0
    private var pointerDragModifierOwner: UInt64?
    private var touchHoldModifierOwner: UInt64?
    private weak var monitoredCatalystKeyboardInput: GCKeyboardInput?
    #if targetEnvironment(macCatalyst)
    // Repeat state for Option/Command+arrow chords read from GameController,
    // which UIKit does not deliver to the responder on Catalyst.
    private var catalystArrowDelayTimer: Timer?
    private var catalystArrowRepeatTimer: Timer?
    private var catalystArrowRepeatUsage: UInt32?
    #endif
    #if DEBUG
    private let inputLog = VNCLogger(category: "InputRouting")
    private var inputLogBudget = 128
    #endif

    private lazy var scrollRecognizer = UIPanGestureRecognizer(
        target: self,
        action: #selector(handleNativeScrollState(_:)))
    private lazy var directTouchRecognizer: DirectTouchGestureRecognizer = {
        let recognizer = DirectTouchGestureRecognizer(
            target: self,
            action: #selector(handleDirectTouchState(_:)))
        recognizer.onTouchDown = { [weak self] location in
            guard let self else { return false }
            if self.catchMomentumFlingIfActive() {
                self.momentumCatchPending = true
                self.momentumCatchTimestamp = CACurrentMediaTime()
                return true
            }
            self.momentumCatchPending = false
            self.momentumCatchTimestamp = 0
            self.prepareDragEngageFeedback()
            // Relative motion has no landing point to adopt: jumping the
            // remote pointer under the finger is exactly the absolute
            // behaviour trackpad mode exists to avoid.
            if self.pointerMode == .direct {
                self.positionRemotePointerForTouch(at: location)
            }
            return false
        }
        return recognizer
    }()
    private lazy var pinchRecognizer = UIPinchGestureRecognizer(
        target: self,
        action: #selector(handlePinch(_:)))
    private lazy var viewportPanRecognizer = UIPanGestureRecognizer(
        target: self,
        action: #selector(handleViewportPan(_:)))
    private lazy var pointerDragRecognizer = UILongPressGestureRecognizer(
        target: self,
        action: #selector(handlePointerDrag(_:)))
    private lazy var tapRecognizer = UITapGestureRecognizer(
        target: self,
        action: #selector(handleTap(_:)))
    private lazy var doubleTapRecognizer = UITapGestureRecognizer(
        target: self,
        action: #selector(handleDoubleTap(_:)))
    private lazy var rightTapRecognizer = UITapGestureRecognizer(
        target: self,
        action: #selector(handleRightTap(_:)))
    /// A physical trackpad reports a click the moment the finger lifts; macOS
    /// itself decides what is a double click from the timing. Waiting for a
    /// second tap to fail would put a third of a second between the tap and
    /// the remote button-down, which reads as a dropped click. This recognizer
    /// exists only so `.trackpad` can click without that dependency.
    private lazy var trackpadTapRecognizer = UITapGestureRecognizer(
        target: self,
        action: #selector(handleTrackpadTap(_:)))
    /// Two-finger scrolling for `.trackpad`, where one finger already means
    /// cursor motion. It replaces the two-finger viewport pan rather than
    /// joining it, so the finger count keeps its single meaning.
    private lazy var trackpadScrollRecognizer = UIPanGestureRecognizer(
        target: self,
        action: #selector(handleTrackpadScroll(_:)))
    /// Three-finger tap middle-clicks where a two-finger tap would right-click.
    private lazy var middleTapRecognizer = UITapGestureRecognizer(
        target: self,
        action: #selector(handleMiddleTap(_:)))
    /// Still fingers that outlast the hold delay press a button and drag with
    /// it, in both pointer modes: two fingers hold right, three hold middle.
    private lazy var twoFingerHoldRecognizer = MultiFingerHoldGestureRecognizer(
        fingerCount: 2,
        target: self,
        action: #selector(handleMultiFingerHold(_:)))
    private lazy var threeFingerHoldRecognizer = MultiFingerHoldGestureRecognizer(
        fingerCount: 3,
        target: self,
        action: #selector(handleMultiFingerHold(_:)))
    private lazy var threeFingerSwipeRecognizer = UIPanGestureRecognizer(
        target: self,
        action: #selector(handleThreeFingerSwipe(_:)))
    private lazy var hoverRecognizer = UIHoverGestureRecognizer(
        target: self,
        action: #selector(handleHover(_:)))
    private lazy var pointerInteraction = UIPointerInteraction(delegate: self)
    #if !targetEnvironment(macCatalyst) && !os(visionOS)
    private lazy var pencilInteraction = UIPencilInteraction(delegate: self)
    #endif
    #if targetEnvironment(macCatalyst)
    private lazy var secondaryClickInteraction = UIContextMenuInteraction(delegate: self)
    private var catalystCursor: NSCursor?
    private var catalystCursorDisplayScale: CGFloat = 0
    private var catalystDotCursor: (diameter: CGFloat, displayScale: CGFloat, cursor: NSCursor)?
    #else
    /// UIPointerShape outlines every scanline in a bitmap silhouette, which
    /// makes detailed macOS cursors look striped or duplicated on iPad. Keep
    /// one ordinary image view under the locally tracked pointer instead.
    private lazy var remoteCursorImageView: UIImageView = {
        let imageView = UIImageView(frame: .zero)
        imageView.isHidden = true
        imageView.isUserInteractionEnabled = false
        imageView.contentMode = .scaleToFill
        imageView.layer.magnificationFilter = .linear
        imageView.layer.minificationFilter = .linear
        return imageView
    }()
    private var remoteCursorHoverLocation: CGPoint?
    /// Reuse the rasterized fallback across moves at the same size and density.
    private var fallbackCursorImages: [FallbackCursorKey: FallbackCursorImage?] = [:]
    /// What the virtual cursor currently shows. A redraw happens when any
    /// part of this differs, which is what keeps a shape change from being
    /// read as "nothing moved".
    private var trackpadCursorPresentation: TrackpadCursorPresentation?
    #endif
    #if !os(visionOS)
    /// Prepared at touch-down so the taptic engine is already spun up when a
    /// hold turns into a drag; the confirmation is useless if it lands after
    /// the drag has visibly started.
    private lazy var dragEngageFeedback = UIImpactFeedbackGenerator(
        style: .light,
        view: self)
    #endif

    override var keyCommands: [UIKeyCommand]? {
        guard keyboardCapture.isCaptured else { return viewerCommandKeyCommands }
        #if targetEnvironment(macCatalyst)
        let commands = reservedHostKeyCommands
            + standardRemoteKeyCommands
            + remoteNavigationKeyCommands
            + viewerCommandKeyCommands
            + catalystEditingKeyCommands
            + remoteControlKeyCommands
        #else
        let commands = reservedHostKeyCommands
            + commandCompatibilityKeyCommands
            + standardRemoteKeyCommands
            + remoteNavigationKeyCommands
            + viewerCommandKeyCommands
            + remoteCommandKeyCommands
        #endif
        guard keyboardCapture.controlOptionAsCommand else { return commands }
        return universalCommandKeyCommands + commands.filter {
            !Self.isControlOptionChord($0.modifierFlags)
        }
    }

    private static func isControlOptionChord(_ flags: UIKeyModifierFlags) -> Bool {
        flags.contains([.control, .alternate])
    }

    private static let hardwareCommandCharacters = "abcdefghijklmnopqrstuvwxyz0123456789 -=[]\\;',./`"
    // Only non-printable UIKit inputs have a layout-independent HID mapping.
    // This table translates their value, never a held key's physical identity.
    private static let universalSpecialInputs: [(String, UInt32)] = [
        ("\r", 0x28), ("\t", 0x2B), ("\u{8}", 0x2A), ("\u{7F}", 0x4C),
        (UIKeyCommand.inputEscape, 0x29),
        (UIKeyCommand.inputUpArrow, 0x52), (UIKeyCommand.inputDownArrow, 0x51),
        (UIKeyCommand.inputLeftArrow, 0x50), (UIKeyCommand.inputRightArrow, 0x4F),
        (UIKeyCommand.inputHome, 0x4A), (UIKeyCommand.inputEnd, 0x4D),
        (UIKeyCommand.inputPageUp, 0x4B), (UIKeyCommand.inputPageDown, 0x4E),
    ]
    private static let universalCommandInputs = hardwareCommandCharacters.map(String.init)
        + universalSpecialInputs.map(\.0)

    private lazy var universalCommandKeyCommands: [UIKeyCommand] = {
        Self.universalCommandInputs.flatMap { input in
            let variants: [UIKeyModifierFlags] = [
                [.control, .alternate], [.control, .alternate, .shift],
                [.control, .alternate, .command], [.control, .alternate, .command, .shift],
            ]
            return variants.map { flags in
                let command = UIKeyCommand(input: input, modifierFlags: flags,
                    action: #selector(handleUniversalCommandKey(_:)))
                command.wantsPriorityOverSystemBehavior = true
                command.allowsAutomaticLocalization = false
                return command
            }
        }
    }()

    @objc private func handleUniversalCommandKey(_ command: UIKeyCommand) {
        guard keyboardCapture.isCaptured, keyboardCapture.controlOptionAsCommand,
              let input = command.input else { return }
        let keysym: UInt32
        if let special = Self.universalSpecialInputs.first(where: { $0.0 == input }) {
            keysym = KeyboardInputHandler.keysymForHIDUsage(special.1, characters: "")
        } else if let character = input.lowercased().first {
            keysym = KeyboardInputHandler.keysymForCharacter(character)
        } else {
            return
        }
        synchronizeUniversalModifiers(command.modifierFlags)
        switch universalKeys.routeCommand(keysym: keysym) {
        case .duplicate:
            break
        case .tap:
            // This identity exists only within this synchronous tap. It never
            // waits for a hardware release and cannot leave key repeat running.
            let tapUsage: UInt32 = 0x10000
            beginSupplementalModifiersIfNeeded(for: tapUsage)
            _ = hardwareKeyboard.press(usage: tapUsage, keysym: keysym)
            _ = hardwareKeyboard.release(usage: tapUsage)
            endSupplementalModifiers(for: tapUsage)
        }
    }

    /// UIKit may have selected an action just before the session mode changed.
    /// Re-check precedence at dispatch as well as when publishing key commands.
    private func routeUniversalCommandIfNeeded(_ command: UIKeyCommand) -> Bool {
        guard keyboardCapture.isCaptured, keyboardCapture.controlOptionAsCommand,
              Self.isControlOptionChord(command.modifierFlags) else { return false }
        handleUniversalCommandKey(command)
        return true
    }

    private static func keyboardModifiers(_ flags: UIKeyModifierFlags) -> VNCKeyboardModifiers {
        var result: VNCKeyboardModifiers = []
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.alternate) { result.insert(.option) }
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.command) { result.insert(.command) }
        return result
    }

    private func pressUniversalKey(usage: UInt32, characters: String, flags: UIKeyModifierFlags) {
        synchronizeUniversalModifiers(flags)
        let keysym = KeyboardInputHandler.keysymForHIDUsage(usage, characters: characters.lowercased())
        pressUniversalKeysym(usage: usage, keysym: keysym)
    }

    private func pressUniversalKeysym(usage: UInt32, keysym: UInt32) {
        guard keysym != 0, universalKeys.beginPhysical(usage: usage, keysym: keysym) else { return }
        beginSupplementalModifiersIfNeeded(for: usage)
        _ = hardwareKeyboard.press(usage: usage, keysym: keysym)
    }

    private func synchronizeUniversalModifiers(_ flags: UIKeyModifierFlags) {
        hardwareKeyboard.synchronizeModifiers(Self.keyboardModifiers(flags))
        clearPendingTapsIfChordEnded()
    }

    private func clearPendingTapsIfChordEnded() {
        if !hardwareKeyboard.isControlOptionChordActive {
            universalKeys.endTranslatedChord()
        }
    }

    /// Explicit commands for the small set of chords owned by a containing
    /// app. Keeping these on the focused VNC responder avoids relying on menu
    /// command arbitration, which is not consistent across iPad and Catalyst.
    private lazy var reservedHostKeyCommands: [UIKeyCommand] = {
        keyboardCapture.reservedHostShortcuts.flatMap { shortcut in
            var signatures = [(
                input: shortcut.input,
                modifiers: Self.uiModifiers(for: shortcut.modifiers)
            )]

            // UIKit reports shifted punctuation differently by platform:
            // iPad commonly uses "[" + Shift while Catalyst menu commands use
            // "{" without Shift for the same physical key. Claim both forms.
            if shortcut.modifiers.contains(.shift),
               let shiftedInput = Self.shiftedHostShortcutInput(shortcut.input) {
                var modifiers = Self.uiModifiers(for: shortcut.modifiers)
                modifiers.remove(.shift)
                signatures.append((shiftedInput, modifiers))
            }

            return signatures.map { signature in
                let command = UIKeyCommand(
                    input: signature.input,
                    modifierFlags: signature.modifiers,
                    action: #selector(handleReservedHostShortcut(_:)))
                command.wantsPriorityOverSystemBehavior = true
                command.allowsAutomaticLocalization = false
                return command
            }
        }
    }()

    private lazy var commandCompatibilityKeyCommands: [UIKeyCommand] = {
        [
            ("h", String(localized: "Command-H", bundle: .module)),
            ("m", String(localized: "Command-M", bundle: .module)),
        ].map { input, title in
            let command = UIKeyCommand(
                input: input,
                modifierFlags: [.control, .alternate],
                action: #selector(handleCommandCompatibilityAlias(_:)))
            command.discoverabilityTitle = title
            command.wantsPriorityOverSystemBehavior = true
            command.allowsAutomaticLocalization = false
            return command
        }
    }()

    private lazy var standardRemoteKeyCommands: [UIKeyCommand] = {
        RemoteCommand.allCases.filter { remoteCommand in
            !isReservedHostShortcut(
                input: Self.uiInput(for: remoteCommand.shortcut.input),
                modifiers: Self.uiModifiers(for: remoteCommand.shortcut.modifiers))
        }.map { remoteCommand in
            let command = UIKeyCommand(
                input: Self.uiInput(for: remoteCommand.shortcut.input),
                modifierFlags: Self.uiModifiers(
                    for: remoteCommand.shortcut.modifiers),
                action: #selector(handleStandardRemoteCommand(_:)))
            command.discoverabilityTitle = remoteCommand.title
            command.wantsPriorityOverSystemBehavior = true
            command.allowsAutomaticLocalization = false
            return command
        }
    }()

    /// Arrow keys are navigation commands to UIKit, so they may be consumed
    /// by the focus system before a hardware `UIPress` reaches this view.
    /// Explicitly claiming the unmodified variants keeps them on the VNC
    /// responder path while keyboard capture is active.
    private lazy var remoteNavigationKeyCommands: [UIKeyCommand] = {
        [
            UIKeyCommand.inputUpArrow,
            UIKeyCommand.inputDownArrow,
            UIKeyCommand.inputLeftArrow,
            UIKeyCommand.inputRightArrow,
        ].map { input in
            let command = UIKeyCommand(
                input: input,
                modifierFlags: [],
                action: #selector(handleRemoteNavigationKey(_:)))
            command.wantsPriorityOverSystemBehavior = true
            command.allowsAutomaticLocalization = false
            return command
        }
    }()

    private lazy var viewerCommandKeyCommands: [UIKeyCommand] = [
        makeViewerCommand(
            title: String(localized: "Type User Password", bundle: .module),
            input: "p",
            modifiers: [.control, .shift],
            action: #selector(handlePasswordCommand(_:))),
        makeViewerCommand(
            title: String(localized: "Dictate", bundle: .module),
            input: "l",
            modifiers: [.control, .alternate],
            action: #selector(handleDictationCommand(_:))),
        makeViewerCommand(
            title: String(localized: "Toggle Full Screen", bundle: .module),
            input: "f",
            modifiers: [.control, .shift],
            action: #selector(handleFullScreenCommand(_:))),
        makeViewerCommand(
            title: String(localized: "Close Connection", bundle: .module),
            input: "q",
            modifiers: [.alternate, .command],
            action: #selector(handleDisconnectCommand(_:))),
    ]

    private func makeViewerCommand(
        title: String,
        input: String,
        modifiers: UIKeyModifierFlags,
        action: Selector
    ) -> UIKeyCommand {
        let command = UIKeyCommand(
            input: input,
            modifierFlags: modifiers,
            action: action)
        command.discoverabilityTitle = title
        command.wantsPriorityOverSystemBehavior = true
        command.allowsAutomaticLocalization = false
        return command
    }

    #if targetEnvironment(macCatalyst)

    private lazy var remoteControlKeyCommands: [UIKeyCommand] = {
        var commands: [UIKeyCommand] = []
        let inputs = Self.hardwareCommandCharacters
        for input in inputs {
            for modifiers: UIKeyModifierFlags in [.control, [.control, .shift]] {
                if Self.isReservedViewerShortcut(
                    input: String(input),
                    modifiers: modifiers
                ) || Self.isStandardRemoteShortcut(
                    input: String(input),
                    modifiers: modifiers
                ) || isReservedHostShortcut(
                    input: String(input),
                    modifiers: modifiers
                ) {
                    continue
                }
                let command = UIKeyCommand(
                    input: String(input),
                    modifierFlags: modifiers,
                    action: #selector(handleControlKeyCommand(_:)))
                command.wantsPriorityOverSystemBehavior = true
                commands.append(command)
            }
        }
        for input in [
            UIKeyCommand.inputUpArrow,
            UIKeyCommand.inputDownArrow,
            UIKeyCommand.inputLeftArrow,
            UIKeyCommand.inputRightArrow,
        ] {
            let command = UIKeyCommand(
                input: input,
                modifierFlags: .control,
                action: #selector(handleControlKeyCommand(_:)))
            command.wantsPriorityOverSystemBehavior = true
            commands.append(command)
        }
        return commands
    }()

    /// Delete/Backspace word-editing chords (Option/Command ± Shift) that macOS
    /// Catalyst consumes as its own `deleteWordBackward:`/`deleteToBeginning…`
    /// before a `UIPress` can reach the responder, so they never reach the
    /// remote. Unlike arrows, an eaten Delete produces no key-up, so each is
    /// sent as one atomic remote chord rather than a held press.
    private lazy var catalystEditingKeyCommands: [UIKeyCommand] = {
        let modifierVariants: [UIKeyModifierFlags] = [
            [.alternate],
            [.alternate, .shift],
            [.command],
            [.command, .shift],
        ]
        return modifierVariants.map { modifiers in
            let command = UIKeyCommand(
                input: "\u{8}",
                modifierFlags: modifiers,
                action: #selector(handleCatalystEditingKeyCommand(_:)))
            command.wantsPriorityOverSystemBehavior = true
            command.allowsAutomaticLocalization = false
            return command
        }
    }()
    #else
    private lazy var remoteCommandKeyCommands: [UIKeyCommand] = {
        var commands: [UIKeyCommand] = []
        let inputs = Self.hardwareCommandCharacters
        let modifierVariants: [UIKeyModifierFlags] = [
            .command,
            [.command, .shift],
            [.command, .alternate],
            [.command, .control],
            [.command, .shift, .alternate],
            [.command, .shift, .control],
            [.command, .alternate, .control],
            [.command, .shift, .alternate, .control],
        ]

        // Declare iPadOS app-management shortcuts first. Command-H (Home) and
        // Command-M (Minimize) otherwise compete with system behavior before
        // UIKit delivers ordinary presses to the remote input view.
        for input in ["h", "m"] {
            commands.append(makeRemoteCommand(input: input, modifiers: .command))
        }

        for input in inputs {
            for modifiers in modifierVariants {
                if Self.isReservedViewerShortcut(
                    input: String(input),
                    modifiers: modifiers)
                    || isReservedHostShortcut(
                        input: String(input),
                        modifiers: modifiers)
                    || (modifiers == .command && (input == "h" || input == "m")) {
                    continue
                }
                commands.append(makeRemoteCommand(
                    input: String(input),
                    modifiers: modifiers))
            }
        }
        return commands
    }()

    private func makeRemoteCommand(
        input: String,
        modifiers: UIKeyModifierFlags
    ) -> UIKeyCommand {
        let command = UIKeyCommand(
            input: input,
            modifierFlags: modifiers,
            action: #selector(handleRemoteCommandKey(_:)))
        command.wantsPriorityOverSystemBehavior = true
        command.allowsAutomaticLocalization = false
        return command
    }
    #endif

    init(
        touchHandler: TouchInputHandler,
        keyboardHandler: KeyboardInputHandler,
        keyboardCapture: VNCKeyboardCapture,
        requestPasswordSend: @escaping () -> Void,
        requestDictation: @escaping () -> Void,
        toggleFullScreen: (() -> Void)?,
        disconnect: @escaping () -> Void
    ) {
        self.touchHandler = touchHandler
        self.keyboardHandler = keyboardHandler
        self.keyboardCapture = keyboardCapture
        self.requestPasswordSend = requestPasswordSend
        self.requestDictation = requestDictation
        self.toggleFullScreen = toggleFullScreen
        self.disconnect = disconnect
        self.lastSeenInputViewsGeneration = keyboardCapture.inputViewsGeneration
        super.init(frame: .zero)
        hardwareKeyboard.controlOptionAsCommand = keyboardCapture.controlOptionAsCommand
        backgroundColor = .clear
        isMultipleTouchEnabled = true
        accessibilityLabel = String(localized: "Remote desktop input", bundle: .module)
        configureRecognizers()
        #if targetEnvironment(macCatalyst)
        // Catalyst surfaces a trackpad secondary click as a touchless button
        // event that only the context-menu machinery consumes — it never
        // reaches touchesBegan or tap recognizers, even with buttonMaskRequired.
        addInteraction(secondaryClickInteraction)
        Self.installCatalystMouseButtonHandlers()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(mouseDidConnect(_:)),
            name: .GCMouseDidConnect,
            object: nil)
        #else
        addInteraction(pointerInteraction)
        #if !os(visionOS)
        // Barrel double-tap (Pencil 2/Pro) = remote right-click
        addInteraction(pencilInteraction)
        #endif
        addSubview(remoteCursorImageView)
        // The bundled cursors are rasterised for one pixel density, so a
        // move to a display with another one has to redraw them.
        registerForTraitChanges(
            [UITraitDisplayScale.self]
        ) { (view: RemoteInputUIView, _: UITraitCollection) in
            view.fallbackCursorImages.removeAll(keepingCapacity: true)
            view.refreshTrackpadCursorImage()
        }
        #endif
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationWillResignActive),
            name: UIApplication.willResignActiveNotification,
            object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidResignKey),
            name: UIWindow.didResignKeyNotification,
            object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(softwareKeyboardWillHide),
            name: UIResponder.keyboardWillHideNotification,
            object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(softwareKeyboardDidHide),
            name: UIResponder.keyboardDidHideNotification,
            object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(hardwareKeyboardDidConnect(_:)),
            name: .GCKeyboardDidConnect,
            object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(hardwareKeyboardDidDisconnect(_:)),
            name: .GCKeyboardDidDisconnect,
            object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func publishHardwareKeyboardAvailability() {
        onHardwareKeyboardAttachedChange?(GCKeyboard.coalesced != nil)
    }

    override var canBecomeFirstResponder: Bool { true }

    /// Three-finger swipes, taps and holds belong to the remote desktop, not
    /// to the system's undo, redo and paste gestures.
    override var editingInteractionConfiguration: UIEditingInteractionConfiguration {
        .none
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { configureHardwareKeyboardMonitor(for: GCKeyboard.coalesced) }
        return became
    }

    override func resignFirstResponder() -> Bool {
        releaseAllPressedKeys()
        return super.resignFirstResponder()
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        if newWindow == nil {
            releasePointerDrag()
            releaseTouchHoldDrag()
            releasePhysicalButtonPress()
            releaseAllPressedKeys()
            releasePointerModifiersNow()
            cancelScrollInteraction()
            stopEdgeScrolling()
            #if !targetEnvironment(macCatalyst)
            remoteCursorHoverLocation = nil
            remoteCursorImageView.isHidden = true
            #endif
        }
        super.willMove(toWindow: newWindow)
    }

    /// Suppress the software keyboard while retaining hardware-keyboard focus
    /// after mouse/trackpad interaction. The explicit keyboard button switches
    /// this back to the system keyboard on touch devices. Container apps can
    /// atomically replace the primary and accessory views through
    /// ``VNCKeyboardCapture/inputViews``.
    override var inputView: UIView? {
        switch keyboardCapture.inputViews.primary {
        case .packageDefault:
            return softwareKeyboardRequested ? nil : suppressedInputView
        case .systemKeyboard:
            return nil
        case .custom(let view):
            return view
        case .systemKeyboardWhenRequested(let fallback):
            return softwareKeyboardRequested ? nil : fallback
        }
    }

    /// The container app supplies an optional keyboard toolbar in the same
    /// atomic snapshot as the primary input view. visionOS has no input
    /// accessory to override, so a host toolbar there goes unshown.
    #if !os(visionOS)
    override var inputAccessoryView: UIView? {
        keyboardCapture.inputViews.accessory
    }
    #endif

    var hasText: Bool { true }

    func update(
        framebufferSize: CGSize,
        viewport: RemoteViewportState,
        viewportPanningMode: RemoteViewportPanningMode,
        pointerMode: RemotePointerMode,
        pointerSpeed: Double,
        cursorHeight: CGFloat,
        serverRendersCursor: Bool,
        showsLocalCursorDot: Bool,
        touchGestures: RemoteTouchGestureConfiguration,
        keyboardActive: Bool,
        keyboardCaptured: Bool,
        inputViewsGeneration: UInt64,
        controlOptionAsCommand: Bool,
        framebufferOrigin: CGPoint,
        requestPasswordSend: @escaping () -> Void,
        requestDictation: @escaping () -> Void,
        toggleFullScreen: (() -> Void)?,
        disconnect: @escaping () -> Void,
        remoteCursor: RemoteCursor?,
        remoteCursorPresence: RemoteCursorPresence
    ) {
        if hardwareKeyboard.controlOptionAsCommand != controlOptionAsCommand {
            releaseAllPressedKeys()
            consumedRemoteAliasUsages.removeAll()
            hardwareKeyboard.controlOptionAsCommand = controlOptionAsCommand
            UIMenuSystem.main.setNeedsRebuild()
        }
        acceptsHardwareInput = keyboardCaptured
        self.framebufferSize = framebufferSize
        self.framebufferOrigin = framebufferOrigin
        self.viewport = viewport
        if self.viewportPanningMode != viewportPanningMode {
            stopEdgeScrolling()
            self.viewportPanningMode = viewportPanningMode
        }
        self.pointerSpeed = pointerSpeed
        let resolvedCursorHeight = TrackpadCursorStyle.resolvedCursorHeight(cursorHeight)
        let localDotChanged = showsLocalCursorDot != self.showsLocalCursorDot
            || (showsLocalCursorDot && resolvedCursorHeight != self.cursorHeight)
        self.cursorHeight = resolvedCursorHeight
        self.serverRendersCursor = serverRendersCursor
        self.showsLocalCursorDot = showsLocalCursorDot
        if localDotChanged {
            // The virtual cursor redraws in the trackpad refresh below.
            #if targetEnvironment(macCatalyst)
            if hoverRecognizer.state == .began || hoverRecognizer.state == .changed {
                applyCatalystCursor()
            }
            #else
            pointerInteraction.invalidate()
            #endif
        }
        if self.touchGestures != touchGestures {
            self.touchGestures = touchGestures
            applyTouchGestureConfiguration()
        }
        if self.pointerMode != pointerMode {
            let previousPointerMode = self.pointerMode
            self.pointerMode = pointerMode
            pointerModeDidChange(from: previousPointerMode, to: pointerMode)
        }
        synchronizeTrackpadModel()
        self.requestPasswordSend = requestPasswordSend
        self.requestDictation = requestDictation
        self.toggleFullScreen = toggleFullScreen
        self.disconnect = disconnect
        self.viewport.clampOffset(
            viewSize: bounds.size,
            framebufferSize: framebufferSize)

        self.remoteCursorPresence = remoteCursorPresence
        if self.remoteCursor?.image !== remoteCursor?.image {
            self.remoteCursor = remoteCursor
            remoteCursorShapeRevision &+= 1
            logTrackpadCursorShape(remoteCursor)
            #if targetEnvironment(macCatalyst)
            catalystCursor = nil
            catalystCursorDisplayScale = 0
            if hoverRecognizer.state == .began || hoverRecognizer.state == .changed {
                applyCatalystCursor()
            }
            #else
            // The hover branch draws the server bitmap at the hover point.
            // In trackpad mode that is the wrong pointer in the wrong place,
            // and the refresh below owns the redraw instead.
            if pointerMode == .direct || hoverIsActive {
                updateRemoteCursorImage(at: remoteCursorHoverLocation)
            }
            pointerInteraction.invalidate()
            #endif
        }
        #if !targetEnvironment(macCatalyst)
        // Zoom and pan move the virtual cursor across the glass without any
        // finger involved, so the drawn cursor has to be re-derived from the
        // viewport this update carries.
        refreshTrackpadCursorImage()
        #endif

        let keyboardModeChanged = keyboardActive != softwareKeyboardRequested
        softwareKeyboardRequested = keyboardActive
        let inputViewsChanged = inputViewsGeneration != lastSeenInputViewsGeneration
        lastSeenInputViewsGeneration = inputViewsGeneration
        if keyboardCaptured {
            if !isFirstResponder { becomeFirstResponder() }
            if keyboardModeChanged || (inputViewsChanged && isFirstResponder) {
                reloadInputViews()
            }
        } else {
            releaseAllPressedKeys()
            if inputViewsChanged, isFirstResponder {
                reloadInputViews()
            }
        }
    }

    /// Called once per switch, after `pointerMode` already holds the new value.
    /// Switching mid-gesture would otherwise strand a held button or a running
    /// momentum scroll, so the gesture layer settles that state here.
    func pointerModeDidChange(
        from previous: RemotePointerMode,
        to current: RemotePointerMode
    ) {
        // Every in-flight interaction belongs to the mode that started it: the
        // button it holds is anchored to a point the other mode cannot reach,
        // and a fling begun under one finger meaning would keep scrolling
        // after that finger changed meaning.
        releasePointerDrag()
        releaseTouchHoldDrag()
        stopEdgeScrolling()
        cancelScrollInteraction()
        trackpadVelocity.reset()
        trackpadConsumedTranslation = .zero

        switch current {
        case .direct:
            trackpadModel = nil
        case .trackpad:
            makeTrackpadModelIfNeeded()
            adoptInFlightTouchStroke()
        }
        updateRecognizerEnablement()

        #if !targetEnvironment(macCatalyst)
        trackpadCursorPresentation = nil
        if current == .direct, !hoverIsActive {
            updateRemoteCursorImage(at: nil)
        }
        refreshTrackpadCursorImage()
        pointerInteraction.invalidate()
        #endif
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        var adjusted = viewport
        adjusted.clampOffset(
            viewSize: bounds.size,
            framebufferSize: framebufferSize)
        if adjusted != viewport {
            viewport = adjusted
            onViewportChange?(adjusted)
        }
        #if !targetEnvironment(macCatalyst)
        // A bounds change moves the desktop under a cursor that did not
        // itself move, and the viewport offset can come out unchanged.
        refreshTrackpadCursorImage()
        #endif
    }

    func insertText(_ text: String) {
        let modifiers = keyboardCapture.supplementalModifiers
        var dispatched = false
        for character in text {
            dispatched = keyboardHandler.handleKeyTap(
                character,
                supplementalModifiers: modifiers) || dispatched
        }
        if dispatched, !modifiers.isEmpty {
            keyboardCapture.onSupplementalModifiersConsumed?()
        }
    }

    func deleteBackward() {
        let modifiers = keyboardCapture.supplementalModifiers
        let dispatched = keyboardHandler.handleKeysymTap(
            KeyboardInputHandler.keysymBackspace,
            supplementalModifiers: modifiers)
        if dispatched, !modifiers.isEmpty {
            keyboardCapture.onSupplementalModifiersConsumed?()
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard keyboardCapture.isCaptured else {
            super.pressesBegan(presses, with: event)
            return
        }
        var unhandled: Set<UIPress> = []
        for press in presses {
            guard let key = press.key else {
                unhandled.insert(press)
                continue
            }
            let usage = UInt32(key.keyCode.rawValue)
            if keyboardCapture.controlOptionAsCommand {
                if (0xE0...0xE7).contains(usage) {
                    _ = hardwareKeyboard.press(usage: usage,
                        keysym: KeyboardInputHandler.keysymForHIDUsage(usage, characters: "",
                            appleModifierConvention: keyboardHandler.usesAppleModifierMapping))
                    clearPendingTapsIfChordEnded()
                    continue
                }
                synchronizeUniversalModifiers(key.modifierFlags)
                if Self.isControlOptionChord(key.modifierFlags) {
                    pressUniversalKey(usage: usage,
                        characters: key.charactersIgnoringModifiers, flags: key.modifierFlags)
                    continue
                }
            }
            // Some UIKit configurations bypass UIKeyCommand arbitration and
            // deliver Command chords directly here. Claim host-owned chords
            // before the generic hardware path can send their target key to
            // VNC. Any modifier downs already sent are released below.
            if let shortcut = reservedHostShortcut(matching: key) {
                releaseAllPressedKeys()
                keyboardCapture.onReservedHostShortcut?(shortcut)
                continue
            }
            if handleCommandCompatibilityAlias(key: key, usage: usage) {
                continue
            }
            #if !targetEnvironment(macCatalyst)
            if handleRemoteSystemAlias(key: key, usage: usage) {
                continue
            }
            #endif
            // Control/Command are represented by separate RFB modifier events.
            // UIKit may put an ASCII control byte in `characters` for those
            // chords, so use the printable layout result instead.
            let characters = KeyboardInputHandler.hardwareCharacters(
                characters: key.characters,
                charactersIgnoringModifiers: key.charactersIgnoringModifiers,
                controlOrCommandDown: !key.modifierFlags
                    .intersection([.control, .command]).isEmpty)
            let keysym = KeyboardInputHandler.keysymForHIDUsage(
                usage,
                characters: characters,
                appleModifierConvention: keyboardHandler.usesAppleModifierMapping)
            guard keysym != 0 else {
                unhandled.insert(press)
                continue
            }
            beginSupplementalModifiersIfNeeded(for: usage)
            _ = hardwareKeyboard.press(usage: usage, keysym: keysym)
        }
        if !unhandled.isEmpty {
            super.pressesBegan(unhandled, with: event)
        }
    }

    /// The containing app's capture toggle reaches this through the responder
    /// chain. Host integrations toggle only the reserved-shortcut destination;
    /// standalone viewers retain the broad keyboard-capture behavior.
    @objc func toggleVNCKeyboardCapture(_ sender: Any?) {
        keyboardCapture.toggleCaptureMode()
        if !keyboardCapture.isCaptured {
            softwareKeyboardRequested = false
            onKeyboardActiveChange?(false)
            releaseAllPressedKeys()
            reloadInputViews()
        } else {
            becomeFirstResponder()
        }
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(toggleVNCKeyboardCapture(_:)) {
            return true
        }
        return super.canPerformAction(action, withSender: sender)
    }

    @objc private func handleReservedHostShortcut(_ command: UIKeyCommand) {
        if routeUniversalCommandIfNeeded(command) { return }
        guard keyboardCapture.isCaptured,
              let shortcut = reservedHostShortcut(matching: command) else { return }
        releaseAllPressedKeys()
        keyboardCapture.onReservedHostShortcut?(shortcut)
    }

    @objc private func handleStandardRemoteCommand(_ command: UIKeyCommand) {
        if routeUniversalCommandIfNeeded(command) { return }
        guard keyboardCapture.isCaptured,
              let remoteCommand = Self.remoteCommand(matching: command) else { return }
        releaseAllPressedKeys()
        keyboardHandler.handleRemoteCommand(remoteCommand)
    }

    @objc private func handleRemoteNavigationKey(_ command: UIKeyCommand) {
        guard keyboardCapture.isCaptured,
              let input = command.input else { return }

        let usage: UInt32
        switch input {
        case UIKeyCommand.inputUpArrow: usage = 0x52
        case UIKeyCommand.inputDownArrow: usage = 0x51
        case UIKeyCommand.inputLeftArrow: usage = 0x50
        case UIKeyCommand.inputRightArrow: usage = 0x4F
        default: return
        }

        beginSupplementalModifiersIfNeeded(for: usage)
        let keysym = KeyboardInputHandler.keysymForHIDUsage(
            usage,
            characters: input)
        _ = hardwareKeyboard.press(usage: usage, keysym: keysym)
    }

    @objc private func handleCommandCompatibilityAlias(_ command: UIKeyCommand) {
        if routeUniversalCommandIfNeeded(command) { return }
        guard keyboardCapture.isCaptured,
              let character = command.input?.lowercased().first,
              character == "h" || character == "m" else { return }
        releaseAllPressedKeys()
        keyboardHandler.handleCommandTap(character)
    }

    private func handleCommandCompatibilityAlias(
        key: UIKey,
        usage: UInt32
    ) -> Bool {
        guard !keyboardCapture.controlOptionAsCommand else { return false }
        let flags = key.modifierFlags.intersection([
            .control, .alternate, .shift, .command,
        ])
        guard flags == [.control, .alternate] else { return false }

        let character: Character
        switch usage {
        case 0x0B: character = "h"
        case 0x10: character = "m"
        default: return false
        }

        releaseAllPressedKeys()
        if consumedRemoteAliasUsages.insert(usage).inserted {
            keyboardHandler.handleCommandTap(character)
        }
        return true
    }

    @objc private func handlePasswordCommand(_ command: UIKeyCommand) {
        requestPasswordSend()
    }

    @objc private func handleDictationCommand(_ command: UIKeyCommand) {
        if routeUniversalCommandIfNeeded(command) { return }
        requestDictation()
    }

    @objc private func handleFullScreenCommand(_ command: UIKeyCommand) {
        toggleFullScreen?()
    }

    @objc private func handleDisconnectCommand(_ command: UIKeyCommand) {
        disconnect()
    }

    private static func remoteCommand(matching command: UIKeyCommand) -> RemoteCommand? {
        guard let input = command.input else { return nil }
        let modifiers = command.modifierFlags.intersection([
            .control, .alternate, .shift, .command,
        ])
        return RemoteCommand.allCases.first {
            uiInput(for: $0.shortcut.input) == input
                && uiModifiers(for: $0.shortcut.modifiers) == modifiers
        }
    }

    private static func uiInput(for input: RemoteCommandInput) -> String {
        switch input {
        case .character(let character): String(character)
        case .upArrow: UIKeyCommand.inputUpArrow
        case .downArrow: UIKeyCommand.inputDownArrow
        case .leftArrow: UIKeyCommand.inputLeftArrow
        case .rightArrow: UIKeyCommand.inputRightArrow
        case .escape: UIKeyCommand.inputEscape
        case .delete: "\u{8}"
        }
    }

    private static func uiModifiers(
        for modifiers: RemoteCommandModifiers
    ) -> UIKeyModifierFlags {
        var flags: UIKeyModifierFlags = []
        if modifiers.contains(.control) { flags.insert(.control) }
        if modifiers.contains(.option) { flags.insert(.alternate) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        if modifiers.contains(.command) { flags.insert(.command) }
        return flags
    }

    private static func isStandardRemoteShortcut(
        input: String,
        modifiers: UIKeyModifierFlags
    ) -> Bool {
        RemoteCommand.allCases.contains {
            uiInput(for: $0.shortcut.input) == input
                && uiModifiers(for: $0.shortcut.modifiers) == modifiers
        }
    }

    private static func isReservedViewerShortcut(
        input: String,
        modifiers: UIKeyModifierFlags
    ) -> Bool {
        let signature = (input.lowercased(), modifiers)
        return signature == ("p", [.control, .shift])
            || signature == ("l", [.control, .alternate])
            || signature == ("f", [.control, .shift])
            || signature == ("q", [.alternate, .command])
    }

    private func isReservedHostShortcut(
        input: String,
        modifiers: UIKeyModifierFlags
    ) -> Bool {
        let normalizedModifiers = modifiers.intersection([
            .control, .alternate, .shift, .command,
        ])
        return keyboardCapture.reservedHostShortcuts.contains { shortcut in
            shortcut.input.lowercased() == input.lowercased()
                && Self.uiModifiers(for: shortcut.modifiers) == normalizedModifiers
        }
    }

    private func reservedHostShortcut(
        matching command: UIKeyCommand
    ) -> VNCHostKeyboardShortcut? {
        guard let input = command.input else { return nil }
        let modifiers = command.modifierFlags.intersection([
            .control, .alternate, .shift, .command,
        ])
        return keyboardCapture.reservedHostShortcuts.first { shortcut in
            if shortcut.input.lowercased() == input.lowercased(),
               Self.uiModifiers(for: shortcut.modifiers) == modifiers {
                return true
            }

            guard shortcut.modifiers.contains(.shift),
                  Self.shiftedHostShortcutInput(shortcut.input)?.lowercased()
                    == input.lowercased() else { return false }
            var shiftedModifiers = Self.uiModifiers(for: shortcut.modifiers)
            shiftedModifiers.remove(.shift)
            return shiftedModifiers == modifiers
        }
    }

    private func reservedHostShortcut(
        matching key: UIKey
    ) -> VNCHostKeyboardShortcut? {
        let modifiers = key.modifierFlags.intersection([
            .control, .alternate, .shift, .command,
        ])
        let unmodifiedInput = key.charactersIgnoringModifiers.lowercased()
        let modifiedInput = key.characters.lowercased()

        return keyboardCapture.reservedHostShortcuts.first { shortcut in
            let shortcutInput = shortcut.input.lowercased()
            let shortcutModifiers = Self.uiModifiers(for: shortcut.modifiers)
            if shortcutModifiers == modifiers,
               (shortcutInput == unmodifiedInput || shortcutInput == modifiedInput) {
                return true
            }

            guard shortcut.modifiers.contains(.shift),
                  let shiftedInput = Self.shiftedHostShortcutInput(shortcut.input)?
                    .lowercased(),
                  shiftedInput == modifiedInput else { return false }

            // Physical UIKey events normally retain Shift, while Catalyst can
            // normalize shifted punctuation to the produced character and
            // omit Shift. Accept both representations of the same key chord.
            if shortcutModifiers == modifiers { return true }
            var normalizedModifiers = shortcutModifiers
            normalizedModifiers.remove(.shift)
            return normalizedModifiers == modifiers
        }
    }

    private static func shiftedHostShortcutInput(_ input: String) -> String? {
        switch input {
        case "[": "{"
        case "]": "}"
        case "\\": "|"
        default: nil
        }
    }

    private static func uiModifiers(
        for modifiers: VNCKeyboardModifiers
    ) -> UIKeyModifierFlags {
        var flags: UIKeyModifierFlags = []
        if modifiers.contains(.control) { flags.insert(.control) }
        if modifiers.contains(.option) { flags.insert(.alternate) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        if modifiers.contains(.command) { flags.insert(.command) }
        return flags
    }

    @objc private func hardwareKeyboardDidConnect(_ notification: Notification) {
        onHardwareKeyboardAttachedChange?(true)
        guard isFirstResponder else { return }
        configureHardwareKeyboardMonitor(
            for: notification.object as? GCKeyboard ?? GCKeyboard.coalesced)
    }

    @objc private func hardwareKeyboardDidDisconnect(_ notification: Notification) {
        releaseAllPressedKeys()
        // GameController may post before `coalesced` drops the disconnected
        // instance. Read it on the next main-loop turn so multiple connected
        // keyboards are handled correctly too.
        DispatchQueue.main.async { [weak self] in
            self?.publishHardwareKeyboardAvailability()
            if self?.isFirstResponder == true {
                self?.configureHardwareKeyboardMonitor(for: GCKeyboard.coalesced)
            }
        }
    }

    /// Recover modifier/key releases that UIKit may omit for intercepted
    /// commands. Printable input still uses UIKit's keyboard-layout result.
    private func configureHardwareKeyboardMonitor(for keyboard: GCKeyboard?) {
        let input = keyboard?.keyboardInput
        monitoredCatalystKeyboardInput?.keyChangedHandler = nil
        monitoredCatalystKeyboardInput = input
        input?.keyChangedHandler = { [weak self] keyboard, _, keyCode, pressed in
            var flags: UIKeyModifierFlags = []
            if keyboard.button(forKeyCode: .leftControl)?.isPressed == true
                || keyboard.button(forKeyCode: .rightControl)?.isPressed == true { flags.insert(.control) }
            if keyboard.button(forKeyCode: .leftAlt)?.isPressed == true
                || keyboard.button(forKeyCode: .rightAlt)?.isPressed == true { flags.insert(.alternate) }
            if keyboard.button(forKeyCode: .leftShift)?.isPressed == true
                || keyboard.button(forKeyCode: .rightShift)?.isPressed == true { flags.insert(.shift) }
            if keyboard.button(forKeyCode: .leftGUI)?.isPressed == true
                || keyboard.button(forKeyCode: .rightGUI)?.isPressed == true { flags.insert(.command) }
            let snapshot = flags
            let usage = UInt32(keyCode.rawValue)
            Task { @MainActor [weak self] in
                self?.handleMonitoredUniversalKey(usage: usage, pressed: pressed, flags: snapshot)
            }
            #if targetEnvironment(macCatalyst)
            // Option/Command+arrow chords: Catalyst consumes these as its own
            // cursor movement and never delivers them via pressesBegan or a
            // UIKeyCommand, so read them straight from GameController — the same
            // approach the terminal uses for Control+arrow. Plain arrows and
            // Control(+Option) arrows keep their existing UIKeyCommand paths.
            let arrowUsage: UInt32?
            switch keyCode {
            case .upArrow: arrowUsage = 0x52
            case .downArrow: arrowUsage = 0x51
            case .leftArrow: arrowUsage = 0x50
            case .rightArrow: arrowUsage = 0x4F
            default: arrowUsage = nil
            }
            if let arrowUsage {
                let control = keyboard.button(forKeyCode: .leftControl)?.isPressed == true
                    || keyboard.button(forKeyCode: .rightControl)?.isPressed == true
                let option = keyboard.button(forKeyCode: .leftAlt)?.isPressed == true
                    || keyboard.button(forKeyCode: .rightAlt)?.isPressed == true
                let command = keyboard.button(forKeyCode: .leftGUI)?.isPressed == true
                    || keyboard.button(forKeyCode: .rightGUI)?.isPressed == true
                let shift = keyboard.button(forKeyCode: .leftShift)?.isPressed == true
                    || keyboard.button(forKeyCode: .rightShift)?.isPressed == true
                // Control(+Option)+arrow is the Spaces/Mission Control shortcut
                // owned by the standard remote commands; leave it alone.
                guard (option || command), !control else { return }
                Task { @MainActor [weak self] in
                    self?.handleCatalystModifiedArrow(
                        usage: arrowUsage,
                        pressed: pressed,
                        option: option,
                        command: command,
                        shift: shift)
                }
                return
            }

            let alias: (usage: UInt32, character: Character)?
            switch keyCode {
            case .keyH: alias = (0x0B, "h")
            case .keyM: alias = (0x10, "m")
            default: alias = nil
            }
            guard let alias else { return }

            let controlDown = keyboard.button(forKeyCode: .leftControl)?.isPressed == true
                || keyboard.button(forKeyCode: .rightControl)?.isPressed == true
            let optionDown = keyboard.button(forKeyCode: .leftAlt)?.isPressed == true
                || keyboard.button(forKeyCode: .rightAlt)?.isPressed == true
            let shiftDown = keyboard.button(forKeyCode: .leftShift)?.isPressed == true
                || keyboard.button(forKeyCode: .rightShift)?.isPressed == true
            let commandDown = keyboard.button(forKeyCode: .leftGUI)?.isPressed == true
                || keyboard.button(forKeyCode: .rightGUI)?.isPressed == true
            let isExactAlias = controlDown && optionDown && !shiftDown && !commandDown

            Task { @MainActor [weak self] in
                self?.handleCatalystCommandCompatibilityAlias(
                    usage: alias.usage,
                    character: alias.character,
                    pressed: pressed,
                    isExactAlias: isExactAlias)
            }
            #endif
        }
    }

    private func handleMonitoredUniversalKey(usage: UInt32, pressed: Bool, flags: UIKeyModifierFlags) {
        guard acceptsHardwareInput, isFirstResponder, window?.isKeyWindow == true,
              keyboardCapture.isCaptured, keyboardCapture.controlOptionAsCommand else { return }
        if (0xE0...0xE7).contains(usage) {
            if pressed {
                _ = hardwareKeyboard.press(usage: usage,
                    keysym: KeyboardInputHandler.keysymForHIDUsage(usage, characters: "",
                        appleModifierConvention: keyboardHandler.usesAppleModifierMapping))
            } else {
                _ = hardwareKeyboard.release(usage: usage)
            }
            synchronizeUniversalModifiers(flags)
            return
        }
        if !pressed {
            if universalKeys.release(usage: usage) {
                _ = hardwareKeyboard.release(usage: usage)
                endSupplementalModifiers(for: usage)
            }
            return
        }
        guard Self.isControlOptionChord(flags) else { return }
        // Non-printable keys have layout-independent HID keysyms. In
        // particular, Catalyst can swallow mapped arrows before UIKit.
        if (0x28...0x73).contains(usage),
           KeyboardInputHandler.keysymForHIDUsage(usage, characters: "") != 0 {
            pressUniversalKey(usage: usage, characters: "", flags: flags)
        }
    }

    #if targetEnvironment(macCatalyst)
    private func handleCatalystCommandCompatibilityAlias(
        usage: UInt32,
        character: Character,
        pressed: Bool,
        isExactAlias: Bool
    ) {
        guard pressed else {
            consumedRemoteAliasUsages.remove(usage)
            return
        }
        guard isFirstResponder, keyboardCapture.isCaptured,
              !keyboardCapture.controlOptionAsCommand, isExactAlias else { return }
        releaseAllPressedKeys()
        if consumedRemoteAliasUsages.insert(usage).inserted {
            keyboardHandler.handleCommandTap(character)
        }
    }

    /// Deliver an Option/Command+arrow chord read from GameController as one
    /// atomic remote chord (Option mapped to `Meta_L` on Apple servers), with
    /// key-repeat while the chord stays physically held. Used because Catalyst
    /// routes these arrows to its own cursor movement instead of the responder.
    private func handleCatalystModifiedArrow(
        usage: UInt32,
        pressed: Bool,
        option: Bool,
        command: Bool,
        shift: Bool
    ) {
        guard keyboardCapture.isCaptured else {
            stopCatalystArrowRepeat()
            return
        }
        guard pressed else {
            stopCatalystArrowRepeat(matching: usage)
            return
        }

        var modifiers: VNCKeyboardModifiers = []
        if command { modifiers.insert(.command) }
        if option { modifiers.insert(.option) }
        if shift { modifiers.insert(.shift) }

        let keysym = KeyboardInputHandler.keysymForHIDUsage(usage, characters: "")
        guard keysym != 0 else { return }

        // A physical modifier that reached RFB via pressesBegan is cleared so
        // each atomic chord is self-contained; subsequent repeats then no-op.
        releaseAllPressedKeys()
        keyboardHandler.handleKeysymTap(keysym, supplementalModifiers: modifiers)
        startCatalystArrowRepeat(usage: usage, keysym: keysym, modifiers: modifiers)
    }

    private func startCatalystArrowRepeat(
        usage: UInt32,
        keysym: UInt32,
        modifiers: VNCKeyboardModifiers
    ) {
        stopCatalystArrowRepeat()
        catalystArrowRepeatUsage = usage
        let delay = Timer(timeInterval: 0.225, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.catalystArrowRepeatUsage == usage,
                      self.catalystArrowChordStillHeld(usage: usage) else {
                    self?.stopCatalystArrowRepeat(matching: usage)
                    return
                }
                self.keyboardHandler.handleKeysymTap(keysym, supplementalModifiers: modifiers)
                let repeating = Timer(timeInterval: 0.03, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, self.catalystArrowRepeatUsage == usage,
                              self.catalystArrowChordStillHeld(usage: usage) else {
                            self?.stopCatalystArrowRepeat(matching: usage)
                            return
                        }
                        self.keyboardHandler.handleKeysymTap(
                            keysym, supplementalModifiers: modifiers)
                    }
                }
                self.catalystArrowRepeatTimer = repeating
                RunLoop.main.add(repeating, forMode: .common)
            }
        }
        catalystArrowDelayTimer = delay
        RunLoop.main.add(delay, forMode: .common)
    }

    private func stopCatalystArrowRepeat(matching usage: UInt32? = nil) {
        guard usage == nil || catalystArrowRepeatUsage == usage else { return }
        catalystArrowDelayTimer?.invalidate()
        catalystArrowDelayTimer = nil
        catalystArrowRepeatTimer?.invalidate()
        catalystArrowRepeatTimer = nil
        catalystArrowRepeatUsage = nil
    }

    /// Whether the repeating arrow and at least one of its Option/Command
    /// modifiers are still physically held, read live from GameController.
    private func catalystArrowChordStillHeld(usage: UInt32) -> Bool {
        guard let input = GCKeyboard.coalesced?.keyboardInput else { return false }
        let keyCode: GCKeyCode
        switch usage {
        case 0x52: keyCode = .upArrow
        case 0x51: keyCode = .downArrow
        case 0x50: keyCode = .leftArrow
        case 0x4F: keyCode = .rightArrow
        default: return false
        }
        guard input.button(forKeyCode: keyCode)?.isPressed == true else { return false }
        let option = input.button(forKeyCode: .leftAlt)?.isPressed == true
            || input.button(forKeyCode: .rightAlt)?.isPressed == true
        let command = input.button(forKeyCode: .leftGUI)?.isPressed == true
            || input.button(forKeyCode: .rightGUI)?.isPressed == true
        let control = input.button(forKeyCode: .leftControl)?.isPressed == true
            || input.button(forKeyCode: .rightControl)?.isPressed == true
        return (option || command) && !control
    }

    /// Send a Catalyst Delete word-editing chord (Option/Command ± Shift +
    /// Delete) as one atomic remote chord. Routing through `handleKeysymTap`
    /// keeps Option mapped to `Meta_L` on Apple servers and leaves no modifier
    /// held, since the system-consumed Delete never yields a matching key-up.
    @objc private func handleCatalystEditingKeyCommand(_ command: UIKeyCommand) {
        guard keyboardCapture.isCaptured else { return }

        var modifiers: VNCKeyboardModifiers = []
        let flags = command.modifierFlags
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.alternate) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.command) { modifiers.insert(.command) }

        // Any physical modifier that reached RFB before UIKit delivered this
        // command is cleared so the atomic chord is the only thing in flight.
        releaseAllPressedKeys()
        keyboardHandler.handleKeysymTap(
            KeyboardInputHandler.keysymBackspace,
            supplementalModifiers: modifiers)
    }

    @objc private func handleControlKeyCommand(_ command: UIKeyCommand) {
        guard keyboardCapture.isCaptured else { return }
        ensureModifierKeys(for: command.modifierFlags)

        let usage: UInt32?
        if command.input == UIKeyCommand.inputUpArrow {
            usage = 0x52
        } else if command.input == UIKeyCommand.inputDownArrow {
            usage = 0x51
        } else if command.input == UIKeyCommand.inputLeftArrow {
            usage = 0x50
        } else if command.input == UIKeyCommand.inputRightArrow {
            usage = 0x4F
        } else if let character = command.input?.lowercased().first {
            usage = Self.controlCommandHIDUsages[character]
        } else {
            usage = nil
        }
        guard let usage else { return }
        let characters = command.input ?? ""
        let keysym = KeyboardInputHandler.keysymForHIDUsage(
            usage,
            characters: characters)
        _ = hardwareKeyboard.press(usage: usage, keysym: keysym)
    }

    private func ensureModifierKeys(for flags: UIKeyModifierFlags) {
        let input = GCKeyboard.coalesced?.keyboardInput
        ensureModifier(
            enabled: flags.contains(.control),
            leftUsage: 0xE0,
            rightUsage: 0xE4,
            rightPressed: input?.button(forKeyCode: .rightControl)?.isPressed == true,
            leftKeysym: KeyboardInputHandler.keysymControlL,
            rightKeysym: KeyboardInputHandler.keysymControlR)
        ensureModifier(
            enabled: flags.contains(.shift),
            leftUsage: 0xE1,
            rightUsage: 0xE5,
            rightPressed: input?.button(forKeyCode: .rightShift)?.isPressed == true,
            leftKeysym: KeyboardInputHandler.keysymShiftL,
            rightKeysym: KeyboardInputHandler.keysymShiftR)
        let appleModifiers = keyboardHandler.usesAppleModifierMapping
        ensureModifier(
            enabled: flags.contains(.alternate),
            leftUsage: 0xE2,
            rightUsage: 0xE6,
            rightPressed: input?.button(forKeyCode: .rightAlt)?.isPressed == true,
            leftKeysym: KeyboardInputHandler.optionLeftKeysym(
                appleModifierConvention: appleModifiers),
            rightKeysym: KeyboardInputHandler.optionRightKeysym(
                appleModifierConvention: appleModifiers))
        ensureModifier(
            enabled: flags.contains(.command),
            leftUsage: 0xE3,
            rightUsage: 0xE7,
            rightPressed: input?.button(forKeyCode: .rightGUI)?.isPressed == true,
            leftKeysym: KeyboardInputHandler.keysymSuperL,
            rightKeysym: KeyboardInputHandler.keysymSuperR)
    }

    private func ensureModifier(
        enabled: Bool,
        leftUsage: UInt32,
        rightUsage: UInt32,
        rightPressed: Bool,
        leftKeysym: UInt32,
        rightKeysym: UInt32
    ) {
        guard enabled,
              !hardwareKeyboard.contains(usage: leftUsage),
              !hardwareKeyboard.contains(usage: rightUsage) else { return }
        _ = hardwareKeyboard.press(
            usage: rightPressed ? rightUsage : leftUsage,
            keysym: rightPressed ? rightKeysym : leftKeysym)
    }

    private static func hidUsage(forCommandInput input: String) -> UInt32? {
        switch input {
        case UIKeyCommand.inputUpArrow: return 0x52
        case UIKeyCommand.inputDownArrow: return 0x51
        case UIKeyCommand.inputLeftArrow: return 0x50
        case UIKeyCommand.inputRightArrow: return 0x4F
        case UIKeyCommand.inputHome: return 0x4A
        case UIKeyCommand.inputEnd: return 0x4D
        case UIKeyCommand.inputPageUp: return 0x4B
        case UIKeyCommand.inputPageDown: return 0x4E
        case UIKeyCommand.inputEscape: return 0x29
        case "\r": return 0x28
        case "\t": return 0x2B
        default:
            guard let character = input.lowercased().first else { return nil }
            return controlCommandHIDUsages[character]
        }
    }

    private static let controlCommandHIDUsages: [Character: UInt32] = {
        var result: [Character: UInt32] = [:]
        for (offset, character) in "abcdefghijklmnopqrstuvwxyz".enumerated() {
            result[character] = UInt32(0x04 + offset)
        }
        for (offset, character) in "1234567890".enumerated() {
            result[character] = UInt32(0x1E + offset)
        }
        result[" "] = 0x2C
        result["-"] = 0x2D
        result["="] = 0x2E
        result["/"] = 0x38
        result["\\"] = 0x31
        result["["] = 0x2F
        result["]"] = 0x30
        result[";"] = 0x33
        result["'"] = 0x34
        result[","] = 0x36
        result["."] = 0x37
        result["`"] = 0x35
        return result
    }()
    #else
    @objc private func handleRemoteCommandKey(_ command: UIKeyCommand) {
        guard keyboardCapture.isCaptured,
              let input = command.input,
              let character = input.lowercased().first,
              let usage = Self.remoteCommandHIDUsages[character] else { return }

        ensureLeftModifier(
            command.modifierFlags.contains(.control),
            usage: 0xE0,
            keysym: KeyboardInputHandler.keysymControlL)
        ensureLeftModifier(
            command.modifierFlags.contains(.shift),
            usage: 0xE1,
            keysym: KeyboardInputHandler.keysymShiftL)
        ensureLeftModifier(
            command.modifierFlags.contains(.alternate),
            usage: 0xE2,
            keysym: KeyboardInputHandler.optionLeftKeysym(
                appleModifierConvention: keyboardHandler.usesAppleModifierMapping))
        ensureLeftModifier(
            command.modifierFlags.contains(.command),
            usage: 0xE3,
            keysym: KeyboardInputHandler.keysymSuperL)

        let keysym = KeyboardInputHandler.keysymForHIDUsage(
            usage,
            characters: input)
        _ = hardwareKeyboard.press(usage: usage, keysym: keysym)
    }

    private func handleRemoteSystemAlias(
        key: UIKey,
        usage: UInt32
    ) -> Bool {
        let flags = key.modifierFlags.intersection([
            .control, .alternate, .shift, .command,
        ])
        var modifiers: RemoteCommandModifiers = []
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.alternate) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.command) { modifiers.insert(.command) }

        let input: RemoteCommandInput
        switch usage {
        case 0x52: input = .upArrow
        case 0x51: input = .downArrow
        case 0x50: input = .leftArrow
        case 0x4F: input = .rightArrow
        case 0x29: input = .escape
        case 0x2A, 0x4C: input = .delete
        default:
            guard let character = key.charactersIgnoringModifiers
                .lowercased().first else { return false }
            input = .character(character)
        }

        let command = RemoteCommand.allCases.first(where: {
            $0.shortcut == RemoteCommandShortcut(
                input: input,
                modifiers: modifiers)
        })
        guard let command else { return false }

        // Alias modifiers may already have reached RFB before UIKit delivers
        // the target key. Clear them, consume the target through key-up, and
        // send one clean remote command chord.
        releaseAllPressedKeys()
        if consumedRemoteAliasUsages.insert(usage).inserted {
            keyboardHandler.handleRemoteCommand(command)
        }
        return true
    }

    private func ensureLeftModifier(
        _ enabled: Bool,
        usage: UInt32,
        keysym: UInt32
    ) {
        guard enabled, !hardwareKeyboard.contains(usage: usage) else { return }
        _ = hardwareKeyboard.press(usage: usage, keysym: keysym)
    }

    private static let remoteCommandHIDUsages: [Character: UInt32] = {
        var result: [Character: UInt32] = [:]
        for (offset, character) in "abcdefghijklmnopqrstuvwxyz".enumerated() {
            result[character] = UInt32(0x04 + offset)
        }
        for (offset, character) in "1234567890".enumerated() {
            result[character] = UInt32(0x1E + offset)
        }
        result[" "] = 0x2C
        result["-"] = 0x2D
        result["="] = 0x2E
        result["["] = 0x2F
        result["]"] = 0x30
        result["\\"] = 0x31
        result[";"] = 0x33
        result["'"] = 0x34
        result["`"] = 0x35
        result[","] = 0x36
        result["."] = 0x37
        result["/"] = 0x38
        return result
    }()
    #endif

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = releaseHardwarePresses(presses)
        if !unhandled.isEmpty {
            super.pressesEnded(unhandled, with: event)
        }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        consumedRemoteAliasUsages.removeAll()
        releaseAllPressedKeys()
        super.pressesCancelled(presses, with: event)
    }

    private func releaseHardwarePresses(_ presses: Set<UIPress>) -> Set<UIPress> {
        var unhandled: Set<UIPress> = []
        for press in presses {
            guard let key = press.key else {
                unhandled.insert(press)
                continue
            }
            let usage = UInt32(key.keyCode.rawValue)
            if keyboardCapture.controlOptionAsCommand, (0xE0...0xE7).contains(usage) {
                _ = hardwareKeyboard.release(usage: usage)
                clearPendingTapsIfChordEnded()
                continue
            }
            let releasedKeysym = KeyboardInputHandler.keysymForHIDUsage(
                usage, characters: key.charactersIgnoringModifiers.lowercased())
            let wasUniversalKey = universalKeys.release(usage: usage, keysym: releasedKeysym)
            if consumedRemoteAliasUsages.remove(usage) != nil {
                continue
            }
            guard hardwareKeyboard.release(usage: usage) else {
                if !wasUniversalKey { unhandled.insert(press) }
                continue
            }
            endSupplementalModifiers(for: usage)
        }
        return unhandled
    }

    private func releaseAllPressedKeys() {
        universalKeys.releaseAll()
        hardwareKeyboard.releaseAll()
        releaseAllSupplementalModifiers()
        #if targetEnvironment(macCatalyst)
        stopCatalystArrowRepeat()
        #endif
    }

    private func beginSupplementalModifiersIfNeeded(for usage: UInt32) {
        // Modifier-only presses already have explicit physical transitions.
        guard !(0xE0...0xE7).contains(usage),
              !supplementalModifierState.contains(.key(usage)) else { return }

        let configured = keyboardCapture.supplementalModifiers
        guard !configured.isEmpty else { return }
        let keysyms = KeyboardInputHandler.keysyms(
            for: configured,
            appleModifierConvention: keyboardHandler.usesAppleModifierMapping)

        // The owner record doubles as the repeat sentinel for this usage.
        supplementalModifierState.begin(.key(usage), keysyms: keysyms)
            .forEach(sendSupplementalTransition)
        keyboardCapture.onSupplementalModifiersConsumed?()
    }

    private func endSupplementalModifiers(for usage: UInt32) {
        supplementalModifierState.end(.key(usage))
            .forEach(sendSupplementalTransition)
    }

    /// Keyboard resets run mid-gesture, so they leave pointer holds alone.
    private func releaseAllSupplementalModifiers() {
        supplementalModifierState.releaseKeyOwners()
            .forEach(sendSupplementalTransition)
    }

    // MARK: Pointer modifiers

    /// RFB pointer messages carry no modifier bits, so toolbar modifiers go
    /// down as key events before a press. Returns the owner to end later.
    private func beginPointerModifiers() -> UInt64? {
        let configured = keyboardCapture.supplementalModifiers
        guard !configured.isEmpty else { return nil }
        let keysyms = KeyboardInputHandler.keysyms(
            for: configured,
            appleModifierConvention: keyboardHandler.usesAppleModifierMapping)
        nextPointerModifierOwner &+= 1
        let owner = nextPointerModifierOwner
        supplementalModifierState.begin(.pointer(owner), keysyms: keysyms)
            .forEach(sendSupplementalTransition)
        keyboardCapture.onSupplementalModifiersConsumed?()
        return owner
    }

    /// Releases after the chord delay so remote apps that read live modifier
    /// state at click or drop time still see it.
    private func endPointerModifiers(_ owner: UInt64?) {
        guard let owner else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: KeyboardInputHandler.chordReleaseDelay)
            guard let self else { return }
            self.supplementalModifierState.end(.pointer(owner))
                .forEach(self.sendSupplementalTransition)
        }
    }

    private func releasePointerModifiersNow() {
        supplementalModifierState.releasePointerOwners()
            .forEach(sendSupplementalTransition)
    }

    private func clickWithPointerModifiers(_ click: () -> Void) {
        let owner = beginPointerModifiers()
        click()
        endPointerModifiers(owner)
    }

    private func sendSupplementalTransition(_ transition: HardwareKeyboardTransition) {
        sendSharedModifier(transition, usage: nil)
    }

    /// Every shared-state emission goes through here so a release always
    /// takes the same API (HID usage or keysym) as the press it ends.
    private func sendSharedModifier(
        _ transition: HardwareKeyboardTransition,
        usage offered: UInt32?
    ) {
        if let usage = modifierPressRoutes.usage(for: transition, offered: offered) {
            keyboardHandler.handlePhysicalKey(
                downFlag: transition.downFlag,
                usage: usage,
                keysym: transition.keysym)
        } else {
            keyboardHandler.handleKeysym(
                downFlag: transition.downFlag,
                keysym: transition.keysym)
        }
    }

    /// Physical modifiers share reference counts with toolbar holds, so
    /// releasing one source never lifts a modifier another still holds.
    private func routePhysicalModifier(
        _ transition: HardwareKeyboardTransition,
        usage: UInt32?
    ) {
        let owner = SupplementalHardwareModifierState.Owner
            .physicalModifier(transition.keysym)
        let transitions = transition.downFlag
            ? supplementalModifierState.begin(owner, keysyms: [transition.keysym])
            : supplementalModifierState.end(owner)
        for routed in transitions {
            sendSharedModifier(routed, usage: usage)
        }
    }

    @objc private func applicationWillResignActive() {
        releaseAllPressedKeys()
        releasePointerDrag()
        releaseTouchHoldDrag()
        releasePhysicalButtonPress()
        releasePointerModifiersNow()
        stopEdgeScrolling()
        #if !targetEnvironment(macCatalyst)
        remoteCursorHoverLocation = nil
        remoteCursorImageView.isHidden = true
        #endif
    }

    @objc private func windowDidResignKey(_ notification: Notification) {
        guard notification.object as AnyObject? === window else { return }
        releaseAllPressedKeys()
        releasePointerDrag()
        releaseTouchHoldDrag()
        releasePhysicalButtonPress()
        releasePointerModifiersNow()
        stopEdgeScrolling()
        #if !targetEnvironment(macCatalyst)
        remoteCursorHoverLocation = nil
        remoteCursorImageView.isHidden = true
        #endif
    }

    private func releasePointerDrag() {
        if pointerDragActive, let point = lastPointerPoint {
            touchHandler.handleDragEnd(x: point.x, y: point.y)
        }
        endPointerModifiers(pointerDragModifierOwner)
        pointerDragModifierOwner = nil
        pointerDragActive = false
        lastPointerPoint = nil
    }

    /// Catalyst does not consistently expose a deceleration phase for its
    /// UIEvent.scroll pan. Consume the direct translation and always generate
    /// the momentum tail ourselves from displacement over the gesture's
    /// trailing window, the same way native scroll views derive a fling.
    @objc private func handleNativeScrollState(_ recognizer: UIPanGestureRecognizer) {
        stopEdgeScrolling()
        logInputRoute(
            "scroll state=\(recognizer.state.rawValue) "
            + "translation=\(recognizer.translation(in: self))")
        switch recognizer.state {
        case .began:
            if momentumScrollPhaseActive {
                endMomentumScrollPhase()
                finishScrollInteraction()
            }
            momentumCatchPending = false
            momentumCatchTimestamp = 0
            activeScrollRecognizer = recognizer
            activeScrollUsesDirectTouch = false
            let translation = recognizer.translation(in: self)
            let now = CACurrentMediaTime()
            releaseVelocityEstimator.reset()
            releaseVelocityEstimator.record(position: translation, at: now)
            previousScrollTranslation = translation
            previousScrollTimestamp = now
            beginScrollInteractionIfNeeded(
                at: recognizer.location(in: self),
                initialTranslation: translation)
        case .changed:
            guard activeScrollRecognizer === recognizer else { return }
            let translation = recognizer.translation(in: self)
            let now = CACurrentMediaTime()
            let deltaX = translation.x - previousScrollTranslation.x
            let deltaY = translation.y - previousScrollTranslation.y
            releaseVelocityEstimator.record(position: translation, at: now)
            previousScrollTranslation = translation
            previousScrollTimestamp = now
            sendFilteredScrollDelta(
                deltaX: deltaX,
                deltaY: deltaY,
                scrollPhase: .changed)
        case .ended:
            guard activeScrollRecognizer === recognizer else { return }
            flushPendingScrollDelta()
            endDirectScrollPhase(.ended)
            if !beginSyntheticMomentumIfNeeded() {
                finishScrollInteraction()
            }
        case .cancelled, .failed:
            guard activeScrollRecognizer === recognizer else { return }
            cancelScrollInteraction()
        default:
            break
        }
    }

    /// `overridingScrollPoint` lets a caller that already knows the remote
    /// coordinate skip the round trip through view space. Relative pointing
    /// scrolls at the virtual cursor, which no finger location describes.
    private func beginScrollInteractionIfNeeded(
        at location: CGPoint,
        initialTranslation: CGPoint,
        overridingScrollPoint: (x: UInt16, y: UInt16)? = nil
    ) {
        guard !directScrollPhaseActive else { return }
        if momentumScrollPhaseActive {
            endMomentumScrollPhase()
        }
        directScrollPhaseActive = true
        lastScrollPoint = nil
        scrollPointAccumulator.reset()
        horizontalScrollIntentFilter.reset()
        if let overridingScrollPoint {
            lastScrollPoint = overridingScrollPoint
        } else {
            captureScrollPoint(at: location)
        }
        if let point = lastScrollPoint {
            // The Apple scroll record carries coordinates, but remote WebKit
            // hit-testing still follows the server's current pointer. Sync it
            // explicitly before the gesture envelope just like a local hover.
            lastPointerPoint = point
            touchHandler.handleMove(x: point.x, y: point.y)
            touchHandler.handleGesture(
                kind: .began,
                x: point.x,
                y: point.y)
        }
        sendFilteredScrollDelta(
            deltaX: initialTranslation.x,
            deltaY: initialTranslation.y,
            scrollPhase: .began,
            momentumPhase: .none)
    }

    private func beginMomentumScrollPhaseIfNeeded() {
        guard !momentumScrollPhaseActive else { return }
        endDirectScrollPhase(.ended)
        momentumScrollPhaseActive = true
        sendScrollSample(
            pointDeltaX: 0,
            pointDeltaY: 0,
            scrollPhase: .none,
            momentumPhase: .began)
    }

    /// Derive the fling from displacement over the gesture's trailing window
    /// and generate a consistent tail on every platform instead of depending
    /// on UIKit's private scroll phase.
    @discardableResult
    private func beginSyntheticMomentumIfNeeded() -> Bool {
        guard momentumDisplayLink == nil else { return false }
        let releaseVelocity = releaseVelocityEstimator.releaseVelocity(
            at: CACurrentMediaTime())
        let speed = hypot(releaseVelocity.x, releaseVelocity.y)
        guard speed >= 25 else { return false }

        let maximumSpeed: CGFloat = 12_000
        let scale = min(1, maximumSpeed / speed)
        syntheticMomentumVelocity = CGPoint(
            x: releaseVelocity.x * scale,
            y: releaseVelocity.y * scale)
        syntheticMomentumLastTimestamp = 0
        beginMomentumScrollPhaseIfNeeded()

        let link = CADisplayLink(target: self, selector: #selector(stepSyntheticMomentum(_:)))
        link.preferredFramesPerSecond = 60
        link.add(to: .main, forMode: .common)
        momentumDisplayLink = link
        logInputRoute(
            "synthetic momentum velocity=(\(syntheticMomentumVelocity.x),"
                + "\(syntheticMomentumVelocity.y))")
        return true
    }

    @objc private func stepSyntheticMomentum(_ displayLink: CADisplayLink) {
        guard momentumDisplayLink === displayLink,
              momentumScrollPhaseActive else {
            stopSyntheticMomentum()
            return
        }

        let elapsed: CFTimeInterval
        if syntheticMomentumLastTimestamp == 0 {
            elapsed = displayLink.duration
        } else {
            elapsed = min(0.05, displayLink.timestamp - syntheticMomentumLastTimestamp)
        }
        syntheticMomentumLastTimestamp = displayLink.timestamp

        sendFilteredScrollDelta(
            deltaX: syntheticMomentumVelocity.x * elapsed,
            deltaY: syntheticMomentumVelocity.y * elapsed,
            scrollPhase: .none,
            momentumPhase: .changed)

        // UIScrollView.DecelerationRate.normal is 0.998 per millisecond.
        let decay = pow(CGFloat(0.998), CGFloat(elapsed * 1_000))
        syntheticMomentumVelocity.x *= decay
        syntheticMomentumVelocity.y *= decay
        if hypot(syntheticMomentumVelocity.x, syntheticMomentumVelocity.y) < 5 {
            endMomentumScrollPhase()
            finishScrollInteraction()
        }
    }

    private func stopSyntheticMomentum() {
        momentumDisplayLink?.invalidate()
        momentumDisplayLink = nil
        syntheticMomentumVelocity = .zero
        syntheticMomentumLastTimestamp = 0
    }

    private func endDirectScrollPhase(_ phase: AppleScrollEvent.Phase) {
        guard directScrollPhaseActive else { return }
        sendScrollSample(
            pointDeltaX: 0,
            pointDeltaY: 0,
            scrollPhase: phase,
            momentumPhase: .none)
        if let point = lastScrollPoint {
            touchHandler.handleGesture(
                kind: .ended,
                x: point.x,
                y: point.y)
        }
        directScrollPhaseActive = false
    }

    private func endMomentumScrollPhase() {
        guard momentumScrollPhaseActive else { return }
        stopSyntheticMomentum()
        sendScrollSample(
            pointDeltaX: 0,
            pointDeltaY: 0,
            scrollPhase: .none,
            momentumPhase: .ended)
        momentumScrollPhaseActive = false
    }

    /// Pointer motion is ignored while a fling runs, and a fling lasts
    /// seconds, so moving the pointer ends it instead of freezing the cursor.
    private func catchMomentumForPointerMove(to location: CGPoint) {
        defer { lastPointerViewLocation = location }
        guard momentumScrollPhaseActive else {
            momentumPointerAnchor = nil
            return
        }
        guard let anchor = momentumPointerAnchor ?? lastPointerViewLocation else {
            momentumPointerAnchor = location
            return
        }
        momentumPointerAnchor = anchor
        if hypot(location.x - anchor.x, location.y - anchor.y) > 4 {
            catchMomentumFlingIfActive()
        }
    }

    /// Stop an active synthetic fling because new input arrived, the way a
    /// native scroll view halts deceleration on contact. Returns true when a
    /// fling was actually caught.
    @discardableResult
    private func catchMomentumFlingIfActive() -> Bool {
        guard momentumScrollPhaseActive else { return false }
        endMomentumScrollPhase()
        finishScrollInteraction()
        return true
    }

    /// Trackpad tap-to-click and pencil contacts never create direct touches,
    /// so the touch recognizer's fling catch cannot see them, and their tap
    /// recognition is further delayed by double-tap disambiguation. Catch at
    /// raw touch-down instead; the click that follows still lands normally.
    /// Direct touches are left to the touch recognizer, whose catch also
    /// suppresses the accidental click.
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if touches.contains(where: { $0.type == .direct }) {
            stopEdgeScrolling()
            catchMomentumForMultiFingerLanding(touches, event: event)
        }
        if touches.contains(where: { $0.type != .direct }) {
            catchMomentumFlingIfActive()
        }
        #if !targetEnvironment(macCatalyst)
        // Catalyst never delivers secondary clicks as indirect-pointer
        // touches; they arrive as a touchless button event consumed by
        // secondaryClickInteraction instead.
        beginPhysicalButtonPress(in: touches, event: event)
        #endif
        super.touchesBegan(touches, with: event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let touch = physicalButtonPressTouch(in: touches) {
            continuePhysicalButtonPress(at: touch.location(in: self))
        }
        super.touchesMoved(touches, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if physicalButtonPressTouch(in: touches) != nil {
            releasePhysicalButtonPress()
        }
        super.touchesEnded(touches, with: event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        if physicalButtonPressTouch(in: touches) != nil {
            releasePhysicalButtonPress()
        }
        super.touchesCancelled(touches, with: event)
    }

    /// Fingers that land together never reach the one-finger recognizer's
    /// touch-down hook, so a fling they stop is caught here. As with one
    /// finger, the catching touch must not click or hold a button.
    private func catchMomentumForMultiFingerLanding(
        _ touches: Set<UITouch>,
        event: UIEvent?
    ) {
        let landed = touches.filter { $0.type == .direct }.count
        let down = event?.allTouches?.filter { $0.type == .direct }.count ?? landed
        guard landed >= 2, landed == down else { return }
        momentumCatchPending = catchMomentumFlingIfActive()
        momentumCatchTimestamp = momentumCatchPending ? CACurrentMediaTime() : 0
    }

    // MARK: Physical non-primary buttons

    private struct PhysicalButtonPress {
        let button: RemotePointerButton
        /// The indirect-pointer touch carrying the press; nil when
        /// GameController reports it instead.
        let touch: ObjectIdentifier?
        let modifierOwner: UInt64?
        /// Where the button goes up; cleanup may clear `lastPointerPoint` first.
        var lastPoint: (x: UInt16, y: UInt16)
    }

    /// The context-menu interaction and the zero-delay drag recognizer both
    /// own primary input, so other buttons are read from the raw mask: a real
    /// press, drag and release rather than a click fired on button-down.
    private func beginPhysicalButtonPress(
        in touches: Set<UITouch>,
        event: UIEvent?
    ) {
        guard physicalButtonPress == nil, !pointerDragActive,
              let event,
              let button = Self.physicalButton(for: event.buttonMask),
              let touch = touches.first(where: {
                  $0.type == .indirectPointer
              }),
              let point = framebufferPoint(
                  for: touch.location(in: self)) else { return }
        focusForHardwareKeyboard()
        beginPhysicalButtonPress(button, touch: ObjectIdentifier(touch), at: point)
    }

    private static func physicalButton(
        for mask: UIEvent.ButtonMask
    ) -> RemotePointerButton? {
        guard !mask.contains(.primary) else { return nil }
        if mask.contains(.button(3)) { return .middle }
        if mask.contains(.secondary) { return .right }
        return nil
    }

    private func beginPhysicalButtonPress(
        _ button: RemotePointerButton,
        touch: ObjectIdentifier?,
        at point: (x: UInt16, y: UInt16)
    ) {
        lastPointerPoint = point
        lastKnownFramebufferPoint = point
        touchHandler.handleMove(x: point.x, y: point.y)
        let owner = beginPointerModifiers()
        touchHandler.handleDrag(x: point.x, y: point.y, button: button)
        physicalButtonPress = PhysicalButtonPress(
            button: button,
            touch: touch,
            modifierOwner: owner,
            lastPoint: point)
    }

    private func physicalButtonPressTouch(in touches: Set<UITouch>) -> UITouch? {
        guard let id = physicalButtonPress?.touch else { return nil }
        return touches.first { ObjectIdentifier($0) == id }
    }

    /// Hover pauses while a button is down, so the press itself moves the
    /// drawn cursor and pans a zoomed desktop.
    private func continuePhysicalButtonPress(at location: CGPoint) {
        guard let button = physicalButtonPress?.button else { return }
        #if !targetEnvironment(macCatalyst)
        updateRemoteCursorImage(at: location)
        #endif
        updatePointerPanning(at: location, dragButton: button)
        guard let point = framebufferPoint(for: location) else { return }
        movePhysicalButtonPress(to: point)
    }

    private func movePhysicalButtonPress(to point: (x: UInt16, y: UInt16)) {
        guard var press = physicalButtonPress,
              press.lastPoint != point else { return }
        press.lastPoint = point
        physicalButtonPress = press
        lastPointerPoint = point
        touchHandler.handleDrag(x: point.x, y: point.y, button: press.button)
    }

    private func releasePhysicalButtonPress() {
        guard let press = physicalButtonPress else { return }
        physicalButtonPress = nil
        stopEdgeScrolling()
        touchHandler.handleDragEnd(x: press.lastPoint.x, y: press.lastPoint.y)
        endPointerModifiers(press.modifierOwner)
        #if targetEnvironment(macCatalyst)
        handOffCatalystMouseButtons()
        #endif
    }

    #if targetEnvironment(macCatalyst)
    /// The pane under the pointer, or the pane whose press is still down;
    /// only it answers GameController's buttons.
    private static weak var catalystMouseButtonOwner: RemoteInputUIView?
    /// The pane the pointer entered while another one held a press.
    private static weak var catalystMouseButtonNextOwner: RemoteInputUIView?

    /// Catalyst hands UIKit no middle-button events, so GameController
    /// reports them. The handler routes to whichever pane owns the pointer.
    private static func installCatalystMouseButtonHandlers(on mice: [GCMouse] = GCMouse.mice()) {
        for mouse in mice {
            mouse.mouseInput?.middleButton?.pressedChangedHandler = { _, _, pressed in
                Task { @MainActor in
                    RemoteInputUIView.catalystMouseButtonOwner?
                        .handleCatalystMiddleButton(pressed: pressed)
                }
            }
        }
    }

    @objc private func mouseDidConnect(_ notification: Notification) {
        guard let mouse = notification.object as? GCMouse else { return }
        Self.installCatalystMouseButtonHandlers(on: [mouse])
    }

    private func claimCatalystMouseButtons() {
        guard Self.catalystMouseButtonOwner !== self else {
            Self.catalystMouseButtonNextOwner = nil
            return
        }
        // A press stays with the pane it began in until the button comes up.
        if Self.catalystMouseButtonOwner?.physicalButtonPress != nil {
            Self.catalystMouseButtonNextOwner = self
            return
        }
        Self.catalystMouseButtonOwner = self
    }

    /// While another pane holds a press, motion over this one is that drag's,
    /// not hover here. Returns true when the event was taken.
    private func forwardHoverToCatalystPressOwner(
        _ recognizer: UIHoverGestureRecognizer
    ) -> Bool {
        guard let owner = Self.catalystMouseButtonOwner, owner !== self,
              owner.physicalButtonPress != nil else { return false }
        guard recognizer.state == .began || recognizer.state == .changed else { return true }
        claimCatalystMouseButtons()
        // Another window's coordinates mean nothing to the owner.
        guard owner.window === window else { return true }
        // Off its desktop the owner's pointer pins to the nearest visible
        // pixel, as a drag off a screen's edge does.
        let location = convert(recognizer.location(in: self), to: owner)
        guard let pinned = owner.viewport.nearestVisibleViewPoint(
            to: location,
            viewSize: owner.bounds.size,
            framebufferSize: owner.framebufferSize) else { return true }
        owner.continuePhysicalButtonPress(at: pinned)
        return true
    }

    private func handOffCatalystMouseButtons() {
        guard Self.catalystMouseButtonOwner === self,
              let next = Self.catalystMouseButtonNextOwner else { return }
        Self.catalystMouseButtonNextOwner = nil
        Self.catalystMouseButtonOwner = next
    }

    private func handleCatalystMiddleButton(pressed: Bool) {
        guard pressed else {
            if physicalButtonPress?.button == .middle {
                releasePhysicalButtonPress()
            }
            return
        }
        guard physicalButtonPress == nil, !pointerDragActive,
              window?.isKeyWindow == true,
              hoverRecognizer.state == .began || hoverRecognizer.state == .changed,
              let point = framebufferPoint(
                  for: hoverRecognizer.location(in: self)) else { return }
        catchMomentumFlingIfActive()
        focusForHardwareKeyboard()
        beginPhysicalButtonPress(.middle, touch: nil, at: point)
    }
    #endif

    private func cancelScrollInteraction() {
        endDirectScrollPhase(.cancelled)
        endMomentumScrollPhase()
        finishScrollInteraction()
    }

    private func captureScrollPoint(at location: CGPoint) {
        // For UIEvent.scroll, UIKit supplies the actual trackpad pointer
        // position at gesture begin. Direct touch supplies its committed start
        // location. Either is more reliable than the last cached hover point.
        if let point = framebufferPoint(for: location) {
            lastScrollPoint = point
        } else if let lastKnownFramebufferPoint {
            lastScrollPoint = lastKnownFramebufferPoint
        } else if let center = framebufferPoint(for: CGPoint(
            x: bounds.midX,
            y: bounds.midY)) {
            lastScrollPoint = center
        }
    }

    private func sendScrollSample(
        pointDeltaX: Int32,
        pointDeltaY: Int32,
        scrollPhase: AppleScrollEvent.Phase,
        momentumPhase: AppleScrollEvent.MomentumPhase = .none
    ) {
        guard let point = lastScrollPoint else { return }
        let coarse = wheelUnitAccumulator.consume(
            pointDeltaX: pointDeltaX,
            pointDeltaY: pointDeltaY)
        logInputRoute(
            "send scroll delta=(\(pointDeltaX),\(pointDeltaY)) "
            + "coarse=(\(coarse.x),\(coarse.y)) "
            + "phase=\(scrollPhase.rawValue) pos=(\(point.x),\(point.y))")
        touchHandler.handleScroll(
            x: point.x,
            y: point.y,
            pointDeltaX: pointDeltaX,
            pointDeltaY: pointDeltaY,
            coarseDeltaX: coarse.x,
            coarseDeltaY: coarse.y,
            scrollPhase: scrollPhase,
            momentumPhase: momentumPhase)
    }

    private func sendFilteredScrollDelta(
        deltaX: CGFloat,
        deltaY: CGFloat,
        scrollPhase: AppleScrollEvent.Phase,
        momentumPhase: AppleScrollEvent.MomentumPhase = .none
    ) {
        var filtered: CGPoint
        if activeScrollUsesDirectTouch {
            filtered = horizontalScrollIntentFilter.consume(
                deltaX: deltaX,
                deltaY: deltaY)
            if horizontalScrollIntentFilter.isHorizontallyLocked {
                // Trackpad scroll events already contain system acceleration;
                // raw finger translation does not. A modest horizontal gain
                // lets AppKit's fluid swipe tracking reach the commit distance
                // during an ordinary finger stroke instead of requiring an
                // edge-to-edge fling.
                filtered.x *= 2
            }
        } else {
            // UIKit's UIEvent.scroll stream already carries the trackpad's
            // native directional intent. Preserve it byte-for-byte instead
            // of applying touch-oriented axis correction to a working path.
            filtered = CGPoint(x: deltaX, y: deltaY)
        }
        if filtered.x == 0, filtered.y == 0, scrollPhase == .began {
            // Preserve the lifecycle boundary even while the opening motion
            // is buffered for an axis-intent decision.
            sendScrollSample(
                pointDeltaX: 0,
                pointDeltaY: 0,
                scrollPhase: .began,
                momentumPhase: momentumPhase)
            return
        }
        sendAccumulatedScrollDelta(
            filtered,
            scrollPhase: scrollPhase,
            momentumPhase: momentumPhase)
    }

    private func flushPendingScrollDelta() {
        guard activeScrollUsesDirectTouch else { return }
        sendAccumulatedScrollDelta(
            horizontalScrollIntentFilter.flush(),
            scrollPhase: .changed)
    }

    private func sendAccumulatedScrollDelta(
        _ delta: CGPoint,
        scrollPhase: AppleScrollEvent.Phase,
        momentumPhase: AppleScrollEvent.MomentumPhase = .none
    ) {
        let points = scrollPointAccumulator.consume(
            deltaX: delta.x,
            deltaY: delta.y)
        guard points.x != 0 || points.y != 0 else { return }
        sendScrollSample(
            pointDeltaX: points.x,
            pointDeltaY: points.y,
            scrollPhase: scrollPhase,
            momentumPhase: momentumPhase)
    }

    private func finishScrollInteraction() {
        guard !directScrollPhaseActive, !momentumScrollPhaseActive else { return }
        activeScrollRecognizer = nil
        lastScrollPoint = nil
        scrollPointAccumulator.reset()
        wheelUnitAccumulator.reset()
        horizontalScrollIntentFilter.reset()
        activeScrollUsesDirectTouch = false
        releaseVelocityEstimator.reset()
        previousScrollTimestamp = 0
        previousScrollTranslation = .zero
    }

    private static let directTouchTypes = [
        NSNumber(value: UITouch.TouchType.direct.rawValue)
    ]
    private static let pointerTypes = [
        NSNumber(value: UITouch.TouchType.pencil.rawValue),
        NSNumber(value: UITouch.TouchType.indirectPointer.rawValue),
    ]
    private static let allPointerTypes = directTouchTypes + pointerTypes

    private func configureRecognizers() {
        let directTouchTypes = Self.directTouchTypes
        let pointerTypes = Self.pointerTypes
        let allPointerTypes = Self.allPointerTypes

        // UIKit represents trackpad/wheel scrolling as a zero-touch pan. Keep
        // it separate from the ordinary one-finger recognizer: the delegate
        // admits only UIEvent.scroll here and only direct touches there.
        scrollRecognizer.minimumNumberOfTouches = 0
        scrollRecognizer.maximumNumberOfTouches = 1
        scrollRecognizer.allowedTouchTypes = directTouchTypes
        scrollRecognizer.allowedScrollTypesMask = .all
        scrollRecognizer.delegate = self

        directTouchRecognizer.allowedTouchTypes = directTouchTypes
        directTouchRecognizer.delegate = self

        pinchRecognizer.allowedTouchTypes = directTouchTypes
        pinchRecognizer.delegate = self

        viewportPanRecognizer.minimumNumberOfTouches = 2
        viewportPanRecognizer.maximumNumberOfTouches = 2
        viewportPanRecognizer.allowedTouchTypes = directTouchTypes
        viewportPanRecognizer.delegate = self

        // A pan waits for a movement threshold before beginning, which can
        // move off a narrow scrollbar thumb before remote button-down. Begin
        // at the exact primary-button location and keep tracking while held.
        pointerDragRecognizer.minimumPressDuration = 0
        pointerDragRecognizer.allowableMovement = .greatestFiniteMagnitude
        pointerDragRecognizer.numberOfTouchesRequired = 1
        pointerDragRecognizer.allowedTouchTypes = pointerTypes
        pointerDragRecognizer.delegate = self

        tapRecognizer.numberOfTapsRequired = 1
        tapRecognizer.allowedTouchTypes = allPointerTypes
        tapRecognizer.delegate = self

        doubleTapRecognizer.numberOfTapsRequired = 2
        doubleTapRecognizer.allowedTouchTypes = allPointerTypes
        doubleTapRecognizer.delegate = self
        tapRecognizer.require(toFail: pointerDragRecognizer)
        doubleTapRecognizer.require(toFail: pointerDragRecognizer)
        tapRecognizer.require(toFail: doubleTapRecognizer)

        rightTapRecognizer.numberOfTouchesRequired = 2
        rightTapRecognizer.allowedTouchTypes = directTouchTypes
        rightTapRecognizer.delegate = self

        // Deliberately without the double-tap dependency the direct-mode tap
        // carries. Exclusivity with DirectTouchGestureRecognizer still comes
        // for free: a touch that moves far enough to scroll or drag makes that
        // recognizer begin, which cancels this one.
        trackpadTapRecognizer.numberOfTapsRequired = 1
        trackpadTapRecognizer.numberOfTouchesRequired = 1
        trackpadTapRecognizer.allowedTouchTypes = directTouchTypes
        trackpadTapRecognizer.delegate = self

        trackpadScrollRecognizer.minimumNumberOfTouches = 2
        trackpadScrollRecognizer.maximumNumberOfTouches = 2
        trackpadScrollRecognizer.allowedTouchTypes = directTouchTypes
        trackpadScrollRecognizer.delegate = self

        middleTapRecognizer.numberOfTouchesRequired = 3
        middleTapRecognizer.allowedTouchTypes = directTouchTypes
        middleTapRecognizer.delegate = self

        // Any motion before the hold delay fails these, leaving the fingers
        // to pinch, pan, scroll or swipe.
        for hold in [twoFingerHoldRecognizer, threeFingerHoldRecognizer] {
            hold.allowedTouchTypes = directTouchTypes
            hold.delegate = self
        }

        threeFingerSwipeRecognizer.minimumNumberOfTouches = 3
        threeFingerSwipeRecognizer.maximumNumberOfTouches = 3
        threeFingerSwipeRecognizer.allowedTouchTypes = directTouchTypes
        threeFingerSwipeRecognizer.delegate = self

        hoverRecognizer.allowedTouchTypes = pointerTypes
        hoverRecognizer.delegate = self

        for recognizer in [
            scrollRecognizer,
            directTouchRecognizer,
            pinchRecognizer,
            viewportPanRecognizer,
            pointerDragRecognizer,
            tapRecognizer,
            doubleTapRecognizer,
            rightTapRecognizer,
            trackpadTapRecognizer,
            trackpadScrollRecognizer,
            middleTapRecognizer,
            twoFingerHoldRecognizer,
            threeFingerHoldRecognizer,
            threeFingerSwipeRecognizer,
            hoverRecognizer,
        ] {
            recognizer.cancelsTouchesInView = false
            addGestureRecognizer(recognizer)
        }
        updateRecognizerEnablement()
        applyTouchGestureConfiguration()
    }

    private func applyTouchGestureConfiguration() {
        let holdDuration = touchGestures.resolvedHoldDuration
        directTouchRecognizer.holdDuration = holdDuration
        twoFingerHoldRecognizer.holdDuration = holdDuration
        threeFingerHoldRecognizer.holdDuration = holdDuration
        threeFingerSwipeRecognizer.isEnabled = touchGestures.hasSwipeActions
        if !touchGestures.showsButtonIndicator {
            buttonIndicator.hide()
        }
    }

    /// One finger means a different thing in each mode, so the recognizers
    /// that read it are swapped wholesale rather than branching inside every
    /// handler. A pencil or an attached mouse is not a finger: its taps and
    /// clicks, the secondary button included, keep going to the direct-mode
    /// recognizers in both modes, so switching how the finger works changes
    /// nothing about how the mouse does.
    private func updateRecognizerEnablement() {
        let usesTrackpad = pointerMode == .trackpad
        let clickTypes = usesTrackpad ? Self.pointerTypes : Self.allPointerTypes
        tapRecognizer.allowedTouchTypes = clickTypes
        doubleTapRecognizer.allowedTouchTypes = clickTypes
        trackpadTapRecognizer.isEnabled = usesTrackpad
        trackpadScrollRecognizer.isEnabled = usesTrackpad
    }

    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        guard recognizer.state == .began || recognizer.state == .changed else { return }
        stopEdgeScrolling()
        viewport.zoom(
            by: recognizer.scale,
            around: visibleLocation(for: recognizer.location(in: self)),
            viewSize: bounds.size,
            framebufferSize: framebufferSize)
        recognizer.scale = 1
        onViewportChange?(viewport)
    }

    @objc private func handleViewportPan(_ recognizer: UIPanGestureRecognizer) {
        guard recognizer.state == .began || recognizer.state == .changed else { return }
        stopEdgeScrolling()
        let translation = recognizer.translation(in: self)
        viewport.pan(
            by: CGSize(width: translation.x, height: translation.y),
            viewSize: bounds.size,
            framebufferSize: framebufferSize)
        recognizer.setTranslation(.zero, in: self)
        onViewportChange?(viewport)
    }

    @objc private func handlePointerDrag(_ recognizer: UILongPressGestureRecognizer) {
        focusForHardwareKeyboardIfNeeded(recognizer)
        switch recognizer.state {
        case .began, .changed:
            catchMomentumFlingIfActive()
            let location = recognizer.location(in: self)
            #if !targetEnvironment(macCatalyst)
            // Hover updates pause while the trackpad button is down. Advance
            // the custom remote-cursor image from the drag stream without
            // sending a zero-button pointer event that would release the item.
            updateRemoteCursorImage(at: location)
            #endif
            // The initial pencil contact must press at the content visibly
            // under the tip: panning first would shift the continuous-mode
            // viewport and press at the post-pan coordinate. Later drag events
            // pan normally for zoomed-in edge reach.
            let isInitialPencilContact = pointerDragIsPencil && !pointerDragActive
            if !isInitialPencilContact {
                updatePointerPanning(at: location, dragButton: .left)
            }
            guard let point = framebufferPoint(for: location) else { return }
            if isInitialPencilContact {
                // Sync the server pointer before the button goes down so
                // remote UIs hit-test the landing spot, mirroring the scroll
                // path. The trackpad pointer already streams moves via
                // UIPointerInteraction.
                touchHandler.handleMove(x: point.x, y: point.y)
            }
            if pointerDragIsPencil {
                lastPencilFramebufferPoint = point
                lastPencilContactTimestamp = CACurrentMediaTime()
                Self.lastPencilContactView = self
            }
            lastPointerPoint = point
            if !pointerDragActive {
                pointerDragModifierOwner = beginPointerModifiers()
            }
            pointerDragActive = true
            touchHandler.handleDrag(x: point.x, y: point.y)
        case .ended, .cancelled, .failed:
            stopEdgeScrolling()
            releasePointerDrag()
        default:
            break
        }
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended,
              let point = framebufferPoint(
                for: recognizer.location(in: self)) else { return }
        if momentumCatchPending {
            // The touch that stopped a fling belongs to the scroll
            // interaction; catching never clicks the remote desktop.
            momentumCatchPending = false
            momentumCatchTimestamp = 0
            return
        }
        // A pointer click during a fling stops it; the click still lands,
        // matching a trackpad click on a decelerating native view.
        catchMomentumFlingIfActive()
        focusForHardwareKeyboardIfNeeded(recognizer)
        clickWithPointerModifiers {
            if recognizer.buttonMask.contains(.secondary) {
                touchHandler.handleRightClick(x: point.x, y: point.y)
            } else {
                touchHandler.handleTap(x: point.x, y: point.y)
            }
        }
    }

    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended,
              let point = framebufferPoint(
                for: recognizer.location(in: self)) else { return }
        focusForHardwareKeyboardIfNeeded(recognizer)
        if momentumCatchPending
            || (momentumCatchTimestamp > 0
                && CACurrentMediaTime() - momentumCatchTimestamp <= 0.75) {
            // The first tap of the pair caught the fling; deliver only the
            // second as an ordinary click, as a native scroll view would.
            momentumCatchPending = false
            momentumCatchTimestamp = 0
            clickWithPointerModifiers {
                touchHandler.handleTap(x: point.x, y: point.y)
            }
            return
        }
        catchMomentumFlingIfActive()
        clickWithPointerModifiers {
            touchHandler.handleDoubleTap(x: point.x, y: point.y)
        }
    }

    @objc private func handleRightTap(_ recognizer: UITapGestureRecognizer) {
        handleMultiFingerTap(recognizer, button: .right)
    }

    @objc private func handleMiddleTap(_ recognizer: UITapGestureRecognizer) {
        handleMultiFingerTap(recognizer, button: .middle)
    }

    /// Multi-finger taps click at the fingers in `.direct` and at the
    /// virtual cursor in `.trackpad`.
    private func handleMultiFingerTap(
        _ recognizer: UITapGestureRecognizer,
        button: RemotePointerButton
    ) {
        guard recognizer.state == .ended else { return }
        let usesTrackpad = pointerMode == .trackpad
        let location = usesTrackpad
            ? trackpadWirePoint()
            : framebufferPoint(for: recognizer.location(in: self))
        guard let point = location else { return }
        if catchMomentumFlingIfActive() || momentumCatchPending {
            momentumCatchPending = false
            momentumCatchTimestamp = 0
            return
        }
        if usesTrackpad {
            // No finger location produced this point, so the cached
            // framebuffer point that seeds a future cursor has to be written
            // here rather than as a side effect of converting one.
            lastPointerPoint = point
            lastKnownFramebufferPoint = point
        }
        clickWithPointerModifiers {
            touchHandler.handleClick(button, x: point.x, y: point.y)
        }
    }

    @objc private func handleDirectTouchState(
        _ recognizer: DirectTouchGestureRecognizer
    ) {
        guard let mode = recognizer.mode else { return }
        if pointerMode == .trackpad {
            handleTrackpadTouchState(mode: mode, recognizer: recognizer)
            return
        }
        switch (mode, recognizer.state) {
        case (.scroll, .began):
            if momentumScrollPhaseActive {
                endMomentumScrollPhase()
                finishScrollInteraction()
            }
            momentumCatchPending = false
            momentumCatchTimestamp = 0
            activeScrollRecognizer = recognizer
            activeScrollUsesDirectTouch = true
            let beginTimestamp = CACurrentMediaTime()
            releaseVelocityEstimator.reset()
            releaseVelocityEstimator.record(
                position: recognizer.translation,
                at: beginTimestamp)
            previousScrollTranslation = recognizer.translation
            previousScrollTimestamp = beginTimestamp
            beginScrollInteractionIfNeeded(
                at: recognizer.currentLocation,
                initialTranslation: recognizer.translation)
        case (.scroll, .changed):
            guard activeScrollRecognizer === recognizer else { return }
            let now = CACurrentMediaTime()
            let translation = recognizer.translation
            let deltaX = translation.x - previousScrollTranslation.x
            let deltaY = translation.y - previousScrollTranslation.y
            releaseVelocityEstimator.record(position: translation, at: now)
            previousScrollTranslation = translation
            previousScrollTimestamp = now
            sendFilteredScrollDelta(
                deltaX: deltaX,
                deltaY: deltaY,
                scrollPhase: .changed)
        case (.scroll, .ended):
            guard activeScrollRecognizer === recognizer else { return }
            flushPendingScrollDelta()
            endDirectScrollPhase(.ended)
            if !beginSyntheticMomentumIfNeeded() {
                finishScrollInteraction()
            }
        case (.scroll, .cancelled):
            guard activeScrollRecognizer === recognizer else { return }
            cancelScrollInteraction()
        case (.drag, .began):
            guard let point = framebufferPoint(
                for: recognizer.currentLocation) else { return }
            beginTouchHoldDrag(.left, at: point, anchor: recognizer.currentLocation)
        case (.drag, .changed):
            guard touchHoldDragActive,
                  let point = framebufferPoint(
                    for: recognizer.currentLocation) else { return }
            continueTouchHoldDrag(at: point, anchor: recognizer.currentLocation)
        case (.drag, .ended), (.drag, .cancelled):
            releaseTouchHoldDrag()
        default:
            break
        }
    }

    /// One-finger touch in `.trackpad`. The recognizer's two outcomes keep
    /// their meaning — motion versus a stationary hold — but neither reads the
    /// finger's location any more: motion nudges the cursor and the hold
    /// presses wherever the cursor already is.
    private func handleTrackpadTouchState(
        mode: DirectTouchGestureRecognizer.Mode,
        recognizer: DirectTouchGestureRecognizer
    ) {
        switch (mode, recognizer.state) {
        case (.scroll, .began):
            // The touch that caught a fling has already paid for it; from here
            // it is an ordinary cursor stroke.
            momentumCatchPending = false
            momentumCatchTimestamp = 0
            beginTrackpadStroke(from: .zero)
            recenterTrackpadCursorIfOffscreen()
            if moveTrackpadCursor(to: recognizer.translation) {
                sendTrackpadPointer(buttonHeld: false)
            }
        case (.scroll, .changed):
            if moveTrackpadCursor(to: recognizer.translation) {
                sendTrackpadPointer(buttonHeld: false)
            }
        case (.scroll, .ended), (.scroll, .cancelled):
            trackpadVelocity.reset()
        case (.drag, .began):
            recenterTrackpadCursorIfOffscreen()
            guard let point = trackpadWirePoint() else { return }
            // Movement under the slop before the hold committed was noise, not
            // intent: start the drag from where the finger rests.
            beginTrackpadStroke(from: recognizer.translation)
            lastKnownFramebufferPoint = point
            beginTouchHoldDrag(.left, at: point, anchor: trackpadCursorViewPoint())
        case (.drag, .changed):
            guard touchHoldDragActive else { return }
            if moveTrackpadCursor(to: recognizer.translation) {
                sendTrackpadPointer(buttonHeld: true)
            }
        case (.drag, .ended), (.drag, .cancelled):
            releaseTouchHoldDrag()
            trackpadVelocity.reset()
        default:
            break
        }
    }

    @objc private func handleTrackpadTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended,
              let point = trackpadWirePoint() else { return }
        if momentumCatchPending {
            // The touch that stopped a fling belongs to the scroll
            // interaction; catching never clicks the remote desktop.
            momentumCatchPending = false
            momentumCatchTimestamp = 0
            return
        }
        catchMomentumFlingIfActive()
        focusForHardwareKeyboardIfNeeded(recognizer)
        lastPointerPoint = point
        lastKnownFramebufferPoint = point
        clickWithPointerModifiers {
            touchHandler.handleTap(x: point.x, y: point.y)
        }
    }

    /// Two-finger scrolling in `.trackpad`, driving the same precise pipeline
    /// as the one-finger direct scroll it stands in for. Only the anchor
    /// differs: the samples are addressed to the virtual cursor rather than to
    /// the fingers doing the scrolling.
    @objc private func handleTrackpadScroll(_ recognizer: UIPanGestureRecognizer) {
        stopEdgeScrolling()
        switch recognizer.state {
        case .began:
            if momentumScrollPhaseActive {
                endMomentumScrollPhase()
                finishScrollInteraction()
            }
            momentumCatchPending = false
            momentumCatchTimestamp = 0
            activeScrollRecognizer = recognizer
            activeScrollUsesDirectTouch = true
            let translation = recognizer.translation(in: self)
            let now = CACurrentMediaTime()
            releaseVelocityEstimator.reset()
            releaseVelocityEstimator.record(position: translation, at: now)
            previousScrollTranslation = translation
            previousScrollTimestamp = now
            beginScrollInteractionIfNeeded(
                at: trackpadCursorViewPoint()
                    ?? CGPoint(x: bounds.midX, y: bounds.midY),
                initialTranslation: translation,
                overridingScrollPoint: trackpadWirePoint())
        case .changed:
            guard activeScrollRecognizer === recognizer else { return }
            let translation = recognizer.translation(in: self)
            let now = CACurrentMediaTime()
            let deltaX = translation.x - previousScrollTranslation.x
            let deltaY = translation.y - previousScrollTranslation.y
            releaseVelocityEstimator.record(position: translation, at: now)
            previousScrollTranslation = translation
            previousScrollTimestamp = now
            sendFilteredScrollDelta(
                deltaX: deltaX,
                deltaY: deltaY,
                scrollPhase: .changed)
        case .ended:
            guard activeScrollRecognizer === recognizer else { return }
            flushPendingScrollDelta()
            endDirectScrollPhase(.ended)
            if !beginSyntheticMomentumIfNeeded() {
                finishScrollInteraction()
            }
        case .cancelled, .failed:
            guard activeScrollRecognizer === recognizer else { return }
            cancelScrollInteraction()
        default:
            break
        }
    }

    private func trackpadBitmapScale() -> CGFloat {
        TrackpadCursorStyle.bitmapScale(cursorHeight: cursorHeight)
    }

    /// Records cursor dimensions and the display scale once per size/hotspot.
    private func logTrackpadCursorShape(_ cursor: RemoteCursor?) {
        guard let cursor else { return }
        let key = "\(cursor.width)x\(cursor.height)"
            + "@\(cursor.hotspotX),\(cursor.hotspotY)"
        guard loggedTrackpadCursorShapes.insert(key).inserted else { return }
        let bounds = cursor.shapePath.boundingBox
        #if targetEnvironment(macCatalyst)
        let displayScale = traitCollection.displayScale
        #else
        let displayScale = fallbackCursorDisplayScale
        #endif
        Self.trackpadCursorLog.info(
            "cursor shape"
            + " size=(\(cursor.width),\(cursor.height))"
            + " hotspot=(\(cursor.hotspotX),\(cursor.hotspotY))"
            + " bounds=(\(bounds.minX),\(bounds.minY),"
            + "\(bounds.width),\(bounds.height))"
            + " style=serverBitmap"
            + " cursorHeight=\(cursorHeight)"
            + " bitmapScale=\(trackpadBitmapScale())"
            + " displayScale=\(displayScale)")
    }

    private func beginTrackpadStroke(from translation: CGPoint) {
        trackpadConsumedTranslation = translation
        trackpadVelocity.reset()
    }

    /// Takes over a finger that is already down when the mode changes.
    ///
    /// The HUD can switch modes mid-stroke. `DirectTouchGestureRecognizer` has
    /// been tracking that touch since it landed and will deliver its next
    /// `.changed` with no `.began` in front of it, so without adopting the
    /// translation accumulated so far the cursor would receive the finger's
    /// entire journey since touch-down as a single jump.
    private func adoptInFlightTouchStroke() {
        guard directTouchRecognizer.mode != nil,
              directTouchRecognizer.state == .began
                || directTouchRecognizer.state == .changed else { return }
        beginTrackpadStroke(from: directTouchRecognizer.translation)
        recenterTrackpadCursorIfOffscreen()
    }

    /// Folds the recognizer's cumulative translation into the cursor and
    /// reports whether the remote pixel under it changed. Sub-pixel motion is
    /// kept by the model, so a stream of tiny deltas eventually moves the
    /// pointer instead of being rounded away one callback at a time.
    @discardableResult
    private func moveTrackpadCursor(to translation: CGPoint) -> Bool {
        guard var model = trackpadModel else { return false }
        let delta = CGPoint(
            x: translation.x - trackpadConsumedTranslation.x,
            y: translation.y - trackpadConsumedTranslation.y)
        trackpadConsumedTranslation = translation
        let velocity = trackpadVelocity.record(
            translation: delta,
            at: CACurrentMediaTime())
        let previous = model.integerPosition
        model.move(
            by: delta,
            framebufferPixelsPerPoint: viewport.framebufferPixelsPerPoint(
                viewSize: bounds.size,
                framebufferSize: framebufferSize) ?? 0,
            velocity: velocity)
        trackpadModel = model
        let current = model.integerPosition
        followTrackpadCursor()
        #if !targetEnvironment(macCatalyst)
        refreshTrackpadCursorImage()
        #endif
        return current != previous
    }

    private func sendTrackpadPointer(buttonHeld: Bool) {
        guard let point = trackpadWirePoint() else { return }
        lastPointerPoint = point
        lastKnownFramebufferPoint = point
        if buttonHeld {
            continueTouchHoldDrag(at: point, anchor: trackpadCursorViewPoint())
        } else {
            touchHandler.handleMove(x: point.x, y: point.y)
        }
    }

    /// Slides the desktop once the cursor leaves the middle of the viewport,
    /// so a zoomed-in session can be crossed without lifting the finger to
    /// pan. See ``TrackpadFollowPolicy`` for why the dead zone is that large.
    private func followTrackpadCursor() {
        guard let viewPoint = trackpadCursorViewPoint() else { return }
        let inset = TrackpadFollowPolicy.deadZoneInsetFraction
        let translation = viewport.translationToReveal(
            viewPoint: viewPoint,
            viewSize: bounds.size,
            framebufferSize: framebufferSize,
            horizontalInset: bounds.width * inset,
            verticalInset: bounds.height * inset)
        guard translation != .zero else { return }
        viewport.pan(
            by: translation,
            viewSize: bounds.size,
            framebufferSize: framebufferSize)
        onViewportChange?(viewport)
    }

    private func trackpadWirePoint() -> (x: UInt16, y: UInt16)? {
        guard let trackpadModel else { return nil }
        return TrackpadPointerWire.wirePoint(
            framebufferPoint: trackpadModel.integerPosition,
            origin: framebufferOrigin)
    }

    private func trackpadCursorViewPoint() -> CGPoint? {
        guard let trackpadModel else { return nil }
        return viewport.viewPoint(
            forFramebufferPoint: trackpadModel.position,
            viewSize: bounds.size,
            framebufferSize: framebufferSize)
    }

    private func makeTrackpadModelIfNeeded() {
        guard trackpadModel == nil else { return }
        trackpadModel = TrackpadPointerModel(
            position: trackpadSeedPosition(),
            framebufferSize: framebufferSize,
            speed: pointerSpeed)
    }

    /// Keeps the cursor's own idea of the desktop and of the user's speed
    /// preference current, both of which can change mid-session.
    private func synchronizeTrackpadModel() {
        guard var model = trackpadModel else { return }
        let hadNoDesktop = model.framebufferSize == .zero
        model.updateFramebufferSize(framebufferSize)
        model.speed = pointerSpeed
        if hadNoDesktop, model.framebufferSize != .zero {
            // Trackpad mode can be chosen before the server has reported its
            // dimensions, which pins the cursor to the corner because every
            // coordinate clamps to zero. Seed it properly now that there is a
            // desktop to seed it against.
            model.place(at: trackpadSeedPosition())
        }
        trackpadModel = model
    }

    /// Where the cursor appears the first time relative pointing takes over.
    /// Wherever this pane last put the pointer is the least surprising spot;
    /// the middle of what is on screen is the answer when nothing has been
    /// sent yet.
    private func trackpadSeedPosition() -> CGPoint {
        guard let lastKnownFramebufferPoint else {
            return visibleCenterFramebufferPosition()
        }
        return TrackpadPointerWire.framebufferPoint(
            wirePoint: lastKnownFramebufferPoint,
            origin: framebufferOrigin)
    }

    private func visibleCenterFramebufferPosition() -> CGPoint {
        if let center = viewport.framebufferPoint(
            for: visibleLocation(for: CGPoint(x: bounds.midX, y: bounds.midY)),
            viewSize: bounds.size,
            framebufferSize: framebufferSize) {
            return center
        }
        return CGPoint(
            x: framebufferSize.width / 2,
            y: framebufferSize.height / 2)
    }

    /// A pinch, or a mode switch made while zoomed elsewhere, can leave the
    /// cursor off the visible desktop, where the user has nothing to aim
    /// with. Bring it back before the stroke rather than after it.
    private func recenterTrackpadCursorIfOffscreen() {
        makeTrackpadModelIfNeeded()
        guard var model = trackpadModel else { return }
        if let viewPoint = trackpadCursorViewPoint(),
           bounds.contains(viewPoint) {
            return
        }
        model.place(at: visibleCenterFramebufferPosition())
        trackpadModel = model
    }

    private func prepareDragEngageFeedback() {
        #if !os(visionOS)
        dragEngageFeedback.prepare()
        #endif
    }

    private func fireDragEngageFeedback() {
        #if !os(visionOS)
        dragEngageFeedback.impactOccurred()
        #endif
    }

    private func positionRemotePointerForTouch(at location: CGPoint) {
        guard let point = framebufferPoint(for: location) else { return }
        lastPointerPoint = point
        touchHandler.handleMove(x: point.x, y: point.y)
    }

    /// Presses `button` for a touch hold. The pointer syncs first: trackpad
    /// mode sent no move at touch-down, and a multi-finger centroid is not
    /// where the first finger landed, so remote UIs would hit-test elsewhere.
    /// `anchor` is the view point the held-button label floats above.
    private func beginTouchHoldDrag(
        _ button: RemotePointerButton,
        at point: (x: UInt16, y: UInt16),
        anchor: CGPoint?
    ) {
        fireDragEngageFeedback()
        // Read before the press consumes a one-shot toolbar modifier.
        let modifiers = keyboardCapture.supplementalModifiers
        touchHoldDragButton = button
        touchHoldDragLastPoint = point
        touchHoldDragActive = true
        lastPointerPoint = point
        touchHandler.handleMove(x: point.x, y: point.y)
        touchHoldModifierOwner = beginPointerModifiers()
        touchHandler.handleDrag(x: point.x, y: point.y, button: button)
        guard touchGestures.showsButtonIndicator, let anchor else { return }
        if buttonIndicator.superview == nil {
            addSubview(buttonIndicator)
        }
        bringSubviewToFront(buttonIndicator)
        buttonIndicator.show(
            title: TouchButtonIndicatorText.title(for: button, modifiers: modifiers),
            near: anchor,
            in: bounds)
    }

    private func continueTouchHoldDrag(
        at point: (x: UInt16, y: UInt16),
        anchor: CGPoint?
    ) {
        touchHoldDragLastPoint = point
        lastPointerPoint = point
        touchHandler.handleDrag(x: point.x, y: point.y, button: touchHoldDragButton)
        if let anchor, buttonIndicator.isShowing {
            buttonIndicator.move(near: anchor, in: bounds)
        }
    }

    private func releaseTouchHoldDrag() {
        if touchHoldDragActive, let point = touchHoldDragLastPoint {
            touchHandler.handleDragEnd(x: point.x, y: point.y)
        }
        endPointerModifiers(touchHoldModifierOwner)
        touchHoldModifierOwner = nil
        resetTouchHoldDrag()
    }

    private func resetTouchHoldDrag() {
        touchHoldDragLastPoint = nil
        touchHoldDragActive = false
        touchHoldDragButton = .left
        buttonIndicator.hide()
    }

    /// Two- and three-finger holds. In `.direct` the fingers' centroid is the
    /// pointer; in `.trackpad` they nudge the virtual cursor as one finger
    /// does, with the button held.
    @objc private func handleMultiFingerHold(
        _ recognizer: MultiFingerHoldGestureRecognizer
    ) {
        let button: RemotePointerButton = recognizer.fingerCount == 2 ? .right : .middle
        let usesTrackpad = pointerMode == .trackpad
        switch recognizer.state {
        case .began:
            if usesTrackpad {
                recenterTrackpadCursorIfOffscreen()
                guard let point = trackpadWirePoint() else { return }
                beginTrackpadStroke(from: recognizer.translation)
                lastKnownFramebufferPoint = point
                beginTouchHoldDrag(button, at: point, anchor: trackpadCursorViewPoint())
            } else {
                guard let point = framebufferPoint(for: recognizer.centroid) else { return }
                beginTouchHoldDrag(button, at: point, anchor: recognizer.centroid)
            }
        case .changed:
            guard touchHoldDragActive, touchHoldDragButton == button else { return }
            if usesTrackpad {
                if moveTrackpadCursor(to: recognizer.translation) {
                    sendTrackpadPointer(buttonHeld: true)
                }
            } else if let point = framebufferPoint(for: recognizer.centroid) {
                continueTouchHoldDrag(at: point, anchor: recognizer.centroid)
            }
        case .ended, .cancelled:
            guard touchHoldDragActive, touchHoldDragButton == button else { return }
            releaseTouchHoldDrag()
            trackpadVelocity.reset()
        default:
            break
        }
    }

    /// Fires one remote command per three-finger stroke.
    @objc private func handleThreeFingerSwipe(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
        case .began:
            swipeTracker.reset()
            catchMomentumFlingIfActive()
            momentumCatchPending = false
            momentumCatchTimestamp = 0
            performSwipe(swipeTracker.update(translation: recognizer.translation(in: self)))
        case .changed:
            performSwipe(swipeTracker.update(translation: recognizer.translation(in: self)))
        case .ended:
            performSwipe(swipeTracker.end(
                translation: recognizer.translation(in: self),
                velocity: recognizer.velocity(in: self)))
        default:
            break
        }
    }

    private func performSwipe(_ direction: RemoteSwipeDirection?) {
        guard let direction,
              let command = touchGestures.action(for: direction).command else { return }
        fireDragEngageFeedback()
        keyboardHandler.handleRemoteCommand(command)
    }

    @objc private func handleHover(_ recognizer: UIHoverGestureRecognizer) {
        #if targetEnvironment(macCatalyst)
        if forwardHoverToCatalystPressOwner(recognizer) { return }
        if recognizer.state == .ended || recognizer.state == .cancelled {
            stopEdgeScrolling()
            NSCursor.arrow.set()
            return
        }
        if recognizer.state == .began || recognizer.state == .changed {
            applyCatalystCursor()
        }
        #else
        if recognizer.state == .ended || recognizer.state == .cancelled {
            stopEdgeScrolling()
            remoteCursorHoverLocation = nil
            remoteCursorImageView.isHidden = true
            // The pointer that outranked the virtual cursor has left the
            // glass; the virtual one is visible again.
            refreshTrackpadCursorImage()
            return
        }
        if recognizer.state == .began || recognizer.state == .changed {
            updateRemoteCursorImage(at: recognizer.location(in: self))
        }
        #endif

        if recognizer.state == .began || recognizer.state == .changed {
            catchMomentumForPointerMove(to: recognizer.location(in: self))
            #if targetEnvironment(macCatalyst)
            claimCatalystMouseButtons()
            #endif
        }

        // A held non-primary button turns pointer motion into its drag.
        if physicalButtonPress != nil {
            if recognizer.state == .began || recognizer.state == .changed {
                continuePhysicalButtonPress(at: recognizer.location(in: self))
            }
            return
        }

        if !directScrollPhaseActive,
           !momentumScrollPhaseActive,
           !pointerDragActive,
           recognizer.state == .began || recognizer.state == .changed {
            updatePointerPanning(
                at: recognizer.location(in: self),
                dragButton: nil)
        }

        guard !directScrollPhaseActive,
              !momentumScrollPhaseActive,
              !pointerDragActive,
              recognizer.state == .began || recognizer.state == .changed,
              let point = framebufferPoint(
                for: recognizer.location(in: self)) else { return }
        guard lastPointerPoint?.x != point.x
                || lastPointerPoint?.y != point.y else { return }
        lastPointerPoint = point
        logInputRoute("hover pos=(\(point.x),\(point.y))")
        focusForHardwareKeyboard()
        touchHandler.handleMove(x: point.x, y: point.y)
    }

    /// `dragButton` is the button held while the pointer moves, nil for hover.
    private func updatePointerPanning(
        at location: CGPoint,
        dragButton: RemotePointerButton?
    ) {
        switch viewportPanningMode {
        case .edge:
            updateEdgeScrolling(at: location, dragButton: dragButton)
        case .continuous:
            stopEdgeScrolling()
            let translation = viewport.cursorFollowingTranslation(
                for: location,
                viewSize: bounds.size,
                framebufferSize: framebufferSize)
            guard translation != .zero else { return }
            viewport.pan(
                by: translation,
                viewSize: bounds.size,
                framebufferSize: framebufferSize)
            onViewportChange?(viewport)
        }
    }

    private func updateEdgeScrolling(
        at location: CGPoint,
        dragButton: RemotePointerButton?
    ) {
        edgeScrollPointerLocation = location
        edgeScrollDragButton = dragButton
        let translation = viewport.edgeScrollTranslation(
            for: location,
            viewSize: bounds.size,
            framebufferSize: framebufferSize,
            elapsedTime: 1.0 / 60.0)
        guard translation != .zero else {
            stopEdgeScrolling()
            return
        }
        guard edgeScrollDisplayLink == nil else { return }
        edgeScrollLastTimestamp = 0
        let link = CADisplayLink(
            target: self,
            selector: #selector(stepEdgeScrolling(_:)))
        link.preferredFramesPerSecond = 60
        link.add(to: .main, forMode: .common)
        edgeScrollDisplayLink = link
    }

    @objc private func stepEdgeScrolling(_ displayLink: CADisplayLink) {
        guard edgeScrollDisplayLink === displayLink,
              let location = edgeScrollPointerLocation,
              window != nil else {
            stopEdgeScrolling()
            return
        }
        let elapsed: CFTimeInterval
        if edgeScrollLastTimestamp == 0 {
            elapsed = displayLink.duration
        } else {
            elapsed = min(0.05, displayLink.timestamp - edgeScrollLastTimestamp)
        }
        edgeScrollLastTimestamp = displayLink.timestamp

        let translation = viewport.edgeScrollTranslation(
            for: location,
            viewSize: bounds.size,
            framebufferSize: framebufferSize,
            elapsedTime: elapsed)
        guard translation != .zero else {
            stopEdgeScrolling()
            return
        }
        viewport.pan(
            by: translation,
            viewSize: bounds.size,
            framebufferSize: framebufferSize)
        onViewportChange?(viewport)

        guard let point = framebufferPoint(for: location),
              lastPointerPoint?.x != point.x
                || lastPointerPoint?.y != point.y else { return }
        if physicalButtonPress != nil {
            movePhysicalButtonPress(to: point)
            return
        }
        lastPointerPoint = point
        if let button = edgeScrollDragButton {
            touchHandler.handleDrag(x: point.x, y: point.y, button: button)
        } else {
            touchHandler.handleMove(x: point.x, y: point.y)
        }
    }

    private func stopEdgeScrolling() {
        edgeScrollDisplayLink?.invalidate()
        edgeScrollDisplayLink = nil
        edgeScrollPointerLocation = nil
        edgeScrollLastTimestamp = 0
        edgeScrollDragButton = nil
    }

    #if targetEnvironment(macCatalyst)
    /// One clear pixel: NSCursor has no hidden style that is scoped to a view,
    /// and `NSCursor.hide()` is global and counted.
    private static let invisibleCatalystCursor = NSCursor(
        image: UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1))
            .image { _ in },
        hotSpot: .zero)

    /// Catalyst uses the macOS cursor compositor. Feeding the remote bitmap to
    /// NSCursor preserves the server-selected resize/I-beam/hand cursor, its
    /// colors, and its hotspot; UIPointerShape is an iPad pointer-morphing API
    /// and is not reliably applied to the Mac arrow.
    private func applyCatalystCursor() {
        guard let remoteCursor else {
            // A server that paints the pointer into the picture has already
            // drawn it; the Mac's own arrow on top would be a second one.
            if serverRendersCursor {
                let dot = showsLocalCursorDot ? catalystLocalDotCursor() : nil
                (dot ?? Self.invisibleCatalystCursor).set()
            } else {
                NSCursor.arrow.set()
            }
            return
        }

        // Cursor size is a local accessibility/display preference. Remote
        // framebuffer zoom and Retina scaling must not shrink or enlarge it.
        // AppleVNCServer's cursor dimensions are already expressed in local
        // points, not Retina backing pixels.
        let displayScale: CGFloat = 1
        if catalystCursor == nil
            || abs(catalystCursorDisplayScale - displayScale) > 0.001 {
            let image = UIImage(
                cgImage: remoteCursor.image,
                scale: displayScale,
                orientation: .up)
            catalystCursor = NSCursor(
                image: image,
                hotSpot: CGPoint(
                    x: CGFloat(remoteCursor.hotspotX) / displayScale,
                    y: CGFloat(remoteCursor.hotspotY) / displayScale))
            catalystCursorDisplayScale = displayScale
        }
        catalystCursor?.set()
    }

    private func catalystLocalDotCursor() -> NSCursor? {
        let diameter = TrackpadCursorStyle.localDotDiameter(cursorHeight: cursorHeight)
        let displayScale = fallbackCursorDisplayScale
        if let cached = catalystDotCursor,
           cached.diameter == diameter, cached.displayScale == displayScale {
            return cached.cursor
        }
        guard let dot = Self.renderFallbackCursorImage(
            .dot, height: diameter, displayScale: displayScale)
        else { return nil }
        let cursor = NSCursor(image: dot.image, hotSpot: dot.hotspot)
        catalystDotCursor = (diameter, displayScale, cursor)
        return cursor
    }
    #endif

    #if !targetEnvironment(macCatalyst)
    private func hideRemoteCursorImage() {
        remoteCursorImageView.isHidden = true
        remoteCursorImageView.image = nil
    }

    private func drawRemoteCursorImage(
        _ image: UIImage,
        hotspot: CGPoint,
        size: CGSize,
        at location: CGPoint
    ) {
        remoteCursorImageView.image = image
        remoteCursorImageView.frame = CGRect(
            x: location.x - hotspot.x,
            y: location.y - hotspot.y,
            width: size.width,
            height: size.height)
        remoteCursorImageView.isHidden = false
        bringSubviewToFront(remoteCursorImageView)
    }

    private var hoverIsActive: Bool {
        hoverRecognizer.state == .began || hoverRecognizer.state == .changed
    }

    /// Draw the server-selected bitmap at the locally delivered hover point.
    /// This remains as responsive as UIKit's pointer because it does not wait
    /// for the remote cursor-position echo; only shape changes cross the wire.
    /// `allowingFallback` belongs to the virtual cursor alone. A real pointer
    /// on the glass already draws itself, so adding a local arrow under it
    /// would show two pointers where the server described none.
    private func updateRemoteCursorImage(
        at location: CGPoint?,
        allowingFallback: Bool = false
    ) {
        remoteCursorHoverLocation = location
        if !allowingFallback {
            // Hover and pointer drags paint over the same image view, so
            // the virtual cursor's record of what is on screen is stale
            // the moment one of them draws.
            trackpadCursorPresentation = nil
        }
        guard let location else {
            hideRemoteCursorImage()
            return
        }
        let style = TrackpadCursorStyle.resolve(
            hasServerCursor: remoteCursor != nil,
            presence: remoteCursorPresence,
            allowingFallback: allowingFallback,
            serverRendersCursor: serverRendersCursor,
            showsLocalDot: showsLocalCursorDot)
        guard style != .hidden else {
            hideRemoteCursorImage()
            return
        }
        if style == .localDot {
            guard let dot = fallbackCursorImage(
                .dot, height: TrackpadCursorStyle.localDotDiameter(cursorHeight: cursorHeight))
            else {
                hideRemoteCursorImage()
                return
            }
            drawRemoteCursorImage(
                dot.image, hotspot: dot.hotspot, size: dot.image.size, at: location)
            return
        }
        if let remoteCursor {
            if allowingFallback {
                drawTrackpadCursor(remoteCursor, at: location)
                return
            }
            drawRemoteCursorImage(
                UIImage(cgImage: remoteCursor.image, scale: 1, orientation: .up),
                hotspot: CGPoint(
                    x: CGFloat(remoteCursor.hotspotX),
                    y: CGFloat(remoteCursor.hotspotY)),
                size: CGSize(
                    width: CGFloat(remoteCursor.width),
                    height: CGFloat(remoteCursor.height)),
                at: location)
            return
        }
        // A pointer nobody has described yet leaves relative pointing with
        // nothing on screen to aim, and unlike direct touch there is no finger
        // standing in for it. A pointer the server explicitly hid is the
        // opposite: the desktop wants no pointer and drawing one would lie.
        guard style == .fallbackArrow,
              let fallback = fallbackCursorImage(.arrow, height: cursorHeight)
        else {
            hideRemoteCursorImage()
            return
        }
        drawRemoteCursorImage(
            fallback.image,
            hotspot: fallback.hotspot,
            size: fallback.image.size,
            at: location)
    }

    /// All remote shapes retain the server's pixels and share one scale, so
    /// their relative sizes and hotspot positions survive shape changes.
    private func drawTrackpadCursor(_ cursor: RemoteCursor, at location: CGPoint) {
        let scale = trackpadBitmapScale()
        drawRemoteCursorImage(
            UIImage(cgImage: cursor.image, scale: 1, orientation: .up),
            hotspot: CGPoint(
                x: CGFloat(cursor.hotspotX) * scale,
                y: CGFloat(cursor.hotspotY) * scale),
            size: CGSize(
                width: CGFloat(cursor.width) * scale,
                height: CGFloat(cursor.height) * scale),
            at: location)
    }

    /// Redraws the virtual cursor wherever the viewport now places it. A real
    /// pointer on the glass outranks it: hover carries its own position and
    /// that is the one the user is following.
    private func refreshTrackpadCursorImage() {
        guard pointerMode == .trackpad, !hoverIsActive else { return }
        // When the server draws the pointer into the framebuffer there is
        // nothing left for this view to draw. Letting the picture carry it
        // costs a frame of latency, and buys a cursor that is exactly macOS's
        // own — every context shape, at the right size for the content,
        // scaling with the desktop as it zooms instead of floating above it at
        // a fixed size. A local overlay on top of it would simply be a second
        // pointer chasing the first. The opt-in dot is the exception: it
        // marks where input lands before the video shows it.
        guard !serverRendersCursor || showsLocalCursorDot else {
            if remoteCursorHoverLocation != nil
                || !remoteCursorImageView.isHidden {
                trackpadCursorPresentation = nil
                updateRemoteCursorImage(at: nil)
            }
            return
        }
        let location = trackpadCursorViewPoint()
        let presentation = TrackpadCursorPresentation(
            location: location,
            pointerMode: pointerMode,
            shapeRevision: remoteCursorShapeRevision,
            presence: remoteCursorPresence,
            localDot: serverRendersCursor && showsLocalCursorDot,
            height: cursorHeight,
            displayScale: fallbackCursorDisplayScale,
            hotspot: remoteCursor.map {
                CGPoint(x: CGFloat($0.hotspotX), y: CGFloat($0.hotspotY))
            } ?? .zero)
        // Every component is something that changes what lands on screen, so
        // comparing the whole record is what keeps a shape swap from being
        // mistaken for "nothing moved" and skipped.
        guard presentation != trackpadCursorPresentation
                || remoteCursorImageView.isHidden else { return }
        trackpadCursorPresentation = presentation
        updateRemoteCursorImage(at: location, allowingFallback: true)
    }

    /// Everything that decides what the virtual cursor looks like and where it
    /// sits. Any difference is a redraw.
    private struct TrackpadCursorPresentation: Equatable {
        var location: CGPoint?
        var pointerMode: RemotePointerMode
        var shapeRevision: UInt64
        /// A server hiding its pointer sends no shape, so the revision does
        /// not move; without the presence here the hide would be skipped as
        /// "nothing changed" and the fallback arrow would stay on screen.
        var presence: RemoteCursorPresence
        var localDot: Bool
        var height: CGFloat
        var displayScale: CGFloat
        var hotspot: CGPoint
    }
    #endif

    /// Rasterisation scale for the original fallback. Before the view reaches a
    /// window its trait collection reports no scale, and the renderer's own
    /// preferred format is the same main-screen value UIKit would pick.
    private var fallbackCursorDisplayScale: CGFloat {
        let scale = traitCollection.displayScale
        return scale > 0 ? scale : UIGraphicsImageRendererFormat.preferred().scale
    }

    /// A rendered cursor and the point inside it the pointer aims with. The
    /// hotspot is not the image corner: the canvas holds the white outline and
    /// the drop shadow around the shape, so the arrow's tip sits well inside.
    private struct FallbackCursorImage {
        var image: UIImage
        var hotspot: CGPoint
    }

    #if !targetEnvironment(macCatalyst)
    private struct FallbackCursorKey: Hashable {
        var shape: TrackpadCursorArtwork.Shape
        var height: CGFloat
        var displayScale: CGFloat
    }

    /// Heights are quantized to this many points before rendering, so a
    /// continuous change reuses images instead of rasterizing one per frame.
    private static let fallbackCursorHeightStep: CGFloat = 0.5
    /// Bound memory while the user adjusts the cursor size preference.
    private static let fallbackCursorCacheLimit = 96

    private func fallbackCursorImage(
        _ shape: TrackpadCursorArtwork.Shape,
        height: CGFloat
    ) -> FallbackCursorImage? {
        let step = Self.fallbackCursorHeightStep
        let quantized = max(step, (height / step).rounded() * step)
        let scale = fallbackCursorDisplayScale
        let key = FallbackCursorKey(
            shape: shape, height: quantized, displayScale: scale)
        if let cached = fallbackCursorImages[key] { return cached }
        if fallbackCursorImages.count >= Self.fallbackCursorCacheLimit {
            fallbackCursorImages.removeAll(keepingCapacity: true)
        }
        let rendered = Self.renderFallbackCursorImage(
            shape, height: quantized, displayScale: scale)
        fallbackCursorImages[key] = rendered
        return rendered
    }
    #endif

    /// Rasterises our vector fallback at the destination display density.
    private static func renderFallbackCursorImage(
        _ shape: TrackpadCursorArtwork.Shape,
        height: CGFloat,
        displayScale: CGFloat
    ) -> FallbackCursorImage? {
        let scale = height / shape.visibleHeight
        let canvas = CGSize(
            width: shape.canvasSize.width * scale,
            height: shape.canvasSize.height * scale)
        guard let source = TrackpadCursorArtwork.image(
            for: shape, pixelHeight: canvas.height * displayScale)
        else { return nil }
        return FallbackCursorImage(
            image: UIImage(cgImage: source, scale: displayScale, orientation: .up),
            hotspot: CGPoint(
                x: shape.hotspot.x * scale,
                y: shape.hotspot.y * scale))
    }

    func pointerInteraction(
        _ interaction: UIPointerInteraction,
        regionFor request: UIPointerRegionRequest,
        defaultRegion: UIPointerRegion
    ) -> UIPointerRegion? {
        catchMomentumForPointerMove(to: request.location)
        guard !directScrollPhaseActive,
              !momentumScrollPhaseActive,
              !pointerDragActive,
              physicalButtonPress == nil,
              scrollRecognizer.state != .began,
              scrollRecognizer.state != .changed,
              let point = framebufferPoint(for: request.location) else {
            return defaultRegion
        }
        if lastPointerPoint?.x != point.x || lastPointerPoint?.y != point.y {
            lastPointerPoint = point
            logInputRoute("pointer interaction pos=(\(point.x),\(point.y))")
            focusForHardwareKeyboard()
            touchHandler.handleMove(x: point.x, y: point.y)
        }
        return defaultRegion
    }

    /// iPad has no public bitmap-backed UIPointerShape. Hide its synthetic
    /// pointer while the local image overlay above displays the exact remote
    /// cursor, and whenever the server paints the pointer into the picture,
    /// which would otherwise show two of them; nil retains the ordinary
    /// system pointer. The local dot is a system shape, so it moves with no
    /// more lag than the pointer itself.
    func pointerInteraction(
        _ interaction: UIPointerInteraction,
        styleFor region: UIPointerRegion
    ) -> UIPointerStyle? {
        if serverRendersCursor {
            guard showsLocalCursorDot else { return .hidden() }
            let diameter = TrackpadCursorStyle.localDotDiameter(cursorHeight: cursorHeight)
            // Path coordinates put the pointer location at the origin.
            let dot = UIBezierPath(ovalIn: CGRect(
                x: -diameter / 2, y: -diameter / 2, width: diameter, height: diameter))
            return UIPointerStyle(shape: .path(dot), constrainedAxes: [])
        }
        return remoteCursor == nil ? nil : .hidden()
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldReceive event: UIEvent
    ) -> Bool {
        switch event.type {
        case .scroll:
            let accepted = gestureRecognizer === scrollRecognizer
            if accepted {
                logInputRoute("received UIEvent.scroll")
                // Trackpad contact surfaces here before the pan recognizer
                // has any movement to begin with (the scroll stream's
                // may-begin phase). Fingers returning to the trackpad must
                // catch an active fling exactly like a finger on glass; the
                // synthetic tail emits no UIEvents, so any scroll event
                // during momentum is real user contact.
                catchMomentumFlingIfActive()
            }
            return accepted
        case .hover:
            return gestureRecognizer === hoverRecognizer
        default:
            if gestureRecognizer === scrollRecognizer {
                return false
            }
            if gestureRecognizer === pointerDragRecognizer {
                if !event.buttonMask.isEmpty,
                   !event.buttonMask.contains(.primary) {
                    // Reject before recognition so a secondary click is not
                    // consumed by the zero-delay primary drag recognizer.
                    return false
                }
                pointerDragIsPencil = event.allTouches?.contains {
                    $0.type == .pencil
                } == true
            }
            #if !targetEnvironment(macCatalyst)
            // A non-primary press is tracked from raw touches; a tap
            // recognizer analysing it would only delay its release.
            if gestureRecognizer === tapRecognizer || gestureRecognizer === doubleTapRecognizer,
               Self.physicalButton(for: event.buttonMask) != nil {
                return false
            }
            #endif
            return true
        }
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === pointerDragRecognizer,
           !gestureRecognizer.buttonMask.isEmpty {
            return gestureRecognizer.buttonMask.contains(.primary)
        }
        // Two fingers scroll in trackpad mode, so they cannot also drag the
        // viewport; the cursor pulls the desktop along instead.
        if gestureRecognizer === viewportPanRecognizer,
           pointerMode == .trackpad {
            return false
        }
        // Fingers that stopped a fling never hold a button. Failing here,
        // before recognition, leaves them free to scroll or pan on.
        if gestureRecognizer === twoFingerHoldRecognizer
            || gestureRecognizer === threeFingerHoldRecognizer,
           momentumCatchPending {
            return false
        }
        // A third finger belongs to the middle-button and swipe gestures.
        if gestureRecognizer === pinchRecognizer
            || gestureRecognizer === viewportPanRecognizer
            || gestureRecognizer === trackpadScrollRecognizer,
           gestureRecognizer.numberOfTouches > 2 {
            return false
        }
        #if targetEnvironment(macCatalyst)
        // The context-menu interaction also recognizes a held primary button,
        // which would cancel an in-flight remote drag (e.g. a Finder drag)
        // before it moves. Primary input belongs exclusively to
        // pointerDragRecognizer; the interaction's recognizers may begin only
        // for the touchless secondary-click event.
        if !isOwnRecognizer(gestureRecognizer),
           pointerDragActive || gestureRecognizer.buttonMask.contains(.primary) {
            return false
        }
        #endif
        return true
    }

    private func isOwnRecognizer(_ recognizer: UIGestureRecognizer) -> Bool {
        recognizer === scrollRecognizer
            || recognizer === directTouchRecognizer
            || recognizer === pinchRecognizer
            || recognizer === viewportPanRecognizer
            || recognizer === pointerDragRecognizer
            || recognizer === tapRecognizer
            || recognizer === doubleTapRecognizer
            || recognizer === rightTapRecognizer
            || recognizer === trackpadTapRecognizer
            || recognizer === trackpadScrollRecognizer
            || recognizer === middleTapRecognizer
            || recognizer === twoFingerHoldRecognizer
            || recognizer === threeFingerHoldRecognizer
            || recognizer === threeFingerSwipeRecognizer
            || recognizer === hoverRecognizer
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        let pair = Set([ObjectIdentifier(gestureRecognizer), ObjectIdentifier(otherGestureRecognizer)])
        return pair == Set([
            ObjectIdentifier(pinchRecognizer),
            ObjectIdentifier(viewportPanRecognizer),
        ])
    }

    private func framebufferPoint(for location: CGPoint) -> (x: UInt16, y: UInt16)? {
        guard let point = viewport.framebufferPoint(
            for: visibleLocation(for: location),
            viewSize: bounds.size,
            framebufferSize: framebufferSize) else { return nil }
        let result = (
            UInt16(min(
                CGFloat(UInt16.max),
                max(0, point.x + framebufferOrigin.x))),
            UInt16(min(
                CGFloat(UInt16.max),
                max(0, point.y + framebufferOrigin.y))))
        lastKnownFramebufferPoint = result
        return result
    }

    private func visibleLocation(for contentLocation: CGPoint) -> CGPoint {
        contentLocation
    }

    private func logInputRoute(_ message: String) {
        #if DEBUG
        guard VNCDiagnostics.isEnabled("ROOTSHELL_VNC_TRACE_INPUT"),
              inputLogBudget > 0 else { return }
        inputLogBudget -= 1
        inputLog.info(message)
        #endif
    }

    private func focusForHardwareKeyboardIfNeeded(_ recognizer: UIGestureRecognizer) {
        if !recognizer.buttonMask.isEmpty {
            focusForHardwareKeyboard()
        }
    }

    private func focusForHardwareKeyboard() {
        if keyboardCapture.automaticallyCapturesOnInteraction {
            keyboardCapture.capture()
        }
        guard !isFirstResponder else { return }
        softwareKeyboardRequested = false
        becomeFirstResponder()
    }

    private func dismissKeyboard() {
        softwareKeyboardRequested = false
        reloadInputViews()
        onKeyboardActiveChange?(false)
    }

    @objc private func softwareKeyboardWillHide() {
        guard softwareKeyboardRequested else { return }
        softwareKeyboardRequested = false
        onKeyboardActiveChange?(false)
    }

    @objc private func softwareKeyboardDidHide() {
        guard softwareKeyboardRequested else { return }
        softwareKeyboardRequested = false
        onKeyboardActiveChange?(false)
    }
}

/// Resolves a one-finger direct touch exactly once. Motion wins immediately
/// and becomes a scroll; a stationary hold becomes a remote mouse drag. Using
/// one recognizer avoids the timing races that occur when a pan and long press
/// compete for the same touch sequence.
@MainActor
final class DirectTouchGestureRecognizer: UIGestureRecognizer {
    enum Mode {
        case scroll
        case drag
    }

    private(set) var mode: Mode?
    private(set) var currentLocation = CGPoint(x: 0, y: 0)
    private(set) var translation = CGPoint(x: 0, y: 0)
    /// Called at touch-down with the touch location. Returning true marks the
    /// touch as captured by an active scroll fling: hold-to-drag is skipped so
    /// the catching finger can only rest or continue scrolling.
    var onTouchDown: ((CGPoint) -> Bool)?

    private let movementSlop: CGFloat = 6
    var holdDuration = RemoteTouchGestureConfiguration.defaultHoldDuration
    private var trackedTouch: UITouch?
    private var startLocation = CGPoint(x: 0, y: 0)
    private var holdTimer: Timer?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        guard state == .possible,
              trackedTouch == nil,
              touches.count == 1,
              event.allTouches?.count == 1,
              let touch = touches.first else {
            rejectGesture()
            return
        }

        trackedTouch = touch
        currentLocation = touch.location(in: view)
        startLocation = currentLocation
        translation = CGPoint(x: 0, y: 0)
        let capturedByFling = onTouchDown?(currentLocation) ?? false
        if !capturedByFling {
            scheduleHoldTimer()
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        guard let trackedTouch, touches.contains(trackedTouch) else { return }
        updateMetrics(for: trackedTouch)

        if mode == nil {
            guard hypot(translation.x, translation.y) >= movementSlop else { return }
            invalidateHoldTimer()
            mode = .scroll
            state = .began
        } else {
            state = .changed
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        guard let trackedTouch, touches.contains(trackedTouch) else { return }
        updateMetrics(for: trackedTouch)
        invalidateHoldTimer()
        state = mode == nil ? .failed : .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        invalidateHoldTimer()
        state = mode == nil ? .failed : .cancelled
    }

    override func reset() {
        super.reset()
        invalidateHoldTimer()
        mode = nil
        trackedTouch = nil
        currentLocation = CGPoint(x: 0, y: 0)
        startLocation = CGPoint(x: 0, y: 0)
        translation = CGPoint(x: 0, y: 0)
    }

    private func scheduleHoldTimer() {
        invalidateHoldTimer()
        let timer = Timer(
            timeInterval: holdDuration,
            target: self,
            selector: #selector(commitHold),
            userInfo: nil,
            repeats: false)
        RunLoop.main.add(timer, forMode: .common)
        holdTimer = timer
    }

    private func invalidateHoldTimer() {
        holdTimer?.invalidate()
        holdTimer = nil
    }

    private func updateMetrics(for touch: UITouch) {
        let location = touch.location(in: view)
        currentLocation = location
        translation = CGPoint(
            x: location.x - startLocation.x,
            y: location.y - startLocation.y)
    }

    private func rejectGesture() {
        invalidateHoldTimer()
        switch state {
        case .possible:
            state = .failed
        case .began, .changed:
            state = .cancelled
        default:
            break
        }
    }

    @objc private func commitHold() {
        holdTimer = nil
        guard state == .possible, trackedTouch != nil else { return }
        mode = .drag
        state = .began
    }
}

/// Several fingers that land together and stay still for `holdDuration`
/// hold a remote button. Motion before then fails the gesture so pinch, pan,
/// scroll and swipes keep their fingers; lifting first leaves a tap.
@MainActor
final class MultiFingerHoldGestureRecognizer: UIGestureRecognizer {
    let fingerCount: Int
    var holdDuration = RemoteTouchGestureConfiguration.defaultHoldDuration
    /// Mean location of the held fingers.
    private(set) var centroid = CGPoint(x: 0, y: 0)
    /// Centroid motion since all the fingers were down.
    private(set) var translation = CGPoint(x: 0, y: 0)

    private let movementSlop: CGFloat = 10
    /// Fingers further apart in time than this are separate gestures, so a
    /// one-finger drag never turns into a two-finger one.
    private let landingWindow: TimeInterval = 0.25
    private var trackedTouches: [UITouch] = []
    private var startLocations: [ObjectIdentifier: CGPoint] = [:]
    private var startCentroid = CGPoint(x: 0, y: 0)
    private var firstLandingTimestamp: TimeInterval = 0
    private var holdTimer: Timer?

    init(fingerCount: Int, target: Any?, action: Selector?) {
        self.fingerCount = fingerCount
        super.init(target: target, action: action)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        guard state == .possible else {
            // A finger added mid-drag does not change the press.
            for touch in touches { ignore(touch, for: event) }
            return
        }
        if trackedTouches.isEmpty {
            firstLandingTimestamp = event.timestamp
        }
        trackedTouches.append(contentsOf: touches)
        guard trackedTouches.count <= fingerCount,
              event.timestamp - firstLandingTimestamp <= landingWindow else {
            failGesture()
            return
        }
        guard trackedTouches.count == fingerCount else { return }
        for touch in trackedTouches {
            startLocations[ObjectIdentifier(touch)] = touch.location(in: view)
        }
        startCentroid = currentCentroid()
        centroid = startCentroid
        translation = CGPoint(x: 0, y: 0)
        scheduleHoldTimer()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        guard trackedTouches.count == fingerCount else { return }
        centroid = currentCentroid()
        translation = CGPoint(
            x: centroid.x - startCentroid.x,
            y: centroid.y - startCentroid.y)
        switch state {
        case .possible:
            if trackedTouches.contains(where: movedPastSlop) {
                failGesture()
            }
        case .began, .changed:
            state = .changed
        default:
            break
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        guard touches.contains(where: isTracked) else { return }
        switch state {
        case .possible:
            failGesture()
        case .began, .changed:
            // Lifting any finger ends the press; the centroid would jump.
            state = .ended
        default:
            break
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        switch state {
        case .possible:
            failGesture()
        case .began, .changed:
            state = .cancelled
        default:
            break
        }
    }

    override func reset() {
        super.reset()
        invalidateHoldTimer()
        trackedTouches.removeAll()
        startLocations.removeAll()
        startCentroid = CGPoint(x: 0, y: 0)
        centroid = CGPoint(x: 0, y: 0)
        translation = CGPoint(x: 0, y: 0)
        firstLandingTimestamp = 0
    }

    private func isTracked(_ touch: UITouch) -> Bool {
        trackedTouches.contains { $0 === touch }
    }

    private func movedPastSlop(_ touch: UITouch) -> Bool {
        guard let start = startLocations[ObjectIdentifier(touch)] else { return false }
        let location = touch.location(in: view)
        return hypot(location.x - start.x, location.y - start.y) >= movementSlop
    }

    private func currentCentroid() -> CGPoint {
        guard !trackedTouches.isEmpty else { return CGPoint(x: 0, y: 0) }
        var sum = CGPoint(x: 0, y: 0)
        for touch in trackedTouches {
            let location = touch.location(in: view)
            sum.x += location.x
            sum.y += location.y
        }
        let count = CGFloat(trackedTouches.count)
        return CGPoint(x: sum.x / count, y: sum.y / count)
    }

    private func failGesture() {
        invalidateHoldTimer()
        if state == .possible {
            state = .failed
        }
    }

    private func scheduleHoldTimer() {
        invalidateHoldTimer()
        let timer = Timer(
            timeInterval: holdDuration,
            target: self,
            selector: #selector(commitHold),
            userInfo: nil,
            repeats: false)
        RunLoop.main.add(timer, forMode: .common)
        holdTimer = timer
    }

    private func invalidateHoldTimer() {
        holdTimer?.invalidate()
        holdTimer = nil
    }

    @objc private func commitHold() {
        holdTimer = nil
        guard state == .possible, trackedTouches.count == fingerCount else { return }
        state = .began
    }
}

#if targetEnvironment(macCatalyst)
extension RemoteInputUIView: UIContextMenuInteractionDelegate {
    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let point = framebufferPoint(for: location) else { return nil }
        catchMomentumFlingIfActive()
        focusForHardwareKeyboard()
        clickWithPointerModifiers {
            touchHandler.handleRightClick(x: point.x, y: point.y)
        }
        // The remote desktop owns the contextual action; suppress a local menu.
        return nil
    }
}
#endif

#if !targetEnvironment(macCatalyst) && !os(visionOS)
extension RemoteInputUIView: UIPencilInteractionDelegate {
    private static let pencilBarrelTapRecency: CFTimeInterval = 5

    func pencilInteraction(
        _ interaction: UIPencilInteraction,
        didReceiveTap tap: UIPencilInteraction.Tap
    ) {
        guard UIPencilInteraction.preferredTapAction != .ignore,
              !pointerDragActive else { return }
        if let hoverLocation = tap.hoverPose?.location {
            // Hover-capable hardware reports the pencil's position in this
            // view's coordinates; outside our bounds means another pane owns
            // the tap.
            guard bounds.contains(hoverLocation),
                  let point = framebufferPoint(for: hoverLocation) else { return }
            clickWithPointerModifiers {
                touchHandler.handleRightClick(x: point.x, y: point.y)
            }
            return
        }
        // No hover data: only the most recently pencil-touched view responds,
        // at the pencil's own last position, and only near the touch in time.
        guard Self.lastPencilContactView === self,
              CACurrentMediaTime() - lastPencilContactTimestamp <= Self.pencilBarrelTapRecency,
              let point = lastPencilFramebufferPoint else { return }
        clickWithPointerModifiers {
            touchHandler.handleRightClick(x: point.x, y: point.y)
        }
    }
}
#endif
#endif
