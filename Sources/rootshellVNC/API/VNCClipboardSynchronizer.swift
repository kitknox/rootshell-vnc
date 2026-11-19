import Foundation
import RFBProtocol
import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Clipboard data: pasteboard items with representations in fidelity order.
public typealias VNCClipboardContent = ClipboardContent
/// Which clipboard representations a connected server can receive.
public typealias VNCClipboardContentSupport = ClipboardContentSupport

/// The direction of a completed clipboard transfer.
public enum VNCClipboardTransferDirection: Sendable {
    case deviceToRemote
    case remoteToDevice
}

/// The latest remote clipboard written to the device and the pane that
/// wrote it, shared by every pane on the same pasteboard.
@MainActor
final class VNCClipboardRemoteWrites {
    static let system = VNCClipboardRemoteWrites()
    var latest: (changeCount: Int, writer: ObjectIdentifier)?
    // A different host window taking key supersedes an in-flight app switch.
    private(set) var ownershipGeneration: UInt64 = 0
    weak var remoteCopyOwner: VNCClipboardSynchronizer? {
        didSet {
            if remoteCopyOwner !== oldValue { ownershipGeneration &+= 1 }
        }
    }
}

@MainActor
protocol VNCClipboardProviding: AnyObject {
    var changeCount: Int { get }
    var remoteWrites: VNCClipboardRemoteWrites { get }

    func hasTransferableContent(for support: VNCClipboardContentSupport) -> Bool
    func readContent(for support: VNCClipboardContentSupport) -> VNCClipboardContent?
    func write(_ content: VNCClipboardContent)
}

/// Rich representations come from each pasteboard item; plain text keeps
/// its URL-first derivation and rides on the first item.
private func clipboardContent(
    richItems: [VNCClipboardContent.Item],
    text: String?
) -> VNCClipboardContent? {
    var items = richItems
    if let text {
        let representation = VNCClipboardContent.Representation(
            type: ClipboardType.utf8PlainText, data: Data(text.utf8))
        if items.isEmpty {
            items = [[representation]]
        } else {
            items[0].append(representation)
        }
    }
    let content = VNCClipboardContent(items: items)
    return content.isEmpty ? nil : content
}

private func outboundRichTypes(for support: VNCClipboardContentSupport) -> Set<String> {
    ClipboardType.outbound
        .subtracting([ClipboardType.utf8PlainText])
        .filter(support.accepts)
}

#if canImport(UIKit)
@MainActor
private final class VNCSystemClipboard: VNCClipboardProviding {
    private let pasteboard = UIPasteboard.general

    var changeCount: Int { pasteboard.changeCount }
    var remoteWrites: VNCClipboardRemoteWrites { .system }

    // Type and has* queries do not trigger the paste permission prompt.
    func hasTransferableContent(for support: VNCClipboardContentSupport) -> Bool {
        if pasteboard.hasStrings || pasteboard.hasURLs { return true }
        let richTypes = outboundRichTypes(for: support)
        return !richTypes.isEmpty && pasteboard.contains(pasteboardTypes: Array(richTypes))
    }

    func readContent(for support: VNCClipboardContentSupport) -> VNCClipboardContent? {
        let richTypes = outboundRichTypes(for: support)
        var richItems: [VNCClipboardContent.Item] = []
        if !richTypes.isEmpty {
            for (index, types) in (pasteboard.types(forItemSet: nil) ?? []).enumerated() {
                let itemSet = IndexSet(integer: index)
                var item: VNCClipboardContent.Item = []
                for type in types
                where richTypes.contains(type) && !item.contains(where: { $0.type == type }) {
                    guard let data = pasteboard.data(
                        forPasteboardType: type, inItemSet: itemSet)?.first else { continue }
                    item.append(.init(type: type, data: data))
                }
                richItems.append(item)
            }
        }
        return clipboardContent(richItems: richItems, text: transferableText())
    }

    func write(_ content: VNCClipboardContent) {
        pasteboard.setItems(content.items.map { item in
            var values: [String: Any] = [:]
            for representation in item where values[representation.type] == nil {
                values[representation.type] = representation.type == ClipboardType.utf8PlainText
                    ? String(decoding: representation.data, as: UTF8.self)
                    : representation.data
            }
            return values
        })
    }

    private func transferableText() -> String? {
        if let urls = pasteboard.urls, !urls.isEmpty {
            return urls.map { $0.isFileURL ? $0.path : $0.absoluteString }
                .joined(separator: " ")
        }
        return pasteboard.string
    }
}
#elseif canImport(AppKit)
@MainActor
private final class VNCSystemClipboard: VNCClipboardProviding {
    private let pasteboard = NSPasteboard.general

    var changeCount: Int { pasteboard.changeCount }
    var remoteWrites: VNCClipboardRemoteWrites { .system }

    func hasTransferableContent(for support: VNCClipboardContentSupport) -> Bool {
        if pasteboard.canReadObject(forClasses: [NSString.self, NSURL.self], options: nil) {
            return true
        }
        let richTypes = outboundRichTypes(for: support)
            .map(NSPasteboard.PasteboardType.init(rawValue:))
        return !richTypes.isEmpty && pasteboard.availableType(from: richTypes) != nil
    }

    func readContent(for support: VNCClipboardContentSupport) -> VNCClipboardContent? {
        let richTypes = outboundRichTypes(for: support)
        var richItems: [VNCClipboardContent.Item] = []
        if !richTypes.isEmpty {
            for pasteboardItem in pasteboard.pasteboardItems ?? [] {
                var item: VNCClipboardContent.Item = []
                for type in pasteboardItem.types
                where richTypes.contains(type.rawValue)
                    && !item.contains(where: { $0.type == type.rawValue }) {
                    guard let data = pasteboardItem.data(forType: type) else { continue }
                    item.append(.init(type: type.rawValue, data: data))
                }
                richItems.append(item)
            }
        }
        return clipboardContent(richItems: richItems, text: transferableText())
    }

