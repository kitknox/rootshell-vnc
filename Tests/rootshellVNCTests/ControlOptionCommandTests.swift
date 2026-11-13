import XCTest
@testable import rootshellVNC

final class ControlOptionCommandTests: XCTestCase {
    private let control = KeyboardInputHandler.keysymControlL
    private let option = KeyboardInputHandler.keysymMetaL
    private let command = KeyboardInputHandler.keysymSuperL

    private func event(_ down: Bool, _ keysym: UInt32) -> HardwareKeyboardTransition {
        HardwareKeyboardTransition(downFlag: down, keysym: keysym)
    }

    func testEitherPressOrderReplacesTheFirstModifierBeforeCommand() {
        for optionFirst in [false, true] {
            var state = CommandModifierState()
            let first: (UInt32, UInt32) = optionFirst ? (0xE2, option) : (0xE0, control)
            let second: (UInt32, UInt32) = optionFirst ? (0xE0, control) : (0xE2, option)
            XCTAssertEqual(state.press(usage: first.0, keysym: first.1), [event(true, first.1)])
            XCTAssertEqual(state.press(usage: second.0, keysym: second.1), [
                event(false, first.1), event(true, command),
            ])
            XCTAssertEqual(state.releaseAll(), [event(false, command)])
            XCTAssertTrue(state.releaseAll().isEmpty)
        }
    }

    func testEitherReleaseOrderRestoresTheRemainingPhysicalModifier() {
        for optionFirst in [false, true] {
            var state = CommandModifierState()
            _ = state.press(usage: 0xE0, keysym: control)
            _ = state.press(usage: 0xE2, keysym: option)
            XCTAssertEqual(state.release(usage: optionFirst ? 0xE2 : 0xE0), [
                event(false, command), event(true, optionFirst ? control : option),
            ])
            XCTAssertEqual(state.release(usage: optionFirst ? 0xE0 : 0xE2), [
                event(false, optionFirst ? control : option),
            ])
        }
    }

    func testRightHandModifiersAndPhysicalCommandShareRemoteCommand() {
        var state = CommandModifierState()
        _ = state.press(usage: 0xE4, keysym: KeyboardInputHandler.keysymControlR)
        _ = state.press(usage: 0xE6, keysym: KeyboardInputHandler.keysymMetaR)
        XCTAssertTrue(state.press(usage: 0xE7, keysym: KeyboardInputHandler.keysymSuperR).isEmpty)
        XCTAssertEqual(state.release(usage: 0xE4), [event(true, KeyboardInputHandler.keysymMetaR)])
        XCTAssertEqual(state.release(usage: 0xE6), [event(false, KeyboardInputHandler.keysymMetaR)])
        XCTAssertEqual(state.release(usage: 0xE7), [event(false, command)])
    }

    func testBothControlSidesCanBeReleasedIndependently() {
        var state = CommandModifierState()
        _ = state.press(usage: 0xE0, keysym: control)
        _ = state.press(usage: 0xE2, keysym: option)
        XCTAssertTrue(state.press(usage: 0xE4, keysym: KeyboardInputHandler.keysymControlR).isEmpty)
        XCTAssertTrue(state.release(usage: 0xE0).isEmpty)
        XCTAssertEqual(state.release(usage: 0xE4), [event(false, command), event(true, option)])
    }

    func testFlagsBeforePhysicalEventsDoNotLeaveAnInferredModifierHeld() {
        var state = CommandModifierState()
        XCTAssertEqual(state.synchronize(modifiers: [.control, .option], optionKeysym: option), [
            event(true, command),
        ])
        XCTAssertTrue(state.press(usage: 0xE4, keysym: KeyboardInputHandler.keysymControlR).isEmpty)
        XCTAssertTrue(state.press(usage: 0xE6, keysym: KeyboardInputHandler.keysymMetaR).isEmpty)
        _ = state.release(usage: 0xE4)
        _ = state.release(usage: 0xE6)
        XCTAssertTrue(state.physical.isEmpty)
        XCTAssertTrue(state.releaseAll().isEmpty)
    }

