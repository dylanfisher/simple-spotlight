# 0004. System Settings pane names: the extension's loctable, then a two-entry table

- **Date:** 2026-10-31
- **Status:** accepted

## Context

`SettingsPaneProvider` lists the System Settings panes that `x-apple.systempreferences:<bundle
id>` opens: each `.appex` whose `EXAppExtensionAttributes` has the extension point
`com.apple.Settings.extension.ui` and whose `SettingsExtensionAttributes` (nested inside
`EXAppExtensionAttributes`) has `allowsXAppleSystemPreferencesURLScheme` true. On macOS 26.6 that
is 51 panes in `/System/Library/ExtensionKit/Extensions` plus General, which lives in
`/System/Applications/System Settings.app/Contents/PlugIns`. Home's privacy pane has no URL flag
and is left out.

`Bundle.localizedInfoDictionary["CFBundleDisplayName"]` gave the right name for most panes, but
none or an internal one for Bluetooth, Battery, Touch ID & Password, Headphones, Wallpaper,
Storage, VPN, Focus, Network, CDs & DVDs, Apple Account and Background Security Improvements.

What we found, looking at each appex's `Resources` and at System Settings' own:

- Apple's bundles keep localized `Info.plist` values in one `Resources/InfoPlist.loctable` (a
  plist keyed by language), not in `*.lproj/InfoPlist.strings`. Most loctables have an `en`
  entry with the sidebar name ("Menu Bar", "Wi‑Fi", "CDs & DVDs").
- Bluetooth, Apple Account, Touch ID & Password, Wallpaper, Storage, VPN and Background Security
  Improvements have no `en` entry: their English name is the one in `Info.plist`, which is
  right. `localizedInfoDictionary` returns nothing for them, since no table entry matches.
- Wi‑Fi names its development region `English` and has an `en` entry; treating the region as a
  separate language picks `Info.plist`'s "WiFiSettings".
- Battery and Headphones have only internal names (`PowerPreferences`,
  `HeadphoneSettingsExtension`) in every language. System Settings gets their names from the
  running extension: Battery's `Localizable.loctable` has both `BATTERY_PREF_TITLE` ("Battery")
  and `ENERGY_SAVER_PREF_TITLE` ("Energy"), chosen by hardware, and the Headphones pane shows the
  connected headphones' name. System Settings' `Sidebar.plist` lists bundle IDs only, and its
  `Localizable.loctable` has section names, not pane names.

## Decision

A pane's name is `SettingsPaneProvider.names[bundle ID]` when the table has it, else the
localized `CFBundleDisplayName` (then `CFBundleName`) as `BundleInfo` reads it: the loctable entry
for the language the user prefers, where the development region is a candidate and stands for
its canonical code ("English" is "en"), and a winning region with no entry of its own means
`Info.plist`'s values. The table holds two entries, Battery and Headphones, in English. A test
checks every pane on the build machine for an "Extension" or "Settings" suffix or a run-together
CamelCase name.

General is included by scanning the System Settings app's `PlugIns` folder as a second root, as
it is a main sidebar entry and opens by URL like the others.

## Alternatives considered

- **`Bundle.localizedInfoDictionary`** — rejected: it drops the panes whose English name is only
  in `Info.plist`, and `Bundle(url:)` caches (see 0005).
- **A table for every pane** — rejected: 50 names to keep in step with each macOS release, in
  one language.
- **Reading Battery's `BATTERY_PREF_TITLE` from its `Localizable.loctable`** — rejected for now:
  it would localize the name, but choosing it over "Energy" needs a battery check, and the key
  is private to that extension.

## Consequences

The two table names are English in every language. A new pane with an internal name shows that
name until it is added to the table; the build-machine test catches it on the next macOS. The
Headphones pane opens only while headphones are connected; opening its URL otherwise leaves
System Settings where it was.
