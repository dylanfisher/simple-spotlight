import Foundation
import Testing

@testable import Search

/// A watch that reports nothing; tests call `reload()` for each change instead.
private let noWatch: ConfigStore.Watch = { _, _ in {} }
/// A wait that ends only when cancelled, so a read that finds the file gone or empty is
/// confirmed only if nothing reads the file first.
private let neverEnds: ConfigStore.Sleep = { _ in try await Task.sleep(for: .seconds(3600)) }
/// A wait that ends at once.
private let endsAtOnce: ConfigStore.Sleep = { _ in }

private func write(_ text: String, to url: URL) throws {
    try Data(text.utf8).write(to: url)
}

/// Writes a config file that sets `maxResults` alone.
private func write(maxResults: Int, to url: URL) throws {
    try write(#"{"maxResults": \#(maxResults)}"#, to: url)
}

private func contents(of url: URL) throws -> String {
    String(decoding: try Data(contentsOf: url), as: UTF8.self)
}

private func settings(maxResults: Int) -> Settings {
    var settings = Settings()
    settings.maxResults = maxResults
    return settings
}

/// The first state `store` publishes from now on that `matches`, or nil when none does within
/// `limit`. The limit only bounds a failing test, except where FSEvents reports the change: its
/// latency is real time.
private func next(
    from store: ConfigStore, within limit: Duration = .seconds(10),
    where matches: @escaping @Sendable (ConfigStore.State) -> Bool = { _ in true }
) async -> ConfigStore.State? {
    let states = store.states
    return await withTaskGroup(of: ConfigStore.State?.self) { group in
        group.addTask {
            for await state in states where matches(state) { return state }
            return nil
        }
        group.addTask {
            try? await Task.sleep(for: limit)
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}

/// A store of a folder in `root`, started, with its first state taken from `states`.
private func started(
    in root: TempFolder, sleep: @escaping ConfigStore.Sleep = endsAtOnce
) async -> (store: ConfigStore, first: ConfigStore.State?) {
    let store = ConfigStore(folder: root.url, watch: noWatch, sleep: sleep)
    await store.start()
    return (store, await next(from: store))
}

@Test func writesTheDefaultFileWhenThereIsNone() async throws {
    let root = try TempFolder()
    let folder = root.url.appending(path: "simple-spotlight")
    let store = ConfigStore(folder: folder, watch: noWatch)
    let state = await store.start()
    #expect(state == ConfigStore.State(settings: Settings(), errors: []))
    #expect(try contents(of: store.file) == ConfigFile.defaultText)
    #expect(await next(from: store) == state)
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == [ConfigFile.name])
}

@Test func writesTheDefaultFileOverAnEmptyOne() async throws {
    let root = try TempFolder()
    try write(" \n", to: root.url.appending(path: ConfigFile.name))
    let (store, first) = await started(in: root)
    #expect(first == ConfigStore.State(settings: Settings(), errors: []))
    #expect(try contents(of: store.file) == ConfigFile.defaultText)
}

@Test func readsTheFileThereAndLeavesIt() async throws {
    let root = try TempFolder()
    let text = #"{"maxResults": 3}"#
    try write(text, to: root.url.appending(path: ConfigFile.name))
    let (store, first) = await started(in: root)
    #expect(first == ConfigStore.State(settings: settings(maxResults: 3), errors: []))
    #expect(try contents(of: store.file) == text)
}

@Test func aFileWithAnErrorAtLaunchLeavesTheDefaults() async throws {
    let root = try TempFolder()
    let text = "{\n  \"maxResults\": 3,\n  \"calculator\": \"no\"\n}"
    try write(text, to: root.url.appending(path: ConfigFile.name))
    let (store, first) = await started(in: root)
    #expect(first?.settings == Settings())
    #expect(first?.errors.map(\.line) == [3])
    #expect(try contents(of: store.file) == text)
}

@Test func publishesAnEdit() async throws {
    let root = try TempFolder()
    let (store, _) = await started(in: root)
    try write(maxResults: 4, to: store.file)
    await store.reload()
    #expect(
        await next(from: store) == ConfigStore.State(settings: settings(maxResults: 4), errors: []))
}

@Test func anEditWithAnErrorKeepsTheLastGoodSettings() async throws {
    let root = try TempFolder()
    try write(maxResults: 4, to: root.url.appending(path: ConfigFile.name))
    let (store, _) = await started(in: root)
    try write(#"{"maxResults": 4, "calculator": 2}"#, to: store.file)
    await store.reload()
    let state = await next(from: store)
    #expect(state?.settings == settings(maxResults: 4))
    #expect(state?.errors.map(\.key) == ["calculator"])
    // Fixing it applies it and clears the error.
    try write(maxResults: 5, to: store.file)
    await store.reload()
    #expect(
        await next(from: store) == ConfigStore.State(settings: settings(maxResults: 5), errors: []))
}

@Test func aReadThatChangesNothingPublishesNothing() async throws {
    let root = try TempFolder()
    let (store, _) = await started(in: root)
    await store.reload()
    // A save that changes the text but not the settings.
    try write(ConfigFile.defaultText + "\n", to: store.file)
    await store.reload()
    try write(maxResults: 6, to: store.file)
    await store.reload()
    #expect(await next(from: store)?.settings == settings(maxResults: 6))
}

@Test func aFileGoneOnlyForAMomentChangesNothing() async throws {
    let root = try TempFolder()
    try write(maxResults: 4, to: root.url.appending(path: ConfigFile.name))
    let (store, _) = await started(in: root, sleep: neverEnds)
    try FileManager.default.removeItem(at: store.file)
    await store.reload()
    try write("", to: store.file)
    await store.reload()
    try write(maxResults: 5, to: store.file)
    await store.reload()
    #expect(
        await next(from: store) == ConfigStore.State(settings: settings(maxResults: 5), errors: []))
}

