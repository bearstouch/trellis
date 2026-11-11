# Authorization

Every automation client authenticates with a **grant**. The user creates and edits grants in **Settings → Automation**. A grant combines a set of capabilities, a space scope, a host scope and an expiry. Authorization is enforced at the service boundary (`AuthorizationPolicy` in `Sources/TrellisControl/Authorization.swift`), including for internal calls from adapters.

## Grants and tokens

| Property | Implementation |
| --- | --- |
| Token format | `trl_` followed by 32 random bytes in base64url without padding |
| Token storage | Keychain generic password: service `Trellis Automation`, account = grant UUID, accessibility *when unlocked, this device only* |
| Grant metadata | `<state-dir>/grants.json`, mode `0600`, written atomically. Stores only `sha256:<hex>` of the token, which is compared in constant time. |
| File format | Schema 2: `{"schemaVersion": 2, "grants": [...]}`. Each grant has `id`, `name`, `tokenHash`, `preset`, `revision`, `capabilities` (stored under their protocol 2 names: `workspace.read` for `metadata.read`, `workspace.write` for `layout.write`, the others unchanged), `scope` (`spaces`, `projects`, `hosts`, `agents`), `createdSpaces`, `createdAt`, `expiresAt` and `revokedAt`. |
| Upgrade | A schema 1 file (a bare array with `windowScope`) is migrated once: it is copied byte for byte to `grants.json.v1.bak` (mode `0600`), then replaced. Every grant keeps its token, expiry and scopes and gets exactly the mapped capabilities, never more; protocol 1 sees it exactly as before. An earlier release can't read schema 2 (it shows no grants and writes nothing); restore the backup to use the old grants there. |
| Lifetime | Between 60 seconds and 90 days. The UI offers 1 hour, 1 day (default), 7, 30 and 90 days. |
| Revocation | Takes effect immediately: open connections and subscriptions are closed. Revoked and expired grants stay in the file for the record. |
| Editing | Name, capabilities, scopes and expiry can be changed; the token can't. See [Editing grants](#editing-grants). |

The token is shown only once, in the grant-creation flow. If `grants.json` can't be read, or has a newer `schemaVersion`, or names a capability or scope this build doesn't know, Trellis preserves it, marks the store read-only, and treats no grant as active.

Tokens never go on a command line. The CLI reads the token from standard input (`--token-stdin`) or from the Keychain (`--keychain-grant GRANT_UUID`), and it rejects `--token`, `--password` and `--secret`. Tokens never go into environment variables that shells inherit, either; launched sessions have Trellis control variables removed from their environment.

## Presets and editing grants

The grant sheet leads with presets. Each one sets its capabilities and a starting scope, which you can still change:

| Preset | What it can do (protocol 1 names) | Starting scope |
| --- | --- | --- |
| **Observer** | `metadata.read`, `session.output.read`, `host.read`, `theme.read`, plus reading projects and tasks (protocol 2) | all spaces and hosts |
| **Operator** | Observer + `layout.write`, `session.start`, `session.input`, `session.close`, plus running tasks (protocol 2) | all spaces, approved hosts |
| **Agent orchestrator** | Operator, plus agent, project and remote workspace capabilities that only protocol 2 uses | only spaces this grant creates, approved hosts |
| **Full control** | every capability | everything |
| **Custom** | what you choose | what you choose |

Custom lists every capability grouped by area, described in plain language with the capability name underneath; changing any capability turns a preset into Custom. Some capabilities belong to areas only protocol 2 (in development) uses: agents, remote workspaces, projects and tasks. Protocol 1 doesn't see them, and a grant's v1 `capabilities` list only the v1 ones it holds.

### Editing grants

**Edit…** next to an active grant opens the same form.

- **Narrowing** (removing a capability, narrowing a scope, an earlier expiry) applies at once. Subscriptions the grant no longer allows end, MCP sessions of the grant end, and every open connection gets `AUTH_REQUIRED` on its next call, so the client authenticates again and sees the new limits.
- **Widening** (adding a capability or scope, a later expiry) asks for confirmation first; **Cancel** leaves the grant exactly as it was. Open connections keep working and get the new access on their next call.
- **Reapprove** next to a changed host refreshes host approvals as before.

## Capabilities

