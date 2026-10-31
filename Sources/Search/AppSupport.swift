import Foundation

/// Where the app keeps the files it writes for itself, as opposed to the config file the user
/// writes: the state file and the usage file.
public enum AppSupport {
    /// The app's folder in Application Support for the user whose home folder is `home`.
    public static func standardFolder(home: URL = HomePath.current) -> URL {
        HomePath.folder("~/Library/Application Support/\(AppSlug.value)", home: home)
    }
}
