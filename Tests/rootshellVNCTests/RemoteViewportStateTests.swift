import CoreGraphics
import XCTest
@testable import rootshellVNC

final class RemoteViewportStateTests: XCTestCase {
    private let viewSize = CGSize(width: 1000, height: 1000)
    private let framebufferSize = CGSize(width: 1920, height: 1080)

    func testAspectFitCoordinateMapping() throws {
        let viewport = RemoteViewportState()
        let frame = try XCTUnwrap(viewport.displayedFrame(
            viewSize: viewSize,
            framebufferSize: framebufferSize))

        XCTAssertEqual(frame.minX, 0, accuracy: 0.001)
        XCTAssertEqual(frame.minY, 218.75, accuracy: 0.001)
        XCTAssertEqual(frame.width, 1000, accuracy: 0.001)
        XCTAssertEqual(frame.height, 562.5, accuracy: 0.001)

        let center = try XCTUnwrap(viewport.framebufferPoint(
            for: CGPoint(x: 500, y: 500),
            viewSize: viewSize,
            framebufferSize: framebufferSize))
        XCTAssertEqual(center.x, 960, accuracy: 0.001)
        XCTAssertEqual(center.y, 540, accuracy: 0.001)
        XCTAssertNil(viewport.framebufferPoint(
            for: CGPoint(x: 500, y: 100),
            viewSize: viewSize,
            framebufferSize: framebufferSize))
    }

    func testNearMatchFillsTheViewExactly() throws {
        // Match Client rounds 1371×1022 points to 1368×1024 on its 8-point grid.
        let view = CGSize(width: 1371, height: 1022)
        let framebuffer = CGSize(width: 2736, height: 2048)
        let viewport = RemoteViewportState()
        let frame = try XCTUnwrap(viewport.displayedFrame(
            viewSize: view,
            framebufferSize: framebuffer))
        XCTAssertEqual(frame.minX, 0, accuracy: 0.001)
        XCTAssertEqual(frame.minY, 0, accuracy: 0.001)
        XCTAssertEqual(frame.width, view.width, accuracy: 0.001)
        XCTAssertEqual(frame.height, view.height, accuracy: 0.001)

        let topLeft = try XCTUnwrap(viewport.framebufferPoint(
            for: .zero,
            viewSize: view,
            framebufferSize: framebuffer))
        XCTAssertEqual(topLeft.x, 0, accuracy: 0.001)
        XCTAssertEqual(topLeft.y, 0, accuracy: 0.001)
        let bottomRight = try XCTUnwrap(viewport.framebufferPoint(
            for: CGPoint(x: view.width - 0.01, y: view.height - 0.01),
            viewSize: view,
            framebufferSize: framebuffer))
        XCTAssertEqual(bottomRight.x, framebuffer.width, accuracy: 0.1)
        XCTAssertEqual(bottomRight.y, framebuffer.height, accuracy: 0.1)
    }

    func testRealAspectMismatchStillLetterboxes() {
        // 16:10 desktop in a 4:3 pane.
        let scale = RemoteViewportState.fitScale(
            content: CGSize(width: 2560, height: 1600),
            into: CGSize(width: 1024, height: 768))
        XCTAssertEqual(scale.width, scale.height)
        XCTAssertEqual(scale.width, 0.4, accuracy: 0.0001)
    }

    func testNearMatchZoomRoundTrips() throws {
        let view = CGSize(width: 1371, height: 1022)
        let framebuffer = CGSize(width: 2736, height: 2048)
        var viewport = RemoteViewportState()
        viewport.zoom(
            by: 3,
            around: CGPoint(x: 400, y: 300),
            viewSize: view,
            framebufferSize: framebuffer)
        let remote = CGPoint(x: 1000, y: 700)
        let viewPoint = try XCTUnwrap(viewport.viewPoint(
            forFramebufferPoint: remote,
            viewSize: view,
            framebufferSize: framebuffer))
        let back = try XCTUnwrap(viewport.framebufferPoint(
            for: viewPoint,
            viewSize: view,
            framebufferSize: framebuffer))
        XCTAssertEqual(back.x, remote.x, accuracy: 0.001)
        XCTAssertEqual(back.y, remote.y, accuracy: 0.001)
    }

