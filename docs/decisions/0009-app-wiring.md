# 0009. App wiring: the hotkey, live config, problem rows and the conflict notice

- **Date:** 2026-10-31
- **Status:** accepted

## Context

P6 turns the parts into an app. B3 gives 300 ms from launch to a working hotkey, so launch can't
wait for the config file or the index. `ConfigStore.states` sends a state on any change, and
each part (hotkey, index, login item) should only be redone when its settings change. Config
errors and index problems need a place to show in an app with no window but the panel. ⌘Space,
the default chord, belongs to Spotlight until the user turns Spotlight's shortcut off.

## Decision

- **A coordinator in Interface, a thin delegate in the app.** `AppCoordinator` holds the logic,
  with the hotkey, login item, index build and notice injected so tests drive it without
  touching the system. `AppDelegate` creates it, starts the store, and forwards each state, the
  reopen event and termination. Launch returns at once: the store reads the file off the main
  actor, and the first state registers the hotkey.
- **Each part runs only when its settings change.** On each state the hotkey is registered first
  (when `hotkey` changed), then the index rebuilt off the main actor (when
  `Settings.asksForSameIndex(as:)` says the index keys changed; a build still running is
  cancelled), then the login item followed (when `launchAtLogin` changed), and the settings and
  problem rows always passed to the panel. The first state counts as a change of every key. The
  built index gets the two command rows appended, and the icon cache is cleared on each swap.
  Before the first build the index holds only the commands.
- **Problem rows sit above the results** (`SearchItem.Kind.problem`, a warning triangle), for any
  query including an empty one, at most one per source:
  - **Config file:** "Config error: line 3: …" for an error on a line, "Config file couldn't be
    read: …" for one that isn't. The subtitle counts the other errors and says Return opens the
    file. Return runs the config command, which creates the default file if needed.
  - **Login item:** when registering or unregistering fails, or macOS wants approval. Return
    opens System Settings' Login Items pane.
  - **Index:** "Couldn't search Apps" for one problem, "Couldn't search 3 folders or apps" for
    several, the first problem in the subtitle. Return copies every problem, a line each, since
    a row shows only one and the fixes vary (a missing folder is fixed in the config file, an
    unreadable bundle is not).
  An opener failure after the panel hides (an app that won't launch) is an alert, not a row: it
  is about one action, not a state that lasts.
- **Built-in commands are index items.** `CommandProvider` makes "<name> Config" and "Quit
  <name>" from the bundle's `CFBundleName`; each command's raw value is both the row's id and
  its `.command` identifier.
- **The hotkey is Carbon's `RegisterEventHotKey`** with a handler on the application event
  target. It needs no Accessibility permission, which `CGEventTap` and `NSEvent` global
  monitors do. Changing the chord unregisters the old one first; quitting unregisters it.
- **Conflicts are checked against macOS's own shortcuts before registering.** Measured on macOS
  26.6: `RegisterEventHotKey` returns `noErr` for ⌘Space while Spotlight's shortcut is on, and
  only returns `eventHotKeyExistsErr` when another app registered the chord through Carbon. Since
  macOS handles its own shortcuts before any app, a registered ⌘Space then never fires.
  `CopySymbolicHotKeys` lists macOS's shortcuts with key code, Carbon modifiers and whether each
  is on (⌘Space showed as code 49, modifiers 256, on). It gives no names or IDs, and
  `com.apple.symbolichotkeys` holds no entry for a shortcut left at its default, so the notice
  names Spotlight only for Spotlight's default chords (⌘Space, ⌥⌘Space) and otherwise says "the
  shortcut that uses ⌃F2". Modifiers outside the four a chord holds (macOS adds the Fn mask to
  F-key shortcuts) are ignored in the comparison. The chord is registered even when it
  conflicts, so it starts working as soon as the user turns the system shortcut off.
- **The notice is an alert, once per chord per run.** It names the chord and the path System
  Settings → Keyboard → Keyboard Shortcuts…, with buttons to open that section, to open the
  config file, and OK, and says a second launch shows the panel meanwhile. The section is
  `x-apple.systempreferences:com.apple.Keyboard-Settings.extension?Shortcuts`; "Shortcuts" is
  one of the keys of the pane's `Keyboard.searchTerms`, which System Settings uses as anchors,
  and an anchor it doesn't know opens the pane.
- **Alerts run from the run loop, not from a task.** Found by running the app: an alert's modal
  loop started inside a main-actor task holds the main dispatch queue, so the index built
  during the alert was never installed. `AlertPresenter` starts the modal through
  `RunLoop.main.perform`, where the queue keeps draining.
- **A second launch shows the panel** (`applicationShouldHandleReopen`), the way in when the
  hotkey doesn't work.
- **Login item:** `SMAppService.mainApp`, checked against its status first so an unchanged
  setting does nothing; `requiresApproval` after registering becomes a row.
- **Logging:** `os.Logger` with the bundle's ID as subsystem, category `app`: launch, hotkey
  registration and conflicts, each index build (count, problems, time), config errors, reopen.

## Alternatives considered

- **Show the conflict as a problem row** — rejected as the only signal: with the hotkey dead the
  user may never see the panel. The alert can't be missed.
- **Skip registering a chord macOS holds** — rejected: the user would have to relaunch after
  freeing it.
- **Read `com.apple.symbolichotkeys` to name the shortcut** — rejected: a shortcut at its default
  has no entry there, so it misses the common case.
- **One row per config error** — rejected: rows count toward `maxResults`, and a broken file can
  have ten errors; the file is where all of them are fixed.
- **Compare `IndexBuilder` values to decide a rebuild** — rejected: its providers aren't
  `Equatable`, and the comparison would sit far from the keys. `asksForSameIndex(as:)` sits
  beside `indexBuilder(home:languages:)` and reads the same four keys.

## Consequences

While the conflict alert is open it is app-modal: a second launch and a quit wait until it is
dismissed. Measured on a release build (Apple silicon, macOS 26.6): the hotkey registers about
20 ms after the app's first log line, and 61–82 ms after `open` warm (264 ms for the first
launch of a freshly signed build); the index installs about 45 ms later. Idle footprint is
18–21 MB (`footprint`), RSS about 60 MB. The login item was not registered on the build machine,
so how an ad hoc signed bundle in `.build` fares with `SMAppService` is unverified.
