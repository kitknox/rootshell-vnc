import XCTest
@testable import rootshellVNC

@MainActor
final class VNCDownloadStoreTests: XCTestCase {
    func testListsItemsLeftByEarlierSessionsWithTheirDiskUsage() async throws {
        let store = try makeStore()
        let first = try makeDownload(in: store, files: ["a.txt": 5_000])
        let second = try makeDownload(in: store, files: ["Photos/one.jpg": 20_000, "Photos/two.jpg": 30_000])

        await store.refresh()

        XCTAssertTrue(store.hasLoaded)
        XCTAssertEqual(Set(store.downloads.map(\.name)), ["a.txt", "Photos"])
        let file = try XCTUnwrap(store.downloads.first { $0.name == "a.txt" })
        let folder = try XCTUnwrap(store.downloads.first { $0.name == "Photos" })
        XCTAssertFalse(file.isDirectory)
        XCTAssertTrue(folder.isDirectory)
        XCTAssertEqual(file.url.deletingLastPathComponent().lastPathComponent, first.lastPathComponent)
        XCTAssertEqual(folder.url.deletingLastPathComponent().lastPathComponent, second.lastPathComponent)
        XCTAssertGreaterThanOrEqual(file.byteCount, 5_000)
        XCTAssertGreaterThanOrEqual(folder.byteCount, 50_000)
        XCTAssertEqual(store.totalByteCount, file.byteCount + folder.byteCount)
    }

    func testDeletingOneItemLeavesTheOthers() async throws {
        let store = try makeStore()
        let single = try makeDownload(in: store, files: ["a.txt": 10])
        let pair = try makeDownload(in: store, files: ["b.txt": 10, "c.txt": 10])
        await store.refresh()

        await store.delete(try XCTUnwrap(store.downloads.first { $0.name == "a.txt" }))
        XCTAssertEqual(Set(store.downloads.map(\.name)), ["b.txt", "c.txt"])
        XCTAssertFalse(exists(single), "An emptied download folder is removed")

        await store.delete(try XCTUnwrap(store.downloads.first { $0.name == "b.txt" }))
        XCTAssertEqual(store.downloads.map(\.name), ["c.txt"])
        XCTAssertTrue(exists(pair.appendingPathComponent("c.txt")))
    }

    func testDeleteAllRemovesLeftoversAndEmptyFolders() async throws {
        let store = try makeStore()
        let full = try makeDownload(in: store, files: ["a.txt": 10, "Folder/b.txt": 10])
        let empty = try makeDownload(in: store, files: [:])
        let stray = store.root.appendingPathComponent("not-a-download")
        try Data().write(to: stray)
        await store.refresh()

        await store.deleteAll()

        XCTAssertTrue(store.downloads.isEmpty)
        XCTAssertEqual(store.totalByteCount, 0)
        XCTAssertFalse(exists(full))
        XCTAssertFalse(exists(empty))
        XCTAssertTrue(exists(stray), "Only download folders are deleted")
    }

    func testADownloadInProgressIsHiddenAndSurvivesCleanup() async throws {
        let store = try makeStore()
        let controller = VNCFileTransferController(downloadStore: store)
        let id = controller.startDownload(paths: ["/Users/x/big.bin"], dragImage: nil)
        let active = try XCTUnwrap(controller.activeDownloadFolders.first)
        let partial = store.root.appendingPathComponent(active).appendingPathComponent("big.bin")
        try Data(count: 100).write(to: partial)
        try makeDownload(in: store, files: ["old.txt": 10])

        await store.refresh()
        XCTAssertEqual(store.downloads.map(\.name), ["old.txt"])

        await store.delete(VNCStoredDownload(
            url: partial, name: "big.bin", isDirectory: false, byteCount: 100, date: nil))
        await store.deleteAll()
        XCTAssertTrue(exists(partial))
        XCTAssertTrue(store.downloads.isEmpty)
        XCTAssertTrue(controller.transfers.first { $0.id == id }?.isActive == true)

        controller.cancel(id)
        try await waitUntil { controller.activeDownloadFolders.isEmpty }
    }

    func testADownloadFinishingDuringTheFirstScanIsListed() async throws {
        let store = try makeStore()
        let first = Task { await store.refresh() }
        // Lets the refresh take its folder snapshot and start scanning.
        await Task.yield()
        try makeDownload(in: store, files: ["late.txt": 10])
        store.contentsDidChange()
        await first.value

        try await waitUntil { store.downloads.map(\.name) == ["late.txt"] }
        XCTAssertTrue(store.hasLoaded)
    }

    func testACancelledDownloadStaysHiddenUntilItsFilesAreGone() async throws {
        let store = try makeStore()
        let controller = VNCFileTransferController(downloadStore: store)
        let id = controller.startDownload(paths: ["/Users/x/big.bin"], dragImage: nil)
        let name = try XCTUnwrap(controller.activeDownloadFolders.first)
        let folder = store.root.appendingPathComponent(name)
        try Data(count: 100).write(to: folder.appendingPathComponent("big.bin"))
        await store.refresh()

        controller.cancel(id)
        XCTAssertEqual(controller.activeDownloadFolders, [name], "In use until cleanup ends")
        await store.refresh()
        XCTAssertTrue(store.downloads.isEmpty)

        try await waitUntil { controller.activeDownloadFolders.isEmpty }
        XCTAssertFalse(exists(folder))
        await store.refresh()
        XCTAssertTrue(store.downloads.isEmpty)
    }

    func testItemsRemovedBehindTheStoreDropOutOnRefresh() async throws {
        let store = try makeStore()
        let folder = try makeDownload(in: store, files: ["a.txt": 10])
        try makeDownload(in: store, files: ["b.txt": 10])
        await store.refresh()
        XCTAssertEqual(store.downloads.count, 2)

        try FileManager.default.removeItem(at: folder)
        await store.refresh()

        XCTAssertEqual(store.downloads.map(\.name), ["b.txt"])
    }

    func testItemsOutsideTheDownloadsFolderAreNeverDeleted() async throws {
        let store = try makeStore()
        let outside = store.root.deletingLastPathComponent()
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: outside) }
        let file = outside.appendingPathComponent("keep.txt")
        try Data(count: 10).write(to: file)

        await store.delete(VNCStoredDownload(
            url: file, name: "keep.txt", isDirectory: false, byteCount: 10, date: nil))

        XCTAssertTrue(exists(file))
    }

    func testMovedItemLeavesTheListAndItsEmptyFolder() async throws {
        let store = try makeStore()
        let folder = try makeDownload(in: store, files: ["a.txt": 10])
        await store.refresh()
        let download = try XCTUnwrap(store.downloads.first)
        try FileManager.default.removeItem(at: download.url)

        store.downloadWasMoved(download)

        XCTAssertTrue(store.downloads.isEmpty)
        XCTAssertFalse(exists(folder))
    }

    // MARK: - Helpers

    private func makeStore() throws -> VNCDownloadStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rootshell-download-store-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return VNCDownloadStore(root: root)
    }

    @discardableResult
    private func makeDownload(in store: VNCDownloadStore, files: [String: Int]) throws -> URL {
        let folder = store.makeFolder()
        for (path, size) in files {
            let url = folder.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(count: size).write(to: url)
        }
        return folder
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition())
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }
}
