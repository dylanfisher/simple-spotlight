/// Builds the items of the search index from the app and System Settings providers.
public struct IndexBuilder: Sendable {
    /// What one build found, apps first, what it had to leave out, and how long it took.
    public struct Build: Sendable {
        public let items: [SearchItem]
        /// Both providers' problems, apps' first. A problem leaves out one folder or bundle; the
        /// rest of the index is still built.
        public let problems: [IndexProblem]
        public let duration: Duration

        public init(items: [SearchItem], problems: [IndexProblem], duration: Duration) {
            self.items = items
            self.problems = problems
            self.duration = duration
        }
    }

    public let apps: AppProvider
    public let settingsPanes: SettingsPaneProvider
    /// Ids of items left out of the build: apps' and panes' bundle IDs.
    public let excludedIDs: Set<String>

    public init(
        apps: AppProvider, settingsPanes: SettingsPaneProvider, excludedIDs: Set<String> = []
    ) {
        self.apps = apps
        self.settingsPanes = settingsPanes
        self.excludedIDs = excludedIDs
    }

    /// Runs both providers at once, off the caller's actor, since they read the disk. Throws
    /// only `CancellationError`, so a stale rebuild can be cancelled.
    @concurrent public func build() async throws -> Build {
        let clock = ContinuousClock()
        let start = clock.now
        async let appScan = apps.items()
        async let paneScan = settingsPanes.items()
        let (found, panes) = try await (appScan, paneScan)
        return Build(
            items: (found.items + panes.items).filter { !excludedIDs.contains($0.id) },
            problems: found.problems + panes.problems,
            duration: clock.now - start)
    }
}
