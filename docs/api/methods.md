# Methods

## Resource conventions (API-03)

- IDs are UUID strings. Matching by name is only a CLI convenience, and an ambiguous name fails. Unattended scripts should use IDs.
- Mutations are serialized and return the current resource revisions.
- Methods that change an existing resource accept `expectedRevision`, and a stale revision returns `CONFLICT` with `{expectedRevision, currentRevision}`. Leaving the revision out mutates the latest state. The one exception is `layout.apply`, where `expectedRevision` is **required**.
- `window.create`, `tab.create` and `pane.split` create **stopped** panes unless you pass `start: true`, which also needs the matching start capability. UI creation starts sessions immediately, through the same service.
- A new window has one tab with one pane, and a new tab has one pane. Creation results return every created ID, the revisions and any launch outcomes.
- Destructive container operations accept `allowRunning: true`, which needs `session.close`. Without it they return `CONFIRMATION_REQUIRED` and list the affected sessions. Containers with no running sessions need only `layout.write`.
- No API method ever opens a modal dialog that would block a client, and there's no unrestricted "force everything" setting.
- If a mutation fails, the domain is left exactly as it was.

## Idempotency (API-04)

Mutating calls accept an optional `idempotencyKey` (1–128 bytes):

- A repeated key with the **same** method and parameters, from the same grant and app instance, returns the original result for 10 minutes.
- Reusing a key with **different** parameters returns `CONFLICT`. If the original call is still running, the response is a retryable `CONFLICT`.
- Keys live in memory only and don't survive an app restart. Each grant can hold up to 1,000 keys. A call that fails with a retryable error releases its key.

**Never retry a command blindly.** If you disconnect while a call is executing, inspect the session and state before you do anything else. A missing response doesn't mean nothing ran.

## Method catalog

| Method | Key parameters | Result / semantics |
| --- | --- | --- |
| `system.info` | — | `apiVersion`, `appVersion`, `instanceId`, the grant's capabilities and `limits` (`maxFrameBytes`, `maxPanes`, `maxNesting`) |
| `window.list`, `window.get` | `id` for get | Scoped metadata and revisions |
| `window.create` | `name`, `start?` | The window plus its initial tab, pane and session IDs |
| `window.update` | `id`, `name`, `expectedRevision?` | The renamed resource |
| `window.reorder` | ordered `ids`, `expectedRevision?` | New collection revision. Needs all-windows scope. |
| `window.focus` | `id` | Selects the window |
| `window.close` | `id`, `allowRunning?`, `force?`, `expectedRevision?` | A close result or pending cleanup |
| `tab.list`, `tab.get` | `windowId` / `id` | Ordered tabs / split-tree metadata |
| `tab.create` | `windowId`, `title?`, `start?` | The tab plus its initial pane and session IDs |
| `tab.update`, `tab.reorder` | `id`, `title` / `windowId`, `ids`; revision optional | Updated metadata or order |
| `tab.focus`, `tab.close` | `id`, plus close flags | Selection / close result |
| `pane.split` | `paneId`, `axis`, `ratio?`, `start?` | New pane and branch IDs. The existing pane becomes the first child. |
| `pane.resize` | `branchId`, `ratio`, `expectedRevision?` | Updated branch, with geometry constraints enforced |
| `pane.focus`, `pane.close` | `id`, plus close flags | Selection / close result |
| `pane.maximize` | `id`, `maximized` | Temporary presentation state |
| `session.get` | `id` | State and exit status. Launch details only with execute permission. With [shell integration](../features/shell-integration.md), `shellIntegration: {commandRunning, lastExitStatus?, currentDirectory?}`; the directory needs execute permission, and command text is never included. |
| `session.start` | `paneId`, `launch?` | New or stopped session ID and the launch status |
| `session.restart` | `paneId`, `allowRunning?`, `launch?` | Replaces the session after any required termination. The new session gets a new UUID. |
| `session.sendInput` | `id`, `text` or `base64`, `mode: literal\|paste` | Accepted byte count. Acceptance doesn't mean the input has been processed. |
| `session.execute` | `id`, `command`, `submit: true` | `{acceptedBytes, submitted: true}` |
| `session.readOutput` | `id`, `view`, `cursor?`, `maxBytes?` | See [Output and events](output-events.md) |
| `host.list`, `host.get` | `query?`, tags / `id` | Scoped host metadata |
| `host.create`, `host.update`, `host.delete` | Validated host fields; revision on update and delete | Persisted metadata change |
| `host.connect` | `hostId`, `windowId`, optional split target and `axis` | A new tab or pane, plus the SSH launch outcome |
| `layout.validate` | `document` | Errors and warnings, without changing anything |
| `layout.plan` | `namespace`, `document` | Proposed keyed changes, conflicts and `baseRevision` |
| `layout.apply` | `namespace`, `document`, `expectedRevision`, `startNew?` | Applied IDs, the key mapping and per-pane launch results |
| `layout.export` | `windowIds` | A safe declarative document with fresh export keys |
| `theme.list`, `theme.get` | — / `id` | Installed theme metadata / the resolved palette |
| `theme.validate` | `document` | Schema and semantic errors, plus contrast warnings |
| `theme.import` | `document`, `replace?` | The theme, installed atomically |
| `theme.export` | `id`, `resolved?` | `{id, resolved, document}`. Built-in themes are always exported complete. |
| `theme.delete` | `id` | Deletes a custom theme. Any slot that had it selected falls back to the built-in theme. |
| `appearance.get` | — | Mode, selected theme IDs and the effective theme |
| `appearance.set` | `mode: system\|dark\|light`, `darkThemeId?`, `lightThemeId?`, `expectedRevision?` | Atomic settings update. A theme in the wrong appearance slot is rejected. |
| `events.subscribe` | `topics`, `resourceIds?`, `afterSequence?`, `instanceId?` | `{subscriptionId, sequence, instanceId}` |
| `events.unsubscribe` | `subscriptionId` | The subscription stops |

