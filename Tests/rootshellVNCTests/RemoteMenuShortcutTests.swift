import XCTest
@testable import rootshellVNC

final class RemoteMenuShortcutTests: XCTestCase {
    func testEveryTouchShortcutIsInExactlyOneMenu() {
        let visible = RemoteMenuShortcut.editing + RemoteMenuShortcut.applications
            + RemoteMenuShortcut.documents + RemoteMenuShortcut.keys
        XCTAssertEqual(Set(visible), Set(RemoteMenuShortcut.allCases))
        XCTAssertEqual(visible.count, Set(visible).count)
    }

    func testAppSwitchingAndClipboardChords() {
        XCTAssertEqual(RemoteMenuShortcut.switchApp.character, "\t")
        XCTAssertEqual(RemoteMenuShortcut.switchApp.modifiers, [.command])
        XCTAssertEqual(RemoteMenuShortcut.switchAppBackward.character, "\t")
        XCTAssertEqual(RemoteMenuShortcut.switchAppBackward.modifiers, [.command, .shift])
        XCTAssertEqual(RemoteMenuShortcut.copy.character, "c")
        XCTAssertEqual(RemoteMenuShortcut.paste.character, "v")
        XCTAssertEqual(RemoteMenuShortcut.paste.modifiers, [.command])
        XCTAssertEqual(RemoteMenuShortcut.pasteAndMatchStyle.modifiers, [.command, .shift, .option])
        XCTAssertEqual(RemoteMenuShortcut.fullScreen.modifiers, [.control, .command])
    }

    func testSpecialKeysHaveNoCommandModifier() {
        for shortcut in RemoteMenuShortcut.keys {
            XCTAssertFalse(shortcut.modifiers.contains(.command))
            XCTAssertNotEqual(KeyboardInputHandler.keysymForCharacter(shortcut.character), 0)
        }
        XCTAssertEqual(RemoteMenuShortcut.backTab.modifiers, [.shift])
        XCTAssertEqual(KeyboardInputHandler.keysymForCharacter(RemoteMenuShortcut.escape.character), 0xFF1B)
        XCTAssertEqual(KeyboardInputHandler.keysymForCharacter(RemoteMenuShortcut.forwardDelete.character), 0xFFFF)
    }

    func testMacChordsAreTheMacSpelling() {
        for shortcut in RemoteMenuShortcut.allCases {
            XCTAssertEqual(
                shortcut.chord(for: .mac),
                .init(key: .character(shortcut.character), modifiers: shortcut.modifiers))
        }
        XCTAssertEqual(RemoteMenuShortcut.copy.menuTitle(for: .mac), "Copy (⌘C)")
        XCTAssertEqual(RemoteMenuShortcut.switchApp.menuTitle(for: .mac), "Switch App (⌘⇥)")
        XCTAssertEqual(RemoteMenuShortcut.escape.menuTitle(for: .mac), "Escape")
    }

    func testOtherPlatformsUseControlNotCommand() {
        XCTAssertEqual(
            RemoteMenuShortcut.copy.chord(for: .other),
            .init(key: .character("c"), modifiers: [.control]))
        XCTAssertEqual(
            RemoteMenuShortcut.redo.chord(for: .other),
            .init(key: .character("y"), modifiers: [.control]))
        XCTAssertEqual(
            RemoteMenuShortcut.switchApp.chord(for: .other),
            .init(key: .character("\t"), modifiers: [.option]))
        XCTAssertEqual(
            RemoteMenuShortcut.previousTab.chord(for: .other),
            .init(key: .character("\t"), modifiers: [.control, .shift]))
        XCTAssertEqual(
            RemoteMenuShortcut.closeWindow.chord(for: .other),
            .init(key: .keysym(KeyboardInputHandler.keysymF4), modifiers: [.option]))
        XCTAssertEqual(RemoteMenuShortcut.copy.menuTitle(for: .other), "Copy (Ctrl+C)")
        XCTAssertEqual(RemoteMenuShortcut.closeWindow.menuTitle(for: .other), "Close Window (Alt+F4)")
        XCTAssertEqual(RemoteMenuShortcut.reopenTab.menuTitle(for: .other), "Reopen Closed Tab (Ctrl+Shift+T)")
        XCTAssertEqual(RemoteMenuShortcut.spotlight.menuTitle(for: .other), "Start Menu")

        for shortcut in RemoteMenuShortcut.allCases {
            guard let chord = shortcut.chord(for: .other) else { continue }
            XCTAssertFalse(chord.modifiers.contains(.command), "\(shortcut)")
            XCTAssertNotEqual(chord.key.keysym, 0, "\(shortcut)")
        }
    }

