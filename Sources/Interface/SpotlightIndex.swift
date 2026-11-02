import Foundation

/// Why macOS's Spotlight index couldn't be read or switched.
public enum SpotlightIndexError: Error, Equatable, Sendable {
    /// The user cancelled the administrator password prompt.
    case cancelled
    /// The command failed; the text says why, in its own words.
    case failed(String)
}

/// macOS's Spotlight index, which this app doesn't use: it reads the app folders itself. A
/// protocol so tests don't read or change the real index.
public protocol SpotlightIndexService: Sendable {
    /// Whether the startup volume is indexed.
    func isIndexing() async throws(SpotlightIndexError) -> Bool
    /// Turns indexing on or off on every volume, asking for an administrator's password.
    func setIndexing(_ on: Bool) async throws(SpotlightIndexError)
}

/// The index as `mdutil` reads and switches it (docs/decisions/0019-spotlight-indexing.md).
/// Reading needs no privileges; switching runs `mdutil -a -i` through osascript's
/// `with administrator privileges`, which shows macOS's password prompt.
public struct SpotlightIndex: SpotlightIndexService {
    static let mdutil = "/usr/bin/mdutil"
    static let osascript = "/usr/bin/osascript"
    /// The startup volume, whose status the pane shows.
    static let startupVolume = "/"
    /// osascript's error number when the user cancels the password prompt.
    static let userCanceled = "(-128)"

    public init() {}

    public func isIndexing() async throws(SpotlightIndexError) -> Bool {
        let run = try await Self.run(Self.mdutil, ["-s", Self.startupVolume])
        guard run.status == 0 else { throw .failed(run.message) }
        return try Self.isIndexing(status: run.output)
    }

    public func setIndexing(_ on: Bool) async throws(SpotlightIndexError) {
        let run = try await Self.run(Self.osascript, ["-e", Self.script(on)])
        guard run.status == 0 else {
            throw run.error.contains(Self.userCanceled) ? .cancelled : .failed(run.message)
        }
    }

    /// The AppleScript that runs `mdutil -a -i on|off` as root.
    static func script(_ on: Bool) -> String {
        "do shell script \"\(mdutil) -a -i \(on ? "on" : "off")\" with administrator privileges"
    }

    /// Whether `mdutil -s` says the volume is indexed: "Indexing enabled." or "Indexing
    /// disabled." (or "Indexing and searching disabled.") on the line under the volume's path.
    static func isIndexing(status output: String) throws(SpotlightIndexError) -> Bool {
        if output.contains("Indexing enabled.") { return true }
        if output.contains("disabled.") { return false }
        throw .failed("mdutil gave an unknown status: \(output.trimmed)")
    }

    struct Run {
        let status: Int32
        let output: String
        let error: String

        /// What to show when the run failed: stderr, else stdout, else the exit status.
        var message: String {
            let text = error.trimmed.isEmpty ? output.trimmed : error.trimmed
            return text.isEmpty ? "It exited with status \(status)." : text
        }
    }

    /// Runs the tool at `path` and waits for it to exit, off the main actor. Its output is a few
    /// lines, well under a pipe's buffer, so it is read once the tool has exited.
    @concurrent
    static func run(_ path: String, _ arguments: [String]) async throws(SpotlightIndexError) -> Run
    {
        let process = Process()
        process.executableURL = URL(filePath: path)
        process.arguments = arguments
        let output = Pipe()
        let error = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = error
        let result: Result<Run, SpotlightIndexError> = await withCheckedContinuation {
            continuation in
            process.terminationHandler = { process in
                let out = output.fileHandleForReading.readDataToEndOfFile()
                let err = error.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(
                    returning: .success(
                        Run(
                            status: process.terminationStatus,
                            output: String(decoding: out, as: UTF8.self),
                            error: String(decoding: err, as: UTF8.self))))
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(
                    returning: .failure(
                        .failed("\(path) couldn't start: \(error.localizedDescription)")))
            }
        }
        return try result.get()
    }
}

extension String {
    fileprivate var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
