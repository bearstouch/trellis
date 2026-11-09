# EX-27: Native fetch to declared origins

Part of the [Extensions specification](SPEC.md#stories). **Epic:** 6, Network and OAuth · **Phase:** 6 · **Requirements:** FR-EX21 · **Depends on:** [EX-9](EX-09-runtime-prompts-audit.md) · **Points:** 3

**Definition.** As a Trellis user, I want extensions to reach only the network origins I approved, through Trellis, so that an extension can't send my data anywhere else.

JavaScript can't open connections. `trellis.fetch(url, init)` is executed by the app in an ephemeral `URLSession` with no cookies and no credential storage, and only to origins declared in `network`. The first fetch to each declared origin prompts once and is remembered.

## Scope

**In**

- `ExtensionFetch`: an ephemeral `URLSession`, no cookies, no credential storage.
- Only declared origins, with one leading `*.` wildcard. Redirects followed only to declared origins.
- The first fetch to each origin prompts once (EX-9); Always Allow covers that origin.
- Limits: 30 s default timeout (120 s max), 5 MiB per response, 8 requests in flight per extension.
- Result `{status, headers, body}`.
- `Image.url` fetches for the renderer go through the same path.

**Out**

- Authenticated requests (EX-28).

## Acceptance criteria

- [ ] **Given** an undeclared origin, **when** the extension fetches it, **then** it rejects with `NETWORK_NOT_DECLARED`.
- [ ] **Given** a declared origin fetched for the first time, **when** the call runs, **then** it prompts, and the choice is remembered for that origin.
- [ ] **Given** a declared origin that redirects to an undeclared one, **when** fetched, **then** the redirect is refused.
- [ ] **Given** a response over 5 MiB, **when** fetched, **then** the call fails.
- [ ] **Given** 8 requests in flight, **when** a 9th is made, **then** it waits or is refused, and Trellis never exceeds 8.
- [ ] **Given** a server that sets cookies, **when** a second request is made, **then** no cookie is sent.
- [ ] **Given** a timeout over 120 s, **when** requested, **then** it is clamped to 120 s.

## Implementation notes

- New in `TrellisUI`: `ExtensionFetch`.
- Inject the transport (a `URLProtocol` stub or a protocol) so tests never touch the network.

## Tests

- `ExtensionFetchTests`: undeclared origin; redirects; caps; first-fetch prompt; no cookies.
