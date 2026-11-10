# Tasks

Tasks are a project's named build, test and run commands, kept in its repository as `.trellis/launch.json`. Trellis lists them for the pane you're working in, runs one with a click, shows whether it is still running and how it ended, and lets you stop it.

Trellis also finds common tasks on its own (npm, Make, CMake, SwiftPM, Python and Cargo), so a project without a `launch.json` still has something to run. To write a longer script and save it as a task, use the [command scratchpad](scratchpad.md).

## Open the Tasks view

Tasks are one of the views of the [right sidebar](sidebar.md). Open it with the checklist icon in the dock on the window's right edge, with **View → Show Tasks**, or with <kbd>⌥</kbd><kbd>⌘</kbd><kbd>T</kbd>.

The view follows the focused pane. It shows the pane's project name and folder, the tasks in its `launch.json` with the exact line each one types, and below them a **Detected** list. At the bottom, **Edit launch.json** opens the file, or **Create launch.json** makes one when there is none. The reload button reads the file again.

The view works for panes on this Mac and in [remote workspaces](remote-workspaces.md). The icon is dimmed for SSH panes. The dock's Tasks icon shows a badge with the number of tasks running in all your panes.

### Which project a pane belongs to

The project folder is the nearest folder at or above the pane's current directory that contains a `.trellis` folder or a `.git` folder or file. The search never leaves your home folder, and never treats your home folder or `/` as a project. If no project is found, the view says **No project folder**.

## Run a task

Click **Run** next to a task. Trellis types the task into the focused pane's shell, followed by Return, exactly as if you had typed it. The line it types is shown under the task's name before you click.

**Run** is available only when the pane is a shell with [shell integration](shell-integration.md) that is idle at its prompt and not already running a task. Otherwise the button is disabled and the view says why. This way a task can never land inside an editor, a REPL or another running program.

