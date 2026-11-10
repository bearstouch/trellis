# Right sidebar and dock

!!! note "New in 1.2 beta"
    The right sidebar and its dock arrived in 1.2.0-beta.1. They replace the **Scratchpad**, **Tasks** and **Agent** buttons that pane headers had in earlier versions.

[Files](files.md), [Changes](changes.md), the [scratchpad](scratchpad.md), [tasks](tasks.md) and [coding agents](agents.md) share one sidebar on the right of the window. A narrow **dock** along the window's right edge switches between them, like an editor's activity bar.

## Show and hide a view

Click an icon in the dock to show that view in the sidebar. Click the icon of the view that's already shown to hide the sidebar; the keyboard goes back to the focused terminal. Only one view is shown at a time, and clicking another icon replaces it.

| Icon | View | Shortcut |
| --- | --- | --- |
| Folder | [Files](files.md) | <kbd>⌥</kbd><kbd>⌘</kbd><kbd>F</kbd> |
| Branch | [Changes](changes.md) | <kbd>⌥</kbd><kbd>⌘</kbd><kbd>G</kbd> |
| `</>` | [Scratchpad](scratchpad.md) | <kbd>⌥</kbd><kbd>⌘</kbd><kbd>E</kbd> |
| Play | [Tasks](tasks.md) | <kbd>⌥</kbd><kbd>⌘</kbd><kbd>T</kbd> |
| Sparkles | [Agents](agents.md) | <kbd>⌥</kbd><kbd>⌘</kbd><kbd>A</kbd> |

The **View** menu has the same commands (**Show Files** / **Hide Files**, **Show Changes**, **Show Scratchpad**, **Show Tasks** and **Show Agents**), and so does the [command palette](command-palette.md). Showing Files puts the keyboard in its search field; showing the scratchpad puts it in the editor.

You can change these shortcuts in **Settings → Keyboard**, where they're listed as **Toggle Files**, **Toggle Changes**, **Toggle Scratchpad**, **Toggle Tasks** and **Toggle Agents**. If you had already given one of these key combinations to another command, your binding wins and the sidebar command starts without a shortcut.

The dock is shown whenever the space has panes. It's hidden on the empty-workspace, restoring and recovery screens. Hover an icon to see its name and shortcut; the view that's shown is marked with an accent bar beside its icon.

## Resize the sidebar

Drag the sidebar's left edge to make it wider or narrower, between 280 and 640 points (380 by default). All views share the same width, so switching views keeps it. The panes take the rest of the window.

Showing, hiding, switching and resizing don't change your saved workspace, and Trellis doesn't remember which view was open.

## Views follow the focused pane

Every view works with the **focused pane** and follows focus as you move between panes:

- **Files** shows the pane's project.
- **Changes** shows the uncommitted changes in the pane's git repository.
- The **scratchpad** sends its text to the pane.
- **Tasks** lists the pane's project tasks and runs them in it.
- **Agents** opens agents in the pane's folder, on the pane's machine.

Not every view works with every kind of pane:

| Focused pane | Files | Changes | Scratchpad | Tasks | Agents |
| --- | --- | --- | --- | --- | --- |
| A shell or agent on this Mac | Yes | Yes | Yes | Yes | Yes |
| A shell or agent in a [remote workspace](remote-workspaces.md) | No | No | No | Yes | Yes |
| An [SSH](ssh-hosts.md) pane (a saved host, or a pane started straight into `ssh`, `mosh` or `autossh`) | No | No | No | No | No |

When a view doesn't apply to the focused pane, its icon is dimmed and can't be clicked; hover it to see why. Its shortcut and menu item do nothing either. If the open view doesn't apply to a pane you focus, the sidebar hides, and it comes back when you focus a pane it applies to. With no pane focused, every icon is dimmed.

## Badges

Numbers on the dock icons show what needs your attention:

| Icon | Badge |
| --- | --- |
| Changes | How many files have changed in the focused pane's repository |
| Tasks | How many tasks are starting or running, in any pane |
| Agents | How many agent panes are waiting on you (**Needs you**), in any space |

There is no badge when the count is zero. Badges stay visible while an icon is dimmed, and VoiceOver reads them too ("2 running", "1 needs you").

## Pane headers

Pane headers keep only the pane's own tools: its title, folder, status (exit code, input, progress), the machine it runs on, **Resume** or **Restart** where they apply, and **Maximize**, the split buttons and **Close**. An agent's state and the pane's git status show on the tab and in the dock instead.
