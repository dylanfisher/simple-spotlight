import AppKit
import Combine
import Search

/// Records the hotkey in the settings window: a click starts listening, the next chord pressed
/// is the shortcut if the config file would take it, and Esc, a second click or the window
/// losing the keys stops listening without a change. A chord the file wouldn't take, such as a
/// letter with no modifier, says why and keeps listening.
///
/// While it listens, a local event monitor takes the window's keys before any view or key
/// equivalent sees them, and `recordingChanged` is told, so the app can give up its hotkey:
/// a registered chord never reaches the window as a key press.
@MainActor
public final class ShortcutRecorder: ObservableObject {
    /// Whether it is listening for a chord.
    @Published public private(set) var isRecording = false
    /// The modifiers held while listening, shown before the key comes.
    @Published private(set) var held: KeyChord.Modifiers = []
    /// Why the last chord pressed can't be the shortcut; nil once another is pressed.
    @Published private(set) var refusal: String?
    /// Told each chord recorded.
    var recorded: @MainActor (KeyChord) -> Void = { _ in }

    private let recordingChanged: @MainActor (Bool) -> Void
    private var monitor: Any?

    init(recordingChanged: @escaping @MainActor (Bool) -> Void) {
        self.recordingChanged = recordingChanged
    }

    /// Starts listening, or stops if it is already.
    func toggle() {
        if isRecording { stop() } else { start() }
    }

    func start() {
        guard !isRecording else { return }
        isRecording = true
        held = []
        refusal = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) {
            [weak self] event in
            // Local monitors run on the main thread, in the app's event dispatch.
            MainActor.assumeIsolated { self?.handle(event) ?? false } ? nil : event
        }
        recordingChanged(true)
    }

    /// Stops listening without a change.
    public func stop() {
        guard isRecording else { return }
        isRecording = false
        held = []
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recordingChanged(false)
    }

    /// Takes a key event while listening, and returns whether it did: a key down records its
    /// chord or says why it can't, Esc with no modifier stops, and a change of modifiers shows
    /// them.
    func handle(_ event: NSEvent) -> Bool {
        guard isRecording else { return false }
        let modifiers = event.modifierFlags.chordModifiers
        switch event.type {
        case .flagsChanged:
            held = modifiers
        case .keyDown:
            if event.keyCode == KeyChord.Key.escape.code, modifiers.isEmpty {
                stop()
                return true
            }
            switch Self.chord(keyCode: event.keyCode, modifiers: modifiers) {
            case .success(let chord):
                stop()
                recorded(chord)
            case .failure(let error):
                refusal = error.reason
            }
        default:
            return false
        }
        return true
    }

    /// Why a chord pressed can't be the shortcut, in a sentence.
    struct Refusal: Error, Equatable {
        let reason: String
    }

    /// The chord a key press makes, or why the config file wouldn't take it.
    nonisolated static func chord(keyCode: UInt16, modifiers: KeyChord.Modifiers) -> Result<
        KeyChord, Refusal
    > {
        guard let key = KeyChord.Key(code: keyCode) else {
            return .failure(
                Refusal(
                    reason: "That key can't end a shortcut. Use a letter, a digit, Space, Return,"
                        + " Tab, Esc, an F-key or punctuation."))
        }
        do throws(KeyChord.ParseError) {
            return .success(try KeyChord(checking: modifiers, key))
        } catch {
            let pressed = KeyChord(modifiers, key)
            return .failure(Refusal(reason: "\(pressed) can't be the shortcut: \(error.reason)."))
        }
    }

    /// What the recorder shows: the chord, or while listening the modifiers held.
    func label(for chord: KeyChord) -> String {
        guard isRecording else { return chord.description }
        return held.isEmpty ? "Type a shortcut" : held.symbols
    }
}

extension NSEvent.ModifierFlags {
    /// The four modifiers a chord can hold; the rest of the flags, such as Caps Lock and Fn, are
    /// not part of one.
    static let chordKeys: NSEvent.ModifierFlags = [.command, .shift, .option, .control]

    /// The chord modifiers among the flags.
    var chordModifiers: KeyChord.Modifiers {
        let pairs: [(NSEvent.ModifierFlags, KeyChord.Modifiers)] = [
            (.command, .command), (.option, .option), (.control, .control), (.shift, .shift),
        ]
        return pairs.reduce(into: []) { result, pair in
            if contains(pair.0) { result.insert(pair.1) }
        }
    }
}
