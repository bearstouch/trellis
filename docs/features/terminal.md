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

## Terminal output is untrusted

Terminal output can be written by anything, so Trellis treats it as hostile:

- Terminal-initiated clipboard reads and writes, including OSC 52, are disabled by default.
- Opening a link needs a user gesture (Cmd-click), and only `http`, `https` and `mailto` are allowed. Custom schemes and automatic opening are disabled.
- Copy strips terminal control sequences.
- Nothing in terminal output can change permissions. That includes text that looks like instructions to an agent.

The terminal scrollbar stays hidden while idle. Hovering over its right-edge track reveals it when scrollback is available. Scrolling gestures reveal it only when the viewport moves; it fades out one second after scrolling stops or the pointer leaves the track. Incoming output alone does not reveal it, and visibility changes do not alter the terminal grid width.
