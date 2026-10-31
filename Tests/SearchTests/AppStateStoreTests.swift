import Foundation
import Testing

@testable import Search

@Test func placesItsFolderInApplicationSupport() {
    let home = URL(filePath: "/Users/test", directoryHint: .isDirectory)
    #expect(
        AppSupport.standardFolder(home: home).path
            == "/Users/test/Library/Application Support/simple-spotlight")
}

@Test func startsWithNoHotkeyAcknowledged() async throws {
    let folder = try TempFolder()
    let store = AppStateStore(folder: folder.url.appending(path: "missing"))

    #expect(try await store.acknowledgedHotKeys().isEmpty)
}

@Test func remembersAnAcknowledgedHotkeyAcrossLaunches() async throws {
    let folder = try TempFolder()
    let inner = folder.url.appending(path: "simple-spotlight")
    try await AppStateStore(folder: inner).acknowledge(hotKey: "cmd+space")
    try await AppStateStore(folder: inner).acknowledge(hotKey: "cmd+space")

    let later = AppStateStore(folder: inner)
    #expect(try await later.acknowledgedHotKeys() == ["cmd+space"])
}

/// One shape, per the pre-release rule: a file that doesn't decode is replaced.
@Test func discardsAFileThatDoesntDecode() async throws {
    let folder = try TempFolder()
    let store = AppStateStore(folder: folder.url)
    try Data(#"{"acknowledgedHotKeys": 3}"#.utf8).write(to: store.file)

    #expect(try await store.acknowledgedHotKeys().isEmpty)
    try await store.acknowledge(hotKey: "ctrl+k")
    #expect(try await AppStateStore(folder: folder.url).acknowledgedHotKeys() == ["ctrl+k"])
}
