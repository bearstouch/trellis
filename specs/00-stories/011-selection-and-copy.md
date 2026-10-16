# S011 — Select and copy terminal text naturally

Priority: P0 / MVP  
Status: Implemented and reviewed — 117 tests and native copy checks pass; delayed independent review completed during S012
Delivery phase: 3  
Depends on: [S001](001-terminal-engine-feasibility.md), [S003](003-local-pty-session.md), [S004](004-native-application-shell.md)  
Requirements: `FR-C01`, `FR-C02`, `INT-08`, `MAC-07`

## Story

As a terminal user, I want to select and copy text with native macOS gestures and shortcuts.

## Acceptance criteria

- [x] **S011-AC01:** Support drag, word/line selection, Select All, copy selection, and copy all retained text as plain Unicode text without terminal control sequences.
- [x] **S011-AC02:** Cmd-C copies a selection; Cmd-C without a selection does not send SIGINT. Ctrl-C remains terminal interrupt input.
- [x] **S011-AC03:** Context-menu and menu-bar copy operate on the focused pane and honor the native responder chain.
- [x] **S011-AC04:** Copy all covers only retained content and indicates eviction when older output is unavailable; never poll or retain clipboard contents.

## Unit tests

All four named cases are implemented and passing, with three additional retention, context-menu, and last-column regressions. Clipboard writes use injected sinks.

| Test | Setup, action, and expected result |
| --- | --- |
| `S011_UT01_copyStripsControlsPreservesUnicode` | Copy a fixture with ANSI colors, emoji, combining marks, and newlines; assert exact plain-text output. |
| `S011_UT02_cmdCWithoutSelectionDoesNotInterrupt` | Invoke Cmd-C without selection; fake terminal transport receives zero bytes/signals. |
| `S011_UT03_ctrlCStillReachesTerminal` | Route Ctrl-C with no edit field active; transport receives the intended terminal control input. |
| `S011_UT04_copyUsesFocusedPane` | Select different content in two panes; copy writes only the focused pane’s selected text once. |

## Integration and manual verification

Verify drag/word/line selection, alternate-screen selection behavior, menus, and Cmd-C/Ctrl-C in the real terminal view using NSPasteboard.

## Completion evidence

See [S011 evidence](../../docs/evidence/S011-terminal-copy.md) for 117 passing tests, native selection/clipboard/interrupt checks, engine edge fixes, and the independent review completed during S012 after the first agent hit its service usage limit.

## Source specifications

[Overview](../01-overview/README.md), [architecture](../02-architecture/README.md), [functional requirements](../03-functional-requirements/README.md), [quality requirements](../04-non-functional-requirements/README.md), [API](../05-api/README.md), [integrations](../06-integrations/README.md), [macOS support](../07-macos-support/README.md), [themes](../03-functional-requirements/themes/README.md)
