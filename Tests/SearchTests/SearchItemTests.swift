import Foundation
import Testing

@testable import Base
@testable import Search

@Test func foldsTheTitleAtCreation() {
    let item = SearchItem(
        id: "com.example.resume", kind: .app, title: "Résumé", subtitle: nil,
        target: .openFile(URL(filePath: "/Applications/Résumé.app")))
    #expect(item.foldedTitle.text == "Résumé")
    #expect(item.foldedTitle.bytes == Array("resume".utf8))
}

@Test func foldsAlternateNamesAtCreation() {
    let item = SearchItem(
        id: "com.example.calculator", kind: .app, title: "Rechner", subtitle: nil,
        target: .openFile(URL(filePath: "/System/Applications/Calculator.app")),
        alternateNames: ["Calculator"])
    #expect(item.foldedAlternates.map(\.bytes) == [Array("calculator".utf8)])
}

/// The user opens apps, panes and scripts; answers, commands, groups and problems aren't counted
/// (docs/decisions/0010-usage-ranking.md).
@Test func countsOpensOfAppsPanesAndScripts() {
    let counted: [SearchItem.Kind] = [.app, .settingsPane, .script]
    let notCounted: [SearchItem.Kind] = [.calculation, .command, .group, .problem]
    #expect(counted.map(\.countsAsOpen) == [true, true, true])
    #expect(notCounted.map(\.countsAsOpen) == [false, false, false, false])
}
