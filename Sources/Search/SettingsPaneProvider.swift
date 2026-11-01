import Foundation

/// Finds the System Settings panes that can be opened directly, and third-party `.prefPane`
/// bundles, and turns each into a row. On macOS 12 the system's panes are System Preferences'
/// `.prefPane` bundles instead (docs/decisions/0016-macos-12-branch.md).
public struct SettingsPaneProvider: Sendable {
    /// Whether this macOS has System Settings, made of extensions, rather than macOS 12's System
    /// Preferences, made of `.prefPane` bundles.
    public static var hasSystemSettings: Bool {
        if #available(macOS 13, *) { true } else { false }
    }
    /// The subtitle of every pane's row: the settings app's name.
    public static let subtitle = hasSystemSettings ? "System Settings" : "System Preferences"
    /// The ExtensionKit extension point of a System Settings pane.
    public static let extensionPoint = "com.apple.Settings.extension.ui"
    /// The System Settings app, or System Preferences on macOS 12, which holds some panes and
    /// whose icon every pane's row shows.
    public static let systemSettingsApp = URL(
        fileURLWithPath: hasSystemSettings
            ? "/System/Applications/System Settings.app"
            : "/System/Applications/System Preferences.app",
        isDirectory: true)
    /// Where macOS keeps its panes. Most are in ExtensionKit's folder; General is inside the app.
    /// None on macOS 12.
    public static let systemExtensionFolders =
        hasSystemSettings
        ? [
            URL(fileURLWithPath: "/System/Library/ExtensionKit/Extensions", isDirectory: true),
            systemSettingsApp.appendingPathComponent("Contents/PlugIns", isDirectory: true),
        ] : []
    /// Where macOS 12 keeps System Preferences' panes. None on later versions.
    public static let systemPreferencePaneFolders =
        hasSystemSettings
        ? [] : [URL(fileURLWithPath: "/System/Library/PreferencePanes", isDirectory: true)]
    /// Where third-party `.prefPane` bundles are installed, for everyone and for the user whose
    /// home folder is `home`.
    public static func standardPreferencePaneFolders(
        home: URL = HomePath.current
    ) -> [URL] {
        ["/Library/PreferencePanes", "~/Library/PreferencePanes"].map {
            HomePath.folder($0, home: home)
        }
    }

    /// The URL that opens the pane whose bundle ID is `id` in System Settings, at the section
    /// `anchor` names when there is one; nil when `id` can't be part of a URL.
    public static func paneURL(_ id: String, anchor: String? = nil) -> URL? {
        URL(string: "x-apple.systempreferences:\(id)" + (anchor.map { "?\($0)" } ?? ""))
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
    /// Scanned in order for the `.prefPane` bundles of System Preferences, named as its window
    /// labels them. A missing one is a problem.
    public let systemPreferencePaneFolders: [URL]
    /// Scanned in order for `.prefPane` bundles. A missing one has none.
    public let preferencePaneFolders: [URL]
    /// Picks the localization each pane's name is read in, as `Locale.preferredLanguages` does.
    public let languages: [String]

    public init(
        extensionFolders: [URL] = systemExtensionFolders,
        systemPreferencePaneFolders: [URL] = systemPreferencePaneFolders,
        preferencePaneFolders: [URL] = standardPreferencePaneFolders(),
        languages: [String] = Locale.preferredLanguages
    ) {
        self.extensionFolders = extensionFolders
        self.systemPreferencePaneFolders = systemPreferencePaneFolders
        self.preferencePaneFolders = preferencePaneFolders
        self.languages = languages
    }

    /// The panes, then System Preferences' `.prefPane` bundles, then the others, each in folder
    /// order; a `.prefPane` whose bundle ID was already found is left out. A folder that can't be listed or a bundle that can't be
    /// read is left out and reported as a problem. Throws when cancelled.
    ///
    /// It blocks on the disk; callers go through `IndexBuilder.build()`, which runs it off the
    /// caller's actor.
    func items() throws(CancellationError) -> (items: [SearchItem], problems: [IndexProblem]) {
        var problems: [IndexProblem] = []
        var items: [SearchItem] = []
        for folder in extensionFolders {
            for url in Self.bundles(in: folder, withExtension: "appex", problems: &problems) {
                if Task.isCancelled { throw CancellationError() }
                do {
                    if let item = try pane(at: url) { items.append(item) }
                } catch {
                    problems.append(IndexProblem(url, error))
                }
            }
        }
        var seen: Set<String> = []
        for folder in systemPreferencePaneFolders {
            for url in Self.bundles(in: folder, withExtension: "prefPane", problems: &problems) {
                if Task.isCancelled { throw CancellationError() }
                do {
                    let item = try systemPreferencePane(at: url)
                    if seen.insert(item.id).inserted { items.append(item) }
                } catch {
                    problems.append(IndexProblem(url, error))
                }
            }
        }
        for folder in preferencePaneFolders
        where FileManager.default.fileExists(atPath: folder.path) {
            for url in Self.bundles(in: folder, withExtension: "prefPane", problems: &problems) {
                if Task.isCancelled { throw CancellationError() }
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
        guard let id = info.identifier, let target = Self.paneURL(id) else {
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

    /// The row for System Preferences' pane at `url`, named by its icon label, which is what
    /// System Preferences shows: the bundles' own names are often internal ("Appearance" for
    /// General, "DesktopScreenEffectsPref"). A label may hold a line break, for the icon grid;
    /// the row shows it on one line.
    private func systemPreferencePane(at url: URL) throws -> SearchItem {
        let info = try BundleInfo(bundle: url)
        let id = info.identifier ?? url.path
        let oneLine = { (label: String) in
            label.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        let labels = try info.localizedStrings("NSPrefPaneIconLabel", for: languages)
        guard let preferred = labels.preferred.map(oneLine) else {
            return SearchItem(
                id: id, kind: .settingsPane, title: try info.displayName(for: languages),
                subtitle: Self.subtitle, target: .openFile(url))
        }
        let regional = labels.regional.map(oneLine)
        return SearchItem(
            id: id, kind: .settingsPane, title: preferred, subtitle: Self.subtitle,
            target: .openFile(url),
            alternateNames: regional.flatMap { $0 == preferred ? nil : [$0] } ?? [])
    }

    /// The bundles in `folder` with the path extension `pathExtension`, sorted by name. A folder
    /// that can't be listed is added to `problems`.
    private static func bundles(
        in folder: URL, withExtension pathExtension: String, problems: inout [IndexProblem]
    ) -> [URL] {
        do {
            return try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
                .filter { !$0.hasPrefix(".") }
                .map { folder.appendingPathComponent($0, isDirectory: true) }
                .filter { $0.pathExtension == pathExtension }
        } catch {
            problems.append(IndexProblem(folder, error))
            return []
        }
    }
}