    func write(_ content: VNCClipboardContent) {
        pasteboard.clearContents()
        pasteboard.writeObjects(content.items.map { item in
            let pasteboardItem = NSPasteboardItem()
            for representation in item {
                if representation.type == ClipboardType.utf8PlainText {
                    pasteboardItem.setString(
                        String(decoding: representation.data, as: UTF8.self),
                        forType: .string)
                } else {
                    pasteboardItem.setData(
                        representation.data,
                        forType: NSPasteboard.PasteboardType(representation.type))
                }
            }
            return pasteboardItem
        })
    }

    private func transferableText() -> String? {
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: nil) as? [URL],
           !urls.isEmpty {
            return urls.map { $0.isFileURL ? $0.path : $0.absoluteString }
                .joined(separator: " ")
        }
        return pasteboard.string(forType: .string)
    }
}
#endif

/// Coordinates manual and shared clipboard transfers for one VNC session.
///
/// Shared mode is deliberately session-scoped and starts disabled. Enabling it
/// establishes a baseline without immediately replacing either clipboard; the
/// next local or remote change chooses the initial shared value.
@MainActor
@Observable
public final class VNCClipboardSynchronizer {
    /// Whether subsequent clipboard changes automatically flow both ways.
    public var sharedClipboardEnabled = false {
        didSet {
            guard oldValue != sharedClipboardEnabled else { return }
            needsForegroundReconciliation = false
            ordinaryRequest = nil
            cancelRemoteCopy()
            cancelAutomaticApply()
            establishBaseline()
            if sharedClipboardEnabled, automaticallyMonitors {
                startMonitoring()
                startClipboardObservation()
            } else {
                monitoringTask?.cancel()
                monitoringTask = nil
                stopClipboardObservation()
            }
            if canControlRemoteSharedClipboard() {
                setRemoteSharedClipboard(sharedClipboardEnabled)
            }
        }
    }

    /// Invoked with the plain text of a transfer once it is applied locally or
    /// queued for the remote. Transfers without plain text, such as a lone
    /// image, are not reported. Hosts can use this for clipboard history
    /// without observing contents merely cached while sharing was inactive.
    @ObservationIgnored
    public var onTransfer: ((VNCClipboardTransferDirection, String) -> Void)?

    public var hasRemoteClipboard: Bool { latestRemoteContent != nil }

    /// Whether Get Clipboard can either request the current value from the
    /// server or apply a value the server already published.
    public var canGetClipboard: Bool {
        latestRemoteContent != nil || (canSend() && canRequestRemoteClipboard())
    }

    public var canSendClipboard: Bool {
        canSend() && clipboard.hasTransferableContent(for: contentSupport())
    }

    /// Internal visibility for deterministic observer lifecycle tests.
    var isObservingClipboardChanges: Bool {
        clipboardChangeObserver != nil
    }

    @ObservationIgnored
    private let clipboard: any VNCClipboardProviding
    @ObservationIgnored
    private let canSend: () -> Bool
    @ObservationIgnored
    private let send: (VNCClipboardContent) -> Void
    @ObservationIgnored
    private let contentSupport: () -> VNCClipboardContentSupport
    @ObservationIgnored
    private let canRequestRemoteClipboard: () -> Bool
    @ObservationIgnored
    private let requestRemoteClipboard: () -> Void
    @ObservationIgnored
    private let requestAppleClipboard: () -> UInt32?
    @ObservationIgnored
    private let now: () -> ContinuousClock.Instant
    @ObservationIgnored
    private let canControlRemoteSharedClipboard: () -> Bool
    @ObservationIgnored
    private let setRemoteSharedClipboard: (Bool) -> Void
    @ObservationIgnored
    private let notificationCenter: NotificationCenter
    @ObservationIgnored
    private let automaticallyMonitors: Bool
    @ObservationIgnored
    private let clipboardChangeNotification: Notification.Name?
    @ObservationIgnored
    private let clipboardChangeObject: Any?

    @ObservationIgnored
    private weak var session: VNCSession?
    @ObservationIgnored
    private var sessionObserverID: UUID?
    @ObservationIgnored
    private var connectionStateObserverID: UUID?
    @ObservationIgnored
    private var capabilityObserverID: UUID?
    @ObservationIgnored
    private var lifecycleObservers: [NSObjectProtocol] = []
    @ObservationIgnored
    private var clipboardChangeObserver: NSObjectProtocol?
    @ObservationIgnored
    private var monitoringTask: Task<Void, Never>?

