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
