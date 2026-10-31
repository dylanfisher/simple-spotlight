import Foundation
import Testing

@testable import Search

private func app(_ title: String) -> SearchItem {
    SearchItem(
        id: "app:\(title)", kind: .app, title: title, subtitle: nil,
        target: .openFile(URL(filePath: "/Applications/\(title).app")))
}

private func titles(_ query: String, _ names: [String], limit: Int = 20) -> [String] {
    SearchIndex(items: names.map(app)).results(for: query, limit: limit).map(\.item.title)
}

@Test func exactPrefixRanksFirst() {
    let ranked = titles("saf", ["Font Book", "Microsoft Safety Scanner", "Safari"])
    #expect(ranked == ["Safari", "Microsoft Safety Scanner"])
}

@Test func wordStartPrefixBeatsSubsequence() {
    #expect(titles("code", ["Xcode", "Visual Studio Code"]) == ["Visual Studio Code", "Xcode"])
}

@Test func initialsMatch() {
    #expect(titles("vsc", ["Safari", "Visual Studio Code"]) == ["Visual Studio Code"])
}

@Test func foldsTheQuery() {
    #expect(titles("é", ["e"]) == ["e"])
    #expect(titles("ｃ", ["c"]) == ["c"])
}

@Test func emptyQueryReturnsNothing() {
    #expect(titles("", ["Safari", "Mail"]).isEmpty)
}

@Test func tiesOrderByShorterThenAlphabetical() {
    let ranked = titles("ma", ["Maps Extra", "Maps", "Mailbox", "Mail"])
    #expect(ranked == ["Mail", "Maps", "Mailbox", "Maps Extra"])
}

@Test func usageBreaksTiesWithinAClass() {
    let index = SearchIndex(items: ["Mail", "Maps"].map(app))
    let ranked = index.results(for: "ma", limit: 5) { $0.title == "Maps" ? 1 : 0 }
    #expect(ranked.map(\.item.title) == ["Maps", "Mail"])
}

@Test func usageDoesNotCrossClasses() {
    let index = SearchIndex(items: ["Safari", "Microsoft Safety Scanner"].map(app))
    let ranked = index.results(for: "saf", limit: 5) { $0.title == "Safari" ? 0 : 100 }
    #expect(ranked.map(\.item.title) == ["Safari", "Microsoft Safety Scanner"])
}

@Test func limitIsHonored() {
    let names = (0..<50).map { "Item \($0)" }
    #expect(titles("item", names, limit: 8).count == 8)
    #expect(titles("item", names, limit: 0).isEmpty)
}

@Test func keepsTheBestWhenTheLimitCuts() {
    let ranked = titles("saf", ["Microsoft Safety Scanner", "Font Book", "Safari"], limit: 1)
    #expect(ranked == ["Safari"])
}

@Test func resultsCarryTheMatchedRanges() {
    let result = SearchIndex(items: [app("Safari")]).results(for: "saf", limit: 1)[0]
    #expect(result.match.ranges.map { String(result.item.title[$0]) } == ["Saf"])
}

@Suite(.serialized) struct SearchIndexTiming {
    /// B2 gives a keystroke 16 ms; the model's part is bounded at 5x that so a debug build under
    /// load doesn't flake.
    @Test func ranksFiveThousandItemsWithinBudget() {
        let words = ["alpha", "bravo", "Charlie", "delta", "Echo", "foxtrot", "golf", "Hotel"]
        let items = (0..<5_000).map { n in
            app("\(words[n % 8]) \(words[(n / 8) % 8])\(words[(n / 64) % 8]) \(n)")
        }
        let index = SearchIndex(items: items)
        let clock = ContinuousClock()
        var count = 0
        let elapsed = clock.measure {
            count = index.results(for: "dec", limit: 8).count
        }
        #expect(count == 8)
        #expect(elapsed < .milliseconds(80))
    }
}

@Test func whitespaceQueryReturnsNothing() {
    #expect(titles(" ", ["Visual Studio Code", "Safari"]).isEmpty)
    #expect(titles("code ", ["Visual Studio Code"]) == ["Visual Studio Code"])
}

@Test func fullTiesKeepTheItemsOrder() {
    let items = ["first", "second"].map { tag in
        SearchItem(
            id: "same", kind: .app, title: "Mail", subtitle: tag,
            target: .openFile(URL(filePath: "/Applications/Mail.app")))
    }
    let subtitles = { (items: [SearchItem]) in
        SearchIndex(items: items).results(for: "mail", limit: 5).map(\.item.subtitle)
    }
    #expect(subtitles(items) == ["first", "second"])
    #expect(subtitles(items.reversed()) == ["second", "first"])
}
