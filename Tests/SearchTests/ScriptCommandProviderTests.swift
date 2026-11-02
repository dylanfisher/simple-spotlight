import Foundation
import Testing

@testable import Search

/// Writes a script named `name` holding `text` into `folder`, executable unless `executable` is
/// false.
@discardableResult
func makeScript(
    _ name: String, in folder: URL, _ text: String = "#!/bin/sh\n", executable: Bool = true
) throws -> URL {
    let url = folder.appendingPathComponent(name)
    try Data(text.utf8).write(to: url)
    try FileManager.default.setAttributes(
        [.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: url.path)
    return url
}

@Test func makesARowForEachScript() throws {
    let folder = try TempFolder()
    let tv = try makeScript(
        "tv.sh", in: folder.url,
        "#!/bin/sh\n# @title TV\n# @subtitle Denon\n# @keywords hdmi1 tele\n")
    let lock = try makeScript("lock-screen.sh", in: folder.url)
    let found = try ScriptCommandProvider(folder: folder.url).items()
    #expect(found.problems.isEmpty)
    #expect(found.items.map(\.title) == ["lock-screen", "TV"])
    let item = try #require(found.items.last)
    #expect(item.id == SearchItem.builtInID("commands/tv.sh"))
    #expect(item.kind == .script)
    #expect(item.subtitle == "Denon")
    #expect(item.alternateNames == ["hdmi1", "tele"])
    #expect(item.target == .runScript(tv))
    #expect(found.items.first?.target == .runScript(lock))
    #expect(found.items.first?.subtitle == nil)
}

@Test func skipsDotfilesUnderscoreFilesAndSubfolders() throws {
    let folder = try TempFolder()
    try makeScript("tv.sh", in: folder.url)
    try makeScript(".hidden.sh", in: folder.url)
    try makeScript("_helper.sh", in: folder.url)
    let group = folder.url.appendingPathComponent("Living Room")
    try FileManager.default.createDirectory(at: group, withIntermediateDirectories: true)
    try makeScript("game.sh", in: group)
    let found = try ScriptCommandProvider(folder: folder.url).items()
    #expect(found.items.map(\.title) == ["tv"])
    #expect(found.problems.isEmpty)
}

/// Strict like the config file (plan decision 7): a file the app can't run, or a header it
/// can't read, is a problem rather than a row.
@Test func reportsAFileThatIsNotExecutableAndAnUnknownTag() throws {
    let folder = try TempFolder()
    try makeScript("tv.sh", in: folder.url)
    let plain = try makeScript("notes.sh", in: folder.url, executable: false)
    let tagged = try makeScript("game.sh", in: folder.url, "#!/bin/sh\n# @title Game\n# @icon x\n")
    let found = try ScriptCommandProvider(folder: folder.url).items()
    #expect(found.items.map(\.title) == ["tv"])
    #expect(
        found.problems == [
            IndexProblem(path: tagged.path, reason: "Line 3: unknown tag @icon."),
            IndexProblem(path: plain.path, reason: "It isn't executable; run chmod +x on it."),
        ])
}

/// Having the folder is how the feature is turned on, so a missing one is no problem.
@Test func findsNothingInAMissingFolder() throws {
    let root = try TempFolder()
    let found = try ScriptCommandProvider(folder: root.url.appendingPathComponent("commands"))
        .items()
    #expect(found.items.isEmpty)
    #expect(found.problems.isEmpty)
}

/// Holds the result of a scan run on another thread. The semaphore orders the write before the
/// read, so the unchecked conformance is safe.
private final class ScanResult: @unchecked Sendable {
    let done = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var value: (items: [SearchItem], problems: [IndexProblem])?
}

/// Opening a named pipe for reading blocks until a writer appears, so a scan that opens one
/// hangs. The scan runs on a background thread and the test waits on a semaphore for at most
/// 10 seconds; on timeout it opens the pipe for writing, which releases the blocked reader so
/// the thread doesn't outlive the test.
@Test func reportsAnExecutableNamedPipeWithoutOpeningIt() throws {
    let folder = try TempFolder()
    try makeScript("tv.sh", in: folder.url)
    let pipe = folder.url.appendingPathComponent("pipe.sh")
    try #require(mkfifo(pipe.path, 0o755) == 0)
    let result = ScanResult()
    let provider = ScriptCommandProvider(folder: folder.url)
    DispatchQueue.global().async {
        result.value = try? provider.items()
        result.done.signal()
    }
    let finished = result.done.wait(timeout: .now() + 10) == .success
    if !finished {
        let release = open(pipe.path, O_WRONLY | O_NONBLOCK)
        if release >= 0 { close(release) }
    }
    try #require(finished, "The scan blocked opening the pipe.")
    let found = try #require(result.value)
    #expect(found.items.map(\.title) == ["tv"])
    #expect(
        found.problems == [IndexProblem(path: pipe.path, reason: "It isn't a regular file.")])
}

@Test func followsASymlinkToAScriptAndSkipsOneToAFolder() throws {
    let folder = try TempFolder()
    let real = try makeScript("real.sh", in: folder.url)
    let group = folder.url.appendingPathComponent("group")
    try FileManager.default.createDirectory(at: group, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
        at: folder.url.appendingPathComponent("alias.sh"), withDestinationURL: real)
    try FileManager.default.createSymbolicLink(
        at: folder.url.appendingPathComponent("linked-group"), withDestinationURL: group)
    let found = try ScriptCommandProvider(folder: folder.url).items()
    #expect(found.items.map(\.title) == ["alias", "real"])
    #expect(found.problems.isEmpty)
}

@Test func reportsASymlinkThatPointsAtNothing() throws {
    let folder = try TempFolder()
    let link = folder.url.appendingPathComponent("gone.sh")
    try FileManager.default.createSymbolicLink(
        at: link, withDestinationURL: folder.url.appendingPathComponent("missing.sh"))
    let found = try ScriptCommandProvider(folder: folder.url).items()
    #expect(found.items.isEmpty)
    #expect(
        found.problems == [
            IndexProblem(path: link.path, reason: "It's a link that points at nothing.")
        ])
}
