import AppKit
import Foundation
import Search
import Testing

@testable import Interface

/// Records what the controller asked to open, instead of opening it.
@MainActor
private final class StubOpener: ResultOpener {
    enum Call: Equatable {
        case application(URL)
        case open(URL)
        case reveal(URL)
        case run(URL)
        case copy(String)
    }

    private(set) var calls: [Call] = []
    var clipboard: String?

    func openApplication(at url: URL) { calls.append(.application(url)) }
    func open(_ url: URL) { calls.append(.open(url)) }
    func reveal(_ url: URL) { calls.append(.reveal(url)) }
    func run(_ url: URL) { calls.append(.run(url)) }
    func copy(_ text: String) { calls.append(.copy(text)) }
    func clipboardText() -> String? { clipboard }
}

private let safari = SearchItem(
    id: "com.apple.Safari", kind: .app, title: "Safari", subtitle: "/Applications/Safari.app",
    target: .openFile(URL(filePath: "/Applications/Safari.app")))
private let fontBook = SearchItem(
    id: "com.apple.FontBook", kind: .app, title: "Font Book", subtitle: nil,
    target: .openFile(URL(filePath: "/System/Applications/Font Book.app")))
private let scanner = SearchItem(
    id: "com.microsoft.scanner", kind: .app, title: "Microsoft Safety Scanner", subtitle: nil,
    target: .openFile(URL(filePath: "/Applications/Microsoft Safety Scanner.app")))
private let bluetoothURL = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings")!
private let bluetooth = SearchItem(
    id: "com.apple.BluetoothSettings", kind: .settingsPane, title: "Bluetooth",
    subtitle: "System Settings", target: .openURL(bluetoothURL))
private let quitItem = SearchItem(
    id: "quit", kind: .command, title: "Quit Simple Spotlight", subtitle: nil,
    target: .command("quit"))
private let configURL = URL(filePath: "/tmp/simple-spotlight-test/config.json")

/// An open the controller counted.
private struct Recorded: Equatable {
    let id: String
    let query: String
}

/// A controller over a few items whose panel is never ordered on screen, with what it opened,
/// ran, quit and reported recorded.
@MainActor
private final class Fixture {
    let opener = StubOpener()
    var commands: [String] = []
    /// The ids the controller counted as opened, each with the query it was opened from.
    var recorded: [Recorded] = []
    var now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    var quits = 0
    var errors: [String] = []
    var announcements: [String] = []
    var configResult: Result<URL, ConfigError> = .success(configURL)
    var settingsOpened = 0
    private(set) var controller: SearchPanelController!

    init(
        items: [SearchItem] = [safari, fontBook, scanner, bluetooth, quitItem],
        groups: [String: [SearchItem]] = [:]
    ) {
        _ = NSApplication.shared
        controller = SearchPanelController(
            index: SearchIndex(items: items), groups: groups, settings: Settings(),
            calculator: CalculatorProvider(locale: Locale(identifier: "en_US")),
            opener: opener, icons: IconCache(load: { _ in NSImage() }),
            configFile: { [unowned self] in configResult },
            openSettings: { [unowned self] in settingsOpened += 1 },
            runCommand: { [unowned self] in commands.append($0) },
            recordOpen: { [unowned self] in recorded.append(Recorded(id: $0, query: $1)) },
            now: { [unowned self] in now },
            quit: { [unowned self] in quits += 1 },
            reportError: { [unowned self] in errors.append(String(describing: $0)) },
            ordersPanel: false)
        controller.announce = { [unowned self] in announcements.append($0) }
        controller.replaceIndex(SearchIndex(items: items), groups: groups)
        controller.show()
    }

    /// The field's editor, which has the keys while the panel shows.
    var editor: NSTextView {
        get throws {
            let editor = try #require(controller.panel.firstResponder as? NSTextView)
            #expect(editor.isFieldEditor)
            return editor
        }
    }

    /// Replaces the field's text with `query`, as typing would.
    func type(_ query: String) throws {
        let editor = try editor
        editor.insertText(
            query, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
    }

    func press(_ characters: String, keyCode: UInt16 = 0, modifiers: NSEvent.ModifierFlags = [])
        throws
    {
        try editor.keyDown(with: keyEvent(characters, modifiers: modifiers, keyCode: keyCode))
    }

    func down() throws {
        try press(functionKey(NSDownArrowFunctionKey), keyCode: 125, modifiers: arrowFlags)
    }

    func up() throws {
        try press(functionKey(NSUpArrowFunctionKey), keyCode: 126, modifiers: arrowFlags)
    }

    /// A Command chord, as AppKit offers it to the key window before its views.
    @discardableResult
    func command(_ characters: String, keyCode: UInt16 = 0) throws -> Bool {
        controller.panel.performKeyEquivalent(
            with: try keyEvent(characters, modifiers: .command, keyCode: keyCode))
    }

    /// The Command chord a key with `characters` and `keyCode` makes, on any layout.
    @discardableResult
    func command(characters: String, keyCode: UInt16) throws -> Bool {
        try command(characters, keyCode: keyCode)
    }

    var titles: [String] { controller.state.rows.map(\.item.title) }
    /// The titles of the rows drawn subdued.
    var dimmed: [String] { controller.state.rows.filter(\.dimmed).map(\.item.title) }
    var selection: Int { controller.state.selection }
}

@MainActor @Test func typingShowsTheBestMatchesFirstWithTheFirstSelected() throws {
    let fixture = Fixture()
    #expect(fixture.titles.isEmpty)

    try fixture.type("saf")

    #expect(fixture.titles.first == "Safari")
    #expect(fixture.titles.contains("Microsoft Safety Scanner"))
    #expect(fixture.selection == 0)
    #expect(fixture.controller.query == "saf")
}

@MainActor @Test func aKeyPressInTheFieldSearchesAgain() throws {
    let fixture = Fixture()

    try fixture.press("b")

    #expect(fixture.titles.first == "Bluetooth")
}

@MainActor @Test func theCalculatorRowComesFirstAndCountsTowardTheCap() throws {
    let fixture = Fixture()
    fixture.controller.settings.maxResults = 1

    try fixture.type("2*3")

    #expect(fixture.titles == ["6"])
}

@MainActor @Test func theCalculatorSettingTurnsItsRowOff() throws {
    let fixture = Fixture()
    fixture.controller.settings.calculator = false

    try fixture.type("2*3")

    #expect(fixture.titles.isEmpty)
}

@MainActor @Test func maxResultsCapsTheRows() throws {
    let fixture = Fixture()
    try fixture.type("s")
    #expect(fixture.titles.count > 2)

    fixture.controller.settings.maxResults = 2

    #expect(fixture.titles.count == 2)
    #expect(fixture.controller.query == "s")
}

@MainActor @Test func leadingItemsComeFirstAndCountTowardTheCap() throws {
    let fixture = Fixture()
    let error = SearchItem(
        id: "config-error", kind: .command, title: "Config error: line 3", subtitle: nil,
        target: .command("open-config"))
    fixture.controller.settings.maxResults = 2

    fixture.controller.leadingItems = [error]
    #expect(fixture.titles == ["Config error: line 3"])
    try fixture.type("s")

    #expect(fixture.titles.count == 2)
    #expect(fixture.titles.first == "Config error: line 3")

    fixture.controller.settings.maxResults = 1
    try fixture.type("2*3")
    #expect(fixture.titles == ["Config error: line 3"])
}

@MainActor @Test func downAndUpMoveTheSelectionAndStopAtTheEnds() throws {
    let fixture = Fixture()
    try fixture.type("saf")
    let count = fixture.titles.count
    #expect(count == 2)

    try fixture.up()
    #expect(fixture.selection == 0)
    try fixture.down()
    #expect(fixture.selection == 1)
    try fixture.down()
    #expect(fixture.selection == 1)
    try fixture.up()
    #expect(fixture.selection == 0)
}

@MainActor @Test func controlNAndControlPMoveTheSelection() throws {
    let fixture = Fixture()
    try fixture.type("saf")

    try fixture.press("n", characters: "\u{0E}", modifiers: .control, keyCode: 45)
    #expect(fixture.selection == 1)
    try fixture.press("p", characters: "\u{10}", modifiers: .control, keyCode: 35)
    #expect(fixture.selection == 0)
}

extension Fixture {
    func press(
        _ ignoringModifiers: String, characters: String, modifiers: NSEvent.ModifierFlags,
        keyCode: UInt16
    ) throws {
        try editor.keyDown(
            with: keyEvent(
                ignoringModifiers, characters: characters, modifiers: modifiers, keyCode: keyCode))
    }
}

@MainActor @Test func theSelectionGoesBackToTheFirstRowOnEachKeystroke() throws {
    let fixture = Fixture()
    try fixture.type("s")
    try fixture.down()
    #expect(fixture.selection == 1)

    try fixture.type("sa")

    #expect(fixture.selection == 0)
}

@MainActor @Test func returnOpensTheSelectedAppAndHides() throws {
    let fixture = Fixture()
    try fixture.type("saf")

    try fixture.press("\r", keyCode: 36)

    #expect(fixture.opener.calls == [.application(URL(filePath: "/Applications/Safari.app"))])
    #expect(!fixture.controller.isShown)
    #expect(fixture.recorded == [Recorded(id: "com.apple.Safari", query: "saf")])
}

@MainActor @Test func returnOpensASettingsPaneByItsURL() throws {
    let fixture = Fixture()
    try fixture.type("bluetooth")

    try fixture.press("\r", keyCode: 36)

    #expect(fixture.opener.calls == [.open(bluetoothURL)])
    #expect(fixture.recorded == [Recorded(id: "com.apple.BluetoothSettings", query: "bluetooth")])
}

/// A calculator answer, a command and a problem aren't things the user opens, so they don't
/// count toward usage (docs/decisions/0010-usage-ranking.md); nor does revealing an app.
@MainActor @Test func onlyAppsAndPanesCountAsOpened() throws {
    let fixture = Fixture()
    fixture.controller.leadingItems = [
        ProblemItems.row(.index, title: "Problem", subtitle: "", target: .copyText("problem"))
    ]
    for query in ["1+1", "quit"] {
        fixture.controller.show()
        try fixture.type(query)
        try fixture.command("2", keyCode: 19)
    }
    fixture.controller.show()
    try fixture.type("problem")
    try fixture.press("\r", keyCode: 36)
    fixture.controller.leadingItems = []
    fixture.controller.show()
    try fixture.type("saf")
    try fixture.command("\r", keyCode: 36)

    #expect(fixture.commands == ["quit"])
    #expect(
        fixture.opener.calls == [
            .copy("2"), .copy("problem"), .reveal(URL(filePath: "/Applications/Safari.app")),
        ])
    #expect(fixture.recorded.isEmpty)
}

