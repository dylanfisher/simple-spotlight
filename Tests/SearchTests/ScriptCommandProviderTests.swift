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
