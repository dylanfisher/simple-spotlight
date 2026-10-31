/// Something wrong with the config file: where its text isn't JSON, a key it can't have or a
/// value a key can't take, or the file as a whole, as one that can't be read. A file with any
/// error sets nothing (docs/decisions/0006-config-file.md).
public struct ConfigError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The line it is on, counted from 1; nil for an error that isn't on a line.
    public let line: Int?
    /// The key it is about, as the file spells it; nil for an error with no key.
    public let key: String?
    /// What is wrong, in a phrase that names the key when there is one:
    /// `maxResults must be a whole number from 1 to 20, not 30`.
    public let reason: String

    public init(line: Int?, key: String?, reason: String) {
        self.line = line
        self.key = key
        self.reason = reason
    }

    /// The reason after the line it is on: `line 3: isn't valid JSON: …`.
    public var description: String {
        line.map { "line \($0): \(reason)" } ?? reason
    }
}