    func testOtherPlatformsDropMacOnlyShortcuts() {
        let applications = RemoteMenuShortcut.available(RemoteMenuShortcut.applications, on: .other)
        XCTAssertEqual(applications, [.switchApp, .switchAppBackward, .fullScreen, .spotlight, .closeWindow])
        XCTAssertEqual(
            RemoteMenuShortcut.available(RemoteMenuShortcut.editing, on: .other),
            RemoteMenuShortcut.editing)
        XCTAssertEqual(
            RemoteMenuShortcut.available(RemoteMenuShortcut.applications, on: .mac),
            RemoteMenuShortcut.applications)
    }

    func testSystemCommandsFollowThePlatform() {
        XCTAssertEqual(RemoteCommand.systemCommands(for: .mac), [.forceQuit, .lockScreen, .logOutUser])
        XCTAssertEqual(RemoteCommand.systemCommands(for: .other), [.lockScreen, .controlAltDelete])

        let listed = Set(RemoteCommand.macSpecific + RemoteCommand.keys
            + RemoteCommand.systemCommands(for: .mac) + RemoteCommand.systemCommands(for: .other))
        XCTAssertEqual(listed, Set(RemoteCommand.allCases))

        XCTAssertEqual(
            RemoteCommand.lockScreen.remoteChord(appleModifierConvention: false, platform: .other),
            RemoteKeyChord(
                modifiers: [KeyboardInputHandler.keysymSuperL],
                key: KeyboardInputHandler.keysymForCharacter("l")))
        XCTAssertEqual(
            RemoteCommand.lockScreen.remoteChord(appleModifierConvention: false, platform: .mac),
            RemoteKeyChord(
                modifiers: [KeyboardInputHandler.keysymControlL, KeyboardInputHandler.keysymSuperL],
                key: KeyboardInputHandler.keysymForCharacter("q")))
    }

    @MainActor
    func testCommandPlatformFollowsTheModifierConventionUnlessSet() {
        let send: KeyboardInputHandler.KeyEventHandler = { _, _ in }
        XCTAssertEqual(KeyboardInputHandler(sendKeyEvent: send).commandPlatform, .other)
        XCTAssertEqual(
            KeyboardInputHandler(sendKeyEvent: send, usesAppleModifierConvention: { true }).commandPlatform,
            .mac)
        XCTAssertEqual(
            KeyboardInputHandler(sendKeyEvent: send, commandPlatform: { .mac }).commandPlatform,
            .mac)
    }

    @MainActor
    func testMenuShortcutSendsThePlatformChord() {
        var sent: [(Bool, UInt32)] = []
        let handler = KeyboardInputHandler(sendKeyEvent: { sent.append(($0, $1)) })
        handler.handleMenuShortcut(.copy)
        XCTAssertEqual(sent.map(\.1), [KeyboardInputHandler.keysymControlL, KeyboardInputHandler.keysymForCharacter("c")])
        XCTAssertTrue(sent.allSatisfy(\.0))

        sent = []
        handler.handleMenuShortcut(.hide)
        XCTAssertTrue(sent.isEmpty)
    }
}
