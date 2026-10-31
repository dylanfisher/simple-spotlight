import AppKit
import Observation
import Search

/// Records the hotkey in the settings window: a click starts listening, the next chord pressed
/// is the shortcut if the config file would take it, and Esc, a second click or the window
/// losing the keys stops listening without a change. A chord the file wouldn't take, such as a
/// letter with no modifier, says why and keeps listening.
///
/// While it listens, a local event monitor takes the window's keys before any view or key
/// equivalent sees them, and `recordingChanged` is told, so the app can give up its hotkey:
/// a registered chord never reaches the window as a key press.
@MainActor @Observable
public final class ShortcutRecorder {
    /// Whether it is listening for a chord.
    public private(set) var isRecording = false
    /// The modifiers held while listening, shown before the key comes.
    private(set) var held: KeyChord.Modifiers = []
    /// Why the last chord pressed can't be the shortcut; nil once another is pressed.
    private(set) var refusal: String?
    /// Told each chord recorded.
    var recorded: @MainActor (KeyChord) -> Void = { _ in }

    @ObservationIgnored private let recordingChanged: @MainActor (Bool) -> Void
    @ObservationIgnored private var monitor: Any?

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
        let modifiers = Self.modifiers(event.modifierFlags)
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

    /// The chord modifiers among AppKit's flags.
    nonisolated static func modifiers(_ flags: NSEvent.ModifierFlags) -> KeyChord.Modifiers {
        let pairs: [(NSEvent.ModifierFlags, KeyChord.Modifiers)] = [
            (.command, .command), (.option, .option), (.control, .control), (.shift, .shift),
        ]
        return pairs.reduce(into: []) { result, pair in
            if flags.contains(pair.0) { result.insert(pair.1) }
        }
    }

    /// What the recorder shows: the chord, or while listening the modifiers held.
    func label(for chord: KeyChord) -> String {
        guard isRecording else { return chord.description }
        return held.isEmpty ? "Type a shortcut" : held.symbols
    }
}