@MainActor @Test func usageRanksTheResults() throws {
    let fixture = Fixture()
    var usage = UsageStore.Usage()
    usage.record("com.microsoft.scanner", query: "scanner", at: fixture.now)
    fixture.controller.usage = usage

    try fixture.type("saf")

    #expect(fixture.titles == ["Safari", "Microsoft Safety Scanner"])
    for _ in 1..<Int(UsageBoost.liftingFrecency) {
        usage.record("com.microsoft.scanner", query: "scanner", at: fixture.now)
    }
    fixture.controller.usage = usage
    #expect(fixture.titles == ["Microsoft Safety Scanner", "Safari"])
}

/// The frecencies are worked out at each show, so usage wears off while the app runs.
@MainActor @Test func usageDecaysToTheTimeOfEachShow() throws {
    let fixture = Fixture()
    var usage = UsageStore.Usage()
    for _ in 0..<Int(UsageBoost.liftingFrecency) {
        usage.record("com.microsoft.scanner", query: "scanner", at: fixture.now)
    }
    fixture.controller.usage = usage
    try fixture.type("saf")
    #expect(fixture.titles == ["Microsoft Safety Scanner", "Safari"])

    fixture.controller.hide()
    fixture.now += UsageBoost.halfLife
    fixture.controller.show()

    #expect(fixture.titles == ["Safari", "Microsoft Safety Scanner"])
}

/// Apps and panes not opened lately draw subdued (docs/decisions/0014-dim-unused.md); answers
/// and commands never do.
@MainActor @Test func rowsNotOpenedLatelyAreDimmed() throws {
    let fixture = Fixture()
    var usage = UsageStore.Usage()
    usage.record("com.apple.Safari", query: "saf", at: fixture.now)
    usage.record(
        "com.microsoft.scanner", query: "scanner",
        at: fixture.now.addingTimeInterval(-31 * 24 * 60 * 60))
    fixture.controller.usage = usage

    try fixture.type("saf")
    #expect(fixture.titles == ["Safari", "Microsoft Safety Scanner"])
    #expect(fixture.dimmed == ["Microsoft Safety Scanner"])

    try fixture.type("blue")
    #expect(fixture.dimmed == ["Bluetooth"])

    try fixture.type("quit")
    #expect(fixture.titles == ["Quit Simple Spotlight"])
    #expect(fixture.dimmed.isEmpty)

    try fixture.type("1+1")
    #expect(fixture.dimmed.isEmpty)
}

@MainActor @Test func theDimSettingsApplyWhileShown() throws {
    let fixture = Fixture()
    var usage = UsageStore.Usage()
    usage.record(
        "com.apple.Safari", query: "saf", at: fixture.now.addingTimeInterval(-10 * 24 * 60 * 60))
    fixture.controller.usage = usage
    try fixture.type("saf")
    #expect(fixture.dimmed == ["Microsoft Safety Scanner"])

    fixture.controller.settings.dimAfterDays = 7
    #expect(fixture.dimmed == ["Safari", "Microsoft Safety Scanner"])

    fixture.controller.settings.dimUnused = false
    #expect(fixture.dimmed.isEmpty)
}

/// Which rows dim is worked out at each show, as the frecencies are, so an item dims while the
/// app runs.
@MainActor @Test func dimmingIsWorkedOutAtEachShow() throws {
    let fixture = Fixture()
    var usage = UsageStore.Usage()
    usage.record("com.apple.Safari", query: "saf", at: fixture.now)
    fixture.controller.usage = usage
    try fixture.type("safari")
    #expect(fixture.dimmed.isEmpty)

    fixture.controller.hide()
    fixture.now += 31 * 24 * 60 * 60
    fixture.controller.show()

    #expect(fixture.dimmed == ["Safari"])
}

@MainActor @Test func returnOnTheCalculatorRowCopiesThePlainAnswer() throws {
    let fixture = Fixture()
    try fixture.type("1000*2")
    #expect(fixture.titles.first == "2,000")

    try fixture.press("\r", keyCode: 36)

    #expect(fixture.opener.calls == [.copy("2000")])
    #expect(!fixture.controller.isShown)
}

@MainActor @Test func returnOnACommandRowRunsTheCommand() throws {
    let fixture = Fixture()
    try fixture.type("quit")

    try fixture.press("\r", keyCode: 36)

    #expect(fixture.commands == ["quit"])
    #expect(fixture.opener.calls.isEmpty)
    #expect(!fixture.controller.isShown)
}

/// A script counts as an open, as an app does (docs/decisions/0010-usage-ranking.md).
@MainActor @Test func returnOnAScriptRowRunsItAndCountsAsAnOpen() throws {
    let url = URL(fileURLWithPath: "/tmp/simple-spotlight-test/commands/tv.sh")
    let script = SearchItem(
        id: SearchItem.builtInID("commands/tv.sh"), kind: .script, title: "TV", subtitle: nil,
        target: .runScript(url))
    let fixture = Fixture(items: [safari, script])
    try fixture.type("tv")

    try fixture.press("\r", keyCode: 36)

    #expect(fixture.opener.calls == [.run(url)])
    #expect(fixture.recorded == [Recorded(id: script.id, query: "tv")])
    #expect(!fixture.controller.isShown)
}

@MainActor @Test func returnWithNoRowsDoesNothing() throws {
    let fixture = Fixture()
    try fixture.type("zzzz")

    try fixture.press("\r", keyCode: 36)

    #expect(fixture.opener.calls.isEmpty)
    #expect(fixture.controller.isShown)
}

