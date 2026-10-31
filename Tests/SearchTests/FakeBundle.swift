import Foundation

@testable import Search

/// How a fake bundle stores its localized Info.plist values.
enum Localization {
    /// `Resources/<language>.lproj/InfoPlist.strings`, as most apps do.
    case lproj
    /// `Resources/InfoPlist.loctable`, one plist keyed by language, as Apple's own bundles do.
    case loctable
}

/// Writes a bundle at `url` with `Contents/Info.plist` holding `info`, and `localized` values per
/// language.
func makeBundle(
    at url: URL, info: [String: Any], localized: [String: [String: String]] = [:],
    as localization: Localization = .lproj
) throws {
    let contents = url.appending(path: "Contents", directoryHint: .isDirectory)
    let resources = contents.appending(path: "Resources", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        .write(to: contents.appending(path: "Info.plist"))
    switch localization {
    case .lproj:
        for (language, values) in localized {
            let folder = resources.appending(path: "\(language).lproj", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let lines = values.map { "\"\($0.key)\" = \"\($0.value)\";" }
            try Data(lines.joined(separator: "\n").utf8)
                .write(to: folder.appending(path: "InfoPlist.strings"))
        }
    case .loctable:
        guard !localized.isEmpty else { return }
        try PropertyListSerialization.data(fromPropertyList: localized, format: .binary, options: 0)
            .write(to: resources.appending(path: "InfoPlist.loctable"))
    }
}

/// Writes an app bundle named `<file>.app` in `folder`.
@discardableResult
func makeApp(
    _ file: String, in folder: URL, id: String?, name: String? = nil,
    extra: [String: Any] = [:], localized: [String: [String: String]] = [:]
) throws -> URL {
    var info = extra
    info["CFBundleIdentifier"] = id
    info["CFBundleName"] = name
    let url = folder.appending(path: "\(file).app", directoryHint: .isDirectory)
    try makeBundle(at: url, info: info, localized: localized)
    return url
}

/// Writes `<file>.appex` in `folder`, a System Settings pane unless `extensionPoint` or
/// `allowsURL` say otherwise.
@discardableResult
func makePane(
    _ file: String, in folder: URL, id: String, displayName: String? = nil,
    extensionPoint: String = SettingsPaneProvider.extensionPoint, allowsURL: Bool? = true,
    extra: [String: Any] = [:], localized: [String: [String: String]] = [:]
) throws -> URL {
    var settings: [String: Any] = [:]
    settings["allowsXAppleSystemPreferencesURLScheme"] = allowsURL
    var info = extra
    info["CFBundleIdentifier"] = id
    info["CFBundleName"] = file
    info["CFBundleDisplayName"] = displayName
    info["EXAppExtensionAttributes"] = [
        "EXExtensionPointIdentifier": extensionPoint, "SettingsExtensionAttributes": settings,
    ]
    let url = folder.appending(path: "\(file).appex", directoryHint: .isDirectory)
    try makeBundle(at: url, info: info, localized: localized, as: .loctable)
    return url
}
