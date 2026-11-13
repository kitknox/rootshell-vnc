import XCTest
import CoreGraphics
@testable import rootshellVNC

@MainActor
final class ExternalDisplayOverrideTests: XCTestCase {
    private let phone = CGSize(width: 852, height: 393)
    private let rotatedPhone = CGSize(width: 393, height: 852)
    private let monitor = CGSize(width: 1920, height: 1080)

    private func makeSession() -> VNCSession {
        VNCSession(configuration: VNCConfiguration(
            videoQualityMode: .adaptive,
            displaySizingMode: .matchClient))
    }

    func testExternalDisplaySizeReplacesTheHostingViewSize() {
        let session = makeSession()
        session.updateRemoteDisplaySize(viewSize: phone, displayScale: 3)
        XCTAssertEqual(
            session.preparedClientDisplaySize,
            RemoteDisplaySize.matching(viewSize: phone))

        session.externalDisplayViewSize = monitor
        XCTAssertEqual(
            session.preparedClientDisplaySize,
            RemoteDisplaySize.matching(viewSize: monitor))
    }

    func testHostingViewChangesDoNotOverrideTheExternalDisplay() {
        let session = makeSession()
        session.externalDisplayViewSize = monitor
        // A rotation or keyboard change re-reports the device's geometry.
        session.updateRemoteDisplaySize(viewSize: rotatedPhone, displayScale: 3)
        XCTAssertEqual(
            session.preparedClientDisplaySize,
            RemoteDisplaySize.matching(viewSize: monitor))
    }

    func testClearingTheExternalDisplayRestoresTheLatestHostSize() {
        let session = makeSession()
        session.updateRemoteDisplaySize(viewSize: phone, displayScale: 3)
        session.externalDisplayViewSize = monitor
        session.updateRemoteDisplaySize(viewSize: rotatedPhone, displayScale: 3)

        session.externalDisplayViewSize = nil
        XCTAssertEqual(
            session.preparedClientDisplaySize,
            RemoteDisplaySize.matching(viewSize: rotatedPhone))
    }

    func testExternalDisplayAppliesWithoutAnyHostReport() {
        let session = makeSession()
        session.externalDisplayViewSize = monitor
        XCTAssertEqual(
            session.preparedClientDisplaySize,
            RemoteDisplaySize.matching(viewSize: monitor))
    }

    func testSuspendedUpdatesApplyTheExternalDisplayOnResume() {
        let session = makeSession()
        session.updateRemoteDisplaySize(viewSize: phone, displayScale: 3)
        session.suspendsRemoteDisplaySizeUpdates = true

        session.externalDisplayViewSize = monitor
        XCTAssertEqual(
            session.preparedClientDisplaySize,
            RemoteDisplaySize.matching(viewSize: phone),
            "An occluded host defers every resize, including this one")

        session.suspendsRemoteDisplaySizeUpdates = false
        XCTAssertEqual(
            session.preparedClientDisplaySize,
            RemoteDisplaySize.matching(viewSize: monitor))
    }

    func testBackingScaleIsTwoOnlyForHighPerformanceMatchClient() {
        let session = makeSession()
        session.externalDisplayViewSize = monitor
        XCTAssertEqual(session.presentedBackingScale, 1)

        session.isHighPerformanceMode = true
        XCTAssertEqual(session.presentedBackingScale, 2)

        let remoteDisplay = VNCSession(configuration: VNCConfiguration(
            videoQualityMode: .adaptive,
            displaySizingMode: .remoteDisplay))
        remoteDisplay.isHighPerformanceMode = true
        XCTAssertEqual(remoteDisplay.presentedBackingScale, 1)
    }
}
