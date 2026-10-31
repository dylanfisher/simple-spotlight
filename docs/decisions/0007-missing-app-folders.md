# 0007. A missing app folder is an index problem, not a config error

- **Date:** 2026-10-31
- **Status:** accepted

## Context

The plan's Config table says a missing folder in `appFolders`, other than `~/Applications`, is a
config error naming it. P3 already reports each missing folder as an `IndexProblem` when the
index is built (0005), since a folder can disappear after the config file is read, as an
external drive's does when it is ejected. Checking in both places would show the user two
messages for one folder, and a config error makes the whole file set nothing.

## Decision

The index owns it. `ConfigFile` checks only that each entry is a full path or starts with `~/`;
it never looks at the disk. `AppProvider` reports a missing folder as an `IndexProblem` with its
path ("…: It doesn't exist.") at every build, and skips a missing `~/Applications`
(`AppProvider.userApplications`) silently. P6 shows the build's problems in the panel's error
row beside the config errors.

## Alternatives considered

- **A config error, as the plan says** — rejected: ejecting a drive named in `appFolders` would
  make the next read of the file refuse it whole, putting the hotkey and every other key back to
  their last good values over a folder that only affects the index. The parse would also depend
  on the disk, and the error would go stale when the folder came back without the file changing.
- **Both** — rejected: two messages for one cause.

## Consequences

The message appears at the next build rather than at the next save of the file, and it tracks
the folder: it goes away once the folder is back and the index is rebuilt (P7 rebuilds on
folder changes).
