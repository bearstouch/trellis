# Keyboard and accessibility

Everything you do every day in Trellis has a keyboard shortcut, and you can change almost all of them. This page lists the defaults, shows how to rebind them, and describes how Trellis works with VoiceOver and the macOS accessibility settings.

Menus always show your current shortcuts, so the menu bar is the quickest place to check one.

## Default shortcuts

### File

| Action | Shortcut |
| --- | --- |
| New Space | <kbd>⌘</kbd><kbd>N</kbd> |
| New Tab | <kbd>⌘</kbd><kbd>T</kbd> |
| Close Pane (closes the tab when it has one pane) | <kbd>⌘</kbd><kbd>W</kbd> |
| Close Tab | <kbd>⇧</kbd><kbd>⌘</kbd><kbd>W</kbd> |
| Projects… | <kbd>⌘</kbd><kbd>O</kbd> |
| Save Workspace | <kbd>⌘</kbd><kbd>S</kbd> |
| Rename Tab…, Rename Space…, Delete Space…, Hosts… | None by default |

When another Trellis window, such as Settings, is in front, <kbd>⌘</kbd><kbd>W</kbd> closes that window instead.

### Edit

| Action | Shortcut |
| --- | --- |
| Find in Pane… | <kbd>⌘</kbd><kbd>F</kbd> |
| Find Next / Find Previous | <kbd>⌘</kbd><kbd>G</kbd> / <kbd>⇧</kbd><kbd>⌘</kbd><kbd>G</kbd> |
| Previous Prompt / Next Prompt | <kbd>⌘</kbd><kbd>↑</kbd> / <kbd>⌘</kbd><kbd>↓</kbd> |
| Clear (the focused pane) | <kbd>⌘</kbd><kbd>K</kbd> |

Previous Prompt and Next Prompt need [shell integration](shell-integration.md).

### View

| Action | Shortcut |
| --- | --- |
| [Command Palette…](command-palette.md) | <kbd>⇧</kbd><kbd>⌘</kbd><kbd>P</kbd> |
| [Jump to Directory…](directory-jump.md) | <kbd>⌘</kbd><kbd>J</kbd> |
| Toggle Sidebar (the left sidebar) | <kbd>⌃</kbd><kbd>⌘</kbd><kbd>S</kbd> |
| Toggle [Files](files.md) | <kbd>⌥</kbd><kbd>⌘</kbd><kbd>F</kbd> |
| Toggle [Changes](changes.md) | <kbd>⌥</kbd><kbd>⌘</kbd><kbd>G</kbd> |
| Toggle [Scratchpad](scratchpad.md) | <kbd>⌥</kbd><kbd>⌘</kbd><kbd>E</kbd> |
| Toggle [Tasks](tasks.md) | <kbd>⌥</kbd><kbd>⌘</kbd><kbd>T</kbd> |
| Toggle [Agents](agents.md) | <kbd>⌥</kbd><kbd>⌘</kbd><kbd>A</kbd> |
| Zoom In | <kbd>⌘</kbd><kbd>+</kbd> (<kbd>⌘</kbd><kbd>=</kbd> also works) |
| Zoom Out | <kbd>⌘</kbd><kbd>-</kbd> |
| Actual Size | <kbd>⌘</kbd><kbd>0</kbd> |

The Files, Changes, Scratchpad, Tasks and Agents views open in the [right sidebar](sidebar.md).

!!! note "New in 1.2"
    The Files (<kbd>⌥</kbd><kbd>⌘</kbd><kbd>F</kbd>) and Changes (<kbd>⌥</kbd><kbd>⌘</kbd><kbd>G</kbd>) views first shipped in 1.2.

### Pane

| Action | Shortcut |
| --- | --- |
| Split Left/Right | <kbd>⌘</kbd><kbd>D</kbd> |
| Split Top/Bottom | <kbd>⇧</kbd><kbd>⌘</kbd><kbd>D</kbd> |
| Focus Left / Right / Up / Down | <kbd>⌥</kbd><kbd>⌘</kbd> + arrow key |
| Move Divider Left / Right / Up / Down | <kbd>⌥</kbd><kbd>⇧</kbd><kbd>⌘</kbd> + arrow key |
| Maximize / Restore Pane | <kbd>⇧</kbd><kbd>⌘</kbd><kbd>Return</kbd> |

### Window

| Action | Shortcut |
| --- | --- |
| Previous Space / Next Space | <kbd>⌃</kbd><kbd>⌘</kbd><kbd>[</kbd> / <kbd>⌃</kbd><kbd>⌘</kbd><kbd>]</kbd> |
| Previous Tab / Next Tab | <kbd>⇧</kbd><kbd>⌘</kbd><kbd>[</kbd> / <kbd>⇧</kbd><kbd>⌘</kbd><kbd>]</kbd> |
| Select Tab 1–9 | <kbd>⌘</kbd><kbd>1</kbd> – <kbd>⌘</kbd><kbd>9</kbd> |

### Standard macOS shortcuts

