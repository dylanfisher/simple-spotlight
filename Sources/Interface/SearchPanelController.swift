import AppKit
import Search
import SwiftUI

/// Shows and hides the search panel, searches the current index and the calculator on each
/// keystroke, and handles the panel's keys: the arrows and Ctrl-N/P move the selection, Return
/// opens, ⌘Return reveals, ⌘1…⌘9 open a row, ⌘C copies a calculator answer, Esc clears then
/// hides, ⌘, opens the config file and ⌘Q quits, whatever the keyboard layout (docs/decisions/0008-search-panel-window.md).
///
/// A keystroke searches on the main actor: the index answers in well under a millisecond, so a
/// hop off it would cost more than the search.
@MainActor
public final class SearchPanelController: NSObject, NSTextFieldDelegate, NSWindowDelegate {
    /// The items searched. Setting it searches again, keeping the query and the selected item.
    public var index: SearchIndex {
        didSet { search(keepingSelection: true) }
    }
    /// Read for `maxResults` and `calculator`. Changing either searches again, as setting
    /// `index` does; searching happens only while the panel shows.
    public var settings: Search.Settings {
        didSet {
            guard
                settings.maxResults != oldValue.maxResults
                    || settings.calculator != oldValue.calculator
            else { return }
            search(keepingSelection: true)
        }
    }
    /// Rows shown above the results whatever the query, such as a config error. They count
    /// toward `maxResults`.
    public var leadingItems: [SearchItem] = [] {
        didSet { search(keepingSelection: true) }
    }
    /// What the user has opened, which ranks the results (docs/decisions/0010-usage-ranking.md).
    /// Setting it searches again, as setting `index` does.
    public var usage = UsageStore.Usage() {
        didSet {
            // Showing works the frecencies out, for the time it shows.
            guard isShown else { return }
            boost = UsageBoost(usage, at: now())
            search(keepingSelection: true)
        }
    }
    public private(set) var isShown = false
    /// The text in the field, kept while the panel is hidden.
    public var query: String { panel.field.stringValue }

    let panel = SearchPanel()
    let state = SearchState()
    let icons: IconCache
    private(set) var rowsView: ResultListHostingView!
    /// Speaks to VoiceOver: the results after each search, the row selected after each move.
    var announce: @MainActor (String) -> Void = SearchPanelController.postAnnouncement
    /// The visible area of the screen the panel last showed on; the rows stop at its bottom.
    /// Nil before the first show.
    private var visibleFrame: NSRect?
    /// The open of the config file ⌘, started last, for tests to wait on.
    private(set) var configFileOpened: Task<Void, Never>?
    /// `usage`'s frecencies as of the last show, so a keystroke only looks them up.
    private var boost = UsageBoost.none
    private let calculator: CalculatorProvider
    private let opener: any ResultOpener
    private let recordOpen: @MainActor (_ id: String, _ query: String) -> Void
    private let now: @MainActor () -> Date
    private let configFile: @MainActor () async throws(ConfigError) -> URL
    private let runCommand: @MainActor (String) -> Void
    private let quit: @MainActor () -> Void
    private let reportError: @MainActor (any Error) -> Void
    private let ordersPanel: Bool