@MainActor @Test func commandReturnRevealsTheSelectedAppAndHides() throws {
    let fixture = Fixture()
    try fixture.type("saf")

    #expect(try fixture.command("\r", keyCode: 36))

    #expect(fixture.opener.calls == [.reveal(URL(filePath: "/Applications/Safari.app"))])
    #expect(!fixture.controller.isShown)
}

@MainActor @Test func commandReturnOnARowWithNoFileKeepsThePanel() throws {
    let fixture = Fixture()
    try fixture.type("2+2")

    #expect(try fixture.command("\r", keyCode: 36))

    #expect(fixture.opener.calls.isEmpty)
    #expect(fixture.controller.isShown)
}

@MainActor @Test func commandNumberOpensThatRow() throws {
    let fixture = Fixture()
    try fixture.type("saf")

    #expect(try fixture.command("2", keyCode: 19))

    #expect(
        fixture.opener.calls == [
            .application(URL(filePath: "/Applications/Microsoft Safety Scanner.app"))
        ])
    #expect(!fixture.controller.isShown)
}

@MainActor @Test func commandOneOpensTheFirstRow() throws {
    let fixture = Fixture()
    try fixture.type("saf")
    try fixture.down()

    #expect(try fixture.command("1", keyCode: 18))

    #expect(fixture.opener.calls == [.application(URL(filePath: "/Applications/Safari.app"))])
}

@MainActor @Test func commandNumberPastTheRowsDoesNothing() throws {
    let fixture = Fixture()
    try fixture.type("saf")

    #expect(try fixture.command("9", keyCode: 25))

    #expect(fixture.opener.calls.isEmpty)
    #expect(fixture.controller.isShown)
}

@MainActor @Test func commandCWithNothingSelectedCopiesTheCalculatorAnswer() throws {
    let fixture = Fixture()
    try fixture.type("1000*2")
    try fixture.editor.setSelectedRange(NSRange(location: 6, length: 0))

    #expect(try fixture.command("c", keyCode: 8))

    #expect(fixture.opener.calls == [.copy("2000")])
    #expect(fixture.controller.isShown)
}

@MainActor @Test func commandCWithNothingSelectedCopiesTheSelectedAppsPath() throws {
    let fixture = Fixture()
    try fixture.type("saf")
    try fixture.down()
    try fixture.editor.setSelectedRange(NSRange(location: 3, length: 0))

    #expect(try fixture.command("c", keyCode: 8))

    #expect(fixture.opener.calls == [.copy("/Applications/Microsoft Safety Scanner.app")])
    #expect(fixture.controller.isShown)
    #expect(fixture.recorded.isEmpty)
}

/// A pane copies the URL that opens it, which works in a link, a browser or `open`; its name is
/// in the field already (docs/decisions/0008-search-panel-window.md).
@MainActor @Test func commandCWithNothingSelectedCopiesTheSelectedPanesURL() throws {
    let prefPaneURL = URL(filePath: "/Library/PreferencePanes/Thing.prefPane")
    let prefPane = SearchItem(
        id: "/Library/PreferencePanes/Thing.prefPane", kind: .settingsPane, title: "Thing",
        subtitle: nil, target: .openFile(prefPaneURL))
    let fixture = Fixture(items: [bluetooth, prefPane])
    try fixture.type("bluetooth")
    try fixture.editor.setSelectedRange(NSRange(location: 9, length: 0))
    #expect(try fixture.command("c", keyCode: 8))
    try fixture.type("thing")
    try fixture.editor.setSelectedRange(NSRange(location: 5, length: 0))
    #expect(try fixture.command("c", keyCode: 8))

    #expect(
        fixture.opener.calls == [
            .copy("x-apple.systempreferences:com.apple.BluetoothSettings"),
            .copy("/Library/PreferencePanes/Thing.prefPane"),
        ])
}

/// A command and a problem have nothing to copy, though a problem's row may copy its text
/// when opened.
@MainActor @Test func commandCWithNothingSelectedOnACommandOrProblemCopiesNothing() throws {
    let fixture = Fixture()
    try fixture.type("quit")
    try fixture.editor.setSelectedRange(NSRange(location: 4, length: 0))
    #expect(try fixture.command("c", keyCode: 8))
    fixture.controller.leadingItems = [
        ProblemItems.row(.index, title: "Problem", subtitle: "", target: .copyText("problem"))
    ]
    #expect(fixture.titles.first == "Problem")
    #expect(try fixture.command("c", keyCode: 8))

    #expect(fixture.opener.calls.isEmpty)
}

@MainActor @Test func commandASelectsTheWholeQuery() throws {
    let fixture = Fixture()
    try fixture.type("saf")

    #expect(try fixture.command("a", keyCode: 0))

    #expect(try fixture.editor.selectedRange() == NSRange(location: 0, length: 3))
}

@MainActor @Test func escClearsTheQueryThenHides() throws {
    let fixture = Fixture()
    try fixture.type("saf")

    try fixture.press("\u{1B}", keyCode: 53)
    #expect(fixture.controller.query.isEmpty)
    #expect(fixture.titles.isEmpty)
    #expect(fixture.controller.isShown)

    try fixture.press("\u{1B}", keyCode: 53)
    #expect(!fixture.controller.isShown)
}

@MainActor @Test func reopeningShowsTheLastQuerySelected() throws {
    let fixture = Fixture()
    try fixture.type("saf")
    try fixture.editor.setSelectedRange(NSRange(location: 1, length: 0))
    try fixture.press("\r", keyCode: 36)
    #expect(!fixture.controller.isShown)

    fixture.controller.show()

    #expect(fixture.controller.isShown)
    #expect(fixture.controller.query == "saf")
    #expect(try fixture.editor.selectedRange() == NSRange(location: 0, length: 3))
    #expect(fixture.titles.first == "Safari")
}

@MainActor @Test func toggleShowsAndHides() {
    let fixture = Fixture()

    fixture.controller.toggle()
    #expect(!fixture.controller.isShown)
    fixture.controller.toggle()
    #expect(fixture.controller.isShown)
}

@MainActor @Test func losingTheKeysHides() {
    let fixture = Fixture()

    NotificationCenter.default.post(
        name: NSWindow.didResignKeyNotification, object: fixture.controller.panel)

    #expect(!fixture.controller.isShown)
}

@MainActor @Test func aNewIndexSearchesAgainKeepingTheQueryAndSelection() throws {
    let fixture = Fixture()
    try fixture.type("saf")
    try fixture.down()
    #expect(fixture.titles[1] == "Microsoft Safety Scanner")

    let safariTechnologyPreview = SearchItem(
        id: "com.apple.SafariTechnologyPreview", kind: .app,
        title: "Safari Technology Preview", subtitle: nil,
        target: .openFile(URL(filePath: "/Applications/Safari Technology Preview.app")))
    fixture.controller.replaceIndex(
        SearchIndex(items: [safari, scanner, safariTechnologyPreview]), groups: [:])

    #expect(fixture.controller.query == "saf")
    #expect(fixture.titles == ["Safari", "Safari Technology Preview", "Microsoft Safety Scanner"])
    #expect(fixture.selection == 2)
}

@MainActor @Test func commandCommaOpensSettings() throws {
    let fixture = Fixture()

    #expect(try fixture.command(",", keyCode: 43))

    #expect(!fixture.controller.isShown)
    #expect(fixture.settingsOpened == 1)
    #expect(fixture.opener.calls.isEmpty)
}

@MainActor @Test func theGearHidesThePanelAndOpensSettings() {
    let fixture = Fixture()

    fixture.controller.panel.showGear(true)
    fixture.controller.panel.gear.performClick(nil)

    #expect(!fixture.controller.isShown)
    #expect(fixture.settingsOpened == 1)
}

@MainActor @Test func theGearShowsWhenOptionIsAlreadyHeldAsThePanelAppears() {
    let fixture = Fixture()
    fixture.controller.hide()
    fixture.controller.modifierFlags = { [.option, .shift] }

    fixture.controller.show()

    #expect(!fixture.controller.panel.gear.isHidden)
}

@MainActor @Test func theGearStaysAwayWhenOptionIsntHeldAsThePanelAppears() {
    let fixture = Fixture()
    fixture.controller.hide()
    fixture.controller.modifierFlags = { .shift }

    fixture.controller.show()

    #expect(fixture.controller.panel.gear.isHidden)
}

