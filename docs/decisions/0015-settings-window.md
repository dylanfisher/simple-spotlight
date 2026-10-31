# 0015. A settings window that writes the config file in place

- **Date:** 2026-10-31
- **Status:** accepted
- **Amends:** [0006](0006-config-file.md), [0009](0009-app-wiring.md)

## Context

The user chose (2026-10-31) a small native settings window reachable without a menu bar icon:
⌘, while the panel shows, a gear at the right of the field while Option is held, and the
built-in row, renamed "Simple Spotlight Settings". The app stays an agent app. The config file
stays the source of truth (0006), which until now the app wrote only to create the default
file. The window needs a control for every user-facing key, a shortcut recorder for the hotkey,
and has to cope with a file the user is editing, or has broken, while it is open.

## Decision

- **Layout.** SwiftUI `Form` with `.formStyle(.grouped)`, as macOS 26's System Settings and
  apps' settings windows lay out: labels left, controls right, in sections (the shortcut, login
  and displays; results; app folders; apps left out; the config file). One titled, closable
  window in an `NSHostingController`. Opening it activates the app; closing it activates the
  app that was frontmost when it opened, since an agent app with no window would otherwise keep
  the keys. ⌘W and ⌘Q work in it, as the app has no menu bar to route them.
- **Writes edit the file's text, one key at a time.** `ConfigStore.update` takes a change to the
  settings, reads the file, and `ConfigFile.changing` writes in only the keys whose value
  changed: the value's text is replaced, or a key the file leaves out goes in after the last
  key, at its indent, with its comment above it, matching a trailing comma and the file's line
  ends (`Base.ConfigText`, following Searcher's 0126). Comments, blank lines, key order and the
  spelling of untouched values stay; a change the file already has writes nothing. With no file
  or an empty one, the default file is the text changed. The write goes beside the destination,
  through a symbolic link, with the destination's permissions, and is renamed into place only if
  the file still has the bytes the change was made to; otherwise the change is made again to the
  new text, up to three times. It shares this path with the default file's write. Unknown keys
  are an error in this app (0006), so a file that can be written has none to keep.
- **The window shows the file.** It shows each state the store publishes, so an edit to the file
  shows in it at once. A change shows immediately and stays shown on top of the states that
  arrive until the store's read of the written file does, so a toggle doesn't flick back. Writes
  run in the order made.
- **A file with an error is never written.** `ConfigStore.State.isFileBroken` is true while the
  file is there but sets nothing. The window then lists the errors, says settings can't change
  until the file is fixed, turns its controls off and keeps "Open config.json". `update` refuses
  such a file as well, so a write that races the user's broken save doesn't land; that error, or
  any failed write, shows the same way and the change is undone in the window.
- **The recorder.** A click listens; the next chord pressed is the hotkey if the config file
  would take it (`KeyChord(checking:_:)`, the rule parsing applies), else the window says why and
  keeps listening. Esc with no modifier, a second click, or the window losing the keys stops
  without a change. It listens through a local event monitor, and while it does the app gives up
  its hotkey, since a registered chord is taken by Carbon before the window sees it; the
  settings' chord is registered again when it stops.
- **A chord another app or macOS holds is saved anyway**, exactly as typing it into the file
  would be, and the window says why it won't work, using `HotKeyConflictNotice`'s detection and
  words: for a macOS shortcut such as Spotlight's ⌘Space, with an Open Keyboard Shortcuts
  button, since the user may be about to free it; for a chord another app registered, with
  "Record another shortcut", while the chord before it keeps working (0009). While the window is
  open the one-time alert is skipped, as the window says it already; the panel's row stays. The
  alert and the refused-chord row point to Settings to record another shortcut.
- **Lists.** App folders are added from an open panel, written `~/…` inside the home folder.
  Apps are left out by choosing them in an open panel; their bundle IDs are read off the main
  actor. Panes and other IDs are added in the file.
- **Ways in.** ⌘, in the panel; the gear, shown only while Option is held so the field stays the
  panel's only control, with a tooltip and a VoiceOver label; the "Simple Spotlight Settings"
  row. The config error row still opens the file. A second launch still shows the panel.

## Alternatives considered

- **Rewrite the whole file from the settings, comments regenerated** — rejected: the first
  toggle would drop the user's comments and order, and the file is theirs.
- **Keep changes made while the file is broken and write them on top of the fix**, as Searcher
  does — rejected: a queue of patches held across the user's edits is most of Searcher's config
  code, and this window has a few toggles; turning the controls off says plainly what to do.
- **Refuse a chord another app holds**, by trying to register it first — rejected: the file
  takes it, so the window would allow less than the file, and a chord another app holds now may
  be free later. The window says what is wrong instead.
- **Keep the alert while the window is open** — rejected: it would cover the window that already
  shows the conflict.
- **A SwiftUI `Settings` scene or `fileImporter`** — rejected: the scene needs a menu bar to open
  from, and the SwiftUI macros (`@State` among them) aren't available to this SwiftPM build,
  so the window is an `NSWindow` and the open panels `NSOpenPanel`.

## Consequences

Each change costs one read and one small write on the store's actor. The window's state is the
store's, so there is no second copy of the settings to drift. The gear makes the field narrower
only while Option is held.
