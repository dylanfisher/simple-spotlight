/// The built-in rows: opening the config file and quitting, which the app has no menu bar or
/// Dock icon for. They are index items, so they rank like any app.
public struct CommandProvider: Sendable {
    /// A built-in command. The raw value is both the row's id, which usage is keyed by, and the
    /// identifier its `.command` target carries.
    public enum Command: String, Sendable, CaseIterable {
        case openConfig = "simple-spotlight.config"
        case quit = "simple-spotlight.quit"
    }

    /// The app's name as its bundle gives it, which the rows' titles carry.
    public let appName: String

    public init(appName: String) {
        self.appName = appName
    }

    public var items: [SearchItem] {
        Command.allCases.map { command in
            SearchItem(
                id: command.rawValue, kind: .command, title: title(of: command), subtitle: nil,
                target: .command(command.rawValue))
        }
    }

    private func title(of command: Command) -> String {
        switch command {
        case .openConfig: "\(appName) Config"
        case .quit: "Quit \(appName)"
        }
    }
}
