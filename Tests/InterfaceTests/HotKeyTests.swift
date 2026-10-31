import Carbon
import Search
import Testing

@testable import Interface

/// `KeyChord` holds Carbon's values so Search needs no Carbon import; this checks them against
/// Carbon's own constants.
@Test func chordsHoldCarbonsModifierMasksAndKeyCodes() {
    #expect(KeyChord.Modifiers.command.rawValue == UInt32(cmdKey))
    #expect(KeyChord.Modifiers.shift.rawValue == UInt32(shiftKey))
    #expect(KeyChord.Modifiers.option.rawValue == UInt32(optionKey))
    #expect(KeyChord.Modifiers.control.rawValue == UInt32(controlKey))
    let codes: [(KeyChord.Key, Int)] = [
        (.space, kVK_Space), (.a, kVK_ANSI_A), (.k, kVK_ANSI_K), (.digit0, kVK_ANSI_0),
        (.return, kVK_Return), (.escape, kVK_Escape), (.f1, kVK_F1), (.f20, kVK_F20),
        (.comma, kVK_ANSI_Comma), (.grave, kVK_ANSI_Grave),
    ]
    for (key, code) in codes {
        #expect(Int(key.code) == code, "\(key)")
    }
}

private let commandSpace = KeyChord(.command, .space)

@Test func findsAMacOSShortcutThatIsOnAndUsesTheChord() {
    let spotlight = SystemHotKey(modifiers: UInt32(cmdKey), code: 49, isEnabled: true)
    #expect(HotKey.systemShortcutUses(commandSpace, in: [spotlight]))
}

@Test func ignoresAShortcutThatIsOffOrDiffers() {
    let off = SystemHotKey(modifiers: UInt32(cmdKey), code: 49, isEnabled: false)
    let otherModifiers = SystemHotKey(
        modifiers: UInt32(cmdKey | optionKey), code: 49, isEnabled: true)
    let otherKey = SystemHotKey(modifiers: UInt32(cmdKey), code: 48, isEnabled: true)
    #expect(!HotKey.systemShortcutUses(commandSpace, in: [off, otherModifiers, otherKey]))
}

/// macOS adds the Fn mask to its F-key shortcuts, which no chord holds.
@Test func ignoresModifiersAChordCantHold() {
    let showDesktop = SystemHotKey(modifiers: 1 << 17, code: 103, isEnabled: true)
    #expect(HotKey.systemShortcutUses(KeyChord([], .f11), in: [showDesktop]))
}

@Test func readsMacOSShortcuts() throws {
    #expect(try !HotKey.systemHotKeys().isEmpty)
}

/// Chords no one uses, so the tests can take them from the system for a moment.
private let rareA = KeyChord([.control, .option, .shift, .command], .f18)
private let rareB = KeyChord([.control, .option, .shift, .command], .f19)

/// Whether a chord is free, found by registering it with a hotkey of its own.
@MainActor private func isFree(_ chord: KeyChord) -> Bool {
    let probe = HotKey()
    do throws(HotKeyConflict) {
        try probe.register(chord) {}
        probe.unregister()
        return true
    } catch {
        return false
    }
}

@MainActor @Test func aRefusedNewChordKeepsTheOldOne() throws {
    let hotKey = HotKey()
    let holder = HotKey()
    try hotKey.register(rareA) {}
    try holder.register(rareB) {}
    defer {
        hotKey.unregister()
        holder.unregister()
    }

    #expect(throws: HotKeyConflict.refused(OSStatus(eventHotKeyExistsErr))) {
        try hotKey.register(rareB) {}
    }
    #expect(!isFree(rareA))
}

@MainActor @Test func aNewChordReplacesTheOld() throws {
    let hotKey = HotKey()
    try hotKey.register(rareA) {}
    try hotKey.register(rareB) {}
    defer { hotKey.unregister() }

    #expect(isFree(rareA))
    #expect(!isFree(rareB))
}

@MainActor @Test func registeringTheSameChordAgainKeepsIt() throws {
    let hotKey = HotKey()
    try hotKey.register(rareA) {}
    defer { hotKey.unregister() }

    try hotKey.register(rareA) {}
    #expect(!isFree(rareA))
}

@MainActor @Test func unregisteringFreesTheChord() throws {
    let hotKey = HotKey()
    try hotKey.register(rareA) {}

    hotKey.unregister()
    #expect(isFree(rareA))
}
