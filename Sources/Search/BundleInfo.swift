import Foundation

/// A bundle's `Info.plist` values overlaid with the localization the given languages pick, read
/// from the files directly.
///
/// `Bundle` isn't used: `Bundle(url:)` keeps one instance per path for the life of the process,
/// so a rebuild after an app updates would read the values it cached the first time.
struct BundleInfo {
    /// A file that exists but isn't a property list dictionary.
    struct ReadError: Error, CustomStringConvertible {
        let file: URL
        let reason: String

        var description: String { "\(file.path): \(reason)" }
    }

    /// The bundle's file name without its extension.
    let fileName: String
    /// The values in `Info.plist` as written, in the development region's language.
    private let base: [String: Any]
    /// `base` with the chosen localization's values on top.
    private let localized: [String: Any]

    /// Reads the bundle at `url`. A bundle with no `Info.plist` has no values.
    init(bundle url: URL, languages: [String]) throws {
        fileName = url.deletingPathExtension().lastPathComponent
        let contents = url.appending(path: "Contents", directoryHint: .isDirectory)
        base = try Self.propertyList(at: contents.appending(path: "Info.plist")) ?? [:]
        let region = base["CFBundleDevelopmentRegion"] as? String ?? "en"
        let strings = try Self.localizedStrings(
            in: contents.appending(path: "Resources", directoryHint: .isDirectory),
            region: region, languages: languages)
        localized = base.merging(strings) { $1 }
    }

    /// The localized value of `key`, or nil when it is missing, empty or not a string.
    func string(_ key: String) -> String? {
        Self.string(key, in: localized)
    }

    /// The value of `key` in `Info.plist` when it is a dictionary.
    func dictionary(_ key: String) -> [String: Any]? {
        base[key] as? [String: Any]
    }

    /// The value of `key` as a flag: a boolean, or a string such as "1" or "YES", as Launch
    /// Services reads `LSUIElement`.
    func flag(_ key: String) -> Bool {
        switch base[key] {
        case let value as Bool: value
        case let value as String: NSString(string: value).boolValue
        default: false
        }
    }

    /// The name Finder shows: the localized display name, then the localized bundle name, unless
    /// the file was renamed away from the names in `Info.plist`, in which case the file name.
    var displayName: String {
        let written = ["CFBundleDisplayName", "CFBundleName"].compactMap {
            Self.string($0, in: base)
        }
        guard written.isEmpty || written.contains(fileName) else { return fileName }
        return string("CFBundleDisplayName") ?? string("CFBundleName") ?? fileName
    }

    /// The value of `key` in `values`, preferring its macOS form: Apple's bundles carry keys
    /// such as `CFBundleDisplayName-macos` ("Image Playground") beside the plain key
    /// ("Playground", for iOS), as `Bundle` reads them.
    private static func string(_ key: String, in values: [String: Any]) -> String? {
        for key in [key + "-macos", key] {
            if let value = values[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    /// The `InfoPlist` values of the localization `languages` prefer, from `InfoPlist.loctable`
    /// when the bundle has one, as Apple's do, or else from `<language>.lproj/InfoPlist.strings`.
    /// The development region is always a candidate; when it wins and has no table of its own,
    /// `Info.plist` already holds its values.
    private static func localizedStrings(
        in resources: URL, region: String, languages: [String]
    ) throws -> [String: Any] {
        let available: Set<String>
        let read: (String) throws -> [String: Any]?
        if let loctable = try propertyList(at: resources.appending(path: "InfoPlist.loctable")) {
            // The table also holds "LocProvenance", which says where each language came from.
            available = Set(loctable.keys).subtracting(["LocProvenance"])
            read = { loctable[$0] as? [String: Any] }
        } else {
            guard FileManager.default.fileExists(atPath: resources.path) else { return [:] }
            let names = try FileManager.default.contentsOfDirectory(atPath: resources.path)
            let suffix = ".lproj"
            available = Set(
                names.filter { $0.hasSuffix(suffix) }.map { String($0.dropLast(suffix.count)) })
            read = { language in
                try propertyList(
                    at: resources.appending(path: "\(language)\(suffix)/InfoPlist.strings"))
            }
        }
        // Some bundles name the region "English"; it stands for "en" when that's in the table.
        let canonical = Locale.canonicalLanguageIdentifier(from:)
        var candidates = available
        if !available.contains(where: { canonical($0) == canonical(region) }) {
            candidates.insert(region)
        }
        guard
            let language = Bundle.preferredLocalizations(
                from: candidates.sorted(), forPreferences: languages
            ).first
        else { return [:] }
        return try read(language) ?? [:]
    }

    /// The dictionary in the property list at `url`, or nil when there is no file there.
    private static func propertyList(at url: URL) throws -> [String: Any]? {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        }
        let value: Any
        do {
            value = try PropertyListSerialization.propertyList(from: data, format: nil)
        } catch {
            throw ReadError(file: url, reason: "\(error)")
        }
        guard let dictionary = value as? [String: Any] else {
            throw ReadError(file: url, reason: "not a dictionary")
        }
        return dictionary
    }
}
