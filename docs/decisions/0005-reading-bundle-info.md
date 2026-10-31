# 0005. Indexing reads Info.plist files directly and names apps as Finder does

- **Date:** 2026-10-31
- **Status:** accepted

## Context

`AppProvider` and `SettingsPaneProvider` read each bundle's identifier, name and flags. The index
is built at launch and, from P7, again whenever an app folder changes, in the same process. The
plan orders an app's name as the localized `CFBundleDisplayName`, then `CFBundleName`, then the
file name.

## Decision

- **`BundleInfo` reads `Contents/Info.plist` and the localized values itself**, with
  `PropertyListSerialization`, from `Resources/InfoPlist.loctable` when there is one, else from
  `<language>.lproj/InfoPlist.strings`. The language comes from
  `Bundle.preferredLocalizations(from:forPreferences:)`, a pure function of the names it is
  given.
- **An app's name is Finder's.** The localized display name (then bundle name) is used only when
  the file name matches a name in `Info.plist`; a renamed file keeps its file name. This is the
  plan's order plus the rule Finder applies: "Visual Studio Code.app" has `CFBundleDisplayName`
  "Code", and Finder, Spotlight and the plan's own ranking example call it Visual Studio Code. On
  the build machine all 117 apps get the name `FileManager.displayName(atPath:)` gives.
- **The `-macos` form of a key wins** (`CFBundleDisplayName-macos` is "Image Playground" where the
  plain key is the iOS "Playground"), as `Bundle` reads it.
- **Listings skip dot files only.** `/Applications/Safari.app` is a symbolic link with the hidden
  flag set, so `.skipsHiddenFiles` drops Safari. Links are followed.
- **Only `Info.plist` is read until the bundle is known to be wanted.** An appex's strings are
  read only once its `Info.plist` says it is a Settings pane, so the 30-odd other extensions in
  the folder cost one small file each.
- **When no localization matches a preferred language, the development region's is used**, as
  `Bundle` does, not the arbitrary candidate `preferredLocalizations` returns then.
- **Soft hyphens (U+00AD) are removed from names.** German names carry them
  ("System­einstellungen"), and `FoldedText` drops all format characters when matching.
- **A localized app is also found by its file name.** The file name, when it differs from the
  title, is an alternate match name, so a German user finds "Rechner" by typing "calc".
- **Finder is always included** when `/System/Library/CoreServices/Finder.app` exists
  (`AppProvider.finder`). It sits in none of the configured folders, and the plan leaves
  `/System/Library/CoreServices` itself out because most apps there are agents.
- **One bad folder or bundle leaves out only itself.** A bundle with no `Info.plist` is indexed
  by file name and path. A bundle whose `Info.plist` or strings don't parse, a folder or
  subfolder that can't be listed, and a configured folder that is missing are each skipped and
  returned as an `IndexProblem` (path and a plain reason) beside the items, which
  `IndexBuilder.Build` carries for the panel to show. A missing `~/Applications` and missing
  `.prefPane` folders are skipped silently, as most Macs don't have them. The providers throw
  only `CancellationError`, so a stale rebuild can be cancelled.

## Alternatives considered

- **`Bundle(url:)` and `localizedInfoDictionary`** — rejected: `Bundle` keeps one instance per
  path for the process's life, so a rebuild after an app updates would read the first values. It
  also misses names that live only in `Info.plist` (0004).
- **`FileManager.displayName(atPath:)` for apps** — rejected: it follows the Finder setting for
  showing extensions ("Safari.app"), and goes through Launch Services for each app.
- **Failing the whole build on the first bad bundle or folder** — rejected: one broken
  third-party app would empty the launcher. Reporting each problem beside the items keeps the
  failure visible without that.

## Consequences

The build reads only plain files, so it measures about 31 ms for 118 apps and 50 panes with a
warm disk cache (release build, median of 20). A bundle format `BundleInfo` doesn't read, such as
an iOS app's `Wrapper/`, gets its file name as its title.
