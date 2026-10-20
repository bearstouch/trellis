# Workspace files

A workspace file is a project's Trellis layout, checked into its repository as `.trellis/workspace.json` so it can be reviewed like any other source file. It describes one sidebar window: its tabs (titles and color labels), each tab's split tree, pane titles, the folder each pane starts in, and an optional command to type into each new shell.

Unlike [API layouts](../api/layouts.md), which never carry commands, a workspace file can run commands. They run only after you have reviewed and trusted that exact version of the file.

All requirements here are P1.

- Schema: [`workspace-file.schema.json`](../api/workspace-file.schema.json) (JSON Schema 2020-12)
- Example: this repository's own [`.trellis/workspace.json`](https://github.com/bearstouch/trellis/blob/master/.trellis/workspace.json). The tests parse it.

```json
{
  "version": 1,
  "name": "Trellis",
  "tabs": [
    {
      "title": "Develop",
      "color": "green",
      "root": {
        "type": "split",
        "axis": "x",
        "ratio": 0.6,
        "children": [
          {"type": "pane", "title": "Shell"},
          {"type": "pane", "title": "Status", "command": "git status --short"}
        ]
      }
    },
    {"title": "Docs", "root": {"type": "pane", "directory": "docs"}}
  ]
}
```

## Format

| Element | Rules |
| --- | --- |
| Document | `version` (must be `1`), `name` (the window name, 1–200 characters) and 1–50 `tabs`. An optional `$schema` string is ignored. Any other field is an error. Files are limited to 256 KB. |
| `tab` | `title` (1–200 characters) and `root`, with optional `color` (`red`, `orange`, `yellow`, `green`, `blue`, `purple`, `gray`) and `key` |
| Pane | `{type: "pane"}` with optional `title`, `directory`, `command` and `key` |
| Split | `{type: "split", axis: x\|y, children: [node, node]}` with optional `ratio` (0.1–0.9, default 0.5) and `key`. `ratio` is the first child's share. |
| `directory` | Relative to the project folder, the folder that holds `.trellis`. Omitted or `.` means the project folder. Absolute paths, `~`, `..` segments, `$` and backticks are rejected, so a file can only name folders inside its project. A folder that doesn't exist yet is a warning. |
| `command` | One line of at most 4,096 characters, typed into the pane's login shell followed by Return. NUL, CR, LF, other control characters, line and paragraph separators, and invisible characters (bidi overrides, zero-width characters, fillers, variation selectors and other default-ignorable code points) are rejected, so the review shows exactly what runs. The text is parsed by the shell, deliberately. |
| Keys | Optional. Missing keys are derived from position (`t1`, `t1-0`, `t1-12`). They match the pattern and limits of [layout keys](../api/layouts.md#document-rules), and `trellis-window` is reserved. Add keys to tabs and panes if reordering them should keep matching the same open panes. |

Titles and the name also reject control characters, line separators and invisible formatting characters. Layout limits are the same as for API layouts: at most 100 panes and 16 levels of nesting. Saved hosts and custom processes can't be referenced, since their IDs belong to one Mac.

## Requirements

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| FR-WF01 | Parse workspace files strictly and atomically. | An unknown field, a wrong type, an absolute or `..` directory, a multi-line command, a bidi override in a command, an unknown color or a file over 256 KB is reported with the offending key, and nothing changes. A valid file parses to the same layout every time. |
| FR-WF02 | Offer a project's workspace file on the tab whose shell is inside it. With shell integration, when a local shell reports a directory at or below a folder with `.trellis/workspace.json`, hovering that tab shows a **Load Workspace** button. A selected tab shows its glyph without hovering. The tab's context menu has **Load Workspace “Name”** and **Don’t Offer for This Folder**, and VoiceOver gets a **Load Workspace** action, so the offer never depends on the pointer. | `cd` into this repository's `Sources` folder, hover the tab, and **Load Workspace** appears, with a tooltip naming the project and file path. `cd /` and it goes away. The search stops below your home folder and never treats home or `/` as a project. Tabs in the project's own window, SSH panes, files you don't own or that are symbolic links, and folders you chose **Don’t Offer** for show nothing. Detection never reads anything but the file itself, and never runs anything. |
| FR-WF03 | Run a file's commands only after its exact bytes are trusted. Trust is recorded per canonical project folder and SHA-256 digest. Opening a file with commands that isn't trusted shows a review sheet listing every tab, pane, folder and command verbatim, with **Cancel**, **Open Without Commands** and **Trust and Open**. | The first open of a file with commands shows the sheet; Return doesn't trust it. **Open Without Commands** opens the layout with plain shells and types nothing. **Trust and Open** runs the commands, and the next open of the same file skips the sheet. Changing one byte shows the sheet again, saying the file changed; moving the project shows it again too. The trust list (`workspace-trust.json`, 0600, in the state directory) holds one digest per folder. If it is unreadable or from a newer version, nothing is trusted and it is never overwritten. A file without commands opens without the sheet. |
| FR-WF04 | Open a workspace file as the project's own sidebar window, and reconcile that window when the file is opened again. | The first open creates one window named after `name`, with the file's tabs, labels, splits, pane titles and folders, selects it and starts its shells. Opening again selects the same window: changed titles, labels and ratios apply, new tabs and panes are added and started, nothing is removed, no running pane is restarted, and no command runs again. Running panes keep their folder; stopped ones take the file's folder. A conflict or a stale workspace changes nothing and says why. The file is read once per open, and what was reviewed is what is applied. |
| FR-WF05 | Type each command into its new pane's shell once, when the shell is ready. | With shell integration, a command waits for the shell's first prompt, so slow startup files can't swallow it. Without integration (turned off, or another shell), it is written as soon as the shell starts, and the terminal holds it until the shell reads it. When the command exits or is interrupted, the shell stays, with the command in its history. A pane that fails to start, exits or restarts drops its queued command. Commands are never logged, persisted with the workspace or replayed on restore. |
| FR-WF06 | Save a window as a workspace file. **Save as Workspace File…** in the window's sidebar menu, and **File → Save Window as Workspace File…**, ask for the project folder, then show every pane with an editable command before writing `<folder>/.trellis/workspace.json`. | The folder picker starts at the active pane's project, or its directory. The sheet prefills each pane's command from the file it was opened from, or from the existing file's same key. Folders inside the project are written relative; a pane outside it is listed with a warning and saved without a folder. Saving twice writes identical bytes, in a fixed field order with two-space indentation. A window the file format can't hold (more than 50 tabs, 100 panes or 16 levels, or keys that collide) is refused before anything is written. Replacing an existing file says so first. The written version is trusted, and the window becomes the project's window. If the window changes while the sheet is open, or the folder can't be written, nothing is written or changed. **File → Open Workspace File…** opens a project folder, its `.trellis` folder or the file itself. |

## Trust and safety

- Opening a repository never runs anything by itself. Detection only reads `.trellis/workspace.json`, and only to show its name.
- The file must be a regular file you own, not a symbolic link.
- Trust covers one version of one file in one folder. Pulling a change to the file, or cloning the repository somewhere else, asks again.
- Commands run in your login shell with your permissions, like anything you type. Trust only files you've read.
- Pane commands typed by a workspace file are not [`session.execute`](../api/methods.md) calls, and no automation grant is involved. Automation can't open workspace files, and API layouts still can't carry commands.
