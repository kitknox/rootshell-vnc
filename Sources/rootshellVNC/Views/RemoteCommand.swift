import Foundation

/// Which computer a remote command's shortcut is written for.
public enum RemoteCommandPlatform: Sendable, Equatable {
    case mac
    /// Windows and Linux conventions.
    case other
}

/// A local, conflict-resistant shortcut that expands to a familiar command on
/// the remote computer. These defaults follow common VNC viewer conventions,
/// so hardware keyboard and touch users share one command vocabulary.
enum RemoteCommand: String, CaseIterable, Identifiable, Sendable {
    case missionControl
    case applicationWindows
    case moveLeftASpace
    case moveRightASpace
    case forceQuit
    case lockScreen
    case logOutUser
    case controlAltDelete
    case backslash
    case insert

    var id: Self { self }

    static let macSpecific: [Self] = [
        .missionControl,
        .applicationWindows,
        .moveLeftASpace,
        .moveRightASpace,
    ]

    /// Keys some keyboards lack, listed with the menu's Special Keys.
    static let keys: [Self] = [.backslash, .insert]

    static func systemCommands(for platform: RemoteCommandPlatform) -> [Self] {
        switch platform {
        case .mac: [.forceQuit, .lockScreen, .logOutUser]
        case .other: [.lockScreen, .controlAltDelete]
        }
    }

    var title: String {
        switch self {
        case .missionControl:
            String(localized: "Mission Control", bundle: .module, comment: "Remote keyboard command")
        case .applicationWindows:
            String(localized: "Application Windows", bundle: .module, comment: "Remote keyboard command")
        case .moveLeftASpace:
            String(localized: "Move Left a Space", bundle: .module, comment: "Remote keyboard command")
        case .moveRightASpace:
            String(localized: "Move Right a Space", bundle: .module, comment: "Remote keyboard command")
        case .forceQuit:
            String(localized: "Force Quit…", bundle: .module, comment: "Remote keyboard command")
        case .lockScreen:
            String(localized: "Lock Screen", bundle: .module, comment: "Remote keyboard command")
        case .logOutUser:
            String(localized: "Log Out User…", bundle: .module, comment: "Remote keyboard command")
        case .controlAltDelete:
            String(localized: "Ctrl-Alt-Delete", bundle: .module, comment: "Remote keyboard command")
        case .backslash:
            String(localized: "Backslash", bundle: .module, comment: "Remote keyboard command")
        case .insert:
            String(localized: "Insert", bundle: .module, comment: "Remote keyboard command")
        }
    }

    var shortcut: RemoteCommandShortcut {
        switch self {
        case .missionControl:
            RemoteCommandShortcut(input: .upArrow, modifiers: [.control, .option])
        case .applicationWindows:
            RemoteCommandShortcut(input: .downArrow, modifiers: [.control, .option])
        case .moveLeftASpace:
            RemoteCommandShortcut(input: .leftArrow, modifiers: [.control, .option])
        case .moveRightASpace:
            RemoteCommandShortcut(input: .rightArrow, modifiers: [.control, .option])
        case .forceQuit:
            RemoteCommandShortcut(input: .escape, modifiers: [.control, .option])
        case .lockScreen:
            RemoteCommandShortcut(input: .character("q"), modifiers: [.control, .option])
        case .logOutUser:
            RemoteCommandShortcut(input: .character("q"), modifiers: [.option, .shift])
        case .controlAltDelete:
            RemoteCommandShortcut(input: .delete, modifiers: [.control, .option])
        case .backslash:
            RemoteCommandShortcut(input: .character("7"), modifiers: [.control, .shift])
        case .insert:
            RemoteCommandShortcut(input: .character("8"), modifiers: [.control, .shift])
        }
    }

    /// The remote key chord this command expands to.
    ///
    /// - Parameter appleModifierConvention: When `true`, the **Option** leg of
    ///   commands such as Force Quit (⌘⌥⎋) is emitted as `Meta_L`, because
    ///   Apple's Screen Sharing server maps `Alt_L` to Command. `controlAltDelete`
    ///   keeps the literal `Alt_L` (PC "Ctrl-Alt-Del" semantics; the combo has no
    ///   Mac meaning anyway).
    func remoteChord(
        appleModifierConvention: Bool,
        platform: RemoteCommandPlatform
    ) -> RemoteKeyChord {
        let optionKeysym = KeyboardInputHandler.optionLeftKeysym(
            appleModifierConvention: appleModifierConvention)
        switch self {
        case .missionControl:
            return RemoteKeyChord(modifiers: [KeyboardInputHandler.keysymControlL], key: KeyboardInputHandler.keysymUp)
        case .applicationWindows:
            return RemoteKeyChord(modifiers: [KeyboardInputHandler.keysymControlL], key: KeyboardInputHandler.keysymDown)
        case .moveLeftASpace:
            return RemoteKeyChord(modifiers: [KeyboardInputHandler.keysymControlL], key: KeyboardInputHandler.keysymLeft)
        case .moveRightASpace:
            return RemoteKeyChord(modifiers: [KeyboardInputHandler.keysymControlL], key: KeyboardInputHandler.keysymRight)
        case .forceQuit:
            return RemoteKeyChord(
                modifiers: [KeyboardInputHandler.keysymSuperL, optionKeysym],
                key: KeyboardInputHandler.keysymEscape)
        case .lockScreen:
            guard platform == .mac else {
                return RemoteKeyChord(
                    modifiers: [KeyboardInputHandler.keysymSuperL],
                    key: KeyboardInputHandler.keysymForCharacter("l"))
            }
            return RemoteKeyChord(
                modifiers: [KeyboardInputHandler.keysymControlL, KeyboardInputHandler.keysymSuperL],
                key: KeyboardInputHandler.keysymForCharacter("q"))
        case .logOutUser:
            return RemoteKeyChord(
                modifiers: [KeyboardInputHandler.keysymShiftL, KeyboardInputHandler.keysymSuperL],
                key: KeyboardInputHandler.keysymForCharacter("q"))
        case .controlAltDelete:
            return RemoteKeyChord(
                modifiers: [KeyboardInputHandler.keysymControlL, KeyboardInputHandler.keysymAltL],
                key: KeyboardInputHandler.keysymDelete)
        case .backslash:
            return RemoteKeyChord(modifiers: [], key: KeyboardInputHandler.keysymForCharacter("\\"))
        case .insert:
            return RemoteKeyChord(modifiers: [], key: KeyboardInputHandler.keysymInsert)
        }
    }
}

struct RemoteCommandModifiers: OptionSet, Equatable, Sendable {
    let rawValue: UInt8

    static let control = Self(rawValue: 1 << 0)
    static let option = Self(rawValue: 1 << 1)
    static let shift = Self(rawValue: 1 << 2)
    static let command = Self(rawValue: 1 << 3)
}

enum RemoteCommandInput: Equatable, Sendable {
    case character(Character)
    case upArrow
    case downArrow
    case leftArrow
    case rightArrow
    case escape
    case delete
}

struct RemoteCommandShortcut: Equatable, Sendable {
    let input: RemoteCommandInput
    let modifiers: RemoteCommandModifiers
}

struct RemoteKeyChord: Equatable, Sendable {
    let modifiers: [UInt32]
    let key: UInt32
}
