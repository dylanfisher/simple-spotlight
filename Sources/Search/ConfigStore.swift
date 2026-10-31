import Base
import Darwin
import Foundation

/// Reads the config file off the main actor, writes the default file where there is none, and
/// reads it again after each change in its folder, publishing the settings and what is wrong
/// with the file through `states` (docs/decisions/0006-config-file.md).
///
/// It watches the folder rather than the file, since an editor's atomic save replaces the
/// file; when the file is a symbolic link, as dotfiles often are, it also watches the folder of
/// the file the link leads to. A read that finds the file gone or empty is believed only once a
/// second read `confirmDelay` later still finds it so: an editor's save in place truncates the
/// file before writing it, and a sync tool may delete it and make it again.
public actor ConfigStore {
    /// What the app should use, and what to tell the user.
    public struct State: Equatable, Sendable {
        /// The file's settings as of its last good read; the defaults until one, and while there
        /// is no file.
        public let settings: Settings
        /// What is wrong with the file, or with reading, creating or watching it, in that order;
        /// empty when the file applies as it is.
        public let errors: [ConfigError]
        /// Whether the file is there but sets nothing, as it has an error or can't be read.
        /// `update` refuses to change it then, since the user is fixing it.
        public let isFileBroken: Bool

        public init(settings: Settings, errors: [ConfigError], isFileBroken: Bool) {
            self.settings = settings
            self.errors = errors
            self.isFileBroken = isFileBroken
        }
    }

    /// Starts watching `folder`, calling `onChange` after each batch of changes in it, and
    /// returns what stops the watch.
    public typealias Watch =
        @Sendable (_ folder: URL, _ onChange: @escaping @Sendable () -> Void) throws
        -> @Sendable () -> Void
    /// Returns after the duration, or throws once cancelled.
    public typealias Sleep = @Sendable (Duration) async throws -> Void

    /// How many times `update` makes its change to the file's text before it gives up, when the
    /// file changes under each try.
    static let attempts = 3

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
        home: URL = HomePath.current
    ) -> URL {
        HomePath.folder("~/.config/\(AppSlug.value)", home: home)
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
    /// The watch of the folder a link at the file's path leads into, when that is elsewhere.
    private var targetWatch: (folder: URL, stop: @Sendable () -> Void)?
    private var targetWatchError: ConfigError?
    private var published: State?
    /// The second read of a file found gone or empty, waiting for `confirmDelay`.
    private var confirming: Task<Void, Never>?

    enum Read: Equatable {
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
    public func start() async -> State {
        precondition(!started, "the config file is already watched")
        started = true
        var first = await settled(read())
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
            watchError = Self.unwatched(error)
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
        targetWatch?.stop()
        targetWatch = nil
        feed.finish()
    }

    /// Writes the default file where there is none or it is empty, as opening the config file
    /// needs, and returns the file to open. A file made meanwhile, as by an editor, is kept.
    public func makeDefaultFileIfMissing() async throws(ConfigError) -> URL {
        let found = await settled(read())
        if case .failed(let error) = found { throw error }
        if found.isAbsent {
            try writeDefault(over: found)
            reload()
        }
        return file
    }

    /// Writes what `change` does to the file's settings into the file, keeping its comments,
    /// spacing and key order (`ConfigFile.changing`), and reads it again, so `states` has the
    /// change before this returns. With no file, or an empty one, the default file is the text
    /// changed. A file with an error, or one that can't be read, is left alone and the error
    /// thrown. The text is written through a link at the file's path, as the default file is,
    /// and replaces the file only if it still has the bytes the change was made to; when it
    /// doesn't, as when an editor saved meanwhile, the change is made again to the new bytes.
    public func update(_ change: @Sendable (inout Settings) -> Void) throws(ConfigError) {
        for _ in 0..<Self.attempts {
            let found = read()
            let text: Data
            switch found {
            case .failed(let error): throw error
            case .missing: text = Data(ConfigFile.defaultText.utf8)
            case .text(let data): text = found.isAbsent ? Data(ConfigFile.defaultText.utf8) : data
            }
            guard let changed = try ConfigFile.changing(text, change) else { return }
            if try replace(found, with: changed, failing: "couldn't be changed") {
                reload()
                return
            }
        }
        throw ConfigError(
            reason: "couldn't be changed: it changed under each of \(Self.attempts) tries")
    }

    /// Reads the file again and publishes what changed. A read that finds the file gone or
    /// empty where the last didn't waits for `confirm`; this read cancels one waiting.
    func reload() {
        confirming?.cancel()
        confirming = nil
        followLink()
        let read = read()
        guard read != lastRead else { return }
        if read.isAbsent, let lastRead, !lastRead.isAbsent {
            confirm()
            return
        }
        accept(read)
    }

    /// `found`, or when it is an empty file, what a read `confirmDelay` later finds, so a save in
    /// place that has emptied the file but not yet written it isn't taken for an empty file.
    private func settled(_ found: Read) async -> Read {
        guard case .text = found, found.isAbsent else { return found }
        do {
            try await sleep(Self.confirmDelay)
        } catch {
            return .failed(ConfigError(reason: "wasn't read: \(error)"))
        }
        return read()
    }

    /// Watches the folder of the file a link at the file's path leads to, when that isn't the
    /// store's own folder, and stops watching one the link no longer leads into.
    private func followLink() {
        guard started, stopWatch != nil else { return }
        let own = Self.realPath(folder) ?? folder
        let wanted = linkTarget().map { $0.deletingLastPathComponent() }
            .flatMap { $0.path == own.path ? nil : $0 }
        guard wanted?.path != targetWatch?.folder.path else { return }
        targetWatch?.stop()
        targetWatch = nil
        targetWatchError = nil
        if let wanted {
            do {
                let stop = try watch(wanted) { [weak self] in
                    Task { await self?.reload() }
                }
                targetWatch = (wanted, stop)
            } catch {
                targetWatchError = Self.unwatched(error)
            }
        }
        publish()
    }

    private static func unwatched(_ error: any Error) -> ConfigError {
        ConfigError(reason: "isn't watched, so a change applies at the next launch: \(error)")
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
            errors: readErrors + [createError, watchError, targetWatchError].compactMap { $0 },
            isFileBroken: !readErrors.isEmpty)
        guard state != published else { return }
        published = state
        feed.yield(state)
    }

    /// The file's bytes, through a link at its path, up to one byte more than
    /// `ConfigFile.largestSize` so a file too large is refused without reading it whole;
    /// `missing` when there is none. A link to nothing and a file that can't be read are errors
    /// with no line, and neither is written over.
    func read() -> Read {
        var info = stat()
        guard lstat(file.path, &info) == 0 else {
            let code = errno
            if code == ENOENT { return .missing }
            return .failed(
                ConfigError(reason: "couldn't be read: \(String(cString: strerror(code)))"))
        }
        if info.st_mode & S_IFMT == S_IFLNK, linkTarget() == nil {
            let destination: String
            do {
                destination = try FileManager.default.destinationOfSymbolicLink(atPath: file.path)
            } catch {
                return .failed(
                    ConfigError(reason: "couldn't be read: \(error.localizedDescription)"))
            }
            return .failed(
                ConfigError(
                    reason: "is a symbolic link to \(destination), which doesn't lead to a file"))
        }
        do {
            let handle = try FileHandle(forReadingFrom: file)
            let data = try handle.read(upToCount: ConfigFile.largestSize + 1) ?? Data()
            try handle.close()
            return .text(data)
        } catch CocoaError.fileReadNoSuchFile {
            return .missing
        } catch {
            return .failed(ConfigError(reason: "couldn't be read: \(error.localizedDescription)"))
        }
    }

    /// The file a symbolic link at the file's path leads to, through any links after it; nil
    /// when the path isn't a link, or it leads to nothing.
    private func linkTarget() -> URL? {
        var info = stat()
        guard lstat(file.path, &info) == 0, info.st_mode & S_IFMT == S_IFLNK else { return nil }
        return Self.realPath(file)
    }

    /// `url` with every symbolic link in it followed; nil when it leads to nothing.
    private static func realPath(_ url: URL) -> URL? {
        guard let resolved = realpath(url.path, nil) else { return nil }
        defer { free(resolved) }
        return URL(filePath: String(cString: resolved))
    }

    /// Writes `ConfigFile.defaultText` as the file, which `found`, a read just made, says is
    /// missing or empty. A file written meanwhile, by the user, stays.
    func writeDefault(over found: Read) throws(ConfigError) {
        _ = try replace(
            found, with: Data(ConfigFile.defaultText.utf8), failing: "couldn't be created")
    }

    /// Writes `data` as the file in place of `found`, a read just made, and returns whether it
    /// did; false when the file is no longer `found`. A symbolic link at the file's path stays:
    /// the text goes to the file it leads to. The text is written beside its destination, with
    /// the destination's permissions, and renamed into place. Where there was no file, the
    /// rename doesn't replace one made since (`RENAME_EXCL`); otherwise it replaces the file
    /// only if it still has `found`'s bytes, which leaves the microseconds between that check
    /// and the rename. A failure is an error whose reason starts with `failing`.
    private func replace(_ found: Read, with data: Data, failing: String) throws(ConfigError)
        -> Bool
    {
        let files = FileManager.default
        let link = linkTarget()
        let destination = link ?? file
        let partial = destination.deletingLastPathComponent()
            .appending(path: ".\(destination.lastPathComponent).partial-\(UUID().uuidString)")
        do {
            if link == nil {
                try files.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            try data.write(to: partial, options: .withoutOverwriting)
            var info = stat()
            if stat(destination.path, &info) == 0 {
                guard chmod(partial.path, info.st_mode & 0o7777) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
            let renamed: Int32
            if found == .missing {
                renamed = renamex_np(partial.path, destination.path, UInt32(RENAME_EXCL))
            } else if read() == found, linkTarget() == link {
                renamed = rename(partial.path, destination.path)
            } else {
                try files.removeItem(at: partial)
                return false
            }
            guard renamed == 0 else {
                let code = POSIXErrorCode(rawValue: errno) ?? .EIO
                try files.removeItem(at: partial)
                if code == .EEXIST { return false }
                throw POSIXError(code)
            }
            return true
        } catch {
            var reason = "\(failing): \(error.localizedDescription)"
            if files.fileExists(atPath: partial.path) {
                do {
                    try files.removeItem(at: partial)
                } catch let cleanup {
                    reason += "; removing \(partial.path) then failed: \(cleanup)"
                }
            }
            throw ConfigError(reason: reason)
        }
    }
}
