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
