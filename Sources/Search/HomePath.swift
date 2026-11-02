import Foundation

/// Folder paths that may be written relative to the user's home folder, as `~/Applications`.
public enum HomePath {
    /// This user's home folder: the default wherever a home folder can be passed in.
    public static var current: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// The folder the config file lives in.
    static let config = "~/.config/\(AppSlug.value)"
    /// The folder of the user's script commands, beside the config file.
    static let scriptCommands = "\(config)/commands"

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

    /// `folder` as the config file writes it: `~/…` inside `home`, `~` for `home` itself, and
    /// the full path anywhere else.
    public static func written(_ folder: URL, home: URL = current) -> String {
        let path = folder.standardizedFileURL.path(percentEncoded: false)
        let homePath = home.standardizedFileURL.path(percentEncoded: false)
        let base = homePath.hasSuffix("/") ? String(homePath.dropLast()) : homePath
        let trimmed = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        if trimmed == base { return "~" }
        guard trimmed.hasPrefix(base + "/") else { return trimmed }
        return "~" + trimmed.dropFirst(base.count)
    }

    /// The part of `path` after `~` or `~/`, when it starts with one of them.
    private static func underHome(_ path: String) -> Substring? {
        guard path == "~" || path.hasPrefix("~/") else { return nil }
        return path.dropFirst(2)
    }
}
