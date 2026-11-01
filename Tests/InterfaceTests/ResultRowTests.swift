import AppKit
import Search
import Testing

@testable import Interface

/// The characters of `title` drawn bold.
private func boldCharacters(_ title: AttributedString) -> String {
    title.runs.filter { $0.inlinePresentationIntent == .stronglyEmphasized }
        .map { String(title[$0.range].characters) }.joined()
}

@Test func theMatchedCharactersAreBold() throws {
    let title = "Visual Studio Code"
    let v = title.startIndex..<title.index(after: title.startIndex)
    let code = try #require(title.range(of: "Code"))

    let shown = ResultRow.title(title, bold: [v, code])

    #expect(String(shown.characters) == title)
    #expect(boldCharacters(shown) == "VCode")
}

@Test func aTitleWithNoRangesHasNothingBold() {
    let shown = ResultRow.title("Calculator", bold: [])

    #expect(String(shown.characters) == "Calculator")
    #expect(boldCharacters(shown).isEmpty)
}

@Test func anAppShowsItsOwnIconAndAPaneShowsSystemSettings() {
    let app = SearchItem(
        id: "com.apple.Safari", kind: .app, title: "Safari", subtitle: nil,
        target: .openFile(URL(filePath: "/Applications/Safari.app")))
    let pane = SearchItem(
        id: "com.apple.BluetoothSettings", kind: .settingsPane, title: "Bluetooth",
        subtitle: nil,
        target: .openURL(URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings")!))
    let prefPane = SearchItem(
        id: "/Library/PreferencePanes/Thing.prefPane", kind: .settingsPane, title: "Thing",
        subtitle: nil, target: .openFile(URL(filePath: "/Library/PreferencePanes/Thing.prefPane")))

    let systemSettings = SettingsPaneProvider.systemSettingsApp.path
    #expect(systemSettings.hasPrefix("/System/Applications/System Settings.app"))
    #expect(ResultRow.icon(for: app) == .file("/Applications/Safari.app"))
    #expect(ResultRow.icon(for: pane) == .file(systemSettings))
    #expect(ResultRow.icon(for: prefPane) == .file(systemSettings))
}

@Test func theCalculatorRowShowsTheCalculatorAppsIcon() throws {
    let calculation = try #require(
        CalculatorProvider(locale: Locale(identifier: "en_US")).item(for: "1+1"))

    let calculator = CalculatorProvider.calculatorApp.path
    #expect(calculator.hasPrefix("/System/Applications/Calculator.app"))
    #expect(ResultRow.icon(for: calculation) == .file(calculator))
}

@Test func aCommandRowShowsASymbol() {
    let command = SearchItem(
        id: "quit", kind: .command, title: "Quit", subtitle: nil, target: .command("quit"))

    guard case .symbol = ResultRow.icon(for: command) else {
        Issue.record("a command row has no symbol")
        return
    }
}

/// `fill` as drawn in the appearance `name`, in gray.
@MainActor private func resolved(_ fill: NSColor, in name: NSAppearance.Name) throws -> NSColor {
    let appearance = try #require(NSAppearance(named: name))
    var color: NSColor?
    appearance.performAsCurrentDrawingAppearance {
        color = fill.usingColorSpace(.genericGray)
    }
    return try #require(color)
}

/// Every row is selected the same way: a fill a little darker than the panel in light mode and
/// a little lighter in dark mode, as Spotlight's is, not the accent color.
@MainActor @Test func theSelectionIsANeutralFill() throws {
    let light = try resolved(ResultRow.selectionFill, in: .aqua)
    let dark = try resolved(ResultRow.selectionFill, in: .darkAqua)

    #expect(light.whiteComponent == 0)
    #expect((0.08...0.12).contains(light.alphaComponent))
    #expect(dark.whiteComponent == 1)
    #expect((0.08...0.12).contains(dark.alphaComponent))
}

/// Increase Contrast makes the fill stronger, so the selection stays easy to see. Its
/// appearances can only be matched, not made, so the fill is checked for each case directly.
@Test func theSelectionIsStrongerWithIncreasedContrast() {
    for dark in [false, true] {
        let usual = ResultRow.selectionFill(dark: dark, highContrast: false)
        let high = ResultRow.selectionFill(dark: dark, highContrast: true)

        #expect(high.whiteComponent == usual.whiteComponent)
        #expect(high.alphaComponent > usual.alphaComponent)
    }
}

/// The selected row is the one Return opens, so it reads at full strength whatever its usage.
@Test func aDimmedRowIsSubduedUnlessSelected() {
    for highContrast in [false, true] {
        let dim = ResultRow.contentOpacity(
            dimmed: true, selected: false, highContrast: highContrast)
        #expect(dim >= 0.5 && dim < 1)
        #expect(
            ResultRow.contentOpacity(dimmed: true, selected: true, highContrast: highContrast)
                == 1)
        #expect(
            ResultRow.contentOpacity(dimmed: false, selected: false, highContrast: highContrast)
                == 1)
    }
    #expect(
        ResultRow.contentOpacity(dimmed: true, selected: false, highContrast: true)
            > ResultRow.contentOpacity(dimmed: true, selected: false, highContrast: false))
}

@Test func aRowReadsItsTitleThenItsSubtitle() {
    let app = SearchItem(
        id: "com.apple.Safari", kind: .app, title: "Safari", subtitle: "/Applications/Safari.app",
        target: .openFile(URL(filePath: "/Applications/Safari.app")))
    let bare = SearchItem(
        id: "quit", kind: .command, title: "Quit", subtitle: nil, target: .command("quit"))

    #expect(ResultRow.accessibilityLabel(for: app) == "Safari, /Applications/Safari.app")
    #expect(ResultRow.accessibilityLabel(for: bare) == "Quit")
}

/// The title is the answer and the subtitle the expression, which reads backwards as "14, 2*(3+4)".
@Test func aCalculationReadsItsExpressionEqualsItsAnswer() throws {
    let calculation = try #require(
        CalculatorProvider(locale: Locale(identifier: "en_US")).item(for: "2*(3+4)"))

    #expect(ResultRow.accessibilityLabel(for: calculation) == "2*(3+4) equals 14")
}

/// The icon is the row's anchor: most of its height, as in Finder's list.
@Test func theIconFillsMostOfTheRow() {
    #expect(ResultRow.iconSize >= ResultRow.height * 0.8)
    #expect(ResultRow.iconSize < ResultRow.height)
}
