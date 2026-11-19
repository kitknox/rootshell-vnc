import ImageIO
import RFBProtocol
import XCTest
@testable import rootshellVNC

@MainActor
final class VNCClipboardSynchronizerTests: XCTestCase {
    private final class FakeClipboard: VNCClipboardProviding {
        var changeCount = 0
        let remoteWrites = VNCClipboardRemoteWrites()
        var content: VNCClipboardContent?

        var text: String? { content?.plainText }

        func hasTransferableContent(for support: VNCClipboardContentSupport) -> Bool {
            readContent(for: support) != nil
        }

        func readContent(for support: VNCClipboardContentSupport) -> VNCClipboardContent? {
            guard let content else { return nil }
            let accepted = content.filtered { support.accepts($0.type) }
            return accepted.isEmpty ? nil : accepted
        }

        func write(_ content: VNCClipboardContent) {
            self.content = content
            changeCount += 1
        }

        func copyOnDevice(_ text: String?) {
            copyOnDevice(text.map(VNCClipboardContent.text))
        }

        func copyOnDevice(_ content: VNCClipboardContent?) {
            self.content = content
            changeCount += 1
        }
    }

    private func appleRequestIDs() -> () -> UInt32? {
        var id: UInt32 = 0x8000_0000
        return {
            id += 1
            return id
        }
    }

    private func makeSynchronizer(
        clipboard: FakeClipboard,
        connected: @escaping () -> Bool = { true },
        contentSupport: @escaping () -> VNCClipboardContentSupport = { .all },
        automaticallyMonitors: Bool = false,
        canRequestRemoteClipboard: @escaping () -> Bool = { false },
        requestRemoteClipboard: @escaping () -> Void = {},
        requestAppleClipboard: @escaping () -> UInt32? = { nil },
        now: @escaping () -> ContinuousClock.Instant = { .now },
        canControlRemoteSharedClipboard: @escaping () -> Bool = { false },
        setRemoteSharedClipboard: @escaping (Bool) -> Void = { _ in },
        notificationCenter: NotificationCenter = NotificationCenter(),
        clipboardChangeNotification: Notification.Name? = nil,
        sendContent: ((VNCClipboardContent) -> Void)? = nil,
        send: @escaping (String) -> Void
    ) -> VNCClipboardSynchronizer {
        VNCClipboardSynchronizer(
            clipboard: clipboard,
            canSend: connected,
            send: { content in
                sendContent?(content)
                if let text = content.plainText { send(text) }
            },
            contentSupport: contentSupport,
            canRequestRemoteClipboard: canRequestRemoteClipboard,
            requestRemoteClipboard: requestRemoteClipboard,
            requestAppleClipboard: requestAppleClipboard, now: now,
            canControlRemoteSharedClipboard: canControlRemoteSharedClipboard,
            setRemoteSharedClipboard: setRemoteSharedClipboard,
            notificationCenter: notificationCenter,
            observesApplicationLifecycle: false,
            automaticallyMonitors: automaticallyMonitors,
            clipboardChangeNotification: clipboardChangeNotification)
    }

    func testManualGetUsesLatestRemoteClipboardWhileSharingIsOff() {
        let clipboard = FakeClipboard()
        var sent: [String] = []
        let synchronizer = makeSynchronizer(clipboard: clipboard) { sent.append($0) }

        synchronizer.receiveRemoteClipboardText("remote value")

        XCTAssertTrue(synchronizer.hasRemoteClipboard)
        XCTAssertNil(clipboard.text)

        synchronizer.getClipboard()

        XCTAssertEqual(clipboard.text, "remote value")
        XCTAssertTrue(sent.isEmpty)
    }

    func testManualGetCanClearTheDeviceClipboard() {
        let clipboard = FakeClipboard()
        clipboard.copyOnDevice("old value")
        let synchronizer = makeSynchronizer(clipboard: clipboard) { _ in }

        synchronizer.receiveRemoteClipboardText("")
        synchronizer.getClipboard()

        XCTAssertEqual(clipboard.text, "")
    }

    func testAppleManualGetRequestsCurrentClipboardAndAppliesResponse() {
        let clipboard = FakeClipboard()
        clipboard.copyOnDevice("local value")
        var requestCount = 0
        let synchronizer = makeSynchronizer(
            clipboard: clipboard,
            canRequestRemoteClipboard: { true },
            requestRemoteClipboard: { requestCount += 1 }
        ) { _ in }

        XCTAssertTrue(synchronizer.canGetClipboard)
        synchronizer.getClipboard()

        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(clipboard.text, "local value")

        synchronizer.receiveRemoteClipboardText("current remote value")
        XCTAssertEqual(clipboard.text, "current remote value")
    }

    func testStandardServerGetRequiresPublishedClipboard() {
        let clipboard = FakeClipboard()
        let synchronizer = makeSynchronizer(clipboard: clipboard) { _ in }

        XCTAssertFalse(synchronizer.canGetClipboard)
        synchronizer.receiveRemoteClipboardText("published remote value")
        XCTAssertTrue(synchronizer.canGetClipboard)
    }

    func testSharedModeControlsCapableAppleServer() {
        let clipboard = FakeClipboard()
        var remoteStates: [Bool] = []
        let synchronizer = makeSynchronizer(
            clipboard: clipboard,
            canControlRemoteSharedClipboard: { true },
            setRemoteSharedClipboard: { remoteStates.append($0) }
        ) { _ in }

        synchronizer.sharedClipboardEnabled = true
        synchronizer.sharedClipboardEnabled = false

        XCTAssertEqual(remoteStates, [true, false])
    }

    func testManualSendRequiresConnectionAndClipboardContent() {
        let clipboard = FakeClipboard()
        var connected = false
        var sent: [String] = []
        let synchronizer = makeSynchronizer(
            clipboard: clipboard,
            connected: { connected }
        ) { sent.append($0) }

        synchronizer.sendClipboard()
        clipboard.copyOnDevice("device value")
        synchronizer.sendClipboard()
        XCTAssertTrue(sent.isEmpty)

        connected = true
        synchronizer.sendClipboard()
        XCTAssertEqual(sent, ["device value"])
    }

    func testEnablingSharedClipboardWaitsForNextChange() {
        let clipboard = FakeClipboard()
        clipboard.copyOnDevice("existing local")
        var sent: [String] = []
        let synchronizer = makeSynchronizer(clipboard: clipboard) { sent.append($0) }
        synchronizer.receiveRemoteClipboardText("existing remote")

        synchronizer.sharedClipboardEnabled = true

        XCTAssertEqual(clipboard.text, "existing local")
        XCTAssertTrue(sent.isEmpty)
    }

    func testSharedClipboardTransfersBothDirectionsWithoutEcho() {
        let clipboard = FakeClipboard()
        var sent: [String] = []
        let synchronizer = makeSynchronizer(clipboard: clipboard) { sent.append($0) }
        synchronizer.sharedClipboardEnabled = true

        synchronizer.receiveRemoteClipboardText("from remote")
        synchronizer.localClipboardDidChange()

        XCTAssertEqual(clipboard.text, "from remote")
        XCTAssertTrue(sent.isEmpty, "A remote pasteboard write must not echo back")

        clipboard.copyOnDevice("from device")
        synchronizer.localClipboardDidChange()

        XCTAssertEqual(sent, ["from device"])
    }

    func testLocalChangeDuringReconnectIsRetriedWhenConnected() {
        let clipboard = FakeClipboard()
        var connected = false
        var sent: [String] = []
        let synchronizer = makeSynchronizer(
            clipboard: clipboard,
            connected: { connected }
        ) { sent.append($0) }
        synchronizer.sharedClipboardEnabled = true

        synchronizer.connectionStateDidChange(.reconnecting(attempt: 1, delay: 0))
        clipboard.copyOnDevice("copied while reconnecting")
        synchronizer.localClipboardDidChange()
        XCTAssertTrue(sent.isEmpty)

        connected = true
        synchronizer.connectionStateDidChange(.connected)

        XCTAssertEqual(sent, ["copied while reconnecting"])
    }

