# Windows, tabs and panes

These are the organizing requirements. All are P0. The acceptance check is the observable release behavior that proves each one.

## Managed windows

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| FR-W01 | Create, rename, reorder, select and delete managed windows in the left sidebar. | Create two windows, reorder and rename them, restart, and verify the saved order and names. |
| FR-W02 | Keep sessions in inactive windows running and show bounded activity and exit indicators. | Run output in one window, switch away and back, and verify output continued and the process is the same one. |
| FR-W03 | Remember the active tab and pane per window. | Switch windows repeatedly and verify keyboard focus returns to the right pane. |
| FR-W04 | Allow an empty application state. | Delete the last window and create a new one from the welcome screen. |
| FR-W05 | Collapse the sidebar to a narrow rail that shows each window as a square with its initials. Toggle it from the sidebar button or **View → Hide/Show Sidebar** (⌃⌘S). | Collapse the sidebar and check that each window shows its initials (the first letters of its first two words, or the first two characters of a one-word name), the selected window has a border, activity and exit markers stay visible, a click selects the window, the tooltip shows the full name, and the context menu still offers Rename, Move and Delete. Relaunch and confirm the sidebar stays collapsed. The state is a per-user preference and is not part of the workspace. |

## Tabs

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| FR-T01 | Support multiple tabs per window: create, rename inline from the tab bar, reorder, duplicate the configuration, and close. | Double-click a tab label or choose Rename. Enter commits, Escape cancels, and empty input keeps the name. The new name persists without restarting sessions. Duplicating a tab copies its layout and launch settings into new sessions and processes; it copies no output and no shell input. |
| FR-T02 | Show the selected window's own ordered tab bar above its terminal area, and switch tabs by mouse, keyboard or command service. | Switch between two windows with different tabs; each keeps its own tab order and selection. Every way of selecting a tab focuses the same pane. Tab separators, the new-tab button and rename are visible. |
| FR-T03 | Confirm before closing running sessions, and summarize the affected panes. | Closing a window with three running panes shows a single confirmation covering all three. |
| FR-T04 | Label a tab with one of seven colors (red, orange, yellow, green, blue, purple, gray) from the tab's **Color** context menu, the `tab.update` API method or `trellis tab color`. **None** removes the label. | A labeled tab shows a colored stripe along its top edge, a light tint and a tinted icon, selected or not. VoiceOver reads the color name with the tab position (for example "1 of 3, red label"), and hovering the stripe shows the name, so the label never relies on color alone. The label persists across relaunch, a duplicated tab keeps it, and changing it never restarts sessions. A saved color name that this build doesn't know loads as no label instead of triggering recovery. |
| FR-T05 | Show a busy bar along a tab's top edge while any of its panes is printing output. With shell integration, output at the prompt never counts. Output that arrives within 0.15 s of a keystroke is treated as typing echo and ignored, with or without integration (SSH, other shells). | Run `sleep 1; seq 1 3000000` in a tab, selected or not: its top edge fills and unfills while output arrives and stops about 0.8 s after it goes quiet. Typing at an idle prompt never shows it. With Reduce Motion on, the bar is static. Hovering shows "Printing output" and VoiceOver reads "output in progress" with the tab, so the cue never relies on motion or color alone. A labeled tab animates in its label color. Without integration, programs that redraw on a timer (`top`, `watch`, a tmux clock over SSH) count as output and keep the bar on. |
| FR-T06 | Label a tab whose running program is waiting for the user, without needing shell integration. A **password prompt** (the PTY has echo off with line editing on, as sudo, ssh and `read -s` do) labels the tab while it lasts, even when the tab is selected. A **bell** (BEL) or a **notification** (OSC 9 text, OSC 777 `notify`) labels the tab only when the pane isn't the focused pane of the selected tab. It clears when that pane is shown and focused, at the shell's next prompt, or when the session exits or restarts. With shell integration, nothing counts while the shell is at its own prompt. Notification text is never shown, stored or logged. | `sudo -k; sudo true` shows an "Input" capsule on the tab and "Password" in the pane header until the password is entered. `sleep 3; printf '\a'` in tab B while tab A is selected labels tab B; selecting tab B clears it. `printf '\e]9;done\a'` and `printf '\e]777;notify;T;B\a'` behave the same; `printf '\e]9;4;1;50\a'` (progress) doesn't. `vim`, `less` and a Tab-completion bell at the prompt never label a tab. The window list shows a keyboard symbol for windows with a waiting pane. Hovering the capsule shows "Waiting for a password" or "Waiting for input"; VoiceOver reads it with the tab, pane and window, so the cue never relies on color alone. `session.get` reports `waitingForInput: "password"\|"attention"`. |

## Panes and splits

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| FR-P01 | Split any pane left/right (`x`) or top/bottom (`y`), including nested splits. | Build a three-pane mixed-axis layout and verify each pane works on its own. |
| FR-P02 | Resize splits with draggable dividers and keyboard controls. | Ratios persist. Neither child can go below 20 columns × 5 rows. An invalid split returns a clear error. |
| FR-P03 | Collapse the parent branch when a pane closes. | Closing one leaf leaves its sibling filling the parent's region, and the remaining IDs don't change. Closing a tab's last pane closes the tab, and closing a window's last tab closes the window. |
| FR-P04 | Navigate panes by direction and temporarily maximize one. | Maximize and restore keep the tree and ratios intact, and focus indicators stay visible. |

Limits: split ratios are finite and between 0.1 and 0.9, nesting is at most 16 levels deep, and a workspace holds at most 100 panes. A mutation that fails never leaves a partial tree behind.

## Persistence and portability

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| FR-R01 | Save and restore the organization as stopped panes. | After a normal quit and relaunch, names and splits come back without running any command. |
| FR-R02 | Import and export layouts and host metadata, with a review summary. | Validate before changing anything, assign fresh IDs, leave out credentials, and refuse unsupported versions without a partial import. |

**File → Export Workspace…** and **File → Import Workspace…** implement FR-R02. The rules for portable documents are in [Integrations](../integrations.md#configuration-import-and-export), and the on-disk format is described in [Persistence](../architecture/persistence.md).

## Closing the native window

Closing the terminal-bearing native window while sessions are live asks once whether to end them. If you accept, the workspaces close and the app returns to its empty state. Reopening the main window shows the current state. Quitting has its own running-session confirmation. See [macOS support](../platform/macos.md) (`MAC-04`).
