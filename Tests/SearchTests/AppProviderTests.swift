import Foundation
import Testing

@testable import Search

/// Scans `folders` with no extra apps and a home folder that has no Applications folder.
private func scan(
    _ folders: [URL], languages: [String] = ["en"], extraApps: [URL] = [],
    home: URL = URL(filePath: "/nonexistent-home", directoryHint: .isDirectory)
) throws -> (items: [SearchItem], problems: [IndexProblem]) {
    try AppProvider(folders: folders, languages: languages, extraApps: extraApps, home: home)
        .items()
}

private func items(_ folders: [URL], languages: [String] = ["en"]) throws -> [SearchItem] {
    let found = try scan(folders, languages: languages)
    #expect(found.problems.isEmpty)
    return found.items
}

@Test func findsAppsToADepthOfTwo() throws {
    let root = try TempFolder()
    let utilities = root.url.appending(path: "Utilities")
    let deeper = utilities.appending(path: "Deeper")
    try FileManager.default.createDirectory(at: deeper, withIntermediateDirectories: true)
    try makeApp("One", in: root.url, id: "test.one")
    try makeApp("Two", in: utilities, id: "test.two")
    try makeApp("Three", in: deeper, id: "test.three")
    #expect(try items([root.url]).map(\.title).sorted() == ["One", "Two"])
}

@Test func describesAnApp() throws {
    let root = try TempFolder()
    let url = try makeApp("Mail", in: root.url, id: "test.mail")
    let item = try #require(try items([root.url]).first)
    #expect(item.id == "test.mail")
    #expect(item.kind == .app)
    #expect(item.title == "Mail")
    #expect(item.alternateNames.isEmpty)
    #expect(item.subtitle == root.url.path)
    #expect(item.target == .openFile(url))
}

@Test func indexesNothingInsideAnApp() throws {
    let root = try TempFolder()
    let outer = try makeApp("Outer", in: root.url, id: "test.outer")
    try makeApp("Helper", in: outer.appending(path: "Contents"), id: "test.helper")
    #expect(try items([root.url]).map(\.title) == ["Outer"])
}

@Test func localizedNamesWin() throws {
    let root = try TempFolder()
    let names = ["CFBundleDisplayName": "Plans", "CFBundleName": "Plans"]
    try makeApp(
        "Plans", in: root.url, id: "test.plans", name: "Plans",
        extra: ["CFBundleDisplayName": "Plans"],
        localized: ["fr": ["CFBundleDisplayName": "Cartes"], "en": names])
    #expect(try items([root.url], languages: ["fr-FR"]).map(\.title) == ["Cartes"])
    #expect(try items([root.url], languages: ["en-US"]).map(\.title) == ["Plans"])
}

@Test func aLocalizedAppIsAlsoFoundByItsFileName() throws {
    let root = try TempFolder()
    try makeApp(
        "Calculator", in: root.url, id: "test.calculator", name: "Calculator",
        localized: ["de": ["CFBundleName": "Rechner"]])
    let item = try #require(try items([root.url], languages: ["de-DE"]).first)
    #expect(item.title == "Rechner")
    #expect(item.alternateNames == ["Calculator"])
}

@Test func usesTheDevelopmentRegionWhenNoLocalizationMatches() throws {
    let root = try TempFolder()
    try makeApp(
        "Mail", in: root.url, id: "test.mail", name: "Mail",
        localized: ["fr": ["CFBundleName": "Courrier"], "de": ["CFBundleName": "Post"]])
    #expect(try items([root.url], languages: ["en-US"]).map(\.title) == ["Mail"])
}

@Test func usesTheDevelopmentRegionsTableWhenNoLanguageMatches() throws {
    let root = try TempFolder()
    try makeApp(
        "Mail", in: root.url, id: "test.mail", name: "Mail",
        extra: ["CFBundleDevelopmentRegion": "fr"],
        localized: ["fr": ["CFBundleName": "Mail FR"], "de": ["CFBundleName": "Mail DE"]])
    #expect(try items([root.url], languages: ["ja-JP"]).map(\.title) == ["Mail FR"])
}

@Test func macOSKeysWin() throws {
    let root = try TempFolder()
    try makeApp(
        "Image Playground", in: root.url, id: "test.playground", name: "Image Playground",
        localized: [
            "en": [
                "CFBundleDisplayName": "Playground",
                "CFBundleDisplayName-macos": "Image Playground",
            ]
        ])
    #expect(try items([root.url]).map(\.title) == ["Image Playground"])
}