    func testConnectionBoundaryClearsCachedRemoteClipboard() {
        let clipboard = FakeClipboard()
        let synchronizer = makeSynchronizer(clipboard: clipboard) { _ in }
        synchronizer.receiveRemoteClipboardText("clipboard from first server")
        XCTAssertTrue(synchronizer.hasRemoteClipboard)

        synchronizer.connectionStateDidChange(.connecting)

        XCTAssertFalse(synchronizer.hasRemoteClipboard)
        synchronizer.getClipboard()
        XCTAssertNil(clipboard.text)
    }

    func testUnfocusedPaneCachesWithoutReplayingOrBridging() {
        let clipboard = FakeClipboard()
        var sent: [String] = []
        let synchronizer = makeSynchronizer(clipboard: clipboard) { sent.append($0) }
        synchronizer.sharedClipboardEnabled = true
        synchronizer.setHostFocused(false)

        synchronizer.receiveRemoteClipboardText("inactive remote")
        clipboard.copyOnDevice("active pane value")
        synchronizer.localClipboardDidChange()

        synchronizer.setHostFocused(true)

        XCTAssertEqual(clipboard.text, "active pane value")
        XCTAssertTrue(sent.isEmpty)

        synchronizer.receiveRemoteClipboardText("new focused remote")
        XCTAssertEqual(clipboard.text, "new focused remote")
    }

    func testMacCopyCanBePastedAfterAnImmediateAppSwitch() {
        for windowResignsFirst in [false, true] {
            let clipboard = FakeClipboard()
            var requests = 0
            var sent: [String] = []
            let sync = makeSynchronizer(
                clipboard: clipboard, canRequestRemoteClipboard: { true },
                requestAppleClipboard: {
                    requests += 1
                    return 0x8000_0000 + UInt32(requests)
                }) { sent.append($0) }
            sync.sharedClipboardEnabled = true
            sync.remoteKeyEvent(down: true, key: KeyboardInputHandler.keysymSuperL)
            sync.remoteKeyEvent(down: true, key: 0x63)
            sync.handleClipboardEvent(.reply(0x8000_0001, .text("before copy")))
            if windowResignsFirst { sync.setHostWindowActive(false) }
            sync.applicationWillResignActive()
            sync.setHostWindowActive(false)
            sync.remoteKeyEvent(down: false, key: 0x63)
            XCTAssertEqual(requests, 2)

            sync.handleClipboardEvent(.reply(0x8000_0002, .text("first reply")))
            sync.handleClipboardEvent(.requestStarted(2, changeNotice: true))
            sync.handleClipboardEvent(.reply(2, .text("latest remote copy")))
            XCTAssertEqual(clipboard.text, "latest remote copy")
            sync.applicationDidBecomeActive()
            sync.setHostWindowActive(true)
            XCTAssertTrue(sent.isEmpty)
        }
    }

    func testCopyReplyBetweenWindowAndAppResignationIsAppliedOnDeparture() {
        let clipboard = FakeClipboard()
        clipboard.copyOnDevice("original")
        var sent: [String] = []
        let sync = makeSynchronizer(
            clipboard: clipboard, canRequestRemoteClipboard: { true },
            requestAppleClipboard: appleRequestIDs()) { sent.append($0) }
        sync.sharedClipboardEnabled = true
        sync.remoteKeyEvent(down: true, key: KeyboardInputHandler.keysymSuperL)
        sync.remoteKeyEvent(down: true, key: 0x63)
        sync.handleClipboardEvent(.reply(0x8000_0001, .text("before copy")))
        sync.setHostWindowActive(false)
        sync.handleClipboardEvent(.reply(0x8000_0002, .text("first")))
        sync.handleClipboardEvent(.requestStarted(2, changeNotice: true))
        sync.handleClipboardEvent(.reply(2, .text("second")))
        XCTAssertEqual(clipboard.text, "original")
        sync.applicationWillResignActive()
        XCTAssertEqual(clipboard.text, "second")
        sync.applicationDidBecomeActive()
        sync.setHostWindowActive(true)
        XCTAssertTrue(sent.isEmpty)
    }

    func testLocalCopyBeforeResignationCannotBeReplacedOnReturn() {
        for alreadySent in [false, true] {
            let clipboard = FakeClipboard()
            var sent: [String] = []
            let sync = makeSynchronizer(
                clipboard: clipboard, canRequestRemoteClipboard: { true },
            requestAppleClipboard: appleRequestIDs()) { sent.append($0) }
            sync.sharedClipboardEnabled = true
            sync.remoteKeyEvent(down: true, key: KeyboardInputHandler.keysymSuperR)
            sync.remoteKeyEvent(down: true, key: 0x63)
            sync.handleClipboardEvent(.reply(0x8000_0001, .text("before copy")))
            sync.remoteKeyEvent(down: false, key: 0x63)
            clipboard.copyOnDevice("new local")
            if alreadySent { sync.localClipboardDidChange() }
            sync.applicationWillResignActive()
            sync.handleClipboardEvent(.reply(0x8000_0002, .text("late remote")))
            XCTAssertEqual(clipboard.text, "new local")
            sync.applicationDidBecomeActive()
            XCTAssertEqual(clipboard.text, "new local")
            XCTAssertEqual(sent, ["new local"])
        }
    }

    func testOtherWindowTakingFocusRevokesPendingCopyAcrossAppSwitch() {
        let clipboard = FakeClipboard()
        clipboard.copyOnDevice("original")
        let a = makeSynchronizer(clipboard: clipboard, canRequestRemoteClipboard: { true },
            requestAppleClipboard: appleRequestIDs()) { _ in }
        let b = makeSynchronizer(clipboard: clipboard, canRequestRemoteClipboard: { true },
            requestAppleClipboard: appleRequestIDs()) { _ in }
        b.setHostWindowActive(false)
        a.sharedClipboardEnabled = true
        b.sharedClipboardEnabled = true
        a.remoteKeyEvent(down: true, key: KeyboardInputHandler.keysymSuperL)
        a.remoteKeyEvent(down: true, key: 0x63)
        a.handleClipboardEvent(.reply(0x8000_0001, .text("before copy")))
        a.setHostWindowActive(false)
        a.handleClipboardEvent(.reply(0x8000_0002, .text("early A")))
        a.handleClipboardEvent(.requestStarted(2, changeNotice: true))
        b.setHostWindowActive(true)
        a.applicationWillResignActive()
        b.applicationWillResignActive()
        XCTAssertEqual(clipboard.text, "original")
        a.handleClipboardEvent(.reply(2, .text("late A")))
        XCTAssertEqual(clipboard.text, "original")
        b.applicationDidBecomeActive()
        a.applicationDidBecomeActive()
        b.setHostWindowActive(false)
        a.setHostWindowActive(true)
        XCTAssertEqual(clipboard.text, "original")
    }

    func testRemoteMenuCopyFetchesOnDepartureAndOrdinaryClickPreservesLocalClipboard() {
        for didCopy in [false, true] {
            let clipboard = FakeClipboard()
            clipboard.copyOnDevice("initial local")
            var requests = 0
            let sync = makeSynchronizer(
                clipboard: clipboard, canRequestRemoteClipboard: { true },
                requestAppleClipboard: {
                    requests += 1
                    return 0x8000_0000 + UInt32(requests)
                }) { _ in }
            sync.sharedClipboardEnabled = true
            sync.remotePointerWillSend(buttonMask: 1)
            sync.handleClipboardEvent(.reply(0x8000_0001, .text("initial remote")))
            sync.remotePointerWillSend(buttonMask: 0)
            XCTAssertEqual(clipboard.text, "initial local")
            sync.applicationWillResignActive()
            XCTAssertEqual(requests, 2)
            sync.handleClipboardEvent(.reply(0x8000_0002, .text(didCopy ? "menu copy" : "initial remote")))
            XCTAssertEqual(clipboard.text, didCopy ? "menu copy" : "initial local")
            sync.applicationDidBecomeActive()
            XCTAssertEqual(clipboard.text, didCopy ? "menu copy" : "initial local")
        }
    }

