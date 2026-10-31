import Foundation

/// Watches the folders the index reads and calls back once per burst of changes in them, so the
/// index can be rebuilt when an app is installed, updated or removed
/// (docs/decisions/0011-live-index.md).
///
/// A burst ends after `quiet` without a change, or `longest` after it began, whichever is first.
/// Copying or updating an app writes thousands of files inside its bundle over several seconds;
/// that is one burst, and the rebuild runs once the bundle is complete.
public final class AppFolderMonitor: @unchecked Sendable {
    /// Starts watching `folders`, calling `onChange` after each batch of changes in or under
    /// them, and returns what stops the watch.
    public typealias Watch =
        @Sendable (_ folders: [URL], _ onChange: @escaping @Sendable () -> Void) throws
        -> @Sendable () -> Void

    /// Watches through FSEvents, which also reports a folder created after the watch starts.
    public static let fileEvents: Watch = { folders, onChange in
        let watcher = try FolderWatcher(
            paths: folders.map(\.path), latency: .milliseconds(250), onChange: onChange)
        return { watcher.stop() }
    }

    /// The pause that ends a burst: longer than the gaps between the writes of one copy.
    public static let quiet: Duration = .seconds(1)
    /// The longest a burst waits, so changes that never pause still rebuild every so often.
    public static let longest: Duration = .seconds(10)

    /// When a burst of changes is due to be reported.
    struct Burst: Equatable {
        typealias Instant = ContinuousClock.Instant

        let quiet: Duration
        let longest: Duration
        private(set) var first: Instant?
        private(set) var last: Instant?

        init(quiet: Duration, longest: Duration) {
            self.quiet = quiet
            self.longest = longest
        }

        /// When the burst under way is reported; nil when none is.
        var deadline: Instant? {
            guard let first, let last else { return nil }
            return min(last + quiet, first + longest)
        }

        /// Takes a change at `now`, and returns whether it began a burst.
        mutating func change(at now: Instant) -> Bool {
            last = now
            guard first == nil else { return false }
            first = now
            return true
        }

        /// Ends the burst when it is due at `now`, and returns whether it was.
        mutating func report(at now: Instant) -> Bool {
            guard let deadline, now >= deadline else { return false }
            first = nil
            last = nil
            return true
        }
    }

    private let onChange: @Sendable () -> Void
    private let lock = NSLock()
    private var burst: Burst
    private var stopped = false
    private var stopWatch: (@Sendable () -> Void)?

    /// Starts watching `folders`, calling `onChange` at the end of each burst of changes.
    public init(
        folders: [URL], quiet: Duration = quiet, longest: Duration = longest,
        watch: Watch = fileEvents, onChange: @escaping @Sendable () -> Void
    ) throws {
        self.onChange = onChange
        burst = Burst(quiet: quiet, longest: longest)
        let stop = try watch(folders) { [weak self] in self?.changed() }
        lock.withLock { stopWatch = stop }
    }

    /// Stops watching. A burst under way is dropped.
    public func stop() {
        let stop = lock.withLock {
            stopped = true
            defer { stopWatch = nil }
            return stopWatch
        }
        stop?()
    }

    deinit { stop() }

    private func changed() {
        let began = lock.withLock { !stopped && burst.change(at: .now) }
        guard began else { return }
        Task { await self.reportWhenDue() }
    }

    /// Waits for the burst's deadline, which later changes move, then calls back.
    private func reportWhenDue() async {
        while true {
            guard let deadline = lock.withLock({ stopped ? nil : burst.deadline }) else { return }
            // Not cancellable: `stop` ends the wait at its next check instead.
            try? await Task.sleep(until: deadline, clock: .continuous)
            let due = lock.withLock { !stopped && burst.report(at: .now) }
            if due {
                onChange()
                return
            }
        }
    }
}