The first time you run a task from a `launch.json`, Trellis asks you to review it first (see [Review before the first run](#review-before-the-first-run)). Detected tasks run straight away.

### What gets typed

- `<command>`, when the shell is already in the task's folder.
- `cd '<folder>' && <command>` otherwise. The `cd` stays in effect afterwards, like any command you type.
- With variables: `/usr/bin/env NAME='value' … '<shell>' -c '<command>'`, after the `cd` if one is needed. The variables apply to the whole command, including `&&` chains, and the command runs in a new copy of the pane's own shell (zsh, bash or fish), so its syntax is unchanged. That copy isn't interactive, so your aliases and shell functions aren't available to it. Tasks without variables are typed exactly as written.

Before the line, Trellis sends Ctrl-E and Ctrl-U (end of line, then delete to its start) to clear anything half-typed at the prompt. Quoting follows the pane's shell: POSIX single quotes for zsh and bash, fish's own escapes for fish.

### While it runs

The top of the Tasks view shows the focused pane's task:

| Shown | Meaning |
| --- | --- |
| **Starting: build** | Trellis typed the line and is waiting for the shell to report that the command started. |
| **Running: build · 12s** | The shell reported that the command started; the elapsed time counts up. |
| **build: done** | It exited with status 0. |
| **build: exit 1** | It exited with that status. |
| **build: ended** | It finished without reporting an exit status. |

Each state has a symbol as well as a color, and VoiceOver reads the same words. The result stays until another command starts in that pane, and is cleared when the pane closes, exits or restarts.

### Stop a task

**Stop** sends Ctrl-C to the task, and you can press it again. If the task is still running 2 seconds after the first Stop, the button becomes **Force Stop**, which sends Ctrl-\\. The shell and the pane stay open either way.

## Detected tasks

Trellis reads a few well-known files at the project's root, and never runs anything to do so:

| Source | Tasks |
| --- | --- |
| `package.json` | Its scripts, run with npm, pnpm, yarn or bun, chosen from `packageManager` or the lockfile. |
| `GNUmakefile`, `makefile` or `Makefile` | Its targets, up to 50. Special, pattern and variable lines are skipped, and includes aren't followed. |
| CMake | Build, plus `ctest` when the project enables tests. |
| SwiftPM | Build and test. |
| Python | `pytest` or `unittest` (through `uv run` when there is a `uv.lock`), and `tox`. |
| Cargo | Build and test, plus run when there is a binary. |

A script whose name contains a quote or backslash, or starts with `-`, is skipped. Detection looks only at the project root, not at subfolders or monorepo packages.

To keep a detected task, click **+** next to it (**Add to launch.json**). Trellis creates `launch.json` if it is missing and appends the task. A task with the same command isn't added twice, and a name that is already taken gets a number. If the file changed since the view read it, or doesn't parse, nothing is written and the view says why. Adding a task to a file you had trusted keeps it trusted; it never trusts the other tasks of a file you haven't reviewed yet.

## The launch.json format

Here is this repository's own [`.trellis/launch.json`](https://github.com/bearstouch/trellis/blob/master/.trellis/launch.json):

```json
{
  "version": 1,
  "tasks": [
    {
      "name": "build",
      "command": "swift build",
      "group": "build"
    },
    {
      "name": "test",
      "command": "swift test",
      "group": "test"
    },
    {
      "name": "lint",
      "command": "swift format lint --strict -r Sources Tests",
      "group": "test"
    },
    {
      "name": "format",
      "command": "swift format -i -r Sources Tests"
    },
    {
      "name": "run fixture",
      "command": "swift run Trellis --fixture",
      "group": "run"
    }
  ]
}
```

And one that uses a folder and variables:

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

| Element | Rules |
| --- | --- |
| Document | `version` (must be `1`) and `tasks` (0–100), with optional `env`. An optional `$schema` string is kept but otherwise ignored. Any other field is an error. The file is limited to 64 KB. |
| Task | `name` (1–100 characters, unique in the file) and `command`, with optional `cwd`, `group` and `env`. |
| `command` | One shell line, with the same rules as a [project command](project-library.md#what-a-project-contains): at most 4,096 characters, no control, line-separator or invisible characters. The shell parses it, so pipes, `&&` and quoting work as usual. |
| `cwd` | Relative to the project folder. Absolute paths, `~`, `..` segments, `$`, backticks and control characters are rejected. Omitted or `.` means the project folder. |
| `group` | `build`, `test` or `run`. It is shown as a word next to the task. |
| `env` | An object of variable names to string values. Names match `[A-Za-z_][A-Za-z0-9_]*` (at most 255 characters); values are at most 4,096 characters without control or invisible characters, and may be empty. The top-level `env` applies to every task in the file; a task's own `env` wins for the same name. At most 50 variables apply to one task. Values are literal: `$VAR`, `${…}` and `~` are not expanded. |

For example, with a top-level `env` of `{"A": "1", "B": "x"}` and a task `env` of `{"B": "y"}`, the task sees `A=1` and `B=y`. A value of `"$HOME"` arrives as the literal text `$HOME`.

A JSON Schema for editors is published at [`launch-file.schema.json`](../api/launch-file.schema.json).

The file is checked strictly. An unknown field (including `label`), a wrong type, a missing or duplicate `name`, a multi-line command, an absolute or `..` `cwd`, an unknown `group`, an invalid variable, too many tasks or variables, or a file over 64 KB is reported in the Tasks view with the task's name, and none of the file's tasks run. A `launch.json` that is a symbolic link or isn't owned by you is refused too.

When Trellis writes the file (adding a task), it uses a fixed field order (`$schema`, `version`, `env`, `tasks`; in each task `name`, `command`, `cwd`, `group`, `env`), variables sorted by name, two-space indentation and a final newline, so adding a task changes only the lines it adds.

## Review before the first run

`launch.json` is shared through the repository, so anyone who can change it can change what **Run** types. The first time you run a task from a version of the file you haven't trusted, Trellis shows **Review launch.json**: every task in the file with its name, folder, variables and command, verbatim.

- **Trust and Run** trusts this exact version of the file and runs the task you chose. Pressing Return doesn't trust it; you have to click.
- **Cancel** runs nothing.

Trust is remembered per project folder and for the file's exact contents. Changing a single byte asks again, and the sheet tells you the file changed since you last trusted it. The task that runs is always the one from the version you reviewed. In a remote workspace the sheet names the host, and trust given through one host doesn't carry over to another.

Detected tasks don't need a review: Trellis builds them from fixed templates, and the view shows the exact line.

## Trust and safety

- The review sheet shows every task before the first run of each version, and the Tasks view always shows the exact line next to its **Run** button.
- Variable values are typed into the terminal along with the command, so they appear on screen and in your shell history. Don't put secrets in `launch.json`.
- Trellis never logs the typed line, and never saves it anywhere except `launch.json` itself.

## Limits

- **Stop** relies on the terminal's signal characters. A program in raw mode, or one that ignores Ctrl-C and Ctrl-\\, keeps running; close the pane to end it.
- With shell integration off, or in a shell Trellis has no integration scripts for, tasks can be listed and added but not run.
- In a remote workspace, tasks run on the host, but **Add to launch.json** isn't available.
- The view reads `launch.json` when you open it, when you focus another pane, when the pane changes folder and when you click reload. It doesn't watch the file for changes.
- Ctrl-E and Ctrl-U clear a half-typed line only with emacs-style line editing. In vi command mode, or while the shell is waiting for the rest of a multi-line command, finish or cancel what is at the prompt before you click **Run**.
- Right after a project opens a new pane, there's a brief moment between the shell's first prompt and the start of the project's command when **Run** still sees the shell as idle.