These work as in any Mac app and can't be changed: **Settings…** (<kbd>⌘</kbd><kbd>,</kbd>), **Hide Trellis** (<kbd>⌘</kbd><kbd>H</kbd>), **Quit Trellis** (<kbd>⌘</kbd><kbd>Q</kbd>), **Undo** and **Redo** (<kbd>⌘</kbd><kbd>Z</kbd>, <kbd>⇧</kbd><kbd>⌘</kbd><kbd>Z</kbd>), **Cut**, **Copy** and **Paste** (<kbd>⌘</kbd><kbd>X</kbd>, <kbd>⌘</kbd><kbd>C</kbd>, <kbd>⌘</kbd><kbd>V</kbd>), **Select All** (<kbd>⌘</kbd><kbd>A</kbd>) and **Minimize** (<kbd>⌘</kbd><kbd>M</kbd>).

In a terminal pane, <kbd>⌘</kbd><kbd>C</kbd> and <kbd>⌘</kbd><kbd>V</kbd> always copy and paste, and <kbd>⌃</kbd><kbd>C</kbd> always interrupts the running program.

## Change a shortcut

Open **Settings → Keyboard**. Shortcuts are grouped by menu: File, Edit, View, Pane and Window.

1. Click the shortcut next to an action. The button reads **Type shortcut…**.
2. Press the new key combination. Press <kbd>Esc</kbd> to cancel without changing anything.
3. Click **Save Shortcuts**.

To remove a shortcut, click **Clear** next to it. An action without a shortcut is still in its menu and in the [command palette](command-palette.md).

**Revert** discards changes you haven't saved. **Restore Defaults** puts every shortcut back to the default; click **Save Shortcuts** to keep that.

Trellis checks your changes before saving them:

- **Every shortcut must include <kbd>⌘</kbd>.** This keeps <kbd>⌃</kbd> and <kbd>⌥</kbd> key combinations free for programs running in your terminals.
- **Two actions can't share a shortcut.** Trellis names both actions, and **Save Shortcuts** stays unavailable until you resolve it. You can swap two shortcuts in steps: problems only block saving, not editing.
- **Some combinations are reserved:** the standard macOS shortcuts above, and system ones such as <kbd>⌥</kbd><kbd>⌘</kbd><kbd>H</kbd> (Hide Others), <kbd>⌘</kbd><kbd>`</kbd> (cycle windows), <kbd>⌘</kbd><kbd>Tab</kbd> and <kbd>⌘</kbd><kbd>Space</kbd>.

If you upgrade and a new default shortcut matches one you had already assigned to something else, yours is kept and the new action starts with no shortcut.

## Option as Meta

Some terminal programs, such as Emacs or shell line editing, use Meta key combinations. Turn on **Settings → Keyboard → Use Option as Meta key** to make <kbd>⌥</kbd> send them.

It's off by default. When it's off, <kbd>⌥</kbd> types accented characters, symbols and dead keys, as it does in other Mac apps, which many keyboard layouts need.

## Readable text

In **Settings → Appearance** you choose the terminal font and size (8 to 48 points), the cursor style, and the light and dark themes. Changes apply at once, without restarting sessions. Zoom In, Zoom Out and Actual Size adjust the text size from the keyboard.

Trellis comes with six terminal fonts, so they're always available: JetBrains Mono (the default), Roboto Mono, Cascadia Mono NF, IBM Plex Mono, Iosevka Fixed and Atkinson Hyperlegible Mono, a typeface designed for legibility. If a saved font is missing or isn't monospaced, Trellis falls back to a system monospaced font and tells you.

See [Themes](themes.md) and [Terminal](terminal.md) for colors and text rendering.

## VoiceOver

Sidebar spaces, tabs and terminal panes have spoken labels that include their status in words. For example:

- A space: "Space Project, 2 tabs, new output". A space also reports when a session in it exited or is waiting for input.
- A tab: "Tab Build, 1 of 2". A tab with a color label adds the color name, such as "red label", and a temporary tab in a project's space is read as "temporary tab".
- A pane: "Terminal Server, Exited (7), focused". Pane status also says when a program is waiting for a password or for input, or when the last command failed.

The selected space, tab and focused pane are reported as selected. Spaces offer **Move Up** and **Move Down** actions, so you can reorder them without dragging.

## Status never relies on color alone

Wherever Trellis uses color, it also uses shape, weight or words:

- The selected space and tab are marked by shape and weight, such as a tab underline and a semibold pane title, not only by color.
- With several panes visible, the focused pane's header is marked and the other panes are slightly dimmed.
- Stopped, exited and failed panes show their status as text.
- A tab's color label also shows its name when you hover over it.

## macOS accessibility settings

Trellis follows the system appearance and these settings in **System Settings → Accessibility → Display**:

- **Increase Contrast**: panes are never dimmed, translucent panes stay opaque, and the welcome tour's borders and backdrop get stronger.
- **Reduce Motion**: the welcome tour's step animation is removed, busy spinners and the moving edge on a working agent's tab hold still, and blinking text stays steady.
- **Reduce Transparency**: terminal panes stay opaque even if you've set a translucent background.

## Typing stays where you expect

- While you rename a tab, terminal input is paused, so your keystrokes can't reach a shell.
- While the welcome tour is open, typing doesn't reach a shell either.
- Trellis never asks for Accessibility permission and never monitors keystrokes system-wide.
