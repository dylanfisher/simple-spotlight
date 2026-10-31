import Foundation

/// The user's settings, and the only type that knows the config file's keys
/// (docs/decisions/0006-config-file.md).
///
/// Each key is declared once, in `Keys`: its name in the file, its type, its default, what it
/// accepts and what it does. `ConfigFile` reads the file and writes the default one from those
/// declarations, so a property's meaning is its key's `summary`.
public struct Settings: Sendable, Equatable {
    public var hotkey: KeyChord = Keys.hotkey.defaultValue
    public var searchApplications: Bool = Keys.searchApplications.defaultValue
    public var searchSystemSettings: Bool = Keys.searchSystemSettings.defaultValue
    public var calculator: Bool = Keys.calculator.defaultValue
    /// As the file writes them; `indexBuilder(home:languages:)` places the `~/` ones.
    public var appFolders: [String] = Keys.appFolders.defaultValue
    public var excludedApps: [String] = Keys.excludedApps.defaultValue
    public var maxResults: Int = Keys.maxResults.defaultValue
    public var launchAtLogin: Bool = Keys.launchAtLogin.defaultValue

    /// Every setting at its default.
    public init() {}

    /// The index these settings ask for: apps from `appFolders`, `~` standing for `home`, and
    /// System Settings panes, each only when its setting is on, less `excludedApps`.
    public func indexBuilder(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        languages: [String] = Locale.preferredLanguages
    ) -> IndexBuilder {
        let apps =
            searchApplications
            ? AppProvider(
                folders: appFolders.map { HomePath.folder($0, home: home) }, languages: languages,
                home: home)
            : AppProvider(folders: [], languages: languages, extraApps: [], home: home)
        let panes =
            searchSystemSettings
            ? SettingsPaneProvider(
                preferencePaneFolders: SettingsPaneProvider.standardPreferencePaneFolders(
                    home: home),
                languages: languages)
            : SettingsPaneProvider(
                extensionFolders: [], preferencePaneFolders: [], languages: languages)
        return IndexBuilder(apps: apps, settingsPanes: panes, excludedIDs: Set(excludedApps))
    }
}

extension Settings {
    /// The config file's keys, each declared once.
    enum Keys {
        static let hotkey = Key(
            \.hotkey, "hotkey", .chord, default: KeyChord(.command, .space),
            "Shows and hides the panel.")
        static let searchApplications = Key(
            \.searchApplications, "searchApplications", .bool, default: true,
            "Find apps.")
        static let searchSystemSettings = Key(
            \.searchSystemSettings, "searchSystemSettings", .bool, default: true,
            "Find System Settings panes.")
        static let calculator = Key(
            \.calculator, "calculator", .bool, default: true,
            "Show the answer when the search is arithmetic, such as 2*(3+4).")
        static let appFolders = Key(
            \.appFolders, "appFolders", .folders,
            default: [
                "/Applications", "/System/Applications",
                "/System/Library/CoreServices/Applications", AppProvider.userApplications,
            ],
            "Folders searched for apps, two levels deep. ~ stands for your home folder.")
        static let excludedApps = Key(
            \.excludedApps, "excludedApps", .identifiers, default: [],
            "Bundle IDs of apps and panes to leave out of the results.")
        static let maxResults = Key(
            \.maxResults, "maxResults", .integer(1...20), default: 8,
            "The most rows the panel shows.")
        static let launchAtLogin = Key(
            \.launchAtLogin, "launchAtLogin", .bool, default: false,
            "Open Simple Spotlight when you log in.")

        /// Every key, in the order the default file lists them.
        static let all: [any AnyKey] = [
            hotkey, searchApplications, searchSystemSettings, calculator, appFolders,
            excludedApps, maxResults, launchAtLogin,
        ]
    }

    /// A key of the config file whatever its type, as `ConfigFile` reads and writes it.
    protocol AnyKey: Sendable {
        var name: String { get }
        /// The lines of the comment above the key in the default file: what it does, and what
        /// it takes.
        var comment: [String] { get }
        /// The default as JSON text, a nested line indented for a key of the top-level object.
        var defaultText: String { get }
        /// Sets the key in `settings` to `json`, a value `JSONSerialization` read, or returns
        /// why it can't take it, naming the key.
        func read(_ json: Any, into settings: inout Settings) -> String?
    }

