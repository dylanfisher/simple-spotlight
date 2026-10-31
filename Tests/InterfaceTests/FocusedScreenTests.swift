import AppKit
import Testing

@testable import Interface

/// Two screens side by side, the primary one on the left, 1000 pt tall, and a shorter one to
/// its right whose bottom edge lines up with the primary's: AppKit frames, origin at the
/// primary's bottom-left.
private let primary = NSRect(x: 0, y: 0, width: 1600, height: 1000)
private let right = NSRect(x: 1600, y: 0, width: 1200, height: 800)
private let screens = [primary, right]

/// In the window server's coordinates, origin at the primary's top-left and y growing down, the
/// right screen spans y 200 to 1000.
@Test func aWindowIsOnTheScreenItOverlapsMost() {
    let mostlyRight = CGRect(x: 1500, y: 300, width: 600, height: 400)

    #expect(FocusedScreen.index(windows: [mostlyRight], screens: screens) == 1)
    #expect(
        FocusedScreen.index(
            windows: [CGRect(x: 100, y: 100, width: 800, height: 600)], screens: screens)
            == 0)
}

/// A window high on the right of the primary screen, at window-server y 0 to 150, is above the
/// right screen's top (window-server y 200), so it doesn't overlap the right screen at all. Read
/// without flipping y, it would.
@Test func theWindowServersYIsFlipped() {
    let window = CGRect(x: 1500, y: 0, width: 400, height: 150)

    #expect(FocusedScreen.index(windows: [window], screens: screens) == 0)
}

/// The frontmost window that is on a screen decides; one off every screen is passed over.
@Test func theFrontmostWindowOnAScreenDecides() {
    let offscreen = CGRect(x: -5000, y: 0, width: 100, height: 100)
    let onRight = CGRect(x: 2000, y: 400, width: 300, height: 300)
    let onPrimary = CGRect(x: 100, y: 100, width: 300, height: 300)

    #expect(FocusedScreen.index(windows: [offscreen, onRight, onPrimary], screens: screens) == 1)
}

@Test func noWindowOnAScreenGivesNoScreen() {
    #expect(FocusedScreen.index(windows: [], screens: screens) == nil)
    #expect(
        FocusedScreen.index(
            windows: [CGRect(x: -5000, y: 0, width: 100, height: 100)], screens: screens) == nil)
}
