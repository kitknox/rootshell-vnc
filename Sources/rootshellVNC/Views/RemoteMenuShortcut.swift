import Foundation

/// Touch-menu shortcuts only. These do not register additional hardware
/// aliases or compete with the containing app's reserved shortcuts.
enum RemoteMenuShortcut: String, CaseIterable, Identifiable {
    case undo, redo, cut, copy, paste, pasteAndMatchStyle, selectAll, find
    case switchApp, switchAppBackward, switchWindow, hide, hideOthers, minimize
    case closeWindow, quit, fullScreen, spotlight, settings
    case newDocument, open, save, print, newTab, reopenTab, previousTab, nextTab
    case escape, tab, backTab, enter, backspace, forwardDelete

    var id: Self { self }

    static let editing: [Self] = [.undo, .redo, .cut, .copy, .paste, .pasteAndMatchStyle, .selectAll, .find]
    static let applications: [Self] = [
        .switchApp, .switchAppBackward, .switchWindow, .hide, .hideOthers,
        .minimize, .fullScreen, .spotlight, .settings, .closeWindow, .quit,
    ]
    static let documents: [Self] = [.newDocument, .open, .save, .print, .newTab, .reopenTab, .previousTab, .nextTab]
    static let keys: [Self] = [.escape, .tab, .backTab, .enter, .backspace, .forwardDelete]

    var title: String {
        switch self {
        case .undo: String(localized: "Undo", bundle: .module)
        case .redo: String(localized: "Redo", bundle: .module)
        case .cut: String(localized: "Cut", bundle: .module)
        case .copy: String(localized: "Copy", bundle: .module)
        case .paste: String(localized: "Paste", bundle: .module)
        case .pasteAndMatchStyle: String(localized: "Paste and Match Style", bundle: .module)
        case .selectAll: String(localized: "Select All", bundle: .module)
        case .find: String(localized: "Find", bundle: .module)
        case .switchApp: String(localized: "Switch App", bundle: .module)
        case .switchAppBackward: String(localized: "Switch App Backward", bundle: .module)
        case .switchWindow: String(localized: "Switch Window", bundle: .module)
        case .hide: String(localized: "Hide App", bundle: .module)
        case .hideOthers: String(localized: "Hide Other Apps", bundle: .module)
        case .minimize: String(localized: "Minimize Window", bundle: .module)
        case .closeWindow: String(localized: "Close Window", bundle: .module)
        case .quit: String(localized: "Quit App", bundle: .module)
        case .fullScreen: String(localized: "Toggle Full Screen", bundle: .module)
        case .spotlight: String(localized: "Spotlight", bundle: .module)
        case .settings: String(localized: "App Settings", bundle: .module)
        case .newDocument: String(localized: "New Window or Document", bundle: .module)
        case .open: String(localized: "Open…", bundle: .module)
        case .save: String(localized: "Save", bundle: .module)
        case .print: String(localized: "Print…", bundle: .module)
        case .newTab: String(localized: "New Tab", bundle: .module)
        case .reopenTab: String(localized: "Reopen Closed Tab", bundle: .module)
        case .previousTab: String(localized: "Previous Tab", bundle: .module)
        case .nextTab: String(localized: "Next Tab", bundle: .module)
        case .escape: String(localized: "Escape", bundle: .module)
        case .tab: String(localized: "Tab", bundle: .module)
        case .backTab: String(localized: "Shift-Tab", bundle: .module)
        case .enter: String(localized: "Return", bundle: .module)
        case .backspace: String(localized: "Backspace", bundle: .module)
        case .forwardDelete: String(localized: "Forward Delete", bundle: .module)
        }
    }

    var character: Character {
        switch self {
        case .undo, .redo: "z"
        case .cut: "x"
        case .copy: "c"
        case .paste, .pasteAndMatchStyle: "v"
        case .selectAll: "a"
        case .find, .fullScreen: "f"
        case .switchApp, .switchAppBackward, .tab, .backTab: "\t"
        case .switchWindow: "`"
        case .hide, .hideOthers: "h"
        case .minimize: "m"
        case .closeWindow: "w"
        case .quit: "q"
        case .spotlight: " "
        case .settings: ","
        case .newDocument: "n"
        case .open: "o"
        case .save: "s"
        case .print: "p"
        case .newTab, .reopenTab: "t"
        case .previousTab: "["
        case .nextTab: "]"
        case .escape: "\u{1B}"
        case .enter: "\r"
        case .backspace: "\u{8}"
        case .forwardDelete: "\u{7F}"
        }
    }

    var modifiers: VNCKeyboardModifiers {
        switch self {
        case .escape, .tab, .enter, .backspace, .forwardDelete: []
        case .backTab: [.shift]
        case .redo, .switchAppBackward, .reopenTab, .previousTab, .nextTab: [.command, .shift]
        case .pasteAndMatchStyle: [.command, .option, .shift]
        case .hideOthers: [.command, .option]
        case .fullScreen: [.command, .control]
        default: [.command]
        }
    }

    var menuTitle: String {
        guard !Self.keys.contains(self) else { return title }
        var symbols = modifiers.symbols
        switch character {
        case "\t": symbols += "⇥"
        case " ": symbols += String(localized: "Space", bundle: .module)
        default: symbols += String(character).uppercased()
        }
        return "\(title) (\(symbols))"
    }
}
