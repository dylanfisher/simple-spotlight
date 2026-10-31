import Foundation

/// The items whose rows draw subdued: with `dimUnused` on, the apps and panes not opened from
/// the panel within `dimAfterDays` (docs/decisions/0014-dim-unused.md). Built with `UsageBoost`,
/// when the panel shows, so a keystroke only looks ids up.
public struct DimmedItems: Sendable {
    /// Nothing dims.
    public static let none = DimmedItems(recent: nil)

    /// The ids opened within `dimAfterDays`; nil when `dimUnused` is off.
    private let recent: Set<String>?

    private init(recent: Set<String>?) {
        self.recent = recent
    }

    /// The items of `usage` dimmed at `now` by `settings`. An item opened exactly
    /// `dimAfterDays` ago still counts as recent.
    public init(_ usage: UsageStore.Usage, settings: Settings, at now: Date) {
        guard settings.dimUnused else {
            recent = nil
            return
        }
        let since = now.addingTimeInterval(-Double(settings.dimAfterDays) * Self.day)
        recent = Set(usage.entries.filter { $0.value.opens.lastOpened >= since }.keys)
    }

    /// Whether `item`'s row draws subdued. Kinds that don't count as opened never do, as they
    /// would always be dim.
    public func contains(_ item: SearchItem) -> Bool {
        guard let recent, item.kind.countsAsOpen else { return false }
        return !recent.contains(item.id)
    }

    private static let day: TimeInterval = 24 * 60 * 60
}
