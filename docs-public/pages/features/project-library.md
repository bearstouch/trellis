# Project library

A project is a workspace you define once in Trellis and open whenever you need it, on this Mac or on any saved SSH host. It holds the tabs, splits and panes you want, the folder and command of each pane, and the git repositories the project is made of.

Projects live in Trellis's own settings, not in a repository, so the same definition sets up your laptop, a build server or a fresh VM. A project's build, test and run commands are a separate thing: they live in the repository as [tasks](tasks.md).

## Open the library

Click **Projects** at the bottom of the sidebar, above Hosts and Settings (an icon with the same label when the sidebar is collapsed), or choose **File → Projects…** (<kbd>⌘</kbd><kbd>O</kbd>). You can rebind the shortcut in **Settings → Keyboard**.

The library is a window of its own. The left side is a searchable list of your projects, showing each one's name, how many tabs and repositories it has, and where it was last launched. Search matches names, notes and repository URLs. The right side edits the selected project.

## Create a project

There are three ways to start one:

- **New Project** starts an empty project with one tab and one pane.
- **New from Space…** captures the active space in the sidebar: its tabs, titles, colors, splits and their sizes. The project folder becomes the panes' nearest common folder, and each pane's folder is stored relative to it. If that common folder is `/` or your home folder, Trellis warns you that launching will ask where the project goes. SSH panes and panes running another program become plain shells, again with a warning. Commands are never captured.
- **Import JSON…** reads a project file, such as one written by **Export JSON…** on another Mac. A file with problems is refused and the problems are listed. An imported project is always added as a new one, so importing the same file twice gives you two projects.

Each of these opens the result in the editor, unsaved, so you can look it over before you choose **Save**.

**Export JSON…** writes the selected project as it is saved (not your unsaved edits), without the folders it was launched in, so you can share it or import it elsewhere.

## Edit a project

The editor has the project's name, notes and an optional repository, and an outline of its layout: tabs, splits and panes.

- Select a **tab** to set its title, color, folder and repository.
- Select a **pane** to set its title, folder, what it **Runs** (**Shell** or one of your [coding agents](agents.md)), its command and its repository.
- Select a **split** to set its direction (**Side by side** or **Top and bottom**) and the first pane's share.

**Add Tab**, **Split Right**, **Split Down** and **Remove** change the outline, and **Move Up** and **Move Down** reorder tabs. Splitting a pane puts it and a new pane side by side; removing one side of a split leaves the other in its place. The last tab and the last pane can't be removed.

Every field is checked as you type, with the problem shown next to it, and **Save** stays disabled until everything is valid. **Delete…** removes the project after asking; it removes only the definition, never its folders, repositories or open spaces.

If you close the window, select another project, or capture or import one while you have unsaved changes, Trellis asks whether to save or discard them. If the same project was changed and saved somewhere else in the meantime, your save is refused and Trellis says so, so two edits never silently overwrite each other.

### Edit as JSON

The **Form / JSON** switch shows the project as JSON, in the terminal's font and theme. **Validate** (<kbd>⌥</kbd><kbd>⌘</kbd><kbd>V</kbd>) checks it with the same rules as the form and lists each problem with its tab or pane, and **Save** (<kbd>⌥</kbd><kbd>⌘</kbd><kbd>S</kbd>) stores it. Text that doesn't validate can't be saved or switched back to the form. Unknown fields are errors.

## What a project contains

