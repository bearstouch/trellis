# Tasks

Tasks are a project's named build, test and run commands, checked into its repository as `.trellis/launch.json`, next to the [workspace file](workspace-files.md). Each local pane's header has a **Tasks** menu, next to **Local**, that lists them for the pane's project. **Run** types a task into that pane's shell, the menu shows that it is running and how it ended, and **Stop** interrupts it.

Trellis also detects common tasks in the project folder (npm, Make, CMake, SwiftPM, Python and Cargo). You can run a detected task directly, or add it to `launch.json` with one click.

All requirements here are P2.

- Schema: [`launch-file.schema.json`](../api/launch-file.schema.json) (JSON Schema 2020-12)
- Example: this repository's own [`.trellis/launch.json`](https://github.com/bearstouch/trellis/blob/master/.trellis/launch.json). The tests parse it.

```json
{
  "version": 1,
  "env": {
    "NODE_ENV": "development"
  },
  "tasks": [
    {
      "name": "build",
      "command": "swift build",
      "group": "build"
    },
    {
      "name": "test UI",
      "command": "swift test --filter TrellisUITests",
      "cwd": ".",
      "group": "test",
      "env": {
        "TRELLIS_TEST_VERBOSE": "1"
      }
    }
  ]
}
```

## Format

| Element | Rules |
| --- | --- |
| Document | `version` (must be `1`) and `tasks` (0–100), with optional `env`. An optional `$schema` string is kept but otherwise ignored. Any other field is an error. Files are limited to 64 KB. |
| Task | `name` (1–100 characters, unique in the file) and `command`, with optional `cwd`, `group` and `env`. |
| `command` | One shell line, with the same rules as a [workspace file command](workspace-files.md#format): at most 4,096 characters, no control, line-separator or invisible characters. The shell parses it, deliberately. |
| `cwd` | Relative to the project folder, with the same rules as a workspace file `directory`. Omitted or `.` means the project folder. |
| `group` | `build`, `test` or `run`. It is shown as a word next to the task. |
| `env` | An object of variable names to string values. Names match `[A-Za-z_][A-Za-z0-9_]*` (at most 255 characters); values are at most 4,096 characters without control or invisible characters, and may be empty. The top-level `env` applies to every task in the file; a task's own `env` wins for the same name. At most 50 variables apply to one task. Values are literal: `$VAR`, `${…}` and `~` are not expanded. |

Encoding writes fields in a fixed order (`$schema` when present, `version`, `env`, `tasks`; each task `name`, `command`, `cwd`, `group`, `env`), variables sorted by name, with two-space indentation and a final newline, so adding a task changes only the lines it adds.

## How a task runs

The project folder is the nearest folder at or above the pane's directory that has a `.trellis` folder or a `.git` folder or file. The search never leaves your home folder and never treats home or `/` as a project.

**Run** types one line into the pane's shell, followed by Return:

- `<command>` when the shell is already in the task's folder.
- `cd '<folder>' && <command>` otherwise. The `cd` stays in effect afterwards, like any command you type.
- With variables, `/usr/bin/env NAME='value' … '<shell>' -c '<command>'`, after the `cd` if one is needed. The variables apply to the whole command, including `&&` chains, and the command runs in a new instance of the pane's own shell (zsh, bash or fish), so its syntax is unchanged. That instance is not interactive, so your aliases and shell functions aren't available to it. Tasks without variables are typed exactly as written.

Before the line, Trellis sends Ctrl-E and Ctrl-U (end of line, then delete to its start) to clear anything half-typed at the prompt. Quoting follows the pane's shell: POSIX single quotes for zsh and bash, fish's single-quote escapes for fish.

Run needs [shell integration](shell-integration.md): Trellis only types into a local shell that has reported it is idle at its prompt, so a task can never land inside an editor, a REPL or a running program.

## Requirements

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| FR-TK01 | Parse `.trellis/launch.json` strictly. | An unknown field (including `label`), a wrong type, a missing or duplicate `name`, a multi-line or hidden-character command, an absolute or `..` `cwd`, an unknown `group`, an invalid variable name or value, more than 100 tasks, more than 50 variables for one task or a file over 64 KB is reported with the task's name, and nothing runs. A valid file re-encodes to identical bytes. |
| FR-TK02 | Find a pane's project and list its tasks in a **Tasks** menu in the pane's header. | Local panes show **Tasks** before **Local**; SSH panes don't. The project is the nearest folder with `.trellis` or `.git` at or above the pane's directory (its shell-reported directory, else its start folder). The search stops below home and never treats home or `/` as a project. Opening the menu reads the file again. A `launch.json` that is a symbolic link, not yours, or over the limit is refused with a reason, and nothing else in the menu is affected. The menu shows the project's name and folder, the file's tasks with their command lines, and an **Edit launch.json** (or **Create launch.json**) button. |
| FR-TK03 | Detect common tasks in the project folder. | Detection reads only these files at the project root, each with a size limit, and never runs anything: `package.json` scripts (with npm, pnpm, yarn or bun chosen by `packageManager` or the lockfile); Make targets from `GNUmakefile`, `makefile` or `Makefile` (special, pattern, variable and assignment lines are skipped, includes aren't followed, at most 50); CMake build, plus `ctest` when the file enables tests; SwiftPM build and test; Python `pytest` or `unittest` (through `uv run` when `uv.lock` exists) and `tox`; Cargo build, test, and run when there is a binary. A script name with a quote or backslash, or starting with `-`, is skipped. |
| FR-TK04 | Add a detected task to `launch.json` with one click. | **+** creates the file if it is missing and appends the task. A task with the same command already in the file is not added twice; a name already taken gets a number. If the file changed since the menu read it, or doesn't parse, nothing is written and the menu says why. The file is written atomically with mode 0644, like a workspace file. The new version is trusted only if the previous version was trusted or there was no file, so adding a task never trusts a cloned file's other tasks. |
| FR-TK05 | Run a task in the pane whose menu was opened. | Run is enabled only for a local shell with integration that is running, not replaying, idle at its prompt, and not already running a task. Otherwise it is disabled and the menu says why. The typed line is exactly as described above. |
| FR-TK06 | Review a file's tasks before the first run of each version. | Running a task from a version of the file you haven't trusted shows a sheet listing every task's name, folder, variables and command verbatim, with **Cancel** and **Trust and Run**; Return doesn't trust. Trust is per canonical project folder and SHA-256 digest, in `launch-trust.json` (0600, in the state directory), separate from workspace file trust. Changing one byte asks again. An unreadable trust file trusts nothing and is never overwritten. The task that runs is the one from the reviewed bytes. Detected tasks don't need review: Trellis builds them from fixed templates, and the menu shows the exact line. |
| FR-TK07 | Show the task's state. | The pane's Tasks button shows **Running: name** with the elapsed time once the shell reports the command started, then **name: done**, **name: exit N** or **name: ended** (no exit status reported) with a symbol when it finishes, never color alone. VoiceOver reads the same as the button's value. The result stays until another command starts in that pane, and is cleared when the pane closes, exits or restarts. Marks replayed from a kept session never change it. The command line is never logged or persisted. |
| FR-TK08 | Stop a running task. | **Stop** sends Ctrl-C (SIGINT to the foreground job) and can be pressed again. If the task is still running 2 seconds after the first Stop, the button becomes **Force Stop**, which sends Ctrl-\ (SIGQUIT). The shell and pane stay. |
| FR-TK09 | Set environment variables for a task. | With top-level `{"A": "1", "B": "x"}` and task `{"B": "y"}`, the task sees `A=1` and `B=y`. `"V": "$HOME"` arrives as the literal text `$HOME`. A value with spaces or quotes arrives unchanged in zsh, bash and fish. Both commands of `printf "$A" && printf "$B"` see the variables. Stop and the exit code work the same as without variables. |

## Trust and safety

- `launch.json` is shared through the repository, so anyone who can change it can change what **Run** types. The review sheet shows every task before the first run of each version, and the menu always shows the exact line next to its button.
- Variable values are typed into the terminal like the command, so they appear on screen and in your shell history. Don't put secrets in `launch.json`.
- Trellis never logs the typed line, and never persists it outside `launch.json` itself.

## Known limits

- **Stop** relies on the terminal's signal characters. A program in raw mode, or one that ignores SIGINT and SIGQUIT, keeps running; use **Restart Pane** to end it.
- With shell integration off, or in a shell without bundled scripts, tasks can be listed and added but not run.
- The menu reads `launch.json` each time it opens; it doesn't watch the file.
- Ctrl-E and Ctrl-U clear a half-typed line in emacs-style line editing only. In vi command mode, or while the shell is waiting for the rest of a multi-line command, the typed line is read differently; finish or cancel what is at the prompt first.
- In the moment between a new pane's first prompt and the start of its workspace file command (FR-WF05), Run still reports the shell as idle.
- Detection looks only at the project root; it doesn't find tasks in subfolders or monorepo packages.
