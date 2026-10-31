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
