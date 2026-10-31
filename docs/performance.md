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

Run the release bundle with a temporary home, so the real config, usage and state files are
never touched, and a config in it whose `hotkey` no other app holds, so no conflict alert shows:

```
./scripts/bundle -c release
open --env CFFIXED_USER_HOME=<temp>/home .build/SimpleSpotlight.app
log stream --level debug --predicate 'subsystem == "<bundle ID>"'
```

- **B1:** each show logs a debug line, `show <n>: <ms> ms`. It measures from the hotkey handler,
  or a second launch, calling show to the commit of the Core Animation transaction that puts
  the panel on screen, key, with the field taking the keys. The pixels reach the display one
  refresh later (8–16 ms). Posting the hotkey from a script needs the Accessibility permission,
  so a second `open` of the running app drives it; bringing another app forward hides the panel
  between shows. Report the first show apart from the rest.
- **B2:** the model part (search, ranking and the calculator) is timed by serialized tests in
  `Tests/SearchTests` with bounds about 5× the budget. The path through the panel is timed with
  a throwaway test that puts text in the field's editor and lays out the rows, on the real index;
  it leaves out drawing.
- **B3:** from `open` to the `hotkey … registered` log line, and from the app's first log line,
  `launched`, to the same line. Leave out the first launch after a build: it takes 100–200 ms
  longer, all of it before the app's first line, and the next launch of the same binary
  doesn't.
- **B4:** the `index built: … in` log line at launch, and a serialized test with a 1 s bound.
- **B5:** `footprint <pid>` with the panel hidden, after showing it 20 times.

## Measured

2026-10-31, release build, Apple M5 Max, macOS 26.6.2 (25G83), 166 items indexed.

| ID | Budget | Result |
|---|---|---|
| B1 | 50 ms | First show 20–31 ms (median 21, 13 launches); later shows median 6.4, p95 11.7, max 16.3 ms (57 shows). |
| B2 | 16 ms | Model with usage ≤ 0.23 ms p95. Through the panel, with the rows laid out: median 1.9, p95 3.5 ms in a debug build (135 keystrokes). |
| B3 | 300 ms | `launched` → hotkey registered 10–29 ms. `open` → registered median 127, p95 138 ms (49 launches). The first launch of a newly signed build took 233–322 ms (5 launches), all of the extra before the app's code runs. |
| B4 | 200 ms | 32–41 ms, median 34 ms (49 launches). |
| B5 | 40 MB | 18–19 MB. |
