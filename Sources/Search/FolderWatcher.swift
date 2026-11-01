import CoreServices
import Foundation

/// Calls back after each batch of changes in or under some folders, through one FSEvents
/// stream, which costs no file descriptor. FSEvents matches each change by its path, so a
/// folder that doesn't exist yet is watched too, and a file replaced by an atomic save, which
/// a watch of the file itself would lose, is a change in its folder.
public final class FolderWatcher: @unchecked Sendable {
    /// What the C callback reaches through its context pointer.
    private final class Receiver: @unchecked Sendable {
        let onChange: @Sendable () -> Void
        let lock = NSLock()
        var stopped = false

        init(onChange: @escaping @Sendable () -> Void) {
            self.onChange = onChange
        }

        func deliver() {
            let live = lock.withLock { !stopped }
            if live { onChange() }
        }
    }

    /// The system wouldn't start the stream; FSEvents gives no reason.
    public struct StartFailed: Error, CustomStringConvertible {
        public let paths: [String]

        public var description: String {
            "FSEvents wouldn't watch \(paths.joined(separator: ", "))"
        }
    }

    private let stream: FSEventStreamRef
    private let receiver: Receiver
    private let lock = NSLock()
    private var stopped = false

    /// Starts watching `paths`, calling `onChange` on a serial queue after each batch of
    /// changes, the changes of `latency` batched together. The first change after a quiet
    /// period is reported at once.
    public init(
        paths: [String], latency: TimeInterval, onChange: @escaping @Sendable () -> Void
    ) throws(StartFailed) {
        let receiver = Receiver(onChange: onChange)
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passRetained(receiver).toOpaque(),
            retain: nil, release: { Unmanaged<Receiver>.fromOpaque($0!).release() },
            copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            Unmanaged<Receiver>.fromOpaque(info!).takeUnretainedValue().deliver()
        }
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot
                | kFSEventStreamCreateFlagNoDefer)
        guard
            let stream = FSEventStreamCreate(
                nil, callback, &context, paths as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags)
        else {
            // Creating the stream failed before it took ownership of the receiver.
            Unmanaged.passUnretained(receiver).release()
            throw StartFailed(paths: paths)
        }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue(label: "FolderWatcher"))
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            throw StartFailed(paths: paths)
        }
        self.stream = stream
        self.receiver = receiver
    }

    /// Stops the stream. A callback already running may finish, and none starts after.
    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        if stopped { return }
        stopped = true
        receiver.lock.withLock { receiver.stopped = true }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    deinit { stop() }
}