@Test func aFileGoneOnceConfirmedMeansTheDefaults() async throws {
    let root = try TempFolder()
    try write(maxResults: 4, to: root.url.appending(path: ConfigFile.name))
    let (store, _) = await started(in: root, sleep: endsAtOnce)
    try FileManager.default.removeItem(at: store.file)
    await store.reload()
    #expect(await next(from: store) == ConfigStore.State(settings: Settings(), errors: []))
    // Only opening the config file writes a new one.
    #expect(!FileManager.default.fileExists(atPath: store.file.path))
    #expect(try await store.makeDefaultFileIfMissing() == store.file)
    #expect(try contents(of: store.file) == ConfigFile.defaultText)
}

@Test func aFileEmptiedOnceConfirmedIsAnError() async throws {
    let root = try TempFolder()
    try write(maxResults: 4, to: root.url.appending(path: ConfigFile.name))
    let (store, _) = await started(in: root, sleep: endsAtOnce)
    try write("", to: store.file)
    await store.reload()
    let state = await next(from: store)
    #expect(state?.settings == settings(maxResults: 4))
    #expect(state?.errors.map(\.reason) == ["is empty: it needs a JSON object, such as {}"])
}

@Test func makingTheDefaultFileKeepsOneThere() async throws {
    let root = try TempFolder()
    let text = #"{"maxResults": 4}"#
    try write(text, to: root.url.appending(path: ConfigFile.name))
    let (store, _) = await started(in: root)
    #expect(try await store.makeDefaultFileIfMissing() == store.file)
    #expect(try contents(of: store.file) == text)
}

@Test func aLinkToNothingIsAnErrorAndIsntWrittenThrough() async throws {
    let root = try TempFolder()
    let target = root.url.appending(path: "elsewhere.json")
    try FileManager.default.createSymbolicLink(
        at: root.url.appending(path: ConfigFile.name), withDestinationURL: target)
    let (store, first) = await started(in: root)
    #expect(first?.settings == Settings())
    #expect(
        first?.errors.map(\.reason) == [
            "is a symbolic link to \(target.path), which doesn't lead to a file"
        ]
    )
    #expect(!FileManager.default.fileExists(atPath: target.path))
    await #expect(throws: ConfigError.self) { try await store.makeDefaultFileIfMissing() }
}

@Test func aFileThatCantBeCreatedIsAnError() async throws {
    let root = try TempFolder()
    let files = FileManager.default
    try files.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.url.path)
    defer {
        do {
            try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.url.path)
        } catch {
            Issue.record(error, "restoring \(root.url.path)")
        }
    }
    let store = ConfigStore(folder: root.url, watch: noWatch)
    let state = await store.start()
    #expect(state.settings == Settings())
    #expect(state.errors.count == 1)
    #expect(state.errors.first?.reason.hasPrefix("couldn't be created: ") == true)
    #expect(try files.contentsOfDirectory(atPath: root.url.path).isEmpty)
}

@Test func aWatchThatFailsIsAnError() async throws {
    struct Refused: Error, CustomStringConvertible {
        var description: String { "refused" }
    }
    let root = try TempFolder()
    let store = ConfigStore(folder: root.url, watch: { _, _ in throw Refused() })
    let state = await store.start()
    #expect(state.settings == Settings())
    #expect(
        state.errors.map(\.reason) == [
            "isn't watched, so a change applies at the next launch: refused"
        ])
}

/// Real FSEvents, so the wait for the edit is a bounded wait on real time.
@Test func appliesAnEditFSEventsReports() async throws {
    let root = try TempFolder()
    let store = ConfigStore(folder: root.url)
    await store.start()
    defer { Task { await store.stop() } }
    try write(maxResults: 7, to: store.file)
    let state = await next(from: store, within: .seconds(10)) { $0.settings.maxResults == 7 }
    #expect(state == ConfigStore.State(settings: settings(maxResults: 7), errors: []))
}

