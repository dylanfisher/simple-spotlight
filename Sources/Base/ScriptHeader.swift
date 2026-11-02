import Foundation

/// What a script file says about itself in its leading comment lines.
///
/// A tag sits on its own `#` or `//` comment line: `# @title TV`. Reading stops at the first line
/// that is not blank and not a comment. The shebang is a `#` comment, so it passes like any other
/// comment line, as does a comment that is not a tag.
public struct ScriptHeader: Equatable, Sendable {
    /// A header line that could not be read, with its 1-based line number.
    public struct Problem: Equatable, Sendable {
        public let line: Int
        public let message: String
    }

    /// Only this many bytes from the start of a file are read, so a large binary costs nothing.
    /// A caller can read just this much of a file. A line the limit cuts through is dropped.
    public static let readLimit = 4096

    /// `@title`, or the default title `parse` was given.
    public let title: String
    public let subtitle: String?
    /// The words of `@keywords`.
    public let keywords: [String]
    public let isTopLevel: Bool
    public let errors: [Problem]

    /// The header in the start of `bytes`, a file's content. The title defaults to `fileName`
    /// without its extension.
    public static func parse(_ bytes: [UInt8], fileName: String) -> ScriptHeader {
        parse(bytes, defaultTitle: (fileName as NSString).deletingPathExtension)
    }

    /// The header in the start of `bytes`, with `defaultTitle` as the title when it has none.
    public static func parse(_ bytes: [UInt8], defaultTitle: String) -> ScriptHeader {
        let cutShort = bytes.count > readLimit
        // Split on bytes: Swift reads "\r\n" as one Character, which a "\n" split would miss.
        var lines = bytes.prefix(readLimit)
            .split(separator: newline, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
        // The last line is unfinished when the cut fell inside it.
        if cutShort, bytes[readLimit - 1] != newline { lines.removeLast() }

        var title: String?
        var subtitle: String?
        var keywords: [String]?
        var isTopLevel = false
        var seen = Set<String>()
        var errors: [Problem] = []

        for (offset, raw) in lines.enumerated() {
            let number = offset + 1
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            guard let body = commentBody(line) else { break }
            guard body.hasPrefix("@") else { continue }

            let parts = body.dropFirst().split(
                maxSplits: 1, omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
            let tag = parts.first.map(String.init) ?? ""
            let value = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
            func fail(_ message: String) { errors.append(Problem(line: number, message: message)) }

            guard tags.contains(tag) else {
                fail("unknown tag @\(tag)")
                continue
            }
            guard seen.insert(tag).inserted else {
                fail("@\(tag) is given more than once")
                continue
            }
            if tag == "top-level" {
                if value.isEmpty { isTopLevel = true } else { fail("@top-level takes no value") }
            } else if value.isEmpty {
                fail("@\(tag) needs a value")
            } else {
                switch tag {
                case "title": title = value
                case "subtitle": subtitle = value
                default: keywords = value.split(whereSeparator: \.isWhitespace).map(String.init)
                }
            }
        }

        return ScriptHeader(
            title: title ?? defaultTitle,
            subtitle: subtitle, keywords: keywords ?? [], isTopLevel: isTopLevel, errors: errors)
    }

    private static let tags: Set<String> = ["title", "subtitle", "keywords", "top-level"]
    private static let newline: UInt8 = 0x0A

    /// The text after a leading `#` or `//` marker, trimmed, or nil if `line` is not a comment.
    private static func commentBody(_ line: String) -> String? {
        for marker in ["#", "//"] where line.hasPrefix(marker) {
            return line.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }
}
