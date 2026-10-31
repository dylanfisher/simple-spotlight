import Foundation

/// Each item's frecency at one moment: how many times it was opened, each open's weight halving
/// every `halfLife` since, overall and from each query (docs/decisions/0010-usage-ranking.md).
/// `SearchIndex.results` ranks by it, as `SearchIndex.precedes` describes. Built when the panel
/// shows, so a keystroke only looks frecencies up.
public struct UsageBoost: Sendable {
    /// The opens of one item from one query, at the moment the boost was built.
    private struct Pick: Sendable {
        let id: String
        /// The query's `UsageStore.Usage.queryKey`, as bytes, which the prefix test compares.
        let query: [UInt8]
        let frecency: Double
    }

    /// An app opened daily last month ranks below one opened daily this week.
    public static let halfLife: TimeInterval = 14 * 24 * 60 * 60
    /// The frecency at which an item ranks with the matches one kind better.
    public static let liftingFrecency = 3.0
    /// No item has been opened.
    public static let none = UsageBoost(frecencies: [:], picks: [])

    private let frecencies: [String: Double]
    private let picks: [Pick]

    private init(frecencies: [String: Double], picks: [Pick]) {
        self.frecencies = frecencies
        self.picks = picks
    }

    /// The frecencies of `usage`'s entries and of their queries at `now`.
    public init(_ usage: UsageStore.Usage, at now: Date) {
        frecencies = usage.entries.mapValues { $0.opens.frecency(at: now) }
        picks = usage.entries.flatMap { id, entry in
            entry.queries.map { query, opens in
                Pick(id: id, query: Array(query.utf8), frecency: opens.frecency(at: now))
            }
        }
    }

    /// Per item id, the frecency of the item's picks for `query`: its opens from a query that
    /// starts with `query`'s key: the user typed at least this much on the way to the pick.
    /// Items never picked for such a query are absent. Worked out once per keystroke, so each item's rank has one key.
    public func learned(for query: String) -> [String: Double] {
        guard !picks.isEmpty else { return [:] }
        let key = Array(UsageStore.Usage.queryKey(query).utf8)
        guard !key.isEmpty else { return [:] }
        var learned: [String: Double] = [:]
        for pick in picks where pick.query.starts(with: key) {
            learned[pick.id, default: 0] += pick.frecency
        }
        return learned
    }

    /// The frecency of the item with `id`; 0 for one never opened.
    public func frecency(of id: String) -> Double {
        // Most keystrokes rank with few or no opens; an empty table skips hashing the id.
        frecencies.isEmpty ? 0 : frecencies[id, default: 0]
    }

    /// The weight of `count` opens `elapsed` seconds later. A clock set back doesn't add weight.
    public static func decayed(_ count: Double, over elapsed: TimeInterval) -> Double {
        count * exp2(-max(elapsed, 0) / halfLife)
    }
}
