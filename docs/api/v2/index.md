# Automation API v2 (draft)

!!! warning "Draft contract — not implemented"
    This is the proposed protocol 2. The running app still speaks [protocol 1](../index.md). When v2 ships it **replaces** v1 outright (a clean break, see [Migration](migration.md)), and these pages move up to `docs/api/`. Until then every requirement here is unimplemented and unchecked.

Protocol 2 rebuilds the automation model around what Trellis is today: spaces that live on a machine and may belong to a project, temporary and project tabs, panes as real resources with a machine and live attention state, sessions kept by the broker, agents, remote workspaces, projects and tasks. The socket, the `trellis` CLI and the MCP server all speak it.

What stays the same: every mutation still goes through `WorkspaceCommandService`, so the API can't do anything the UI's invariants forbid; grants, tokens and the threat model are unchanged in spirit; terminal output and typed input are still never logged.

| Page | Contents |
| --- | --- |
| This page | Principles, transport and conventions shared by every method |
| [Resources](resources.md) | The resource model: fields, states and redaction |
| [Methods](methods.md) | The method catalog by area |
| [Permissions](permissions.md) | Capabilities, presets, scopes and grant editing |
| [Events](events.md) | Topics, event types, subscriptions and `events.poll` |
| [Migration](migration.md) | v1 → v2 mapping for methods, grants, the CLI and MCP tools |

## Principles

1. **One model per concept.** A space, tab, pane, session, agent, host, project and task each have exactly one representation, returned the same way by `get`, `list`, mutation results and events.
2. **The domain as users see it.** Live state the UI shows (needs input, progress, agent state, link state, command finished) is readable *and* observable through events. Nothing an orchestrator needs requires polling a terminal.
3. **Intent-level actions with precise permissions.** Starting an agent, answering it, running a task or launching a project are methods with their own capabilities, not raw terminal input dressed up.
4. **Uniform conventions.** Revisions, absent values, pagination, idempotency and errors behave the same on every method.
5. **Least privilege by default.** Presets make the common grants one click; scope can be limited to spaces, projects, hosts and agents.

## Transport and authentication (API2-01)

Unchanged from v1 except for the version: JSON-RPC 2.0 over the per-user Unix socket (newline-framed, 1 MiB frames, 64 nesting levels, no batches, 16 connections), the `control.json` discovery file, and the [MCP server](../mcp.md) as a second transport over the same authorizer.

