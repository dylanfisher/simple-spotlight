import Foundation

/// Folder paths that may be written relative to the user's home folder, as `~/Applications`.
public enum HomePath {
    /// This user's home folder: the default wherever a home folder can be passed in.
    public static var current: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// What `isValid` accepts, in words, for the config file's comments and errors.
    static let accepted = "a full path, ~, or a path that starts with ~/"

    /// Whether `path` names a folder `folder(_:home:)` can place: `accepted`. `~user` and
    /// relative paths aren't.
    static func isValid(_ path: String) -> Bool {
        path.hasPrefix("/") || underHome(path) != nil
    }

    /// The folder `path` names, a leading `~` standing for `home`.
    static func folder(_ path: String, home: URL) -> URL {
        guard let rest = underHome(path) else {
            return URL(filePath: path, directoryHint: .isDirectory)
        }
        return rest.isEmpty ? home : home.appending(path: rest, directoryHint: .isDirectory)
    }

    /// The part of `path` after `~` or `~/`, when it starts with one of them.
    private static func underHome(_ path: String) -> Substring? {
        guard path == "~" || path.hasPrefix("~/") else { return nil }
        return path.dropFirst(2)
    }
}
