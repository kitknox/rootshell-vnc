import XCTest
@testable import rootshellVNC

final class RemoteTextInputDocumentTests: XCTestCase {
    private typealias Edit = RemoteTextInputDocument.Edit

    func testCompositionCommitsOnceOnUnmark() {
        var document = RemoteTextInputDocument()
        document.setMarked("nihao")
        document.setMarked("你好")
        XCTAssertEqual(document.markedRange, NSRange(location: 0, length: 2))
        XCTAssertEqual(document.unmark(), "你好")
        XCTAssertNil(document.unmark())
        XCTAssertNil(document.markedRange)
        XCTAssertEqual(document.text, "你好")
    }

    func testInsertTextReplacesTheCompositionSoUnmarkSendsNothing() {
        var document = RemoteTextInputDocument()
        document.setMarked("nihao")
        document.insert("你好")
        XCTAssertNil(document.unmark())
        XCTAssertEqual(document.text, "你好")
    }

    func testClearedCompositionCommitsNothing() {
        var document = RemoteTextInputDocument()
        document.setMarked("ni")
        document.setMarked("")
        XCTAssertNil(document.unmark())
        document.setMarked("ni")
        document.setMarked(nil)
        XCTAssertNil(document.unmark())
        XCTAssertTrue(document.isEmpty)
    }

    func testDeleteInsideCompositionStaysLocal() {
        var document = RemoteTextInputDocument()
        document.insert("a")
        document.setMarked("ni")
        XCTAssertTrue(document.deleteBackward())
        XCTAssertTrue(document.deleteBackward())
        XCTAssertNil(document.markedRange)
        XCTAssertFalse(document.deleteBackward())
        XCTAssertEqual(document.text, "")
        XCTAssertFalse(document.deleteBackward())
    }

    func testCompositionSelectionIsKeptAndDrivesDeletion() {
        var document = RemoteTextInputDocument()
        document.insert("a")
        document.setMarked("nihao", selectedRange: NSRange(location: 2, length: 0))
        XCTAssertEqual(document.selectedRange, NSRange(location: 3, length: 0))
        XCTAssertTrue(document.deleteBackward())
        XCTAssertEqual(document.marked, "nhao")
        XCTAssertEqual(document.selectedRange, NSRange(location: 2, length: 0))

        document.select(NSRange(location: 2, length: 2))
        XCTAssertTrue(document.deleteBackward())
        XCTAssertEqual(document.marked, "no")
        XCTAssertEqual(document.selectedRange, NSRange(location: 2, length: 0))

        document.select(NSRange(location: 1, length: 0))
        XCTAssertTrue(document.deleteBackward())
        XCTAssertEqual(document.marked, "no")
        XCTAssertEqual(document.text, "ano")
    }

    func testSelectionDefaultsToTheEndAndIgnoresTypedText() {
        var document = RemoteTextInputDocument()
        document.insert("ab")
        document.select(NSRange(location: 0, length: 1))
        XCTAssertEqual(document.selectedRange, NSRange(location: 2, length: 0))
        document.setMarked("ni", selectedRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(document.selectedRange, NSRange(location: 4, length: 0))
        document.setMarked("ni", selectedRange: NSRange(location: 9, length: 1))
        XCTAssertEqual(document.selectedRange, NSRange(location: 4, length: 0))
        document.select(NSRange(location: 1, length: 1))
        XCTAssertEqual(document.selectedRange, NSRange(location: 4, length: 0))
        XCTAssertEqual(document.unmark(), "ni")
        XCTAssertEqual(document.selectedRange, NSRange(location: 4, length: 0))
    }

    func testSuccessiveCommitsAppendAfterCommittedText() {
        var document = RemoteTextInputDocument()
        document.setMarked("你好")
        XCTAssertEqual(document.unmark(), "你好")
        document.setMarked("世界")
        XCTAssertEqual(document.markedRange, NSRange(location: 2, length: 2))
        XCTAssertEqual(document.unmark(), "世界")
        XCTAssertEqual(document.text, "你好世界")
    }

    func testReplacingTheCompositionCommitsTheReplacement() {
        var document = RemoteTextInputDocument()
        document.insert("a ")
        document.setMarked("nihao")
        XCTAssertNil(document.replace(NSRange(location: 0, length: 2), with: "x"))
        XCTAssertEqual(
            document.replace(NSRange(location: 2, length: 5), with: "你好"),
            Edit(backspaces: 0, text: "你好"))
        XCTAssertNil(document.unmark())
        XCTAssertEqual(document.text, "a 你好")
    }

    func testReplacingTypedTextRetypesFromTheFirstDifference() {
        var document = RemoteTextInputDocument()
        document.insert("H")
        XCTAssertEqual(
            document.replace(NSRange(location: 0, length: 1), with: "Hello"),
            Edit(backspaces: 0, text: "ello"))
        XCTAssertEqual(
            document.replace(NSRange(location: 0, length: 5), with: "Help me"),
            Edit(backspaces: 2, text: "p me"))
        XCTAssertEqual(
            document.replace(NSRange(location: 0, length: 4), with: "Yelp"),
            Edit(backspaces: 7, text: "Yelp me"))
        XCTAssertEqual(document.text, "Yelp me")
    }

    func testOutOfBoundsReplacementIsRefused() {
        var document = RemoteTextInputDocument()
        document.insert("abc")
        XCTAssertNil(document.replace(NSRange(location: 2, length: 5), with: "x"))
        XCTAssertNil(document.replace(NSRange(location: 4, length: 0), with: "x"))
        XCTAssertEqual(document.text, "abc")
    }

    func testKeyTapsKeepEveryScalar() {
        XCTAssertEqual(RemoteTextInputDocument.keyTaps(for: "e\u{301}"), ["\u{E9}"])
        XCTAssertEqual(RemoteTextInputDocument.keyTaps(for: "a\r\nb"), ["a", "\n", "b"])
        // No composed form exists, so the mark follows as its own tap.
        XCTAssertEqual(
            RemoteTextInputDocument.keyTaps(for: "x\u{301}").map { $0.unicodeScalars.first!.value },
            [0x78, 0x301])
        XCTAssertEqual(
            RemoteTextInputDocument.keyTaps(for: "👍🏽").map { $0.unicodeScalars.first!.value },
            [0x1F44D, 0x1F3FD])
        XCTAssertEqual(RemoteTextInputDocument.keyTaps(for: "你好"), ["你", "好"])
    }

    func testControlKeysMoveTheRemoteCaret() {
        XCTAssertTrue(RemoteTextInputDocument.movesRemoteCaret("\n"))
        XCTAssertTrue(RemoteTextInputDocument.movesRemoteCaret("ls\tdone"))
        XCTAssertTrue(RemoteTextInputDocument.movesRemoteCaret("a\r\nb"))
        XCTAssertFalse(RemoteTextInputDocument.movesRemoteCaret("hello 你好."))
    }

    func testResetChangesGenerationOnlyWhenSomethingWasForgotten() {
        var document = RemoteTextInputDocument()
        XCTAssertFalse(document.reset())
        XCTAssertEqual(document.generation, 0)
        document.setMarked("ni")
        XCTAssertTrue(document.reset())
        XCTAssertEqual(document.generation, 1)
        XCTAssertNil(document.unmark())
        XCTAssertTrue(document.isEmpty)
    }
}
