# simple-spotlight

A minimal, fast Spotlight replacement for macOS: apps, System Settings, and a calculator, behind
⌘Space.

Requires macOS 15 or later.

## Use it

Build and launch it with `./scripts/dev`. The app is built at the path `./scripts/bundle` prints,
with no Dock icon or menu bar; the panel is the whole interface.

The default hotkey is ⌘Space, which Spotlight holds until you free it: System Settings →
Keyboard → Keyboard Shortcuts → Spotlight → uncheck "Show Spotlight search". Until then, an alert
says so the first time, then a row at the top of the panel does, and launching the app again
shows the panel.

In the panel, type to search apps, System Settings panes and arithmetic (`2^10`, `15% * 80`,
`sqrt(2)`). Return opens the selected row or copies a calculator answer. ↑ ↓ (or Ctrl-P Ctrl-N)
move the selection, ⌘1…⌘9 open a row, ⌘Return shows an app in Finder, ⌘C copies an app's path
(a pane's `x-apple.systempreferences:` link, a calculator answer) when no text is selected, and
Esc clears the query or hides the panel. ⌘, opens Settings, as does the gear that shows at the
right of the field while Option is held, and the "Simple Spotlight Settings" row. ⌘Q quits; so
does the "Quit Simple Spotlight" row.

## Configure

Settings live in `~/.config/simple-spotlight/config.json`, and the Settings window (⌘, in the
panel) changes them there: each change replaces that one value in the file, or adds the key with
its comment, and leaves the rest of the file, your comments included, as it is. Its "Open
config.json" button opens the file. The app writes the default file the first time: every key at
its default, with a comment above it saying what it does and what it accepts. `Settings.Keys` in
`Sources/Search/Settings.swift` declares them. The file allows comments and trailing commas. A
save applies right away, in the Settings window too; if the file has an error, a row at the top
of the panel names the line, the last good settings stay, and the Settings window lists the
errors and changes nothing until the file is fixed.

Set `"launchAtLogin": true` to start the app at login. It registers the app where it is, so
launch it from where it will stay. If macOS asks for approval, a row in the panel opens Login
Items.

The app keeps what you open and what you typed to find it, so the next search like it puts
that first, in
`~/Library/Application Support/simple-spotlight/usage.json`, and the hotkey conflicts it has
told you about in `state.json` beside it. Deleting either resets it.

## Develop

Needs Swift 6.2 or later (Command Line Tools or Xcode).

| Task | Command |
|---|---|
| Bootstrap, install the commit hook | `./scripts/setup` |
| Run the app | `./scripts/dev` |
| Run tests | `./scripts/test` |
| Fix formatting | `./scripts/format` |
| Full gate — format, build, tier rules, bundle, tests | `./scripts/check` |

## Layout

| Path | Purpose |
|---|---|
| `Package.swift` | Targets and their dependencies — the tier map. |
| `Sources/` | One directory per target: Base, Search, Interface, SimpleSpotlight. See [docs/map.md](docs/map.md). |
| `Tests/` | Mirrors `Sources/`. |
| `AGENTS.md` | Instructions for AI coding agents. |
| `docs/performance.md` | Speed and memory budgets. |
| `docs/principles.md` | Rationale behind the rules in AGENTS.md. |
| `docs/writing.md` | Comment voice and commit format. |
| `docs/decisions/` | Why things are the way they are. |

## License

MIT — see [LICENSE](LICENSE).