    func testNearestVisiblePointStaysOnTheDesktop() throws {
        let viewport = RemoteViewportState()
        // Right of the view, and below the letterboxed desktop.
        for outside in [CGPoint(x: 1400, y: 300), CGPoint(x: 500, y: 990), CGPoint(x: -50, y: -50)] {
            let pinned = try XCTUnwrap(viewport.nearestVisibleViewPoint(
                to: outside,
                viewSize: viewSize,
                framebufferSize: framebufferSize))
            let remote = try XCTUnwrap(viewport.framebufferPoint(
                for: pinned,
                viewSize: viewSize,
                framebufferSize: framebufferSize))
            XCTAssertLessThan(remote.x, framebufferSize.width)
            XCTAssertLessThan(remote.y, framebufferSize.height)
        }
        let corner = try XCTUnwrap(viewport.nearestVisibleViewPoint(
            to: CGPoint(x: 5000, y: 5000),
            viewSize: viewSize,
            framebufferSize: framebufferSize))
        let remoteCorner = try XCTUnwrap(viewport.framebufferPoint(
            for: corner,
            viewSize: viewSize,
            framebufferSize: framebufferSize))
        XCTAssertEqual(remoteCorner.x, framebufferSize.width - 0.5, accuracy: 0.001)
        XCTAssertEqual(remoteCorner.y, framebufferSize.height - 0.5, accuracy: 0.001)
        // A point already on the desktop is unchanged.
        XCTAssertEqual(viewport.nearestVisibleViewPoint(
            to: CGPoint(x: 400, y: 500),
            viewSize: viewSize,
            framebufferSize: framebufferSize), CGPoint(x: 400, y: 500))
    }

    func testNearestVisiblePointUsesTheVisiblePartWhenZoomed() throws {
        var viewport = RemoteViewportState()
        viewport.zoom(by: 3, around: CGPoint(x: 500, y: 500), viewSize: viewSize, framebufferSize: framebufferSize)
        let pinned = try XCTUnwrap(viewport.nearestVisibleViewPoint(
            to: CGPoint(x: 2000, y: 500),
            viewSize: viewSize,
            framebufferSize: framebufferSize))
        XCTAssertLessThan(pinned.x, viewSize.width)
        XCTAssertNotNil(viewport.framebufferPoint(
            for: pinned,
            viewSize: viewSize,
            framebufferSize: framebufferSize))
    }

    func testPinchKeepsRemotePixelUnderAnchor() throws {
        var viewport = RemoteViewportState()
        // Keep the requested offset within the pan bounds so clamping does
        // not intentionally move the anchor.
        let anchor = CGPoint(x: 250, y: 470)
        let before = try XCTUnwrap(viewport.framebufferPoint(
            for: anchor,
            viewSize: viewSize,
            framebufferSize: framebufferSize))

        viewport.zoom(
            by: 2,
            around: anchor,
            viewSize: viewSize,
            framebufferSize: framebufferSize)

        let after = try XCTUnwrap(viewport.framebufferPoint(
            for: anchor,
            viewSize: viewSize,
            framebufferSize: framebufferSize))
        XCTAssertEqual(viewport.scale, 2, accuracy: 0.001)
        XCTAssertEqual(after.x, before.x, accuracy: 0.001)
        XCTAssertEqual(after.y, before.y, accuracy: 0.001)
    }

