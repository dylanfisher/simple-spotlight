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

- **What is watched** is `IndexBuilder.watchedFolders`, so the watch and the build read one list.
  System Settings' own panes are on the read-only system volume, which changes only with a macOS
  update, so they aren't watched.
- **Bursts, not events.** Every change under a watched folder counts, including those inside
  bundles, and `AppFolderMonitor` reports once per burst: after `quiet` without a change, or
  `longest` after the first, whichever is first. An update writing for several seconds is one
  rebuild, run once the bundle is complete, and changes that never pause still rebuild now and
  then.
- **A folder that doesn't exist yet** is watched like the others. FSEvents matches changes by
  path, so making the folder, or moving it into place, is a change; a test covers it. A missing
  folder stays an index problem (0007) until the rebuild that change causes.
- **A watch that won't start** is logged, and the index works without updates until the next
  change of the index's settings or the next launch. With no folders to watch, no watch starts.

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

A new app shows in results about a second after its copy finishes. Measured with a release
bundle: copying a 393-file app into a watched folder, writing 600 files inside it over 5 s, and
deleting it each caused one rebuild. A folder with constant writes, such as a home folder listed
in `appFolders`, rebuilds once per `longest`: about 1% of a core when it was ten seconds.
