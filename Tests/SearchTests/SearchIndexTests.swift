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

private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

/// Usage in which each title was opened its number of times just now, so its frecency is that
/// number.
private func usage(_ opens: [String: Double]) -> UsageBoost {
    let entries = opens.mapValues { UsageStore.Usage.Entry(count: $0, lastOpened: now) }
    return UsageBoost(
        UsageStore.Usage(
            entries: Dictionary(uniqueKeysWithValues: entries.map { ("app:\($0)", $1) })),
        at: now)
}

private func titles(_ query: String, _ names: [String], opens: [String: Double]) -> [String] {
    SearchIndex(items: names.map(app)).results(for: query, limit: 20, usage: usage(opens))
        .map(\.item.title)
}

@Test func openingAnItemTwiceLiftsItAboveAnEqualMatch() {
    #expect(titles("ma", ["Mail", "Maps"], opens: ["Maps": 2]) == ["Maps", "Mail"])
}

@Test func usageBelowTheLiftStaysWithinItsKind() {
    let opens = UsageBoost.liftingFrecency.nextDown
    #expect(
        titles("code", ["Visual Studio Code", "Codex"], opens: ["Visual Studio Code": opens])
            == ["Codex", "Visual Studio Code"])
}

@Test func usageAtTheLiftPassesTheMatchesOneKindBetter() {
    let opens = UsageBoost.liftingFrecency
    #expect(
        titles("code", ["Visual Studio Code", "Codex"], opens: ["Visual Studio Code": opens])
            == ["Visual Studio Code", "Codex"])
}

/// "Xcode" is a subsequence of "code", "Color Of Dark Edge" its initials, "Visual Studio Code" a
/// word-start prefix and "Codex" an exact prefix.
@Test func usageNeverLiftsAcrossTwoKinds() {
    let names = ["Xcode", "Color Of Dark Edge", "Visual Studio Code", "Codex"]
    #expect(
        titles("code", names, opens: ["Xcode": 1_000])
            == ["Codex", "Visual Studio Code", "Xcode", "Color Of Dark Edge"])
}

@Test func aLiftedMatchStillLosesToALiftedBetterKind() {
    let opens = ["Visual Studio Code": 50.0, "Codex": UsageBoost.liftingFrecency]
    #expect(
        titles("code", ["Visual Studio Code", "Codex"], opens: opens)
            == ["Codex", "Visual Studio Code"])
}

@Test func usageNeverMakesANonMatchMatch() {
    #expect(titles("code", ["Safari", "Codex"], opens: ["Safari": 1_000]) == ["Codex"])
}

/// Decision 0002: two subsequences of different quality aren't a tie, so usage short of the
/// lift doesn't reorder them.
@Test func subsequenceQualityRanksBeforeUsageShortOfTheLift() {
    let opens = UsageBoost.liftingFrecency.nextDown
    #expect(
        titles("code", ["Color Draw Editor", "Xcode"], opens: ["Color Draw Editor": opens])
            == ["Xcode", "Color Draw Editor"])
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
    #expect(result.ranges.map { String(result.item.title[$0]) } == ["Saf"])
}

private let calculator = SearchItem(
    id: "com.apple.calculator", kind: .app, title: "Rechner", subtitle: nil,
    target: .openFile(URL(filePath: "/System/Applications/Calculator.app")),
    alternateNames: ["Calculator"])

@Test func matchesAnAlternateNameWithoutRanges() throws {
    let index = SearchIndex(items: [calculator, app("Calendar")])
    let results = index.results(for: "calc", limit: 5)
    let result = try #require(results.first)
    #expect(results.map(\.item.title) == ["Rechner"])
    #expect(result.score.kind == .exactPrefix)
    #expect(result.ranges.isEmpty)
}

@Test func aTitleMatchKeepsItsRanges() throws {
    let result = try #require(SearchIndex(items: [calculator]).results(for: "rech", limit: 5).first)
    #expect(result.ranges.map { String(result.item.title[$0]) } == ["Rech"])
}

@Test func anAlternateMatchRanksByItsKind() {
    // The alternate's exact prefix beats the other item's initials.
    let index = SearchIndex(items: [app("Cool Alarm Light"), calculator])
    #expect(
        index.results(for: "cal", limit: 5).map(\.item.title) == ["Rechner", "Cool Alarm Light"])
}

@Suite(.serialized) struct SearchIndexTiming {
    /// B2 gives a keystroke 16 ms; the model's part is bounded at 5x that so a debug build under
    /// load doesn't flake. One item in ten has been opened, so usage is looked up and compared.
    @Test func ranksFiveThousandItemsWithinBudget() {
        let words = ["alpha", "bravo", "Charlie", "delta", "Echo", "foxtrot", "golf", "Hotel"]
        let items = (0..<5_000).map { n in
            app("\(words[n % 8]) \(words[(n / 8) % 8])\(words[(n / 64) % 8]) \(n)")
        }
        let index = SearchIndex(items: items)
        var opened = UsageStore.Usage()
        for (n, item) in items.enumerated() where n % 10 == 0 {
            opened.entries[item.id] = .init(count: Double(n % 7), lastOpened: now)
        }
        let boost = UsageBoost(opened, at: now)
        let clock = ContinuousClock()
        var count = 0
        let elapsed = clock.measure {
            count = index.results(for: "dec", limit: 8, usage: boost).count
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
