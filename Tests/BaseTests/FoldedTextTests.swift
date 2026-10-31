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

@Test func wordStartsAtTheEndOfAnAcronym() {
    #expect(FoldedText("VPNClient").wordStarts == [0, 3])
    #expect(FoldedText("HTMLEditor Pro").wordStarts == [0, 4, 11])
    #expect(FoldedText("ÉTATRésumé").wordStarts == [0, 4])
}

@Test func wordStartsAtLetterDigitBoundaries() {
    #expect(FoldedText("Time2Go").wordStarts == [0, 4, 5])
    #expect(FoldedText("Office365").wordStarts == [0, 6])
    #expect(FoldedText("3DMark").wordStarts == [0, 1, 2])
    #expect(FoldedText("Café2Go").wordStarts == [0, 4, 5])
}

/// Every printable ASCII character, which both ways of finding word starts must classify alike.
private let printableASCII = (0x20...0x7E).map { Character(Unicode.Scalar(UInt8($0))) }

@Test func asciiAndCharacterClassesAgree() {
    for character in printableASCII {
        let byte = character.asciiValue!
        #expect(
            FoldedText.CharacterClass(ascii: byte) == FoldedText.CharacterClass(character),
            "\(character)")
    }
}

/// The ASCII path's word starts for `text`, and the general path's, forced by a non-ASCII
/// suffix that folds to the same single byte as the ASCII one.
private func bothPaths(_ text: String) -> (ascii: [Int32], general: [Int32]) {
    (FoldedText(text + " e").wordStarts, FoldedText(text + " é").wordStarts)
}

@Test func asciiAndGeneralPathsFindTheSameWordStarts() {
    for first in printableASCII {
        for second in printableASCII {
            let paths = bothPaths(String([first, second]))
            #expect(paths.ascii == paths.general, "\(first)\(second)")
        }
    }
    // Triples of one character per class and boundary, for the rules that look ahead.
    let representatives = Array("aZm5 -._A0z")
    for first in representatives {
        for second in representatives {
            for third in representatives {
                let paths = bothPaths(String([first, second, third]))
                #expect(paths.ascii == paths.general, "\(first)\(second)\(third)")
            }
        }
    }
}
