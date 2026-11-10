# Command scratchpad

The scratchpad is a small editor beside your panes where you write a command or script, check its syntax and run it in the focused pane without leaving Trellis. When it works, you can save it as a [task](tasks.md) in the project's `launch.json`, or keep notes next to it in Markdown.

## Open the scratchpad

The scratchpad is one of the views of the [right sidebar](sidebar.md). Open it with the `</>` icon in the dock on the window's right edge, with **View → Show Scratchpad**, or with <kbd>⌥</kbd><kbd>⌘</kbd><kbd>E</kbd> (you can rebind it in **Settings → Keyboard**). The same icon, menu item or shortcut closes it again.

The editor has focus as soon as it opens, and closing it returns focus to the terminal. Drag the sidebar's left edge to make it wider or narrower.

The scratchpad works with the focused pane, which must be on this Mac. Its icon is dimmed while an SSH or remote workspace pane is focused.

## Languages

Choose the language from the selector in the header. Its menu lists every language with the interpreter it uses and marks the current one. Changing the language changes the highlighting, the file extension, the syntax check and the interpreter.

| Language | File | Check | Run types |
| --- | --- | --- | --- |
| sh | `.sh` | `sh -n` | `sh '<file>'` |
| bash | `.sh` | `bash -n` | `bash '<file>'` |
| JavaScript | `.js` | `node --check` | `node '<file>'` |
| Markdown | `.md` | — | — (notes: highlighted and saved, never checked or run) |

## The panel

**Header.** The file selector shows **Scratchpad** until you save, then the saved file's name, with **Edited** while your text differs from it. Its menu offers **New Scratchpad** and lists the project's saved scratchpads. Next to it are the language selector and a close button.

**Editor.** Plain text in your terminal's font and theme colors, with line numbers and syntax highlighting. Smart quotes, dashes, text replacement, spelling and link detection are off, so what you type is what runs: `"` stays a straight quote and `--` stays two hyphens. Undo, Find (<kbd>⌘</kbd><kbd>F</kbd>, <kbd>⌘</kbd><kbd>G</kbd> and <kbd>⇧</kbd><kbd>⌘</kbd><kbd>G</kbd>, which search the editor rather than the pane while it has focus) and the usual editing commands work. <kbd>Tab</kbd> inserts a tab; <kbd>Ctrl</kbd><kbd>Tab</kbd> moves focus out of the editor.

**Check result.** After a check, the panel shows **Syntax OK** with the check that ran, or each problem as `Line N: message`, and marks those lines in the gutter. **Not checked** means the interpreter couldn't be found or started. Editing the text clears the result.

**Footer.** **Runs in** names the focused pane and its state: at prompt, busy, task running, not running, remote shell or no shell integration. Then come four icon buttons:

| Button | Shortcut while the editor has focus | Does |
| --- | --- | --- |
| Clear (trash) | — | Starts an empty buffer. |
| Validate (✓ in a circle) | <kbd>⌥</kbd><kbd>⌘</kbd><kbd>V</kbd> | Checks the syntax without running anything. |
| Save as Task (tray) | <kbd>⌥</kbd><kbd>⌘</kbd><kbd>S</kbd> | Opens the save sheet, with **Save** and **Save & Run**. For Markdown it is **Save File…**, which saves without a task. |
| Run (filled play) | <kbd>⌘</kbd><kbd>↩</kbd> | Checks, then runs in the focused pane. |

Hover a button to see its name and shortcut. When a button is disabled, its tooltip says why.

## Check a script

**Validate** runs the language's syntax check (`sh -n`, `bash -n` or `node --check`) on a private copy of your text, with a 5-second limit, and shows up to 20 problems with their line numbers. Nothing in your script runs.

Before any check, text containing control or invisible formatting characters other than tabs (carriage returns included) is rejected with the line number, and so is an empty buffer or one over 64 KB.

Trellis looks for the interpreter in its own `PATH`, `/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin` and `/bin`. If none is found, the result is **Not checked**, which doesn't stop you from running the script.

## Run a script

**Run** checks the script first and stops if the check finds a problem. Then it saves your text to a private file in Trellis's state folder and types `<interpreter> '<file>'` into the focused pane, followed by Return. The script runs in the pane's current folder. Like a task, it first clears anything half-typed at the prompt.

