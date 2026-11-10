#if os(macOS)
import AppKit
import XCTest
@testable import RFBProtocol
@testable import rootshellVNC

/// Live rich-clipboard probe against this Mac's own Screen Sharing server.
/// Over localhost the server's pasteboard is `NSPasteboard.general`, so both
/// directions can be checked without a second device. Replaces the
/// pasteboard contents; logs types and sizes only.
///
///   VNC_TEST_CLIPBOARD=1 VNC_TEST_HOST=localhost \
///     VNC_TEST_USERNAME=... VNC_TEST_PASSWORD='...' \
///     xcrun swift test --filter LiveClipboardProbeTests
@MainActor
final class LiveClipboardProbeTests: XCTestCase {
    func testRichClipboardRoundTripsThroughLocalScreenSharing() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["VNC_TEST_CLIPBOARD"] == "1" else {
            throw XCTSkip("Set VNC_TEST_CLIPBOARD=1 to run the live clipboard probe")
        }
        guard let host = environment["VNC_TEST_HOST"],
              ["localhost", "127.0.0.1", "::1"].contains(host),
              let password = environment["VNC_TEST_PASSWORD"], !password.isEmpty else {
            throw XCTSkip("Set VNC_TEST_HOST=localhost and VNC_TEST_PASSWORD")
        }

        let session = VNCSession(configuration: VNCConfiguration(
            videoQualityMode: .standard,
            displaySizingMode: .remoteDisplay,
            enableRemoteAudio: false,
            reconnectionPolicy: VNCReconnectionPolicy(isEnabled: false, maximumAttempts: 0)))
        var received: [VNCClipboardContent] = []
        session.onServerClipboardContent = { received.append($0) }
        try await session.connect(credentials: VNCCredentials(
            host: host,
            port: UInt16(environment["VNC_TEST_PORT"] ?? "5900") ?? 5900,
            password: password,
            username: environment["VNC_TEST_USERNAME"]))
        defer { session.disconnect() }

        let ready = await Self.waitUntil(seconds: 15) {
            session.supportsRemoteClipboardRequest
        }
        XCTAssertTrue(ready, "Apple clipboard requests were never negotiated")
        XCTAssertEqual(session.clipboardContentSupport, .all)

        // Mac to device.
        let png = try Self.pngData()
        let rtf = Data("{\\rtf1\\ansi {\\b bold} probe}".utf8)
        let html = Data("<b>bold</b> probe".utf8)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString("bold probe", forType: .string)
        item.setData(rtf, forType: .rtf)
        item.setData(html, forType: .html)
        item.setData(png, forType: .png)
        pasteboard.writeObjects([item])

        session.requestRemoteClipboard()
        let gotRemote = await Self.waitUntil(seconds: 10) { !received.isEmpty }
        XCTAssertTrue(gotRemote, "No reply to the clipboard request")
        if let content = received.last {
            print("CLIPBOARD PROBE mac->device \(content.summary)")
            XCTAssertEqual(content.plainText, "bold probe")
            XCTAssertTrue(content.contains(type: ClipboardType.rtf))
            XCTAssertTrue(content.contains(type: ClipboardType.html))
            XCTAssertTrue(content.contains(type: ClipboardType.png))
        }

        // Device to Mac.
        pasteboard.clearContents()
        let sent = VNCClipboardContent(items: [[
            .init(type: ClipboardType.rtf, data: rtf),
            .init(type: ClipboardType.png, data: png),
            .init(type: ClipboardType.utf8PlainText, data: Data("sent probe".utf8)),
        ]])
        session.sendClipboard(sent)
        let applied = await Self.waitUntil(seconds: 10) {
            pasteboard.string(forType: .string) == "sent probe"
        }
        XCTAssertTrue(applied, "The server never stored the sent clipboard")
        print("CLIPBOARD PROBE device->mac types=\(pasteboard.types?.map(\.rawValue) ?? [])")
        XCTAssertEqual(pasteboard.data(forType: .png), png)
        XCTAssertEqual(pasteboard.data(forType: .rtf), rtf)

        // Echo: does the server announce a pasteboard change we made?
        session.setRemoteSharedClipboardEnabled(true)
        try await Task.sleep(for: .seconds(1))
        let before = received.count
        session.sendClipboard(.text("echo probe"))
        _ = await Self.waitUntil(seconds: 3) { received.count > before }
        let echoed = received.dropFirst(before).contains { $0.plainText == "echo probe" }
        print("CLIPBOARD PROBE server echoes our own write: \(echoed)")
    }

    private static func pngData() throws -> Data {
        let image = NSImage(size: NSSize(width: 4, height: 4), flipped: false) { rect in
            NSColor.systemOrange.setFill()
            rect.fill()
            return true
        }
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
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
