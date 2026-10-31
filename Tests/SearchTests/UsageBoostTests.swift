import Foundation
import Testing

@testable import Search

private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

@Test func anOpenHalvesEveryHalfLife() {
    let usage = UsageStore.Usage(entries: [
        "a": .init(opens: .init(count: 1, lastOpened: now)),
        "b": .init(
            opens: .init(count: 4, lastOpened: now.addingTimeInterval(-2 * UsageBoost.halfLife))),
    ])
    let boost = UsageBoost(usage, at: now)

    #expect(boost.frecency(of: "a") == 1)
    #expect(boost.frecency(of: "b") == 1)
    #expect(boost.frecency(of: "never opened") == 0)
}

@Test func recordingAddsOneToTheDecayedCount() {
    var usage = UsageStore.Usage()
    usage.record("a", query: "a", at: now.addingTimeInterval(-UsageBoost.halfLife))
    usage.record("a", query: "a", at: now)

    #expect(usage.entries["a"]?.opens == .init(count: 1.5, lastOpened: now))
    #expect(usage.entries["a"]?.queries == ["a": .init(count: 1.5, lastOpened: now)])
}

@Test func aClockSetBackAddsNoWeight() {
    #expect(UsageBoost.decayed(2, over: -UsageBoost.halfLife) == 2)
}

@Test func learnedSumsThePicksForQueriesLikeTheQuery() {
    var usage = UsageStore.Usage()
    usage.record("chrome", query: "c", at: now.addingTimeInterval(-UsageBoost.halfLife))
    usage.record("chrome", query: "chr", at: now)
    usage.record("chrome", query: "go", at: now)
    usage.record("chess", query: "che", at: now)
    let boost = UsageBoost(usage, at: now)

    #expect(boost.learned(for: "ch") == ["chrome": 1.5, "chess": 1])
    #expect(boost.learned(for: "chr") == ["chrome": 1.5])
    #expect(boost.learned(for: "x").isEmpty)
    #expect(boost.learned(for: " ").isEmpty)
}