    func testCommandCWithoutSelectionPreservesDeviceClipboardWhileActive() {
        let clipboard = FakeClipboard()
        clipboard.copyOnDevice("L")
        let count = clipboard.changeCount
        let sync = makeSynchronizer(
            clipboard: clipboard, canRequestRemoteClipboard: { true },
            requestAppleClipboard: appleRequestIDs()) { _ in }
        sync.sharedClipboardEnabled = true
        sync.remoteKeyEvent(down: true, key: KeyboardInputHandler.keysymSuperL)
        sync.remoteKeyEvent(down: true, key: 0x63)
        sync.handleClipboardEvent(.reply(0x8000_0001, .text("A")))
        sync.remoteKeyEvent(down: false, key: 0x63)
        sync.handleClipboardEvent(.reply(0x8000_0002, .text("A")))
        XCTAssertEqual(clipboard.text, "L")
        XCTAssertEqual(clipboard.changeCount, count)
        // Copying the same text deliberately still produces a server notice.
        sync.handleClipboardEvent(.requestStarted(1, changeNotice: true))
        sync.handleClipboardEvent(.reply(1, .text("A")))
        XCTAssertEqual(clipboard.text, "A")
    }

    func testUnannouncedSnapshotWaitsForBaselineInEitherReplyOrder() {
        for keyboard in [false, true] {
            for baselineFirst in [false, true] {
                for baseline in [nil, "A", "B"] as [String?] {
                    let clipboard = FakeClipboard()
                    clipboard.copyOnDevice("local")
                    let count = clipboard.changeCount
                    let sync = makeSynchronizer(
                        clipboard: clipboard, canRequestRemoteClipboard: { true },
                        requestAppleClipboard: appleRequestIDs()) { _ in }
                    sync.sharedClipboardEnabled = true
                    if keyboard {
                        sync.remoteKeyEvent(down: true, key: KeyboardInputHandler.keysymSuperL)
                        sync.remoteKeyEvent(down: true, key: 0x63)
                    } else {
                        sync.remotePointerWillSend(buttonMask: 1)
                    }
                    sync.applicationWillResignActive()
                    let before = VNCSession.ClipboardEvent.reply(0x8000_0001, baseline.map(VNCClipboardContent.text))
                    if baselineFirst { sync.handleClipboardEvent(before) }
                    sync.handleClipboardEvent(.reply(0x8000_0002, .text("A")))
                    if !baselineFirst {
                        XCTAssertEqual(clipboard.changeCount, count)
                        sync.handleClipboardEvent(before)
                    }
                    XCTAssertEqual(clipboard.text, baseline == "A" ? "local" : "A")
                    XCTAssertEqual(clipboard.changeCount, baseline == "A" ? count : count + 1)
                }
            }
        }
    }

    func testMenuCopyNoticeCompletesWithoutBaselineReply() {
        let clipboard = FakeClipboard()
        clipboard.copyOnDevice("local")
        let sync = makeSynchronizer(
            clipboard: clipboard, canRequestRemoteClipboard: { true },
            requestAppleClipboard: appleRequestIDs()) { _ in }
        sync.sharedClipboardEnabled = true
        sync.remotePointerWillSend(buttonMask: 1)
        sync.applicationWillResignActive()
        sync.handleClipboardEvent(.reply(0x8000_0002, .text("first copy")))
        XCTAssertEqual(clipboard.text, "local")
        sync.handleClipboardEvent(.requestStarted(3, changeNotice: true))
        sync.handleClipboardEvent(.reply(3, .text("first copy")))
        XCTAssertEqual(clipboard.text, "first copy")
    }

    func testOnlyNewestAnnouncedClipboardWritesInEitherReplyOrder() {
        for newerFirst in [false, true] {
            let clipboard = FakeClipboard()
            clipboard.copyOnDevice("original")
            let sync = makeSynchronizer(
                clipboard: clipboard, canRequestRemoteClipboard: { true },
                requestAppleClipboard: appleRequestIDs()) { _ in }
            sync.sharedClipboardEnabled = true
            sync.remoteKeyEvent(down: true, key: KeyboardInputHandler.keysymSuperL)
            sync.remoteKeyEvent(down: true, key: 0x63)
            sync.handleClipboardEvent(.reply(0x8000_0001, .text("before copy")))
            sync.remoteKeyEvent(down: false, key: 0x63)
            sync.handleClipboardEvent(.requestStarted(1, changeNotice: true))
            sync.handleClipboardEvent(.requestStarted(2, changeNotice: true))
            if newerFirst { sync.handleClipboardEvent(.reply(2, .text("B"))) }
            sync.handleClipboardEvent(.reply(1, .text("A")))
            XCTAssertEqual(clipboard.text, newerFirst ? "B" : "original")
            if !newerFirst { sync.handleClipboardEvent(.reply(2, .text("B"))) }
            XCTAssertEqual(clipboard.text, "B")
        }
    }

    func testClickDuringDownloadOrNormalizationPreservesAcceptedImage() async throws {
        let tiff = VNCClipboardContent(items: [[.init(
            type: ClipboardType.tiff, data: try Self.imageData(type: "public.tiff"))]])
        for clickBeforeReply in [true, false] {
            let clipboard = FakeClipboard()
            var id: UInt32 = 0x8000_0000
            let sync = makeSynchronizer(
                clipboard: clipboard, canRequestRemoteClipboard: { true },
                requestAppleClipboard: {
                    id += 1
                    return id
                }) { _ in }
            sync.sharedClipboardEnabled = true
            sync.remoteKeyEvent(down: true, key: KeyboardInputHandler.keysymSuperL)
            sync.remoteKeyEvent(down: true, key: 0x63)
            sync.handleClipboardEvent(.reply(0x8000_0001, .text("before copy")))
            sync.remoteKeyEvent(down: false, key: 0x63)
            if clickBeforeReply { sync.remotePointerWillSend(buttonMask: 1) }
            sync.handleClipboardEvent(.reply(0x8000_0002, tiff))
            if !clickBeforeReply { sync.remotePointerWillSend(buttonMask: 1) }
            sync.applicationWillResignActive()
            let written = await Self.waitUntil { clipboard.content?.contains(type: ClipboardType.png) == true }
            XCTAssertTrue(written)
        }
    }

    func testClickAfterReducedUploadPreservesFullLocalClipboard() {
        let clipboard = FakeClipboard()
        var id: UInt32 = 0x8000_0000
        let sync = makeSynchronizer(
            clipboard: clipboard, canRequestRemoteClipboard: { true },
            requestAppleClipboard: {
                id += 1
                return id
            }) { _ in }
        sync.sharedClipboardEnabled = true
        let full = VNCClipboardContent(items: [[
            .init(type: ClipboardType.png, data: Data([1, 2, 3])),
            .init(type: ClipboardType.utf8PlainText, data: Data("label".utf8))
        ]])
        clipboard.copyOnDevice(full)
        sync.localClipboardDidChange()
        let count = clipboard.changeCount
        sync.remotePointerWillSend(buttonMask: 1)
        sync.handleClipboardEvent(.reply(0x8000_0001, .text("label")))
        sync.applicationWillResignActive()
        sync.handleClipboardEvent(.reply(0x8000_0002, .text("label")))
        XCTAssertEqual(clipboard.content, full)
        XCTAssertEqual(clipboard.changeCount, count)
    }

    func testPointerBaselineBelongsToCurrentSharingInterval() {
        let clipboard = FakeClipboard()
        var id: UInt32 = 0x8000_0000
        let sync = makeSynchronizer(
            clipboard: clipboard, canRequestRemoteClipboard: { true },
            requestAppleClipboard: {
                    id += 1
                    return id
                }) { _ in }
        sync.sharedClipboardEnabled = true
        sync.remotePointerWillSend(buttonMask: 1)
        sync.receiveRemoteClipboardText("A")
        sync.sharedClipboardEnabled = false
        clipboard.copyOnDevice("L")
        sync.sharedClipboardEnabled = true
        sync.remotePointerWillSend(buttonMask: 1)
        sync.applicationWillResignActive()
        sync.handleClipboardEvent(.reply(0x8000_0001, .text("A")))
        sync.handleClipboardEvent(.reply(0x8000_0002, .text("B")))
        sync.handleClipboardEvent(.reply(0x8000_0003, .text("B")))
        XCTAssertEqual(id, 0x8000_0003)
        XCTAssertEqual(clipboard.text, "L")
    }

