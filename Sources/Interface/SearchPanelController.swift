import AppKit
import Search
import SwiftUI

/// Shows and hides the search panel, searches the current index and the calculator on each
/// keystroke, and handles the panel's keys: the arrows and Ctrl-N/P move the selection, Return
/// opens, ⌘Return reveals in Finder, ⌘1…⌘9 open a row, ⌘C copies the field's selected text or
/// else the selected row's path, URL or answer, Esc clears then hides, ⌘, opens Settings, as the
/// gear does that Option shows, and ⌘Q quits, whatever the keyboard layout
/// (docs/decisions/0008-search-panel-window.md). The keys the field's editor sends are listed
/// at `control(_:textView:doCommandBy:)`.
///
/// Opening a group's row searches only that group's rows until the panel goes back up a level.
/// Hiding goes back to the top level.
///
/// With `showOnAllDisplays` it shows a panel on every display, all with the same query, rows and
/// selection; one takes the keys (docs/decisions/0013-all-displays.md).
///
/// A keystroke searches on the main actor: the index answers in well under a millisecond, so a
/// hop off it would cost more than the search.
@MainActor
public final class SearchPanelController: NSObject, NSTextFieldDelegate, NSWindowDelegate {
    /// The top level's items, searched outside a group. `replaceIndex(_:groups:)` sets it.
    public private(set) var index: SearchIndex
    /// Each group's rows, keyed by the group's id, as `IndexBuilder.Build.groups` holds them.
    public private(set) var groups: [String: [SearchItem]] = [:]
    /// Read for `maxResults`, `calculator`, `dimUnused`, `dimAfterDays` and `showOnAllDisplays`.
    /// Changing any but `showOnAllDisplays` searches again, as `replaceIndex(_:groups:)` does;
    /// searching happens only while the panel shows. The next show reads `showOnAllDisplays`.
    public var settings: Search.Settings {
        didSet {
            if settings.showOnAllDisplays, !oldValue.showOnAllDisplays {
                // Draws the other displays' panels once too, so their first show is quick. The
                // coordinator's `prepare()` at launch draws the first panel; this covers the
                // setting turning on later, and costs nothing when that call has already
                // drawn them.
                schedulePrepare()
            } else if !settings.showOnAllDisplays, oldValue.showOnAllDisplays {
                releaseUnusedPanels()
            }
            let dimming =
                settings.dimUnused != oldValue.dimUnused
                || settings.dimAfterDays != oldValue.dimAfterDays
            guard
                dimming || settings.maxResults != oldValue.maxResults
                    || settings.calculator != oldValue.calculator
            else { return }
            if dimming, isShown { takeUsage() }
            search(keepingSelection: true)
        }
    }
    /// Rows shown above the results whatever the query, such as a config error. They count
    /// toward `maxResults`.
    public var leadingItems: [SearchItem] = [] {
        didSet { search(keepingSelection: true) }
    }
    /// What the user has opened, which ranks the results (docs/decisions/0010-usage-ranking.md).
    /// Setting it searches again, as `replaceIndex(_:groups:)` does.
    public var usage = UsageStore.Usage() {
        didSet {
            // Showing works the frecencies out, for the time it shows.
            guard isShown else { return }
            takeUsage()
            search(keepingSelection: true)
        }
    }
    public private(set) var isShown = false
    /// The groups opened, outermost first; empty at the top level.
    private(set) var path: [OpenGroup] = []
    /// The text in the field, kept while the panel is hidden.
    public var query: String { panel.field.stringValue }

    /// A screen to show a panel on: its frame, and its visible area, where the rows stop.
    struct Display: Equatable {
        let frame: NSRect
        let visible: NSRect
    }

    /// The panel taking the keys: the one on the focused window's display, or the one clicked
    /// since.
    var panel: SearchPanel { slots[keyIndex].panel }
    /// The panels showing, the one that took the keys at the show first; empty while hidden.
    var shownPanels: [SearchPanel] { slots.prefix(shownCount).map(\.panel) }
    /// The rows' views of every panel made, in `slots` order. For tests.
    var rowsViews: [ResultListHostingView] { slots.map(\.rows) }
    let state = SearchState()
    let icons: IconCache
    /// Speaks to VoiceOver: the results after each search, the row selected after each move.
    var announce: @MainActor (String) -> Void = SearchPanelController.postAnnouncement
    /// A group opened: the row it was opened from, and its rows, searched in place of `index`.
    struct OpenGroup {
        let row: SearchItem
        let index: SearchIndex
    }

