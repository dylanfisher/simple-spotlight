import AppKit

/// A pane of the settings window, in toolbar order
/// (docs/decisions/0015-settings-window.md).
public enum SettingsPane: String, CaseIterable, Sendable {
    case general, results, apps, shortcut, spotlight

    var item: NSToolbarItem.Identifier { NSToolbarItem.Identifier(rawValue) }

    /// The toolbar item's label and the window's title while the pane shows.
    var title: String {
        switch self {
        case .general: "General"
        case .results: "Results"
        case .apps: "Apps"
        case .shortcut: "Shortcut"
        case .spotlight: "Spotlight"
        }
    }

    /// The toolbar item's SF Symbol.
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .results: "list.bullet.rectangle"
        case .apps: "square.grid.2x2"
        case .shortcut: "keyboard"
        case .spotlight: "magnifyingglass"
        }
    }

    /// The content's height when the pane is chosen: room for what it shows without a scroll,
    /// except a long list of folders or apps.
    var height: CGFloat {
        switch self {
        case .general: 320
        case .results: 410
        case .apps: 520
        case .shortcut: 170
        case .spotlight: 210
        }
    }
}
