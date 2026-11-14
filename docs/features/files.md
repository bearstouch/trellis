# Files

The **Files** view of the [right sidebar](sidebar.md) shows the focused pane's project as a tree, so you can find a file,
open it in your editor, or copy its path without leaving the terminal. Show it with the folder icon at the top of the
dock or **⌥⌘F**.

All requirements here are P1.

## What it shows

The tree's root is the focused pane's **project**: the nearest folder at or above the pane's folder that holds `.trellis`
or `.git` (as for [tasks](tasks.md)), else the pane's folder itself. The pane's folder is the one its shell last reported,
else the one it started in. A `cd` in the pane moves the tree; so does focusing another pane. The root is shown above the
tree, with `~` for the home folder.

The tree never shows `.git`, `.build`, `.swiftpm`, `node_modules`, `DerivedData` or `.DS_Store`, nor what the root's
`.gitignore` ignores. Hidden files (names starting with `.`) show only while the eye button is on. Files reads only
`.gitignore`'s simple patterns: `#` comments, `*`/`?`/`[…]` globs, a trailing `/` for folders, and a leading or inner `/`
to anchor a pattern to the root. Negations (`!`) are skipped, and nested `.gitignore` files and global excludes are not
read.

Files works only for panes on this Mac. Its icon is dimmed for SSH panes and [remote workspace](remote-workspaces.md)
panes, whose files Trellis can't list.

## Using it

| Do this | To |
| --- | --- |
| Click a folder, or → / ← | Open or close it |
| Type in **Search files…** | Find files by name anywhere in the project (letters in order, like the [command palette](command-palette.md)); a query with `/` matches the path |
| ↑ / ↓ | Move the selection |
| Return, double-click, or **Open in** | Open the selection (the project folder when nothing is selected) in the chosen app |
| The arrow beside **Open in** | Choose another app; it is remembered for next time |
| ⇧⌘C, or the copy button on the row | Copy the full path |
| ⌥⇧⌘C | Copy the path relative to the project |
| ⌥Return | Insert the path at the pane's prompt, quoted for the shell |
| Esc | Clear the search |
| Drag a row onto a pane | Insert its quoted path, as when [dropping from Finder](terminal.md) |

A row's context menu also has **Open With**, **Reveal in Finder**, **Copy Name** and **Type cd to …**, which types
`cd '<folder>'` at the prompt without pressing Return.

**Open in** lists [Trellis Editor](editor.md) (an editor tab in this space; the default), Finder, then each of these that is installed: Cursor, VS Code (or VS Code Insiders or VSCodium), Zed,
Xcode, Sublime Text, Nova, IntelliJ IDEA, WebStorm and PyCharm, then **Default App** (whatever macOS opens the file with)
and **New Tab Here** (a Trellis tab in the file's folder). **Other App…** picks any app once without remembering it.
Finder reveals a file and opens a folder. Finder and **Default App** never run anything: an app, a script, an executable or
another launchable file is revealed in Finder instead, as for [terminal links](terminal.md) (FR-L03).

## Requirements

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| FR-FB01 | Show Files in the dock, for panes on this Mac. | The dock's first icon is Files (a folder), with Toggle Files (⌥⌘F, rebindable, starting unbound when the chord is already taken) in the View menu, Settings → Keyboard and the command palette. Showing it puts the keyboard in its search field. For SSH and remote workspace panes the icon is dimmed with the reason "Files shows only folders on this Mac.", and the view hides until a local pane is focused (FR-SB04). Showing and hiding it never changes the saved workspace. |
| FR-FB02 | Root the tree at the focused pane's project. | A pane in a folder inside a `.git` or `.trellis` project shows the project; outside one, the pane's folder. A `cd` or a focus change re-roots it. A pane with no local folder shows "No folder". The root never goes above the home folder for a folder inside it. |
| FR-FB03 | List folders as they open, safely. | Folders come first, then files, in natural name order. A folder is read when first opened, off the main thread. `.git`, build and dependency folders and `.gitignore`'d entries are left out; hidden files follow the eye toggle. A symbolic link is listed but never opened as a folder, so the tree can't loop. A folder that can't be read shows "Can't read this folder" under it and the rest of the tree stays. Open folders are kept per project for the session (never saved); **Collapse All** closes them and **Reload** reads them again. |
| FR-FB04 | Search the project by file name. | Typing searches every file under the root (skipping what the tree skips), off the main thread, a moment after typing stops; a newer query cancels the older search. Results show the name with matched letters in bold accent and the folder relative to the root; the best match is selected. The search stops after 20 000 files and says "in the first 20,000 files"; at most 200 results show. Esc or clearing the field shows the tree again. |
| FR-FB05 | Open in an editor. | Only installed apps are offered; they are looked up when Files first shows and again on **Reload**, not on every pane switch or `cd`. **Open in** and Return open the selection, or the project folder, in the remembered app (Trellis Editor until another is chosen, FR-ED09); choosing an app from the menu opens with it and remembers it in preferences. An app that is no longer installed shows "<App> isn't installed on this Mac." and opens nothing. Finder and **Default App** reveal, never open, what FR-L03 would only reveal (apps, packages, scripts, executables); a FIFO or device opens nothing. **New Tab Here** opens a local tab in the folder. |
| FR-FB06 | Copy and insert paths. | Copy Path, Copy Relative Path and Copy Name put exactly that text on the pasteboard and show "Copied …" for two seconds, announced to VoiceOver. Insert Path and dragging a row send the path through the [paste route](terminal.md) quoted for the shell (as a Finder drop); Type cd types the command without Return. Nothing runs by itself. |
| FR-FB07 | Make the tree accessible. | Every row is one element named after its file, with the value "file" or "folder, expanded/collapsed" (and its folder in search), the selected trait, a default action (open the file, or open/close the folder) and named **Copy Path** and **Insert Path in Terminal** actions. Every icon button has a label and a tooltip; state is in words, not color alone. |

## Verification

| Area | How it's checked |
| --- | --- |
| Listing, ignore rules, links, search (FR-FB03, FR-FB04) | `FileBrowserTests`: order, skipped and hidden names, `.gitignore` patterns, a `.gitignore` that isn't a regular file, a link never being a folder, an unreadable folder, ranking, path queries, the file and result limits. |
| Dock, root, tree, search, Open in, copy and insert (FR-FB01–FR-FB06) | `FilesSidebarTests`: dimming on a remote workspace pane and coming back with focus, the project root from a subfolder, lazy folders and selection, the hidden toggle, an unreadable folder, search through unopened folders, installed editors and the remembered choice, Finder revealing, an app bundle and a script revealed rather than opened, a missing app, New Tab Here, the three copy styles and a quoted inserted path. |
| Shortcut (FR-FB01) | `KeyboardShortcutTests`: ⌥⌘F default, View menu, yielding to a saved chord. |
| The view in the app, keyboard, VoiceOver (FR-FB01–FR-FB07) | Manual: **pending** (the native view's layout, mouse and keyboard use, real editors opening, dragging a row onto a pane, VoiceOver walk of the tree). |
