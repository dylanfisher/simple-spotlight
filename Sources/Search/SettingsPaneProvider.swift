import Foundation

/// Finds the System Settings panes that can be opened directly, and third-party `.prefPane`
/// bundles, and turns each into a row.
public struct SettingsPaneProvider: Sendable {
    /// The subtitle of every pane's row.
    public static let subtitle = "System Settings"
    /// The ExtensionKit extension point of a System Settings pane.
    public static let extensionPoint = "com.apple.Settings.extension.ui"
    /// Where macOS keeps its panes. Most are in ExtensionKit's folder; General is inside the app.
    public static let systemExtensionFolders = [
        URL(filePath: "/System/Library/ExtensionKit/Extensions", directoryHint: .isDirectory),
        URL(
            filePath: "/System/Applications/System Settings.app/Contents/PlugIns",
            directoryHint: .isDirectory),
    ]
    /// Where third-party `.prefPane` bundles are installed, for everyone and for this user.
    public static var standardPreferencePaneFolders: [URL] {
        [
            URL(filePath: "/Library/PreferencePanes", directoryHint: .isDirectory),
            FileManager.default.homeDirectoryForCurrentUser.appending(
                path: "Library/PreferencePanes", directoryHint: .isDirectory),
        ]
    }

    /// Names for panes whose bundles hold only an internal one in every language. System Settings
    /// gets these from the running extension: Battery's says "Battery" or "Energy" by hardware,
    /// and Headphones' shows the connected headphones' name. See
    /// docs/decisions/0004-settings-pane-names.md.
    static let names = [
        "com.apple.Battery-Settings.extension": "Battery",
        "com.apple.HeadphoneSettings": "Headphones",
    ]

    /// Scanned in order for `.appex` bundles. Each must exist.
    public let extensionFolders: [URL]
    /// Scanned in order for `.prefPane` bundles. A missing one has none.
    public let preferencePaneFolders: [URL]
    /// Picks the localization each pane's name is read in, as `Locale.preferredLanguages` does.
    public let languages: [String]

    public init(
        extensionFolders: [URL] = systemExtensionFolders,
        preferencePaneFolders: [URL] = standardPreferencePaneFolders,
        languages: [String] = Locale.preferredLanguages
    ) {
        self.extensionFolders = extensionFolders
        self.preferencePaneFolders = preferencePaneFolders
        self.languages = languages
    }

    /// The panes, then the `.prefPane` bundles, each in folder order. Throws when an extension
    /// folder can't be listed or a bundle's `Info.plist` can't be read.
    public func items() throws -> [SearchItem] {
        var items: [SearchItem] = []
        for folder in extensionFolders {
            for url in try Self.bundles(in: folder, withExtension: "appex") {
                if let item = try pane(at: url) { items.append(item) }
            }
        }
        for folder in preferencePaneFolders
        where FileManager.default.fileExists(atPath: folder.path) {
            for url in try Self.bundles(in: folder, withExtension: "prefPane") {
                let info = try BundleInfo(bundle: url, languages: languages)
                items.append(
                    SearchItem(
                        id: info.string("CFBundleIdentifier") ?? url.path, kind: .settingsPane,
                        title: info.displayName, subtitle: Self.subtitle, target: .openFile(url)))
            }
        }
        return items
    }

    /// The row for the extension at `url`, or nil when it isn't a pane that
    /// `x-apple.systempreferences:` can open.
    private func pane(at url: URL) throws -> SearchItem? {
        let info = try BundleInfo(bundle: url, languages: languages)
        let attributes = info.dictionary("EXAppExtensionAttributes")
        let settings = attributes?["SettingsExtensionAttributes"] as? [String: Any]
        guard attributes?["EXExtensionPointIdentifier"] as? String == Self.extensionPoint,
            settings?["allowsXAppleSystemPreferencesURLScheme"] as? Bool == true
        else { return nil }
        guard let id = info.string("CFBundleIdentifier"),
            let target = URL(string: "x-apple.systempreferences:\(id)")
        else {
            throw BundleInfo.ReadError(file: url, reason: "no bundle ID to open the pane by")
        }
        // An appex's file and bundle names are internal ("DisplaysExt"), so the Finder rule in
        // `BundleInfo.displayName` doesn't apply.
        let title =
            Self.names[id] ?? info.string("CFBundleDisplayName") ?? info.string("CFBundleName")
            ?? info.fileName
        return SearchItem(
            id: id, kind: .settingsPane, title: title, subtitle: Self.subtitle,
            target: .openURL(target))
    }

    /// The bundles in `folder` with the path extension `pathExtension`, sorted by name.
    private static func bundles(in folder: URL, withExtension pathExtension: String) throws -> [URL]
    {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
            .filter { !$0.hasPrefix(".") }
            .map { folder.appending(path: $0, directoryHint: .isDirectory) }
            .filter { $0.pathExtension == pathExtension }
    }
}