    private var latestRemoteContent: VNCClipboardContent?
    @ObservationIgnored
    private var pendingManualGet = false
    @ObservationIgnored
    private var remoteGeneration: UInt64 = 0
    @ObservationIgnored
    private var applyGeneration: UInt64 = 0
    @ObservationIgnored
    private(set) var normalizationTask: Task<Void, Never>?
    @ObservationIgnored
    private var pendingApplyIsAutomatic = false
    /// The last automatic flush and the support it was read under. Support
    /// that grows later (ExtendedClipboard caps) resends it.
    @ObservationIgnored
    private var automaticFlush: (changeCount: Int, support: VNCClipboardContentSupport)?
    /// What the device clipboard held as of a change count, as last applied
    /// from or sent to the remote. Servers repeat unchanged deliveries.
    @ObservationIgnored
    private var syncedLocalContent: (content: VNCClipboardContent, changeCount: Int)?
    @ObservationIgnored
    private var observedLocalChangeCount: Int
    @ObservationIgnored
    private var backgroundLocalChangeCount: Int
    @ObservationIgnored
    private var backgroundRemoteGeneration: UInt64 = 0
    @ObservationIgnored
    private var isApplyingRemoteContent = false
    @ObservationIgnored
    private var remoteModifiers: Set<UInt32> = []
    /// A copy initiated by this pane may finish after the user switches Mac apps.
    private final class RemoteCopy {
        var localCount: Int
        let deadline: ContinuousClock.Instant
        let ownershipGeneration: UInt64
        var isPointerAction = false
        var baseline = RemoteBaseline.unknown

        init(localCount: Int, deadline: ContinuousClock.Instant, ownershipGeneration: UInt64) {
            self.localCount = localCount
            self.deadline = deadline
            self.ownershipGeneration = ownershipGeneration
        }
    }
    @ObservationIgnored
    private var pendingRemoteCopy: RemoteCopy?
    @ObservationIgnored
    private var pointerButtonDown = false
    private enum RemoteBaseline {
        case unknown
        case requested(UInt32)
        case known(VNCClipboardContent?)
    }
    @ObservationIgnored
    private var remoteBaseline = RemoteBaseline.unknown
    @ObservationIgnored
    private var manualAppleRequestID: UInt32?
    /// Keep only the newest notice. Any other nonzero reply needs its own
    /// matching request to reach the automatic clipboard.
    @ObservationIgnored
    private var ordinaryRequest: (id: UInt32, localCount: Int, precedingCopy: RemoteCopy?)?
    @ObservationIgnored
    private var copyRequest: (id: UInt32, copy: RemoteCopy)?
    @ObservationIgnored
    private var snapshotRequest: (id: UInt32, copy: RemoteCopy, content: VNCClipboardContent?)?
    @ObservationIgnored
    private var deferredCopy: (content: VNCClipboardContent, copy: RemoteCopy, generation: UInt64)?
    @ObservationIgnored
    private var copyRequestKey: UInt32?
    @ObservationIgnored
    private var hostIsFocused = true
    @ObservationIgnored
    private var hostWindowIsActive = true
    @ObservationIgnored
    private var departingKeyWindowID: ObjectIdentifier?
    @ObservationIgnored
    private var applicationIsActive = true
    @ObservationIgnored
    private var needsForegroundReconciliation = false
    /// The device change count when the app came forward with this pane's
    /// reconciliation still deferred. A later copy belongs to whichever
    /// window was in front, not to the time away.
    @ObservationIgnored
    private var deferredForegroundChangeCount: Int?
    @ObservationIgnored
    private var invalidated = false

    /// Create clipboard synchronization for a VNC session using the platform's
    /// general pasteboard.
    public convenience init(session: VNCSession) {
        let clipboard = VNCSystemClipboard()
        #if canImport(UIKit)
        let clipboardChangeNotification: Notification.Name? =
            UIPasteboard.changedNotification
        let clipboardChangeObject: Any? = UIPasteboard.general
        #else
        let clipboardChangeNotification: Notification.Name? = nil
        let clipboardChangeObject: Any? = nil
        #endif
        self.init(
            clipboard: clipboard,
            canSend: { [weak session] in
                session?.connectionState.isConnected == true
            },
            send: { [weak session] content in
                session?.sendClipboard(content)
            },
            contentSupport: { [weak session] in
                session?.clipboardContentSupport ?? .plainText
            },
            canRequestRemoteClipboard: { [weak session] in
                session?.connectionState.isConnected == true
                    && session?.supportsRemoteClipboardRequest == true
            },
            requestRemoteClipboard: { [weak session] in
                session?.requestRemoteClipboard()
            },
            requestAppleClipboard: { [weak session] in session?.requestAppleClipboard() },
            canControlRemoteSharedClipboard: { [weak session] in
                session?.connectionState.isConnected == true
                    && session?.supportsRemoteSharedClipboardControl == true
            },
            setRemoteSharedClipboard: { [weak session] enabled in
                session?.setRemoteSharedClipboardEnabled(enabled)
            },
            notificationCenter: .default,
            observesApplicationLifecycle: true,
            automaticallyMonitors: true,
            clipboardChangeNotification: clipboardChangeNotification,
            clipboardChangeObject: clipboardChangeObject
        )
        self.session = session
        self.sessionObserverID = session.addServerClipboardObserver { [weak self] event in
            self?.handleClipboardEvent(event)
        }
        self.connectionStateObserverID = session.addConnectionStateObserver { [weak self] state in
            self?.connectionStateDidChange(state)
        }
        self.capabilityObserverID = session.addClipboardCapabilityObserver { [weak self] in
            self?.clipboardCapabilitiesDidChange()
        }
        connectionStateDidChange(session.connectionState)
    }

