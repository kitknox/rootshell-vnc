import Foundation
import Observation
import RFBProtocol
import RFBTransport
import UniformTypeIdentifiers

/// One upload or download in a Screen Sharing session with a Mac.
public struct VNCFileTransfer: Identifiable, Equatable, Sendable {
    public enum Direction: Sendable, Equatable {
        case upload
        case download
    }

    public enum State: Sendable, Equatable {
        /// An upload drag is over the remote screen.
        case dragging
        /// Copying dropped files or waiting for the Mac.
        case preparing
        case transferring
        case completed
        case failed(String)
        case cancelled
    }

    public let id: UUID
    public let direction: Direction
    public internal(set) var name: String
    public internal(set) var itemCount: Int
    public internal(set) var totalBytes: Int64 = 0
    public internal(set) var completedBytes: Int64 = 0
    public internal(set) var state: State
    /// The folder on the Mac an upload was dropped into.
    public internal(set) var remoteFolder: String?
    /// Downloaded items, set once a download completes.
    public internal(set) var localURLs: [URL] = []
    /// The Mac's drag image for a download.
    public internal(set) var dragImagePNG: Data?

    public var isActive: Bool {
        switch state {
        case .dragging, .preparing, .transferring: return true
        case .completed, .failed, .cancelled: return false
        }
    }

    public var fractionCompleted: Double? {
        guard totalBytes > 0 else { return state == .completed ? 1 : nil }
        return min(1, Double(completedBytes) / Double(totalBytes))
    }
}

/// Drag-and-drop file transfer with a Mac. Uploads follow a drop on the
/// remote screen; downloads start when a drag on the Mac is released over
/// the host's download target (``dragOutTarget``).
@MainActor
@Observable
public final class VNCFileTransferController {
    public private(set) var transfers: [VNCFileTransfer] = []
    public private(set) var canUpload = false
    public private(set) var canDownload = false
    /// A left-button drag is moving on the remote screen.
    public private(set) var remoteDragInProgress = false
    /// Names of the files the Mac says are being dragged on its screen.
    public private(set) var remoteDraggedNames: [String] = []
    @ObservationIgnored private(set) var remoteDraggedPaths: [String] = []
    /// The remote pointer is over ``dragOutTarget`` during that drag.
    public private(set) var remoteDragOverTarget = false

    /// The Mac is dragging files on its screen, so the host shows its target.
    public var showsDragOutTarget: Bool {
        canDownload && remoteDragInProgress && !remoteDraggedNames.isEmpty
    }
    /// Framebuffer rectangle under the host's download target, or nil when
    /// none is shown.
    public var dragOutTarget: CGRect? {
        didSet {
            if dragOutTarget == nil { remoteDragOverTarget = false }
        }
    }

    @ObservationIgnored weak var session: VNCSession?
    @ObservationIgnored private var nextSessionID: UInt32 = 0
    @ObservationIgnored private var lastHandle: UInt32 = 0
    @ObservationIgnored private var uploads: [UUID: UploadJob] = [:]
    @ObservationIgnored private var downloads: [UUID: DownloadJob] = [:]
    @ObservationIgnored private var owners: [UInt32: UUID] = [:]
    @ObservationIgnored private var activeUploadDrag: UUID?
    @ObservationIgnored private var lastUploadDragPoint: (x: UInt16, y: UInt16) = (0, 0)
    /// When the last drag-out request was sent; replies after the deadline are ignored.
    @ObservationIgnored private var pendingDragOut: ContinuousClock.Instant?
    @ObservationIgnored private var pressPoint: (x: UInt16, y: UInt16)?

    static let dragThreshold = 16
    static let dropTimeout: Duration = .seconds(20)
    static let completionTimeout: Duration = .seconds(30)
    static let dragOutReplyWindow: Duration = .seconds(10)
    static let escapeKeysym: UInt32 = 0xff1b

    init() {}

    public var hasActiveTransfers: Bool { transfers.contains(where: \.isActive) }

    // MARK: - Host actions

    public func cancel(_ id: UUID) {
        guard let index = index(of: id), transfers[index].isActive else { return }
        if activeUploadDrag == id {
            cancelUploadDrag()
            return
        }
        if let job = uploads[id] {
            job.stagingTask?.cancel()
            job.timeout?.cancel()
            if let run = job.runTask, !job.streamFinished {
                // runUpload stops the Mac's sessions once its worker has exited,
                // so a stop never overtakes a chunk already being sent.
                job.cancelRequested = true
                run.cancel()
                update(id) { $0.state = .cancelled }
            } else {
                for session in job.openSessions {
                    send(AppleFileTransferProtocol.stopMessage(session: session))
                }
                finishUpload(id, state: .cancelled)
            }
        } else if let job = downloads[id], !job.moving {
            for session in job.openSessions {
                send(AppleFileTransferProtocol.stopMessage(session: session))
            }
            job.writer.discard()
            finishDownload(id, state: .cancelled)
        }
    }

    /// Removes a finished transfer and its local files.
    public func remove(_ id: UUID) {
        cancel(id)
        guard let index = index(of: id) else { return }
        let transfer = transfers.remove(at: index)
        if transfer.direction == .download {
            for url in transfer.localURLs {
                try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            }
        }
    }

