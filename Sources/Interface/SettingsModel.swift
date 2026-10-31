import Foundation
import Observation
import Search

/// What the settings window shows and changes (docs/decisions/0015-settings-window.md).
///
/// The config file stays the source of truth: the window shows the settings the config store
/// last read, and each change is written into the file through `update`, which reads the file
/// back. Until that read arrives, a change shows on top of the settings read, so a control
/// doesn't flick back while the file is written. While the file has an error, nothing is
/// written and the controls are off.
@MainActor @Observable
public final class SettingsModel {
    /// A change to make to the settings.
    public typealias Change = @Sendable (inout Search.Settings) -> Void
    /// Writes a change into the config file and reads it back, as `ConfigStore.update` does.
    public typealias Update = @Sendable (@escaping Change) async throws(ConfigError) -> Void

    /// A conflict that keeps the hotkey from showing the panel, as the panel's problem row
    /// names it.
    public struct Conflict: Equatable, Sendable {
        public let chord: KeyChord
        public let conflict: HotKeyConflict

        public init(chord: KeyChord, conflict: HotKeyConflict) {
            self.chord = chord
            self.conflict = conflict
        }

        /// The panel's row's words: "⌘Space is also Spotlight's shortcut".
        @MainActor var title: String { HotKeyConflictNotice.row(chord, conflict: conflict).title }
        /// Whether turning off a macOS shortcut in Keyboard Shortcuts frees the chord.
        var isSystemShortcut: Bool { conflict == .systemShortcut }
    }

    /// The settings as the window shows them: the file's, with the changes not yet read back.
    public private(set) var settings = Search.Settings()
    /// What is wrong with the config file, as the store last said.
    public private(set) var errors: [ConfigError] = []
    /// Whether the file has an error, so the controls are off and nothing is written.
    public private(set) var isFileBroken = false
    /// Why the last change couldn't be written; nil once one is.
    public private(set) var writeError: ConfigError?
    /// Why the hotkey doesn't work, when it doesn't.
    public var hotKeyConflict: Conflict?
    /// Records the hotkey.
    public let recorder: ShortcutRecorder
    /// Where the config file is, as the window shows it.
    let configFile: URL
    let openConfigFile: @MainActor () -> Void
    let openKeyboardShortcuts: @MainActor () -> Void

    /// The settings the store last read.
    private var stored = Search.Settings()
    private var pending: [Pending] = []
    private var nextID = 0
    private let update: Update
    /// The write started last, which waits for the one before, so the file gets the changes in
    /// the order they were made. For tests to wait on.
    private(set) var lastWrite: Task<Void, Never>?

    /// A change made in the window that the settings read may not have yet.
    private struct Pending {
        let id: Int
        let change: Change
        /// Whether `update` has written it; then the store has read it back too.
        var isWritten = false
        /// The states received since it was written. The first may be one the store sent
        /// before the write; the second can't be.
        var statesSinceWritten = 0
    }

    /// - Parameters:
    ///   - recordingChanged: Told when the recorder starts and stops listening, so the hotkey
    ///     can be given up meanwhile and its chord recorded.
    public init(
        configFile: URL, update: @escaping Update,
        openConfigFile: @escaping @MainActor () -> Void,
        openKeyboardShortcuts: @escaping @MainActor () -> Void,
        recordingChanged: @escaping @MainActor (Bool) -> Void
    ) {
        self.configFile = configFile
        self.update = update
        self.openConfigFile = openConfigFile
        self.openKeyboardShortcuts = openKeyboardShortcuts
        recorder = ShortcutRecorder(recordingChanged: recordingChanged)
        recorder.recorded = { [weak self] chord in self?.change { $0.hotkey = chord } }
    }

    /// Takes what the config store read.
    public func receive(_ state: ConfigStore.State) {
        if isFileBroken, !state.isFileBroken { writeError = nil }
        stored = state.settings
        errors = state.errors
        isFileBroken = state.isFileBroken
        for index in pending.indices where pending[index].isWritten {
            pending[index].statesSinceWritten += 1
        }
        pending.removeAll { $0.isWritten && ($0.statesSinceWritten >= 2 || isRead($0)) }
        show()
    }

    /// Shows `change` at once and writes it into the file. While the file has an error nothing is
    /// written, and `writeError` says so.
    public func change(_ change: @escaping Change) {
        guard !isFileBroken else {
            // The file broke after the control was used, as while a shortcut was being recorded.
            writeError = ConfigError(
                reason: "The change wasn't saved, since the config file has an error.")
            return
        }
        nextID += 1
        let id = nextID
        pending.append(Pending(id: id, change: change))
        show()
        lastWrite = Task { [previous = lastWrite, update] in
            await previous?.value
            do throws(ConfigError) {
                try await update(change)
                written(id)
            } catch {
                failed(id, error)
            }
        }
    }

    /// The errors the window lists: the file's, and the failed write's when there is one.
    var shownErrors: [ConfigError] {
        (isFileBroken ? errors : []) + (writeError.map { [$0] } ?? [])
    }

    private func written(_ id: Int) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        writeError = nil
        pending[index].isWritten = true
        if isRead(pending[index]) { pending.remove(at: index) }
        show()
    }

    private func failed(_ id: Int, _ error: ConfigError) {
        writeError = error
        pending.removeAll { $0.id == id }
        show()
    }

    /// Whether the settings read already have what `pending` changes.
    private func isRead(_ pending: Pending) -> Bool {
        var changed = stored
        pending.change(&changed)
        return changed == stored
    }

    private func show() {
        var shown = stored
        for change in pending { change.change(&shown) }
        if shown != settings { settings = shown }
    }
}
