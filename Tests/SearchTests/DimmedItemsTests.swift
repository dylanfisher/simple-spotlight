import Foundation
import Testing

@testable import Search

private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
private let day: TimeInterval = 24 * 60 * 60

private func item(_ id: String, _ kind: SearchItem.Kind) -> SearchItem {
    SearchItem(id: id, kind: kind, title: id, subtitle: nil, target: .command(id))
}

/// Usage with each id last opened that many days before `now`.
private func usage(_ daysAgo: [String: Double]) -> UsageStore.Usage {
    UsageStore.Usage(
        entries: daysAgo.mapValues {
            .init(opens: .init(count: 1, lastOpened: now.addingTimeInterval(-$0 * day)))
        })
}

@Test func dimsAppsAndPanesNeverOpenedOrNotOpenedWithinTheDays() {
    let dimmed = DimmedItems(
        usage(["recent": 1, "edge": 30, "stale": 31, "pane": 2]), settings: Settings(), at: now)

    #expect(Settings().dimAfterDays == 30)
    #expect(!dimmed.contains(item("recent", .app)))
    #expect(!dimmed.contains(item("edge", .app)))
    #expect(dimmed.contains(item("stale", .app)))
    #expect(dimmed.contains(item("never", .app)))
    #expect(!dimmed.contains(item("pane", .settingsPane)))
    #expect(dimmed.contains(item("other pane", .settingsPane)))
}

/// Usage isn't recorded for them (docs/decisions/0010-usage-ranking.md), so they would always
/// dim.
@Test func neverDimsAnswersCommandsOrProblems() {
    let dimmed = DimmedItems(UsageStore.Usage(), settings: Settings(), at: now)

    for kind: SearchItem.Kind in [.calculation, .command, .problem] {
        #expect(!dimmed.contains(item("never", kind)))
    }
}

@Test func dimsNothingWithDimUnusedOff() {
    var settings = Settings()
    settings.dimUnused = false

    let dimmed = DimmedItems(usage(["stale": 100]), settings: settings, at: now)

    #expect(!dimmed.contains(item("stale", .app)))
    #expect(!dimmed.contains(item("never", .app)))
    #expect(!DimmedItems.none.contains(item("never", .app)))
}

@Test func dimAfterDaysSetsHowLongAnOpenKeepsAnItemBright() {
    var settings = Settings()
    settings.dimAfterDays = 7

    let dimmed = DimmedItems(usage(["a": 6, "b": 8]), settings: settings, at: now)

    #expect(!dimmed.contains(item("a", .app)))
    #expect(dimmed.contains(item("b", .app)))
}
