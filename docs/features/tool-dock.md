# Tool dock

The tool dock is a panel beside the panes where you browse the focused pane's project and edit its files without leaving Trellis. A narrow **tool rail** on the window's edge holds one button per tool; choosing one opens the dock with that tool. **Files** (a file tree and a quick editor) is the first tool. Git is the next one planned, and every later tool joins the same rail and dock.

The dock sits on the right by default, or on the left, and it belongs to a tab: each tab keeps its own dock. When docking it would make the panes too small, it floats over them instead.

All requirements here are P2 (preview). The Files tool is implemented; what has been verified, and what is still pending in the running app, is in [Status](../overview/status.md). The interactive prototype these requirements came from has frames for editing, browsing, Quick Git, a file changed on disk, splits, a cramped tab and the dock on the left.

## Layout

```
 window sidebar │ tab bar ─────────────────────────────────────────────
                │ panes (split tree)                │ dock       │ rail
                │                                   │ tree │ ed. │ 📁 ⎇
```

With the dock on the left, the order is window sidebar, rail, dock, panes. The tab bar and the bottom bar always span the whole window. When the dock floats, it keeps its place on its side, over the panes nearest to it.

| Part | What it does |
| --- | --- |
| Tool rail | One button per tool, in a fixed order: **Files**, then **Git** when it ships. The button of the open tool shows as pressed. The rail is always visible, also while the dock is closed. |
| Dock header | The tool's title or, for Files, the project's name and machine (**Local**), a follow symbol whose tooltip and label name the focused pane ("Follows run"), the ⇄ button that moves the dock to the other side, and a close button. |
| File tree | A filter field, then the project's folders and files. |
| Editor | A tab per open file, a bar with the path, **Edited**, a button that shows or hides the tree, **Insert Path** and **Save**, then the text, then a footer with the language, encoding, line endings and line count. |

