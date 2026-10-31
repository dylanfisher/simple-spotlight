# 0013. Show the panel on every display: one controller, a panel per display, shared rows

- **Date:** 2026-10-31
- **Status:** accepted

## Context

The user asked for an option to show the search field on all displays at once, so it is in
front of them whichever display they are looking at. The plan's P10 adds a `showOnAllDisplays`
config key, default false: when true, the hotkey shows the panel on every screen, all with the
same query, rows and selection, the one on the focused window's screen (`FocusedScreen`,
decision 0008) taking the keys. A click in another display's panel moves the keys there, hiding
any panel hides them all, and each panel sizes its rows to its own screen. B1 (50 ms from the
hotkey to the panel with the field taking the keys) still applies.

## Decision

- **One controller, one `SearchState`, a panel per display.** `SearchPanelController` keeps a
  list of panels, each with its own field and rows view, all over the one `SearchState`. A
  show uses as many as there are displays, making more when there are more displays than
  panels, and keeps them while hidden. The first panel goes on the focused window's screen and
  takes the keys; the others go on the other screens in `NSScreen.screens` order, ordered in
  with `orderFrontRegardless` and never key. The same rows and selection follow from the shared
  state. The query is copied into every other panel's field after each search; a programmatic
  `stringValue` doesn't reach the field's delegate, so the copy doesn't search again.
- **Rows per screen.** The rows the keys move through are capped by the room on the screen of
  the panel taking the keys, as with one panel. A panel on a shorter screen shows as many of
  them as fit there (`SearchView.limit`); its height fits those. When the keys move to it, the
  search runs again and the cap becomes its own.
- **Moving the keys.** `SearchPanel.sendEvent` tells the controller of a mouse-down in a panel
  that isn't key, before AppKit makes it key. The controller makes that panel the one taking
  the keys and gives its field the first responder. The panel that had them then resigns key;
  `windowDidResignKey` hides everything only when the panel resigning is the one taking the
  keys, so this resign is ignored. A click outside every panel, or another app coming forward,
  still hides them all.
- **Hiding.** `hide()` orders every shown panel out. Esc, Return, ⌘1…⌘9, the hotkey and a
  click elsewhere all go through it.
- **Live setting.** The key is read at each show, so a config edit applies at the next one.
  Turning it on draws a panel for each screen once, transparent, as `prepare()` does for the
  first (decision 0012), so the first show on several displays doesn't pay for making their
  windows.
- **Off by default.** With it off, a show uses only the first panel, as before.

## Alternatives considered

- **A controller per display, kept in step by the coordinator** — rejected: the query, the
  rows, the selection and the hide would each need syncing between controllers, and the
  search would run once per display on each keystroke. One controller searches once.
- **The same rows on every panel, capped by the shortest screen** — rejected: one short display
  would shorten the list on every other, and the plan asks each panel to size to its own
  screen.
- **Moving the keys in `windowDidBecomeKey`** — rejected: the panel losing the keys resigns
  before the clicked one becomes key, so the resign would hide everything first. The
  mouse-down arrives before either.
- **Hiding on resign only when no panel of ours is key, checked a turn later** — rejected: the
  hide would wait a run-loop turn, and a test would have to wait for it.

## Consequences

Each keystroke compares the query with each other panel's field and refits each panel, which
is small next to the search; the search runs once. Showing on two or three displays orders one or
two more windows in on the hotkey, which adds to B1; the B1 timing in performance.md is the
check. A display connected after the setting was turned on gets its panel made and drawn at
its first show, so that one show is slower. What tests can't see: the panels on real screens,
the click that moves the keys (`sendEvent` with a real mouse-down), and the non-key panels'
look.
