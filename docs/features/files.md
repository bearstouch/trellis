# Files

The **Files** view of the [right sidebar](sidebar.md) shows the focused pane's project as a tree, so you can find a file,
open it in your editor, or copy its path without leaving the terminal. Show it with the folder icon at the top of the
dock or **⌥⌘F**.

All requirements here are P1, except copying files by drag and drop (FR-FB10–FR-FB14), which is P2.

## What it shows

The tree's root is the focused pane's **project**: the nearest folder at or above the pane's folder that holds `.trellis`
or `.git` (as for [tasks](tasks.md)), else the pane's folder itself. The pane's folder is the one its shell last reported,
else the one it started in. A `cd` in the pane moves the tree; so does focusing another pane. The root is shown above the
tree, with `~` for the home folder.

The tree never shows `.git`, `.build`, `.swiftpm`, `node_modules`, `DerivedData` or `.DS_Store`. What the root's
`.gitignore` ignores shows only while the ignored-files button (the filter symbol) is on, and hidden files (names starting
with `.`) only while the eye button is on. The two are independent, so an ignored dot-file such as `.env` needs both. Both
start off, are kept for the session and are never saved. Files reads only
`.gitignore`'s simple patterns: `#` comments, `*`/`?`/`[…]` globs, a trailing `/` for folders, and a leading or inner `/`
to anchor a pattern to the root. Negations (`!`) are skipped, and nested `.gitignore` files and global excludes are not
read.

