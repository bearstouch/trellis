# S020 SSH connections in tabs and splits

Date: 2026-10-16. Implemented with independent review and fixes. Automated tests use a fixture in place of `ssh`. Checks against a real SSH server are **pending**.

## Behavior

**Connecting.** The Hosts window offers **Connect in New Tab** (the default) and **Connect in Split** (Left/Right or Top/Bottom of the focused pane). Both are disabled while the editor has unsaved changes.

- `AppWorkspaceModel.connect(host:placement:)` creates a new stopped pane. With no window open, it uses the pane of a newly created window.
- A new tab is titled with the host name.
- The pane is configured as `SessionLaunch.host(id)` and started.
- Every call owns a new pane, session, PTY, and process. Connections are never reused or retried.
- A split is refused while the tab is maximized, so authentication prompts cannot open hidden. It is also refused without a focused pane, or during restore, recovery, or shutdown.

**Spawning ssh.** The domain session keeps `.host(id)`. When the session spawns, `start` resolves the current saved host and launches `/usr/bin/ssh` through the existing validated PTY path.

- The argument array is `[-p port] [-l user] [-i identity] -- destination`. There is no shell, and the options come before `--`.
- Fields that are not set are left to `ssh_config`.
- No `-o` option and no StrictHostKeyChecking, UserKnownHostsFile, BatchMode, or known-hosts bypass is ever added.
- The environment, including `SSH_AUTH_SOCK`, is inherited under the S003 policy.
- Host-key, password, passphrase, and agent prompts stay in the terminal and are handled by OpenSSH.
- Edits to a host apply to later spawns only. A running process keeps its arguments, while restore and explicit reconnect re-read the host.

**Status and failure.** "Running" means the ssh process is live; Trellis does not infer that authentication succeeded.

- A failed connection stays inspectable, with ssh's own output and the exit code, for example "Exited (255)".
- The pane shows **Reconnect**, which restarts the session explicitly with a new session ID. There is no automatic retry or timer.
- If the host was deleted, or the host library could not be read, ssh is not spawned. The domain session and the terminal both become **Failed**, the pane explains why, and Reconnect or Close stays available.
- Hosts are loaded before the workspace restore, so restored host panes resolve correctly.

## Tests

- `testS020_UT01_buildSshArgumentsSafely`: the exact argument array, including an identity path with spaces kept as a single element. An alias-only host passes only `-- alias`.
- `testS020_UT02_neverAddTrustBypass`: across every combination of optional fields, the only options are `-p`, `-l`, and `-i`. No `-o`, trust, known-hosts, BatchMode, or `-f`/`-T` flags appear.
- `testS020_UT03_connectCreatesIndependentSession`: three connections (two tabs and a split) get distinct panes, sessions, and PIDs. Each keeps `.host(id)`, the tab title is the host name, the split lands in the focused tab, and the fixture records three identical argument arrays.
- `testS020_UT04_failedConnectionDoesNotRetry`: a fixture exit of 255 leaves the session exited with code 255 and the status "Exited (255)". After 1.5 s it is the same session with one invocation. An explicit Reconnect creates a new session and a second invocation.
- Additional tests:
  - A deleted host fails the terminal and the domain without spawning ssh, and Reconnect fails safely again.
  - A split while the tab is maximized is refused without spawning ssh.

Full suite: **226 tests passed, 0 failures**. Lint is clean and the build has zero warnings. The app packages and verifies.

## Independent review

Three issues were fixed:

1. When the host was missing, the domain said failed but the terminal stayed "Stopped", showing a dead Start button and no Reconnect. `refuseLaunch` now fails the terminal without spawning.
2. Connect in Split worked while the tab was maximized, so the new pane and its authentication prompts were hidden.
3. Races across the new awaits: closing or shutdown during connect, and a terminal replaced while the host was resolving.

Follow-ups, not applied:

- No canvas minimum-size check for host splits; the domain's terminal-size check still applies.
- No dedicated "host library unavailable" state.
- No test that holds host resolution suspended while a close runs.

## Pending manual verification

Run against a controlled local SSH server only, never production hosts. Not performed, and **not** marked passed:

- key, agent, and password prompts
- unknown and changed host keys
- refused connections
- network loss
- visual placement of new tabs and splits
- connecting by an alias discovered in S019