    func testPanAllowsDesktopEdgesToReachViewportCenter() throws {
        var viewport = RemoteViewportState()
        viewport.zoom(
            by: 2,
            around: CGPoint(x: 500, y: 500),
            viewSize: viewSize,
            framebufferSize: framebufferSize)
        viewport.pan(
            by: CGSize(width: 10_000, height: 10_000),
            viewSize: viewSize,
            framebufferSize: framebufferSize)

        XCTAssertEqual(viewport.offset.width, 1_000, accuracy: 0.001)
        XCTAssertEqual(viewport.offset.height, 562.5, accuracy: 0.001)

        var frame = try XCTUnwrap(viewport.displayedFrame(
            viewSize: viewSize,
            framebufferSize: framebufferSize))
        XCTAssertEqual(frame.minX, viewSize.width / 2, accuracy: 0.001)
        XCTAssertEqual(frame.minY, viewSize.height / 2, accuracy: 0.001)

        viewport.pan(
            by: CGSize(width: -20_000, height: -20_000),
            viewSize: viewSize,
            framebufferSize: framebufferSize)

        XCTAssertEqual(viewport.offset.width, -1_000, accuracy: 0.001)
        XCTAssertEqual(viewport.offset.height, -562.5, accuracy: 0.001)
        frame = try XCTUnwrap(viewport.displayedFrame(
            viewSize: viewSize,
            framebufferSize: framebufferSize))
        XCTAssertEqual(frame.maxX, viewSize.width / 2, accuracy: 0.001)
        XCTAssertEqual(frame.maxY, viewSize.height / 2, accuracy: 0.001)

        viewport.reset()
        XCTAssertTrue(viewport.isIdentity)
    }

    func testAspectFitDesktopCanUseHalfViewportMargin() throws {
        var viewport = RemoteViewportState()
        viewport.pan(
            by: CGSize(width: 10_000, height: 10_000),
            viewSize: viewSize,
            framebufferSize: framebufferSize)

        let frame = try XCTUnwrap(viewport.displayedFrame(
            viewSize: viewSize,
            framebufferSize: framebufferSize))
        XCTAssertEqual(frame.minX, viewSize.width / 2, accuracy: 0.001)
        XCTAssertEqual(frame.minY, viewSize.height / 2, accuracy: 0.001)
    }

    func testPinchingInAtMinimumScaleRecentersDesktop() {
        var viewport = RemoteViewportState()
        viewport.pan(
            by: CGSize(width: 10_000, height: 10_000),
            viewSize: viewSize,
            framebufferSize: framebufferSize)
        XCTAssertFalse(viewport.isIdentity)

        viewport.zoom(
            by: 0.5,
            around: CGPoint(x: 900, y: 100),
            viewSize: viewSize,
            framebufferSize: framebufferSize)

        XCTAssertTrue(viewport.isIdentity)
    }

    func testPinchingDownToMinimumScaleRecentersDesktop() {
        var viewport = RemoteViewportState()
        viewport.zoom(
            by: 4,
            around: CGPoint(x: 250, y: 750),
            viewSize: viewSize,
            framebufferSize: framebufferSize)
        viewport.pan(
            by: CGSize(width: 300, height: -200),
            viewSize: viewSize,
            framebufferSize: framebufferSize)

        viewport.zoom(
            by: 0.01,
            around: CGPoint(x: 900, y: 100),
            viewSize: viewSize,
            framebufferSize: framebufferSize)

        XCTAssertTrue(viewport.isIdentity)
    }

    func testScaleIsBounded() {
        var viewport = RemoteViewportState()
        viewport.zoom(
            by: 100,
            around: .zero,
            viewSize: viewSize,
            framebufferSize: framebufferSize)
        XCTAssertEqual(viewport.scale, RemoteViewportState.maximumScale)
        XCTAssertEqual(viewport.scale, 10)

        viewport.zoom(
            by: 0.001,
            around: .zero,
            viewSize: viewSize,
            framebufferSize: framebufferSize)
        XCTAssertEqual(viewport.scale, RemoteViewportState.minimumScale)
    }

