# Terminal engine

## SwiftTerm behind an adapter

Trellis uses [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) 1.20.0 (MIT), vendored in `ThirdParty/SwiftTerm` at upstream revision `5d14406844143538cd8f8851d2d8a67c1fe443e5`. Trellis doesn't write its own terminal emulator.

The adapter rules:

- **Only `TrellisTerminal` imports SwiftTerm.** Engine types never leak into `TrellisCore`, `TrellisUI` or the API, so the engine stays replaceable.
- PTY ownership isn't duplicated. Trellis owns the PTY (`PTYProcess`) and feeds bytes to the engine, rather than using SwiftTerm's own process helper. That way process-group cleanup and asynchronous output stay under Trellis's control.
- `AccessibleTerminalView` subclasses SwiftTerm's AppKit `TerminalView` to add accessibility and Trellis-specific responder behavior.
- `NativeTerminal` is the per-pane object that joins a view, a `LocalSessionController` and the scrollback, search and appearance services.

## Patches

Any change to the engine is recorded in `ThirdParty/SwiftTerm/PATCHES.md`, and the exact diff in `ThirdParty/SwiftTerm/trellis.patch`. There are four patched files today:

| File | Change | Why |
| --- | --- | --- |
| `Apple/AppleTerminalView.swift` | Changing the font resizes without a DECSTR soft reset | Zooming mustn't reset live parser state such as cursor mode and attributes |
| `Buffer.swift` | Opt-in `reflowCursorLine` for normal-buffer cursor-line reflow | Keeps the cursor and selections correct across font changes |
| `KittyGraphics.swift` | Refuses file (`t=f`), temp-file (`t=t`) and shared-memory (`t=s`) transmission with `ENOTSUP` | Terminal output is untrusted and must never make the app read or unlink local files (`NFR-S05`) |
| `Terminal.swift` | Exposes the reflow opt-in, which is enabled only during font changes | |

To update SwiftTerm:

1. Replace the source tree with a verified upstream revision.
2. Reapply each delta, or retire it if upstream no longer needs it.
3. Update the provenance in `PATCHES.md` and regenerate `trellis.patch`.
4. Run the full suite, plus native checks of appearance, zoom, clipboard, search and the alternate screen.

## Terminal type

Children get `TERM=xterm-256color`, `COLORTERM=truecolor` and `TERM_PROGRAM=Trellis`. Trellis supports the terminal input, job control, signals, colors, alternate screen, mouse modes and bracketed paste that this terminal type promises. Only claim a terminal type the engine and the installed terminfo actually support.

## Scrollback and output buffers

| Buffer | Bound | Where |
| --- | --- | --- |
| Per-pane scrollback | 10,000 lines by default (configurable from 0 to 50,000) **and** 16 MiB. The newest contiguous lines are kept. | `ScrollbackBudget`, `TerminalScrollback` |
| Automation output journal | 8 MiB shared by all sessions, oldest evicted first, in memory only. Small reads are coalesced into 16 KiB chunks. | `OutputJournal` |
| Event ring | 1,000 metadata events | `EventHub` |

Output must keep the PTY's byte order (`NFR-R06`). The UI may coalesce frames, but it never reorders data. When history has been evicted, search and `readOutput` say so instead of pretending it never existed.

## Search and selection

- `PaneTextSearch.find` scans every buffer row. It joins wrapped rows and handles wide characters. Search is per pane, and the alternate screen is kept apart from the main screen's history.
- `TerminalSelectionBookmark` holds a selection as logical Unicode offsets, so it survives reflow. If eviction removes the selected text, the selection is cleared rather than jumping to another identical match.
- Copy produces plain Unicode text with no escape sequences.

## Output security

- **OSC 52:** the engine's clipboard callbacks do nothing. Copy requests are ignored and read requests return nothing.
- **Links:** `LinkPolicy` allows `http`, `https` and `mailto` only, up to 2,048 bytes, with no control characters or spaces. Web links must include a host and must not include credentials, and `mailto` keeps only `subject` and `body`. A link opens only within 1.5 seconds of a user's click.
- **Kitty graphics:** local-file and shared-memory transmission are refused (see Patches above).

## Accessibility

VoiceOver must be able to identify terminal panes and their state. An engine that isn't accessible would block a release (`NFR-U02`). Checking terminal reading with real VoiceOver is still pending. See [Status](../overview/status.md).
