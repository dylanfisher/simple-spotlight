import Foundation
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

    let systemSettings = SettingsPaneProvider.systemSettingsApp.path(percentEncoded: false)
    #expect(systemSettings.hasPrefix("/System/Applications/System Settings.app"))
    #expect(ResultRow.icon(for: app) == .file("/Applications/Safari.app"))
    #expect(ResultRow.icon(for: pane) == .file(systemSettings))
    #expect(ResultRow.icon(for: prefPane) == .file(systemSettings))
}

@Test func calculatorAndCommandRowsShowASymbol() throws {
    let calculation = try #require(
        CalculatorProvider(locale: Locale(identifier: "en_US")).item(for: "1+1"))
    let command = SearchItem(
        id: "quit", kind: .command, title: "Quit", subtitle: nil, target: .command("quit"))

    guard case .symbol = ResultRow.icon(for: calculation) else {
        Issue.record("the calculator row has no symbol")
        return
    }
    guard case .symbol = ResultRow.icon(for: command) else {
        Issue.record("a command row has no symbol")
        return
    }
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
