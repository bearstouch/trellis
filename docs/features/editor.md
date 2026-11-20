# Editor tabs

An **editor tab** opens a text file of the project in the current space, so a quick change doesn't need another app. It
has line numbers, syntax highlighting, undo and find, and saves with ⌘S. Open one from the [Files](files.md) view or by
⌘-clicking a path that a [terminal](terminal.md#links) printed inside the project.

All requirements here are P1.

## Opening a file

- **Files:** **Trellis Editor** is the first entry of **Open in**, and the default until another app is chosen. Return
  and **Open in** open the selected file in an editor tab; the row's context menu also has **Open in Trellis Editor**.
  Double-clicking a code file (a name or extension the editor highlights, such as `.swift`, `.ts`, `.md` or `Dockerfile`)
  always opens it in an editor tab, even when another app is chosen; that choice is kept, and is used for a code file the
  editor refuses. A CSV or TSV file opens the same way, already showing its [table](#table-preview). A folder opened with Trellis Editor is shown in Finder.
- **Terminal links:** ⌘-click on a file path inside the pane's project (as for Files, FR-FB02) or below the pane's
  current folder opens it in an editor tab, at the line and column of a `path:line[:column]` suffix. Right-clicking such a
  path offers **Open in Trellis Editor** first, and for a Markdown, CSV or TSV file **Preview in Trellis Editor**, which
  opens the tab on its rendered preview. Paths elsewhere keep [FR-L02](terminal.md#links).

The tab opens in the current space, after its terminal tabs (and after the editor tab being shown, if any). When the file is
already open in that space its tab is focused instead (and moves to the line, if one was given). Only UTF-8 text up to 2 MB opens: a file with a NUL byte in its first
8 KB, one that isn't valid UTF-8, or one over 2 MB is handed to the default app with the FR-L03 rules (a launchable file
is only revealed), and Trellis says why.

## Editing and saving

The editor keeps the file's line endings (LF or CRLF), its byte-order mark and whether it ends with a newline. Typing never
substitutes quotes, dashes or spelling. Each editor tab has its own undo history. ⌘S saves: the text is written to a temporary file in the same folder, which then
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

## Markdown preview

A Markdown tab has a **Preview** button in its header (⇧⌘V) that shows the file rendered in place of its source; **Edit**
(the same button and chord) goes back. The choice belongs to the tab and is never saved. The preview shows the tab's
current text, unsaved changes included, and follows it as it changes. While previewing, ⌘S still saves, the unsaved mark
stays, and the source keeps its undo history, cursor and scroll position; Find goes back to Edit first.

The preview is drawn by Trellis in the theme's colors and fonts, with no web view and no scripts. It shows ATX and setext
headings, paragraphs and hard line breaks, emphasis, strong, strikethrough, inline code and links, bullet, ordered and
task lists (nested), block quotes, fenced and indented code (fenced code highlighted when its language is one the editor
knows), GitHub tables with column alignment, and thematic breaks. Raw HTML is shown as text and never interpreted.

The file is untrusted, so the preview never reaches out by itself:

- Clicking a `http`, `https` or `mailto` link opens it in the default app. A relative link to a file inside the project
  opens it in an editor tab (for a file opened outside a project, inside its own folder; a leading `/` names that root,
  and a symbolic link is judged by its target), and a `#heading` link scrolls to that heading. A link with any other
  scheme is drawn as plain text, not a link; any other link, or a path outside the project, does nothing.
- Images are never loaded, local or remote: each shows as its alt text beside an image symbol.

## Table preview

A CSV (`.csv`) or TSV (`.tsv`, `.tab`) tab has the same **Preview**/**Edit** button and ⇧⌘V, and its preview is a table.
As for Markdown, the choice belongs to the tab and is never saved, the table shows the tab's current text with unsaved
changes, ⌘S still saves, the source keeps its undo, cursor and scroll position, and Find goes back to Edit first.

The file is read as RFC 4180: fields in double quotes may hold the delimiter, line breaks and `""` for a quote, and rows
end with LF, CRLF or CR. A `.csv` uses commas, or semicolons when its first line has more semicolons than commas; a TSV
uses tabs. A leading byte-order mark and blank lines are skipped, and a quote that never closes takes the rest of the
file. A quoted empty value (`""`) on its own line is a row. The first row is the header (an empty name shows as "Column N");
a short row shows empty cells and every column of a long row is kept. At most 100 000 rows and 1 000 columns are shown,
with a note naming the limit that was reached.

The table is native, in the theme's colors and terminal font: a fixed header, a row number column (the record's number
after the header, which differs from the line number when a quoted cell spans lines), resizable columns, and a line break in a cell shown as `↵` with the whole value in its tooltip. A column whose
every non-empty cell is a plain, finite decimal number aligns to the right. Clicking a header sorts by that column, again to
reverse it: numbers by value, text as Finder sorts names, empty cells last, equal cells in file order. Sorting changes
only the view, never the text. ⌘C copies the selected rows as tab-separated text.

## Shortcuts

| Do this | To |
| --- | --- |
| ⌘S | Save |
| ⌘L | Go to line |
| ⇧⌘V | Markdown, CSV and TSV: switch between Preview and Edit |
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
| FR-ED09 | Choose Trellis Editor in Files. | **Open in** lists Trellis Editor first; it is used when no app has been chosen, and a remembered choice is kept. The row context menu offers **Open in Trellis Editor**. Double-clicking a code file (known to the editor by name or extension) opens it in an editor tab whatever app is remembered, without changing the choice; any other file, a link to a folder, and a code file FR-ED02 refuses open in the remembered app. |
| FR-ED10 | Make editor tabs accessible and localized. | The tab is named "Editor tab, <file>" with the value "unsaved" when it is; the text area is named after the file and its language; every header button has a label and a tooltip; banners are announced. All text on screen is localized. |
| FR-ED11 | Follow the theme. | Editor colors, syntax colors and font come from the active theme and terminal font settings. Changing the theme, previewing one in Settings (and cancelling), or switching appearance repaints open editor tabs at once; their text, selection, undo and scroll position are kept. |
| FR-ED12 | Preview Markdown. | A Markdown tab, and only a Markdown tab, shows **Preview**/**Edit** (⇧⌘V); the choice is per tab, kept while switching tabs and never saved. The preview renders the tab's current text including unsaved changes, and the elements listed above; raw HTML appears as text. ⌘S saves while previewing, and going back to Edit keeps undo and the cursor. Web links open only by a click and only for `http`, `https` and `mailto`; a relative link inside the project opens an editor tab; `#heading` scrolls; any other link does nothing; images are never loaded. Headings are announced as headings and task items as done or not done. |
| FR-ED13 | Keep the preview quick in a long document. | The preview is drawn again only when the text, the theme, the font, the language, Reduce Motion or a `#heading` link changes; a change anywhere else in the app (typing in a pane, a progress report, a tab switch) redraws none of it. A document of up to 150 top-level blocks is laid out whole, so its scroll height is exact; a longer one builds its blocks as they scroll into view, so it shows at once whatever its length, and its scroller may settle as blocks are measured. `#heading` links reach headings that aren't built yet, and every block has an id of its own even when a numbered heading meets a repeated one (`Step`, `Step`, `Step 1`). Known limit: in a document over 150 blocks, VoiceOver finds only the headings built so far. |
| FR-ED14 | Type without lag up to the size limit. | A key typed in a file near the 2 MB limit stays near 10 ms (about 4 ms in a 400 KB file): each key reads the text view's text into the tab once, in one pass, and checks the size limit against the size already known, instead of walking the file a character at a time. Text reaches the tab byte for byte, including accents, emoji and characters beyond the BMP; an unpaired surrogate is replaced by U+FFFD as before. |
| FR-ED16 | Show a remote workspace's file read-only. | Opening a file from the Files view of a remote workspace pane (FR-FB09) reads it through the host's helper (FR-RW19) and shows it in an editor tab of the current space marked "Read-only · <host>" in the header, the tab's tooltip and its accessibility value. FR-ED02 applies to its bytes (UTF-8, at most 2 MB, no NUL in the first 8 KB); a refused file opens nothing and shows the reason, since no app on this Mac can open it. The text can be selected, searched, copied and, for Markdown, previewed (FR-ED12; links to files open nothing), but not changed: typing does nothing, there is no Save, Open With or Reveal in Finder, ⌘S writes nothing, and closing never asks. **Reload** reads the file again from the host; this Mac's disk is never compared with it (FR-ED06 doesn't apply). The tab is separate from a tab for the same path on this Mac, and its title adds the host when both are open. Like every editor tab it is never saved (FR-ED08), so its text is kept only in memory. With the host not connected, opening and Reload say so and change nothing. |
| FR-ED15 | Preview Markdown and tables from terminal links. | The terminal link context menu offers **Preview in Trellis Editor**, after **Open in Trellis Editor**, only for a Markdown file (`.md`, `.markdown`, `.mdown`, `.mkd`) or a table (`.csv`, `.tsv`, `.tab`, FR-ED17) that FR-ED07 would open in an editor tab. Choosing it opens the file in an editor tab showing its preview (FR-ED12); when the file is already open in the space, its tab is shown and switched to the preview. A file FR-ED02 refuses keeps the FR-L02 behavior. It opens only when chosen, never from output alone. |
| FR-ED17 | Preview CSV and TSV as a table. | A CSV or TSV tab, besides a Markdown one, shows **Preview**/**Edit** (⇧⌘V); the choice is per tab, kept while switching tabs and never saved, and ⌘S, the unsaved mark, undo, the cursor and Find behave as in FR-ED12. The table shows the current text, unsaved changes included, read as described above: quoted fields with delimiters, `""` and line breaks, LF/CRLF/CR, the semicolon guess, BOM and blank lines skipped, an unterminated quote taking the rest, short rows shown with empty cells (never stored padded), "Column N" for an empty header name, and the 100 000-row and 1 000-column caps with a note naming the one reached. Reading and memory are linear in the file's size on any input, including a wide header over many short rows. Numeric columns align right; a header click sorts the view (numbers by value, text as Finder, empty last, stable) and never the text; ⌘C copies the selected rows as TSV. The table is named "Table preview of <file>" and its header and cells are read by VoiceOver; row numbers are text. |
| FR-ED18 | Open tables from Files on their preview. | A double click on a `.csv`, `.tsv` or `.tab` file in Files opens it in an editor tab showing its table, whatever app **Open in** remembers, which is kept (FR-ED09); **Open in Trellis Editor** does the same, and an open tab is shown and switched to its table. On a remote workspace the read-only tab (FR-ED16) opens on its table too. A file FR-ED02 refuses opens in the remembered app, as code does. |
| FR-ED19 | Keep the table preview quick up to the size limit. | Nothing is parsed or built while the source is shown, so typing in a CSV costs what it does in any file (FR-ED14). The file is read off the main thread, and the table is loaded again only when its text, the theme, the font or the language changes; a change anywhere else in the app (typing in a pane, a progress report, a tab switch) reloads none of it. Only the rows on screen are built, and every row has the same height, so a file at the 2 MB limit shows at once with an exact scroller. Sorting runs off the main thread, and a newer sort or edit wins over one still running. Measured on a 2 MB, 31 500-row CSV (optimized build, hosted view): the table shows in about 95 ms, an unrelated change costs about 2 ms, a 2 000 pt scroll step about 14 ms, sorting about 4 ms for numbers and 41 ms for text (about 120–140 ms until the sorted rows are drawn), and showing it again after an edit about 100 ms. |

## Verification

| Area | How it's checked |
| --- | --- |
| Reading, encoding, saving, disk changes (FR-ED02–FR-ED04, FR-ED06) | `EditorDocumentTests`: BOM, CRLF and final newline round-trip, binary/invalid/too-large refusals, permissions kept, failed write keeps the file, change and deletion detection. |
| Markdown preview (FR-ED12) | `MarkdownDocumentTests`: each block kind, nesting, task items, fences, tables, setext headings, HTML as text, the nesting cap and linear time on hostile input, link actions (schemes, project scope, `..` and link escapes, anchors) and heading slugs. `EditorTabTests`: the toggle only for Markdown and per tab, saving while previewing, project, web and refused links. |
| Long previews (FR-ED13) | `MarkdownPreviewLongDocumentTests`: block ids with repeated and clashing headings, the preview comparing equal until its text, font or heading link changes, and a short and a 2 400-block document hosted in a window, each showing its full scroll height and scrolling to a `#heading` near its end. |
| Markdown and table preview from terminal links (FR-ED15) | `TerminalEditorLinkTests`: the menu item only for Markdown or a table the editor may open and only with an editor, choosing it previews the file, a stale gesture opens nothing, a refused or non-Markdown file opens as before. `EditorTabTests`: a new tab opens on its preview, an open tab is reused and switched to it, other files ignore it, a path outside the project is handed back. Manual: right-clicking a `.md` path in the app opens its preview (observed). |
| Table preview (FR-ED17, FR-ED18) | `DelimitedDocumentTests`: quotes, escapes, line breaks in quotes, LF/CRLF/CR, BOM, blank lines and a quoted empty value, ragged rows kept unpadded, the semicolon guess, an unterminated quote, numeric columns (not `inf` or overflow), each cap and no false truncation, linear time on hostile input including a 1 000-column header over 100 000 short rows, and `.csv`/`.tsv`/`.tab` detection. `TablePreviewLongDocumentTests`: sort order (numbers, Finder order, empty and missing cells last, stable) and ⌘C text (shown order, quoting of tabs and quotes, nothing when nothing is selected). `EditorTabTests`: the toggle for tables and not plain text, saving while previewing, Files opening a table on its preview and reusing its tab, a terminal link previewing a table. `FilesSidebarTests`: a double click opens a CSV on its table whatever app is remembered. `RemoteFilesSidebarTests`: a host's CSV opens read-only on its table, and an open tab is switched to it. `TerminalEditorLinkTests`: the preview item for a CSV. Manual: the table in the app in light and dark themes, sorting, resizing and ⌘C by hand, and VoiceOver reading the header and cells: **pending**. |
| Table preview speed (FR-ED19) | `DelimitedDocumentTests`: a 2 MB file parses quickly. `TablePreviewLongDocumentTests`: the preview comparing equal until its table or font changes; a sort still running when the rows change never applying to the new rows, and the row number column widening with them; a 30-row TSV, a 30-row CSV and a 2 MB CSV hosted in a window, each with nothing built while the source is shown, every row counted, an exact scroll height, only the rows on screen built, no reload on an unrelated change, sorting reordering the view but not the text, and an edit shown on return; it prints the times FR-ED19 records (run with `swift test -c release -Xswiftc -enable-testing --filter TablePreviewLongDocumentTests`). Scrolling a 2 MB table by hand in the app: **pending**. |
| Read-only remote tabs (FR-ED16) | `RemoteFilesSidebarTests`: the tab's text, host and read-only mark, typing and saving doing nothing and the host's file unchanged, no disk check, reuse of an open tab, Reload, a local tab for the same path staying separate and editable, closing without a question, a binary and a missing file opening nothing. `RemoteWorkspaceTests`: a file longer than one chunk read whole through the real helper. The tab in the app and VoiceOver: **pending**. |
| Typing in large files (FR-ED14) | `ScratchpadEditorReviewTests`: the text storage read as a native string for ASCII, accented, emoji and non-BMP text, unpaired surrogates, NUL and CRLF; the size limit using the known size only while it matches the text view; and typing in the middle of a long non-ASCII text reaching the model intact. |
| Languages and highlighting (FR-ED03) | `CodeHighlighterTests`: detection by name and `#!` line, tokens per language, linear time on hostile input, the scratchpad grammars unchanged. |
| Tabs, saving, closing, links, Files, theme (FR-ED01, FR-ED05, FR-ED07–FR-ED09, FR-ED11) | `FilesSidebarTests`: a double click opens code in an editor tab whatever app is remembered, and refused code or a link to a folder in that app; `EditorDocumentTests`: code files known by name or extension; `EditorTabTests`: open and reuse, not in the snapshot, dirty close asks, space close and quit ask, tab selection, Review coexisting, fallback to the default app, Files default and remembered choice, link inside and outside the project with line and column, theme change repaints. |
| The editor in the app, VoiceOver, IME (FR-ED03, FR-ED10) | Manual: **pending** (typing and IME input, find bar, Go to Line, theme switching by eye, VoiceOver walk of the tab and text area). |
