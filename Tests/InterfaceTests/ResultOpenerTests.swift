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

@MainActor @Test func revealingAFileThatIsGoneReportsIt() async {
    var errors: [String] = []
    let opener = WorkspaceOpener(reportError: { errors.append(String(describing: $0)) })
    let gone = URL(filePath: "/simple-spotlight-\(UUID().uuidString).app")

    opener.reveal(gone)
    await opener.revealed?.value

    #expect(errors.count == 1)
    #expect(errors.first?.contains(gone.path(percentEncoded: false)) == true)
}
