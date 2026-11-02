import Foundation
import Observation

/// What the Spotlight pane shows and does: whether macOS indexes the startup volume, read each
/// time the pane shows, and a button that turns indexing off or back on everywhere
/// (docs/decisions/0019-spotlight-indexing.md).
@MainActor @Observable
public final class SpotlightIndexModel {
    /// Whether the startup volume is indexed, as last read; nil before the first read and when
    /// it couldn't be read.
    public private(set) var isIndexing: Bool?
    /// Whether a read or a switch is running, which turns the button off.
    public private(set) var isBusy = false
    /// Why the last read or switch failed; nil once one works or the user cancels.
    public private(set) var problem: String?
    /// The read or switch running, for tests to wait on.
    @ObservationIgnored private(set) var work: Task<Void, Never>?

    @ObservationIgnored private let service: any SpotlightIndexService

    public init(service: any SpotlightIndexService) {
        self.service = service
    }

    /// Reads the status again, unless a read or switch is running.
    public func refresh() {
        guard !isBusy else { return }
        start { service in await Self.read(service, after: nil) }
    }

    /// Turns indexing to the other state, then reads it back, which shows what macOS did
    /// whether or not the switch went through. Off until the status has been read.
    public func toggle() {
        guard !isBusy, let isIndexing else { return }
        start { service in
            do throws(SpotlightIndexError) {
                try await service.setIndexing(!isIndexing)
                return await Self.read(service, after: nil)
            } catch {
                return await Self.read(service, after: error)
            }
        }
    }

    /// What a read or switch found: the status, nil when it couldn't be read, and what failed.
    private typealias Outcome = (isIndexing: Bool?, error: SpotlightIndexError?)

    /// Reads the status, keeping `failure`, the switch's error, unless the read fails too.
    private static func read(
        _ service: any SpotlightIndexService, after failure: SpotlightIndexError?
    )
        async -> Outcome
    {
        do throws(SpotlightIndexError) {
            return (try await service.isIndexing(), failure)
        } catch {
            return (nil, error)
        }
    }

    private func start(_ step: @escaping @Sendable (any SpotlightIndexService) async -> Outcome) {
        isBusy = true
        work = Task { [service] in
            let outcome = await step(service)
            isIndexing = outcome.isIndexing
            switch outcome.error {
            case nil, .cancelled?: problem = nil
            case .failed(let reason)?: problem = reason
            }
            isBusy = false
        }
    }
}
