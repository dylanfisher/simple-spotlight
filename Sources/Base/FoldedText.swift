import Foundation

/// A text prepared for fuzzy matching: folded once, with its word starts found, so a keystroke
/// only compares bytes.
///
/// Folding removes case, diacritics and width, so "Résumé" and "ｒｅｓｕｍｅ" both fold to
/// "resume". A word starts at the beginning of the text, after a space or punctuation, and at a
/// capital that follows a lowercase letter ("FaceTime" has words at "F" and "T").
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
        var wordStarts: [Int32] = []
        if text.utf8.allSatisfy({ $0 < 0x80 }) {
            // Folding ASCII only lowercases, so offsets match and the original capitals show where
            // camel-case words start.
            var bytes: [UInt8] = []
            bytes.reserveCapacity(text.utf8.count)
            var previous: CharacterClass?
            for byte in text.utf8 {
                let current = CharacterClass(ascii: byte)
                if Self.startsWord(current, after: previous) {
                    wordStarts.append(Int32(bytes.count))
                }
                bytes.append(Self.isCapital(byte) ? byte + 0x20 : byte)
                previous = current
            }
            self.bytes = bytes
            origins = nil
        } else {
            // Folding a character at a time tells which character each folded byte came from,
            // for the match's ranges.
            var bytes: [UInt8] = []
            var origins: [Int32] = []
            var offset = 0
            var previous: CharacterClass?
            for character in text {
                let current = CharacterClass(character)
                let folded = Self.fold(String(character)).utf8
                if !folded.isEmpty && Self.startsWord(current, after: previous) {
                    wordStarts.append(Int32(bytes.count))
                }
                bytes.append(contentsOf: folded)
                origins.append(contentsOf: repeatElement(Int32(offset), count: folded.count))
                offset += character.utf8.count
                previous = current
            }
            self.bytes = bytes
            self.origins = origins
        }
        self.wordStarts = wordStarts
    }

    /// `text` with case, diacritics and width folded away: what a query is folded with before it
    /// is matched against a `FoldedText`.
    public static func fold(_ text: String) -> String {
        if text.utf8.allSatisfy({ $0 < 0x80 }) {
            // Most names are ASCII, where folding only lowercases. Skipping Foundation's pass
            // keeps building the index cheap.
            return String(decoding: text.utf8.map { isCapital($0) ? $0 + 0x20 : $0 }, as: UTF8.self)
        }
        return text.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// What a character contributes to finding word starts.
    enum CharacterClass {
        case separator, lowercase, uppercase, other

        init(ascii byte: UInt8) {
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"): self = .lowercase
            case UInt8(ascii: "A")...UInt8(ascii: "Z"): self = .uppercase
            case UInt8(ascii: "0")...UInt8(ascii: "9"): self = .other
            default: self = .separator
            }
        }

        init(_ character: Character) {
            if character.isLowercase {
                self = .lowercase
            } else if character.isUppercase {
                self = .uppercase
            } else if character.isLetter || character.isNumber {
                self = .other
            } else {
                self = .separator
            }
        }
    }

    private static func startsWord(_ current: CharacterClass, after previous: CharacterClass?)
        -> Bool
    {
        switch (previous, current) {
        case (_, .separator): false
        case (nil, _), (.separator, _), (.lowercase, .uppercase): true
        default: false
        }
    }

    private static func isCapital(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
    }
}
