import Foundation
import Testing

@testable import Search

private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

@Test func anOpenHalvesEveryHalfLife() {
    let usage = UsageStore.Usage(entries: [
        "a": .init(count: 1, lastOpened: now),
        "b": .init(count: 4, lastOpened: now.addingTimeInterval(-2 * UsageBoost.halfLife)),
    ])
    let boost = UsageBoost(usage, at: now)

    #expect(boost.frecency(of: "a") == 1)
    #expect(boost.frecency(of: "b") == 1)
    #expect(boost.frecency(of: "never opened") == 0)
}

@Test func recordingAddsOneToTheDecayedCount() {
    var usage = UsageStore.Usage()
    usage.record("a", at: now.addingTimeInterval(-UsageBoost.halfLife))
    usage.record("a", at: now)

    #expect(usage.entries["a"] == .init(count: 1.5, lastOpened: now))
}

@Test func aClockSetBackAddsNoWeight() {
    #expect(UsageBoost.decayed(2, over: -UsageBoost.halfLife) == 2)
}
