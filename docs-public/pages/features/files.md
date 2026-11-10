# Files

!!! note "New in 1.2 beta"
    The Files view arrived in 1.2.0-beta.1.

The **Files** view in the [right sidebar](sidebar.md) shows the focused pane's project as a tree. Use it to find a file, open it in your editor or copy its path without leaving the terminal. Show it with the folder icon at the top of the dock, or press <kbd>⌥</kbd><kbd>⌘</kbd><kbd>F</kbd> (**View → Show Files**). The keyboard goes straight to the search field.

## Which folder it shows

The tree starts at the focused pane's **project**: the nearest folder, at or above the pane's folder, that contains `.trellis` or `.git` (the same rule [tasks](tasks.md) use). Outside a project, it starts at the pane's folder itself. The pane's folder is the one its shell last reported through [shell integration](shell-integration.md), or else the one it started in.

When you `cd` in the pane, or focus another pane, the tree moves with it. The root is shown above the tree, with `~` for your home folder. A pane with no local folder shows "No folder".

Files works only for panes on this Mac. Its icon is dimmed for [SSH](ssh-hosts.md) panes and [remote workspace](remote-workspaces.md) panes, because Trellis can't list their files.

## What's left out

The tree never shows `.git`, `.build`, `.swiftpm`, `node_modules`, `DerivedData` or `.DS_Store`, nor anything the project's `.gitignore` ignores. Hidden files (names starting with `.`) appear only while the eye button at the top of the view is on.

Trellis reads the simple parts of the `.gitignore` at the root of the tree: `#` comments, `*`, `?` and `[…]` globs, a trailing `/` for folders, and a leading or inner `/` to anchor a pattern to the root. It skips negations (`!`), and doesn't read nested `.gitignore` files or your global excludes, so a few ignored files can still show up.

## Browse and search

| Do this | To |
| --- | --- |
| Click a folder, or press <kbd>→</kbd> / <kbd>←</kbd> | Open or close it |
| <kbd>↑</kbd> / <kbd>↓</kbd> | Move the selection |
| Type in **Search files…** | Find files by name anywhere in the project |
| <kbd>Esc</kbd> | Clear the search and show the tree again |

Search matches the letters you type in order, like the [command palette](command-palette.md). Include a `/` to match against the path instead of only the name. Results show each file's name, with the matched letters highlighted, and its folder; the best match is selected, so Return opens it.

Folders are read when you first open them. The folders you've opened are remembered per project while Trellis runs. The collapse button at the top of the view closes them all, and the reload button reads them again from disk.

## Open a file in your editor

Press <kbd>Return</kbd>, double-click a row, or click **Open in** to open the selection in your chosen app. With nothing selected, **Open in** opens the project folder.

Click the arrow beside **Open in** to choose another app. Trellis remembers your choice for next time, and the [Changes](changes.md) view uses the same app. The list has:

- **Finder**, the default. It reveals a file and opens a folder.
- Each of these editors that is installed: Cursor, VS Code (or VS Code Insiders or VSCodium), Zed, Xcode, Sublime Text, Nova, IntelliJ IDEA, WebStorm and PyCharm.
- **Default App**: whatever macOS normally opens the file with.
- **New Tab Here**: a Trellis tab in the file's folder.
- **Other App…**: pick any app for this one time, without remembering it.

If the app you chose has since been removed, Trellis says it isn't installed on this Mac and opens nothing.

!!! tip "Nothing runs by itself"
    **Finder** and **Default App** never launch anything. An app, a script, an executable or another launchable file is shown in Finder instead of opened, just as with [links in the terminal](terminal.md).

## Copy and insert paths

| Do this | To |
| --- | --- |
| <kbd>⇧</kbd><kbd>⌘</kbd><kbd>C</kbd>, or the copy button on the row | Copy the full path |
| <kbd>⌥</kbd><kbd>⇧</kbd><kbd>⌘</kbd><kbd>C</kbd> | Copy the path relative to the project |
| <kbd>⌥</kbd><kbd>Return</kbd> | Insert the path at the pane's prompt, quoted for the shell |
| Drag a row onto a pane | Insert its quoted path, as when [dropping a file from Finder](terminal.md) |

Trellis confirms a copy with a short "Copied …" message. Inserting a path only types it; nothing is run until you press Return.

Right-click a row for more: **Open in** your chosen app, **Open With**, **Reveal in Finder**, **Copy Path**, **Copy Relative Path**, **Copy Name**, **Insert Path in Terminal**, and **Type cd to This Folder** (or **Type cd to Its Folder** on a file), which types `cd '<folder>'` at the prompt without pressing Return.

## Limits

- Search looks through the first 20,000 files of the project and says so when it stops there. At most 200 results are shown.
- A symbolic link is listed, but never opened as a folder, so the tree can't loop.
- A folder Trellis can't read shows "Can't read this folder" under it; the rest of the tree still works.
- Which folders are open is never saved; it lasts until you quit.