| Element | Rules |
| --- | --- |
| Project | `name` (1–200 characters), optional `notes`, an optional `repository` (the project folder itself is a checkout of it) and 1–50 `tabs`. |
| Tab | `title` (1–200 characters), optional `color` (`red`, `orange`, `yellow`, `green`, `blue`, `purple`, `gray`), an optional `directory` and `repository`, and a `root` node. Panes in the tab without a `directory` start in the tab's folder. |
| Pane | Optional `title`, `directory`, `command`, `agent` and `repository`. A pane's `repository` makes its `directory` (required then) a checkout. A pane has either an `agent` or a `command`, not both. |
| Split | `axis` `x` (side by side) or `y` (top and bottom), `ratio` 0.1–0.9 (the first child's share) and exactly two children. |
| `directory` | Relative to the project folder you choose at launch. Omitted or `.` means the project folder. Absolute paths, `~`, `..` segments, `$`, backticks, quotes and backslashes are rejected. |
| `command` | One line of at most 4,096 characters, typed into the pane's login shell after its first prompt. Control, line-separator and invisible characters are rejected. |
| `agent` | An agent ID from **Settings → Agents**, such as `trellis-claude-code`, `trellis-pi` or `trellis-codex`: lower-case letters, digits and `-`. The pane opens as that agent instead of a shell. |
| `repository` | `url`: `https://…`, `ssh://…` or `user@host:path`, at most 2,048 characters of letters, digits and `-._~:/@%+=,`, never starting with `-`. Other transports (`file://`, `ext::`, `http://`) are rejected, and so is a URL with a password in it. Optional `branch`, following git's branch-name rules. Two repositories may use the same folder only with the same `url` and `branch`. |

A project has at most 50 tabs, 100 panes and 16 levels of nested splits. In JSON the structure is:

```json
{
  "name": "Shop",
  "notes": "Storefront and API",
  "repository": { "url": "git@github.com:acme/shop.git" },
  "tabs": [
    {
      "title": "API",
      "color": "blue",
      "directory": "api",
      "root": {
        "type": "split",
        "axis": "x",
        "ratio": 0.5,
        "children": [
          { "type": "pane", "title": "server", "command": "make dev" },
          { "type": "pane", "agent": "trellis-claude-code" }
        ]
      }
    }
  ]
}
```

The editor's JSON view always shows the exact field order Trellis uses, so the easiest way to get a valid file is to build the project in the form and switch to **JSON**.

## Launch a project

Select a project and choose **Launch…**, or use **Launch Project…** in the [command palette](command-palette.md). Save the project first; an unsaved one can't be launched.

1. Choose the **Target**: **This Mac** or one of your saved [SSH hosts](ssh-hosts.md).
2. Choose the project folder there: an absolute path on this Mac, or a path inside your home folder on a host. Both are filled in from your last launch to that target, or else `~/<name>`, with the name in lower case and spaces turned into `-`.
3. Trellis checks the target and shows what will happen: whether the folder exists or will be created, each repository that is already cloned (used as it is), each one that will be cloned, each folder that exists but isn't a checkout (a warning; Trellis never touches it), and the tabs, panes and commands that will open. Checking a host connects to it first, so a host-key or password prompt may appear in its console. If you change the folder, choose **Check** again.
4. Choose **Open**, or **Set Up & Open** when something is missing. **Cancel** changes nothing anywhere.

### Setting up what's missing

When the folder or a repository is missing, **Set Up & Open** runs a terminal on the target that creates the folder and clones each missing repository, using that machine's own git and credentials. You see git's output and answer its questions (host keys, passphrases, passwords) right there; Trellis never stores or types credentials. Nothing runs before you choose **Set Up & Open**.

When every step succeeds, the space opens. If a step fails, the output stays on screen with three choices:

- **Retry** runs the setup again, skipping what is already in place.
- **Open Anyway** opens the space; panes whose folder is missing fail to start.
- **Cancel** stops. Anything already cloned stays.

If the project folder already has files and the project has a repository, Trellis initializes the repository in place (`git init`, the remote, a fetch and a checkout of the branch or the remote's default). Git refuses to overwrite a file that is already there.

### The project's space

The space is named after the project. On a host it works like a [remote workspace](remote-workspaces.md): every pane is a shell on that host. Each pane's command is typed once, at its new shell's first prompt, and the shell stays open when the command ends. Panes set to an agent open that agent instead, with its icon and live state on the tab.

Launching the same project on the same target and folder again selects its space and brings it up to date: it adds new tabs and panes and applies changed titles, colors and split sizes, but it removes nothing, restarts nothing and runs no command again. The same project on another target or folder opens another space.

!!! note "New in 1.2 beta"
    A space opened from a project remembers it and shows a folder symbol in the sidebar. Tabs the project doesn't define, such as ones you add, duplicate or open for a host or an agent, are temporary: their titles are in italics and VoiceOver reads "temporary tab". Launching the project again keeps them, and they never change the project.

## Git status

For a shell on this Mac or in a remote workspace whose folder is inside a git repository, Trellis keeps track of the branch (or the short commit when detached), the number of uncommitted changes, and how far it is ahead of and behind its upstream. The [Changes](changes.md) icon in the dock shows the focused pane's count as a badge.

Status is checked each time the shell shows its prompt, after a `cd` or a command, never on a timer. It needs [shell integration](shell-integration.md). SSH panes and folders outside a repository show nothing.

Trellis reads status without running anything the repository configures: no hooks, no fsmonitor, no filters and no fetch. On a Mac without the developer tools, it skips `/usr/bin/git` rather than prompting you to install them. File names are never shown or stored by this check.

## Back up or move your projects

**File → Export Projects & Hosts…** writes your project library and saved hosts to one file; **File → Import Projects & Hosts…** reads it back on any Mac. The export leaves out the folders each project was launched in, and never contains output, passwords, keys or tokens.

The import preview counts the projects and lists any named like one you already have. **Import** adds them as new projects, never over yours; a name you already use gets " (imported)". If any project in the file is invalid, nothing is imported. Exports from earlier versions still import their projects and hosts.

!!! note "New in 1.2 beta"
    Export and import now carry projects and hosts. They replace **Export Windows & Hosts**; open spaces are no longer exported.

## Trust and safety

- You write a project's commands and repositories yourself, in Trellis, so launching runs them without a further review. An imported project opens in the editor, unsaved, so you see its commands and repositories before you save or launch it.
- Commands run in the target's login shell with your permissions there, like anything you type. They are never logged or saved with the workspace, and a restored workspace never runs them again.
- Git runs with the target's own configuration and credentials. Trellis never stores, reads or types a token, key or password for it.
- Setup only creates folders and clones into folders that don't exist yet, or initializes the project folder in place. It never deletes, resets or overwrites files. If initializing in place fails or you cancel it, Trellis removes only the `.git` it just created, so the folder is as it was.

## Limits

- The library is stored in `projects.json` in Trellis's state folder, readable only by you. If the file can't be read, or was written by a newer Trellis, the library opens read-only with **Reset Project Library**, which moves the file aside; Trellis never overwrites it.
- Once a project has an agent pane, an older Trellis that doesn't know about agent panes opens the library read-only rather than dropping the agent.
- Without shell integration, a pane's command is typed as soon as the shell starts rather than at its first prompt.
- A remote host whose Trellis helper is too old shows no git status.
