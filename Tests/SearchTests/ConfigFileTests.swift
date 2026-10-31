import Foundation
import Testing

@testable import Search

private func parse(_ text: String) -> ConfigFile.Outcome {
    ConfigFile.parse(Data(text.utf8))
}

/// The errors `text` gives; none when it parses.
private func errors(_ text: String) -> [ConfigError] {
    guard case .failed(let errors) = parse(text) else { return [] }
    return errors
}

@Test func theDefaultFileReadsBackAsTheDefaults() {
    #expect(parse(ConfigFile.defaultText) == .settings(Settings()))
}

@Test func theDefaultFileCommentsEachKey() {
    let lines = ConfigFile.defaultText.split(separator: "\n", omittingEmptySubsequences: false)
    for key in Settings.Keys.all {
        let at = lines.firstIndex { $0.hasPrefix("  \"\(key.name)\": ") }
        guard let at else {
            Issue.record("\(key.name) isn't in the default file")
            continue
        }
        #expect(
            lines[(at - key.comment.count)..<at].map(String.init)
                == key.comment.map { "  // \($0)" })
        #expect(lines[at - key.comment.count - 1] == "{" || lines[at - key.comment.count - 1] == "")
    }
    #expect(ConfigFile.defaultText.hasSuffix("\n}\n"))
    #expect(ConfigFile.defaultText.contains("\"appFolders\": [\n    \"/Applications\",\n"))
}

@Test func keepsDefaultsForKeysLeftOut() {
    var expected = Settings()
    expected.maxResults = 5
    #expect(parse(#"{"maxResults": 5}"#) == .settings(expected))
    #expect(parse("{}") == .settings(Settings()))
}

@Test func readsEveryKey() throws {
    let text = """
        {
          "hotkey": "ctrl+opt+k",
          "searchApplications": false,
          "searchSystemSettings": false,
          "calculator": false,
          "appFolders": ["/Apps", "~/More"],
          "excludedApps": ["com.apple.Chess"],
          "maxResults": 20,
          "dimUnused": false,
          "dimAfterDays": 365,
          "showOnAllDisplays": true,
          "launchAtLogin": true
        }
        """
    var expected = Settings()
    expected.hotkey = KeyChord([.control, .option], .k)
    expected.searchApplications = false
    expected.searchSystemSettings = false
    expected.calculator = false
    expected.appFolders = ["/Apps", "~/More"]
    expected.excludedApps = ["com.apple.Chess"]
    expected.maxResults = 20
    expected.dimUnused = false
    expected.dimAfterDays = 365
    expected.showOnAllDisplays = true
    expected.launchAtLogin = true
    #expect(parse(text) == .settings(expected))
}

@Test func acceptsCommentsAndTrailingCommas() {
    let text = """
        // My settings.
        {
          /* Fewer rows. */
          "maxResults": 4, // was 8
          "appFolders": ["/Apps",],
        }
        """
    var expected = Settings()
    expected.maxResults = 4
    expected.appFolders = ["/Apps"]
    #expect(parse(text) == .settings(expected))
}

@Test func acceptsAByteOrderMark() {
    #expect(ConfigFile.parse(Data([0xEF, 0xBB, 0xBF]) + Data("{}".utf8)) == .settings(Settings()))
}

