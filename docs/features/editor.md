# Editor tabs

An **editor tab** opens a text file of the project in the current space, so a quick change doesn't need another app. It
has line numbers, syntax highlighting, undo and find, and saves with ⌘S. Open one from the [Files](files.md) view or by
⌘-clicking a path that a [terminal](terminal.md#links) printed inside the project.

All requirements here are P1.

## Opening a file

- **Files:** **Trellis Editor** is the first entry of **Open in**, and the default until another app is chosen. Return,
  double-click and **Open in** open the selected file in an editor tab; the row's context menu also has **Open in Trellis
  Editor**. A folder opened with Trellis Editor is shown in Finder.
- **Terminal links:** ⌘-click on a file path inside the pane's project (as for Files, FR-FB02) or below the pane's
  current folder opens it in an editor tab, at the line and column of a `path:line[:column]` suffix. Right-clicking such a
  path offers **Open in Trellis Editor** first. Paths elsewhere keep [FR-L02](terminal.md#links).

The tab opens in the current space, after its terminal tabs (and after the editor tab being shown, if any). When the file is
already open in that space its tab is focused instead (and moves to the line, if one was given). Only UTF-8 text up to 2 MB opens: a file with a NUL byte in its first
8 KB, one that isn't valid UTF-8, or one over 2 MB is handed to the default app with the FR-L03 rules (a launchable file
is only revealed), and Trellis says why.

## Editing and saving

The editor keeps the file's line endings (LF or CRLF), its byte-order mark and whether it ends with a newline. Typing never
substitutes quotes, dashes or spelling. ⌘S saves: the text is written to a temporary file in the same folder, which then
replaces the file and keeps its permissions. If saving fails the tab keeps the text and its unsaved mark and shows why.

A tab with unsaved changes shows a dot before its close button and says "unsaved" to VoiceOver. Closing it, closing its
space, or quitting Trellis asks first: **Save**, **Don't Save** or **Cancel** (one question listing every unsaved file when
quitting or closing a space).

Trellis checks the file on disk when the tab is shown and before saving. When the file changed and the tab has no unsaved
changes, the tab reloads it quietly. With unsaved changes, a banner says the file changed on disk and offers **Reload
from Disk** or **Keep Mine**; saving over a changed file asks first. When the file was deleted, a banner says so and Save
creates it again.

Editor tabs are temporary, like the [Review tab](changes.md): they are never saved in the workspace, never restored after
relaunch, and absent from the automation API (`tab.list`, `layout.export`, events). Next and previous tab move through
the space's tabs, then its editor tabs; ⌘1–9 select only the space's own tabs.

## Colors and languages

The editor has no colors of its own. Its background, text, cursor, selection, line numbers and syntax colors come from
the active [theme](themes.md)'s terminal palette, and its header and banners from the theme's interface colors, so code
looks as it would in the terminal. The terminal font and size are used. Changing the theme, its preview in Settings, or
Light/Dark/System repaints open editor tabs at once without touching their text, undo or scroll position.

Highlighting is a fast, single-pass tokenizer for: Swift, Python, JavaScript and TypeScript, JSON, Go, Rust, C, C++,
Objective-C, Java, Kotlin, Ruby, shell scripts, Markdown, YAML, TOML, HTML/XML and CSS. The language comes from the file name,
then from a `#!` line. Other files are plain text. Files over 512 KB are shown without highlighting.

## Shortcuts

| Do this | To |
| --- | --- |
| ⌘S | Save |
| ⌘L | Go to line |
| ⌘F, ⌘G, ⇧⌘G | Find, next, previous (the standard find bar) |
| ⌘W | Close the editor tab (asks when unsaved) |
| ⌘Z, ⇧⌘Z | Undo, redo |

