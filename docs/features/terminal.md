# Terminal sessions, copy, paste and search

All requirements here are P0.

## Sessions

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| FR-S01 | Run configurable local shells with real PTY behavior. | The default login shell, Ctrl-C, Ctrl-D, job control, resizing and process exit all work. |
| FR-S02 | Render ordinary terminal applications reliably. | Exercise vim, less, top, colors, the alternate screen, mouse reporting and Unicode. |
| FR-S03 | Show session status and exit code, and allow an explicit restart. | A process that exits with code 7 stays visible, and restarting gives a fresh session ID. |
| FR-S04 | Keep bounded scrollback and search per pane. | Search forward and backward through retained text, and say when older output has been evicted. |
| FR-S05 | Let new sessions set a working directory and environment. | Launch in a directory whose name contains spaces, with an override variable. Inaccessible paths are rejected before any process is created. |

Session states and process handling are described in [Sessions and processes](../architecture/sessions.md). Run `swift run Trellis --fixture` to see a fixed shell that exits with code 7 (FR-S03).

## Copy

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| FR-C01 | Support native text selection, Cmd-C, Cmd-V, and context-menu copy and paste. | Cmd-C copies when there's a selection, and with no selection it does **not** send SIGINT. Ctrl-C still sends the terminal interrupt. |
| FR-C02 | Support plain-text copy, Select All, and word and line selection. | Unicode and multiline text copy without terminal escape sequences, and Copy All covers the whole retained buffer. |
| FR-C06 | Double-click selects the whole recognized token under the pointer (smart selection): a URL, an email address, a file path with an optional `:line[:column]` suffix, a UUID, an IPv4 address with optional port, an IPv6 address, a git hash, or a quoted string when the click lands on one of its quotes. Elsewhere it selects a word as before. | Double-clicking any part of `https://en.wikipedia.org/wiki/A_(b)).` selects the URL without the trailing `).`, `src/main.swift:12:5` and `~/notes/todo.md` are selected whole, a path that soft-wraps across rows is selected across them, and wide characters keep their columns. A clock time such as `12:34:56` is not an IPv6 address. Dragging after the double-click extends from the whole token. While a program captures the mouse (mouse reporting), the double-click goes to the program. Triple-click still selects the line. |

## Paste

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| FR-C03 | Paste only into the focused pane, using bracketed paste when the shell has negotiated it. | With two panes, only the focused pane receives the pasted bytes. |
| FR-C04 | Review multiline pastes and text with control characters before sending them. | The review shows the line count, invisible control characters and the target pane. Cancelling sends zero bytes. Paste never adds a newline that wasn't in the clipboard. |
| FR-C05 | Paste file paths through an explicit action. | **Paste Escaped Path** escapes paths for the configured shell; shells it doesn't support get a quoted-path preview. Ordinary paste stays plain text. |

The UI paste review is mandatory. API input (`session.sendInput`) doesn't show it, because the grant itself authorizes input. See [Methods](../api/methods.md#session-launch-and-input).

## Scrollback and search

- Each pane keeps 10,000 lines of scrollback by default, plus a 16 MiB byte cap. The oldest lines are evicted first.
- Search is per pane and runs forward and backward. It shows the current match, and says when the history it could have matched has been evicted.
- The alternate screen (vim, less, top) and the main screen's history are searched separately.

## Links

Hold ⌘ and hover to underline a link; ⌘-click opens it. Links come from OSC 8 hyperlinks (`ls --hyperlink`, compilers, `rg`) or are detected in plain text.

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| FR-L01 | ⌘-click opens web and mail links. | `http`, `https` and `mailto` links open in the default browser or mail app only after a ⌘-click; output alone never opens anything, and one click opens at most one link. |
| FR-L02 | ⌘-click opens local file paths and OSC 8 `file://` links in the file's default app. | Absolute paths, `~/` paths and relative paths open; a `:line[:column]` suffix is removed before opening, and percent-encoded `file://` paths are decoded. Missing files, devices, sockets and FIFOs do nothing. |
| FR-L03 | Never launch anything from a terminal link. | Executables (any execute bit), application bundles and other packages, scripts (`.command`, `.sh`, `.py`, `.scpt`, …), installers, disk images, aliases and URL shortcut files are revealed in Finder instead of opened. A symbolic link is judged by its target. |
| FR-L04 | Open files only from local panes. | Relative paths resolve only against the directory reported by authenticated shell integration; without one they don't open. Panes connected to a saved SSH host, or started directly as `ssh` or `mosh`, never open file paths. Paths under the `/net` and `/Network` automounts are refused, so a click can't make the Mac contact a host named by output. `file://` links naming another host or a port are refused, and an OSC 8 link whose target has no scheme is refused because its visible text can differ from its target. |
| FR-L05 | Offer link actions in the context menu. | Right-clicking a web link offers **Open Link** and **Copy Link**; right-clicking a file path offers **Open** (or **Reveal in Finder** under FR-L03) and **Copy Path**. Elsewhere the menu is unchanged. The menu follows the same rules as ⌘-click. |

Known limits: a host reached by typing `ssh` inside a local shell isn't detected, so absolute paths from it open if the same path exists on this Mac. The `:line[:column]` suffix isn't passed to editors. The pointer doesn't change to a hand over links.

## Terminal output is untrusted

Terminal output can be written by anything, so Trellis treats it as hostile:

- Terminal-initiated clipboard reads and writes, including OSC 52, are disabled by default.
- Opening a link needs a user gesture (⌘-click or a context-menu choice). Only `http`, `https` and `mailto` links and existing local files open; files that could run code are only revealed in Finder (FR-L01–FR-L04). Custom schemes and automatic opening are disabled.
- Copy strips terminal control sequences.
- Nothing in terminal output can change permissions. That includes text that looks like instructions to an agent.

The terminal scrollbar stays hidden while idle. Hovering over its right-edge track reveals it when scrollback is available. Scrolling gestures reveal it only when the viewport moves; it fades out one second after scrolling stops or the pointer leaves the track. Incoming output alone does not reveal it, and visibility changes do not alter the terminal grid width.
