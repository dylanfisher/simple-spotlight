import Foundation

/// One run of a script command: it runs in its own folder with no stdin and the PATH launchd
/// gives a GUI app, and is stopped with SIGTERM if it runs past its timeout. Its stdout is
/// dropped, and its stderr is read as it comes, so a script that writes a lot can't fill the
/// pipe and stall, and only the end is kept, for the report.
///
/// `@unchecked Sendable` because every stored property that changes is read and written only
/// on `queue`.
final class ScriptRun: @unchecked Sendable {
    /// What a script gets as PATH: the one launchd gives a GUI app, not the user's shell PATH,
    /// so a script behaves the same however the app was started.
    static let path = "/usr/bin:/bin:/usr/sbin:/sbin"
    /// How many bytes from the end of stderr a failure report quotes.
    static let stderrTail = 500

    private let url: URL
    private let timeout: TimeInterval
    private let process = Process()
    private let stderr = Pipe()
    private let queue = DispatchQueue(label: "simple-spotlight.script-run")
    private var tail = Data()
    /// Why stderr stopped being read before its end, if it did.
    private var readFailure: String?
    private var source: DispatchSourceRead?
    /// Resumed once, with the run's failure or nil; nil after that.
    private var continuation: CheckedContinuation<OpenerError?, Never>?

    private init(url: URL, timeout: TimeInterval) {
        self.url = url
        self.timeout = timeout
    }

    /// Runs the script at `url` and returns what went wrong: it couldn't start, it exited
    /// with a code other than 0, a signal stopped it, or it ran past `timeout` seconds. Nil when
    /// it exited 0. A timeout returns as the SIGTERM is sent, without waiting for the exit.
    @concurrent
    static func failure(running url: URL, timeout: TimeInterval) async -> OpenerError? {
        let run = ScriptRun(url: url, timeout: timeout)
        return await withCheckedContinuation { continuation in
            run.queue.async { run.start(continuation) }
        }
    }

    private func start(_ continuation: CheckedContinuation<OpenerError?, Never>) {
        self.continuation = continuation
        process.executableURL = url
        process.currentDirectoryURL = url.deletingLastPathComponent()
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = Self.path
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderr
        process.terminationHandler = { [self] _ in queue.async { self.exited() } }
        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            finish(
                OpenerError(description: "couldn't run \(url.path): \(error.localizedDescription)"))
            return
        }
        let descriptor = stderr.fileHandleForReading.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags != -1, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) != -1 else {
            let reason = String(cString: strerror(errno))
            process.terminate()
            finish(OpenerError(description: "couldn't read \(url.path)'s stderr: \(reason)"))
            return
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [self] in readStderr() }
        source.resume()
        self.source = source
        queue.asyncAfter(deadline: .now() + timeout) { [self] in
            guard self.continuation != nil else { return }
            process.terminate()
            finish(
                OpenerError(
                    description:
                        "\(url.path) didn't finish within \(timeout.formatted()) seconds, so it was stopped"
                ))
        }
    }

    /// Reads what stderr holds now, keeping the last `stderrTail` bytes. The descriptor is
    /// non-blocking, so this returns when the pipe is empty.
    private func readStderr() {
        let descriptor = stderr.fileHandleForReading.fileDescriptor
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count > 0 {
                tail.append(contentsOf: buffer[..<count])
                if tail.count > Self.stderrTail { tail = Data(tail.suffix(Self.stderrTail)) }
            } else if count < 0, errno == EINTR {
                continue
            } else {
                if count < 0, errno != EAGAIN { readFailure = String(cString: strerror(errno)) }
                // At the end, or after an error, the source would fire again at once.
                if count == 0 || readFailure != nil {
                    source?.cancel()
                    source = nil
                }
                return
            }
        }
    }

    /// The script exited. What it wrote before exiting is in the pipe, so one last read gets
    /// it even if the source hasn't fired for it yet.
    private func exited() {
        process.terminationHandler = nil
        if source != nil { readStderr() }
        source?.cancel()
        source = nil
        guard continuation != nil else { return }
        let status = process.terminationStatus
        switch process.terminationReason {
        case .exit where status == 0:
            finish(nil)
        case .exit:
            finish(OpenerError(description: "\(url.path) exited with code \(status)\(details)"))
        case .uncaughtSignal:
            finish(
                OpenerError(description: "\(url.path) was stopped by signal \(status)\(details)"))
        @unknown default:
            finish(OpenerError(description: "\(url.path) ended in a way the app doesn't know"))
        }
    }

    /// The end of stderr after a colon, or nothing when it was empty and read to its end.
    private var details: String {
        // The cut can land inside a character; its leftover continuation bytes are dropped.
        let start = tail.firstIndex { $0 & 0xC0 != 0x80 } ?? tail.endIndex
        let text = String(decoding: tail[start...], as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = [text, readFailure.map { "(couldn't read the rest of its stderr: \($0))" }]
            .compactMap { $0 }.filter { !$0.isEmpty }
        return lines.isEmpty ? "" : ":\n" + lines.joined(separator: "\n")
    }

    private func finish(_ failure: OpenerError?) {
        continuation?.resume(returning: failure)
        continuation = nil
    }
}
