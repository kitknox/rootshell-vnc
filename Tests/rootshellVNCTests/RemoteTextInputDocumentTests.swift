import XCTest
@testable import rootshellVNC

final class RemoteTextInputDocumentTests: XCTestCase {
    private typealias Edit = RemoteTextInputDocument.Edit
    private typealias Commit = RemoteTextInputDocument.Commit

    /// A composition committed after everything typed.
    private func appended(_ text: String) -> Commit {
        Commit(text: text, edit: Edit(backspaces: 0, text: text))
    }

    /// Plays an edit's keys against what the remote desktop holds.
    private func send(_ edit: Edit?, to remote: inout String) {
        guard let edit else { return }
        remote.removeLast(min(edit.backspaces, remote.count))
        remote += edit.text
    }

    func testCompositionCommitsOnceOnUnmark() {
        var document = RemoteTextInputDocument()
        document.setMarked("nihao")
        document.setMarked("你好")
        XCTAssertEqual(document.markedRange, NSRange(location: 0, length: 2))
        XCTAssertEqual(document.unmark(), appended("你好"))
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
        XCTAssertNil(document.setMarked(""))
        XCTAssertNil(document.unmark())
        document.setMarked("ni")
        XCTAssertNil(document.setMarked(nil))
        XCTAssertNil(document.unmark())
        XCTAssertTrue(document.isEmpty)
    }

    func testDeleteInsideCompositionStaysLocal() {
        var document = RemoteTextInputDocument()
        document.insert("a")
        document.setMarked("ni")
        XCTAssertNil(document.deleteBackward())
        XCTAssertNil(document.deleteBackward())
        XCTAssertNil(document.markedRange)
        XCTAssertEqual(document.deleteBackward(), Edit(backspaces: 1, text: ""))
        XCTAssertEqual(document.text, "")
        XCTAssertEqual(document.deleteBackward(), Edit(backspaces: 1, text: ""))
    }

    func testCompositionSelectionIsKeptAndDrivesDeletion() {
        var document = RemoteTextInputDocument()
        document.insert("a")
        document.setMarked("nihao", selectedRange: NSRange(location: 2, length: 0))
        XCTAssertEqual(document.selectedRange, NSRange(location: 3, length: 0))
        XCTAssertNil(document.deleteBackward())
        XCTAssertEqual(document.marked, "nhao")
        XCTAssertEqual(document.selectedRange, NSRange(location: 2, length: 0))

        document.select(NSRange(location: 2, length: 2))
        XCTAssertNil(document.deleteBackward())
        XCTAssertEqual(document.marked, "no")
        XCTAssertEqual(document.selectedRange, NSRange(location: 2, length: 0))

        document.select(NSRange(location: 1, length: 0))
        XCTAssertNil(document.deleteBackward())
        XCTAssertEqual(document.marked, "no")
        XCTAssertEqual(document.text, "ano")
    }

