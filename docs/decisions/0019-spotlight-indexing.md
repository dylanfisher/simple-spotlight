# 0019. A button that turns macOS's Spotlight indexing off and on

- **Date:** 2026-11-02
- **Status:** accepted

## Context

The user asked (2026-11-02) for a settings pane that turns macOS's own Spotlight indexing off
completely, and back on, with a short note on why. This app never uses the Spotlight index: it
reads the app folders, System Settings' panes and the script folder itself. Users who replace
Spotlight with it still pay for `mds` and `mdworker` indexing every file on every disk.
Switching indexing needs root; reading it doesn't.

## Decision

- **Read** with `mdutil -s /`, which any user may run, each time the Spotlight pane shows, so a
  change made in Terminal shows. "Indexing enabled." is on; "… disabled." is off; anything else is
  an error shown under the button, with the button off until a read works.
- **Switch** with `mdutil -a -i off` (or `on`), every volume, run through `osascript -e 'do shell
  script "…" with administrator privileges'`, which shows macOS's own password prompt. Then read
  the status back, so the pane shows what macOS did. Cancelling the prompt (osascript's -128)
  changes nothing and shows no error. Both run as child processes off the main actor.
- The state lives in macOS, not in the config file: there's no key for it, since the file would
  then claim a state that `mdutil` or another app can change behind it.

## Alternatives considered

- **`mdutil -a -i off -d`**, which also turns Spotlight searching off — rejected: indexing is
  what costs CPU and disk; searching an index that isn't updated costs nothing, and Finder and
  Mail keep finding what was indexed.
- **A privileged helper (`SMAppService.daemon`)** — rejected: an installed root daemon for a
  switch used once is far more than the password prompt, which macOS already provides.
- **`NSAppleScript`** in process — rejected: it runs on the main thread and the prompt waits for
  the user; `osascript` as a child process waits off the main actor.
- **A config key** — rejected; see Decision.

## Consequences

The button needs an administrator's password each time. Spotlight, Finder search and Mail search
find no new files while indexing is off. If a future macOS changes `mdutil -s`'s wording, the pane
shows the unknown status as an error rather than guessing.