@Test func namesDropSoftHyphens() throws {
    let root = try TempFolder()
    try makeApp(
        "System Settings", in: root.url, id: "test.settings", name: "System Settings",
        localized: ["de": ["CFBundleName": "System\u{AD}einstellungen"]])
    #expect(try items([root.url], languages: ["de"]).map(\.title) == ["Systemeinstellungen"])
}

@Test func fallsBackFromDisplayNameToNameToFileName() throws {
    let root = try TempFolder()
    try makeApp(
        "Display", in: root.url, id: "test.display", name: "Display",
        extra: ["CFBundleDisplayName": "Display"])
    try makeApp("Named", in: root.url, id: "test.named", name: "Named")
    try makeApp("Bare", in: root.url, id: "test.bare")
    #expect(try items([root.url]).map(\.title) == ["Bare", "Display", "Named"])
}

@Test func aRenamedAppKeepsItsFileName() throws {
    let root = try TempFolder()
    try makeApp(
        "Visual Studio Code", in: root.url, id: "test.code", name: "Code",
        extra: ["CFBundleDisplayName": "Code"])
    #expect(try items([root.url]).map(\.title) == ["Visual Studio Code"])
}

@Test func aDuplicateBundleIDKeepsTheFirstFolders() throws {
    let first = try TempFolder()
    let second = try TempFolder()
    try makeApp("Old", in: second.url, id: "test.same")
    let kept = try makeApp("New", in: first.url, id: "test.same")
    try makeApp("Other", in: second.url, id: "test.other")
    let found = try items([first.url, second.url])
    #expect(found.map(\.title) == ["New", "Other"])
    #expect(found.first?.target == .openFile(kept))
}

@Test func anAppWithoutABundleIDIsKeyedByPath() throws {
    let root = try TempFolder()
    let url = try makeApp("Loose", in: root.url, id: nil)
    #expect(try items([root.url]).map(\.id) == [url.path])
}

@Test func findsAnAppThroughASymbolicLink() throws {
    let root = try TempFolder()
    let elsewhere = try TempFolder()
    let target = try makeApp("Safari", in: elsewhere.url, id: "test.safari")
    let link = root.url.appending(path: "Safari.app", directoryHint: .isDirectory)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    let item = try #require(try items([root.url]).first)
    #expect(item.title == "Safari")
    #expect(item.target == .openFile(link))
}

@Test func followsALinkedFolderAtDepthOne() throws {
    let root = try TempFolder()
    let elsewhere = try TempFolder()
    try makeApp("Linked", in: elsewhere.url, id: "test.linked")
    try FileManager.default.createSymbolicLink(
        at: root.url.appending(path: "Folder"), withDestinationURL: elsewhere.url)
    #expect(try items([root.url]).map(\.id) == ["test.linked"])
}

@Test func aLinkLoopEndsAtTheDepthLimit() throws {
    let root = try TempFolder()
    try makeApp("One", in: root.url, id: "test.one")
    try FileManager.default.createSymbolicLink(
        at: root.url.appending(path: "Loop"), withDestinationURL: root.url)
    #expect(try items([root.url]).map(\.id) == ["test.one"])
}

@Test func findsAnAppWithTheHiddenFlag() throws {
    let root = try TempFolder()
    var url = try makeApp("Hidden", in: root.url, id: "test.hidden")
    var values = URLResourceValues()
    values.isHidden = true
    try url.setResourceValues(values)
    try makeApp(".Dotted", in: root.url, id: "test.dotted")
    #expect(try items([root.url]).map(\.id) == ["test.hidden"])
}

@Test func skipsAgentsOnlyUnderCoreServices() throws {
    let root = try TempFolder()
    let coreServices = root.url.appending(path: "CoreServices")
    let applications = root.url.appending(path: "Applications")
    for folder in [coreServices, applications] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try makeApp(
            "Agent", in: folder, id: "\(folder.lastPathComponent).agent",
            extra: ["LSUIElement": true])
        try makeApp(
            "Daemon", in: folder, id: "\(folder.lastPathComponent).daemon",
            extra: ["LSBackgroundOnly": "1"])
        try makeApp(
            "Visible", in: folder, id: "\(folder.lastPathComponent).visible",
            extra: ["LSUIElement": false])
    }
    let provider = AppProvider(
        folders: [coreServices, applications], languages: ["en"], coreServices: coreServices,
        extraApps: [])
    #expect(
        try provider.items().items.map(\.id) == [
            "CoreServices.visible", "Applications.agent", "Applications.daemon",
            "Applications.visible",
        ])
}

