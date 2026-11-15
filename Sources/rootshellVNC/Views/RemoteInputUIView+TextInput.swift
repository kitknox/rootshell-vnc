#if canImport(UIKit) && !targetEnvironment(macCatalyst)
import UIKit

// UITextInput for the software keyboard, so input methods can compose
// (marked text) and commit without calling insertText. Mac Catalyst types
// through hardware key events and stays on UIKeyInput.

final class RemoteTextPosition: UITextPosition {
    let offset: Int
    let generation: UInt64

    init(offset: Int, generation: UInt64) {
        self.offset = offset
        self.generation = generation
    }
}

final class RemoteTextRange: UITextRange {
    let range: NSRange
    let generation: UInt64

    init(_ range: NSRange, generation: UInt64) {
        self.range = range
        self.generation = generation
    }

    override var start: UITextPosition {
        RemoteTextPosition(offset: range.location, generation: generation)
    }

    override var end: UITextPosition {
        RemoteTextPosition(offset: range.location + range.length, generation: generation)
    }

    override var isEmpty: Bool { range.length == 0 }
}

extension RemoteInputUIView: UITextInput {

    // MARK: Composition

    func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        // Clearing a composition deletes the selection it had replaced.
        guard let edit = textDocument.setMarked(markedText, selectedRange: selectedRange) else { return }
        applyTextEdit(edit)
    }

    func unmarkText() {
        guard let commit = textDocument.unmark() else { return }
        commitComposition(commit)
    }

    var markedTextRange: UITextRange? {
        textDocument.markedRange.map(textRange)
    }

    // MARK: Text

    var selectedTextRange: UITextRange? {
        get { textRange(textDocument.selectedRange) }
        // The keyboard selects typed text to replace or delete it.
        set {
            guard let newValue, let range = currentRange(newValue) else { return }
            textDocument.select(range)
        }
    }

    func text(in range: UITextRange) -> String? {
        guard let range = currentRange(range) else { return nil }
        let text = textDocument.text
        guard let indices = Range(range, in: text) else { return nil }
        return String(text[indices])
    }

    func replace(_ range: UITextRange, withText text: String) {
        guard let range = currentRange(range) else { return }
        if textDocument.marked != nil {
            // Replacing any of a composition commits the result.
            guard let commit = textDocument.commitMarked(replacing: range, with: text) else { return }
            commitComposition(commit)
        } else if let edit = textDocument.replace(range, with: text) {
            applyTextEdit(edit)
        }
    }

    // MARK: Positions

    var beginningOfDocument: UITextPosition { position(0) }
    var endOfDocument: UITextPosition { position(textDocument.length) }

    func textRange(from fromPosition: UITextPosition, to toPosition: UITextPosition) -> UITextRange? {
        guard let from = currentOffset(fromPosition), let to = currentOffset(toPosition) else { return nil }
        return textRange(NSRange(location: min(from, to), length: abs(to - from)))
    }

    func position(from position: UITextPosition, offset: Int) -> UITextPosition? {
        guard let start = currentOffset(position) else { return nil }
        let (target, overflow) = start.addingReportingOverflow(offset)
        guard !overflow, target >= 0, target <= textDocument.length else { return nil }
        return self.position(target)
    }

    func position(
        from position: UITextPosition,
        in direction: UITextLayoutDirection,
        offset: Int
    ) -> UITextPosition? {
        guard offset != Int.min else { return nil }
        let backward = direction == .left || direction == .up
        return self.position(from: position, offset: backward ? -offset : offset)
    }

    func compare(_ position: UITextPosition, to other: UITextPosition) -> ComparisonResult {
        guard let a = position as? RemoteTextPosition,
              let b = other as? RemoteTextPosition else { return .orderedSame }
        if a.offset < b.offset { return .orderedAscending }
        if a.offset > b.offset { return .orderedDescending }
        return .orderedSame
    }

    func offset(from: UITextPosition, to toPosition: UITextPosition) -> Int {
        guard let a = from as? RemoteTextPosition,
              let b = toPosition as? RemoteTextPosition else { return 0 }
        return b.offset - a.offset
    }

    func position(within range: UITextRange, farthestIn direction: UITextLayoutDirection) -> UITextPosition? {
        (direction == .left || direction == .up) ? range.start : range.end
    }

    func characterRange(
        byExtending position: UITextPosition,
        in direction: UITextLayoutDirection
    ) -> UITextRange? {
        nil
    }

    func baseWritingDirection(
        for position: UITextPosition,
        in direction: UITextStorageDirection
    ) -> NSWritingDirection {
        .natural
    }

    func setBaseWritingDirection(_ writingDirection: NSWritingDirection, for range: UITextRange) {}

    // MARK: Geometry

    // There is no local caret; anchor system text UI to the bottom edge.
    private var textAnchorRect: CGRect {
        CGRect(x: bounds.midX, y: max(bounds.minY, bounds.maxY - 20), width: 2, height: 20)
    }

    func firstRect(for range: UITextRange) -> CGRect { textAnchorRect }
    func caretRect(for position: UITextPosition) -> CGRect { textAnchorRect }
    func selectionRects(for range: UITextRange) -> [UITextSelectionRect] { [] }
    func closestPosition(to point: CGPoint) -> UITextPosition? { endOfDocument }
    func closestPosition(to point: CGPoint, within range: UITextRange) -> UITextPosition? { range.end }
    func characterRange(at point: CGPoint) -> UITextRange? { nil }

    // MARK: Helpers

    private func position(_ offset: Int) -> RemoteTextPosition {
        RemoteTextPosition(offset: offset, generation: textDocument.generation)
    }

    private func textRange(_ range: NSRange) -> RemoteTextRange {
        RemoteTextRange(range, generation: textDocument.generation)
    }

    /// Nil for positions handed out before the document was last discarded.
    private func currentOffset(_ position: UITextPosition) -> Int? {
        guard let position = position as? RemoteTextPosition,
              position.generation == textDocument.generation else { return nil }
        return position.offset
    }

    private func currentRange(_ range: UITextRange) -> NSRange? {
        guard let range = range as? RemoteTextRange,
              range.generation == textDocument.generation else { return nil }
        return range.range
    }
}
#endif
