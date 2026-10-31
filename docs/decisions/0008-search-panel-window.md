# 0008. The search panel: a non-activating borderless panel, an AppKit field over SwiftUI rows

- **Date:** 2026-10-31
- **Status:** accepted

## Context

P5 puts the search on screen. The app is an accessory (no Dock icon, no menu bar), so the panel
has to take typing while another app stays frontmost, show over full-screen apps and every
space, and hide when the user clicks away. B1 gives 50 ms from the hotkey to a visible panel with
the field focused, and B2 16 ms from a keystroke to new rows. AGENTS.md asks for AppKit for the
panel and SwiftUI for the views inside it, and tests must never show a window or take focus.
Searcher's palette (its 0087) solved the look and the key handling for a similar panel.

## Decision

- **Window.** `SearchPanel` is an `NSPanel` with `[.borderless, .nonactivatingPanel]`, floating
  level, `[.canJoinAllSpaces, .fullScreenAuxiliary]`, `canBecomeKey` true and `canBecomeMain`
  false. Non-activating means it becomes key and gets the keystrokes without bringing the app
  forward, so the app the user was in stays active and gets the keys back on hide. It hides when
  it resigns key (a click elsewhere, another app forward), not on app deactivation, since the
  app is rarely active. No open or close animation.
- **Look.** Searcher's recipe after its fixes: a view clipped to a 16 pt rounded rectangle holding
  the backdrop and a hairline edge (`EdgeView`). The backdrop is an `NSVisualEffectView`
  (`.popover`, behind window, always active) on every macOS version: its tint is set by light or
  dark appearance alone, so the panel reads the same color over a white window and a black one,
  as Spotlight's does. The clip keeps the window's shadow rounded, since the window server shapes
  it from the panel's pixels (Searcher 0087, "no window shadow around the glass").
- **Place and size.** On the screen holding the frontmost app's frontmost window, where the
  user is working, rather than the screen with the mouse. `FocusedScreen` finds it with
  `CGWindowListCopyWindowInfo`: the first on-screen window at layer 0, not fully transparent,
  owned by `NSWorkspace.frontmostApplication`, and the screen it overlaps most. It reads only
  bounds, layer, alpha and owner, which need no Screen Recording permission, so no prompt
  shows; window names would. With no such window (the desktop, an app with no windows open) it
  is `NSScreen.main`, the screen with the menu bar's key focus. Finding it adds 0.22 ms median
  and 0.39 ms p95 to a show (200 calls, 28 windows on 2 screens, release build); one call took
  4.5 ms. Centered across the screen, its
  top 22% of the way down the screen's frame. The height fits the rows and the top stays put as rows come and go,
  so the field doesn't jump while typing. The rows stop at the bottom of the screen's visible
  area: a short screen shows fewer rows rather than a panel that runs off it, so the selection
  never needs scrolling into view.
- **The field is AppKit; the rows are SwiftUI.** An `NSTextField` gets the keys from
  `makeFirstResponder` in the same pass as the show, and its editor's commands (`moveUp:`,
  `moveDown:` with their Ctrl-P/Ctrl-N bindings, `insertNewline:`, `cancelOperation:`) arrive
  through its delegate. Tab and Shift-Tab do nothing, since the field is the only control and
  tabbing would select its text again. The rows (`SearchView`, `ResultRow`) are SwiftUI in an `NSHostingView`,
  observing a `SearchState` the controller sets. The hosting view never accepts first
  responder, so a click between rows leaves the keys in the field.
- **Command chords in the panel.** With no menu bar, no Command chord reaches anything unless the
  key window takes it, so `SearchPanel.performKeyEquivalent` offers each to the controller first:
  ⌘Return (and ⌘ keypad Enter), ⌘1…⌘9, ⌘, and ⌘Q, plus ⌘X, ⌘C, ⌘V and ⌘A for the field, which
  would otherwise not work. ⌘C copies the field's selected text when there is some, else a
  selected calculator row's answer, else nothing. Cut, copy and paste go through
  `ResultOpener`, so tests never touch the user's clipboard; a paste's line breaks become
  spaces. Undo is not wired.
