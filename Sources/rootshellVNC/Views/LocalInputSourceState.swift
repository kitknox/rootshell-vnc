import Foundation

struct LocalInputSourceState {
    private(set) var capsLockIsDown = false
    private(set) var compensatesCapsLock = false
    private(set) var uppercaseLocked = false

    static func matchingLanguages(preferences: [String], available: [String]) -> [String] {
        var result: [String] = []
        for preference in preferences {
            let match = available.first { $0 == preference }
                ?? available.first { $0.hasPrefix(preference + "-") }
            if let match, !result.contains(match) { result.append(match) }
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

    mutating func pressCapsLock(shift: Bool) -> Bool {
        guard !capsLockIsDown else { return false }
        capsLockIsDown = true
        compensatesCapsLock = true
        if shift { uppercaseLocked.toggle() }
        return !shift
    }

    mutating func releaseCapsLock() { capsLockIsDown = false }

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
