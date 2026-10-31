# 0012. Draw the panel once, transparent, at launch

- **Date:** 2026-10-31
- **Status:** accepted

## Context

B1 gives the hotkey 50 ms to put the panel on screen with the field taking the keys. Measured on
a release build (Apple M5 Max, macOS 26.6.2), each show after the first took 4–17 ms, but the
first took 36–45 ms. Most of the first show's time was work AppKit does only once: creating the
window server's window for the deferred panel, the first drawing of the glass and the field, and
setting up the field editor. Those 45 ms run up to the commit; the frame reaches the display one
refresh later, so the margin was too thin. The first show after a login item launch is the one
that matters most.

## Decision

After the first config state registers the hotkey and starts the index build, the coordinator
queues `SearchPanelController.prepare()` on the main actor. It orders the panel in at alpha 0
and out again in the same run-loop turn, drawing it once. The panel is never key and never
visible. The first show then took 20–31 ms.

## Alternatives considered

- **Create the field editor only** (`fieldEditor(true, for:)`): rejected. It took 1 ms and the
  first show stayed at 34–42 ms. Drawing the window creates the editor as well.
- **Create the panel with `defer: false`**: rejected. That creates the window at init, before
  the hotkey is registered, which adds to B3. It also leaves the first drawing until the first
  show.
- **Make the panel key once while transparent**: rejected. Becoming key costs about 7 ms of the
  first show and can't be warmed without taking the keys from the user's app.

## Consequences

Launch does about 15 ms more main-actor work, after the hotkey works and while the index builds
off the main actor, so B3 and B4 don't change. Idle footprint stayed at 18–19 MB. A tool that
lists windows could see the transparent panel for that one run-loop turn.
