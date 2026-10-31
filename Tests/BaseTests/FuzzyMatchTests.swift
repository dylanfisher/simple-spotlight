import Testing

@testable import Base

private func kind(_ query: String, _ text: String) -> FuzzyMatch.Kind? {
    FuzzyMatch.Query(query).score(FoldedText(text))?.kind
}

/// The matched characters of `text`, one string per range.
private func highlighted(_ query: String, _ text: String) -> [String]? {
    FuzzyMatch.Query(query).match(FoldedText(text)).map { match in
        match.ranges.map { String(text[$0]) }
    }
}

@Test func classifiesExactPrefix() {
    #expect(kind("saf", "Safari") == .exactPrefix)
    #expect(kind("safari", "Safari") == .exactPrefix)
}

@Test func classifiesWordStartPrefix() {
    #expect(kind("code", "Visual Studio Code") == .wordStartPrefix)
    #expect(kind("saf", "Microsoft Safety Scanner") == .wordStartPrefix)
    #expect(kind("time", "FaceTime") == .wordStartPrefix)
}

@Test func classifiesInitials() {
    #expect(kind("vsc", "Visual Studio Code") == .initials)
    #expect(kind("ft", "FaceTime") == .initials)
}

@Test func classifiesSubsequence() {
    #expect(kind("code", "Xcode") == .subsequence)
    #expect(kind("sfr", "Safari") == .subsequence)
}

@Test func rejectsWhatIsNotASubsequence() {
    #expect(kind("saf", "Font Book") == nil)
    #expect(kind("ba", "ab") == nil)
    #expect(kind("long query", "short") == nil)
}

@Test func emptyQueryMatchesNothing() {
    #expect(FuzzyMatch.Query("").isEmpty)
    #expect(kind("", "Safari") == nil)
}

@Test func classesOrderBestFirst() {
    #expect(FuzzyMatch.Kind.exactPrefix > .wordStartPrefix)
    #expect(FuzzyMatch.Kind.wordStartPrefix > .initials)
    #expect(FuzzyMatch.Kind.initials > .subsequence)
}

@Test func foldsTheQueryAndTheCandidate() {
    #expect(kind("é", "e") == .exactPrefix)
    #expect(kind("e", "é") == .exactPrefix)
    #expect(kind("ｃ", "c") == .exactPrefix)
    #expect(kind("RES", "résumé") == .exactPrefix)
}

@Test func aRunScoresHigherThanScatteredWordStarts() {
    let query = FuzzyMatch.Query("code")
    let together = query.score(FoldedText("Xcode"))!
    let apart = query.score(FoldedText("Color Draw Editor"))!
    #expect(together.kind == .subsequence && apart.kind == .subsequence)
    #expect(together > apart)
}

@Test func rangesCoverTheMatchedCharacters() {
    #expect(highlighted("saf", "Safari") == ["Saf"])
    #expect(highlighted("code", "Visual Studio Code") == ["Code"])
    #expect(highlighted("vsc", "Visual Studio Code") == ["V", "S", "C"])
    #expect(highlighted("sfr", "Safari") == ["S", "f", "r"])
    #expect(highlighted("res", "Résumé") == ["Rés"])
    #expect(highlighted("e", "Café") == ["é"])
}

@Test func wordStartsScoreHigherWithinSubsequence() {
    let query = FuzzyMatch.Query("sri")
    #expect(query.score(FoldedText("Safari"))! > query.score(FoldedText("Xsafari"))!)
}
