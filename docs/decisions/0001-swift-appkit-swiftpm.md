# 0001. Swift, AppKit and SwiftUI, built with SwiftPM only

- **Date:** 2026-10-31
- **Status:** accepted

## Context

Simple Spotlight replaces Spotlight with a launcher that searches three things: installed apps,
System Settings panes, and calculator results. It opens on a global hotkey (⌘Space by default)
and has to feel instant. It runs on macOS 15 and later, ships by direct download, and is built
mostly by agents from the terminal. It follows the conventions of the author's other Swift app,
Searcher, so the two read alike.

## Decision

- **Swift 6, language mode 6, macOS 15+.** AppKit for the borderless floating panel and the app
  shell; SwiftUI for the field and results inside the panel. The app is an agent app
  (`LSUIElement`): no Dock icon, no menu bar.
- **A SwiftPM package with no `.xcodeproj` and no dependencies.** Tiers are SwiftPM targets, so
  the build enforces dependency direction. `scripts/bundle` assembles and ad hoc signs the
  `.app`. The global hotkey uses Carbon's `RegisterEventHotKey`, which needs no Accessibility
  grant. Formatting and lint use `swift format`, which ships with the toolchain. Tests use Swift
  Testing.
- **The native build system** (`--build-system native`), with one set of flags for every build
  and test, defined in `swift_cmd` in `scripts/swift-env`. With Command Line Tools, the default
  build system picks one of two toolchain IDs at random and rebuilds every module on about half
  of all runs (measured in Searcher's 0092).

## Alternatives considered

- **All SwiftUI** — rejected because a Spotlight-style panel (borderless, non-activating, over
  full-screen apps, closing on focus loss) needs `NSPanel`.
- **Committed `.xcodeproj`** — rejected because agents edit `project.pbxproj` badly and it causes
  merge conflicts.
- **XcodeGen or Tuist** — rejected as a dependency that buys little until the app needs asset
  catalogs or extensions.
- **A hotkey package (KeyboardShortcuts)** — rejected as a dependency for about 60 lines of Carbon.
- **SwiftLint** — not added; `swift format lint` covers style.

## Consequences

- macOS won't hand ⌘Space to another app while Spotlight's own shortcut is on. The user turns it
  off once in System Settings → Keyboard → Keyboard Shortcuts → Spotlight; the app detects the
  failed registration and says so.
- `-warnings-as-errors` is an unsafe flag, so the package can't be another package's
  dependency. It is an app, so that doesn't matter.
- Ad hoc signing changes the code hash every build, so any TCC grant would need renewing after a
  rebuild. Nothing planned needs one.
