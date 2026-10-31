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
- **A bundle with no `Info.plist` is indexed by file name and path**; one whose `Info.plist` or
  strings file doesn't parse fails the build with the file's path, as does a folder that can't
  be listed. A missing `.prefPane` folder has no panes; the app folders' existence is P4's to
  check, per the plan's config rules.

## Alternatives considered

- **`Bundle(url:)` and `localizedInfoDictionary`** — rejected: `Bundle` keeps one instance per
  path for the process's life, so a rebuild after an app updates would read the first values. It
  also misses names that live only in `Info.plist` (0004).
- **`FileManager.displayName(atPath:)` for apps** — rejected: it follows the Finder setting for
  showing extensions ("Safari.app"), and goes through Launch Services for each app.
- **Skipping a bundle with a broken `Info.plist`** — rejected per "fail loudly"; none exists on
  the build machine. If one turns up in practice, the error names the file.

## Consequences

The build reads only plain files, so it measures about 30 ms for 117 apps and 52 panes with a
warm disk cache (release build, median of 20). A bundle format `BundleInfo` doesn't read, such as
an iOS app's `Wrapper/`, gets its file name as its title.
