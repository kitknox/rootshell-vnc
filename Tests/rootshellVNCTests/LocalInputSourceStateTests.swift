import XCTest
@testable import rootshellVNC

final class LocalInputSourceStateTests: XCTestCase {
    func testInstalledLanguagesCycleInOrderWithoutDuplicatesOrPseudoModes() {
        let languages = LocalInputSourceState.availableLanguages(
            ["emoji", "ja-JP", "en-US", "ko-KR", "en-GB", "fr-FR", "zh-Hans", "ja-JP", "", "dictation"])
        XCTAssertEqual(languages, ["ja-JP", "en-US", "ko-KR", "en-GB", "fr-FR", "zh-Hans"])
        for index in languages.indices {
            XCTAssertEqual(LocalInputSourceState.nextLanguage(current: languages[index], languages: languages),
                           languages[(index + 1) % languages.count])
        }
        XCTAssertEqual(LocalInputSourceState.nextLanguage(current: "de-DE", languages: languages), "ja-JP")
    }

    func testMissingSecondLanguageDoesNotSwitch() {
        let languages = LocalInputSourceState.availableLanguages(["en-US", "emoji", "en-US"])
        XCTAssertNil(LocalInputSourceState.nextLanguage(current: "en-US", languages: languages))
        XCTAssertNil(LocalInputSourceState.nextLanguage(current: nil, languages: []))
    }

    @MainActor
    func testRoutingDefaultsAndSessionChanges() {
        let capture = VNCKeyboardCapture()
        XCTAssertTrue(capture.routesControlSpaceToRemote)
        XCTAssertFalse(capture.capsLockSwitchesInputSource)
        var changes = 0
        capture.onInputSourceRoutingChanged = { changes += 1 }
        capture.routesControlSpaceToRemote = false
        capture.capsLockSwitchesInputSource = true
        XCTAssertEqual(changes, 2)
    }

    func testCapsLockTapHoldAndCancelledPress() {
        var state = LocalInputSourceState()
        XCTAssertTrue(state.pressCapsLock(shift: false, at: 0))
        XCTAssertFalse(state.pressCapsLock(shift: false, at: 0.1))
        XCTAssertTrue(state.releaseCapsLock(at: 0.2))
        _ = state.pressCapsLock(shift: false, at: 1)
        state.holdCapsLock(at: 1 + LocalInputSourceState.capsLockHoldDuration)
        XCTAssertTrue(state.uppercaseLocked)
        XCTAssertFalse(state.releaseCapsLock(at: 2))
        _ = state.pressCapsLock(shift: false, at: 3)
        XCTAssertFalse(state.releaseCapsLock(at: 3.1))
        XCTAssertFalse(state.uppercaseLocked)
        _ = state.pressCapsLock(shift: false, at: 4)
        state.releaseCapsLock()
        XCTAssertFalse(state.releaseCapsLock(at: 5))
        _ = state.pressCapsLock(shift: false, at: 6)
        XCTAssertFalse(state.releaseCapsLock(at: 7))
        XCTAssertTrue(state.uppercaseLocked)
    }

    func testConsumedCapsLockDoesNotLeaveEnglishUppercase() {
        var state = LocalInputSourceState()
        XCTAssertEqual(state.hardwareCharacters("A", shift: false), "A")
        _ = state.pressCapsLock(shift: false, at: 0)
        _ = state.releaseCapsLock(at: 0.1)
        XCTAssertEqual(state.hardwareCharacters("A", shift: false), "a")
        XCTAssertEqual(state.hardwareCharacters("a", shift: true), "A")
        XCTAssertEqual(state.hardwareCharacters("!§{}", shift: true), "!§{}")
        XCTAssertEqual(state.hardwareCharacters("한글", shift: false), "한글")
    }

    func testShiftCapsLockPreservesIntentionalCaseLockWithoutSwitchingLanguage() {
        var state = LocalInputSourceState()
        _ = state.pressCapsLock(shift: true, at: 0)
        XCTAssertTrue(state.uppercaseLocked)
        XCTAssertEqual(state.hardwareCharacters("a", shift: false), "A")
        XCTAssertEqual(state.hardwareCharacters("A", shift: true), "a")
        XCTAssertFalse(state.releaseCapsLock(at: 1))
        _ = state.pressCapsLock(shift: true, at: 2)
        XCTAssertFalse(state.uppercaseLocked)
        XCTAssertFalse(state.releaseCapsLock(at: 2.1))
        XCTAssertEqual(state.hardwareCharacters("A", shift: false), "a")
    }

    @MainActor
    func testInputObserverIdentifiesShiftBeforeSendingItAndDoesNotObserveReleases() {
        var events: [String] = []
        let handler = KeyboardInputHandler(sendKeyEvent: { down, keysym in
            events.append("send:\(keysym):\(down)")
        }).notifyingKeyDown { keysym in
            events.append("observe:\(keysym)")
        }
        handler.handleKeysym(downFlag: true, keysym: KeyboardInputHandler.keysymShiftL)
        handler.handleKeysym(downFlag: false, keysym: KeyboardInputHandler.keysymShiftL)
        XCTAssertEqual(events, ["observe:65505", "send:65505:true", "send:65505:false"])
    }
}
