import Base

/// The items a query is matched against, and the ranking of a query's matches.
///
/// Matches rank by `FuzzyMatch.Score`: the kind of match first, then a subsequence's quality.
/// Equal scores rank by the usage bonus, then the shorter folded title, then the folded titles'
/// byte order, then the id, so the order never depends on the items' order.
public struct SearchIndex: Sendable {
    /// One ranked match.
    public struct Result: Sendable {
        public let item: SearchItem
        public let match: FuzzyMatch
    }

    public let items: [SearchItem]

    public init(items: [SearchItem]) {
        self.items = items
    }

    /// The `limit` best matches for `query`, best first. An empty query matches nothing.
    ///
    /// `usage` gives an item's bonus from how often and how recently it was opened; it only
    /// orders matches of equal score. It is called once per matching item.
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
            guard let score = query.score(item.foldedTitle) else { continue }
            let ranked = Ranked(score: score, usage: usage(item), index: index)
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
            guard let match = query.match(item.foldedTitle) else {
                preconditionFailure("\(item.title) scored but didn't match")
            }
            return Result(item: item, match: match)
        }
    }

    /// A scored item, before its ranges are worked out.
    private struct Ranked {
        let score: FuzzyMatch.Score
        let usage: Int
        let index: Int
    }

    /// Whether `a` ranks before `b`.
    private func precedes(_ a: Ranked, _ b: Ranked) -> Bool {
        if a.score != b.score { return a.score > b.score }
        if a.usage != b.usage { return a.usage > b.usage }
        let first = items[a.index]
        let second = items[b.index]
        let x = first.foldedTitle.bytes
        let y = second.foldedTitle.bytes
        if x.count != y.count { return x.count < y.count }
        if x != y { return x.lexicographicallyPrecedes(y) }
        return first.id < second.id
    }
}