    /// A panel with its rows, and the visible area of the screen it last showed on, where its
    /// rows stop; nil before its first show.
    private struct Slot {
        let panel: SearchPanel
        let rows: ResultListHostingView
        var visible: NSRect?
    }

    /// The panels made so far, the first at init and one more for each further display shown
    /// on at once. Kept while hidden, so a show doesn't make them again.
    private var slots: [Slot] = []
    /// How many of `slots`, from the first, show; 0 while hidden.
    private var shownCount = 0
    /// The index in `slots` of the panel taking the keys.
    private var keyIndex = 0
    /// How many of `slots`, from the first, have been drawn, by `prepare()` or by a show.
    private(set) var preparedCount = 0
    /// Whether a `prepare()` is queued, so a second request doesn't queue another.
    private var prepareQueued = false
    /// Whether `prepare()` was asked for while shown, to run on the next hide.
    private var prepareOnHide = false
    /// The queued `prepare()`, for tests to wait on.
    private(set) var queuedPrepare: Task<Void, Never>?
    /// How many displays are connected.
    var screenCount: () -> Int = { NSScreen.screens.count }
    /// The modifier keys held now, which decide whether the gear shows as the panel appears.
    var modifierFlags: () -> NSEvent.ModifierFlags = { NSEvent.modifierFlags }
    /// How many panels have been made.
    var panelCount: Int { slots.count }
    /// The open of the config file ⌘, started last, for tests to wait on.
    private(set) var configFileOpened: Task<Void, Never>?
    /// `usage`'s frecencies as of the last show, so a keystroke only looks them up.
    private var boost = UsageBoost.none
    /// The items `usage` and `settings` dim, as of the last show, likewise.
    private var dimmed = DimmedItems.none
    private let calculator: CalculatorProvider
    private let opener: any ResultOpener
    private let recordOpen: @MainActor (_ id: String, _ query: String) -> Void
    private let now: @MainActor () -> Date
    private let configFile: @MainActor () async throws(ConfigError) -> URL
    private let openSettings: @MainActor () -> Void
    private let runCommand: @MainActor (String) -> Void
    private let quit: @MainActor () -> Void
    private let reportError: @MainActor (any Error) -> Void
    private let ordersPanel: Bool

