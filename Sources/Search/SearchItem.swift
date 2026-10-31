import Base
import Foundation

/// One row the panel can show and open: an app, a System Settings pane, a calculator answer or a
/// built-in command.
public struct SearchItem: Sendable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case app, settingsPane, calculation, command
    }

    /// What opening the item does.
    public enum Target: Sendable, Equatable {
        /// Opens the file, folder or bundle at the URL, as an app or a `.prefPane`.
        case openFile(URL)
        /// Opens the URL with its handler, as a `x-apple.systempreferences:` pane.
        case openURL(URL)
        /// Puts the text on the clipboard.
        case copyText(String)
        /// Runs the built-in command with this identifier.
        case command(String)
    }

    /// Stable across launches and index rebuilds, so usage can be keyed by it: a bundle ID, a
    /// path, or a command's identifier.
    public let id: String
    public let kind: Kind
    public let title: String
    public let subtitle: String?
    public let target: Target
    /// Other names the item is found by but not shown with, such as an app's English file name
    /// ("Calculator") when its title is localized ("Rechner").
    public let alternateNames: [String]
    /// `title` folded for matching, built here so a keystroke never folds it.
    public let foldedTitle: FoldedText
    /// `alternateNames` folded, likewise.
    public let foldedAlternates: [FoldedText]

    public init(
        id: String, kind: Kind, title: String, subtitle: String?, target: Target,
        alternateNames: [String] = []
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.target = target
        self.alternateNames = alternateNames
        foldedTitle = FoldedText(title)
        foldedAlternates = alternateNames.map(FoldedText.init)
    }
}