    /// - Parameters:
    ///   - configFile: Gives the config file, creating the default one if it's missing, as
    ///     `ConfigStore.makeDefaultFileIfMissing` does.
    ///   - runCommand: Runs a `.command` row's identifier.
    ///   - recordOpen: Told the id of each app or System Settings pane opened, and the query
    ///     it was opened from, to count it in `usage`.
    ///   - now: The time `usage` decays to when the panel shows.
    ///   - quit: Runs on ⌘Q.
    ///   - reportError: Told when the config file can't be made.
    ///   - ordersPanel: Whether showing puts the panel on screen. Tests pass false, so the panel
    ///     takes the keys in code but never shows or takes focus.
    public init(
        index: SearchIndex, settings: Search.Settings, calculator: CalculatorProvider,
        opener: any ResultOpener, icons: IconCache,
        configFile: @escaping @MainActor () async throws(ConfigError) -> URL,
        runCommand: @escaping @MainActor (String) -> Void,
        recordOpen: @escaping @MainActor (_ id: String, _ query: String) -> Void,
        now: @escaping @MainActor () -> Date,
        quit: @escaping @MainActor () -> Void,
        reportError: @escaping @MainActor (any Error) -> Void,
        ordersPanel: Bool = true
    ) {
        self.index = index
        self.settings = settings
        self.calculator = calculator
        self.opener = opener
        self.icons = icons
        self.configFile = configFile
        self.runCommand = runCommand
        self.recordOpen = recordOpen
        self.now = now
        self.quit = quit
        self.reportError = reportError
        self.ordersPanel = ordersPanel
        super.init()
        let rows = ResultListHostingView(
            rootView: SearchView(state: state, icons: icons) { [weak self] in self?.open(row: $0) })
        rows.sizingOptions = []
        rowsView = rows
        panel.install(rows: rows)
        panel.field.delegate = self
        panel.delegate = self
        panel.keyEquivalent = { [weak self] in self?.keyEquivalent($0) ?? false }
    }

    // MARK: Showing

    /// Shows the panel on the screen with the mouse, the last query selected in the field.
    public func show() {
        // The mouse can sit on the edge between two screens, where no frame contains it.
        let mouse = NSEvent.mouseLocation
        guard
            let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
                ?? NSScreen.main
        else { preconditionFailure("there is no screen to show the panel on") }
        show(onScreen: screen.frame, visible: screen.visibleFrame)
    }

    /// Shows the panel on a screen whose frame is `screen` and whose visible area is `visible`,
    /// with as many rows as fit above the visible area's bottom.
    func show(onScreen screen: NSRect, visible: NSRect) {
        guard !isShown else { return }
        isShown = true
        visibleFrame = visible
        panel.setFrameTopLeftPoint(SearchPanel.topLeft(on: screen))
        boost = UsageBoost(usage, at: now())
        search(keepingSelection: true)
        // The field selects its whole text as it takes the keys, so typing replaces the query.
        panel.makeFirstResponder(panel.field)
        guard ordersPanel else { return }
        panel.makeKeyAndOrderFront(nil)
        panel.invalidateShadow()
    }

    /// Orders the panel in fully transparent and out again in the same run-loop turn, so the
    /// window server's window and the first drawing of the backdrop and the field happen now
    /// rather than on the first show, which they slowed from about 6 ms to 37. The panel never
    /// becomes key or visible (docs/decisions/0012-warm-panel.md).
    func prepare() {
        guard ordersPanel, !isShown else { return }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.displayIfNeeded()
        panel.orderOut(nil)
        panel.alphaValue = 1
    }

    /// Hides the panel, keeping the query for the next show.
    public func hide() {
        guard isShown else { return }
        isShown = false
        guard ordersPanel else { return }
        panel.orderOut(nil)
    }

    public func toggle() {
        if isShown { hide() } else { show() }
    }

    /// Hides the panel and opens the config file, making the default one if there is none.
    public func openConfigFile() {
        hide()
        configFileOpened = Task {
            do throws(ConfigError) {
                opener.open(try await configFile())
            } catch {
                reportError(error)
            }
        }
    }

    // MARK: Searching

