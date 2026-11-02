import AppKit
import Search
import SwiftUI
import Testing

@testable import Interface

@MainActor
private func model() -> SettingsModel {
    SettingsModel(
        configFile: URL(filePath: "/tmp/simple-spotlight-test/config.json"),
        update: { _ throws(ConfigError) in }, openConfigFile: {}, revealConfigFile: {},
        copy: { _ in }, openKeyboardShortcuts: {}, recordingChanged: { _ in })
}

@MainActor
private func controller(
    _ model: SettingsModel = model(), spotlight: StubSpotlightIndex = StubSpotlightIndex(),
    quit: @escaping @MainActor () -> Void = {}
) -> SettingsWindowController {
    SettingsWindowController(
        model: model, spotlight: SpotlightIndexModel(service: spotlight),
        appName: "Simple Spotlight", quitTitle: "Quit Simple Spotlight", quit: quit,
        ordersWindow: false)
}

@MainActor @Test func showingAndClosingTracksTheWindow() {
    _ = NSApplication.shared
    let controller = controller()
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
    let controller = controller(model)
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

/// The Quit button calls what the controller was given, under the title it was given.
@MainActor @Test func theQuitButtonRunsTheInjectedQuit() {
    var quits = 0
    let controller = controller(quit: { quits += 1 })

    controller.rootView(.general).quit()

    #expect(quits == 1)
    #expect(controller.rootView(.general).quitTitle == "Quit Simple Spotlight")
}

@MainActor @Test func closingTheWindowStopsARecording() {
    _ = NSApplication.shared
    let model = model()
    let controller = controller(model)
    controller.show()
    model.recorder.start()
    #expect(model.recorder.isRecording)

    controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))

    #expect(!model.recorder.isRecording)
}

@MainActor @Test func closingStopsARecording() {
    _ = NSApplication.shared
    let model = model()
    let controller = controller(model)
    controller.show()
    model.recorder.start()

    controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))

    #expect(!model.recorder.isRecording)
}

/// Lays each pane out off screen, with a file error and a hotkey conflict showing, so a view
/// that traps when built fails here rather than in the app.
@MainActor @Test func everyPaneLaysOut() {
    _ = NSApplication.shared
    let model = model()
    model.receive(
        ConfigStore.State(
            settings: Search.Settings(), errors: [ConfigError(line: 3, reason: "bad")],
            isFileBroken: true))
    model.hotKeyConflict = SettingsModel.Conflict(
        chord: KeyChord(.command, .space), conflict: .systemShortcut)
    let controller = controller(model)

    for pane in SettingsPane.allCases {
        let view = NSHostingView(rootView: controller.rootView(pane))
        view.layoutSubtreeIfNeeded()

        #expect(view.fittingSize.width == SettingsView.width, "\(pane)")
        #expect(view.fittingSize.height > 0, "\(pane)")
    }
}

@MainActor @Test func theWindowHasAToolbarItemForEachPaneAndOpensOnGeneral() throws {
    _ = NSApplication.shared
    let controller = controller()

    controller.show()

    let window = try #require(controller.window)
    #expect(window.toolbar?.items.map(\.label) == SettingsPane.allCases.map(\.title))
    #expect(window.toolbar?.selectedItemIdentifier == SettingsPane.general.item)
    #expect(window.title == "General")
    #expect(controller.pane == .general)
}

/// Choosing a pane titles the window after it and sizes the content to it; the window opens on
/// the pane shown last.
@MainActor @Test func showingAPaneTitlesAndSizesTheWindowAndIsRemembered() throws {
    _ = NSApplication.shared
    let controller = controller()

    controller.show(.apps)

    let window = try #require(controller.window)
    #expect(window.title == "Apps")
    #expect(window.toolbar?.selectedItemIdentifier == SettingsPane.apps.item)
    #expect(window.contentRect(forFrameRect: window.frame).height == SettingsPane.apps.height)

    controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
    controller.show()

    #expect(controller.window?.title == "Apps")
}

@MainActor @Test func leavingTheShortcutPaneStopsARecording() {
    _ = NSApplication.shared
    let model = model()
    let controller = controller(model)
    controller.show(.shortcut)
    model.recorder.start()

    controller.show(.results)

    #expect(!model.recorder.isRecording)
}

/// The Spotlight pane reads the index each time it shows, so a change made in Terminal shows.
@MainActor @Test func theSpotlightPaneReadsTheIndexEachTimeItShows() async throws {
    _ = NSApplication.shared
    let index = StubSpotlightIndex(indexing: true)
    let spotlight = SpotlightIndexModel(service: index)
    let controller = SettingsWindowController(
        model: model(), spotlight: spotlight, appName: "Simple Spotlight",
        quitTitle: "Quit Simple Spotlight", quit: {}, ordersWindow: false)

    controller.show(.spotlight)
    await spotlight.work?.value
    #expect(spotlight.isIndexing == true)

    try await index.setIndexing(false)
    controller.show()
    await spotlight.work?.value

    #expect(spotlight.isIndexing == false)
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