    func testCompositionSelectionStaysInsideTheComposition() {
        var document = RemoteTextInputDocument()
        document.insert("ab")
        XCTAssertEqual(document.selectedRange, NSRange(location: 2, length: 0))
        document.setMarked("ni", selectedRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(document.selectedRange, NSRange(location: 4, length: 0))
        document.setMarked("ni", selectedRange: NSRange(location: 9, length: 1))
        XCTAssertEqual(document.selectedRange, NSRange(location: 4, length: 0))
        document.select(NSRange(location: 1, length: 1))
        XCTAssertEqual(document.selectedRange, NSRange(location: 4, length: 0))
        XCTAssertEqual(document.unmark(), appended("ni"))
        XCTAssertEqual(document.selectedRange, NSRange(location: 4, length: 0))
    }

    func testSelectionInTypedTextIsKeptAndDeletedWhole() {
        var document = RemoteTextInputDocument()
        document.insert("什么呢")
        // UIKit deletes one character as select two, delete, reinsert one.
        document.select(NSRange(location: 1, length: 2))
        XCTAssertEqual(document.selectedRange, NSRange(location: 1, length: 2))
        XCTAssertEqual(document.deleteBackward(), Edit(backspaces: 2, text: ""))
        XCTAssertEqual(document.selectedRange, NSRange(location: 1, length: 0))
        XCTAssertEqual(document.insert("么"), Edit(backspaces: 0, text: "么"))
        XCTAssertEqual(document.text, "什么")
        XCTAssertEqual(document.selectedRange, NSRange(location: 2, length: 0))
    }

    func testCorrectedDictationReplacesTheFirstResult() {
        var document = RemoteTextInputDocument()
        var remote = ""
        send(document.insert("我在想，嗯，明天吃什么呢"), to: &remote)
        // UIKit deletes each character as select two, delete, reinsert one.
        while document.length > 1 {
            let kept = String(document.text.dropLast().suffix(1))
            document.select(NSRange(location: document.length - 2, length: 2))
            send(document.deleteBackward(), to: &remote)
            send(document.insert(kept), to: &remote)
            XCTAssertEqual(remote, document.text)
        }
        send(document.deleteBackward(), to: &remote)
        XCTAssertEqual(remote, "")
        send(document.insert("我在想，明天吃什么呢"), to: &remote)
        XCTAssertEqual(remote, "我在想，明天吃什么呢")
        XCTAssertEqual(document.text, remote)
    }

    func testInsertReplacesASelectionInTypedText() {
        var document = RemoteTextInputDocument()
        document.insert("我在想，嗯，明天")
        document.select(NSRange(location: 4, length: 2))
        XCTAssertEqual(document.insert(""), Edit(backspaces: 4, text: "明天"))
        XCTAssertEqual(document.selectedRange, NSRange(location: 4, length: 0))
        XCTAssertEqual(document.insert("后"), Edit(backspaces: 2, text: "后明天"))
        XCTAssertEqual(document.text, "我在想，后明天")
        XCTAssertEqual(document.selectedRange, NSRange(location: 5, length: 0))
    }

    func testCaretInsideTypedTextDeletesTheCharacterBeforeIt() {
        var document = RemoteTextInputDocument()
        document.insert("abc")
        document.select(NSRange(location: 1, length: 0))
        XCTAssertEqual(document.deleteBackward(), Edit(backspaces: 3, text: "bc"))
        XCTAssertEqual(document.selectedRange, NSRange(location: 0, length: 0))
        // Nothing before the caret here, and "bc" is after it remotely.
        XCTAssertEqual(document.deleteBackward(), Edit(backspaces: 0, text: ""))
        XCTAssertEqual(document.text, "bc")
    }

    func testSelectionFollowsReplacementsAndEndsWithTheDocument() {
        var document = RemoteTextInputDocument()
        document.insert("abcdef")
        document.select(NSRange(location: 4, length: 1))
        XCTAssertNotNil(document.replace(NSRange(location: 0, length: 2), with: "x"))
        XCTAssertEqual(document.selectedRange, NSRange(location: 3, length: 1))
        XCTAssertNotNil(document.replace(NSRange(location: 2, length: 3), with: "yz"))
        XCTAssertEqual(document.selectedRange, NSRange(location: 4, length: 0))

        document.select(NSRange(location: 9, length: 1))
        XCTAssertEqual(document.selectedRange, NSRange(location: 4, length: 0))
        document.select(NSRange(location: 0, length: 2))
        XCTAssertTrue(document.reset())
        XCTAssertEqual(document.selectedRange, NSRange(location: 0, length: 0))
    }

    func testSelectionBeforeAReplacementStaysPut() {
        var document = RemoteTextInputDocument()
        document.insert("abcdef")
        document.select(NSRange(location: 1, length: 1))
        XCTAssertEqual(
            document.replace(NSRange(location: 4, length: 1), with: "X"),
            Edit(backspaces: 2, text: "Xf"))
        XCTAssertEqual(document.selectedRange, NSRange(location: 1, length: 1))
        // Text right after the selection is not part of it either.
        XCTAssertNotNil(document.replace(NSRange(location: 2, length: 1), with: "yy"))
        XCTAssertEqual(document.selectedRange, NSRange(location: 1, length: 1))
        XCTAssertEqual(document.insert("Q"), Edit(backspaces: 6, text: "QyydXf"))
        XCTAssertEqual(document.text, "aQyydXf")
        XCTAssertEqual(document.selectedRange, NSRange(location: 2, length: 0))

        // Only an insertion at the caret itself moves a caret.
        XCTAssertNotNil(document.replace(NSRange(location: 2, length: 2), with: "z"))
        XCTAssertEqual(document.selectedRange, NSRange(location: 2, length: 0))
        XCTAssertNotNil(document.replace(NSRange(location: 2, length: 0), with: "ww"))
        XCTAssertEqual(document.selectedRange, NSRange(location: 4, length: 0))
        XCTAssertEqual(document.text, "aQwwzdXf")
    }

    func testCompositionReplacesTheSelectionWhenCommitted() {
        var document = RemoteTextInputDocument()
        document.insert("abc")
        document.select(NSRange(location: 1, length: 1))
        XCTAssertNil(document.setMarked("ni"))
        XCTAssertEqual(document.text, "anic")
        XCTAssertEqual(document.committed, "abc")
        XCTAssertEqual(document.markedRange, NSRange(location: 1, length: 2))
        XCTAssertEqual(document.selectedRange, NSRange(location: 3, length: 0))
        // Typed text is out of reach while composing.
        document.select(NSRange(location: 0, length: 1))
        XCTAssertEqual(document.selectedRange, NSRange(location: 3, length: 0))
        XCTAssertNil(document.replace(NSRange(location: 3, length: 1), with: "x"))
        document.select(NSRange(location: 1, length: 1))
        XCTAssertEqual(document.selectedRange, NSRange(location: 1, length: 1))

        XCTAssertNil(document.setMarked("你"))
        XCTAssertEqual(document.text, "a你c")
        XCTAssertEqual(
            document.unmark(),
            Commit(text: "你", edit: Edit(backspaces: 2, text: "你c")))
        XCTAssertEqual(document.text, "a你c")
        XCTAssertEqual(document.selectedRange, NSRange(location: 2, length: 0))
        XCTAssertEqual(document.insert("x"), Edit(backspaces: 1, text: "xc"))
        XCTAssertEqual(document.text, "a你xc")
    }

    func testCompositionAtACaretInsideTypedTextCommitsThere() {
        var document = RemoteTextInputDocument()
        document.insert("abc")
        document.select(NSRange(location: 1, length: 0))
        document.setMarked("ni")
        XCTAssertEqual(document.text, "anibc")
        XCTAssertEqual(document.markedRange, NSRange(location: 1, length: 2))
        // A keyboard that commits with insertText replaces the composition.
        XCTAssertEqual(document.insert("你"), Edit(backspaces: 2, text: "你bc"))
        XCTAssertNil(document.unmark())
        XCTAssertEqual(document.text, "a你bc")
        XCTAssertEqual(document.selectedRange, NSRange(location: 2, length: 0))
    }

    func testAbandonedCompositionDeletesTheSelectionItReplaced() {
        var document = RemoteTextInputDocument()
        document.insert("abc")
        document.select(NSRange(location: 1, length: 1))
        document.setMarked("n")
        XCTAssertEqual(document.deleteBackward(), Edit(backspaces: 2, text: "c"))
        XCTAssertNil(document.markedRange)
        XCTAssertEqual(document.text, "ac")
        XCTAssertEqual(document.selectedRange, NSRange(location: 1, length: 0))

        document.select(NSRange(location: 0, length: 1))
        document.setMarked("n")
        XCTAssertEqual(document.setMarked(""), Edit(backspaces: 2, text: "c"))
        XCTAssertEqual(document.text, "c")
        XCTAssertEqual(document.selectedRange, NSRange(location: 0, length: 0))

        // A caret has nothing to delete, and no composition means no change.
        document.setMarked("n")
        XCTAssertNil(document.setMarked(nil))
        document.select(NSRange(location: 0, length: 1))
        XCTAssertNil(document.setMarked(""))
        XCTAssertEqual(document.text, "c")
        XCTAssertEqual(document.selectedRange, NSRange(location: 0, length: 1))
    }

    func testCaretLeftAtTheEndByAReplacementAppendsAgain() {
        var document = RemoteTextInputDocument()
        document.insert("abc")
        document.select(NSRange(location: 0, length: 0))
        XCTAssertEqual(
            document.replace(NSRange(location: 0, length: 3), with: ""),
            Edit(backspaces: 3, text: ""))
        XCTAssertTrue(document.isEmpty)
        XCTAssertTrue(document.insertsAtEnd)
        // Earlier remote text is deletable again.
        XCTAssertEqual(document.deleteBackward(), Edit(backspaces: 1, text: ""))

        document.insert("abc")
        document.select(NSRange(location: 1, length: 0))
        XCTAssertNotNil(document.replace(NSRange(location: 1, length: 2), with: ""))
        XCTAssertTrue(document.insertsAtEnd)
        XCTAssertEqual(document.insert("d"), Edit(backspaces: 0, text: "d"))
    }

    func testInsertsAtEndOnlyWithACaretAfterEverythingTyped() {
        var document = RemoteTextInputDocument()
        XCTAssertTrue(document.insertsAtEnd)
        document.insert("aaa")
        XCTAssertTrue(document.insertsAtEnd)
        document.setMarked("ni")
        XCTAssertTrue(document.insertsAtEnd)
        document.setMarked(nil)

        // A caret moved inside stays there across inserts.
        document.select(NSRange(location: 0, length: 0))
        XCTAssertFalse(document.insertsAtEnd)
        document.insert("X")
        XCTAssertFalse(document.insertsAtEnd)
        document.setMarked("ni")
        XCTAssertFalse(document.insertsAtEnd)
        XCTAssertEqual(document.insert("Y"), Edit(backspaces: 3, text: "Yaaa"))
        XCTAssertEqual(document.text, "XYaaa")
        document.select(NSRange(location: 5, length: 0))
        XCTAssertTrue(document.insertsAtEnd)
    }

    func testSuccessiveCommitsAppendAfterCommittedText() {
        var document = RemoteTextInputDocument()
        document.setMarked("你好")
        XCTAssertEqual(document.unmark(), appended("你好"))
        document.setMarked("世界")
        XCTAssertEqual(document.markedRange, NSRange(location: 2, length: 2))
        XCTAssertEqual(document.unmark(), appended("世界"))
        XCTAssertEqual(document.text, "你好世界")
    }

    func testReplacingTheCompositionCommitsTheReplacement() {
        var document = RemoteTextInputDocument()
        document.insert("a ")
        document.setMarked("nihao")
        XCTAssertNil(document.commitMarked(replacing: NSRange(location: 0, length: 2), with: "x"))
        XCTAssertNil(document.commitMarked(replacing: NSRange(location: 2, length: 6), with: "x"))
        XCTAssertEqual(
            document.commitMarked(replacing: NSRange(location: 2, length: 5), with: "你好"),
            appended("你好"))
        XCTAssertNil(document.unmark())
        XCTAssertEqual(document.text, "a 你好")
        XCTAssertNil(document.commitMarked(replacing: NSRange(location: 0, length: 1), with: "x"))

        // Over a selection, the commit lands where the selection was.
        document.select(NSRange(location: 0, length: 1))
        document.setMarked("nihao")
        XCTAssertEqual(
            document.commitMarked(replacing: NSRange(location: 2, length: 3), with: ""),
            Commit(text: "ni", edit: Edit(backspaces: 4, text: "ni 你好")))
        XCTAssertEqual(document.text, "ni 你好")
        XCTAssertEqual(document.selectedRange, NSRange(location: 2, length: 0))
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
