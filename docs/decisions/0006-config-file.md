# 0006. The config file follows Searcher's; the app writes it only to make the default file

- **Date:** 2026-10-31
- **Status:** accepted; amended by [0015](0015-settings-window.md) (the settings window writes
  changes into the file)

## Context

The plan puts every setting in `~/.config/simple-spotlight/config.json` and points at Searcher's
config design (its decisions 0123, 0126 and 0130, and `ConfigText`, `ConfigFile`, `ConfigStore`
and `Settings`). Searcher writes the file from its settings window, so most of its config code
is about writing: patches, a write queue, retries, a byte check before each rename, a chosen
location and symbolic links written through. Simple Spotlight has no settings window, and the
plan says the app writes the file only to create the default one.

## Decision

- **Kept from Searcher.** JSON with `//` and `/* */` comments and trailing commas, blanked byte
  for byte by `Base.ConfigText` so offsets and lines stay the file's own. An unknown key is an
  error, not ignored. A key given twice is an error on the second's line. A file with any error
  sets nothing: the last good settings stay, the defaults at launch. Errors are
  `ConfigError`s, a line and a reason that names the key (`ConfigError.description`). The
  default file has a comment above each key: what it does, then "Takes …", the words its error
  uses (`Settings.Key.comment`). The folder is watched with FSEvents, not the file, since an
  atomic save replaces the file. A read that finds the file gone or empty is believed only after
  a second read `ConfigStore.confirmDelay` later, so a save in place or a sync tool's delete and
  create doesn't flash an error, reset the settings or get overwritten by the default file.
- **Each key is declared once**, in `Settings.Keys`: the property it sets, its name in the file,
  its kind (what it takes, how it is read and written), its default and a one-sentence summary.
  `Settings`' stored properties take their defaults from there. `ConfigFile.parse`, the default
  file and the tests read `Settings.Keys.all`; `everyPropertyHasAKey` fails when a stored
  property is missing from it.
- **Every key error has a line.** Searcher gives a line only to syntax errors and duplicates.
  Here a scan of the parsed text finds each top-level key's line, so a wrong type or an
  out-of-range value is reported where it is, as the plan asks. Lines end at `\n`, `\r\n` or a
  lone `\r` (`ConfigText.isLineBreak`).
- **Limits.** A file over `ConfigFile.largestSize` is refused without being read whole, and at
  most `ConfigFile.mostErrors` errors are reported, the last counting the rest, so a pasted file
  can't hold up the store or bury the first error.
- **The app writes the default file**, and only where there is no file or the file is
  whitespace only (an empty file only once a second read confirms it): at launch, and from
  `ConfigStore.makeDefaultFileIfMissing()`, which the config error row and the settings
  window's "Open config.json" button use before opening the file. Changes from the settings
  window are the only other write ([0015](0015-settings-window.md)). The text goes to a file
  beside its destination and is renamed into place; with no file there the rename is
  `RENAME_EXCL`, so a file an editor saves meanwhile is kept. A file that is gone once
  confirmed means the defaults, and nothing is written until the next launch, the next time the
  file is opened, or the next change in the settings window. An emptied file, once confirmed,
  is an error ("is empty"), since the user is editing it.
- **Symbolic links, as dotfiles kept elsewhere are.** A link at the file's path is read through,
  and the folder of the file it leads to is watched as well as the store's own, worked out again
  at each read, so retargeting the link is followed. The default file is written through to the
  link's target, which stays a link; a link to nothing is an error and nothing is written.
- **Cut from Searcher:** patches and the write queue, retries, the quit flush, `UserDefaults`
  (there are no in-app preferences) and a chosen location.
- **Problems with the file itself are errors in the published state**, beside the file's own:
  one that can't be read or created, and a folder that can't be watched. Each says what happens
  instead ("isn't watched, so a change applies at the next launch").
- **`KeyChord` holds Carbon's values as plain integers**: `Modifiers.rawValue` is Carbon's
  modifier mask and `Key.code` its `kVK_` code, so Interface hands them to
  `RegisterEventHotKey` unchanged and Search imports no Carbon. The test target imports Carbon
  and checks every code and mask against its constant. Names are read in any case and modifiers
  in any order; they are written in `KeyChord.Modifiers.named`'s order. Shift alone is refused
  except with an F-key, since it would take a key away from typing.
- **`excludedApps` applies to every item id**, apps' and panes' bundle IDs, through
  `IndexBuilder.excludedIDs`.

## Alternatives considered

- **Searcher's `ConfigStore` as it is** — rejected: nearly all of it serves in-app writes, which
  this app doesn't make.
- **`JSONSerialization`'s `.json5Allowed`** — rejected, as Searcher did: it takes unquoted keys,
  single quotes and hex numbers too, and its errors still carry no key line.
- **Writing the default file again whenever the file is deleted** — rejected: a sync tool's
  delete and create could race it, and a deletion meaning "use the defaults" is what Searcher's
  users already have.

## Consequences

Launch reads one small file on the store's actor and writes it only on the first launch. A key
added later is a stored property, its declaration in `Settings.Keys` and an entry in
`Settings.Keys.all`; the file, its comment and its errors follow from those.
