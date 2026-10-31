import Foundation

/// A config file's text made readable by Foundation's JSON parser: JSON with `//` and `/* */`
/// comments and a comma allowed after an object's or array's last item, as Sublime Text's
/// settings are.
///
/// Each comment and trailing comma is made spaces byte for byte, keeping line breaks, so an
/// offset into the result is the same offset, on the same line, in the file.
///
/// It also edits the text as the user wrote it: a change replaces one top-level value's text,
/// or puts in one key, and leaves every comment, blank line, space and key order around it.
public enum ConfigText {
    /// Why text can't be read past its comments: a block comment not closed, on the line it
    /// opens on.
    public struct UnclosedComment: Error, Equatable {
        public let line: Int
    }

    /// `bytes` with each comment's bytes made spaces, its line breaks kept.
    public static func blankingComments(_ bytes: [UInt8]) -> Result<[UInt8], UnclosedComment> {
        markingComments(bytes).map(\.bytes)
    }

    /// `blankingComments`, and which bytes are in a comment, its line breaks among them.
    private static func markingComments(_ bytes: [UInt8]) -> Result<
        (bytes: [UInt8], inComment: [Bool]), UnclosedComment
    > {
        var blanked = bytes
        var inComment = [Bool](repeating: false, count: bytes.count)
        func blank(_ index: Int) {
            inComment[index] = true
            if bytes[index] != newline, bytes[index] != carriageReturn { blanked[index] = space }
        }
        var line = 1
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == quote {
                index = stringEnd(bytes, from: index)
                continue
            }
            if isLineBreak(bytes, at: index) { line += 1 }
            let next = index + 1 < bytes.count ? bytes[index + 1] : nil
            if byte == slash, next == slash {
                while index < bytes.count, bytes[index] != newline, bytes[index] != carriageReturn {
                    blank(index)
                    index += 1
                }
                continue
            }
            if byte == slash, next == star {
                let opened = line
                blank(index)
                blank(index + 1)
                index += 2
                while index < bytes.count,
                    !(bytes[index] == star && index + 1 < bytes.count
                        && bytes[index + 1] == slash)
                {
                    if isLineBreak(bytes, at: index) { line += 1 }
                    blank(index)
                    index += 1
                }
                guard index < bytes.count else { return .failure(UnclosedComment(line: opened)) }
                blank(index)
                blank(index + 1)
                index += 2
                continue
            }
            index += 1
        }
        return .success((blanked, inComment))
    }

    /// `bytes`, its comments already blanked, with each comma after an object's or array's last
    /// item made a space. A comma with no item before it, as in `{,}`, stays, so the parser
    /// reports it.
    public static func blankingTrailingCommas(_ bytes: [UInt8]) -> [UInt8] {
        var blanked = bytes
        // The last two bytes that aren't whitespace, the later one last.
        var previous: Int?
        var last: Int?
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == quote {
                index = stringEnd(bytes, from: index)
                (previous, last) = (last, index - 1)
                continue
            }
            if byte == UInt8(ascii: "}") || byte == UInt8(ascii: "]"), let last,
                bytes[last] == comma, let previous,
                ![comma, UInt8(ascii: "{"), UInt8(ascii: "[")].contains(bytes[previous])
            {
                blanked[last] = space
            }
            if !isWhitespace(byte) { (previous, last) = (last, index) }
            index += 1
        }
        return blanked
    }

    /// Whether the byte at `index` ends a line: a line feed, or a carriage return that no line
    /// feed follows, so `\n`, `\r\n` and a lone `\r` each end one line.
    public static func isLineBreak(_ bytes: [UInt8], at index: Int) -> Bool {
        bytes[index] == newline
            || (bytes[index] == carriageReturn
                && (index + 1 == bytes.count || bytes[index + 1] != newline))
    }

    /// The line, counted from 1, that the byte at `offset` is on.
    public static func line(at offset: Int, in bytes: [UInt8]) -> Int {
        1 + (0..<min(offset, bytes.count)).count { isLineBreak(bytes, at: $0) }
    }

    /// Whether `byte` is whitespace as JSON counts it.
    public static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == space || byte == tab || byte == newline || byte == carriageReturn
    }

    // MARK: Reading the shape

    /// A key of a config file's top-level object, and where its value is in the text.
    public struct Member: Equatable, Sendable {
        /// The key as JSON reads it, escapes and all.
        public let name: String
        /// The offset of the key's opening quote.
        public let keyStart: Int
        /// The value's text is `valueStart..<valueEnd`.
        public let valueStart: Int
        public let valueEnd: Int
        /// The offset of the comma after the value, if one follows it.
        public let comma: Int?
    }

    /// A config file's top-level object: the offsets of its braces, and its keys in the text's
    /// order.
    public struct Object: Equatable, Sendable {
        public let open: Int
        public let close: Int
        public let members: [Member]

        public func member(_ name: String) -> Member? {
            members.first { $0.name == name }
        }
    }

    /// Why `scan` can't read the text's shape: what it found, at an offset.
    public struct ScanError: Error, Equatable, Sendable {
        public let offset: Int
        public let reason: String
    }

    /// The top-level object of `bytes`, a config file's text, or why its shape isn't one the
    /// edits can read. Text that Foundation parses as one object always scans; a value is
    /// skipped over by its brackets and strings, not read.
    public static func scan(_ bytes: [UInt8]) throws(ScanError) -> Object {
        let text: [UInt8]
        switch blankingComments(bytes) {
        case .success(let blanked): text = blanked
        case .failure: throw ScanError(offset: 0, reason: "a /* comment isn't closed")
        }
        // An editor may start the file with a byte order mark; it stays where it is.
        let start = text.starts(with: byteOrderMark) ? byteOrderMark.count : 0
        var index = skippingWhitespace(text, from: start)
        guard index < text.count, text[index] == openBrace else {
            throw ScanError(offset: index, reason: "the text doesn't start with {")
        }
        let open = index
        index += 1
        var members: [Member] = []
        while true {
            index = skippingWhitespace(text, from: index)
            guard index < text.count else {
                throw ScanError(offset: open, reason: "the { isn't closed")
            }
            if text[index] == closeBrace { break }
            guard text[index] == quote else {
                throw ScanError(offset: index, reason: "a key isn't a string in quotes")
            }
            let keyStart = index
            index = stringEnd(text, from: index)
            let name = try Self.name(Array(text[keyStart..<index]), at: keyStart)
            index = skippingWhitespace(text, from: index)
            guard index < text.count, text[index] == UInt8(ascii: ":") else {
                throw ScanError(offset: keyStart, reason: "a key has no : after it")
            }
            let valueStart = skippingWhitespace(text, from: index + 1)
            guard valueStart < text.count else {
                throw ScanError(offset: keyStart, reason: "a key has no value")
            }
            let valueEnd = Self.valueEnd(text, from: valueStart)
            guard valueEnd > valueStart else {
                throw ScanError(offset: keyStart, reason: "a key has no value")
            }
            index = skippingWhitespace(text, from: valueEnd)
            var separator: Int?
            if index < text.count, text[index] == comma {
                separator = index
                index += 1
            } else if index >= text.count || text[index] != closeBrace {
                throw ScanError(offset: valueEnd, reason: "a value has no , or } after it")
            }
            members.append(
                Member(
                    name: name, keyStart: keyStart, valueStart: valueStart, valueEnd: valueEnd,
                    comma: separator))
        }
        let close = index
        index = skippingWhitespace(text, from: index + 1)
        guard index == text.count else {
            throw ScanError(offset: index, reason: "there is text after the closing }")
        }
        return Object(open: open, close: close, members: members)
    }

    /// A key's name from its text at `offset`, quotes and all, escapes read as JSON reads them.
    private static func name(_ quoted: [UInt8], at offset: Int) throws(ScanError) -> String {
        guard quoted.count >= 2, quoted.last == quote else {
            throw ScanError(offset: offset, reason: "a key's string isn't closed")
        }
        guard quoted.contains(backslash) else {
            return String(decoding: quoted.dropFirst().dropLast(), as: UTF8.self)
        }
        guard
            let name = try? JSONSerialization.jsonObject(
                with: Data(quoted), options: .fragmentsAllowed) as? String
        else { throw ScanError(offset: offset, reason: "a key isn't a JSON string") }
        return name
    }

    /// The offset just past the value that starts at `index`: a string, an array or object to
    /// its matching bracket, or anything else up to the next space, comma or bracket.
    private static func valueEnd(_ text: [UInt8], from index: Int) -> Int {
        if text[index] == quote { return stringEnd(text, from: index) }
        if text[index] == openBracket || text[index] == openBrace {
            var depth = 0
            var end = index
            repeat {
                if text[end] == quote {
                    end = stringEnd(text, from: end)
                    continue
                }
                if text[end] == openBracket || text[end] == openBrace { depth += 1 }
                if text[end] == closeBracket || text[end] == closeBrace { depth -= 1 }
                end += 1
            } while depth > 0 && end < text.count
            return end
        }
        var end = index
        while end < text.count, !isWhitespace(text[end]),
            ![comma, closeBrace, closeBracket].contains(text[end])
        {
            end += 1
        }
        return end
    }

    // MARK: Changing it

    /// `bytes` with `member`'s value made `value`, JSON's text for it.
    public static func replacing(_ member: Member, with value: String, in bytes: [UInt8])
        -> [UInt8]
    {
        var edited = bytes
        edited.replaceSubrange(member.valueStart..<member.valueEnd, with: Array(value.utf8))
        return edited
    }

    /// `bytes` with `member`, a key and its value as JSON text, put in `object` after its last
    /// key, at that key's indent, with `comment`'s lines above it as `//` comments and a blank
    /// line before them. An object on one line gets it on that line, with no comment, and an
    /// empty one on lines of its own. A comma after the last key, which the text may have, is
    /// matched. New lines end as the text's first line does.
    public static func inserting(
        _ member: String, comment: [String], into object: Object, in bytes: [UInt8]
    ) -> [UInt8] {
        guard case .success(let marked) = markingComments(bytes) else {
            preconditionFailure("inserting into text whose comments don't close")
        }
        var edited = bytes
        func insert(_ text: String, at index: Int) {
            edited.insert(contentsOf: Array(text.utf8), at: index)
        }
        let last = object.members.last
        let anchor = last.map { ($0.comma ?? ($0.valueEnd - 1)) + 1 } ?? object.open + 1
        let trailing = last?.comma != nil ? "," : ""
        let keyIndent =
            last.flatMap {
                startsLine($0.keyStart, in: bytes) ? indent(of: $0.keyStart, in: bytes) : nil
            }
            ?? indent(of: object.open, in: bytes) + indentUnit(of: object, in: bytes)
        let nl = lineEnding(of: bytes)
        let commentLines = comment.map { "\(keyIndent)// \($0)\(nl)" }.joined()
        let lineBreak = (anchor..<object.close).first {
            isLineBreak(bytes, at: $0) && !marked.inComment[$0]
        }
        if var lineBreak {
            if bytes[lineBreak] == newline, lineBreak > anchor,
                bytes[lineBreak - 1] == carriageReturn
            {
                lineBreak -= 1
            }
            let gap = comment.isEmpty || last == nil ? "" : nl
            insert("\(nl)\(gap)\(commentLines)\(keyIndent)\(member)\(trailing)", at: lineBreak)
            if let last, last.comma == nil { insert(",", at: last.valueEnd) }
        } else if last != nil {
            insert(trailing.isEmpty ? ", \(member)" : " \(member),", at: anchor)
        } else {
            let closing = indent(of: object.open, in: bytes)
            insert("\(nl)\(commentLines)\(keyIndent)\(member)\(nl)\(closing)", at: object.close)
        }
        return edited
    }

    /// The text's line break: its first line's, `\n` when it has one line.
    private static func lineEnding(of bytes: [UInt8]) -> String {
        guard let first = bytes.indices.first(where: { isLineBreak(bytes, at: $0) }) else {
            return "\n"
        }
        if bytes[first] == carriageReturn { return "\r" }
        return first > 0 && bytes[first - 1] == carriageReturn ? "\r\n" : "\n"
    }

    /// The offset of the first byte of `index`'s line.
    private static func lineStart(_ index: Int, in bytes: [UInt8]) -> Int {
        (bytes[..<index].indices.last { isLineBreak(bytes, at: $0) }).map { $0 + 1 } ?? 0
    }

    /// The spaces and tabs that start `index`'s line.
    private static func indent(of index: Int, in bytes: [UInt8]) -> String {
        let start = lineStart(index, in: bytes)
        let end = bytes[start...].firstIndex { $0 != space && $0 != tab } ?? bytes.count
        return String(decoding: bytes[start..<end], as: UTF8.self)
    }

    /// Whether only spaces and tabs come before `index` on its line.
    private static func startsLine(_ index: Int, in bytes: [UInt8]) -> Bool {
        bytes[lineStart(index, in: bytes)..<index].allSatisfy { $0 == space || $0 == tab }
    }

    /// One level of indent: that of `object`'s first key, or two spaces.
    private static func indentUnit(of object: Object, in bytes: [UInt8]) -> String {
        guard let first = object.members.first, startsLine(first.keyStart, in: bytes) else {
            return "  "
        }
        let unit = indent(of: first.keyStart, in: bytes)
        return unit.isEmpty ? "  " : unit
    }

    private static func skippingWhitespace(_ bytes: [UInt8], from index: Int) -> Int {
        var index = index
        while index < bytes.count, isWhitespace(bytes[index]) { index += 1 }
        return index
    }

    /// The offset just past the string whose opening quote is at `index`. JSON escapes a line
    /// break in a string, so an unclosed one ends at the end of the text.
    private static func stringEnd(_ bytes: [UInt8], from index: Int) -> Int {
        var end = index + 1
        while end < bytes.count, bytes[end] != quote {
            if bytes[end] == backslash { end += 1 }
            end += 1
        }
        return min(end + 1, bytes.count)
    }
}

private let quote = UInt8(ascii: "\"")
private let backslash = UInt8(ascii: "\\")
private let slash = UInt8(ascii: "/")
private let star = UInt8(ascii: "*")
private let comma = UInt8(ascii: ",")
private let space = UInt8(ascii: " ")
private let tab = UInt8(ascii: "\t")
private let newline = UInt8(ascii: "\n")
private let carriageReturn = UInt8(ascii: "\r")
private let openBrace = UInt8(ascii: "{")
private let closeBrace = UInt8(ascii: "}")
private let openBracket = UInt8(ascii: "[")
private let closeBracket = UInt8(ascii: "]")
private let byteOrderMark: [UInt8] = [0xEF, 0xBB, 0xBF]
