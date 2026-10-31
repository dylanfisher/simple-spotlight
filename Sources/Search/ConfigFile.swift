import Base
import Foundation

/// The config file's format: one JSON object holding any of the keys in `Settings.Keys`, with
/// `//` and `/* */` comments and a comma after the last item allowed (`ConfigText`). A key left
/// out keeps its default.
///
/// A file with any error sets nothing. Text that isn't JSON is one error, on its line; a key
/// the file can't have, a value its key can't take, and a key given twice are each an error
/// that names the key, on its line (docs/decisions/0006-config-file.md).
public enum ConfigFile {
    /// The file's name in its folder.
    public static let name = "config.json"
    /// The most bytes a config file may have. The default file is under 1 KB; a file this large
    /// is something else, and reading it whole would hold up the store.
    public static let largestSize = 1_000_000
    /// The most errors reported for one file; the rest are counted in a last error.
    public static let mostErrors = 20

    /// What a read of the file found.
    public enum Outcome: Equatable, Sendable {
        /// Every key good: the settings the file sets, each key it leaves out at its default.
        case settings(Settings)
        /// What is wrong, by line; the file sets nothing.
        case failed([ConfigError])
    }

    /// What `data` sets, or every error in it.
    public static func parse(_ data: Data) -> Outcome {
        func failed(_ reason: String, line: Int? = nil) -> Outcome {
            .failed([ConfigError(line: line, reason: reason)])
        }
        guard data.count <= largestSize else {
            return failed("is too large: a config file has at most \(largestSize) bytes")
        }
        guard String(data: data, encoding: .utf8) != nil else {
            return failed("isn't UTF-8 text")
        }
        let uncommented: [UInt8]
        switch ConfigText.blankingComments(Array(data)) {
        case .success(let blanked): uncommented = blanked
        case .failure(let unclosed):
            return failed("has a /* comment that isn't closed with */", line: unclosed.line)
        }
        if uncommented.allSatisfy(ConfigText.isWhitespace) {
            return failed("is empty: it needs a JSON object, such as {}")
        }
        // Comments and trailing commas are blanked byte for byte, so an offset in `json` is the
        // same in `data`, and so is its line.
        let json = Data(ConfigText.blankingTrailingCommas(uncommented))
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: json)
        } catch let error as NSError {
            return .failed([syntaxError(error, in: data)])
        }
        guard let dictionary = object as? [String: Any] else {
            return failed("must be a JSON object, its keys and values in braces", line: 1)
        }
        // Foundation keeps the last of a key given twice and says nothing.
        let keys = keyLines(in: json)
        if !keys.duplicates.isEmpty { return .failed(capped(keys.duplicates)) }
        var settings = Settings()
        var errors: [ConfigError] = []
        for (name, value) in dictionary {
            let line = keys.lines[name]
            guard let key = keysByName[name] else {
                errors.append(ConfigError(line: line, key: name, reason: "unknown key \"\(name)\""))
                continue
            }
            if let reason = key.read(value, into: &settings) {
                errors.append(ConfigError(line: line, key: name, reason: reason))
            }
        }
        guard errors.isEmpty else {
            return .failed(
                capped(
                    errors.sorted { ($0.line ?? 0, $0.key ?? "") < ($1.line ?? 0, $1.key ?? "") }))
        }
        return .settings(settings)
    }

    /// `data`, a config file's text, with what `change` does to its settings written in: each
    /// key whose value changes has its value's text replaced, or goes in after the last key with
    /// its comment when the file leaves it out, and every other byte stays as the user wrote it
    /// (`ConfigText`). Nil when the file's settings already are what `change` makes them, so
    /// nothing needs writing. A file with an error isn't changed: the user is fixing it, and
    /// its settings aren't known.
    public static func changing(_ data: Data, _ change: (inout Settings) -> Void)
        throws(ConfigError) -> Data?
    {
        guard case .settings(let old) = parse(data) else {
            throw ConfigError(reason: "has an error, so nothing is saved to it until it's fixed")
        }
        var new = old
        change(&new)
        guard new != old else { return nil }
        var bytes = Array(data)
        for key in Settings.Keys.all where key.differs(old, new) {
            let root: ConfigText.Object
            do {
                root = try ConfigText.scan(bytes)
            } catch {
                throw ConfigError(
                    line: ConfigText.line(at: error.offset, in: bytes),
                    reason: "couldn't be changed: \(error.reason)")
            }
            let value = key.text(in: new)
            bytes =
                root.member(key.name).map { ConfigText.replacing($0, with: value, in: bytes) }
                ?? ConfigText.inserting(
                    "\(json(key.name)): \(value)", comment: key.comment, into: root, in: bytes)
        }
        return Data(bytes)
    }

    /// The file written where there is none: every key at its default, in the order
    /// `Settings.Keys.all` gives them, each with its comment above it, as in Sublime Text's
    /// settings.
    public static let defaultText: String = {
        let entries = Settings.Keys.all.map { key in
            key.comment.map { "  // \($0)\n" }.joined() + "  \(json(key.name)): \(key.defaultText)"
        }
        return "{\n" + entries.joined(separator: ",\n\n") + "\n}\n"
    }()

    /// `value`, a string or a value `JSONSerialization` read, as JSON text: the file's own
    /// spelling, for errors that quote it and for the default file.
    static func json(_ value: Any) -> String {
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: value,
                options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes])
        else { preconditionFailure("\(value) didn't encode as JSON") }
        return String(decoding: data, as: UTF8.self)
    }

    /// The first `mostErrors` of `errors`, the last of them standing for the rest.
    private static func capped(_ errors: [ConfigError]) -> [ConfigError] {
        guard errors.count > mostErrors else { return errors }
        let shown = errors.prefix(mostErrors - 1)
        return shown + [ConfigError(reason: "and \(errors.count - shown.count) more errors")]
    }

    private static let keysByName = Dictionary(
        uniqueKeysWithValues: Settings.Keys.all.map { ($0.name, $0) })

    /// The line of each key of the top-level object in `data`, valid JSON, and an error for
    /// each key an object has a second time, on that line, named by its path (`a.b`).
    private static func keyLines(in data: Data) -> (lines: [String: Int], duplicates: [ConfigError])
    {
        struct Object {
            let path: String?
            var lines: [String: Int] = [:]
        }
        enum Container {
            case object(Object)
            case array
        }
        // The innermost object or array is kept apart from those around it, so recording a
        // key changes it in place rather than copying its dictionary out of an array.
        var current: Container?
        var enclosing: [Container?] = []
        var errors: [ConfigError] = []
        var line = 1
        var lastKey: String?
        let bytes = Array(data)
        let quote = UInt8(ascii: "\"")
        let backslash = UInt8(ascii: "\\")
        var index = 0
        while index < bytes.count {
            if ConfigText.isLineBreak(bytes, at: index) { line += 1 }
            switch bytes[index] {
            case quote:
                // JSON escapes a line break in a string, so the string ends on this line.
                var end = index + 1
                var escaped = false
                while end < bytes.count, bytes[end] != quote {
                    if bytes[end] == backslash {
                        escaped = true
                        end += 1
                    }
                    end += 1
                }
                let quoted = bytes[index...min(end, bytes.count - 1)]
                index = end
                var next = end + 1
                while next < bytes.count, ConfigText.isWhitespace(bytes[next]) { next += 1 }
                guard next < bytes.count, bytes[next] == UInt8(ascii: ":"),
                    case .object(var object) = current
                else { break }
                current = nil
                // The name as JSON reads it, escapes and all, so it matches the dictionary's.
                let name =
                    escaped
                    ? (try? JSONSerialization.jsonObject(
                        with: Data(quoted), options: .fragmentsAllowed) as? String)
                        ?? String(decoding: quoted.dropFirst().dropLast(), as: UTF8.self)
                    : String(decoding: quoted.dropFirst().dropLast(), as: UTF8.self)
                let path = object.path.map { "\($0).\(name)" } ?? name
                if let first = object.lines[name] {
                    errors.append(
                        ConfigError(
                            line: line, key: path,
                            reason: "\(path) is set twice, first on line \(first)"))
                } else {
                    object.lines[name] = line
                }
                current = .object(object)
                lastKey = path
            case UInt8(ascii: "{"):
                enclosing.append(current)
                current = .object(Object(path: enclosing.count == 1 ? nil : lastKey))
                lastKey = nil
            case UInt8(ascii: "["):
                enclosing.append(current)
                current = .array
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                // The top-level object is the last to close, so its lines are what is left.
                if enclosing.count == 1, case .object(let top) = current {
                    return (top.lines, errors)
                }
                current = enclosing.popLast() ?? nil
            default:
                break
            }
            index += 1
        }
        return ([:], errors)
    }

    /// The error for text that isn't JSON, on the line Foundation's error points into.
    /// Foundation gives the offset of the byte it stopped at, and a description that ends with
    /// where that is; the line comes from the offset, and the description's tail is dropped.
    private static func syntaxError(_ error: NSError, in data: Data) -> ConfigError {
        let line = (error.userInfo["NSJSONSerializationErrorIndex"] as? Int).map { index in
            ConfigText.line(at: index, in: Array(data))
        }
        let description = (error.userInfo[NSDebugDescriptionErrorKey] as? String)?
            .replacingOccurrences(
                of: #"\s*around line \d+, column \d+\.?$"#, with: "",
                options: .regularExpression)
        let reason = description.map { "isn't valid JSON: \($0)" } ?? "isn't valid JSON"
        return ConfigError(line: line, reason: reason)
    }
}
