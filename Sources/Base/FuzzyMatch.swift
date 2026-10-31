import Foundation

/// How well a typed query matched one candidate, and where.
///
/// The query's letters must appear in the candidate in order. A match falls into one of four
/// kinds, best first: the query starts the candidate ("saf" in "Safari"), the query starts a later
/// word ("code" in "Visual Studio Code"), each letter starts a word ("vsc" in "Visual Studio
/// Code"), or the letters appear anywhere in order ("code" in "Xcode", whose "c" doesn't start a
/// word). Within a subsequence, letters that run together or start words score higher.
public struct FuzzyMatch: Sendable, Equatable {
    /// The kinds of match, ordered worst to best.
    public enum Kind: Int, Sendable, Comparable {
        case subsequence, initials, wordStartPrefix, exactPrefix

        public static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }
    }

    /// A match's rank without its ranges. Only scores for the same query compare.
    public struct Score: Sendable, Comparable {
        public let kind: Kind
        /// Orders subsequences: two points for each letter that directly follows the letter before
        /// it, one for each that starts a word. A run counts more so that "code" ranks "Xcode" above
        /// "Color Draw Editor". Zero for the other kinds, whose matches of one query are equally
        /// good.
        public let quality: Int

        public static func < (a: Score, b: Score) -> Bool {
            (a.kind, a.quality) < (b.kind, b.quality)
        }
    }

    public let score: Score
    /// The matched characters of the candidate's text, in order, with adjacent ones joined into
    /// one range. A letter matched inside a character that folds to several, as "f" in "ﬁ",
    /// covers the whole character.
    public let ranges: [Range<String.Index>]

    /// A query folded once per keystroke, to score against every candidate.
    public struct Query: Sendable {
        /// The folded query's bytes.
        private let bytes: [UInt8]

        /// Whitespace around `text` is dropped, so a trailing space doesn't stop a match; spaces
        /// inside it are matched like any other character.
        public init(_ text: String) {
            bytes = Array(
                FoldedText.fold(text.trimmingCharacters(in: .whitespacesAndNewlines)).utf8)
        }

        /// True when the query has nothing to match, as one of only whitespace. An empty query
        /// matches no candidate.
        public var isEmpty: Bool { bytes.isEmpty }

        /// The score of `candidate`, or nil when it doesn't hold the query's letters in order.
        /// Allocates nothing.
        public func score(_ candidate: FoldedText) -> Score? {
            align(candidate) { _, _ in }
        }

        /// The score and matched ranges of `candidate`, or nil when it doesn't match.
        public func match(_ candidate: FoldedText) -> FuzzyMatch? {
            var spans: [Range<Int>] = []
            guard let score = align(candidate, { spans.append($0..<($0 + $1)) }) else {
                return nil
            }
            return FuzzyMatch(score: score, ranges: Self.ranges(of: spans, in: candidate))
        }

        /// Finds the best kind of match and reports each matched run of folded bytes to `found`
        /// as a start and a length, in order.
        private func align(_ candidate: FoldedText, _ found: (Int, Int) -> Void) -> Score? {
            let query = bytes
            let text = candidate.bytes
            guard !query.isEmpty, query.count <= text.count else { return nil }
            if text.starts(with: query) {
                found(0, query.count)
                return Score(kind: .exactPrefix, quality: 0)
            }
            for start in candidate.wordStarts.lazy.map(Int.init)
            where start > 0 && Self.matches(query, 0..<query.count, in: text, at: start) {
                found(start, query.count)
                return Score(kind: .wordStartPrefix, quality: 0)
            }
            if initials(candidate) {
                // Second pass to report: the first one rejects most candidates without calling
                // `found` for letters that turn out not to chain.
                _ = initials(candidate, found)
                return Score(kind: .initials, quality: 0)
            }
            return subsequence(candidate, found)
        }

        /// Whether each query character starts a word of `candidate`, in order. Taking the
        /// earliest word start for each character finds a chain whenever one exists.
        private func initials(_ candidate: FoldedText, _ found: (Int, Int) -> Void = { _, _ in })
            -> Bool
        {
            let text = candidate.bytes
            var word = 0
            var letter = 0
            while letter < bytes.count {
                let character = letter..<Self.characterEnd(bytes, from: letter)
                while word < candidate.wordStarts.count
                    && !Self.matches(
                        bytes, character, in: text, at: Int(candidate.wordStarts[word]))
                {
                    word += 1
                }
                guard word < candidate.wordStarts.count else { return false }
                found(Int(candidate.wordStarts[word]), character.count)
                word += 1
                letter = character.upperBound
            }
            return true
        }

        /// The leftmost placement of the query's characters in order, scored by how many start
        /// words or run on from the letter before.
        private func subsequence(_ candidate: FoldedText, _ found: (Int, Int) -> Void) -> Score? {
            let text = candidate.bytes
            let wordStarts = candidate.wordStarts
            var quality = 0
            var position = 0
            var previousEnd = -1
            var word = 0
            var letter = 0
            while letter < bytes.count {
                let character = letter..<Self.characterEnd(bytes, from: letter)
                while position + character.count <= text.count
                    && !Self.matches(bytes, character, in: text, at: position)
                {
                    position += 1
                }
                guard position + character.count <= text.count else { return nil }
                while word < wordStarts.count && Int(wordStarts[word]) < position { word += 1 }
                if word < wordStarts.count && Int(wordStarts[word]) == position { quality += 1 }
                if position == previousEnd { quality += 2 }
                found(position, character.count)
                previousEnd = position + character.count
                position = previousEnd
                letter = character.upperBound
            }
            return Score(kind: .subsequence, quality: quality)
        }

        /// Whether `query[character]` appears in `text` at `start`.
        private static func matches(
            _ query: [UInt8], _ character: Range<Int>, in text: [UInt8], at start: Int
        ) -> Bool {
            guard start + character.count <= text.count else { return false }
            for offset in 0..<character.count
            where text[start + offset] != query[character.lowerBound + offset] {
                return false
            }
            return true
        }

        /// The end of the UTF-8 character starting at `start`: a character matches whole, so a
        /// letter's continuation bytes never match on their own.
        private static func characterEnd(_ bytes: [UInt8], from start: Int) -> Int {
            var end = start + 1
            while end < bytes.count && bytes[end] & 0xC0 == 0x80 { end += 1 }
            return end
        }

        /// The characters of `candidate.text` holding the folded byte `spans`, adjacent ones
        /// joined.
        private static func ranges(of spans: [Range<Int>], in candidate: FoldedText)
            -> [Range<String.Index>]
        {
            let utf8 = candidate.text.utf8
            var offsets: [Range<Int>] = []
            for span in spans {
                let characters: Range<Int>
                if let origins = candidate.origins {
                    let start = Int(origins[span.lowerBound])
                    var next = span.upperBound
                    while next < origins.count && origins[next] == origins[span.upperBound - 1] {
                        next += 1
                    }
                    characters = start..<(next < origins.count ? Int(origins[next]) : utf8.count)
                } else {
                    characters = span
                }
                if let last = offsets.last, last.upperBound >= characters.lowerBound {
                    offsets[offsets.count - 1] =
                        last.lowerBound..<max(last.upperBound, characters.upperBound)
                } else {
                    offsets.append(characters)
                }
            }
            return offsets.map {
                utf8.index(
                    utf8.startIndex, offsetBy: $0.lowerBound)..<utf8.index(
                        utf8.startIndex, offsetBy: $0.upperBound)
            }
        }
    }
}
