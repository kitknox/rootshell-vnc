#if os(macOS)
import XCTest
@testable import RFBTransport
@testable import rootshellVNC

/// Live file-transfer probe against a Mac's Screen Sharing server. Leaves
/// `rootshell-probe-*` items in the Mac's /private/tmp.
///
///   VNC_TEST_FILE_TRANSFER=1 VNC_TEST_HOST=... \
///     VNC_TEST_USERNAME=... VNC_TEST_PASSWORD='...' \
///     [VNC_TEST_HIGH_PERFORMANCE=1] \
///     xcrun swift test --filter LiveFileTransferProbeTests
@MainActor
final class LiveFileTransferProbeTests: XCTestCase {
    func testDownloadAndUploadRoundTrip() async throws {
        let session = try await connect()
        defer { session.disconnect() }
        let transfers = session.fileTransfers
        print("FILE PROBE canUpload=\(transfers.canUpload) canDownload=\(transfers.canDownload)")
        XCTAssertTrue(transfers.canUpload)
        XCTAssertTrue(transfers.canDownload)

        // Mac to device: a file every Mac has.
        let system = try await download(
            "/System/Library/CoreServices/SystemVersion.plist", with: transfers)
        let plist = try String(contentsOf: system, encoding: .utf8)
        XCTAssertTrue(plist.contains("ProductVersion"), "Unexpected SystemVersion.plist")

        // Device to Mac and back: one file and a folder holding a nested file.
        let local = FileManager.default.temporaryDirectory
            .appendingPathComponent("rootshell-probe-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: local) }
        let payload = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let file = local.appendingPathComponent("\(local.lastPathComponent).bin")
        try payload.write(to: file)
        let folder = local.appendingPathComponent("\(local.lastPathComponent) folder", isDirectory: true)
        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent("inner"), withIntermediateDirectories: true)
        try Data("nested".utf8).write(to: folder.appendingPathComponent("inner/note.txt"))
        try Data().write(to: folder.appendingPathComponent("empty"))
        try FileManager.default.createSymbolicLink(
            atPath: folder.appendingPathComponent("inner/link").path, withDestinationPath: "note.txt")

        transfers.upload([file, folder], toRemoteFolder: "/private/tmp")
        let upload = try await waitForFinish(transfers, direction: .upload)
        print("FILE PROBE upload state=\(upload.state) bytes=\(upload.completedBytes)/\(upload.totalBytes)")
        XCTAssertEqual(upload.state, .completed)

        let roundTrip = try await download("/private/tmp/\(file.lastPathComponent)", with: transfers)
        XCTAssertEqual(try Data(contentsOf: roundTrip), payload)
        let folderTrip = try await download("/private/tmp/\(folder.lastPathComponent)", with: transfers)
        XCTAssertEqual(
            try String(contentsOf: folderTrip.appendingPathComponent("inner/note.txt"), encoding: .utf8),
            "nested")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: folderTrip.appendingPathComponent("empty").path))
        XCTAssertEqual(
            try? FileManager.default.destinationOfSymbolicLink(
                atPath: folderTrip.appendingPathComponent("inner/link").path),
            "note.txt")

        // A missing path fails without ending the session.
        transfers.startDownload(paths: ["/private/tmp/rootshell-probe-missing"], dragImage: nil)
        let missing = try await waitForFinish(transfers, direction: .download)
        print("FILE PROBE missing path state=\(missing.state)")
        XCTAssertNotEqual(missing.state, .completed)
        XCTAssertTrue(session.connectionState.isConnected)
    }

    /// Large files: many chunks each way, and text the Mac may compress.
    func testLargeFilesRoundTrip() async throws {
        let session = try await connect()
        defer { session.disconnect() }
        let transfers = session.fileTransfers
        let local = FileManager.default.temporaryDirectory
            .appendingPathComponent("rootshell-probe-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: local) }

        var generator = SystemRandomNumberGenerator()
        let random = Data((0..<(16 << 20)).map { _ in UInt8.random(in: 0...255, using: &generator) })
        let line = Data("rootshell file transfer probe line with some repetition 0123456789\n".utf8)
        var text = Data(capacity: 16 << 20)
        while text.count < 16 << 20 { text.append(line) }
        for (name, payload) in [("\(local.lastPathComponent).bin", random), ("\(local.lastPathComponent).txt", text)] {
            let file = local.appendingPathComponent(name)
            try payload.write(to: file)
            let start = Date()
            transfers.upload([file], toRemoteFolder: "/private/tmp")
            let upload = try await waitForFinish(transfers, direction: .upload)
            let uploadSeconds = Date().timeIntervalSince(start)
            XCTAssertEqual(upload.state, .completed)
            let downStart = Date()
            let back = try await download("/private/tmp/\(name)", with: transfers)
            let downSeconds = Date().timeIntervalSince(downStart)
            print(String(format: "FILE PROBE %@ up %.1f MB/s down %.1f MB/s",
                         name, 16 / uploadSeconds, 16 / downSeconds))
            XCTAssertEqual(try Data(contentsOf: back), payload, "\(name) changed in transit")
        }
    }

    // MARK: - Helpers

    private func connect() async throws -> VNCSession {
        let environment = ProcessInfo.processInfo.environment
        guard environment["VNC_TEST_FILE_TRANSFER"] == "1" else {
            throw XCTSkip("Set VNC_TEST_FILE_TRANSFER=1 to run the live file-transfer probe")
        }
        guard let host = environment["VNC_TEST_HOST"],
              let password = environment["VNC_TEST_PASSWORD"], !password.isEmpty else {
            throw XCTSkip("Set VNC_TEST_HOST and VNC_TEST_PASSWORD")
        }
        let session = VNCSession(configuration: VNCConfiguration(
            videoQualityMode: environment["VNC_TEST_HIGH_PERFORMANCE"] == "1" ? .adaptive : .standard,
            displaySizingMode: .remoteDisplay,
            enableRemoteAudio: false,
            reconnectionPolicy: VNCReconnectionPolicy(isEnabled: false, maximumAttempts: 0)))
        try await session.connect(credentials: VNCCredentials(
            host: host,
            port: UInt16(environment["VNC_TEST_PORT"] ?? "5900") ?? 5900,
            password: password,
            username: environment["VNC_TEST_USERNAME"]))
        let ready = await Self.waitUntil(seconds: 20) {
            session.connectionState.isConnected && session.fileTransfers.canDownload
        }
        XCTAssertTrue(ready, "File transfer was never negotiated (state \(session.connectionState))")
        return session
    }

    private func download(_ path: String, with transfers: VNCFileTransferController) async throws -> URL {
        transfers.startDownload(paths: [path], dragImage: nil)
        let transfer = try await waitForFinish(transfers, direction: .download)
        print("FILE PROBE download \(path) state=\(transfer.state) bytes=\(transfer.completedBytes)/\(transfer.totalBytes)")
        XCTAssertEqual(transfer.state, .completed)
        return try XCTUnwrap(transfer.localURLs.first)
    }

    /// Waits for the newest transfer in `direction` to stop being active.
    private func waitForFinish(
        _ transfers: VNCFileTransferController,
        direction: VNCFileTransfer.Direction
    ) async throws -> VNCFileTransfer {
        let finished = await Self.waitUntil(seconds: 60) {
            transfers.transfers.last(where: { $0.direction == direction })?.isActive == false
        }
        let transfer = try XCTUnwrap(transfers.transfers.last(where: { $0.direction == direction }))
        XCTAssertTrue(finished, "Transfer \(transfer.name) never finished (\(transfer.state))")
        return transfer
    }

    private static func waitUntil(seconds: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return condition()
    }
}
#endif
