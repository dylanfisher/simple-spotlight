import AppKit
import Foundation
import Search
import ServiceManagement
import Testing
import os

@testable import Interface

/// Records what was opened, instead of opening it.
@MainActor
private final class StubOpener: ResultOpener {
    private(set) var opened: [URL] = []
    private(set) var copied: [String] = []

    func openApplication(at url: URL) { opened.append(url) }
    func open(_ url: URL) { opened.append(url) }
    func reveal(_ url: URL) {}
    func copy(_ text: String) { copied.append(text) }
    func clipboardText() -> String? { nil }
}

/// Records the chords registered, instead of taking them from the system.
@MainActor
private final class StubHotKey: HotKeyRegistrar {
    private(set) var registered: [KeyChord] = []
    private(set) var onPress: (@MainActor () -> Void)?
    var refusal: HotKeyConflict?

    func register(_ chord: KeyChord, onPress: @escaping @MainActor () -> Void)
        throws(HotKeyConflict)
    {
        registered.append(chord)
        if let refusal { throw refusal }
        self.onPress = onPress
    }

    private(set) var unregisters = 0

    func unregister() {
        unregisters += 1
        onPress = nil
    }
}

/// Counts what was asked of the login item.
@MainActor
private final class StubLoginItem: LoginItemService {
    var status: SMAppService.Status = .notRegistered
    var statusAfterRegister: SMAppService.Status = .enabled
    private(set) var calls = 0

    func register() throws {
        calls += 1
        status = statusAfterRegister
    }

    func unregister() throws {
        calls += 1
        status = .notRegistered
    }
}

/// Records the settings each build was asked for.
private final class BuildRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Search.Settings] = []
    let items: [SearchItem]
    let problems: [IndexProblem]

    init(items: [SearchItem], problems: [IndexProblem] = []) {
        self.items = items
        self.problems = problems
    }

    var builds: [Search.Settings] { lock.withLock { recorded } }

    func build(_ settings: Search.Settings) -> IndexBuilder.Build {
        lock.withLock { recorded.append(settings) }
        return IndexBuilder.Build(items: items, problems: problems, duration: .zero)
    }
}

/// Records each watch of the index's folders, and keeps the last one's callback.
@MainActor
private final class StubWatch {
    private(set) var watched: [Search.Settings] = []
    private(set) var stops = 0
    private(set) var onChange: (@MainActor () -> Void)?

    var watch: AppCoordinator.WatchIndex {
        { [unowned self] settings, onChange in
            watched.append(settings)
            self.onChange = onChange
            return { [unowned self] in stops += 1 }
        }
    }
}

private let safari = SearchItem(
    id: "com.apple.Safari", kind: .app, title: "Safari", subtitle: nil,
    target: .openFile(URL(filePath: "/Applications/Safari.app")))
private let configURL = URL(filePath: "/tmp/simple-spotlight-test/config.json")

@MainActor
private final class Fixture {
    let opener = StubOpener()
    let hotKey = StubHotKey()
    let loginItem = StubLoginItem()
    let watch = StubWatch()
    let recorder: BuildRecorder
    let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    var systemHotKeys: [SystemHotKey] = []
    var notices: [HotKeyConflictNotice.Content] = []
    var quits = 0
    var announcements: [String] = []
    let stateFolder: URL
    private let ownsStateFolder: Bool
    private(set) var coordinator: AppCoordinator!

    deinit {
        guard ownsStateFolder, FileManager.default.fileExists(atPath: stateFolder.path) else {
            return
        }
        do {
            try FileManager.default.removeItem(at: stateFolder)
        } catch {
            Issue.record(error, "removing \(stateFolder.path)")
        }
    }

