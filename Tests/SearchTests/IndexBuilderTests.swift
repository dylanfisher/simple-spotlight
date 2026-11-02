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

@Test func buildsScriptsAfterAppsAndPanesAndWatchesTheirFolder() async throws {
    let apps = try TempFolder()
    let commands = try TempFolder()
    try makeApp("Mail", in: apps.url, id: "test.mail")
    try makeScript("tv.sh", in: commands.url)
    let builder = IndexBuilder(
        apps: AppProvider(folders: [apps.url], languages: ["en"], extraApps: []),
        settingsPanes: SettingsPaneProvider(
            extensionFolders: [], preferencePaneFolders: [], languages: ["en"]),
        scripts: ScriptCommandProvider(folder: commands.url))
    let build = try await builder.build()
    #expect(build.items.map(\.id) == ["test.mail", SearchItem.builtInID("commands/tv.sh")])
    #expect(builder.watchedFolders.map(\.path) == [apps.url.path, commands.url.path])
}

/// `scriptCommands` adds the commands folder beside the config file, to the build and the watch.
@Test func scriptCommandsTurnsTheCommandsFolderOnAndOff() async throws {
    let home = try TempFolder()
    let commands = home.url.appendingPathComponent(".config/simple-spotlight/commands")
    try FileManager.default.createDirectory(at: commands, withIntermediateDirectories: true)
    try makeScript("tv.sh", in: commands)
    var settings = Settings()
    settings.searchApplications = false
    settings.searchSystemSettings = false
    #expect(settings.scriptCommands)
    let on = settings.indexBuilder(home: home.url, languages: ["en"])
    #expect(try await on.build().items.map(\.title) == ["tv"])
    #expect(on.watchedFolders.map(\.path) == [commands.path])

    settings.scriptCommands = false
    let off = settings.indexBuilder(home: home.url, languages: ["en"])
    #expect(try await off.build().items.isEmpty)
    #expect(off.watchedFolders.isEmpty)
}

@Suite(.serialized) struct IndexBuilderTiming {
    /// B4 gives the build 200 ms; the bound is 5x that so a debug build under load doesn't flake.
    /// The scripts are 50 in a temporary folder rather than the user's.
    @Test func buildsThisMacsIndexWithinBudget() async throws {
        let commands = try TempFolder()
        for number in 1...50 {
            try makeScript(
                "script-\(number).sh", in: commands.url,
                "#!/bin/sh\n# @title Script \(number)\n# @keywords one two\necho \(number)\n")
        }
        let standard = Settings().indexBuilder()
        let builder = IndexBuilder(
            apps: standard.apps, settingsPanes: standard.settingsPanes,
            scripts: ScriptCommandProvider(folder: commands.url))
        let build = try await builder.build()
        #expect(build.items.filter { $0.kind == .script }.count == 50)
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
