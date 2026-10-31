import Foundation

/// Finds the apps in a list of folders and turns each into a row.
public struct AppProvider: Sendable {
    /// Scanned in order, each to a depth of two, so `/Applications/Utilities/*.app` is found.
    public let folders: [URL]
    /// Picks the localization each app's name is read in, as `Locale.preferredLanguages` does.
    public let languages: [String]
    /// Apps under this folder that run without a Dock icon (`LSUIElement`, `LSBackgroundOnly`)
    /// are left out. They are system agents there; elsewhere, such as menu bar apps in
    /// `/Applications`, people do launch them.
    public let coreServices: URL

    public init(
        folders: [URL], languages: [String] = Locale.preferredLanguages,
        coreServices: URL = URL(
            filePath: "/System/Library/CoreServices", directoryHint: .isDirectory)
    ) {
        self.folders = folders
        self.languages = languages
        self.coreServices = coreServices
    }

    /// One row per app, in folder order. When two apps share a bundle ID, the one found first
    /// wins. Throws when a folder can't be listed or an app's `Info.plist` can't be read.
    public func items() throws -> [SearchItem] {
        var seen: Set<String> = []
        var items: [SearchItem] = []
        for folder in folders {
            for url in try Self.apps(in: folder, depth: 2) {
                guard let item = try item(for: url), seen.insert(item.id).inserted else { continue }
                items.append(item)
            }
        }
        return items
    }

    private func item(for url: URL) throws -> SearchItem? {
        let info = try BundleInfo(bundle: url, languages: languages)
        let agent = info.flag("LSUIElement") || info.flag("LSBackgroundOnly")
        if agent,
            url.standardizedFileURL.path.hasPrefix(coreServices.standardizedFileURL.path + "/")
        {
            return nil
        }
        return SearchItem(
            id: info.string("CFBundleIdentifier") ?? url.path, kind: .app, title: info.displayName,
            subtitle: url.deletingLastPathComponent().path, target: .openFile(url))
    }

    /// The `.app` bundles in `folder` and, while `depth` allows, in its subfolders, sorted by
    /// name. Never looks inside an app. `/Applications/Safari.app` is a symbolic link with the
    /// hidden flag set, so links are followed and only dot files are skipped.
    private static func apps(in folder: URL, depth: Int) throws -> [URL] {
        var apps: [URL] = []
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        where !name.hasPrefix(".") {
            let entry = folder.appending(path: name, directoryHint: .isDirectory)
            if entry.pathExtension.lowercased() == "app" {
                apps.append(entry)
                continue
            }
            var isDirectory: ObjCBool = false
            guard depth > 1,
                FileManager.default.fileExists(atPath: entry.path, isDirectory: &isDirectory),
                isDirectory.boolValue
            else { continue }
            apps += try Self.apps(in: entry, depth: depth - 1)
        }
        return apps
    }
}
