# S027 CLI and agent workflows

Date: 2026-10-16. Implemented with independent review and fixes. Covered by automated tests (fake environment and real socket) and a live demo against an isolated app instance.

## Behavior

**Executable name.** The CLI builds as `trellis-cli`. A product named `trellis` would collide with the `Trellis` app binary on case-insensitive volumes. Packaging (S032) installs it as `trellis`; the examples below use that name.

**Commands.** `trellis <noun> <verb> [options]` covers every v1 command group.

| Noun | Verbs |
| --- | --- |
| `system` | `info` |
| `window` | `list`, `get`, `create`, `rename`, `reorder`, `focus`, `close` |
| `tab` | `list`, `get`, `create`, `rename`, `reorder`, `focus`, `close` |
| `pane` | `split`, `resize`, `focus`, `maximize`, `close` |
| `session` | `get`, `start`, `restart`, `input`, `execute`, `output` |
| `host` | `list`, `get`, `create`, `update`, `delete`, `connect` |
| `layout` | `validate FILE`, `plan FILE`, `apply FILE`, `export` |
| `events` | `subscribe` |

Most command options follow the API: `--expected-revision`, `--idempotency-key`, `--allow-running`, `--force`, `--start`, `--start-new`, `--submit`, `--view`, `--cursor`, `--max-bytes`, `--topics`, `--after-sequence`, and `--instance`.

`session start` and `session restart` take a launch through one of:

- `--shell [--directory]`
- `--process EXEC --arg … --directory`
- `--host-launch`

**Arguments and names.** Parsing performs no I/O.

- Unknown commands or options, missing values, repeated single-use options, and stray arguments exit 2.
- `--window`, `--tab`, and `--host` accept UUIDs, or exact names resolved through list calls. Tab titles are resolved across all windows.
- A name matching several resources exits 2 before any mutation. A missing name exits 3. A failed lookup reports its own status, for example 4 for permission denied.

**Discovery and launch.** The CLI only trusts a current-user `control.json` that is a regular file, read without following symlinks, and a socket owned by the current user in an owner-only directory. The default state directory is `~/Library/Application Support/dev.trellis`, or the path given with `--state-directory`.

- With the app absent, the CLI returns `APP_NOT_RUNNING` (exit 7).
- Only `--launch` starts the app, through a normal `open -b dev.trellis` launch. An explicit `--state-directory` is forwarded to the launched app.
- The CLI waits at most about 10 s for the socket and never relaunches a running app.

**Credentials.** The token comes from `--token-stdin` (the first stdin line) or `--keychain-grant GRANT_ID`, which reads the Keychain item the app writes.

- Tokens are never accepted as arguments. `--token`, `--password`, and `--secret` (also in `=value` form), any `--option=value` form, and stray values all exit 2 without echoing the value.
- No environment variables are used for credentials.

**Output.** With `--json`, stdout gets exactly one envelope: `{"ok":true,"result":…}` or `{"ok":false,"error":{code,message,exitStatus,details?}}`.

- In JSON mode, stderr carries only diagnostics.
- In plain mode, a pretty result goes to stdout and `trellis: message (CODE)` to stderr.
- There is no color.

**Exit statuses.**

| Status | Meaning |
| --- | --- |
| 0 | Success |
| 2 | Arguments or schema (`-32600`/`-32602`/parse errors, invalid layout) |
| 3 | Not found |
| 4 | Authentication or permission |
| 5 | Conflict or confirmation required |
| 6 | Launch failed |
| 7 | App unavailable or transport failure |
| 8 | Other application error |

**No retries.** Nothing is retried. A lost connection or a 120 s timeout after a request is sent exits 7 with "may or may not have run; inspect state before retrying". `session execute` success means the input was submitted.

**Events.** `events subscribe` first prints the subscription envelope (ID, sequence, instance), then one event per line, including any replayed before the reply. When the app closes the stream, the CLI exits 7 with a hint to resume with `--instance` and `--after-sequence`. It never resubscribes on its own.

## Tests

- `testS027_UT01_parseAndRejectAmbiguousArguments`:
  - Documented commands and repeatable `--arg` values parse correctly, and eight malformed invocations are rejected.
  - A duplicate window name exits 2 and a missing one exits 3, both with no mutation; a unique name updates.
  - A denied lookup exits 4, and tab titles resolve across windows, with ambiguity rejected.
- `testS027_UT02_jsonAndExitCodeMapping`: twelve error classes map to their exact statuses. Each JSON envelope has the exact keys, stderr stays empty, and there is no ANSI. Success has the exact envelope. A transport loss during `session.execute` exits 7 after one attempt, with the uncertainty message. Plain mode splits stdout and stderr.
- `testS027_UT03_launchOnlyWhenRequested`: with the app absent, the CLI exits 7 with zero launches and zero calls. `--launch` launches once, and forwards an explicit state directory. A running app is never relaunched.
- `testS027_UT04_credentialsNeverInArgumentsOrLogs`: `--token`, `--password`, `=value` forms, and stray secrets exit 2 with nothing sent and nothing echoed. The stdin token appears only in `auth.authenticate`, never in output, including on authentication failure. A Keychain reference works without reading stdin, and a missing item exits 4. Missing credentials exit 2.
- Real socket tests:
  - a round trip through the `control.json` discovery
  - a wrong token exits 4, and a stopped server exits 7
  - notifications received before a reply are kept
  - the subscription is printed first and closure is reported
  - an invalid layout validation exits 2

Full suite: **280 tests passed, 0 failures**. Lint is clean, the build has zero warnings, and the app packages and verifies.

## Native demo (performed)

The built app was launched with `--fixture --state-directory <scratch>`, with a grant seeded in `grants.json` as only the SHA-256 of a test token. The Keychain and the user's workspace were not involved. With `trellis-cli`:

- Missing credentials exited 2 with guidance. A token passed as an argument was rejected without being echoed.
- `window list --token-stdin --json` returned the fixture window.
- `layout plan` and then `layout apply` of `docs/api/example-layout.json` were run twice. The first apply returned `changed: true` and the second `changed: false`. Both returned identical mapping IDs with 0 launches, which also covers S026's pending live demo.
- `session execute` on an ID outside the grant returned `NOT_FOUND` (exit 3).
- A scan of the state directory found no copy of the token.

## Independent review

The review fixed six issues:

1. Tokens could be echoed through `--token-stdin VALUE`, `--password=…`, or unknown-option errors.
2. Name-resolution failures were masked as `NOT_FOUND`.
3. Events received before the subscribe reply were dropped.
4. The event stream printed its subscription only at the end and exited 0 when the app closed it. `--idempotency-key` was also removed from `events subscribe`.
5. Reads had no timeout and errors were misreported.
6. `layout validate` exited 0 for invalid documents.

I fixed `--launch` combined with `--state-directory`, which launched the default workspace instead.

Follow-ups, not applied:

- Always include `result` and `error` keys (with null) in the envelope.
- `UNSUPPORTED_VERSION` and method-not-found statuses are not specified by the spec.
- `discovery.protocolVersion` is not checked.
- There is a small window between verifying the socket and connecting to it.

## Pending

- Install as `trellis` and confirm signed CLI behavior (S032).
- Use a real Keychain-backed grant created in Settings.