    public func clearFinished() {
        for transfer in transfers where !transfer.isActive {
            remove(transfer.id)
        }
    }

    /// The host moved a download's files elsewhere (for example Save to Files).
    public func downloadWasSaved(_ id: UUID) {
        guard let index = index(of: id) else { return }
        let transfer = transfers.remove(at: index)
        // Each download has its own folder; only leftovers remain after a move.
        if let folder = transfer.localURLs.first?.deletingLastPathComponent() {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    // MARK: - Session plumbing

    func updateSupport(upload: Bool, download: Bool) {
        canUpload = upload
        canDownload = download
    }

    func transportDidEnd() {
        canUpload = false
        canDownload = false
        activeUploadDrag = nil
        pendingDragOut = nil
        remoteDraggedNames = []
        remoteDraggedPaths = []
        pressPoint = nil
        remoteDragInProgress = false
        remoteDragOverTarget = false
        let message = String(localized: "The connection closed.", bundle: .module)
        for transfer in transfers where transfer.isActive {
            // A local move needs no connection; it finishes on its own.
            if downloads[transfer.id]?.moving == true { continue }
            if let job = uploads[transfer.id] {
                job.stagingTask?.cancel()
                job.runTask?.cancel()
                job.timeout?.cancel()
                finishUpload(transfer.id, state: .failed(message))
            } else if let job = downloads[transfer.id] {
                job.writer.discard()
                finishDownload(transfer.id, state: .failed(message))
            } else {
                update(transfer.id) { $0.state = .failed(message) }
            }
        }
        owners.removeAll()
    }

    /// Sees every pointer event before it is queued, so a drag-out request
    /// precedes the release that drops onto the Mac's helper.
    func observePointer(buttonMask: UInt8, x: UInt16, y: UInt16) {
        guard activeUploadDrag == nil else { return }
        guard buttonMask & TouchInputHandler.leftButton != 0 else {
            if pressPoint != nil, showsDragOutTarget, targetContains(x, y) {
                requestDragOut()
            }
            pressPoint = nil
            remoteDragInProgress = false
            remoteDragOverTarget = false
            if !remoteDraggedNames.isEmpty { remoteDraggedNames = [] }
            remoteDraggedPaths = []
            return
        }
        guard let press = pressPoint else {
            pressPoint = (x, y)
            return
        }
        if !remoteDragInProgress,
           abs(Int(x) - Int(press.x)) + abs(Int(y) - Int(press.y)) >= Self.dragThreshold {
            remoteDragInProgress = true
        }
        let over = showsDragOutTarget && targetContains(x, y)
        if over != remoteDragOverTarget { remoteDragOverTarget = over }
    }

    func handle(_ request: AppleFileTransferProtocol.UploadRequest) {
        guard let job = uploads.values.first(where: {
            $0.handle == request.handle && $0.destination == nil
        }) else { return }
        job.destination = request.destinationPath
        job.timeout?.cancel()
        job.timeout = nil
        update(job.id) { $0.remoteFolder = request.destinationPath }
        startUploadIfReady(job)
    }

    func handle(_ reply: AppleFileTransferProtocol.DragOutReply) {
        guard !reply.paths.isEmpty else { return }
        // The Mac answers with its own handle, and may send several replies
        // (some empty), so take the first one with files after a request.
        if let sent = pendingDragOut, ContinuousClock.now - sent < Self.dragOutReplyWindow {
            pendingDragOut = nil
            startDownload(paths: reply.paths, dragImage: reply.dragImagePNG)
        } else if pressPoint != nil {
            // Unasked, it announces a file drag that started on its screen.
            remoteDraggedNames = reply.paths.map { ($0 as NSString).lastPathComponent }
            remoteDraggedPaths = reply.paths
        }
    }

    /// `acknowledge` releases the transport's read credit once file data is written.
    func handle(
        _ message: AppleFileTransferProtocol.ServerMessage,
        acknowledge: @escaping @Sendable (Int) -> Void
    ) {
        let bytes = message.dataByteCount
        guard let id = owners[message.session], let job = downloads[id] else {
            acknowledge(bytes)
            handleUploadMessage(message)
            return
        }
        if case .end = message { job.openSessions.remove(message.session) }
        job.writer.handle(message) { acknowledge(bytes) }
    }

    private func handleUploadMessage(_ message: AppleFileTransferProtocol.ServerMessage) {
        guard let id = owners[message.session] else { return }
        if let job = uploads[id] {
            switch message {
            case .completion(let session, let status, let name):
                job.openSessions.remove(session)
                owners[session] = nil
                if status != 0, job.failure == nil {
                    job.failure = Self.uploadFailureMessage(status: status, name: name)
                }
                if job.openSessions.isEmpty, job.streamFinished {
                    job.timeout?.cancel()
                    finishUpload(id, state: job.failure.map { .failed($0) } ?? .completed)
                }
            default:
                break
            }
        }
    }

    // MARK: - Upload

    /// A file drag entered the remote screen at framebuffer `x`, `y`.
    func beginUploadDrag(names: [String], x: UInt16, y: UInt16) -> Bool {
        guard canUpload, activeUploadDrag == nil, !names.isEmpty, let session else { return false }
        let handle = makeHandle()
        let folder = FileManager.default.temporaryDirectory
        let urls = names.map { folder.appendingPathComponent($0) }
        guard let message = try? AppleFileTransferProtocol.dragInMessage(
            handle: handle, fileURLs: urls) else { return false }

        let transfer = VNCFileTransfer(
            id: UUID(),
            direction: .upload,
            name: Self.displayName(names),
            itemCount: names.count,
            state: .dragging)
        transfers.append(transfer)
        uploads[transfer.id] = UploadJob(id: transfer.id, handle: handle)
        activeUploadDrag = transfer.id
        pressPoint = nil
        remoteDragInProgress = false
        lastUploadDragPoint = (x, y)

        // The Mac's helper starts its drag at the pointer and drops on the next
        // release. The server holds back this press, and an early release,
        // until the helper is ready, so hold the button until the drop.
        session.sendPointerEvent(buttonMask: 0, x: x, y: y)
        session.enqueueFileTransferControl(message)
        session.sendPointerEvent(buttonMask: TouchInputHandler.leftButton, x: x, y: y)
        return true
    }

    func moveUploadDrag(x: UInt16, y: UInt16) {
        guard activeUploadDrag != nil else { return }
        lastUploadDragPoint = (x, y)
        session?.sendPointerEvent(buttonMask: TouchInputHandler.leftButton, x: x, y: y)
    }

    /// The drag left the remote screen or ended without a drop here.
    func cancelUploadDrag() {
        guard let id = activeUploadDrag else { return }
        activeUploadDrag = nil
        let point = lastUploadDragPoint
        // Escape cancels the Mac's drag before the button comes up.
        session?.sendKeyEvent(downFlag: true, key: Self.escapeKeysym)
        session?.sendKeyEvent(downFlag: false, key: Self.escapeKeysym)
        session?.sendPointerEvent(buttonMask: 0, x: point.x, y: point.y)
        uploads[id] = nil
        transfers.removeAll { $0.id == id }
    }

    func dropUpload(itemProviders: [NSItemProvider], x: UInt16, y: UInt16) {
        guard let id = activeUploadDrag, let job = uploads[id] else { return }
        activeUploadDrag = nil
        session?.sendPointerEvent(buttonMask: TouchInputHandler.leftButton, x: x, y: y)
        session?.sendPointerEvent(buttonMask: 0, x: x, y: y)
        update(id) { $0.state = .preparing }

        let staging = Self.temporaryFolder("Screen Sharing Uploads")
        job.stagingFolder = staging
        job.timeout = Task { [weak self] in
            try? await Task.sleep(for: Self.dropTimeout)
            guard !Task.isCancelled else { return }
            self?.finishUpload(id, state: .failed(String(
                localized: "The Mac didn't accept the files there. Drop them on a folder or the desktop.",
                bundle: .module)))
        }
        job.stagingTask = Task { [weak self] in
            let result = await Self.stage(itemProviders, into: staging)
            guard let self, !Task.isCancelled, self.uploads[id] != nil else { return }
            job.stagingFailures = result.failedNames
            guard !result.staged.isEmpty else {
                self.finishUpload(id, state: .failed(String(
                    localized: "The dropped items couldn't be read.", bundle: .module)))
                return
            }
            job.staged = result.staged
            self.startUploadIfReady(job)
        }
    }

    /// Uploads local items straight into a folder on the Mac, without a drag.
    func upload(_ urls: [URL], toRemoteFolder destination: String) {
        let transfer = VNCFileTransfer(
            id: UUID(),
            direction: .upload,
            name: Self.displayName(urls.map(\.lastPathComponent)),
            itemCount: urls.count,
            state: .preparing,
            remoteFolder: destination)
        transfers.append(transfer)
        let job = UploadJob(id: transfer.id, handle: 0)
        job.staged = urls
        job.destination = destination
        uploads[transfer.id] = job
        startUploadIfReady(job)
    }

    private func startUploadIfReady(_ job: UploadJob) {
        guard job.runTask == nil,
              let staged = job.staged,
              let destination = job.destination else { return }
        guard let transport = session?.activeTransport else {
            finishUpload(job.id, state: .failed(String(
                localized: "The connection closed.", bundle: .module)))
            return
        }
        job.runTask = Task { [weak self] in
            await self?.runUpload(job, staged: staged, destination: destination, transport: transport)
        }
    }

    private func runUpload(
        _ job: UploadJob,
        staged: [URL],
        destination: String,
        transport: TransportSession
    ) async {
        let id = job.id
        let plan: [UploadPlan.Root]
        do {
            plan = try await Task.detached { try UploadPlan.make(staged) }.value
        } catch {
            finishUpload(id, state: .failed(error.localizedDescription))
            return
        }
        // Cancelled while planning: nothing has reached the Mac yet.
        guard !Task.isCancelled, uploads[id] != nil else {
            finishUpload(id, state: .cancelled)
            return
        }
        var sessions: [UInt32] = []
        for _ in plan {
            let session = makeSessionID()
            sessions.append(session)
            owners[session] = id
            job.openSessions.insert(session)
        }
        update(id) {
            $0.state = .transferring
            $0.totalBytes = plan.reduce(0) { $0 + $1.bytes }
            $0.itemCount = plan.count + job.stagingFailures.count
            $0.name = Self.displayName(plan.map(\.name) + job.stagingFailures)
        }
        // Special files inside dropped folders make the result partial too.
        job.stagingFailures += plan.flatMap(\.skipped)

        let progress = ProgressThrottle { [weak self] sent in
            self?.update(id) { $0.completedBytes = sent }
        }
        // Detached so file reads stay off the main actor; cancelling the run
        // task must reach it explicitly.
        let worker = Task.detached {
            try await UploadPlan.stream(
                plan,
                sessions: sessions,
                destination: destination,
                transport: transport,
                progress: progress)
        }
        do {
            try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }
        } catch {
            guard uploads[id] != nil else { return }
            for session in job.openSessions {
                send(AppleFileTransferProtocol.stopMessage(session: session))
            }
            finishUpload(id, state: job.cancelRequested || error is CancellationError
                ? .cancelled
                : .failed(error.localizedDescription))
            return
        }
        guard uploads[id] != nil else { return }
        progress.flush()
        job.streamFinished = true
        if job.openSessions.isEmpty {
            finishUpload(id, state: job.failure.map { .failed($0) } ?? .completed)
            return
        }
        // The Mac confirms each session. Without that the files may be
        // incomplete, so a missing confirmation is a failure.
        job.timeout = Task { [weak self] in
            try? await Task.sleep(for: Self.completionTimeout)
            guard !Task.isCancelled, let self, self.uploads[id] != nil else { return }
            self.finishUpload(id, state: .failed(job.failure ?? String(
                localized: "The Mac didn't confirm the upload.", bundle: .module)))
        }
    }

    private func finishUpload(_ id: UUID, state: VNCFileTransfer.State) {
        guard let job = uploads.removeValue(forKey: id) else { return }
        var state = state
        if state == .completed, !job.stagingFailures.isEmpty {
            let names = ListFormatter.localizedString(byJoining: job.stagingFailures)
            state = .failed(String(
                localized: "Couldn't read \(names). The other items were copied.", bundle: .module))
        }
        job.timeout?.cancel()
        for session in job.openSessions { owners[session] = nil }
        if let folder = job.stagingFolder {
            let cleanup = job.stagingTask
            Task.detached {
                await cleanup?.value
                try? FileManager.default.removeItem(at: folder)
            }
        }
        update(id) {
            $0.state = state
            if state == .completed { $0.completedBytes = $0.totalBytes }
        }
    }

    // MARK: - Download

    /// A local drag took over the Mac's file drag: Escape cancels it on the
    /// Mac before the caller releases the button.
    func handOffRemoteDrag() {
        pressPoint = nil
        remoteDragInProgress = false
        remoteDragOverTarget = false
        remoteDraggedNames = []
        remoteDraggedPaths = []
        session?.sendKeyEvent(downFlag: true, key: Self.escapeKeysym)
        session?.sendKeyEvent(downFlag: false, key: Self.escapeKeysym)
    }

    /// Downloads one item on the Mac to `destination`, for a file promise.
    /// AppKit asks after the drop, so the connection may be gone by then.
    func download(path: String, to destination: URL, completion: @escaping (Error?) -> Void) {
        guard canDownload, session?.activeTransport != nil else {
            completion(Self.promiseError(String(localized: "The connection closed.", bundle: .module)))
            return
        }
        let id = startDownload(paths: [path], dragImage: nil)
        downloads[id]?.promise = (destination, completion)
    }

    /// The job stays registered and active until the move ends, so neither
    /// cancel nor Clear can delete its source mid-copy.
    private func movePromisedDownload(_ job: DownloadJob, to destination: URL) {
        guard let source = job.results.first else { return }
        job.moving = true
        Task {
            let moved = await Task.detached {
                Result { try FileManager.default.moveItem(at: source, to: destination) }
            }.value
            job.moving = false
            switch moved {
            case .success:
                // Lets downloadWasSaved find and delete the emptied folder.
                update(job.id) { $0.localURLs = job.results }
                finishDownload(job.id, state: .completed)
                downloadWasSaved(job.id)
            case .failure(let error):
                // The files are still in the panel to save another way.
                update(job.id) { $0.localURLs = job.results }
                finishDownload(job.id, state: .failed(error.localizedDescription))
            }
        }
    }

    private static func promiseError(_ message: String) -> Error {
        CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func requestDragOut() {
        let handle = makeHandle()
        pendingDragOut = .now
        session?.enqueueFileTransferControl(
            AppleFileTransferProtocol.dragOutRequestMessage(handle: handle))
    }

    /// Downloads items on the Mac by path.
    @discardableResult
    func startDownload(paths: [String], dragImage: Data?) -> UUID {
        let id = UUID()
        let folder = Self.temporaryFolder("Screen Sharing Downloads")
        var transfer = VNCFileTransfer(
            id: id,
            direction: .download,
            name: Self.displayName(paths.map { ($0 as NSString).lastPathComponent }),
            itemCount: paths.count,
            state: .transferring)
        transfer.dragImagePNG = dragImage
        transfers.append(transfer)

        let writer = DownloadWriter(folder: folder) { [weak self] event in
            self?.handleWriterEvent(event, transfer: id)
        }
        let job = DownloadJob(id: id, writer: writer)
        downloads[id] = job
        for path in paths {
            let session = makeSessionID()
            owners[session] = id
            job.openSessions.insert(session)
            job.pendingSessions.insert(session)
            writer.addSession(session)
            send(AppleFileTransferProtocol.startDownloadMessage(session: session, path: path))
        }
        return id
    }

    private func handleWriterEvent(_ event: DownloadWriter.Event, transfer id: UUID) {
        guard let job = downloads[id] else { return }
        switch event {
        case .progress(let total, let written):
            update(id) {
                $0.totalBytes = max(total, written)
                $0.completedBytes = written
            }
        case .finished(let session, let url, let error):
            job.pendingSessions.remove(session)
            owners[session] = nil
            if let url { job.results.append(url) }
            if let error, job.failure == nil { job.failure = error }
            guard job.pendingSessions.isEmpty else { return }
            if job.results.isEmpty {
                job.writer.discard()
                finishDownload(id, state: .failed(job.failure ?? String(
                    localized: "The Mac didn't send any files.", bundle: .module)))
            } else if let promise = job.promise, job.failure == nil {
                movePromisedDownload(job, to: promise.destination)
            } else {
                // Keep what arrived; a partial failure still reports why.
                update(id) { $0.localURLs = job.results }
                finishDownload(id, state: job.failure.map { .failed($0) } ?? .completed)
            }
        }
    }

    private func finishDownload(_ id: UUID, state: VNCFileTransfer.State) {
        guard let job = downloads.removeValue(forKey: id) else { return }
        for session in job.openSessions { owners[session] = nil }
        update(id) {
            $0.state = state
            if state == .completed { $0.completedBytes = max($0.completedBytes, $0.totalBytes) }
        }
        switch state {
        case .completed: job.promise?.completion(nil)
        case .failed(let message): job.promise?.completion(Self.promiseError(message))
        default: job.promise?.completion(CocoaError(.userCancelled))
        }
    }

    // MARK: - Helpers

    private func send(_ message: Data) {
        session?.enqueueFileTransferControl(message)
    }

    private func targetContains(_ x: UInt16, _ y: UInt16) -> Bool {
        dragOutTarget?.contains(CGPoint(x: CGFloat(x), y: CGFloat(y))) == true
    }

    private func makeHandle() -> UInt32 {
        var handle: UInt32
        repeat { handle = UInt32.random(in: 1...UInt32.max) } while handle == lastHandle
        lastHandle = handle
        return handle
    }

    private func makeSessionID() -> UInt32 {
        nextSessionID &+= 1
        if nextSessionID == 0 { nextSessionID = 1 }
        return nextSessionID
    }

    private func index(of id: UUID) -> Int? {
        transfers.firstIndex { $0.id == id }
    }

    private func update(_ id: UUID, _ change: (inout VNCFileTransfer) -> Void) {
        guard let index = index(of: id) else { return }
        change(&transfers[index])
    }

    static func displayName(_ names: [String]) -> String {
        if names.count == 1, let name = names.first { return name }
        return String(localized: "\(names.count) items", bundle: .module)
    }

    static func uploadFailureMessage(status: Int16, name: String) -> String {
        switch status {
        case -34:
            return String(localized: "The Mac's disk is full.", bundle: .module)
        case -54, -61, -5000:
            return String(localized: "You don't have permission to save there on the Mac.", bundle: .module)
        case 5:
            return String(localized: "The Mac stopped receiving \(name).", bundle: .module)
        default:
            return String(localized: "The Mac couldn't save \(name) (error \(Int(status))).", bundle: .module)
        }
    }

    nonisolated static func temporaryFolder(_ name: String) -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(name, isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    // MARK: - Staging dropped items

    /// A name the drop session can show before any file is loaded.
    nonisolated static func suggestedName(for provider: NSItemProvider) -> String? {
        guard let type = fileType(for: provider) else { return nil }
        var name = provider.suggestedName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if name.isEmpty { name = String(localized: "File", bundle: .module) }
        if (name as NSString).pathExtension.isEmpty,
           let ext = UTType(type)?.preferredFilenameExtension {
            name += "." + ext
        }
        return sanitizedName(name)
    }

    /// The first file-backed type; text snippets without a name are skipped.
    nonisolated static func fileType(for provider: NSItemProvider) -> String? {
        // Finder names its items only at drop time; its node type marks a file.
        let isFile = provider.suggestedName != nil
            || provider.registeredTypeIdentifiers.contains(finderNodeType)
        return provider.registeredTypeIdentifiers.first { identifier in
            guard let type = UTType(identifier) else { return false }
            if type.conforms(to: .directory) { return true }
            guard type.conforms(to: .data) || type.conforms(to: .package) else { return false }
            if type.conforms(to: .url) { return false }
            if type.conforms(to: .text), !isFile { return false }
            return true
        }
    }

    nonisolated static let finderNodeType = "com.apple.finder.node"

    struct StagingResult {
        var staged: [URL] = []
        /// Files that couldn't be loaded or copied, by name.
        var failedNames: [String] = []
    }

    /// Items without a file type (text snippets, tabs) are skipped, not failed.
    static func stage(_ providers: [NSItemProvider], into folder: URL) async -> StagingResult {
        var result = StagingResult()
        for (index, provider) in providers.enumerated() {
            guard let type = fileType(for: provider) else { continue }
            let name = suggestedName(for: provider)
            let url: URL? = await withCheckedContinuation { continuation in
                _ = provider.loadFileRepresentation(forTypeIdentifier: type) { url, _ in
                    continuation.resume(returning: url.flatMap {
                        copyLoadedFile($0, name: name, into: folder)
                    })
                }
            }
            if let url {
                result.staged.append(url)
            } else {
                result.failedNames.append(name ?? String(localized: "Item \(index + 1)", bundle: .module))
            }
        }
        return result
    }

    /// The loaded URL is only valid inside the provider's handler.
    private nonisolated static func copyLoadedFile(_ url: URL, name: String?, into folder: URL) -> URL? {
        var name = name ?? url.lastPathComponent
        if (name as NSString).pathExtension.isEmpty, !url.pathExtension.isEmpty {
            name += "." + url.pathExtension
        }
        let destination = uniqueURL(in: folder, name: sanitizedName(name))
        do {
            try FileManager.default.copyItem(at: url, to: destination)
            return destination
        } catch {
            return nil
        }
    }

    nonisolated static func sanitizedName(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: ":")
            .replacingOccurrences(of: "\0", with: "")
        return cleaned.isEmpty || cleaned == "." || cleaned == ".." ? "File" : cleaned
    }

    /// Link-aware: a dangling symbolic link still counts as taken.
    nonisolated static func uniqueURL(in folder: URL, name: String) -> URL {
        var candidate = folder.appendingPathComponent(name)
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var counter = 2
        var info = stat()
        while lstat(candidate.path, &info) == 0 {
            let numbered = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            candidate = folder.appendingPathComponent(numbered)
            counter += 1
        }
        return candidate
    }
}

// MARK: - Jobs

@MainActor
private final class UploadJob {
    let id: UUID
    let handle: UInt32
    var destination: String?
    var staged: [URL]?
    var stagingFolder: URL?
    var stagingTask: Task<Void, Never>?
    var runTask: Task<Void, Never>?
    var timeout: Task<Void, Never>?
    var openSessions: Set<UInt32> = []
    var streamFinished = false
    var cancelRequested = false
    var stagingFailures: [String] = []
    var failure: String?

    init(id: UUID, handle: UInt32) {
        self.id = id
        self.handle = handle
    }
}

@MainActor
private final class DownloadJob {
    let id: UUID
    let writer: DownloadWriter
    /// Sessions the Mac may still send to (cancel stops these).
    var openSessions: Set<UInt32> = []
    /// Sessions whose files are not yet closed.
    var pendingSessions: Set<UInt32> = []
    var results: [URL] = []
    var failure: String?
    /// Set for a file promise: where the result goes and who waits for it.
    var promise: (destination: URL, completion: (Error?) -> Void)?
    /// Moving to the promise destination; cancel and disconnect wait it out.
    var moving = false

    init(id: UUID, writer: DownloadWriter) {
        self.id = id
        self.writer = writer
    }
}

/// Coalesces byte counts to about ten main-actor updates a second.
private final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Int64 = 0
    private var lastReport: ContinuousClock.Instant?
    private let report: @MainActor (Int64) -> Void

    init(report: @escaping @MainActor (Int64) -> Void) {
        self.report = report
    }

    func add(_ count: Int) {
        lock.lock()
        bytes += Int64(count)
        let now = ContinuousClock.now
        let due = lastReport.map { now - $0 >= .milliseconds(100) } ?? true
        if due { lastReport = now }
        let total = bytes
        lock.unlock()
        if due { Task { @MainActor in self.report(total) } }
    }

    @MainActor
    func flush() {
        lock.lock()
        let total = bytes
        lock.unlock()
        report(total)
    }
}

// MARK: - Upload stream

private enum UploadPlan {
    struct Root: Sendable {
        let name: String
        let items: [(item: AppleFileTransferProtocol.Item, url: URL?)]
        let bytes: Int64
        let fileCount: Int
        let folderCount: Int
        /// Special files (sockets, devices) that have no place on the Mac.
        let skipped: [String]
    }

