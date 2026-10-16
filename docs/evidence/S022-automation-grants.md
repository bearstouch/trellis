# S022 scoped automation grants

Date: 2026-10-16. Implemented with independent review and fixes, and automated tests. Keychain-backed grant checks and native UI checks are still **pending**.

## Behavior

**Grants and tokens.** Settings → Automation lists grants with their status (active until a date, expired, or revoked), capabilities, and scopes.

- **New Grant…** takes a name, a list of capabilities with plain-language descriptions, a window scope (all windows or selected windows), a host scope (all hosts or approved hosts), and an expiry from 1 hour to 90 days.
- The token is shown once with a Copy button. Copies are marked with the concealed-pasteboard type.
- **Token format:** `trl_` followed by 256 random bits (`arc4random_buf`), base64url-encoded.
- **Where the secret lives:** the token is stored as a Keychain generic password (service "Trellis Automation", account = grant ID, `WhenUnlockedThisDeviceOnly`).
- **What `grants.json` keeps:** only `sha256:<hex>`. The file is mode 0600, written with `O_NOFOLLOW` and an atomic rename.
- **If a save fails:** a failed file save during creation rolls back the Keychain item, and a failed Keychain store creates nothing.
- **If `grants.json` is unreadable or newer:** the file is left untouched, no grant is active, and create, revoke, and reapprove report read-only.
- The panel explains the same-user isolation limits (NFR-S02).

**Authentication.** `auth.authenticate` requires a same-UID peer, `protocolVersion: 1`, and a token of at most 512 bytes. The token is compared with a constant-time hash comparison against active grants.

- Five failures in 60 s return `LIMIT_EXCEEDED` with `retryable: true`, even for a valid token, until the window passes.
- The result returns the connection and grant IDs, the expiry, the sorted capabilities, and the window scope. The token is never echoed.

**Authorization.** `AuthorizingControlHandler` re-checks the stored grant on every call. When a grant expires or is revoked, the call returns `AUTH_REQUIRED` and the session drops its identity, so the client must reauthenticate.

- Revocation also deletes the Keychain item and disconnects every socket authenticated with that grant.
- `AuthorizationPolicy` covers every API catalog method. Unknown methods are never dispatched.
- **Resource and scope checks:**
  - Resource IDs in params, including ID lists such as `windowIds`, `ids`, and `resourceIds`, must resolve to windows visible to the grant; otherwise the call returns `NOT_FOUND`, which looks exactly like a missing resource.
  - `window.create`, `window.reorder`, `layout.apply`, `theme.import`, `theme.delete`, and `appearance.set` need all-windows scope.
  - `theme.read` is independent of window scope.
- **Capability rules:**
  - The capabilities are separate and checked on their own: metadata, layout, start, input, execute, output, close, host, and theme.
  - **`start: true`** additionally needs `session.start`.
  - **`launch`** needs `session.execute`.
  - **`allowRunning` or `force`** needs `session.close`.
  - **Output event topics** (or unrecognized topic shapes) need `session.output.read`.
  - **Any `host.update` field beyond rename or retag** needs `session.execute`.
- Denied calls never reach the domain.

**Host approvals.** `SavedHost.connectionRevision` advances only when the destination, user, port, or identity file changes; files written before S022 migrate by defaulting it to the existing revision.

- An approved-host grant binds each host to the connection revision it approved. A rename keeps the approval.
- A changed connection returns `PERMISSION_DENIED` with "Reapprove it in Settings → Automation". **Reapprove** in Settings rebinds the host to its current connection revision.

**Errors.** Control errors now follow API-06: application failures use code -32000 with `data.code` and `retryable`. This replaces S021's provisional codes.

**Scope of this story.** The app's `AppControlDomain` executes only `system.info`. Resource methods are S023 and later; their authorization is already enforced here.

## Tests

- `testS022_UT01_denyBeforeAuthentication`: domain probes before authentication, a wrong token, and the wrong version all return `AUTH_REQUIRED` or `UNSUPPORTED_VERSION` with no effects. The rate limit blocks even a valid token until the fake clock advances. The token is never echoed.
- `testS022_UT02_scopeAndCapabilityMatrix`: 27 methods × {layout-only and window-scoped, full} grants. Output, input, and execute are denied to the layout grant, hidden IDs return `NOT_FOUND`, IDs are absent from errors, and the domain is called only for allowed cases.
- `testS022_UT03_expiryAndRevocationStopAccess`: expiry on a fake clock forces reauthentication and blocks it. Revocation fires observers, removes the secret, and blocks later calls.
- `testRevocationDisconnectsALiveSocketClient`: on a real socket, revocation closes the client.
- `testS022_UT04_hostRevisionInvalidatesApproval`: a rename keeps the approval, a destination change denies `host.connect` and `host.get` with a reapproval message, reapproval restores access, and an unapproved host returns `NOT_FOUND`.
- Additional tests:
  - the grant file stores the hash, never the token, with mode 0600, and reloads correctly
  - a secret-store failure creates nothing
  - name and capability validation
  - review tests: global theme writes, ID-list checks, output topics, `host.update` field composition, and preservation of an unreadable grant file

Full suite: **243 tests passed, 0 failures**. Lint is clean, the build has zero warnings, and the app packages and verifies.

## Independent review

Six issues were fixed:

1. Window-scoped grants could change global themes and appearance.
2. ID lists in params were not scope-checked.
3. Output event topics needed only metadata access.
4. Nested or alternate `host.update` shapes could change a connection without `session.execute`.
5. A corrupt or newer `grants.json` was silently overwritten.
6. Revoke and reapprove failures were swallowed.

I also fixed the read-only method name (`session.readOutput`), concealed the copied token, and guarded Create Grant against a double click.

Follow-ups, not applied:

- **Rate limiter:** concurrent connections can each get about one extra attempt per window.
- **`grants.json`:** add a version envelope, and possibly an HMAC against same-user tampering (NFR-S02 limit).
- **Later stories:**
  - check host access when `session.start` runs on a host pane
  - scope the `host.connect` split target
  - check host scope inside layout documents
  - end subscriptions at expiry

## Pending manual verification

These checks were not performed and are **not** marked passed:

- Create and revoke a real Keychain-backed grant in Settings, and confirm the Keychain item appears and is removed.
- Authenticate clients with different scopes over the socket.
- Scan app logs, exports, and child environments for a distinctive test token.