@Test func anEmptyFileAtLaunchFilledMeanwhileIsKept() async throws {
    let root = try TempFolder()
    let file = root.url.appending(path: ConfigFile.name)
    try write("", to: file)
    // The editor's save in place finishes during the wait.
    let store = ConfigStore(folder: root.url, watch: noWatch) { _ in
        try write(maxResults: 4, to: file)
    }
    let state = await store.start()
    #expect(state == ConfigStore.State(settings: settings(maxResults: 4), errors: []))
    #expect(try contents(of: file) == #"{"maxResults": 4}"#)
}

@Test func anEmptyFileWhenOpenedFilledMeanwhileIsKept() async throws {
    let root = try TempFolder()
    let file = root.url.appending(path: ConfigFile.name)
    try write(maxResults: 3, to: file)
    let store = ConfigStore(folder: root.url, watch: noWatch) { _ in
        try write(maxResults: 4, to: file)
    }
    await store.start()
    try write("", to: file)
    #expect(try await store.makeDefaultFileIfMissing() == file)
    #expect(try contents(of: file) == #"{"maxResults": 4}"#)
}

@Test func aFileMadeJustBeforeTheRenameIsKept() async throws {
    let root = try TempFolder()
    let (store, _) = await started(in: root)
    try write(maxResults: 4, to: store.file)
    // The read said there was no file; one appeared before the rename.
    try await store.writeDefault(over: .missing)
    #expect(try contents(of: store.file) == #"{"maxResults": 4}"#)
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.url.path) == [ConfigFile.name])
}

@Test func stoppingEndsTheStates() async throws {
    let root = try TempFolder()
    let store = ConfigStore(folder: root.url, watch: noWatch)
    await store.start()
    await store.stop()
    let states = store.states
    let ended = Task {
        var count = 0
        for await _ in states { count += 1 }
        return count
    }
    // Only the first state was buffered, and the stream ends after it.
    #expect(await ended.value == 1)
}

/// Makes `link` a symbolic link to `target`.
private func link(_ link: URL, to target: URL) throws {
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
}

private func isLink(_ url: URL) throws -> Bool {
    try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
        == .typeSymbolicLink
}

@Test func readsThroughALink() async throws {
    let root = try TempFolder()
    let elsewhere = try TempFolder()
    let target = elsewhere.url.appending(path: "mine.json")
    try write(maxResults: 4, to: target)
    try link(root.url.appending(path: ConfigFile.name), to: target)
    let (store, first) = await started(in: root)
    #expect(first == ConfigStore.State(settings: settings(maxResults: 4), errors: []))
    #expect(try isLink(store.file))
}

@Test func writesTheDefaultFileThroughALinkToAnEmptyFile() async throws {
    let root = try TempFolder()
    let elsewhere = try TempFolder()
    let target = elsewhere.url.appending(path: "mine.json")
    try write("", to: target)
    try link(root.url.appending(path: ConfigFile.name), to: target)
    let (store, first) = await started(in: root)
    #expect(first == ConfigStore.State(settings: Settings(), errors: []))
    #expect(try isLink(store.file))
    #expect(try contents(of: target) == ConfigFile.defaultText)
    // Opening the config file once the target is emptied again does the same.
    try write("", to: target)
    #expect(try await store.makeDefaultFileIfMissing() == store.file)
    #expect(try isLink(store.file))
    #expect(try contents(of: target) == ConfigFile.defaultText)
    #expect(
        try FileManager.default.contentsOfDirectory(atPath: elsewhere.url.path) == ["mine.json"])
}

/// Real FSEvents, so each wait is a bounded wait on real time.
@Test func followsALinksTargetAsItChanges() async throws {
    let root = try TempFolder()
    let first = try TempFolder()
    let second = try TempFolder()
    let firstTarget = first.url.appending(path: "a.json")
    let secondTarget = second.url.appending(path: "b.json")
    try write(maxResults: 3, to: firstTarget)
    try write(maxResults: 4, to: secondTarget)
    try link(root.url.appending(path: ConfigFile.name), to: firstTarget)
    let store = ConfigStore(folder: root.url)
    await store.start()
    defer { Task { await store.stop() } }
    try write(maxResults: 5, to: firstTarget)
    #expect(await next(from: store) { $0.settings.maxResults == 5 } != nil)
    // Pointing the link elsewhere is a change in the store's folder; the new target's folder is
    // then watched.
    try FileManager.default.removeItem(at: store.file)
    try link(store.file, to: secondTarget)
    #expect(await next(from: store) { $0.settings.maxResults == 4 } != nil)
    try write(maxResults: 6, to: secondTarget)
    #expect(await next(from: store) { $0.settings.maxResults == 6 } != nil)
}

/// Real FSEvents: an editor's atomic save replaces the file by a rename.
@Test func appliesAnAtomicSave() async throws {
    let root = try TempFolder()
    let store = ConfigStore(folder: root.url)
    await store.start()
    defer { Task { await store.stop() } }
    try Data(#"{"maxResults": 9}"#.utf8).write(to: store.file, options: .atomic)
    let state = await next(from: store) { $0.settings.maxResults == 9 }
    #expect(state == ConfigStore.State(settings: settings(maxResults: 9), errors: []))
}