    func testSlowAppleClipboardDownloadAndNormalizationFinishAfterDeparture() async throws {
        let tiff = VNCClipboardContent(items: [[.init(
            type: ClipboardType.tiff, data: try Self.imageData(type: "public.tiff"))]])
        for announced in [false, true] {
            let clipboard = FakeClipboard()
            var instant = ContinuousClock.now
            let sync = makeSynchronizer(
                clipboard: clipboard, canRequestRemoteClipboard: { true },
                requestAppleClipboard: appleRequestIDs(), now: { instant }) { _ in }
            sync.sharedClipboardEnabled = true
            sync.remoteKeyEvent(down: true, key: KeyboardInputHandler.keysymSuperL)
            sync.remoteKeyEvent(down: true, key: 0x63)
            sync.handleClipboardEvent(.reply(0x8000_0001, .text("before copy")))
            sync.remoteKeyEvent(down: false, key: 0x63)
            sync.applicationWillResignActive()
            sync.handleClipboardEvent(.reply(99, .text("unrelated early reply")))
            XCTAssertNil(clipboard.content)
            if announced {
                sync.handleClipboardEvent(.requestStarted(42, changeNotice: true))
                sync.handleClipboardEvent(.reply(0x8000_0002, .text("superseded snapshot")))
                XCTAssertNil(clipboard.content)
            }
            instant += .seconds(10)
            sync.handleClipboardEvent(.reply(announced ? 42 : 0x8000_0002, tiff))
            instant += .seconds(10)
            let written = await Self.waitUntil { clipboard.content?.contains(type: ClipboardType.png) == true }
            XCTAssertTrue(written)
            let count = clipboard.changeCount
            sync.handleClipboardEvent(.reply(99, .text("unrelated later update")))
            XCTAssertEqual(clipboard.changeCount, count)
        }
    }

    func testLateMatchedDownloadStillYieldsToLocalCopy() {
        let clipboard = FakeClipboard()
        var instant = ContinuousClock.now
        let sync = makeSynchronizer(
            clipboard: clipboard, canRequestRemoteClipboard: { true },
            requestAppleClipboard: appleRequestIDs(), now: { instant }) { _ in }
        sync.sharedClipboardEnabled = true
        sync.remoteKeyEvent(down: true, key: KeyboardInputHandler.keysymSuperL)
        sync.remoteKeyEvent(down: true, key: 0x63)
        sync.handleClipboardEvent(.reply(0x8000_0001, .text("before copy")))
        sync.applicationWillResignActive()
        instant += .seconds(10)
        clipboard.copyOnDevice("newer local")
        sync.handleClipboardEvent(.reply(0x8000_0002, .text("late")))
        sync.applicationDidBecomeActive()
        XCTAssertEqual(clipboard.text, "newer local")
    }

    func testCopyReplyBetweenAppAndWindowActivationIsAppliedOnReturn() {
        for localCopy in [false, true] {
            let clipboard = FakeClipboard()
            clipboard.copyOnDevice("original")
            let sync = makeSynchronizer(
                clipboard: clipboard, canRequestRemoteClipboard: { true },
                requestAppleClipboard: appleRequestIDs()) { _ in }
            sync.sharedClipboardEnabled = true
            sync.remoteKeyEvent(down: true, key: KeyboardInputHandler.keysymSuperL)
            sync.remoteKeyEvent(down: true, key: 0x63)
            sync.handleClipboardEvent(.reply(0x8000_0001, .text("before copy")))
            sync.applicationWillResignActive()
            sync.setHostWindowActive(false)
            sync.applicationDidBecomeActive()
            sync.handleClipboardEvent(.reply(0x8000_0002, .text("remote copy")))
            XCTAssertEqual(clipboard.text, "original")
            if localCopy { clipboard.copyOnDevice("new local") }
            sync.setHostWindowActive(true)
            XCTAssertEqual(clipboard.text, localCopy ? "new local" : "remote copy")
            let count = clipboard.changeCount
            sync.applicationWillResignActive()
            XCTAssertEqual(clipboard.changeCount, count)
        }
    }

    func testNoticeBeforeLocalUploadCannotOverwriteLocalCopy() {
        for uploadAlreadyQueued in [false, true] {
            let clipboard = FakeClipboard()
            clipboard.copyOnDevice("original")
            var sent: [String] = []
            let sync = makeSynchronizer(
                clipboard: clipboard, canRequestRemoteClipboard: { true },
                requestAppleClipboard: appleRequestIDs()) { sent.append($0) }
            sync.sharedClipboardEnabled = true
            sync.remoteKeyEvent(down: true, key: KeyboardInputHandler.keysymSuperL)
            sync.remoteKeyEvent(down: true, key: 0x63)
            sync.handleClipboardEvent(.reply(0x8000_0001, .text("before copy")))
            sync.remoteKeyEvent(down: false, key: 0x63)
            clipboard.copyOnDevice("new local")
            if uploadAlreadyQueued { sync.localClipboardDidChange() }
            sync.handleClipboardEvent(.requestStarted(1, changeNotice: true, localUploadPending: uploadAlreadyQueued))
            sync.handleClipboardEvent(.reply(1, .text("old remote")))
            sync.handleClipboardEvent(.reply(0x8000_0002, .text("old remote")))
            XCTAssertEqual(clipboard.text, "new local")
            XCTAssertEqual(sent, ["new local"])
            sync.handleClipboardEvent(.requestStarted(2, changeNotice: true))
            sync.handleClipboardEvent(.reply(2, .text("subsequent remote copy")))
            XCTAssertEqual(clipboard.text, "subsequent remote copy")
        }
    }

    func testLateNoticeFinishesSilentKeyboardFetchDuringAppSwitch() {
        let clipboard = FakeClipboard()
        clipboard.copyOnDevice("original")
        var instant = ContinuousClock.now
        let sync = makeSynchronizer(
            clipboard: clipboard, canRequestRemoteClipboard: { true },
            requestAppleClipboard: appleRequestIDs(), now: { instant }) { _ in }
        sync.sharedClipboardEnabled = true
        sync.remoteKeyEvent(down: true, key: KeyboardInputHandler.keysymSuperL)
        sync.remoteKeyEvent(down: true, key: 0x63)
        sync.handleClipboardEvent(.reply(0x8000_0001, .text("before copy")))
        sync.applicationWillResignActive()
        instant += .seconds(10)
        sync.handleClipboardEvent(.requestStarted(2, changeNotice: true))
        sync.handleClipboardEvent(.reply(2, .text("newer notice")))
        XCTAssertEqual(clipboard.text, "newer notice")
        // An empty response, if it eventually arrives, cannot undo the announced copy.
        let count = clipboard.changeCount
        sync.handleClipboardEvent(.reply(0x8000_0002, nil))
        XCTAssertEqual(clipboard.changeCount, count)
    }

    func testOrdinaryReplySurvivesReturnBeforeWindowBecomesKey() {
        for localCopy in [false, true] {
            let clipboard = FakeClipboard()
            clipboard.copyOnDevice("original")
            let sync = makeSynchronizer(clipboard: clipboard) { _ in }
            sync.sharedClipboardEnabled = true
            sync.applicationWillResignActive()
            sync.setHostWindowActive(false)
            sync.handleClipboardEvent(.requestStarted(1, changeNotice: true))
            if localCopy { clipboard.copyOnDevice("new local") }
            sync.applicationDidBecomeActive()
            sync.setHostWindowActive(true)
            sync.handleClipboardEvent(.reply(1, .text("away update")))
            XCTAssertEqual(clipboard.text, localCopy ? "new local" : "away update")
        }
    }

