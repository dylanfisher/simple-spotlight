import Foundation

/// What the app remembers between launches that isn't a setting: the hotkeys whose conflict the
/// user has been told about, so the alert shows once per chord rather than at every launch
/// (docs/decisions/0009-app-wiring.md). Reads and writes `state.json` off the main actor.
public actor AppStateStore {
    /// The file's one shape. A file that doesn't decode is discarded, per the pre-release rule.
    struct Contents: Codable, Equatable {
        /// Chords as the config file spells them, such as "cmd+space".
        var acknowledgedHotKeys: [String] = []
    }

    public nonisolated let file: URL
    private let folder: URL
    /// The file as last read or written; nil until the first read.
    private var contents: Contents?

    /// A store of `state.json` in `folder`, which is made when first written.
    public init(folder: URL) {
        self.folder = folder
        file = folder.appending(path: "state.json")
    }

    /// The chords whose conflict the user has been told about.
    public func acknowledgedHotKeys() throws -> Set<String> {
        Set(try load().acknowledgedHotKeys)
    }

    /// Remembers that the user has been told `hotKey`, a chord as the config file spells it,
    /// conflicts.
    public func acknowledge(hotKey: String) throws {
        var updated = try load()
        guard !updated.acknowledgedHotKeys.contains(hotKey) else { return }
        updated.acknowledgedHotKeys.append(hotKey)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(updated).write(to: file, options: .atomic)
        contents = updated
    }

    /// The file's contents, empty when there is no file or it doesn't decode. Any other read
    /// error is thrown.
    private func load() throws -> Contents {
        if let contents { return contents }
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch CocoaError.fileReadNoSuchFile {
            contents = Contents()
            return Contents()
        }
        // The pre-release rule: data of another shape is dropped and replaced at the next write.
        let read = (try? JSONDecoder().decode(Contents.self, from: data)) ?? Contents()
        contents = read
        return read
    }
}
