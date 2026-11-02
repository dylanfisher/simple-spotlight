import AppKit
import Testing

@testable import Interface

@MainActor @Test func copyPutsTheTextAloneOnThePasteboard() throws {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("simple-spotlight-\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }
    pasteboard.setString("old", forType: .rtf)
    let opener = WorkspaceOpener(pasteboard: pasteboard, reportError: { Issue.record($0) })

    opener.copy("2000")

    #expect(pasteboard.string(forType: .string) == "2000")
    #expect(pasteboard.data(forType: .rtf) == nil)
}

@MainActor @Test func revealingAFileThatIsGoneReportsIt() async {
    var errors: [String] = []
    let opener = WorkspaceOpener(reportError: { errors.append(String(describing: $0)) })
    let gone = URL(filePath: "/simple-spotlight-\(UUID().uuidString).app")

    opener.reveal(gone)
    await opener.revealed?.value

    #expect(errors.count == 1)
    #expect(errors.first?.contains(gone.path(percentEncoded: false)) == true)
}

/// A folder under the temporary directory for one test's scripts, removed when released.
private final class ScriptFolder {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "simple-spotlight-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// An executable `sh` script called `name` that runs `body`.
    func script(_ name: String, _ body: String) throws -> URL {
        let file = url.appendingPathComponent(name)
        try "#!/bin/sh\n\(body)\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        return file
    }

    deinit {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            Issue.record(error, "removing \(url.path)")
        }
    }
}

// These tests run a real child process, so each waits for its run to end. The opener's timeout
// bounds that wait: a script that hangs is stopped and reported.

/// A script runs in its own folder with the PATH launchd gives a GUI app, and success shows
/// nothing.
@MainActor @Test func aScriptThatExitsZeroRunsInItsFolderAndReportsNothing() async throws {
    let folder = try ScriptFolder()
    let script = try folder.script("path.sh", #"printf '%s' "$PATH" > ran"#)
    var errors: [String] = []
    let opener = WorkspaceOpener(
        scriptTimeout: 5, reportError: { errors.append(String(describing: $0)) })

    opener.run(script)
    await opener.ran?.value

    #expect(errors.isEmpty)
    let ran = try String(
        contentsOf: folder.url.appendingPathComponent("ran"), encoding: .utf8)
    #expect(ran == "/usr/bin:/bin:/usr/sbin:/sbin")
}

/// The script writes more than a pipe holds, so the run has to read stderr as it comes or the
/// script stalls until the timeout.
@MainActor @Test func aScriptThatFailsIsReportedWithItsCodeAndTheEndOfItsStderr() async throws {
    let folder = try ScriptFolder()
    let script = try folder.script(
        "fail.sh", "printf 'START%0200000d the end\\n' 0 >&2\nexit 3")
    var errors: [String] = []
    let opener = WorkspaceOpener(
        scriptTimeout: 5, reportError: { errors.append(String(describing: $0)) })

    opener.run(script)
    await opener.ran?.value

    #expect(errors.count == 1)
    let error = try #require(errors.first)
    #expect(error.contains(script.path))
    #expect(error.contains("code 3"))
    #expect(error.contains("0 the end"))
    #expect(!error.contains("START"))
    #expect(error.count < script.path.count + 600)
}

@MainActor @Test func aScriptThatCantBeLaunchedIsReported() async throws {
    let folder = try ScriptFolder()
    let gone = folder.url.appendingPathComponent("gone.sh")
    var errors: [String] = []
    let opener = WorkspaceOpener(
        scriptTimeout: 5, reportError: { errors.append(String(describing: $0)) })

    opener.run(gone)
    await opener.ran?.value

    #expect(errors.count == 1)
    #expect(errors.first?.contains(gone.path) == true)
}

/// `exec` makes `sleep` the script's own process, so the timeout's SIGTERM stops it and no
/// child outlives the test.
@MainActor @Test func aScriptThatRunsTooLongIsStoppedAndReported() async throws {
    let folder = try ScriptFolder()
    let script = try folder.script("sleep.sh", "exec sleep 30")
    var errors: [String] = []
    let opener = WorkspaceOpener(
        scriptTimeout: 0.05, reportError: { errors.append(String(describing: $0)) })

    opener.run(script)
    await opener.ran?.value

    #expect(errors.count == 1)
    #expect(errors.first?.contains(script.path) == true)
    #expect(errors.first?.contains("stopped") == true)
}
