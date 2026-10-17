# Automation API

Trellis has a local control API, protocol version 1, for scripts and agents. The [`trellis` CLI](cli.md) is a thin client over the same API. Every API call goes through the same command service as the UI, so the API can't do anything the UI's invariants forbid, and the UI and API always end up with equivalent domain state.

The server lives in `Sources/TrellisControl`, and domain dispatch is in `Sources/TrellisUI/AutomationService.swift`.

| Page | Contents |
| --- | --- |
| This page | Transport, framing, discovery and authentication |
| [Authorization](authorization.md) | Grants, capabilities and resource scope |
| [Methods](methods.md) | Resource conventions, revisions, idempotency and the full method catalog |
| [Output and events](output-events.md) | Reading terminal output, cursors, subscriptions and gaps |
| [Errors](errors.md) | JSON-RPC and application error codes |
| [Layouts](layouts.md) | Declarative layout documents and the validate → plan → apply flow |
| [CLI](cli.md) | The `trellis` command-line client |

## Transport (API-01)

- JSON-RPC 2.0 over a Unix-domain socket. There is no TCP listener.
- Each message is one UTF-8 JSON object followed by a newline. Newlines inside strings must be escaped, as JSON requires.
- The maximum frame size is **1 MiB**, for both requests and responses. A response that would be larger returns `LIMIT_EXCEEDED`.
- JSON nesting is limited to 64 levels, and method names to 128 bytes.
- Batch requests aren't supported.
- Mutating methods need a request `id`. A notification (a request without an `id`) for a mutating method is rejected with `-32600`.
- Malformed framing or invalid UTF-8 gets a best-effort error, and then the connection is closed.
- The server accepts up to 16 concurrent connections.

## Discovery

On startup the app publishes a discovery file and a socket:

| Item | Location | Notes |
| --- | --- | --- |
| Discovery file | `<state-dir>/control.json` | Mode `0600`, replaced atomically. Fields: `protocolVersion` (1), `instanceID` and `socketPath`. **Contains no token.** |
| Runtime directory | `$TMPDIR/trellis-<12 hex>` | Per-user temporary directory, mode `0700`, random name |
| Socket | `<runtime-dir>/s` | Mode `0600`, path ≤ 103 bytes to respect the `sun_path` limit |

`<state-dir>` defaults to `~/Library/Application Support/dev.trellis` (`dev.trellis.dev` for development builds of the app). You can override it with `--state-directory` on both the app and the CLI.

Endpoint safety rules:

- Symlinked endpoints are rejected, and Trellis never follows or overwrites another user's socket.
- The peer's UID must match the server's effective UID.
- Trellis removes a stale socket and discovery file only after a connection probe fails. If a live instance answers, the new instance refuses to start its server. Running several independent app instances is outside the MVP.

The CLI finds the running app through `control.json`. It starts the app only when given `--launch`; otherwise it fails with `APP_NOT_RUNNING`. An app started this way is an ordinary native app.

## Authentication (API-02)

The first request on every connection must be `auth.authenticate`:

```json
{"jsonrpc":"2.0","id":1,"method":"auth.authenticate","params":{"protocolVersion":1,"token":"trl_…"}}
```

The result describes the connection:

```json
{"connectionId":"…","grantId":"…","expiresAt":"…","capabilities":["metadata.read","layout.write"],"windowScope":"all","protocolVersion":1}
```

- Any other method called before authentication returns `AUTH_REQUIRED`. The exception is `system.info`, which needs no capability but still requires an authenticated connection.
- Authentication checks the peer's UID as well as the token.
- Failed authentication is rate-limited to 5 failures per 60 seconds across all connections, after which calls return a retryable `LIMIT_EXCEEDED`. Tokens are never echoed back.
- Grant expiry and revocation are checked again on every call. Revoking a grant immediately closes its connections and subscriptions, and an expired connection has to authenticate again.

Grants are created in **Settings → Automation**. How tokens are stored and scoped is covered in [Authorization](authorization.md).

## A minimal session

```sh
# The token is shown once when the grant is created. Keep it in an owner-only file.
trellis system info --token-stdin --json < ~/.config/trellis/token
trellis window list --token-stdin --json < ~/.config/trellis/token
```

Talking to the socket directly works the same way: read `socketPath` from `control.json`, connect, send `auth.authenticate`, and then send requests one line at a time.

## Contract acceptance

Every change to the API should keep these behaviors covered by tests:

- unauthenticated and expired clients
- cross-scope IDs
- host revision changes
- stale mutations
- malformed frames
- over-limit input
- event gaps
- disconnects while a command is being submitted

Applying the [example layout](example-layout.json) twice must return identical resource IDs and launch no duplicate processes.
