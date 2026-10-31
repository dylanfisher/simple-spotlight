import Foundation
import Testing

@testable import Search

/// Writes `<file>.appex` in `folder`, a Settings extension unless `extensionPoint` or `allowsURL`
/// say otherwise.
@discardableResult
private func makePane(
    _ file: String, in folder: URL, id: String, displayName: String? = nil,
    extensionPoint: String = SettingsPaneProvider.extensionPoint, allowsURL: Bool? = true,
    extra: [String: Any] = [:], localized: [String: [String: String]] = [:]
) throws -> URL {
    var settings: [String: Any] = [:]
    settings["allowsXAppleSystemPreferencesURLScheme"] = allowsURL
    var info = extra
    info["CFBundleIdentifier"] = id
    info["CFBundleName"] = file
    info["EXAppExtensionAttributes"] = [
        "EXExtensionPointIdentifier": extensionPoint, "SettingsExtensionAttributes": settings,
    ]
    info["CFBundleDisplayName"] = displayName
    let url = folder.appending(path: "\(file).appex", directoryHint: .isDirectory)
    try makeBundle(at: url, info: info, localized: localized, as: .loctable)
    return url
}

private func panes(
    in extensions: URL, preferencePanes: [URL] = [], languages: [String] = ["en"]
) throws -> [SearchItem] {
    try SettingsPaneProvider(
        extensionFolders: [extensions], preferencePaneFolders: preferencePanes,
        languages: languages
    ).items()
}

@Test func indexesASettingsExtension() throws {
    let root = try TempFolder()
    try makePane("KeyboardSettings", in: root.url, id: "test.keyboard", displayName: "Keyboard")
    let item = try #require(try panes(in: root.url).first)
    #expect(item.id == "test.keyboard")
    #expect(item.kind == .settingsPane)
    #expect(item.title == "Keyboard")
    #expect(item.subtitle == SettingsPaneProvider.subtitle)
    #expect(item.target == .openURL(URL(string: "x-apple.systempreferences:test.keyboard")!))
}

@Test func skipsOtherExtensionsAndPanesWithoutTheURLFlag() throws {
    let root = try TempFolder()
    try makePane("Shown", in: root.url, id: "test.shown", displayName: "Shown")
    try makePane("Widget", in: root.url, id: "test.widget", extensionPoint: "com.apple.widgetkit")
    try makePane("NoFlag", in: root.url, id: "test.noflag", allowsURL: nil)
    try makePane("FlagOff", in: root.url, id: "test.flagoff", allowsURL: false)
    #expect(try panes(in: root.url).map(\.id) == ["test.shown"])
}

@Test func paneNamesComeFromTheLocTable() throws {
    let root = try TempFolder()
    try makePane(
        "ControlCenterSettings", in: root.url, id: "test.menubar",
        displayName: "ControlCenterSettings",
        localized: [
            "en": ["CFBundleDisplayName": "Menu Bar"],
            "de": ["CFBundleDisplayName": "Menüleiste"],
        ])
    #expect(try panes(in: root.url).map(\.title) == ["Menu Bar"])
    #expect(try panes(in: root.url, languages: ["de-DE"]).map(\.title) == ["Menüleiste"])
}

@Test func paneNamesFallBackToInfoPlistForTheDevelopmentRegion() throws {
    let root = try TempFolder()
    try makePane(
        "Bluetooth", in: root.url, id: "test.bluetooth", displayName: "Bluetooth",
        localized: ["de": ["CFBundleDisplayName": "Bluetooth-DE"]])
    #expect(try panes(in: root.url, languages: ["en-US"]).map(\.title) == ["Bluetooth"])
}

@Test func aRegionNamedEnglishStandsForEn() throws {
    let root = try TempFolder()
    try makePane(
        "Wi-Fi", in: root.url, id: "test.wifi", displayName: "WiFiSettings",
        extra: ["CFBundleDevelopmentRegion": "English"],
        localized: ["en": ["CFBundleDisplayName": "Wi-Fi"]])
    #expect(try panes(in: root.url, languages: ["en-US"]).map(\.title) == ["Wi-Fi"])
}

@Test func panesWithOnlyAnInternalNameUseTheTable() throws {
    let root = try TempFolder()
    let (id, name) = try #require(SettingsPaneProvider.names.first)
    try makePane("Internal", in: root.url, id: id, displayName: "InternalExtension")
    #expect(try panes(in: root.url).map(\.title) == [name])
}

@Test func indexesPreferencePanesByPath() throws {
    let extensions = try TempFolder()
    let preferencePanes = try TempFolder()
    let url = preferencePanes.url.appending(path: "Fuse.prefPane", directoryHint: .isDirectory)
    try makeBundle(at: url, info: ["CFBundleIdentifier": "test.fuse", "CFBundleName": "Fuse"])
    let missing = preferencePanes.url.appending(path: "Missing")
    let item = try #require(
        try panes(in: extensions.url, preferencePanes: [missing, preferencePanes.url]).first)
    #expect(item.id == "test.fuse")
    #expect(item.kind == .settingsPane)
    #expect(item.title == "Fuse")
    #expect(item.target == .openFile(url))
}

@Test func aMissingExtensionFolderThrows() throws {
    let root = try TempFolder()
    #expect(throws: (any Error).self) {
        try panes(in: root.url.appending(path: "Missing"))
    }
}

/// Words with a lowercase letter before a capital that are real names, not bundle names run
/// together.
private let camelCaseNames: Set<Substring> = ["AirDrop", "AppleCare", "FollowUps"]

/// Every pane on this Mac gets the name System Settings shows, not a bundle's internal name such
/// as "PowerPreferences" or "HeadphoneSettingsExtension".
@Test func everyPaneOnThisMacHasAReadableName() throws {
    let items = try SettingsPaneProvider(languages: ["en-US"]).items()
    #expect(items.count > 40)
    for item in items {
        let runTogether = item.title.split(separator: " ").contains { word in
            !camelCaseNames.contains(word)
                && zip(word, word.dropFirst()).contains { $0.isLowercase && $1.isUppercase }
        }
        #expect(!runTogether, "\(item.id): \(item.title)")
        #expect(!item.title.hasSuffix("Extension"), "\(item.id): \(item.title)")
        #expect(!item.title.hasSuffix("Settings"), "\(item.id): \(item.title)")
    }
}