    static let keys: [URLResourceKey] = [
        .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
        .creationDateKey, .contentModificationDateKey, .isExecutableKey,
    ]

    static func make(_ urls: [URL]) throws -> [Root] {
        try urls.map { url in
            var items: [(item: AppleFileTransferProtocol.Item, url: URL?)] = []
            var skipped: [String] = []
            guard let root = try item(for: url, name: url.lastPathComponent, level: 0) else {
                throw CocoaError(.fileReadUnsupportedScheme)
            }
            items.append((item: root, url: url))
            if root.kind == .folder,
               let enumerator = FileManager.default.enumerator(
                   at: url, includingPropertiesForKeys: keys) {
                // Preorder: each folder arrives before its contents.
                for case let child as URL in enumerator {
                    let level = UInt16(clamping: enumerator.level)
                    if let item = try item(for: child, name: child.lastPathComponent, level: level) {
                        items.append((item: item, url: child))
                    } else {
                        skipped.append(child.lastPathComponent)
                    }
                }
            }
            let files = items.filter { $0.item.kind == .file }
            return Root(
                name: url.lastPathComponent,
                items: items,
                bytes: files.reduce(0) { $0 + Int64($1.item.dataSize) },
                fileCount: files.count,
                folderCount: items.filter { $0.item.kind == .folder }.count,
                skipped: skipped)
        }
    }

