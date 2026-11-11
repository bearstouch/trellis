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
| `project` | Present for a project-bound space (FR-W08) whose project is in the grant's project scope. `name` and `target` need **project.read**; `folder` also needs **session.execute**. `target` is `{"kind": "local"}` or `{"kind": "host", "hostId"}` (the host's ID as for machines); `folder` is the folder the space was launched in, as `project.launch` takes it (absolute on this Mac, relative to home on a host), omitted when Trellis can't tell. A space whose project was deleted keeps `id` and gets `missing: true`, once the project library has loaded: a library that hasn't loaded (or couldn't be read) calls nothing missing. |
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
  "attention": {"needsInput": "password", "progress": {"state": "indeterminate"}},
  "agent": {"agentId": "trellis-claude-code", "state": "working"},
  "task": {"taskId": "file:build", "phase": "running"}
}
```

| Field | Notes |
| --- | --- |
| `revision` | Changes with the pane's record, its place or focus in the tab, and maximizing; not with `shell`, `attention` or `agent`. |
| `title` | A pane title set by a layout or project; omitted otherwise. |
| `machine` | From the session's launch: `local`, `ssh` (an SSH pane) or `remote`. |
| `folder` **(session.execute)** | The current directory from shell integration, else the launch directory. |
| `shell` | Shell-integration state (FR-SI01–SI09). `integration` is `authenticated`, `remote` (marks from a remote shell, display-only) or `none`. Command text is never exposed. |
| `attention` | `needsInput` (`password`, or `attention`: the program rang the bell or posted a notification while the pane wasn't in view, FR-T06), `progress` (OSC 9;4, cleared after 15 s). |
| `agent` | Present while the pane runs an agent: a summary of its [agent run](#agent-run). |
| `task` | Present while a [task run](#task-run) is active or just finished in this pane: `taskId` and `phase`. |

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
| `kept` | The session runs in the broker and survives quitting Trellis (FR-R03). `false` for sessions started outside it, and for sessions that aren't running. |
| `launch` | One of the kinds below. Fields marked **(execute)** need **session.execute**; host IDs need **host.read**. A launch is never returned with environment values. |

| `launch.kind` | Fields |
| --- | --- |
| `shell` | `directory` (execute). A login shell resolved to its program is still reported as `shell`. |
| `process` | `executable`, `arguments`, `directory` (execute) |
| `ssh` | `hostId` |
| `remoteShell` | `hostId`, `directory` (execute) |
| `agent` | `agentId`, `machine`, `directory` (execute), `resume` (only in `agent.start` parameters) |

## Agent definition

```json
{
  "id": "trellis-claude-code", "name": "Claude Code", "builtIn": true, "revision": 0,
  "integration": "claude-hooks", "resumable": true, "executable": "claude",
  "install": {"darwin": {"command": "curl -fsSL https://claude.ai/install.sh | bash", "requires": ["curl", "bash"]}, "linux": {"command": "…", "requires": ["curl", "bash"]}},
  "availability": [{"machine": {"kind": "local"}, "status": "installed"}, {"machine": {"kind": "remote", "hostId": "…"}, "status": "missing", "installable": true}]
}
```

| Field | Notes |
| --- | --- |
| `revision` | Moves when a reload of the agent catalog changes the definition (FR-AG02); a definition unchanged since launch is at 0. Runtime only, like pane revisions. |
| `integration` | `claude-hooks`, `codex-notify`, `pi-extension` or `none` (FR-AG). |
| `resumable` | The definition has resume arguments, so `resume` continues the last conversation (FR-AG06). |
| `executable`, `install` **(session.execute)** | What runs: the program, and the installer per platform (`darwin`, `linux`) with the programs it `requires`. |
| `availability` | This Mac, then each remote workspace host the grant can read (host.read and the host in scope) that has an open space, a helper check or an agent found missing. `status`: `checking`, `installed` or `missing` from this Mac's login PATH check, `unknown` before any check; on a host only `missing` (a launch there exited 127) or `unknown`, since Trellis doesn't check a host ahead (FR-AG12), and `unsupported` when the host has no helper for its system. `installable` (omitted when installed): the definition has an installer for the machine's platform (a host's as its helper reported it, else Linux) whose requirements this Mac's PATH has, so `agent.install` can run it. |

Definitions are readable whatever the grant's agent scope; that scope limits starting, restarting and installing.

## Agent run

An agent running in a pane, whether started as an agent pane or typed in a shell and recognised (FR-AG15). Its ID is the session ID.

```json
{
  "sessionId": "…", "paneId": "…", "spaceId": "…", "agentId": "trellis-claude-code",
  "origin": "managed", "state": "needsInput", "since": "…", "unseen": false,
  "settings": {"model": "claude-opus-5-5", "effort": "high"}
}
```

| Field | Notes |
| --- | --- |
| `origin` | `managed` (an agent pane) or `detected` (typed in a shell). Only managed runs can be restarted or resumed through the API. A typed agent is a run once its own hooks have spoken (FR-AG18), as in the app's Running list. |
| `state` | `ready`, `working`, `needsInput`, `done`, `error` (FR-AG). Agents without a hook integration only reach `ready`, `working` (from output) and `done`. A run lasts while its session runs: an agent that ended has none. |
| `since` | When the run entered its current state. |
| `unseen` | A `done` the user hasn't looked at (the tab's Done badge, FR-AG10). |
| `settings` | Model ID and reasoning effort as the agent reported them (FR-AG19), as in `agent.settings` events; omitted until reported. Untrusted text. |

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
| `remote` | Present once the host has been used as a remote workspace (a helper check or a link); `remote.*` results always carry it. `helper`: `current`, `outdated`, `missing`, `unsupported`, or `unknown` before any check; `checkedAt` is when it was last probed (it is never inferred, FR-RW17). `link` (omitted until this app run connected or tried to): `state` is `connecting`, `connected`, `reconnecting` (with `attempt`, `nextAttemptAt`), `offline`, `needsInput` (with `reason`), `disconnected` (with `reason`). The link isn't a session state: sessions stay `running` while it is down (FR-RW). |

### Remote link reasons

`reason` is a stable code, never the words the app shows (those are in the user's language). It appears in `Host.remote.link`, `remote.link` events and the `details.reason` of `REMOTE_DISCONNECTED`, `INVALID_STATE` and `CONFIRMATION_REQUIRED` from remote methods. Clients must accept codes added later. **Retried on its own** says whether automatic reconnects (FR-RW07) keep trying a workspace link that failed this way; a `needsInput` reason waits for `remote.reconnect` with `interactive: true` or **Reconnect…** in the app.

| `reason` | Link state | Meaning | Retried on its own |
| --- | --- | --- | --- |
| `hostUnreachable` | `disconnected` | Refused, timed out, no route, name not resolved | yes (`reconnecting`) |
| `lost` | `disconnected` | An established link went quiet or closed | yes |
| `sshExited` | `disconnected` | ssh ended before the helper answered; the app's connection console shows why | yes |
| `sshUnavailable` | `disconnected` | ssh couldn't be started on this Mac | yes |
| `authFailed` | `needsInput` | The host refused the keys offered (or too many were tried) | no |
| `needsPassword` | `needsInput` | ssh needs a password or keyboard-interactive answer | no |
| `needsPassphrase` | `needsInput` | ssh needs a key's passphrase | no |
| `hostKeyChanged` | `needsInput` | The host's key differs from known_hosts | no |
| `hostKeyUnverified` | `needsInput` | The host's key isn't known or couldn't be verified | no |
| `needsInput` | `needsInput` | ssh needs the person for something else | no |
| `helperMissing` | `disconnected` | No helper on the host, and installing it wasn't allowed (the helperInstall rule) or was declined | no |
| `helperUnsupported` | `disconnected` | No helper exists for the host's system or architecture | no |
| `helperUnavailable` | `disconnected` | This build doesn't include the helper for that platform | no |
| `noChecksumTool` | `disconnected` | The host has no sha256sum, shasum or openssl to verify an upload | no |
| `helperIncompatible` | `disconnected` | The helper there speaks a protocol this build can't use | no |
| `installFailed` | `disconnected` | Installing failed on the host (digest mismatch, no gzip, `~/.trellis` not writable); nothing was installed | no |
| `hostRefused` | `disconnected` | The host's bootstrap refused the request | no |
| `cancelled` | `disconnected` | The attempt was cancelled in the app | no |
| `closed` | `disconnected` | Trellis closed the link (quit, Close All Workspaces) | no |
| `hostMissing` | `disconnected` | The saved host was deleted | no |
| `unavailable` | — | Remote workspaces aren't available in this app instance (error details only) | no |
| `helperTooOldForAgents` | — | The connected helper predates agents in remote workspaces (error details only); update it | no |
| `unknown` | `disconnected` | Nothing was recorded | no |

## Project

```json
{
  "id": "…", "name": "Lotus", "revision": 9, "notes": "…",
  "repository": {"url": "git@github.com:me/lotus.git"},
  "tabs": [{"key": "t1", "title": "Editor", "color": "blue", "directory": "app",
            "layout": {"type": "split", "axis": "x", "ratio": 0.5, "children": [
              {"type": "pane", "key": "t1-1", "title": "Server", "command": "make dev"},
              {"type": "pane", "key": "t1-2", "agent": "trellis-claude-code"}]}}],
  "lastFolders": [{"target": {"kind": "local"}, "folder": "/Users/me/src/lotus"}],
  "spaces": ["…"]
}
```

The definition is the project library entry (FR-PL01–PL10). `revision` moves when the definition is saved, not when it is launched. Tabs and panes carry the layout `key` a launch gives them (`t1`, `t1-0` for a tab's only pane, then one digit per level of split), the same keys `project.check`'s plan and `project.launch`'s `launches` use. Pane entries can hold `command` and `agent`; `command`, `repository` and folders (`directory`, `lastFolders`) need **session.execute** to read, because they say what runs where; a pane's `agent` and titles don't. `lastFolders` lists the folder last launched per target (absolute on this Mac, relative to home on a host). `spaces` lists open spaces bound to it, within scope.

## Task

Tasks belong to a pane's project folder: `.trellis/launch.json` plus detected tasks (FR-TK).

```json
{"id": "file:build", "name": "build", "source": "file", "group": "build", "trusted": true, "command": "swift build", "cwd": "app", "env": ["CI"]}
```

`id` is `file:<name>` for a `launch.json` task and `detected:<name>` for a detected one. `source` is `file`, `npm`, `make`, `cmake`, `swift`, `python` or `cargo`. `trusted` is false for `launch.json` tasks whose exact file version hasn't been approved in the app; detected tasks are always true (fixed templates). `command`, `cwd` and `env` keys (never values) need **session.execute**; commands from repository files are untrusted text.

## Task run

```json
{"paneId": "…", "taskId": "file:build", "name": "build", "phase": "finished", "exitCode": 0, "durationMs": 41230, "stopRequested": false}
```

`phase`: `submitted`, `running`, `finished`. `submittedAt` is present while submitted, `startedAt` while running, `exitCode` (when the shell reported one) and `durationMs` once finished. A run lives in its pane until the pane runs something else; it is runtime state and isn't saved. It is the app's run: a task started in the Tasks view or through `task.run` is the same record.
