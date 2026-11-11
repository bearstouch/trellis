# Methods (draft)

!!! warning "Draft contract — not implemented"
    Part of the proposed [protocol 2](index.md).

Every method follows the [conventions](index.md#conventions-api2-02). In the tables, **Caps** are required [capabilities](permissions.md); `+x if y` is a conditional capability. Every `id`-addressed method answers `NOT_FOUND` for resources outside the grant's scope. Unless stated otherwise, mutating methods take `expectedRevision` and `idempotencyKey`.

## System and workspace

| Method | Params | Result | Caps |
| --- | --- | --- | --- |
| `system.info` | — | `appVersion`, `protocolVersion`, `instanceId`, `limits` | none |
| `grant.get` | — | `grant` (the caller's own [grant view](permissions.md#grant-view)) | none |
| `workspace.get` | `include?: ["tabs","panes","sessions","agents","layout"]` | Everything in scope in one call: `revision`, `activeSpaceId`, `spaces`, and the included collections | workspace.read |
| `workspace.save` | — | `savedAt` | workspace.write |

`workspace.get` is the starting point for agents: one call instead of `space.list` + N × `tab.get`. It is bounded by the 1 MiB frame; `LIMIT_EXCEEDED` tells the client to page with the list methods.

## Spaces

| Method | Params | Result | Caps |
| --- | --- | --- | --- |
| `space.list` | `limit?`, `cursor?` | `spaces`, `revision` (workspace) | workspace.read |
| `space.get` | `id` | `space` | workspace.read |
| `space.create` | `name`, `start?` | `space`, `tab`, `panes` | workspace.write (+session.start if `start`) |
| `space.update` | `id`, `name` | `space` | workspace.write |
| `space.reorder` | `ids` | `spaces`, `revision` | workspace.write, all-spaces |
| `space.focus` | `id` | `space` | workspace.write |
| `space.close` | `id`, `allowRunning?`, `force?` | `deleted` | workspace.write (+session.close if running) |

Remote and project spaces are created by [`remote.open`](#remote-workspaces) and [`project.launch`](#projects). A grant whose space scope is `created` can see and change only the spaces it created.

## Tabs

| Method | Params | Result | Caps |
| --- | --- | --- | --- |
| `tab.list` | `spaceId`, `include?: ["layout"]` | `tabs`, `revision` (space) | workspace.read |
| `tab.get` | `id` | `tab` with `layout` | workspace.read |
| `tab.create` | `spaceId`, `title?`, `color?`, `start?` | `tab`, `panes` | workspace.write (+session.start) |
| `tab.update` | `id`, `title?` (null → automatic), `color?` (null clears) | `tab` | workspace.write |
| `tab.duplicate` | `id`, `start?` | `tab`, `panes` | workspace.write (+session.start) |
| `tab.reorder` | `spaceId`, `ids` | `tabs`, `revision` (space) | workspace.write |
| `tab.focus` | `id` | `tab` | workspace.write |
| `tab.close` | `id`, `allowRunning?`, `force?` | `deleted` | workspace.write (+session.close) |

In a project space, `tab.create` makes a temporary tab (FR-W08); project tabs come from the project.

## Panes

| Method | Params | Result | Caps |
| --- | --- | --- | --- |
| `pane.list` | `tabId` or `spaceId` | `panes`, `revision` | workspace.read |
| `pane.get` | `id` | `pane` | workspace.read |
| `pane.split` | `id`, `axis` `x`/`y`, `ratio?`, `start?` | `pane` (new), `tab` | workspace.write (+session.start) |
| `pane.resize` | `branchId`, `ratio` | `tab` | workspace.write |
| `pane.focus` | `id` | `pane` | workspace.write |
| `pane.maximize` | `id`, `maximized` | `pane`, `tab` | workspace.write |
| `pane.close` | `id`, `allowRunning?`, `force?` | `deleted` | workspace.write (+session.close) |

A new pane inherits the source pane's machine and folder, as in the UI: a split of a remote pane is a remote shell on the same host.

## Sessions

| Method | Params | Result | Caps |
| --- | --- | --- | --- |
| `session.get` | `id` | `session` | workspace.read |
| `session.start` | `paneId`, `launch?` | `session` | session.start (+session.execute for a `shell` with `directory`, any `process`, or an `environment`) |
| `session.restart` | `paneId`, `launch?`, `allowRunning?`, `force?` | `session` (new ID) | session.start (+session.close if running, +session.execute as above) |
| `session.stop` | `id`, `force?` | `session` | session.close |
| `session.sendInput` | `id`, `text` or `base64`, `mode` `literal`/`paste` | `acceptedBytes` | session.input |
| `session.execute` | `id`, `command`, `wait?: {until: "finished", timeoutMs}` | `submitted`, and with `wait`: `exitCode`, `durationMs`, `timedOut` | session.execute |
| `session.readOutput` | `id`, `view` `screen`/`scrollback`/`stream`, `cursor?`, `maxBytes?` | as v1 (`text` or `base64`, `nextCursor`, `truncated`, `gap`) | session.output.read |

- Without `launch`, `session.start` uses the pane's saved launch, which may be an SSH host (needs the host in scope) or an agent (needs **agent.control**).
- `launch.kind: "agent"` is accepted only through `agent.start`; `session.start` refuses it with `-32602` so agent permissions can't be bypassed.
- `session.execute` with `wait` needs authenticated shell integration (FR-SI02) and returns when the command-finished mark arrives. Without integration it is `INVALID_STATE` (`details.state: "noIntegration"`). Remote workspace panes return `REMOTE_DISCONNECTED` while the link is down.

## Agents

| Method | Params | Result | Caps |
| --- | --- | --- | --- |
| `agent.list` | `machine?` | `agents` (definitions with availability) | workspace.read |
| `agent.get` | `id` | `agent` | workspace.read |
| `agent.runs` | `spaceId?`, `state?` | `runs` (agent runs in scope) | workspace.read |
| `agent.start` | `agentId`, `placement`, `directory?`, `resume?` | `run`, `pane`, `tab?` | agent.control + workspace.write (+session.execute if `directory`) |
| `agent.restart` | `sessionId`, `resume?` | `run` (new session) | agent.control |
| `agent.respond` | `sessionId`, `action` `approve`/`reject`/`reply`, `text?`, `expectedState?` | `run` | agent.respond (or session.input) |
| `agent.install` | `agentId`, `hostId?` | `availability` | agent.install + session.execute |

- `placement` is `{"kind": "tab", "spaceId"}`, `{"kind": "split", "paneId", "axis"}` or `{"kind": "pane", "paneId"}` (a stopped pane). The machine is the space's or pane's machine; an agent missing there is `AGENT_UNAVAILABLE`.
- `agent.respond` sends fixed bytes: `approve` is `1` + Return, `reject` is Escape, `reply` is the text + Return. It is refused with `INVALID_STATE` unless the run's state is `needsInput` (or `expectedState` if given), so a stale answer never reaches a prompt that moved on. It is a narrower permission than **session.input**.
- `agent.install` runs the definition's install command on the machine, exactly as the app's install offer does (FR-AG).

## Hosts

| Method | Params | Result | Caps |
| --- | --- | --- | --- |
| `host.list` | `query?`, `tags?`, `limit?`, `cursor?` | `hosts` | host.read |
| `host.get` | `id` | `host` | host.read |
| `host.create` | `name`, `destination`, `user?`, `port?`, `identityFile?`, `tags?` | `host` | host.write + session.execute |
| `host.update` | `id`, fields | `host` | host.write (+session.execute if a connection field changes) |
| `host.delete` | `id` | `deleted` | host.write |
| `host.connect` | `hostId`, `placement` (`tab`, `split` or `space`) | `session`, `pane` | session.start + workspace.write |

Passwords are never set or read through the API; saving one stays a UI action (FR-H09).

## Remote workspaces

| Method | Params | Result | Caps |
| --- | --- | --- | --- |
| `remote.open` | `hostId`, `name?`, `start?` | `space`, `tab`, `panes` | remote.connect + workspace.write, all-spaces or `created` scope (+session.start) |
| `remote.status` | `hostId` | `remote` (helper and link) | host.read |
| `remote.reconnect` | `hostId` | `remote` | remote.connect |
| `remote.helper.install` | `hostId` | `remote` | remote.manage |
| `remote.helper.remove` | `hostId` | `remote` | remote.manage |

`remote.open` makes a space whose machine is the host (FR-RW01); its sessions run in the host's broker. If the helper is missing and the host's auto-install is off, it is `CONFIRMATION_REQUIRED` with `details.reason: "helperInstall"` unless the grant also holds **remote.manage**.

## Projects

| Method | Params | Result | Caps |
| --- | --- | --- | --- |
| `project.list` | `query?`, `limit?`, `cursor?` | `projects` | project.read |
| `project.get` | `id` | `project` | project.read |
| `project.create` | `document` (project JSON, FR-PL) | `project` | project.write + session.execute |
| `project.update` | `id`, `document` | `project` | project.write (+session.execute if commands, agents or repository change) |
| `project.delete` | `id` | `deleted` | project.write |
| `project.capture` | `spaceId`, `name` | `project` | project.write + workspace.read |
| `project.check` | `id`, `target`, `folder?` | `plan`: `needsSetup`, `checkouts` (`clone`/`present`/`blocked`), `commands`, `agents`, `folderExists` | project.read |
| `project.launch` | `id`, `target`, `folder?`, `setup?` | `space`, `launches` | project.launch + session.start (+session.execute if it runs setup or pane commands, +agent.control if it starts agents, +remote.connect for a host target) |

`project.launch` does what the app's launch sheet does (FR-PL06–PL08) and binds the space to the project. If setup is needed and `setup` isn't true, it is `SETUP_REQUIRED` with the plan in `details`. Project definitions are untrusted: a grant can only run what the plan shows, and a project changed after `project.check` is `CONFLICT`.

## Tasks

| Method | Params | Result | Caps |
| --- | --- | --- | --- |
| `task.list` | `paneId` | `tasks`, `folder` (execute) | task.read |
| `task.run` | `paneId`, `taskId` | `run` | task.run |
| `task.stop` | `paneId`, `force?` | `run` | task.run |
| `task.get` | `paneId` | `run` (the pane's current or last run) | task.read |

`task.run` types the task into the pane's shell exactly as the app does (FR-TK04) and needs a shell pane with integration; an untrusted `launch.json` task is `TASK_UNTRUSTED` — trust is only given in the app. Stop sends Ctrl-C and force sends Ctrl-\\ (FR-TK06).

## Layouts, themes and appearance

As in v1 ([Layouts](../layouts.md)), renamed to the v2 capabilities: `layout.validate`, `layout.plan`, `layout.export` need workspace.read; `layout.apply` needs workspace.write and all-spaces. Layout documents become version 3: `windows` (v1) is no longer accepted, spaces may carry `machine` (remote, needs remote.connect) and `projectId` (binds the space, needs project.launch), and panes may carry an `agent` (needs agent.control).

`theme.*` and `appearance.*` are unchanged apart from capability names (theme.read, theme.write).

## Events

`events.subscribe`, `events.unsubscribe` and `events.poll`: see [Events](events.md).