@MainActor @Test func hidingTakesTheGearAway() {
    let fixture = Fixture()
    fixture.controller.panel.showGear(true)

    fixture.controller.hide()

    #expect(fixture.controller.panel.gear.isHidden)
}

@MainActor @Test func theConfigFileOpensFromTheController() async throws {
    let fixture = Fixture()

    fixture.controller.openConfigFile()

    await fixture.controller.configFileOpened?.value
    #expect(fixture.opener.calls == [.open(configURL)])
    #expect(fixture.errors.isEmpty)
}

@MainActor @Test func aConfigFileThatCantBeMadeIsReported() async throws {
    let fixture = Fixture()
    fixture.configResult = .failure(ConfigError(reason: "can't write it"))

    fixture.controller.openConfigFile()

    await fixture.controller.configFileOpened?.value
    #expect(fixture.opener.calls.isEmpty)
    #expect(fixture.errors == ["can't write it"])
}

@MainActor @Test func commandQQuits() throws {
    let fixture = Fixture()

    #expect(try fixture.command("q", keyCode: 12))

    #expect(fixture.quits == 1)
}

@MainActor @Test func otherCommandChordsAreLeftToThePanel() throws {
    let fixture = Fixture()

    #expect(try !fixture.command("t", keyCode: 17))
    #expect(
        !fixture.controller.panel.performKeyEquivalent(
            with: try keyEvent("q", modifiers: [.command, .shift], keyCode: 12)))
    #expect(fixture.quits == 0)
}

@MainActor @Test func thePanelGrowsWithTheRowsKeepingItsTop() throws {
    let fixture = Fixture()
    let panel = fixture.controller.panel
    let empty = panel.frame

    try fixture.type("saf")

    #expect(panel.frame.maxY == empty.maxY)
    #expect(panel.frame.height == SearchPanel.height(rows: 2))
    #expect(panel.frame.height > empty.height)
}

@MainActor @Test func theRowsIconsAreAskedForAsTheRowsShow() throws {
    let fixture = Fixture()

    try fixture.type("saf")

    let paths = fixture.controller.state.rows.map { ResultRow.icon(for: $0.item) }
    #expect(
        paths == [
            .file("/Applications/Safari.app"), .file("/Applications/Microsoft Safety Scanner.app"),
        ])
    #expect(fixture.controller.icons.isRequested("/Applications/Safari.app"))
    #expect(fixture.controller.icons.isRequested("/Applications/Microsoft Safety Scanner.app"))
}

@MainActor @Test func theControllerHandlesThePanelsAndTheFieldsEvents() {
    let fixture = Fixture()

    #expect(fixture.controller.panel.delegate === fixture.controller)
    #expect(fixture.controller.panel.field.delegate === fixture.controller)
}

// MARK: Screen

@MainActor @Test func theRowsStopAtTheBottomOfASmallScreen() throws {
    let fixture = Fixture()
    fixture.controller.hide()
    let screen = NSRect(x: 0, y: 0, width: 800, height: 250)
    let visible = NSRect(x: 0, y: 0, width: 800, height: 225)
    fixture.controller.show(on: [SearchPanelController.Display(frame: screen, visible: visible)])

    try fixture.type("s")

    #expect(fixture.titles.count == 2)
    #expect(fixture.controller.panel.frame.minY >= visible.minY)
    try fixture.down()
    try fixture.down()
    #expect(fixture.selection == 1)
}

// MARK: All displays

/// Three screens in a row: a tall one, the primary, a short one that fits two rows, and another
/// tall one. AppKit frames; each visible area leaves out a menu bar.
private let tall = SearchPanelController.Display(
    frame: NSRect(x: 0, y: 0, width: 1600, height: 1000),
    visible: NSRect(x: 0, y: 0, width: 1600, height: 975))
private let short = SearchPanelController.Display(
    frame: NSRect(x: 1600, y: 0, width: 800, height: 250),
    visible: NSRect(x: 1600, y: 0, width: 800, height: 225))
private let otherTall = SearchPanelController.Display(
    frame: NSRect(x: 2400, y: 0, width: 1600, height: 1000),
    visible: NSRect(x: 2400, y: 0, width: 1600, height: 975))

extension Fixture {
    /// Hides the panel and shows it on `displays`, the first taking the keys.
    func show(on displays: [SearchPanelController.Display]) {
        controller.hide()
        controller.show(on: displays)
    }

    var shown: [SearchPanel] { controller.shownPanels }
}

@Test func onlyTheFocusedDisplayIsUsedUnlessShowingOnAll() {
    let all = [tall, short, otherTall]

    #expect(SearchPanelController.displays(focused: short, all: all, onAll: false) == [short])
    #expect(
        SearchPanelController.displays(focused: short, all: all, onAll: true)
            == [short, tall, otherTall])
}

@MainActor @Test func showingOnEveryDisplayPutsAPanelOnEachWithTheKeysOnTheFirst() throws {
    let fixture = Fixture()

    fixture.show(on: [otherTall, tall, short])

    #expect(fixture.shown.count == 3)
    #expect(Set(fixture.shown.map(ObjectIdentifier.init)).count == 3)
    #expect(
        fixture.shown.map(\.frame.minX)
            == [otherTall, tall, short].map { SearchPanel.topLeft(on: $0.frame).x })
    #expect(fixture.controller.panel === fixture.shown[0])
    #expect(try fixture.editor.delegate === fixture.shown[0].field)
}

@MainActor @Test func everyPanelShowsTheSameQueryAndRows() throws {
    let fixture = Fixture()
    fixture.show(on: [tall, otherTall])

    try fixture.type("saf")

    #expect(fixture.shown.map(\.field.stringValue) == ["saf", "saf"])
    #expect(
        fixture.shown.map(\.frame.height) == Array(repeating: SearchPanel.height(rows: 2), count: 2)
    )
    #expect(
        fixture.controller.rowsViews.allSatisfy { $0.rootView.state === fixture.controller.state })

    try fixture.press("\u{1B}", keyCode: 53)
    #expect(fixture.shown.map(\.field.stringValue) == ["", ""])
}

/// The rows the keys move through are the ones the panel taking the keys has room for; a
/// panel on a shorter screen shows as many of them as fit there.
@MainActor @Test func eachPanelShowsTheRowsItsScreenHasRoomFor() throws {
    let fixture = Fixture()
    fixture.show(on: [tall, short])

    try fixture.type("s")

    let count = fixture.titles.count
    #expect(count > 2)
    #expect(fixture.shown[0].frame.height == SearchPanel.height(rows: count))
    #expect(fixture.shown[1].frame.height == SearchPanel.height(rows: 2))
    #expect(
        fixture.controller.rowsViews.prefix(2).map(\.rootView.limit)
            == [SearchPanel.rows(fitting: tall.frame.height * (1 - SearchPanel.topShare)), 2])
}

@MainActor @Test func hidingHidesEveryPanel() throws {
    let fixture = Fixture()
    fixture.show(on: [tall, short, otherTall])

    try fixture.press("\u{1B}", keyCode: 53)

    #expect(!fixture.controller.isShown)
    #expect(fixture.shown.isEmpty)
}

/// A click in another display's panel moves the keys there, and the panel it took them from
/// stays, as do the query and the selection.
@MainActor @Test func aClickInAnotherPanelMovesTheKeysToIt() throws {
    let fixture = Fixture()
    fixture.show(on: [tall, otherTall])
    try fixture.type("saf")
    try fixture.down()
    let first = fixture.shown[0]
    let second = fixture.shown[1]

    second.willTakeKeys(second)
    NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: first)

    #expect(fixture.controller.isShown)
    #expect(fixture.controller.panel === second)
    #expect(try fixture.editor.delegate === second.field)
    #expect(fixture.selection == 1)
    try fixture.type("font")
    #expect(first.field.stringValue == "font")
    #expect(fixture.titles == ["Font Book"])

    NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: second)
    #expect(!fixture.controller.isShown)
}

