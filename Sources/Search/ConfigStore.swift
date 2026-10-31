import Base
import Darwin
import Foundation

/// Reads the config file off the main actor, writes the default file where there is none, and
/// reads it again after each change in its folder, publishing the settings and what is wrong
/// with the file through `states` (docs/decisions/0006-config-file.md).
///
/// It watches the folder rather than the file, since an editor's atomic save replaces the
/// file. A read that finds the file gone or empty where the last read didn't is believed only
/// once a second read `confirmDelay` later still finds it so: an editor's save in place
/// truncates the file before writing it, and a sync tool may delete it and make it again.
public actor ConfigStore {
    /// What the app should use, and what to tell the user.
    public struct State: Equatable, Sendable {
        /// The file's settings as of its last good read; the defaults until one, and while there
        /// is no file.
        public let settings: Settings
        /// What is wrong with the file, or with reading, creating or watching it, in that order;
        /// empty when the file applies as it is.
        public let errors: [ConfigError]
    }

    /// Starts watching `folder`, calling `onChange` after each batch of changes in it, and
    /// returns what stops the watch.
    public typealias Watch =
        @Sendable (_ folder: URL, _ onChange: @escaping @Sendable () -> Void) throws
        -> @Sendable () -> Void
    /// Returns after the duration, or throws once cancelled.
    public typealias Sleep = @Sendable (Duration) async throws -> Void

    /// How long after a read that finds the file gone or empty the store reads it again before
    /// it believes it. A save in place and a delete and create each take a few milliseconds;
    /// a real deletion still shows at once to a person.
    public static let confirmDelay: Duration = .milliseconds(200)

    /// Watches a folder through FSEvents.
    public static let fileEvents: Watch = { folder, onChange in
        let watcher = try FolderWatcher(
            paths: [folder.path], latency: .milliseconds(100), onChange: onChange)
        return { watcher.stop() }
    }

    /// The folder the config file lives in for the user whose home folder is `home`.
    public static func standardFolder(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        HomePath.folder("~/.config/simple-spotlight", home: home)
    }

    public nonisolated let folder: URL
    public nonisolated let file: URL
    /// Each state that differs from the one before, the first read's first.
    public nonisolated let states: AsyncStream<State>
    private let feed: AsyncStream<State>.Continuation
    private let watch: Watch
    private let sleep: Sleep
    private var started = false
    private var stopWatch: (@Sendable () -> Void)?
    /// The read the settings and `readErrors` come from.
    private var lastRead: Read?
    private var settings = Settings()
    private var readErrors: [ConfigError] = []
    private var createError: ConfigError?
    private var watchError: ConfigError?
    private var published: State?
    /// The second read of a file found gone or empty, waiting for `confirmDelay`.
    private var confirming: Task<Void, Never>?

    private enum Read: Equatable {
        case missing
        case text(Data)
        case failed(ConfigError)

        /// Whether there is no file, or one of whitespace only: one the default file may take
        /// the place of.
        var isAbsent: Bool {
            switch self {
            case .missing: true
            case .text(let data): data.allSatisfy(ConfigText.isWhitespace)
            case .failed: false
            }
        }
    }

    /// A store of `ConfigFile.name` in `folder`, watched through `watch`, waiting through
    /// `sleep` before it believes a file gone or empty.
    public init(
        folder: URL, watch: @escaping Watch = fileEvents,
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) }
    ) {
        self.folder = folder
        file = folder.appending(path: ConfigFile.name)
        self.watch = watch
        self.sleep = sleep
        (states, feed) = AsyncStream.makeStream(of: State.self)
    }

    /// Reads the file, writing the default file first where there is none or it is empty,
    /// starts watching its folder, and returns the state, which `states` also gets. The file
    /// is read again once the watch has started, so a change between the two isn't missed.
    @discardableResult
    public func start() -> State {
        precondition(!started, "the config file is already watched")
        started = true
        var first = read()
        if first.isAbsent {
            do {
                try writeDefault(over: first)
            } catch {
                createError = error
            }
            first = read()
        }
        accept(first)
        do {
            stopWatch = try watch(folder) { [weak self] in
                Task { await self?.reload() }
            }
        } catch {
            watchError = ConfigError(
                line: nil, key: nil,
                reason: "isn't watched, so a change applies at the next launch: \(error)")
            publish()
        }
        reload()
        guard let published else { preconditionFailure("the first read published nothing") }
        return published
    }

    /// Stops watching and ends `states`.
    public func stop() {
        confirming?.cancel()
        confirming = nil
        stopWatch?()
        stopWatch = nil
        feed.finish()
    }

    /// Writes the default file where there is none or it is empty, as opening the config file
    /// needs, and returns the file to open. A file made meanwhile, as by an editor, is kept.
    public func makeDefaultFileIfMissing() throws(ConfigError) -> URL {
        let found = read()
        if case .failed(let error) = found { throw error }
        if found.isAbsent {
            try writeDefault(over: found)
            reload()
        }
        return file
    }

    /// Reads the file again and publishes what changed. A read that finds the file gone or
    /// empty where the last didn't waits for `confirm`; this read cancels one waiting.
    func reload() {
        confirming?.cancel()
        confirming = nil
        let read = read()
        guard read != lastRead else { return }
        if read.isAbsent, let lastRead, !lastRead.isAbsent {
            confirm()
            return
        }
        accept(read)
    }

    /// Reads the file again `confirmDelay` from now and takes what it finds then, unless a
    /// change in the folder reads it first.
    private func confirm() {
        let sleep = sleep
        confirming = Task {
            do {
                try await sleep(Self.confirmDelay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            confirming = nil
            accept(read())
        }
    }

    /// Takes `read` as the file's state: a good file's settings replace the settings, and a
    /// file with an error keeps them.
    private func accept(_ read: Read) {
        lastRead = read
        switch read {
        case .missing:
            settings = Settings()
            readErrors = []
        case .text(let data):
            createError = nil
            switch ConfigFile.parse(data) {
            case .settings(let parsed):
                settings = parsed
                readErrors = []
            case .failed(let errors):
                readErrors = errors
            }
        case .failed(let error):
            readErrors = [error]
        }
        publish()
    }

    /// Sends the state when it differs from the last one sent.
    private func publish() {
        let state = State(
            settings: settings,
            errors: readErrors + [createError, watchError].compactMap { $0 })
        guard state != published else { return }
        published = state
        feed.yield(state)
    }

    /// The file's bytes; `missing` when there is none. A link to nothing and a file that can't
    /// be read are errors with no line, and neither is written over.
    private func read() -> Read {
        do {
            return .text(try Data(contentsOf: file))
        } catch CocoaError.fileReadNoSuchFile {
            // Reading follows a link, so a link to nothing reads as no file.
            if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: file.path) {
                return .failed(
                    ConfigError(
                        line: nil, key: nil,
                        reason: "is a symbolic link to \(target), which doesn't exist"))
            }
            return .missing
        } catch {
            return .failed(
                ConfigError(
                    line: nil, key: nil, reason: "couldn't be read: \(error.localizedDescription)"))
        }
    }

    /// Writes `ConfigFile.defaultText` as the file, which `found`, a read just made, says is
    /// missing or empty. The text goes to a file beside it that is renamed into place. Where
    /// there was no file, the rename doesn't replace one made since (`RENAME_EXCL`); where it was
    /// empty, it replaces it only if it is still empty, which leaves the microseconds between
    /// that check and the rename.
    private func writeDefault(over found: Read) throws(ConfigError) {
        let files = FileManager.default
        let partial = folder.appending(path: ".\(ConfigFile.name).partial-\(UUID().uuidString)")
        do {
            try files.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(ConfigFile.defaultText.utf8).write(to: partial, options: .withoutOverwriting)
            let renamed: Int32
            if found == .missing {
                renamed = renamex_np(partial.path, file.path, UInt32(RENAME_EXCL))
            } else if read().isAbsent {
                renamed = rename(partial.path, file.path)
            } else {
                // Written meanwhile, by the user: that file stays.
                try files.removeItem(at: partial)
                return
            }
            guard renamed == 0 else {
                let code = POSIXErrorCode(rawValue: errno) ?? .EIO
                try files.removeItem(at: partial)
                // Made meanwhile, by the user: that file stays.
                if code == .EEXIST { return }
                throw POSIXError(code)
            }
        } catch {
            var reason = "couldn't be created: \(error.localizedDescription)"
            if files.fileExists(atPath: partial.path) {
                do {
                    try files.removeItem(at: partial)
                } catch let cleanup {
                    reason += "; removing \(partial.path) then failed: \(cleanup)"
                }
            }
            throw ConfigError(line: nil, key: nil, reason: reason)
        }
    }
}