    init(
        clipboard: any VNCClipboardProviding,
        canSend: @escaping () -> Bool,
        send: @escaping (VNCClipboardContent) -> Void,
        contentSupport: @escaping () -> VNCClipboardContentSupport = { .all },
        canRequestRemoteClipboard: @escaping () -> Bool = { false },
        requestRemoteClipboard: @escaping () -> Void = {},
        requestAppleClipboard: @escaping () -> UInt32? = { nil },
        now: @escaping () -> ContinuousClock.Instant = { .now },
        canControlRemoteSharedClipboard: @escaping () -> Bool = { false },
        setRemoteSharedClipboard: @escaping (Bool) -> Void = { _ in },
        notificationCenter: NotificationCenter = .default,
        observesApplicationLifecycle: Bool,
        automaticallyMonitors: Bool,
        clipboardChangeNotification: Notification.Name? = nil,
        clipboardChangeObject: Any? = nil
    ) {
        self.clipboard = clipboard
        self.canSend = canSend
        self.send = send
        self.contentSupport = contentSupport
        self.canRequestRemoteClipboard = canRequestRemoteClipboard
        self.requestRemoteClipboard = requestRemoteClipboard
        self.requestAppleClipboard = requestAppleClipboard
        self.now = now
        self.canControlRemoteSharedClipboard = canControlRemoteSharedClipboard
        self.setRemoteSharedClipboard = setRemoteSharedClipboard
        self.notificationCenter = notificationCenter
        self.automaticallyMonitors = automaticallyMonitors
        self.clipboardChangeNotification = clipboardChangeNotification
        self.clipboardChangeObject = clipboardChangeObject
        self.observedLocalChangeCount = clipboard.changeCount
        self.backgroundLocalChangeCount = clipboard.changeCount

        if observesApplicationLifecycle {
            installLifecycleObservers()
        }
    }

    isolated deinit {
        monitoringTask?.cancel()
        normalizationTask?.cancel()
        if let clipboardChangeObserver {
            notificationCenter.removeObserver(clipboardChangeObserver)
        }
        for observer in lifecycleObservers {
            notificationCenter.removeObserver(observer)
        }

        if let sessionObserverID {
            session?.removeServerClipboardObserver(sessionObserverID)
        }
        if let connectionStateObserverID {
            session?.removeConnectionStateObserver(connectionStateObserverID)
        }
        if let capabilityObserverID {
            session?.removeClipboardCapabilityObserver(capabilityObserverID)
        }
    }

    /// Send the device's clipboard to the remote server, keeping every
    /// representation the server can receive.
    public func sendClipboard() {
        guard !invalidated, canSend(),
              let content = clipboard.readContent(for: contentSupport()) else { return }
        observedLocalChangeCount = clipboard.changeCount
        syncedLocalContent = (content, clipboard.changeCount)
        transmit(content)
    }

    /// Request the current clipboard from a server that supports requests, or
    /// put the most recently published value on the device.
    public func getClipboard() {
        guard !invalidated else { return }
        if canSend(), canRequestRemoteClipboard() {
            pendingManualGet = true
            requestRemoteClipboard()
        } else if let latestRemoteContent {
            applyRemoteContent(latestRemoteContent, automatic: false)
        }
    }

    /// The Apple server can batch its change notices. Fetch on release of a
    /// forwarded Command-C/X, after the copy keystroke in the session input queue.
    func remoteKeyEvent(down: Bool, key: UInt32) {
        guard sharedClipboardEnabled, !invalidated, isEligible else { return }
        if (KeyboardInputHandler.keysymShiftL...KeyboardInputHandler.keysymSuperR).contains(key) {
            if down { remoteModifiers.insert(key) } else { remoteModifiers.remove(key) }
            return
        }
        if !down, copyRequestKey == key {
            requestPendingCopy()
            return
        }
        guard down, key == 0x63 || key == 0x78, // c or x
              remoteModifiers.contains(KeyboardInputHandler.keysymSuperL)
                || remoteModifiers.contains(KeyboardInputHandler.keysymSuperR),
              remoteModifiers.subtracting([KeyboardInputHandler.keysymSuperL,
                                          KeyboardInputHandler.keysymSuperR,
                                          KeyboardInputHandler.keysymCapsLock]).isEmpty,
              canSend(), canRequestRemoteClipboard() else { return }

        pendingRemoteCopy = newRemoteCopy()
        copyRequestKey = key
    }

    /// Remote apps implement their own Copy menus. Remember the clipboard
    /// before a pointer action so an ordinary click never imports an old value.
    func remotePointerWillSend(buttonMask: UInt8) {
        let pressed = buttonMask & 0x07 != 0
        guard pressed != pointerButtonDown else { return }
        pointerButtonDown = pressed
        guard pressed, isEligible, sharedClipboardEnabled, !invalidated,
              canSend(), canRequestRemoteClipboard() else { return }
        pendingRemoteCopy = newRemoteCopy()
        pendingRemoteCopy?.isPointerAction = true
    }

    private func newRemoteCopy() -> RemoteCopy {
        clipboard.remoteWrites.remoteCopyOwner = self
        let copy = RemoteCopy(localCount: clipboard.changeCount, deadline: now() + .seconds(3),
                              ownershipGeneration: clipboard.remoteWrites.ownershipGeneration)
        if case .known = remoteBaseline {
            copy.baseline = remoteBaseline
        } else if let id = requestAppleClipboard() {
            remoteBaseline = .requested(id)
            copy.baseline = remoteBaseline
        }
        return copy
    }

    private func requestPendingCopy() {
        guard copyRequestKey != nil || pendingRemoteCopy?.isPointerAction == true else { return }
        copyRequestKey = nil
        guard let copy = pendingRemoteCopy, ownsRemoteCopy(copy),
              now() < copy.deadline, copyRequest?.copy !== copy, snapshotRequest?.copy !== copy else { return }
        // An ordinary click must not displace a keyboard snapshot still downloading.
        if copy.isPointerAction, let previous = snapshotRequest, !previous.copy.isPointerAction,
           previous.content == nil, ownsRemoteCopy(previous.copy) { return }
        if let id = requestAppleClipboard() { snapshotRequest = (id, copy, nil) }
    }