@Test(arguments: [
    (#""maxResult": 5"#, "maxResult", #"unknown key "maxResult""#),
    (#""calculator": "yes""#, "calculator", #"calculator must be true or false, not "yes""#),
    (#""calculator": 1"#, "calculator", "calculator must be true or false, not 1"),
    (#""maxResults": 30"#, "maxResults", "maxResults must be a whole number from 1 to 20, not 30"),
    (#""maxResults": 0"#, "maxResults", "maxResults must be a whole number from 1 to 20, not 0"),
    (
        #""maxResults": 2.5"#, "maxResults",
        "maxResults must be a whole number from 1 to 20, not 2.5"
    ),
    (
        #""maxResults": true"#, "maxResults",
        "maxResults must be a whole number from 1 to 20, not true"
    ),
    (
        #""dimAfterDays": 0"#, "dimAfterDays",
        "dimAfterDays must be a whole number from 1 to 365, not 0"
    ),
    (
        #""hotkey": "cmd+""#, "hotkey",
        #"hotkey must be a shortcut such as "cmd+space" or "ctrl+opt+k", not "cmd+": it has no key after the last +"#
    ),
    (
        #""hotkey": "cmd+foo""#, "hotkey",
        #"hotkey must be a shortcut such as "cmd+space" or "ctrl+opt+k", not "cmd+foo": "foo" isn't a key"#
    ),
    (
        #""hotkey": "space""#, "hotkey",
        #"hotkey must be a shortcut such as "cmd+space" or "ctrl+opt+k", not "space": it needs a modifier, as only F1 to F20 can be used alone"#
    ),
    (
        #""appFolders": ["Applications"]"#, "appFolders",
        #"appFolders must be a list of folders, each a full path, ~, or a path that starts with ~/, not ["Applications"]: "Applications" isn't a full path, ~, or a path that starts with ~/"#
    ),
    (
        #""appFolders": "/Applications""#, "appFolders",
        #"appFolders must be a list of folders, each a full path, ~, or a path that starts with ~/, not "/Applications""#
    ),
    (
        #""excludedApps": [""]"#, "excludedApps",
        #"excludedApps must be a list of bundle IDs, such as ["com.apple.Chess"], not [""]: a bundle ID is empty"#
    ),
    (
        #""launchAtLogin": null"#, "launchAtLogin",
        "launchAtLogin must be true or false, not null"
    ),
])
func refusesABadKeyOnItsLine(entry: String, key: String, reason: String) {
    // The good key before it would apply if the file applied in part.
    let text = "{\n  \"searchApplications\": false,\n  \(entry)\n}"
    #expect(errors(text) == [ConfigError(line: 3, key: key, reason: reason)])
}

@Test func reportsEveryBadKeyInLineOrder() {
    let text = """
        {
          "maxResults": 99,
          "calculator": 0,
          "nope": 1
        }
        """
    #expect(errors(text).map(\.line) == [2, 3, 4])
    #expect(errors(text).map(\.key) == ["maxResults", "calculator", "nope"])
}

@Test func refusesAKeyGivenTwice() {
    let text = "{\n  \"maxResults\": 3,\n  \"maxResults\": 4\n}"
    #expect(
        errors(text) == [
            ConfigError(
                line: 3, key: "maxResults", reason: "maxResults is set twice, first on line 2")
        ])
}

@Test func findsTheLineOfAnEscapedKey() {
    #expect(errors("{\n\n  \"max\\u0052esults\": 0}").map(\.line) == [3])
}

@Test func reportsTextThatIsntJSONOnItsLine() throws {
    let found = errors("{\n  \"maxResults\": 3\n  \"calculator\": true\n}")
    let error = try #require(found.first)
    #expect(found.count == 1)
    #expect(error.line == 3)
    #expect(error.key == nil)
    #expect(error.reason.hasPrefix("isn't valid JSON"))
    #expect(!error.reason.contains("around line"))
}

@Test func refusesFilesThatHoldNoObject() {
    #expect(
        errors("  // nothing\n") == [
            ConfigError(line: nil, key: nil, reason: "is empty: it needs a JSON object, such as {}")
        ])
    #expect(
        errors("[1]") == [
            ConfigError(
                line: 1, key: nil, reason: "must be a JSON object, its keys and values in braces")
        ])
    #expect(
        errors("{\n/* open\n}") == [
            ConfigError(line: 2, key: nil, reason: "has a /* comment that isn't closed with */")
        ])
    #expect(
        ConfigFile.parse(Data([0x7B, 0xFF, 0x7D]))
            == .failed([ConfigError(line: nil, key: nil, reason: "isn't UTF-8 text")]))
}

@Test func countsLinesEndedByALoneCarriageReturn() {
    #expect(errors("{\r\"calculator\": 1,\r\n\"maxResults\": 0\r}").map(\.line) == [2, 3])
}

@Test func refusesAFileTooLargeToRead() {
    let text = "{" + String(repeating: " ", count: ConfigFile.largestSize) + "}"
    #expect(
        errors(text) == [
            ConfigError(
                reason: "is too large: a config file has at most \(ConfigFile.largestSize) bytes")
        ])
}

