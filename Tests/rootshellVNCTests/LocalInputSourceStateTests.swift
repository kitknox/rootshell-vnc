import XCTest
@testable import rootshellVNC

final class LocalInputSourceStateTests: XCTestCase {
    func testOnlyInstalledRequestedLanguagesParticipate() {
        let languages = LocalInputSourceState.matchingLanguages(
            preferences: ["ko", "en"], available: ["emoji", "ja-JP", "en-US", "ko-KR", "en-GB"])
        XCTAssertEqual(languages, ["ko-KR", "en-US"])
        XCTAssertEqual(LocalInputSourceState.nextLanguage(current: "en-US", languages: languages), "ko-KR")
        XCTAssertEqual(LocalInputSourceState.nextLanguage(current: "ko-KR", languages: languages), "en-US")
    }

    func testMissingSecondLanguageKeepsNormalCapsLock() {
        let languages = LocalInputSourceState.matchingLanguages(
            preferences: ["ko", "en"], available: ["en-US", "emoji"])
        XCTAssertNil(LocalInputSourceState.nextLanguage(current: "en-US", languages: languages))
        XCTAssertNil(LocalInputSourceState.nextLanguage(current: nil, languages: []))
    }

    func testExactLanguageWinsAndDuplicatesDoNotMakeACycle() {
        XCTAssertEqual(LocalInputSourceState.matchingLanguages(
            preferences: ["en", "en", "ko"], available: ["en-US", "en", "ko"]), ["en", "ko"])
        XCTAssertEqual(LocalInputSourceState.matchingLanguages(
            preferences: ["en"], available: ["eng", "emoji"]), [])
    }

    func testHeldCapsLockSwitchesOnlyOnceAndNextTapSwitchesAgain() {
        var state = LocalInputSourceState()
        XCTAssertTrue(state.pressCapsLock(shift: false))
        XCTAssertFalse(state.pressCapsLock(shift: false))
        XCTAssertTrue(state.capsLockIsDown)
        state.releaseCapsLock()
        XCTAssertTrue(state.pressCapsLock(shift: false))
    }

    func testConsumedCapsLockDoesNotLeaveEnglishUppercase() {
        var state = LocalInputSourceState()
        XCTAssertEqual(state.hardwareCharacters("A", shift: false), "A")
        _ = state.pressCapsLock(shift: false)
        state.releaseCapsLock()
        XCTAssertEqual(state.hardwareCharacters("A", shift: false), "a")
        XCTAssertEqual(state.hardwareCharacters("a", shift: true), "A")
        XCTAssertEqual(state.hardwareCharacters("!§{}", shift: true), "!§{}")
        XCTAssertEqual(state.hardwareCharacters("한글", shift: false), "한글")
    }

    func testShiftCapsLockPreservesIntentionalCaseLockWithoutSwitchingLanguage() {
        var state = LocalInputSourceState()
        XCTAssertFalse(state.pressCapsLock(shift: true))
        XCTAssertTrue(state.uppercaseLocked)
        XCTAssertEqual(state.hardwareCharacters("a", shift: false), "A")
        XCTAssertEqual(state.hardwareCharacters("A", shift: true), "a")
        state.releaseCapsLock()
        XCTAssertFalse(state.pressCapsLock(shift: true))
        XCTAssertFalse(state.uppercaseLocked)
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
