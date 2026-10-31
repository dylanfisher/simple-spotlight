import Base
import Testing

/// `text` with its comments and trailing commas blanked, or the unclosed comment's line.
private func plain(_ text: String) -> Result<String, ConfigText.UnclosedComment> {
    ConfigText.blankingComments(Array(text.utf8)).map {
        String(decoding: ConfigText.blankingTrailingCommas($0), as: UTF8.self)
    }
}

private func spaces(_ count: Int) -> String { String(repeating: " ", count: count) }

@Test func blanksLineAndBlockCommentsKeepingOffsets() throws {
    let text = "{ // one\n  /* two\n three */ \"a\": 1 }"
    let blanked = try plain(text).get()
    #expect(blanked == "{" + spaces(7) + "\n" + spaces(8) + "\n" + spaces(9) + " \"a\": 1 }")
    #expect(blanked.utf8.count == text.utf8.count)
}

@Test func leavesCommentMarkersInStringsAlone() throws {
    let text = #"{"url": "http://x/*y*/", "q": "a\"//b"}"#
    #expect(try plain(text).get() == text)
}

@Test func blanksTrailingCommasOnly() throws {
    #expect(try plain("[1, 2,]").get() == "[1, 2 ]")
    #expect(try plain("{\"a\": [1,],\n}").get() == "{\"a\": [1 ] \n}")
    #expect(try plain("{\"a\": \",\",}").get() == "{\"a\": \",\" }")
    // No item before the comma: left for the parser to refuse.
    #expect(try plain("{,}").get() == "{,}")
    #expect(try plain("[,]").get() == "[,]")
}

@Test func blanksACommaBeforeAComment() throws {
    #expect(try plain("[1, // last\n]").get() == "[1" + spaces(9) + "\n]")
}

@Test func reportsAnUnclosedBlockCommentsLine() {
    let error = #expect(throws: ConfigText.UnclosedComment.self) {
        try plain("{\n\n /* open\n").get()
    }
    #expect(error?.line == 3)
}

@Test func keepsCarriageReturnsInComments() throws {
    #expect(try plain("{ // a\r\n}").get() == "{     \r\n}")
}

@Test func countsEachKindOfLineBreakOnce() {
    let bytes = Array("a\nb\r\nc\rd".utf8)
    #expect(ConfigText.line(at: 0, in: bytes) == 1)
    #expect(ConfigText.line(at: 2, in: bytes) == 2)
    #expect(ConfigText.line(at: 5, in: bytes) == 3)
    #expect(ConfigText.line(at: 7, in: bytes) == 4)
}

@Test func endsALineCommentAtALoneCarriageReturn() throws {
    #expect(try plain("[1, // a\r2]").get() == "[1," + spaces(5) + "\r2]")
    let error = #expect(throws: ConfigText.UnclosedComment.self) {
        try plain("{\r\r /* open\r").get()
    }
    #expect(error?.line == 3)
}

// MARK: Editing

private func scanned(_ text: String) throws -> ConfigText.Object {
    try ConfigText.scan(Array(text.utf8))
}

/// `text` with the top-level key `name`'s value made `value`, or the key put in with `comment`
/// above it when the text doesn't have it.
private func setting(_ name: String, to value: String, comment: [String] = [], in text: String)
    throws -> String
{
    let bytes = Array(text.utf8)
    let root = try ConfigText.scan(bytes)
    let edited =
        root.member(name).map { ConfigText.replacing($0, with: value, in: bytes) }
        ?? ConfigText.inserting(
            "\"\(name)\": \(value)", comment: comment, into: root, in: bytes)
    return String(decoding: edited, as: UTF8.self)
}

@Test func scanFindsEachTopLevelKeyAndItsValue() throws {
    let text = """
        {
          // "fake": 1,
          "a": [1, {"b": "]"}], /* "c": 2 */
          "d\\u0065": "x",
        }
        """
    let root = try scanned(text)
    #expect(root.members.map(\.name) == ["a", "de"])
    let bytes = Array(text.utf8)
    let values = root.members.map {
        String(decoding: bytes[$0.valueStart..<$0.valueEnd], as: UTF8.self)
    }
    #expect(values == [#"[1, {"b": "]"}]"#, #""x""#])
    #expect(root.members.allSatisfy { $0.comma != nil })
}

@Test func scanRefusesTextThatIsntOneObject() {
    #expect(throws: ConfigText.ScanError.self) { try scanned("[1]") }
    #expect(throws: ConfigText.ScanError.self) { try scanned("{\"a\": 1} 2") }
    #expect(throws: ConfigText.ScanError.self) { try scanned("{\"a\" 1}") }
    #expect(throws: ConfigText.ScanError.self) { try scanned("{\"a\": 1") }
}

@Test func replacingAValueKeepsEveryOtherByte() throws {
    let text = "{\n  // Rows.\n  \"max\": 8, // eight\n  \"b\": true\n}"
    #expect(
        try setting("max", to: "12", in: text)
            == "{\n  // Rows.\n  \"max\": 12, // eight\n  \"b\": true\n}")
    #expect(
        try setting("b", to: "[\n    \"x\"\n  ]", in: text)
            == "{\n  // Rows.\n  \"max\": 8, // eight\n  \"b\": [\n    \"x\"\n  ]\n}")
}

@Test func insertingPutsTheKeyAfterTheLastWithItsComment() throws {
    let text = "{\n    \"a\": 1 // one\n}\n"
    #expect(
        try setting("b", to: "2", comment: ["Two.", "Takes a number."], in: text)
            == "{\n    \"a\": 1, // one\n\n    // Two.\n    // Takes a number.\n    \"b\": 2\n}\n")
}

@Test func insertingMatchesATrailingComma() throws {
    #expect(
        try setting("b", to: "2", in: "{\n  \"a\": 1,\n}")
            == "{\n  \"a\": 1,\n  \"b\": 2,\n}")
}

@Test func insertingKeepsCRLFLineEnds() throws {
    #expect(
        try setting("b", to: "2", comment: ["Two."], in: "{\r\n  \"a\": 1\r\n}\r\n")
            == "{\r\n  \"a\": 1,\r\n\r\n  // Two.\r\n  \"b\": 2\r\n}\r\n")
}

@Test func insertingSkipsABlockCommentAfterTheLastKey() throws {
    #expect(
        try setting("b", to: "2", in: "{\n  \"a\": 1 /* x\n y */\n}")
            == "{\n  \"a\": 1, /* x\n y */\n  \"b\": 2\n}")
}

@Test func insertingIntoAnObjectOnOneLineStaysOnIt() throws {
    #expect(try setting("b", to: "2", comment: ["Two."], in: #"{"a": 1}"#) == #"{"a": 1, "b": 2}"#)
    #expect(try setting("b", to: "2", in: #"{"a": 1,}"#) == #"{"a": 1, "b": 2,}"#)
}

@Test func insertingIntoAnEmptyObjectOpensItOntoLines() throws {
    #expect(
        try setting("b", to: "2", comment: ["Two."], in: "{}\n")
            == "{\n  // Two.\n  \"b\": 2\n}\n")
}