    func testEdgeScrollMovesTowardHiddenDesktop() {
        var viewport = RemoteViewportState()
        viewport.zoom(
            by: 2,
            around: CGPoint(x: 500, y: 500),
            viewSize: viewSize,
            framebufferSize: framebufferSize)

        let right = viewport.edgeScrollTranslation(
            for: CGPoint(x: 1_000, y: 500),
            viewSize: viewSize,
            framebufferSize: framebufferSize,
            elapsedTime: 0.1)
        XCTAssertEqual(right.width, -240, accuracy: 0.001)
        XCTAssertEqual(right.height, 0, accuracy: 0.001)

        let top = viewport.edgeScrollTranslation(
            for: CGPoint(x: 500, y: 0),
            viewSize: viewSize,
            framebufferSize: framebufferSize,
            elapsedTime: 0.1)
        XCTAssertEqual(top.width, 0, accuracy: 0.001)
        XCTAssertEqual(top.height, 240, accuracy: 0.001)
    }

    func testEdgeScrollAcceleratesInsideActivationInset() {
        var viewport = RemoteViewportState()
        viewport.zoom(
            by: 2,
            around: CGPoint(x: 500, y: 500),
            viewSize: viewSize,
            framebufferSize: framebufferSize)

        let halfway = viewport.edgeScrollTranslation(
            for: CGPoint(x: 12, y: 500),
            viewSize: viewSize,
            framebufferSize: framebufferSize,
            elapsedTime: 0.1)
        XCTAssertEqual(halfway.width, 120, accuracy: 0.001)

        let outsideInset = viewport.edgeScrollTranslation(
            for: CGPoint(x: 25, y: 500),
            viewSize: viewSize,
            framebufferSize: framebufferSize,
            elapsedTime: 0.1)
        XCTAssertEqual(outsideInset, .zero)
    }

    func testEdgeScrollUsesSameOverscrollLimitAsTwoFingerPan() throws {
        var viewport = RemoteViewportState()
        viewport.zoom(
            by: 2,
            around: CGPoint(x: 500, y: 500),
            viewSize: viewSize,
            framebufferSize: framebufferSize)
        viewport.pan(
            by: CGSize(width: -490, height: 0),
            viewSize: viewSize,
            framebufferSize: framebufferSize)

        let translation = viewport.edgeScrollTranslation(
            for: CGPoint(x: 1_000, y: 500),
            viewSize: viewSize,
            framebufferSize: framebufferSize,
            elapsedTime: 1)
        XCTAssertEqual(translation.width, -510, accuracy: 0.001)
        viewport.pan(
            by: translation,
            viewSize: viewSize,
            framebufferSize: framebufferSize)

        let frame = try XCTUnwrap(viewport.displayedFrame(
            viewSize: viewSize,
            framebufferSize: framebufferSize))
        XCTAssertEqual(frame.maxX, viewSize.width / 2, accuracy: 0.001)
        XCTAssertEqual(viewport.edgeScrollTranslation(
            for: CGPoint(x: 1_000, y: 500),
            viewSize: viewSize,
            framebufferSize: framebufferSize,
            elapsedTime: 1), .zero)
    }

    func testEdgeScrollDoesNotApplyAtFittedScale() {
        let viewport = RemoteViewportState()
        let translation = viewport.edgeScrollTranslation(
            for: CGPoint(x: 0, y: 100),
            viewSize: viewSize,
            framebufferSize: framebufferSize,
            elapsedTime: 1)
        XCTAssertEqual(translation, .zero)
    }

    func testContinuousPanningMapsPointerAcrossOverscrollRange() throws {
        var viewport = RemoteViewportState()
        viewport.zoom(
            by: 2,
            around: CGPoint(x: 500, y: 500),
            viewSize: viewSize,
            framebufferSize: framebufferSize)

        let pointer = CGPoint(x: 750, y: 250)
        let translation = viewport.cursorFollowingTranslation(
            for: pointer,
            viewSize: viewSize,
            framebufferSize: framebufferSize)
        XCTAssertEqual(translation.width, -500, accuracy: 0.001)
        XCTAssertEqual(translation.height, 281.25, accuracy: 0.001)

        viewport.pan(
            by: translation,
            viewSize: viewSize,
            framebufferSize: framebufferSize)
        XCTAssertEqual(viewport.offset.width, -500, accuracy: 0.001)
        XCTAssertEqual(viewport.offset.height, 281.25, accuracy: 0.001)
        // Zoomed frame is 2000x1125; after the pan its origin sits at
        // (-1000, 218.75), so the pointer lies 0.875 across and 31.25 points
        // into the desktop: x = 0.875 * 1920, y = 31.25 / 1125 * 1080.
        let remotePoint = try XCTUnwrap(viewport.framebufferPoint(
            for: pointer,
            viewSize: viewSize,
            framebufferSize: framebufferSize))
        XCTAssertEqual(remotePoint.x, 1_680, accuracy: 0.001)
        XCTAssertEqual(remotePoint.y, 30, accuracy: 0.001)
    }

