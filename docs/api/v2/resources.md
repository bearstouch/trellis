# Resources (draft)

!!! warning "Draft contract — not implemented"
    Part of the proposed [protocol 2](index.md).

Fields marked **(cap)** appear only when the grant holds that capability; without it they are omitted, never blanked. Out-of-scope resources don't appear at all (`NOT_FOUND` on direct access).

```
workspace
 └─ space ──(machine: local | host)──(project?)
     └─ tab (standard | project | temporary)
         └─ layout: split tree
             └─ pane ──(machine: local | ssh | remote)
                 └─ session ──(launch: shell | process | ssh | remoteShell | agent)
                     └─ agent run? ── agent definition
host ── remote workspace link, helper
project ── launches → space
task (per pane folder) ── task run (per pane)
```

## Machine

Where something runs. Used by spaces, panes and agent availability.

```json
{"kind": "local"}
{"kind": "ssh", "hostId": "…"}          // a pane connected to a saved host with ssh
{"kind": "remote", "hostId": "…"}       // a remote workspace: the broker runs on the host
```

`hostId` needs **host.read** and the host in scope; otherwise only `kind` is shown.

## Space

```json
{
  "id": "a5329e1d-…", "name": "Lotus", "revision": 12,
  "machine": {"kind": "local"},
  "project": {"id": "…", "name": "Lotus", "target": {"kind": "local"}, "folder": "/Users/me/src/lotus"},
  "tabIds": ["…"], "activeTabId": "…", "active": true,
  "attention": {"needsInput": 1, "activity": "output"}
}
```

| Field | Notes |
| --- | --- |
| `machine` | `local`, or `remote` for a [remote workspace](../../features/remote-workspaces.md) (FR-RW01). A space never has kind `ssh`. |
| `project` | Present for a project-bound space (FR-W08). `name` and `target` need **project.read**; `folder` also needs **session.execute**. A space whose project was deleted keeps `id` and gets `missing: true`. |
| `attention` | `needsInput`: panes waiting for input in this space. `activity`: `output`, `exit` or omitted, for inactive spaces (the sidebar dot). |

## Tab

```json
{
  "id": "…", "spaceId": "…", "revision": 4,
  "role": "project", "projectKey": "t2",
  "title": "claude · lotus", "customTitle": false, "color": "blue",
  "activePaneId": "…", "paneIds": ["…"], "maximizedPaneId": "…",
  "status": {"busy": true, "progress": {"state": "normal", "percent": 40}, "needsInput": "attention", "agent": "needsInput", "linkDown": false},
  "layout": {"type": "split", "id": "…", "axis": "x", "ratio": 0.5, "children": [{"type": "pane", "id": "…"}, {"type": "pane", "id": "…"}]}
}
```

| Field | Notes |
| --- | --- |
| `role` | `standard` in a space without a project; in a project space, `project` (defined by the project, has `projectKey`) or `temporary` (FR-W08). |
| `title`, `customTitle` | `title` is what the tab shows. `customTitle: false` means it is automatic (program, `<agent> · <folder>` or folder, FR-SI05, FR-AG15); renaming sets it true, and `tab.update {title: null}` returns to automatic. Automatic titles come from programs and are untrusted. |
| `status` | The tab's live aggregate, as drawn in the tab bar: `busy` (FR-T05), `progress` (FR-T09), `needsInput` `password`/`attention` (FR-T06), `agent` badge state (FR-AG10), `linkDown` (FR-RW07). Omitted members are false or none. |
| `layout` | Only in `tab.get` and `tab.create`/`pane.split` results, or with `include: ["layout"]` on `tab.list`. |

## Pane

Panes are first-class in v2.

```json
{
  "id": "…", "tabId": "…", "spaceId": "…", "revision": 3,
  "title": "server", "machine": {"kind": "remote", "hostId": "…"},
  "sessionId": "…", "focused": true, "maximized": false,
  "folder": "/srv/app",
  "shell": {"integration": "authenticated", "commandRunning": true, "commandStartedAt": "…", "lastExitCode": 0, "lastDurationMs": 5230},
  "attention": {"needsInput": "password", "progress": {"state": "indeterminate"}, "bell": false},
  "agent": {"agentId": "trellis-claude-code", "state": "working"},
  "task": {"taskId": "file:build", "phase": "running"}
}
```

