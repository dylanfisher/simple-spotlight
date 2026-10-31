import AppKit
import Search
import Testing

@testable import Interface

@MainActor
private final class Fixture {
    var recorded: [KeyChord] = []
    var recording: [Bool] = []
    let recorder: ShortcutRecorder

    init() {
        _ = NSApplication.shared
        recorder = ShortcutRecorder(recordingChanged: { _ in })
        recorder.recorded = { [unowned self] in recorded.append($0) }
    }

    @discardableResult
    func press(_ key: KeyChord.Key, _ modifiers: NSEvent.ModifierFlags = []) throws -> Bool {
        recorder.handle(try keyEvent(key.rawValue, modifiers: modifiers, keyCode: key.code))
    }
}

@MainActor @Test func recordsTheChordPressed() throws {
    let fixture = Fixture()
    fixture.recorder.start()

    #expect(try fixture.press(.space, [.command, .shift]))

    #expect(fixture.recorded == [KeyChord([.command, .shift], .space)])
    #expect(!fixture.recorder.isRecording)
}

@MainActor @Test func escapeStopsWithoutAChord() throws {
    let fixture = Fixture()
    fixture.recorder.start()

    #expect(try fixture.press(.escape))

    #expect(fixture.recorded.isEmpty)
    #expect(!fixture.recorder.isRecording)
}

@MainActor @Test func escapeWithAModifierIsAChord() throws {
    let fixture = Fixture()
    fixture.recorder.start()

    try fixture.press(.escape, .command)

    #expect(fixture.recorded == [KeyChord(.command, .escape)])
}

@MainActor @Test func aChordTheFileWouldRefuseSaysWhyAndKeepsListening() throws {
    let fixture = Fixture()
    fixture.recorder.start()

    #expect(try fixture.press(.k, .shift))

    #expect(fixture.recorded.isEmpty)
    #expect(fixture.recorder.isRecording)
    #expect(fixture.recorder.refusal?.hasPrefix("⇧K can't be the shortcut: shift alone") == true)
    try fixture.press(.f5)
    #expect(fixture.recorded == [KeyChord([], .f5)])
}

@MainActor @Test func aKeyNoChordEndsWithIsRefused() {
    let leftArrow: UInt16 = 0x7B
    #expect(throws: ShortcutRecorder.Refusal.self) {
        try ShortcutRecorder.chord(keyCode: leftArrow, modifiers: .command).get()
    }
}

@MainActor @Test func showsTheModifiersHeldWhileListening() throws {
    let fixture = Fixture()
    let chord = KeyChord(.command, .space)
    #expect(fixture.recorder.label(for: chord) == "⌘Space")
    fixture.recorder.start()
    #expect(fixture.recorder.label(for: chord) == "Type a shortcut")

    let flags = try #require(
        NSEvent.keyEvent(
            with: .flagsChanged, location: .zero, modifierFlags: [.control, .option],
            timestamp: 0, windowNumber: 0, context: nil, characters: "",
            charactersIgnoringModifiers: "", isARepeat: false, keyCode: 0x3A))
    #expect(fixture.recorder.handle(flags))

    #expect(fixture.recorder.label(for: chord) == "⌃⌥")
}

@MainActor @Test func takesNoKeysWhenNotListening() throws {
    let fixture = Fixture()

    #expect(try !fixture.press(.k, .command))
    #expect(fixture.recorded.isEmpty)
}

@Test func theFourChordModifiersMapAndTheRestAreLeftOut() {
    let flags: NSEvent.ModifierFlags = [.command, .shift, .option, .control, .capsLock, .function]

    #expect(flags.chordModifiers == KeyChord.Modifiers.all)
    #expect(flags.intersection(.chordKeys) == [.command, .shift, .option, .control])
    #expect(NSEvent.ModifierFlags.capsLock.chordModifiers.isEmpty)
}
