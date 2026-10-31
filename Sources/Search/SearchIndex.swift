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
    /// `usage` gives an item's bonus from how often and how recently it was opened; `precedes`
    /// says where it counts. It is called once per matching item.
    public func results(
        for query: String, limit: Int, usage: (SearchItem) -> Int = { _ in 0 }
    ) -> [Result] {
        precondition(limit >= 0, "a negative limit \(limit)")
        let query = FuzzyMatch.Query(query)
        guard limit > 0, !query.isEmpty else { return [] }
        // Kept sorted best first. A binary insertion into at most `limit` entries is cheaper than
        // sorting every match when a short query matches most items.
        var top: [Ranked] = []
        top.reserveCapacity(limit + 1)
        for (index, item) in items.enumerated() {
            guard let (score, byTitle) = Self.score(query, item) else { continue }
            let ranked = Ranked(score: score, byTitle: byTitle, usage: usage(item), index: index)
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
        let usage: Int
        let index: Int
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

    /// Whether `a` ranks before `b`: the higher `FuzzyMatch.Score` first (the kind of match,
    /// then a subsequence's quality); at equal scores, the higher usage bonus, then the shorter
    /// folded title, then the folded titles' byte order, then the id. Items that tie on all of
    /// these, as duplicates do, keep the order they have in `items`.
    private func precedes(_ a: Ranked, _ b: Ranked) -> Bool {
        if a.score != b.score { return a.score > b.score }
        if a.usage != b.usage { return a.usage > b.usage }
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
