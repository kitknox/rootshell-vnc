import XCTest
@testable import RFBTransport
@testable import rootshellVNC

@MainActor
final class VNCFileTransferControllerTests: XCTestCase {
    private typealias P = AppleFileTransferProtocol

    // MARK: - Drag-out

    func testTargetAppearsOnlyWhenTheMacAnnouncesAFileDrag() {
        let controller = VNCFileTransferController()
        controller.updateSupport(upload: true, download: true)
        controller.observePointer(buttonMask: 1, x: 100, y: 100)
        controller.observePointer(buttonMask: 1, x: 160, y: 100)
        XCTAssertTrue(controller.remoteDragInProgress)
        XCTAssertFalse(controller.showsDragOutTarget, "A window drag is not a file drag")

        controller.handle(reply(paths: ["/Users/x/Desktop/a.txt"]))
        XCTAssertTrue(controller.showsDragOutTarget)
        XCTAssertEqual(controller.remoteDraggedNames, ["a.txt"])

        controller.observePointer(buttonMask: 0, x: 160, y: 100)
        XCTAssertFalse(controller.showsDragOutTarget)
        XCTAssertTrue(controller.remoteDraggedNames.isEmpty)
        XCTAssertTrue(controller.transfers.isEmpty, "Released outside the target")
    }

    func testReleaseOverTargetDownloadsWhicheverHandleTheMacUses() {
        let controller = VNCFileTransferController()
        controller.updateSupport(upload: true, download: true)
        controller.dragOutTarget = CGRect(x: 0, y: 0, width: 200, height: 50)
        controller.observePointer(buttonMask: 1, x: 300, y: 300)
        controller.observePointer(buttonMask: 1, x: 100, y: 20)
        controller.handle(reply(paths: ["/Users/x/a.txt"], handle: 1))
        controller.observePointer(buttonMask: 1, x: 100, y: 21)
        XCTAssertTrue(controller.remoteDragOverTarget)
        controller.observePointer(buttonMask: 0, x: 100, y: 21)

        // The Mac answers with its own handle; empty replies are skipped.
        controller.handle(reply(paths: [], handle: 1))
        XCTAssertTrue(controller.transfers.isEmpty)
        controller.handle(reply(paths: ["/Users/x/a.txt"], handle: 1))
        XCTAssertEqual(controller.transfers.map(\.direction), [.download])
        XCTAssertEqual(controller.transfers.first?.name, "a.txt")

        // Only the first reply after a request starts a download.
        controller.handle(reply(paths: ["/Users/x/a.txt"], handle: 1))
        XCTAssertEqual(controller.transfers.count, 1)
        controller.remove(controller.transfers[0].id)
    }

    // MARK: - Upload drag

    func testCancelledUploadDragLeavesNothingBehind() {
        let session = VNCSession()
        let controller = session.fileTransfers
        controller.updateSupport(upload: true, download: true)
        XCTAssertTrue(controller.beginUploadDrag(names: ["a.txt"], x: 10, y: 10))
        XCTAssertEqual(controller.transfers.first?.state, .dragging)
        XCTAssertFalse(controller.beginUploadDrag(names: ["b.txt"], x: 10, y: 10), "One drag at a time")
        controller.cancelUploadDrag()
        XCTAssertTrue(controller.transfers.isEmpty)
    }

    func testUploadRequestForAnotherDragIsIgnored() {
        let session = VNCSession()
        let controller = session.fileTransfers
        controller.updateSupport(upload: true, download: false)
        XCTAssertTrue(controller.beginUploadDrag(names: ["a.txt"], x: 10, y: 10))
        controller.dropUpload(itemProviders: [], x: 10, y: 10)
        controller.handle(P.UploadRequest(handle: 0, destinationPath: "/Users/x/Desktop"))
        XCTAssertNil(controller.transfers.first?.remoteFolder)
        controller.remove(controller.transfers[0].id)
    }

    // MARK: - Download writer

    func testWriterRecreatesTreePermissionsAndLinks() async throws {
        let folder = try temporaryFolder()
        let events = WriterEvents()
        let writer = DownloadWriter(folder: folder) { events.append($0) }
        writer.addSession(1)
        feed(writer, [
            .item(session: 1, .init(kind: .folder, name: "top", level: 0)),
            .item(session: 1, .init(kind: .file, name: "run.sh", level: 1, dataSize: 3, mode: 0o100755)),
            .fileData(session: 1, Data("ok\n".utf8)),
            .item(session: 1, .init(kind: .symbolicLink, name: "link", level: 1, symbolicLinkTarget: "run.sh")),
            .item(session: 1, .init(kind: .file, name: "empty", level: 1)),
            .end(session: 1, status: 0),
        ])
        let finished = try await events.finished()
        XCTAssertNil(finished.error)
        let top = try XCTUnwrap(finished.url)
        XCTAssertEqual(try String(contentsOf: top.appendingPathComponent("run.sh"), encoding: .utf8), "ok\n")
        let mode = try FileManager.default.attributesOfItem(
            atPath: top.appendingPathComponent("run.sh").path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o755)
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: top.appendingPathComponent("link").path),
            "run.sh")
        XCTAssertTrue(FileManager.default.fileExists(atPath: top.appendingPathComponent("empty").path))
    }

    /// A dangling link followed by a file of the same name must not write
    /// through the link to a path outside the download folder.
    func testWriterNeverWritesThroughALink() async throws {
        let folder = try temporaryFolder()
        let outside = try temporaryFolder().appendingPathComponent("escaped")
        let events = WriterEvents()
        let writer = DownloadWriter(folder: folder) { events.append($0) }
        writer.addSession(1)
        feed(writer, [
            .item(session: 1, .init(kind: .folder, name: "top", level: 0)),
            .item(session: 1, .init(kind: .symbolicLink, name: "x", level: 1, symbolicLinkTarget: outside.path)),
            .item(session: 1, .init(kind: .file, name: "x", level: 1, dataSize: 4)),
            .fileData(session: 1, Data("evil".utf8)),
            .end(session: 1, status: 0),
        ])
        let finished = try await events.finished()
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.path))
        let top = try XCTUnwrap(finished.url)
        XCTAssertEqual(try String(contentsOf: top.appendingPathComponent("x 2"), encoding: .utf8), "evil")
    }

    func testWriterReportsMacErrors() async throws {
        let events = WriterEvents()
        let writer = DownloadWriter(folder: try temporaryFolder()) { events.append($0) }
        writer.addSession(1)
        feed(writer, [.end(session: 1, status: 0xffff_ffd5)])
        let finished = try await events.finished()
        XCTAssertNil(finished.url)
        XCTAssertNotNil(finished.error)
    }

    // MARK: - Helpers

    private func reply(paths: [String], handle: UInt32 = 1) -> P.DragOutReply {
        P.DragOutReply(handle: handle, paths: paths, dragImagePNG: nil)
    }

    private func feed(_ writer: DownloadWriter, _ messages: [P.ServerMessage]) {
        for message in messages { writer.handle(message) {} }
    }

    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rootshell-transfer-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

@MainActor
private final class WriterEvents {
    private var events: [DownloadWriter.Event] = []

    func append(_ event: DownloadWriter.Event) { events.append(event) }

    func finished() async throws -> (url: URL?, error: String?) {
        for _ in 0..<200 {
            for event in events {
                if case .finished(_, let url, let error) = event { return (url, error) }
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        struct Timeout: Error {}
        XCTFail("Writer never finished")
        throw Timeout()
    }
}