    func testLateNoticeLeavesAcceptedDownloadEligibleInEitherReplyOrder() {
        for noticeFirst in [false, true] {
            let clipboard = FakeClipboard()
            clipboard.copyOnDevice("original")
            var instant = ContinuousClock.now
            let sync = makeSynchronizer(
                clipboard: clipboard, canRequestRemoteClipboard: { true },
                requestAppleClipboard: appleRequestIDs(), now: { instant }) { _ in }
            sync.sharedClipboardEnabled = true
            sync.remoteKeyEvent(down: true, key: KeyboardInputHandler.keysymSuperL)
            sync.remoteKeyEvent(down: true, key: 0x63)
            sync.handleClipboardEvent(.reply(0x8000_0001, .text("before copy")))
            sync.applicationWillResignActive()
            instant += .seconds(10)
            sync.handleClipboardEvent(.requestStarted(2, changeNotice: true))
            if noticeFirst {
                sync.handleClipboardEvent(.reply(2, .text("newer notice")))
                XCTAssertEqual(clipboard.text, "newer notice")
            }
            sync.handleClipboardEvent(.reply(0x8000_0002, .text("accepted copy")))
            XCTAssertEqual(clipboard.text, noticeFirst ? "newer notice" : "accepted copy")
            if !noticeFirst { sync.handleClipboardEvent(.reply(2, .text("newer notice"))) }
            sync.applicationDidBecomeActive()
            XCTAssertEqual(clipboard.text, "newer notice")
        }
    }

    func testNoticePublishesRepeatedRemoteMenuCopy() {
        let clipboard = FakeClipboard()
        clipboard.copyOnDevice("L")
        var id: UInt32 = 0x8000_0000
        let sync = makeSynchronizer(
            clipboard: clipboard, canRequestRemoteClipboard: { true },
            requestAppleClipboard: {
                id += 1
                return id
            }) { _ in }
        sync.sharedClipboardEnabled = true
        sync.remotePointerWillSend(buttonMask: 1)
        sync.handleClipboardEvent(.reply(0x8000_0001, .text("A")))
        sync.applicationWillResignActive()
        sync.handleClipboardEvent(.reply(0x8000_0002, .text("A")))
        XCTAssertEqual(clipboard.text, "L")
        sync.handleClipboardEvent(.requestStarted(3, changeNotice: true))
        sync.handleClipboardEvent(.reply(3, .text("A")))
        XCTAssertEqual(clipboard.text, "A")
    }

    func testNewerDeferredReplySupersedesRunningImageNormalization() async throws {
        let clipboard = FakeClipboard()
        clipboard.copyOnDevice("original")
        let sync = makeSynchronizer(
            clipboard: clipboard, canRequestRemoteClipboard: { true },
            requestAppleClipboard: appleRequestIDs()) { _ in }
        let tiff = VNCClipboardContent(items: [[.init(
            type: ClipboardType.tiff, data: try Self.imageData(type: "public.tiff"))]])
        sync.sharedClipboardEnabled = true
        sync.remoteKeyEvent(down: true, key: KeyboardInputHandler.keysymSuperL)
        sync.remoteKeyEvent(down: true, key: 0x63)
        sync.handleClipboardEvent(.reply(0x8000_0001, .text("before copy")))
        sync.remoteKeyEvent(down: false, key: 0x63)
        sync.handleClipboardEvent(.reply(0x8000_0002, tiff))
        let conversion = try XCTUnwrap(sync.normalizationTask)
        sync.setHostWindowActive(false)
        sync.handleClipboardEvent(.requestStarted(2, changeNotice: true))
        sync.handleClipboardEvent(.reply(2, .text("B")))
        await conversion.value
        XCTAssertEqual(clipboard.text, "original")
        sync.applicationWillResignActive()
        XCTAssertEqual(clipboard.text, "B")
        sync.applicationDidBecomeActive()
        sync.setHostWindowActive(true)
        XCTAssertEqual(clipboard.text, "B")
    }

    func testNewLocalCopyWinsOverMacCopyReply() {
        let clipboard = FakeClipboard()
        var sent: [String] = []
        let sync = makeSynchronizer(
            clipboard: clipboard, canRequestRemoteClipboard: { true },
            requestAppleClipboard: appleRequestIDs()) { sent.append($0) }
        sync.sharedClipboardEnabled = true
        sync.remoteKeyEvent(down: true, key: KeyboardInputHandler.keysymSuperR)
        sync.remoteKeyEvent(down: true, key: 0x78)
        sync.handleClipboardEvent(.reply(0x8000_0001, .text("before copy")))
        sync.remoteKeyEvent(down: false, key: 0x78)
        sync.applicationWillResignActive()
        clipboard.copyOnDevice("copied locally")
        sync.handleClipboardEvent(.reply(0x8000_0002, .text("late reply")))
        XCTAssertEqual(clipboard.text, "copied locally")
        sync.applicationDidBecomeActive()
        XCTAssertEqual(sent, ["copied locally"])
    }

    func testOnlyCopyOrCutFromTheFocusedSharedPaneRequestsTheClipboard() {
        let clipboard = FakeClipboard()
        var requests = 0
        let sync = makeSynchronizer(
            clipboard: clipboard, canRequestRemoteClipboard: { true },
            requestAppleClipboard: {
                    requests += 1
                    return 0x8000_0000 + UInt32(requests)
                }) { _ in }
        func sendC() {
            sync.remoteKeyEvent(down: true, key: 0x63)
            sync.remoteKeyEvent(down: false, key: 0x63)
        }
        sync.remoteKeyEvent(down: true, key: KeyboardInputHandler.keysymSuperL)
        sendC()
        sync.sharedClipboardEnabled = true
        sendC()
        sync.remoteKeyEvent(down: true, key: KeyboardInputHandler.keysymSuperL)
        sync.remoteKeyEvent(down: true, key: KeyboardInputHandler.keysymShiftL)
        sendC()
        sync.remoteKeyEvent(down: false, key: KeyboardInputHandler.keysymShiftL)
        XCTAssertEqual(requests, 0)
        sendC()
        XCTAssertEqual(requests, 2)
        sync.setHostFocused(false)
        sync.applicationWillResignActive()
        sync.receiveRemoteClipboardText("inactive pane")
        XCTAssertNil(clipboard.text)
    }

    func testForegroundLocalChangeWinsOverRemoteChange() {
        let clipboard = FakeClipboard()
        var sent: [String] = []
        let synchronizer = makeSynchronizer(clipboard: clipboard) { sent.append($0) }
        synchronizer.sharedClipboardEnabled = true

        synchronizer.applicationWillResignActive()
        synchronizer.receiveRemoteClipboardText("background remote")
        clipboard.copyOnDevice("external local")
        synchronizer.applicationDidBecomeActive()

        XCTAssertEqual(sent, ["external local"])
        XCTAssertEqual(clipboard.text, "external local")
    }

    func testForegroundAppliesRemoteWhenLocalClipboardDidNotChange() {
        let clipboard = FakeClipboard()
        clipboard.copyOnDevice("unchanged local")
        var sent: [String] = []
        let synchronizer = makeSynchronizer(clipboard: clipboard) { sent.append($0) }
        synchronizer.sharedClipboardEnabled = true

        synchronizer.applicationWillResignActive()
        synchronizer.receiveRemoteClipboardText("background remote")
        synchronizer.applicationDidBecomeActive()

        XCTAssertEqual(clipboard.text, "background remote")
        XCTAssertTrue(sent.isEmpty)
    }

    func testInactiveWindowDefersForegroundReconciliation() {
        let clipboard = FakeClipboard()
        var sent: [String] = []
        let synchronizer = makeSynchronizer(clipboard: clipboard) { sent.append($0) }
        synchronizer.sharedClipboardEnabled = true

        synchronizer.applicationWillResignActive()
        synchronizer.setHostWindowActive(false)
        clipboard.copyOnDevice("external local")
        synchronizer.applicationDidBecomeActive()

        XCTAssertTrue(sent.isEmpty)

        synchronizer.setHostWindowActive(true)
        XCTAssertEqual(sent, ["external local"])
    }

