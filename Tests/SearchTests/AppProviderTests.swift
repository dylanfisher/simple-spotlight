import Foundation
import Testing

@testable import Search

private func items(_ folders: [URL], languages: [String] = ["en"]) throws -> [SearchItem] {
    try AppProvider(folders: folders, languages: languages).items()
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

@Test func usesTheDevelopmentRegionWhenNoLocalizationMatches() throws {
    let root = try TempFolder()
    try makeApp(
        "Mail", in: root.url, id: "test.mail", name: "Mail",
        localized: ["fr": ["CFBundleName": "Courrier"], "de": ["CFBundleName": "Post"]])
    #expect(try items([root.url], languages: ["en-US"]).map(\.title) == ["Mail"])
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
        folders: [coreServices, applications], languages: ["en"], coreServices: coreServices)
    #expect(
        try provider.items().map(\.id) == [
            "CoreServices.visible", "Applications.agent", "Applications.daemon",
            "Applications.visible",
        ])
}

@Test func aMissingFolderThrows() throws {
    let root = try TempFolder()
    #expect(throws: (any Error).self) {
        try items([root.url.appending(path: "Missing")])
    }
}

@Test func anUnreadableInfoPlistThrows() throws {
    let root = try TempFolder()
    let url = try makeApp("Broken", in: root.url, id: "test.broken")
    try Data("not a plist".utf8).write(to: url.appending(path: "Contents/Info.plist"))
    #expect(throws: BundleInfo.ReadError.self) { try items([root.url]) }
}