@Test func reportsTheFirstErrorsAndCountsTheRest() {
    let keys = (1...30).map { "\"unknown\($0)\": 1" }
    let found = errors("{\n" + keys.joined(separator: ",\n") + "\n}")
    #expect(found.count == ConfigFile.mostErrors)
    #expect(found.dropLast().map(\.line) == Array(2...ConfigFile.mostErrors))
    #expect(
        found.last
            == ConfigError(reason: "and \(30 - ConfigFile.mostErrors + 1) more errors"))
}

@Suite(.serialized) struct ConfigFileTiming {
    /// A file of many keys, as a pasted file might be, parses in time linear in its size. The
    /// bound is loose: the scan once copied each object's keys per key, which took 5.5 s here.
    @Test func parsesManyKeysQuickly() {
        let keys = (1...50_000).map { "\"k\($0)\": 1" }
        let text = "{\n" + keys.joined(separator: ",\n") + "\n}"
        let clock = ContinuousClock()
        let start = clock.now
        let found = errors(text)
        #expect(clock.now - start < .seconds(2))
        #expect(found.count == ConfigFile.mostErrors)
    }
}

// MARK: Changing

/// `text` with `change` written in, or nil when it changes nothing.
private func changing(_ text: String, _ change: (inout Settings) -> Void) throws -> String? {
    try ConfigFile.changing(Data(text.utf8), change).map { String(decoding: $0, as: UTF8.self) }
}

@Test func aChangeReplacesOnlyItsValue() throws {
    let changed = try #require(try changing(ConfigFile.defaultText) { $0.maxResults = 12 })
    #expect(
        changed
            == ConfigFile.defaultText.replacingOccurrences(
                of: "\"maxResults\": 8", with: "\"maxResults\": 12"))
}

@Test func aChangeKeepsTheUsersCommentsAndSpelling() throws {
    let text = """
        // Mine.
        {
          "hotkey": "CTRL+opt+K", // left as typed
          /* fewer */ "maxResults": 4,
        }

        """
    let changed = try changing(text) { $0.maxResults = 5 }
    #expect(
        changed == """
            // Mine.
            {
              "hotkey": "CTRL+opt+K", // left as typed
              /* fewer */ "maxResults": 5,
            }

            """)
}

@Test func aKeyTheFileLeavesOutGoesInWithItsComment() throws {
    let changed = try #require(
        try changing("{\n  \"maxResults\": 4\n}\n") { $0.dimAfterDays = 10 })
    let comment = Settings.Keys.dimAfterDays.comment.map { "  // \($0)\n" }.joined()
    #expect(changed == "{\n  \"maxResults\": 4,\n\n\(comment)  \"dimAfterDays\": 10\n}\n")
}

@Test func everyKeyChangedReadsBack() throws {
    var expected = Settings()
    expected.hotkey = KeyChord([.control, .shift], .f5)
    expected.searchApplications = false
    expected.searchSystemSettings = false
    expected.calculator = false
    expected.appFolders = ["/Apps", "~/More \"quoted\""]
    expected.excludedApps = []
    expected.maxResults = 20
    expected.dimUnused = false
    expected.dimAfterDays = 1
    expected.showOnAllDisplays = true
    expected.launchAtLogin = true
    for text in ["{}", ConfigFile.defaultText, #"{"excludedApps": ["com.apple.Chess"],}"#] {
        let changed = try #require(try changing(text) { $0 = expected })
        #expect(parse(changed) == .settings(expected), "from \(text)")
    }
}

@Test func aChangeTheFileAlreadyHasWritesNothing() throws {
    #expect(
        try changing(#"{"hotkey": "CMD+SPACE"}"#) { $0.hotkey = KeyChord(.command, .space) } == nil)
    #expect(try changing("{}") { $0.maxResults = 8 } == nil)
}

@Test func aFileWithAnErrorIsntChanged() {
    #expect(throws: ConfigError.self) {
        try changing(#"{"maxResults": 30}"#) { $0.maxResults = 5 }
    }
    #expect(throws: ConfigError.self) { try changing("{") { $0.maxResults = 5 } }
}
