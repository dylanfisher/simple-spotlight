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
        case copy(String)
    }

    private(set) var calls: [Call] = []
    var clipboard: String?

    func openApplication(at url: URL) { calls.append(.application(url)) }
    func open(_ url: URL) { calls.append(.open(url)) }
    func reveal(_ url: URL) { calls.append(.reveal(url)) }
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

/// A controller over a few items whose panel is never ordered on screen, with what it opened,
/// ran, quit and reported recorded.
@MainActor
private final class Fixture {
    let opener = StubOpener()
    var commands: [String] = []
    /// The ids the controller counted as opened.
    var recorded: [String] = []
    var now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    var quits = 0
    var errors: [String] = []
    var announcements: [String] = []
    var configResult: Result<URL, ConfigError> = .success(configURL)
    private(set) var controller: SearchPanelController!

    init(items: [SearchItem] = [safari, fontBook, scanner, bluetooth, quitItem]) {
        _ = NSApplication.shared
        controller = SearchPanelController(
            index: SearchIndex(items: items), settings: Settings(),
            calculator: CalculatorProvider(locale: Locale(identifier: "en_US")),
            opener: opener, icons: IconCache(load: { _ in NSImage() }),
            configFile: { [unowned self] () throws(ConfigError) in try configResult.get() },
            runCommand: { [unowned self] in commands.append($0) },
            recordOpen: { [unowned self] in recorded.append($0) },
            now: { [unowned self] in now },
            quit: { [unowned self] in quits += 1 },
            reportError: { [unowned self] in errors.append(String(describing: $0)) },
            ordersPanel: false)
        controller.announce = { [unowned self] in announcements.append($0) }
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
    #expect(fixture.recorded == ["com.apple.Safari"])
}

@MainActor @Test func returnOpensASettingsPaneByItsURL() throws {
    let fixture = Fixture()
    try fixture.type("bluetooth")

    try fixture.press("\r", keyCode: 36)

    #expect(fixture.opener.calls == [.open(bluetoothURL)])
    #expect(fixture.recorded == ["com.apple.BluetoothSettings"])
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
    usage.record("com.microsoft.scanner", at: fixture.now)
    fixture.controller.usage = usage

    try fixture.type("saf")

    #expect(fixture.titles == ["Safari", "Microsoft Safety Scanner"])
    for _ in 1..<Int(UsageBoost.liftingFrecency) {
        usage.record("com.microsoft.scanner", at: fixture.now)
    }
    fixture.controller.usage = usage
    #expect(fixture.titles == ["Microsoft Safety Scanner", "Safari"])
}

/// The frecencies are worked out at each show, so usage wears off while the app runs.
@MainActor @Test func usageDecaysToTheTimeOfEachShow() throws {
    let fixture = Fixture()
    var usage = UsageStore.Usage()
    for _ in 0..<Int(UsageBoost.liftingFrecency) {
        usage.record("com.microsoft.scanner", at: fixture.now)
    }
    fixture.controller.usage = usage
    try fixture.type("saf")
    #expect(fixture.titles == ["Microsoft Safety Scanner", "Safari"])

    fixture.controller.hide()
    fixture.now += UsageBoost.halfLife
    fixture.controller.show()

    #expect(fixture.titles == ["Safari", "Microsoft Safety Scanner"])
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

@MainActor @Test func commandCWithNothingSelectedOnAnAppRowCopiesNothing() throws {
    let fixture = Fixture()
    try fixture.type("saf")

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
    fixture.controller.index = SearchIndex(items: [safari, scanner, safariTechnologyPreview])

    #expect(fixture.controller.query == "saf")
    #expect(fixture.titles == ["Safari", "Safari Technology Preview", "Microsoft Safety Scanner"])
    #expect(fixture.selection == 2)
}

@MainActor @Test func commandCommaOpensTheConfigFile() async throws {
    let fixture = Fixture()

    #expect(try fixture.command(",", keyCode: 43))

    #expect(!fixture.controller.isShown)
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
    fixture.controller.show(onScreen: screen, visible: visible)

    try fixture.type("s")

    #expect(fixture.titles.count == 2)
    #expect(fixture.controller.panel.frame.minY >= visible.minY)
    try fixture.down()
    try fixture.down()
    #expect(fixture.selection == 1)
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
    await fixture.controller.configFileOpened?.value
    #expect(fixture.opener.calls == [.copy("6"), .open(configURL)])
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

    #expect(!fixture.controller.rowsView.acceptsFirstResponder)
}

// MARK: Accessibility

@MainActor @Test func theFieldReadsAsASearchField() {
    let fixture = Fixture()

    #expect(fixture.controller.panel.field.accessibilitySubrole() == .searchField)
    #expect(fixture.controller.panel.field.accessibilityLabel() == SearchPanel.searchLabel)
    #expect(fixture.controller.panel.field.placeholderString == SearchPanel.searchLabel)
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

    fixture.controller.index = SearchIndex(items: [fontBook])
    fixture.controller.leadingItems = [quitItem]
    #expect(fixture.announcements.isEmpty)

    fixture.controller.show()
    #expect(fixture.titles == ["Quit Simple Spotlight"])
    #expect(fixture.announcements.count == 1)
}
