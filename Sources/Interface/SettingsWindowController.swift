import AppKit
import SwiftUI

/// The settings window: `SettingsView` in an ordinary titled window. The app stays an agent
/// app, with no Dock icon or menu bar, so showing the window activates the app, and closing it
/// gives the keys back to the app that had them (docs/decisions/0015-settings-window.md).
@MainActor
public final class SettingsWindowController: NSObject, NSWindowDelegate {
    /// Whether the window is open.
    public private(set) var isShown = false

    private let model: SettingsModel
    private let title: String
    private let ordersWindow: Bool
    private let quit: @MainActor () -> Void
    private var window: SettingsWindow?
    /// The app that had the keys when the window opened, which gets them back when it closes.
    private var previousApp: NSRunningApplication?

    /// - Parameters:
    ///   - title: The window's title.
    ///   - quit: Runs on ⌘Q in the window.
    ///   - ordersWindow: Whether showing puts the window on screen and activates the app. Tests
    ///     pass false.
    public init(
        model: SettingsModel, title: String, quit: @escaping @MainActor () -> Void,
        ordersWindow: Bool = true
    ) {
        self.model = model
        self.title = title
        self.quit = quit
        self.ordersWindow = ordersWindow
    }

    /// Brings the window forward, making it the first time.
    public func show() {
        isShown = true
        guard ordersWindow else { return }
        let window = self.window ?? makeWindow()
        if !NSApplication.shared.isActive {
            let frontmost = NSWorkspace.shared.frontmostApplication
            previousApp = frontmost == .current ? nil : frontmost
        }
        NSApplication.shared.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> SettingsWindow {
        let hosting = NSHostingController(rootView: SettingsView(model: model))
        hosting.sizingOptions = [.preferredContentSize]
        let window = SettingsWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .resizable]
        window.title = title
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenNone]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.quit = quit
        window.center()
        self.window = window
        return window
    }

    public func windowWillClose(_ notification: Notification) {
        isShown = false
        model.recorder.stop()
        // An agent app with no window left would keep the keys, with nothing to type into.
        if let previousApp, !previousApp.isTerminated { previousApp.activate() }
        previousApp = nil
    }

    /// A shortcut half recorded when the user clicks into another app stops, so the hotkey
    /// comes back.
    public func windowDidResignKey(_ notification: Notification) {
        model.recorder.stop()
    }
}

/// The window, which takes ⌘W and ⌘Q itself, since the app has no menu bar to.
@MainActor
private final class SettingsWindow: NSWindow {
    var quit: @MainActor () -> Void = {}

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard modifiers == .command else { return super.performKeyEquivalent(with: event) }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "w":
            performClose(nil)
        case "q":
            quit()
        default:
            return super.performKeyEquivalent(with: event)
        }
        return true
    }
}
