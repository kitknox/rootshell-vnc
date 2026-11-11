import CoreGraphics
import XCTest
@testable import rootshellVNC

final class HUDDockPositionTests: XCTestCase {
    func testDefaultBottomTrailingPositionReturnsAfterKeyboardResize() {
        let full = CGRect(x: 45, y: 45, width: 934, height: 678)
        let keyboardVisible = CGRect(x: 45, y: 45, width: 934, height: 330)
        let position = HUDDockPosition.bottomTrailing

        let originalCenter = position.center(in: full)
        let keyboardCenter = position.center(in: keyboardVisible)
        let restoredCenter = position.center(in: full)

        XCTAssertEqual(originalCenter.x, full.maxX)
        XCTAssertEqual(originalCenter.y, full.maxY)
        XCTAssertEqual(keyboardCenter.x, keyboardVisible.maxX)
        XCTAssertEqual(keyboardCenter.y, keyboardVisible.maxY)
        XCTAssertEqual(restoredCenter.x, originalCenter.x)
        XCTAssertEqual(restoredCenter.y, originalCenter.y)
    }

    func testDockedPositionPreservesSideAndRelativeHeightAcrossResize() {
        let originalRect = CGRect(x: 40, y: 40, width: 900, height: 600)
        let resizedRect = CGRect(x: 30, y: 30, width: 500, height: 300)
        let position = HUDDockPosition(side: .leading, verticalFraction: 0.25)

        let originalCenter = position.center(in: originalRect)
        let resizedCenter = position.center(in: resizedRect)

        XCTAssertEqual(originalCenter.x, originalRect.minX)
        XCTAssertEqual(originalCenter.y, 190, accuracy: 0.001)
        XCTAssertEqual(resizedCenter.x, resizedRect.minX)
        XCTAssertEqual(resizedCenter.y, 105, accuracy: 0.001)
    }

    func testDockingChoosesNearestHorizontalSideAndCapturesHeight() {
        let allowedRect = CGRect(x: 50, y: 100, width: 900, height: 400)

        let leading = HUDDockPosition.docked(
            at: CGPoint(x: 200, y: 200),
            in: allowedRect)
        let trailing = HUDDockPosition.docked(
            at: CGPoint(x: 800, y: 400),
            in: allowedRect)

        XCTAssertEqual(leading.side, .leading)
        XCTAssertEqual(leading.verticalFraction, 0.25, accuracy: 0.001)
        XCTAssertEqual(trailing.side, .trailing)
        XCTAssertEqual(trailing.verticalFraction, 0.75, accuracy: 0.001)
    }

    func testAllowedCenterRectIncludesHostInsetsAndHUDSize() {
        let allowedRect = HUDDockGeometry.allowedCenterRect(
            in: CGRect(x: 0, y: 0, width: 1_024, height: 768),
            contentSize: CGSize(width: 46, height: 46),
            insets: HUDLayoutInsets(
                top: 36,
                leading: 12,
                bottom: 32,
                trailing: 12))

        XCTAssertEqual(allowedRect.minX, 35)
        XCTAssertEqual(allowedRect.maxX, 989)
        XCTAssertEqual(allowedRect.minY, 59)
        XCTAssertEqual(allowedRect.maxY, 713)
    }

    func testClampAndOversizedContainerGeometryRemainValid() {
        let allowedRect = HUDDockGeometry.allowedCenterRect(
            in: CGRect(x: 0, y: 0, width: 40, height: 30),
            contentSize: CGSize(width: 46, height: 46),
            insets: HUDLayoutInsets(
                top: 4,
                leading: 4,
                bottom: 4,
                trailing: 4))
        let center = HUDDockPosition.clamp(
            CGPoint(x: -100, y: 1_000),
            to: allowedRect)

        XCTAssertEqual(allowedRect.width, 0)
        XCTAssertEqual(allowedRect.height, 0)
        XCTAssertEqual(center.x, 20)
        XCTAssertEqual(center.y, 15)
    }

    func testSafeAreaAddsToMarginOnlyOnHonoredEdges() {
        let safeArea = HUDLayoutInsets(top: 59, leading: 0, bottom: 34, trailing: 72)

        XCTAssertEqual(
            HUDLayoutInsets(margin: 12, safeArea: safeArea),
            HUDLayoutInsets(top: 71, leading: 12, bottom: 46, trailing: 84))
        // A takeover that covers a side rail lets the HUD reach that edge.
        XCTAssertEqual(
            HUDLayoutInsets(margin: 12, safeArea: safeArea, honoring: [.top, .bottom]),
            HUDLayoutInsets(top: 71, leading: 12, bottom: 46, trailing: 12))
        XCTAssertEqual(
            HUDLayoutInsets(margin: 12),
            HUDLayoutInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
    }
}
