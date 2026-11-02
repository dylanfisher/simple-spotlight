# 0017. Script commands: one file is a command, one folder is a group

- **Date:** 2026-11-01
- **Status:** accepted

## Context

The user wants rows of their own in the panel, the first being a switch for the living room
receiver's input: type "game", press Return, and a script sends the command to the receiver.
Several such commands belong together (TV, game, power off), so they need a place to live that
doesn't crowd the top level. The rows must rank with usage like apps do (decision 0010), follow
edits to the files live (decision 0011), and report mistakes the way the config file does
(decision 0006).

## Decision

**The folder.** Each file in `~/.config/simple-spotlight/commands/` is a command; Return runs
it. Each subfolder, at any depth, is a group; opening it searches only the rows inside it. The
folder is fixed, beside `config.json`, and the `scriptCommands` key (default true) turns the
feature on. A missing folder isn't a problem: having the folder is how a user opts in. The
folder joins `IndexBuilder.watchedFolders`, so adding or editing a script updates the index as
decision 0011 describes.

**The header.** A script describes itself in `#` or `//` comment lines before its first other
line: `@title` (default: the file name without its extension), `@subtitle`, `@keywords`
(space-separated, matched as alternate names) and `@top-level` (no value). Only the first 4 KB
is read. A group takes the same tags from a `_group` file in its folder, which is never run; the
title defaults to the folder's name. `ScriptHeader` in Base parses them.

**Strict, like the config file.** An unknown or repeated tag, or a value given to `@top-level`,
is a problem row naming the file and line; the script gets no row. So does a script that isn't
executable, whose fix is `chmod +x`. A broken `_group` is a problem row too, but its group still
shows, under the folder's name, so the commands inside stay reachable.

**What the scan reads.** Only regular files, found through `stat`. A named pipe or other special
file, a link to nothing, and a link to a folder are problem rows: opening a named pipe blocks
the reader, FSEvents doesn't follow links so a linked folder wouldn't update the index, and a
link up the tree can make the scan loop. A link to a script is followed. Names starting with `.`
or `_` are skipped at every depth, other than `_group`; that is how to keep a helper such as a
sourced `_denon.sh`, or a big folder, out of the scan, which otherwise walks every subfolder.
Rows are ordered as Finder orders names (`localizedStandardCompare`).

**What the top level shows.** Every command and group directly in the folder, and every deeper
one marked `@top-level`. A `@top-level` row with no subtitle gets its immediate group's title as
one. Its id is the same in both places (`SearchItem.builtInID("commands/<path>")`), so the
two rows share usage.

**Running.** A script runs only when its row is opened, never while the index is built, in its
own folder with no stdin. It gets the app's environment with only `PATH` replaced by
`/usr/bin:/bin:/usr/sbin:/sbin`, the PATH launchd gives a GUI app, so it behaves the same
however the app was started. The app doesn't copy the user's shell PATH; scripts use absolute
paths. Stdout is dropped. A non-zero exit, a signal or a launch failure goes through
`reportError` with the exit code and the last 500 bytes of stderr, and success shows nothing.
After 10 seconds the script gets SIGTERM and the user is told it timed out. Only SIGTERM: a
script that ignores it keeps running, and the report doesn't wait for it.

**Usage.** A script counts as an open, so it ranks by frecency and dims when unused (decisions
0010 and 0014). A group doesn't: opening one is a step toward the command. Inside a group, an
empty query lists its rows by frecency, then by name; at the top level an empty query still
matches nothing.

**Keys.** Tab, or Return on a group row, opens the group. → opens it when the cursor is at the
end of the query with no text selected and a group row is selected; otherwise it moves the
cursor. Shift-Tab goes up a level, as does ← with the cursor at the start of the query, and
Backspace on an empty query. Esc clears the query if there is one, then goes up a level, then
hides the panel. A breadcrumb chip at the left of the field names the groups opened, and
clicking it goes up a level. Entering a group clears the field after remembering the query and
the group's row at the level it came from; going up puts that query back, with the caret at its
end and the group's row selected. Entering a group is announced to VoiceOver as "<title>, N
commands"; leaving announces the parent's title, or "Search" at the top level. A rebuild of the
index keeps the panel in its group if the group still exists. If not, the panel goes up to the
deepest level that does, as if the user had left each lost group, and selects the lost group's
row if it is still there.

**Hiding goes up to the top level.** Hiding inside a group goes up through every level as
leaving each would, so the next show is at the top level with the query it had when the
outermost group was entered and that group's row selected. Hiding at the top level keeps the
query, as before.

## Alternatives considered

- **Swift plugin bundles** — rejected: loading code into the app needs a stable ABI between the
  app and each plugin, and code signing and notarization for every plugin, to let a user add a
  shell one-liner.
- **Commands in `config.json`** — rejected: a shell command inside a JSON string needs its
  quotes and backslashes escaped, which is where one-liners go wrong, and decision 0006's schema
  is one key per setting with a kind, a default and a comment. A list of commands is none of
  those, and the Settings window would need a second editor for it.
- **The user's shell PATH** — rejected: it means starting a login shell to ask for it, which
  costs time and can print or hang. Absolute paths in the script avoid it.
- **Following links to folders** — rejected for the loop and the missing updates described
  above.
- **Skipping nothing, or a skip list in `config.json`** — rejected: a leading `.` or `_` is
  enough, needs no setting, and is visible in the folder itself.

## Consequences

A user adds a command by saving an executable file; it shows in the panel about a second later
(decision 0011). Because the scan walks every subfolder that doesn't start with `.` or `_`, a
large unrelated folder in `commands/` slows the index build until it is renamed with a `_`.
A script that ignores SIGTERM and runs on is the user's to fix; the app keeps no handle on it.
Scripts run with the app's permissions, so a file dropped into the folder runs when its row is
opened.
