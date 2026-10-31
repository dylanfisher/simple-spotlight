import AppKit
import Search
import SwiftUI
import Testing

@testable import Interface

@MainActor
private func model() -> SettingsModel {
    SettingsModel(
        configFile: URL(filePath: "/tmp/simple-spotlight-test/config.json"),
        update: { _ throws(ConfigError) in }, openConfigFile: {}, openKeyboardShortcuts: {},
        recordingChanged: { _ in })
}

@MainActor @Test func showingAndClosingTracksTheWindow() {
    _ = NSApplication.shared
    let controller = SettingsWindowController(
        model: model(), title: "Simple Spotlight Settings", quit: {}, ordersWindow: false)
    #expect(!controller.isShown)

    controller.show()
    #expect(controller.isShown)

    controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
    #expect(!controller.isShown)
}

/// The window and its form are built when shown and let go when closed; the model keeps what
/// they show.
@MainActor @Test func closingReleasesTheWindowAndShowingBuildsAnother() {
    _ = NSApplication.shared
    let model = model()
    let controller = SettingsWindowController(
        model: model, title: "Simple Spotlight Settings", quit: {}, ordersWindow: false)
    model.receive(
        ConfigStore.State(
            settings: settings(maxResults: 3), errors: [], isFileBroken: false))
    controller.show()
    let first = controller.window
    #expect(first != nil)

    controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
    #expect(controller.window == nil)

    controller.show()
    #expect(controller.window != nil)
    #expect(controller.window !== first)
    #expect(model.settings.maxResults == 3)
}

@MainActor @Test func closingTheWindowStopsARecording() {
    _ = NSApplication.shared
    let model = model()
    let controller = SettingsWindowController(
        model: model, title: "Simple Spotlight Settings", quit: {}, ordersWindow: false)
    controller.show()
    model.recorder.start()
    #expect(model.recorder.isRecording)

    controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))

    #expect(!model.recorder.isRecording)
}

@MainActor @Test func closingStopsARecording() {
    _ = NSApplication.shared
    let model = model()
    let controller = SettingsWindowController(
        model: model, title: "Simple Spotlight Settings", quit: {}, ordersWindow: false)
    controller.show()
    model.recorder.start()

    controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))

    #expect(!model.recorder.isRecording)
}

/// Lays the form out off screen, with a file error and a hotkey conflict showing, so a view
/// that traps when built fails here rather than in the app.
@MainActor @Test func theFormLaysOut() {
    _ = NSApplication.shared
    let model = model()
    model.receive(
        ConfigStore.State(
            settings: Search.Settings(), errors: [ConfigError(line: 3, reason: "bad")],
            isFileBroken: true))
    model.hotKeyConflict = SettingsModel.Conflict(
        chord: KeyChord(.command, .space), conflict: .systemShortcut)
    let view = NSHostingView(rootView: SettingsView(model: model))

    view.layoutSubtreeIfNeeded()

    #expect(view.fittingSize.width == SettingsView.width)
    #expect(view.fittingSize.height > 0)
}

@MainActor
private final class KeyWindow: NSObject, NSWindowDelegate {
    let window: SettingsWindow
    var quits = 0
    var closes = 0

    override init() {
        _ = NSApplication.shared
        window = SettingsWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        super.init()
        window.quit = { [unowned self] in quits += 1 }
        window.delegate = self
    }

    func windowWillClose(_ notification: Notification) {
        closes += 1
    }

    func command(_ characters: String, keyCode: UInt16) throws -> Bool {
        window.performKeyEquivalent(
            with: try keyEvent(characters, modifiers: .command, keyCode: keyCode))
    }
}

@MainActor @Test func commandWAndQCloseAndQuitOnALatinLayout() throws {
    let keys = KeyWindow()

    #expect(try keys.command("w", keyCode: 13))
    #expect(keys.closes == 1)
    #expect(try keys.command("q", keyCode: 12))
    #expect(keys.quits == 1)
}

@MainActor @Test func commandWAndQCloseAndQuitOnACyrillicLayout() throws {
    let keys = KeyWindow()

    #expect(try keys.command("ц", keyCode: 13))
    #expect(keys.closes == 1)
    #expect(try keys.command("й", keyCode: 12))
    #expect(keys.quits == 1)
}

private func settings(maxResults: Int) -> Search.Settings {
    var settings = Search.Settings()
    settings.maxResults = maxResults
    return settings
}

@MainActor @Test func theKeysGoBackOnlyWhileNoOtherAppHasThem() throws {
    let other = try #require(
        NSWorkspace.shared.runningApplications.first { $0 != .current && !$0.isTerminated })
    let current = NSRunningApplication.current

    #expect(SettingsWindowController.appToReturnTo(previous: other, frontmost: current) === other)
    #expect(SettingsWindowController.appToReturnTo(previous: other, frontmost: nil) === other)
    // Another app, even the one the window came from, already has the keys.
    #expect(SettingsWindowController.appToReturnTo(previous: other, frontmost: other) == nil)
    #expect(SettingsWindowController.appToReturnTo(previous: nil, frontmost: current) == nil)
}