    /// Fills the rows for the query: the leading items, the calculator's row, then the index's
    /// best matches, `maxResults` in all. The first row is selected, or with `keepingSelection`
    /// the row of the item selected before, if it is still there. Does nothing while the panel
    /// is hidden: showing searches, and a search no one sees would still be announced.
    private func search(keepingSelection: Bool = false) {
        guard isShown else { return }
        let query = query
        let kept = keepingSelection ? selectedRow?.item.id : nil
        var rows = leadingItems.map { SearchState.Row(item: $0, ranges: []) }
        if settings.calculator, let item = calculator.item(for: query) {
            rows.append(SearchState.Row(item: item, ranges: []))
        }
        let limit = min(settings.maxResults, rowsThatFit)
        let room = max(limit - rows.count, 0)
        rows += index.results(for: query, limit: room, usage: boost).map {
            SearchState.Row(item: $0.item, ranges: $0.ranges)
        }
        rows = Array(rows.prefix(limit))
        state.rows = rows
        state.selection = kept.flatMap { id in rows.firstIndex { $0.item.id == id } } ?? 0
        if let first = rows.first {
            let count = rows.count == 1 ? "1 result" : "\(rows.count) results"
            announce("\(count), \(ResultRow.accessibilityLabel(for: first.item))")
        } else {
            announce("No results")
        }
        icons.request(
            rows.compactMap {
                guard case .file(let path) = ResultRow.icon(for: $0.item) else { return nil }
                return path
            })
        panel.fit(rows: rows.count)
    }

    /// The rows with room between the panel's top and the bottom of the screen's visible area.
    private var rowsThatFit: Int {
        guard let visibleFrame else { return .max }
        return SearchPanel.rows(fitting: panel.frame.maxY - visibleFrame.minY)
    }

    private var selectedRow: SearchState.Row? {
        state.rows.indices.contains(state.selection) ? state.rows[state.selection] : nil
    }

    private func moveSelection(by offset: Int) {
        guard !state.rows.isEmpty else { return }
        let selection = min(max(state.selection + offset, 0), state.rows.count - 1)
        guard selection != state.selection else { return }
        state.selection = selection
        announce(ResultRow.accessibilityLabel(for: state.rows[selection].item))
    }

    private static func postAnnouncement(_ text: String) {
        NSAccessibility.post(
            element: NSApplication.shared, notification: .announcementRequested,
            userInfo: [
                .announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ])
    }

    // MARK: Opening

    /// Hides the panel and opens the row at `index`: launches an app, opens a pane, copies a
    /// calculator answer or runs a command. An index past the rows does nothing. Only apps and
    /// panes count toward usage (docs/decisions/0010-usage-ranking.md).
    func open(row index: Int) {
        guard state.rows.indices.contains(index) else { return }
        let item = state.rows[index].item
        hide()
        if item.kind == .app || item.kind == .settingsPane { recordOpen(item.id, query) }
        switch item.target {
        case .openFile(let url) where item.kind == .app:
            opener.openApplication(at: url)
        case .openFile(let url), .openURL(let url):
            opener.open(url)
        case .copyText(let text):
            opener.copy(text)
        case .command(let id):
            runCommand(id)
        }
    }

    /// Hides the panel and shows the selected row's file in Finder; a row with no file, such as
    /// the calculator's, does nothing.
    private func revealSelected() {
        guard let item = selectedRow?.item, case .openFile(let url) = item.target else { return }
        hide()
        opener.reveal(url)
    }

    // MARK: Keys

    /// The field's editor, which has the keys while the panel shows.
    private var editor: NSTextView? {
        panel.field.currentEditor() as? NSTextView
    }

    /// The Command chords the panel takes, and what each does.
    enum Chord: Equatable {
        case reveal, openConfig, quit, copy, cut, paste, selectAll
        /// Opens the row at this index.
        case row(Int)
    }

    /// The virtual key code of the keypad's Enter key, Carbon's `kVK_ANSI_KeypadEnter`. A Return
    /// for ⌘Return.
    static let keypadEnterCode: UInt16 = 0x4C

    /// The chords named by a letter or punctuation, with the character the key types on a Latin
    /// layout and the key that types it on a US one.
    private static let namedChords: [(character: String, key: KeyChord.Key, chord: Chord)] = [
        ("c", .c, .copy), ("x", .x, .cut), ("v", .v, .paste), ("a", .a, .selectAll),
        ("q", .q, .quit), (",", .comma, .openConfig),
    ]
    private static let digitKeys: [KeyChord.Key] = [
        .digit1, .digit2, .digit3, .digit4, .digit5, .digit6, .digit7, .digit8, .digit9,
    ]

