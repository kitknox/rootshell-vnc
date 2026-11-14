import Foundation
import Observation

/// A downloaded file or folder still in the temporary downloads folder.
public struct VNCStoredDownload: Identifiable, Hashable, Sendable {
    public var id: URL { url }
    public let url: URL
    public let name: String
    public let isDirectory: Bool
    /// Space taken on disk, including a folder's contents.
    public let byteCount: Int64
    /// When the download started.
    public let date: Date?
}

/// The Screen Sharing downloads left on this device, whichever session made
/// them. Lists what is on disk now; downloads still in progress are left out
/// and never deleted.
@MainActor
@Observable
public final class VNCDownloadStore {
    public static let shared = VNCDownloadStore(
        root: FileManager.default.temporaryDirectory
            .appendingPathComponent("Screen Sharing Downloads", isDirectory: true))

    /// Newest first.
    public private(set) var downloads: [VNCStoredDownload] = []
    /// False until the first ``refresh()`` finishes.
    public private(set) var hasLoaded = false

    public var totalByteCount: Int64 {
        downloads.reduce(0) { $0 + $1.byteCount }
    }

    @ObservationIgnored let root: URL
    @ObservationIgnored private let controllers = NSHashTable<VNCFileTransferController>.weakObjects()
    @ObservationIgnored private var generation = 0
    /// A host has asked for the list, so changes are worth a reread.
    @ObservationIgnored private var isListed = false

    init(root: URL) {
        self.root = root
    }

    // MARK: - Host actions

    /// Reads the folder again, so items the system removed drop out.
    public func refresh() async {
        isListed = true
        generation += 1
        let current = generation
        let folders = idleFolders()
        let found = await Task.detached(priority: .userInitiated) {
            Self.scan(folders)
        }.value
        guard current == generation else { return }
        if found != downloads { downloads = found }
        hasLoaded = true
    }

    /// Deletes one downloaded item from this device.
    public func delete(_ download: VNCStoredDownload) async {
        guard let folder = idleFolder(containing: download.url) else { return }
        let url = download.url
        await Task.detached {
            try? FileManager.default.removeItem(at: url)
            // Only succeeds once the download's folder is empty.
            rmdir(folder.path)
        }.value
        pruneControllers()
        await refresh()
    }

    /// Deletes every download that no transfer is still writing, along with
    /// empty folders earlier sessions left behind.
    public func deleteAll() async {
        let folders = idleFolders()
        await Task.detached {
            for folder in folders {
                try? FileManager.default.removeItem(at: folder)
            }
        }.value
        pruneControllers()
        await refresh()
    }

    /// The host moved an item elsewhere (for example Save to Files).
    public func downloadWasMoved(_ download: VNCStoredDownload) {
        if let folder = idleFolder(containing: download.url) {
            rmdir(folder.path)
        }
        downloads.removeAll { $0.id == download.id }
        pruneControllers()
    }

    // MARK: - Transfer plumbing

    func register(_ controller: VNCFileTransferController) {
        controllers.add(controller)
    }

    /// A new folder for one download's items.
    func makeFolder() -> URL {
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// A session added or removed files; only reread if a host is listing them.
    /// A reread started during a scan supersedes that scan's result.
    func contentsDidChange() {
        guard isListed else { return }
        Task { await refresh() }
    }

    // MARK: - Helpers

    private func pruneControllers() {
        for controller in controllers.allObjects {
            controller.pruneMissingDownloads()
        }
    }

    private func foldersInUse() -> Set<String> {
        controllers.allObjects.reduce(into: Set<String>()) {
            $0.formUnion($1.activeDownloadFolders)
        }
    }

    /// Download folders no transfer is writing. Taken in one main-actor turn,
    /// so a download that starts later is never in the list.
    private func idleFolders() -> [URL] {
        let inUse = foldersInUse()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names
            .filter { UUID(uuidString: $0) != nil && !inUse.contains($0) }
            .map { root.appendingPathComponent($0, isDirectory: true) }
    }

    /// The download folder holding `url`, if it is one of ours and idle.
    private func idleFolder(containing url: URL) -> URL? {
        let folder = url.deletingLastPathComponent()
        let name = folder.lastPathComponent
        guard UUID(uuidString: name) != nil,
              folder.deletingLastPathComponent().resolvingSymlinksInPath().path
                  == root.resolvingSymlinksInPath().path,
              !foldersInUse().contains(name) else { return nil }
        return folder
    }

    private nonisolated static let sizeKeys: Set<URLResourceKey> = [
        .isDirectoryKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey,
    ]

    private nonisolated static func scan(_ folders: [URL]) -> [VNCStoredDownload] {
        let manager = FileManager.default
        var found: [VNCStoredDownload] = []
        for folder in folders {
            let date = try? folder.resourceValues(forKeys: [.creationDateKey]).creationDate
            let children = (try? manager.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: Array(sizeKeys))) ?? []
            for child in children {
                let values = try? child.resourceValues(forKeys: sizeKeys)
                let isDirectory = values?.isDirectory == true
                var bytes = size(values)
                if isDirectory,
                   let enumerator = manager.enumerator(
                       at: child, includingPropertiesForKeys: Array(sizeKeys)) {
                    for case let item as URL in enumerator {
                        bytes += size(try? item.resourceValues(forKeys: sizeKeys))
                    }
                }
                found.append(VNCStoredDownload(
                    url: child,
                    name: child.lastPathComponent,
                    isDirectory: isDirectory,
                    byteCount: bytes,
                    date: date))
            }
        }
        return found.sorted {
            let (a, b) = ($0.date ?? .distantPast, $1.date ?? .distantPast)
            return a != b ? a > b : $0.url.path < $1.url.path
        }
    }

    private nonisolated static func size(_ values: URLResourceValues?) -> Int64 {
        Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? values?.fileSize ?? 0)
    }
}