    private func cancelRemoteCopy() {
        remoteModifiers.removeAll()
        copyRequestKey = nil
        pointerButtonDown = false
        remoteBaseline = .unknown
        pendingRemoteCopy = nil
        copyRequest = nil
        snapshotRequest = nil
        deferredCopy = nil
        if clipboard.remoteWrites.remoteCopyOwner === self { clipboard.remoteWrites.remoteCopyOwner = nil }
    }

    private func ownsRemoteCopy(_ copy: RemoteCopy) -> Bool {
        sharedClipboardEnabled && hostIsFocused
            && copy.ownershipGeneration == clipboard.remoteWrites.ownershipGeneration
            && clipboard.remoteWrites.remoteCopyOwner === self
            && copy.localCount == clipboard.changeCount
    }

    /// Focus participation is separate from application activity: switching
    /// panes must not replay a stale clipboard into a newly focused server.
    public func setHostFocused(_ focused: Bool) {
        guard hostIsFocused != focused else { return }
        hostIsFocused = focused
        cancelRemoteCopy()
        cancelAutomaticApply()
        if !focused {
            needsForegroundReconciliation = false
        }
        establishBaseline()
    }

    /// Window participation prevents two rootshell windows from sharing the
    /// same device clipboard with different VNC servers at once.
    public func setHostWindowActive(_ active: Bool) {
        guard hostWindowIsActive != active else { return }
        hostWindowIsActive = active
        if active, hostIsFocused, clipboard.remoteWrites.remoteCopyOwner !== self {
            clipboard.remoteWrites.remoteCopyOwner = nil
        }
        if !active, applicationIsActive {
            // Key-up can be delivered to the newly active application.
            requestPendingCopy()
            remoteModifiers.removeAll()
        } else if active, applicationIsActive, !needsForegroundReconciliation {
            cancelRemoteCopy()
        }
        if pendingRemoteCopy.map(ownsRemoteCopy) != true { cancelAutomaticApply() }

        if active, needsForegroundReconciliation {
            reconcileAfterForegroundIfPossible()
        } else if applicationIsActive {
            // This is an in-app window switch, not an app foreground. Start
            // fresh so the previously active server is never bridged here.
            needsForegroundReconciliation = false
            establishBaseline()
        }
    }

    /// Remove observers and stop polling. Safe to call more than once.
    public func invalidate() {
        guard !invalidated else { return }
        invalidated = true
        cancelRemoteCopy()
        monitoringTask?.cancel()
        monitoringTask = nil
        normalizationTask?.cancel()
        normalizationTask = nil
        stopClipboardObservation()
        for observer in lifecycleObservers {
            notificationCenter.removeObserver(observer)
        }
        lifecycleObservers.removeAll()
        if let sessionObserverID {
            session?.removeServerClipboardObserver(sessionObserverID)
        }
        if let connectionStateObserverID {
            session?.removeConnectionStateObserver(connectionStateObserverID)
        }
        if let capabilityObserverID {
            session?.removeClipboardCapabilityObserver(capabilityObserverID)
        }
        sessionObserverID = nil
        connectionStateObserverID = nil
        capabilityObserverID = nil
        session = nil
    }

    func receiveRemoteClipboardText(_ text: String) {
        receiveRemoteClipboardContent(.text(text))
    }

    func handleClipboardEvent(_ event: VNCSession.ClipboardEvent) {
        guard !invalidated else { return }
        switch event {
        case .key(let down, let key):
            remoteKeyEvent(down: down, key: key)
        case .pointer(let mask):
            remotePointerWillSend(buttonMask: mask)
        case .content(let content):
            receiveRemoteClipboardContent(content)
        case .requestFailed(let id):
            if case .requested(id) = remoteBaseline {
                remoteBaseline = .unknown
            }
            if copyRequest?.id == id { copyRequest = nil }
            if snapshotRequest?.id == id { snapshotRequest = nil }
            if ordinaryRequest?.id == id { ordinaryRequest = nil }
        case .requestStarted(let id, let changeNotice, let localUploadPending):
            if !changeNotice, pendingManualGet {
                manualAppleRequestID = id
                pendingManualGet = false
                return
            }
            if changeNotice, localUploadPending || (isEligible && clipboard.changeCount != observedLocalChangeCount) {
                // This notice precedes the local upload. Its reply cannot own the pasteboard,
                // even if the upload finishes before the reply arrives.
                ordinaryRequest = nil
                localClipboardDidChange()
                return
            }
            let localCount = applicationIsActive ? clipboard.changeCount : backgroundLocalChangeCount
            let outstandingCopy = copyRequest?.copy ?? snapshotRequest?.copy
            let precedingCopy = outstandingCopy.flatMap { ownsRemoteCopy($0) ? $0 : nil }
            ordinaryRequest = (id, localCount, changeNotice ? precedingCopy : nil)
            // A notice only supersedes the accepted download when it can
            // take over the same permission to finish after the app switch.
            if changeNotice, let copy = pendingRemoteCopy,
               now() < copy.deadline, ownsRemoteCopy(copy) {
                copyRequest = (id, copy)
                snapshotRequest = nil
                ordinaryRequest?.precedingCopy = nil
            }
        case .reply(let id, let content):
            receiveAppleReply(id: id, content: content)
        }
    }

