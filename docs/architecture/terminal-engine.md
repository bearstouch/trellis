# Terminal engine

## SwiftTerm behind an adapter

Trellis uses [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) 1.20.0 (MIT), vendored in `ThirdParty/SwiftTerm` at upstream revision `5d14406844143538cd8f8851d2d8a67c1fe443e5`. Trellis doesn't write its own terminal emulator.

The adapter rules:

- **Only `TrellisTerminal` imports SwiftTerm.** Engine types never leak into `TrellisCore`, `TrellisUI` or the API, so the engine stays replaceable.
- PTY ownership isn't duplicated. Trellis owns the PTY (`PTYProcess`) and feeds bytes to the engine, rather than using SwiftTerm's own process helper. That way process-group cleanup and asynchronous output stay under Trellis's control.
- `AccessibleTerminalView` subclasses SwiftTerm's AppKit `TerminalView` to add accessibility and Trellis-specific responder behavior.
- `NativeTerminal` is the per-pane object that joins a view, a `LocalSessionController` and the scrollback, search and appearance services.

## Patches

Any change to the engine is recorded in `ThirdParty/SwiftTerm/PATCHES.md`, and the exact diff in `ThirdParty/SwiftTerm/trellis.patch`. There are eleven patched files today:

| File | Change | Why |
| --- | --- | --- |
| `Mac/MacTerminalView.swift` | Mouse-exit and scroll-wheel overrides are `open`; a `doubleClickSelection` hook replaces double-click word selection; `bufferPosition(for:)` exposes the engine's BiDi-aware hit test; `fontLigatures`, `allowBoldFont`, `allowItalicFont`, `boldIsBright` and `textBlinkEnabled` view properties; `cellMetrics` gives the cell size in points and the backing scale | Scrollbar reveal, [smart selection](../features/terminal.md#copy), context-menu link actions, text-rendering settings and `ReportCellSize` (FR-IM03) |
| `Apple/AppleTerminalView.swift` | Changing the font resizes without a DECSTR soft reset; OSC 8 parameters are split from the URL only at the first `;`; glyphs and decorations are placed from each run's source cells; concealed text and overline are drawn; the cursor cell is shaped on its own while ligatures are on; text-style flags select fonts, bright colours and blinking; `insertImage` is public | Zooming mustn't reset live parser state such as cursor mode and attributes; URLs containing `;` aren't truncated; [text rendering](../features/terminal.md#text-rendering) (FR-TX01–FR-TX03); Trellis decodes [inline images](../features/terminal.md#inline-images) itself and places them with the engine |
| `CharData.swift` | `Attribute.extendedStyle` holds overline | `CharacterStyle`'s eight bits are all taken |
| `Mac/MacCaretView.swift` | The caret hides concealed text | FR-TX02 |
| `iOS/iOSTerminalView.swift` | Plain copies of the text-style properties | Keeps the shared renderer compiling for iOS; not built here |
| `SelectionService.swift` | `setWordSelection(start:end:)` sets a half-open word-mode selection | A smart double-click selection extends by word when dragged and may end in the last column |
| `Buffer.swift` | Opt-in `reflowCursorLine` for normal-buffer cursor-line reflow | Keeps the cursor and selections correct across font changes |
| `EscapeSequenceParser.swift` | `maxStringPayloadBytes` (8 MiB): a longer OSC, APC or DCS sequence is dropped whole, even when it arrives across several reads | Upstream grows the payload buffer without limit, so output could exhaust memory (FR-IM04) |
| `KittyGraphics.swift` | Refuses file (`t=f`), temp-file (`t=t`) and shared-memory (`t=s`) transmission with `ENOTSUP`; `o=z` payloads are checked as RFC 1950 zlib (header and Adler-32), inflated at most to the 400 MiB image cap, and refused if the stream stalls; chunked (`m=1`) transfers are capped at that image size too | Terminal output is untrusted and must never make the app read or unlink local files; upstream decoded zlib as raw deflate with no progress check, so a 30-byte payload hung the main thread, and concatenated chunks without limit |
| `SixelDcsHandler.swift` | Sixel numbers saturate and repeat counts are clamped; an image over 10,000 px a side, 40 MP or 40 million sixels is dropped before allocation | Upstream trapped on integer overflow and allocated and drew any size, so output could crash or exhaust the app (FR-IM04) |
| `Terminal.swift` | `DECRQSS` stores at most a request-sized buffer; exposes the reflow opt-in, which is enabled only during font changes, public `handleSemanticPrompt(_:)` and `handleProgressReport(_:)` forwarders, and `linkIsExplicit(at:)`; parses overline (SGR 53/55) and rapid blink (SGR 6) | Trellis's own 133 handler authenticates [shell-integration](../features/shell-integration.md) marks and still keeps prompt navigation state; file links treat OSC 8 targets differently from detected text; FR-TX02 |

