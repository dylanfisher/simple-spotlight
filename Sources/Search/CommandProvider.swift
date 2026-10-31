/// The built-in rows: opening the config file and quitting, which the app has no menu bar or
/// Dock icon for. They are index items, so they rank like any app.
public struct CommandProvider: Sendable {
    /// A built-in command.
    public enum Command: String, Sendable, CaseIterable {
        case openConfig = "config"
        case quit

        /// Both the row's id, which usage is keyed by, and the identifier its `.command` target
        /// carries.
        public var id: String { SearchItem.builtInID(rawValue) }

        /// The command whose `id` is `id`.
        public init?(id: String) {
            guard let command = Self.allCases.first(where: { $0.id == id }) else { return nil }
            self = command
        }
    }

    /// The app's name as its bundle gives it, which the rows' titles carry.
    public let appName: String

    public init(appName: String) {
        self.appName = appName
    }

    public var items: [SearchItem] {
        Command.allCases.map { command in
            SearchItem(
                id: command.id, kind: .command, title: title(of: command), subtitle: nil,
                target: .command(command.id))
        }
    }

    private func title(of command: Command) -> String {
        switch command {
        case .openConfig: "\(appName) Config"
        case .quit: "Quit \(appName)"
        }
    }
}
