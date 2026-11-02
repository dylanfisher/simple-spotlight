import AppKit
import SwiftUI

/// The settings window: a toolbar of panes, as macOS apps' settings windows have, each a
/// `SettingsView` in an ordinary titled window titled after it. The app stays an agent app, with
/// no Dock icon or menu bar, so showing the window activates the app, and closing it gives the
/// keys back to the app that had them (docs/decisions/0015-settings-window.md).
@MainActor
public final class SettingsWindowController: NSObject, NSWindowDelegate, NSToolbarDelegate {
    /// Whether the window is open.
    public private(set) var isShown = false
    /// The pane showing, or shown last; the window opens on it again.
    public private(set) var pane = SettingsPane.general

    private let model: SettingsModel
    private let spotlight: SpotlightIndexModel
    private let appName: String
    private let quitTitle: String
    private let ordersWindow: Bool
    private let quit: @MainActor () -> Void
    /// Built when the window is shown and let go when it closes.
    private(set) var window: SettingsWindow?
    /// The app that had the keys when the window opened, which gets them back when it closes.
    private var previousApp: NSRunningApplication?

    /// - Parameters:
    ///   - spotlight: What the Spotlight pane shows; read again each time the pane shows.
    ///   - appName: The app's name, as the panes' notes say it.
    ///   - quitTitle: The label of the window's Quit button.
    ///   - quit: Runs on ⌘Q in the window and on the Quit button.
    ///   - ordersWindow: Whether showing puts the window on screen and activates the app. Tests
    ///     pass false.
    public init(
        model: SettingsModel, spotlight: SpotlightIndexModel, appName: String, quitTitle: String,
        quit: @escaping @MainActor () -> Void,
        ordersWindow: Bool = true
    ) {
        self.model = model
        self.spotlight = spotlight
        self.appName = appName
        self.quitTitle = quitTitle
        self.quit = quit
        self.ordersWindow = ordersWindow
    }

    /// Brings the window forward, making it the first time, on `pane` when given and otherwise
    /// on the pane shown last.
    public func show(_ pane: SettingsPane? = nil) {
        isShown = true
        let isNew = self.window == nil
        let window = self.window ?? makeWindow()
        let chosen = pane ?? self.pane
        if isNew || chosen != self.pane {
            select(chosen)
        } else if chosen == .spotlight {
            spotlight.refresh()
        }
        if isNew { window.center() }
        guard ordersWindow else { return }
        if !NSApplication.shared.isActive {
            let frontmost = NSWorkspace.shared.frontmostApplication
            previousApp = frontmost == .current ? nil : frontmost
        }
        NSApplication.shared.activate()
        window.makeKeyAndOrderFront(nil)
        // With Full Keyboard Access on, AppKit focuses the first control, and Space would
        // then start recording a shortcut or flip a toggle the user never chose.
        window.makeFirstResponder(nil)
    }

    func rootView(_ pane: SettingsPane) -> SettingsView {
        SettingsView(
            pane: pane, model: model, spotlight: spotlight, appName: appName,
            quitTitle: quitTitle, quit: quit)
    }

    private func makeWindow() -> SettingsWindow {
        let window = SettingsWindow(
            contentRect: NSRect(x: 0, y: 0, width: SettingsView.width, height: pane.height),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: true)
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenNone]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.quit = quit
        let toolbar = NSToolbar(identifier: "Settings")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        window.toolbar = toolbar
        window.toolbarStyle = .preference
        // Only the height changes by hand, for a long list of folders or apps.
        window.contentMinSize = NSSize(width: SettingsView.width, height: Self.minHeight)
        window.contentMaxSize = NSSize(
            width: SettingsView.width, height: CGFloat.greatestFiniteMagnitude)
        self.window = window
        return window
    }

    /// The least height a pane can be made by hand.
    static let minHeight: CGFloat = 160

    /// Shows `pane` at its height, the window's top edge where it was, and leaves a shortcut
    /// half recorded, so the hotkey comes back.
    private func select(_ pane: SettingsPane) {
        guard let window else { preconditionFailure("a settings pane was chosen with no window") }
        if pane != self.pane { model.recorder.stop() }
        self.pane = pane
        window.toolbar?.selectedItemIdentifier = pane.item
        window.title = pane.title
        let top = window.frame.maxY
        let hosting = NSHostingController(rootView: rootView(pane))
        // The window's size is set here and by hand, not from the view's.
        hosting.sizingOptions = []
        window.contentViewController = hosting
        var frame = window.frameRect(
            forContentRect: NSRect(x: 0, y: 0, width: SettingsView.width, height: pane.height))
        frame.origin = NSPoint(x: window.frame.minX, y: top - frame.height)
        window.setFrame(frame, display: true, animate: window.isVisible)
        if pane == .spotlight { spotlight.refresh() }
    }

    // MARK: NSToolbarDelegate

    public func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard let pane = SettingsPane(rawValue: itemIdentifier.rawValue) else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = pane.title
        item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
        item.target = self
        item.action = #selector(choosePane(_:))
        return item
    }

    public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SettingsPane.allCases.map(\.item)
    }

    public func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SettingsPane.allCases.map(\.item)
    }

    public func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar)
        -> [NSToolbarItem.Identifier]
    {
        SettingsPane.allCases.map(\.item)
    }

    @objc private func choosePane(_ sender: NSToolbarItem) {
        guard let pane = SettingsPane(rawValue: sender.itemIdentifier.rawValue) else {
            preconditionFailure("the settings toolbar has no pane \(sender.itemIdentifier)")
        }
        select(pane)
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
            NSApplication.shared.yieldActivation(to: app)
            app.activate()
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
