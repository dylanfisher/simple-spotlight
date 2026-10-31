import Foundation
import Testing

@testable import Search

/// The keys and defaults of the plan's Config table, the spec `Settings.Keys` follows.
@Test func declaresThePlannedKeysAndDefaults() {
    #expect(
        Settings.Keys.all.map(\.name) == [
            "hotkey", "searchApplications", "searchSystemSettings", "calculator", "appFolders",
            "excludedApps", "maxResults", "dimUnused", "dimAfterDays", "showOnAllDisplays",
            "launchAtLogin",
        ])
    let settings = Settings()
    #expect(settings.hotkey.text == "cmd+space")
    #expect(settings.searchApplications)
    #expect(settings.searchSystemSettings)
    #expect(settings.calculator)
    #expect(
        settings.appFolders == [
            "/Applications", "/System/Applications", "/System/Library/CoreServices/Applications",
            "~/Applications",
        ])
    #expect(settings.excludedApps.isEmpty)
    #expect(settings.maxResults == 8)
    #expect(settings.dimUnused)
    #expect(settings.dimAfterDays == 30)
    #expect(!settings.showOnAllDisplays)
    #expect(!settings.launchAtLogin)
}

/// A property with no key would never be read from the file.
@Test func everyPropertyHasAKey() {
    let properties = Mirror(reflecting: Settings()).children.compactMap(\.label)
    #expect(properties == Settings.Keys.all.map(\.name))
}

@Test func buildsTheIndexFromTheAppFoldersWithTildePlaced() async throws {
    let home = try TempFolder()
    let apps = home.url.appending(path: "Apps")
    try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
    try makeApp("Mail", in: apps, id: "test.mail")
    try makeApp("Chess", in: apps, id: "test.chess")
    var settings = Settings()
    settings.appFolders = ["~/Apps"]
    settings.searchSystemSettings = false
    settings.excludedApps = ["test.chess"]
    let builder = settings.indexBuilder(home: home.url, languages: ["en"])
    #expect(builder.apps.folders.map(\.path) == [apps.path])
    let build = try await builder.build()
    #expect(build.items.map(\.id).filter { $0.hasPrefix("test.") } == ["test.mail"])
    #expect(build.problems.isEmpty)
}

@Test func buildsNothingWithBothSourcesOff() async throws {
    var settings = Settings()
    settings.searchApplications = false
    settings.searchSystemSettings = false
    let build = try await settings.indexBuilder().build()
    #expect(build.items.isEmpty)
    #expect(build.problems.isEmpty)
}

/// Whether a missing app folder is reported is the index's call, not the config file's: see
/// docs/decisions/0007-missing-app-folders.md.
@Test func reportsAMissingAppFolderButTheUsersApplications() async throws {
    let home = try TempFolder()
    var settings = Settings()
    settings.appFolders = ["~/Applications", "~/Gone"]
    settings.searchSystemSettings = false
    let build = try await settings.indexBuilder(home: home.url, languages: ["en"]).build()
    #expect(build.problems.map(\.path) == [home.url.appending(path: "Gone").path])
}

/// A change the index doesn't read keeps the index; one it reads asks for a new one.
@Test func asksForTheSameIndexUnlessAnIndexedKeyChanges() {
    let base = Settings()
    var other = base
    other.hotkey = KeyChord(.control, .k)
    other.calculator = false
    other.maxResults = 3
    other.dimUnused = false
    other.dimAfterDays = 7
    other.showOnAllDisplays = true
    other.launchAtLogin = true
    #expect(base.indexKeys == other.indexKeys)

    let changes: [(inout Settings) -> Void] = [
        { $0.searchApplications = false }, { $0.searchSystemSettings = false },
        { $0.appFolders = ["/Applications"] }, { $0.excludedApps = ["com.apple.Chess"] },
    ]
    for change in changes {
        var changed = base
        change(&changed)
        #expect(base.indexKeys != changed.indexKeys)
    }
}
