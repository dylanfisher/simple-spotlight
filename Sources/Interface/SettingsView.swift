import Search
import SwiftUI
import UniformTypeIdentifiers

/// One pane of the settings window: a grouped form, as macOS's own settings windows lay theirs
/// out, with a control for each key of the config file the pane covers
/// (docs/decisions/0015-settings-window.md). While the file has an error, or a change couldn't
/// be saved, each pane says so at the top.
struct SettingsView: View {
    let pane: SettingsPane
    let model: SettingsModel
    let spotlight: SpotlightIndexModel
    let appName: String
    let quitTitle: String
    let quit: @MainActor () -> Void

    static let width: CGFloat = 520

    var body: some View {
        Form {
            if model.isFileBroken || model.writeError != nil {
                problems
            }
            switch pane {
            case .general:
                general
                    .disabled(model.isFileBroken)
                file
                Section {
                    Button(quitTitle, action: quit)
                }
            case .results:
                Group {
                    results
                    dimming
                }
                .disabled(model.isFileBroken)
            case .apps:
                Group {
                    folders
                    excluded
                }
                .disabled(model.isFileBroken)
            case .shortcut:
                shortcut
                    .disabled(model.isFileBroken)
            case .spotlight:
                spotlightIndex
            }
        }
        .formStyle(.grouped)
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
    }

    // MARK: Sections

