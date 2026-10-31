import AppKit
import Search
import os

/// Applies each config state to the app: registers the hotkey, builds the index off the main
/// actor and swaps it into the panel, rebuilding it when the folders it reads change, follows
/// `launchAtLogin`, and shows what is wrong as rows above the results. Each part runs only when
/// its settings change (docs/decisions/0009-app-wiring.md). Loads usage at launch and records
/// each open (docs/decisions/0010-usage-ranking.md).
@MainActor
public final class AppCoordinator {
    /// Builds the index the settings ask for, off the main actor; throws when cancelled.
    public typealias BuildIndex =
        @Sendable (Search.Settings) async throws(CancellationError) -> IndexBuilder.Build
    /// Starts watching the folders the index for the settings reads, calling `onChange` at the
    /// end of each burst of changes in them, and returns what stops the watch
    /// (docs/decisions/0011-live-index.md).
    public typealias WatchIndex =
        @MainActor (Search.Settings, _ onChange: @escaping @Sendable @MainActor () -> Void)
        -> @MainActor () -> Void

    public private(set) var panel: SearchPanelController!
    /// The settings last applied; nil before the first.
    public private(set) var settings: Search.Settings?
    /// The build started last, for tests to wait on.
    private(set) var indexBuild: Task<Void, Never>?
    /// The check of whether to show the conflict alert started last, for tests to wait on.
    private(set) var noticeDecision: Task<Void, Never>?
    /// The load or record of usage started last, which waits for the one before, so the panel
    /// gets the store's usage in the order of the changes. For tests to wait on.
    private(set) var usageUpdate: Task<Void, Never>?

    private let configFile: URL
    private let commands: CommandProvider
    private let opener: any ResultOpener
    private let icons: IconCache
    private let hotKey: any HotKeyRegistrar
    private let systemHotKeys: @MainActor () throws -> [SystemHotKey]
    private let conflictNotice: HotKeyConflictNotice
    private let loginItem: LoginItem
    private let appState: AppStateStore
    private let buildIndex: BuildIndex
    private let watchIndex: WatchIndex
    private let usage: UsageStore
    private let now: @Sendable () -> Date
    private var stopWatch: (@MainActor () -> Void)?
    private let quit: @MainActor () -> Void
    private let log: Logger
    private var configErrors: [ConfigError] = []
    private var indexProblems: [IndexProblem] = []
    private var loginItemProblem: SearchItem?
    private var hotKeyProblem: SearchItem?
    /// The times the panel has shown, for the timing `show` logs.
    private var shows = 0

    /// - Parameters:
    ///   - configFile: Where the config file is, for its error row.
    ///   - makeConfigFile: Gives the config file, creating the default one if it's missing.
    ///   - systemHotKeys: The shortcuts macOS handles itself, checked for the hotkey's chord.
    ///   - appState: Remembers the chords whose conflict alert the user has seen.
    ///   - usage: Holds what the user has opened; loaded now, off the main actor.
    ///   - now: The time an open is recorded at and usage decays to.
    ///   - ordersPanel: Whether showing puts the panel on screen; tests pass false.
    public init(
        appName: String, configFile: URL, calculator: CalculatorProvider,
        opener: any ResultOpener, icons: IconCache,
        makeConfigFile: @escaping @MainActor () async throws(ConfigError) -> URL,
        hotKey: any HotKeyRegistrar,
        systemHotKeys: @escaping @MainActor () throws -> [SystemHotKey],
        conflictNotice: HotKeyConflictNotice, loginItem: LoginItem, appState: AppStateStore,
        buildIndex: @escaping BuildIndex, watchIndex: @escaping WatchIndex, usage: UsageStore,
        now: @escaping @Sendable () -> Date, quit: @escaping @MainActor () -> Void,
        reportError: @escaping @MainActor (any Error) -> Void, log: Logger,
        ordersPanel: Bool = true
    ) {
        self.configFile = configFile
        commands = CommandProvider(appName: appName)
        self.opener = opener
        self.icons = icons
        self.hotKey = hotKey
        self.systemHotKeys = systemHotKeys
        self.conflictNotice = conflictNotice
        self.loginItem = loginItem
        self.appState = appState
        self.buildIndex = buildIndex
        self.watchIndex = watchIndex
        self.usage = usage
        self.now = now
        self.quit = quit
        self.log = log
        panel = SearchPanelController(
            index: SearchIndex(items: commands.items), settings: Search.Settings(),
            calculator: calculator, opener: opener, icons: icons, configFile: makeConfigFile,
            runCommand: { [weak self] in self?.run(command: $0) },
            recordOpen: { [weak self] in self?.recordOpen($0) }, now: now, quit: quit,
            reportError: reportError, ordersPanel: ordersPanel)
        updateUsage { usage in try await usage.load(at: now()) }
    }

