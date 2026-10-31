import Foundation
import Search
import Testing

@testable import Interface

/// Holds the writes the model asks for until the test lets each through.
private actor StubFile {
    private(set) var settings = Search.Settings()
    private(set) var writes = 0
    var refusal: ConfigError?
    /// Each write waiting for `finish`.
    private var waiting: [CheckedContinuation<Void, Never>] = []
    var holds = false

    func update(_ change: SettingsModel.Change) async throws(ConfigError) {
        if holds { await withCheckedContinuation { waiting.append($0) } }
        if let refusal { throw refusal }
        writes += 1
        change(&settings)
    }

    func hold() { holds = true }
    func refuse(_ error: ConfigError) { refusal = error }

    /// Lets the waiting writes through.
    func finish() {
        holds = false
        for continuation in waiting { continuation.resume() }
        waiting = []
    }

    var waitingCount: Int { waiting.count }
}

private let configURL = URL(filePath: "/tmp/simple-spotlight-test/config.json")

@MainActor
private func model(_ file: StubFile, recording: @escaping @MainActor (Bool) -> Void = { _ in })
    -> SettingsModel
{
    SettingsModel(
        configFile: configURL,
        update: { change throws(ConfigError) in try await file.update(change) },
        openConfigFile: {}, openKeyboardShortcuts: {}, recordingChanged: recording)
}

private func state(_ settings: Search.Settings, broken: Bool = false) -> ConfigStore.State {
    ConfigStore.State(
        settings: settings, errors: broken ? [ConfigError(line: 2, reason: "bad")] : [],
        isFileBroken: broken)
}

/// Waits until `file` has `count` writes held, polling the actor with yields, not a clock.
private func waitForHeldWrites(_ file: StubFile, count: Int) async {
    while await file.waitingCount < count { await Task.yield() }
}

@MainActor @Test func aChangeShowsAtOnceAndIsWritten() async {
    let file = StubFile()
    let model = model(file)
    model.receive(state(Search.Settings()))

    model.change { $0.maxResults = 12 }

    #expect(model.settings.maxResults == 12)
    await model.lastWrite?.value
    #expect(await file.settings.maxResults == 12)
}

@MainActor @Test func aChangeStaysShownUntilTheFileIsReadBack() async {
    let file = StubFile()
    await file.hold()
    let model = model(file)
    model.receive(state(Search.Settings()))

    model.change { $0.calculator = false }
    model.change { $0.maxResults = 3 }
    // A read of the file made before either change was written.
    model.receive(state(Search.Settings()))

    #expect(!model.settings.calculator)
    #expect(model.settings.maxResults == 3)
    await waitForHeldWrites(file, count: 1)
    await file.finish()
    await model.lastWrite?.value
    // The store's read of the written file.
    var written = Search.Settings()
    written.calculator = false
    written.maxResults = 3
    model.receive(state(written))
    #expect(model.settings == written)
}

@MainActor @Test func anEditOfTheFileShows() {
    let model = model(StubFile())
    var edited = Search.Settings()
    edited.dimAfterDays = 7

    model.receive(state(edited))

    #expect(model.settings == edited)
}

@MainActor @Test func aBrokenFileTurnsChangesOff() async {
    let file = StubFile()
    let model = model(file)

    model.receive(state(Search.Settings(), broken: true))
    model.change { $0.maxResults = 3 }

    #expect(model.isFileBroken)
    #expect(model.errors.map(\.description) == ["line 2: bad"])
    #expect(model.settings.maxResults == Search.Settings().maxResults)
    await model.lastWrite?.value
    #expect(await file.writes == 0)
}

/// The file turned broken while the shortcut was being recorded.
@MainActor @Test func aChordRecordedIntoABrokenFileIsReportedNotDropped() async {
    let file = StubFile()
    let model = model(file)
    model.receive(state(Search.Settings(), broken: true))

    model.recorder.recorded(KeyChord(.control, .k))

    #expect(model.writeError?.reason.hasPrefix("The change wasn't saved") == true)
    #expect(model.shownErrors.map(\.description).count == 2)
    await model.lastWrite?.value
    #expect(await file.writes == 0)

    model.receive(state(Search.Settings()))
    #expect(model.writeError == nil)
}

@MainActor @Test func aWriteThatFailsIsShownAndUndone() async {
    let file = StubFile()
    await file.refuse(ConfigError(reason: "has an error"))
    let model = model(file)
    model.receive(state(Search.Settings()))

    model.change { $0.maxResults = 3 }
    await model.lastWrite?.value

    #expect(model.writeError == ConfigError(reason: "has an error"))
    #expect(model.settings.maxResults == Search.Settings().maxResults)
}

@MainActor @Test func aRecordedChordIsWritten() async throws {
    let file = StubFile()
    var recording: [Bool] = []
    let model = model(file) { recording.append($0) }
    model.receive(state(Search.Settings()))

    model.recorder.start()
    #expect(
        model.recorder.handle(
            try keyEvent("k", modifiers: [.control, .option], keyCode: KeyChord.Key.k.code)))

    #expect(recording == [true, false])
    #expect(model.settings.hotkey == KeyChord([.control, .option], .k))
    await model.lastWrite?.value
    #expect(await file.settings.hotkey == KeyChord([.control, .option], .k))
}
