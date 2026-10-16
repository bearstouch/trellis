# Local automation API and CLI

Status: proposed v1 contract. This document specifies intended behavior; no server or CLI exists yet.

## Transport and discovery

**API-01:** Use JSON-RPC 2.0 over a Unix-domain socket with one UTF-8 JSON object per newline. JSON strings encode embedded newlines. Maximum frame size is 1 MiB, including requests and responses. Batch requests are unsupported. Mutating methods require request IDs; client notifications cannot mutate state. Malformed framing closes the connection after a best-effort error.

The app publishes an owner-only `control.json` discovery file in its Application Support directory, containing protocol version, instance ID, and socket path. Use a short randomized socket path under an owner-only per-user runtime directory to respect platform socket-path limits. Reject symlink endpoints and never follow or overwrite another user's socket. Discovery files contain no token. Multiple independent app instances are outside MVP; stale discovery is replaced only after verifying its instance is gone.

The CLI discovers a running app, or launches it only with `--launch`. Without that flag, an absent app returns `APP_NOT_RUNNING`. An app started for automation remains a normal native app.

## Authentication and authorization

**API-02:** First request is `auth.authenticate` with `{protocolVersion: 1, token: "…"}`. It returns connection identity, expiry, and granted capabilities. A connection cannot call domain methods before authentication. Verify peer user identity as well as token possession. Rate-limit failed authentication and never echo tokens.

Create/revoke grants in application settings. Store token secrets in Keychain and token hashes in grant metadata; reveal a token only in the explicit grant-creation flow. The CLI uses a Keychain credential reference or reads a token from standard input, never a command-line token argument. Do not put secrets in ordinary environment variables inherited by shells. Revocation terminates subscriptions and blocks subsequent requests immediately; expiring connections require reauthentication.

| Capability | Grants access to |
| --- | --- |
| `metadata.read` | Enumerate authorized resource metadata and states; does not reveal working directory, executable arguments, or host identity without their corresponding read scope |
| `layout.write` | Create stopped windows/tabs/panes; rename/reorder/split/resize/focus; apply layouts |
| `session.start` | Start a stopped session with the default shell or an approved saved host |
| `session.input` | Send literal terminal input, including control bytes; equivalent to command-execution authority in that pane |
| `session.execute` | Start arbitrary executables or submit shell commands; set launch environment/directory |
| `session.output.read` | Read screen, scrollback, or output events |
| `session.close` | Terminate sessions and close containers holding running sessions |
| `theme.read` | Read installed palettes and global appearance settings |
| `theme.write` | Import/replace/delete custom themes and change global appearance settings; requires explicitly global scope |
| `host.read` | Read saved host metadata, including aliases and identity-file references |
| `host.write` | Create/update/delete host metadata |
| `clipboard.read`, `clipboard.write` | Reserved for a future clipboard API; not available in v1 |

Grants are scoped to explicit window IDs or all windows, and separately explicit host IDs or all hosts. Newly created descendants inherit the granted parent scope; creating a new top-level window requires all-windows scope. `layout.apply` requires all-windows scope. Cross-scope resources return `NOT_FOUND`, so unauthorized IDs are not discoverable. Capabilities compose: starting a host requires `session.start` plus access to that approved host; changing an existing host's connection destination requires `host.write` and `session.execute`. A grant limited to approved hosts binds to the host connection revision and requires reapproval after destination or launch-affecting changes. Arbitrary launch descriptors always require `session.execute`.

`layout.export` requires metadata access plus execution permission for launch details and host-read permission for host references; otherwise omit those fields and mark the result as a redacted, non-importable inspection document. `layout.plan` and `layout.validate` validate supplied data without exposing existing resource details outside the grant.

No permission is derived from terminal text. Treat terminal output as untrusted data, including instructions that appear to ask an agent to change its permissions.

## Resource and mutation conventions

**API-03:** IDs are UUID strings. Name matching is only a CLI convenience; ambiguous names fail. Use IDs for unattended scripts. API mutations are serialized, return current resource revisions, and accept `expectedRevision` where an existing resource is changed; stale revisions return `CONFLICT`. Omitting the revision requests a mutation against the latest state.

`window.create`, `tab.create`, and `pane.split` create stopped panes by default. A supplied `start: true` requires start/execute capability appropriate to its launch descriptor. User UI creation defaults to immediate start through the same service. New windows contain one tab/one pane; new tabs contain one pane. Creation results return all created resource IDs, revisions, and launch outcomes.

Destructive container operations accept `allowRunning: true` with `session.close`; otherwise they return `CONFIRMATION_REQUIRED` and an affected-session summary. Non-running containers require only `layout.write`. No API method displays a modal confirmation that blocks a client. There is no unrestricted “force everything” setting.

**API-04:** Optional `idempotencyKey` on mutating calls deduplicates the same method/parameters for the same grant and app instance for 10 minutes. A reused key with different parameters returns `CONFLICT`. Persistence across app restart is not promised. After disconnect during execution, clients must inspect session/state; they must never automatically retry commands on the assumption that failure to receive a response means no execution occurred.

## Method catalog