    func testShiftChangesWhileCommandRemainsHeld() {
        var state = CommandModifierState()
        _ = state.synchronize(modifiers: [.control, .option], optionKeysym: option)
        XCTAssertEqual(state.synchronize(modifiers: [.control, .option, .shift], optionKeysym: option), [
            event(true, KeyboardInputHandler.keysymShiftL),
        ])
        XCTAssertEqual(state.synchronize(modifiers: [.control, .option], optionKeysym: option), [
            event(false, KeyboardInputHandler.keysymShiftL),
        ])
        XCTAssertTrue(state.contains(keysym: command))
    }

    func testReleaseOnlySynchronizeNeverPressesALatchedModifier() {
        var state = CommandModifierState()
        _ = state.press(usage: 0xE1, keysym: KeyboardInputHandler.keysymShiftL)
        // A snapshot still showing Command after its key-up (#747).
        XCTAssertTrue(state.synchronize(
            modifiers: [.shift, .command], optionKeysym: option, inferMissing: false).isEmpty)
        XCTAssertFalse(state.contains(keysym: command))
        XCTAssertEqual(state.synchronize(
            modifiers: [.command], optionKeysym: option, inferMissing: false), [
            event(false, KeyboardInputHandler.keysymShiftL),
        ])
        XCTAssertTrue(state.physical.isEmpty)
    }

    @MainActor
    func testSessionDefaultsOnAndChoicesAreIndependent() {
        let first = VNCKeyboardCapture()
        let second = VNCKeyboardCapture()
        XCTAssertTrue(first.controlOptionAsCommand)
        first.controlOptionAsCommand = false
        XCTAssertTrue(second.controlOptionAsCommand)
        first.release()
        first.capture()
        XCTAssertFalse(first.controlOptionAsCommand)
    }
}

final class UniversalCommandKeyIdentityTests: XCTestCase {
    func testUnrelatedUnknownKeyUpPreservesPendingTapDeduplication() {
        var state = UniversalCommandKeyState()
        XCTAssertEqual(state.routeCommand(keysym: 0x61), .tap)
        XCTAssertFalse(state.release(usage: 0x05))
        XCTAssertFalse(state.release(usage: 0x06, keysym: 0x63))
        XCTAssertFalse(state.beginPhysical(usage: 0x14, keysym: 0x61),
                       "The later AZERTY A event was already emitted by the command tap")
    }

    func testReleasingAnotherTrackedKeyPreservesAllPendingTaps() {
        var state = UniversalCommandKeyState()
        XCTAssertTrue(state.beginPhysical(usage: 0x05, keysym: 0x62))
        XCTAssertEqual(state.routeCommand(keysym: 0x61), .tap)
        XCTAssertEqual(state.routeCommand(keysym: 0x63), .tap)
        XCTAssertTrue(state.release(usage: 0x05))
        XCTAssertFalse(state.beginPhysical(usage: 0x14, keysym: 0x61))
        XCTAssertFalse(state.beginPhysical(usage: 0x06, keysym: 0x63))
    }

    func testCorrelatedKeyUpWithoutKeyDownClearsOnlyItsOwnPendingTap() {
        var state = UniversalCommandKeyState()
        XCTAssertEqual(state.routeCommand(keysym: 0x61), .tap)
        XCTAssertEqual(state.routeCommand(keysym: 0x63), .tap)
        XCTAssertFalse(state.release(usage: 0x14, keysym: 0x61))
        XCTAssertTrue(state.beginPhysical(usage: 0x14, keysym: 0x61), "This is a new stroke")
        XCTAssertFalse(state.beginPhysical(usage: 0x06, keysym: 0x63))
    }

    func testEndingTranslatedChordClearsPendingTapsButRetainsHeldKeyIdentity() {
        var state = UniversalCommandKeyState()
        XCTAssertTrue(state.beginPhysical(usage: 0x05, keysym: 0x62))
        XCTAssertEqual(state.routeCommand(keysym: 0x61), .tap)
        state.endTranslatedChord()
        XCTAssertTrue(state.beginPhysical(usage: 0x14, keysym: 0x61))
        XCTAssertTrue(state.release(usage: 0x05))
    }