    /// - Parameters:
    ///   - state: The folder of the state and usage files; a new one is made and removed when
    ///     nil.
    ///   - buildIndex: Builds the index; the recorder's build when nil.
    init(
        items: [SearchItem] = [safari], problems: [IndexProblem] = [], state: URL? = nil,
        buildIndex: AppCoordinator.BuildIndex? = nil
    ) {
        _ = NSApplication.shared
        recorder = BuildRecorder(items: items, problems: problems)
        let recorder = recorder
        stateFolder =
            state
            ?? FileManager.default.temporaryDirectory.appending(
                path: "simple-spotlight-\(UUID().uuidString)", directoryHint: .isDirectory)
        ownsStateFolder = state == nil
        coordinator = AppCoordinator(
            appName: "Simple Spotlight", configFile: configURL,
            calculator: CalculatorProvider(locale: Locale(identifier: "en_US")),
            opener: opener, icons: IconCache(load: { _ in NSImage() }),
            makeConfigFile: { () throws(ConfigError) in configURL },
            hotKey: hotKey, systemHotKeys: { [unowned self] in systemHotKeys },
            conflictNotice: HotKeyConflictNotice(appName: "Simple Spotlight") {
                [unowned self] content, _ in notices.append(content)
            },
            loginItem: LoginItem(service: loginItem, appName: "Simple Spotlight"),
            appState: AppStateStore(folder: stateFolder),
            buildIndex: buildIndex ?? { settings throws(CancellationError) in
                recorder.build(settings)
            },
            watchIndex: watch.watch,
            usage: UsageStore(folder: stateFolder) { Issue.record($0) },
            now: { [now] in now },
            quit: { [unowned self] in quits += 1 },
            reportError: { Issue.record($0) }, log: Logger(.disabled), ordersPanel: false)
        coordinator.panel.announce = { [unowned self] in announcements.append($0) }
    }

    var panel: SearchPanelController { coordinator.panel }

    /// Applies `settings` and waits for the index build it starts, if any.
    func apply(_ settings: Search.Settings, errors: [ConfigError] = []) async {
        coordinator.apply(settings: settings, errors: errors)
        await coordinator.indexBuild?.value
        await coordinator.noticeDecision?.value
    }

