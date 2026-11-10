import CoreGraphics
import XCTest
@testable import rootshellVNC

final class RemoteTouchGestureTests: XCTestCase {
    func testButtonMasksUseStandardRFBOrder() {
        XCTAssertEqual(RemotePointerButton.left.mask, 0x01)
        XCTAssertEqual(RemotePointerButton.middle.mask, 0x02)
        XCTAssertEqual(RemotePointerButton.right.mask, 0x04)
    }

    @MainActor
    func testMiddleClickPressesAndReleasesTheMiddleButton() {
        var events: [(UInt8, UInt16, UInt16)] = []
        let handler = TouchInputHandler { mask, x, y in events.append((mask, x, y)) }

        handler.handleMiddleClick(x: 10, y: 20)

        XCTAssertEqual(events.map(\.0), [0, TouchInputHandler.middleButton, 0])
        XCTAssertEqual(events.map(\.1), [10, 10, 10])
        XCTAssertEqual(events.map(\.2), [20, 20, 20])
    }

    @MainActor
    func testRightAndMiddleDragsKeepTheirButtonUntilRelease() {
        for button in [RemotePointerButton.right, .middle] {
            var events: [UInt8] = []
            let handler = TouchInputHandler { mask, _, _ in events.append(mask) }

            handler.handleDrag(x: 1, y: 1, button: button)
            handler.handleDrag(x: 5, y: 5, button: button)
            handler.handleDragEnd(x: 5, y: 5)

            XCTAssertEqual(events, [button.mask, button.mask, 0])
        }
    }

    @MainActor
    func testDragDefaultsToTheLeftButton() {
        var events: [UInt8] = []
        let handler = TouchInputHandler { mask, _, _ in events.append(mask) }

        handler.handleDrag(x: 1, y: 1)

        XCTAssertEqual(events, [TouchInputHandler.leftButton])
    }

    func testStandardConfigurationFollowsTheMacTrackpad() {
        let configuration = RemoteTouchGestureConfiguration.standard
        XCTAssertEqual(configuration.holdDuration, 0.3)
        XCTAssertEqual(configuration.action(for: .up), .missionControl)
        XCTAssertEqual(configuration.action(for: .down), .applicationWindows)
        XCTAssertEqual(configuration.action(for: .left), .moveRightASpace)
        XCTAssertEqual(configuration.action(for: .right), .moveLeftASpace)
        XCTAssertTrue(configuration.hasSwipeActions)
        XCTAssertTrue(configuration.showsButtonIndicator)
    }

    func testHoldDurationIsClampedToTheSupportedRange() {
        XCTAssertEqual(RemoteTouchGestureConfiguration(holdDuration: 0).resolvedHoldDuration, 0.15)
        XCTAssertEqual(RemoteTouchGestureConfiguration(holdDuration: 5).resolvedHoldDuration, 1.0)
        XCTAssertEqual(RemoteTouchGestureConfiguration(holdDuration: 0.5).resolvedHoldDuration, 0.5)
        XCTAssertEqual(
            RemoteTouchGestureConfiguration(holdDuration: .nan).resolvedHoldDuration,
            RemoteTouchGestureConfiguration.defaultHoldDuration)
    }

    func testSwipesAreOffOnlyWhenEveryDirectionIsOff() {
        var configuration = RemoteTouchGestureConfiguration(
            swipeUp: .none, swipeDown: .none, swipeLeft: .none, swipeRight: .none)
        XCTAssertFalse(configuration.hasSwipeActions)
        configuration.swipeRight = .missionControl
        XCTAssertTrue(configuration.hasSwipeActions)
    }

    func testSwipeActionsSendTheMatchingRemoteCommands() {
        XCTAssertNil(RemoteSwipeAction.none.command)
        XCTAssertEqual(RemoteSwipeAction.missionControl.command, .missionControl)
        XCTAssertEqual(RemoteSwipeAction.applicationWindows.command, .applicationWindows)
        XCTAssertEqual(RemoteSwipeAction.moveLeftASpace.command, .moveLeftASpace)
        XCTAssertEqual(RemoteSwipeAction.moveRightASpace.command, .moveRightASpace)
    }

    func testLongStrokeFiresOnceWhenItCrossesTheCommitDistance() {
        var tracker = MultiFingerSwipeTracker()
        XCTAssertNil(tracker.update(translation: CGPoint(x: 0, y: -30)))
        XCTAssertEqual(tracker.update(translation: CGPoint(x: 5, y: -61)), .up)
        XCTAssertNil(tracker.update(translation: CGPoint(x: 5, y: -200)))
        XCTAssertNil(tracker.end(translation: CGPoint(x: 5, y: -200), velocity: CGPoint(x: 0, y: -2000)))
    }

    func testDiagonalStrokeNeverFires() {
        var tracker = MultiFingerSwipeTracker()
        XCTAssertNil(tracker.update(translation: CGPoint(x: 80, y: 70)))
        XCTAssertNil(tracker.end(translation: CGPoint(x: 80, y: 70), velocity: CGPoint(x: 900, y: 800)))
    }

    func testShortStrokeFiresAtReleaseOnlyWhenQuick() {
        var quick = MultiFingerSwipeTracker()
        XCTAssertNil(quick.update(translation: CGPoint(x: -30, y: 2)))
        XCTAssertEqual(quick.end(translation: CGPoint(x: -30, y: 2), velocity: CGPoint(x: -700, y: 0)), .left)

        var slow = MultiFingerSwipeTracker()
        XCTAssertNil(slow.end(translation: CGPoint(x: -30, y: 2), velocity: CGPoint(x: -100, y: 0)))

        var reversed = MultiFingerSwipeTracker()
        XCTAssertNil(reversed.end(translation: CGPoint(x: -30, y: 2), velocity: CGPoint(x: 700, y: 0)))
    }

    func testResetArmsTheTrackerForTheNextStroke() {
        var tracker = MultiFingerSwipeTracker()
        XCTAssertEqual(tracker.update(translation: CGPoint(x: 70, y: 0)), .right)
        tracker.reset()
        XCTAssertEqual(tracker.update(translation: CGPoint(x: 0, y: 70)), .down)
    }

    func testIndicatorNamesTheButtonAndAnyHeldModifiers() {
        let plain = TouchButtonIndicatorText.title(for: .right, modifiers: [])
        let modified = TouchButtonIndicatorText.title(for: .right, modifiers: [.command, .shift])
        XCTAssertFalse(plain.isEmpty)
        XCTAssertEqual(modified, "⇧⌘ \(plain)")
        XCTAssertNotEqual(
            TouchButtonIndicatorText.title(for: .left, modifiers: []),
            TouchButtonIndicatorText.title(for: .middle, modifiers: []))
    }

    func testModifierSymbolsUseMenuOrder() {
        XCTAssertEqual(VNCKeyboardModifiers([.command, .control, .shift, .option]).symbols, "⌃⌥⇧⌘")
        XCTAssertEqual(VNCKeyboardModifiers().symbols, "")
    }
}