    func testWindowActivationBeforeApplicationActivationDoesNotReconcileEarly() {
        let clipboard = FakeClipboard()
        var sent: [String] = []
        let synchronizer = makeSynchronizer(clipboard: clipboard) { sent.append($0) }
        synchronizer.sharedClipboardEnabled = true

        synchronizer.applicationWillResignActive()
        synchronizer.setHostWindowActive(false)
        clipboard.copyOnDevice("first background value")
        synchronizer.setHostWindowActive(true)

        XCTAssertTrue(sent.isEmpty)

        clipboard.copyOnDevice("latest background value")
        synchronizer.applicationDidBecomeActive()

        XCTAssertEqual(sent, ["latest background value"])
    }

    /// Mac app switch: the window can lose key before the app resigns, and
    /// polling keeps running while the copy happens elsewhere.
    func testCopyInAnotherMacAppIsSentOnReturn() {
        let clipboard = FakeClipboard()
        var sent: [String] = []
        let synchronizer = makeSynchronizer(clipboard: clipboard) { sent.append($0) }
        synchronizer.sharedClipboardEnabled = true

        synchronizer.setHostWindowActive(false)
        synchronizer.applicationWillResignActive()
        clipboard.copyOnDevice("copied elsewhere")
        synchronizer.localClipboardDidChange()
        synchronizer.setHostWindowActive(true)
        synchronizer.applicationDidBecomeActive()

        XCTAssertEqual(sent, ["copied elsewhere"])
    }

    /// Two windows share with different servers. A copy made in the window
    /// that came forward must not reach the other window's server later.
    func testCopyAfterReturningToAnotherWindowIsNotBridged() {
        let clipboard = FakeClipboard()
        var sentA: [String] = []
        var sentB: [String] = []
        let windowA = makeSynchronizer(clipboard: clipboard) { sentA.append($0) }
        let windowB = makeSynchronizer(clipboard: clipboard) { sentB.append($0) }
        windowA.sharedClipboardEnabled = true
        windowB.sharedClipboardEnabled = true
        windowB.setHostWindowActive(false)

        for window in [windowA, windowB] { window.applicationWillResignActive() }
        for window in [windowA, windowB] { window.applicationDidBecomeActive() }

        clipboard.copyOnDevice("copied in window A")
        windowA.localClipboardDidChange()
        windowB.localClipboardDidChange()
        windowA.setHostWindowActive(false)
        windowB.setHostWindowActive(true)

        XCTAssertEqual(sentA, ["copied in window A"])
        XCTAssertTrue(sentB.isEmpty)

        clipboard.copyOnDevice("copied in window B")
        windowB.localClipboardDidChange()
        XCTAssertEqual(sentB, ["copied in window B"])
    }

    /// The front window applies its server's clipboard on return before the
    /// other window hears the app came forward.
    func testRemoteClipboardAppliedByAnotherWindowIsNotBridged() {
        let clipboard = FakeClipboard()
        var sentB: [String] = []
        let windowA = makeSynchronizer(clipboard: clipboard) { _ in }
        let windowB = makeSynchronizer(clipboard: clipboard) { sentB.append($0) }
        windowA.sharedClipboardEnabled = true
        windowB.sharedClipboardEnabled = true
        windowB.setHostWindowActive(false)

        for window in [windowA, windowB] { window.applicationWillResignActive() }
        windowA.receiveRemoteClipboardText("from the first Mac")
        windowA.applicationDidBecomeActive()
        XCTAssertEqual(clipboard.text, "from the first Mac")
        windowB.applicationDidBecomeActive()

        windowA.setHostWindowActive(false)
        windowB.setHostWindowActive(true)
        XCTAssertTrue(sentB.isEmpty)

        clipboard.copyOnDevice("copied in window B")
        windowB.localClipboardDidChange()
        XCTAssertEqual(sentB, ["copied in window B"])
    }

    /// A clipboard another window's server wrote before the app was left
    /// does not block this window's own remote change on return.
    func testEarlierWriteByAnotherWindowDoesNotBlockRemoteOnReturn() {
        let clipboard = FakeClipboard()
        var sentB: [String] = []
        let windowA = makeSynchronizer(clipboard: clipboard) { _ in }
        let windowB = makeSynchronizer(clipboard: clipboard) { sentB.append($0) }
        windowA.sharedClipboardEnabled = true
        windowB.sharedClipboardEnabled = true
        windowB.setHostWindowActive(false)

        windowA.receiveRemoteClipboardText("from the first Mac")
        windowA.setHostWindowActive(false)
        windowB.setHostWindowActive(true)

        for window in [windowA, windowB] { window.applicationWillResignActive() }
        windowB.receiveRemoteClipboardText("from the second Mac")
        for window in [windowA, windowB] { window.applicationDidBecomeActive() }

        XCTAssertEqual(clipboard.text, "from the second Mac")
        XCTAssertTrue(sentB.isEmpty)
    }

    func testMonitoringDoesNotRetainSynchronizer() async {
        let clipboard = FakeClipboard()
        weak var weakSynchronizer: VNCClipboardSynchronizer?

        do {
            let synchronizer = makeSynchronizer(
                clipboard: clipboard,
                automaticallyMonitors: true
            ) { _ in }
            synchronizer.sharedClipboardEnabled = true
            weakSynchronizer = synchronizer
        }

        try? await Task.sleep(for: .milliseconds(600))
        XCTAssertNil(weakSynchronizer)
    }

    func testClipboardObservationFollowsSharedModeWithoutDuplicates() async {
        let clipboard = FakeClipboard()
        let notificationCenter = NotificationCenter()
        let notificationName = Notification.Name("VNCClipboardDidChange")
        var sent: [String] = []
        var transferExpectation: XCTestExpectation?
        let synchronizer = makeSynchronizer(
            clipboard: clipboard,
            automaticallyMonitors: true,
            notificationCenter: notificationCenter,
            clipboardChangeNotification: notificationName
        ) {
            sent.append($0)
            transferExpectation?.fulfill()
        }

        XCTAssertFalse(synchronizer.isObservingClipboardChanges)
        clipboard.copyOnDevice("sharing disabled")
        notificationCenter.post(name: notificationName, object: nil)
        XCTAssertTrue(sent.isEmpty)

        synchronizer.sharedClipboardEnabled = true
        XCTAssertTrue(synchronizer.isObservingClipboardChanges)
        let firstTransfer = expectation(description: "First clipboard transfer")
        transferExpectation = firstTransfer
        clipboard.copyOnDevice("sharing enabled")
        notificationCenter.post(name: notificationName, object: nil)
        await fulfillment(of: [firstTransfer], timeout: 1)
        transferExpectation = nil
        XCTAssertEqual(sent, ["sharing enabled"])

        synchronizer.sharedClipboardEnabled = false
        XCTAssertFalse(synchronizer.isObservingClipboardChanges)
        clipboard.copyOnDevice("disabled again")
        notificationCenter.post(name: notificationName, object: nil)
        XCTAssertEqual(sent, ["sharing enabled"])

        synchronizer.sharedClipboardEnabled = true
        XCTAssertTrue(synchronizer.isObservingClipboardChanges)
        let secondTransfer = expectation(description: "Second clipboard transfer")
        transferExpectation = secondTransfer
        clipboard.copyOnDevice("enabled again")
        notificationCenter.post(name: notificationName, object: nil)
        await fulfillment(of: [secondTransfer], timeout: 1)
        transferExpectation = nil
        XCTAssertEqual(sent, ["sharing enabled", "enabled again"])
    }

    func testBackgroundClipboardNotificationDoesNotWaitForMainActor() {
        let clipboard = FakeClipboard()
        let notificationCenter = NotificationCenter()
        let notificationName = Notification.Name("VNCClipboardDidChange")
        let synchronizer = makeSynchronizer(
            clipboard: clipboard,
            automaticallyMonitors: true,
            notificationCenter: notificationCenter,
            clipboardChangeNotification: notificationName
        ) { _ in }
        synchronizer.sharedClipboardEnabled = true

        let postFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            notificationCenter.post(name: notificationName, object: nil)
            postFinished.signal()
        }