    /// Applies the config file's settings and errors. The hotkey is registered first, so it is
    /// ready before the index is built.
    public func apply(settings new: Search.Settings, errors: [ConfigError]) {
        let old = settings
        settings = new
        if old?.hotkey != new.hotkey {
            register(new.hotkey)
        }
        if old?.indexKeys != new.indexKeys {
            stopWatch?()
            stopWatch = watchIndex(new) { [weak self] in self?.indexFoldersChanged() }
            rebuildIndex(for: new)
        }
        if old?.launchAtLogin != new.launchAtLogin {
            loginItemProblem = loginItem.follow(new.launchAtLogin)
            if let loginItemProblem {
                log.error(
                    "login item: \(loginItemProblem.title, privacy: .public): \(loginItemProblem.subtitle ?? "", privacy: .private)"
                )
            }
        }
        if errors != configErrors {
            for error in errors {
                log.error("config file: \(error.description, privacy: .private)")
            }
            configErrors = errors
        }
        if panel.settings != new { panel.settings = new }
        showProblems()
        // Draws the panel once so the first show takes about as long as later ones; queued so
        // it runs after the hotkey works and the build has started (docs/decisions/0012-warm-panel.md).
        if old == nil {
            Task { [weak self] in self?.panel.prepare() }
        }
    }

    /// Shows the panel, as a second launch of the app asks: the way in when the hotkey doesn't
    /// work.
    public func reopen() {
        log.info("reopened")
        show()
    }

    /// Gives the hotkey back and stops the watch and the build, before the app quits.
    public func stop() {
        hotKey.unregister()
        stopWatch?()
        stopWatch = nil
        indexBuild?.cancel()
    }

    /// Writes the opens still waiting to be, once the usage updates before have run, as the
    /// app does before it quits.
    public func flushUsage() async {
        await usageUpdate?.value
        do {
            try await usage.flush()
        } catch {
            log.error("usage file: \(String(describing: error), privacy: .private)")
        }
    }

    private func hotKeyPressed() {
        // The press reached the app, so no macOS shortcut holds the chord any more.
        if hotKeyProblem != nil {
            hotKeyProblem = nil
            showProblems()
        }
        if panel.isShown { panel.hide() } else { show() }
    }

    /// Shows the panel, first reading the login item's status again, so a row asking for
    /// approval goes once the user has approved it in System Settings.
    ///
    /// Logs, at debug level, the time from the call to the commit of the Core Animation
    /// transaction that puts the panel on screen with the field taking the keys: budget B1
    /// (docs/performance.md). The frame reaches the display at the next refresh after that.
    private func show() {
        let start = ContinuousClock.now
        let wasShown = panel.isShown
        if let settings {
            loginItemProblem = loginItem.recheck(settings.launchAtLogin, shown: loginItemProblem)
            showProblems()
        }
        panel.show()
        guard !wasShown else { return }
        shows += 1
        let count = shows
        CATransaction.setCompletionBlock { [log] in
            let elapsed = (ContinuousClock.now - start) / .milliseconds(1)
            log.debug(
                "show \(count, privacy: .public): \(elapsed, format: .fixed(precision: 1), privacy: .public) ms"
            )
        }
    }

