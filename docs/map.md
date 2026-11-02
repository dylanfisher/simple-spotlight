# Code map

Where things live, and how to find one before you build a second. Read this before creating any
new file.

This file describes **shape, not contents** — conventions and search commands, never an inventory.
An inventory would be a second copy of facts the code already holds, it would rot within a week,
and it would have no error message when it diverged. If you catch yourself listing what exists
here, stop: the grep is the list.

## Find before you create

The single rule that matters. AGENTS.md principles 1–3 (single source of truth, match the
surrounding code, DRY on the third occurrence) all depend on it — none of them can be followed
against a codebase you haven't searched.

| Before adding… | Run |
|---|---|
| any named thing | `rg -i '<name>' --type swift` |
| a building block | `ls Sources/Base/` |
| a result type, provider or ranking rule | `ls Sources/Search/` |
| a view, window or controller | `ls Sources/Interface/` |
| a free function | `rg '^\s*(public )?func ' Sources/Base/` |
| a file or folder path | `rg 'HomePath.folder\|fileURLWithPath: "/' Sources/Search/` — paths are built in Search, `~` through `HomePath` |
| a preference or config key | `rg '<key>' Sources/Search/Settings.swift` — every key is declared there, in `Settings.Keys` |
| a type | `rg '(struct\|class\|enum\|protocol\|actor) <Name>\b'` |

If a search turns up something close but not identical, that's the second occurrence. Use it or
duplicate it — do not abstract yet (principle 3).

## Tiers

| Tier | Path | What belongs here | May import from |
|---|---|---|---|
| **base** | `Sources/Base` | Domain-free building blocks: text folding and matching, expression evaluation and number formatting, config text scanning. Foundation only; no AppKit. Portable as-is. | nothing |
| **search** | `Sources/Search` | The model: result types, the providers (apps, System Settings panes, calculator, built-in commands, the user's script commands), ranking with usage, the config file (`Settings` declares its keys and holds their values; `ConfigFile` parses it; `ConfigStore` reads and watches it), the files the app writes for itself (`…Store` actors), and folder watching. No AppKit, so it's testable without a window. | base |
| **interface** | `Sources/Interface` | The search panel, its SwiftUI views and icons, the global hotkey and its conflict alert, the login item, launching results, and the coordinator that applies each config state. | search, base |
| **app** | `Sources/SimpleSpotlight` | The executable: app delegate and wiring. Kept thin. | everything |

**Dependency direction is one-way: app → interface → search → base.** Never upward.

Each tier is a SwiftPM target, so `Package.swift` is the dependency map. The build rejects an
import of any target that isn't a declared dependency, and because the tiers form a chain, an
upward dependency is a cycle, which SwiftPM refuses. `scripts/arch` covers the rule the compiler
can't see: no AppKit, SwiftUI, Cocoa or Carbon import in Base or Search. Each rule has a file in
`scripts/arch-fixtures/` that breaks it, and the script fails if a rule stops catching its
fixture. A new rule gets a fixture in the same change.

## Naming

- One thing per file; the filename is the thing's name.
- File names singular, after the type they hold: `AppProvider.swift`, not `Providers.swift`.
- Tests mirror the tree: `Sources/Search/AppProvider.swift` →
  `Tests/SearchTests/AppProviderTests.swift`.
- AppKit subclasses keep their AppKit suffix: `…Panel`, `…WindowController`, `…View`.

## Promotion

Things move up a tier deliberately, never by accident:

- **Third occurrence** → extract to the lowest tier that all three callers can reach (principle 3).
- **Search type loses its project knowledge** → it belongs in Base; move it down.
- **Base type grows a domain type or a `Settings` read** → it belongs in Search; move it up.

A promotion is its own commit, separate from whatever work revealed it (principle 4).

<!-- paths: Sources/Base Sources/Search Sources/Interface Sources/SimpleSpotlight -->
<!-- ↑ scripts/check verifies every path above exists. Keep it in sync with the Tiers table;
     a rename that misses this line fails the gate, which is the point. -->
