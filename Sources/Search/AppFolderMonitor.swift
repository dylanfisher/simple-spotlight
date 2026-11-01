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
            paths: folders.map(\.path), latency: latency, onChange: onChange)
        return { watcher.stop() }
    }

    /// How long FSEvents batches changes before calling back: well under `quiet`, so the batches
    /// of one burst don't leave gaps that end it.
    public static let latency: TimeInterval = 0.25
    /// The pause that ends a burst: longer than the gaps between the writes of one copy.
    public static let quiet: TimeInterval = 1
    /// The longest a burst waits, so changes that never pause still rebuild every so often.
    public static let longest: TimeInterval = 10

    /// When a burst of changes is due to be reported.
    struct Burst: Equatable {
        /// Seconds of system uptime: macOS 12 has no `ContinuousClock`.
        typealias Instant = TimeInterval

        let quiet: TimeInterval
        let longest: TimeInterval
        private(set) var first: Instant?
        private(set) var last: Instant?

        init(quiet: TimeInterval, longest: TimeInterval) {
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
    private var starting: Task<Void, Never>?

    /// Starts watching `folders`, calling `onChange` at the end of each burst of changes. The
    /// watch starts off the caller's actor, since FSEvents looks the folders up on the disk;
    /// `failed` is told if it won't.
    public init(
        folders: [URL], quiet: TimeInterval = quiet, longest: TimeInterval = longest,
        watch: @escaping Watch = fileEvents, failed: @escaping @Sendable (any Error) -> Void,
        onChange: @escaping @Sendable () -> Void
    ) {
        self.onChange = onChange
        burst = Burst(quiet: quiet, longest: longest)
        // FSEvents refuses a stream of no paths, as when apps and panes are both turned off.
        guard !folders.isEmpty else { return }
        let start = Task.detached { [weak self] in
            let stop: @Sendable () -> Void
            do {
                stop = try watch(folders) { [weak self] in self?.changed() }
            } catch {
                failed(error)
                return
            }
            guard let self else {
                stop()
                return
            }
            let kept = lock.withLock {
                if !stopped { stopWatch = stop }
                return !stopped
            }
            if !kept { stop() }
        }
        lock.withLock { starting = start }
    }

    /// The start of the watch, for tests to wait on; nil when there was nothing to watch.
    var started: Task<Void, Never>? { lock.withLock { starting } }

    /// Stops watching, or the watch from starting. A burst under way is dropped.
    public func stop() {
        let stop = lock.withLock {
            stopped = true
            defer { stopWatch = nil }
            return stopWatch
        }
        stop?()
    }

    deinit { stop() }

    private static var now: Burst.Instant { ProcessInfo.processInfo.systemUptime }

    private func changed() {
        let began = lock.withLock { !stopped && burst.change(at: Self.now) }
        guard began else { return }
        Task { await self.reportWhenDue() }
    }

    /// Waits for the burst's deadline, which later changes move, then calls back.
    private func reportWhenDue() async {
        while true {
            guard let deadline = lock.withLock({ stopped ? nil : burst.deadline }) else { return }
            // Not cancellable: `stop` ends the wait at its next check instead.
            let wait = max(0, deadline - Self.now)
            try? await Task.sleep(nanoseconds: UInt64(wait * 1e9))
            let due = lock.withLock { !stopped && burst.report(at: Self.now) }
            if due {
                onChange()
                return
            }
        }
    }
}
