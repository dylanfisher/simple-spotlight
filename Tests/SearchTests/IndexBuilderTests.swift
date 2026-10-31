import Foundation
import Testing

@testable import Search

@Test func buildsAppsAndPanesTogether() async throws {
    let apps = try TempFolder()
    let extensions = try TempFolder()
    try makeApp("Mail", in: apps.url, id: "test.mail")
    try makePane("Sound", in: extensions.url, id: "test.sound", displayName: "Sound")
    let builder = IndexBuilder(
        apps: AppProvider(folders: [apps.url], languages: ["en"], extraApps: []),
        settingsPanes: SettingsPaneProvider(
            extensionFolders: [extensions.url], preferencePaneFolders: [], languages: ["en"]))
    let build = try await builder.build()
    #expect(build.items.map(\.id) == ["test.mail", "test.sound"])
    #expect(build.problems.isEmpty)
    #expect(build.duration > .zero)
}

@Test func collectsBothProvidersProblems() async throws {
    let root = try TempFolder()
    let missingApps = root.url.appending(path: "MissingApps")
    let missingPanes = root.url.appending(path: "MissingPanes")
    try makeApp("Mail", in: root.url, id: "test.mail")
    let builder = IndexBuilder(
        apps: AppProvider(folders: [missingApps, root.url], languages: ["en"], extraApps: []),
        settingsPanes: SettingsPaneProvider(
            extensionFolders: [missingPanes], preferencePaneFolders: [], languages: ["en"]))
    let build = try await builder.build()
    #expect(build.items.map(\.id) == ["test.mail"])
    #expect(build.problems.map(\.path) == [missingApps.path, missingPanes.path])
}

@Test func leavesOutExcludedIDs() async throws {
    let apps = try TempFolder()
    let extensions = try TempFolder()
    try makeApp("Mail", in: apps.url, id: "test.mail")
    try makeApp("Chess", in: apps.url, id: "test.chess")
    try makePane("Sound", in: extensions.url, id: "test.sound", displayName: "Sound")
    let builder = IndexBuilder(
        apps: AppProvider(folders: [apps.url], languages: ["en"], extraApps: []),
        settingsPanes: SettingsPaneProvider(
            extensionFolders: [extensions.url], preferencePaneFolders: [], languages: ["en"]),
        excludedIDs: ["test.chess", "test.sound"])
    #expect(try await builder.build().items.map(\.id) == ["test.mail"])
}

@Suite(.serialized) struct IndexBuilderTiming {
    /// The default app folders, less any this Mac doesn't have.
    static var appFolders: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            "/Applications", "/System/Applications", "/System/Library/CoreServices/Applications",
            home.appending(path: "Applications").path,
        ]
        .filter { FileManager.default.fileExists(atPath: $0) }
        .map { URL(filePath: $0, directoryHint: .isDirectory) }
    }

    /// B4 gives the build 200 ms; the bound is 5x that so a debug build under load doesn't flake.
    @Test func buildsThisMacsIndexWithinBudget() async throws {
        let builder = IndexBuilder(
            apps: AppProvider(folders: Self.appFolders), settingsPanes: SettingsPaneProvider())
        let build = try await builder.build()
        #expect(build.problems.isEmpty)
        let ids = Set(build.items.map(\.id))
        for id in [
            "com.apple.Safari", "com.apple.systempreferences", "com.apple.BluetoothSettings",
            "com.apple.Keyboard-Settings.extension", "com.apple.finder",
        ] {
            #expect(ids.contains(id), "\(id)")
        }
        #expect(build.duration < .seconds(1))
    }
}
