/// Builds the items of the search index from the app and System Settings providers.
public struct IndexBuilder: Sendable {
    /// The items one build found, apps first, and how long it took.
    public struct Build: Sendable {
        public let items: [SearchItem]
        public let duration: Duration
    }

    public let apps: AppProvider
    public let settingsPanes: SettingsPaneProvider

    public init(apps: AppProvider, settingsPanes: SettingsPaneProvider) {
        self.apps = apps
        self.settingsPanes = settingsPanes
    }

    /// Runs both providers at once, off the caller's actor, since they read the disk. Throws the
    /// first provider error; a partial index would hide a folder's apps without saying why.
    @concurrent public func build() async throws -> Build {
        let clock = ContinuousClock()
        let start = clock.now
        async let appItems = apps.items()
        async let paneItems = settingsPanes.items()
        let items = try await appItems + paneItems
        return Build(items: items, duration: clock.now - start)
    }
}
