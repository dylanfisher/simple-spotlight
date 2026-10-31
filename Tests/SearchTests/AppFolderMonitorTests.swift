import Foundation
import Testing

@testable import Search

/// How many reports a monitor's `Burst` makes for changes at `offsets` from a start, checking
/// its deadline before each change as the monitor's wait would.
private func reports(
    _ offsets: [Duration], quiet: Duration = AppFolderMonitor.quiet,
    longest: Duration = AppFolderMonitor.longest
) -> Int {
    let start = ContinuousClock.now
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
    let writes = (0..<1_000).map { Duration.milliseconds(5 * $0) }
    #expect(reports(writes) == 1)
}

@Test func aPauseLongerThanQuietEndsTheBurst() {
    #expect(reports([.zero, .milliseconds(900), .milliseconds(2_000)]) == 2)
}

@Test func changesThatNeverPauseReportEveryLongest() {
    let writes = (0..<250).map { Duration.milliseconds(100 * $0) }
    #expect(reports(writes) == 3)
}

@Test func aBurstIsDueQuietAfterItsLastChange() throws {
    let start = ContinuousClock.now
    var burst = AppFolderMonitor.Burst(quiet: .seconds(1), longest: .seconds(10))
    let began = burst.change(at: start)
    let continued = !burst.change(at: start + .milliseconds(500))
    #expect(began && continued)

    #expect(burst.deadline == start + .milliseconds(1_500))
    let early = burst.report(at: start + .milliseconds(1_499))
    let due = burst.report(at: start + .milliseconds(1_500))
    #expect(!early && due)
    #expect(burst.deadline == nil)
}

/// Records the stop of a watch, and keeps its callback for the test to call.
private final class FakeWatch: @unchecked Sendable {
    private let lock = NSLock()
    private var stops = 0
    private var callback: (@Sendable () -> Void)?

    var watch: AppFolderMonitor.Watch {
        { [self] _, onChange in
            lock.withLock { callback = onChange }
            return { [self] in lock.withLock { stops += 1 } }
        }
    }

    var stopped: Int { lock.withLock { stops } }
}

@Test func stopEndsTheWatch() throws {
    let fake = FakeWatch()
    let monitor = try AppFolderMonitor(folders: [], watch: fake.watch) {}

    monitor.stop()
    monitor.stop()

    #expect(fake.stopped == 1)
}

/// Rebuilds the index of the apps in one folder at each report of a monitor on it, and lets a
/// test wait for a build that passes a check.
private final class LiveIndex: Sendable {
    let monitor: AppFolderMonitor
    private let builds: AsyncStream<[String]>

    init(apps folder: URL) throws {
        let builder = IndexBuilder(
            apps: AppProvider(folders: [folder], languages: ["en"], extraApps: []),
            settingsPanes: SettingsPaneProvider(
                extensionFolders: [], preferencePaneFolders: [], languages: ["en"]))
        let (builds, feed) = AsyncStream.makeStream(of: [String].self)
        self.builds = builds
        monitor = try AppFolderMonitor(
            folders: builder.watchedFolders, quiet: .milliseconds(50)
        ) {
            Task {
                do {
                    feed.yield(try await builder.build().items.map(\.id))
                } catch {
                    Issue.record(error)
                }
            }
        }
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
    let live = try LiveIndex(apps: folder.url)
    defer { live.monitor.stop() }

    let app = try makeApp("Fake", in: folder.url, id: "test.fake")
    #expect(await live.builds { $0.contains("test.fake") })

    try FileManager.default.removeItem(at: app)
    #expect(await live.builds { !$0.contains("test.fake") })
}

/// FSEvents matches changes by path, so a folder made after the watch starts is watched.
@Test func aFolderMadeAfterTheWatchStartsIsWatched() async throws {
    let root = try TempFolder()
    let folder = root.url.appending(path: "Apps", directoryHint: .isDirectory)
    let live = try LiveIndex(apps: folder)
    defer { live.monitor.stop() }

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