    /// Nil for special files. Links go as links; folders are not followed through them.
    static func item(for url: URL, name: String, level: UInt16) throws -> AppleFileTransferProtocol.Item? {
        let values = try url.resourceValues(forKeys: Set(keys))
        let created = values.creationDate
        let modified = values.contentModificationDate
        if values.isSymbolicLink == true {
            return .init(
                kind: .symbolicLink, name: name, level: level,
                creationDate: created, modificationDate: modified,
                symbolicLinkTarget: try FileManager.default.destinationOfSymbolicLink(atPath: url.path))
        }
        if values.isDirectory == true {
            return .init(kind: .folder, name: name, level: level,
                         creationDate: created, modificationDate: modified)
        }
        guard values.isRegularFile == true else { return nil }
        return .init(
            kind: .file,
            name: name,
            level: level,
            dataSize: UInt64(max(0, values.fileSize ?? 0)),
            mode: values.isExecutable == true ? 0o100755 : 0o100644,
            creationDate: created,
            modificationDate: modified)
    }

    /// Every session's start goes first, then each session in turn.
    static func stream(
        _ roots: [Root],
        sessions: [UInt32],
        destination: String,
        transport: TransportSession,
        progress: ProgressThrottle
    ) async throws {
        for session in sessions {
            try await transport.sendAppleFileTransferMessage(
                AppleFileTransferProtocol.startUploadMessage(
                    session: session, destinationPath: destination))
        }
        for (root, session) in zip(roots, sessions) {
            try await transport.sendAppleFileTransferMessage(
                AppleFileTransferProtocol.summaryMessage(
                    session: session,
                    totalBytes: UInt64(root.bytes),
                    fileCount: UInt64(root.fileCount),
                    folderCount: UInt64(root.folderCount)))
            for (item, url) in root.items {
                try Task.checkCancellation()
                try await transport.sendAppleFileTransferMessage(
                    AppleFileTransferProtocol.itemMessage(session: session, item: item))
                guard item.kind == .file, item.dataSize > 0, let url else { continue }
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                var remaining = item.dataSize
                while remaining > 0 {
                    try Task.checkCancellation()
                    let count = Int(min(UInt64(AppleFileTransferProtocol.dataChunkSize), remaining))
                    guard let chunk = try handle.read(upToCount: count), !chunk.isEmpty else {
                        throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: url.path])
                    }
                    try await transport.sendAppleFileTransferMessage(
                        AppleFileTransferProtocol.fileDataMessage(session: session, bytes: chunk))
                    remaining -= UInt64(chunk.count)
                    progress.add(chunk.count)
                }
            }
            try await transport.sendAppleFileTransferMessage(
                AppleFileTransferProtocol.endSessionMessage(session: session))
        }
    }
}

