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
its comment, and leaves the rest of the file, your comments included, as it is. Its General
pane opens the file in your editor, shows it in Finder, or copies a default file's text. The app
writes the default file the first time: every key at
its default, with a comment above it saying what it does and what it accepts. `Settings.Keys` in
`Sources/Search/Settings.swift` declares them. The file allows comments and trailing commas. A
save applies right away, in the Settings window too; if the file has an error, a row at the top
of the panel names the line, the last good settings stay, and the Settings window lists the
errors and changes nothing until the file is fixed.

The Settings window's Spotlight pane turns macOS's own Spotlight indexing off on every disk, and
back on. Simple Spotlight doesn't use that index, so with indexing off macOS stops the background
work of indexing every file; Spotlight, Finder and Mail search then find no new files. It asks for
an administrator's password.

Set `"launchAtLogin": true` to start the app at login. It registers the app where it is, so
launch it from where it will stay. If macOS asks for approval, a row in the panel opens Login
Items.

The app keeps what you open and what you typed to find it, so the next search like it puts
that first, in
`~/Library/Application Support/simple-spotlight/usage.json`, and the hotkey conflicts it has
told you about in `state.json` beside it. Deleting either resets it.

## Your own commands

Each executable file in `~/.config/simple-spotlight/commands/` is a row in the panel, and Return
runs it. Each subfolder is a group: opening it searches only the commands inside. Set
`"scriptCommands": false` to turn the feature off. The folder shows up in the index about a
second after you add or edit a file.

A script describes itself in `#` or `//` comment lines before its first other line:
`@title` (default: the file name without its extension), `@subtitle`, `@keywords` (words that
also find it) and `@top-level` (also show a command from inside a group at the top level, with
the group's title as its subtitle). A group takes the same tags from a file named `_group` in
its folder, which is never run. A mistake in a header, or a file that isn't executable
(`chmod +x` it), shows as a row at the top of the panel naming the file. Names starting with `.`
or `_` are skipped, so `_denon.sh` below stays out of the panel.

An example that switches a Denon receiver's input over telnet. The shared file holds the address
and a `send` function:

```sh
# commands/Denon/_denon.sh
host=192.0.2.10   # your receiver's IP address

send() {
  printf '%s\r' "$1" | /usr/bin/nc -G 2 -w 1 "$host" 23 \
    || { echo "couldn't reach the receiver at $host" >&2; exit 1; }
}
```

```sh
#!/bin/sh
# commands/Denon/game.sh
# @title Game
# @keywords input console
. "$(dirname "$0")/_denon.sh"
send SIGAME
```

```
# commands/Denon/_group
# @title Denon
# @keywords receiver avr
```

A script runs in its own folder with no input, and with the PATH that launchd gives an app,
`/usr/bin:/bin:/usr/sbin:/sbin`, not your shell's: use absolute paths for anything else. Its
output is dropped. If it exits with an error, a notice shows the exit code and the end of its
stderr, which is why the example says what went wrong there. After 10 seconds it is stopped and
you are told.

In the panel, Tab or Return on a group row opens the group, and so does → when the cursor is at
the end of the query. Shift-Tab goes up a level, as do ← at the start of the query and
Backspace on an empty one. Esc clears the query, then goes up a level, then hides the panel. The
groups you are in show at the left of the field, and clicking them goes up a level. Going up
returns to what you had typed there, with the group's row selected. Hiding the panel inside a
group goes all the way up the same way.

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
