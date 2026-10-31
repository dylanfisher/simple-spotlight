# 0002. Fuzzy match: four match kinds, not Searcher's scored alignment

- **Date:** 2026-10-31
- **Status:** accepted

## Context

The panel ranks a few hundred apps and System Settings panes on every keystroke, within B2's
16 ms. The plan fixes the order: exact prefix of the name, then a prefix of a later word ("code" →
"Visual Studio Code"), then initials ("vsc"), then any subsequence; ties go to usage (P7), then
the shorter name, then alphabetical. Searcher solved fuzzy matching for its palette
(`~/projects/searcher/docs/decisions/0079-fuzzy-match.md`) with a dynamic program that sums
per-letter bonuses and penalties into one score. That suits 50k paths with no fixed order of
kinds, but in it the plan's kinds are only tendencies: a two-letter initials chain beats a prefix,
and a prefix needs three letters to win.

## Decision

- **Kinds first.** `FuzzyMatch.Query.score` classifies a match into one of the four kinds,
  tried best first, and stops at the first that holds. Word starts follow Searcher: the start of
  the text, after a space or punctuation, and a capital after a lowercase letter.
- **Quality orders subsequences only.** Within a subsequence, each letter that runs on from the
  one before scores 2 and each letter at a word start scores 1, over the leftmost placement.
  Runs count more so "code" ranks "Xcode" above "Color Draw Editor". The other kinds score 0, so
  the plan's tie rules decide among them. Quality ranks before usage: two subsequences of very
  different quality aren't a tie.
- **Leftmost placement, no alignment search.** The subsequence and initials checks each take the
  earliest position for each letter. That finds a match whenever one exists; it can miss a
  better-scoring placement of a subsequence ("ab" in "xab-ab"), which only shifts quality.
- **Folding.** ASCII lowercases byte by byte; other text uses Foundation's case, diacritic and
  width folding, a character at a time so ranges map back to the original characters. Searcher
  keeps letters such as й apart from и to match its sort order; this app has no sort order to
  match, so it folds all diacritics, as the plan asks.
- **Kept from Searcher:** matching on folded UTF-8 bytes with a character's bytes kept together,
  the per-byte origin map for ranges, top-k by binary insertion, and ranges built only for the
  rows returned.
- **An empty query matches nothing**, so the panel shows no rows until something is typed.

## Alternatives considered

- **Port Searcher's `FuzzyMatcher` as is** — rejected: its scores don't keep the plan's kinds in
  order ("gh" ranks "GitHub" above "ghost" by design), and its two DP tables are more code than a
  few hundred names need.
- **Searcher's DP score inside each kind** — rejected for now: it would pick the best placement of
  a subsequence, but within the top three kinds the plan's ties already decide, and the
  subsequence kind is rare among the rows shown. Revisit if subsequence rows rank badly.
- **Usage before quality** — rejected: a scattered subsequence opened once would rank above a
  contiguous one, where the plan only lets usage break ties.

## Consequences

P7's usage boost plugs into `SearchIndex.results(for:limit:usage:)`, which currently orders only
equal scores by it. Lifting a weaker kind by one level, as P7 asks, means comparing kinds with the
boost applied there. Camel-case word starts are found in non-ASCII names too, through `Character`
case properties.
