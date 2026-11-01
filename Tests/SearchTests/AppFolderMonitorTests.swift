import Foundation
import Testing

@testable import Search

/// How many reports a monitor's `Burst` makes for changes at `offsets` from a start, checking
/// its deadline before each change as the monitor's wait would.
private func reports(
    _ offsets: [TimeInterval], quiet: TimeInterval = AppFolderMonitor.quiet,
    longest: TimeInterval = AppFolderMonitor.longest
) -> Int {
    let start: TimeInterval = 0
    var burst = AppFolderMonitor.Burst(quiet: quiet, longest: longest)
    var count = 0
    for offset in offsets {
        let now = start + offset
        while let deadline = burst.deadline, deadline <= now {
            if burst.report(at: deadline) { count += 1 }
        }
        _ = burst.change(at: now)
    }
    if let deadline = burst.deadline, burst.report(at: deadline) { count += 1 }
    return count
}

/// An app update: a write every 5 ms for 5 s.
@Test func thousandsOfWritesInABundleAreOneReport() {
    let writes = (0..<1_000).map { 0.005 * Double($0) }
    #expect(reports(writes) == 1)
}

@Test func aPauseLongerThanQuietEndsTheBurst() {
    #expect(reports([0, 0.9, 2]) == 2)
}

@Test func changesThatNeverPauseReportEveryLongest() {
    let writes = (0..<250).map { 0.1 * Double($0) }
    #expect(reports(writes) == 3)
}

@Test func aBurstIsDueQuietAfterItsLastChange() throws {
    let start: TimeInterval = 0
    var burst = AppFolderMonitor.Burst(quiet: 1, longest: 10)
    let began = burst.change(at: start)
    let continued = !burst.change(at: start + 0.5)
    #expect(began && continued)

    #expect(burst.deadline == start + 1.5)
    let early = burst.report(at: start + 1.499)
    let due = burst.report(at: start + 1.5)
    #expect(!early && due)
    #expect(burst.deadline == nil)
}

/// Records the stop of a watch, and keeps its callback for the test to call.
private final class FakeWatch: @unchecked Sendable {
    private let lock = NSLock()
    private var stops = 0
    private var starts = 0
    private var callback: (@Sendable () -> Void)?

    var watch: AppFolderMonitor.Watch {
        { [self] _, onChange in
            lock.withLock {
                starts += 1
                callback = onChange
            }
            return { [self] in lock.withLock { stops += 1 } }
        }
    }

    var stopped: Int { lock.withLock { stops } }
    var watches: Int { lock.withLock { starts } }
}

@Test func stopEndsTheWatch() async throws {
    let fake = FakeWatch()
    let monitor = AppFolderMonitor(
        folders: [URL(filePath: "/Applications")], watch: fake.watch,
        failed: { Issue.record($0) }, onChange: {})
    await monitor.started?.value

    monitor.stop()
    monitor.stop()

    #expect(fake.stopped == 1)
}

@Test func aStopBeforeTheWatchStartsStopsItOnceStarted() async throws {
    let fake = FakeWatch()
    let monitor = AppFolderMonitor(
        folders: [URL(filePath: "/Applications")], watch: fake.watch,
        failed: { Issue.record($0) }, onChange: {})
    monitor.stop()
    await monitor.started?.value

    #expect(fake.stopped == 1)
}

/// FSEvents refuses a stream of no paths; with no folders to watch, there is nothing to start.
@Test func noFoldersStartNoWatch() async throws {
    let fake = FakeWatch()
    let monitor = AppFolderMonitor(
        folders: [], watch: fake.watch, failed: { Issue.record($0) }, onChange: {})
    await monitor.started?.value
    monitor.stop()

    #expect(fake.watches == 0)
    #expect(fake.stopped == 0)
}

private struct Refused: Error {}

@Test func aWatchThatWontStartIsReported() async throws {
    let failures = Failures()
    let monitor = AppFolderMonitor(
        folders: [URL(filePath: "/Applications")], watch: { _, _ in throw Refused() },
        failed: { failures.add($0) },
        onChange: {})
    await monitor.started?.value

    #expect(failures.count == 1)
}

private final class Failures: @unchecked Sendable {
    private let lock = NSLock()
    private var errors: [any Error] = []

    func add(_ error: any Error) { lock.withLock { errors.append(error) } }
    var count: Int { lock.withLock { errors.count } }
}

/// Rebuilds the index of the apps in one folder at each report of a monitor on it, and lets a
/// test wait for a build that passes a check.
private final class LiveIndex: Sendable {
    let monitor: AppFolderMonitor
    private let builds: AsyncStream<[String]>

    init(apps folder: URL) {
        let builder = IndexBuilder(
            apps: AppProvider(folders: [folder], languages: ["en"], extraApps: []),
            settingsPanes: SettingsPaneProvider(
                extensionFolders: [], preferencePaneFolders: [], languages: ["en"]))
        let (builds, feed) = AsyncStream.makeStream(of: [String].self)
        self.builds = builds
        monitor = AppFolderMonitor(
            folders: builder.watchedFolders, quiet: 0.05,
            failed: { Issue.record($0) },
            onChange: {
                Task {
                    do {
                        feed.yield(try await builder.build().items.map(\.id))
                    } catch {
                        Issue.record(error)
                    }
                }
            })
    }

    /// Whether a build passing `check` comes within `limit`. FSEvents latency is real time, so
    /// this waits on it, bounded.
    func builds(
        within limit: Duration = .seconds(10), where check: @escaping @Sendable ([String]) -> Bool
    ) async -> Bool {
        let builds = builds
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await ids in builds where check(ids) { return true }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: limit)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }
}

@Test func anAppAddedToAWatchedFolderIsIndexedAndRemovingItDropsIt() async throws {
    let folder = try TempFolder()
    let live = LiveIndex(apps: folder.url)
    defer { live.monitor.stop() }
    await live.monitor.started?.value

    let app = try makeApp("Fake", in: folder.url, id: "test.fake")
    #expect(await live.builds { $0.contains("test.fake") })

    try FileManager.default.removeItem(at: app)
    #expect(await live.builds { !$0.contains("test.fake") })
}

/// FSEvents matches changes by path, so a folder made after the watch starts is watched.
@Test func aFolderMadeAfterTheWatchStartsIsWatched() async throws {
    let root = try TempFolder()
    let folder = root.url.appending(path: "Apps", directoryHint: .isDirectory)
    let live = LiveIndex(apps: folder)
    defer { live.monitor.stop() }
    await live.monitor.started?.value

    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try makeApp("Fake", in: folder, id: "test.fake")

    #expect(await live.builds { $0.contains("test.fake") })
}

@Test func watchesTheAppAndPreferencePaneFolders() {
    let builder = IndexBuilder(
        apps: AppProvider(folders: [URL(filePath: "/A")], extraApps: []),
        settingsPanes: SettingsPaneProvider(
            extensionFolders: [URL(filePath: "/E")], preferencePaneFolders: [URL(filePath: "/P")]))
    #expect(builder.watchedFolders.map(\.path) == ["/A", "/P"])
}