    func testContinuousPanningDoesNotApplyAtFittedScale() {
        let viewport = RemoteViewportState()
        let translation = viewport.cursorFollowingTranslation(
            for: CGPoint(x: 900, y: 500),
            viewSize: viewSize,
            framebufferSize: framebufferSize)
        XCTAssertEqual(translation, .zero)
    }

    func testViewPointInvertsFramebufferMapping() throws {
        var viewport = RemoteViewportState()
        let fitted = try XCTUnwrap(viewport.viewPoint(
            forFramebufferPoint: CGPoint(x: 960, y: 540),
            viewSize: viewSize,
            framebufferSize: framebufferSize))
        XCTAssertEqual(fitted.x, 500, accuracy: 0.001)
        XCTAssertEqual(fitted.y, 500, accuracy: 0.001)

        viewport.zoom(
            by: 3,
            around: CGPoint(x: 500, y: 500),
            viewSize: viewSize,
            framebufferSize: framebufferSize)
        viewport.pan(
            by: CGSize(width: 200, height: -150),
            viewSize: viewSize,
            framebufferSize: framebufferSize)

        for remotePoint in [CGPoint(x: 960, y: 540),
                            CGPoint(x: 0, y: 0),
                            CGPoint(x: 1_200, y: 25)] {
            let point = try XCTUnwrap(viewport.viewPoint(
                forFramebufferPoint: remotePoint,
                viewSize: viewSize,
                framebufferSize: framebufferSize))
            let roundTrip = try XCTUnwrap(viewport.framebufferPoint(
                for: point,
                viewSize: viewSize,
                framebufferSize: framebufferSize))
            XCTAssertEqual(roundTrip.x, remotePoint.x, accuracy: 0.001)
            XCTAssertEqual(roundTrip.y, remotePoint.y, accuracy: 0.001)
        }

        // The zoomed desktop reaches well outside the viewport, and the
        // inverse has to report that rather than refusing the point.
        let offScreen = try XCTUnwrap(viewport.viewPoint(
            forFramebufferPoint: .zero,
            viewSize: viewSize,
            framebufferSize: framebufferSize))
        XCTAssertEqual(offScreen.x, -800, accuracy: 0.001)
        XCTAssertEqual(offScreen.y, -493.75, accuracy: 0.001)

        XCTAssertNil(viewport.viewPoint(
            forFramebufferPoint: .zero,
            viewSize: .zero,
            framebufferSize: framebufferSize))
    }

    func testFramebufferPixelsPerPointTracksZoom() throws {
        var viewport = RemoteViewportState()
        let fitted = try XCTUnwrap(viewport.framebufferPixelsPerPoint(
            viewSize: viewSize,
            framebufferSize: framebufferSize))
        XCTAssertEqual(fitted, 1.92, accuracy: 0.001)

        viewport.zoom(
            by: 3,
            around: CGPoint(x: 500, y: 500),
            viewSize: viewSize,
            framebufferSize: framebufferSize)
        let zoomed = try XCTUnwrap(viewport.framebufferPixelsPerPoint(
            viewSize: viewSize,
            framebufferSize: framebufferSize))
        XCTAssertEqual(zoomed, 0.64, accuracy: 0.001)

        XCTAssertNil(viewport.framebufferPixelsPerPoint(
            viewSize: .zero,
            framebufferSize: framebufferSize))
    }

