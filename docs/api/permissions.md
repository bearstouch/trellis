# Permissions

Every automation client authenticates with a **grant**: a token plus what it may do. The user creates and edits grants in **Settings → Automation**. A grant combines **capabilities** (the unit the server enforces, matching the areas of the app), **scopes** for spaces, projects, hosts and agents, a **preset** it came from, and an expiry. Authorization is enforced at the service boundary from each method's declaration in the catalog (`MethodCatalogV2`, `Sources/TrellisControl/V2/`), for the socket and MCP alike, and every call re-reads the grant.

## Grants and tokens

| Property | Implementation |
| --- | --- |
| Token format | `trl_` followed by 32 random bytes in base64url without padding |
| Token storage | Keychain generic password: service `Trellis Automation`, account = grant UUID, accessibility *when unlocked, this device only* |
| Grant metadata | `<state-dir>/grants.json`, mode `0600`, written atomically. Stores only `sha256:<hex>` of the token, which is compared in constant time. See [Storage](#storage). |
| Lifetime | Between 60 seconds and 90 days. The sheet offers 1 hour, 1 day (default), 7, 30 and 90 days. |
| Revocation | Takes effect immediately: open connections, subscriptions, waiting polls and MCP sessions of the grant end. Revoked and expired grants stay in the file for the record. |
| Editing | Name, capabilities, scopes and expiry can be changed; the token can't. See [Editing grants](#editing-grants). |

The token is shown only once, in the grant-creation flow. If `grants.json` can't be read, has a newer `schemaVersion`, or names a capability or scope this build doesn't know, Trellis preserves it, marks the store read-only, and treats no grant as active.

Tokens never go on a command line. The CLI reads the token from standard input (`--token-stdin`) or from the Keychain (`--keychain-grant GRANT_UUID`), and it rejects `--token`, `--password` and `--secret`. Tokens never go into environment variables that shells inherit, either; launched sessions have Trellis control variables removed from their environment. Failed authentications are rate-limited (5 per 60 seconds; MCP's network failures are counted apart, so they can't lock out the local socket).

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

`clipboard.read` and `clipboard.write` are reserved for a future clipboard API; agents get no clipboard access.

### How capabilities compose

Intent-level capabilities never widen what a grant can execute: anything that decides *what runs* also needs `session.execute`.

| Operation | Required |
| --- | --- |
| Start an agent in a pane's folder | agent.control + workspace.write |
| …in a chosen `directory` | + session.execute |
| Answer an agent | agent.respond (session.input also suffices: the method declares the pair as "any of", and `details.missing` names agent.respond) |
| Install an agent | agent.install + session.execute (+ agent.control + workspace.write: the installer then starts the agent in a pane, as the app's Install and Launch does) |
| Run a trusted task | task.run (the task's command is fixed by the trusted file or detection) |
| Launch a project | project.launch + session.start (+remote.connect for a host target, which must be in host scope; all or `created` spaces) |
| …that runs setup or pane commands, or in a chosen folder | + session.execute |
| …that starts agents | + agent.control, each agent in the agent scope |
| Check a project on a host (connects to it) | project.read + remote.connect |
| Create a project, or edit a project's commands, agents, repositories or folders | project.write + session.execute |
| Open a remote workspace | remote.connect + workspace.write, host in scope, all or `created` spaces (+session.start to start its shell; +remote.manage to install a missing helper, unless the host's automatic install is on: otherwise `CONFIRMATION_REQUIRED`, `helperInstall`) |
| Reconnect a remote workspace | remote.connect, host in scope (the same helper rule) |
| Install, update or remove the remote helper | remote.manage, host in scope (+session.close to stop this Mac's sessions there while removing) |
| Act on a remote workspace session (input, execute, stop, restart, read output) | the session method's capability + the session's host in scope at its current connection (FR-RW15) |
| Close anything with running sessions | session.close + workspace.write |
| Apply a layout | workspace.write, all spaces (+session.start with `startNew`; +remote.connect for a space on a remote machine; +project.launch for a space bound to a project; +agent.control for agent panes, each agent in scope) |
| Write themes or appearance | theme.write, all spaces |
| Read launch details, folders, task commands, project commands | the read capability + session.execute |

## Scopes

| Scope | Values | Applies to |
| --- | --- | --- |
| Spaces | `all`, `created` (only spaces this grant created, and their contents), or a set of space IDs | spaces, tabs, panes, sessions, agent runs, task runs, workspace events |
| Projects | `all` or a set of project IDs | project methods, launching, project spaces' `project` field |
| Hosts | `all` or approved hosts, each bound to its `connectionRevision` (unchanged from v1) | hosts, SSH panes, remote workspaces, agent availability on hosts |
| Agents | `all` or a set of agent definition IDs | `agent.start`, `agent.restart`, `agent.install`; runs of other agents stay readable |

- Creating a top-level space needs `all` or `created` space scope (`space.create`, `host.connect` with `placement.kind: space`, `remote.open` and `project.launch`); a set of space IDs can't create spaces. With `created`, the new space joins the grant's scope, so an orchestrator can make and manage its own spaces without seeing the user's.
- **How `created` is recorded.** A space created through protocol 2 is recorded for the creating grant inside the same workspace transaction that creates it, so no later call, result or event sees the space before the grant does. Spaces created in the app (the sidebar, menus, palette, project and remote launches started by the user) never join. The record is kept with the grant whatever its scope, so narrowing a grant from `all` to `created` keeps the spaces it made; a closed space leaves it once its `space.deleted` event has been delivered. The recorded IDs are stored in `grants.json`.
- A project space is visible if the space is in scope; its `project` field is shown only if the project is in project scope too. Launching needs both the project and (for a host target) the host in scope.
- Agent scope limits what a grant can start: `agent.start`, `agent.restart`, `agent.install`, and starting a pane whose saved launch is an agent (`session.start`, `start: true`), which also needs **agent.control**. To the agent methods an agent outside the scope is `NOT_FOUND`; definitions and runs of every agent stay readable, and `agent.respond` answers any run in space scope.
- These need **all-spaces** scope: reordering spaces, `layout.apply`, and every theme and appearance write.
- Each host approval is bound to the host's *connection revision*: if its destination or another launch-affecting field changes, calls that use it are `PERMISSION_DENIED` until the user reapproves it.
- Out-of-scope resources are `NOT_FOUND`, exactly as if they didn't exist. Events are redacted the same way.

## Presets

The grant sheet leads with presets; **Custom** shows every capability, grouped by area with plain-language descriptions instead of raw names. A grant stores its capabilities (the enforcement unit) and the preset it came from (for display); editing capabilities turns it into Custom.

| Preset | Capabilities | Default scope |
| --- | --- | --- |
| **Observer** | workspace.read, session.output.read, host.read, project.read, task.read, theme.read | all spaces, projects, hosts and agents |
| **Operator** | Observer + workspace.write, session.start, session.input, session.close, task.run | all spaces, projects and agents; approved hosts |
| **Agent orchestrator** | Operator + agent.control, agent.respond, project.launch, remote.connect | `created` spaces, all projects, approved hosts, all agents |
| **Full control** | every capability | all |
| **Custom** | chosen | chosen |

Host access stays opt-in (approved hosts, none until chosen) for every preset that can start sessions except Full control. Choosing a preset sets exactly its capabilities and default scopes; changing any capability afterwards makes the grant Custom, while changing a scope keeps the preset. Default lifetime stays 1 day; the sheet keeps 1 hour to 90 days.

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
- **Reapprove** next to a changed host refreshes its approval to the host's current connection without a confirmation: the user approves exactly the same hosts again. Adding a host is a widening.
- Renaming alone neither widens nor narrows.

## Storage

`grants.json` is schema 2: `{"schemaVersion": 2, "grants": [...]}`, where each grant stores its v2 `capabilities`, `preset`, `revision`, `scope` (`spaces`: `"all"`, `"created"` or IDs; `projects` and `agents`: `"all"` or IDs; `hosts`: `"all"` or `[{"hostId", "connectionRevision"}]`), `createdSpaces` (the `created` scope's members, when there are any), `createdAt`, `expiresAt` and `revokedAt`. The v1 keys (`windowScope`, `windows`, `hostID` and the v1 capability names) are read once during migration, never written. File mode, atomic replace, hash-only storage and read-only recovery are unchanged: an unreadable file, a newer `schemaVersion` or an unknown capability or scope leaves the file untouched and no grant active.

A schema 1 file (a bare array with `windowScope`, from protocol 1 releases) is migrated once: it is copied byte for byte to `grants.json.v1.bak` (mode `0600`), then replaced. Every grant keeps its token, expiry and scopes and gets exactly the [mapped capabilities](migration.md#capabilities), never more; its preset is Custom and its project and agent scopes `all`. If the backup or the new file can't be written, the migrated grants still work and the next write tries again, backup first. An earlier release can't read schema 2 (it shows no grants and writes nothing); restore the backup to use the old grants there.

## Network clients (MCP)

The [MCP server](mcp.md) uses the same grants. A network client has no peer user ID, so its bearer token is its whole credential. Capabilities, scopes, expiry, revocation and edits apply exactly as on the socket, and `tools/list` shows only the tools the grant can use. Clients that connect over a tailnet through **Share over Tailscale** use grants the same way. Give each client its own grant; the allowed-devices list only decides which tailnet devices can reach the endpoint at all ([FR-RC09](mcp.md#connecting-agents-over-a-tailnet)).

## Untrusted output

No permission ever comes from terminal text. Output, titles set by programs, task commands from repository files and agent-reported settings are untrusted data, and that includes text that seems to ask an agent to change its permissions or run something. A client that can read the workspace can't assume it may also read or control every pane.

## Threat model

These controls protect against accidental and unauthorized access by *other clients*: the peer's UID must match the app's on the socket, tokens are hashed at rest, and out-of-scope resources look missing. Malware running as the same user is outside any strong isolation guarantee, and nothing here can make a compromised user account safe.

## Requirements

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| API2-06a | Capabilities and composition are enforced at the service boundary. | Each row of both tables has an allow and a deny test; a test fails if a method has no policy entry. |
| API2-06b | `created` scope. | A grant with `created` scope that makes a space can read and change it, its tabs, panes and sessions, and nothing else; its events are delivered; another grant's spaces are `NOT_FOUND`. |
| API2-06c | Presets and Custom. | Each preset produces exactly its capability set; changing one capability shows Custom; the sheet groups capabilities by area with descriptions and VoiceOver labels. |
| API2-06d | Grants are editable; narrowing applies at once, widening asks first. | Removing `session.output.read` and `session.input` ends an output subscription (a metadata one stays), and the next `session.sendInput` is `AUTH_REQUIRED`, then `PERMISSION_DENIED` after re-authenticating; adding a capability shows a confirmation, and Cancel keeps the grant unchanged. |
| API2-06e | Agent and project scopes. | An `agents: ["trellis-codex"]` grant can't start Claude Code (`NOT_FOUND`) but can read its runs; a project outside scope is `NOT_FOUND` for launch. |
