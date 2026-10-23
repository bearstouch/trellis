# Command scratchpad

The scratchpad is a panel on the right of the window where you write a command or script, check its syntax and run it in the focused pane without leaving Trellis. When it works, you can save it as a [task](tasks.md) in the project's `launch.json`.

Open it with the `</>` button in a local pane's header, just left of **Tasks**, or with **View → Show Scratchpad** (⌥⌘E, rebindable). The button opens the panel for that pane and shows as pressed while the panel is open there. The panel sits beside the panes and below the tab bar; drag its left edge to resize it.

All requirements here are P2.

## Languages

Each language is one entry in a registry: its name, file extension, the interpreter **Run** types (none for text that is never run, like Markdown), the arguments that check syntax without running, and the highlighting rules. The language selector lists every entry with its interpreter, so adding a language adds one row to the menu and needs no other UI change.

| Language | File | Check | Run types |
| --- | --- | --- | --- |
| sh | `.sh` | `sh -n` | `sh '<file>'` |
| bash | `.sh` | `bash -n` | `bash '<file>'` |
| JavaScript | `.js` | `node --check` | `node '<file>'` |
| Markdown | `.md` | — | — (notes: highlighted and saved, never checked or run) |

## The panel

| Part | What it does |
| --- | --- |
| Header | The file selector: **Scratchpad** until the script is saved, then the saved file's name, with **Edited** while the buffer differs from it. Its menu offers **New Scratchpad** and lists the project's saved scratchpads (FR-SP10). Then the language selector and a close button. |
| Editor | Plain text in the terminal font and colors, with line numbers. Smart quotes, dashes, text replacement, spelling and link detection are off, so what you type is what runs. Undo, Find (⌘F, ⌘G and ⌘⇧G, or whatever Find is bound to; they search the editor, not the pane, while it has focus) and the standard editing commands work. Tab inserts a tab; Ctrl-Tab moves focus out. |
| Check result | **Syntax OK** with the check that ran, or each problem as `Line N: message` with a symbol, or **Not checked** when the interpreter couldn't be found or started. Lines with a problem are also marked in the gutter. Editing the text clears the result. |
| Footer | **Runs in** the focused pane's title and its state (at prompt, busy, task running, not running, remote shell, no shell integration), then four icon buttons. |

| Button | Shortcut while the editor has focus | Does |
| --- | --- | --- |
| Clear (trash) | — | Starts an empty buffer (FR-SP09). |
| Validate (✓ in a circle) | ⌥⌘V | Checks the syntax. |
| Save as Task (tray) | ⌥⌘S | Opens the save sheet, which offers **Save** and **Save & Run**; for Markdown, **Save File…** saves without a task. |
| Run (filled play) | ⌘Return | Checks, then runs in the focused pane. |

The buttons are icons only. Each has a tooltip and an accessibility label with its name and shortcut; a disabled button's tooltip and hint say why it is disabled.

