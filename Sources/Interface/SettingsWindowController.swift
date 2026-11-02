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
    private let quitTitle: String
    private let ordersWindow: Bool
    private let quit: @MainActor () -> Void
    /// Built when the window is shown and let go when it closes.
    private(set) var window: SettingsWindow?
    /// The app that had the keys when the window opened, which gets them back when it closes.
    private var previousApp: NSRunningApplication?

    /// - Parameters:
    ///   - title: The window's title.
    ///   - quitTitle: The label of the window's Quit button.
    ///   - quit: Runs on ⌘Q in the window and on the Quit button.
    ///   - ordersWindow: Whether showing puts the window on screen and activates the app. Tests
    ///     pass false.
    public init(
        model: SettingsModel, title: String, quitTitle: String,
        quit: @escaping @MainActor () -> Void,
        ordersWindow: Bool = true
    ) {
        self.model = model
        self.title = title
        self.quitTitle = quitTitle
        self.quit = quit
        self.ordersWindow = ordersWindow
    }

    /// Brings the window forward, making it the first time.
    public func show() {
        isShown = true
        let window = self.window ?? makeWindow()
        guard ordersWindow else { return }
        if !NSApplication.shared.isActive {
            let frontmost = NSWorkspace.shared.frontmostApplication
            previousApp = frontmost == .current ? nil : frontmost
        }
        if #available(macOS 14, *) {
            NSApplication.shared.activate()
        } else {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        window.makeKeyAndOrderFront(nil)
        // With Full Keyboard Access on, AppKit focuses the first control, and Space would
        // then start recording a shortcut or flip a toggle the user never chose.
        window.makeFirstResponder(nil)
    }

    var rootView: SettingsView {
        SettingsView(model: model, quitTitle: quitTitle, quit: quit)
    }

    private func makeWindow() -> SettingsWindow {
        let hosting = NSHostingController(rootView: rootView)
        // macOS 12's hosting controller sizes the window to the view without being asked.
        if #available(macOS 13, *) { hosting.sizingOptions = [.preferredContentSize] }
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
        // Stopping registers the hotkey again, which tells of a conflict by alert unless the
        // window is still counted open to say it.
        model.recorder.stop()
        isShown = false
        window = nil
        // An agent app with no window left would keep the keys, with nothing to type into.
        if let app = Self.appToReturnTo(
            previous: previousApp, frontmost: NSWorkspace.shared.frontmostApplication)
        {
            // Since macOS 14 an app is activated only if the active app yields to it.
            if #available(macOS 14, *) {
                NSApplication.shared.yieldActivation(to: app)
                app.activate()
            } else {
                app.activate(options: .activateIgnoringOtherApps)
            }
        }
        previousApp = nil
    }

    /// The app that had the keys when the window opened, if it still runs and nothing else has
    /// the keys now: the user may have switched apps with the window open, and closing it
    /// then mustn't pull them back.
    static func appToReturnTo(previous: NSRunningApplication?, frontmost: NSRunningApplication?)
        -> NSRunningApplication?
    {
        guard let previous, !previous.isTerminated else { return nil }
        guard frontmost == nil || frontmost == .current else { return nil }
        return previous
    }

    /// A shortcut half recorded when the user clicks into another app stops, so the hotkey
    /// comes back.
    public func windowDidResignKey(_ notification: Notification) {
        model.recorder.stop()
    }
}

/// The window, which takes ⌘W and ⌘Q itself, since the app has no menu bar to.
@MainActor
final class SettingsWindow: NSWindow {
    var quit: @MainActor () -> Void = {}

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.chordKeys)
        guard modifiers == .command,
            let chord = SearchPanelController.chord(
                characters: event.charactersIgnoringModifiers, keyCode: event.keyCode)
        else { return super.performKeyEquivalent(with: event) }
        switch chord {
        case .close:
            performClose(nil)
        case .quit:
            quit()
        default:
            return super.performKeyEquivalent(with: event)
        }
        return true
    }
}