    /// Registers `chord`, telling the user when it won't work: when a macOS shortcut that is
    /// turned on uses it, as Spotlight's uses ⌘Space, or when registering it fails. The chord is
    /// registered even then, so it works once the user frees it. The conflict shows as a row,
    /// and the first time for the chord, as an alert too.
    private func register(_ chord: KeyChord) {
        var conflict: HotKeyConflict?
        do {
            if HotKey.systemShortcutUses(chord, in: try systemHotKeys()) {
                conflict = .systemShortcut
            }
        } catch {
            log.error("\(String(describing: error), privacy: .public)")
        }
        do throws(HotKeyConflict) {
            try hotKey.register(chord) { [weak self] in self?.hotKeyPressed() }
            log.info("hotkey \(chord.text, privacy: .private) registered")
        } catch {
            conflict = error
        }
        hotKeyProblem = conflict.map { HotKeyConflictNotice.row(chord, conflict: $0) }
        guard let conflict else { return }
        log.error(
            "hotkey \(chord.text, privacy: .private): \(String(describing: conflict), privacy: .public)"
        )
        noticeDecision = Task { [weak self, appState, log, conflictNotice] in
            do {
                if try await appState.acknowledgedHotKeys().contains(chord.text) { return }
            } catch {
                log.error("state file: \(String(describing: error), privacy: .private)")
            }
            conflictNotice.show(chord, conflict: conflict) { self?.handle($0) }
            do {
                try await appState.acknowledge(hotKey: chord.text)
            } catch {
                log.error("state file: \(String(describing: error), privacy: .private)")
            }
        }
    }

    private func handle(_ choice: HotKeyConflictNotice.Choice) {
        switch choice {
        case .openKeyboardShortcuts: opener.open(HotKeyConflictNotice.keyboardShortcutsURL)
        case .openConfigFile: panel.openConfigFile()
        case .dismiss: break
        }
    }

    /// Builds the index `settings` ask for off the main actor, in place of a build still
    /// running, and swaps it in with the commands when it is done.
    private func rebuildIndex(for settings: Search.Settings) {
        indexBuild?.cancel()
        indexBuild = Task { [buildIndex] in
            let build: IndexBuilder.Build
            do throws(CancellationError) {
                build = try await buildIndex(settings)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            install(build)
        }
    }

    private func indexFoldersChanged() {
        guard let settings else { return }
        log.info("index folders changed")
        rebuildIndex(for: settings)
    }

    private func install(_ build: IndexBuilder.Build) {
        log.info(
            "index built: \(build.items.count) items, \(build.problems.count) problems in \(String(describing: build.duration), privacy: .public)"
        )
        for problem in build.problems {
            log.error("index: \(problem.description, privacy: .private)")
        }
        // An app may have a new icon since the last build.
        icons.forgetAll()
        indexProblems = build.problems
        panel.index = SearchIndex(items: build.items + commands.items)
        showProblems()
    }

    /// Sets the panel's problem rows when they differ from those it has, since each setting
    /// searches again.
    private func showProblems() {
        let rows = [
            ProblemItems.config(configErrors, file: configFile), hotKeyProblem, loginItemProblem,
            ProblemItems.index(indexProblems),
        ].compactMap { $0 }
        let shown = { (rows: [SearchItem]) in rows.map { [$0.id, $0.title, $0.subtitle ?? ""] } }
        guard shown(rows) != shown(panel.leadingItems) else { return }
        panel.leadingItems = rows
    }

    private func recordOpen(_ id: String) {
        let date = now()
        updateUsage { usage in try await usage.record(id, at: date) }
    }

    /// Runs `change` on the usage store after the change started before it, and gives the
    /// panel the usage it returns.
    private func updateUsage(
        _ change: @escaping @Sendable (UsageStore) async throws -> UsageStore.Usage
    ) {
        usageUpdate = Task { [weak self, previous = usageUpdate, usage, log] in
            await previous?.value
            do {
                let updated = try await change(usage)
                self?.panel.usage = updated
            } catch {
                log.error("usage file: \(String(describing: error), privacy: .private)")
            }
        }
    }

    private func run(command id: String) {
        switch CommandProvider.Command(id: id) {
        case .openConfig: panel.openConfigFile()
        case .quit: quit()
        case nil: preconditionFailure("no command \(id)")
        }
    }
}
