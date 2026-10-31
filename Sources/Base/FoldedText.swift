import Foundation

/// A text prepared for fuzzy matching: folded once, with its word starts found, so a keystroke
/// only compares bytes.
///
/// Folding removes case, diacritics and width, so "Résumé" and "ｒｅｓｕｍｅ" both fold to
/// "resume", and drops format characters such as the soft hyphen. A word starts at the beginning
/// of the text, after a space or punctuation, at a capital that follows a lowercase letter
/// ("FaceTime"), at the last capital of a run of capitals followed by a lowercase letter (the "C"
/// of "VPNClient"), and where letters and digits meet ("Time2Go", "Office365").
public struct FoldedText: Sendable {
    /// The text as given, which the match's ranges index into.
    public let text: String
    /// The folded text's UTF-8 bytes, which matching compares and ties sort by.
    public let bytes: [UInt8]
    /// The offsets in `bytes` where a word starts, ascending.
    let wordStarts: [Int32]
    /// For a text that isn't all ASCII, the UTF-8 offset in `text` of the character each folded
    /// byte comes from. Nil when the folded bytes line up with `text`'s, as ASCII does.
    let origins: [Int32]?

    public init(_ text: String) {
        self.text = text
        // Each character's class and the offset of its first folded byte, for `wordStarts(_:)`.
        var characters: [(CharacterClass, Int32)] = []
        if text.utf8.allSatisfy({ $0 < 0x80 }) {
            // Folding ASCII only lowercases, so offsets match and the original capitals show where
            // camel-case words start.
            var bytes: [UInt8] = []
            bytes.reserveCapacity(text.utf8.count)
            characters.reserveCapacity(text.utf8.count)
            for byte in text.utf8 {
                characters.append((CharacterClass(ascii: byte), Int32(bytes.count)))
                bytes.append(Self.isCapital(byte) ? byte + 0x20 : byte)
            }
            self.bytes = bytes
            origins = nil
        } else {
            // Folding a character at a time tells which character each folded byte came from,
            // for the match's ranges.
            var bytes: [UInt8] = []
            var origins: [Int32] = []
            var offset = 0
            for character in text {
                let folded = Self.fold(String(character)).utf8
                // A character that folds to nothing can't be matched or start a word.
                if !folded.isEmpty {
                    characters.append((CharacterClass(character), Int32(bytes.count)))
                }
                bytes.append(contentsOf: folded)
                origins.append(contentsOf: repeatElement(Int32(offset), count: folded.count))
                offset += character.utf8.count
            }
            self.bytes = bytes
            self.origins = origins
        }
        wordStarts = Self.wordStarts(characters)
    }

    /// `text` with case, diacritics and width folded away, and invisible format characters
    /// (Unicode category Cf) removed: what a query is folded with before it is matched against a
    /// `FoldedText`. German names carry soft hyphens ("System\u{AD}einstellungen") that no one
    /// types.
    public static func fold(_ text: String) -> String {
        if text.utf8.allSatisfy({ $0 < 0x80 }) {
            // Most names are ASCII, where folding only lowercases. Skipping Foundation's pass
            // keeps building the index cheap.
            return String(decoding: text.utf8.map { isCapital($0) ? $0 + 0x20 : $0 }, as: UTF8.self)
        }
        let folded = text.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        let isFormat = { (scalar: Unicode.Scalar) in scalar.properties.generalCategory == .format }
        guard folded.unicodeScalars.contains(where: isFormat) else { return folded }
        var kept = String.UnicodeScalarView()
        kept.append(contentsOf: folded.unicodeScalars.filter { !isFormat($0) })
        return String(kept)
    }

    /// What a character contributes to finding word starts. Both initializers must agree on
    /// ASCII, so a name finds the same words whichever path folds it.
    enum CharacterClass {
        case separator, lowercase, uppercase, digit, otherLetter

        init(ascii byte: UInt8) {
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"): self = .lowercase
            case UInt8(ascii: "A")...UInt8(ascii: "Z"): self = .uppercase
            case UInt8(ascii: "0")...UInt8(ascii: "9"): self = .digit
            default: self = .separator
            }
        }

        init(_ character: Character) {
            if character.isLowercase {
                self = .lowercase
            } else if character.isUppercase {
                self = .uppercase
            } else if character.isNumber {
                self = .digit
            } else if character.isLetter {
                self = .otherLetter
            } else {
                self = .separator
            }
        }

        var isLetter: Bool {
            switch self {
            case .lowercase, .uppercase, .otherLetter: true
            case .separator, .digit: false
            }
        }
    }

    /// The folded offsets of the characters that start a word, from each character's class and
    /// offset.
    private static func wordStarts(_ characters: [(CharacterClass, Int32)]) -> [Int32] {
        var starts: [Int32] = []
        for (index, (current, offset)) in characters.enumerated() {
            let previous = index > 0 ? characters[index - 1].0 : nil
            let next = index + 1 < characters.count ? characters[index + 1].0 : nil
            if startsWord(current, after: previous, before: next) { starts.append(offset) }
        }
        return starts
    }

    private static func startsWord(
        _ current: CharacterClass, after previous: CharacterClass?, before next: CharacterClass?
    ) -> Bool {
        guard current != .separator else { return false }
        guard let previous, previous != .separator else { return true }
        switch (previous, current) {
        case (.lowercase, .uppercase): return true
        case (.uppercase, .uppercase): return next == .lowercase
        case (.digit, _): return current.isLetter
        case (_, .digit): return previous.isLetter
        default: return false
        }
    }

    private static func isCapital(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
    }
}
