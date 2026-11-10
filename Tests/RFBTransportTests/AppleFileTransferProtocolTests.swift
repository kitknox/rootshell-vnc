import XCTest
import RFBProtocol
@testable import RFBTransport

final class AppleFileTransferProtocolTests: XCTestCase {
    private typealias P = AppleFileTransferProtocol

    func testStartUploadWireFormat() {
        XCTAssertEqual(
            P.startUploadMessage(session: 1, destinationPath: "/Users/x/Desktop"),
            Data([0x22, 0, 0, 0, 0, 0x23, 0, 1, 0, 2, 0, 0, 0, 1,
                  0, 0, 0, 0, 0, 0, 0, 0, 0, 0x10]) + Data("/Users/x/Desktop".utf8) + Data([0]))
    }

    func testStartDownloadWireFormat() {
        let path = "/Users/x/Desktop/a.txt"
        XCTAssertEqual(
            P.startDownloadMessage(session: 1, path: path),
            Data([0x22, 0, 0, 0, 0, 0x29, 0, 1, 0, 1, 0, 0, 0, 1,
                  0, 0, 0, 1, 0, 0, 0, 0, 0, 0x16]) + Data(path.utf8) + Data([0]))
    }

    func testFileItemHeaderLayout() {
        // 2026-11-10T00:00:00Z is 0xE7180F00 seconds after 1904.
        let date = Date(timeIntervalSince1970: 1_794_268_800)
        let message = P.itemMessage(session: 1, item: .init(
            kind: .file, name: "a.txt", level: 0, dataSize: 5,
            creationDate: date, modificationDate: date))
        XCTAssertEqual(message.count, 14 + 104 + 6)
        XCTAssertEqual(Array(message.prefix(14)),
                       [0x22, 0, 0, 0, 0, 0x76, 0, 1, 0, 0x65, 0, 0, 0, 1])
        let body = Array(message.dropFirst(14))
        XCTAssertEqual(body[0], 1) // file
        XCTAssertEqual(Array(body[34..<50]), [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 5])
        for offset in [50, 58, 66, 74] {
            XCTAssertEqual(Array(body[offset..<offset + 8]), [0, 0, 0xe7, 0x18, 0x0f, 0, 0, 0])
        }
        XCTAssertEqual(Array(body[82..<90]), Array(repeating: 0, count: 8))
        XCTAssertEqual(Array(body[90..<96]), [0, 0, 0, 0, 0x81, 0xa4]) // flags, level, mode
        XCTAssertEqual(Array(body[100..<104]), [0, 5, 0, 0])
        XCTAssertEqual(Array(body[104...]), Array("a.txt".utf8) + [0])
    }

    func testFolderHeaderAndColonNames() {
        let message = P.itemMessage(session: 2, item: .init(kind: .folder, name: "a:b", level: 1))
        let body = Array(message.dropFirst(14))
        XCTAssertEqual(body[0], 2)
        XCTAssertEqual(Array(body[90..<96]), [0, 0x10, 0, 1, 0x41, 0xed])
        XCTAssertEqual(Array(body[104...]), Array("a/b".utf8) + [0])
    }

    func testDataSummaryAndEndWireFormats() {
        XCTAssertEqual(
            P.fileDataMessage(session: 1, bytes: Data("hello".utf8)),
            Data([0x22, 0, 0, 0, 0, 0x11, 0, 1, 0, 0x66, 0, 0, 0, 1, 0, 0, 0, 5]) + Data("hello".utf8))
        XCTAssertEqual(
            P.endSessionMessage(session: 1),
            Data([0x22, 0, 0, 0, 0, 8, 0, 1, 0, 0x68, 0, 0, 0, 1]))
        XCTAssertEqual(
            P.stopMessage(session: 7),
            Data([0x22, 0, 0, 0, 0, 8, 0, 1, 0, 5, 0, 0, 0, 7]))
        let summary = P.summaryMessage(session: 1, totalBytes: 5, fileCount: 1, folderCount: 0)
        XCTAssertEqual(summary.count, 66)
        XCTAssertEqual(Array(summary.prefix(6)), [0x22, 0, 0, 0, 0, 0x3c])
    }

