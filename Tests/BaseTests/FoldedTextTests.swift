import Testing

@testable import Base

@Test func foldsCaseDiacriticsAndWidth() {
    #expect(FoldedText.fold("Safari") == "safari")
    #expect(FoldedText.fold("Résumé") == "resume")
    #expect(FoldedText.fold("ｃｏｄｅ") == "code")
    #expect(FoldedText.fold("é") == "e")
}

@Test func candidateBytesMatchTheQueryFold() {
    for text in ["Safari", "Résumé Builder", "ｃｏｄｅ", "Ünïcödé Tool"] {
        #expect(FoldedText(text).bytes == Array(FoldedText.fold(text).utf8))
    }
}

@Test func wordStartsAtSpacesPunctuationAndCaseChanges() {
    #expect(FoldedText("Visual Studio Code").wordStarts == [0, 7, 14])
    #expect(FoldedText("Xcode").wordStarts == [0])
    #expect(FoldedText("FaceTime").wordStarts == [0, 4])
    #expect(FoldedText("my-video_downloads").wordStarts == [0, 3, 9])
    #expect(FoldedText("iPhone Mirroring").wordStarts == [0, 1, 7])
    #expect(FoldedText("  Leading").wordStarts == [2])
}

@Test func capitalRunsAreOneWord() {
    #expect(FoldedText("VPN Client").wordStarts == [0, 4])
}

@Test func wordStartsInNonASCIIText() {
    // "É" folds to one byte, so "Éditeur Vidéo" keeps its offsets in the folded text.
    #expect(FoldedText("Éditeur Vidéo").wordStarts == [0, 8])
    #expect(FoldedText("ÉcranPartagé").wordStarts == [0, 5])
}
