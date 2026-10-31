# 0014. Dim the rows of apps and panes not opened lately

- **Date:** 2026-10-31
- **Status:** accepted

## Context

The user asked for rows of items they haven't opened, or haven't opened in the last X days, to
look subdued, so the apps they use stand out at a glance. Usage already ranks them first
(decision 0010); this is about how a row looks, not where it goes. The plan's P11 adds
`dimUnused` (default true) and `dimAfterDays` (default 30), takes the last-opened date from the
usage store with no new storage, and asks that a keystroke not compute dates per row.

## Decision

- **What dims.** With `dimUnused` on, the row of an app or System Settings pane whose last open
  from the panel (`UsageStore.Usage.Opens.lastOpened`) is more than `dimAfterDays` days ago, or
  that has no entry, draws subdued. An open exactly `dimAfterDays` ago still counts as recent. A
  day is 24 hours, not a calendar day. Calculator answers, commands and problems never dim: they
  aren't recorded (decision 0010), so they would always be dim. `SearchItem.Kind.countsAsOpen`
  holds which kinds are recorded, for both rules.
- **The selected row never dims.** It is the one Return opens, so it reads at full strength.
- **How it looks.** The row's icon and text draw at 0.55 opacity, 0.7 with Increase Contrast.
  The selection fill isn't faded. The subtitle is already a secondary color, so at 0.55 it is
  faint but still readable on both the light and dark panel; Increase Contrast keeps it
  stronger. VoiceOver reads a dimmed row as any other.
- **When it is worked out.** `DimmedItems` holds the set of ids opened within `dimAfterDays`.
  The panel builds it with `UsageBoost`, when it shows and when usage changes while shown, and
  again when `dimUnused` or `dimAfterDays` changes while shown. A search looks each row's id up
  in the set. Building it for 2,000 entries took 0.08 ms median, 0.11 ms p95; the lookups for 20
  rows 0.0005 ms (200 runs, release build).
- **`dimAfterDays` takes 1 to 365.** The key kind is a closed range; a year is past any useful
  setting.

## Alternatives considered

- **Dim by frecency below a threshold** — rejected: the user asked for days since the last
  open, which is easier to set and to predict than a decayed count.
- **Compare the date per row per keystroke** — rejected by the plan; the set lookup is the
  same result for the time the panel shows.
- **A new store of last-opened dates** — rejected: `usage.json` already keeps one per item.
- **Dim the selected row too** — rejected: the row about to open should be the easiest to read.

## Consequences

Loading usage forgets entries whose frecency fell below `UsageStore.forgetBelow` (decision
0010): an item opened once is forgotten about 84 days later, one opened more often later. A
forgotten item dims like one never opened, so with `dimAfterDays` above 84 an item opened once
dims at the next launch after 84 days rather than after `dimAfterDays`.

On a fresh install with no usage every app and pane dims until it is opened from the panel.
