import Foundation

/// The text document the software keyboard believes it is editing.
///
/// The remote desktop has no readable text, so this is only what was typed
/// since the last key or click that could have moved the remote caret, plus
/// the composition (marked text) an input method is still building.
/// Composition text stays local until it is committed.
struct RemoteTextInputDocument: Equatable, Sendable {
    /// Keys to send so the remote text matches a local replacement.
    struct Edit: Equatable, Sendable {
        var backspaces: Int
        var text: String
    }

    /// A finished composition: the text the input method committed, and the
    /// keys that put it where the composition was.
    struct Commit: Equatable, Sendable {
        var text: String
        var edit: Edit
    }

    /// A composition as the input method presents it. `selection` is in
    /// UTF-16 offsets from the start of `text`.
    struct Composition: Equatable, Sendable {
        var text: String
        var selection: NSRange

        /// The text before, inside and after the selection.
        var parts: (before: String, selected: String, after: String) {
            guard let range = Range(selection, in: text) else { return (text, "", "") }
            return (
                String(text[..<range.lowerBound]),
                String(text[range]),
                String(text[range.upperBound...]))
        }
    }

    /// What the remote desktop holds. A composition is not in it yet.
    private(set) var committed = ""
    private(set) var marked: String?
    /// The input method's selection inside ``marked``, in UTF-16 offsets
    /// from its start. Empty and at the end unless it says otherwise.
    private(set) var markedSelection = NSRange(location: 0, length: 0)
    /// The keyboard's selection inside ``committed`` in UTF-16 offsets, or
    /// nil for a caret at the end, where the remote caret always is.
    /// While composing it is what the composition replaces.
    private var committedSelection: NSRange?
    /// Changes whenever the document is discarded, so ranges handed out
    /// before then can be told apart from current ones.
    private(set) var generation: UInt64 = 0

    /// What the keyboard sees: the composition stands in for the selection
    /// it replaces.
    var text: String {
        guard let marked else { return committed }
        guard let target = committedSelection, let indices = Range(target, in: committed) else {
            return committed + marked
        }
        return committed.replacingCharacters(in: indices, with: marked)
    }

    var isEmpty: Bool { committed.isEmpty && marked == nil }
    var committedLength: Int { committed.utf16.count }
    var length: Int { text.utf16.count }

    var markedRange: NSRange? {
        guard let marked, !marked.isEmpty else { return nil }
        return NSRange(location: selectionStart, length: marked.utf16.count)
    }

    /// The composition to show locally, or nil when nothing is being composed.
    var composition: Composition? {
        guard let marked, !marked.isEmpty else { return nil }
        return Composition(text: marked, selection: markedSelection)
    }

    /// Where the selection in ``committed`` starts, and so any composition.
    private var selectionStart: Int { committedSelection?.location ?? committedLength }

    /// True when inserted text lands after everything typed, so nothing
    /// typed earlier is needed to place it.
    var insertsAtEnd: Bool { committedSelection == nil }

    /// Records text the keyboard inserted directly, replacing the selection.
    /// It also replaces any composition, which the keyboard commits this way
    /// or abandons.
    @discardableResult
    mutating func insert(_ text: String) -> Edit {
        clearMarked()
        return replaceSelection(with: text)
    }

    /// The selection in UTF-16 offsets into ``text``: the input method's own
    /// while composing, otherwise the keyboard's, a caret after everything
    /// typed unless it moved it.
    var selectedRange: NSRange {
        guard marked != nil else {
            return committedSelection ?? NSRange(location: committedLength, length: 0)
        }
        return NSRange(
            location: selectionStart + markedSelection.location,
            length: markedSelection.length)
    }

    /// Moves the selection. While composing it stays inside the composition.
    mutating func select(_ range: NSRange) {
        guard let marked else {
            setCommittedSelection(Self.clamped(range, in: committed))
            return
        }
        guard range.location >= selectionStart else { return }
        markedSelection = Self.clamped(
            NSRange(location: range.location - selectionStart, length: range.length),
            in: marked)
    }

    /// Deletes the selection, or the character before the caret. Returns the
    /// keys that do the same remotely, or nil when the deletion only edited
    /// the composition.
    mutating func deleteBackward() -> Edit? {
        if let current = marked, !current.isEmpty {
            let string = current as NSString
            var doomed = markedSelection
            if doomed.length == 0 {
                // A caret at the start of the composition has nothing to delete.
                guard doomed.location > 0 else { return nil }
                doomed = string.rangeOfComposedCharacterSequence(at: doomed.location - 1)
            }
            let shortened = string.replacingCharacters(in: doomed, with: "")
            guard shortened.isEmpty else {
                marked = shortened
                markedSelection = NSRange(location: doomed.location, length: 0)
                return nil
            }
            return abandonMarked()
        }
        clearMarked()
        guard var doomed = committedSelection else {
            // The remote text may reach back further than what was typed here.
            if !committed.isEmpty { committed.removeLast() }
            return Edit(backspaces: 1, text: "")
        }
        let nothing = Edit(backspaces: 0, text: "")
        if doomed.length == 0 {
            // Text before the caret is still to its right remotely.
            guard doomed.location > 0 else { return nothing }
            doomed = (committed as NSString).rangeOfComposedCharacterSequence(at: doomed.location - 1)
        }
        return replace(doomed, with: "") ?? nothing
    }

