import Foundation

struct HardwareKeyboardTransition: Equatable, Sendable {
    let downFlag: Bool
    let keysym: UInt32
}

/// Platform-independent pressed-key bookkeeping. Physical HID usage is the
/// identity; the keysym chosen at key-down is retained until key-up.
struct HardwareKeyboardState: Sendable {
    private(set) var pressedKeysyms: [UInt32: UInt32] = [:]
    private var pressOrder: [UInt32] = []

    var isEmpty: Bool { pressedKeysyms.isEmpty }

    func contains(_ usage: UInt32) -> Bool {
        pressedKeysyms[usage] != nil
    }

    @discardableResult
    mutating func press(usage: UInt32, keysym: UInt32) -> HardwareKeyboardTransition? {
        guard usage != 0, keysym != 0, pressedKeysyms[usage] == nil else { return nil }
        pressedKeysyms[usage] = keysym
        pressOrder.append(usage)
        return HardwareKeyboardTransition(downFlag: true, keysym: keysym)
    }

    func repeatedPress(usage: UInt32) -> HardwareKeyboardTransition? {
        guard let keysym = pressedKeysyms[usage] else { return nil }
        return HardwareKeyboardTransition(downFlag: true, keysym: keysym)
    }

    mutating func release(usage: UInt32) -> HardwareKeyboardTransition? {
        guard let keysym = pressedKeysyms.removeValue(forKey: usage) else { return nil }
        pressOrder.removeAll { $0 == usage }
        return HardwareKeyboardTransition(downFlag: false, keysym: keysym)
    }

    mutating func releaseAll() -> [HardwareKeyboardTransition] {
        releaseAllWithUsages().map(\.transition)
    }

    mutating func releaseAllWithUsages() -> [(usage: UInt32, transition: HardwareKeyboardTransition)] {
        let transitions = pressOrder.reversed().compactMap { usage in
            pressedKeysyms[usage].map {
                (usage, HardwareKeyboardTransition(downFlag: false, keysym: $0))
            }
        }
        pressedKeysyms.removeAll(keepingCapacity: true)
        pressOrder.removeAll(keepingCapacity: true)
        return transitions
    }
}

/// Bookkeeping for host-toolbar modifiers wrapped around physical key
/// presses. A modifier remains down until every overlapping target key that
/// borrowed it has been released.
struct SupplementalHardwareModifierState: Sendable {
    private var keysymsByUsage: [UInt32: [UInt32]] = [:]
    private var referenceCounts: [UInt32: Int] = [:]
    private var activationOrder: [UInt32] = []

    func contains(usage: UInt32) -> Bool {
        keysymsByUsage[usage] != nil
    }

    mutating func begin(
        usage: UInt32,
        keysyms: [UInt32]
    ) -> [HardwareKeyboardTransition] {
        guard usage != 0, keysymsByUsage[usage] == nil else { return [] }
        keysymsByUsage[usage] = keysyms
        var transitions: [HardwareKeyboardTransition] = []
        for keysym in keysyms where keysym != 0 {
            let count = referenceCounts[keysym, default: 0]
            if count == 0 {
                activationOrder.append(keysym)
                transitions.append(HardwareKeyboardTransition(
                    downFlag: true,
                    keysym: keysym))
            }
            referenceCounts[keysym] = count + 1
        }
        return transitions
    }

    mutating func end(usage: UInt32) -> [HardwareKeyboardTransition] {
        guard let keysyms = keysymsByUsage.removeValue(forKey: usage) else {
            return []
        }
        var transitions: [HardwareKeyboardTransition] = []
        for keysym in keysyms.reversed() {
            let next = max(0, (referenceCounts[keysym] ?? 1) - 1)
            if next == 0 {
                referenceCounts.removeValue(forKey: keysym)
                activationOrder.removeAll { $0 == keysym }
                transitions.append(HardwareKeyboardTransition(
                    downFlag: false,
                    keysym: keysym))
            } else {
                referenceCounts[keysym] = next
            }
        }
        return transitions
    }

    mutating func releaseAll() -> [HardwareKeyboardTransition] {
        let transitions = activationOrder.reversed().map {
            HardwareKeyboardTransition(downFlag: false, keysym: $0)
        }
        keysymsByUsage.removeAll(keepingCapacity: true)
        referenceCounts.removeAll(keepingCapacity: true)
        activationOrder.removeAll(keepingCapacity: true)
        return transitions
    }
}

/// UIKeyCommand supplies layout-dependent text, not a physical HID identity.
/// Only hardware observations can identify a held/repeating key. If a command
/// cannot be correlated, send a bounded tap and consume a subsequent physical
/// report of that same keysym rather than inventing a US-layout HID usage.
struct UniversalCommandKeyState {
    enum Route: Equatable {
        case duplicate
        case tap
    }

    private(set) var pressed: [UInt32: UInt32] = [:]
    private var heldRemotely: Set<UInt32> = []
    private var unidentifiedTaps: Set<UInt32> = []

