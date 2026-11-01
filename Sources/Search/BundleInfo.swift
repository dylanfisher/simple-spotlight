import Foundation

/// A bundle's `Info.plist`, read from the file directly, and its localized values on request.
///
/// `Bundle` isn't used: `Bundle(url:)` keeps one instance per path for the life of the process,
/// so a rebuild after an app updates would read the values it cached the first time.
struct BundleInfo {
    /// The bundle's file name without its extension.
    let fileName: String
    private let contents: URL
    /// The values in `Info.plist` as written, in the development region's language.
    private let base: [String: Any]

    /// Reads the `Info.plist` of the bundle at `url`. A bundle with none has no values; one that
    /// doesn't parse throws an `IndexProblem`.
    init(bundle url: URL) throws {
        fileName = url.deletingPathExtension().lastPathComponent
        contents = url.appendingPathComponent("Contents", isDirectory: true)
        base = try Self.propertyList(at: contents.appendingPathComponent("Info.plist")) ?? [:]
    }

    var identifier: String? { Self.string("CFBundleIdentifier", in: base) }

    /// The language `Info.plist`'s own values are in.
    private var developmentRegion: String { base["CFBundleDevelopmentRegion"] as? String ?? "en" }

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

    /// The name the localization `languages` pick gives: its display name, then its bundle name.
    /// Reads the bundle's strings, so callers that may skip the bundle check `Info.plist` first.
    func localizedName(for languages: [String]) throws -> String? {
        let strings = try strings()
        let language = Self.language(
            for: languages, in: strings?.available ?? [], region: region(in: strings))
        return Self.name(in: try values(in: language, from: strings))
    }

    /// `localizedName(for:)`, and the name the development region's localization gives, reading
    /// the strings once.
    func localizedNames(for languages: [String]) throws -> (preferred: String?, regional: String?) {
        try localized(for: languages, Self.name(in:))
    }

    /// The value of `key` in the localization `languages` pick and in the development region's,
    /// as `localizedNames(for:)` reads names.
    func localizedStrings(_ key: String, for languages: [String]) throws -> (
        preferred: String?, regional: String?
    ) {
        try localized(for: languages) { Self.string(key, in: $0).map(Self.visible) }
    }

    /// What `pick` finds in the values of the localization `languages` pick and of the
    /// development region's, reading the strings once.
    private func localized(
        for languages: [String], _ pick: ([String: Any]) -> String?
    ) throws -> (preferred: String?, regional: String?) {
        let strings = try strings()
        let region = region(in: strings)
        let language = Self.language(for: languages, in: strings?.available ?? [], region: region)
        let preferred = pick(try values(in: language, from: strings))
        guard language != region else { return (preferred, preferred) }
        return (preferred, pick(try values(in: region, from: strings)))
    }

    /// The name Finder shows: `localizedName(for:)`, unless the file was renamed away from the
    /// names in `Info.plist`, in which case the file name.
    func displayName(for languages: [String]) throws -> String {
        let written = ["CFBundleDisplayName", "CFBundleName"].compactMap {
            Self.string($0, in: base).map(Self.visible)
        }
        guard written.isEmpty || written.contains(fileName) else { return fileName }
        return try localizedName(for: languages) ?? fileName
    }

    /// The display name, then the bundle name, in `values`, with soft hyphens removed: German
    /// names carry them ("System\u{AD}einstellungen") and some text views draw them.
    private static func name(in values: [String: Any]) -> String? {
        (string("CFBundleDisplayName", in: values) ?? string("CFBundleName", in: values))
            .map(visible)
    }

    private static func visible(_ name: String) -> String {
        name.replacingOccurrences(of: "\u{AD}", with: "")
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

    /// A bundle's localized `InfoPlist` values: the languages it has, and a reader for one.
    private struct Strings {
        let available: Set<String>
        let read: (String) throws -> [String: Any]?
    }

    /// The localized values, from `InfoPlist.loctable` when the bundle has one, as Apple's do,
    /// or else from `<language>.lproj/InfoPlist.strings`. Nil when there are none.
    private func strings() throws -> Strings? {
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        if let loctable = try Self.propertyList(
            at: resources.appendingPathComponent("InfoPlist.loctable"))
        {
            // The table also holds "LocProvenance", which says where each language came from.
            return Strings(
                available: Set(loctable.keys).subtracting(["LocProvenance"]),
                read: { loctable[$0] as? [String: Any] })
        }
        guard FileManager.default.fileExists(atPath: resources.path) else { return nil }
        let names = try FileManager.default.contentsOfDirectory(atPath: resources.path)
        let suffix = ".lproj"
        return Strings(
            available: Set(
                names.filter { $0.hasSuffix(suffix) }.map { String($0.dropLast(suffix.count)) }),
            read: { language in
                try Self.propertyList(
                    at: resources.appendingPathComponent("\(language)\(suffix)/InfoPlist.strings"))
            })
    }

    /// The development region as the strings name it: some bundles say "English", which stands
    /// for "en" when the strings have that.
    private func region(in strings: Strings?) -> String {
        let canonical = Locale.canonicalLanguageIdentifier(from:)
        return strings?.available.first { canonical($0) == canonical(developmentRegion) }
            ?? developmentRegion
    }

    /// The localization `languages` prefer among `available` and `region`. The region is always
    /// a candidate, so "en" wins over "en_GB" for an "en-US" user, and it is the answer when no
    /// localization matches a preferred language, as `Bundle` does.
    private static func language(
        for languages: [String], in available: Set<String>, region: String
    ) -> String {
        let picked = Bundle.preferredLocalizations(
            from: available.union([region]).sorted(), forPreferences: languages
        ).first
        // `preferredLocalizations` returns some candidate even when none matches, so its pick is
        // kept only when it shares a language code with a preferred language.
        let canonical = Locale.canonicalLanguageIdentifier(from:)
        let code = { Locale(identifier: canonical($0)).languageCode }
        guard let picked, languages.contains(where: { code($0) == code(picked) }) else {
            return region
        }
        return picked
    }

    /// `Info.plist` with `language`'s strings on top. A language with no strings of its own,
    /// such as the development region, is what `Info.plist` already says.
    private func values(in language: String, from strings: Strings?) throws -> [String: Any] {
        guard let table = try strings?.read(language) else { return base }
        return base.merging(table) { $1 }
    }

    /// The dictionary in the property list at `url`, or nil when there is no file there.
    private static func propertyList(at url: URL) throws -> [String: Any]? {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        } catch {
            throw IndexProblem(url, error)
        }
        let value: Any
        do {
            value = try PropertyListSerialization.propertyList(from: data, format: nil)
        } catch {
            throw IndexProblem(path: url.path, reason: "It isn't a property list.")
        }
        guard let dictionary = value as? [String: Any] else {
            throw IndexProblem(path: url.path, reason: "It isn't a property list dictionary.")
        }
        return dictionary
    }
}