    /// The chord a Command key makes, on any layout. Digits go by key, as AZERTY's digit keys
    /// type punctuation without Shift. Letters and punctuation go by the character the layout
    /// types, so ⌘A is the key that types a, unless the layout types no ASCII there, as a
    /// Cyrillic one doesn't; then by the key, where the US layout has the letter.
    static func chord(characters: String?, keyCode: UInt16) -> Chord? {
        if let digit = digitKeys.firstIndex(where: { $0.code == keyCode }) {
            return .row(digit)
        }
        if keyCode == KeyChord.Key.return.code || keyCode == keypadEnterCode { return .reveal }
        let typed = characters?.lowercased() ?? ""
        if let digit = Int(typed), (1...9).contains(digit) { return .row(digit - 1) }
        if typed.unicodeScalars.allSatisfy(\.isASCII), !typed.isEmpty {
            return namedChords.first { $0.character == typed }?.chord
        }
        return namedChords.first { $0.key.code == keyCode }?.chord
    }

    /// The Command chords. The app has no menu bar, so the editing chords the field needs are
    /// handled here; Command with any other modifier, or a key not listed, is left to the panel.
    private func keyEquivalent(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard modifiers == .command,
            let chord = Self.chord(
                characters: event.charactersIgnoringModifiers, keyCode: event.keyCode)
        else { return false }
        switch chord {
        case .reveal:
            revealSelected()
        case .openConfig:
            openConfigFile()
        case .quit:
            quit()
        case .copy:
            copySelectionOrAnswer()
        case .cut:
            cutSelection()
        case .paste:
            paste()
        case .selectAll:
            editor?.selectAll(nil)
        case .row(let index):
            open(row: index)
        }
        return true
    }

    /// The field's selected text and its range, or nil when nothing is selected.
    private var selectedText: (text: String, range: NSRange)? {
        guard let editor else { return nil }
        let range = editor.selectedRange()
        guard range.length > 0 else { return nil }
        return ((editor.string as NSString).substring(with: range), range)
    }

    /// ⌘C: the selected text in the field when there is some; otherwise the answer of a selected
    /// calculator row. With neither, nothing.
    private func copySelectionOrAnswer() {
        if let selected = selectedText {
            opener.copy(selected.text)
            return
        }
        guard let item = selectedRow?.item, item.kind == .calculation,
            case .copyText(let text) = item.target
        else { return }
        opener.copy(text)
    }

    /// ⌘X: copies the field's selected text and deletes it, which searches again.
    private func cutSelection() {
        guard let selected = selectedText, let editor else { return }
        opener.copy(selected.text)
        editor.insertText("", replacementRange: selected.range)
    }

    /// ⌘V: the clipboard's text over the field's selection, its line breaks as spaces, since
    /// the query is one line.
    private func paste() {
        guard let editor, let text = opener.clipboardText() else { return }
        let line = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        editor.insertText(line, replacementRange: editor.selectedRange())
    }

    public func controlTextDidChange(_ notification: Notification) {
        search()
    }

    /// The keys the field's editor turns into commands: the arrows and Ctrl-N/P move, Return
    /// opens, Esc clears or hides. Every other command edits the text as usual.
    public func control(
        _ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector
    ) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1)
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1)
        case #selector(NSResponder.insertNewline(_:)),
            #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)),
            #selector(NSResponder.insertLineBreak(_:)):
            open(row: state.selection)
        case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
            // The field is the panel's only control; Tab would only select its text again.
            break
        case #selector(NSResponder.cancelOperation(_:)):
            if query.isEmpty {
                hide()
            } else {
                panel.field.stringValue = ""
                search()
            }
        default:
            return false
        }
        return true
    }

    // MARK: Window

    /// A click elsewhere, or another app coming forward, takes the keys: the panel hides.
    public func windowDidResignKey(_ notification: Notification) {
        hide()
    }
}