    mutating func routeCommand(keysym: UInt32) -> Route {
        if pressed.contains(where: { $0.value == keysym && heldRemotely.contains($0.key) }) {
            return .duplicate
        }
        // Command-only autorepeat is a sequence of bounded taps. A physical
        // key already consumed by a tap does not suppress those repeat events.
        if !pressed.values.contains(keysym) { unidentifiedTaps.insert(keysym) }
        return .tap
    }

    /// Returns false for duplicate UIKit/GameController delivery or a physical
    /// press whose command was already sent as an unidentified bounded tap.
    mutating func beginPhysical(usage: UInt32, keysym: UInt32) -> Bool {
        guard pressed[usage] == nil else { return false }
        pressed[usage] = keysym
        guard unidentifiedTaps.remove(keysym) == nil else { return false }
        heldRemotely.insert(usage)
        return true
    }

    @discardableResult
    mutating func release(usage: UInt32, keysym: UInt32? = nil) -> Bool {
        let recordedKeysym = pressed.removeValue(forKey: usage)
        // UIKit can provide layout-correct text even if it omitted key-down.
        // GameController key-ups carry only a usage, so an unknown usage must
        // leave pending matches for other strokes intact.
        if let releasedKeysym = recordedKeysym ?? keysym {
            unidentifiedTaps.remove(releasedKeysym)
        }
        heldRemotely.remove(usage)
        return recordedKeysym != nil
    }

    mutating func endTranslatedChord() {
        unidentifiedTaps.removeAll()
    }

    mutating func releaseAll() {
        pressed.removeAll()
        heldRemotely.removeAll()
        unidentifiedTaps.removeAll()
    }
}

/// Physical modifier identities are separate from the remote keys they hold.
/// Multiple physical Command keys and the translated chord share one remote
/// Command, so releasing one source cannot release another source's modifier.
struct CommandModifierState: Sendable {
    private(set) var physical: [UInt32: UInt32] = [:]
    private var inferredUsages: Set<UInt32> = []
    private var emitted: [UInt32] = []

    func contains(keysym: UInt32) -> Bool { emitted.contains(keysym) }

    var isControlOptionChordActive: Bool {
        (physical[0xE0] != nil || physical[0xE4] != nil)
            && (physical[0xE2] != nil || physical[0xE6] != nil)
    }

    mutating func press(usage: UInt32, keysym: UInt32) -> [HardwareKeyboardTransition] {
        // A UIKeyCommand may report flags before the physical modifier press.
        // Replace its inferred side with the actual side, rather than keeping
        // a phantom left modifier after a right-hand key is released.
        for inferred in inferredUsages.filter({ ($0 & 3) == (usage & 3) }) {
            physical.removeValue(forKey: inferred)
            inferredUsages.remove(inferred)
        }
        physical[usage] = keysym
        return reconcile()
    }

    mutating func release(usage: UInt32) -> [HardwareKeyboardTransition] {
        physical.removeValue(forKey: usage)
        inferredUsages.remove(usage)
        for inferred in inferredUsages.filter({ ($0 & 3) == (usage & 3) }) {
            physical.removeValue(forKey: inferred)
            inferredUsages.remove(inferred)
        }
        return reconcile()
    }

    mutating func synchronize(
        modifiers: VNCKeyboardModifiers,
        optionKeysym: UInt32
    ) -> [HardwareKeyboardTransition] {
        let groups: [(VNCKeyboardModifiers, UInt32, UInt32, UInt32)] = [
            (.control, 0xE0, 0xE4, KeyboardInputHandler.keysymControlL),
            (.shift, 0xE1, 0xE5, KeyboardInputHandler.keysymShiftL),
            (.option, 0xE2, 0xE6, optionKeysym),
            (.command, 0xE3, 0xE7, KeyboardInputHandler.keysymSuperL),
        ]
        for (flag, left, right, keysym) in groups {
            if !modifiers.contains(flag) {
                physical.removeValue(forKey: left)
                physical.removeValue(forKey: right)
                inferredUsages.remove(left)
                inferredUsages.remove(right)
            } else if physical[left] == nil && physical[right] == nil {
                physical[left] = keysym
                inferredUsages.insert(left)
            }
        }
        return reconcile()
    }

    mutating func releaseAll() -> [HardwareKeyboardTransition] {
        physical.removeAll()
        inferredUsages.removeAll()
        return reconcile()
    }

