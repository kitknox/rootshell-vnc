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

@MainActor
protocol VNCClipboardProviding: AnyObject {
    var changeCount: Int { get }

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
    private var normalizationTask: Task<Void, Never>?
    @ObservationIgnored
    private var pendingApplyIsAutomatic = false
    /// The last automatic flush and the support it was read under. Support
    /// that grows later (ExtendedClipboard caps) resends it.
    @ObservationIgnored
    private var automaticFlush: (changeCount: Int, support: VNCClipboardContentSupport)?
    @ObservationIgnored
    private var observedLocalChangeCount: Int
    @ObservationIgnored
    private var backgroundLocalChangeCount: Int
    @ObservationIgnored
    private var backgroundRemoteGeneration: UInt64 = 0
    @ObservationIgnored
    private var isApplyingRemoteContent = false
    @ObservationIgnored
    private var hostIsFocused = true
    @ObservationIgnored
    private var hostWindowIsActive = true
    @ObservationIgnored
    private var applicationIsActive = true
    @ObservationIgnored
    private var needsForegroundReconciliation = false
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
        self.sessionObserverID = session.addServerClipboardObserver { [weak self] content in
            self?.receiveRemoteClipboardContent(content)
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

    /// Focus participation is separate from application activity: switching
    /// panes must not replay a stale clipboard into a newly focused server.
    public func setHostFocused(_ focused: Bool) {
        guard hostIsFocused != focused else { return }
        hostIsFocused = focused
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
        cancelAutomaticApply()

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

    func receiveRemoteClipboardContent(_ content: VNCClipboardContent) {
        guard !invalidated else { return }
        latestRemoteContent = content
        remoteGeneration &+= 1

        if pendingManualGet {
            pendingManualGet = false
            applyRemoteContent(content, automatic: false)
            return
        }

        guard sharedClipboardEnabled, isEligible else { return }
        applyRemoteContent(content, automatic: true)
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
        applicationIsActive = false
        cancelAutomaticApply()
        backgroundLocalChangeCount = clipboard.changeCount
        backgroundRemoteGeneration = remoteGeneration
        needsForegroundReconciliation = true
    }

    func applicationDidBecomeActive() {
        applicationIsActive = true
        reconcileAfterForegroundIfPossible()
    }

    private var isEligible: Bool {
        hostIsFocused && hostWindowIsActive && applicationIsActive
    }

    private func transmit(_ content: VNCClipboardContent) {
        send(content)
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
    /// for shared-mode applies, once this pane stops being eligible.
    private func applyRemoteContent(_ content: VNCClipboardContent, automatic: Bool) {
        applyGeneration &+= 1
        normalizationTask?.cancel()
        normalizationTask = nil
        guard VNCClipboardImageNormalizer.needsNormalization(content) else {
            writeRemoteContent(content)
            return
        }

        let generation = applyGeneration
        let localChangeCount = clipboard.changeCount
        pendingApplyIsAutomatic = automatic
        normalizationTask = Task { [weak self] in
            let normalized = await Task.detached(priority: .userInitiated) {
                VNCClipboardImageNormalizer.normalized(content)
            }.value
            guard let self, !Task.isCancelled, !self.invalidated,
                  self.applyGeneration == generation,
                  self.clipboard.changeCount == localChangeCount,
                  !automatic || (self.sharedClipboardEnabled && self.isEligible)
            else { return }
            self.normalizationTask = nil
            self.writeRemoteContent(normalized)
        }
    }

    private func cancelAutomaticApply() {
        guard normalizationTask != nil, pendingApplyIsAutomatic else { return }
        normalizationTask?.cancel()
        normalizationTask = nil
        applyGeneration &+= 1
    }

    private func writeRemoteContent(_ content: VNCClipboardContent) {
        isApplyingRemoteContent = true
        clipboard.write(content)
        observedLocalChangeCount = clipboard.changeCount
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
        let remoteChanged = remoteGeneration != backgroundRemoteGeneration
        if localChanged {
            if canSend() { flushLocalClipboard() }
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
        #if canImport(UIKit)
        applicationIsActive = UIApplication.shared.applicationState == .active
        lifecycleObservers.append(notificationCenter.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.applicationWillResignActive()
            }
        })
        lifecycleObservers.append(notificationCenter.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.applicationDidBecomeActive()
            }
        })
        #elseif canImport(AppKit)
        applicationIsActive = NSApplication.shared.isActive
        lifecycleObservers.append(notificationCenter.addObserver(
            forName: NSApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.applicationWillResignActive()
            }
        })
        lifecycleObservers.append(notificationCenter.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.applicationDidBecomeActive()
            }
        })
        #endif
    }
}