## Requirements

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| FR-SP01 | Open and close the scratchpad beside the panes. | Local pane headers show the `</>` button immediately left of **Tasks**; SSH panes don't. Clicking it in the focused pane toggles the panel; clicking it in another pane focuses that pane and keeps the panel open. **View → Show/Hide Scratchpad** (⌥⌘E by default, rebindable; it yields to a chord you had already assigned) does the same for the focused pane. The panel opens with the editor focused; closing it returns focus to the terminal. It is 380 points wide by default, 280–640 by dragging its edge or with VoiceOver's adjust actions, and the canvas takes the rest, so split minimums still apply. Opening, closing and resizing never change the saved workspace. |
| FR-SP02 | Edit with syntax highlighting. | The editor uses the terminal font, size and colors of the active theme, and highlights keywords, commands, strings, comments, variables and expansions, numbers and operators with the theme's ANSI colors. Typing `"` or `--` never becomes curly quotes or a dash. Highlighting is display-only and never changes the text or undo. Unterminated quotes and comments, and a 64 KB buffer, highlight without hanging. Input that would make the buffer larger than 64 KB is refused with a beep. |
| FR-SP03 | Choose the language from a selector. | The selector shows the current language; its menu lists every registered language with its interpreter and marks the current one. Changing the language changes the highlighting, the file extension, the check and the interpreter, and clears the check result. |
| FR-SP04 | Validate without running. | Before any interpreter runs, a runnable buffer is rejected with a line number when it contains control or invisible formatting characters other than tabs (carriage returns included), and rejected when it's empty, over 64 KB or has an invalid name. The check writes the buffer to a private file (0600, in a 0700 folder), runs the language's check on it with a 5-second limit and removes it. `bash -n` and `sh -n` errors (`file: line N: message`) and `node --check` errors (`file:N` … `SyntaxError: message`) are shown with their line numbers, at most 20. A check that runs too long fails with a message. An interpreter that isn't found in the app's PATH, `/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin` or `/bin`, or that can't start, gives **Not checked** and doesn't block Run. A result for text that changed during the check isn't shown. |
| FR-SP05 | Run in the focused pane. | Run is enabled only when the buffer isn't empty, the last check didn't fail, and the focused pane can run a task (FR-TK05: a local shell with integration, idle at its prompt, no task running). Otherwise it is disabled and says why. Run checks first; a failed check stops it. It then writes the buffer to `scratch/<name>.<ext>` in the state directory (0600) and types `<interpreter> '<file>'` after Ctrl-E Ctrl-U, quoted for the pane's shell, followed by Return. The pane's Tasks button follows it like a task (FR-TK07, FR-TK08), named after the file. The script runs in the pane's current folder. |
| FR-SP06 | Save as a task. | The sheet asks for the task name, the file name (letters, digits, `.`, `-` and `_`, not starting with `.` or `-`; suggested from the task name until you edit it, e.g. **Deploy preview** → `deploy-preview`) and an optional group, and shows the command verbatim. Save stays disabled, with the reason shown, until both names are valid. Saving again after a save offers the same names. **Save** writes the buffer to `.trellis/scratch/<name>.<ext>` in the focused pane's project (mode 0644) and appends a task `{"name", "command": "<interpreter> .trellis/scratch/<name>.<ext>", "group"}` to `launch.json` through the same path as adding a detected task (FR-TK04): same-command tasks aren't duplicated, a taken name gets a number, a file that changed since it was read or doesn't parse is left alone, and trust carries over only from a trusted or missing file. An existing script file is replaced only if this scratchpad saved it during this session and it can still be read; otherwise saving asks you to rename. A symbolic link in `.trellis`, `.trellis/scratch` or the file is refused. If the task can't be added, the script file is restored or removed. Without a project, the pane's current folder becomes one: `.trellis/scratch/` is created there (except in your home folder or `/`, which are never projects; saving there reports why and writes nothing). **Save & Run** then runs the task like the Tasks menu, with review if the file isn't trusted (FR-TK06). |
| FR-SP07 | Keep the buffer private. | The buffer, name, language, check result and panel state live in memory only: they aren't saved with the workspace and are gone after quitting. Nothing from the scratchpad is logged. Only Validate (temporary private file), Run (private state folder) and Save (the project) write the text to disk. |
| FR-SP08 | Make the panel accessible. | The panel is a labelled group. The pane button has the label **Scratchpad** and the selected trait while pressed. **Edited** is text, not a color or dot. The language selector (label and value), editor and each icon button have labels; tooltips give the shortcut, or the reason when disabled. Check results use words and symbols, never color alone, and the gutter marks are repeated as `Line N` text. |
| FR-SP09 | Clear the buffer. | **Clear** (trash icon in the footer, left of Validate) starts an empty buffer in the same language and clears the check result and the saved file name. It asks first, with **Clear** and **Cancel**, when the buffer has unsaved changes: text that was never saved, or text or language that differs from the last save. A saved, unchanged buffer clears at once. The saved script and its task are never removed. It is disabled when there is nothing to clear. |
| FR-SP10 | Open saved scratchpads, and keep notes in Markdown. | The header's file selector lists the regular files in the focused pane's project's `.trellis/scratch/` whose names the scratchpad could have saved (`<name>.<ext>` with a registered extension), sorted by name; symbolic links, other files and a linked `.trellis` or `.trellis/scratch` are left out. It reads the folder again when the focused pane changes and after a save. Choosing a file asks first when the buffer has unsaved changes, then opens it: only a regular file you own, at most 64 KB and valid UTF-8 is read, otherwise the buffer is kept and the reason shown. The language comes from the extension, and for `.sh` from the `#!` line (`sh` when it names sh, else bash). An opened file counts as saved, so Save may replace it. **New Scratchpad** works like Clear. Markdown is highlighted (headings, emphasis, inline and fenced code, links, list, quote and rule markers, HTML comments) and has no hidden-character check, so emoji with joiners are fine. Validate and Run are disabled for it with the reason, and Save becomes **Save File…**: the sheet asks only for the file name and writes `.trellis/scratch/<name>.md` without adding a task. |

## Trust and safety

- Run types into the pane only when its shell reports it is idle at its prompt, like a task, so a script can't land inside an editor or a running program.
- Saved scripts are repository files next to `launch.json`. Anyone who can change them changes what the task runs, just as with `launch.json` itself; review changes to `.trellis/scratch/` like any other code. Trust (FR-TK06) covers `launch.json`'s bytes, not the scripts it names.
- The scratchpad never stores secrets for you. Text you put in a script is written to disk when you run or save it.

## Known limits

- The syntax check uses the first interpreter found in the folders above, which can differ from the one your shell finds on its PATH (for example macOS `/bin/bash` 3.2 versus a newer Homebrew bash).
- `sh -n`, `bash -n` and `node --check` find syntax errors only; a script that parses can still fail when it runs.
- Run needs shell integration and a local shell, like tasks.
- The panel is shared by all windows in the sidebar and keeps one buffer.
