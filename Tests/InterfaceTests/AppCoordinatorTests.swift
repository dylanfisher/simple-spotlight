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

    func unregister() { onPress = nil }
}

/// Counts what was asked of the login item.
@MainActor
private final class StubLoginItem: LoginItemService {
    var status: SMAppService.Status = .notRegistered
    private(set) var calls = 0

    func register() throws {
        calls += 1
        status = .enabled
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

private let safari = SearchItem(
    id: "com.apple.Safari", kind: .app, title: "Safari", subtitle: nil,
    target: .openFile(URL(filePath: "/Applications/Safari.app")))
private let configURL = URL(filePath: "/tmp/simple-spotlight-test/config.json")

@MainActor
private final class Fixture {
    let opener = StubOpener()
    let hotKey = StubHotKey()
    let loginItem = StubLoginItem()
    let recorder: BuildRecorder
    var systemHotKeys: [SystemHotKey] = []
    var notices: [HotKeyConflictNotice.Content] = []
    var quits = 0
    var announcements: [String] = []
    private(set) var coordinator: AppCoordinator!

    init(problems: [IndexProblem] = []) {
        _ = NSApplication.shared
        recorder = BuildRecorder(items: [safari], problems: problems)
        let recorder = recorder
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
            buildIndex: { recorder.build($0) }, quit: { [unowned self] in quits += 1 },
            reportError: { Issue.record($0) }, log: Logger(.disabled), ordersPanel: false)
        coordinator.panel.announce = { [unowned self] in announcements.append($0) }
    }

    var panel: SearchPanelController { coordinator.panel }

    /// Applies `settings` and waits for the index build it starts, if any.
    func apply(_ settings: Search.Settings, errors: [ConfigError] = []) async {
        coordinator.apply(settings: settings, errors: errors)
        await coordinator.indexBuild?.value
    }

    func type(_ query: String) throws {
        panel.show()
        let editor = try #require(panel.panel.firstResponder as? NSTextView)
        editor.insertText(
            query, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
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

@MainActor @Test func aMacOSShortcutOnTheChordShowsTheNoticeAndStillRegisters() async {
    let fixture = Fixture()
    fixture.systemHotKeys = [
        SystemHotKey(modifiers: KeyChord.Modifiers.command.rawValue, code: 49, isEnabled: true)
    ]

    await fixture.apply(Search.Settings())

    #expect(fixture.notices.count == 1)
    #expect(fixture.notices.first?.title.contains("⌘Space") == true)
    #expect(fixture.hotKey.registered == [KeyChord(.command, .space)])
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
