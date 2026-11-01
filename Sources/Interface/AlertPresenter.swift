import AppKit

/// Runs alerts so the main actor keeps working while they show.
public enum AlertPresenter {
    /// Runs `alert` as a modal and calls `then` with its response, from the run loop rather than
    /// from the caller. A modal loop started inside a main-actor task holds the main dispatch
    /// queue, so no other main-actor work, such as installing a built index, runs until the
    /// alert closes; started from the run loop, it lets the queue drain.
    @MainActor
    public static func run(
        _ alert: NSAlert,
        then: @escaping @MainActor (NSApplication.ModalResponse) -> Void = { _ in }
    ) {
        RunLoop.main.perform(inModes: [.default]) {
            MainActor.assumeIsolated {
                if #available(macOS 14, *) {
                    NSApplication.shared.activate()
                } else {
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
                then(alert.runModal())
            }
        }
    }
}
