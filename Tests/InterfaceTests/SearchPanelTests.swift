import AppKit
import Testing

@testable import Interface

@MainActor @Test func thePanelFloatsOverEverySpaceWithoutActivatingTheApp() {
    let panel = SearchPanel()

    #expect(panel.styleMask.contains(.borderless))
    #expect(panel.styleMask.contains(.nonactivatingPanel))
    #expect(panel.level == .floating)
    #expect(panel.collectionBehavior.contains(.canJoinAllSpaces))
    #expect(panel.collectionBehavior.contains(.fullScreenAuxiliary))
    #expect(panel.canBecomeKey)
    #expect(!panel.canBecomeMain)
    #expect(!panel.isOpaque)
    #expect(!panel.isVisible)
}

@MainActor @Test func thePanelIsTheFieldAloneWithNoRows() {
    #expect(SearchPanel.height(rows: 0) == SearchPanel.fieldHeight)
    #expect(SearchPanel.height(rows: 2) - SearchPanel.height(rows: 1) == ResultRow.height)
}

@MainActor @Test func fitKeepsTheTopEdge() {
    let panel = SearchPanel()
    panel.setFrameTopLeftPoint(NSPoint(x: 100, y: 800))

    panel.fit(rows: 3)

    #expect(panel.frame.maxY == 800)
    #expect(panel.frame.minX == 100)
    #expect(panel.frame.height == SearchPanel.height(rows: 3))
}

@MainActor @Test func theTopSitsAt22PercentOfTheScreenCenteredAcross() {
    let screen = NSRect(x: 1000, y: 0, width: 2000, height: 1000)

    let origin = SearchPanel.topLeft(on: screen)

    #expect(origin == NSPoint(x: 1000 + (2000 - SearchPanel.width) / 2, y: 780))
}

@MainActor @Test func anyCommandChordTheHandlerRefusesGoesToThePanel() throws {
    let panel = SearchPanel()
    var offered: [String] = []
    panel.keyEquivalent = { event in
        offered.append(event.charactersIgnoringModifiers ?? "")
        return event.charactersIgnoringModifiers == "q"
    }

    #expect(panel.performKeyEquivalent(with: try keyEvent("q", modifiers: .command)))
    #expect(!panel.performKeyEquivalent(with: try keyEvent("t", modifiers: .command)))
    #expect(offered == ["q", "t"])
}

@MainActor @Test func theRowsThatFitBelowATopAreCounted() {
    let room = SearchPanel.height(rows: 3)

    #expect(SearchPanel.rows(fitting: room) == 3)
    #expect(SearchPanel.rows(fitting: room - 1) == 2)
    #expect(SearchPanel.rows(fitting: SearchPanel.fieldHeight) == 0)
    #expect(SearchPanel.rows(fitting: 10) == 0)
}