// MARK: - Download writer

/// Writes download streams on its own queue, in message order.
final class DownloadWriter: @unchecked Sendable {
    enum Event: Sendable {
        case progress(total: Int64, written: Int64)
        /// `url` is the session's top-level item when anything was written.
        case finished(session: UInt32, url: URL?, error: String?)
    }

    private struct Stream {
        var folders: [URL]
        var topLevel: URL?
        var file: FileHandle?
        var fileURL: URL?
        var modificationDate: Date?
        var permissions: Int?
        /// Entries this device couldn't recreate.
        var skipped: [String] = []
        var remainingData: UInt64 = 0
        var remainingResource: UInt64 = 0
        var inflater: RFBZlibStreamInflater?
        var total: Int64 = 0
        var written: Int64 = 0
        var error: String?
    }

    private let queue = DispatchQueue(label: "rootshellVNC.file-download")
    private let folder: URL
    private let onEvent: @MainActor (Event) -> Void
    private var streams: [UInt32: Stream] = [:]
    private var discarded = false
    private var lastProgress: ContinuousClock.Instant?

    init(folder: URL, onEvent: @escaping @MainActor (Event) -> Void) {
        self.folder = folder
        self.onEvent = onEvent
    }

    func addSession(_ session: UInt32) {
        queue.async {
            self.streams[session] = Stream(folders: [self.folder])
        }
    }

