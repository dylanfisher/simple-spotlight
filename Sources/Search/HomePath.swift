import Foundation

/// Folder paths that may be written relative to the user's home folder, as `~/Applications`.
enum HomePath {
    /// Whether `path` names a folder `folder(_:home:)` can place: absolute, `~`, or starting
    /// with `~/`. `~user` and relative paths aren't.
    static func isValid(_ path: String) -> Bool {
        path.hasPrefix("/") || path == "~" || path.hasPrefix("~/")
    }

    /// The folder `path` names, a leading `~` standing for `home`.
    static func folder(_ path: String, home: URL) -> URL {
        guard path == "~" || path.hasPrefix("~/") else {
            return URL(filePath: path, directoryHint: .isDirectory)
        }
        let rest = path.dropFirst(2)
        return rest.isEmpty ? home : home.appending(path: rest, directoryHint: .isDirectory)
    }
}
