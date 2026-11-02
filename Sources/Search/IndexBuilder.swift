import Foundation

/// Builds the items of the search index from the app, System Settings and script command
/// providers.
public struct IndexBuilder: Sendable {
    /// What one build found, apps first, then panes, then scripts, what it had to leave out, and
    /// how long it took.
    public struct Build: Sendable {
        public let items: [SearchItem]
        /// The rows of each group of script commands, keyed by the group's id, as
        /// `ScriptCommandProvider.Tree.groups`. `items` holds the top level's group rows; a
        /// group's own index is built from its list here, and a group that is gone after a
        /// rebuild has none.
        public let groups: [String: [SearchItem]]
        /// The providers' problems, in the order of their items. A problem leaves out one
        /// folder, bundle or script; the rest of the index is still built.
        public let problems: [IndexProblem]
        public let duration: Duration

        public init(
            items: [SearchItem], groups: [String: [SearchItem]] = [:], problems: [IndexProblem],
            duration: Duration
        ) {
            self.items = items
            self.groups = groups
            self.problems = problems
            self.duration = duration
        }
    }

    public let apps: AppProvider
    public let settingsPanes: SettingsPaneProvider
    /// Nil when script commands are off.
    public let scripts: ScriptCommandProvider?
    /// Ids of items left out of the build: apps' and panes' bundle IDs.
    public let excludedIDs: Set<String>

    public init(
        apps: AppProvider, settingsPanes: SettingsPaneProvider,
        scripts: ScriptCommandProvider? = nil, excludedIDs: Set<String> = []
    ) {
        self.apps = apps
        self.settingsPanes = settingsPanes
        self.scripts = scripts
        self.excludedIDs = excludedIDs
    }

    /// The folders whose changes can change the build: the app folders, the `.prefPane`
    /// folders and the commands folder. System Settings' own panes are on the read-only system
    /// volume, which changes only with a macOS update.
    public var watchedFolders: [URL] {
        apps.folders + settingsPanes.preferencePaneFolders + (scripts.map { [$0.folder] } ?? [])
    }

    /// Runs the providers at once, off the caller's actor, since they read the disk. Throws
    /// when cancelled, so a stale rebuild can be.
    @concurrent public func build() async throws(CancellationError) -> Build {
        let clock = ContinuousClock()
        let start = clock.now
        // `async let` loses a typed error, so each scan's comes back in a `Result`.
        async let appScan = Result { () throws(CancellationError) in try apps.items() }
        async let paneScan = Result { () throws(CancellationError) in try settingsPanes.items() }
        async let scriptScan = Result { () throws(CancellationError) in
            try scripts?.items() ?? ScriptCommandProvider.Tree(items: [], groups: [:], problems: [])
        }
        let (found, panes, scripted) = try await (appScan.get(), paneScan.get(), scriptScan.get())
        return Build(
            items: (found.items + panes.items + scripted.items)
                .filter { !excludedIDs.contains($0.id) },
            groups: scripted.groups, problems: found.problems + panes.problems + scripted.problems,
            duration: clock.now - start)
    }
}
