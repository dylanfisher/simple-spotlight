import Base
import Testing

private func parse(_ text: String, file: String = "tv.sh") -> ScriptHeader {
    ScriptHeader.parse(Array(text.utf8), fileName: file)
}

@Test func readsEachTag() {
    let header = parse(
        "# @title Living Room TV\n# @subtitle Denon\n# @keywords receiver  avr\n# @top-level\n")
    #expect(header.title == "Living Room TV")
    #expect(header.subtitle == "Denon")
    #expect(header.keywords == ["receiver", "avr"])
    #expect(header.isTopLevel)
    #expect(header.errors.isEmpty)
}

@Test func missingTitleIsTheFileNameWithoutItsExtension() {
    let header = parse("#!/bin/sh\necho hi\n", file: "power-off.sh")
    #expect(header.title == "power-off")
    #expect(header.subtitle == nil)
    #expect(header.keywords.isEmpty)
    #expect(!header.isTopLevel)
    #expect(header.errors.isEmpty)
}

@Test func readsBothCommentStyles() {
    let header = parse("// @title Slash\n//@subtitle Tight\n#@keywords a b\n")
    #expect(header.title == "Slash")
    #expect(header.subtitle == "Tight")
    #expect(header.keywords == ["a", "b"])
}

@Test func shebangAndPlainCommentsDoNotEndTheHeader() {
    let header = parse("#!/bin/sh\n# Turns the TV on.\n\n// note\n# @title TV\nrun\n")
    #expect(header.title == "TV")
    #expect(header.errors.isEmpty)
}

@Test func unknownTagIsAnErrorWithItsLine() {
    let header = parse("#!/bin/sh\n# @title TV\n# @colour red\n")
    #expect(header.title == "TV")
    #expect(header.errors.map(\.line) == [3])
    #expect(header.errors.first?.message.contains("@colour") == true)
}

@Test func repeatedTagIsAnErrorAndKeepsTheFirst() {
    let header = parse("# @title One\n# @title Two\n")
    #expect(header.title == "One")
    #expect(header.errors.map(\.line) == [2])
}

@Test func valueOnTopLevelIsAnError() {
    let header = parse("# @top-level yes\n")
    #expect(header.errors.map(\.line) == [1])
}

@Test func emptyValueIsAnError() {
    let header = parse("# @title\n# @keywords \n")
    #expect(header.title == "tv")
    #expect(header.errors.map(\.line) == [1, 2])
}

@Test func tagsAfterTheFirstOtherLineAreIgnored() {
    let header = parse("# @title TV\necho hi\n# @subtitle Late\n# @bogus\n")
    #expect(header.title == "TV")
    #expect(header.subtitle == nil)
    #expect(header.errors.isEmpty)
}

@Test func readsWindowsLineEndings() {
    let header = parse("#!/bin/sh\r\n# @title TV\r\n# @keywords a b\r\n# @top-level\r\n")
    #expect(header.title == "TV")
    #expect(header.keywords == ["a", "b"])
    #expect(header.isTopLevel)
    #expect(header.errors.isEmpty)
}

@Test func cutsTheHeaderOffAtFourKilobytes() {
    let filler = String(repeating: "# filler\n", count: ScriptHeader.readLimit / 9)
    let header = parse(filler + "# @title Late\n")
    #expect(header.title == "tv")
    #expect(header.errors.isEmpty)
    // A tag line that straddles the cut is dropped, not read half-way.
    let straddle =
        String(repeating: "#", count: ScriptHeader.readLimit - 8) + "\n# @title Cut Off Here\n"
    #expect(parse(straddle).title == "tv")
    // A tag just inside the limit is read.
    let inside = parse("# @title In\n" + String(repeating: "#", count: 100))
    #expect(inside.title == "In")
}