    func testRevealDoesNothingInsideTheInsetOrAtFittedScale() {
        var viewport = RemoteViewportState()
        XCTAssertEqual(viewport.translationToReveal(
            viewPoint: CGPoint(x: -400, y: 500),
            viewSize: viewSize,
            framebufferSize: framebufferSize,
            inset: 24), .zero)

        viewport.zoom(
            by: 2,
            around: CGPoint(x: 500, y: 500),
            viewSize: viewSize,
            framebufferSize: framebufferSize)
        XCTAssertEqual(viewport.translationToReveal(
            viewPoint: CGPoint(x: 500, y: 500),
            viewSize: viewSize,
            framebufferSize: framebufferSize,
            inset: 24), .zero)
        XCTAssertEqual(viewport.translationToReveal(
            viewPoint: CGPoint(x: 24, y: 976),
            viewSize: viewSize,
            framebufferSize: framebufferSize,
            inset: 24), .zero)
    }

    func testRevealBringsAnOffscreenCursorInsideTheInset() throws {
        var viewport = RemoteViewportState()
        viewport.zoom(
            by: 2,
            around: CGPoint(x: 500, y: 500),
            viewSize: viewSize,
            framebufferSize: framebufferSize)

        let cursor = CGPoint(x: 100, y: 540)
        let before = try XCTUnwrap(viewport.viewPoint(
            forFramebufferPoint: cursor,
            viewSize: viewSize,
            framebufferSize: framebufferSize))
        XCTAssertLessThan(before.x, 24)

        let translation = viewport.translationToReveal(
            viewPoint: before,
            viewSize: viewSize,
            framebufferSize: framebufferSize,
            inset: 24)
        viewport.pan(
            by: translation,
            viewSize: viewSize,
            framebufferSize: framebufferSize)

        let after = try XCTUnwrap(viewport.viewPoint(
            forFramebufferPoint: cursor,
            viewSize: viewSize,
            framebufferSize: framebufferSize))
        XCTAssertEqual(after.x, 24, accuracy: 0.001)
        XCTAssertEqual(after.y, before.y, accuracy: 0.001)
        XCTAssertEqual(after.x - before.x, translation.width, accuracy: 0.001)
    }

    func testRevealReportsOnlyTheTranslationThePanLimitsAllow() {
        var viewport = RemoteViewportState()
        viewport.zoom(
            by: 2,
            around: CGPoint(x: 500, y: 500),
            viewSize: viewSize,
            framebufferSize: framebufferSize)

        // Far beyond any reachable position: the answer is the remaining
        // travel, so a caller panning by it is not promised movement the
        // clamp will refuse.
        let translation = viewport.translationToReveal(
            viewPoint: CGPoint(x: -5_000, y: 5_000),
            viewSize: viewSize,
            framebufferSize: framebufferSize,
            inset: 24)
        XCTAssertEqual(translation.width, 1_000, accuracy: 0.001)
        XCTAssertEqual(translation.height, -562.5, accuracy: 0.001)

        viewport.pan(
            by: translation,
            viewSize: viewSize,
            framebufferSize: framebufferSize)
        XCTAssertEqual(viewport.offset.width, 1_000, accuracy: 0.001)
        XCTAssertEqual(viewport.offset.height, -562.5, accuracy: 0.001)
        XCTAssertEqual(viewport.translationToReveal(
            viewPoint: CGPoint(x: -5_000, y: 5_000),
            viewSize: viewSize,
            framebufferSize: framebufferSize,
            inset: 24), .zero)
    }

    func testRevealCapsAnInsetWiderThanTheViewport() {
        var viewport = RemoteViewportState()
        viewport.zoom(
            by: 2,
            around: CGPoint(x: 500, y: 500),
            viewSize: viewSize,
            framebufferSize: framebufferSize)

        // An inset past the halfway mark collapses onto the center line
        // instead of inverting and pushing the point the wrong way.
        let translation = viewport.translationToReveal(
            viewPoint: CGPoint(x: 300, y: 500),
            viewSize: viewSize,
            framebufferSize: framebufferSize,
            inset: 600)
        XCTAssertEqual(translation.width, 200, accuracy: 0.001)
        XCTAssertEqual(translation.height, 0, accuracy: 0.001)
    }

