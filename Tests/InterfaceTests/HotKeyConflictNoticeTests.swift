import Carbon
import Search
import Testing

@testable import Interface

@MainActor @Test func namesSpotlightsShortcutAndWhereToTurnItOff() {
    let content = HotKeyConflictNotice.content(
        KeyChord(.command, .space), conflict: .systemShortcut, appName: "Simple Spotlight")

    #expect(content.title.contains("⌘Space"))
    #expect(
        content.message.contains(
            "System Settings → Keyboard → Keyboard Shortcuts…, choose Spotlight, and turn off"
                + " \"Show Spotlight search\""))
    #expect(content.message.contains("config file"))
    #expect(content.buttons.map(\.choice) == [.openKeyboardShortcuts, .openConfigFile, .dismiss])
}

@MainActor @Test func namesTheChordWhenItIsntSpotlights() {
    let content = HotKeyConflictNotice.content(
        KeyChord(.control, .f2), conflict: .systemShortcut, appName: "Simple Spotlight")

    #expect(content.message.contains("turn off the shortcut that uses ⌃F2"))
}

@MainActor @Test func saysAnotherAppHoldsAChordItRegistered() {
    let content = HotKeyConflictNotice.content(
        KeyChord(.control, .k), conflict: .refused(OSStatus(eventHotKeyExistsErr)),
        appName: "Simple Spotlight")

    #expect(content.message.contains("Another app uses ⌃K"))
    #expect(content.buttons.map(\.choice) == [.openConfigFile, .dismiss])
}

@MainActor @Test func aSystemShortcutRowOpensKeyboardShortcuts() {
    let row = HotKeyConflictNotice.row(KeyChord(.command, .space), conflict: .systemShortcut)

    #expect(row.title == "⌘Space is also Spotlight's shortcut")
    #expect(row.kind == .problem)
    #expect(row.id == ProblemItems.ID.hotKey.id)
    #expect(row.target == .openURL(HotKeyConflictNotice.keyboardShortcutsURL))
}

@MainActor @Test func aRowForAnotherChordSaysMacOS() {
    let row = HotKeyConflictNotice.row(KeyChord(.control, .f2), conflict: .systemShortcut)

    #expect(row.title == "⌃F2 is also a macOS shortcut")
}

@MainActor @Test func aRefusedChordsRowOpensTheConfigFile() {
    let row = HotKeyConflictNotice.row(KeyChord(.control, .k), conflict: .refused(-9878))

    #expect(row.title == "Another app uses ⌃K")
    #expect(row.target == .command(CommandProvider.Command.openConfig.id))
}

@MainActor @Test func opensTheKeyboardShortcutsSection() {
    #expect(
        HotKeyConflictNotice.keyboardShortcutsURL.absoluteString
            == "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?Shortcuts")
}
