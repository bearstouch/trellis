# Methods (draft)

!!! warning "Draft contract — not implemented"
    Part of the proposed [protocol 2](index.md).

Every method follows the [conventions](index.md#conventions-api2-02). In the tables, **Caps** are required [capabilities](permissions.md); `+x if y` is a conditional capability. Every `id`-addressed method answers `NOT_FOUND` for resources outside the grant's scope. Unless stated otherwise, mutating methods take `expectedRevision` and `idempotencyKey`.

## System and workspace

| Method | Params | Result | Caps |
| --- | --- | --- | --- |
| `system.info` | — | `appVersion`, `protocolVersion`, `instanceId`, `limits` (`maxFrameBytes`, `maxJsonDepth`, `maxConnections`, `maxPageSize`, `maxPanes`) | none |
| `grant.get` | — | `grant` (the caller's own [grant view](permissions.md#grant-view)) | none |
| `workspace.get` | `include?: ["tabs","panes","sessions","agents","layout"]` | Everything in scope in one call: `revision`, `activeSpaceId`, `spaces`, and the included collections | workspace.read |
| `workspace.save` | — | `savedAt` | workspace.write |

`workspace.get` is the starting point for agents: one call instead of `space.list` + N × `tab.get`. `include: ["layout"]` adds each tab's split tree (and implies `tabs`). It is bounded by the 1 MiB frame; `LIMIT_EXCEEDED` tells the client to page with the list methods. `workspace.save` takes no `expectedRevision`: it writes the current state and changes no resource.

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

In a project space, `tab.create` makes a temporary tab (FR-W08); project tabs come from the project. `tab.update` needs at least one of `title` and `color`; `tab.duplicate`'s `expectedRevision` is the source tab's.

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

A new pane inherits the source pane's machine and folder, as in the UI: a split of a remote pane is a remote shell on the same host. `pane.list` takes exactly one of `tabId` and `spaceId`; its `revision` is that tab's or space's. A branch has no revision of its own, so `pane.resize`'s `expectedRevision` is its tab's. `pane.split` is refused with `INVALID_STATE` while the tab has a maximized pane, as in the app.

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

- `launch` is `{"kind": "shell", "directory"?, "environment"?}`, `{"kind": "process", "executable", "arguments"?, "directory", "environment"?}` or `{"kind": "ssh", "hostId"}` (the host must be in scope). Paths are absolute; `TRELLIS_` environment names are reserved. In a remote workspace only `shell` is accepted, and it runs on the space's host (as layouts do, FR-RW10).
- Without `launch`, `session.start` uses the pane's saved launch, which may be an SSH host (needs the host in scope) or an agent (needs **agent.control**). The same applies to `start: true` on `space.create`, `tab.create`, `tab.duplicate` and `pane.split`, checked before anything is created: a duplicated agent or SSH pane, or a new pane in a remote workspace (the space's host).
- `launch.kind: "agent"` is accepted only through `agent.start`; `session.start` refuses it with `-32602` so agent permissions can't be bypassed.
- `session.start`'s and `session.restart`'s `expectedRevision` is the pane's (`paneId`); the other session methods compare the session's. A running pane is `INVALID_STATE` for `session.start` (`details.state`). `session.stop` asks gracefully; `force: true` is honoured only once the graceful request is 2 s old, so the first call is `CLOSE_PENDING` either way if the process ignores it.
- `session.sendInput` takes exactly one of `text` and `base64` (64 KiB decoded, `LIMIT_EXCEEDED` above) and returns `acceptedBytes` and `mode`; `session.execute` returns `submitted` and `acceptedBytes`.
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

- `host.list` filters by `query` (every word matches a name, destination, user or tag) and `tags` (every tag, any case). It has no `revision`: the host library has no collection revision. `host.create` takes no `expectedRevision` for the same reason. `host.create` returns the new host even to a grant limited to approved hosts; it can't be used through that grant until it is approved.
- `host.update` needs at least one field; `null` clears `user`, `port`, `identityFile` or `tags`. Sending any of `destination`, `user`, `port` or `identityFile`, `null` included, needs **session.execute**.
- `host.delete` returns `deleted` without `workspaceRevision`.
- `host.connect`'s `placement` is `{"kind": "tab", "spaceId"}`, `{"kind": "split", "paneId", "axis"?}` or `{"kind": "space", "name"?}`; a new space needs all-spaces scope. Its `expectedRevision` is the host's, so a client connects to the host it read. An ssh pane never opens in a remote workspace (`INVALID_STATE`). The new tab or space is named after the host.

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
