import AppKit
import Carbon
import Search

/// Tells the user the hotkey won't show the panel, how to free it, and that Settings can record
/// another: an alert the first time, and a problem row in the panel for as long as it lasts.
@MainActor
public final class HotKeyConflictNotice {
    /// What the user can do from the notice.
    public enum Choice: Equatable, Sendable {
        case openKeyboardShortcuts, openSettings, dismiss
    }

    /// The notice's words and buttons, the first button the default.
    public struct Content: Equatable, Sendable {
        public let title: String
        public let message: String
        public let buttons: [Button]
    }

    public struct Button: Equatable, Sendable {
        public let title: String
        public let choice: Choice
    }

    /// Shows `Content` and later calls back with the button chosen.
    public typealias Present =
        @MainActor (Content, _ chosen: @escaping @MainActor (Choice) -> Void) -> Void

    /// The Keyboard Shortcuts section of System Settings' Keyboard pane, where Spotlight's
    /// shortcuts are turned off.
    public static let keyboardShortcutsURL: URL = {
        guard
            let url = SettingsPaneProvider.paneURL(
                "com.apple.Keyboard-Settings.extension", anchor: "Shortcuts")
        else { preconditionFailure("the Keyboard pane has no URL") }
        return url
    }()

    /// Spotlight's shortcuts at their defaults, as Keyboard Shortcuts names them under
    /// Spotlight.
    static let spotlightShortcuts: [(chord: KeyChord, name: String)] = [
        (KeyChord(.command, .space), "Show Spotlight search"),
        (KeyChord([.command, .option], .space), "Show Finder search window"),
    ]

    private let appName: String
    private let present: Present

    public init(appName: String, present: @escaping Present = HotKeyConflictNotice.alert) {
        self.appName = appName
        self.present = present
    }

    /// Shows the alert for `chord` and calls `chosen` with the user's choice.
    public func show(
        _ chord: KeyChord, conflict: HotKeyConflict,
        chosen: @escaping @MainActor (Choice) -> Void
    ) {
        present(Self.content(chord, conflict: conflict, appName: appName), chosen)
    }

    /// The problem row for the conflict. Return opens Keyboard Shortcuts for a macOS shortcut,
    /// and Settings, to record another, for a chord another app holds.
    public static func row(_ chord: KeyChord, conflict: HotKeyConflict) -> SearchItem {
        switch conflict {
        case .systemShortcut:
            let owner =
                spotlightShortcuts.contains { $0.chord == chord }
                ? "Spotlight's shortcut" : "a macOS shortcut"
            return ProblemItems.row(
                .hotKey, title: "\(chord) is also \(owner)",
                subtitle: "Return opens Keyboard Shortcuts", target: .openURL(keyboardShortcutsURL))
        case .refused:
            return ProblemItems.row(
                .hotKey, title: "Another app uses \(chord)",
                subtitle: "Record another shortcut in Settings. Return opens them.",
                target: .command(CommandProvider.Command.openSettings.id))
        }
    }

    static func content(_ chord: KeyChord, conflict: HotKeyConflict, appName: String) -> Content {
        let elsewhere =
            "Or record another shortcut in \(appName) Settings. Until then, open \(appName)"
            + " again, as from Finder, to show the panel."
        let settings = Button(title: "Open Settings", choice: .openSettings)
        let ok = Button(title: "OK", choice: .dismiss)
        switch conflict {
        case .systemShortcut:
            let place =
                spotlightShortcuts.first { $0.chord == chord }
                .map { "choose Spotlight, and turn off \"\($0.name)\"" }
                ?? "and turn off the shortcut that uses \(chord)"
            return Content(
                title: "A macOS shortcut uses \(chord)",
                message:
                    "macOS takes \(chord) before \(appName) sees it. To free it, open System"
                    + " Settings → Keyboard → Keyboard Shortcuts…, \(place). \(elsewhere)",
                buttons: [
                    Button(title: "Open Keyboard Shortcuts", choice: .openKeyboardShortcuts),
                    settings, ok,
                ])
        case .refused(let status):
            let reason =
                status == OSStatus(eventHotKeyExistsErr)
                ? "Another app uses \(chord) as its shortcut. Change that app's shortcut or quit it."
                : "macOS refused \(chord) (status \(status))."
            return Content(
                title: "\(appName) can't use \(chord)", message: "\(reason) \(elsewhere)",
                buttons: [settings, ok])
        }
    }

    /// Shows `content` as an alert once the caller has returned, so the alert's modal loop
    /// doesn't run inside a config update.
    public static func alert(
        _ content: Content, chosen: @escaping @MainActor (Choice) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = content.title
        alert.informativeText = content.message
        for button in content.buttons {
            alert.addButton(withTitle: button.title)
        }
        AlertPresenter.run(alert) { response in
            let index =
                response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            guard content.buttons.indices.contains(index) else {
                preconditionFailure("the alert returned a button it doesn't have: \(index)")
            }
            chosen(content.buttons[index].choice)
        }
    }
}
