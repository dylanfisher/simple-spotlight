# 0003. Calculator: a hand-written grammar, not NSExpression

- **Date:** 2026-10-31
- **Status:** accepted

## Context

Every keystroke runs the calculator on the query, so it sees app names, partial expressions and
anything pasted into the field. It must reject most of that quickly and never crash, and show a
row only for queries that are clearly arithmetic: "2+2" and "sqrt 16" yes, "1password", "2048",
"3d" and "safari" no.

## Decision

A hand-written tokenizer and recursive-descent parser, `Base.Expression`. Its doc comment states
the grammar, what counts as a calculation, the separator rule and the noise rule; its
`maximumDepth` bounds nesting. `Base.NumberText` formats the answer, and `CalculatorProvider`
gives every row the fixed id `itemID` so usage keeps one entry for the calculator. The choices a
reader might question:

- **"1-password" gives no row.** It has an operator, but any word that isn't a constant, a
  function or `mod` is an error. That one rule is what rules out "1password", "3d" and "safari",
  with no special case for hyphens; a launcher query with a hyphen is far more often a name than
  a sum.
- **`mod` takes the divisor's sign** (`-7 mod 3` is 2), as in mathematics and spreadsheets,
  rather than the dividend's, as Swift's `truncatingRemainder` does.
- **Trigonometry is in radians**, as in every programming language; no one types degrees into a
  launcher often enough to make it the default.
- **Rounding noise is 0.** `sin pi` is 1.2e-16 and `1-0.9-0.1` is -2.8e-17 in Double, which would
  show as noise. A sum, difference, `sin`, `cos` or `tan` below 1e-12 times its largest operand
  snaps to 0. The rule applies per step and relative to that step's operands, so `1e-20*1` and
  `sin 1e-20` keep their value; products, quotients and powers don't cancel, so they are left
  alone. `tan(pi/2)` stays a large number, since it isn't small.
- **Exponents are read** (`1.5E21`), so a copied scientific answer pastes back. An exponent
  needs a digit after `e`, so `2e` is still 2 followed by the constant `e`, an error with no
  implicit multiplication. A bare literal like "1e3" is a bare number and gives no row.

## Alternatives considered

- **NSExpression** — rejected: it raises Objective-C exceptions on malformed input ("2+",
  "(1"), which Swift can't catch, so a half-typed expression would crash the app. It also
  evaluates names as key paths, has its own function syntax (`sqrt:`), and can't tell a bare
  number from a calculation.
- **A Pratt parser or an operator-precedence table** — rejected: the grammar has six levels and
  no user-defined operators; one method per level reads more directly.
- **Snapping relative to the largest magnitude in the whole evaluation** — rejected: `1e-20*1`
  would become 0, though nothing cancelled.

## Consequences

The query must use `.` for decimals in every locale; the title shows the locale's separators.
Adding an operator or function means a token and a line in the grammar and its doc comment.