**Run** is available only when the buffer isn't empty, the last check didn't fail, and the focused pane can run a task: a shell on this Mac with [shell integration](shell-integration.md), idle at its prompt, with no task already running. So a script can never land inside an editor or a running program.

While it runs, the [Tasks](tasks.md) view follows it like any task, named after the file, with the elapsed time, how it ended, and **Stop**.

## Save as a task

When a script works, click Save as Task (<kbd>⌥</kbd><kbd>⌘</kbd><kbd>S</kbd>). The sheet asks for:

- **Task name**, as it appears in the Tasks view.
- **File name**: letters, digits, `.`, `-` and `_`, not starting with `.` or `-`. It is suggested from the task name until you edit it, so **Deploy preview** becomes `deploy-preview`.
- **Group**: none, `build`, `test` or `run`.

The sheet shows the exact command the task will run. **Save** stays disabled, with the reason shown, until both names are valid. Saving again later offers the same names.

**Save** writes your script to `.trellis/scratch/<name>.<ext>` in the focused pane's project and adds a task to `launch.json` whose command is `<interpreter> .trellis/scratch/<name>.<ext>`, run from the project folder. **Save & Run** also runs it right away, like the Tasks view, including the review if the file isn't trusted yet.

Adding the task works the same way as adding a detected task: a task with the same command isn't added twice, a name already taken gets a number, and a `launch.json` that changed since it was read, or doesn't parse, is left alone. If `launch.json` was trusted, it stays trusted.

- An existing script file is replaced only if this scratchpad saved it during this session (or you opened it from the file selector). Otherwise Trellis asks you to choose another name.
- If the task can't be added, Trellis puts the script folder back the way it was.
- If the pane isn't in a project, its current folder becomes one and `.trellis/scratch/` is created there. Your home folder and `/` are never projects; saving there tells you why and writes nothing.

## Open saved scratchpads

The file selector in the header lists the scripts and notes in the focused pane's project's `.trellis/scratch/` folder, sorted by name. Choosing one opens it; if your current text has unsaved changes, Trellis asks first. The language comes from the extension, and for `.sh` files from the `#!` line (`sh` when it names sh, otherwise bash). An opened file counts as saved, so saving again replaces it.

Only regular files you own, up to 64 KB and valid UTF-8, are opened; otherwise your current text is kept and the reason is shown. Symbolic links and other files aren't listed.

**New Scratchpad** starts empty, like Clear.

## Keep notes in Markdown

Choose **Markdown** to keep notes beside your scripts. Headings, emphasis, code, links, lists, quotes and rules are highlighted, and emoji are fine. Notes are never checked or run: Validate and Run are disabled. The save button becomes **Save File…**, which asks only for a file name and writes `.trellis/scratch/<name>.md` without adding a task.

## Clear the scratchpad

Clear (the trash icon) starts an empty buffer in the same language and clears the check result and the saved file name. If your text has unsaved changes, Trellis asks first, with **Clear** and **Cancel**. Clearing never removes a saved script or its task.

## Privacy

- What you type in the scratchpad, its name, language and check result live in memory only. They aren't saved with your workspace and are gone when you quit Trellis. Nothing from the scratchpad is logged.
- Your text is written to disk only when you check it (a private temporary file, removed straight away), run it (a private file in Trellis's state folder, deleted when Trellis quits, or at the next launch after a crash) or save it (in the project).
- The scratchpad never stores secrets for you. Text you put in a script is written to disk when you run or save it.
- Saved scripts are files in the repository, next to `launch.json`. Anyone who can change them changes what the task runs, so review changes to `.trellis/scratch/` like any other code. The task review covers `launch.json` itself, not the scripts it names.

## Limits

- The scratchpad holds one buffer, shared by all your spaces.
- Text is limited to 64 KB; typing or pasting more is refused with a beep.
- The syntax check uses the first interpreter it finds in the folders above, which can differ from the one your shell finds on its `PATH` (for example macOS's `/bin/bash` 3.2 versus a newer Homebrew bash).
- `sh -n`, `bash -n` and `node --check` find syntax errors only. A script that passes can still fail when it runs.
- Run needs a shell on this Mac with shell integration, like tasks.
