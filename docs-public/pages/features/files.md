# Files

!!! note "New in 1.2"
    The Files view arrived in 1.2.

The **Files** view in the [right sidebar](sidebar.md) shows the focused pane's project as a tree. Use it to find a file, open it in your editor or copy its path without leaving the terminal. Show it with the folder icon at the top of the dock, or press <kbd>⌥</kbd><kbd>⌘</kbd><kbd>F</kbd> (**View → Show Files**). The keyboard goes straight to the search field.

## Which folder it shows

The tree starts at the focused pane's **project**: the nearest folder, at or above the pane's folder, that contains `.trellis` or `.git` (the same rule [tasks](tasks.md) use). Outside a project, it starts at the pane's folder itself. The pane's folder is the one its shell last reported through [shell integration](shell-integration.md), or else the one it started in.

When you `cd` in the pane, or focus another pane, the tree moves with it. The root is shown above the tree, with `~` for your home folder. A pane with no local folder shows "No folder".

Files works for panes on this Mac and for [remote workspace](remote-workspaces.md) panes, where it shows the project on the host (see [On a remote workspace](#on-a-remote-workspace)). Its icon is dimmed for [SSH](ssh-hosts.md) panes, because Trellis can't list their files.

## What's left out

!!! note "New in 1.3"
    The ignored-files button is new in 1.3. Before, `.gitignore`'d files were never shown.

The tree never shows `.git`, `.build`, `.swiftpm`, `node_modules`, `DerivedData` or `.DS_Store`. Files the project's `.gitignore` ignores appear only while the ignored-files button (the filter symbol at the top of the view) is on, and hidden files (names starting with `.`) only while the eye button is on. To see a `.env` file, which is usually both hidden and ignored, turn both on.

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

Press <kbd>Return</kbd>, double-click a row, or click **Open in** to open the selection in your chosen app. Double-clicking a code file always opens it in a Trellis [editor tab](editor.md), whichever app you chose. With nothing selected, **Open in** opens the project folder.

Click the arrow beside **Open in** to choose another app. Trellis remembers your choice for next time, and the [Changes](changes.md) view uses the same app. The list has:

- **Trellis Editor**, the default. It opens a text file in an [editor tab](editor.md) of the current space; a folder is shown in Finder.
- **Finder**. It reveals a file and opens a folder.
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
| Drag files from Finder onto a folder | Copy them into it (see [Copying files](#copying-files)) |
| Drag a row onto Finder or the desktop | Copy the file or folder there |

Trellis confirms a copy with a short "Copied …" message. Inserting a path only types it; nothing is run until you press Return.

Right-click a row for more: **Open in** your chosen app, **Open With**, **Reveal in Finder**, **Copy Path**, **Copy Relative Path**, **Copy Name**, **Insert Path in Terminal**, and **Type cd to This Folder** (or **Type cd to Its Folder** on a file), which types `cd '<folder>'` at the prompt without pressing Return.

## On a remote workspace

In a remote workspace pane, Files shows the project **on the host**, found the same way from the folder the pane's shell is in. The line under the header names the host. The tree, search, the hidden and ignored toggles, the copy commands, **Insert Path in Terminal** and **Type cd** work as they do on this Mac, with the host's paths.

A few things are different:

- **Files open read-only.** <kbd>Return</kbd>, a double click or **Open in** shows the file in a [read-only editor tab](editor.md#read-only-files-from-a-remote-workspace). **Open in** offers only **Trellis Editor** and **New Tab Here**; Finder and the editors on this Mac aren't offered, because they can't reach a file on the host.
- **A folder opens a tab.** Opening a folder, or choosing **New Tab Here** on a file, opens a new tab in that folder on the host.
- **Trellis changes the host only when you drop files on it.** Otherwise it only lists the folders you open and reads the files you open, through the Trellis helper there.
- **Dragging a row out copies it.** Dropped on Finder or the desktop, a row of the host's tree is copied there from the host. To put its path at a prompt, use **Insert Path in Terminal**.
- **Very long folders are cut short.** A folder with more than 10,000 entries shows the first 10,000 and says so.
- **The host must be connected.** While it isn't, the tree you already had stays, with a note that it may be out of date, and it is read again when the connection is back.

If Files says "Update the Trellis helper on … to browse its files.", open **Hosts**, select the host and choose **Update Helper…**.

## Copying files

You can drag files between Files and Finder in both directions, on this Mac and on a remote workspace's host:

- **Into the tree:** drop files or folders from Finder on a folder to copy them into it, on a file to copy them beside it, or on the empty part of the list to copy them into the project's root. The receiving folder is outlined while you drag.
- **Out of the tree:** drag a row onto Finder or the desktop to copy that file or folder there. A file from a host is copied over the connection when you drop it.
- **Between folders:** drag a row onto another folder of the tree to copy it there.
- **Moving:** hold <kbd>⌘</kbd> while dropping to move instead of copy, on this Mac or within the same host. Between this Mac and a host, files are always copied.

When a name is already taken, Trellis asks: **Replace** (or **Merge** for a folder), **Keep Both** (the copy is named like "report 2.pdf"), or **Skip**, with **Apply to all** for the rest. **Stop Copying** ends the copy. A file never replaces a folder, or a folder a file. A row dragged onto Finder is kept beside anything with the same name there, without asking.

A bar above the bottom of Files shows each copy's progress, with a button to stop it; what was already copied stays. When it is done, the tree shows the folder and selects what you dropped, and a short message says how many items were copied or skipped.

One drag copies at most 2 GB and 10,000 items. Symbolic links are copied as links on this Mac and skipped when copying to or from a host. If Files says "Update the Trellis helper on … to copy files to it.", open **Hosts**, select the host and choose **Update Helper…**.

## Limits

- Search looks through the first 20,000 files of the project and says so when it stops there. At most 200 results are shown.
- A symbolic link is listed, but never opened as a folder, so the tree can't loop.
- A folder Trellis can't read shows "Can't read this folder" under it; the rest of the tree still works.
- Which folders are open is never saved; it lasts until you quit.