    func handle(_ message: AppleFileTransferProtocol.ServerMessage, written: @escaping @Sendable () -> Void) {
        queue.async {
            self.process(message)
            written()
        }
    }

    /// Stops writing and deletes everything received.
    func discard() {
        queue.async {
            self.discarded = true
            for stream in self.streams.values { try? stream.file?.close() }
            self.streams.removeAll()
            try? FileManager.default.removeItem(at: self.folder)
        }
    }

    private func process(_ message: AppleFileTransferProtocol.ServerMessage) {
        guard !discarded, var stream = streams[message.session] else { return }
        switch message {
        case .summary(_, let summary):
            stream.total = Int64(clamping: summary.totalBytes)
        case .item(_, let item):
            guard stream.error == nil else { break }
            closeFile(&stream)
            open(item, in: &stream)
        case .fileData(_, let data):
            write(data, to: &stream)
        case .compressedFileData(_, let size, let compressed):
            do {
                if stream.inflater == nil { stream.inflater = try RFBZlibStreamInflater() }
                let data = try stream.inflater?.decompress(compressed, maxOutputSize: max(1, size)) ?? Data()
                write(data, to: &stream)
            } catch {
                stream.error = error.localizedDescription
            }
        case .end(let session, let status):
            closeFile(&stream)
            if status != 0, stream.error == nil {
                stream.error = String(
                    localized: "The Mac couldn't send the item (error \(Int32(bitPattern: status))).",
                    bundle: .module)
            }
            if !stream.skipped.isEmpty, stream.error == nil {
                let names = ListFormatter.localizedString(byJoining: stream.skipped)
                stream.error = String(
                    localized: "Couldn't save \(names) on this device. Everything else downloaded.",
                    bundle: .module)
            }
            // Finished sessions leave `streams`; keep their bytes in the totals.
            finishedTotal += max(stream.total, stream.written)
            finishedWritten += stream.written
            streams[session] = nil
            reportProgress(force: true)
            let event = Event.finished(session: session, url: stream.topLevel, error: stream.error)
            Task { @MainActor in self.onEvent(event) }
            return
        default:
            break
        }
        streams[message.session] = stream
        reportProgress(force: false)
    }

