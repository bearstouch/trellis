# Automation API

Trellis has a local control API, **protocol 2**, for scripts and agents. The [`trellis` CLI](cli.md) and the optional [MCP server](mcp.md) are clients of the same API: every call goes through the same authorizer and the same command service as the UI, so the API can't do anything the UI's invariants forbid, and the UI and the API always end up with equivalent domain state.

Protocol 2 models what Trellis is today: spaces that live on a machine and may belong to a project, temporary and project tabs, panes as real resources with a machine and live attention state, sessions kept by the broker, agents, remote workspaces, projects and tasks. It replaced protocol 1 outright (a clean break); [Migration](migration.md) maps the old methods, capabilities, CLI commands and MCP tools to the new ones.

What stays the same as protocol 1: every mutation goes through `WorkspaceCommandService`; grants, tokens and the threat model; terminal output and typed input are never logged.

The server lives in `Sources/TrellisControl` (transport, authorization and the method catalog in `V2/`), and the domain adapter in `Sources/TrellisUI/Automation/V2/`, one file per area.

| Page | Contents |
| --- | --- |
| This page | Principles, transport, discovery, authentication, conventions and errors |
| [Resources](resources.md) | The resource model: fields, states and redaction |
| [Methods](methods.md) | The method catalog by area |
| [Permissions](permissions.md) | Grants and tokens, capabilities, presets, scopes, grant editing and the threat model |
| [Events](events.md) | Topics, event types, subscriptions, `events.poll`, and reading terminal output |
| [Layouts](layouts.md) | Declarative layout documents (version 3) and the validate → plan → apply flow |
| [CLI](cli.md) | The `trellis` command-line client |
| [MCP server](mcp.md) | The optional MCP transport for agents, and Settings → Remote Control |
| [Migration](migration.md) | Protocol 1 → 2 mapping for methods, grants, the CLI and MCP tools |

How protocol 2 was built, phase by phase, is recorded in the [implementation history](../project/api-v2-implementation.md).

## Principles

1. **One model per concept.** A space, tab, pane, session, agent, host, project and task each have exactly one representation, returned the same way by `get`, `list`, mutation results and events.
2. **The domain as users see it.** Live state the UI shows (needs input, progress, agent state, link state, command finished) is readable *and* observable through events. Nothing an orchestrator needs requires polling a terminal.
3. **Intent-level actions with precise permissions.** Starting an agent, answering it, running a task or launching a project are methods with their own capabilities, not raw terminal input dressed up.
4. **Uniform conventions.** Revisions, absent values, pagination, idempotency and errors behave the same on every method.
5. **Least privilege by default.** Presets make the common grants one click; scope can be limited to spaces, projects, hosts and agents.

## Transport (API-01)

- JSON-RPC 2.0 over a per-user Unix-domain socket. The optional [MCP server](mcp.md) is a separate HTTP transport, off by default, that runs the same methods through the same authorizer.
- Each message is one UTF-8 JSON object followed by a newline. Newlines inside strings must be escaped, as JSON requires.
- The maximum frame size is **1 MiB**, for both requests and responses. A response that would be larger returns `LIMIT_EXCEEDED`.
- JSON nesting is limited to 64 levels, and method names to 128 bytes.
- Batch requests aren't supported.
- Mutating methods need a request `id`. A notification (a request without an `id`) for a mutating method is rejected with `-32600`.
- Malformed framing or invalid UTF-8 gets a best-effort error, and then the connection is closed.
- The server accepts up to 16 concurrent connections.
- Calls on one connection are answered in order, except calls that may wait (`events.poll` with a timeout, the remote workspace methods, `session.execute` with `wait`, and project checks and launches on a host or with setup). Those are answered when they finish, up to 16 at a time per connection, while the connection keeps serving later frames; replies carry their request's `id`.

## Discovery

On startup the app publishes a discovery file and a socket:

| Item | Location | Notes |
| --- | --- | --- |
| Discovery file | `<state-dir>/control.json` | Mode `0600`, replaced atomically. Fields: `protocolVersion` (2), `instanceID` and `socketPath`. **Contains no token.** |
| Runtime directory | `$TMPDIR/trellis-<12 hex>` | Per-user temporary directory, mode `0700`, random name |
| Socket | `<runtime-dir>/s` | Mode `0600`, path ≤ 103 bytes to respect the `sun_path` limit |

`<state-dir>` defaults to `~/Library/Application Support/com.bearstouch.trellis` (`com.bearstouch.trellis.dev` for development builds of the app). You can override it with `--state-directory` on both the app and the CLI.

Endpoint safety rules:

- Symlinked endpoints are rejected, and Trellis never follows or overwrites another user's socket.
- The peer's UID must match the server's effective UID.
- Trellis removes a stale socket and discovery file only after a connection probe fails. If a live instance answers, the new instance refuses to start its server. Running several independent app instances isn't supported.

