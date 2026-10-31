# 0003. Calculator: a hand-written grammar, not NSExpression

- **Date:** 2026-10-31
- **Status:** accepted

## Context

Every keystroke runs the calculator on the query, so it sees app names, partial expressions and
anything pasted into the field. It must reject most of that quickly and never crash, and it must
show a row only for queries that are clearly arithmetic: "2+2" and "sqrt 16" yes, "1password",
"2048", "3d" and "safari" no. The plan fixes the operators, constants and functions, and asks for
answers rounded to 10 significant digits, grouped on screen but not on the clipboard.

## Decision

- **Hand-written tokenizer and recursive-descent parser** (`Base.Expression`), evaluating as it
  parses and returning a `Double` or a typed error. Its doc comment holds the grammar; it is the
  one statement of it.
- **What counts as a calculation:** text that tokenizes and parses in full and applies at least
  one binary operator, `%` or a function. A sign is not an operator, so "-5", "(5)", "pi" and
  "-pi" are bare values and give no row; "-5+1", "10%" and "pi*2" do. Any word that isn't `pi`,
  `e`, `mod` or a function name is an error, which is what rules out "1password", "3d" and
  "safari": there are no variables and no implicit multiplication.
- **"1-password" gives no row.** It has an operator, but "password" is not a name, and treating
  unknown words as errors keeps the rule to one sentence. A launcher query with a hyphen is far
  more often a name than a sum.
- **Function arguments:** a function followed by `(` takes only the parenthesized group, so
  `sqrt(16)^2` is 16; without `(` it takes the following unary expression, so `sqrt 2^4` is 4 and
  `sqrt 16 + 1` is 5, the usual reading of "sin x^2".
- **Smaller choices:** `-2^2` is -4 (power binds tighter than a sign); `mod` takes the divisor's
  sign (`-7 mod 3` is 2, as in mathematics and spreadsheets); `%` is only postfix percent, so
  `200 + 10%` is 200.1; trigonometry is in radians and `log` is base 10. A `,` is accepted only
  as a thousands separator (1–3 digits before the first, exactly 3 after each), in every locale,
  so "1,2" is an error rather than 12.
- **Depth limit:** the parser recurses once per nesting level, so nesting past 100 levels is an
  error. A pasted run of thousands of `(` otherwise overflows the stack (a test checks this).
- **Formatting** (`Base.NumberText`): one `FloatingPointFormatStyle`, 10 significant digits,
  rendered twice: with the user's locale for the title ("1.234,5" in German) and with
  `en_US_POSIX` and no grouping for the copied text ("1234.5"). Below 1e-6 and from 1e21 up it
  switches to scientific notation ("1.5E21"), JavaScript's thresholds, which the plan's examples
  follow. -0 shows as 0.
- **Stable id:** every calculator row has the id `calculator`, so P7's usage store keeps one
  entry for the calculator, not one per expression.

## Alternatives considered

- **NSExpression** — rejected: it raises Objective-C exceptions on malformed input ("2+",
  "(1"), which Swift can't catch, so a half-typed expression would crash the app. It also
  evaluates names as key paths and has its own function syntax (`sqrt:`), and gives no way to
  tell a bare number from a calculation.
- **A Pratt parser or an operator-precedence table** — rejected: the grammar has six levels and
  no user-defined operators; one method per level reads more directly.
- **Unknown words as "not a calculation" only when no operator is present** — rejected: it would
  make "1-password" an error anyway (the word has no value), so the rule gains nothing.
- **Formatting digits by hand from `%.9e`** — rejected: the locale's grouping isn't always in
  threes (Indian "12,34,567"), which the format style already handles.

## Consequences

Adding an operator or function means a token and a line in the grammar and its doc comment.
Locale-aware input (a `,` decimal separator) is not supported; the title shows the locale's
separators, but the query must use `.` for decimals. The scientific form uses `E`, which pastes
back into most programs but not into this calculator, which doesn't read exponents.
