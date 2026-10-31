/// A config file's text made readable by Foundation's JSON parser: JSON with `//` and `/* */`
/// comments and a comma allowed after an object's or array's last item, as Sublime Text's
/// settings are.
///
/// Each comment and trailing comma is made spaces byte for byte, keeping line breaks, so an
/// offset into the result is the same offset, on the same line, in the file.
public enum ConfigText {
    /// Why text can't be read past its comments: a block comment not closed, on the line it
    /// opens on.
    public struct UnclosedComment: Error, Equatable {
        public let line: Int
    }

    /// `bytes` with each comment's bytes made spaces, its line breaks kept.
    public static func blankingComments(_ bytes: [UInt8]) -> Result<[UInt8], UnclosedComment> {
        var blanked = bytes
        func blank(_ index: Int) {
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
            if byte == newline { line += 1 }
            let next = index + 1 < bytes.count ? bytes[index + 1] : nil
            if byte == slash, next == slash {
                while index < bytes.count, bytes[index] != newline {
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
                    if bytes[index] == newline { line += 1 }
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
        return .success(blanked)
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

    /// Whether `byte` is whitespace as JSON counts it.
    public static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == space || byte == tab || byte == newline || byte == carriageReturn
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