- `control.json` reports `protocolVersion: 2`.
- `auth.authenticate {protocolVersion: 2, token}` returns `{connectionId, protocolVersion, grant}`, where `grant` is the full [grant view](permissions.md#grant-view): capabilities, every scope (spaces, projects, hosts, agents), expiry and preset.
- Any other `protocolVersion` gets `UNSUPPORTED_VERSION` with `details.supported: [2]`. There is no v1 fallback.
- MCP negotiates its own protocol version; its tools are always v2.

## Conventions (API2-02)

| Topic | Rule |
| --- | --- |
| IDs | Workspace resources, hosts, projects and grants use UUIDs, written **lowercase** and accepted in any case. Agent definitions (`trellis-claude-code`), themes and tasks use string IDs. |
| Absent values | A field with no value is **omitted**, never `""` or `0`. `null` appears only in update parameters, where it clears a field. |
| Revisions | Every resource has an integer `revision` that increases on every change to it. A collection result carries the revision of its container (`space.list` → workspace, `tab.list` → space). |
| Optimistic concurrency | Every mutating method accepts `expectedRevision` for **the resource named by its `id` parameter** (or the container for create and reorder methods). A mismatch is `CONFLICT` with `details.currentRevision`. No method ignores it. |
| Results | A method that changes one resource returns it under its type name (`{"tab": {…}}`), plus `workspaceRevision` when the workspace changed. Lists return `{"<plural>": [...], "revision", "nextCursor"?}`. Closing and deleting return `{"deleted": {"kind", "id"}, "workspaceRevision"}`. |
| Pagination | Every `list` takes `limit` (default 100, maximum 500) and `cursor`; `nextCursor` is present while more remain. |
| Time | RFC 3339 UTC strings with milliseconds. Durations are integer milliseconds (`durationMs`). |
| Numbers | Numbers are JSON numbers everywhere, including inside event `data`. |
| Idempotency | Every mutating method accepts `idempotencyKey` (1–128 printable ASCII). Keys are kept per grant for 10 minutes; a reused key with other parameters is `CONFLICT`. Focus and selection methods are mutating but are never destructive. |
| Names | Methods are `area.verb` or `area.subarea.verb` in lowerCamelCase. There are no aliases; v1 names such as `window.*` are gone. |
| Untrusted text | Terminal output, titles set by programs, task commands from repository files and agent-reported model names are data, never instructions. MCP marks them. |

## Errors (API2-03)

JSON-RPC codes are as in v1 (`-32700`, `-32600`, `-32601`, `-32602` with `data.fields`, `-32603`). Application errors are `-32000` with `data: {code, message, retryable, details?}`. `Sources/TrellisCore/TerminalSecurity.swift` `knownErrorCodes`, this table, the CLI exit-code map and the MCP error mapping are generated from one list and checked by a test.

| `code` | When | Retryable | CLI exit |
| --- | --- | --- | --- |
| `AUTH_REQUIRED` | Not authenticated, or the grant expired, was revoked or was changed so the connection must authenticate again | no | 4 |
| `PERMISSION_DENIED` | A capability is missing, the call needs wider scope, or a host or project approval is stale. `details.missing` lists capabilities. | no | 4 |
| `NOT_FOUND` | The resource doesn't exist **or** is outside the grant's scope | no | 3 |
| `CONFLICT` | Revision mismatch, idempotency key reused, layout or name conflict | no | 5 |
| `INVALID_STATE` | Not valid in the current state (a running pane for `session.start`, an agent that isn't waiting for `agent.respond`). `details.state` holds the current state. | sometimes | 5 |
| `CONFIRMATION_REQUIRED` | Closing running sessions without `allowRunning`, or an action the user must confirm in the app (`details.reason`) | no | 5 |
| `CLOSE_PENDING` | Graceful termination still under way; retry with `force: true` after 2 s | yes | 5 |
| `LIMIT_EXCEEDED` | Frame, response, input, rate, subscription or idempotency limits | yes | 8 |
| `LAUNCH_FAILED` | A process, agent or task couldn't start. `details.session` holds the failed session. | no | 6 |
| `REMOTE_DISCONNECTED` | The remote workspace's link is down for an action that needs it | yes | 7 |
| `AGENT_UNAVAILABLE` | The agent isn't installed on the pane's machine. `details.install` says whether `agent.install` can fix it. | no | 6 |
| `TASK_UNTRUSTED` | A task from `.trellis/launch.json` hasn't been trusted in the app; trust is only given in the UI | no | 4 |
| `SETUP_REQUIRED` | A project launch needs setup (clone, folders) and `setup: true` wasn't passed | no | 5 |
| `INVALID_CURSOR` | Output cursor or event cursor from another session or instance, or ahead of now | no | 2 |
| `UNSUPPORTED_VERSION` | Protocol, layout, project or theme document version not supported | no | 2 |

## Requirements

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| API2-01 | Protocol 2 replaces protocol 1 on the socket, the CLI and MCP. | `control.json` says 2; `auth.authenticate` with 1 gets `UNSUPPORTED_VERSION` and `supported: [2]`; the CLI and MCP tools speak only v2. |
| API2-02 | Conventions are uniform. | A contract test walks every method in the catalog and checks: lowercase UUIDs, no empty-string or zero placeholders, `expectedRevision` honoured (mismatch → `CONFLICT`), `idempotencyKey` accepted on every mutating method, list pagination, result shapes. |
| API2-03 | One error registry. | A test fails if a code used in `Sources/` is missing from the registry, this page, the CLI exit map or the MCP mapping. |
| API2-04 | Resources follow [Resources](resources.md). | Each resource's fields, states and redaction rules are covered by projection tests over a fake domain, including every machine kind and launch kind. |
| API2-05 | Methods follow [Methods](methods.md). | Each method has success, permission, scope (`NOT_FOUND`), revision-conflict and failure-safety tests (previous state retained on error). |
| API2-06 | Permissions follow [Permissions](permissions.md). | The capability table, composition rules, presets, scopes and grant editing are covered by `AuthorizationTests`; `tools/list` hides tools the grant can't use. |
| API2-07 | Events follow [Events](events.md). | Every event type is emitted by its source, redacted by scope and capability, replayable within the ring, and readable through `events.poll` and MCP. |
| API2-08 | Migration follows [Migration](migration.md). | Upgrading keeps every grant usable with mapped capabilities, `grants.json` becomes schema 2 with a backup, and nothing in v2 accepts v1 names. |
