# MCP server (remote control)

Trellis can run a [Model Context Protocol](https://modelcontextprotocol.io) server, so agents such as Claude Code can control it with MCP tools instead of the socket protocol. The server is **off by default**. Turn it on in **Settings → Remote Control**.

The MCP server is a second transport for the same API, not a second implementation. Each tool runs through the same authorizer (`AuthorizingControlHandler`) and command service as the [Unix socket](index.md). Grants, capabilities, space and host scope, idempotency, output limits and error codes all work exactly as they do there.

The code is in `Sources/TrellisMCP`: an HTTP listener, the endpoint, the tool table and the Tailscale sharing coordinator (`TailscaleSharing.swift`). Settings are in `Sources/TrellisCore/RemoteControlSettings.swift`, and the Tailscale CLI wrapper is in `Sources/TrellisCore/Tailscale.swift`.

## Requirements

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| INT-07 | An MCP adapter exposes the control API as tools. It can't expand a grant's permissions, it keeps the output limits, redaction and execution semantics, and it isn't a second automation implementation. | Every API method except `events.*` has exactly one tool. A tool call goes through `AuthorizingControlHandler.dispatch`, so a missing capability returns `PERMISSION_DENIED` and an out-of-scope ID returns `NOT_FOUND`. `tools/list` shows only tools the grant can use. |
| FR-RC01 | Settings → Remote Control turns the MCP server on and off. It's off by default, and the setting is saved with the workspace. | A new workspace has no listener. Enabling it and pressing Apply starts the listener, and the choice survives a relaunch. `--no-mcp` and `--fixture` launches never listen. |
| FR-RC02 | The user picks the interface (an IP address) and port. The address must be an IPv4 or IPv6 literal, never a hostname. The port must be 1024–65535. | Invalid values can't be applied and leave the running server unchanged. A saved value that can't be used turns the server off instead of failing the workspace. |
| FR-RC03 | Choosing anything other than loopback (`127.0.0.0/8`, `::1`) needs an explicit confirmation, which warns that the traffic is plain HTTP. | Applying a LAN or wildcard address shows the warning first. Cancel keeps the previous settings. |
| FR-RC04 | Settings shows the server status in text: running with its URL, stopped, or not running with a reason. | A port already in use shows "Port N is already in use". Applying new settings always stops the previous listener first. |
| API-07 | The HTTP endpoint is bounded and resists browser attacks: Origin and Host checks, size and connection limits, idle expiry, and revocation that takes effect at once. | See [Security](#security). Covered by `MCPEndpointTests` and `MCPListenerTests`. |
| FR-RC05 | Remote Control detects Tailscale and shows its state in words. | The Tailscale row says Not installed, Stopped, Needs sign-in, HTTPS off, or Connected with the Mac's MagicDNS name and tailnet address. A missing CLI, a stopped daemon, a slow answer (5 s limit) or unreadable JSON is reported without blocking Settings. An interface address in `100.64.0.0/10` or `fd7a:115c:a1e0::/48` is labelled Tailscale in the Interface picker. |
| FR-RC06 | **Share over Tailscale** publishes the loopback endpoint to the tailnet with `tailscale serve` (HTTPS), and removes it when sharing or the server is turned off, the port changes, or Trellis quits. | Apply runs `tailscale serve --bg --https=P http://127.0.0.1:M` only after Trellis's own listener has started, then reads the serve configuration back to confirm it. Turning sharing off runs `tailscale serve --https=P off` only while that port's single handler is still Trellis's proxy. A port someone else serves is refused (`Port P is already served by another app`) and left unchanged. Sharing needs a loopback interface and one of the HTTPS ports 443, 8443 or 10000. While Tailscale is stopped the status is "Waiting for Tailscale…" and sharing resumes without another Apply. |
| FR-RC07 | Trellis never exposes the server publicly. | Trellis never runs `tailscale funnel`. If Funnel is on for Trellis's entry, the entry is removed and the status says why. A proxied request from an address outside the tailnet ranges gets `403`. |
| FR-RC08 | On a loopback bind, requests that come through Trellis's `tailscale serve` entry are told apart from local ones and admitted only while sharing is on. | A request is proxied when its Host is the shared `name:port` (or the bare name on port 443) or it carries `X-Forwarded-For` or `X-Forwarded-Host`. A proxied request while sharing is off, or naming another `.ts.net` host, gets `403`. Local clients with a loopback Host are unaffected. The Origin rule is unchanged. |
| FR-RC09 | **Allowed devices** limits which tailnet devices can connect. | With devices chosen, a proxied request whose last `X-Forwarded-For` address isn't one of their Tailscale addresses, or that has none, gets `403` before authentication, so it doesn't count toward the authentication limit. A repeated `X-Forwarded-For` header is a `400`. Changing the list keeps MCP sessions and applies to the next request. Applying a change that lets more devices in (sharing turned on, a device added, or the list cleared to any device) asks for confirmation first. |

## Settings

| Setting | Default | Range |
| --- | --- | --- |
| Enable MCP server | Off | On, Off |
| Interface | `127.0.0.1` (loopback) | `127.0.0.1`, `::1`, any local interface address, `0.0.0.0` (all IPv4), `::` (all IPv6) |
| Port | 7777 | 1024–65535 |
| Share over Tailscale | Off | On, Off. Needs the server on and a loopback interface. |
| HTTPS port (Tailscale) | 8443 | 443, 8443, 10000 |
| Allowed devices | Any device in my tailnet | Any device, or a list of up to 64 tailnet devices |

- Changes are a draft until you press **Apply**. Applying restarts the server.
- IPv6 link-local addresses aren't offered, because they need a scope ID.
- `::` listens on IPv6 only. To accept IPv4 clients on every interface, use `0.0.0.0`.
- The settings are stored in `workspace.json` under `settings.remoteControl`.
- **Copy Endpoint URL** and **Copy Client Setup** give the tailnet URL while sharing over Tailscale, and otherwise a URL you can reach from this Mac. A wildcard bind is shown as its loopback address.
- **Copy Client Setup** offers a Claude Code command, a Codex `config.toml` block and a generic `mcpServers` JSON entry. None holds a token: they use a `<TOKEN>` placeholder, or the `TRELLIS_TOKEN` environment variable for Codex, because a grant's token is only shown once, when the grant is created.
- Allowed devices are saved with their names and Tailscale addresses, so the list still works while Tailscale's status can't be read. A device Tailscale lists now uses its current addresses.

## Connecting a client

1. Create a grant in **Settings → Automation** and copy its token.
2. Enable the server in **Settings → Remote Control** and press Apply.
3. Add the server to the client. For Claude Code:

```sh
claude mcp add --transport http trellis http://127.0.0.1:7777/mcp \
  --header "Authorization: Bearer trl_…"
```

Any MCP client that supports Streamable HTTP and custom headers works the same way.

## Connecting agents over a tailnet

Agents on other machines in your [Tailscale](https://tailscale.com) network (tailnet) can reach Trellis without opening a port or sending tokens in plain HTTP. Trellis keeps listening on loopback and asks Tailscale to publish that endpoint to the tailnet over HTTPS:

```
[tailnet device]  Claude Code, Codex, your own bot
      │  HTTPS with a Tailscale certificate, over WireGuard
      ▼
tailscaled on the Mac (tailscale serve, :8443)
      │  proxied with X-Forwarded-For = the device's 100.x address
      ▼
Trellis MCP at 127.0.0.1:7777/mcp
```

The Mac needs the Tailscale app, signed in, with MagicDNS and HTTPS certificates turned on for the tailnet (Tailscale admin console → DNS). Trellis only runs the `tailscale` CLI that ships with it: `/Applications/Tailscale.app/Contents/MacOS/Tailscale`, or `tailscale` in `/opt/homebrew/bin` or `/usr/local/bin`. The file must be owned by root or you and not writable by others.

1. **Create one grant per client** in **Settings → Automation**, for example "Claude Code on laptop", "Codex on build server" and "Grok bot". Give each the spaces and capabilities it needs; full control of one space is `metadata.read`, `layout.write`, `session.start`, `session.input`, `session.output.read`, `session.execute` and `session.close` scoped to that space. Separate grants can be revoked one at a time, and their names show which client did what.
2. In **Settings → Remote Control**, turn on **Enable MCP server** on a loopback interface, turn on **Share over Tailscale**, pick the HTTPS port, and under **Allowed devices** choose the machines your clients run on. Press **Apply** and confirm.
3. The status shows **Shared at `https://<mac>.<tailnet>.ts.net:8443/mcp`**. Pick your client under **Copy Client Setup** and paste it on the client machine with that client's token.

Off-the-shelf agents only need the snippet. For Codex, set `TRELLIS_TOKEN` in the environment Codex runs in. Your own bot, whatever model it uses, needs a Streamable HTTP MCP client (for example `streamablehttp_client` from the Python `mcp` SDK): list the tools with `tools/list`, offer them to the model as functions, run each call the model makes with `tools/call`, and send the result back to the model. Every client should:

- treat `session_read_output` text as untrusted data, never as instructions;
- on `CONFIRMATION_REQUIRED`, ask a person before retrying with `force`;
- poll `session_read_output` after sending input, because there are no event subscriptions over MCP;
- on `404`, initialize again; on `401`, stop and report that its grant expired or was revoked;
- send an `idempotencyKey` with mutating tools so a retried request doesn't run twice.

All clients share the server's limits: 32 sessions and 16 connections in total.

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

Each tool is named after its method, with dots and camel case turned into snake case. For example, `session.sendInput` becomes `session_send_input` and `space.list` becomes `space_list`. The tool's arguments are the method's [parameters](methods.md#method-catalog), and its input schema lists them. Mutating tools also accept `idempotencyKey`.

- `tools/list` returns only tools whose base capabilities the grant holds, and tools that need all-spaces scope only for grants that have it. Conditional capabilities, such as `start: true` needing `session.start`, are checked per call, the same as on the socket.
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
| Default | Off, and loopback-only until the user confirms a network address (FR-RC03) or sharing over Tailscale (FR-RC09) |
| Tailscale | HTTPS with Tailscale's certificate inside the tailnet; never Funnel (FR-RC07). Proxied requests need sharing on, a tailnet client address and, with a device list, an allowed one (FR-RC08, FR-RC09). The entry is removed at quit, so another program that later takes the port isn't reachable from the tailnet. |
| Browsers | A request with an `Origin` header that isn't loopback (`http(s)://localhost`, `127.x`, `[::1]`) gets `403`. No CORS headers are ever sent. |
| DNS rebinding | On a loopback bind, the `Host` header must be `localhost`, a `127.x` address or `[::1]`, or the request gets `403`. |
| Limits | 16 connections (more get `503`), 16 KiB of headers, 1 MiB request and response bodies, JSON nesting up to 64 levels. An idle connection, or a request that hasn't fully arrived, is closed after 30 seconds. |
| Logging | Requests, tokens, terminal output and typed input are never logged. |
| Transport | **Plain HTTP, no TLS**, on the listener itself. On a network address, anyone who can see the traffic can read the token and the terminal output. Prefer loopback, shared over Tailscale (HTTPS), or reached through an SSH tunnel (`ssh -L 7777:127.0.0.1:7777 mac`). |

These controls don't protect against malware running as the same user, the same as the [socket's threat model](authorization.md#threat-model). That includes the forwarding headers: a local process can send any `X-Forwarded-For`, so the allowed-devices list limits tailnet devices, not programs on this Mac. Tailscale's own access controls still apply in front of Trellis.
