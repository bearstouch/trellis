# Permissions (draft)

!!! warning "Draft contract — not implemented"
    Part of the proposed [protocol 2](index.md).

A grant is still a token plus what it may do. v2 keeps **capabilities** as the unit the server enforces, makes them match the areas of the app, adds **scopes** for projects and agents and a `created` space scope, leads the UI with **presets**, and lets grants be **edited**. Tokens, Keychain storage, hashing, lifetimes (60 s – 90 days), revocation and the [threat model](../authorization.md#threat-model) are unchanged.

## Capabilities (API2-06)

| Capability | Allows | Replaces (v1) |
| --- | --- | --- |
| `workspace.read` | Read spaces, tabs, panes, sessions, agent runs and definitions, layouts; subscribe to workspace, attention, shell (no text) and agent events | `metadata.read` |
| `workspace.write` | Create, rename, reorder, focus, split, resize, maximize and close (stopped) spaces, tabs and panes; apply layouts | `layout.write` |
| `session.start` | Start or restart a pane with its saved launch, a default shell or an approved host | `session.start` |
| `session.execute` | Choose what runs: processes, directories, environment, commands; read launch details, folders and commands | `session.execute` |
| `session.input` | Send any input to a session. **Equivalent to command execution in that pane.** | `session.input` |
| `session.output.read` | Read the screen, scrollback and output stream | `session.output.read` |
| `session.close` | Stop running sessions and close containers that hold them | `session.close` |
| `agent.control` | Start, restart and resume managed agents | *(new)* |
| `agent.respond` | Approve, reject or reply to an agent that needs input (`agent.respond` only) | *(new; was only possible with session.input)* |
| `agent.install` | Install an agent on a machine | *(new)* |
| `host.read` | Read saved hosts, helper and link state | `host.read` |
| `host.write` | Create, edit and delete saved hosts | `host.write` |
| `remote.connect` | Open remote workspaces and reconnect them | *(new)* |
| `remote.manage` | Install, update and remove the remote helper on hosts | *(new)* |
| `project.read` | Read the project library and launch plans | *(new)* |
| `project.write` | Create, edit, capture and delete projects | *(new)* |
| `project.launch` | Launch projects into spaces | *(new)* |
| `task.read` | List tasks and read task runs | *(new)* |
| `task.run` | Run and stop trusted tasks | *(new)* |
| `theme.read` / `theme.write` | Themes and appearance | unchanged |

### How capabilities compose

Intent-level capabilities never widen what a grant can execute: anything that decides *what runs* also needs `session.execute`.

| Operation | Required |
| --- | --- |
| Start an agent in a pane's folder | agent.control + workspace.write |
| …in a chosen `directory` | + session.execute |
| Answer an agent | agent.respond (session.input also suffices: the method declares the pair as "any of", and `details.missing` names agent.respond) |
| Install an agent | agent.install + session.execute |
| Run a trusted task | task.run (the task's command is fixed by the trusted file or detection) |
| Launch a project that runs setup, pane commands or agents | project.launch + session.start + session.execute (+agent.control for agents, +remote.connect for a host target) |
| Create or edit a project's commands, agents or repository | project.write + session.execute |
| Open a remote workspace | remote.connect + workspace.write, host in scope (+remote.manage to install the helper) |
| Close anything with running sessions | session.close + workspace.write |
| Read launch details, folders, task commands, project commands | the read capability + session.execute |

## Scopes

| Scope | Values | Applies to |
| --- | --- | --- |
| Spaces | `all`, `created` (only spaces this grant created, and their contents), or a set of space IDs | spaces, tabs, panes, sessions, agent runs, task runs, workspace events |
| Projects | `all` or a set of project IDs | project methods, launching, project spaces' `project` field |
| Hosts | `all` or approved hosts, each bound to its `connectionRevision` (unchanged from v1) | hosts, SSH panes, remote workspaces, agent availability on hosts |
| Agents | `all` or a set of agent definition IDs | `agent.start`, `agent.restart`, `agent.install`; runs of other agents stay readable |

- Creating a top-level space needs `all` or `created` space scope (`space.create`, `host.connect` with `placement.kind: space`, and later `remote.open` and `project.launch`); a set of space IDs can't create spaces. With `created`, the new space joins the grant's scope, so an orchestrator can make and manage its own spaces without seeing the user's.
- **How `created` is recorded.** A space created through protocol 2 is recorded for the creating grant inside the same workspace transaction that creates it, so no later call, result or event sees the space before the grant does. Spaces created in the app (the sidebar, menus, palette, project and remote launches started by the user) never join. The record is kept with the grant whatever its scope, so narrowing a grant from `all` to `created` keeps the spaces it made; a closed space leaves it once its `space.deleted` event has been delivered. The recorded IDs are stored in `grants.json`.
- **Protocol 1** has no `created` scope: until the switch it treats such a grant as the set of spaces it has created so far (`spaceScope` in its `auth.authenticate` result lists them), and since protocol 1 never records, it can't create spaces with it.
- A project space is visible if the space is in scope; its `project` field is shown only if the project is in project scope too. Launching needs both the project and (for a host target) the host in scope.
- Agent scope limits what a grant can start: `agent.start`, `agent.restart`, `agent.install`, and starting a pane whose saved launch is an agent (`session.start`, `start: true`), which also needs **agent.control**.
- Out-of-scope resources are `NOT_FOUND`, exactly as if they didn't exist.

## Presets

The grant sheet leads with presets; **Custom** shows every capability, grouped by area with plain-language descriptions instead of raw names. A grant stores its capabilities (the enforcement unit) and the preset it came from (for display); editing capabilities turns it into Custom.

| Preset | Capabilities | Default scope |
| --- | --- | --- |
| **Observer** | workspace.read, session.output.read, host.read, project.read, task.read, theme.read | all spaces, projects, hosts and agents |
| **Operator** | Observer + workspace.write, session.start, session.input, session.close, task.run | all spaces, projects and agents; approved hosts |
| **Agent orchestrator** | Operator + agent.control, agent.respond, project.launch, remote.connect | `created` spaces, all projects, approved hosts, all agents |
| **Full control** | every capability | all |
| **Custom** | chosen | chosen |

Host access stays opt-in (approved hosts, none until chosen) for every preset that can start sessions except Full control, as in v1's sheet. Choosing a preset sets exactly its capabilities and default scopes; changing any capability afterwards makes the grant Custom, while changing a scope keeps the preset. Default lifetime stays 1 day; the sheet keeps 1 hour to 90 days.

## Grant view

`auth.authenticate` and `grant.get` return:

```json
{"id": "…", "name": "Grok bot", "preset": "agentOrchestrator", "revision": 3,
 "capabilities": ["workspace.read", "…"],
 "scope": {"spaces": "created", "projects": "all", "hosts": [{"hostId": "…", "connectionRevision": 2, "current": true}], "agents": "all"},
 "createdAt": "…", "expiresAt": "…"}
```

`grant.get` (no capability needed) lets a client see what it may do instead of probing with `PERMISSION_DENIED`.

## Editing grants

- Name, capabilities, scopes and expiry can be edited in **Settings → Automation**; the token can't. A new expiry counts from the moment of the edit. Only active grants can be edited, and every edit raises `revision`.
- Narrowing (a capability removed, a narrower scope, an earlier expiry) applies at once, even if saving the file then fails: subscriptions that `events.subscribe` would now refuse end, MCP sessions of the grant end (clients start a new one and get the new tool list), and every open connection gets `AUTH_REQUIRED` on its next call, so it authenticates again and re-reads the grant. Every call already re-reads the grant, so nothing in flight runs with the old one.
- Widening (adding capabilities or scope, or extending expiry) asks for confirmation first, like Remote Control's network confirmation; Cancel leaves the grant exactly as it was. A widening is saved before it applies, so a failed write changes nothing; it doesn't end authentications. An edit can narrow and widen at once; it then needs the confirmation and also ends authentications.
- Host approvals can be refreshed (re-approve) as in v1, without a confirmation: the user approves exactly the same hosts again.
- Renaming alone neither widens nor narrows.

## Storage

`grants.json` becomes schema 2: `{"schemaVersion": 2, "grants": [...]}`, where each grant stores its v2 `capabilities`, `preset`, `revision`, `scope` (`spaces`: `"all"`, `"created"` or IDs; `projects` and `agents`: `"all"` or IDs; `hosts`: `"all"` or `[{"hostId", "connectionRevision"}]`), `createdSpaces` (the `created` scope's members, when there are any), `createdAt`, `expiresAt` and `revokedAt`. The v1 keys (`windowScope`, `windows`, `hostID` and the v1 capability names) are read once during migration, never written. File mode, atomic replace, hash-only storage and read-only recovery are unchanged: an unreadable file, a newer `schemaVersion` or an unknown capability or scope leaves the file untouched and no grant active.

Grants are stored as schema 2 as soon as a build with the v2 grant model runs (before protocol 2 ships, because the grant sheet edits them); protocol 1 reads its view of the same grants, so a migrated grant behaves under v1 exactly as before.

## Requirements

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| API2-06a | Capabilities and composition are enforced at the service boundary. | Each row of both tables has an allow and a deny test; a test fails if a method has no policy entry. |
| API2-06b | `created` scope. | A grant with `created` scope that makes a space can read and change it, its tabs, panes and sessions, and nothing else; its events are delivered; another grant's spaces are `NOT_FOUND`. |
| API2-06c | Presets and Custom. | Each preset produces exactly its capability set; changing one capability shows Custom; the sheet groups capabilities by area with descriptions and VoiceOver labels. |
| API2-06d | Grants are editable; narrowing applies at once, widening asks first. | Removing `session.output.read` and `session.input` ends an output subscription (a metadata one stays), and the next `session.sendInput` is `AUTH_REQUIRED`, then `PERMISSION_DENIED` after re-authenticating; adding a capability shows a confirmation, and Cancel keeps the grant unchanged. |
| API2-06e | Agent and project scopes. | An `agents: ["trellis-codex"]` grant can't start Claude Code (`NOT_FOUND`) but can read its runs; a project outside scope is `NOT_FOUND` for launch. |