Files works for panes on this Mac and for [remote workspace](remote-workspaces.md) panes, whose project is listed on
the host through the Trellis helper there (see [On a remote workspace](#on-a-remote-workspace)). Its icon is dimmed for
SSH panes, whose files Trellis can't list.

## Using it

| Do this | To |
| --- | --- |
| Click a folder, or → / ← | Open or close it |
| Type in **Search files…** | Find files by name anywhere in the project (letters in order, like the [command palette](command-palette.md)); a query with `/` matches the path |
| ↑ / ↓ | Move the selection |
| Return, double-click, or **Open in** | Open the selection (the project folder when nothing is selected) in the chosen app |
| Double-click a code file | Open it in a [Trellis editor tab](editor.md), whichever app is chosen |
| The arrow beside **Open in** | Choose another app; it is remembered for next time |
| ⇧⌘C, or the copy button on the row | Copy the full path |
| ⌥⇧⌘C | Copy the path relative to the project |
| ⌥Return | Insert the path at the pane's prompt, quoted for the shell |
| Esc | Clear the search |
| Drag a row onto a pane | Insert its quoted path, as when [dropping from Finder](terminal.md) |
| Drag files from Finder onto a folder (or the list) | Copy them there; hold ⌘ to move them instead (see [Copying files](#copying-files)) |
| Drag a row onto another folder | Copy it there; ⌘ moves it |
| Drag a row onto Finder or the desktop | Copy the file or folder there (a host's too) |

A row's context menu also has **Open With**, **Reveal in Finder**, **Copy Name** and **Type cd to …**, which types
`cd '<folder>'` at the prompt without pressing Return.

**Open in** lists [Trellis Editor](editor.md) (an editor tab in this space; the default), Finder, then each of these that is installed: Cursor, VS Code (or VS Code Insiders or VSCodium), Zed,
Xcode, Sublime Text, Nova, IntelliJ IDEA, WebStorm and PyCharm, then **Default App** (whatever macOS opens the file with)
and **New Tab Here** (a Trellis tab in the file's folder). **Other App…** picks any app once without remembering it.
Finder reveals a file and opens a folder. Finder and **Default App** never run anything: an app, a script, an executable or
another launchable file is revealed in Finder instead, as for [terminal links](terminal.md) (FR-L03).

## On a remote workspace

In a remote workspace pane the tree is the project **on the host**: the nearest folder with `.git` or `.trellis` above the
folder the pane's shell is in (or the folder it was started in, or the account's home folder, until the shell reports
one). The line under the header names the host. The tree, the toggles, search, the copy commands, **Insert Path** and
**Type cd** work as on this Mac, with the host's paths.

What differs:

- **Opening is read-only.** Return, a double click or **Open in** opens a file in a [read-only editor tab](editor.md)
  (FR-ED16). **Open in** lists only Trellis Editor and **New Tab Here**; Finder, the editors on this Mac, **Open With**,
  **Other App…** and **Reveal in Finder** aren't offered, since no app here can reach the file. Opening a folder, or
  **New Tab Here** on a file, opens a tab in that folder on the host. The app remembered for this Mac's files isn't changed.
- **The host is written only when you drop files on it.** Trellis lists folders and reads the files you open; it writes
  only what you drop on the tree (see [Copying files](#copying-files)), through a helper of protocol 6 or later.
- **A dragged row is a promised file.** Dropped on Finder, a row is copied there from the host; dropped on a text field it
  is the host's path as text. A pane takes only dropped files, so use **Insert Path** for the path.
- **A folder with more than 10,000 entries** shows the first 10,000 the host returned and says so. A name that isn't
  UTF-8 is left out.
- **Search** asks the host for one level of the tree per request and keeps what it listed until the field is cleared,
  so later letters don't ask again. **Reload**, a cleared field or another project reads the host again.
- **While the host isn't connected** the tree already read stays, with "Not connected to <host>. The tree shows what
  was last read."; it is read again when the link is back. A host whose helper predates this shows "Update the Trellis
  helper on <host> to browse its files." (Hosts → **Update Helper…**).

## Copying files

Drop files or folders from Finder on a folder of the tree to copy them into it, on a file to copy them beside it, or on
the empty part of the list to copy them into the project's root. The folder that will receive them is outlined while you
drag. Rows dragged from the tree work the same way, and a row dropped on Finder or the desktop is copied there. All of this
works on this Mac and on a remote workspace's host, in either direction.

- **Move with ⌘.** On this Mac, and between folders of the same host, holding ⌘ moves instead of copying. Between this Mac
  and a host it always copies.
- **A name that is taken asks.** **Replace** (a file) or **Merge** (a folder onto a folder) and **Keep Both** ("report 2.pdf")
  or **Skip**, with **Apply to all**; **Stop Copying** ends the copy. A file and a folder never replace each other, so
  nothing is deleted recursively. A row dropped on Finder is kept beside anything of its name there without asking.
- **Progress** shows above the Files footer with a Cancel button; what was finished when you cancel stays.
- **Limits:** one drag copies at most 2 GB and 10,000 items. Links are copied as links on this Mac and skipped to or from a
  host; FIFOs, devices and sockets are skipped. A file is written under a hidden temporary name and appears whole.
- **Older helpers:** a host whose helper predates protocol 6 refuses drops with "Update the Trellis helper on <host> to copy
  files to it." (Hosts → **Update Helper…**); downloads still work.

## Requirements

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| FR-FB01 | Show Files in the dock, for panes on this Mac and remote workspace panes. | The dock's first icon is Files (a folder), with Toggle Files (⌥⌘F, rebindable, starting unbound when the chord is already taken) in the View menu, Settings → Keyboard and the command palette. Showing it puts the keyboard in its search field. For SSH panes the icon is dimmed with the reason "Files isn't available in SSH panes.", and the view hides until a pane it applies to is focused (FR-SB04). Showing and hiding it never changes the saved workspace. |
| FR-FB02 | Root the tree at the focused pane's project. | A pane in a folder inside a `.git` or `.trellis` project shows the project; outside one, the pane's folder. A `cd` or a focus change re-roots it. A pane with no local folder shows "No folder". The root never goes above the home folder for a folder inside it. |
| FR-FB03 | List folders as they open, safely. | Folders come first, then files, in natural name order. A folder is read when first opened, off the main thread. `.git`, build and dependency folders are always left out; `.gitignore`'d entries follow the ignored-files toggle and hidden files the eye toggle, independently, in the tree and in search. A symbolic link is listed but never opened as a folder, so the tree can't loop. A folder that can't be read shows "Can't read this folder" under it and the rest of the tree stays. Open folders are kept per project for the session (never saved); **Collapse All** closes them and **Reload** reads them again. |
| FR-FB04 | Search the project by file name. | Typing searches every file under the root (skipping what the tree skips), off the main thread, a moment after typing stops; a newer query cancels the older search. Results show the name with matched letters in bold accent and the folder relative to the root; the best match is selected. The search stops after 20 000 files and says "in the first 20,000 files"; at most 200 results show. Esc or clearing the field shows the tree again. |
| FR-FB05 | Open in an editor. | Only installed apps are offered; they are looked up when Files first shows and again on **Reload**, not on every pane switch or `cd`. **Open in** and Return open the selection, or the project folder, in the remembered app (Trellis Editor until another is chosen, FR-ED09); choosing an app from the menu opens with it and remembers it in preferences. An app that is no longer installed shows "<App> isn't installed on this Mac." and opens nothing. Finder and **Default App** reveal, never open, what FR-L03 would only reveal (apps, packages, scripts, executables); a FIFO or device opens nothing. **New Tab Here** opens a local tab in the folder. |
| FR-FB06 | Copy and insert paths. | Copy Path, Copy Relative Path and Copy Name put exactly that text on the pasteboard and show "Copied …" for two seconds, announced to VoiceOver. Insert Path and dragging a row of this Mac send the path through the [paste route](terminal.md) quoted for the shell (as a Finder drop); Type cd types the command without Return. Nothing runs by itself. |
| FR-FB07 | Make the tree accessible. | Every row is one element named after its file, with the value "file" or "folder, expanded/collapsed" (and its folder in search), the selected trait, a default action (open the file, or open/close the folder) and named **Copy Path** and **Insert Path in Terminal** actions. Every icon button has a label and a tooltip; state is in words, not color alone. |
| FR-FB09 | Browse a remote workspace's files. | In a remote workspace pane the tree is rooted at the project on the host holding the shell's authenticated folder (FR-RW05), else the folder the pane was started in, else the account's home there; the header names the host. Folders are listed by the host's helper when they open (FR-RW19), with the same order, skipped names, toggles and `.gitignore` rules as FR-FB03; a link is never opened as a folder; a folder cut at 10,000 entries says "Only the first 10,000 entries are shown". Search (FR-FB04) asks the host one request per tree level and reuses the listings until the field is cleared, the tree is reloaded or the root changes. **Open in** offers only Trellis Editor, which opens a read-only tab (FR-ED16), and **New Tab Here**, which opens a tab in that folder on the host; a folder opens a tab too; no app on this Mac is offered or remembered, and Finder is never asked to reveal a host's path. Copy, Insert Path and Type cd use the host's paths; a dragged row carries a file promise and the path as plain text, never a file URL, which another app would resolve on this Mac (FR-FB11). While the host isn't connected, or its link drops while the tree is being read, the tree already read stays (same root, same listings) with a notice in words and is read again when the link returns; a helper below protocol 5 is never asked and the view says to update it. Open folders are kept per host and project. Nothing on the host is written except files dropped on the tree (FR-FB10, FR-RW20), and nothing read is saved on this Mac unless a row is dragged out (FR-FB11). |
| FR-FB10 | Drop files from Finder into the tree (P2). | Dropping files or folders on a folder row copies them into that folder, on a file row into its folder, and on the list's empty area into the root; search results take no drop. The target line is outlined while hovered and VoiceOver hears "drop target". On this Mac ⌘ held moves instead (the source is removed only after its item copied whole); on a host a drop always copies, through the helper (FR-RW20). A host whose helper is below protocol 6 refuses the drop with "Update the Trellis helper on <host> to copy files to it." and is never sent a write. Afterwards the tree is read again, the target opens and the first copied item is selected, with a summary such as "Copied 12 items to docs · 1 skipped", announced to VoiceOver. |
| FR-FB11 | Drag a host's rows to Finder (P2). | A remote row drags as a file promise (a file, or a folder copied whole), as its path in plain text and, inside Trellis, as the row. Nothing is read until Finder takes the drop; the bytes then come through the helper (protocol 5 is enough) in 512 KB chunks, with progress on the Files bar, into the folder Finder names, beside anything of that name ("README 2.md"). A failed or cancelled file leaves no partial file. A link (or a FIFO, device or socket) isn't copied from a host: the drop fails, so Finder isn't left with a promise that writes nothing, and Files says "<name> is a link; links aren't copied from a host.". A local row drags as its file URL, as before. |
| FR-FB12 | Ask about name conflicts (P2). | A name that is free is copied without asking. A taken one shows "“<name>” already exists in “<folder>”." with **Replace** (for a file; **Merge** for a folder onto a folder), **Keep Both** (the default: "report 2.pdf", "a 2.tar.gz", "docs 2"), **Skip**, an **Apply to all** toggle and **Stop Copying** (Esc). A file onto a folder or the reverse offers only Keep Both and Skip, so nothing is ever deleted recursively. |
| FR-FB13 | Copy within limits, with progress (P2). | One drag copies at most 2 GB and 10,000 items; a larger one is refused before anything is written. A bar above the footer shows "Copying <n> of <m> · <bytes> of <total>" with a Cancel button (labelled, with a percent value). Cancel stops after the current chunk, removes the unfinished file and keeps what was finished. A file that changes while it is read fails alone; a dropped link stops the copy. Links are copied as links on this Mac and skipped to or from a host (counted in the summary); FIFOs, devices and sockets are skipped. Files are written to a hidden temporary name and moved into place, so a half-written file never has the real name. |
| FR-FB14 | Drag rows between folders of the tree (P2). | Dropping a row on another folder copies it there (⌘ moves it on this Mac; on a host ⌘ renames it there and fails across file systems). A folder can't be dropped into itself or a folder inside it. |
| FR-FB08 | Stay smooth in a long folder. | In a folder with thousands of files the tree's scroll height is right before any row is drawn (a tree line is 24 pt and a search result 40 pt, unless a name needs a taller font), so the scroller and the rows under the pointer don't move as scrolling draws them. Moving the selection redraws the two lines it touches, not the list, and a change elsewhere in the app redraws no line; the list is rebuilt only when its rows change, as when a folder opens or closes. The search count stays above the results instead of scrolling with them. |

## Verification

| Area | How it's checked |
| --- | --- |
| Listing, ignore rules, links, search (FR-FB03, FR-FB04) | `FileBrowserTests`: order, skipped and hidden names, `.gitignore` patterns, a `.gitignore` that isn't a regular file, a link never being a folder, an unreadable folder, ranking, path queries, the file and result limits. |
| Dock, root, tree, search, Open in, copy and insert (FR-FB01–FR-FB06) | `FilesSidebarTests`: staying on a remote workspace pane whose host isn't connected, listing nothing of this Mac's and saying why, the project root from a subfolder, lazy folders and selection, the hidden toggle, the ignored-files toggle apart from it, an unreadable folder, search through unopened folders, installed editors and the remembered choice, Finder revealing, an app bundle and a script revealed rather than opened, a missing app, New Tab Here, the three copy styles and a quoted inserted path. |
| Remote workspace files (FR-FB09) | `RemoteFilesSidebarTests`, with the host's files behind an injected reader: the project root from a subfolder, folders read when opened and one request for the root and the open folders, the toggles, search asking one request per level and reusing the walk until the field is cleared, the not-connected and old-helper notices and a tree that stays while the link is down, the truncation note, the two **Open in** choices, a read-only tab, a refused file opening nothing, Finder and other apps never used, **New Tab Here** on the host, copied paths, and a pane on this Mac showing its own tree again. `RemoteFilesSidebarReviewTests`: a link that drops while the root is asked for or while folders are listed leaves the tree already read. A row dragged as text: **pending** (manual). `FileBrowserTests`: the level-by-level walk finds what the local walk finds. `RemoteWorkspaceTests`: through the fake `ssh` and the real helper, the host's project is listed, a link is never a folder, search finds a file in an unopened folder and a file longer than one chunk opens whole. Against a real host: **pending**. |
| Drag and drop (FR-FB10–FR-FB14) | `FileTransferTests`: chunked copies with modes, the limits refusing a drop before anything is written, Keep Both names, the conflict choices (no replace across kinds), Apply to all and Merge, stopping at a conflict, never into itself, a duplicate in place, links and special files skipped between machines, a failed file beside the rest and a dropped link stopping, a file changing mid-copy, cancelling mid-file, a host's move taking free names only, and on this Mac links kept, a merging move and no replace unless asked. `FilesTransferTests`: a Finder drop copied to a host's folder, opened and selected with its summary; an old helper never asked and saying why; the conflict prompt (Keep Both, Stop); a host's row moved within the host; a promised row copied into Finder's folder; the summary text; drop payloads. `BrokerRemoteWriteTests`, `BrokerBridgeTests` for the helper (FR-RW20). Manual: **pending** (dragging with Finder both ways, folder promises, the ⌘ badge and outline, the conflict sheet and bar with VoiceOver, a real host). |
| Long folders (FR-FB08) | `FilesSidebarLongFolderTests`: the hosted view's scroll height with 2 000 files, before and while scrolling and after a far selection; a selection move and other state changes telling only the lines they touch, an opened folder telling its own line, and marks surviving a move to another project while unused ones are dropped. |
| Shortcut (FR-FB01) | `KeyboardShortcutTests`: ⌥⌘F default, View menu, yielding to a saved chord. |
| The view in the app, keyboard, VoiceOver (FR-FB01–FR-FB08) | Manual: **pending** (the native view's layout, mouse and keyboard use, real editors opening, dragging a row onto a pane, VoiceOver walk of the tree). |
