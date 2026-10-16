# S024 automation session control

Date: 2026-10-16. Implemented with independent review and fixes. Automated tests drive real PTY processes, including one over a real control socket. Manual agent checks are **pending**.

## Behavior

### Starting and restarting sessions

**`session.start`** takes `paneId` and an optional `launch`.

- **Without a launch descriptor:** it starts the pane's own stopped session and needs only `session.start`. If the stored launch is a saved host, host access is re-checked, including reapproval after the host's connection details change.
- **Launch descriptors:**
  - `{kind:"shell", directory?, environment?}`
  - `{kind:"process", executable, arguments, directory, environment?}`
  - `{kind:"host", hostId}`
- **Capabilities:** any descriptor other than exactly `{kind:"host", hostId}` needs `session.execute`. A host descriptor needs access to that host.
- **Paths and environment:** paths must be absolute; `~` and relative paths are rejected. Environment overrides are runtime-only, never persisted, at most 256 entries, and reject reserved `TRELLIS_`/`UTERM_` names.
- **Restored panes:** a restored pane that needs configuration cannot start without a fresh descriptor.
- **Result:** the call resolves after the launch attempt. A failure returns `LAUNCH_FAILED` with the failed session record. Launch details stay redacted without execute.

**`session.restart`** has the same descriptor rules.

- A running session needs `allowRunning`, which policy ties to `session.close`. Without it the call returns `CONFIRMATION_REQUIRED`.
- The session is closed through the shared closure coordinator. A session that hasn't finished closing returns a retryable `CLOSE_PENDING`, and force is honored only after the graceful window.
- After the exit is recorded, the session is replaced with a new session ID and started.

### Sending input

**`session.sendInput`** takes exactly one of `text` or `base64` and targets a running session only.

- **Limit:** at most 64 KiB once decoded. Oversized base64 is rejected before decoding, and text is measured in UTF-8 bytes.
- **Modes:**
  - `literal` writes the exact bytes.
  - `paste` applies the terminal's negotiated bracketed-paste framing. It must be UTF-8 and cannot contain the `ESC[201~` end marker.
- **No UI review:** the grant authorizes the input, so the UI paste review is not shown.
- **Errors:** queue-full returns a retryable `LIMIT_EXCEEDED`; nothing was sent in that case.

**`session.execute`** needs `session.execute` and `submit: true`.

- The command must be one non-empty line, without CR, LF, or NUL.
- It sends exactly the command bytes plus one carriage return.
- Success means the input was submitted, not that the command finished.

### Connecting to hosts

**`host.connect`** opens a tab titled with the host name in the authorized window. The new tab and its rename are committed together.

- With `paneId` and `axis` (`x` or `y`), it splits instead. The target pane must be in that window, and a split is refused while the tab is maximized.
- The new session is launched as `.host(id)` through the S020 ssh path.

### No dialogs, no implicit retries

- Automation never shows UI dialogs or alerts. Starts are quiet. Input errors for sessions that automation wrote to never raise the "input could not be sent" alert, including writes cancelled when a process exits.
- Nothing is retried implicitly.
- A client disconnecting leaves sessions running and does not replay, restart, or close anything.
- Idempotency keys (S023) replay the cached result rather than re-sending input.
- Dedicated processes report their real exit code through `session.get`.

## Tests

- `testS024_UT01_rejectUnapprovedLaunchDescriptor`: a start-only grant gets `PERMISSION_DENIED` for process, shell, and host descriptors carrying an environment, and for a restart with a process. An unknown host returns `NOT_FOUND`, and a reserved environment name is rejected. A marker file proves nothing spawned. The pane's stored launch starts with start-only and stays redacted. A missing executable returns `LAUNCH_FAILED` with the failed record.
- `testS024_UT02_validateInputEncodingAndLimit`: both or neither encoding, invalid base64, a bad mode, and a paste end-marker are rejected. Exactly 65,536 bytes are accepted; 65,537 (base64 or text) returns `LIMIT_EXCEEDED`. Paste mode works. A stopped session returns `INVALID_STATE`.
- `testS024_UT03_executeRequiresSubmit`: a missing or false `submit` and multiline commands are rejected. An input-only grant is denied. Zero bytes arrive from rejected calls. An accepted call delivers exactly `6c 73 0d`.
- `testS024_UT04_disconnectDoesNotReplayOrClose`: over a real socket, the client executes and disconnects without reading the reply. The bytes arrive once, and the session keeps running with the same PID and session ID.
- Additional tests:
  - restart needs `allowRunning`, then yields a new running session
  - `host.connect` through a fixture ssh: a foreign split target returns `NOT_FOUND`, and a new tab named after the host runs `-- prod`
  - review test: undelivered automation input never raises an alert

Full suite: **257 tests passed, 0 failures**. Lint is clean, the build has zero warnings, and the app packages and verifies.

## Independent review

**Fixed:** writes left queued when a process exited were cancelled, and each cancellation raised the UI's modal input-error alert for automation sessions (AC04). Automation-written sessions are now excluded from that alert.

I additionally made `host.connect` reject an invalid `axis` instead of defaulting to `x`, and reject `UTERM_` environment names up front.

Follow-ups, not applied:

- A `host.connect` whose start fails leaves a stopped tab behind.
- A narrow race between authorizing host access and spawning.
- The restart exit wait uses a real clock.
- The cancelled-write alert can still appear for user typing; ignoring `ECANCELED` in `PTYProcess` would fix it.

## Pending manual verification

These checks were not performed and are **not** marked passed:

- A real agent drives a shell over the socket.
- Approve a host and connect to a controlled SSH server.
- Inspect that no dialogs appear during automated input to the live app.