    func testAZERTYPhysicalFirstUsesActualUsageForDeduplicationAndRelease() {
        var state = UniversalCommandKeyState()
        // AZERTY's A is physically the US-Q position, not USB usage 0x04.
        XCTAssertTrue(state.beginPhysical(usage: 0x14, keysym: 0x61))
        XCTAssertEqual(state.routeCommand(keysym: 0x61), .duplicate)
        XCTAssertFalse(state.beginPhysical(usage: 0x14, keysym: 0x61))
        XCTAssertNil(state.pressed[0x04])
        XCTAssertTrue(state.release(usage: 0x14))
        XCTAssertTrue(state.pressed.isEmpty)
    }

    func testAZERTYCommandFirstIsBoundedAndConsumesDuplicatePhysicalDelivery() {
        var state = UniversalCommandKeyState()
        XCTAssertEqual(state.routeCommand(keysym: 0x61), .tap)
        XCTAssertTrue(state.pressed.isEmpty, "A command string must never invent a held HID key")
        XCTAssertFalse(state.beginPhysical(usage: 0x14, keysym: 0x61))
        XCTAssertEqual(state.routeCommand(keysym: 0x61), .tap, "Command-only autorepeat stays bounded")
        XCTAssertTrue(state.release(usage: 0x14))
        XCTAssertTrue(state.beginPhysical(usage: 0x14, keysym: 0x61), "A later stroke must not be consumed")
    }

    func testNonUSOverlappingKeysRetainTheirOwnReleaseIdentities() {
        var state = UniversalCommandKeyState()
        XCTAssertTrue(state.beginPhysical(usage: 0x1D, keysym: 0x79)) // German Y
        XCTAssertTrue(state.beginPhysical(usage: 0x10, keysym: 0x3B)) // AZERTY semicolon
        XCTAssertEqual(state.routeCommand(keysym: 0x79), .duplicate)
        XCTAssertEqual(state.routeCommand(keysym: 0x3B), .duplicate)
        XCTAssertTrue(state.release(usage: 0x1D))
        XCTAssertEqual(state.pressed, [0x10: 0x3B])
        state.releaseAll()
        XCTAssertTrue(state.pressed.isEmpty)
        XCTAssertEqual(state.routeCommand(keysym: 0x3B), .tap)
    }
}

#if canImport(UIKit)
import UIKit

final class ControlOptionCommandIntegrationTests: XCTestCase {
    @MainActor
    func testUnidentifiedCommandSendsKeyUpWithoutWaitingForUSLayoutRelease() {
        var events: [HardwareKeyboardTransition] = []
        let view = RemoteInputUIView(
            touchHandler: TouchInputHandler { _, _, _ in },
            keyboardHandler: KeyboardInputHandler(sendKeyEvent: {
                events.append(HardwareKeyboardTransition(downFlag: $0, keysym: $1))
            }),
            keyboardCapture: VNCKeyboardCapture(),
            requestPasswordSend: {}, requestDictation: {}, toggleFullScreen: nil, disconnect: {})
        let command = UIKeyCommand(input: "a", modifierFlags: [.control, .alternate],
            action: NSSelectorFromString("handleUniversalCommandKey:"))
        _ = view.perform(command.action, with: command)
        XCTAssertEqual(events.map(\.keysym), [0xFFEB, 0x61, 0x61])
        XCTAssertEqual(events.map(\.downFlag), [true, true, false])
        _ = view.resignFirstResponder()
        XCTAssertEqual(events.last, HardwareKeyboardTransition(downFlag: false, keysym: 0xFFEB))
    }

