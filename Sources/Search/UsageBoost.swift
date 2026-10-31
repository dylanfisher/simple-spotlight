import Foundation

/// Each item's frecency at one moment: how many times it was opened, each open's weight halving
/// every `halfLife` since (docs/decisions/0010-usage-ranking.md). `SearchIndex.results` ranks
/// by it, as `SearchIndex.precedes` describes. Built when the panel shows, so a keystroke only
/// looks frecencies up.
public struct UsageBoost: Sendable {
    /// Two weeks: an app opened daily last month ranks below one opened daily this week.
    public static let halfLife: TimeInterval = 14 * 24 * 60 * 60
    /// The frecency at which an item ranks with the matches one kind better: three opens today,
    /// or about one every other day for the last two weeks.
    public static let liftingFrecency = 3.0
    /// No item has been opened.
    public static let none = UsageBoost(frecencies: [:])

    private let frecencies: [String: Double]

    private init(frecencies: [String: Double]) {
        self.frecencies = frecencies
    }

    /// The frecencies of `usage`'s entries at `now`.
    public init(_ usage: UsageStore.Usage, at now: Date) {
        frecencies = usage.entries.mapValues { $0.frecency(at: now) }
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