    func type(_ query: String) throws {
        panel.show()
        let editor = try #require(panel.panel.firstResponder as? NSTextView)
        editor.insertText(
            query, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
    }

    /// Opens the first result for `query`, and waits for the open to be counted.
    func open(_ query: String) async throws {
        try type(query)
        try pressReturn()
        await coordinator.usageUpdate?.value
    }

    func pressReturn() throws {
        let editor = try #require(panel.panel.firstResponder as? NSTextView)
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
    }

    var titles: [String] { panel.state.rows.map(\.item.title) }
}

@MainActor @Test func theFirstSettingsRegisterTheHotkeyAndBuildTheIndex() async throws {
    let fixture = Fixture()

    await fixture.apply(Search.Settings())

    #expect(fixture.hotKey.registered == [KeyChord(.command, .space)])
    #expect(fixture.recorder.builds.count == 1)
    try fixture.type("saf")
    #expect(fixture.titles == ["Safari"])
}

@MainActor @Test func theCommandsAreSearchableBeforeTheIndexIsBuilt() throws {
    let fixture = Fixture()

    try fixture.type("quit")

    #expect(fixture.titles == ["Quit Simple Spotlight"])
}

@MainActor @Test func theHotkeyTogglesThePanel() async throws {
    let fixture = Fixture()
    await fixture.apply(Search.Settings())
    let press = try #require(fixture.hotKey.onPress)

    press()
    #expect(fixture.panel.isShown)
    press()
    #expect(!fixture.panel.isShown)
}

@MainActor @Test func reRegistersTheHotkeyOnlyWhenItChanges() async {
    let fixture = Fixture()
    var settings = Search.Settings()
    await fixture.apply(settings)

    settings.maxResults = 3
    await fixture.apply(settings)
    #expect(fixture.hotKey.registered.count == 1)

    settings.hotkey = KeyChord([.control, .option], .k)
    await fixture.apply(settings)
    #expect(fixture.hotKey.registered == [KeyChord(.command, .space), settings.hotkey])
}

/// A config edit reaches the panel without a relaunch; the next show reads it.
@MainActor @Test func showOnAllDisplaysReachesThePanel() async {
    let fixture = Fixture()
    var settings = Search.Settings()
    await fixture.apply(settings)
    #expect(!fixture.panel.settings.showOnAllDisplays)

    settings.showOnAllDisplays = true
    await fixture.apply(settings)

    #expect(fixture.panel.settings.showOnAllDisplays)
    #expect(fixture.recorder.builds.count == 1)
}

@MainActor @Test func rebuildsTheIndexOnlyWhenAnIndexedKeyChanges() async {
    let fixture = Fixture()
    var settings = Search.Settings()
    await fixture.apply(settings)

    settings.calculator = false
    settings.hotkey = KeyChord(.control, .k)
    await fixture.apply(settings)
    #expect(fixture.recorder.builds.count == 1)

    settings.appFolders = ["/Volumes/Apps"]
    await fixture.apply(settings)
    #expect(fixture.recorder.builds.map(\.appFolders).last == ["/Volumes/Apps"])
    #expect(fixture.recorder.builds.count == 2)
}

@MainActor @Test func followsLaunchAtLoginOnlyWhenItChanges() async {
    let fixture = Fixture()
    var settings = Search.Settings()
    settings.launchAtLogin = true
    await fixture.apply(settings)
    #expect(fixture.loginItem.calls == 1)

    settings.maxResults = 4
    await fixture.apply(settings)
    #expect(fixture.loginItem.calls == 1)

    settings.launchAtLogin = false
    await fixture.apply(settings)
    #expect(fixture.loginItem.calls == 2)
    #expect(fixture.loginItem.status == .notRegistered)
}

@MainActor @Test func aConfigErrorShowsARowThatOpensTheFile() async throws {
    let fixture = Fixture()
    var settings = Search.Settings()
    settings.maxResults = 5
    await fixture.apply(settings)

    // A file with an error sets nothing, so the store sends the last good settings with it.
    await fixture.apply(
        settings, errors: [ConfigError(line: 3, key: "maxResults", reason: "too big")])
    try fixture.type("")

    #expect(fixture.titles == ["Config error: line 3: too big"])
    #expect(fixture.panel.settings.maxResults == 5)
    try fixture.pressReturn()
    await fixture.panel.configFileOpened?.value
    #expect(fixture.opener.opened == [configURL])
}

@MainActor @Test func aFixedConfigFileDropsItsRow() async throws {
    let fixture = Fixture()
    await fixture.apply(Search.Settings(), errors: [ConfigError(reason: "couldn't be read")])
    await fixture.apply(Search.Settings())
    try fixture.type("")

    #expect(fixture.titles.isEmpty)
}

@MainActor @Test func indexProblemsShowARowAboveTheResults() async throws {
    let fixture = Fixture(problems: [
        IndexProblem(path: "/Volumes/Apps", reason: "It doesn't exist.")
    ])
    await fixture.apply(Search.Settings())
    try fixture.type("saf")

    #expect(fixture.titles == ["Couldn't search Apps", "Safari"])
}

@MainActor @Test func theQuitRowQuits() async throws {
    let fixture = Fixture()
    await fixture.apply(Search.Settings())
    try fixture.type("quit")
    try fixture.pressReturn()

    #expect(fixture.quits == 1)
}

@MainActor @Test func theConfigRowOpensTheConfigFile() async throws {
    let fixture = Fixture()
    await fixture.apply(Search.Settings())
    try fixture.type("config")
    #expect(fixture.titles.first == "Simple Spotlight Config")
    try fixture.pressReturn()
    await fixture.panel.configFileOpened?.value

    #expect(fixture.opener.opened == [configURL])
}

@MainActor @Test func reopeningTheAppShowsThePanel() {
    let fixture = Fixture()

    fixture.coordinator.reopen()

    #expect(fixture.panel.isShown)
}

@MainActor @Test func aMacOSShortcutOnTheChordShowsTheNoticeAndStillRegisters() async throws {
    let fixture = Fixture()
    fixture.systemHotKeys = [
        SystemHotKey(modifiers: KeyChord.Modifiers.command.rawValue, code: 49, isEnabled: true)
    ]

    await fixture.apply(Search.Settings())

    #expect(fixture.notices.count == 1)
    #expect(fixture.notices.first?.title.contains("⌘Space") == true)
    #expect(fixture.hotKey.registered == [KeyChord(.command, .space)])
    try fixture.type("")
    #expect(fixture.titles == ["⌘Space is also Spotlight's shortcut"])
}

@MainActor @Test func aRefusedChordShowsTheNotice() async {
    let fixture = Fixture()
    fixture.hotKey.refusal = .refused(-9878)

    await fixture.apply(Search.Settings())

    #expect(fixture.notices.map(\.title) == ["Simple Spotlight can't use ⌘Space"])
}

@MainActor @Test func aFreeChordShowsNoNotice() async {
    let fixture = Fixture()
    fixture.systemHotKeys = [
        SystemHotKey(modifiers: KeyChord.Modifiers.command.rawValue, code: 49, isEnabled: false)
    ]

    await fixture.apply(Search.Settings())

    #expect(fixture.notices.isEmpty)
}

/// Each search announces its results; a config save that changes nothing the panel shows
/// mustn't search again.
@MainActor @Test func aStateThatChangesNothingShownDoesntSearch() async throws {
    let fixture = Fixture()
    var settings = Search.Settings()
    await fixture.apply(settings, errors: [ConfigError(reason: "couldn't be read")])
    try fixture.type("saf")
    fixture.announcements = []

    settings.launchAtLogin = true
    await fixture.apply(settings, errors: [ConfigError(reason: "couldn't be read")])

    #expect(fixture.announcements.isEmpty)
}

@MainActor @Test func aRefusedNewHotkeyLeavesTheOldOneWorking() async throws {
    let fixture = Fixture()
    var settings = Search.Settings()
    await fixture.apply(settings)
    fixture.hotKey.refusal = .refused(-9878)

    settings.hotkey = KeyChord(.control, .k)
    await fixture.apply(settings)

    #expect(fixture.hotKey.unregisters == 0)
    let press = try #require(fixture.hotKey.onPress)
    press()
    #expect(fixture.panel.isShown)
}

private let spotlightShortcut = SystemHotKey(
    modifiers: KeyChord.Modifiers.command.rawValue, code: 49, isEnabled: true)

/// With `launchAtLogin` the app starts at each login; the alert would take focus every time.
@MainActor @Test func theConflictAlertShowsOncePerChordAcrossLaunches() async throws {
    let first = Fixture()
    first.systemHotKeys = [spotlightShortcut]
    await first.apply(Search.Settings())
    #expect(first.notices.count == 1)

    let second = Fixture(state: first.stateFolder)
    second.systemHotKeys = [spotlightShortcut]
    await second.apply(Search.Settings())

    #expect(second.notices.isEmpty)
    try second.type("")
    #expect(second.titles == ["⌘Space is also Spotlight's shortcut"])
}

/// A press proves the chord reaches the app, so the system shortcut has been turned off.
@MainActor @Test func aPressOfTheHotkeyClearsTheConflictRow() async throws {
    let fixture = Fixture()
    fixture.systemHotKeys = [spotlightShortcut]
    await fixture.apply(Search.Settings())

    let press = try #require(fixture.hotKey.onPress)
    press()

    #expect(fixture.panel.isShown)
    #expect(fixture.titles.isEmpty)
}

@MainActor @Test func stopGivesTheHotkeyBackAndStopsTheWatch() async {
    let fixture = Fixture()
    await fixture.apply(Search.Settings())

    fixture.coordinator.stop()

    #expect(fixture.hotKey.unregisters == 1)
    #expect(fixture.hotKey.onPress == nil)
    #expect(fixture.watch.stops == 1)
}

private let mail = SearchItem(
    id: "com.apple.mail", kind: .app, title: "Mail", subtitle: nil,
    target: .openFile(URL(filePath: "/System/Applications/Mail.app")))
private let maps = SearchItem(
    id: "com.apple.Maps", kind: .app, title: "Maps", subtitle: nil,
    target: .openFile(URL(filePath: "/System/Applications/Maps.app")))

@MainActor @Test func aChangeInTheIndexFoldersRebuildsTheIndexKeepingTheQuery() async throws {
    let fixture = Fixture()
    await fixture.apply(Search.Settings())
    try fixture.type("saf")
    let onChange = try #require(fixture.watch.onChange)

    onChange()
    await fixture.coordinator.indexBuild?.value

    #expect(fixture.recorder.builds.count == 2)
    #expect(fixture.panel.query == "saf")
    #expect(fixture.titles == ["Safari"])
}

@MainActor @Test func watchesTheIndexFoldersAgainOnlyWhenAnIndexedKeyChanges() async {
    let fixture = Fixture()
    var settings = Search.Settings()
    await fixture.apply(settings)

    settings.maxResults = 3
    await fixture.apply(settings)
    #expect(fixture.watch.watched.count == 1)

    settings.appFolders = ["/Volumes/Apps"]
    await fixture.apply(settings)
    #expect(fixture.watch.watched.map(\.appFolders).last == ["/Volumes/Apps"])
    #expect(fixture.watch.watched.count == 2)
    #expect(fixture.watch.stops == 1)
}

@MainActor @Test func openingAnAppTwiceLiftsItAboveAnEqualMatch() async throws {
    let fixture = Fixture(items: [mail, maps])
    await fixture.apply(Search.Settings())
    try fixture.type("ma")
    #expect(fixture.titles == ["Mail", "Maps"])

    try await fixture.open("maps")
    try await fixture.open("maps")
    try fixture.type("ma")

    #expect(fixture.titles == ["Maps", "Mail"])
}

/// The user's report: typing "c" and opening Chrome should put Chrome first for "c" the next
/// time, over Chess, after one pick.
@MainActor @Test func oneOpenFromAQueryPutsTheItemFirstForItNextTime() async throws {
    let chess = SearchItem(
        id: "com.apple.Chess", kind: .app, title: "Chess", subtitle: nil,
        target: .openFile(URL(filePath: "/System/Applications/Chess.app")))
    let chrome = SearchItem(
        id: "com.google.Chrome", kind: .app, title: "Google Chrome", subtitle: nil,
        target: .openFile(URL(filePath: "/Applications/Google Chrome.app")))
    let fixture = Fixture(items: [chess, chrome])
    await fixture.apply(Search.Settings())
    try fixture.type("c")
    #expect(fixture.titles.prefix(2) == ["Chess", "Google Chrome"])

    fixture.panel.open(row: 1)
    await fixture.coordinator.usageUpdate?.value
    try fixture.type("c")

    #expect(fixture.titles.prefix(2) == ["Google Chrome", "Chess"])
}

@MainActor @Test func usageIsKeptAcrossLaunches() async throws {
    let first = Fixture(items: [mail, maps])
    await first.apply(Search.Settings())
    try await first.open("maps")
    await first.coordinator.flushUsage()

    let second = Fixture(items: [mail, maps], state: first.stateFolder)
    await second.apply(Search.Settings())
    await second.coordinator.usageUpdate?.value
    try second.type("ma")

    #expect(second.titles == ["Maps", "Mail"])
}

@MainActor @Test func aLoginItemAwaitingApprovalShowsARowUntilApproved() async throws {
    let fixture = Fixture()
    fixture.loginItem.statusAfterRegister = .requiresApproval
    var settings = Search.Settings()
    settings.launchAtLogin = true
    await fixture.apply(settings)
    try fixture.type("")
    #expect(fixture.titles == ["Allow Simple Spotlight in Login Items to open it at login"])
    fixture.panel.hide()

    fixture.loginItem.status = .enabled
    fixture.coordinator.reopen()

    #expect(fixture.titles.isEmpty)
    #expect(fixture.loginItem.calls == 1)
}

/// Holds each build until the test lets it finish.
private actor Gates {
    private var waiting: [Int: CheckedContinuation<Void, Never>] = [:]
    private var opened: Set<Int> = []

    func wait(_ gate: Int) async {
        guard !opened.contains(gate) else { return }
        await withCheckedContinuation { waiting[gate] = $0 }
    }

    func open(_ gate: Int) {
        opened.insert(gate)
        waiting.removeValue(forKey: gate)?.resume()
    }
}

@MainActor @Test func anOlderBuildFinishingLastDoesntReplaceANewerIndex() async throws {
    let gates = Gates()
    let chess = SearchItem(
        id: "com.apple.Chess", kind: .app, title: "Chess", subtitle: nil,
        target: .openFile(URL(filePath: "/System/Applications/Chess.app")))
    let fixture = Fixture(buildIndex: { settings throws(CancellationError) in
        // Ignores cancellation, as a build past its last check does.
        let gate = settings.appFolders == ["/Old"] ? 1 : 2
        await gates.wait(gate)
        return IndexBuilder.Build(
            items: gate == 1 ? [safari] : [chess], problems: [], duration: .zero)
    })
    var settings = Search.Settings()
    settings.appFolders = ["/Old"]
    fixture.coordinator.apply(settings: settings, errors: [])
    let older = try #require(fixture.coordinator.indexBuild)
    settings.appFolders = ["/New"]
    fixture.coordinator.apply(settings: settings, errors: [])
    let newer = try #require(fixture.coordinator.indexBuild)

    await gates.open(2)
    await newer.value
    await gates.open(1)
    await older.value

    #expect(fixture.panel.index.items.map(\.title).contains("Chess"))
    #expect(!fixture.panel.index.items.map(\.title).contains("Safari"))
}
