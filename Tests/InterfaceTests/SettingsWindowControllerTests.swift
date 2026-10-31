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
