import Testing

@testable import Search

@Test func describesAnErrorAfterItsLine() {
    #expect(
        ConfigError(line: 3, key: "calculator", reason: "calculator must be true or false, not 1")
            .description == "line 3: calculator must be true or false, not 1")
    #expect(
        ConfigError(line: nil, key: nil, reason: "isn't UTF-8 text").description
            == "isn't UTF-8 text")
}
