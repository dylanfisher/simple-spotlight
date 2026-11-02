# 0010. Usage ranking: picks learned per query, and frecency that lifts a match one kind at most

- **Date:** 2026-10-31
- **Status:** accepted

## Context

The plan ranks matches by kind (exact prefix, word-start prefix, initials, subsequence) and lets
usage break ties and "lift a weaker match class by at most one level, never a non-match", with a
two-week half-life. Decision 0002 put that lift in `SearchIndex`'s ordering and kept the matcher
free of usage. The order is a sort comparator, so it must stay a strict weak order: a pairwise
rule such as "a used item beats a better kind when it was used much more" isn't transitive.

After first use the user asked for more: typing "c" and opening Chrome should put Chrome first
for "c" the next time, over Chess, after one pick. Frecency alone can't do that: one open breaks
ties within a kind, and Chess is a better kind of match for "c" than "Google Chrome".

## Decision

- **Learned picks.** With each open, the store keeps the query it was opened from, as
  `UsageStore.Usage.queryKey` gives it (trimmed, folded as the matcher folds names, cut to
  `UsageStore.queryLength` characters), and that query's own count and last-opened date. An item
  is learned for the current query q when it was picked for a q′ that starts with q (q′ may equal
  q): the user typed at least this much on the way to the pick. A pick for "chr" counts for "c",
  "ch" and "chr", and one for "c" only for "c". Learned matches rank above every other match, by
  the summed frecency of those picks, then in the order below. Only matches are ranked, so a pick
  never makes a non-match appear. The sum is worked out once per keystroke
  (`UsageBoost.learned(for:)`), so each item has one key per query and the comparator stays a
  strict weak order.
- **Frecency.** Each open counts 1 and halves every `UsageBoost.halfLife`, chosen at two weeks.
  The file stores, per item id, the count as of the last open with older opens already decayed,
  and the last-opened date: two numbers that give the exact sum over every open. Each query an
  item was opened from keeps the same two numbers. `UsageBoost` works the frecencies out when the
  panel shows; a keystroke looks them up and never touches the actor or the disk.
- **Lift as a level.** Below the learned matches, an item whose frecency reaches
  `UsageBoost.liftingFrecency` (3: a few opens in a day) is lifted, and its level is its kind plus
  one. Ranking by level turns "lift by one kind at most" into a key each item has on its own,
  which keeps the comparator a strict weak order; `SearchIndex.precedes` gives the full order. A
  lifted item passes the unlifted matches one kind better and never a kind two better, and only
  matches are ranked, so usage can't make a non-match appear.
- **What counts as an open.** An app, System Settings pane or script command opened from the
  panel, at the time the open or run is asked for. Scripts are things the user picks by name,
  as apps are, so a used one should rise. Calculator answers, problem rows and the built-in commands
  aren't recorded: a used "Quit Simple Spotlight" would rise above "QuickTime Player" for "q".
  Revealing in Finder isn't an open of the item. A launch that fails afterwards still counts;
  the workspace reports that later, and it is rare.
- **The lift stays at 3.** Learned picks now cover the queries the user has typed before, and
  any query a past one starts or extends. The lift is left for the rest, such as "fari" after
  picks for "saf", where usage that isn't tied to the query should move an item only on
  repeated use, and only by one kind. Lowering it would let one open from an unrelated query
  pass better matches; raising it would make it rarely matter. Neither had a case for it.
- **Pruning by decay and by count.** Loading drops entries whose frecency is below
  `UsageStore.forgetBelow`, chosen as one open six half-lives ago, and the queries of the
  entries kept that are below it too. That bounds the file to what was opened lately, including
  ids of deleted apps, without the store knowing the index. Each item keeps at most
  `UsageStore.queriesPerItem` (8) queries; recording a ninth drops the one with the lowest
  frecency.
- **One shape.** Adding the queries changed the file's shape. Per the pre-release rule, a file
  of the old shape doesn't decode and is discarded, as any file that doesn't decode is.
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
- **Only an exact query is learned** — rejected: typing "c" after a pick for "chr" wouldn't find
  the pick, and people don't type a name the same way every time.
- **A pick also counts for longer queries** (q′ a prefix of q) — rejected: a pick of Activity
  Monitor for "a" would outrank Acrobat, the exact prefix, for "acr".
- **Learned picks as one more level of lift** — rejected: the user asked for the picked item
  first, and a lift capped at one kind wouldn't pass Chess's exact prefix.

## Consequences

A pick for a long query reaches the shorter ones it starts with: Chrome picked for "chr" is
first for "c" too, over Chess, until another item is picked for "c" more. A pick for a short
query reaches nothing longer, so someone who types "c" and picks Chrome gets Chrome first for
"c" only, and has to pick it again from "ch".

A few opens in a day move an app above an unused better match, and the lift wears off after a
few weeks without use. If it feels too eager or too slow, change the constants in `UsageBoost`.
Per keystroke, usage costs a dictionary
lookup per matching item: for 2,000 items, a one-letter query that matches all of them went from
0.15 ms to 0.23 ms (median of 200 runs, release build). With learned picks, a keystroke also
compares the query with every pick: for 2,000 items, 200 of them picked from 8 queries each,
the slowest query measured took 0.22 ms median and 0.24 ms p95 (200 runs, release build),
against 0.14 and 0.16 ms with no usage.