    private var problems: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Label(
                    model.isFileBroken
                        ? "Settings can't change until the config file is fixed."
                        : "The last change couldn't be saved.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.orange)
                .font(.headline)
                ForEach(Array(model.shownErrors.enumerated()), id: \.offset) { _, error in
                    Text(error.description)
                        .font(.callout)
                        .textSelection(.enabled)
                }
            }
            Button("Open \(ConfigFile.name)", action: model.openConfigFile)
        }
    }

    private var general: some View {
        Section {
            Toggle("Open at login", isOn: binding(\.launchAtLogin))
            Toggle(isOn: binding(\.showOnAllDisplays)) {
                Text("Show on all displays")
                Text("Typing goes to the display you're working on.")
            }
        }
    }

    private var results: some View {
        Section("Show") {
            Toggle("Apps", isOn: binding(\.searchApplications))
            Toggle("System Settings", isOn: binding(\.searchSystemSettings))
            Toggle("Script commands", isOn: binding(\.scriptCommands))
            Toggle("Calculator", isOn: binding(\.calculator))
            Stepper(
                value: binding(\.maxResults), in: Search.Settings.maxResultsRange
            ) {
                LabeledContent("Most rows", value: "\(model.settings.maxResults)")
            }
        }
    }

    private var dimming: some View {
        Section("Dimming") {
            Toggle(isOn: binding(\.dimUnused)) {
                Text("Dim apps not opened lately")
                Text("The apps, panes and scripts you use stand out.")
            }
            Stepper(
                value: binding(\.dimAfterDays), in: Search.Settings.dimAfterDaysRange
            ) {
                LabeledContent(
                    "Dim after",
                    value: model.settings.dimAfterDays == 1
                        ? "1 day" : "\(model.settings.dimAfterDays) days")
            }
            .disabled(!model.settings.dimUnused)
        }
    }

    private var folders: some View {
        Section("App folders") {
            ForEach(model.settings.appFolders, id: \.self) { folder in
                removableRow(folder) { $0.appFolders.removeAll { $0 == folder } }
            }
            Button("Add Folder…", action: addFolders)
        }
    }

    private var excluded: some View {
        Section {
            ForEach(model.settings.excludedApps, id: \.self) { id in
                removableRow(id) { $0.excludedApps.removeAll { $0 == id } }
            }
            Button("Add App…", action: addApps)
        } header: {
            Text("Left out of results")
        } footer: {
            Text("By bundle ID. Panes and other IDs can be added in \(ConfigFile.name).")
                .foregroundStyle(.secondary)
        }
    }

    /// Where the config file is, and a row of buttons for it.
    private var file: some View {
        Section {
            LabeledContent("Config file") {
                Text(
                    (model.configFile.path(percentEncoded: false) as NSString)
                        .abbreviatingWithTildeInPath
                )
                .textSelection(.enabled)
                .foregroundStyle(.secondary)
            }
            HStack {
                Button("Open in Editor", action: model.openConfigFile)
                Button("Reveal in Finder", action: model.revealConfigFile)
                Button(action: model.copyDefaultConfig) {
                    // Both titles take room, so the button keeps its width when it changes.
                    ZStack {
                        Text("Copy Default Config")
                            .opacity(model.defaultConfigCopied ? 0 : 1)
                        Text(SettingsModel.copiedTitle)
                            .opacity(model.defaultConfigCopied ? 1 : 0)
                    }
                }
                .accessibilityLabel(
                    model.defaultConfigCopied ? SettingsModel.copiedTitle : "Copy Default Config"
                )
                .help("Copy a new config file's text, every setting at its default")
            }
        } footer: {
            Text("Changes here are saved to the file, and edits to the file show here.")
                .foregroundStyle(.secondary)
        }
    }

    /// Whether macOS's Spotlight indexes the disks, and a button that turns it off or on.
    private var spotlightIndex: some View {
        Section {
            LabeledContent("Spotlight indexing") {
                HStack {
                    if spotlight.isBusy {
                        ProgressView().controlSize(.small)
                    }
                    Text(spotlightStatus)
                        .foregroundStyle(.secondary)
                }
            }
            Button(
                spotlight.isIndexing == false
                    ? "Turn On Spotlight Indexing" : "Turn Off Spotlight Indexing",
                action: spotlight.toggle
            )
            .disabled(spotlight.isBusy || spotlight.isIndexing == nil)
            if let problem = spotlight.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
                    .textSelection(.enabled)
            }
        } footer: {
            Text(
                """
                \(appName) finds apps, settings and scripts without the Spotlight index. Turning \
                indexing off stops macOS indexing every file on every disk in the background, \
                which saves CPU, battery and disk activity. Spotlight, and search in Finder and \
                Mail, then find no new files until it's back on. Asks for an administrator's \
                password.
                """
            )
            .foregroundStyle(.secondary)
        }
    }

    private var spotlightStatus: String {
        switch spotlight.isIndexing {
        case true?: "On"
        case false?: "Off"
        case nil: spotlight.isBusy ? "Checking…" : "Unknown"
        }
    }

    /// The hotkey's recorder, with why a chord was refused or the hotkey couldn't be registered.
    private var shortcut: some View {
        Section {
            LabeledContent("Shortcut") {
                RecorderButton(recorder: model.recorder, chord: model.settings.hotkey)
            }
            if let refusal = model.recorder.refusal, model.recorder.isRecording {
                Text(refusal)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let conflict = model.hotKeyConflict, conflict.chord == model.settings.hotkey {
                conflictRow(conflict)
            }
        }
    }

    private func conflictRow(_ conflict: SettingsModel.Conflict) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Label(conflict.title, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Spacer()
            if conflict.isSystemShortcut {
                Button("Open Keyboard Shortcuts", action: model.openKeyboardShortcuts)
            } else {
                Text("Record another shortcut.")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }

    // MARK: Parts

    private func removableRow(
        _ text: String, remove: @escaping @Sendable (inout Search.Settings) -> Void
    ) -> some View {
        HStack {
            Text(text)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button {
                model.change(remove)
            } label: {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Remove \(text)")
            .accessibilityLabel("Remove \(text)")
        }
    }

    /// A control's binding to the setting at `path`: it reads the window's settings and writes
    /// a change into the file.
    private func binding<Value: Sendable>(
        _ path: WritableKeyPath<Search.Settings, Value> & Sendable
    ) -> Binding<Value> {
        Binding(
            get: { model.settings[keyPath: path] },
            set: { value in model.change { $0[keyPath: path] = value } })
    }

    /// Asks for folders in an open panel and adds those not listed yet, inside the home folder
    /// as `~/…`.
    private func addFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose folders to search for apps."
        choose(in: panel) { [model] urls in
            let added = urls.map { HomePath.written($0) }
            model.change { settings in
                for folder in added where !settings.appFolders.contains(folder) {
                    settings.appFolders.append(folder)
                }
            }
        }
    }

    /// Asks for apps in an open panel and leaves those not listed yet out of the results.
    private func addApps() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(filePath: "/Applications", directoryHint: .isDirectory)
        panel.prompt = "Leave Out"
        panel.message = "Choose apps to leave out of the results."
        choose(in: panel) { [model] urls in
            Task {
                let ids = await Self.bundleIDs(of: urls)
                model.change { settings in
                    for id in ids where !settings.excludedApps.contains(id) {
                        settings.excludedApps.append(id)
                    }
                }
            }
        }
    }

    /// Shows `panel` as a sheet on the settings window, and calls `chosen` with what the user
    /// chose, unless they cancel.
    private func choose(in panel: NSOpenPanel, chosen: @escaping @MainActor ([URL]) -> Void) {
        let done = { (response: NSApplication.ModalResponse) in
            guard response == .OK else { return }
            chosen(panel.urls)
        }
        if let window = NSApplication.shared.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: done)
        } else {
            panel.begin(completionHandler: done)
        }
    }

    /// The bundle IDs of the apps at `urls`, read off the main actor; an app with none is
    /// left out.
    @concurrent
    private nonisolated static func bundleIDs(of urls: [URL]) async -> [String] {
        urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
    }
}

/// The hotkey's recorder: the chord in a field-like button, which listens for a new one when
/// clicked.
private struct RecorderButton: View {
    let recorder: ShortcutRecorder
    let chord: KeyChord

    var body: some View {
        Button {
            recorder.toggle()
        } label: {
            Text(recorder.label(for: chord))
                .frame(minWidth: 120)
                .foregroundStyle(recorder.isRecording ? .secondary : .primary)
        }
        .buttonStyle(.bordered)
        .help(recorder.isRecording ? "Press a shortcut, or Esc to cancel" : "Click to record")
        .accessibilityLabel("Shortcut")
        .accessibilityValue(recorder.isRecording ? "Recording" : chord.description)
        .accessibilityHint("Shows and hides the search panel")
    }
}