    private func receiveAppleReply(id: UInt32, content: VNCClipboardContent?) {
        // A prior gesture may still be downloading after another gesture sampled its own baseline.
        if case .requested(id) = remoteBaseline { remoteBaseline = .known(content) }
        if let request = snapshotRequest, case .requested(id) = request.copy.baseline {
            request.copy.baseline = .known(content)
            finishSnapshotIfReady()
        }
        if case .requested(id) = pendingRemoteCopy?.baseline { pendingRemoteCopy?.baseline = .known(content) }
        if snapshotRequest?.id == id {
            guard let content else {
                snapshotRequest = nil
                return
            }
            snapshotRequest?.content = content
            finishSnapshotIfReady()
        } else if manualAppleRequestID == id {
            manualAppleRequestID = nil
            if let content {
                latestRemoteContent = content
                applyRemoteContent(content, automatic: false)
            }
        } else if let request = copyRequest, request.id == id {
            copyRequest = nil
            if ordinaryRequest?.id == id { ordinaryRequest = nil }
            if let content { receiveRemoteClipboardContent(content, for: request.copy) }
        } else if let ordinary = ordinaryRequest, ordinary.id == id {
            ordinaryRequest = nil
            guard ordinary.localCount == clipboard.changeCount, let content else { return }
            if let copy = ordinary.precedingCopy {
                // The notice itself confirms a copy. Its usable reply can finish the
                // outstanding handoff even if the original request never receives a reply.
                if copyRequest?.copy === copy { copyRequest = nil }
                if snapshotRequest?.copy === copy { snapshotRequest = nil }
                receiveRemoteClipboardContent(content, for: copy)
            } else {
                receiveRemoteClipboardContent(content, for: nil)
            }
        } else if id == 0, let content {
            receiveRemoteClipboardContent(content, for: nil)
        }
    }

    private func finishSnapshotIfReady() {
        guard let request = snapshotRequest, let content = request.content,
              case .known(let baseline) = request.copy.baseline else { return }
        snapshotRequest = nil
        if content != baseline { receiveRemoteClipboardContent(content, for: request.copy) }
    }

    func receiveRemoteClipboardContent(_ content: VNCClipboardContent) {
        if pendingManualGet {
            pendingManualGet = false
            latestRemoteContent = content
            applyRemoteContent(content, automatic: false)
        } else {
            receiveRemoteClipboardContent(content, for: nil)
        }
    }

    private func receiveRemoteClipboardContent(_ content: VNCClipboardContent, for copy: RemoteCopy?) {
        guard !invalidated else { return }
        latestRemoteContent = content
        if let copy {
            guard ownsRemoteCopy(copy) else {
                backgroundRemoteGeneration = remoteGeneration
                return
            }
            // A confirmed value supersedes any earlier unanswered baseline.
            remoteBaseline = .known(content)
            if applicationIsActive, !hostWindowIsActive {
                supersedePendingApply()
                deferredCopy = (content, copy, remoteGeneration)
                return
            }
        }
        remoteGeneration &+= 1
        guard sharedClipboardEnabled, isEligible || (!applicationIsActive && copy != nil) else { return }
        remoteBaseline = .known(content)
        applyRemoteContent(content, automatic: true, copy: copy)
    }

    func localClipboardDidChange() {
        guard !invalidated else { return }
        let currentChangeCount = clipboard.changeCount
        guard currentChangeCount != observedLocalChangeCount else { return }

        if isApplyingRemoteContent || !sharedClipboardEnabled || !isEligible {
            // Changes made by us, while sharing is disabled, or while another
            // pane/window owns focus must never be replayed later.
            observedLocalChangeCount = currentChangeCount
            return
        }

        // Keep the change unacknowledged while reconnecting. The connection
        // observer retries it immediately after the session is operational,
        // and polling remains a fallback for custom transports.
        guard canSend() else { return }
        flushLocalClipboard()
    }

    func connectionStateDidChange(_ state: VNCConnectionState) {
        guard !invalidated else { return }

        switch state {
        case .connected:
            if sharedClipboardEnabled, canControlRemoteSharedClipboard() {
                setRemoteSharedClipboard(true)
            }
            // Flush a local change retained during automatic reconnect.
            localClipboardDidChange()
        case .reconnecting:
            clearRemoteCache()
            // Do not establish a local baseline: local changes must remain
            // pending until this same connection comes back.
        case .connecting:
            clearRemoteCache()
            // A fresh connect may target another server. Never bridge local
            // changes accumulated while the prior connection was closed.
            establishBaseline()
        case .idle, .disconnecting, .disconnected, .failed:
            clearRemoteCache()
        }
    }

    /// ExtendedClipboard caps arrive after the connection is up, so shared
    /// mode may only become controllable now.
    func clipboardCapabilitiesDidChange() {
        guard !invalidated else { return }
        if sharedClipboardEnabled, canControlRemoteSharedClipboard() {
            setRemoteSharedClipboard(true)
        }
        retryAutomaticFlush()
    }

    func applicationWillResignActive() {
        guard applicationIsActive else { return }
        if hostWindowIsActive { requestPendingCopy() }
        remoteModifiers.removeAll()
        applicationIsActive = false
        if pendingRemoteCopy.map(ownsRemoteCopy) != true { cancelAutomaticApply() }
        backgroundLocalChangeCount = clipboard.changeCount
        backgroundRemoteGeneration = remoteGeneration
        needsForegroundReconciliation = true
        deferredForegroundChangeCount = nil
        if let copy = pendingRemoteCopy, clipboard.remoteWrites.remoteCopyOwner === self,
           now() < copy.deadline || copyRequest?.copy === copy || snapshotRequest?.copy === copy {
            // A local copy can beat both the reply and the app resignation.
            if syncedLocalContent?.changeCount != clipboard.changeCount {
                backgroundLocalChangeCount = copy.localCount
            }
        }
        applyDeferredCopyIfCurrent()
    }

