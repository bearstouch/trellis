# Command palette

The command palette is one searchable list of everything Trellis can do and everywhere you can go. Type a few letters to run any menu action, or to jump to a space, tab, pane, saved host, task, theme or recent directory, without remembering its shortcut or where it lives in the menus.

## Open and close it

Choose **View → Command Palette…** or press <kbd>⇧</kbd><kbd>⌘</kbd><kbd>P</kbd>. The palette opens over the workspace with its search field ready. Press <kbd>⇧</kbd><kbd>⌘</kbd><kbd>P</kbd> again, press <kbd>Esc</kbd>, or click outside it to close it. The keyboard goes back to the pane you were using.

While the palette is open, nothing you type reaches a terminal, and other menu shortcuts such as <kbd>⌘</kbd><kbd>D</kbd> or <kbd>⌘</kbd><kbd>1</kbd> are paused until it closes.

You can change the shortcut in **Settings → Keyboard**. If you had already given <kbd>⇧</kbd><kbd>⌘</kbd><kbd>P</kbd> to another action, it keeps it and the palette starts with no shortcut.

## What it finds

| Kind | Shown with | Return does |
| --- | --- | --- |
| **Action** | Its menu (File, Edit, View, Pane, Window) and current shortcut | The same as choosing it from the menu |
| **Space** | Number of tabs, and "current" for the selected one | Selects the space |
| **Tab** | Space › position · status | Selects the space and the tab |
| **Pane** | Space › tab · status | Shows and focuses the pane |
| **Host** | `user@destination` and port | Connects in a new tab |
| **Task** | Where the task comes from (such as `.trellis/launch.json`) and its command | Runs it in the focused pane |
| **Theme** | Light or Dark, and "current" | Uses the theme |
| **Directory** | Machine, visits and last visit | Changes to it in the focused pane if that pane is on the same machine and idle; otherwise opens a new tab there |

Actions are listed only when their menu item would work right now, so **Find Next** doesn't appear with no terminal, nor **Next Tab** with only one tab. **Settings…**, **Welcome Tour** and **Toggle Scratchpad** are listed too. Tasks are the focused pane's [project tasks](tasks.md), shown while that pane can run one. Directories come from [directory jump](directory-jump.md).

Statuses are shown as words: Running, Stopped, Exited (0), Failed to start.

## Search

Type any letters that appear in order in what you want. Case doesn't matter, so "spl" finds **Split Left/Right** and **Split Top/Bottom**. Matched letters are shown in bold and underlined.

Matches at the start of a word or in a row rank higher, and a match in the name ranks above one in the details. Some actions also answer to related words, so "split" also finds **Maximize / Restore Pane**. Items you used recently, and directories you visit often, get a small boost. Results are grouped by kind, and the best match is selected.

If nothing matches, the palette says **No matches**.

With the field empty, the palette shows up to three items you used recently under **Recent**, followed by suggestions, such as the scopes below and **New Tab**. Recent items are remembered only until you quit Trellis, and what you type is never saved.

## Narrow to one kind

Scopes list one kind of item only:

- **Go to Space…**
- **Go to Tab…** (every tab, grouped by space, with the current space first)
- **Go to Pane…**
- **Connect to Host…**
- **Run Task…**
- **Use Theme…**
- **Jump to Directory…**

Select a scope and press <kbd>Tab</kbd> or <kbd>Return</kbd> to enter it. Press <kbd>⌫</kbd> in an empty field to leave it.

## Run an item

Press <kbd>Return</kbd> to run the selected item. The palette closes first, then the item does exactly what its menu command or control does, including any confirmation or review. For example, a task from a `.trellis/launch.json` file still goes through the usual trust review. If an action fails, your workspace is left as it was.

For hosts and directories you can choose where they open:

- <kbd>⌘</kbd><kbd>Return</kbd>: a host connects in a new space; a directory opens in a new tab.
- <kbd>⌥</kbd><kbd>Return</kbd>: either opens in a split beside the focused pane.

## Preview themes

Moving the selection onto a theme previews it on the whole workspace. Press <kbd>Return</kbd> to keep it. Press <kbd>Esc</kbd>, or move to another item, to put your previous colors back exactly as they were. Previewing never changes your saved appearance settings.

## Keyboard

| Key | Does |
| --- | --- |
| <kbd>⇧</kbd><kbd>⌘</kbd><kbd>P</kbd> | Open or close |
| <kbd>↑</kbd> <kbd>↓</kbd>, or <kbd>⌃</kbd><kbd>P</kbd> <kbd>⌃</kbd><kbd>N</kbd> | Move the selection (wraps around) |
| <kbd>Return</kbd> | Run the selected item |
| <kbd>⌘</kbd><kbd>Return</kbd> | Host: connect in a new space. Directory: open in a new tab |
| <kbd>⌥</kbd><kbd>Return</kbd> | Host or directory: open in a split |
| <kbd>Tab</kbd> | Enter the selected scope |
| <kbd>⌫</kbd> in an empty field | Leave the scope |
| <kbd>⌘</kbd><kbd>⌫</kbd> | Clear the field |
| <kbd>Esc</kbd> | Close, and cancel a theme preview |

## Accessibility

- VoiceOver reads each row's title, kind and details, and its shortcut if it has one, for example "Split Left/Right, Pane action, ⌘D". The number of results is announced as it changes.
- The selected row is shown with a fill and a ↩ badge, and matches with bold and underline, never by color alone.
- With Reduce Motion on, the palette opens and closes without animation.

## Limits

- Saved scratchpads aren't listed yet; open them from the [scratchpad](scratchpad.md). **Toggle Scratchpad** is listed.
- Searches longer than 64 letters match nothing, and only the first 512 characters of each name and its details are searched, so typing stays fast.
