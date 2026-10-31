import AppKit
import Search
import os

/// Applies each config state to the app: registers the hotkey, builds the index off the main
/// actor and swaps it into the panel, follows `launchAtLogin`, and shows what is wrong as rows
/// above the results. Each part runs only when its settings change
/// (docs/decisions/0009-app-wiring.md).
@MainActor
public final class AppCoordinator {
    /// Builds the index the settings ask for, off the main actor. Throws only
    /// `CancellationError`.
    public typealias BuildIndex = @Sendable (Search.Settings) async throws -> IndexBuilder.Build

    public private(set) var panel: SearchPanelController!
    /// The settings last applied; nil before the first.
    public private(set) var settings: Search.Settings?
    /// The build started last, for tests to wait on.
    private(set) var indexBuild: Task<Void, Never>?

    private let configFile: URL
    private let commands: CommandProvider
    private let opener: any ResultOpener
    private let icons: IconCache
    private let hotKey: any HotKeyRegistrar
    private let systemHotKeys: @MainActor () throws -> [SystemHotKey]
    private let conflictNotice: HotKeyConflictNotice
    private let loginItem: LoginItem
    private let buildIndex: BuildIndex
    private let quit: @MainActor () -> Void
    private let log: Logger
    private var configErrors: [ConfigError] = []
    private var indexProblems: [IndexProblem] = []
    private var loginItemProblem: SearchItem?

    /// - Parameters:
    ///   - configFile: Where the config file is, for its error row.
    ///   - makeConfigFile: Gives the config file, creating the default one if it's missing.
    ///   - systemHotKeys: The shortcuts macOS handles itself, checked for the hotkey's chord.
    ///   - ordersPanel: Whether showing puts the panel on screen; tests pass false.
    public init(
        appName: String, configFile: URL, calculator: CalculatorProvider,
        opener: any ResultOpener, icons: IconCache,
        makeConfigFile: @escaping @MainActor () async throws(ConfigError) -> URL,
        hotKey: any HotKeyRegistrar,
        systemHotKeys: @escaping @MainActor () throws -> [SystemHotKey],
        conflictNotice: HotKeyConflictNotice, loginItem: LoginItem,
        buildIndex: @escaping BuildIndex, quit: @escaping @MainActor () -> Void,
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
        self.buildIndex = buildIndex
        self.quit = quit
        self.log = log
        panel = SearchPanelController(
            index: SearchIndex(items: commands.items), settings: Search.Settings(),
            calculator: calculator, opener: opener, icons: icons, configFile: makeConfigFile,
            runCommand: { [weak self] in self?.run(command: $0) }, quit: quit,
            reportError: reportError, ordersPanel: ordersPanel)
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
            rebuildIndex(for: new)
        }
        if old?.launchAtLogin != new.launchAtLogin {
            loginItemProblem = loginItem.follow(new.launchAtLogin)
            if let loginItemProblem {
                log.error("login item: \(loginItemProblem.title, privacy: .public)")
            }
        }
        if errors != configErrors {
            for error in errors {
                log.error("config file: \(error.description, privacy: .public)")
            }
            configErrors = errors
        }
        if panel.settings != new { panel.settings = new }
        showProblems()
    }

    /// Shows the panel, as a second launch of the app asks: the way in when the hotkey doesn't
    /// work.
    public func reopen() {
        log.info("reopened")
        panel.show()
    }

    /// Gives the hotkey back and stops the build, before the app quits.
    public func stop() {
        hotKey.unregister()
        indexBuild?.cancel()
    }

    /// Registers `chord`, telling the user when it won't work: when a macOS shortcut that is
    /// turned on uses it, as Spotlight's uses ⌘Space, or when registering it fails. The chord is
    /// registered even then, so it works once the user frees it.
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
            try hotKey.register(chord) { [weak self] in self?.panel.toggle() }
            log.info("hotkey \(chord.text, privacy: .public) registered")
        } catch {
            conflict = error
        }
        guard let conflict else { return }
        log.error(
            "hotkey \(chord.text, privacy: .public): \(String(describing: conflict), privacy: .public)"
        )
        conflictNotice.show(chord, conflict: conflict) { [weak self] in self?.handle($0) }
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
            do {
                build = try await buildIndex(settings)
            } catch {
                guard error is CancellationError else {
                    preconditionFailure("the index build threw \(error)")
                }
                return
            }
            guard !Task.isCancelled else { return }
            install(build)
        }
    }

    private func install(_ build: IndexBuilder.Build) {
        log.info(
            "index built: \(build.items.count) items, \(build.problems.count) problems in \(String(describing: build.duration), privacy: .public)"
        )
        for problem in build.problems {
            log.error("index: \(problem.description, privacy: .public)")
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
            ProblemItems.config(configErrors, file: configFile), loginItemProblem,
            ProblemItems.index(indexProblems),
        ].compactMap { $0 }
        let shown = { (rows: [SearchItem]) in rows.map { [$0.id, $0.title, $0.subtitle ?? ""] } }
        guard shown(rows) != shown(panel.leadingItems) else { return }
        panel.leadingItems = rows
    }

    private func run(command id: String) {
        switch CommandProvider.Command(id: id) {
        case .openConfig: panel.openConfigFile()
        case .quit: quit()
        case nil: preconditionFailure("no command \(id)")
        }
    }
}
