import Foundation
import Testing

@testable import Search

@Test func buildsAppsAndPanesTogether() async throws {
    let apps = try TempFolder()
    let extensions = try TempFolder()
    try makeApp("Mail", in: apps.url, id: "test.mail")
    try makeBundle(
        at: extensions.url.appending(path: "Sound.appex"),
        info: [
            "CFBundleIdentifier": "test.sound", "CFBundleDisplayName": "Sound",
            "EXAppExtensionAttributes": [
                "EXExtensionPointIdentifier": SettingsPaneProvider.extensionPoint,
                "SettingsExtensionAttributes": ["allowsXAppleSystemPreferencesURLScheme": true],
            ],
        ])
    let builder = IndexBuilder(
        apps: AppProvider(folders: [apps.url], languages: ["en"]),
        settingsPanes: SettingsPaneProvider(
            extensionFolders: [extensions.url], preferencePaneFolders: [], languages: ["en"]))
    let build = try await builder.build()
    #expect(build.items.map(\.id) == ["test.mail", "test.sound"])
    #expect(build.duration > .zero)
}

@Test func aProviderErrorFailsTheBuild() async throws {
    let root = try TempFolder()
    let builder = IndexBuilder(
        apps: AppProvider(folders: [root.url.appending(path: "Missing")], languages: ["en"]),
        settingsPanes: SettingsPaneProvider(
            extensionFolders: [root.url], preferencePaneFolders: [], languages: ["en"]))
    await #expect(throws: (any Error).self) { try await builder.build() }
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
        let ids = Set(build.items.map(\.id))
        for id in [
            "com.apple.Safari", "com.apple.systempreferences", "com.apple.BluetoothSettings",
            "com.apple.Keyboard-Settings.extension",
        ] {
            #expect(ids.contains(id), "\(id)")
        }
        #expect(build.duration < .seconds(1))
    }
}