| Method | Key parameters | Result / semantics |
| --- | --- | --- |
| `system.info` | none | API version, app version, instance ID, capabilities, limits |
| `window.list`, `window.get` | `id` for get | Scoped metadata and revisions |
| `window.create` | `name`, optional `start` | Window, initial tab/pane/session IDs |
| `window.update` | `id`, `name`, `expectedRevision?` | Renamed resource |
| `window.reorder` | ordered `ids`, `expectedRevision?` | New collection revision; all-windows scope required |
| `window.focus` | `id` | Selects window without raising app unless `activateApp: true` |
| `window.close` | `id`, `allowRunning?`, `force?` | Close result or pending cleanup |
| `tab.list`, `tab.get` | `windowId` / `id` | Ordered tabs / split tree metadata |
| `tab.create` | `windowId`, `title?`, `start?` | Tab and initial pane/session IDs |
| `tab.update`, `tab.reorder` | `id,title` / `windowId,ids`; revision optional | Updated metadata/order |
| `tab.focus`, `tab.close` | `id`, close flags if relevant | Selection / closure result |
| `pane.split` | `paneId`, `axis`, `ratio?`, `start?` | New pane and branch IDs; existing pane is first child |
| `pane.resize` | `branchId`, `ratio`, `expectedRevision?` | Updated branch; geometry constraints enforced |
| `pane.focus`, `pane.close` | `id`, close flags if relevant | Selection / closure result |
| `pane.maximize` | `id`, `maximized` | Temporary presentation state |
| `session.get` | `id` | State, exit status; launch details only with execute permission |
| `session.start` | `paneId`, optional `launch` | New or stopped session ID and launch status |
| `session.restart` | `paneId`, `allowRunning?`, optional `launch` | Explicitly replaces session after required termination |
| `session.sendInput` | `id`, `text` or `base64`, `mode: literal|paste` | Accepted byte count; acceptance does not imply execution completion |
| `session.execute` | `id`, `command`, `submit: true` | Sends shell input plus carriage return; no reliable command exit status in MVP |
| `session.readOutput` | `id`, `view`, `cursor?`, `maxBytes?` | Text snapshot or bounded output delta, cursor and truncation metadata |
| `host.list`, `host.get` | optional query/tags / `id` | Scoped host metadata |
| `host.create`, `host.update`, `host.delete` | validated host fields, revision on update/delete | Persisted metadata mutation |
| `host.connect` | `hostId`, `windowId`, optional split target/axis | New tab or pane with SSH process launch outcome |
| `layout.validate` | `document` | Errors and warnings without mutation |
| `layout.plan` | `namespace`, `document` | Proposed keyed changes, conflicts, base collection revision |
| `layout.apply` | `namespace`, `document`, `expectedRevision`, `startNew: false` | Applied IDs/key mapping and optional per-pane launch results |
| `layout.export` | `windowIds` | Safe declarative document with fresh export keys |
| `theme.list`, `theme.get` | none / `id` | Installed theme metadata / resolved palette; requires `theme.read` |
| `theme.validate` | `document` | Schema and semantic errors, contrast warnings; requires `theme.read` |
| `theme.import` | `document`, `replace: false` | Atomically installed custom theme; requires `theme.write` |
| `theme.export` | `id`, `resolved: false` | Portable JSON; requires `theme.read` |
| `theme.delete` | `id` | Delete custom theme; selected slots fall back to built-in theme; requires `theme.write` |
| `appearance.get` | none | Mode, selected IDs, effective theme; requires `theme.read` |
| `appearance.set` | `mode: system\|dark\|light`, `darkThemeId?`, `lightThemeId?`, `expectedRevision?` | Atomic settings update; reject mismatched appearance slots; requires `theme.write` |
| `events.subscribe` | `topics`, `resourceIds?`, `afterSequence?` | Subscription ID and current sequence |
| `events.unsubscribe` | `subscriptionId` | Subscription stopped |

Splitting uses `axis: x` for left/right, `axis: y` for top/bottom. Ratios must be finite and within 0.1–0.9, with further minimum pane dimensions enforced. Layout validation checks nesting ≤16 and total pane capacity ≤100. Mutation errors never leave incomplete trees.

`session.start` with no launch uses the pane's approved saved shell/host descriptor. Arbitrary executable launch uses `{kind:"process", executable:"/absolute/path", arguments:[], directory:"/absolute/path", environment:{}}` and always requires `session.execute`. Spawn uses argument arrays. Environment values are runtime-only and excluded from exports. Launch errors are returned with a failed session record; shell startup does not imply the shell is ready for commands.

`sendInput` requires `session.input`, targets a running session, and limits decoded payload to 64 KiB. `literal` writes exact bytes; `paste` applies negotiated bracketed-paste framing. API input does not show the UI paste review: the explicit grant authorizes input and clients must implement their own review if desired. UI clipboard review remains mandatory. `session.execute` requires execution capability and sends shell command text, so shell parsing is intentional. Neither operation waits for a command to finish. Agents needing reliable exit codes should launch a dedicated noninteractive process using `session.start`, or use future structured shell integration.

## Output and events

