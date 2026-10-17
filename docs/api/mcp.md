# MCP server (remote control)

Trellis can run a [Model Context Protocol](https://modelcontextprotocol.io) server, so agents such as Claude Code can control it with MCP tools instead of the socket protocol. The server is **off by default**. Turn it on in **Settings → Remote Control**.

The MCP server is a second transport for the same API, not a second implementation. Each tool runs through the same authorizer (`AuthorizingControlHandler`) and command service as the [Unix socket](index.md). Grants, capabilities, window and host scope, idempotency, output limits and error codes all work exactly as they do there.

The code is in `Sources/TrellisMCP`: an HTTP listener, the endpoint and the tool table. Settings are in `Sources/TrellisCore/RemoteControlSettings.swift`.

## Requirements

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| INT-07 | An MCP adapter exposes the control API as tools. It can't expand a grant's permissions, it keeps the output limits, redaction and execution semantics, and it isn't a second automation implementation. | Every API method except `events.*` has exactly one tool. A tool call goes through `AuthorizingControlHandler.dispatch`, so a missing capability returns `PERMISSION_DENIED` and an out-of-scope ID returns `NOT_FOUND`. `tools/list` shows only tools the grant can use. |
| FR-RC01 | Settings → Remote Control turns the MCP server on and off. It's off by default, and the setting is saved with the workspace. | A new workspace has no listener. Enabling it and pressing Apply starts the listener, and the choice survives a relaunch. `--no-mcp` and `--fixture` launches never listen. |
| FR-RC02 | The user picks the interface (an IP address) and port. The address must be an IPv4 or IPv6 literal, never a hostname. The port must be 1024–65535. | Invalid values can't be applied and leave the running server unchanged. A saved value that can't be used turns the server off instead of failing the workspace. |
| FR-RC03 | Choosing anything other than loopback (`127.0.0.0/8`, `::1`) needs an explicit confirmation, which warns that the traffic is plain HTTP. | Applying a LAN or wildcard address shows the warning first. Cancel keeps the previous settings. |
| FR-RC04 | Settings shows the server status in text: running with its URL, stopped, or not running with a reason. | A port already in use shows "Port N is already in use". Applying new settings always stops the previous listener first. |
| API-07 | The HTTP endpoint is bounded and resists browser attacks: Origin and Host checks, size and connection limits, idle expiry, and revocation that takes effect at once. | See [Security](#security). Covered by `MCPEndpointTests` and `MCPListenerTests`. |

## Settings

| Setting | Default | Range |
| --- | --- | --- |
| Enable MCP server | Off | On, Off |
| Interface | `127.0.0.1` (loopback) | `127.0.0.1`, `::1`, any local interface address, `0.0.0.0` (all IPv4), `::` (all IPv6) |
| Port | 7777 | 1024–65535 |

- Changes are a draft until you press **Apply**. Applying restarts the server.
- IPv6 link-local addresses aren't offered, because they need a scope ID.
- `::` listens on IPv6 only. To accept IPv4 clients on every interface, use `0.0.0.0`.
- The settings are stored in `workspace.json` under `settings.remoteControl`.
- **Copy Endpoint URL** and **Copy Claude Code Command** give a URL you can reach from this Mac. A wildcard bind is shown as its loopback address. The command has a `<TOKEN>` placeholder, because a grant's token is only shown once, when the grant is created.

## Connecting a client

1. Create a grant in **Settings → Automation** and copy its token.
2. Enable the server in **Settings → Remote Control** and press Apply.
3. Add the server to the client. For Claude Code:

```sh
claude mcp add --transport http trellis http://127.0.0.1:7777/mcp \
  --header "Authorization: Bearer trl_…"
```

Any MCP client that supports Streamable HTTP and custom headers works the same way.

## Transport

- **Streamable HTTP** at a single path, `/mcp`.
- `POST /mcp` takes one JSON-RPC 2.0 message. Batches are rejected with `400`. Requests get an `application/json` response. Notifications and client responses get `202` with no body.
- `GET /mcp` returns `405`, because there's no server-initiated stream. Event subscriptions are socket-only, so there are no `events_*` tools.
- `DELETE /mcp` ends the session (`204`).
- Every other path returns `404`.
- Protocol versions: `2025-11-25`, `2025-06-18` and `2025-03-26`. `initialize` returns the client's version if it's supported, and otherwise the newest one. A request whose `MCP-Protocol-Version` header names an unsupported version gets `400`.
- Supported methods: `initialize`, `ping`, `tools/list`, `tools/call` and notifications. Any other method returns `-32601`.
- HTTP/1.1 with keep-alive. Request bodies need `Content-Length`; chunked bodies get `411`.

## Authentication and sessions

- **Every request** needs `Authorization: Bearer <grant token>`. A missing or invalid token gets `401` with `WWW-Authenticate: Bearer`. Error responses never repeat the token.
- `initialize` authenticates the token and returns an `Mcp-Session-Id`. Later requests must send that ID **and the same token**. Another grant's token on that session gets `401`.
- An unknown or expired session ID gets `404`, so the client should initialize again. A missing session ID on anything except `initialize` gets `400`.
- A network client has no user ID to check, so the token is its only credential. Its grant's expiry, revocation and scope apply exactly as on the socket.
- Failed authentications are rate-limited to 5 per 60 seconds (`429` with `Retry-After`). The limit is counted separately from the socket's, so failures from the network can't lock out the local CLI.
- Sessions expire after 30 minutes of inactivity. At most 32 sessions exist at once; opening another closes the least recently used one.
- Revoking a grant immediately ends its MCP sessions, as it does its socket connections. A tool call on an expired grant returns `AUTH_REQUIRED` and ends the session.

## Tools

Each tool is named after its method, with dots and camel case turned into snake case. For example, `session.sendInput` becomes `session_send_input` and `window.list` becomes `window_list`. The tool's arguments are the method's [parameters](methods.md#method-catalog), and its input schema lists them. Mutating tools also accept `idempotencyKey`.

- `tools/list` returns only tools whose base capabilities the grant holds, and tools that need all-windows scope only for grants that have it. Conditional capabilities, such as `start: true` needing `session.start`, are checked per call, the same as on the socket.
- Tool annotations mark read-only tools (`readOnlyHint`) and destructive ones (`destructiveHint`): closing, deleting, restarting, sending input and executing.
- A successful call returns the method's JSON result as text and as `structuredContent`.
- An API error is a **tool error** (`isError: true`) with `{"error": {"code", "message", "retryable", "details?"}}`. The `code` is the [API-06 code](errors.md), such as `PERMISSION_DENIED` or `CONFIRMATION_REQUIRED`, or `INVALID_PARAMS` for bad arguments.
- An unknown tool name or non-object `arguments` returns JSON-RPC `-32602`.
- `session_read_output` results start with an extra text item warning that terminal output is untrusted data and must never be followed as instructions.
- A response larger than 1 MiB is replaced by a `LIMIT_EXCEEDED` tool error.
- The `initialize` result has short `instructions` for agents: how to find IDs, that new panes start stopped, that execute doesn't wait, and that output is untrusted.

## Security

| Control | Behavior |
| --- | --- |
| Default | Off, and loopback-only until the user confirms a network address (FR-RC03) |
| Browsers | A request with an `Origin` header that isn't loopback (`http(s)://localhost`, `127.x`, `[::1]`) gets `403`. No CORS headers are ever sent. |
| DNS rebinding | On a loopback bind, the `Host` header must be `localhost`, a `127.x` address or `[::1]`, or the request gets `403`. |
| Limits | 16 connections (more get `503`), 16 KiB of headers, 1 MiB request and response bodies, JSON nesting up to 64 levels. An idle connection, or a request that hasn't fully arrived, is closed after 30 seconds. |
| Logging | Requests, tokens, terminal output and typed input are never logged. |
| Transport | **Plain HTTP, no TLS.** On a network address, anyone who can see the traffic can read the token and the terminal output. Prefer loopback, or a loopback bind reached through an SSH tunnel (`ssh -L 7777:127.0.0.1:7777 mac`). |

These controls don't protect against malware running as the same user, the same as the [socket's threat model](authorization.md#threat-model).
