import Base

/// The items a query is matched against, and the ranking of a query's matches, in the order
/// `precedes` gives.
public struct SearchIndex: Sendable {
    /// One ranked match.
    public struct Result: Sendable {
        public let item: SearchItem
        /// The better of the title's and the alternate names' scores.
        public let score: FuzzyMatch.Score
        /// The matched characters of the title; empty when an alternate name matched better.
        public let ranges: [Range<String.Index>]
    }

    public let items: [SearchItem]

    public init(items: [SearchItem]) {
        self.items = items
    }

    /// The `limit` best matches for `query`, best first. An empty query matches nothing.
    ///
    /// `usage` gives each item's frecency; `precedes` says where it counts.
    public func results(for query: String, limit: Int, usage: UsageBoost = .none) -> [Result] {
        precondition(limit >= 0, "a negative limit \(limit)")
        let query = FuzzyMatch.Query(query)
        guard limit > 0, !query.isEmpty else { return [] }
        // Kept sorted best first. A binary insertion into at most `limit` entries is cheaper than
        // sorting every match when a short query matches most items.
        var top: [Ranked] = []
        top.reserveCapacity(limit + 1)
        for (index, item) in items.enumerated() {
            guard let (score, byTitle) = Self.score(query, item) else { continue }
            let ranked = Ranked(
                score: score, byTitle: byTitle, frecency: usage.frecency(of: item.id), index: index)
            if top.count == limit, let last = top.last, !precedes(ranked, last) { continue }
            var low = 0
            var high = top.count
            while low < high {
                let middle = (low + high) / 2
                if precedes(top[middle], ranked) { low = middle + 1 } else { high = middle }
            }
            top.insert(ranked, at: low)
            if top.count > limit { top.removeLast() }
        }
        return top.map { ranked in
            let item = items[ranked.index]
            guard ranked.byTitle else { return Result(item: item, score: ranked.score, ranges: []) }
            guard let match = query.match(item.foldedTitle) else {
                preconditionFailure("\(item.title) scored but didn't match")
            }
            return Result(item: item, score: ranked.score, ranges: match.ranges)
        }
    }

    /// A scored item, before its ranges are worked out.
    private struct Ranked {
        let score: FuzzyMatch.Score
        /// Whether the title gave the score, rather than an alternate name.
        let byTitle: Bool
        let frecency: Double
        let index: Int

        /// Whether usage lifts it to the level of the kind of match above its own.
        var lifted: Bool { frecency >= UsageBoost.liftingFrecency }
        var level: Int { score.kind.rawValue + (lifted ? 1 : 0) }
    }

    /// The best score of `item`'s title and alternate names, and whether the title gave it. The
    /// title wins a tie, so its ranges can be shown.
    private static func score(_ query: FuzzyMatch.Query, _ item: SearchItem) -> (
        FuzzyMatch.Score, Bool
    )? {
        var best = query.score(item.foldedTitle).map { ($0, true) }
        for alternate in item.foldedAlternates {
            guard let score = query.score(alternate) else { continue }
            if best.map({ score > $0.0 }) ?? true { best = (score, false) }
        }
        return best
    }

    /// Whether `a` ranks before `b`.
    ///
    /// An item is lifted when its frecency reaches `UsageBoost.liftingFrecency`. Its level is its
    /// kind of match, one higher when lifted, so a lifted subsequence has the level of initials
    /// and a lifted exact prefix a level of its own above every other. In order:
    ///
    /// 1. The higher level.
    /// 2. Within a level, a lifted item before one that isn't. The lifted items of a level are
    ///    the kind below its unlifted ones, so a much-used item passes the matches one kind
    ///    better that aren't, and never a kind two better: those are a level above it at least.
    /// 3. The higher subsequence quality, as items of a level and lift have the same kind.
    /// 4. The higher frecency, so usage short of the lift breaks ties within a kind.
    /// 5. The shorter folded title, then the folded titles' byte order, then the id.
    ///
    /// Items that tie on all of these, as duplicates do, keep the order they have in `items`.
    /// Usage only orders matches: an item the query doesn't match isn't ranked at all.
    private func precedes(_ a: Ranked, _ b: Ranked) -> Bool {
        if a.level != b.level { return a.level > b.level }
        if a.lifted != b.lifted { return a.lifted }
        if a.score.quality != b.score.quality { return a.score.quality > b.score.quality }
        if a.frecency != b.frecency { return a.frecency > b.frecency }
        let first = items[a.index]
        let second = items[b.index]
        let x = first.foldedTitle.bytes
        let y = second.foldedTitle.bytes
        if x.count != y.count { return x.count < y.count }
        if x != y { return x.lexicographicallyPrecedes(y) }
        if first.id != second.id { return first.id < second.id }
        return a.index < b.index
    }
}
