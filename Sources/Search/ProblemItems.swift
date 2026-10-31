import Foundation

/// The rows the panel shows above the results while something is wrong: one for the config
/// file's errors and one for what the index had to leave out
/// (docs/decisions/0009-app-wiring.md).
public enum ProblemItems {
    /// Each problem row, which has one id whatever its words.
    public enum ID: String, Sendable, CaseIterable {
        case config, hotKey, loginItem, index

        public var id: String { SearchItem.builtInID("problem.\(rawValue)") }
    }

    /// A problem row: the one shape every source of problems shares.
    public static func row(
        _ id: ID, title: String, subtitle: String, target: SearchItem.Target
    ) -> SearchItem {
        SearchItem(id: id.id, kind: .problem, title: title, subtitle: subtitle, target: target)
    }

    /// The row for the config file's errors, which opens the file; nil when there are none.
    /// It shows the first error, since the file is where all of them are fixed.
    public static func config(_ errors: [ConfigError], file: URL) -> SearchItem? {
        guard let first = errors.first else { return nil }
        let title =
            first.line == nil ? "Config file \(first.reason)" : "Config error: \(first)"
        let opens =
            "Return opens \((file.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath)"
        let more = errors.count - 1
        let subtitle =
            switch more {
            case 0: opens
            case 1: "1 more error · \(opens)"
            default: "\(more) more errors · \(opens)"
            }
        return row(
            .config, title: title, subtitle: subtitle,
            target: .command(CommandProvider.Command.openConfig.id))
    }

    /// The row for the problems of the last index build, which copies them all; nil when there
    /// are none. A row can show one problem, and the copy holds the rest.
    public static func index(_ problems: [IndexProblem]) -> SearchItem? {
        guard let first = problems.first else { return nil }
        let title: String
        var subtitle = first.description
        if problems.count == 1 {
            title = "Couldn't search \(URL(filePath: first.path).lastPathComponent)"
        } else {
            title = "Couldn't search \(problems.count) folders or apps"
            subtitle += " · Return copies all \(problems.count)"
        }
        return row(
            .index, title: title, subtitle: subtitle,
            target: .copyText(problems.map(\.description).joined(separator: "\n")))
    }
}