[Authorization](authorization.md#how-capabilities-compose) lists the capability each method needs.

## Splits and geometry

- `axis: x` is left/right, and `axis: y` is top/bottom.
- Ratios must be finite and between 0.1 and 0.9.
- Each pane keeps a minimum size of 20 columns × 5 rows.
- Trees can nest at most 16 levels, and a workspace holds at most 100 panes.

## Session launch and input

**Launch descriptors.** `session.start` with no `launch` uses the pane's saved shell or approved host. Starting an arbitrary executable uses a descriptor like this, and always needs `session.execute`:

```json
{"kind": "process", "executable": "/absolute/path", "arguments": [], "directory": "/absolute/path", "environment": {}}
```

- Paths must be absolute, with no NUL, and at most 4,096 bytes.
- `arguments` holds at most 256 entries of up to 64 KiB each. Processes are spawned with an argument array; no shell is involved.
- `environment` holds at most 256 entries, with keys up to 256 bytes and values up to 32 KiB. Keys starting with `TRELLIS_`, `__TRELLIS_`, `UTERM_` or `__UTERM_` are rejected.
- Environment values exist only at runtime. They're never persisted or exported.
- A launch error returns `LAUNCH_FAILED` along with a failed session record.
- A shell that has started isn't necessarily ready to accept commands yet.

**`session.sendInput`** needs `session.input`, targets a running session, and accepts up to 64 KiB of decoded payload.

- `literal` mode writes the exact bytes.
- `paste` mode adds bracketed-paste framing if the shell negotiated it.
- API input skips the UI paste review, because the grant is the authorization. Clients that want a review step have to build their own.

**`session.execute`** needs `session.execute`. It takes a single non-empty line with no NUL, CR or LF, and `submit` must be exactly `true`. Trellis appends a carriage return. The text is parsed by the shell, deliberately.

Neither `sendInput` nor `execute` waits for the command to finish, and neither returns an exit status. An agent that needs a reliable exit code should start a dedicated, non-interactive `kind: process` session and watch for its `session.exit` event.

## Theme automation

Themes follow the [theme format](../features/themes.md).

- Theme operations are global and independent of layout documents. They never start or alter a process.
- Writes need `theme.write` with all-windows scope, and follow the usual revision and idempotency rules.
- A missing theme ID returns `NOT_FOUND`. Trying to replace or delete a built-in theme returns `INVALID_STATE`.
- Appearance changes emit `appearance.changed` events to subscribers with `theme.read`.