/// Taking the keys on a short screen leaves only the rows that fit there to move through.
@MainActor @Test func takingTheKeysOnAShortScreenCutsTheRowsToIt() throws {
    let fixture = Fixture()
    fixture.show(on: [tall, short])
    try fixture.type("s")
    #expect(fixture.titles.count > 2)

    fixture.shown[1].willTakeKeys(fixture.shown[1])

    #expect(fixture.titles.count == 2)
    #expect(fixture.shown[0].frame.height == SearchPanel.height(rows: 2))
}

/// A show on one display after one on several uses only the first panel.
@MainActor @Test func aLaterShowOnOneDisplayUsesOnePanel() throws {
    let fixture = Fixture()
    fixture.show(on: [tall, otherTall])
    fixture.shown[1].willTakeKeys(fixture.shown[1])

    fixture.show(on: [short])

    #expect(fixture.shown.count == 1)
    #expect(fixture.controller.panel === fixture.shown[0])
}

// MARK: Layouts

@MainActor @Test func commandDigitsOpenRowsByKeyOnAnAzertyLayout() throws {
    let fixture = Fixture()
    try fixture.type("saf")

    // AZERTY's 2 key types é without Shift.
    #expect(try fixture.command(characters: "é", keyCode: 19))

    #expect(
        fixture.opener.calls == [
            .application(URL(filePath: "/Applications/Microsoft Safety Scanner.app"))
        ])
}

@MainActor @Test func commandLettersFollowTheLayoutsLatinLetters() throws {
    let fixture = Fixture()
    try fixture.type("saf")

    // AZERTY swaps A and Q: the key in the US Q place types a.
    #expect(try fixture.command(characters: "a", keyCode: 12))
    #expect(fixture.quits == 0)
    #expect(try fixture.editor.selectedRange() == NSRange(location: 0, length: 3))

    #expect(try fixture.command(characters: "q", keyCode: 0))
    #expect(fixture.quits == 1)
}

@MainActor @Test func commandLettersFallBackToTheKeyOnACyrillicLayout() async throws {
    let fixture = Fixture()
    try fixture.type("2*3")
    try fixture.editor.setSelectedRange(NSRange(location: 3, length: 0))

    #expect(try fixture.command(characters: "с", keyCode: 8))
    #expect(fixture.opener.calls == [.copy("6")])
    #expect(try fixture.command(characters: "й", keyCode: 12))
    #expect(fixture.quits == 1)
    #expect(try fixture.command(characters: "б", keyCode: 43))
    #expect(fixture.settingsOpened == 1)
}

@MainActor @Test func commandKeypadEnterRevealsAsCommandReturnDoes() throws {
    let fixture = Fixture()
    try fixture.type("saf")

    #expect(try fixture.command(characters: "\u{3}", keyCode: 76))

    #expect(fixture.opener.calls == [.reveal(URL(filePath: "/Applications/Safari.app"))])
}

// MARK: Editing

@MainActor @Test func commandCWithTextSelectedCopiesTheText() throws {
    let fixture = Fixture()
    try fixture.type("1000*2")
    try fixture.editor.setSelectedRange(NSRange(location: 0, length: 4))

    #expect(try fixture.command("c", keyCode: 8))

    #expect(fixture.opener.calls == [.copy("1000")])
    #expect(fixture.controller.query == "1000*2")
}

@MainActor @Test func commandXCutsTheSelectedText() throws {
    let fixture = Fixture()
    try fixture.type("safari")
    try fixture.editor.setSelectedRange(NSRange(location: 3, length: 3))

    #expect(try fixture.command("x", keyCode: 7))

    #expect(fixture.opener.calls == [.copy("ari")])
    #expect(fixture.controller.query == "saf")
    #expect(fixture.titles.first == "Safari")
}

@MainActor @Test func commandVPastesTheClipboardOnOneLine() throws {
    let fixture = Fixture()
    try fixture.type("saf")
    try fixture.editor.setSelectedRange(NSRange(location: 0, length: 3))
    fixture.opener.clipboard = "Font\nBook"

    #expect(try fixture.command("v", keyCode: 9))

    #expect(fixture.controller.query == "Font Book")
    #expect(fixture.titles.first == "Font Book")
}

@MainActor @Test func tabKeepsTheKeysAndTheCursorInTheField() throws {
    let fixture = Fixture()
    try fixture.type("saf")

    try fixture.press("\t", keyCode: 48)
    try fixture.press("\u{19}", characters: "\u{19}", modifiers: .shift, keyCode: 48)

    #expect(try fixture.editor.selectedRange() == NSRange(location: 3, length: 0))
    #expect(fixture.controller.query == "saf")
}

/// A click makes the view under it first responder only if it accepts that.
@MainActor @Test func theRowsNeverTakeTheKeysFromTheField() {
    let fixture = Fixture()
    fixture.show(on: [tall, otherTall])

    #expect(fixture.controller.rowsViews.count == 2)
    #expect(fixture.controller.rowsViews.allSatisfy { !$0.acceptsFirstResponder })
}

// MARK: Accessibility

@MainActor @Test func theFieldReadsAsASearchField() {
    let fixture = Fixture()

    #expect(fixture.controller.panel.field.accessibilitySubrole() == .searchField)
    #expect(fixture.controller.panel.field.accessibilityLabel() == SearchPanel.searchLabel)
    #expect(fixture.controller.panel.field.placeholderString == SearchPanel.searchLabel)
}

@MainActor @Test func aCalculationIsAnnouncedAsItsRowReadsIt() throws {
    let fixture = Fixture()

    try fixture.type("2*(3+4)")
    #expect(fixture.announcements.last == "1 result, 2*(3+4) equals 14")
}

@MainActor @Test func theResultsAndEachMoveAreAnnounced() throws {
    let fixture = Fixture()

    try fixture.type("saf")
    #expect(fixture.announcements.last == "2 results, Safari, /Applications/Safari.app")
    try fixture.down()
    #expect(fixture.announcements.last == "Microsoft Safety Scanner")
    try fixture.type("zzzz")
    #expect(fixture.announcements.last == "No results")
    try fixture.type("")
    #expect(fixture.announcements.last == "No results")
}

/// A search while hidden would scan the index on the main actor and announce results no one
/// sees; showing searches anyway.
@MainActor @Test func aHiddenPanelDoesntSearchUntilShown() throws {
    let fixture = Fixture()
    try fixture.type("saf")
    fixture.controller.hide()
    fixture.announcements = []

    fixture.controller.replaceIndex(SearchIndex(items: [fontBook]), groups: [:])
    fixture.controller.leadingItems = [quitItem]
    #expect(fixture.announcements.isEmpty)

    fixture.controller.show()
    #expect(fixture.titles == ["Quit Simple Spotlight"])
    #expect(fixture.announcements.count == 1)
}

// MARK: Clicks in another panel

/// A real mouse-down through the panel's `sendEvent`, which is the hook that moves the keys.
@MainActor @Test func aMouseDownInAPanelThatIsNotKeyTellsTheController() throws {
    let panel = SearchPanel()
    var told: [SearchPanel] = []
    panel.willTakeKeys = { told.append($0) }
    let event = try #require(
        NSEvent.mouseEvent(
            with: .leftMouseDown, location: NSPoint(x: 10, y: 10), modifierFlags: [],
            timestamp: 0, windowNumber: panel.windowNumber, context: nil, eventNumber: 0,
            clickCount: 1, pressure: 1))

    panel.sendEvent(event)

    #expect(told == [panel])
}

@MainActor @Test func takingTheKeysPutsTheCaretAtTheEndOfTheQuery() throws {
    let fixture = Fixture()
    fixture.show(on: [tall, otherTall])
    try fixture.type("saf")

    fixture.shown[1].willTakeKeys(fixture.shown[1])

    let editor = try fixture.editor
    #expect(editor.selectedRange() == NSRange(location: 3, length: 0))
}

@MainActor @Test func theFirstClickInAPanelThatIsNotKeyReachesTheRowsAndTheField() {
    let fixture = Fixture()

    #expect(fixture.controller.rowsViews.allSatisfy { $0.acceptsFirstMouse(for: nil) })
    #expect(fixture.controller.panel.field.acceptsFirstMouse(for: nil))
}