    @MainActor
    func testTabTapsAndDuplicateDeliveryKeepCommandHeld() {
        var events: [HardwareKeyboardTransition] = []
        let controller = HardwareKeyboardController(keyboardHandler: KeyboardInputHandler(sendKeyEvent: {
            events.append(HardwareKeyboardTransition(downFlag: $0, keysym: $1))
        }))
        controller.synchronizeModifiers([.control, .option])
        for _ in 0..<2 {
            controller.press(usage: 0x2B, keysym: KeyboardInputHandler.keysymTab)
            controller.press(usage: 0x2B, keysym: KeyboardInputHandler.keysymTab)
            controller.release(usage: 0x2B)
            controller.release(usage: 0x2B)
        }
        controller.releaseAll()
        XCTAssertEqual(events.map(\.keysym), [0xFFEB, 0xFF09, 0xFF09, 0xFF09, 0xFF09, 0xFFEB])
        XCTAssertEqual(events.map(\.downFlag), [true, true, false, true, false, false])
    }

    @MainActor
    func testMappedKeysAndOverlappingPressesReleaseCleanlyWhenDisabled() {
        for (usage, characters) in [(UInt32(0x04), "a"), (0x36, ","), (0x52, ""),
                                    (0x29, ""), (0x2A, ""), (0x4C, "")] {
            var events: [HardwareKeyboardTransition] = []
            let controller = HardwareKeyboardController(keyboardHandler: KeyboardInputHandler(sendKeyEvent: {
                events.append(HardwareKeyboardTransition(downFlag: $0, keysym: $1))
            }))
            controller.synchronizeModifiers([.control, .option, .shift])
            let keysym = KeyboardInputHandler.keysymForHIDUsage(usage, characters: characters)
            controller.press(usage: usage, keysym: keysym)
            controller.press(usage: 0x2B, keysym: KeyboardInputHandler.keysymTab)
            controller.controlOptionAsCommand = false
            XCTAssertFalse(controller.hasPressedKeys)
            XCTAssertEqual(events.filter { $0.keysym == keysym }.map(\.downFlag), [true, false])
            XCTAssertEqual(events.filter { $0.keysym == 0xFFEB }.map(\.downFlag), [true, false])
            XCTAssertFalse(events.contains { [UInt32(0xFFE3), 0xFFE9, 0xFFE7].contains($0.keysym) })
            let count = events.count
            controller.releaseAll()
            XCTAssertEqual(events.count, count)
        }
    }

    @MainActor
    func testDisabledModeKeepsPhysicalControlOption() {
        var events: [HardwareKeyboardTransition] = []
        let controller = HardwareKeyboardController(keyboardHandler: KeyboardInputHandler(sendKeyEvent: {
            events.append(HardwareKeyboardTransition(downFlag: $0, keysym: $1))
        }))
        controller.controlOptionAsCommand = false
        controller.press(usage: 0xE0, keysym: 0xFFE3)
        controller.press(usage: 0xE2, keysym: 0xFFE7)
        controller.releaseAll()
        XCTAssertEqual(events.map(\.keysym), [0xFFE3, 0xFFE7, 0xFFE7, 0xFFE3])
    }

    @MainActor
    func testUniversalRegistrationsReplaceConflictingAliasesAndDictation() {
        let capture = VNCKeyboardCapture()
        let view = RemoteInputUIView(
            touchHandler: TouchInputHandler { _, _, _ in },
            keyboardHandler: KeyboardInputHandler(sendKeyEvent: { _, _ in }),
            keyboardCapture: capture,
            requestPasswordSend: {}, requestDictation: {}, toggleFullScreen: nil, disconnect: {})
        for input in ["\t", "h", "m", "q", "l", "\u{8}", UIKeyCommand.inputEscape, UIKeyCommand.inputUpArrow] {
            let matching = (view.keyCommands ?? []).filter {
                $0.input == input && $0.modifierFlags == [.control, .alternate]
            }
            XCTAssertEqual(matching.count, 1, input)
            XCTAssertEqual(matching.first?.action, NSSelectorFromString("handleUniversalCommandKey:"))
        }
        capture.controlOptionAsCommand = false
        XCTAssertFalse((view.keyCommands ?? []).contains {
            $0.action == NSSelectorFromString("handleUniversalCommandKey:")
        })
        XCTAssertTrue((view.keyCommands ?? []).contains {
            $0.input == "l" && $0.action == NSSelectorFromString("handleDictationCommand:")
        })
    }
}
#endif
