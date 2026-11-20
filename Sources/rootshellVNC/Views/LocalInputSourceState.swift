import Foundation

struct LocalInputSourceState {
    private(set) var capsLockIsDown = false
    private(set) var compensatesCapsLock = false
    private(set) var uppercaseLocked = false
    private var capsLockPressedAt: TimeInterval?
    static let capsLockHoldDuration: TimeInterval = 0.5

    static func availableLanguages(_ available: [String]) -> [String] {
        var result: [String] = []
        for language in available where !language.isEmpty && language != "emoji" && language != "dictation" {
            if !result.contains(language) { result.append(language) }
        }
        return result
    }

    static func nextLanguage(current: String?, languages: [String]) -> String? {
        guard languages.count > 1 else { return nil }
        guard let current, let index = languages.firstIndex(of: current) else {
            return languages.first
        }
        return languages[(index + 1) % languages.count]
    }

    mutating func pressCapsLock(shift: Bool, at time: TimeInterval) -> Bool {
        guard !capsLockIsDown else { return false }
        capsLockIsDown = true
        compensatesCapsLock = true
        if shift { uppercaseLocked.toggle() }
        capsLockPressedAt = shift ? nil : time
        return true
    }

    mutating func holdCapsLock(at time: TimeInterval) {
        guard let start = capsLockPressedAt, time - start >= Self.capsLockHoldDuration else { return }
        capsLockPressedAt = nil
        uppercaseLocked.toggle()
    }

    mutating func releaseCapsLock(at time: TimeInterval) -> Bool {
        holdCapsLock(at: time)
        var switchesLanguage = capsLockPressedAt != nil
        if switchesLanguage, uppercaseLocked {
            uppercaseLocked = false
            switchesLanguage = false
        }
        releaseCapsLock()
        return switchesLanguage
    }

    mutating func releaseCapsLock() {
        capsLockIsDown = false
        capsLockPressedAt = nil
    }

    // Consuming Caps Lock can still latch the OS state. Correct letters, not symbols.
    func hardwareCharacters(_ characters: String, shift: Bool) -> String {
        guard compensatesCapsLock else { return characters }
        let uppercase = shift != uppercaseLocked
        return characters.map { character in
            guard character.isLetter else { return String(character) }
            return uppercase ? String(character).uppercased() : String(character).lowercased()
        }.joined()
    }
}