| Field | Notes |
| --- | --- |
| `title` | A pane title set by a layout or project; omitted otherwise. |
| `machine` | From the session's launch: `local`, `ssh` (an SSH pane) or `remote`. |
| `folder` **(session.execute)** | The current directory from shell integration, else the launch directory. |
| `shell` | Shell-integration state (FR-SI01–SI09). `integration` is `authenticated`, `remote` (marks from a remote shell, display-only) or `none`. Command text is never exposed. |
| `attention` | `needsInput` (`password` or `attention`), `progress` (OSC 9;4, cleared after 15 s), `bell`. |
| `agent` | Present while the pane runs an agent: a summary of its [agent run](#agent-run). |
| `task` | Present while a [task run](#task-run) is active or just finished in this pane. |

## Session

```json
{
  "id": "…", "paneId": "…", "revision": 7,
  "state": "running", "kept": true,
  "launch": {"kind": "agent", "agentId": "trellis-claude-code", "machine": {"kind": "local"}, "directory": "/Users/me/src/lotus"},
  "createdAt": "…", "startedAt": "…", "endedAt": "…", "exitCode": 0, "failureMessage": "…"
}
```

| Field | Notes |
| --- | --- |
| `state` | `stopped → starting → running → exited\|failed`; `running → closing → exited`. Restart creates a new session ID in the same pane. |
| `kept` | The session runs in the broker and survives quitting Trellis (FR-R03). `false` for sessions started outside it. |
| `launch` | One of the kinds below. Fields marked **(execute)** need **session.execute**; host IDs need **host.read**. A launch is never returned with environment values. |

| `launch.kind` | Fields |
| --- | --- |
| `shell` | `directory` (execute) |
| `process` | `executable`, `arguments`, `directory` (execute) |
| `ssh` | `hostId` |
| `remoteShell` | `hostId`, `directory` (execute) |
| `agent` | `agentId`, `machine`, `directory` (execute), `resume` (only in `agent.start` parameters) |

## Agent definition

```json
{
  "id": "trellis-claude-code", "name": "Claude Code", "builtIn": true, "revision": 1,
  "integration": "claude-hooks", "executable": "claude",
  "availability": [{"machine": {"kind": "local"}, "status": "installed"}, {"machine": {"kind": "remote", "hostId": "…"}, "status": "missing", "installable": true}]
}
```

`integration` is `claude-hooks`, `codex-notify`, `pi-extension` or `none` (FR-AG). `availability` lists the local machine and every remote host in scope: `checking`, `installed`, `missing` or `unsupported`. `executable` and install commands need **session.execute**.

## Agent run

An agent running in a pane, whether started as an agent pane or typed in a shell and recognised (FR-AG15). Its ID is the session ID.

```json
{
  "sessionId": "…", "paneId": "…", "agentId": "trellis-claude-code",
  "origin": "managed", "state": "needsInput", "since": "…", "unseen": true,
  "settings": {"model": "Opus 5.5", "effort": "high"}
}
```

| Field | Notes |
| --- | --- |
| `origin` | `managed` (an agent pane) or `detected` (typed in a shell). Only managed runs can be restarted or resumed through the API. |
| `state` | `ready`, `working`, `needsInput`, `done`, `error` (FR-AG). Agents without a hook integration only reach `ready`, `working` (from output) and `done`. |
| `settings` | Model and reasoning effort as the agent reported them (FR-AG19). Untrusted text. |

## Host

```json
{
  "id": "…", "name": "build-box", "destination": "build", "user": "ci", "port": 22, "identityFile": "~/.ssh/id_ed25519",
  "tags": ["work"], "revision": 5, "connectionRevision": 2,
  "password": {"saved": true, "requiresUserPresence": true},
  "remote": {"helper": "current", "checkedAt": "…", "autoInstall": true, "link": {"state": "connected"}}
}
```

| Field | Notes |
| --- | --- |
| `password` | Whether a password is saved for askpass (FR-H09). The password never leaves the Keychain. |
| `remote` | Present once the host has been used as a remote workspace. `helper`: `current`, `outdated`, `missing`, `unsupported`. `link.state`: `connecting`, `connected`, `reconnecting` (with `attempt`, `nextAttemptAt`), `offline`, `needsInput` (with `reason`), `disconnected` (with `reason`). The link isn't a session state: sessions stay `running` while it is down (FR-RW). |

## Project

```json
{
  "id": "…", "name": "Lotus", "revision": 9, "notes": "…",
  "repository": {"url": "git@github.com:me/lotus.git"},
  "tabs": [{"key": "t1", "title": "Editor", "color": "blue", "directory": "app", "layout": {…}}],
  "lastFolders": [{"target": {"kind": "local"}, "folder": "/Users/me/src/lotus"}],
  "spaces": ["…"]
}
```

The definition is the project library entry (FR-PL01–PL10). Pane entries can hold `command` and `agent`; `command`, `repository` and folders need **session.execute** to read, because they say what runs where. `spaces` lists open spaces bound to it, within scope.

## Task

Tasks belong to a pane's project folder: `.trellis/launch.json` plus detected tasks (FR-TK).

```json
{"id": "file:build", "name": "build", "source": "file", "group": "build", "trusted": true, "command": "swift build"}
```

`source` is `file`, `npm`, `make`, `cmake`, `swift`, `python` or `cargo`. `trusted` is false for `launch.json` tasks not yet approved in the app. `command`, `cwd` and `env` keys (never values) need **session.execute**; commands from repository files are untrusted text.

## Task run

```json
{"paneId": "…", "taskId": "file:build", "name": "build", "phase": "finished", "submittedAt": "…", "startedAt": "…", "exitCode": 0, "durationMs": 41230, "stopRequested": false}
```

`phase`: `submitted`, `running`, `finished`. A run lives in its pane until the pane runs something else; it is runtime state and isn't saved.