To update SwiftTerm:

1. Replace the source tree with a verified upstream revision.
2. Reapply each delta, or retire it if upstream no longer needs it.
3. Update the provenance in `PATCHES.md` and regenerate `trellis.patch`.
4. Run the full suite, plus native checks of appearance, zoom, clipboard, search and the alternate screen.

## Terminal type

Children get `TERM=xterm-256color`, `COLORTERM=truecolor` and `TERM_PROGRAM=Trellis`, plus `LC_TERMINAL=iTerm2` and `LC_TERMINAL_VERSION=3.5.0` because Trellis implements iTerm2's inline image protocol (FR-IM05) and image tools look for those. Trellis supports the terminal input, job control, signals, colors, alternate screen, mouse modes and bracketed paste that this terminal type promises. Only claim a terminal type the engine and the installed terminfo actually support.

## Scrollback and output buffers

| Buffer | Bound | Where |
| --- | --- | --- |
| Per-pane scrollback | 10,000 lines by default (configurable from 0 to 50,000) **and** 16 MiB. The newest contiguous lines are kept. | `ScrollbackBudget`, `TerminalScrollback` |
| Automation output journal | 8 MiB shared by all sessions, oldest evicted first, in memory only. Small reads are coalesced into 16 KiB chunks. | `OutputJournal` |
| Event ring | 1,000 metadata events | `EventHub` |

Output must keep the PTY's byte order. The UI may coalesce frames, but it never reorders data. When history has been evicted, search and `readOutput` say so instead of pretending it never existed.

## Search and selection

- `PaneTextSearch.find` scans every buffer row. It joins wrapped rows and handles wide characters. Search is per pane, and the alternate screen is kept apart from the main screen's history.
- `TerminalSelectionBookmark` holds a selection as logical Unicode offsets, so it survives reflow. If eviction removes the selected text, the selection is cleared rather than jumping to another identical match.
- Copy produces plain Unicode text with no escape sequences.

## Output security

- **OSC 52:** the engine's clipboard callbacks do nothing. Copy requests are ignored and read requests return nothing.
- **Links:** `LinkPolicy` allows `http`, `https` and `mailto` only, up to 2,048 bytes, with no control characters or spaces. Web links must include a host and must not include credentials, and `mailto` keeps only `subject` and `body`. A link opens only within 1.5 seconds of a user's click, and each click opens at most one link.
- **File links:** `TerminalLinkClassifier` turns a clicked link into a web URL or a local path, and only when the pane supplies a `FileLinkContext` (local panes; never saved SSH hosts or panes started as `ssh`/`mosh`). `file://` hosts must be local, automount paths (`/net`, `/Network`) are refused, schemeless OSC 8 targets are refused, and relative paths need the authenticated shell-integration directory. `FileLinkPolicy` then probes the symlink-resolved file on the main thread at click time (a `stat`, bounded to the clicked path): packages, executables, scripts and other launchable types are revealed in Finder, other regular files and folders open, and anything else is ignored.
- **Smart selection:** `SmartSelection` (Core) matches URLs, emails, paths, UUIDs, IP addresses, git hashes and quoted strings around a grapheme offset. `TerminalLogicalLine` supplies the soft-wrapped text around the double-clicked cell (at most 32 rows each way and 4,096 characters) and maps the match back to cells.
- **Kitty graphics:** local-file and shared-memory transmission are refused, compressed (`o=z`) payloads are bounded and validated, and chunked transfers are bounded (see Patches above).
- **Sixel:** numbers saturate and images over the inline image limits are dropped before allocation (see Patches above).
- **Inline images (OSC 1337):** `NativeTerminal` registers its own 1337 handler, replacing upstream's, which hands any data to `NSImage` and leaves downloads to the delegate. `InlineImageDecoder` reads the type and pixel size with ImageIO first and only decodes PNG, JPEG, GIF, BMP, TIFF, WebP and HEIC within 10,000 px a side and 40 MP. `MultipartImageTransfer` decodes parts as they arrive, holds at most 32 MiB, and drops the transfer on any other 1337 command. `inline=0` downloads are ignored. `InlineImageLayout` shrinks a box with an `auto` side to the pane's width and 10,000 px tall, because upstream's `insertImage` doesn't bound a side derived from the aspect ratio and allocates each row at that width. Images are decoded synchronously in stream order, so they land where the cursor was.

## Accessibility

VoiceOver must be able to identify terminal panes and their state. An engine that isn't accessible would block a release. Checking terminal reading with real VoiceOver is still pending. See [Status](../overview/status.md).
