import XCTest
@testable import rootshellVNC

final class LoginPasswordInputTests: XCTestCase {
    func testSequenceClearsModifiersAndPacesKeyTaps() {
        let events = VNCSession.loginPasswordInputEvents(password: "Aé")

        XCTAssertEqual(Array(events.prefix(9)), [
            .key(downFlag: false, keysym: KeyboardInputHandler.keysymCapsLock),
            .key(downFlag: false, keysym: KeyboardInputHandler.keysymShiftL),
            .key(downFlag: false, keysym: KeyboardInputHandler.keysymSuperL),
            .key(downFlag: false, keysym: KeyboardInputHandler.keysymAltL),
            .key(downFlag: false, keysym: KeyboardInputHandler.keysymControlL),
            .key(downFlag: false, keysym: KeyboardInputHandler.keysymControlR),
            .key(downFlag: false, keysym: KeyboardInputHandler.keysymSuperR),
            .key(downFlag: false, keysym: KeyboardInputHandler.keysymAltR),
            .key(downFlag: false, keysym: KeyboardInputHandler.keysymShiftR),
        ])
        XCTAssertEqual(Array(events.dropFirst(9)), [
            .key(downFlag: true, keysym: 0x41),
            .key(downFlag: false, keysym: 0x41),
            .pause(nanoseconds: 5_000_000),
            .key(downFlag: true, keysym: 0xE9),
            .key(downFlag: false, keysym: 0xE9),
            .pause(nanoseconds: 5_000_000),
            .key(downFlag: true, keysym: KeyboardInputHandler.keysymReturn),
            .key(downFlag: false, keysym: KeyboardInputHandler.keysymReturn),
            .pause(nanoseconds: 5_000_000),
        ])
    }

    func testTypeOnlySequenceOmitsReturn() {
        let submitting = VNCSession.loginPasswordInputEvents(password: "Aé")
        let typeOnly = VNCSession.loginPasswordInputEvents(
            password: "Aé",
            pressingReturn: false)

        XCTAssertEqual(typeOnly, Array(submitting.dropLast(3)))
        XCTAssertEqual(Array(typeOnly.suffix(3)), [
            .key(downFlag: true, keysym: 0xE9),
            .key(downFlag: false, keysym: 0xE9),
            .pause(nanoseconds: 5_000_000),
        ])
        XCTAssertFalse(typeOnly.contains(
            .key(downFlag: true, keysym: KeyboardInputHandler.keysymReturn)))
    }

    func testFocusClickOnlyForSubmitOrServerReportedLoginWindow() {
        XCTAssertTrue(VNCSession.loginPasswordFocusesField(
            pressingReturn: true, serverReportsLoginWindow: true))
        XCTAssertTrue(VNCSession.loginPasswordFocusesField(
            pressingReturn: true, serverReportsLoginWindow: false))
        XCTAssertTrue(VNCSession.loginPasswordFocusesField(
            pressingReturn: false, serverReportsLoginWindow: true))
        XCTAssertFalse(VNCSession.loginPasswordFocusesField(
            pressingReturn: false, serverReportsLoginWindow: false))
        XCTAssertFalse(VNCSession.loginPasswordFocusesField(
            pressingReturn: true, keepingFocus: true, serverReportsLoginWindow: false))
        XCTAssertTrue(VNCSession.loginPasswordFocusesField(
            pressingReturn: true, keepingFocus: true, serverReportsLoginWindow: true))
    }

    func testPasswordFocusClickClearsFieldBeforeTypingBarrier() {
        XCTAssertEqual(
            VNCSession.loginPasswordFocusInputEvents(x: 800, y: 600),
            [
                .pointer(buttonMask: 0, x: 800, y: 600),
                .pointer(buttonMask: 1, x: 800, y: 600),
                .pointer(buttonMask: 0, x: 800, y: 600),
                .pause(nanoseconds: 150_000_000),
                .key(downFlag: true, keysym: KeyboardInputHandler.keysymSuperL),
                .key(downFlag: true, keysym: 0x61),
                .key(downFlag: false, keysym: 0x61),
                .key(
                    downFlag: false,
                    keysym: KeyboardInputHandler.keysymSuperL),
                .key(
                    downFlag: true,
                    keysym: KeyboardInputHandler.keysymBackspace),
                .key(
                    downFlag: false,
                    keysym: KeyboardInputHandler.keysymBackspace),
                .pause(nanoseconds: 50_000_000),
            ])
    }
}