    func testPerAxisRevealAppliesEachInsetToItsOwnAxis() {
        var viewport = RemoteViewportState()
        viewport.zoom(
            by: 2,
            around: CGPoint(x: 500, y: 500),
            viewSize: viewSize,
            framebufferSize: framebufferSize)

        // Inside the narrow horizontal margin but above the tall vertical one:
        // only the axis that is actually breached may move.
        let vertical = viewport.translationToReveal(
            viewPoint: CGPoint(x: 150, y: 300),
            viewSize: viewSize,
            framebufferSize: framebufferSize,
            horizontalInset: 100,
            verticalInset: 400)
        XCTAssertEqual(vertical.width, 0, accuracy: 0.001)
        XCTAssertEqual(vertical.height, 100, accuracy: 0.001)

        let horizontal = viewport.translationToReveal(
            viewPoint: CGPoint(x: 150, y: 300),
            viewSize: viewSize,
            framebufferSize: framebufferSize,
            horizontalInset: 400,
            verticalInset: 100)
        XCTAssertEqual(horizontal.width, 250, accuracy: 0.001)
        XCTAssertEqual(horizontal.height, 0, accuracy: 0.001)
    }

    func testPerAxisRevealMatchesTheSingleInsetFormWhenBothAgree() {
        var viewport = RemoteViewportState()
        viewport.zoom(
            by: 2,
            around: CGPoint(x: 500, y: 500),
            viewSize: viewSize,
            framebufferSize: framebufferSize)

        for point in [
            CGPoint(x: -5_000, y: 5_000),
            CGPoint(x: 10, y: 990),
            CGPoint(x: 500, y: 500),
        ] {
            XCTAssertEqual(
                viewport.translationToReveal(
                    viewPoint: point,
                    viewSize: viewSize,
                    framebufferSize: framebufferSize,
                    inset: 24),
                viewport.translationToReveal(
                    viewPoint: point,
                    viewSize: viewSize,
                    framebufferSize: framebufferSize,
                    horizontalInset: 24,
                    verticalInset: 24))
        }
    }

    func testPerAxisRevealCapsEachInsetIndependently() {
        var viewport = RemoteViewportState()
        viewport.zoom(
            by: 2,
            around: CGPoint(x: 500, y: 500),
            viewSize: viewSize,
            framebufferSize: framebufferSize)

        // One axis collapses onto its center line, the other is not inset at
        // all, and neither decision leaks into the other.
        let translation = viewport.translationToReveal(
            viewPoint: CGPoint(x: 300, y: 500),
            viewSize: viewSize,
            framebufferSize: framebufferSize,
            horizontalInset: 600,
            verticalInset: 0)
        XCTAssertEqual(translation.width, 200, accuracy: 0.001)
        XCTAssertEqual(translation.height, 0, accuracy: 0.001)
    }

    func testDeadZoneLetsTheCursorRoamTheMiddleBeforeTheDesktopMoves() throws {
        var viewport = RemoteViewportState()
        viewport.zoom(
            by: 2,
            around: CGPoint(x: 500, y: 500),
            viewSize: viewSize,
            framebufferSize: framebufferSize)

        let inset = viewSize.width * TrackpadFollowPolicy.deadZoneInsetFraction
        // Just inside the central 60%: the camera holds still.
        XCTAssertEqual(viewport.translationToReveal(
            viewPoint: CGPoint(x: inset + 1, y: 500),
            viewSize: viewSize,
            framebufferSize: framebufferSize,
            horizontalInset: inset,
            verticalInset: inset), .zero)

        // Past it, the desktop moves by exactly the overshoot.
        let translation = viewport.translationToReveal(
            viewPoint: CGPoint(x: inset - 30, y: 500),
            viewSize: viewSize,
            framebufferSize: framebufferSize,
            horizontalInset: inset,
            verticalInset: inset)
        XCTAssertEqual(translation.width, 30, accuracy: 0.001)
        XCTAssertEqual(translation.height, 0, accuracy: 0.001)
    }
}
