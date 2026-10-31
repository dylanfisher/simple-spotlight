# 0009. App wiring: the hotkey, live config, problem rows and the conflict notice

- **Date:** 2026-10-31
- **Status:** accepted; amended by [0015](0015-settings-window.md) (the conflict alert is
  skipped while the settings window is open, and points to Settings)

## Context

P6 turns the parts into an app. B3 gives 300 ms from launch to a working hotkey, so launch can't
wait for the config file or the index. `ConfigStore.states` sends a state on any change, and
each part (hotkey, index, login item) should only be redone when its settings change. Config
errors and index problems need a place to show in an app with no window but the panel. ⌘Space,
the default chord, belongs to Spotlight until the user turns Spotlight's shortcut off.

## Decision

- **Logic in an Interface coordinator, a thin delegate in the app**, so tests drive the wiring
  with the hotkey, login item, index build and alert injected and nothing touches the system.
- **Launch waits for nothing.** The store reads the file off the main actor; the first state
  registers the hotkey before the index build starts, and the index is swapped in when built.
- **Each part runs only when its own settings change.** The keys the index reads are one value,
  `Settings.IndexKeys`, and the builder is a method on it, so a key the builder can read is a key
  whose change rebuilds. A newer build cancels an older one, and an older one that finishes last
  is dropped. The panel searches only while shown, so a config save makes no VoiceOver
  announcement and no main-actor scan.
- **What is wrong shows as rows above the results**, at most one per source (config file, hotkey,
  login item, index), for any query. A row for a lasting state is noticed when the user next
  opens the panel, without an interruption. Return goes to where the problem is fixed: the
  config file, Keyboard Shortcuts, Login Items. The index row copies every problem instead,
  because one row shows only one and their fixes differ. A failed open is an alert instead: it
  is about one action the user just took, not a state.
- **The hotkey is Carbon's `RegisterEventHotKey`**, the one way to take a chord from every app
  without the Accessibility permission. A new chord is registered before the old one is released,
  so a chord another app holds leaves the working one.
- **Conflicts are checked against macOS's own shortcuts first.** Measured on macOS 26.6:
  Carbon registers ⌘Space without error while Spotlight's shortcut is on, and macOS then keeps
  the keys, so registration alone can't tell. `CopySymbolicHotKeys` lists macOS's shortcuts with
  key, modifiers and whether each is on, but no names; the shortcuts' defaults file has no entry
  for one left at its default. So Spotlight is named only for its default chords. The chord is
  registered even when it conflicts, so it works the moment the user frees it, and a press
  clears the conflict row.
- **The conflict alert shows once per chord, ever.** The chords already shown are kept in the
  app's state file, so a login item launch doesn't take focus each login; afterwards the row
  carries the message. The alert runs from the run loop, because a modal loop inside a
  main-actor task holds the main queue and stopped the index from being installed while it
  showed.
- **A second launch shows the panel**, the way in while the hotkey doesn't work.
- **The login item follows `launchAtLogin` both ways**, so false removes an entry the user added
  by hand. Its status is read again each time the panel shows, which is cheap, so an approval in
  System Settings clears the row.
- **Logs** use the bundle's ID as subsystem; paths and config values in them are private.

## Alternatives considered

- **The conflict only as a row** — rejected for the first time: with the hotkey dead the user
  may never open the panel to see it.
- **The alert at every launch** — rejected: with `launchAtLogin` it takes focus at each login.
- **Skip registering a chord macOS holds** — rejected: the user would have to relaunch after
  freeing it.
- **Read the shortcuts' defaults file to name the owner** — rejected: a shortcut at its default
  isn't in it.
- **One row per config error** — rejected: rows count toward `maxResults`, and the file is where
  all of them are fixed.

## Consequences

The conflict alert is app-modal: while it is open, a second launch and a quit wait. Measured on
a release build: the hotkey registers about 20 ms after the app's first log line and 61–82 ms
after `open` warm; idle footprint 18–21 MB. How `SMAppService` treats an ad hoc signed bundle in
`.build` is unverified.
