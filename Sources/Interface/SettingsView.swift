import Search
import SwiftUI
import UniformTypeIdentifiers

/// The settings window's content: a grouped form, as macOS's own settings windows lay theirs
/// out, with a control for each key of the config file and a button that opens the file
/// (docs/decisions/0015-settings-window.md).
struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    /// The model's recorder, observed apart from the model, which doesn't republish its changes.
    @ObservedObject private var recorder: ShortcutRecorder
    let quitTitle: String
    let quit: @MainActor () -> Void

    init(model: SettingsModel, quitTitle: String, quit: @escaping @MainActor () -> Void) {
        self.model = model
        recorder = model.recorder
        self.quitTitle = quitTitle
        self.quit = quit
    }

    static let width: CGFloat = 520

    var body: some View {
        SettingsForm {
            if model.isFileBroken || model.writeError != nil {
                problems
            }
            Group {
                general
                results
                folders
                excluded
            }
            .disabled(model.isFileBroken)
            file
            shortcut
                .disabled(model.isFileBroken)
            SettingsSection {
                Button(quitTitle, action: quit)
            }
        }
        .frame(width: Self.width)
        .frame(minHeight: 360, idealHeight: 680)
    }

    // MARK: Sections

    private var problems: some View {
        SettingsSection {
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
        SettingsSection {
            if LoginItem.isAvailable {
                Toggle("Open at login", isOn: binding(\.launchAtLogin))
            }
            DescribedToggle(
                "Show on all displays", detail: "Typing goes to the display you're working on.",
                isOn: binding(\.showOnAllDisplays))
        }
    }

    private var results: some View {
        SettingsSection("Results") {
            Toggle("Apps", isOn: binding(\.searchApplications))
            Toggle(SettingsPaneProvider.subtitle, isOn: binding(\.searchSystemSettings))
            Toggle("Script commands", isOn: binding(\.scriptCommands))
            Toggle("Calculator", isOn: binding(\.calculator))
            Stepper(
                value: binding(\.maxResults), in: Search.Settings.maxResultsRange
            ) {
                LabeledRow("Most rows") { Text("\(model.settings.maxResults)") }
            }
            DescribedToggle(
                "Dim apps not opened lately",
                detail: "The apps, panes and scripts you use stand out.",
                isOn: binding(\.dimUnused))
            Stepper(
                value: binding(\.dimAfterDays), in: Search.Settings.dimAfterDaysRange
            ) {
                LabeledRow("Dim after") {
                    Text(
                        model.settings.dimAfterDays == 1
                            ? "1 day" : "\(model.settings.dimAfterDays) days")
                }
            }
            .disabled(!model.settings.dimUnused)
        }
    }

    private var folders: some View {
        SettingsSection("App folders") {
            ForEach(model.settings.appFolders, id: \.self) { folder in
                removableRow(folder) { $0.appFolders.removeAll { $0 == folder } }
            }
            Button("Add Folder…", action: addFolders)
        }
    }

    private var excluded: some View {
        SettingsSection("Left out of results") {
            ForEach(model.settings.excludedApps, id: \.self) { id in
                removableRow(id) { $0.excludedApps.removeAll { $0 == id } }
            }
            Button("Add App…", action: addApps)
        } footer: {
            Text("By bundle ID. Panes and other IDs can be added in \(ConfigFile.name).")
                .foregroundStyle(.secondary)
        }
    }

    private var file: some View {
        SettingsSection {
            LabeledRow("Config file") {
                Text(
                    (model.configFile.path as NSString)
                        .abbreviatingWithTildeInPath
                )
                .textSelection(.enabled)
                .foregroundStyle(.secondary)
            }
            Button("Open \(ConfigFile.name)", action: model.openConfigFile)
        } footer: {
            Text("Changes here are saved to the file, and edits to the file show here.")
                .foregroundStyle(.secondary)
        }
    }

    /// The hotkey's recorder, with why a chord was refused or the hotkey couldn't be registered.
    private var shortcut: some View {
        SettingsSection {
            LabeledRow("Shortcut") {
                RecorderButton(recorder: recorder, chord: model.settings.hotkey)
            }
            if let refusal = recorder.refusal, recorder.isRecording {
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
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
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
    @ObservedObject var recorder: ShortcutRecorder
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

/// A label with a value or control beside it, as `LabeledContent` lays it out in a grouped form.
/// macOS 12 has neither, so there the two share a row, the value on the right.
private struct LabeledRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        if #available(macOS 13, *) {
            LabeledContent(label) { content }
        } else {
            HStack {
                Text(label)
                Spacer()
                content
            }
        }
    }
}

/// The grouped form of macOS's own settings windows. macOS 12 has no grouped style, and its
/// plain form lays rows out in columns that, in a scroll view, end up off the window, so there
/// the sections stack in a padded scroll view instead.
private struct SettingsForm<Content: View>: View {
    @ViewBuilder let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        if #available(macOS 13, *) {
            Form { content }
                .formStyle(.grouped)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) { content }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// A section of the settings form. On macOS 12 the sections aren't in a `Form`, which would
/// style their titles and footers, so there the title is a heading, the footer is callout
/// text, and the rows stack beneath.
private struct SettingsSection<Content: View, Footer: View>: View {
    let title: String?
    @ViewBuilder let content: Content
    @ViewBuilder let footer: Footer

    init(
        _ title: String? = nil, @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer
    ) {
        self.title = title
        self.content = content()
        self.footer = footer()
    }

    init(_ title: String? = nil, @ViewBuilder content: () -> Content)
    where Footer == EmptyView {
        self.init(title, content: content, footer: { EmptyView() })
    }

    var body: some View {
        if #available(macOS 13, *) {
            if let title {
                Section {
                    content
                } header: {
                    Text(title)
                } footer: {
                    footer
                }
            } else {
                Section {
                    content
                } footer: {
                    footer
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                if let title {
                    Text(title).font(.headline)
                }
                content
                footer.font(.callout)
            }
        }
    }
}

/// A toggle with a line under its title saying what it does. A grouped form shows a toggle's
/// second label text that way; macOS 12 runs the two together on one line, so there the line
/// sits under the checkbox, lined up with the title.
private struct DescribedToggle: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    init(_ title: String, detail: String, isOn: Binding<Bool>) {
        self.title = title
        self.detail = detail
        _isOn = isOn
    }

    var body: some View {
        if #available(macOS 13, *) {
            Toggle(isOn: $isOn) {
                Text(title)
                Text(detail)
            }
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Toggle(title, isOn: $isOn)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 20)
            }
        }
    }
}