    private func open(_ item: AppleFileTransferProtocol.Item, in stream: inout Stream) {
        let level = Int(item.level)
        guard level < stream.folders.count else {
            stream.error = String(localized: "The Mac sent an item out of order.", bundle: .module)
            return
        }
        stream.folders.removeSubrange((level + 1)...)
        let parent = stream.folders[level]
        let name = VNCFileTransferController.sanitizedName(item.name)
        let url = VNCFileTransferController.uniqueURL(in: parent, name: name)
        let manager = FileManager.default
        do {
            switch item.kind {
            case .folder:
                try manager.createDirectory(at: url, withIntermediateDirectories: false)
                stream.folders.append(url)
            case .file:
                // Exclusive and no-follow: never write through an existing
                // entry, including a link the Mac sent earlier.
                let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
                guard descriptor >= 0 else {
                    throw CocoaError(.fileWriteUnknown, userInfo: [
                        NSFilePathErrorKey: url.path,
                        NSUnderlyingErrorKey: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO),
                    ])
                }
                stream.file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                stream.fileURL = url
                stream.modificationDate = item.modificationDate
                stream.permissions = Int(item.mode & 0o777)
                stream.remainingData = item.dataSize
                stream.remainingResource = item.resourceForkSize
                if item.dataSize == 0 { closeFile(&stream) }
            case .symbolicLink:
                // Safe to recreate: names are unique and files are opened
                // exclusively without following links.
                do {
                    try manager.createSymbolicLink(
                        atPath: url.path, withDestinationPath: item.symbolicLinkTarget ?? "")
                } catch {
                    stream.skipped.append(name)
                    return
                }
            }
            if level == 0, stream.topLevel == nil { stream.topLevel = url }
        } catch {
            stream.error = error.localizedDescription
        }
    }

    private func write(_ data: Data, to stream: inout Stream) {
        guard stream.error == nil else { return }
        var remaining = data[...]
        if stream.remainingData > 0 {
            let count = Int(min(UInt64(remaining.count), stream.remainingData))
            do {
                try stream.file?.write(contentsOf: remaining.prefix(count))
            } catch {
                stream.error = error.localizedDescription
                return
            }
            stream.remainingData -= UInt64(count)
            stream.written += Int64(count)
            remaining = remaining.dropFirst(count)
            if stream.remainingData == 0 { closeFile(&stream) }
        }
        // Resource forks have no home on this device.
        let resource = min(UInt64(remaining.count), stream.remainingResource)
        stream.remainingResource -= resource
        stream.written += Int64(resource)
    }

    private func closeFile(_ stream: inout Stream) {
        try? stream.file?.close()
        stream.file = nil
        if let url = stream.fileURL {
            var attributes: [FileAttributeKey: Any] = [:]
            attributes[.modificationDate] = stream.modificationDate
            attributes[.posixPermissions] = stream.permissions
            try? FileManager.default.setAttributes(attributes, ofItemAtPath: url.path)
        }
        stream.fileURL = nil
        stream.modificationDate = nil
        stream.permissions = nil
    }

    private func reportProgress(force: Bool) {
        let now = ContinuousClock.now
        if !force, let last = lastProgress, now - last < .milliseconds(100) { return }
        lastProgress = now
        let total = streams.values.reduce(0) { $0 + $1.total }
        let written = streams.values.reduce(0) { $0 + $1.written }
        let event = Event.progress(total: total + finishedTotal, written: written + finishedWritten)
        Task { @MainActor in self.onEvent(event) }
    }

    private var finishedTotal: Int64 = 0
    private var finishedWritten: Int64 = 0
}
