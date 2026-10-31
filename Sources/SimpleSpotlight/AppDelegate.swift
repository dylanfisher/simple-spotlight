import AppKit
import Interface
import Search
import os

/// Wires the config store, the coordinator and the panel together, and passes on what AppKit
/// tells the app: launch, a second launch, and quitting.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let log: Logger
    private let appName: String
    private let store = ConfigStore(folder: ConfigStore.standardFolder())
    private var coordinator: AppCoordinator?

    init(bundle: Bundle) {
        guard let id = bundle.bundleIdentifier,
            let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
        else {
            preconditionFailure("run the app as a bundle with an ID and a name: ./scripts/dev")
        }
        log = Logger(subsystem: id, category: "app")
        appName = name
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let log = log
        let store = store
        let reportError: @MainActor (any Error) -> Void = { [weak self] in self?.report($0) }
        let coordinator = AppCoordinator(
            appName: appName, configFile: store.file,
            calculator: CalculatorProvider(locale: .autoupdatingCurrent),
            opener: WorkspaceOpener(reportError: reportError), icons: IconCache(),
            makeConfigFile: { () throws(ConfigError) in try await store.makeDefaultFileIfMissing()
            },
            hotKey: HotKey(), systemHotKeys: { try HotKey.systemHotKeys() },
            conflictNotice: HotKeyConflictNotice(appName: appName),
            loginItem: LoginItem(service: MainAppLoginItem(), appName: appName),
            appState: AppStateStore(folder: AppSupport.standardFolder()),
            buildIndex: { settings throws(CancellationError) in
                try await settings.indexBuilder().build()
            },
            quit: { NSApplication.shared.terminate(nil) }, reportError: reportError, log: log)
        self.coordinator = coordinator
        // Launch doesn't wait for the file: the store reads it off the main actor, and each
        // state it sends is applied as it comes, the first registering the hotkey.
        Task {
            for await state in store.states {
                coordinator.apply(settings: state.settings, errors: state.errors)
            }
        }
        Task { await store.start() }
        log.info("launched")
    }

    /// A second launch, as `open` of the running app or a double-click in Finder, shows the
    /// panel.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        coordinator?.reopen()
        return false
    }

    /// Gives the hotkey back and stops the config store's watch before quitting; the store is
    /// an actor, so the quit waits for it.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        coordinator?.stop()
        let store = store
        Task {
            await store.stop()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Something the user asked for failed, after the panel hid: an alert says what.
    private func report(_ error: any Error) {
        // A Swift error's description is written for people; an NSError's is a dump, and its
        // localized description is the readable part.
        let detail =
            type(of: error) is NSError.Type
            ? error.localizedDescription : String(describing: error)
        log.error("\(detail, privacy: .private)")
        let alert = NSAlert()
        alert.messageText = "\(appName) couldn't do that"
        alert.informativeText = detail
        AlertPresenter.run(alert)
    }
}
