import Foundation

/// A folder or bundle the index left out, and why, so the panel can say so instead of quietly
/// missing an app.
public struct IndexProblem: Error, Sendable, Equatable, CustomStringConvertible {
    public let path: String
    /// A plain sentence, such as "The folder doesn't exist."
    public let reason: String

    public init(path: String, reason: String) {
        self.path = path
        self.reason = reason
    }

    /// The problem `error` describes for the file at `url`: the error itself when it is already
    /// a problem, else the error's description for that path.
    init(_ url: URL, _ error: any Error) {
        if let problem = error as? IndexProblem {
            self = problem
        } else if case CocoaError.fileReadNoSuchFile = error {
            self.init(path: url.path, reason: "It doesn't exist.")
        } else {
            self.init(path: url.path, reason: error.localizedDescription)
        }
    }

    public var description: String { "\(path): \(reason)" }
}