    /// One key of the config file.
    struct Key<Value: Sendable>: AnyKey {
        let path: WritableKeyPath<Settings, Value> & Sendable
        let name: String
        let kind: Kind<Value>
        let defaultValue: Value
        /// What the key does, in one sentence.
        let summary: String

        init(
            _ path: WritableKeyPath<Settings, Value> & Sendable, _ name: String,
            _ kind: Kind<Value>, default: Value, _ summary: String
        ) {
            self.path = path
            self.name = name
            self.kind = kind
            defaultValue = `default`
            self.summary = summary
        }

        var comment: [String] { [summary, "Takes \(kind.takes)."] }

        var defaultText: String { kind.text(defaultValue) }

        func read(_ json: Any, into settings: inout Settings) -> String? {
            switch kind.read(json) {
            case .success(let value):
                settings[keyPath: path] = value
                return nil
            case .failure(let refusal):
                let reason = "\(name) must be \(kind.takes), not \(ConfigFile.json(json))"
                return refusal.detail.map { "\(reason): \($0)" } ?? reason
            }
        }
    }

    /// Why a value doesn't fit a key, when there is more to say than what the key takes.
    struct Refusal: Error {
        let detail: String?
    }

    /// A type of value a key takes: what it is in words, how it is read from what
    /// `JSONSerialization` gives, and how it is written.
    struct Kind<Value: Sendable>: Sendable {
        /// "true or false": the end of the key's comment and the words of its error.
        let takes: String
        let read: @Sendable (Any) -> Result<Value, Refusal>
        let text: @Sendable (Value) -> String
    }
}

extension Settings.Kind<Bool> {
    static var bool: Self {
        Self(
            takes: "true or false",
            read: { json in
                guard let number = json as? NSNumber, isBoolean(number) else {
                    return .failure(Settings.Refusal(detail: nil))
                }
                return .success(number.boolValue)
            },
            text: { $0 ? "true" : "false" })
    }
}

extension Settings.Kind<Int> {
    static func integer(_ range: ClosedRange<Int>) -> Self {
        Self(
            takes: "a whole number from \(range.lowerBound) to \(range.upperBound)",
            read: { json in
                guard let number = json as? NSNumber, !isBoolean(number),
                    let value = Int(exactly: number.doubleValue), range.contains(value)
                else { return .failure(Settings.Refusal(detail: nil)) }
                return .success(value)
            },
            text: { String($0) })
    }
}

extension Settings.Kind<KeyChord> {
    static var chord: Self {
        Self(
            takes: "a shortcut such as \"cmd+space\" or \"ctrl+opt+k\"",
            read: { json in
                guard let text = json as? String else {
                    return .failure(Settings.Refusal(detail: nil))
                }
                do throws(KeyChord.ParseError) {
                    return .success(try KeyChord(parsing: text))
                } catch {
                    return .failure(Settings.Refusal(detail: error.reason))
                }
            },
            text: { ConfigFile.json($0.text) })
    }
}

extension Settings.Kind<[String]> {
    static var folders: Self {
        strings(takes: "a list of folders, each a full path or one that starts with ~/") {
            HomePath.isValid($0) ? nil : "\(ConfigFile.json($0)) isn't a full path"
        }
    }

    static var identifiers: Self {
        strings(takes: "a list of bundle IDs, such as [\"com.apple.Chess\"]") {
            $0.isEmpty ? "a bundle ID is empty" : nil
        }
    }

    /// A list of strings, each one `problem` finds nothing wrong with, written a string to a
    /// line.
    private static func strings(
        takes: String, problem: @escaping @Sendable (String) -> String?
    ) -> Self {
        Self(
            takes: takes,
            read: { json in
                guard let strings = json as? [String] else {
                    return .failure(Settings.Refusal(detail: nil))
                }
                if let found = strings.lazy.compactMap(problem).first {
                    return .failure(Settings.Refusal(detail: found))
                }
                return .success(strings)
            },
            text: { strings in
                guard !strings.isEmpty else { return "[]" }
                let items = strings.map { "    \(ConfigFile.json($0))" }
                return "[\n\(items.joined(separator: ",\n"))\n  ]"
            })
    }
}

/// Whether `number` is a Boolean. JSON's `true` reads as an NSNumber, as numbers do; only
/// CFBoolean is one.
private func isBoolean(_ number: NSNumber) -> Bool {
    CFGetTypeID(number) == CFBooleanGetTypeID()
}