        XCTAssertEqual(
            postFinished.wait(timeout: .now() + 1),
            .success,
            "Posting a clipboard change must not synchronously wait for main"
        )
    }

    func testTransferCallbackOnlyReportsAppliedTransfers() {
        let clipboard = FakeClipboard()
        clipboard.copyOnDevice("device")
        let synchronizer = makeSynchronizer(clipboard: clipboard) { _ in }
        var transfers: [(VNCClipboardTransferDirection, String)] = []
        synchronizer.onTransfer = { transfers.append(($0, $1)) }

        synchronizer.receiveRemoteClipboardText("cached")
        XCTAssertTrue(transfers.isEmpty)

        synchronizer.getClipboard()
        clipboard.copyOnDevice("sent")
        synchronizer.sendClipboard()

        XCTAssertEqual(transfers.count, 2)
        XCTAssertEqual(transfers[0].1, "cached")
        XCTAssertEqual(transfers[1].1, "sent")
    }

    // MARK: - Rich content

    private static let png = VNCClipboardContent.Representation(
        type: ClipboardType.png, data: Data([0x89, 0x50, 0x4E, 0x47]))
    private static let rtf = VNCClipboardContent.Representation(
        type: ClipboardType.rtf, data: Data("{\\rtf1 hi}".utf8))
    private static let text = VNCClipboardContent.Representation(
        type: ClipboardType.utf8PlainText, data: Data("hi".utf8))

    func testImageOnlyClipboardCannotBeSentToPlainTextServer() {
        let clipboard = FakeClipboard()
        clipboard.copyOnDevice(VNCClipboardContent(items: [[Self.png]]))
        var sent: [VNCClipboardContent] = []
        let synchronizer = makeSynchronizer(
            clipboard: clipboard,
            contentSupport: { .plainText },
            sendContent: { sent.append($0) }
        ) { _ in }

        XCTAssertFalse(synchronizer.canSendClipboard)
        synchronizer.sendClipboard()
        XCTAssertTrue(sent.isEmpty)
    }

    func testManualSendKeepsRepresentationsTheServerAccepts() {
        let clipboard = FakeClipboard()
        clipboard.copyOnDevice(VNCClipboardContent(items: [[Self.rtf, Self.png, Self.text]]))
        var support: VNCClipboardContentSupport = .all
        var sent: [VNCClipboardContent] = []
        let synchronizer = makeSynchronizer(
            clipboard: clipboard,
            contentSupport: { support },
            sendContent: { sent.append($0) }
        ) { _ in }
        var transfers: [String] = []
        synchronizer.onTransfer = { transfers.append($1) }

        synchronizer.sendClipboard()
        support = .formats([ClipboardType.rtf])
        synchronizer.sendClipboard()

        XCTAssertEqual(sent, [
            VNCClipboardContent(items: [[Self.rtf, Self.png, Self.text]]),
            VNCClipboardContent(items: [[Self.rtf, Self.text]]),
        ])
        XCTAssertEqual(transfers, ["hi", "hi"])
    }

    func testImageOnlyTransfersAreAppliedWithoutTransferCallback() {
        let clipboard = FakeClipboard()
        let synchronizer = makeSynchronizer(clipboard: clipboard) { _ in }
        var transfers: [String] = []
        synchronizer.onTransfer = { transfers.append($1) }

        synchronizer.receiveRemoteClipboardContent(VNCClipboardContent(items: [[Self.png]]))
        synchronizer.getClipboard()

        XCTAssertEqual(clipboard.content, VNCClipboardContent(items: [[Self.png]]))
        XCTAssertTrue(transfers.isEmpty)
    }

    func testRemoteFormattingOfTextWeSentIsApplied() {
        let clipboard = FakeClipboard()
        var sent: [String] = []
        let synchronizer = makeSynchronizer(clipboard: clipboard) { sent.append($0) }
        synchronizer.sharedClipboardEnabled = true

        clipboard.copyOnDevice("hi")
        synchronizer.localClipboardDidChange()
        XCTAssertEqual(sent, ["hi"])

        let formatted = VNCClipboardContent(items: [[Self.rtf, Self.text]])
        synchronizer.receiveRemoteClipboardContent(formatted)
        XCTAssertEqual(clipboard.content, formatted)
        synchronizer.localClipboardDidChange()
        XCTAssertEqual(sent, ["hi"], "Applying remote content must not send it back")
    }

    func testRepeatedRemoteDeliveryIsAppliedOnce() {
        let clipboard = FakeClipboard()
        let synchronizer = makeSynchronizer(clipboard: clipboard) { _ in }
        var transfers: [String] = []
        synchronizer.onTransfer = { transfers.append($1) }
        synchronizer.sharedClipboardEnabled = true

        synchronizer.receiveRemoteClipboardText("remote")
        synchronizer.receiveRemoteClipboardText("remote")
        synchronizer.receiveRemoteClipboardText("remote")
        XCTAssertEqual(clipboard.changeCount, 1)
        XCTAssertEqual(transfers, ["remote"])

        synchronizer.receiveRemoteClipboardText("changed")
        XCTAssertEqual(clipboard.text, "changed")
        XCTAssertEqual(clipboard.changeCount, 2)

        // A local copy in between means the device no longer holds it.
        clipboard.copyOnDevice("local")
        synchronizer.receiveRemoteClipboardText("changed")
        XCTAssertEqual(clipboard.text, "changed")
    }

    func testRemoteEchoOfSentContentIsNotRewritten() {
        let clipboard = FakeClipboard()
        var sent: [String] = []
        let synchronizer = makeSynchronizer(clipboard: clipboard) { sent.append($0) }
        synchronizer.sharedClipboardEnabled = true

        clipboard.copyOnDevice("hi")
        synchronizer.localClipboardDidChange()
        synchronizer.receiveRemoteClipboardText("hi")

        XCTAssertEqual(sent, ["hi"])
        XCTAssertEqual(clipboard.changeCount, 1)
    }

    func testManualGetRewritesUnchangedRemoteContent() {
        let clipboard = FakeClipboard()
        let synchronizer = makeSynchronizer(clipboard: clipboard) { _ in }
        synchronizer.sharedClipboardEnabled = true

        synchronizer.receiveRemoteClipboardText("remote")
        synchronizer.getClipboard()

        XCTAssertEqual(clipboard.changeCount, 2)
    }

    func testPendingSharedImageApplyIsDroppedWhenThePaneStopsSharing() async throws {
        let tiff = VNCClipboardContent.Representation(
            type: ClipboardType.tiff, data: try Self.imageData(type: "public.tiff"))
        let interruptions: [(String, (VNCClipboardSynchronizer) -> Void)] = [
            ("focus", { $0.setHostFocused(false) }),
            ("window", { $0.setHostWindowActive(false) }),
            ("background", { $0.applicationWillResignActive() }),
            ("sharing", { $0.sharedClipboardEnabled = false }),
        ]
        for (name, interrupt) in interruptions {
            let clipboard = FakeClipboard()
            let synchronizer = makeSynchronizer(clipboard: clipboard) { _ in }
            synchronizer.sharedClipboardEnabled = true

            synchronizer.receiveRemoteClipboardContent(VNCClipboardContent(items: [[tiff]]))
            interrupt(synchronizer)

            try await Task.sleep(for: .milliseconds(300))
            XCTAssertNil(clipboard.content, "\(name) must cancel the pending write")
        }
    }

    func testManualImageGetCompletesAfterThePaneLosesFocus() async throws {
        let clipboard = FakeClipboard()
        let synchronizer = makeSynchronizer(clipboard: clipboard) { _ in }
        let tiff = VNCClipboardContent.Representation(
            type: ClipboardType.tiff, data: try Self.imageData(type: "public.tiff"))

        synchronizer.receiveRemoteClipboardContent(VNCClipboardContent(items: [[tiff]]))
        synchronizer.getClipboard()
        synchronizer.setHostFocused(false)

        let applied = await Self.waitUntil { clipboard.content != nil }
        XCTAssertTrue(applied)
    }

    func testLocalImageCopiedDuringReconnectIsSentOnceCapsArrive() {
        let clipboard = FakeClipboard()
        var connected = true
        var support: VNCClipboardContentSupport = .plainText
        var sent: [VNCClipboardContent] = []
        let synchronizer = makeSynchronizer(
            clipboard: clipboard,
            connected: { connected },
            contentSupport: { support },
            sendContent: { sent.append($0) }
        ) { _ in }
        synchronizer.sharedClipboardEnabled = true

        connected = false
        synchronizer.connectionStateDidChange(.reconnecting(attempt: 1, delay: 0))
        let image = VNCClipboardContent(items: [[Self.png]])
        clipboard.copyOnDevice(image)
        synchronizer.localClipboardDidChange()

        // Connected before ExtendedClipboard caps: nothing is sendable yet.
        connected = true
        synchronizer.connectionStateDidChange(.connected)
        XCTAssertTrue(sent.isEmpty)

        support = .formats([ClipboardType.png])
        synchronizer.clipboardCapabilitiesDidChange()
        XCTAssertEqual(sent, [image])

        // The same support again, or a later local copy, is not a retry.
        synchronizer.clipboardCapabilitiesDidChange()
        XCTAssertEqual(sent, [image])
    }

    func testRichPartOfAChangeFlushedAsTextFollowsOnceCapsArrive() {
        let clipboard = FakeClipboard()
        var support: VNCClipboardContentSupport = .plainText
        var sent: [VNCClipboardContent] = []
        let synchronizer = makeSynchronizer(
            clipboard: clipboard,
            contentSupport: { support },
            sendContent: { sent.append($0) }
        ) { _ in }
        synchronizer.sharedClipboardEnabled = true

        let rich = VNCClipboardContent(items: [[Self.rtf, Self.text]])
        clipboard.copyOnDevice(rich)
        synchronizer.localClipboardDidChange()
        XCTAssertEqual(sent, [.text("hi")])

        support = .all
        synchronizer.clipboardCapabilitiesDidChange()
        XCTAssertEqual(sent, [.text("hi"), rich])
    }

    func testRichCopyReconciledOnForegroundFollowsOnceCapsArrive() {
        let clipboard = FakeClipboard()
        var support: VNCClipboardContentSupport = .plainText
        var sent: [VNCClipboardContent] = []
        let synchronizer = makeSynchronizer(
            clipboard: clipboard,
            contentSupport: { support },
            sendContent: { sent.append($0) }
        ) { _ in }
        synchronizer.sharedClipboardEnabled = true

        synchronizer.applicationWillResignActive()
        let rich = VNCClipboardContent(items: [[Self.rtf, Self.text]])
        clipboard.copyOnDevice(rich)
        synchronizer.applicationDidBecomeActive()
        XCTAssertEqual(sent, [.text("hi")])

        support = .all
        synchronizer.clipboardCapabilitiesDidChange()
        XCTAssertEqual(sent, [.text("hi"), rich])
    }

    func testCapsArrivingWhileBackgroundedAreRetriedOnForeground() {
        let clipboard = FakeClipboard()
        var support: VNCClipboardContentSupport = .plainText
        var sent: [VNCClipboardContent] = []
        let synchronizer = makeSynchronizer(
            clipboard: clipboard,
            contentSupport: { support },
            sendContent: { sent.append($0) }
        ) { _ in }
        synchronizer.sharedClipboardEnabled = true

        let image = VNCClipboardContent(items: [[Self.png]])
        clipboard.copyOnDevice(image)
        synchronizer.localClipboardDidChange()
        synchronizer.applicationWillResignActive()
        support = .all
        synchronizer.clipboardCapabilitiesDidChange()
        XCTAssertTrue(sent.isEmpty)

        synchronizer.applicationDidBecomeActive()
        XCTAssertEqual(sent, [image])
    }

    func testDeferredFlushSurvivesAForegroundBeforeCapsArrive() {
        let clipboard = FakeClipboard()
        var support: VNCClipboardContentSupport = .plainText
        var sent: [VNCClipboardContent] = []
        let synchronizer = makeSynchronizer(
            clipboard: clipboard,
            contentSupport: { support },
            sendContent: { sent.append($0) }
        ) { _ in }
        synchronizer.sharedClipboardEnabled = true

        let image = VNCClipboardContent(items: [[Self.png]])
        clipboard.copyOnDevice(image)
        synchronizer.localClipboardDidChange()
        synchronizer.applicationWillResignActive()
        synchronizer.applicationDidBecomeActive()
        XCTAssertTrue(sent.isEmpty)

        support = .all
        synchronizer.clipboardCapabilitiesDidChange()
        XCTAssertEqual(sent, [image])
    }

    func testCapsRetryNeverResendsAStaleOrPlainChange() {
        let clipboard = FakeClipboard()
        var support: VNCClipboardContentSupport = .plainText
        var sent: [VNCClipboardContent] = []
        let synchronizer = makeSynchronizer(
            clipboard: clipboard,
            contentSupport: { support },
            sendContent: { sent.append($0) }
        ) { _ in }
        synchronizer.sharedClipboardEnabled = true

        clipboard.copyOnDevice(VNCClipboardContent(items: [[Self.rtf, Self.text]]))
        synchronizer.localClipboardDidChange()
        clipboard.copyOnDevice("newer") // not flushed yet
        support = .all
        synchronizer.clipboardCapabilitiesDidChange()
        XCTAssertEqual(sent, [.text("hi")])

        support = .plainText
        synchronizer.localClipboardDidChange()
        support = .all
        synchronizer.clipboardCapabilitiesDidChange()
        XCTAssertEqual(sent, [.text("hi"), .text("newer")])
    }

    func testImageNormalizationRefusesImagesOverTheDecodeBudget() throws {
        let tiff = try Self.imageData(type: "public.tiff")
        XCTAssertNotNil(VNCClipboardImageNormalizer.pngData(from: tiff))
        // A 1x1 image decodes to 4 bytes; the header alone must reject it.
        XCTAssertNil(VNCClipboardImageNormalizer.pngData(from: tiff, maximumDecodedBytes: 3))
    }

    func testTIFFOnlyRemoteImageGainsPNGBeforeItIsApplied() async throws {
        let clipboard = FakeClipboard()
        let synchronizer = makeSynchronizer(clipboard: clipboard) { _ in }
        let tiff = VNCClipboardContent.Representation(
            type: ClipboardType.tiff, data: try Self.imageData(type: "public.tiff"))

        synchronizer.receiveRemoteClipboardContent(VNCClipboardContent(items: [[tiff, Self.text]]))
        synchronizer.getClipboard()

        let applied = await Self.waitUntil { clipboard.content != nil }
        XCTAssertTrue(applied)
        let types = clipboard.content?.items.flatMap { $0.map(\.type) }
        XCTAssertEqual(types, [ClipboardType.png, ClipboardType.tiff, ClipboardType.utf8PlainText])
    }

    func testNewerApplyWinsOverPendingImageConversion() async throws {
        let clipboard = FakeClipboard()
        let synchronizer = makeSynchronizer(clipboard: clipboard) { _ in }
        let tiff = VNCClipboardContent.Representation(
            type: ClipboardType.tiff, data: try Self.imageData(type: "public.tiff"))

        synchronizer.receiveRemoteClipboardContent(VNCClipboardContent(items: [[tiff]]))
        synchronizer.getClipboard()
        synchronizer.receiveRemoteClipboardText("newer")
        synchronizer.getClipboard()

        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(clipboard.content, .text("newer"))
    }

    func testCapabilityChangeTurnsOnRemoteSharedClipboard() {
        let clipboard = FakeClipboard()
        var controllable = false
        var remoteStates: [Bool] = []
        let synchronizer = makeSynchronizer(
            clipboard: clipboard,
            canControlRemoteSharedClipboard: { controllable },
            setRemoteSharedClipboard: { remoteStates.append($0) }
        ) { _ in }

        synchronizer.sharedClipboardEnabled = true
        XCTAssertTrue(remoteStates.isEmpty)

        controllable = true
        synchronizer.clipboardCapabilitiesDidChange()
        XCTAssertEqual(remoteStates, [true])
    }

    private static func imageData(type: String) throws -> Data {
        var pixels: [UInt8] = [0xFF, 0x00, 0x00, 0xFF]
        let image = try XCTUnwrap(pixels.withUnsafeMutableBytes { buffer in
            CGContext(
                data: buffer.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        })
        let output = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(output, type as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private static func waitUntil(
        timeout: Duration = .seconds(2),
        condition: () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}
