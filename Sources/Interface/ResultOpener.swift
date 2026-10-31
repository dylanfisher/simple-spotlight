import AppKit

/// Opens what a row points at. A protocol so tests can record the calls rather than launch
/// apps or write to the clipboard.
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

    public func reveal(_ url: URL) {
        workspace.activateFileViewerSelecting([url])
    }

    public func copy(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// The workspace calls back on a queue of its own.
    private nonisolated func report(_ app: NSRunningApplication?, _ error: (any Error)?) {
        guard let error else { return }
        Task { @MainActor in self.reportError(error) }
    }
}