    /// Starts or updates the composition, which replaces the selection once
    /// committed. `selectedRange` is relative to the start of `text`; a
    /// missing or out-of-range one puts the caret at the end. Clearing a
    /// composition returns the keys that delete the selection it replaced.
    @discardableResult
    mutating func setMarked(_ text: String?, selectedRange: NSRange? = nil) -> Edit? {
        guard let text, !text.isEmpty else {
            return marked == nil ? nil : abandonMarked()
        }
        marked = text
        let end = NSRange(location: text.utf16.count, length: 0)
        guard let selectedRange, selectedRange.location != NSNotFound else {
            markedSelection = end
            return nil
        }
        markedSelection = Self.clamped(selectedRange, in: text)
        return nil
    }

    private mutating func clearMarked() {
        marked = nil
        markedSelection = NSRange(location: 0, length: 0)
    }

    /// Drops the composition along with the selection it had replaced.
    /// Returns nil when that selection was only a caret.
    private mutating func abandonMarked() -> Edit? {
        clearMarked()
        guard let target = committedSelection, target.length > 0 else { return nil }
        return replace(target, with: "")
    }

    /// Stores `range`, keeping a caret at the end as nil.
    private mutating func setCommittedSelection(_ range: NSRange) {
        let atEnd = range.length == 0 && range.location == committedLength
        committedSelection = atEnd ? nil : range
    }

    /// Puts `text` in place of the selection, leaving a caret after it.
    private mutating func replaceSelection(with text: String) -> Edit {
        guard let selection = committedSelection, let edit = replace(selection, with: text) else {
            committedSelection = nil
            committed += text
            return Edit(backspaces: 0, text: text)
        }
        return edit
    }

    /// Fits `range` inside `text` without splitting a character.
    private static func clamped(_ range: NSRange, in text: String) -> NSRange {
        let length = text.utf16.count
        let end = NSRange(location: length, length: 0)
        guard range.location >= 0, range.length >= 0, range.location <= length else { return end }
        let fitted = NSRange(location: range.location, length: min(range.length, length - range.location))
        return Range(fitted, in: text) == nil ? end : fitted
    }

    /// Ends the composition, committing its text over the selection it
    /// replaced. Returns nil when there was none.
    mutating func unmark() -> Commit? {
        guard let text = marked else { return nil }
        return commit(text)
    }

    /// Applies a keyboard replacement of `range` (UTF-16 offsets into
    /// ``text``) inside the composition, which commits the result. Returns
    /// nil, changing nothing, when the range reaches outside it.
    mutating func commitMarked(replacing range: NSRange, with replacement: String) -> Commit? {
        guard let current = marked, range.length >= 0 else { return nil }
        let local = NSRange(location: range.location - selectionStart, length: range.length)
        guard local.location >= 0, let indices = Range(local, in: current) else { return nil }
        return commit(current.replacingCharacters(in: indices, with: replacement))
    }

    private mutating func commit(_ text: String) -> Commit {
        clearMarked()
        return Commit(text: text, edit: replaceSelection(with: text))
    }

    /// Applies a keyboard replacement of `range` (UTF-16 offsets into
    /// ``text``). Returns nil, changing nothing, when the range is not one
    /// this document can honor, or a composition is active.
    mutating func replace(_ range: NSRange, with replacement: String) -> Edit? {
        let full = committed
        guard marked == nil,
              range.location >= 0, range.length >= 0,
              range.location <= full.utf16.count,
              range.length <= full.utf16.count - range.location,
              let indices = Range(range, in: full) else { return nil }

        let result = full.replacingCharacters(in: indices, with: replacement)
        let shared = zip(full, result).prefix { $0 == $1 }.count
        let edit = Edit(
            backspaces: full.count - shared,
            text: String(result.dropFirst(shared)))
        committed = result
        if var selection = committedSelection {
            let inserted = replacement.utf16.count
            if selection.location >= range.location + range.length {
                // Past the replacement: it moves with the text after it.
                selection.location += inserted - range.length
            } else if selection.location + selection.length > range.location {
                // Overlapping it: what was selected is gone.
                selection = NSRange(location: range.location + inserted, length: 0)
            }
            // Even an unmoved caret can now be at the end.
            setCommittedSelection(selection)
        }
        return edit
    }

    /// The single-scalar characters to send as key taps for `text`.
    /// Sequences are composed where Unicode allows and otherwise sent scalar
    /// by scalar, since a key tap carries one code point.
    static func keyTaps(for text: String) -> [Character] {
        text.precomposedStringWithCanonicalMapping.flatMap { character -> [Character] in
            character == "\r\n" ? ["\n"] : character.unicodeScalars.map(Character.init)
        }
    }

    /// True when typing `text` presses a key such as Return or Tab, which
    /// can move the remote caret away from what was typed before it.
    static func movesRemoteCaret(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }

    /// Forgets everything. Returns false when there was nothing to forget.
    @discardableResult
    mutating func reset() -> Bool {
        guard !isEmpty else { return false }
        committed = ""
        committedSelection = nil
        clearMarked()
        generation &+= 1
        return true
    }
}
