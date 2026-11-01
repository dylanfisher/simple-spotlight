import Foundation

/// Finds the apps in a list of folders and turns each into a row.
public struct AppProvider: Sendable {
    /// Finder isn't in any app folder, but people launch it by name. See
    /// docs/decisions/0005-reading-bundle-info.md.
    public static let finder = URL(
        fileURLWithPath: "/System/Library/CoreServices/Finder.app", isDirectory: true)

    /// The one app folder that may be missing without it being a problem, as most people don't
    /// have one.
    public static let userApplications = "~/Applications"

    /// The folders macOS and installers put apps in, as the config file writes them: the
    /// default `appFolders`. An app in one of them, in its `Utilities` folder, or Finder, shows
    /// no path, since the path would say nothing.
    public static let standardFolders = [
        "/Applications", "/System/Applications", "/System/Library/CoreServices/Applications",
        userApplications,
    ]

    /// Scanned in order, each to a depth of two, so `/Applications/Utilities/*.app` is found.
    public let folders: [URL]
    /// Picks the localization each app's name is read in, as `Locale.preferredLanguages` does.
    public let languages: [String]
    /// Apps under this folder that run without a Dock icon (`LSUIElement`, `LSBackgroundOnly`)
    /// are left out. They are system agents there; elsewhere, such as menu bar apps in
    /// `/Applications`, people do launch them.
    public let coreServices: URL
    /// Apps indexed after the folders' when they exist.
    public let extraApps: [URL]
    /// The user's home folder, where `userApplications` is.
    public let home: URL
    /// The paths of the folders whose apps show no path: `standardFolders`, their `Utilities`
    /// folders, and Finder's folder.
    private let pathlessFolders: Set<String>

    public init(
        folders: [URL], languages: [String] = Locale.preferredLanguages,
        coreServices: URL = URL(
            fileURLWithPath: "/System/Library/CoreServices", isDirectory: true),
        extraApps: [URL] = [finder],
        home: URL = HomePath.current
    ) {
        self.folders = folders
        self.languages = languages
        self.coreServices = coreServices
        self.extraApps = extraApps
        self.home = home
        let standard = Self.standardFolders.map { HomePath.folder($0, home: home) }
        pathlessFolders = Set(
            (standard + standard.map { $0.appendingPathComponent("Utilities") }
                + [Self.finder.deletingLastPathComponent()])
                .map(\.standardizedFileURL.path))
    }

    /// One row per app, in folder order, then the extra apps. When two apps share a bundle ID,
    /// the one found first wins. A folder that can't be listed or an app that can't be read is
    /// left out and reported as a problem. Throws when cancelled.
    ///
    /// It blocks on the disk; callers go through `IndexBuilder.build()`, which runs it off the
    /// caller's actor.
    func items() throws(CancellationError) -> (items: [SearchItem], problems: [IndexProblem]) {
        var problems: [IndexProblem] = []
        var urls: [URL] = []
        let userApplications = HomePath.folder(Self.userApplications, home: home)
            .standardizedFileURL.path
        for folder in folders {
            if folder.standardizedFileURL.path == userApplications,
                !FileManager.default.fileExists(atPath: folder.path)
            {
                continue
            }
            urls += Self.apps(in: folder, depth: 2, problems: &problems)
        }
        urls += extraApps.filter { FileManager.default.fileExists(atPath: $0.path) }
        var seen: Set<String> = []
        var items: [SearchItem] = []
        for url in urls {
            if Task.isCancelled { throw CancellationError() }
            do {
                guard let item = try item(for: url), seen.insert(item.id).inserted else { continue }
                items.append(item)
            } catch {
                problems.append(IndexProblem(url, error))
            }
        }
        return (items, problems)
    }

    private func item(for url: URL) throws -> SearchItem? {
        let info = try BundleInfo(bundle: url)
        let agent = info.flag("LSUIElement") || info.flag("LSBackgroundOnly")
        if agent,
            url.standardizedFileURL.path.hasPrefix(coreServices.standardizedFileURL.path + "/")
        {
            return nil
        }
        let title = try info.displayName(for: languages)
        let folder = url.deletingLastPathComponent()
        let shownFolder = pathlessFolders.contains(folder.standardizedFileURL.path) ? nil : folder
        return SearchItem(
            id: info.identifier ?? url.path, kind: .app, title: title,
            subtitle: shownFolder?.path, target: .openFile(url),
            alternateNames: info.fileName == title ? [] : [info.fileName])
    }

    /// The `.app` bundles in `folder` and, while `depth` allows, in its subfolders, sorted by
    /// name. Never looks inside an app. `/Applications/Safari.app` is a symbolic link with the
    /// hidden flag set, so links are followed and only dot files are skipped. A folder that
    /// can't be listed is added to `problems`.
    private static func apps(in folder: URL, depth: Int, problems: inout [IndexProblem]) -> [URL] {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        } catch {
            problems.append(IndexProblem(folder, error))
            return []
        }
        var apps: [URL] = []
        for name in names.sorted() where !name.hasPrefix(".") {
            let entry = folder.appendingPathComponent(name, isDirectory: true)
            if entry.pathExtension.lowercased() == "app" {
                apps.append(entry)
                continue
            }
            var isDirectory: ObjCBool = false
            guard depth > 1,
                FileManager.default.fileExists(atPath: entry.path, isDirectory: &isDirectory),
                isDirectory.boolValue
            else { continue }
            apps += Self.apps(in: entry, depth: depth - 1, problems: &problems)
        }
        return apps
    }
}
