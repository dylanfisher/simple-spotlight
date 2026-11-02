import Foundation
import Testing

@testable import Search

private let file = URL(filePath: "/tmp/simple-spotlight-test/config.json")

@Test func showsNoConfigRowForAFileThatApplies() {
    #expect(ProblemItems.config([], file: file) == nil)
}

@Test func showsTheFirstConfigErrorWithItsLineAndOpensTheFile() throws {
    let errors = [
        ConfigError(line: 3, key: "maxResults", reason: "maxResults must be a whole number"),
        ConfigError(line: 5, reason: "isn't valid JSON"),
    ]

    let row = try #require(ProblemItems.config(errors, file: file))

    #expect(row.title == "Config error: line 3: maxResults must be a whole number")
    #expect(row.subtitle == "1 more error · Return opens /tmp/simple-spotlight-test/config.json")
    #expect(row.kind == .problem)
    #expect(row.target == .command(CommandProvider.Command.openConfig.id))
}

@Test func namesTheFileForAnErrorWithNoLine() throws {
    let row = try #require(
        ProblemItems.config([ConfigError(reason: "couldn't be read: denied")], file: file))

    #expect(row.title == "Config file couldn't be read: denied")
    #expect(row.subtitle == "Return opens /tmp/simple-spotlight-test/config.json")
}

@Test func showsNoIndexRowWithoutProblems() {
    #expect(ProblemItems.index([]) == nil)
}

@Test func showsOneIndexProblemWholeAndCopiesIt() throws {
    let problem = IndexProblem(path: "/Volumes/Apps", reason: "It doesn't exist.")

    let row = try #require(ProblemItems.index([problem]))

    #expect(row.title == "Couldn't search Apps")
    #expect(row.subtitle == "/Volumes/Apps: It doesn't exist.")
    #expect(row.kind == .problem)
    #expect(row.target == .copyText("/Volumes/Apps: It doesn't exist."))
}

@Test func summarizesSeveralIndexProblemsAndCopiesThemAll() throws {
    let problems = [
        IndexProblem(path: "/Applications/A.app", reason: "It isn't a property list."),
        IndexProblem(path: "/Applications/B.app", reason: "It has no bundle ID."),
    ]

    let row = try #require(ProblemItems.index(problems))

    #expect(row.title == "Couldn't search 2 folders, apps or scripts")
    #expect(row.subtitle == "/Applications/A.app: It isn't a property list. · Return copies all 2")
    #expect(
        row.target
            == .copyText(
                "/Applications/A.app: It isn't a property list.\n"
                    + "/Applications/B.app: It has no bundle ID."))
}

@Test func givesEachProblemRowItsOwnID() throws {
    let config = try #require(ProblemItems.config([ConfigError(reason: "x")], file: file))
    let index = try #require(ProblemItems.index([IndexProblem(path: "/a", reason: "b")]))
    #expect(config.id != index.id)
    #expect(Set(ProblemItems.ID.allCases.map(\.id)).count == ProblemItems.ID.allCases.count)
    #expect(ProblemItems.ID.allCases.allSatisfy { $0.id.hasPrefix(SearchItem.builtInID("")) })
}
