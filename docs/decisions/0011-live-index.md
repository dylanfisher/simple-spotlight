# 0011. Live index: one rebuild per burst of changes in the watched folders

- **Date:** 2026-10-31
- **Status:** accepted

## Context

P7 asks the index to follow apps being installed, updated and removed, by watching `appFolders`
with P4's `FolderWatcher` and rebuilding through the coordinator, which already cancels a stale
build and swaps the new index in without dropping the query. A rebuild takes about 100 ms off
the main actor (B4). Installing or updating an app writes thousands of files inside its bundle
over several seconds, and a folder in `appFolders` may not exist yet.

## Decision

- **What is watched.** `IndexBuilder.watchedFolders`: the expanded `appFolders` and the two
  `.prefPane` folders, each only when its setting is on. System Settings' own panes are on the
  read-only system volume, which changes only with a macOS update, so they aren't watched. The
  coordinator starts a new watch whenever `indexKeys` change, before the rebuild they cause.
- **Bursts, not events.** Every change under a watched folder counts, including those inside
  bundles. `AppFolderMonitor` reports once a second passes without a change, or ten seconds
  after the first, whichever is first. An update that writes every few milliseconds for five
  seconds is one rebuild, run once the bundle is complete; changes that never pause rebuild at
  most every ten seconds.
- **A folder that doesn't exist yet** is watched like the others. FSEvents matches changes by
  path, so making the folder, or moving it into place, is a change; a test covers it. A missing
  folder stays an index problem (0007) until the rebuild that change causes.
- **A watch that won't start** is logged, and the index works without updates until the next
  change of the index's settings or the next launch.

## Alternatives considered

- **Ignore changes inside `.app` bundles**, reacting only to a bundle appearing or going —
  rejected: a copy creates the bundle folder first and fills it after, so the rebuild would read
  a half-written bundle and could miss the app (or report it as a problem) until something else
  changed; an update in place that renames the app would never be seen. Collapsing the bundle's
  writes into one burst costs one rebuild and needs no per-event paths from FSEvents.
- **Rebuild after each FSEvents batch** — rejected: an update would rebuild every batch for as
  long as it writes.
- **Watch the parent of a missing folder** — rejected: FSEvents already reports the folder's
  creation, and a parent watch would need retargeting as folders come and go.

## Consequences

A new app shows in results about a second after its copy finishes. A folder with constant
writes, such as a home folder listed in `appFolders`, rebuilds every ten seconds, about 1% of a
core. The quiet time and cap are constants in `AppFolderMonitor`.
