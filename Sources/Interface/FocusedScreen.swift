import AppKit

/// Finds the screen the panel shows on: the one holding the frontmost app's frontmost window,
/// where the user is working, whichever screen the mouse is on.
@MainActor
enum FocusedScreen {
    /// The screen holding the frontmost app's frontmost window. With no such window, as on the
    /// desktop or in an app with no windows open, the screen with the menu bar's key focus.
    static func current() -> NSScreen? {
        let screens = NSScreen.screens
        guard let app = NSWorkspace.shared.frontmostApplication,
            let index = index(
                windows: windowBounds(of: app.processIdentifier), screens: screens.map(\.frame))
        else { return NSScreen.main }
        return screens[index]
    }

    /// The bounds of the on-screen, normal-level, visible windows of the process `pid`, front to
    /// back, in the window server's coordinates. Only bounds, layer, alpha and owner are read:
    /// a window's name would need the Screen Recording permission, and these don't.
    private static func windowBounds(of pid: pid_t) -> [CGRect] {
        guard
            let windows = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]]
        else { return [] }
        return windows.compactMap { window in
            guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 0 > 0,
                let bounds = window[kCGWindowBounds as String] as? NSDictionary
            else { return nil }
            return CGRect(dictionaryRepresentation: bounds as CFDictionary)
        }
    }

    /// The index in `screens` of the screen that the first of `windows` on any screen overlaps
    /// most; nil when none is on a screen.
    ///
    /// - Parameters:
    ///   - windows: Front to back, in the window server's coordinates: origin at the primary
    ///     screen's top-left, y growing down.
    ///   - screens: AppKit frames, origin at the primary screen's bottom-left, y growing up, the
    ///     primary screen first, as `NSScreen.screens` gives them.
    nonisolated static func index(windows: [CGRect], screens: [NSRect]) -> Int? {
        guard let primary = screens.first else { return nil }
        for window in windows {
            let flipped = NSRect(
                x: window.minX, y: primary.height - window.maxY, width: window.width,
                height: window.height)
            let overlaps = screens.map { screen in
                let shared = screen.intersection(flipped)
                return shared.isNull ? 0 : shared.width * shared.height
            }
            guard let most = overlaps.max(), most > 0 else { continue }
            return overlaps.firstIndex(of: most)
        }
        return nil
    }
}
