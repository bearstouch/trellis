# Right sidebar and dock

The [files](files.md), [scratchpad](scratchpad.md), [tasks](tasks.md) and [coding agents](agents.md) share one sidebar on the right of the window. A narrow **dock** along the window's right edge switches between them, like an editor's activity bar: click an icon to show that view, click the shown view's icon again to hide the sidebar. The dock stays visible while the window has panes.

All four views act on the **focused pane**: Files shows its project, the scratchpad runs in it, Tasks lists its project's tasks and runs them in it, and Agents opens agents in its folder and on its machine. Pane headers keep only the pane's own tools (machine, maximize, split, close); the **Scratchpad**, **Tasks** and **Agent** header buttons of earlier versions moved to the dock.

All requirements here are P1.

## The dock

| Icon | View | Shortcut (rebindable) | Badge |
| --- | --- | --- | --- |
| Folder | [Files](files.md) | ⌥⌘F | — |
| `</>` | [Scratchpad](scratchpad.md) | ⌥⌘E | — |
| Checklist | [Tasks](tasks.md) | ⌥⌘T | How many tasks are running in any pane |
| Sparkles | [Agents](agents.md) | ⌥⌘A | How many agent panes need you, in any window |

**View → Show/Hide Files**, **Show/Hide Scratchpad**, **Show/Hide Tasks** and **Show/Hide Agents**, and the command palette, do the same as the icons.

## Panes the views don't apply to

| Focused pane | Files | Scratchpad | Tasks | Agents |
| --- | --- | --- | --- | --- |
| Local shell or agent | ✓ | ✓ | ✓ | ✓ |
| [Remote workspace](remote-workspaces.md) shell or agent | Dimmed | Dimmed | ✓ (FR-RW11) | ✓ |
| SSH (a saved host, or a pane started straight into `ssh`, `mosh` or `autossh`) | Dimmed | Dimmed | Dimmed | Dimmed |

A dimmed icon can't be clicked; its tooltip and VoiceOver hint say why. If the open view doesn't apply to the newly focused pane, the sidebar hides and comes back when a pane it applies to is focused again.

## Requirements

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| FR-SB01 | Show a dock on the window's right edge. | While the window has a pane, a dock to the right of the tab bar and panes shows the Files, Scratchpad, Tasks and Agents icons, top to bottom. It is hidden on the empty-window, restoring and recovery screens. Each icon has a tooltip with its name and shortcut, the accessibility label of its name, and the selected trait while its view is shown; the shown view's icon is also marked by an accent bar, not color alone. |
| FR-SB02 | Switch views in one shared sidebar. | Clicking an icon (or its shortcut, menu item or palette command) shows that view in the sidebar, replacing the one shown. Doing it again for the shown view hides the sidebar and returns keyboard focus to the focused terminal. Showing the Scratchpad focuses its editor; showing Files focuses its search field. Only one view is shown at a time. |
| FR-SB03 | Share one width. | The sidebar sits right of the panes and below the tab bar. It is 380 points wide by default, 280–640 by dragging its left edge or with VoiceOver's adjust actions, and switching views keeps the width. The canvas takes the rest, so split minimums still apply. Showing, hiding, switching and resizing never change the saved workspace; which view was open isn't saved. |
| FR-SB04 | Follow the focused pane, and dim views that don't apply. | Every view acts on the focused pane and follows focus as it moves. Per the table above, Files and the Scratchpad apply only to panes on this Mac, Tasks and Agents to local and remote workspace panes, and nothing to SSH panes. A view that doesn't apply has a dimmed icon that can't be activated (its tooltip and hint say why), and its shortcut and menu item do nothing. When focus moves to a pane the open view doesn't apply to, the sidebar hides; when focus returns to a pane it applies to, it shows again. With no pane focused, every icon is dimmed. |
| FR-SB05 | Badge the dock with what needs attention, in numbers. | The Tasks icon shows the number of task runs that are starting or running, in every pane (FR-TK07). The Agents icon shows the number of running agent panes whose state is **Needs you**, in every window (FR-AG10). A zero shows no badge. Badges are text in a capsule, and the icon's accessibility value says the same ("2 running", "1 needs you"). Badges show while the icon is dimmed. |
| FR-SB06 | Keep pane headers to the pane's own tools. | Pane headers show no Scratchpad, Tasks or Agent button. They keep the title, folder, status words (exit code, input, progress, agent state, git status), the machine label, Resume/Restart where they apply, and Maximize, Split Left/Right, Split Top/Bottom and Close. |
| FR-SB07 | Bind each view to a rebindable shortcut. | Toggle Files is ⌥⌘F, Toggle Scratchpad ⌥⌘E, Toggle Tasks ⌥⌘T and Toggle Agents ⌥⌘A by default, all in the View menu and Settings → Keyboard. Like other later defaults, Toggle Files, Toggle Tasks and Toggle Agents start unbound when you had already assigned their chord to something else. |

## Verification

| Area | How it's checked |
| --- | --- |
| Switching, hiding, focus and width (FR-SB02–FR-SB04) | `RightSidebarTests`: toggling each view, switching between views, the workspace snapshot unchanged, the editor focus request, dimmed views for SSH and remote workspace panes, hiding and showing again as focus moves. |
| Badges (FR-SB05) | `RightSidebarTests`: the running-task and needs-you counts across panes and windows. |
| Shortcuts (FR-SB07) | `KeyboardShortcutTests`: defaults, menu, and later defaults yielding to saved chords. |
| Dock, header and VoiceOver (FR-SB01, FR-SB06) | Manual: **pending** (VoiceOver walk of the dock and sidebar). |
