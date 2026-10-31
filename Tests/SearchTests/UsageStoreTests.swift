import Foundation
import Testing

@testable import Search

private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

private func store(_ folder: URL, sleep: @escaping UsageStore.Sleep = { _ in }) -> UsageStore {
    UsageStore(folder: folder, sleep: sleep) { Issue.record($0) }
}

@Test func startsEmptyWithNoFile() async throws {
    let folder = try TempFolder()

    #expect(try await store(folder.url.appending(path: "missing")).load(at: now).entries.isEmpty)
}

@Test func remembersOpensAcrossLaunches() async throws {
    let folder = try TempFolder()
    let inner = folder.url.appending(path: "simple-spotlight")
    let first = store(inner)
    _ = try await first.record("com.apple.Safari", at: now)
    let recorded = try await first.record("com.apple.Safari", at: now)
    try await first.flush()

    let later = try await store(inner).load(at: now)
    #expect(later == recorded)
    #expect(later.entries["com.apple.Safari"]?.count == 2)
}

/// Holds the store's delayed write until the test lets it go.
private actor Gate {
    private var waiting: CheckedContinuation<Void, Never>?
    private var opened = false

    func wait() async {
        guard !opened else { return }
        await withCheckedContinuation { waiting = $0 }
    }

    func open() {
        opened = true
        waiting?.resume()
        waiting = nil
    }
}

@Test func opensDuringTheDelayAreWrittenOnce() async throws {
    let folder = try TempFolder()
    let gate = Gate()
    let usage = store(folder.url) { _ in await gate.wait() }
    _ = try await usage.record("a", at: now)
    _ = try await usage.record("b", at: now)
    _ = try await usage.record("a", at: now)
    let writing = try #require(await usage.writing)

    await gate.open()
    await writing.value

    #expect(await usage.writes == 1)
    let read = try await store(folder.url).load(at: now)
    #expect(read.entries.keys.sorted() == ["a", "b"])
}

@Test func flushWritesOnlyWhatIsUnwritten() async throws {
    let folder = try TempFolder()
    let usage = store(folder.url)
    try await usage.flush()
    #expect(await usage.writes == 0)
    #expect(!FileManager.default.fileExists(atPath: usage.file.path))
}

/// One shape, per the pre-release rule: a file that doesn't decode is replaced.
/// Collects the problems a store reports.
private final class Problems: @unchecked Sendable {
    private let lock = NSLock()
    private var reported: [String] = []

    func add(_ error: any Error) { lock.withLock { reported.append(String(describing: error)) } }
    var all: [String] { lock.withLock { reported } }
}

@Test func discardsAFileThatDoesntDecodeAndReplacesIt() async throws {
    let folder = try TempFolder()
    let problems = Problems()
    let usage = UsageStore(
        folder: folder.url, sleep: { _ in }, reportProblem: { problems.add($0) })
    try Data(#"{"entries": 3}"#.utf8).write(to: usage.file)

    #expect(try await usage.load(at: now).entries.isEmpty)
    #expect(problems.all.count == 1)
    #expect(problems.all.first?.contains("discarded") == true)
    _ = try await usage.record("a", at: now)
    try await usage.flush()
    #expect(try await store(folder.url).load(at: now).entries.keys.sorted() == ["a"])
}

@Test func forgetsEntriesThatHaveDecayedAway() async throws {
    let folder = try TempFolder()
    let first = store(folder.url)
    // The age at which one open's weight falls to `forgetBelow`.
    let boundary = -log2(UsageStore.forgetBelow) * UsageBoost.halfLife
    _ = try await first.record("old", at: now.addingTimeInterval(-boundary - 60))
    _ = try await first.record("kept", at: now.addingTimeInterval(-boundary + 60))
    try await first.flush()

    let read = try await store(folder.url).load(at: now)
    #expect(read.entries.keys.sorted() == ["kept"])
}