@MainActor @Test func movingTheKeysDoesntAnnounceTheResultsAgain() throws {
    let fixture = Fixture()
    fixture.show(on: [tall, otherTall])
    try fixture.type("saf")
    let announced = fixture.announcements

    fixture.shown[1].willTakeKeys(fixture.shown[1])

    #expect(fixture.announcements == announced)
}

/// Only the field taking the keys holds the user's edits; the others are copies.
@MainActor @Test func aChangeInAnotherPanelsFieldDoesntSearch() throws {
    let fixture = Fixture()
    fixture.show(on: [tall, otherTall])
    try fixture.type("saf")
    let announced = fixture.announcements

    NotificationCenter.default.post(
        name: NSControl.textDidChangeNotification, object: fixture.shown[1].field)
    fixture.controller.controlTextDidChange(
        Notification(name: NSControl.textDidChangeNotification, object: fixture.shown[1].field))

    #expect(fixture.announcements == announced)
}

/// The copy into the other fields is a programmatic change, which doesn't search even when
/// that field still has its editor from an earlier click.
@MainActor @Test func copyingTheQueryIntoAFieldWithAnEditorDoesntSearch() throws {
    let fixture = Fixture()
    fixture.show(on: [tall, otherTall])
    fixture.shown[1].willTakeKeys(fixture.shown[1])
    fixture.shown[0].makeFirstResponder(fixture.shown[0].field)
    try fixture.type("font")
    let announced = fixture.announcements.count

    fixture.shown[0].field.stringValue = "saf"

    #expect(fixture.announcements.count == announced)
}

// MARK: Displays changing

@MainActor @Test func aScreenChangeHidesThePanels() {
    let fixture = Fixture()
    fixture.show(on: [tall, otherTall])

    fixture.controller.screensChanged()

    #expect(!fixture.controller.isShown)
    #expect(fixture.shown.isEmpty)
}

@MainActor @Test func aScreenChangeWithTheSettingOnDrawsThePanelsForTheNewDisplays() async {
    let fixture = Fixture()
    fixture.controller.settings.showOnAllDisplays = true
    await fixture.controller.queuedPrepare?.value
    fixture.controller.screenCount = { 3 }
    #expect(fixture.controller.panelCount == 1)

    fixture.controller.screensChanged()
    await fixture.controller.queuedPrepare?.value

    #expect(fixture.controller.panelCount == 3)
    #expect(fixture.controller.preparedCount == 3)
}

@MainActor @Test func aScreenChangeWithTheSettingOffMakesNoPanels() async {
    let fixture = Fixture()
    fixture.controller.screenCount = { 3 }

    fixture.controller.screensChanged()
    await fixture.controller.queuedPrepare?.value

    #expect(fixture.controller.panelCount == 1)
}

@MainActor @Test func panelsMadeByAShowCountAsDrawn() {
    let fixture = Fixture()

    fixture.show(on: [tall, short, otherTall])

    #expect(fixture.controller.preparedCount == 3)
}

@MainActor @Test func turningTheSettingOnWhileShownDrawsThePanelsAtTheNextHide() async {
    let fixture = Fixture()
    fixture.controller.screenCount = { 2 }
    fixture.controller.settings.showOnAllDisplays = true
    await fixture.controller.queuedPrepare?.value
    fixture.controller.settings.showOnAllDisplays = false
    fixture.controller.hide()
    fixture.controller.show(on: [tall])
    fixture.controller.settings.showOnAllDisplays = true
    await fixture.controller.queuedPrepare?.value
    #expect(fixture.controller.panelCount == 1)

    fixture.controller.hide()
    await fixture.controller.queuedPrepare?.value

    #expect(fixture.controller.panelCount == 2)
}

@MainActor @Test func turningTheSettingOffReleasesTheExtraPanels() {
    let fixture = Fixture()
    fixture.controller.settings.showOnAllDisplays = true
    fixture.controller.screenCount = { 3 }
    fixture.show(on: [tall, short, otherTall])
    fixture.controller.hide()
    #expect(fixture.controller.panelCount == 3)

    fixture.controller.settings.showOnAllDisplays = false

    #expect(fixture.controller.panelCount == 1)
    #expect(fixture.controller.preparedCount == 1)
}

@MainActor @Test func hidingReleasesPanelsPastTheNumberOfDisplays() {
    let fixture = Fixture()
    fixture.controller.settings.showOnAllDisplays = true
    fixture.controller.screenCount = { 2 }
    fixture.show(on: [tall, short, otherTall])
    #expect(fixture.controller.panelCount == 3)

    fixture.controller.hide()

    #expect(fixture.controller.panelCount == 2)
}

// MARK: Groups

private func script(_ path: String, _ title: String) -> SearchItem {
    SearchItem(
        id: SearchItem.builtInID("commands/\(path)"), kind: .script, title: title, subtitle: nil,
        target: .runScript(URL(fileURLWithPath: "/tmp/simple-spotlight-test/commands/\(path)")))
}

private func group(_ path: String, _ title: String) -> SearchItem {
    let id = SearchItem.builtInID("commands/\(path)")
    return SearchItem(id: id, kind: .group, title: title, subtitle: nil, target: .openGroup(id))
}

private let denon = group("Denon", "Denon")
private let zones = group("Denon/Zones", "Zones")
private let tv = script("Denon/tv.sh", "TV")
private let game = script("Denon/game.sh", "Game")
private let zoneTwo = script("Denon/Zones/zone2.sh", "Zone Two")
private let denonGroups = [denon.id: [tv, game, zones], zones.id: [zoneTwo]]

extension Fixture {
    /// A fixture whose top level has Safari and the Denon group, which holds TV, Game and the
    /// Zones group.
    static func withGroups() -> Fixture {
        Fixture(items: [safari, denon], groups: denonGroups)
    }

    /// Types `query` and presses Return, which opens the group it selects.
    func enter(_ query: String) throws {
        try type(query)
        try press("\r", keyCode: 36)
    }

    func right() throws {
        try press(functionKey(NSRightArrowFunctionKey), keyCode: 124, modifiers: arrowFlags)
    }

    func left() throws {
        try press(functionKey(NSLeftArrowFunctionKey), keyCode: 123, modifiers: arrowFlags)
    }

    func tab() throws { try press("\t", keyCode: 48) }

    func shiftTab() throws {
        try press("\u{19}", characters: "\u{19}", modifiers: .shift, keyCode: 48)
    }

    func backspace() throws { try press("\u{7F}", keyCode: 51) }

    func esc() throws { try press("\u{1B}", keyCode: 53) }

    var caret: NSRange { get throws { try editor.selectedRange() } }
}

@MainActor @Test func returnOnAGroupOpensItInsteadOfRunningAnything() throws {
    let fixture = Fixture.withGroups()

    try fixture.enter("denon")

    #expect(fixture.controller.isShown)
    #expect(fixture.controller.query.isEmpty)
    #expect(fixture.titles == ["TV", "Game", "Zones"])
    #expect(fixture.opener.calls.isEmpty)
    #expect(fixture.recorded.isEmpty)
}

@MainActor @Test func aGroupSearchesOnlyItsRows() throws {
    let fixture = Fixture.withGroups()
    try fixture.enter("denon")

    try fixture.type("a")

    #expect(fixture.titles == ["Game"])
}

@MainActor @Test func tabOpensTheSelectedGroup() throws {
    let fixture = Fixture.withGroups()
    try fixture.type("den")

    try fixture.tab()

    #expect(fixture.controller.query.isEmpty)
    #expect(fixture.titles == ["TV", "Game", "Zones"])
}

@MainActor @Test func tabOnARowThatIsNotAGroupDoesNothing() throws {
    let fixture = Fixture.withGroups()
    try fixture.type("saf")

    try fixture.tab()

    #expect(fixture.controller.query == "saf")
    #expect(fixture.titles == ["Safari"])
    #expect(fixture.opener.calls.isEmpty)
}

@MainActor @Test func rightArrowAtTheEndOfTheQueryOpensTheGroup() throws {
    let fixture = Fixture.withGroups()
    try fixture.type("denon")

    try fixture.right()

    #expect(fixture.controller.query.isEmpty)
    #expect(fixture.titles == ["TV", "Game", "Zones"])
}

