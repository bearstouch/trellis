# Authorization

Every automation client authenticates with a **grant**. The user creates grants in **Settings → Automation**. A grant combines a set of capabilities, a window scope, a host scope and an expiry. Authorization is enforced at the service boundary (`AuthorizationPolicy` in `Sources/TrellisControl/Authorization.swift`), including for internal calls from adapters.

## Grants and tokens

| Property | Implementation |
| --- | --- |
| Token format | `trl_` followed by 32 random bytes in base64url without padding |
| Token storage | Keychain generic password: service `Trellis Automation`, account = grant UUID, accessibility *when unlocked, this device only* |
| Grant metadata | `<state-dir>/grants.json`, mode `0600`, written atomically. Stores only `sha256:<hex>` of the token, which is compared in constant time. |
| Grant fields | `id`, `name`, `tokenHash`, `capabilities`, `windowScope`, `hostScope`, `createdAt`, `expiresAt`, `revokedAt` |
| Lifetime | Between 60 seconds and 90 days. The UI offers 1 hour, 1 day (default), 7, 30 and 90 days. |
| Revocation | Takes effect immediately: open connections and subscriptions are closed. Revoked and expired grants stay in the file for the record. |

The token is shown only once, in the grant-creation flow. If `grants.json` can't be read, Trellis preserves it, marks the store read-only, and treats no grant as active.

Tokens never go on a command line. The CLI reads the token from standard input (`--token-stdin`) or from the Keychain (`--keychain-grant GRANT_UUID`), and it rejects `--token`, `--password` and `--secret`. Tokens never go into environment variables that shells inherit, either; launched sessions have Trellis control variables removed from their environment.

## Capabilities

| Capability | Grants access to |
| --- | --- |
| `metadata.read` | List authorized resources and their states. Doesn't reveal working directories, executable arguments or host identity without the matching read permission. |
| `layout.write` | Create stopped windows, tabs and panes; rename, reorder, split, resize and focus; apply layouts |
| `session.start` | Start a stopped session with the default shell or an approved saved host |
| `session.input` | Send literal terminal input, including control bytes. **This is equivalent to command-execution authority in that pane.** |
| `session.execute` | Start arbitrary executables or submit shell commands; set the launch environment and directory |
| `session.output.read` | Read the screen, scrollback and output events |
| `session.close` | End sessions and close containers that hold running sessions |
| `theme.read` | Read installed themes and global appearance settings |
| `theme.write` | Import, replace and delete custom themes and change appearance. Requires all-windows scope. |
| `host.read` | Read saved host metadata, including aliases and identity-file references |
| `host.write` | Create, update and delete host metadata |

`clipboard.read` and `clipboard.write` are reserved for a future clipboard API and don't exist in v1. Agents get no clipboard access.

## Scope

- **Window scope** is either `all` or an explicit set of window IDs. Tabs, panes and sessions created inside a scoped window inherit its scope.
- These operations require **all-windows** scope: creating a new top-level window, reordering windows, `layout.apply`, and all theme and appearance writes.
- **Host scope** is either `all` or a set of approved hosts. Each approval is bound to the host's *connection revision*. If a host's destination or another launch-affecting field changes, the call returns `PERMISSION_DENIED` until the user approves the host again.
- **Out-of-scope IDs return `NOT_FOUND`**, exactly as if they didn't exist, so a client can't discover resources it isn't allowed to see. Metadata events are redacted the same way; for example, `window.*` events go only to grants with all-windows scope.

## How capabilities compose

| Operation | Required |
| --- | --- |
| Start a pane with its saved shell or approved host | `session.start` |
| Start with an arbitrary launch descriptor (`kind: process`, a directory, arguments, environment) | `session.start` + `session.execute` |
| Connect a saved host | `session.start` + `layout.write`, and both the host and the window must be in scope |
| Change a host's destination, user, port or identity file | `host.write` + `session.execute`. Changing only the name or tags needs just `host.write`. |
| Close a container that holds running sessions (`allowRunning` or `force`) | `layout.write` + `session.close` |
| Create with `start: true`, or apply with `startNew: true` | The creating capability + `session.start` |
| Subscribe to output events | `metadata.read` + `session.output.read` |
| Subscribe to appearance events | `metadata.read` + `theme.read` |

`layout.export` returns launch details only to grants that hold execute permission, and host references only to grants with host-read permission. Without them those fields are left out, and the result is marked as a redacted inspection document that can't be imported. `layout.validate` and `layout.plan` never expose existing resources outside the grant.

## Network clients (MCP)

The [MCP server](mcp.md) uses the same grants. A network client has no peer user ID, so its bearer token is its whole credential. Capabilities, scope, expiry and revocation apply exactly as on the socket. Network authentication failures have their own rate limit, so they can't lock out the local socket.

## Untrusted output

No permission ever comes from terminal text. Output is untrusted data, and that includes text that seems to ask an agent to change its permissions or run something. A client that can list metadata can't assume it may also read or control every pane.

## Threat model

These controls protect against accidental and unauthorized access by *other clients*. Malware running as the same user is outside any strong isolation guarantee, and nothing here can make a compromised user account safe.