- **Chords on any keyboard layout.** Digits match by key code, since AZERTY's digit keys type
  punctuation without Shift. Letters and the comma match the character the layout types, so ⌘A
  is the key labeled A on AZERTY too; when the layout types no ASCII there, as Cyrillic layouts
  don't, they match the key where the US layout has the letter, as macOS's own menus do. The
  key codes come from `KeyChord.Key`.
- **VoiceOver.** The field reads as a search field. Each row is a button labeled with its title
  and subtitle (a calculation reads "<expression> equals <answer>"), and marked selected when
  it is. The result count with the first row is
  announced after each search, and the newly selected row after each move.
- **Search on the main actor.** A keystroke runs `CalculatorProvider` and
  `SearchIndex.results` on the main actor; the index measured about 0.15 ms for 2,000 items in a
  release build, so a hop off and back would cost more than it saves.
- **Icons are drawn off the main actor.** `NSWorkspace.icon(forFile:)` returns an image that
  reads the file's icon resources when first drawn, so `IconCache.render` draws it into a bitmap
  off the main actor, and the rows draw only that bitmap. Icons are cached by path; a row shows
  a rounded placeholder until its icon lands. `forget` and `forgetAll` drop icons, for P6 and P7
  to call when the index is rebuilt; a load that lands after its path was forgotten is dropped. Every settings pane, a
  `.prefPane` included, shows the System Settings app's icon, and the calculator's row the
  Calculator app's; command and problem rows show system symbols.
- **The calculator's row.** Its answer is the title, large, with the expression under it in
  secondary text. Selected, it gets a gray fill with primary text rather than the accent color
  the other rows get: Return copies its answer rather than opening something.
- **Seams for P6.** The controller takes the index, settings, `leadingItems` (rows such as a
  config error, shown first and counted in `maxResults`), a `ResultOpener` (the workspace in the
  app, a recorder in tests), the config file's maker for ⌘,, a handler for `.command` rows, the
  quit action for ⌘Q and an error reporter. Setting the index or settings searches again,
  keeping the query and the selected item.
- **Tests never order the panel in.** `ordersPanel: false` makes `show` give the field the keys in
  code without putting the panel on screen. Tests send key events to the field's editor and
  Command chords to `performKeyEquivalent`, as AppKit would.

## Alternatives considered

- **A SwiftUI `TextField`** — rejected: its focus comes through `@FocusState` after the view is
  laid out in a key window, later than B1 allows and not at all in a panel that is never shown,
  and its key handling (`onKeyPress`) also needs a focused, on-screen view, so the tests would
  have to show a window.
- **An activating panel (`NSApp.activate` on show)** — rejected: it takes the frontmost app's
  active state, which then has to be handed back on hide, and the menu bar would switch to the
  app's empty one while the panel shows.
- **`NSWorkspace.icon(forFile:)` on the main actor, drawn as it comes** — rejected: it reads the
  disk the first time each icon draws, which AGENTS.md rules out on the main thread.
- **`NSGlassEffectView` on macOS 26**, the system's Liquid Glass — used at first, then dropped
  after first use: the glass turns lighter over a light window and darker over a dark one, and
  the user wanted the panel to follow only the appearance. Its public API (`style`,
  `tintColor`, `cornerRadius`) has no setting for that, and Apple describes tinted glass as
  still mapping its tone to the brightness behind it. An explicit `appearance` on the glass sets
  the colors of what it holds, not how it samples what is behind. How Spotlight holds its glass
  still isn't public.

## Consequences

The keystroke path is the field's delegate, the calculator, the index and a SwiftUI update; B1
and B2 are measured by hand at the end of P6, when the hotkey shows the panel. What tests can't
see: the look (the panel over a white and a black window, in light and dark mode), the click on a row (a SwiftUI tap gesture), the panel over a full-screen app, the
frontmost app keeping its active state while the panel takes typing, and what VoiceOver says.
