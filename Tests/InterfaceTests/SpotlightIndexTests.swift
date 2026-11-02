import Testing

@testable import Interface

@Test func mdutilsStatusSaysWhetherTheVolumeIsIndexed() throws {
    #expect(try SpotlightIndex.isIndexing(status: "/:\n\tIndexing enabled. \n"))
    #expect(try !SpotlightIndex.isIndexing(status: "/:\n\tIndexing disabled.\n"))
    #expect(try !SpotlightIndex.isIndexing(status: "/:\n\tIndexing and searching disabled.\n"))
}

@Test func anUnknownStatusIsAnError() {
    #expect(throws: SpotlightIndexError.failed("mdutil gave an unknown status: /:\n\tError: -400"))
    {
        try SpotlightIndex.isIndexing(status: "/:\n\tError: -400\n")
    }
}

@Test func theSwitchRunsMdutilOnEveryVolumeAsAnAdministrator() {
    #expect(
        SpotlightIndex.script(false)
            == "do shell script \"/usr/bin/mdutil -a -i off\" with administrator privileges")
    #expect(SpotlightIndex.script(true).contains("-a -i on\""))
}

@MainActor @Test func refreshReadsTheIndex() async {
    let model = SpotlightIndexModel(service: StubSpotlightIndex(indexing: false))
    #expect(model.isIndexing == nil)

    model.refresh()
    #expect(model.isBusy)
    await model.work?.value

    #expect(model.isIndexing == false)
    #expect(!model.isBusy)
    #expect(model.problem == nil)
}

@MainActor @Test func toggleSwitchesTheIndexAndReadsItBack() async {
    let index = StubSpotlightIndex(indexing: true)
    let model = SpotlightIndexModel(service: index)
    model.refresh()
    await model.work?.value

    model.toggle()
    await model.work?.value

    #expect(await index.switches == [false])
    #expect(model.isIndexing == false)

    model.toggle()
    await model.work?.value

    #expect(await index.switches == [false, true])
    #expect(model.isIndexing == true)
}

/// Until the status is read, there is no state to switch to.
@MainActor @Test func toggleDoesNothingBeforeTheStatusIsRead() async {
    let index = StubSpotlightIndex()
    let model = SpotlightIndexModel(service: index)

    model.toggle()

    #expect(model.work == nil)
    #expect(await index.switches.isEmpty)
}

@MainActor @Test func cancellingThePasswordPromptChangesNothing() async {
    let index = StubSpotlightIndex(indexing: true)
    let model = SpotlightIndexModel(service: index)
    model.refresh()
    await model.work?.value
    await index.fail(set: .cancelled)

    model.toggle()
    await model.work?.value

    #expect(model.isIndexing == true)
    #expect(model.problem == nil)
    #expect(!model.isBusy)
}

/// A switch that fails leaves the status read back, so the button can try again.
@MainActor @Test func aFailedSwitchSaysWhyAndKeepsTheStatusReadBack() async {
    let index = StubSpotlightIndex(indexing: true)
    let model = SpotlightIndexModel(service: index)
    model.refresh()
    await model.work?.value
    await index.fail(set: .failed("mdutil: not permitted"))

    model.toggle()
    await model.work?.value

    #expect(model.problem == "mdutil: not permitted")
    #expect(model.isIndexing == true)
    #expect(!model.isBusy)
}

@MainActor @Test func aFailedReadSaysWhyAndForgetsTheStatus() async {
    let index = StubSpotlightIndex(indexing: true)
    let model = SpotlightIndexModel(service: index)
    model.refresh()
    await model.work?.value
    await index.fail(read: .failed("mdutil: no such volume"))

    model.refresh()
    await model.work?.value

    #expect(model.problem == "mdutil: no such volume")
    #expect(model.isIndexing == nil)

    await index.fail()
    model.refresh()
    await model.work?.value

    #expect(model.problem == nil)
    #expect(model.isIndexing == true)
}