    func testDragMessages() throws {
        XCTAssertEqual(P.dragOutRequestMessage(handle: 0x0102_0304), Data([0x0e, 0, 0, 0, 1, 2, 3, 4]))
        let dragIn = try P.dragInMessage(handle: 9, fileURLs: [URL(fileURLWithPath: "/tmp/a.txt")])
        XCTAssertEqual(Array(dragIn.prefix(8)), [0x20, 0, 0, 0, 0, 0, 0, 9])
        // The client's drag-in has the same layout as the server's drag-out reply.
        let reply = P.dragOutReply(header: dragIn.prefix(16), compressed: dragIn.dropFirst(16))
        XCTAssertEqual(reply.handle, 9)
        XCTAssertEqual(reply.paths, ["/tmp/a.txt"])
        XCTAssertNil(reply.dragImagePNG)
    }

    func testParsesDownloadStream() throws {
        let item = P.itemMessage(session: 3, item: .init(kind: .file, name: "a/b.txt", level: 0, dataSize: 5))
        guard case .item(3, let parsed)? = P.serverMessage(payload: item.dropFirst(6)) else {
            return XCTFail("item")
        }
        XCTAssertEqual(parsed.name, "a:b.txt")
        XCTAssertEqual(parsed.dataSize, 5)
        XCTAssertEqual(parsed.mode, 0o100644)

        let data = P.fileDataMessage(session: 3, bytes: Data("hello".utf8))
        XCTAssertEqual(P.serverMessage(payload: data.dropFirst(6)), .fileData(session: 3, Data("hello".utf8)))

        // The Mac writes the end status little-endian.
        let end = Data([0, 1, 0, 0x68, 0, 0, 0, 3, 0xd5, 0xff, 0xff, 0xff])
        XCTAssertEqual(P.serverMessage(payload: end), .end(session: 3, status: 0xffff_ffd5))
    }

    func testParsesUploadProgressAndCompletion() {
        var progress = Data([0, 1, 0x01, 0x2c, 0, 0, 0, 1])
        let bits = (0.5 as Double).bitPattern
        for shift in stride(from: 56, through: 0, by: -8) { progress.append(UInt8(truncatingIfNeeded: bits >> UInt64(shift))) }
        XCTAssertEqual(P.serverMessage(payload: progress), .progress(session: 1, fraction: 0.5))

        let completion = Data([0, 1, 0, 0xc8, 0, 0, 0, 1, 0, 0, 0, 5]) + Data("a.txt".utf8) + Data([0])
        XCTAssertEqual(P.serverMessage(payload: completion), .completion(session: 1, status: 0, name: "a.txt"))
    }

    func testRejectsOutOfRangeLengths() {
        XCTAssertThrowsError(try P.fileCopyPayloadLength(prefix: Data([0x22, 0, 0, 0x20, 0, 0])))
        XCTAssertThrowsError(try P.fileCopyPayloadLength(prefix: Data([0x22, 0, 0, 0, 0, 4])))
        XCTAssertEqual(try P.fileCopyPayloadLength(prefix: Data([0x22, 0, 0, 0, 0, 8])), 8)
    }

    /// The length bytes at offset 2 once passed for a FramebufferUpdate.
    func testHighPerformanceScannerFindsFileCopyAtStart() {
        let summary = P.summaryMessage(session: 1, totalBytes: 602, fileCount: 1, folderCount: 0)
        XCTAssertEqual(appleRFBServerMessageOffset(in: summary), 0)
        XCTAssertTrue(appleFileTransferMessageStarts(in: summary))
    }

    /// Media controls can open with a length byte equal to these types.
    func testMediaControlRecordsAreNotFileTransfers() {
        for type: UInt8 in [0x1e, 0x20, 0x22] {
            var control = Data(repeating: 0, count: 36)
            control[0] = type
            control[14] = 0x04
            control[15] = 0x51
            XCTAssertFalse(appleFileTransferMessageStarts(in: control), "type \(type)")
        }
        let request = Data([0x1e, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 5]) + Data("/tmp/".utf8)
        XCTAssertTrue(appleFileTransferMessageStarts(in: request))
    }

    /// A header cut by a record boundary is kept, not reframed at offset 2.
    func testSplitHeaderStaysAFileTransferStart() {
        let summary = P.summaryMessage(session: 1, totalBytes: 602, fileCount: 1, folderCount: 0)
        for length in 1..<14 {
            let prefix = summary.prefix(length)
            XCTAssertTrue(appleFileTransferMessageStarts(in: prefix), "prefix \(length)")
            XCTAssertEqual(appleRFBServerMessageOffset(in: prefix), 0, "prefix \(length)")
        }
    }
}
