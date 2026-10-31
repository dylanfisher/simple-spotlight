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

@MainActor @Test func showsOncePerChord() {
    var shown: [String] = []
    let notice = HotKeyConflictNotice(appName: "Simple Spotlight") { content, _ in
        shown.append(content.title)
    }

    notice.show(KeyChord(.command, .space), conflict: .systemShortcut) { _ in }
    notice.show(KeyChord(.command, .space), conflict: .systemShortcut) { _ in }
    notice.show(KeyChord(.control, .k), conflict: .refused(-1)) { _ in }

    #expect(shown.count == 2)
}

@MainActor @Test func opensTheKeyboardShortcutsSection() {
    #expect(
        HotKeyConflictNotice.keyboardShortcutsURL.absoluteString
            == "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?Shortcuts")
}