| Capability | Grants access to |
| --- | --- |
| `metadata.read` | List authorized resources and their states. Doesn't reveal working directories, executable arguments or host identity without the matching read permission. |
| `layout.write` | Create stopped spaces, tabs and panes; rename, reorder, split, resize and focus; apply layouts |
| `session.start` | Start a stopped session with the default shell or an approved saved host |
| `session.input` | Send literal terminal input, including control bytes. **This is equivalent to command-execution authority in that pane.** |
| `session.execute` | Start arbitrary executables or submit shell commands; set the launch environment and directory |
| `session.output.read` | Read the screen, scrollback and output events |
| `session.close` | End sessions and close containers that hold running sessions |
| `theme.read` | Read installed themes and global appearance settings |
| `theme.write` | Import, replace and delete custom themes and change appearance. Requires all-spaces scope. |
| `host.read` | Read saved host metadata, including aliases and identity-file references |
| `host.write` | Create, update and delete host metadata. Creating a host also needs `session.execute`. |

`clipboard.read` and `clipboard.write` are reserved for a future clipboard API and don't exist in v1. Agents get no clipboard access.

## Scope

- **Space scope** is either `all` or an explicit set of space IDs. Tabs, panes and sessions created inside a scoped space inherit its scope.
- A grant made for protocol 2 can have the **only spaces this grant creates** scope (`created`, the Agent orchestrator preset). Protocol 1 treats it as the set of spaces the grant has created through protocol 2 so far: `spaceScope` in the `auth.authenticate` result lists them, and since creating a space needs all-spaces scope in protocol 1, a protocol 1 client can't add to it.
- These operations require **all-spaces** scope: creating a new top-level space, reordering spaces, `layout.apply`, and all theme and appearance writes.
- **Host scope** is either `all` or a set of approved hosts. Each approval is bound to the host's *connection revision*. If a host's destination or another launch-affecting field changes, the call returns `PERMISSION_DENIED` until the user approves the host again.
- **Out-of-scope IDs return `NOT_FOUND`**, exactly as if they didn't exist, so a client can't discover resources it isn't allowed to see. Metadata events are redacted the same way; for example, `space.*` events go only to grants with all-spaces scope.

## How capabilities compose

| Operation | Required |
| --- | --- |
| Start a pane with its saved shell or approved host | `session.start` |
| Start with an arbitrary launch descriptor (`kind: process`, a directory, arguments, environment) | `session.start` + `session.execute` |
| Connect a saved host | `session.start` + `layout.write`, and both the host and the space must be in scope |
| Create a host | `host.write` + `session.execute`, because a new host chooses where ssh connects and is connectable at once with all-hosts scope |
| Change a host's destination, user, port or identity file | `host.write` + `session.execute`. Clearing one with `null` counts as a change. Changing only the name or tags needs just `host.write`. |
| Close a container that holds running sessions (`allowRunning` or `force`) | `layout.write` + `session.close` |
| Create with `start: true`, or apply with `startNew: true` | The creating capability + `session.start` |
| Subscribe to output events | `metadata.read` + `session.output.read` |
| Subscribe to appearance events | `metadata.read` + `theme.read` |

`layout.export` returns launch details only to grants that hold execute permission, and host references only to grants with host-read permission. Without them those fields are left out, and the result is marked as a redacted inspection document that can't be imported. `layout.validate` and `layout.plan` never expose existing resources outside the grant.

## Network clients (MCP)

The [MCP server](mcp.md) uses the same grants. A network client has no peer user ID, so its bearer token is its whole credential. Capabilities, scope, expiry and revocation apply exactly as on the socket. Network authentication failures have their own rate limit, so they can't lock out the local socket. Clients that connect over a tailnet through **Share over Tailscale** use grants the same way. Give each client its own grant; the allowed-devices list only decides which tailnet devices can reach the endpoint at all ([FR-RC09](mcp.md#requirements)).

## Untrusted output

No permission ever comes from terminal text. Output is untrusted data, and that includes text that seems to ask an agent to change its permissions or run something. A client that can list metadata can't assume it may also read or control every pane.

## Threat model

These controls protect against accidental and unauthorized access by *other clients*. Malware running as the same user is outside any strong isolation guarantee, and nothing here can make a compromised user account safe.