## Requirements

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| FR-TD01 | Open and close the dock from the tool rail. | Clicking a tool's rail button opens the dock with that tool; clicking it again closes the dock; clicking another tool's button switches tools without closing the dock. **View → Show Files** (⌥⌘1 by default, rebindable; it yields to a chord you had already assigned) does the same, and every tool is listed in the command palette (FR-CP03). Opening the dock with Files puts keyboard focus in the tree, or in the editor if a file is open; closing it returns focus to the focused pane. The close button and Esc in the tree (not in the editor) close the dock. |
| FR-TD02 | Put the dock on the right or the left. | **Settings → Appearance → Tool dock** offers **Right** (the default) and **Left**, and the ⇄ button in the dock header switches between them. The rail and the dock move together, and the window sidebar stays at the window's left edge. The choice applies to every tab and window at once and is saved with the app settings, so it survives a relaunch. Moving the dock doesn't close it or change its tool, open files, widths or unsaved edits. |
| FR-TD03 | Dock beside the panes without changing the layout. | A docked dock takes its width from the canvas, and the split tree shrinks proportionally: every ratio stays the same. The dock is 225 points wide when it shows only the tree and 760 points with the editor, and dragging its inner edge resizes it between 225 points and 70% of the window (VoiceOver's adjust actions too). Hiding the tree in the editor narrows it by the tree's width. Opening, closing, resizing or moving the dock never changes the saved workspace (no save, no `layout` change, no event in the automation API). |
| FR-TD04 | Float over the panes when docking would make them too small. | When docking at the current width would push any pane below the FR-P02 minimum (20 columns × 5 rows), the dock floats over the panes on its side instead, at the same width, with a shadow and the text **Floating over the panes**. Panes keep their size, so no terminal is resized. It docks again as soon as there's room (the window grows, a pane closes, the dock is narrowed or the tree hidden). While a pane is maximized (FR-P04), the same rule applies to that pane alone. A floating dock never covers the tab bar, bottom bar or rail. |
| FR-TD05 | Keep one dock per tab. | Each tab has its own dock state: open or closed, tool, open files, active file, widths, filter and tree expansion. Switching tabs shows that tab's dock exactly as it was left; a new tab starts with the dock closed. The side (FR-TD02) is shared by all tabs. Dock state lives in memory only and isn't restored after quitting. |
| FR-TD06 | The tree follows the focused pane. | The tree shows the focused pane's project: the root of the git work tree containing the pane's directory, else the pane's library project folder (FR-PL), else the directory itself. Your home folder and `/` are never shown as a root; the tree says why instead. The directory comes from authenticated shell integration (FR-SI); without it, the tree says that shell integration is needed. Focusing a pane in another project switches the tree within 200 ms, and the header's follow symbol names that pane in its tooltip and label ("Follows run"). Open files stay open across switches; a tab for a file outside the current tree's project shows its project's name beside the file name. |
| FR-TD07 | The editor works on this Mac only for now. | When the focused pane is an SSH pane, a pane started as `ssh` or `mosh`, or a pane in a remote workspace (FR-RW), the tree shows "Files on *host* aren't available yet" and **Insert Path** is disabled with that reason. Open local files stay open and editable. Nothing is read from or written to a host, and no new helper command is added (FR-RW12 is unchanged). |
| FR-TD08 | Browse the project. | Folders come first, then files, each sorted by name with the macOS Finder's comparison. Hidden files are shown; `.git` itself is not. A symbolic link shows with a link symbol and its name; a link to a folder isn't expanded, and a link to a file opens its target only if the target is inside the project root. A folder's contents are read when it's first expanded, and the tree follows changes on disk within 1 s. Folders with more than 5,000 entries show the first 5,000 and say so. When FR-PL09 git status is available, changed files show a letter (**M**, **A**, **D**, **U**) with a label, never color alone. The filter matches path fragments, case-insensitively, and lists the matching files flat. |
| FR-TD09 | Open files from the tree and from terminal links. | Clicking a file in the tree opens it in an editor tab, or selects its tab if it's already open. ⌘-click on a local file path in a pane (and the context menu's **Open**, FR-L05) opens a text file in the dock of that pane's tab and focuses that pane, at `:line[:column]` when the link carries one, with the line marked. Other files open in their default app as today (FR-L02), and FR-L03 and FR-L04 apply unchanged. A **Open file links in** setting chooses **Tool dock** (default) or **Default app**. |
| FR-TD10 | Open only files the editor can handle. | A file opens when it's a regular file you can read, at most 2 MiB, and valid UTF-8 (with or without a byte order mark) without NUL bytes. Otherwise it doesn't open, the reason is shown ("Larger than 2 MiB", "Not UTF-8 text", "Binary file", "Permission denied") and **Open in Default App** is offered, under FR-L03 and FR-L04 (an executable or app is only revealed in the Finder). A file you can read but not write opens read-only, labelled **Read Only**, with Save disabled and the reason given. Paths under `/net` and `/Network` are refused (as in FR-L04). |
| FR-TD11 | Edit with the terminal's look and no surprises. | The editor uses the terminal font, size and theme colors, with line numbers and syntax highlighting from the theme's ANSI colors for the bundled languages (at least Swift, JSON, Markdown, shell, JavaScript and TypeScript, YAML and HTML); other files are plain text. Smart quotes, dashes, text replacement, spelling and link detection are off. Undo, IME (marked text), Find (⌘F, ⌘G, ⌘⇧G, or whatever they're bound to; they search the editor while it has focus) and the standard editing commands work. Tabs, indentation, line endings (LF or CRLF), a byte order mark and the presence or absence of a final newline are kept exactly. Highlighting is display-only and keeps typing responsive in a 2 MiB file. |
| FR-TD12 | Save safely. | **Save** and ⌘S (or whatever **Save Workspace** is bound to, which yields to the editor while it has focus) write the file. The new contents are written to a temporary file in the same folder and moved into place, keeping the file's permission bits; a symbolic link is followed and its target saved, never replaced by a regular file. A failed save keeps the buffer, the **Edited** label and the old file, and says why. A saved, unchanged file has Save disabled. |
| FR-TD13 | Notice changes made on disk. | An open file is watched. If it changes on disk and its buffer has no unsaved edits, it reloads, keeping the scroll position and the cursor's line. If the buffer has unsaved edits, a bar says "*name* changed on disk while you were editing it" with **Reload from Disk** and **Keep My Edits**. Saving over a file that changed since it was loaded or last saved always asks first (**Overwrite**, **Reload**, **Cancel**), so an agent's change is never overwritten silently. A deleted or moved file shows "*name* is no longer on disk" and keeps the buffer; Save recreates it at the same path. |
| FR-TD14 | Never lose unsaved edits without asking. | **Edited** (as text) marks a file tab, its tree row and the dock's rail button while there are unsaved edits. Closing a file tab, a pane tab or window whose dock holds them, or quitting, asks with **Save**, **Don't Save** and **Cancel**, naming the files (**Save All** when there are several). Closing such a tab or window through the automation API or MCP server fails with `INVALID_STATE` and closes nothing, without naming the files. Closing the dock only hides the files; they stay open. Unsaved edits live only in memory: nothing is autosaved, backed up or written anywhere else. |
| FR-TD15 | Insert a path at the prompt. | **Insert Path** types the file's path at the focused pane's cursor, quoted for that pane's shell and followed by a space, without Return: relative to the pane's directory when the file is inside it, otherwise absolute with `~` for your home. It's enabled only for a local pane with shell integration, idle at its prompt (as for tasks, FR-TK05), and otherwise disabled with the reason. A path with control characters is never typed: quoting can't stop a typed Ctrl-U or Return from editing or running the line. |
| FR-TD16 | Keep files private. | File contents, paths and edits are never logged, never saved with the workspace, and never exposed through the automation API or MCP server; the API adds no methods for the dock. Trellis reads a file only when you open it and writes it only when you save it. |
| FR-TD17 | Make the dock accessible. | The rail is a labelled toolbar whose buttons have the tool's name, the pressed state and a tooltip with the shortcut. The dock is a labelled group; the tree is an outline with each row's name, kind, git status and **Edited** read out; editor tabs are tabs with their state; **Edited**, **Read Only** and **Floating over the panes** are text. Every control is reachable with the keyboard, and Ctrl-Tab moves focus out of the editor. Reduce Motion removes the dock's open, close and float animations, and Increase Contrast strengthens its border and shadow. |
| FR-TD18 | Add tools through one registry. | Each tool is one registry entry: its identifier, title, rail symbol, menu item and default shortcut, and its view. Adding a tool adds its rail button, **View** menu item, command palette entry and shortcut row in Settings → Keyboard, with no other change to the rail or dock. Tools share the dock's side, width, float and per-tab rules (FR-TD02–FR-TD05). |

## Trust and safety

- The editor writes only the file you save, at its own path or a symbolic link's target. It never runs anything: opening a script shows its text, and FR-L03 still keeps ⌘-click from launching executables.
- Saving over an agent's change needs an explicit choice (FR-TD13). Review what you overwrite.
- No file is read or written on a remote host (FR-TD07), so remote workspaces need no new helper capability.

## Editor engine

The editor is the scratchpad's `NSTextView`-based editor (`ScratchpadEditor`), grown for files, with tree-sitter highlighting from ChimeHQ's **Neon** and **SwiftTreeSitter**. It stays native: it keeps the system text input, Find bar, undo, IME and accessibility that `NSTextView` already gives the scratchpad and the project JSON editor, and it uses the theme's colors the same way. Folding, multiple cursors and a minimap aren't part of this page, and nothing here requires them.

- **Licenses:** Neon and SwiftTreeSitter are BSD-3-Clause, the tree-sitter runtime is MIT, and each grammar carries its own license (most are MIT). All fit MIT-licensed Trellis; their notices ship in `Trellis.app/Contents/Resources` and are recorded in `release/manifest.json`, like SwiftTerm's and Sparkle's.
- **Grammars:** the FR-TD11 languages (Swift, JSON, Markdown, shell, JavaScript, TypeScript, YAML and HTML). Their C sources and highlight queries are vendored into one local package under `ThirdParty/`, with their provenance and licenses, so the build stays reproducible and they ship as one resource bundle.
- **Pins:** SwiftTreeSitter is pinned to an exact release. Neon's last tagged release is from January 2024 while its main branch is maintained, so it's pinned to an exact revision.
- **Highlighting only what's shown:** Neon's ready-made `TextViewHighlighter` restyles the whole document after every change. On a 2 MiB Swift file in a spike it took 3.2 s to show the first colors and styled 886,170 tokens, with a 1.5 s pause on one keystroke. Trellis's `CodeHighlighter` uses the same Neon parts but styles only the visible range: 61 ms and 943 tokens on the same file, with highlighting costing about 3 ms a keystroke. Tree-sitter's line and column points come from a line table updated edit by edit.
- **Packaging:** most grammars are remote SwiftPM packages pinned to exact tags (the Swift grammar by revision, since its generated parser is only on a branch). JavaScript and YAML are vendored in `ThirdParty/TreeSitterGrammars`, because their manifests leave out `scanner.c` and fail to link. All grammars add roughly 10 MB per architecture to the app.
- **Not chosen:**
    - **CodeEditSourceEditor** (MIT): the richest set of features, but its README says it isn't ready for production, its last release was in September 2025, its grammar package has no licence file and ships as a 33 MB prebuilt framework, and it adds a SwiftLint build plugin.
    - **STTextView** (GPL v3 or a commercial licence): TextKit 2 and actively maintained, with explicit VoiceOver work, but its licence doesn't fit MIT-licensed Trellis without buying the commercial licence, it has one maintainer, and its highlighting plugin pins a forked Neon.

## Decisions still open

- **The scratchpad as a dock tool.** The [scratchpad](scratchpad.md) keeps its own panel (FR-SP01) for now; with the dock on the right, the order is panes, scratchpad, dock, rail. Moving it into the dock as a tool changes FR-SP01 and needs its own change.
- **Git.** The Git tool (status, staging, commit, push and diffs for the focused pane's repository) gets its own requirements before it's built.
- **Remote files.** Opening and saving files on a host would need new helper commands and an update to FR-RW12 and the remote known limits.

## Related pages

- [Terminal](terminal.md): FR-L02 opens text files in the dock by default (FR-TD09).
- [Keyboard and accessibility](keyboard-accessibility.md): the Show Files shortcut, and Save while the editor has focus.

## Known limits

- Unsaved edits are lost if Trellis crashes (FR-TD14 keeps them in memory only).
- Saving by moving a new file into place gives it a new inode, so a hard link to the old file keeps the old contents, and extended attributes other than the permission bits aren't carried over.
- One editor per file per tab: the same file open in two tabs has two buffers, and each warns when the other saves (FR-TD13).
- The tree shows no git letters yet (FR-TD08): FR-PL09's status keeps only counts, never file names.
- A library project folder isn't used as a root yet (FR-TD06); the work tree, then the pane's directory, are.
- The tree refreshes open folders once a second while it's shown, rather than through file system events.
