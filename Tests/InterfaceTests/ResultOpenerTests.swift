import AppKit
import Testing

@testable import Interface

@MainActor @Test func copyPutsTheTextAloneOnThePasteboard() throws {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("simple-spotlight-\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }
    pasteboard.setString("old", forType: .rtf)
    let opener = WorkspaceOpener(pasteboard: pasteboard, reportError: { Issue.record($0) })

    opener.copy("2000")

    #expect(pasteboard.string(forType: .string) == "2000")
    #expect(pasteboard.data(forType: .rtf) == nil)
}