    @discardableResult
    private func applyDeferredCopyIfCurrent() -> Bool {
        guard let deferred = deferredCopy else { return false }
        deferredCopy = nil
        guard ownsRemoteCopy(deferred.copy) else { return false }
        // A later ordinary reply may have refreshed the snapshot while the window was inactive.
        let content = deferred.generation == remoteGeneration ? deferred.content : latestRemoteContent
        guard let content else { return false }
        receiveRemoteClipboardContent(content, for: deferred.copy)
        return true
    }

    func applicationDidBecomeActive() {
        applicationIsActive = true
        reconcileAfterForegroundIfPossible()
        if needsForegroundReconciliation {
            deferredForegroundChangeCount = clipboard.changeCount
        }
    }

    private var isEligible: Bool {
        hostIsFocused && hostWindowIsActive && applicationIsActive
    }

    private func transmit(_ content: VNCClipboardContent) {
        send(content)
        // The Apple encoder can reduce an upload to fit the wire limit.
        // The next click samples what the server actually stored.
        remoteBaseline = .unknown
        if pendingRemoteCopy?.isPointerAction == true {
            pendingRemoteCopy = nil
            snapshotRequest = nil
        }
        if let text = content.plainText {
            onTransfer?(.deviceToRemote, text)
        }
    }

    /// Shared-mode send of the device clipboard, remembered with the support
    /// it was read under so retryAutomaticFlush can resend it.
    private func flushLocalClipboard() {
        let support = contentSupport()
        observedLocalChangeCount = clipboard.changeCount
        automaticFlush = (clipboard.changeCount, support)
        guard let content = clipboard.readContent(for: support) else { return }
        syncedLocalContent = (content, clipboard.changeCount)
        transmit(content)
    }

    /// A change flushed before the server's support grew (ExtendedClipboard
    /// caps after connect) went out without what the server now accepts.
    private func retryAutomaticFlush() {
        guard let flush = automaticFlush,
              flush.changeCount == clipboard.changeCount,
              sharedClipboardEnabled, isEligible, canSend() else { return }
        let support = contentSupport()
        guard support != flush.support, support.acceptsRichContent else { return }
        automaticFlush = (flush.changeCount, support)
        guard let content = clipboard.readContent(for: support),
              content.hasRichContent else { return }
        transmit(content)
    }

    /// Items with only TIFF or BMP images get a PNG first, built off the main
    /// actor. The write is dropped if a newer apply or a local copy wins, or,
    /// for shared-mode applies, once this pane stops being eligible. Shared
    /// mode skips content the device clipboard already holds.
    private func applyRemoteContent(
        _ content: VNCClipboardContent, automatic: Bool, copy: RemoteCopy? = nil
    ) {
        supersedePendingApply()
        if automatic, let synced = syncedLocalContent,
           synced.changeCount == clipboard.changeCount, synced.content == content {
            return
        }
        guard VNCClipboardImageNormalizer.needsNormalization(content) else {
            writeRemoteContent(content, original: content, copy: copy)
            return
        }

        let generation = applyGeneration
        let sourceGeneration = remoteGeneration
        let localChangeCount = clipboard.changeCount
        pendingApplyIsAutomatic = automatic
        normalizationTask = Task { [weak self] in
            let normalized = await Task.detached(priority: .userInitiated) {
                VNCClipboardImageNormalizer.normalized(content)
            }.value
            guard let self, !Task.isCancelled, !self.invalidated,
                  self.applyGeneration == generation,
                  self.clipboard.changeCount == localChangeCount else { return }
            self.normalizationTask = nil
            if let copy {
                guard self.ownsRemoteCopy(copy) else { return }
                if self.applicationIsActive, !self.hostWindowIsActive {
                    self.deferredCopy = (content, copy, sourceGeneration)
                    return
                }
            } else if automatic, !(self.sharedClipboardEnabled && self.isEligible) {
                return
            }
            self.writeRemoteContent(normalized, original: content, copy: copy)
        }
    }

    private func supersedePendingApply() {
        applyGeneration &+= 1
        normalizationTask?.cancel()
        normalizationTask = nil
        deferredCopy = nil
    }

    private func cancelAutomaticApply() {
        guard normalizationTask != nil, pendingApplyIsAutomatic else { return }
        supersedePendingApply()
    }

    private func writeRemoteContent(
        _ content: VNCClipboardContent, original: VNCClipboardContent, copy: RemoteCopy?
    ) {
        let currentGesture = pendingRemoteCopy.flatMap { ownsRemoteCopy($0) ? $0 : nil }
        let localCount = clipboard.changeCount
        isApplyingRemoteContent = true
        clipboard.write(content)
        observedLocalChangeCount = clipboard.changeCount
        clipboard.remoteWrites.latest = (clipboard.changeCount, ObjectIdentifier(self))
        syncedLocalContent = (original, clipboard.changeCount)
        if let copy {
            // A server may answer before the remote app has handled the key.
            // Keep accepting its ensuing change notice until this handoff expires.
            copy.localCount = clipboard.changeCount
            copy.baseline = .known(original)
        }
        if ordinaryRequest?.localCount == localCount { ordinaryRequest?.localCount = clipboard.changeCount }
        currentGesture?.localCount = clipboard.changeCount
        currentGesture?.baseline = .known(original)
        if !applicationIsActive {
            backgroundLocalChangeCount = clipboard.changeCount
            if latestRemoteContent == original { backgroundRemoteGeneration = remoteGeneration }
        }
        isApplyingRemoteContent = false
        if let text = content.plainText {
            onTransfer?(.remoteToDevice, text)
        }
    }

