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

    /// Names for panes whose bundles hold only an internal name in every language. See
    /// docs/decisions/0004-settings-pane-names.md.
    static let names = [
        "com.apple.Battery-Settings.extension": "Battery",
        "com.apple.HeadphoneSettings": "Headphones",
    ]
    /// Panes System Settings hides on Macs that aren't managed by a school. See
    /// docs/decisions/0004-settings-pane-names.md.
    static let hidden: Set = [
        "com.apple.ClassKit-Settings.extension",
        "com.apple.Classroom-Settings.extension",
    ]

    /// Scanned in order for `.appex` bundles. A missing one is a problem.
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

    /// The panes, then the `.prefPane` bundles, each in folder order; a `.prefPane` whose bundle
    /// ID was already found is left out. A folder that can't be listed or a bundle that can't be
    /// read is left out and reported as a problem. Throws only `CancellationError`.
    ///
    /// It blocks on the disk; callers go through `IndexBuilder.build()`, which runs it off the
    /// caller's actor.
    func items() throws -> (items: [SearchItem], problems: [IndexProblem]) {
        var problems: [IndexProblem] = []
        var items: [SearchItem] = []
        for folder in extensionFolders {
            for url in Self.bundles(in: folder, withExtension: "appex", problems: &problems) {
                try Task.checkCancellation()
                do {
                    if let item = try pane(at: url) { items.append(item) }
                } catch {
                    problems.append(IndexProblem(url, error))
                }
            }
        }
        var seen: Set<String> = []
        for folder in preferencePaneFolders
        where FileManager.default.fileExists(atPath: folder.path) {
            for url in Self.bundles(in: folder, withExtension: "prefPane", problems: &problems) {
                try Task.checkCancellation()
                do {
                    let info = try BundleInfo(bundle: url)
                    let id = info.identifier ?? url.path
                    guard seen.insert(id).inserted else { continue }
                    items.append(
                        SearchItem(
                            id: id, kind: .settingsPane,
                            title: try info.displayName(for: languages), subtitle: Self.subtitle,
                            target: .openFile(url)))
                } catch {
                    problems.append(IndexProblem(url, error))
                }
            }
        }
        return (items, problems)
    }

    /// The row for the extension at `url`, or nil when it isn't a pane that
    /// `x-apple.systempreferences:` can open or is one System Settings hides. Its strings are read
    /// only once `Info.plist` says it is a pane.
    private func pane(at url: URL) throws -> SearchItem? {
        let info = try BundleInfo(bundle: url)
        let attributes = info.dictionary("EXAppExtensionAttributes")
        let settings = attributes?["SettingsExtensionAttributes"] as? [String: Any]
        guard attributes?["EXExtensionPointIdentifier"] as? String == Self.extensionPoint,
            settings?["allowsXAppleSystemPreferencesURLScheme"] as? Bool == true
        else { return nil }
        guard let id = info.identifier, let target = URL(string: "x-apple.systempreferences:\(id)")
        else {
            throw IndexProblem(path: url.path, reason: "It has no bundle ID to open it by.")
        }
        guard !Self.hidden.contains(id) else { return nil }
        // An appex's file and bundle names are internal ("DisplaysExt"), so the Finder rule in
        // `BundleInfo.displayName` doesn't apply.
        if let title = Self.names[id] {
            return SearchItem(
                id: id, kind: .settingsPane, title: title, subtitle: Self.subtitle,
                target: .openURL(target))
        }
        let names = try info.localizedNames(for: languages)
        let title = names.preferred ?? info.fileName
        // The development region's name is an alternate, so "Menu Bar" still finds "Menüleiste".
        let regional = names.regional
        return SearchItem(
            id: id, kind: .settingsPane, title: title, subtitle: Self.subtitle,
            target: .openURL(target),
            alternateNames: regional.flatMap { $0 == title ? nil : [$0] } ?? [])
    }

    /// The bundles in `folder` with the path extension `pathExtension`, sorted by name. A folder
    /// that can't be listed is added to `problems`.
    private static func bundles(
        in folder: URL, withExtension pathExtension: String, problems: inout [IndexProblem]
    ) -> [URL] {
        do {
            return try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
                .filter { !$0.hasPrefix(".") }
                .map { folder.appending(path: $0, directoryHint: .isDirectory) }
                .filter { $0.pathExtension == pathExtension }
        } catch {
            problems.append(IndexProblem(folder, error))
            return []
        }
    }
}