## Requirements

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| FR-ED01 | Open a file in an editor tab of the current space. | Opening a file adds a tab after the space's tabs (after the shown editor tab, if any), labelled with the file name (and its folder when two open files share a name) and a document icon, and shows it. Opening a file already open in the space focuses its tab instead. Selecting a space tab shows the terminals again; the editor tab stays. |
| FR-ED02 | Open only text the editor can keep intact. | UTF-8 files (with or without BOM) up to 2 MB open. A NUL byte in the first 8 KB, invalid UTF-8 or a larger file opens nothing in Trellis: the file goes to the default app under FR-L03 (launchables are revealed) and the reason is shown. A folder is shown in Finder. |
| FR-ED03 | Edit with line numbers and highlighting. | The editor shows line numbers, highlights the current line and colors the languages listed above. Undo, redo, the find bar and Go to Line work. No automatic substitution changes typed text. Line endings, BOM and the final newline are written back as they were read. |
| FR-ED04 | Save safely. | ⌘S writes the text through a temporary file in the same folder that replaces the file, keeping its permissions. A failed save leaves the file as it was, keeps the text and the unsaved mark, and shows the error. |
| FR-ED05 | Never lose unsaved changes silently. | A tab with unsaved changes shows a dot and the accessibility value "unsaved". Closing the tab, closing its space or quitting asks Save / Don't Save / Cancel; Cancel changes nothing, Save that fails cancels the close. A clean tab closes without asking. |
| FR-ED06 | Notice changes on disk. | When the tab is shown and before saving, the file's modification date and size are compared with what was read. A clean tab reloads; a tab with unsaved changes shows a banner with **Reload from Disk** and **Keep Mine**, and saving over the changed file asks first. A deleted file shows a banner; Save creates it again. |
| FR-ED07 | Open project files from terminal links. | ⌘-click on a file path inside the pane's project or current folder opens it in an editor tab at the given `:line[:column]`, after the FR-L02–FR-L04 checks. A `..` or a symbolic link that leaves both folders, a path elsewhere, a remote pane, and a file FR-ED02 refuses keep the FR-L02 behavior. The link context menu offers **Open in Trellis Editor** for such paths. |
| FR-ED08 | Keep editor tabs temporary. | Editor tabs are absent from the saved workspace, are not restored after relaunch, and are absent from `tab.list`, `layout.export` and API events. Closing a space closes its editor tabs (after FR-ED05). |
| FR-ED09 | Choose Trellis Editor in Files. | **Open in** lists Trellis Editor first; it is used when no app has been chosen, and a remembered choice is kept. The row context menu offers **Open in Trellis Editor**. |
| FR-ED10 | Make editor tabs accessible and localized. | The tab is named "Editor tab, <file>" with the value "unsaved" when it is; the text area is named after the file and its language; every header button has a label and a tooltip; banners are announced. All text on screen is localized. |
| FR-ED11 | Follow the theme. | Editor colors, syntax colors and font come from the active theme and terminal font settings. Changing the theme, previewing one in Settings (and cancelling), or switching appearance repaints open editor tabs at once; their text, selection, undo and scroll position are kept. |

## Verification

| Area | How it's checked |
| --- | --- |
| Reading, encoding, saving, disk changes (FR-ED02–FR-ED04, FR-ED06) | `EditorDocumentTests`: BOM, CRLF and final newline round-trip, binary/invalid/too-large refusals, permissions kept, failed write keeps the file, change and deletion detection. |
| Languages and highlighting (FR-ED03) | `EditorLanguageTests`, `CodeHighlighterTests`: detection by name and `#!` line, tokens per language, linear time on hostile input, the scratchpad grammars unchanged. |
| Tabs, saving, closing, links, Files, theme (FR-ED01, FR-ED05, FR-ED07–FR-ED09, FR-ED11) | `EditorTabTests`: open and reuse, not in the snapshot, dirty close asks, space close and quit ask, tab selection, Review coexisting, fallback to the default app, Files default and remembered choice, link inside and outside the project with line and column, theme change repaints. |
| The editor in the app, VoiceOver, IME (FR-ED03, FR-ED10) | Manual: **pending** (typing and IME input, find bar, Go to Line, theme switching by eye, VoiceOver walk of the tab and text area). |
