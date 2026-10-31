# Agent rules for orchestrated builds

How an orchestrating session hands a plan step to a builder agent and to reviewers. Read
AGENTS.md first; these rules add to it.

## Builders

1. Work in the main checkout on `main`. Builders run one at a time, so there is no worktree or
   branch. Confirm `git status` is clean and note the sha you start from.
2. Read the step in `tmp/plan.md`, the neighbors `docs/map.md` names, and any Searcher file the
   step points at, before writing code.
3. Write the test first and see it fail, then make it pass. New behavior needs a test that fails
   without the change.
4. Iterate with `./scripts/test --filter <name>`. At the end run `./scripts/format`, then
   `./scripts/check`, which must pass. Never call `swift build` or `swift test` directly.
5. No new dependencies. No file-system I/O on the main actor. No TODOs.
6. Tests don't wait on real time. Use an injected clock, a stub, or a condition to wait for, not
   a sleep. When only real time will do (FSEvents latency), wait for the end state with a bounded
   poll and say so in your report.
7. Tests never touch `~/.config/simple-spotlight`, `~/Library/Application Support/simple-spotlight`
   or the user's defaults, and never show a window on screen or take focus.
8. Never write to `tmp/`; it is the orchestrator's. Scratch files go in your session's scratchpad.
9. Don't run `./scripts/dev`; the orchestrator launches the app.
10. Commit on `main`, following docs/writing.md, with no Claude or Anthropic attribution. One
    logical change per commit. Never push.
11. Report the commit sha(s), what changed, the tests added and how each failed before the
    change, the gate result, judgement calls, and anything to check by hand.

## When to review

Reviewer agents run only after a **large change**: a step that adds a feature or subsystem, a
new config key or stored data shape, concurrency or window handling, or a diff over about
300 lines or across more than one tier. For a large change, run three reviewers in parallel on
its commits: DRY/SSOT, code audit, and performance (what each covers is in `tmp/plan.md`, under
"After each step"). Fix the findings that hold up in a follow-up commit before the next step.

Everything else gets no reviewer agents: a fix round after a review, a small feature or tweak,
a visual adjustment, or docs. The orchestrator reads the diff itself and checks that the gate
passed. A fix round never triggers another review.

## Reviewers

1. Read-only: write no product code and commit nothing. Review the commits the orchestrator
   names (`git diff <base>..HEAD`) and the code they touch.
2. Report each finding with file:line, the problem, a concrete failure scenario, its severity,
   and whether it should block. Keep nits apart from real findings. Say "no findings" when there
   are none rather than padding.
