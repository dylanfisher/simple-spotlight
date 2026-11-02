@testable import Interface

/// Stands in for macOS's Spotlight index, so tests never read or switch the real one.
actor StubSpotlightIndex: SpotlightIndexService {
    private(set) var indexing: Bool
    /// What a read throws, if anything.
    private var readError: SpotlightIndexError?
    /// What a switch throws, if anything; it then leaves `indexing` as it was.
    private var setError: SpotlightIndexError?
    /// Each switch asked for, in order.
    private(set) var switches: [Bool] = []

    init(indexing: Bool = true) {
        self.indexing = indexing
    }

    func fail(read: SpotlightIndexError? = nil, set: SpotlightIndexError? = nil) {
        readError = read
        setError = set
    }

    func isIndexing() throws(SpotlightIndexError) -> Bool {
        if let readError { throw readError }
        return indexing
    }

    func setIndexing(_ on: Bool) throws(SpotlightIndexError) {
        switches.append(on)
        if let setError { throw setError }
        indexing = on
    }
}
