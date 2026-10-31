import Base
import Foundation

/// What the user has opened from the panel, which ranks the results
/// (docs/decisions/0010-usage-ranking.md). Reads and writes `usage.json` off the main actor; a
/// burst of opens is written once, `writeDelay` after the first.
public actor UsageStore {
    /// Returns after the duration, or throws once cancelled.
    public typealias Sleep = @Sendable (Duration) async throws -> Void

    /// The file's one shape: per item id, how often and how recently it was opened, and from
    /// which queries. A file that doesn't decode is discarded, per the pre-release rule.
    public struct Usage: Codable, Equatable, Sendable {
        /// Some opens, as two numbers that give their decayed sum exactly.
        public struct Opens: Codable, Equatable, Sendable {
            /// The opens as of `lastOpened`, each weighted by half for every
            /// `UsageBoost.halfLife` between it and `lastOpened`, so the last open counts 1.
            public var count: Double
            public var lastOpened: Date

            public init(count: Double, lastOpened: Date) {
                self.count = count
                self.lastOpened = lastOpened
            }

            /// The opens' weight at `now`.
            public func frecency(at now: Date) -> Double {
                UsageBoost.decayed(count, over: now.timeIntervalSince(lastOpened))
            }

            /// `opens` with one more at `date`; one open when `opens` is nil.
            static func adding(at date: Date, to opens: Opens?) -> Opens {
                Opens(count: (opens?.frecency(at: date) ?? 0) + 1, lastOpened: date)
            }
        }

        public struct Entry: Codable, Equatable, Sendable {
            /// Every open of the item.
            public var opens: Opens
            /// The opens of the item from each query, keyed by `Usage.queryKey`: the picks the
            /// ranking learns from (docs/decisions/0010-usage-ranking.md). At most
            /// `UsageStore.queriesPerItem`.
            public var queries: [String: Opens]

            public init(opens: Opens, queries: [String: Opens] = [:]) {
                self.opens = opens
                self.queries = queries
            }
        }

        /// Keyed by `SearchItem.id`.
        public var entries: [String: Entry] = [:]

        public init(entries: [String: Entry] = [:]) {
            self.entries = entries
        }

        /// What a query is remembered and compared by: trimmed, folded as the matcher folds it,
        /// and cut to `UsageStore.queryLength` characters.
        public static func queryKey(_ query: String) -> String {
            String(
                FoldedText.fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
                    .prefix(UsageStore.queryLength))
        }

        /// Counts an open of the item with `id` from `query` at `date`. When the item has more
        /// than `UsageStore.queriesPerItem` queries, the ones with the lowest frecency go, never the
        /// one just recorded.
        public mutating func record(_ id: String, query: String, at date: Date) {
            let earlier = entries[id]
            var queries = earlier?.queries ?? [:]
            let key = Self.queryKey(query)
            if !key.isEmpty {
                queries[key] = Opens.adding(at: date, to: queries[key])
            }
            if queries.count > UsageStore.queriesPerItem {
                // Over the limit means the query just recorded is new. It stays, whatever it
                // weighs, so a pick can start to count; the others compete for the rest.
                var others = queries
                others[key] = nil
                let heaviest = others.map { (key: $0.key, frecency: $0.value.frecency(at: date)) }
                    .sorted {
                        $0.frecency != $1.frecency ? $0.frecency > $1.frecency : $0.key < $1.key
                    }
                    .prefix(UsageStore.queriesPerItem - 1)
                let kept = Set(heaviest.map(\.key) + [key])
                queries = queries.filter { kept.contains($0.key) }
            }
            entries[id] = Entry(opens: .adding(at: date, to: earlier?.opens), queries: queries)
        }

        /// Drops the entries, and the queries of the entries kept, whose frecency at `now` is
        /// below `UsageStore.forgetBelow`.
        mutating func forget(at now: Date) {
            entries = entries.compactMapValues { entry in
                guard entry.opens.frecency(at: now) >= UsageStore.forgetBelow else { return nil }
                var kept = entry
                kept.queries = entry.queries.filter {
                    $0.value.frecency(at: now) >= UsageStore.forgetBelow
                }
                return kept
            }
        }
    }

    /// How long after an open the file is written, so the opens in between are written with it.
    public static let writeDelay: Duration = .seconds(1)
    /// An entry whose frecency has fallen below this is dropped when the file is loaded. It keeps
    /// the file to what was opened lately, including ids of apps since deleted, without the
    /// store knowing the index.
    public static let forgetBelow = 1.0 / 64
    /// The most queries kept per item. A few cover the ways one person types an app's name.
    public static let queriesPerItem = 8
    /// The longest query kept, in characters. Longer ones are cut, and still compare by their
    /// start, as the ranking compares queries by prefix.
    public static let queryLength = 32

    public nonisolated let file: URL
    private let folder: URL
    private let sleep: Sleep
    private let reportProblem: @Sendable (any Error) -> Void
    /// The usage as last read or recorded; nil until the first read.
    private var usage: Usage?
    /// Whether `usage` holds an open the file doesn't.
    private var unwritten = false
    /// The write waiting for `writeDelay`, for tests to wait on.
    private(set) var writing: Task<Void, Never>?
    /// The writes made, for tests.
    private(set) var writes = 0

    /// A store of `usage.json` in `folder`, which is made when first written. `reportProblem` is
    /// told when a delayed write fails, since no caller is waiting for it, and when a file that
    /// doesn't decode is discarded.
    public init(
        folder: URL, sleep: @escaping Sleep = { try await Task.sleep(for: $0) },
        reportProblem: @escaping @Sendable (any Error) -> Void
    ) {
        self.folder = folder
        file = folder.appending(path: "usage.json")
        self.sleep = sleep
        self.reportProblem = reportProblem
    }

    /// The usage on file, less the entries forgotten by `now`.
    public func load(at now: Date) throws -> Usage {
        var read = try contents()
        read.forget(at: now)
        usage = read
        return read
    }

    /// Counts an open of the item with `id` from `query` at `date`, writes it after
    /// `writeDelay`, and returns the usage with it.
    public func record(_ id: String, query: String, at date: Date) throws -> Usage {
        var updated = try contents()
        updated.record(id, query: query, at: date)
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
                    reportProblem(error)
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
        let read: Usage
        do {
            read = try decoder.decode(Usage.self, from: data)
        } catch {
            reportProblem(Discarded(reason: error))
            read = Usage()
        }
        usage = read
        return read
    }

    /// The file didn't decode, so its usage was dropped.
    struct Discarded: Error, CustomStringConvertible {
        let reason: any Error

        var description: String { "discarded a file that didn't decode: \(reason)" }
    }
}