    /// Reconciliation keeps a deferred flush the clipboard still matches.
    private func establishBaseline(keepingAutomaticFlush: Bool = false) {
        if !keepingAutomaticFlush { automaticFlush = nil }
        observedLocalChangeCount = clipboard.changeCount
        backgroundLocalChangeCount = clipboard.changeCount
        backgroundRemoteGeneration = remoteGeneration
    }

    private func reconcileAfterForegroundIfPossible() {
        guard needsForegroundReconciliation,
              sharedClipboardEnabled,
              applicationIsActive,
              hostIsFocused,
              hostWindowIsActive else { return }
        needsForegroundReconciliation = false

        let localChanged = clipboard.changeCount != backgroundLocalChangeCount
        // Another window took the foreground first, and the clipboard moved
        // since or gained what that window's server put there while away:
        // a window switch, never bridged.
        let heldByAnotherPane = clipboard.remoteWrites.latest.map {
            $0.changeCount == clipboard.changeCount && $0.writer != ObjectIdentifier(self)
        } ?? false
        let movedSinceForeground = deferredForegroundChangeCount.map {
            $0 != clipboard.changeCount
        } ?? false
        if movedSinceForeground || (localChanged && heldByAnotherPane) {
            deferredCopy = nil
            establishBaseline()
            return
        }

        let remoteChanged = remoteGeneration != backgroundRemoteGeneration
        if localChanged {
            deferredCopy = nil
            if canSend() { flushLocalClipboard() }
        } else if applyDeferredCopyIfCurrent() {
            return
        } else if remoteChanged, let latestRemoteContent {
            applyRemoteContent(latestRemoteContent, automatic: true)
        } else {
            // Caps may have arrived while this pane could not send.
            retryAutomaticFlush()
            establishBaseline(keepingAutomaticFlush: true)
        }
    }

    private func startMonitoring() {
        guard monitoringTask == nil, !invalidated else { return }
        monitoringTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(500))
                } catch {
                    return
                }
                guard let self else { return }
                self.localClipboardDidChange()
            }
        }
    }

    /// Observe pasteboard changes only while automatic sharing is enabled.
    /// NotificationCenter delivers observers registered on a specific queue
    /// synchronously. Using the posting queue here is essential: Ghostty can
    /// mutate the pasteboard from its surface API queue while holding the
    /// surface mutex, so waiting for `.main` would deadlock with main-thread
    /// surface queries. The callback itself only enqueues MainActor work.
    private func startClipboardObservation() {
        guard clipboardChangeObserver == nil,
              !invalidated,
              let clipboardChangeNotification else { return }

        clipboardChangeObserver = notificationCenter.addObserver(
            forName: clipboardChangeNotification,
            object: clipboardChangeObject,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.localClipboardDidChange()
            }
        }
    }

    private func stopClipboardObservation() {
        guard let clipboardChangeObserver else { return }
        notificationCenter.removeObserver(clipboardChangeObserver)
        self.clipboardChangeObserver = nil
    }

    private func clearRemoteCache() {
        cancelRemoteCopy()
        ordinaryRequest = nil
        manualAppleRequestID = nil
        latestRemoteContent = nil
        pendingManualGet = false
        applyGeneration &+= 1
        normalizationTask?.cancel()
        normalizationTask = nil
        // Treat the boundary as a generation change so pending foreground
        // reconciliation cannot apply clipboard data from the prior server.
        remoteGeneration &+= 1
    }

    private func installLifecycleObservers() {
        #if targetEnvironment(macCatalyst)
        // Switching Mac apps leaves the UIKit application active; only
        // AppKit reports it.
        applicationIsActive = UIApplication.shared.applicationState == .active
        let willResignActive = Notification.Name("NSApplicationWillResignActiveNotification")
        let didBecomeActive = Notification.Name("NSApplicationDidBecomeActiveNotification")
        #elseif canImport(UIKit)
        applicationIsActive = UIApplication.shared.applicationState == .active
        let willResignActive = UIApplication.willResignActiveNotification
        let didBecomeActive = UIApplication.didBecomeActiveNotification
        #elseif canImport(AppKit)
        applicationIsActive = NSApplication.shared.isActive
        let willResignActive = NSApplication.willResignActiveNotification
        let didBecomeActive = NSApplication.didBecomeActiveNotification
        #endif
        #if os(macOS) || targetEnvironment(macCatalyst)
        // A non-VNC window can also take key. Returning to the very window
        // that resigned preserves its accepted clipboard transfer.
        let resigned = Notification.Name("NSWindowDidResignKeyNotification")
        let becameKey = Notification.Name("NSWindowDidBecomeKeyNotification")
        for name in [resigned, becameKey] {
            lifecycleObservers.append(notificationCenter.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] notification in
                guard let window = notification.object as? NSObject else { return }
                let windowID = ObjectIdentifier(window)
                MainActor.assumeIsolated {
                    guard let self, self.clipboard.remoteWrites.remoteCopyOwner === self else { return }
                    if name == resigned {
                        self.departingKeyWindowID = windowID
                    } else if self.departingKeyWindowID != windowID {
                        self.clipboard.remoteWrites.remoteCopyOwner = nil
                    }
                }
            })
        }
        #endif
        observeLifecycle(willResignActive) { $0.applicationWillResignActive() }
        observeLifecycle(didBecomeActive) { $0.applicationDidBecomeActive() }
    }

    private func observeLifecycle(
        _ name: Notification.Name,
        _ handler: @escaping @MainActor (VNCClipboardSynchronizer) -> Void
    ) {
        lifecycleObservers.append(notificationCenter.addObserver(
            forName: name,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                if let self { handler(self) }
            }
        })
    }
}
