import Foundation

/// What the user has opened from the panel, which ranks the results
/// (docs/decisions/0010-usage-ranking.md). Reads and writes `usage.json` off the main actor; a
/// burst of opens is written once, `writeDelay` after the first.
public actor UsageStore {
    /// Returns after the duration, or throws once cancelled.
    public typealias Sleep = @Sendable (Duration) async throws -> Void

    /// The file's one shape: per item id, how often and how recently it was opened. A file that
    /// doesn't decode is discarded, per the pre-release rule.
    public struct Usage: Codable, Equatable, Sendable {
        public struct Entry: Codable, Equatable, Sendable {
            /// The opens as of `lastOpened`, each weighted by half for every
            /// `UsageBoost.halfLife` between it and `lastOpened`, so the last open counts 1.
            public var count: Double
            public var lastOpened: Date

            /// The opens' weight at `now`.
            public func frecency(at now: Date) -> Double {
                UsageBoost.decayed(count, over: now.timeIntervalSince(lastOpened))
            }
        }

        /// Keyed by `SearchItem.id`.
        public var entries: [String: Entry] = [:]

        public init(entries: [String: Entry] = [:]) {
            self.entries = entries
        }

        /// Counts an open of the item with `id` at `date`.
        public mutating func record(_ id: String, at date: Date) {
            let earlier = entries[id]?.frecency(at: date) ?? 0
            entries[id] = Entry(count: earlier + 1, lastOpened: date)
        }

        /// Drops the entries whose frecency at `now` is below `UsageStore.forgetBelow`.
        mutating func forget(at now: Date) {
            entries = entries.filter { $0.value.frecency(at: now) >= UsageStore.forgetBelow }
        }
    }

    /// How long after an open the file is written, so the opens in between are written with it.
    public static let writeDelay: Duration = .seconds(1)
    /// An entry whose frecency has fallen below this is dropped when the file is loaded: one
    /// open, six half-lives (twelve weeks) ago. It keeps the file to what was opened lately,
    /// including ids of apps since deleted, without the store knowing the index.
    public static let forgetBelow = 1.0 / 64

    public nonisolated let file: URL
    private let folder: URL
    private let sleep: Sleep
    private let writeFailed: @Sendable (any Error) -> Void
    /// The usage as last read or recorded; nil until the first read.
    private var usage: Usage?
    /// Whether `usage` holds an open the file doesn't.
    private var unwritten = false
    /// The write waiting for `writeDelay`, for tests to wait on.
    private(set) var writing: Task<Void, Never>?
    /// The writes made, for tests.
    private(set) var writes = 0

    /// A store of `usage.json` in `folder`, which is made when first written. `writeFailed` is
    /// told when a delayed write fails, since no caller is waiting for it.
    public init(
        folder: URL, sleep: @escaping Sleep = { try await Task.sleep(for: $0) },
        writeFailed: @escaping @Sendable (any Error) -> Void
    ) {
        self.folder = folder
        file = folder.appending(path: "usage.json")
        self.sleep = sleep
        self.writeFailed = writeFailed
    }

    /// The usage on file, less the entries forgotten by `now`.
    public func load(at now: Date) throws -> Usage {
        var read = try contents()
        read.forget(at: now)
        usage = read
        return read
    }

    /// Counts an open of the item with `id` at `date`, writes it after `writeDelay`, and returns
    /// the usage with it.
    public func record(_ id: String, at date: Date) throws -> Usage {
        var updated = try contents()
        updated.record(id, at: date)
        usage = updated
        unwritten = true
        if writing == nil {
            writing = Task {
                do {
                    try await sleep(Self.writeDelay)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                writing = nil
                do {
                    try write()
                } catch {
                    writeFailed(error)
                }
            }
        }
        return updated
    }

    /// Writes an open still waiting for `writeDelay` now, as the app does before it quits.
    public func flush() throws {
        writing?.cancel()
        writing = nil
        try write()
    }

    private func write() throws {
        guard unwritten, let usage else { return }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(usage).write(to: file, options: .atomic)
        unwritten = false
        writes += 1
    }

    /// The file's contents, empty when there is no file or it doesn't decode. Any other read
    /// error is thrown.
    private func contents() throws -> Usage {
        if let usage { return usage }
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch CocoaError.fileReadNoSuchFile {
            usage = Usage()
            return Usage()
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // The pre-release rule: data of another shape is dropped and replaced at the next write.
        let read = (try? decoder.decode(Usage.self, from: data)) ?? Usage()
        usage = read
        return read
    }
}