@MainActor @Test func rightArrowInsideTheQueryMovesTheCursor() throws {
    let fixture = Fixture.withGroups()
    try fixture.type("denon")
    try fixture.editor.setSelectedRange(NSRange(location: 2, length: 0))

    try fixture.right()

    #expect(try fixture.caret == NSRange(location: 3, length: 0))
    #expect(fixture.controller.query == "denon")
    #expect(fixture.titles == ["Denon"])
}

@MainActor @Test func rightArrowWithTextSelectedMovesTheCursor() throws {
    let fixture = Fixture.withGroups()
    try fixture.type("denon")
    try fixture.editor.setSelectedRange(NSRange(location: 0, length: 5))

    try fixture.right()

    #expect(try fixture.caret == NSRange(location: 5, length: 0))
    #expect(fixture.titles == ["Denon"])
}

@MainActor @Test func rightArrowOnARowThatIsNotAGroupMovesTheCursor() throws {
    let fixture = Fixture.withGroups()
    try fixture.type("saf")
    try fixture.editor.setSelectedRange(NSRange(location: 3, length: 0))

    try fixture.right()

    #expect(try fixture.caret == NSRange(location: 3, length: 0))
    #expect(fixture.titles == ["Safari"])
}

@MainActor @Test func shiftTabGoesUpALevel() throws {
    let fixture = Fixture.withGroups()
    try fixture.enter("denon")
    try fixture.enter("zones")
    try fixture.type("two")
    #expect(fixture.titles == ["Zone Two"])

    try fixture.shiftTab()
    #expect(fixture.controller.query == "zones")
    #expect(fixture.titles == ["Zones"])

    try fixture.shiftTab()
    #expect(fixture.controller.query == "denon")
    #expect(fixture.titles == ["Denon"])

    // Gone up to the top, clear it to start the next query afresh.
    try fixture.type("")

    // At the top level it does nothing.
    try fixture.type("saf")
    try fixture.shiftTab()
    #expect(fixture.controller.query == "saf")
    #expect(fixture.titles == ["Safari"])
}

@MainActor @Test func leftArrowAtTheStartGoesUpALevel() throws {
    let fixture = Fixture.withGroups()
    try fixture.enter("denon")
    try fixture.type("tv")
    try fixture.editor.setSelectedRange(NSRange(location: 0, length: 0))

    try fixture.left()

    #expect(fixture.controller.query == "denon")
    #expect(fixture.titles == ["Denon"])
    #expect(fixture.controller.isShown)
}

@MainActor @Test func leftArrowElsewhereMovesTheCursor() throws {
    let fixture = Fixture.withGroups()
    try fixture.enter("denon")
    try fixture.type("tv")

    try fixture.left()
    #expect(try fixture.caret == NSRange(location: 1, length: 0))
    #expect(fixture.titles == ["TV"])

    // With text selected from the start, the selection collapses rather than going up.
    try fixture.editor.setSelectedRange(NSRange(location: 0, length: 2))
    try fixture.left()
    #expect(try fixture.caret == NSRange(location: 0, length: 0))
    #expect(fixture.titles == ["TV"])
}

@MainActor @Test func backspaceOnAnEmptyQueryGoesUpALevel() throws {
    let fixture = Fixture.withGroups()
    try fixture.enter("denon")
    try fixture.type("t")
    try fixture.editor.setSelectedRange(NSRange(location: 1, length: 0))

    try fixture.backspace()
    #expect(fixture.controller.query.isEmpty)
    #expect(fixture.titles == ["TV", "Game", "Zones"])

    try fixture.backspace()
    #expect(fixture.controller.query == "denon")
    #expect(fixture.titles == ["Denon"])
    #expect(fixture.controller.isShown)
}

@MainActor @Test func escClearsTheQueryThenGoesUpEachLevelThenHides() throws {
    let fixture = Fixture.withGroups()
    try fixture.enter("denon")
    try fixture.enter("zones")
    try fixture.type("two")

    try fixture.esc()
    #expect(fixture.controller.query.isEmpty)
    #expect(fixture.titles == ["Zone Two"])

    // Each level's restored query is cleared before the next press goes up.
    try fixture.esc()
    #expect(fixture.controller.query == "zones")
    #expect(fixture.titles == ["Zones"])
    try fixture.esc()
    #expect(fixture.controller.query.isEmpty)
    #expect(fixture.controller.path.count == 1)

    try fixture.esc()
    #expect(fixture.controller.query == "denon")
    #expect(fixture.titles == ["Denon"])
    try fixture.esc()
    #expect(fixture.controller.query.isEmpty)
    #expect(fixture.controller.isShown)

    try fixture.esc()
    #expect(!fixture.controller.isShown)
}

@MainActor @Test func hidingAtTheTopLevelKeepsTheQuery() throws {
    let fixture = Fixture.withGroups()
    try fixture.type("saf")

    fixture.controller.hide()
    fixture.controller.show()

    #expect(fixture.controller.query == "saf")
    #expect(fixture.titles == ["Safari"])
}

@MainActor @Test func problemsAndTheCalculatorShowOnlyAtTheTopLevel() throws {
    let fixture = Fixture.withGroups()
    let error = SearchItem(
        id: "config-error", kind: .problem, title: "Config error: line 3", subtitle: nil,
        target: .command("open-config"))
    fixture.controller.leadingItems = [error]
    try fixture.type("denon")
    try fixture.down()
    try fixture.press("\r", keyCode: 36)
    #expect(fixture.titles == ["TV", "Game", "Zones"])

    try fixture.type("2*3")

    #expect(fixture.titles.isEmpty)
}

@MainActor @Test func aRebuildKeepsTheOpenGroupAndTheQuery() throws {
    let fixture = Fixture.withGroups()
    try fixture.enter("denon")
    try fixture.type("t")
    let tuner = script("Denon/tuner.sh", "Tuner")

    fixture.controller.replaceIndex(
        SearchIndex(items: [safari, denon]), groups: [denon.id: [tv, game, tuner]])

    #expect(fixture.controller.query == "t")
    #expect(Set(fixture.titles) == ["TV", "Tuner"])
}

@MainActor @Test func aRebuildThatRemovesTheInnerGroupLandsInTheOuterOneWithItsQuery() throws {
    let fixture = Fixture.withGroups()
    try fixture.enter("denon")
    try fixture.enter("zon")
    try fixture.type("t")
    let zonal = script("Denon/zonal.sh", "Zonal")

    fixture.controller.replaceIndex(
        SearchIndex(items: [safari, denon]), groups: [denon.id: [tv, game, zonal]])

    #expect(fixture.controller.path.map(\.row.title) == ["Denon"])
    #expect(fixture.controller.query == "zon")
    #expect(fixture.titles == ["Zonal"])
    #expect(fixture.breadcrumbs == ["Denon ›"])
}

@MainActor @Test func aRebuildThatKeepsTheGroupsStillRemembersWhereToGoUp() throws {
    let fixture = Fixture.withGroups()
    try fixture.type("denon")
    try fixture.right()
    let tuner = script("Denon/tuner.sh", "Tuner")

    fixture.controller.replaceIndex(
        SearchIndex(items: [safari, denon]), groups: [denon.id: [tv, game, tuner]])
    try fixture.left()

    #expect(fixture.controller.query == "denon")
    #expect(fixture.titles == ["Denon"])
}

@MainActor @Test func aRebuildThatRemovesATopLevelOpenGroupGoesToTheTopLevel() throws {
    let fixture = Fixture.withGroups()
    try fixture.enter("denon")
    try fixture.type("t")

    fixture.controller.replaceIndex(SearchIndex(items: [safari]), groups: [:])

    #expect(fixture.controller.path.isEmpty)
    #expect(fixture.controller.query == "denon")
    #expect(fixture.titles.isEmpty)
    try fixture.type("saf")
    #expect(fixture.titles == ["Safari"])
}

@MainActor @Test func commandNumberOnAGroupRowOpensItWithoutHidingOrRecording() throws {
    let fixture = Fixture.withGroups()
    try fixture.type("denon")

    #expect(try fixture.command("1", keyCode: 18))

    #expect(fixture.controller.isShown)
    #expect(fixture.titles == ["TV", "Game", "Zones"])
    #expect(fixture.opener.calls.isEmpty)
    #expect(fixture.recorded.isEmpty)
}

