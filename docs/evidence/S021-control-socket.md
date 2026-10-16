# S021 local JSON-RPC control socket

Date: 2026-10-16. Implemented in the new `TrellisControl` target, with independent review and fixes, automated socket tests, and a native app check.

## Behavior

**Endpoint and discovery.** `ControlEndpoint` sets up the socket under an owner-only runtime root (the per-user `$TMPDIR`).

- It creates a random 0700 directory named `trellis-<12 hex>`. The socket inside it, `.../s`, is chmod 0600 and stays well under the 103-byte `sun_path` limit.
- It publishes a token-free `control.json` with exactly `protocolVersion`, `instanceID`, and `socketPath`. The file is mode 0600 and written atomically with `O_EXCL`/`O_NOFOLLOW` before a rename.
- Directory checks use `lstat`: the path must be a real directory owned by our UID, with no group or other access. Socket checks require a real socket owned by our UID inside such a directory. Symlinks and other users' files are refused, and the server never follows or deletes them.

**Stale instances.** Previous discovery is replaced only after a connect probe fails. A live instance makes `start` fail with `anotherInstanceRunning` and leaves its files untouched. If the probe fails, only a verified socket of ours is unlinked and its empty directory removed. Quitting removes this instance's own discovery and runtime directory.

**Server.** `ControlServer` uses AF_UNIX only; there is no TCP code path.

- It accepts at most 16 connections.
- Every client gets `FD_CLOEXEC` and `SO_NOSIGPIPE`.
- `getpeereid` must match our UID. A wrong-UID peer is dropped at accept, and `ControlSession` checks the UID again.
- Each connection reads on its own thread and is bridged to the async session. The bridge is never on the main thread, so main-actor handlers can make progress.

**Protocol.** `ControlSession` handles the JSON-RPC rules.

- Frames end at a raw newline (JSON escapes newlines inside strings) and are limited to 1 MiB; the framer does linear work.
- Frames must be UTF-8. Nesting is limited to 64 levels before decoding.
- Requests must be objects with `jsonrpc: "2.0"` and a string method of at most 128 bytes. The id must be a string or number; params must be an object or array.
- Batches are rejected.
- Notifications are never dispatched, and a mutating notification is refused. Any method not on the explicit read-only list counts as mutating.
- An oversized frame or invalid UTF-8 gets a best-effort error, then the connection closes. Malformed JSON within a frame gets a parse error and the connection stays open.
- Errors are fixed strings with stable codes, such as `UNAUTHENTICATED`, `AUTH_FAILED`, `BATCH_UNSUPPORTED`, `ID_REQUIRED`, and `FRAME_TOO_LARGE`. They never echo client input.
- Every method except `auth.authenticate` requires an authenticated identity.
- Responses over 1 MiB are replaced with `RESPONSE_TOO_LARGE`.

**App integration.** Until grants exist (S022), the app installs `RejectingControlHandler`, so every authentication attempt fails and no domain method is reachable. A failed start, such as an unsafe endpoint or a live second instance, leaves the app usable without automation.

## Tests

- `testS021_UT01_frameAcrossReads`: chunk sizes 1, 2, 7, 64, and the whole stream; an escaped newline inside a string; CRLF; a partial trailing frame; and an exactly-1 MiB frame.
- `testS021_UT02_rejectOversizedAndMalformedFrames`:
  - An oversized frame closes the connection, and nothing is accepted after the close.
  - Invalid UTF-8 closes the connection.
  - Invalid JSON, a batch, a mutating notification, a read-only notification, a wrong `jsonrpc` value, a null id, and scalar params each get the expected handling, along with unauthenticated and failed-auth calls.
  - Zero dispatches occur, and no input is echoed.
  - Dispatch works only after a successful authentication.
- `testS021_UT03_rejectUnsafeEndpoint`: a symlinked socket, a wrong-owner socket, a regular file posing as the socket, and a 0755 directory are each refused. A stale discovery pointing at a symlink never removes its target. A peer with a different UID is dropped before parsing.
- `testS021_UT04_discoveryContainsNoSecret`: exactly three keys, no secret-like content, and modes 0600/0600/0700.
- Additional tests:
  - a real-socket round trip through the authentication gate, with a flood frame closed after the error
  - stale-instance replacement, including refusal while the first instance is live
  - review tests: nesting depths up to 100,000 rejected without a crash (64 still parses), and trickled bytes or tightly packed frames framed correctly

Full suite: **235 tests passed, 0 failures**. Lint is clean, the build has zero warnings, and the app packages and verifies.

## Native verification (performed)

The built app was launched on an isolated scratch state directory with `--fixture`. Observed:

- `control.json` was `-rw-------` and contained only `instanceID`, `protocolVersion`, and `socketPath`.
- The socket was `srw-------` in a `drwx------` directory under `/var/folders/.../T/trellis-…/s`.
- `lsof -i` showed **0** network sockets for the process, and `lsof -U` showed the listening socket.
- Using `nc -U`, `system.info` returned `UNAUTHENTICATED`, and `auth.authenticate` returned `AUTH_FAILED`.
- After SIGTERM, which skips `applicationWillTerminate` like a crash, the files remained. On relaunch, the stale directory was removed and a new socket was published and answered.

## Independent review

Three issues were fixed:

1. Deeply nested JSON overflowed the stack in the recursive decoder on a cooperative thread. Any same-user client could crash the app before authenticating. The fix is a byte-scan nesting limit applied before decoding.
2. The framer did quadratic rescans and memmoves.
3. `stop()` could shut down a reused fd number outside the lock.

I additionally moved the peer-UID check to accept time, so wrong-user peers cannot hold slots.

Follow-ups, not applied:

- Cap the total output per read before S022 handlers return large results.
- Add an idle timeout for silent clients.
- Retry the stale probe so a full listen backlog cannot be mistaken for a dead instance.
- Concurrent starts: the last rename wins.
- Integer ids above 2^53 lose precision.
