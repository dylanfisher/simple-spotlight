import AppKit

/// Opens what a row points at, and reaches the clipboard for the field. A protocol so tests can
/// record the calls rather than launch apps or touch the user's clipboard.
@MainActor
public protocol ResultOpener {
    /// Launches the app at `url`, or brings it forward if it runs.
    func openApplication(at url: URL)
    /// Opens a file with its default app, or a URL with its handler.
    func open(_ url: URL)
    /// Shows the file at `url` selected in Finder.
    func reveal(_ url: URL)
    /// Puts `text` alone on the clipboard.
    func copy(_ text: String)
    /// The clipboard's plain text, if it holds any.
    func clipboardText() -> String?
}

/// Opens rows through `NSWorkspace` and copies to a pasteboard, the general one in the app.
@MainActor
public final class WorkspaceOpener: ResultOpener {
    private let workspace: NSWorkspace
    private let pasteboard: NSPasteboard
    /// Told when the workspace can't open something, on the main actor.
    private let reportError: @MainActor (any Error) -> Void

    public init(
        workspace: NSWorkspace = .shared, pasteboard: NSPasteboard = .general,
        reportError: @escaping @MainActor (any Error) -> Void
    ) {
        self.workspace = workspace
        self.pasteboard = pasteboard
        self.reportError = reportError
    }

    public func openApplication(at url: URL) {
        workspace.openApplication(
            at: url, configuration: NSWorkspace.OpenConfiguration(),
            completionHandler: report(_:_:))
    }

    public func open(_ url: URL) {
        workspace.open(
            url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: report(_:_:))
    }

    /// The check of the file `reveal` started last, for tests to wait on.
    private(set) var revealed: Task<Void, Never>?

    /// Finder opens with nothing selected for a file that is gone, so a gone file is reported
    /// instead. Whether it is there is asked off the main actor.
    public func reveal(_ url: URL) {
        revealed = Task {
            guard await Self.exists(url) else {
                reportError(OpenerError(description: "\(url.path(percentEncoded: false)) is gone"))
                return
            }
            workspace.activateFileViewerSelecting([url])
        }
    }

    public func copy(_ text: String) {
        pasteboard.clearContents()
        if !pasteboard.setString(text, forType: .string) {
            reportError(OpenerError(description: "couldn't copy \(text) to the clipboard"))
        }
    }

    public func clipboardText() -> String? {
        pasteboard.string(forType: .string)
    }

    @concurrent
    private nonisolated static func exists(_ url: URL) async -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    /// The workspace calls back on a queue of its own.
    private nonisolated func report(_ app: NSRunningApplication?, _ error: (any Error)?) {
        guard let error else { return }
        Task { @MainActor in self.reportError(error) }
    }
}

/// Something the opener couldn't do, in words.
struct OpenerError: Error, CustomStringConvertible {
    let description: String
}