    /// - Parameters:
    ///   - groups: The rows of each group, as `replaceIndex(_:groups:)` takes them.
    ///   - configFile: Gives the config file, creating the default one if it's missing, as
    ///     `ConfigStore.makeDefaultFileIfMissing` does.
    ///   - openSettings: Opens the settings window, on ⌘, or a click of the gear.
    ///   - runCommand: Runs a `.command` row's identifier.
    ///   - recordOpen: Told the id of each app or System Settings pane opened, and the query
    ///     it was opened from, to count it in `usage`.
    ///   - now: The time `usage` decays to when the panel shows.
    ///   - quit: Runs on ⌘Q.
    ///   - reportError: Told when the config file can't be made.
    ///   - ordersPanel: Whether showing puts the panel on screen. Tests pass false, so the panel
    ///     takes the keys in code but never shows or takes focus.
    public init(
        index: SearchIndex, groups: [String: [SearchItem]], settings: Search.Settings,
        calculator: CalculatorProvider,
        opener: any ResultOpener, icons: IconCache,
        configFile: @escaping @MainActor () async throws(ConfigError) -> URL,
        openSettings: @escaping @MainActor () -> Void,
        runCommand: @escaping @MainActor (String) -> Void,
        recordOpen: @escaping @MainActor (_ id: String, _ query: String) -> Void,
        now: @escaping @MainActor () -> Date,
        quit: @escaping @MainActor () -> Void,
        reportError: @escaping @MainActor (any Error) -> Void,
        ordersPanel: Bool = true
    ) {
        Self.requireRows(for: index, groups: groups)
        self.index = index
        self.groups = groups
        self.settings = settings
        self.calculator = calculator
        self.opener = opener
        self.icons = icons
        self.configFile = configFile
        self.openSettings = openSettings
        self.runCommand = runCommand
        self.recordOpen = recordOpen
        self.now = now
        self.quit = quit
        self.reportError = reportError
        self.ordersPanel = ordersPanel
        super.init()
        slots = [makeSlot()]
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil)
    }

    /// A panel holding rows that show `state`, its field and keys handled here.
    private func makeSlot() -> Slot {
        let panel = SearchPanel()
        let rows = ResultListHostingView(
            rootView: SearchView(state: state, icons: icons) { [weak self] in self?.open(row: $0) })
        rows.sizingOptions = []
        panel.install(rows: rows)
        panel.field.delegate = self
        panel.delegate = self
        panel.keyEquivalent = { [weak self] in self?.keyEquivalent($0) ?? false }
        panel.willTakeKeys = { [weak self] in self?.takeKeys(in: $0) }
        panel.openSettings = { [weak self] in self?.showSettings() }
        return Slot(panel: panel, rows: rows)
    }

    // MARK: Showing

    /// Shows the panel on the screen with the frontmost app's frontmost window, the last query
    /// selected in the field; with `showOnAllDisplays`, on every other screen as well.
    public func show() {
        guard let focused = FocusedScreen.current() else {
            preconditionFailure("there is no screen to show the panel on")
        }
        show(
            on: Self.displays(
                focused: Display(focused), all: NSScreen.screens.map(Display.init),
                onAll: settings.showOnAllDisplays))
    }

    /// The displays a show uses: `focused`, which takes the keys, then with `onAll` the others
    /// in `all`, in their order. Screens don't overlap, so a frame names one.
    nonisolated static func displays(focused: Display, all: [Display], onAll: Bool) -> [Display] {
        guard onAll else { return [focused] }
        return [focused] + all.filter { $0.frame != focused.frame }
    }

    /// Shows a panel on each of `displays`, the first taking the keys, each with as many rows
    /// as fit above its visible area's bottom.
    func show(on displays: [Display]) {
        guard !isShown else { return }
        precondition(!displays.isEmpty, "there is no display to show the panel on")
        isShown = true
        while slots.count < displays.count { slots.append(makeSlot()) }
        shownCount = displays.count
        keyIndex = 0
        // The show draws these panels, so `prepare()` has nothing left to draw for them.
        preparedCount = max(preparedCount, displays.count)
        for (index, display) in displays.enumerated() {
            slots[index].visible = display.visible
            slots[index].panel.setFrameTopLeftPoint(SearchPanel.topLeft(on: display.frame))
            let fit = rowsThatFit(slots[index])
            if slots[index].rows.rootView.limit != fit { slots[index].rows.rootView.limit = fit }
        }
        let optionHeld = modifierFlags().contains(.option)
        for shown in shownPanels { shown.showGear(optionHeld) }
        takeUsage()
        search(keepingSelection: true)
        // The field selects its whole text as it takes the keys, so typing replaces the query.
        panel.makeFirstResponder(panel.field)
        guard ordersPanel else { return }
        for other in shownPanels where other !== panel {
            other.orderFrontRegardless()
            other.invalidateShadow()
        }
        panel.makeKeyAndOrderFront(nil)
        panel.invalidateShadow()
    }

    /// Works out `usage`'s frecencies and the items it dims as of now, for the searches until
    /// the next show or change.
    private func takeUsage() {
        let now = now()
        boost = UsageBoost(usage, at: now)
        dimmed = DimmedItems(usage, settings: settings, at: now)
    }

    /// Moves the keys to `clicked`, a panel on another display, as a click in it does. The
    /// query and the selected row stay; the rows are cut to those that fit on its screen.
    func takeKeys(in clicked: SearchPanel) {
        guard isShown,
            let index = slots.prefix(shownCount).firstIndex(where: { $0.panel === clicked }),
            index != keyIndex
        else { return }
        keyIndex = index
        clicked.makeFirstResponder(clicked.field)
        // Taking the keys selects the whole query; a click in the margin should leave the caret
        // at the end instead. A click in the field itself then places it where clicked.
        if let editor = clicked.field.currentEditor() {
            editor.selectedRange = NSRange(location: editor.string.utf16.count, length: 0)
        }
        search(keepingSelection: true, announcing: false)
    }

    /// Orders the panel in fully transparent and out again in the same run-loop turn, so the
    /// window server's window and the first drawing of the backdrop and the field happen now
    /// rather than on the first show, which they slowed from about 6 ms to 37. The panel never
    /// becomes key or visible (docs/decisions/0012-warm-panel.md).
    /// With `showOnAllDisplays`, a panel for each screen is made and drawn this way, once.
    /// Drawing a panel can't happen while panels show, so a request then waits for the next
    /// hide.
    func prepare() {
        guard !isShown else {
            prepareOnHide = settings.showOnAllDisplays
            return
        }
        let count = settings.showOnAllDisplays ? max(screenCount(), 1) : 1
        while slots.count < count { slots.append(makeSlot()) }
        if ordersPanel {
            for slot in slots[min(preparedCount, count)..<count] {
                slot.panel.alphaValue = 0
                slot.panel.orderFrontRegardless()
                slot.panel.displayIfNeeded()
                slot.panel.orderOut(nil)
                slot.panel.alphaValue = 1
            }
        }
        preparedCount = max(preparedCount, count)
    }

    /// Runs `prepare()` in a later run-loop turn, so what asked for it finishes first.
    private func schedulePrepare() {
        guard !prepareQueued else { return }
        prepareQueued = true
        queuedPrepare = Task { [weak self] in
            self?.prepareQueued = false
            self?.prepare()
        }
    }

    /// Drops the panels past what the next show can use: all but the first without
    /// `showOnAllDisplays`, else those past the number of displays. Never while shown.
    private func releaseUnusedPanels() {
        guard !isShown else { return }
        let keep = settings.showOnAllDisplays ? max(screenCount(), 1) : 1
        guard slots.count > keep else { return }
        slots.removeSubrange(keep...)
        preparedCount = min(preparedCount, keep)
        keyIndex = 0
    }

    /// A display was connected, disconnected or rearranged. The panels showing are placed for
    /// the old arrangement and may overlap, so they hide; the next show places them again.
    @objc func screensChanged() {
        hide()
        releaseUnusedPanels()
        // A display that came with the setting on gets its panel drawn before the next hotkey.
        if settings.showOnAllDisplays { schedulePrepare() }
    }

    /// Hides every panel, keeping the query for the next show, which starts at the top level.
    public func hide() {
        guard isShown else { return }
        isShown = false
        path = []
        let shown = shownPanels
        shownCount = 0
        for panel in shown { panel.showGear(false) }
        if ordersPanel {
            for panel in shown { panel.orderOut(nil) }
        }
        releaseUnusedPanels()
        if prepareOnHide {
            prepareOnHide = false
            schedulePrepare()
        }
    }

    public func toggle() {
        if isShown { hide() } else { show() }
    }

    /// Hides the panel and opens the settings window.
    private func showSettings() {
        hide()
        openSettings()
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

    /// Searches `index` at the top level and `groups` inside a group from now on, and again now,
    /// keeping the query and the selected item. The groups open stay open while they are all
    /// still there; otherwise the panel goes to the top level, clearing the query. Every group
    /// row in `index` and in `groups` must have an entry in `groups`; one without is a
    /// programming error, so this stops.
    public func replaceIndex(_ index: SearchIndex, groups: [String: [SearchItem]]) {
        Self.requireRows(for: index, groups: groups)
        self.index = index
        self.groups = groups
        reopenPath()
        search(keepingSelection: true)
    }

    /// Opens the groups in `path` again from `index` and `groups`, or goes to the top level when
    /// one of them is gone. Each group's row is looked up where it was opened from, so a changed
    /// title shows.
    private func reopenPath() {
        guard !path.isEmpty else { return }
        var reopened: [OpenGroup] = []
        var rows = index.items
        for open in path {
            guard let row = rows.first(where: { $0.id == open.row.id }),
                let id = row.groupID, let children = groups[id]
            else {
                path = []
                panel.field.stringValue = ""
                return
            }
            reopened.append(OpenGroup(row: row, index: Self.groupIndex(children)))
            rows = children
        }
        path = reopened
    }

    /// Stops unless every group row in `index` and in `groups` has an entry in `groups`, so that
    /// opening a row never finds its group missing.
    private static func requireRows(for index: SearchIndex, groups: [String: [SearchItem]]) {
        let rows = index.items + groups.values.joined()
        for id in rows.compactMap(\.groupID) {
            precondition(groups[id] != nil, "no rows for the group \(id)")
        }
    }

    /// The index of a group's rows, which an empty query lists.
    private static func groupIndex(_ rows: [SearchItem]) -> SearchIndex {
        SearchIndex(items: rows, listsAllForEmptyQuery: true)
    }

    /// Searches the rows of the group `row` opens, with an empty query. `replaceIndex` has
    /// checked that the group has rows.
    private func openGroup(_ row: SearchItem, id: String) {
        let rows = groups[id]!
        path.append(OpenGroup(row: row, index: Self.groupIndex(rows)))
        panel.field.stringValue = ""
        search()
    }

    /// Goes up from the innermost group open to its parent, or the top level, with an empty
    /// query. Returns false, changing nothing, at the top level.
    @discardableResult
    private func leaveGroup() -> Bool {
        guard !path.isEmpty else { return false }
        path.removeLast()
        panel.field.stringValue = ""
        search()
        return true
    }

    /// Fills the rows for the query: the leading items, the calculator's row, then the index's
    /// best matches, `maxResults` in all; inside a group, only the group's best matches. The
    /// first row is selected, or with `keepingSelection` the row of the item selected before, if
    /// it is still there. Does nothing while the panel is hidden: showing searches, and a search
    /// no one sees would still be announced. Moving the keys searches again without
    /// `announcing`, as VoiceOver has said the results.
    private func search(keepingSelection: Bool = false, announcing: Bool = true) {
        guard isShown else { return }
        let query = query
        let kept = keepingSelection ? selectedRow?.item.id : nil
        var rows: [SearchState.Row] = []
        let searched: SearchIndex
        if let group = path.last {
            searched = group.index
        } else {
            searched = index
            rows = leadingItems.map { row($0, ranges: []) }
            if settings.calculator, let item = calculator.item(for: query) {
                rows.append(row(item, ranges: []))
            }
        }
        let limit = min(settings.maxResults, rowsThatFit(slots[keyIndex]))
        let room = max(limit - rows.count, 0)
        rows += searched.results(for: query, limit: room, usage: boost).map {
            row($0.item, ranges: $0.ranges)
        }
        rows = Array(rows.prefix(limit))
        state.rows = rows
        state.selection = kept.flatMap { id in rows.firstIndex { $0.item.id == id } } ?? 0
        if announcing {
            if let first = rows.first {
                let count = rows.count == 1 ? "1 result" : "\(rows.count) results"
                announce("\(count), \(ResultRow.accessibilityLabel(for: first.item))")
            } else {
                announce("No results")
            }
        }
        icons.request(
            rows.compactMap {
                guard case .file(let path) = ResultRow.icon(for: $0.item) else { return nil }
                return path
            })
        for slot in slots.prefix(shownCount) {
            // Programmatic changes don't reach the delegate, so this doesn't search again.
            if slot.panel !== panel, slot.panel.field.stringValue != query {
                slot.panel.field.stringValue = query
            }
            slot.panel.fit(rows: min(rows.count, rowsThatFit(slot)))
        }
    }

    private func row(_ item: SearchItem, ranges: [Range<String.Index>]) -> SearchState.Row {
        SearchState.Row(item: item, ranges: ranges, dimmed: dimmed.contains(item))
    }

    /// The rows with room between `slot`'s panel's top and the bottom of its screen's visible
    /// area.
    private func rowsThatFit(_ slot: Slot) -> Int {
        guard let visible = slot.visible else { return .max }
        return SearchPanel.rows(fitting: slot.panel.frame.maxY - visible.minY)
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
    /// calculator answer, runs a command or runs a script. A group's row opens the group instead,
    /// and the panel stays. An index past the rows does nothing. Only apps, panes and scripts
    /// count toward usage (docs/decisions/0010-usage-ranking.md).
    func open(row index: Int) {
        guard state.rows.indices.contains(index) else { return }
        let item = state.rows[index].item
        if let id = item.groupID {
            openGroup(item, id: id)
            return
        }
        hide()
        if item.kind.countsAsOpen { recordOpen(item.id, query) }
        switch item.target {
        case .openFile(let url) where item.kind == .app:
            opener.openApplication(at: url)
        case .openFile(let url), .openURL(let url):
            opener.open(url)
        case .copyText(let text):
            opener.copy(text)
        case .command(let id):
            runCommand(id)
        case .runScript(let url):
            opener.run(url)
        case .openGroup:
            return
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
        case reveal, openSettings, quit, close, copy, cut, paste, selectAll
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
        ("q", .q, .quit), ("w", .w, .close), (",", .comma, .openSettings),
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
        let modifiers = event.modifierFlags.intersection(.chordKeys)
        guard modifiers == .command,
            let chord = Self.chord(
                characters: event.charactersIgnoringModifiers, keyCode: event.keyCode)
        else { return false }
        switch chord {
        case .close:
            // The panel hides on Esc; ⌘W is for the settings window.
            return false
        case .reveal:
            revealSelected()
        case .openSettings:
            showSettings()
        case .quit:
            quit()
        case .copy:
            copySelectionOrRow()
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

    /// ⌘C: the selected text in the field when there is some; otherwise what the selected row
    /// copies, if anything. The panel stays.
    private func copySelectionOrRow() {
        if let selected = selectedText {
            opener.copy(selected.text)
            return
        }
        guard let item = selectedRow?.item, let text = Self.copiedText(for: item) else { return }
        opener.copy(text)
    }

    /// What ⌘C copies from `item`'s row: an app's path, a pane's `x-apple.systempreferences:` URL
    /// or a `.prefPane`'s path, a calculator answer as Return copies it. Nil for a command, a
    /// script, a group or a problem.
    private static func copiedText(for item: SearchItem) -> String? {
        switch (item.kind, item.target) {
        case (.command, _), (.problem, _), (_, .command), (_, .runScript), (_, .openGroup):
            return nil
        case (_, .openFile(let url)):
            return url.path(percentEncoded: false)
        case (_, .openURL(let url)):
            return url.absoluteString
        case (_, .copyText(let text)):
            return text
        }
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
        // Only edits in the field taking the keys are the user's; the other panels' fields are
        // set from this one.
        guard (notification.object as? NSTextField) === panel.field else { return }
        search()
    }

    /// Whether the selected row is a group's, which Tab and → open.
    private var selectsGroup: Bool { selectedRow?.item.groupID != nil }

    /// The keys the field's editor turns into commands: ↓, ↑ and Ctrl-N/P move, Return opens,
    /// Tab opens a group, Shift-Tab goes up from one, → and ← open and go up at the ends of the
    /// query, Backspace goes up on an empty query, and Esc clears, goes up or hides. Every other
    /// command, and → and ← elsewhere or during an input method's composition, edits the text
    /// as usual.
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
        case #selector(NSResponder.insertTab(_:)):
            // On a row that isn't a group's, Tab does nothing: the field is the panel's only
            // control, so moving the keys would only select its text again.
            if selectsGroup { open(row: state.selection) }
        case #selector(NSResponder.insertBacktab(_:)):
            leaveGroup()
        case #selector(NSResponder.moveRight(_:)):
            let caret = textView.selectedRange()
            guard !textView.hasMarkedText(), selectsGroup, caret.length == 0,
                caret.location == textView.string.utf16.count
            else { return false }
            open(row: state.selection)
        case #selector(NSResponder.moveLeft(_:)):
            guard !textView.hasMarkedText(),
                textView.selectedRange() == NSRange(location: 0, length: 0)
            else { return false }
            return leaveGroup()
        case #selector(NSResponder.deleteBackward(_:)):
            guard query.isEmpty else { return false }
            return leaveGroup()
        case #selector(NSResponder.cancelOperation(_:)):
            if !query.isEmpty {
                panel.field.stringValue = ""
                search()
            } else if !leaveGroup() {
                hide()
            }
        default:
            return false
        }
        return true
    }

    // MARK: Window

    /// A click elsewhere, or another app coming forward, takes the keys: every panel hides. A
    /// click in another display's panel has moved the keys to it first, and the panel that
    /// resigns them is no longer the one taking them, so nothing hides.
    public func windowDidResignKey(_ notification: Notification) {
        guard (notification.object as? SearchPanel) === panel else { return }
        hide()
    }
}

extension SearchPanelController.Display {
    init(_ screen: NSScreen) {
        self.init(frame: screen.frame, visible: screen.visibleFrame)
    }
}

extension SearchItem {
    /// The id of the group this row opens; nil for any other row.
    fileprivate var groupID: String? {
        guard case .openGroup(let id) = target else { return nil }
        return id
    }
}