@Test func includesAnExtraAppWhenItExists() throws {
    let root = try TempFolder()
    let elsewhere = try TempFolder()
    try makeApp("Mail", in: root.url, id: "test.mail")
    let finder = try makeApp("Finder", in: elsewhere.url, id: "test.finder")
    let missing = elsewhere.url.appending(path: "Missing.app", directoryHint: .isDirectory)
    let found = try scan([root.url], extraApps: [finder, missing])
    #expect(found.items.map(\.id) == ["test.mail", "test.finder"])
    #expect(found.problems.isEmpty)
}

@Test func aMissingFolderIsAProblemAndTheRestIsScanned() throws {
    let root = try TempFolder()
    let missing = root.url.appending(path: "Missing")
    try makeApp("Mail", in: root.url, id: "test.mail")
    let found = try scan([missing, root.url])
    #expect(found.items.map(\.id) == ["test.mail"])
    #expect(found.problems.map(\.path) == [missing.path])
}

@Test func aMissingUserApplicationsFolderIsSkippedSilently() throws {
    let home = try TempFolder()
    let found = try scan([home.url.appending(path: "Applications")], home: home.url)
    #expect(found.items.isEmpty)
    #expect(found.problems.isEmpty)
}

@Test func anUnreadableSubfolderIsAProblem() throws {
    let root = try TempFolder()
    let locked = root.url.appending(path: "Locked")
    try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
    try makeApp("Mail", in: root.url, id: "test.mail")
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
    defer {
        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: locked.path)
        } catch {
            Issue.record(error)
        }
    }
    let found = try scan([root.url])
    #expect(found.items.map(\.id) == ["test.mail"])
    #expect(found.problems.map(\.path) == [locked.path])
}

@Test func aGarbageInfoPlistIsAProblem() throws {
    let root = try TempFolder()
    let broken = try makeApp("Broken", in: root.url, id: "test.broken")
    try makeApp("Mail", in: root.url, id: "test.mail")
    let plist = broken.appending(path: "Contents/Info.plist")
    try Data("not a plist".utf8).write(to: plist)
    let found = try scan([root.url])
    #expect(found.items.map(\.id) == ["test.mail"])
    #expect(found.problems.map(\.path) == [plist.path])
}

@Test func stopsWhenCancelled() async throws {
    let root = try TempFolder()
    try makeApp("Mail", in: root.url, id: "test.mail")
    let result = await Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return Result { try scan([root.url]) }
    }.value
    #expect(throws: CancellationError.self) { try result.get() }
}

/// An app where macOS or an installer puts it shows no path; one anywhere else keeps it.
@Test func anAppInAStandardFolderShowsNoPath() throws {
    let home = try TempFolder()
    let applications = home.url.appending(path: "Applications")
    let utilities = applications.appending(path: "Utilities")
    let other = applications.appending(path: "Other")
    try FileManager.default.createDirectory(at: utilities, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    try makeApp("Mail", in: applications, id: "test.mail")
    try makeApp("Disk", in: utilities, id: "test.disk")
    try makeApp("Nested", in: other, id: "test.nested")

    let found = try scan([applications], home: home.url)

    let subtitles = Dictionary(uniqueKeysWithValues: found.items.map { ($0.id, $0.subtitle) })
    #expect(subtitles["test.mail"] == .some(nil))
    #expect(subtitles["test.disk"] == .some(nil))
    #expect(subtitles["test.nested"] == other.path)
}

@Test func systemAppsAndFinderShowNoPath() throws {
    let system = URL(filePath: "/System/Applications", directoryHint: .isDirectory)

    let found = try scan([system], extraApps: [AppProvider.finder])

    let calculator = try #require(found.items.first { $0.id == "com.apple.calculator" })
    let terminal = try #require(found.items.first { $0.id == "com.apple.Terminal" })
    let finder = try #require(found.items.first { $0.id == "com.apple.finder" })
    #expect(calculator.subtitle == nil)
    #expect(terminal.subtitle == nil)
    #expect(finder.subtitle == nil)
}
