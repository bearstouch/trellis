# Command palette

The command palette is one searchable list of everything Trellis can do and everywhere you can go. Open it with **View → Command Palette…** (⇧⌘P, rebindable). Type a few letters to run any action or to jump to a window, tab, pane, saved host, task or theme, without remembering its shortcut or menu.

It floats over the workspace: 640 points wide, centered, a little below the title bar, over a dimmed backdrop. Results update as you type.

All requirements here are P2.

## Requirements

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| FR-CP01 | ⇧⌘P (rebindable, **View → Command Palette…**) opens the palette over the workspace with its field focused; the same shortcut, Esc or a click on the backdrop closes it. | Opening focuses the field. Closing returns keyboard focus to the pane, or the scratchpad editor, that had it. A shortcut you had already bound to ⇧⌘P keeps it, and the palette starts unbound. |
| FR-CP02 | While the palette is open, terminal input is suspended and workspace menu shortcuts other than the palette's own are disabled. | Typing in the palette never reaches a shell, and ⌘D or ⌘1 does nothing behind it. Every pane takes input again after it closes. |
| FR-CP03 | Items: every keyboard-shortcut action that its menu would enable right now (with its current shortcut), every window, every tab and pane in every window, every saved host, the focused pane's project and detected tasks while that pane can run one, and every installed theme. Settings… is listed too. | An action the menu shows as disabled (Find Next with no terminal, Next Tab with one tab) isn't listed. A renamed shortcut shows its new chord. |
| FR-CP04 | Fuzzy matching, case-insensitive: the letters must appear in order. Prefix, word-start and consecutive matches rank higher; gaps rank lower. A match in the title outranks one in an alias keyword or the subtitle. Recently used items get a small boost; equal scores follow the kind order Actions, Tabs, Windows, Panes, Hosts, Tasks, Themes. Results are grouped by kind, and groups are ordered by their best match. The top result is selected. | “spl” lists Split Left/Right and Split Top/Bottom first, with the matched letters bold and underlined. “split” also finds Maximize / Restore Pane through its alias. Gibberish shows **No matches** and the result count reads 0. |
| FR-CP05 | With an empty field: up to 3 recently used items that still exist, then suggestions (the scopes and New Tab). Recents are kept in memory as item IDs for this launch only, never persisted, and the query is never stored or logged. | After running Split Left/Right, it appears under **Recent** the next time. Closing a tab removes it from Recent. |
| FR-CP06 | Scopes: **Go to Window…**, **Go to Tab…**, **Go to Pane…**, **Connect to Host…**, **Run Task…** and **Use Theme…** list one kind only, grouped by window where that applies. Tab or Return on a scope row enters it; ⌫ in an empty field leaves it. | Go to Tab lists every tab of every window under its window's name, with the current window first. |
| FR-CP07 | Return runs the selected item through the same path as its menu item or control: an action runs as if chosen from its menu, a window, tab or pane is selected and focused, a host connects in a new tab (⌘Return: new window; ⌥Return: split), a task runs in the focused pane (the `launch.json` trust review still applies) and a theme is applied. The palette closes first. | Each kind does the same as its menu command or control, including errors and reviews. A failed action leaves the workspace as it was. |
| FR-CP08 | Moving the selection onto a theme previews it in the workspace (opening the palette with a theme on top doesn't); Esc or moving to another item restores the previous colors exactly. The palette never touches a preview that Settings started. | Arrowing through themes and pressing Esc leaves the appearance settings and effective theme unchanged. |

## Keyboard

| Key | Does |
| --- | --- |
| ⇧⌘P | Open or close |
| ↑ ↓, ⌃P ⌃N | Move the selection (wraps) |
| Return | Run the selected item |
| ⌘Return, ⌥Return | Host: connect in a new window, or in a split |
| Tab | Enter the selected scope |
| ⌫ in an empty field | Leave the scope |
| ⌘⌫ | Clear the field |
| Esc | Close; cancels a theme preview |

## Items

| Kind | Subtitle | Return |
| --- | --- | --- |
| Action | Menu (File, Edit, View, Pane, Window) | Same as the menu item |
| Window | Number of tabs, “current” | Select the window |
| Tab | Window › position · status | Select the window and the tab |
| Pane | Window › tab · status | Show and focus the pane |
| Host | `user@destination`, port | Connect in a new tab |
| Task | `.trellis/launch.json` or where it was detected, with the command | Run in the focused pane |
| Theme | Light or Dark, “current” | Use the theme |

Statuses are words (Running, Stopped, Exited (0), Failed to start), never color alone.

## Accessibility

- The palette is a modal group named “Command Palette”. The field is named “Search commands” and the list “Results”.
- Each row reads its title, kind and subtitle, and its shortcut if it has one, for example “Split Left/Right, Pane action, ⌘D”. The selected row has the selected trait.
- The result count is announced when it changes.
- Selection is shown by a fill and a ↩ badge, and matches by bold and underline, never by color alone.
- With Reduce Motion, the palette opens and closes without animation. Otherwise it fades and scales in over 120 ms.

## Not included

Saved scratchpads aren't palette items yet: opening one from the palette would skip the panel's unsaved-changes confirmation (FR-SP10). **Toggle Scratchpad** is listed.
