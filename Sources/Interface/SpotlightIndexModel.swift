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
        start { service throws(SpotlightIndexError) in try await service.isIndexing() }
    }

    /// Turns indexing to the other state, then reads it back, which shows what macOS did
    /// whether or not the switch went through. Off until the status has been read.
    public func toggle() {
        guard !isBusy, let isIndexing else { return }
        start { service throws(SpotlightIndexError) in
            try await service.setIndexing(!isIndexing)
            return try await service.isIndexing()
        }
    }

    private func start(
        _ step:
            @escaping @Sendable (any SpotlightIndexService) async throws(SpotlightIndexError)
            -> Bool
    ) {
        isBusy = true
        work = Task { [service] in
            do throws(SpotlightIndexError) {
                isIndexing = try await step(service)
                problem = nil
            } catch {
                switch error {
                case .cancelled:
                    problem = nil
                case .failed(let reason):
                    problem = reason
                    // The switch may have gone through before the read back failed, so what
                    // was shown is no longer known.
                    isIndexing = nil
                }
            }
            isBusy = false
        }
    }
}