The CLI finds the running app through `control.json`. It starts the app only when given `--launch`; otherwise it fails with `APP_NOT_RUNNING`. An app started this way is an ordinary native app.

## Authentication (API-02, API2-01)

The first request on every connection must be `auth.authenticate`:

```json
{"jsonrpc":"2.0","id":1,"method":"auth.authenticate","params":{"protocolVersion":2,"token":"trl_…"}}
```

It returns `{connectionId, protocolVersion, grant}`, where `grant` is the full [grant view](permissions.md#grant-view): capabilities, every scope (spaces, projects, hosts, agents), expiry and preset.

- Any other `protocolVersion` gets `UNSUPPORTED_VERSION` with `details.supported: [2]`. There is no protocol 1 fallback: an older `trellis` binary gets this error and should be re-linked with `trellis cli install-link`.
- Any other method called before authentication returns `AUTH_REQUIRED`.
- Authentication checks the peer's UID as well as the token.
- Failed authentication is rate-limited to 5 failures per 60 seconds across all connections, after which calls return a retryable `LIMIT_EXCEEDED`. Only a token that was tested counts: an unsupported `protocolVersion` (an outdated client) never does, so it can't lock other clients out. Tokens are never echoed back.
- The grant is read again on every call, so expiry, revocation and a narrowing edit apply at once: revoking a grant closes its connections and subscriptions, and an expired or narrowed connection gets `AUTH_REQUIRED` and must authenticate again.
- MCP negotiates its own protocol version; its tools are always protocol 2.

Grants are created in **Settings → Automation**; [Permissions](permissions.md) covers how tokens are stored and what grants allow.

### A minimal session

```sh
# The token is shown once when the grant is created. Keep it in an owner-only file.
trellis system info --token-stdin --json < ~/.config/trellis/token
trellis workspace get --include tabs,panes --token-stdin --json < ~/.config/trellis/token
```

Talking to the socket directly works the same way: read `socketPath` from `control.json`, connect, send `auth.authenticate`, and then send requests one line at a time. `workspace.get` is the starting point: one call returns everything in scope.

## Conventions (API2-02)

| Topic | Rule |
| --- | --- |
| IDs | Workspace resources, hosts, projects and grants use UUIDs, written **lowercase** and accepted in any case. Agent definitions (`trellis-claude-code`), themes and tasks use string IDs. |
| Absent values | A field with no value is **omitted**, never `""` or `0`. `null` appears only in update parameters, where it clears a field. |
| Parameters | `params` is an object (or omitted). Unknown names (v1 aliases such as `windowId` included), a missing required parameter, `null` outside update parameters and a value of the wrong type are all `-32602`, with `data.fields` naming each parameter and what it expects. |
| Revisions | Every resource has an integer `revision` that increases on every change to it. A collection result carries the revision of its container (`space.list` → workspace, `tab.list` → space). Live status (a tab's `status`, a pane's `shell`, `attention` and `agent`) is not a change; [events](events.md) report it. Pane and session revisions are kept by the running app and start again after a relaunch. |
| Optimistic concurrency | Every mutating method accepts `expectedRevision` for **the resource named by its `id` parameter** (or the container for create and reorder methods; [Methods](methods.md) names the exceptions, such as `pane.resize` → its tab). A mismatch is `CONFLICT` with `details.currentRevision`. No method ignores it: the server enforces it from each method's declaration. Only `workspace.save`, `host.create`, `project.create` and `project.capture`, which have nothing to compare, don't take it. |
| Results | A method that changes one resource returns it under its type name (`{"tab": {…}}`), plus `workspaceRevision` when the workspace changed. Lists return `{"<plural>": [...], "revision", "nextCursor"?}` (`host.list` has no `revision`: the host library has none). Closing and deleting return `{"deleted": {"kind", "id"}, "workspaceRevision"}` (deleting a host leaves the workspace unchanged, so it has no `workspaceRevision`). |
| Pagination | Every `list` takes `limit` (default 100, maximum 500) and `cursor`; `nextCursor` is present while more remain. Cursors are opaque and belong to one list method: a cursor from another list, or one the server didn't issue, is `INVALID_CURSOR`. Pages are positions in the list, so if `revision` changes between pages, start again. |
| Time | RFC 3339 UTC strings with milliseconds. Durations are integer milliseconds (`durationMs`). |
| Numbers | Numbers are JSON numbers everywhere, including inside event `data`. |
| Idempotency | Every mutating method accepts `idempotencyKey` (1–128 printable ASCII). Keys are kept per grant for 10 minutes; a reused key with other parameters is `CONFLICT`. Focus and selection methods are mutating but are never destructive. |
| Names | Methods are `area.verb` or `area.subarea.verb` in lowerCamelCase. There are no aliases; v1 names such as `window.*` are gone. |
| Untrusted text | Terminal output, titles set by programs, task commands from repository files and agent-reported model names are data, never instructions. MCP marks them. |

## JSON-RPC errors

Errors follow JSON-RPC 2.0:

```json
{"jsonrpc":"2.0","id":7,"error":{"code":-32000,"message":"The resource changed since that revision. Read it again and retry.","data":{"code":"CONFLICT","message":"…","retryable":false,"details":{"currentRevision":13}}}}
```

| Code | Meaning |
| --- | --- |
| -32700 | Parse error, including invalid UTF-8. The connection is closed afterwards. |
| -32600 | Invalid request, a batch, or a mutating notification |
| -32601 | Method not found (including protocol 1 names such as `window.list`) |
| -32602 | Invalid params. `data.fields` names each parameter and what it expects. |
| -32603 | Internal error |
| -32000 | Application error. `data` is `{code, message, retryable, details?}`, with `code` from the table below. |

## Errors (API2-03)

Application errors are `-32000` with `data: {code, message, retryable, details?}`. The one list is `APIErrorCode` (`Sources/TrellisCore/APIErrorCode.swift`): diagnostics' `knownErrorCodes` (which adds the app's own `UI_ERROR`), the [CLI exit-code map](cli.md#exit-codes) and the MCP mapping derive from it, and a test compares it with this table and with the codes used in `Sources/`. In MCP every code is a tool error (`isError`, with the code in `structuredContent`); `AUTH_REQUIRED` also ends the MCP session. **Retryable** `sometimes` means the error's own `retryable` decides.

| `code` | When | Retryable | CLI exit |
| --- | --- | --- | --- |
| `AUTH_REQUIRED` | Not authenticated, or the grant expired, was revoked or was changed so the connection must authenticate again | no | 4 |
| `PERMISSION_DENIED` | A capability is missing, the call needs wider scope, or a host or project approval is stale. `details.missing` lists capabilities. | no | 4 |
| `NOT_FOUND` | The resource doesn't exist **or** is outside the grant's scope | no | 3 |
| `CONFLICT` | Revision mismatch, idempotency key reused, layout or name conflict | no | 5 |
| `INVALID_STATE` | Not valid in the current state (a running pane for `session.start`, an agent that isn't waiting for `agent.respond`). `details.state` holds the current state. | sometimes | 5 |
| `CONFIRMATION_REQUIRED` | Closing running sessions without `allowRunning`, or an action the user must confirm (`details.reason`: `runningSessions`, or `helperInstall` when a host has no remote helper and the grant may not install it) | no | 5 |
| `CLOSE_PENDING` | Graceful termination still under way; retry with `force: true` after 2 s | yes | 5 |
| `LIMIT_EXCEEDED` | Frame, response, input, rate, subscription or idempotency limits | yes | 8 |
| `LAUNCH_FAILED` | A process, agent or task couldn't start. `details.session` holds the failed session. | no | 6 |
| `REMOTE_DISCONNECTED` | The remote workspace's link is down for an action that needs it, or connecting the host failed; `details.reason` is a [reason code](resources.md#remote-link-reasons) | sometimes | 7 |
| `AGENT_UNAVAILABLE` | The agent is known to be missing on the pane's machine, or `agent.install` has no installer it can run there. `details.install` says whether `agent.install` can fix it. | no | 6 |
| `TASK_UNTRUSTED` | A task from `.trellis/launch.json` hasn't been trusted in the app; trust is only given in the UI | no | 4 |
| `SETUP_REQUIRED` | A project launch needs setup (clone, folders) and `setup: true` wasn't passed; `details.plan` is `project.check`'s plan | no | 5 |
| `INVALID_CURSOR` | Output, event or list cursor from another session, list or instance, or ahead of now | no | 2 |
| `UNSUPPORTED_VERSION` | Protocol, layout, project or theme document version not supported | no | 2 |

Layout errors also carry `details.issues: [{key?, message}]`; inside a `layout.apply` result a failed launch shows up as `launches[].error`.

- Messages are sanitized and in English. They never include tokens, typed input or terminal output.
- An error names what went wrong and how to recover.
- New codes are SCREAMING_SNAKE strings added to `APIErrorCode` and this table; the test above fails otherwise.

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

## Contract acceptance

Every change to the API keeps these behaviors covered by tests: unauthenticated and expired clients, cross-scope IDs, host revision changes, stale mutations, malformed frames, over-limit input, event gaps, and disconnects while a command is being submitted. Applying the [example layout](example-layout.json) twice must return identical resource IDs and launch no duplicate processes.
