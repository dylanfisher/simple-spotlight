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

/// Makes a folder named `name` in `folder`.
@discardableResult
private func makeFolder(_ name: String, in folder: URL) throws -> URL {
    let url = folder.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// The id of the script or group at `path` inside the commands folder.
private func commandID(_ path: String) -> String {
    SearchItem.builtInID("commands/\(path)")
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

/// Helpers such as a `_denon.sh` that each script sources are skipped in groups too.
@Test func skipsDotfilesAndUnderscoreFiles() throws {
    let folder = try TempFolder()
    try makeScript("tv.sh", in: folder.url)
    try makeScript(".hidden.sh", in: folder.url)
    try makeScript("_helper.sh", in: folder.url)
    let group = try makeFolder("Living Room", in: folder.url)
    try makeScript("game.sh", in: group)
    try makeScript("_denon.sh", in: group)
    try makeScript(".hidden.sh", in: group)
    try makeScript("hidden.sh", in: makeFolder(".git", in: folder.url))
    try makeScript("private.sh", in: makeFolder("_private", in: group))
    let found = try ScriptCommandProvider(folder: folder.url).items()
    #expect(found.items.map(\.title) == ["Living Room", "tv"])
    #expect(found.groups[commandID("Living Room")]?.map(\.title) == ["game"])
    #expect(found.groups.count == 1)
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
    nonisolated(unsafe) var value: ScriptCommandProvider.Tree?
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

/// FSEvents doesn't follow links, so a linked folder's changes wouldn't update the index; a link
/// back up the tree would also make the scan loop.
@Test func followsASymlinkToAScriptAndSkipsOneToAFolder() throws {
    let folder = try TempFolder()
    let real = try makeScript("real.sh", in: folder.url)
    let group = try makeFolder("group", in: folder.url)
    try FileManager.default.createSymbolicLink(
        at: folder.url.appendingPathComponent("alias.sh"), withDestinationURL: real)
    try FileManager.default.createSymbolicLink(
        at: folder.url.appendingPathComponent("linked-group"), withDestinationURL: group)
    try FileManager.default.createSymbolicLink(
        at: group.appendingPathComponent("loop"), withDestinationURL: folder.url)
    let found = try ScriptCommandProvider(folder: folder.url).items()
    #expect(found.items.map(\.title) == ["alias", "group", "real"])
    #expect(found.groups.keys.sorted() == [commandID("group")])
    #expect(found.groups[commandID("group")]?.isEmpty == true)
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

@Test func ordersNamesAsPeopleDo() throws {
    let folder = try TempFolder()
    for name in ["TV.sh", "lock-screen.sh", "Input 10.sh", "Input 2.sh", "apple.sh"] {
        try makeScript(name, in: folder.url)
    }
    let found = try ScriptCommandProvider(folder: folder.url).items()
    #expect(found.items.map(\.title) == ["apple", "Input 2", "Input 10", "lock-screen", "TV"])
}

@Test func makesARowForEachGroupAndItsCommandsNested() throws {
    let folder = try TempFolder()
    try makeScript("lock-screen.sh", in: folder.url)
    let room = try makeFolder("Living Room", in: folder.url)
    // Never run, so it needn't be executable.
    try makeScript(
        "_group", in: room, "# @title Denon\n# @subtitle Receiver\n# @keywords receiver avr\n",
        executable: false)
    let tv = try makeScript("tv.sh", in: room)
    try makeScript("power-off.sh", in: room)
    let inputs = try makeFolder("Inputs", in: room)
    let hdmi = try makeScript("hdmi.sh", in: inputs)
    try makeScript("desk.sh", in: makeFolder("Office", in: folder.url))
    let studio = try makeFolder("Studio 2.0", in: folder.url)
    try makeScript("_group", in: studio, "# @subtitle Upstairs\n")

    let found = try ScriptCommandProvider(folder: folder.url).items()
    #expect(found.problems.isEmpty)
    #expect(found.items.map(\.title) == ["Denon", "lock-screen", "Office", "Studio 2.0"])
    #expect(found.items.map(\.kind) == [.group, .script, .group, .group])
    let denon = found.items[0]
    #expect(denon.id == commandID("Living Room"))
    #expect(denon.target == .openGroup(commandID("Living Room")))
    #expect(denon.subtitle == "Receiver")
    #expect(denon.alternateNames == ["receiver", "avr"])
    #expect(found.items[2].subtitle == nil)
    #expect(found.items[3].subtitle == "Upstairs")

    #expect(
        Set(found.groups.keys)
            == Set(["Living Room", "Living Room/Inputs", "Office", "Studio 2.0"].map(commandID)))
    let inRoom = try #require(found.groups[commandID("Living Room")])
    #expect(inRoom.map(\.title) == ["Inputs", "power-off", "tv"])
    #expect(inRoom.map(\.kind) == [.group, .script, .script])
    #expect(inRoom[0].target == .openGroup(commandID("Living Room/Inputs")))
    #expect(inRoom[2].id == commandID("Living Room/tv.sh"))
    #expect(inRoom[2].target == .runScript(tv))
    let inInputs = try #require(found.groups[commandID("Living Room/Inputs")])
    #expect(inInputs.map(\.id) == [commandID("Living Room/Inputs/hdmi.sh")])
    #expect(inInputs.first?.target == .runScript(hdmi))
    #expect(found.groups[commandID("Office")]?.map(\.title) == ["desk"])
    #expect(found.groups[commandID("Studio 2.0")]?.isEmpty == true)
}

/// A `@top-level` row shows in its group and at the top level, with one id so their usage is
/// shared. At the top level its group's title is its subtitle, unless it has its own.
@Test func showsATopLevelChildAtTheTopWithItsGroupAsSubtitle() throws {
    let folder = try TempFolder()
    try makeScript("lock.sh", in: folder.url, "# @top-level\n")
    let room = try makeFolder("Living Room", in: folder.url)
    let game = try makeScript("game.sh", in: room, "# @title Game\n# @top-level\n")
    try makeScript("tv.sh", in: room, "# @top-level\n# @subtitle Input\n")
    try makeScript("power-off.sh", in: room)
    let inputs = try makeFolder("Inputs", in: room)
    try makeScript("_group", in: inputs, "# @top-level\n")
    try makeScript("hdmi.sh", in: inputs)

    let found = try ScriptCommandProvider(folder: folder.url).items()
    #expect(found.problems.isEmpty)
    #expect(found.items.map(\.title) == ["Living Room", "lock", "Game", "Inputs", "tv"])
    #expect(found.items.map(\.subtitle) == [nil, nil, "Living Room", "Living Room", "Input"])
    let top = found.items[2]
    let inRoom = try #require(found.groups[commandID("Living Room")])
    #expect(inRoom.map(\.title) == ["Game", "Inputs", "power-off", "tv"])
    let grouped = inRoom[0]
    #expect(top.id == commandID("Living Room/game.sh"))
    #expect(grouped.id == top.id)
    #expect(grouped.target == .runScript(game))
    #expect(top.target == grouped.target)
    #expect(grouped.subtitle == nil)
    #expect(found.items[3].target == .openGroup(commandID("Living Room/Inputs")))
}

/// Strict like the config file (plan decision 7): the header's error is a problem. The group
/// still shows, under its folder's name, so its commands stay reachable.
@Test func reportsABrokenGroupHeaderAndKeepsTheGroup() throws {
    let folder = try TempFolder()
    let room = try makeFolder("Living Room", in: folder.url)
    let header = try makeScript("_group", in: room, "# @title Denon\n# @icon x\n# @top-level\n")
    try makeScript("tv.sh", in: room)
    try makeFolder("Empty", in: folder.url)
    let found = try ScriptCommandProvider(folder: folder.url).items()
    #expect(
        found.problems == [IndexProblem(path: header.path, reason: "Line 2: unknown tag @icon.")])
    #expect(found.items.map(\.title) == ["Empty", "Living Room"])
    #expect(found.items.map(\.kind) == [.group, .group])
    #expect(found.groups[commandID("Living Room")]?.map(\.title) == ["tv"])
    #expect(found.groups[commandID("Empty")]?.isEmpty == true)
}

@Test func reportsAGroupHeaderThatIsAFolder() throws {
    let folder = try TempFolder()
    let room = try makeFolder("Living Room", in: folder.url)
    let header = try makeFolder("_group", in: room)
    let found = try ScriptCommandProvider(folder: folder.url).items()
    #expect(found.problems == [IndexProblem(path: header.path, reason: "It isn't a regular file.")])
    #expect(found.items.map(\.title) == ["Living Room"])
}
