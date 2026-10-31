# simple-spotlight

A minimal, fast Spotlight replacement for macOS: apps, System Settings, and a calculator, behind
⌘Space.

Requires macOS 15 or later.

## Use it

To take over ⌘Space, turn off Spotlight's shortcut first: System Settings → Keyboard → Keyboard
Shortcuts → Spotlight → uncheck "Show Spotlight search". The shortcut and what gets indexed are
set in `~/.config/simple-spotlight/config.json`.

## Develop

Needs Swift 6.2 or later (Command Line Tools or Xcode).

| Task | Command |
|---|---|
| Bootstrap, install the commit hook | `./scripts/setup` |
| Run the app | `./scripts/dev` |
| Run tests | `./scripts/test` |
| Fix formatting | `./scripts/format` |
| Full gate — format, build, tier rules, bundle, tests | `./scripts/check` |

## Layout

| Path | Purpose |
|---|---|
| `Package.swift` | Targets and their dependencies — the tier map. |
| `Sources/` | One directory per target: Base, Search, Interface, SimpleSpotlight. See [docs/map.md](docs/map.md). |
| `Tests/` | Mirrors `Sources/`. |
| `AGENTS.md` | Instructions for AI coding agents. |
| `docs/performance.md` | Speed and memory budgets. |
| `docs/principles.md` | Rationale behind the rules in AGENTS.md. |
| `docs/writing.md` | Comment voice and commit format. |
| `docs/decisions/` | Why things are the way they are. |

## License

MIT — see [LICENSE](LICENSE).
