//
//  HUDMenu.swift
//  rootshellVNC
//
//  The HUD's controls menu, shared by RFB sessions and other remote screens
//  so both read alike.
//

import SwiftUI

/// Host items for the HUD menu, each placed with the built-in items it
/// belongs beside. Captured once, so items with live state observe their own
/// models.
@MainActor
public struct VNCHUDMenuExtras {
    let actions: AnyView
    let display: AnyView
    let keyboard: AnyView
    let session: AnyView

    /// - Parameters:
    ///   - actions: Beside the session's own actions, such as its clipboard.
    ///   - display: Inside Display.
    ///   - keyboard: Inside Keyboard.
    ///   - session: Above Close Connection.
    public init<Actions: View, Display: View, Keyboard: View, Session: View>(
        @ViewBuilder actions: () -> Actions = { EmptyView() },
        @ViewBuilder display: () -> Display = { EmptyView() },
        @ViewBuilder keyboard: () -> Keyboard = { EmptyView() },
        @ViewBuilder session: () -> Session = { EmptyView() }
    ) {
        self.actions = AnyView(actions())
        self.display = AnyView(display())
        self.keyboard = AnyView(keyboard())
        self.session = AnyView(session())
    }
}

extension RemoteViewportPanningMode {
    var menuTitle: String {
        switch self {
        case .edge: String(localized: "When Pointer Reaches Edge", bundle: .module)
        case .continuous: String(localized: "Continuously with Pointer", bundle: .module)
        }
    }

    var menuImage: String {
        switch self {
        case .edge: "arrow.right.to.line"
        case .continuous: "arrow.up.and.down.and.arrow.left.and.right"
        }
    }
}

extension RemotePointerMode {
    var menuTitle: String {
        switch self {
        case .direct: String(localized: "Touch", bundle: .module)
        case .trackpad: String(localized: "Trackpad", bundle: .module)
        }
    }

    var menuImage: String {
        switch self {
        case .direct: "hand.point.up.left"
        case .trackpad: "rectangle.and.hand.point.up.left"
        }
    }
}

/// A submenu whose row names the current choice.
struct HUDPanningPicker: View {
    @Binding var selection: RemoteViewportPanningMode

    var body: some View {
        Picker(selection: $selection) {
            ForEach(RemoteViewportPanningMode.allCases, id: \.self) { mode in
                Label(mode.menuTitle, systemImage: mode.menuImage).tag(mode)
            }
        } label: {
            Label(String(localized: "Screen Panning", bundle: .module), systemImage: "cursorarrow.motionlines")
        }
        .pickerStyle(.menu)
    }
}

struct HUDPointerPicker: View {
    @Binding var selection: RemotePointerMode

    var body: some View {
        Picker(selection: $selection) {
            ForEach(RemotePointerMode.allCases, id: \.self) { mode in
                Label(mode.menuTitle, systemImage: mode.menuImage).tag(mode)
            }
        } label: {
            Label(String(localized: "Pointer", bundle: .module), systemImage: "cursorarrow.rays")
        }
        .pickerStyle(.menu)
    }
}

struct HUDFitScreenButton: View {
    @Binding var viewport: RemoteViewportState

    var body: some View {
        Button {
            viewport.reset()
        } label: {
            Label(
                String(localized: "Fit Screen", bundle: .module),
                systemImage: "arrow.up.left.and.down.right.magnifyingglass")
        }
        .disabled(viewport.isIdentity)
    }
}

struct HUDFullScreenButton: View {
    let isFullScreen: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            Label(
                isFullScreen
                    ? String(localized: "Exit Full Screen", bundle: .module)
                    : String(localized: "Enter Full Screen", bundle: .module),
                systemImage: isFullScreen
                    ? "arrow.down.right.and.arrow.up.left"
                    : "arrow.up.left.and.arrow.down.right")
        }
    }
}

struct HUDCloseConnectionButton: View {
    let disconnect: () -> Void

    var body: some View {
        Button(role: .destructive, action: disconnect) {
            Label(String(localized: "Close Connection", bundle: .module), systemImage: "xmark.circle")
        }
    }
}

#if canImport(UIKit)
/// Sections run from what a session reaches for most to what it rarely
/// needs: actions, view, setup, then closing.
struct HUDMenu<SessionActions: View, SessionDisplay: View>: View {
    let keyboardCapture: VNCKeyboardCapture
    let keyboardHandler: KeyboardInputHandler
    @Binding var keyboardActive: Bool
    let hardwareKeyboardAttached: Bool
    /// The HUD bar already carries a keyboard button.
    let hostProvidesKeyboardButton: Bool
    @Binding var viewport: RemoteViewportState
    @Binding var viewportPanningMode: RemoteViewportPanningMode
    @Binding var pointerMode: RemotePointerMode
    let isFullScreen: Bool
    let toggleFullScreen: (() -> Void)?
    let extras: VNCHUDMenuExtras
    let disconnect: () -> Void
    @ViewBuilder var sessionActions: () -> SessionActions
    @ViewBuilder var sessionDisplay: () -> SessionDisplay

