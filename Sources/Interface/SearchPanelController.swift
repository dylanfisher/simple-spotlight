import AppKit
import Search
import SwiftUI

/// Shows and hides the search panel, searches the current index and the calculator on each
/// keystroke, and handles the panel's keys: the arrows and Ctrl-N/P move the selection, Return
/// opens, ⌘Return reveals, ⌘1…⌘9 open a row, ⌘C copies a calculator answer, Esc clears then
/// hides, ⌘, opens the config file and ⌘Q quits (docs/decisions/0008-search-panel-window.md).
///
/// A keystroke searches on the main actor: the index answers in well under a millisecond, so a
/// hop off it would cost more than the search.
@MainActor
public final class SearchPanelController: NSObject, NSTextFieldDelegate, NSWindowDelegate {
    /// The items searched. Setting it searches again, keeping the query and the selected item.
    public var index: SearchIndex {
        didSet { search(keepingSelection: true) }
    }
    /// Read for `maxResults` and `calculator`. Setting it searches again, as `index` does.
    public var settings: Search.Settings {
        didSet { search(keepingSelection: true) }
    }
    /// Rows shown above the results whatever the query, such as a config error. They count
    /// toward `maxResults`.
    public var leadingItems: [SearchItem] = [] {
        didSet { search(keepingSelection: true) }
    }
    public private(set) var isShown = false
    /// The text in the field, kept while the panel is hidden.
    public var query: String { panel.field.stringValue }

    let panel = SearchPanel()
    let state = SearchState()
    let icons: IconCache
    /// The open of the config file ⌘, started last, for tests to wait on.
    private(set) var configFileOpened: Task<Void, Never>?
    private let calculator: CalculatorProvider
    private let opener: any ResultOpener
    private let configFile: @MainActor () async throws(ConfigError) -> URL
    private let runCommand: @MainActor (String) -> Void
    private let quit: @MainActor () -> Void
    private let reportError: @MainActor (any Error) -> Void
    private let ordersPanel: Bool

    /// - Parameters:
    ///   - configFile: Gives the config file, creating the default one if it's missing, as
    ///     `ConfigStore.makeDefaultFileIfMissing` does.
    ///   - runCommand: Runs a `.command` row's identifier.
    ///   - quit: Runs on ⌘Q.
    ///   - reportError: Told when the config file can't be made.
    ///   - ordersPanel: Whether showing puts the panel on screen. Tests pass false, so the panel
    ///     takes the keys in code but never shows or takes focus.
    public init(
        index: SearchIndex, settings: Search.Settings, calculator: CalculatorProvider,
        opener: any ResultOpener, icons: IconCache,
        configFile: @escaping @MainActor () async throws(ConfigError) -> URL,
        runCommand: @escaping @MainActor (String) -> Void,
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
        self.quit = quit
        self.reportError = reportError
        self.ordersPanel = ordersPanel
        super.init()
        let rows = NSHostingView(
            rootView: SearchView(state: state, icons: icons) { [weak self] in self?.open(row: $0) })
        rows.sizingOptions = []
        panel.install(rows: rows)
        panel.field.delegate = self
        panel.delegate = self
        panel.keyEquivalent = { [weak self] in self?.keyEquivalent($0) ?? false }
    }

    // MARK: Showing

    /// Shows the panel on the screen with the mouse, the last query selected in the field.
    public func show() {
        guard !isShown else { return }
        isShown = true
        // The mouse can sit on the edge between two screens, where no frame contains it.
        let mouse = NSEvent.mouseLocation
        guard
            let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
                ?? NSScreen.main
        else { preconditionFailure("there is no screen to show the panel on") }
        panel.setFrameTopLeftPoint(SearchPanel.topLeft(on: screen.frame))
        // The field selects its whole text as it takes the keys, so typing replaces the query.
        panel.makeFirstResponder(panel.field)
        guard ordersPanel else { return }
        panel.makeKeyAndOrderFront(nil)
        panel.invalidateShadow()
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
    /// the row of the item selected before, if it is still there.
    private func search(keepingSelection: Bool = false) {
        let query = query
        let kept = keepingSelection ? selectedRow?.item.id : nil
        var rows = leadingItems.map { SearchState.Row(item: $0, ranges: []) }
        if settings.calculator, let item = calculator.item(for: query) {
            rows.append(SearchState.Row(item: item, ranges: []))
        }
        let room = max(settings.maxResults - rows.count, 0)
        rows += index.results(for: query, limit: room).map {
            SearchState.Row(item: $0.item, ranges: $0.ranges)
        }
        rows = Array(rows.prefix(settings.maxResults))
        state.rows = rows
        state.selection = kept.flatMap { id in rows.firstIndex { $0.item.id == id } } ?? 0
        icons.request(
            rows.compactMap {
                guard case .file(let path) = ResultRow.icon(for: $0.item) else { return nil }
                return path
            })
        panel.fit(rows: rows.count)
    }

    private var selectedRow: SearchState.Row? {
        state.rows.indices.contains(state.selection) ? state.rows[state.selection] : nil
    }

    private func moveSelection(by offset: Int) {
        guard !state.rows.isEmpty else { return }
        state.selection = min(max(state.selection + offset, 0), state.rows.count - 1)
    }

    // MARK: Opening

    /// Hides the panel and opens the row at `index`: launches an app, opens a pane, copies a
    /// calculator answer or runs a command. An index past the rows does nothing.
    func open(row index: Int) {
        guard state.rows.indices.contains(index) else { return }
        let item = state.rows[index].item
        hide()
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

    /// The Command chords. The app has no menu bar, so the editing chords the field needs are
    /// passed to its editor here; Command with any other modifier, or a key not listed, is
    /// left to the panel.
    private func keyEquivalent(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard modifiers == .command, let key = event.charactersIgnoringModifiers?.lowercased()
        else { return false }
        switch key {
        case "\r":
            revealSelected()
        case ",":
            openConfigFile()
        case "q":
            quit()
        case "c":
            copySelectionOrAnswer()
        case "x":
            editor?.cut(nil)
        case "v":
            editor?.paste(nil)
        case "a":
            editor?.selectAll(nil)
        case _ where key.count == 1 && ("1"..."9").contains(key):
            guard let number = Int(key) else { preconditionFailure("\(key) isn't a digit") }
            open(row: number - 1)
        default:
            return false
        }
        return true
    }

    /// ⌘C: the selected text in the field when there is some; otherwise the answer of a selected
    /// calculator row. With neither, nothing.
    private func copySelectionOrAnswer() {
        guard let editor else { return }
        if editor.selectedRange().length > 0 {
            editor.copy(nil)
            return
        }
        guard let item = selectedRow?.item, item.kind == .calculation,
            case .copyText(let text) = item.target
        else { return }
        opener.copy(text)
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
