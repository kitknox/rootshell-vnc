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

    private(set) var committed = ""
    private(set) var marked: String?
    /// The input method's selection inside ``marked``, in UTF-16 offsets
    /// from its start. Empty and at the end unless it says otherwise.
    private(set) var markedSelection = NSRange(location: 0, length: 0)
    /// Changes whenever the document is discarded, so ranges handed out
    /// before then can be told apart from current ones.
    private(set) var generation: UInt64 = 0

    var text: String { committed + (marked ?? "") }
    var isEmpty: Bool { committed.isEmpty && marked == nil }
    var committedLength: Int { committed.utf16.count }
    var length: Int { text.utf16.count }

    var markedRange: NSRange? {
        guard let marked, !marked.isEmpty else { return nil }
        return NSRange(location: committedLength, length: marked.utf16.count)
    }

    /// Records text the keyboard inserted directly. It replaces any
    /// composition, which the keyboard commits this way or abandons.
    mutating func insert(_ text: String) {
        clearMarked()
        committed += text
    }

    /// The selection in UTF-16 offsets into ``text``: the input method's own
    /// while composing, otherwise a caret after everything typed.
    var selectedRange: NSRange {
        guard marked != nil else { return NSRange(location: committedLength, length: 0) }
        return NSRange(
            location: committedLength + markedSelection.location,
            length: markedSelection.length)
    }

    /// Moves the selection, which is only possible inside a composition.
    mutating func select(_ range: NSRange) {
        guard let marked, range.location >= committedLength else { return }
        markedSelection = Self.clamped(
            NSRange(location: range.location - committedLength, length: range.length),
            in: marked)
    }

    /// Returns true when the deletion only edited the composition, so no
    /// Backspace should reach the remote desktop.
    mutating func deleteBackward() -> Bool {
        if let current = marked, !current.isEmpty {
            let string = current as NSString
            var doomed = markedSelection
            if doomed.length == 0 {
                // A caret at the start of the composition has nothing to delete.
                guard doomed.location > 0 else { return true }
                doomed = string.rangeOfComposedCharacterSequence(at: doomed.location - 1)
            }
            let shortened = string.replacingCharacters(in: doomed, with: "")
            if shortened.isEmpty {
                clearMarked()
            } else {
                marked = shortened
                markedSelection = NSRange(location: doomed.location, length: 0)
            }
            return true
        }
        clearMarked()
        if !committed.isEmpty { committed.removeLast() }
        return false
    }

    /// `selectedRange` is relative to the start of `text`; a missing or
    /// out-of-range one puts the caret at the end.
    mutating func setMarked(_ text: String?, selectedRange: NSRange? = nil) {
        guard let text, !text.isEmpty else {
            clearMarked()
            return
        }
        marked = text
        let end = NSRange(location: text.utf16.count, length: 0)
        guard let selectedRange, selectedRange.location != NSNotFound else {
            markedSelection = end
            return
        }
        markedSelection = Self.clamped(selectedRange, in: text)
    }

    private mutating func clearMarked() {
        marked = nil
        markedSelection = NSRange(location: 0, length: 0)
    }

    /// Fits `range` inside `text` without splitting a character.
    private static func clamped(_ range: NSRange, in text: String) -> NSRange {
        let length = text.utf16.count
        let end = NSRange(location: length, length: 0)
        guard range.location >= 0, range.length >= 0, range.location <= length else { return end }
        let fitted = NSRange(location: range.location, length: min(range.length, length - range.location))
        return Range(fitted, in: text) == nil ? end : fitted
    }

    /// Ends the composition and returns the text it commits, if any.
    mutating func unmark() -> String? {
        guard let text = marked else { return nil }
        clearMarked()
        guard !text.isEmpty else { return nil }
        committed += text
        return text
    }

    /// Applies a keyboard replacement of `range` (UTF-16 offsets into
    /// ``text``). Returns nil, changing nothing, when the range is not one
    /// this document can honor.
    mutating func replace(_ range: NSRange, with replacement: String) -> Edit? {
        let full = text
        guard range.location >= 0, range.length >= 0,
              range.location <= full.utf16.count,
              range.length <= full.utf16.count - range.location,
              let indices = Range(range, in: full) else { return nil }

        if let current = marked {
            // Only the composition itself can change while one is active,
            // and replacing any of it commits the result.
            let local = NSRange(location: range.location - committedLength, length: range.length)
            guard local.location >= 0, let localIndices = Range(local, in: current) else { return nil }
            let text = current.replacingCharacters(in: localIndices, with: replacement)
            clearMarked()
            committed += text
            return Edit(backspaces: 0, text: text)
        }

        let result = full.replacingCharacters(in: indices, with: replacement)
        let shared = zip(full, result).prefix { $0 == $1 }.count
        let edit = Edit(
            backspaces: full.count - shared,
            text: String(result.dropFirst(shared)))
        committed = result
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
        clearMarked()
        generation &+= 1
        return true
    }
}
