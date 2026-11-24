import CoreGraphics
import XCTest
@testable import rootshellVNC

final class DockedKeyboardViewportMetricsTests: XCTestCase {
    func testStaleInsetIsIgnoredAfterKeyboardRequestEnds() {
        let metrics = DockedKeyboardViewportMetrics(
            containerSize: CGSize(width: 390, height: 844),
            keyboardInset: 291)

        XCTAssertEqual(
            metrics.effectiveInset(reservingObstruction: false),
            0)
        XCTAssertEqual(
            metrics.availableSize(reservingObstruction: false),
            CGSize(width: 390, height: 844))
    }

    func testInsetIsReservedWhileKeyboardIsRequested() {
        let metrics = DockedKeyboardViewportMetrics(
            containerSize: CGSize(width: 390, height: 844),
            keyboardInset: 291)

        XCTAssertEqual(
            metrics.effectiveInset(reservingObstruction: true),
            291)
        XCTAssertEqual(
            metrics.availableSize(reservingObstruction: true),
            CGSize(width: 390, height: 553))
    }

    func testInsetCannotProduceNegativeViewportHeight() {
        let metrics = DockedKeyboardViewportMetrics(
            containerSize: CGSize(width: 390, height: 200),
            keyboardInset: 291)

        XCTAssertEqual(
            metrics.availableSize(reservingObstruction: true).height,
            0)
    }

    // Mac Catalyst: the reader missed a window resize, then the HUD bar docks
    // and undocks. A reconnect replays the same request.
    func testMatchClientKeepsLaidOutSizeWhenHUDReserveChangesAfterResize() throws {
        let staleMetrics = DockedKeyboardViewportMetrics(
            containerSize: CGSize(width: 1200, height: 800))
        let resized = CGSize(width: 1600, height: 1000)

        for mode in [VNCKeyboardAvoidanceMode.automatic, .hostManaged] {
            func request(hudReserve: CGFloat) throws -> CGSize {
                try XCTUnwrap(staleMetrics.matchClientSize(
                    layoutSize: resized,
                    hudReserve: hudReserve,
                    avoidanceMode: mode,
                    reservingObstruction: false))
            }
            XCTAssertEqual(try request(hudReserve: 0), resized)
            XCTAssertEqual(try request(hudReserve: 44), CGSize(width: 1600, height: 956))
            XCTAssertEqual(try request(hudReserve: 0), resized)
        }
    }

    func testMatchClientUsesReaderWithoutLaidOutSize() throws {
        let metrics = DockedKeyboardViewportMetrics(
            containerSize: CGSize(width: 390, height: 844),
            keyboardInset: 291)

        XCTAssertEqual(
            try XCTUnwrap(metrics.matchClientSize(
                layoutSize: nil,
                hudReserve: 44,
                avoidanceMode: .automatic,
                reservingObstruction: true)),
            CGSize(width: 390, height: 509))
        XCTAssertEqual(
            try XCTUnwrap(metrics.matchClientSize(
                layoutSize: nil,
                hudReserve: 44,
                avoidanceMode: .hostManaged,
                reservingObstruction: true)),
            CGSize(width: 390, height: 800))
    }

    func testMatchClientRejectsHUDReserveThatFillsTheViewport() {
        let metrics = DockedKeyboardViewportMetrics(
            containerSize: CGSize(width: 1200, height: 800))

        XCTAssertNil(metrics.matchClientSize(
            layoutSize: CGSize(width: 1600, height: 40),
            hudReserve: 44,
            avoidanceMode: .hostManaged,
            reservingObstruction: false))
        XCTAssertNil(metrics.matchClientSize(
            layoutSize: .zero,
            hudReserve: 0,
            avoidanceMode: .hostManaged,
            reservingObstruction: false))
    }
}
