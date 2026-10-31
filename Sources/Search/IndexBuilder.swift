/// Builds the items of the search index from the app and System Settings providers.
public struct IndexBuilder: Sendable {
    /// What one build found, apps first, what it had to leave out, and how long it took.
    public struct Build: Sendable {
        public let items: [SearchItem]
        /// Both providers' problems, apps' first. A problem leaves out one folder or bundle; the
        /// rest of the index is still built.
        public let problems: [IndexProblem]
        public let duration: Duration
    }

    public let apps: AppProvider
    public let settingsPanes: SettingsPaneProvider

    public init(apps: AppProvider, settingsPanes: SettingsPaneProvider) {
        self.apps = apps
        self.settingsPanes = settingsPanes
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
            items: found.items + panes.items, problems: found.problems + panes.problems,
            duration: clock.now - start)
    }
}