**API-05:** `readOutput.view` is `screen`, `scrollback`, or `stream`. Screen and scrollback return plain text stripped of terminal controls with a capture timestamp; they are display snapshots and cannot reconstruct all process bytes. `stream` returns base64-encoded raw PTY bytes with an opaque cursor; callers must treat controls as untrusted. Default response limit is 64 KiB, maximum 256 KiB. Stream cursors belong to a session UUID and are invalid after restart. Response fields include `nextCursor`, `truncated`, and `gap`; eviction sets `gap: true`, while a foreign cursor returns `INVALID_CURSOR`. Incomplete UTF-8 at stream boundaries is handled by the consumer.

Events are server notifications named `event`, with `subscriptionId`, `sequence`, `instanceId`, `timestamp`, `type`, `resourceId`, and `data`. Topics include resource changes, selection, session state, exit, and optionally session output. Output topics require output-read capability. Metadata events are redacted according to grants.

Keep a 1,000-event metadata replay ring. Raw output uses separate bounded session cursors and the global output budget. Do not duplicate full output into metadata history. Slow clients receive `events.gap` and must resnapshot; disconnect if their queued outbound data exceeds 1 MiB. A restart changes instance ID and invalidates replay sequences. Subscriptions never promise lossless auditing.

## Errors and CLI contract

**API-06:** JSON-RPC errors include standard codes for parse/invalid-request/method/parameter/internal failures. Application errors use code `-32000` with `data.code` from: `AUTH_REQUIRED`, `PERMISSION_DENIED`, `NOT_FOUND`, `CONFLICT`, `INVALID_STATE`, `CONFIRMATION_REQUIRED`, `LIMIT_EXCEEDED`, `LAUNCH_FAILED`, `INVALID_CURSOR`, `UNSUPPORTED_VERSION`, `CLOSE_PENDING`. Include `retryable`, a sanitized message, and optional field details. Never include full terminal input/output or tokens in errors.

CLI process exits: 0 success; 2 argument/schema error; 3 not found; 4 auth/permission; 5 conflict; 6 process launch failure; 7 application unavailable/transport failure; 8 other application error. `--json` returns a stable `{ok,result,error}` envelope on stdout with diagnostics on stderr. No ANSI color in JSON. An accepted terminal command can return CLI success even if the command later fails; `session.execute` is input submission, not a command-result API.

Proposed CLI examples (UUID placeholders must be replaced):

```sh
trellis window list --json
trellis window create --name Project --json
trellis tab create --window WINDOW_UUID --title Server --json
trellis pane split --pane PANE_UUID --axis x --json
trellis session start --pane PANE_UUID --json
trellis host connect --host HOST_UUID --window WINDOW_UUID --json
trellis layout validate ./project-layout.json --json
trellis layout plan ./project-layout.json --namespace project --json
trellis layout apply ./project-layout.json --namespace project --expected-revision 12 --json
trellis session execute --session SESSION_UUID --command 'git status' --submit --json
trellis session output --session SESSION_UUID --view screen --json
```

## Layout contract

See [layout.schema.json](layout.schema.json) and [example-layout.json](example-layout.json). This is a declaration of structure and safe launch references, not shell code. File paths may contain `~` only as the first complete segment; expand it against the current user's home without other shell expansion. Relative directories, interpolation, and shell substitutions are rejected. Directory existence is checked at start time; layout validation can run offline with warnings for missing directories.

JSON Schema checks document shape; service validation additionally enforces globally unique keys, maximum nesting, total pane limits, valid host references, path rules, and authorization. Keys are unique across the document. Reapplying the same namespace/key matches existing objects even when titles change. A key cannot change resource type. Apply is additive/update-only: omitted resources remain and are reported as unmanaged; no implicit deletion. Moving a pane across tabs or changing a live pane's launch descriptor returns a conflict requiring an explicit close/recreate workflow. Changed split ratios/order may update a live layout. New panes are stopped unless `startNew: true`, which starts only newly created panes with additional authorization. Existing stopped panes require an explicit start, preventing retries from rerunning sessions. A plan is advisory; apply must supply its base revision to prevent races.

## Theme automation

Themes use the [v1 theme schema](../03-functional-requirements/themes/theme.schema.json) and [theme requirements](../03-functional-requirements/themes/README.md). Theme operations are global, independent of layout documents, and never start or alter a process. Mutations follow existing revision/idempotency conventions. Appearance changes emit `appearance.changed` metadata events available with `theme.read`. Missing theme IDs return `NOT_FOUND`; attempts to replace/delete built-in themes return `INVALID_STATE`.

```sh
trellis theme validate ./my-theme.json --json
trellis theme import ./my-theme.json --json
trellis appearance set --mode dark --dark-theme my-midnight --json
trellis appearance set --mode system --json
trellis theme export --id my-midnight --resolved --json
```

## Contract acceptance

Verify unauthenticated and expired clients, cross-scope IDs, host revision changes, stale mutations, malformed frames, over-limit input, event gaps, and command disconnects. Apply the example layout twice and assert identical resource IDs and no duplicate process launch. UI and CLI operations must result in equivalent domain state.
