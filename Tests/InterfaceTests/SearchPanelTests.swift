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

/// The views under `view`, `view` first.
@MainActor private func descendants(of view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap(descendants)
}

/// Liquid Glass turns lighter or darker with what is behind it; the blur's look follows only
/// light and dark appearance (docs/decisions/0008-search-panel-window.md).
@MainActor @Test func theBackdropIsABlurWhoseLookFollowsOnlyTheAppearance() throws {
    let panel = SearchPanel()
    panel.install(rows: NSView())

    let views = descendants(of: try #require(panel.contentView))
    let blur = try #require(views.compactMap { $0 as? NSVisualEffectView }.first)
    #expect(blur.blendingMode == .behindWindow)
    #expect(blur.state == .active)
    if #available(macOS 26, *) {
        #expect(!views.contains { $0 is NSGlassEffectView })
    }
}

@MainActor
private func flagsChanged(_ flags: NSEvent.ModifierFlags, in panel: SearchPanel) throws -> NSEvent {
    try #require(
        NSEvent.keyEvent(
            with: .flagsChanged, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, characters: "",
            charactersIgnoringModifiers: "", isARepeat: false, keyCode: 0x3A))
}

@MainActor @Test func theGearShowsOnlyWhileOptionIsHeld() throws {
    let panel = SearchPanel()
    panel.install(rows: NSView())
    #expect(panel.gear.isHidden)
    let fullField = panel.field.frame.width

    panel.sendEvent(try flagsChanged(.option, in: panel))
    #expect(!panel.gear.isHidden)
    #expect(panel.field.frame.maxX <= panel.gear.frame.minX)
    #expect(panel.field.frame.width < fullField)

    panel.sendEvent(try flagsChanged([.option, .shift], in: panel))
    #expect(!panel.gear.isHidden)

    panel.sendEvent(try flagsChanged([], in: panel))
    #expect(panel.gear.isHidden)
    #expect(panel.field.frame.width == fullField)
}

@MainActor @Test func theGearOpensSettingsAndSaysSo() {
    let panel = SearchPanel()
    panel.install(rows: NSView())
    var opened = 0
    panel.openSettings = { opened += 1 }

    panel.showGear(true)
    panel.gear.performClick(nil)

    #expect(opened == 1)
    #expect(panel.gear.accessibilityLabel() == "Settings")
    #expect(panel.gear.toolTip == "Settings (⌘,)")
}

@MainActor @Test func theBreadcrumbShowsEachGroupOpenAndMakesRoomForItself() {
    let panel = SearchPanel()
    panel.install(rows: NSView())
    #expect(panel.breadcrumb.isHidden)
    let fullField = panel.field.frame

    panel.showPath(["Living Room"])
    #expect(!panel.breadcrumb.isHidden)
    #expect(panel.breadcrumb.title == "Living Room ›")
    #expect(panel.field.frame.minX > panel.breadcrumb.frame.maxX)
    #expect(panel.field.frame.maxX == fullField.maxX)
    #expect(panel.breadcrumb.frame.midY == panel.field.frame.midY)

    panel.showPath(["Living Room", "Zones"])
    #expect(panel.breadcrumb.title == "Living Room › Zones ›")
    #expect(panel.field.frame.minX > panel.breadcrumb.frame.maxX)

    panel.showPath([])
    #expect(panel.breadcrumb.isHidden)
    #expect(panel.field.frame == fullField)
}

/// A long path keeps the field room to type in; the breadcrumb cuts its start, so the group
/// open now still shows.
@MainActor @Test func aLongBreadcrumbLeavesTheFieldRoom() {
    let panel = SearchPanel()
    panel.install(rows: NSView())

    panel.showPath(Array(repeating: "A Group With A Long Name", count: 6))

    #expect(panel.field.frame.width >= SearchPanel.width / 2)
}

@MainActor @Test func aClickOnTheBreadcrumbGoesUpAndVoiceOverReadsItAsAButton() throws {
    let panel = SearchPanel()
    panel.install(rows: NSView())
    var wentUp = 0
    panel.goUp = { wentUp += 1 }

    panel.showPath(["Living Room", "Zones"])
    panel.breadcrumb.performClick(nil)

    #expect(wentUp == 1)
    // A button's cell is the element VoiceOver reads.
    let cell = try #require(panel.breadcrumb.cell)
    #expect(cell.accessibilityRole() == .button)
    #expect(cell.accessibilityLabel() == "Living Room, Zones")
    #expect(panel.breadcrumb.toolTip == "Go up a level (⇧⇥)")
    #expect(panel.breadcrumb.refusesFirstResponder)
}
