import Foundation
import Testing

@testable import Search

private func scan(
    _ extensions: [URL], preferencePanes: [URL] = [], languages: [String] = ["en"]
) throws -> (items: [SearchItem], problems: [IndexProblem]) {
    try SettingsPaneProvider(
        extensionFolders: extensions, preferencePaneFolders: preferencePanes,
        languages: languages
    ).items()
}

private func panes(
    in extensions: URL, preferencePanes: [URL] = [], languages: [String] = ["en"]
) throws -> [SearchItem] {
    let found = try scan([extensions], preferencePanes: preferencePanes, languages: languages)
    #expect(found.problems.isEmpty)
    return found.items
}

@Test func indexesASettingsExtension() throws {
    let root = try TempFolder()
    try makePane("KeyboardSettings", in: root.url, id: "test.keyboard", displayName: "Keyboard")
    let item = try #require(try panes(in: root.url).first)
    #expect(item.id == "test.keyboard")
    #expect(item.kind == .settingsPane)
    #expect(item.title == "Keyboard")
    #expect(item.alternateNames.isEmpty)
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

@Test func neverReadsTheLocTableOfAnotherExtension() throws {
    let root = try TempFolder()
    let widget = try makePane(
        "Widget", in: root.url, id: "test.widget", extensionPoint: "com.apple.widgetkit")
    try Data("not a plist".utf8).write(
        to: widget.appending(path: "Contents/Resources/InfoPlist.loctable"))
    #expect(try panes(in: root.url).isEmpty)
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
    let german = try #require(try panes(in: root.url, languages: ["de-DE"]).first)
    #expect(german.title == "Menüleiste")
    #expect(german.alternateNames == ["Menu Bar"])
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

@Test func skipsHiddenPanes() throws {
    let root = try TempFolder()
    let id = try #require(SettingsPaneProvider.hidden.first)
    try makePane("Hidden", in: root.url, id: id, displayName: "Hidden")
    #expect(try panes(in: root.url).isEmpty)
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

@Test func aDuplicatePreferencePaneKeepsTheFirstFolders() throws {
    let extensions = try TempFolder()
    let first = try TempFolder()
    let second = try TempFolder()
    for (folder, name) in [(first, "New"), (second, "Old")] {
        try makeBundle(
            at: folder.url.appending(path: "\(name).prefPane", directoryHint: .isDirectory),
            info: ["CFBundleIdentifier": "test.same", "CFBundleName": name])
    }
    let found = try panes(in: extensions.url, preferencePanes: [first.url, second.url])
    #expect(found.map(\.title) == ["New"])
}

@Test func aMissingExtensionFolderIsAProblem() throws {
    let root = try TempFolder()
    let missing = root.url.appending(path: "Missing")
    try makePane("Sound", in: root.url, id: "test.sound", displayName: "Sound")
    let found = try scan([missing, root.url])
    #expect(found.items.map(\.id) == ["test.sound"])
    #expect(found.problems.map(\.path) == [missing.path])
}

@Test func aGarbagePaneIsAProblem() throws {
    let root = try TempFolder()
    let broken = try makePane("Broken", in: root.url, id: "test.broken", displayName: "Broken")
    try makePane("Sound", in: root.url, id: "test.sound", displayName: "Sound")
    let plist = broken.appending(path: "Contents/Info.plist")
    try Data("not a plist".utf8).write(to: plist)
    let found = try scan([root.url])
    #expect(found.items.map(\.id) == ["test.sound"])
    #expect(found.problems.map(\.path) == [plist.path])
}

@Test func stopsPaneScanWhenCancelled() async throws {
    let root = try TempFolder()
    try makePane("Sound", in: root.url, id: "test.sound", displayName: "Sound")
    let result = await Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return Result { try scan([root.url]) }
    }.value
    #expect(throws: CancellationError.self) { try result.get() }
}

/// Words with a lowercase letter before a capital that are real names, not bundle names run
/// together.
private let camelCaseNames: Set<Substring> = ["AirDrop", "AppleCare", "FollowUps"]

/// Every pane on this Mac gets the name System Settings shows, not a bundle's internal name such
/// as "PowerPreferences" or "HeadphoneSettingsExtension".
@Test func everyPaneOnThisMacHasAReadableName() throws {
    let found = try SettingsPaneProvider(languages: ["en-US"]).items()
    #expect(found.problems.isEmpty)
    #expect(found.items.count > 40)
    for item in found.items {
        let runTogether = item.title.split(separator: " ").contains { word in
            !camelCaseNames.contains(word)
                && zip(word, word.dropFirst()).contains { $0.isLowercase && $1.isUppercase }
        }
        #expect(!runTogether, "\(item.id): \(item.title)")
        #expect(!item.title.hasSuffix("Extension"), "\(item.id): \(item.title)")
        #expect(!item.title.hasSuffix("Settings"), "\(item.id): \(item.title)")
    }
}

@Test func looksForPreferencePanesInTheGivenHomeFolder() {
    let home = URL(filePath: "/Users/someone", directoryHint: .isDirectory)
    #expect(
        SettingsPaneProvider.standardPreferencePaneFolders(home: home).map(\.path) == [
            "/Library/PreferencePanes", "/Users/someone/Library/PreferencePanes",
        ])
}
