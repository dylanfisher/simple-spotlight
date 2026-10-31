import Foundation
import Testing

@testable import Search

private let commands = CommandProvider(appName: "Simple Spotlight")

@Test func offersTheConfigAndQuitRowsAsCommands() {
    #expect(commands.items.map(\.title) == ["Simple Spotlight Config", "Quit Simple Spotlight"])
    #expect(commands.items.allSatisfy { $0.kind == .command })
    #expect(
        commands.items.map(\.target)
            == CommandProvider.Command.allCases.map {
                .command($0.id)
            })
    #expect(Set(commands.items.map(\.id)).count == commands.items.count)
}

@Test func ranksItsRowsForQuitAndConfig() {
    let safari = SearchItem(
        id: "com.apple.Safari", kind: .app, title: "Safari", subtitle: nil,
        target: .openFile(URL(filePath: "/Applications/Safari.app")))
    let index = SearchIndex(items: [safari] + commands.items)

    #expect(index.results(for: "quit", limit: 8).map(\.item.title) == ["Quit Simple Spotlight"])
    #expect(
        index.results(for: "config", limit: 8).map(\.item.title) == ["Simple Spotlight Config"])
}

@Test func readsTheCommandOfAnIdentifier() {
    for command in CommandProvider.Command.allCases {
        #expect(CommandProvider.Command(id: command.id) == command)
    }
    #expect(CommandProvider.Command(id: "simple-spotlight.unknown") == nil)
    #expect(CommandProvider.Command(id: "quit") == nil)
}