@MainActor @Test func aClickOnAGroupRowOpensItWithoutHidingOrRecording() throws {
    let fixture = Fixture.withGroups()
    try fixture.type("denon")

    fixture.controller.open(row: 0)

    #expect(fixture.controller.isShown)
    #expect(fixture.titles == ["TV", "Game", "Zones"])
    #expect(fixture.opener.calls.isEmpty)
    #expect(fixture.recorded.isEmpty)
}

@MainActor @Test func backspaceWithTextInsideAGroupEditsTheTextAndStays() throws {
    let fixture = Fixture.withGroups()
    try fixture.enter("denon")
    try fixture.type("tv")

    try fixture.backspace()

    #expect(fixture.controller.query == "t")
    #expect(fixture.controller.path.count == 1)
}

@MainActor @Test func arrowsDuringAnInputMethodCompositionNeitherOpenNorLeaveAGroup() throws {
    let fixture = Fixture.withGroups()
    let editor = try fixture.editor
    try fixture.type("denon")
    editor.setMarkedText(
        "denon", selectedRange: NSRange(location: 5, length: 0),
        replacementRange: NSRange(location: 0, length: 5))
    #expect(editor.hasMarkedText())
    #expect(fixture.titles == ["Denon"])

    try fixture.right()
    #expect(fixture.controller.path.isEmpty)

    editor.unmarkText()
    try fixture.enter("denon")
    editor.setMarkedText(
        "t", selectedRange: NSRange(location: 0, length: 0),
        replacementRange: NSRange(location: 0, length: 0))
    try fixture.left()
    #expect(fixture.controller.path.count == 1)
}

@MainActor @Test func leavingAGroupAtTheTopLevelDoesNothing() throws {
    let fixture = Fixture.withGroups()
    try fixture.type("saf")

    try fixture.shiftTab()
    try fixture.backspace()

    #expect(fixture.controller.path.isEmpty)
    #expect(fixture.controller.query == "sa")
    #expect(fixture.controller.isShown)
}

@MainActor @Test func everyPanelShowsTheSameGroup() throws {
    let fixture = Fixture.withGroups()
    fixture.show(on: [tall, otherTall])
    try fixture.type("denon")
    #expect(fixture.shown.map(\.field.stringValue) == ["denon", "denon"])

    try fixture.press("\r", keyCode: 36)

    #expect(fixture.shown.map(\.field.stringValue) == ["", ""])
    #expect(
        fixture.shown.map(\.frame.height) == Array(repeating: SearchPanel.height(rows: 3), count: 2)
    )
}

extension Fixture {
    /// The breadcrumb of each panel showing: its text, or nil while it is hidden.
    var breadcrumbs: [String?] {
        shown.map { $0.breadcrumb.isHidden ? nil : $0.breadcrumb.title }
    }
}

@MainActor @Test func everyPanelsBreadcrumbShowsTheGroupsOpen() throws {
    let fixture = Fixture.withGroups()
    fixture.show(on: [tall, otherTall])
    #expect(fixture.breadcrumbs == [nil, nil])

    try fixture.enter("denon")
    #expect(fixture.breadcrumbs == ["Denon ›", "Denon ›"])

    try fixture.enter("zones")
    #expect(fixture.breadcrumbs == ["Denon › Zones ›", "Denon › Zones ›"])

    try fixture.shiftTab()
    #expect(fixture.breadcrumbs == ["Denon ›", "Denon ›"])

    fixture.controller.hide()
    fixture.show(on: [tall, otherTall])
    #expect(fixture.breadcrumbs == [nil, nil])
}

@MainActor @Test func aClickOnTheBreadcrumbGoesUpALevel() throws {
    let fixture = Fixture.withGroups()
    try fixture.enter("denon")
    try fixture.enter("zones")

    fixture.controller.panel.breadcrumb.performClick(nil)

    #expect(fixture.controller.path.map(\.row.title) == ["Denon"])
    #expect(fixture.titles == ["Zones"])
    #expect(fixture.controller.isShown)
}

extension Array {
    fileprivate subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

extension Fixture {
    /// A fixture whose top level has a second group, "Denon Two", ahead of Denon in the rows
    /// for "denon", so that the selected row isn't the first.
    static func withTwoMatches() -> Fixture {
        let other = group("Other", "Denon Other")
        let groups = denonGroups.merging([other.id: [script("Other/x.sh", "X")]]) { $1 }
        return Fixture(items: [safari, other, denon], groups: groups)
    }

    /// Moves the selection down until the row titled `title` is selected.
    func select(_ title: String) throws {
        for _ in 0..<titles.count where titles[safe: selection] != title { try down() }
        #expect(titles[safe: selection] == title)
    }
}

/// Every way of going up puts back the query and the group's row, with the caret at the end.
@MainActor @Test func goingUpRestoresTheQueryAndSelectsTheGroupRow() throws {
    let ways: [(String, (Fixture) throws -> Void)] = [
        ("left", { try $0.left() }),
        ("backspace", { try $0.backspace() }),
        ("shift-tab", { try $0.shiftTab() }),
        ("esc", { try $0.esc() }),
        ("breadcrumb", { $0.controller.panel.breadcrumb.performClick(nil) }),
    ]
    for (name, goUp) in ways {
        let fixture = Fixture.withTwoMatches()
        try fixture.type("denon")
        try fixture.select("Denon")
        try fixture.right()
        #expect(fixture.controller.query.isEmpty, "\(name)")

        try goUp(fixture)

        #expect(fixture.controller.query == "denon", "\(name)")
        #expect(try fixture.caret == NSRange(location: 5, length: 0), "\(name)")
        #expect(fixture.titles[safe: fixture.selection] == "Denon", "\(name)")
        #expect(fixture.controller.path.isEmpty, "\(name)")
    }
}

@MainActor @Test func goingUpFromANestedGroupRestoresEachLevel() throws {
    let fixture = Fixture.withTwoMatches()
    try fixture.type("denon")
    try fixture.select("Denon")
    try fixture.right()
    try fixture.type("o")
    try fixture.select("Zones")
    try fixture.right()
    try fixture.type("two")

    try fixture.shiftTab()
    #expect(fixture.controller.path.map(\.row.title) == ["Denon"])
    #expect(fixture.controller.query == "o")
    #expect(fixture.titles[safe: fixture.selection] == "Zones")

    try fixture.shiftTab()
    #expect(fixture.controller.query == "denon")
    #expect(fixture.titles[safe: fixture.selection] == "Denon")
}

@MainActor @Test func hidingInsideANestedGroupGoesUpToTheTopLevelLikeLeavingEachLevel() throws {
    let fixture = Fixture.withTwoMatches()
    fixture.show(on: [tall, otherTall])
    try fixture.type("denon")
    try fixture.select("Denon")
    try fixture.right()
    try fixture.type("o")
    try fixture.select("Zones")
    try fixture.right()

    fixture.controller.hide()
    fixture.show(on: [tall, otherTall])

    #expect(fixture.controller.path.isEmpty)
    #expect(fixture.shown.map(\.field.stringValue) == ["denon", "denon"])
    #expect(fixture.titles[safe: fixture.selection] == "Denon")
}

@MainActor @Test func aRebuildThatRemovesTheOpenGroupHidesTheBreadcrumb() throws {
    let fixture = Fixture.withGroups()
    try fixture.enter("denon")

    fixture.controller.replaceIndex(SearchIndex(items: [safari]), groups: [:])

    #expect(fixture.breadcrumbs == [nil])
}

/// Entering says the group and how many rows it has, in place of the first row; going up says
/// where the panel is now, the top level being the field's own name.
@MainActor @Test func enteringAndLeavingAGroupSaySoToVoiceOver() throws {
    let fixture = Fixture.withGroups()

    try fixture.enter("denon")
    #expect(fixture.announcements.last == "Denon, 3 commands")

    try fixture.enter("zones")
    #expect(fixture.announcements.last == "Zones, 1 command")

    let announced = fixture.announcements.count
    try fixture.backspace()
    #expect(fixture.announcements.count == announced + 1)
    #expect(fixture.announcements.last == "Denon")

    try fixture.esc()
    try fixture.esc()
    #expect(fixture.announcements.last == "Search")
}