    private mutating func reconcile() -> [HardwareKeyboardTransition] {
        let control = physical[0xE0] != nil || physical[0xE4] != nil
        let option = physical[0xE2] != nil || physical[0xE6] != nil
        var desired: [UInt32] = []
        for usage in physical.keys.sorted() {
            if control && option && [0xE0, 0xE4, 0xE2, 0xE6].contains(usage) { continue }
            let keysym = (usage == 0xE3 || usage == 0xE7)
                ? KeyboardInputHandler.keysymSuperL : physical[usage]!
            if !desired.contains(keysym) { desired.append(keysym) }
        }
        if control && option && !desired.contains(KeyboardInputHandler.keysymSuperL) {
            desired.append(KeyboardInputHandler.keysymSuperL)
        }
        let releases = emitted.reversed().filter { !desired.contains($0) }.map {
            HardwareKeyboardTransition(downFlag: false, keysym: $0)
        }
        let presses = desired.filter { !emitted.contains($0) }.map {
            HardwareKeyboardTransition(downFlag: true, keysym: $0)
        }
        emitted = desired
        return releases + presses
    }
}

#if canImport(UIKit)
import UIKit

@MainActor
final class HardwareKeyboardController {
    private let keyboardHandler: KeyboardInputHandler
    private var state = HardwareKeyboardState()
    private var commandModifiers = CommandModifierState()
    var controlOptionAsCommand = true {
        didSet {
            if oldValue != controlOptionAsCommand { releaseAll() }
        }
    }
    private var delayTimer: Timer?
    private var repeatTimer: Timer?
    private var repeatingUsage: UInt32?

    init(keyboardHandler: KeyboardInputHandler) {
        self.keyboardHandler = keyboardHandler
    }

    var hasPressedKeys: Bool { !state.isEmpty || !commandModifiers.physical.isEmpty }

    func contains(usage: UInt32) -> Bool {
        state.contains(usage) || commandModifiers.physical[usage] != nil
    }

    @discardableResult
    func press(usage: UInt32, keysym: UInt32) -> Bool {
        if controlOptionAsCommand, (0xE0...0xE7).contains(usage) {
            commandModifiers.press(usage: usage, keysym: keysym).forEach(send)
            return true
        }
        guard let transition = state.press(usage: usage, keysym: keysym) else {
            // UIKit and UIKeyCommand can both report OS repeat callbacks. The
            // controller owns repeat timing, so duplicate begins are consumed.
            return state.contains(usage)
        }
        send(transition, usage: usage)
        // A physical-key host is a USB keyboard; the remote OS repeats held keys.
        if Self.isRepeatable(usage), !keyboardHandler.forwardsPhysicalKeys {
            startRepeat(for: usage)
        }
        return true
    }

    @discardableResult
    func release(usage: UInt32) -> Bool {
        if controlOptionAsCommand, (0xE0...0xE7).contains(usage) {
            commandModifiers.release(usage: usage).forEach(send)
            return true
        }
        guard let transition = state.release(usage: usage) else { return false }
        if repeatingUsage == usage { stopRepeat() }
        send(transition, usage: usage)
        return true
    }

    func releaseAll() {
        stopRepeat()
        state.releaseAllWithUsages().forEach { send($0.transition, usage: $0.usage) }
        commandModifiers.releaseAll().forEach(send)
    }

    func synchronizeModifiers(_ modifiers: VNCKeyboardModifiers) {
        guard controlOptionAsCommand else { return }
        commandModifiers.synchronize(
            modifiers: modifiers,
            optionKeysym: KeyboardInputHandler.optionLeftKeysym(
                appleModifierConvention: keyboardHandler.usesAppleModifierMapping)
        ).forEach(send)
    }

    func emitsModifier(keysym: UInt32) -> Bool {
        commandModifiers.contains(keysym: keysym)
    }

    var isControlOptionChordActive: Bool {
        controlOptionAsCommand && commandModifiers.isControlOptionChordActive
    }

    private func startRepeat(for usage: UInt32) {
        stopRepeat()
        repeatingUsage = usage
        let timer = Timer(timeInterval: 0.225, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.repeatingUsage == usage else { return }
                self.emitRepeat(for: usage)
                let repeating = Timer(timeInterval: 0.03, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.emitRepeat(for: usage) }
                }
                self.repeatTimer = repeating
                RunLoop.main.add(repeating, forMode: .common)
            }
        }
        delayTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func emitRepeat(for usage: UInt32) {
        guard repeatingUsage == usage,
              let transition = state.repeatedPress(usage: usage) else {
            stopRepeat()
            return
        }
        send(transition)
    }

    private func stopRepeat() {
        delayTimer?.invalidate()
        delayTimer = nil
        repeatTimer?.invalidate()
        repeatTimer = nil
        repeatingUsage = nil
    }

    private func send(_ transition: HardwareKeyboardTransition) {
        keyboardHandler.handleKeysym(
            downFlag: transition.downFlag,
            keysym: transition.keysym)
    }

    private func send(_ transition: HardwareKeyboardTransition, usage: UInt32) {
        keyboardHandler.handlePhysicalKey(
            downFlag: transition.downFlag,
            usage: usage,
            keysym: transition.keysym)
    }

    private static func isRepeatable(_ usage: UInt32) -> Bool {
        switch usage {
        case 0x39, 0xE0...0xE7: return false
        default: return true
        }
    }
}
#endif
