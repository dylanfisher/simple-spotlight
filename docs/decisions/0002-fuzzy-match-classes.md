# 0002. Fuzzy match: four match kinds, not Searcher's scored alignment

- **Date:** 2026-10-31
- **Status:** accepted

## Context

The panel ranks a few hundred apps and System Settings panes on every keystroke, within B2's
16 ms. The plan fixes the order: exact prefix of the name, then a prefix of a later word ("code" →
"Visual Studio Code"), then initials ("vsc"), then any subsequence, with tie rules after the
kinds. Searcher solved fuzzy matching for its palette
(`~/projects/searcher/docs/decisions/0079-fuzzy-match.md`) with a dynamic program that sums
per-letter bonuses and penalties into one score. That suits 50k paths with no fixed order of
kinds, but in it the plan's kinds are only tendencies: a two-letter initials chain beats a prefix,
and a prefix needs three letters to win.

## Decision

- **Kinds first.** `FuzzyMatch.Query.score` classifies a match into one of the four kinds,
  tried best first, and stops at the first that holds. Word starts follow Searcher's (the start
  of the text, after a space or punctuation, a capital after a lowercase letter), plus the end of
  an acronym and letter-digit boundaries, so "VPNClient", "Time2Go" and "Office365" can match by
  word. `FoldedText`'s doc comment is the one statement of the rule.
- **Quality orders subsequences only.** Within a subsequence, letters that run together and
  letters at word starts score higher, runs more than word starts, so "code" ranks "Xcode" above
  "Color Draw Editor". The other kinds have no quality, so the plan's tie rules decide among them.
  Quality ranks before usage: two subsequences of very different quality aren't a tie.
  `FuzzyMatch.Score` holds the weights and `SearchIndex.precedes` the full order.
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
  Whitespace around the query is dropped, so a query of only spaces is empty and a trailing space
  doesn't stop a match.

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

P7's usage boost enters through the index's ranking, which takes usage from its caller. Lifting a
weaker kind by one level, as P7 asks, belongs in that ordering; the matcher stays free of usage. Camel-case and acronym word starts are found in non-ASCII names too,
through `Character` case properties, and a test keeps the ASCII and general paths in agreement.
