# 0016. A `macos-12` branch for Monterey and Intel Macs

- **Date:** 2026-10-31
- **Status:** accepted

## Context

The app needs to run on an Intel MacBook that stays on macOS 12.7.6. `main` targets macOS 15
and uses APIs from macOS 13 to 15:

- Observation (`@Observable`), macOS 14.
- `Duration`, `ContinuousClock` and `Task.sleep(for:)`, macOS 13.
- `URL(filePath:)`, `appending(path:)` and `path(percentEncoded:)`, macOS 13.
- `SMAppService`, macOS 13. `NSApplication.activate()` and `yieldActivation(to:)`, macOS 14.
- `LabeledContent`, `.formStyle(.grouped)` and the hosting views' `sizingOptions`, macOS 13.
- Typed-throws function types stored in closures (`async throws(ConfigError) -> URL`). Their
  metadata needs the macOS 15 Swift runtime. The compiler doesn't flag this. It weak-links
  `swift_getExtendedFunctionTypeMetadata`, so the app launches on macOS 12 and crashes the first
  time it needs that metadata, such as when a `Task` captures the closure.
- System Settings itself, macOS 13. macOS 12 has System Preferences, whose panes are `.prefPane`
  bundles in `/System/Library/PreferencePanes`, not ExtensionKit extensions.

The build machine runs a recent macOS on Apple Silicon. The Intel Mac can't run Swift 6.2.

## Decision

The `macos-12` branch targets macOS 12, keeps `main`'s behavior on macOS 13 and later through
`#available`, and is built universal (`./scripts/bundle -c release -a universal`).

- APIs with an old equivalent use it everywhere: `TimeInterval` and system uptime for
  `Duration` and the clock, `Task.sleep(nanoseconds:)`, `fileURLWithPath:`,
  `appendingPathComponent`, `path`, `Locale.languageCode`, and `ObservableObject` with
  `@Published` for `@Observable`.
- APIs without one are behind `#available`. The settings form is grouped on macOS 13 and later,
  and a padded scroll view on 12. Login items need macOS 13, so on 12 the toggle is hidden and
  `launchAtLogin: true` shows a problem row saying so. Activation uses
  `activate(ignoringOtherApps:)` on 12.
- Stored closures that threw a typed error return a `Result` instead. `Result(catching:)` gets
  an async overload in Base for building one. `scripts/check` fails if the bundled binary
  imports `swift_getExtendedFunctionTypeMetadata`.
- `SettingsPaneProvider` picks the system's panes at runtime: System Settings' extensions on
  macOS 13 and later, and on 12 the `.prefPane` bundles in `/System/Library/PreferencePanes`.
  Those are named by their `NSPrefPaneIconLabel`, which is the name System Preferences shows,
  joined onto one line. They open as files, as third-party panes already do. Their rows say
  "System Preferences" and show its icon. The Keyboard Shortcuts link uses
  `com.apple.preference.keyboard` on 12.
- Test targets build with `-disable-availability-checking`, since tests run only on the build
  machine. Tests keep `main`'s newer APIs, and the branch's diff stays in `Sources`.

## Alternatives considered

- **Target macOS 12 on `main`** — rejected for now: `main` would carry the `#available`
  branches and the older APIs for one machine. The branch can be folded into `main` later if it
  lasts.
- **A separate fork** — rejected: changes from `main` merge into a branch more easily.
- **Plain `throws` for the closures** — rejected: callers would cast the error back to
  `ConfigError` and need a fallback for the error that can't happen.
- **Rewrite the tests' URL and clock calls** — rejected: about 120 lines of churn for code that
  never runs on macOS 12.

## Consequences

Merging `main` into this branch conflicts where `main` adds new uses of the APIs above. The
build catches most of them. A new typed-throws closure type fails the `runtime` step of
`scripts/check`. The tests run on the build machine's macOS, so the macOS 12 paths have to be
checked by hand on the Intel Mac: the pane list (some panes may be shown only on certain
hardware or when an MDM profile is installed), the settings window layout, activation, and the
problem row for `launchAtLogin`. Nothing hides any of Monterey's panes yet.