    var body: some View {
        Menu {
            Section {
                if !hardwareKeyboardAttached, !hostProvidesKeyboardButton {
                    keyboardButton
                }
                // A Mac's own pointer already carries its position.
                #if !targetEnvironment(macCatalyst)
                HUDPointerPicker(selection: $pointerMode)
                #endif
                commandsMenu
                sessionActions()
                extras.actions
            }

            Section {
                displayMenu
                if let toggleFullScreen {
                    HUDFullScreenButton(isFullScreen: isFullScreen, toggle: toggleFullScreen)
                }
            }

            Section {
                keyboardMenu
                extras.session
            }

            Section {
                HUDCloseConnectionButton(disconnect: disconnect)
            }
        } label: {
            HUDMenuButtonLabel()
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .accessibilityLabel(String(localized: "Remote Desktop Controls", bundle: .module))
        .help(String(localized: "Remote Desktop Controls", bundle: .module))
    }

    private var keyboardButton: some View {
        Button {
            keyboardCapture.capture()
            keyboardActive.toggle()
        } label: {
            Label(
                keyboardActive
                    ? String(localized: "Hide Keyboard", bundle: .module)
                    : String(localized: "Show Keyboard", bundle: .module),
                systemImage: keyboardActive ? "keyboard.chevron.compact.down" : "keyboard")
        }
    }

    // MARK: - Commands

    private var commandsMenu: some View {
        let platform = keyboardHandler.commandPlatform
        return Menu {
            Menu(String(localized: "Editing", bundle: .module)) {
                shortcutButtons(RemoteMenuShortcut.editing, platform: platform)
            }
            Menu(String(localized: "Apps and Windows", bundle: .module)) {
                shortcutButtons(RemoteMenuShortcut.applications, platform: platform)
            }
            Menu(String(localized: "Documents and Tabs", bundle: .module)) {
                shortcutButtons(RemoteMenuShortcut.documents, platform: platform)
            }
            Menu(String(localized: "Special Keys", bundle: .module)) {
                shortcutButtons(RemoteMenuShortcut.keys, platform: platform)
                commandButtons(RemoteCommand.keys)
            }

            if platform == .mac {
                Section(String(localized: "Mac Specific", bundle: .module)) {
                    commandButtons(RemoteCommand.macSpecific)
                }
            }

            Section(String(localized: "Other Commands", bundle: .module)) {
                commandButtons(RemoteCommand.systemCommands(for: platform))
            }
        } label: {
            Label(String(localized: "Commands", bundle: .module), systemImage: "command")
        }
    }

    private func shortcutButtons(
        _ shortcuts: [RemoteMenuShortcut],
        platform: RemoteCommandPlatform
    ) -> some View {
        ForEach(RemoteMenuShortcut.available(shortcuts, on: platform)) { shortcut in
            Button(shortcut.menuTitle(for: platform)) {
                keyboardCapture.noteExternalInput()
                keyboardHandler.handleMenuShortcut(shortcut)
            }
        }
    }

    private func commandButtons(_ commands: [RemoteCommand]) -> some View {
        ForEach(commands) { command in
            Button(command.title) {
                keyboardCapture.noteExternalInput()
                keyboardHandler.handleRemoteCommand(command)
            }
        }
    }

    // MARK: - Display

    private var displayMenu: some View {
        Menu {
            HUDFitScreenButton(viewport: $viewport)
            HUDPanningPicker(selection: $viewportPanningMode)
            sessionDisplay()
            extras.display
        } label: {
            Label(String(localized: "Display", bundle: .module), systemImage: "display")
        }
    }

    // MARK: - Keyboard

    /// Settings a hardware keyboard needs stay out of a touch user's way.
    private var keyboardMenu: some View {
        Menu {
            extras.keyboard

            Button {
                keyboardCapture.capture()
                keyboardActive = true
            } label: {
                Label(String(localized: "Dictate", bundle: .module), systemImage: "mic")
            }

            if !keyboardCapture.hasReservedHostShortcuts {
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
                        systemImage: keyboardCapture.isCaptured ? "lock.open" : "lock")
                }
            }

            if hardwareKeyboardAttached {
                if keyboardCapture.hasReservedHostShortcuts {
                    Toggle(isOn: Binding(
                        get: { keyboardCapture.routesReservedHostShortcutsToVNC },
                        set: { keyboardCapture.routeReservedHostShortcutsToVNC($0) }
                    )) {
                        Label(
                            String(localized: "Route Reserved Shortcuts to Remote Computer", bundle: .module),
                            systemImage: "arrowshape.turn.up.right")
                    }
                }
                Toggle(isOn: Binding(
                    get: { keyboardCapture.controlOptionAsCommand },
                    set: { keyboardCapture.controlOptionAsCommand = $0 }
                )) {
                    Label(String(localized: "Control+Option as Command", bundle: .module), systemImage: "option")
                }
            }
        } label: {
            Label(String(localized: "Keyboard", bundle: .module), systemImage: "keyboard.badge.ellipsis")
        }
    }
}
#endif
