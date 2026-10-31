# 0010. Usage ranking: frecency that lifts a match one kind at most

- **Date:** 2026-10-31
- **Status:** accepted

## Context

The plan ranks matches by kind (exact prefix, word-start prefix, initials, subsequence) and lets
usage break ties and "lift a weaker match class by at most one level, never a non-match", with a
two-week half-life. Decision 0002 put that lift in `SearchIndex`'s ordering and kept the matcher
free of usage. The order is a sort comparator, so it must stay a strict weak order: a pairwise
rule such as "a used item beats a better kind when it was used much more" isn't transitive.

## Decision

- **Frecency.** Each open counts 1 and halves every `UsageBoost.halfLife`, chosen at two weeks.
  The file stores, per item id, the count as of the last open with older opens already decayed,
  and the last-opened date: two numbers that give the exact sum over every open. `UsageBoost`
  works the frecencies out when the panel shows; a keystroke looks them up and never touches the
  actor or the disk.
- **Lift as a level.** An item whose frecency reaches `UsageBoost.liftingFrecency` (3 at the
  time: a few opens in a day) is lifted, and its level is its kind plus one. Ranking by level
  turns "lift by one kind at most" into a key each item has on its own, which keeps the
  comparator a strict weak order; `SearchIndex.precedes` gives the full order. A lifted item
  passes the unlifted matches one kind better and never a kind two better, and only matches are
  ranked, so usage can't make a non-match appear.
- **What counts as an open.** An app or System Settings pane opened from the panel, at the time
  the open is asked of the workspace. Calculator answers, problem rows and the built-in commands
  aren't recorded: a used "Quit Simple Spotlight" would rise above "QuickTime Player" for "q".
  Revealing in Finder isn't an open of the item. A launch that fails afterwards still counts;
  the workspace reports that later, and it is rare.
- **Pruning by decay.** Loading drops entries whose frecency is below `UsageStore.forgetBelow`,
  chosen as one open six half-lives ago. That bounds the file to what was opened lately,
  including ids of deleted apps, without the store knowing the index.
- **Writes.** `UsageStore` is an actor that writes a burst of opens once, after
  `UsageStore.writeDelay`, and the app writes what is left before it quits.

## Alternatives considered

- **Frecency added to the score**, so enough use crosses any number of kinds — rejected: the plan
  limits the lift to one kind.
- **Pairwise lift** (a weaker kind wins when its frecency exceeds the other's by a margin) —
  rejected: not transitive, so the top-k insertion could order results inconsistently.
- **Lifted items ranked by frecency against the kind above** — rejected: within a level, the
  unlifted items are below the threshold and the lifted ones at or above it, so frecency would
  give the same order there, but it would also put frecency before quality among unlifted
  subsequences, which decision 0002 rules out.
- **`count × decay(last open)` with a raw count** — rejected: a hundred opens a year ago and one
  today would rank as 101 opens.
- **Pruning ids missing from the index** — rejected: an app on an ejected drive would lose its
  history while the drive is out.

## Consequences

A few opens in a day move an app above an unused better match, and the lift wears off after a
few weeks without use. If it feels too eager or too slow, change the constants in `UsageBoost`.
Per keystroke, usage costs a dictionary
lookup per matching item: for 2,000 items, a one-letter query that matches all of them went from
0.15 ms to 0.23 ms (median of 200 runs, release build).
