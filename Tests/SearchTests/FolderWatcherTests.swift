import Foundation
import Testing

@testable import Search

/// Counts a watcher's callbacks, and lets a test wait for the next one.
private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    let stream: AsyncStream<Void>
    private let feed: AsyncStream<Void>.Continuation

    init() {
        (stream, feed) = AsyncStream.makeStream()
    }

    func record() {
        lock.withLock { count += 1 }
        feed.yield()
    }

    var total: Int { lock.withLock { count } }
}

/// Whether `calls` reports one within `limit`. FSEvents latency is real time, so this waits on
/// it, bounded.
private func called(_ calls: Calls, within limit: Duration = .seconds(10)) async -> Bool {
    let stream = calls.stream
    return await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            for await _ in stream { return true }
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

@Test func reportsAChangeInTheFolder() async throws {
    let folder = try TempFolder()
    let calls = Calls()
    let watcher = try FolderWatcher(paths: [folder.url.path], latency: 0.05) {
        calls.record()
    }
    defer { watcher.stop() }
    try Data("x".utf8).write(to: folder.url.appending(path: "file"))
    #expect(await called(calls))
}

/// A group of script commands is a subfolder of the watched commands folder.
@Test func reportsAChangeInASubfolder() async throws {
    let folder = try TempFolder()
    let nested = folder.url.appendingPathComponent("Living Room/Inputs")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    let calls = Calls()
    let watcher = try FolderWatcher(paths: [folder.url.path], latency: .milliseconds(50)) {
        calls.record()
    }
    defer { watcher.stop() }
    try Data("x".utf8).write(to: nested.appendingPathComponent("tv.sh"))
    #expect(await called(calls))
}

/// Proving no callback comes needs a wait; a second watcher started before the stopped one's
/// changes is waited on twice, which gives the stopped one's queue at least as long.
@Test func reportsNothingOnceStopped() async throws {
    let folder = try TempFolder()
    let stoppedCalls = Calls()
    let liveCalls = Calls()
    let stopped = try FolderWatcher(paths: [folder.url.path], latency: 0.05) {
        stoppedCalls.record()
    }
    let live = try FolderWatcher(paths: [folder.url.path], latency: 0.05) {
        liveCalls.record()
    }
    defer { live.stop() }
    stopped.stop()
    try Data("x".utf8).write(to: folder.url.appending(path: "one"))
    #expect(await called(liveCalls))
    try Data("x".utf8).write(to: folder.url.appending(path: "two"))
    #expect(await called(liveCalls))
    #expect(stoppedCalls.total == 0)
}
