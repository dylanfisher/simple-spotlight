/// The built-in rows: opening the settings window and quitting, which the app has no menu bar
/// or Dock icon for. They are index items, so they rank like any app.
public struct CommandProvider: Sendable {
    /// A built-in command.
    public enum Command: String, Sendable, CaseIterable {
        case openSettings = "settings"
        case quit
        /// Opens the config file: the config error row's command, which has no row of its own.
        case openConfig = "config"

        /// Both the row's id and the identifier its `.command` target carries.
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

    /// The commands that are rows, with their titles.
    public var items: [SearchItem] {
        [(Command.openSettings, "\(appName) Settings"), (.quit, "Quit \(appName)")].map {
            command, title in
            SearchItem(
                id: command.id, kind: .command, title: title, subtitle: nil,
                target: .command(command.id))
        }
    }
}
