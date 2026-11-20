import CoreGraphics
import XCTest
@testable import rootshellVNC

final class CompositionPreviewTests: XCTestCase {
    private typealias Slot = CompositionPreviewSlot

    private let bounds = CGRect(x: 0, y: 0, width: 390, height: 400)
    private let insets = HUDLayoutInsets(top: 12, leading: 12, bottom: 12, trailing: 12)

    private func slot(hud: CGRect?, height: CGFloat = 34) -> Slot {
        Slot.resolve(in: bounds, insets: insets, hudFrame: hud, height: height)
    }

    func testRestsAlongTheBottomWithoutAHUDInTheWay() {
        let resting = Slot(minX: 12, maxWidth: 366, maxY: 388)
        XCTAssertEqual(slot(hud: nil), resting)
        // A HUD dragged up the side leaves the bottom row free.
        XCTAssertEqual(slot(hud: CGRect(x: 332, y: 100, width: 46, height: 46)), resting)
    }

    func testSitsAboveABarThatSpansTheBottom() {
        let docked = CGRect(x: 6, y: 348, width: 378, height: 46)
        XCTAssertEqual(slot(hud: docked), Slot(minX: 12, maxWidth: 366, maxY: 342))
        // Drawer rows open above the bar; the preview clears them too.
        let withDrawer = CGRect(x: 6, y: 256, width: 378, height: 138)
        XCTAssertEqual(slot(hud: withDrawer).maxY, 250)
    }

    func testSharesTheBottomRowWithASmallHUD() {
        let trailing = CGRect(x: 240, y: 342, width: 138, height: 46)
        XCTAssertEqual(slot(hud: trailing), Slot(minX: 12, maxWidth: 222, maxY: 388))
        let leading = CGRect(x: 12, y: 342, width: 138, height: 46)
        XCTAssertEqual(slot(hud: leading), Slot(minX: 156, maxWidth: 222, maxY: 388))
    }

    func testStaysPutWhenNothingFitsAboveTheHUD() {
        let short = CGRect(x: 0, y: 0, width: 390, height: 90)
        let bar = CGRect(x: 6, y: 38, width: 378, height: 46)
        let resolved = Slot.resolve(in: short, insets: insets, hudFrame: bar, height: 34)
        XCTAssertEqual(resolved, Slot(minX: 12, maxWidth: 366, maxY: 78))
    }

    func testCompositionFollowsTheMarkedText() {
        var document = RemoteTextInputDocument()
        XCTAssertNil(document.composition)
        document.insert("a")
        XCTAssertNil(document.composition)

        document.setMarked("th")
        XCTAssertEqual(document.composition?.text, "th")
        document.setMarked("thing", selectedRange: NSRange(location: 2, length: 0))
        XCTAssertEqual(document.composition?.text, "thing")
        XCTAssertEqual(document.composition?.selection, NSRange(location: 2, length: 0))

        // Deleting inside the composition shortens it without leaving it.
        XCTAssertNil(document.deleteBackward())
        XCTAssertEqual(document.composition?.text, "ting")

        XCTAssertNotNil(document.unmark())
        XCTAssertNil(document.composition)
    }

    func testCompositionClearsOnEveryWayOut() {
        var document = RemoteTextInputDocument()
        document.setMarked("ni")
        document.insert("你")
        XCTAssertNil(document.composition)

        document.setMarked("ni")
        document.setMarked("")
        XCTAssertNil(document.composition)

        document.setMarked("n")
        XCTAssertNil(document.deleteBackward())
        XCTAssertNil(document.composition)

        document.setMarked("ni")
        document.reset()
        XCTAssertNil(document.composition)
    }

    func testPartsSplitAroundTheSelection() {
        typealias Composition = RemoteTextInputDocument.Composition
        let caret = Composition(text: "ni'hao", selection: NSRange(location: 2, length: 0)).parts
        XCTAssertEqual(caret.before, "ni")
        XCTAssertEqual(caret.selected, "")
        XCTAssertEqual(caret.after, "'hao")

        let selected = Composition(text: "你好吗", selection: NSRange(location: 1, length: 2)).parts
        XCTAssertEqual(selected.before, "你")
        XCTAssertEqual(selected.selected, "好吗")
        XCTAssertEqual(selected.after, "")

        // A range that splits a character or runs past the end loses no text.
        let split = Composition(text: "😀", selection: NSRange(location: 1, length: 0)).parts
        XCTAssertEqual(split.before + split.selected + split.after, "😀")
        let past = Composition(text: "ni", selection: NSRange(location: 5, length: 0)).parts
        XCTAssertEqual(past.before, "ni")
        XCTAssertEqual(past.selected + past.after, "")
    }
}
