# Functional requirements

All requirements below are P0 unless marked otherwise. Acceptance checks describe observable release behavior.

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| FR-W01 | Create, rename, reorder, select, and delete managed windows in the left sidebar. | Create two windows, reorder and rename them, restart, and verify saved order and names. |
| FR-W02 | Keep inactive-window sessions running and show bounded activity/exit indicators. | Run output in one window, switch away, return, and verify continued output and process identity. |
| FR-W03 | Remember the active tab and pane per window. | Switch windows repeatedly and verify keyboard focus returns correctly. |
| FR-W04 | Allow an empty application state. | Delete the last window and create a new one from the welcome screen. |
| FR-T01 | Support multiple tabs per window; create, rename inline from the tab bar, reorder, duplicate configuration, and close tabs. | Double-click a tab label or choose Rename; Enter commits, Escape cancels, and empty input preserves the name. The saved name persists without restarting sessions. Duplicating a tab copies its layout/launch settings but creates new session IDs and processes; it copies no output or shell input. |
| FR-T02 | Display the selected window’s own ordered tab bar above its terminal area (Native calm); switch tabs by mouse, keyboard, and command service. | Switch between two windows with different tabs; each retains its own tab order and active selection. All selection paths focus the same pane. Tab separators, new-tab, and rename controls are visible. |
| FR-T03 | Confirm closure of any running sessions and summarize affected panes. | Closing a window with three running panes shows one confirmation covering all three. |
| FR-P01 | Split any pane left/right (`x`) or top/bottom (`y`), including nested splits. | Build a three-pane mixed-axis layout and verify each pane is independently interactive. |
| FR-P02 | Resize splits with draggable dividers and keyboard controls. | Ratios persist; neither child is allowed below 20 columns × 5 rows; an invalid split returns a clear error. |
| FR-P03 | Collapse the parent branch when a pane closes. | Closing one leaf leaves its sibling in the parent region with stable remaining IDs. Closing a tab's last pane closes the tab; closing a window's last tab closes the window. |
| FR-P04 | Navigate panes directionally and temporarily maximize one pane. | Maximize/restore preserves the tree and ratios; focus indicators remain visible. |
| FR-S01 | Run configurable local shells with PTY behavior. | Default login shell, Ctrl-C, Ctrl-D, job control, resize, and process exit work. |
| FR-S02 | Render ordinary terminal applications reliably. | Exercise vim, less, top, colors, alternate screen, mouse reporting, and Unicode with the selected engine. |
| FR-S03 | Show session status and exit code, and allow explicit restart. | A process exiting with code 7 remains visible; restart produces a fresh session ID. |
| FR-S04 | Provide bounded scrollback and search per pane. | Search forward/backward through retained text; explain when older output has been evicted. |
| FR-S05 | Allow working-directory and environment configuration for new sessions. | Launch in a directory containing spaces with an override variable; reject inaccessible paths before creating a process. |
| FR-C01 | Support native text selection, Cmd-C, Cmd-V, and context-menu copy/paste. | Cmd-C with a selection copies it; without a selection does not send SIGINT. Ctrl-C continues to send terminal interrupt input. |
| FR-C02 | Support plain-text copy, select all, and word/line selection. | Copy Unicode and multiline text without terminal escape sequences; copy-all covers the retained buffer. |
| FR-C03 | Paste only into the focused pane, using bracketed paste when negotiated. | With two panes, only the focused pane receives the pasted bytes. |
| FR-C04 | Review multiline paste and text containing control characters before submission. | Preview line count, invisible controls, and target; cancel sends zero bytes. “Paste” never adds a newline beyond the clipboard content. |
| FR-C05 | Support file-path paste through an explicit action. | “Paste escaped path” escapes paths for the configured shell; unsupported shells get a quoted-path preview. Ordinary paste remains plain text. |
| FR-H01 | Create, edit, delete, search, and tag saved SSH hosts. | Save alias or hostname, optional username, port, identity-file reference, and tags; reconnect from the host list. |
| FR-H02 | Open a host in a new tab or explicitly chosen split. | Each connection has an independent SSH process; host edits affect only subsequent connections. |
| FR-H03 | Discover aliases from user SSH config without changing it. | Imported aliases retain their SSH alias; unsupported config details are delegated to OpenSSH. |
| FR-H04 | Preserve native SSH authentication and trust prompts. | Unknown/changed host keys and password/key-passphrase prompts remain interactive. No host-key checking bypass is inserted. |
| FR-H05 | Leave failed connections inspectable and reconnect explicitly. | A failed SSH process exposes status/exit code; no automatic credential attempt loop occurs. |
| FR-A01 | Provide CLI/API equivalents for workspace, tab, pane, session, host, and layout operations. | A script creates two windows and a nested layout without using pointer input. See API contract. |
| FR-A02 | Discover stable IDs, revisions, session states, and allowed capabilities. | JSON enumeration gives deterministic resource relationships and no credentials. |
| FR-A03 | Read output and send input only with explicit scoped grants. | A layout-only client cannot read terminal text or execute commands; denial changes no state. |
| FR-A04 | Validate, plan, and apply versioned layouts idempotently by namespace and key. | Applying the same layout twice reuses existing objects and does not rerun commands or restart sessions. |
| FR-A05 | Expose state/exit/output events with sequence cursors. | A client detects an event gap and resynchronizes without silently assuming complete history. |
| FR-R01 | Save and restore organization as stopped panes. | After normal quit/relaunch, names and splits return without executing a command. |
| FR-R02 | Import/export layouts and host metadata with a review summary. | Validate before mutation, assign fresh IDs, omit credentials, and refuse unsupported versions without partial import. |
| FR-U01 | Provide discoverable, configurable keyboard shortcuts with conflict warnings. | Menus show shortcuts; conflicts cannot silently disable a critical command. |
| FR-U02 | Support readable terminal settings. | Monaco is the default terminal font; use Menlo or system monospace with a visible notice if Monaco is unavailable. Font family/size, light/dark application theme, cursor style, and scrollback limit update predictably; font zoom is available. Terminal backgrounds remain dark by default in both application themes. |

## Themes

Built-in dark/light themes, system appearance matching, and custom JSON theme files are MVP requirements. See [Theme specification](themes/README.md), including FR-TH01–FR-TH08, the schema, and complete editable examples.

## Default shortcut proposal

Use Cmd-N for a managed window, Cmd-T for a tab, Cmd-W for the current pane (which closes a one-pane tab), Cmd-Shift-W for the tab, Cmd-D for left/right split, and Cmd-Shift-D for top/bottom split. Cmd-F searches the focused terminal. Cmd-1 through Cmd-9 select tabs; Cmd-Option-Arrow navigates panes. Final defaults require collision and keyboard-layout validation.

## Cross-feature acceptance scenario

Create “Project” and “Operations” in the sidebar. In Project, open a local shell, add a second tab, split it left/right and then top/bottom. Copy a selected command, review a multiline paste, and verify only the focused pane changes. In Operations, connect to a saved SSH alias and inspect a failed connection. Use the CLI to list the same object IDs and apply a layout twice. Verify a restricted agent cannot read output. Quit with running-session confirmation and reopen; the layout returns stopped until explicitly started.
