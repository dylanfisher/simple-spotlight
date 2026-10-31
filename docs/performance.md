# Performance

A launcher is only worth using if it is faster than reaching for the mouse. These are the
budgets every change is measured against. The budget is the p95 of the runs, on a release build.

| ID | Interaction | Budget |
|---|---|---|
| B1 | Hotkey pressed → panel visible with the field focused | 50 ms |
| B2 | Keystroke → results list updated | 16 ms |
| B3 | Cold launch → hotkey ready | 300 ms |
| B4 | Full index build (apps and System Settings panes) | 200 ms, off the main thread |
| B5 | Resident memory, idle, panel hidden | 40 MB |

The index is built at launch and kept in memory; a keystroke searches it and never touches the
disk. A change to an app folder updates the index in the background.

## Measurement

Search and ranking (B2's model part) and the index build (B4) are timed by tests in
`Tests/SearchTests` with loose bounds (about 5× the budget) so they catch a regression without
flaking under load. B1, B3 and B5 are checked by hand at each phase's end with `./scripts/dev -c
release`, Instruments if needed, and the numbers recorded in the phase's commit body.
