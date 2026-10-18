# Output and events (API-05)

## Reading output

`session.readOutput` needs `session.output.read`. The `view` parameter is required:

| View | Returns | Notes |
| --- | --- | --- |
| `screen` | `{view, text, capturedAt, truncated, historyNotice}` | Plain text of the visible screen, with terminal controls stripped |
| `scrollback` | Same as `screen` | Plain text of the retained history. If it's too long, the newest text is kept up to `maxBytes`. |
| `stream` | `{view, base64, nextCursor, truncated, gap, capturedAt}` | Raw PTY bytes, base64-encoded, starting from an opaque cursor |

- `maxBytes` defaults to 64 KiB and can go up to 256 KiB.
- `screen` and `scrollback` are display snapshots. They can't be used to reconstruct every byte the process wrote.
- `stream` bytes are raw and untrusted. Escape sequences are the caller's problem, and so is a UTF-8 character split across two reads.
- Stream cursors belong to one session UUID and one app instance. A cursor from another session or instance returns `INVALID_CURSOR`, and a restart invalidates every cursor.
- When output older than the cursor has been evicted, the response sets `gap: true`.

The output journal behind `stream` is an in-memory ring with a global budget of **8 MiB** shared by all sessions. The oldest output is evicted first, and the journal is never persisted. Output replayed from the session broker when a kept session is reattached (FR-R03), and text restored from the scrollback file (FR-R04), are display only: they never enter the journal and are never streamed. A reattached session's journal starts with its first live output.

## Subscribing to events

`events.subscribe` takes `topics` (required, non-empty), `resourceIds?`, `afterSequence?` and `instanceId?`. It returns `{subscriptionId, sequence, instanceId}`. A connection can have up to 16 subscriptions.

| Topic | Aliases | Event types | Extra capability |
| --- | --- | --- | --- |
| `resources` | `resource` | `window.created/updated/deleted/reordered`, `tab.created/updated/deleted/layoutChanged`, `pane.created/deleted` | — |
| `selection` | — | `selection.window`, `selection.tab`, `selection.pane` | — |
| `session` | `session.state`, `session.exit` | `session.state` (`state`, `paneId`), `session.exit` (adds `exitCode`) | — |
| `output` | `session.output` | `session.output` (`base64`, `cursor`, `nextCursor`, `gap`) | `session.output.read` |
| `appearance` | `appearance.changed` | `appearance.changed` (`mode`, `lightThemeId`, `darkThemeId`, `effectiveThemeId`, `revision`) | `theme.read` |

Every subscription needs `metadata.read`. `window.*` events are delivered only to grants with all-windows scope, and every other metadata event is filtered by scope.

Events arrive as JSON-RPC notifications named `event`:

```json
{"jsonrpc":"2.0","method":"event","params":{"subscriptionId":"…","sequence":42,"instanceId":"…","timestamp":"…","type":"session.exit","resourceId":"…","data":{"state":"exited","paneId":"…","exitCode":"0"}}}
```

`data` values are strings. Output events carry no `sequence`, because output isn't stored in the metadata ring.

## Replay, gaps and slow clients

- Metadata events are kept in a **1,000-event replay ring**. Pass `afterSequence`, along with the `instanceId` you got it from, to resume. An `afterSequence` ahead of the current sequence, or an `instanceId` that doesn't match, returns `INVALID_CURSOR`.
- If the events you asked for have already left the ring, the server sends an `events.gap` notification with `{subscriptionId, instanceId, oldestSequence, action: "resnapshot"}`. When you get one, list the resources again before trusting your local state.
- At most 8 MiB of output can be in flight to clients at once. Output events beyond that are dropped, and the next one sent has `gap: true` set.
- Each connection has a 1 MiB outbound queue. A client that falls further behind is disconnected.
- Restarting the app changes the instance ID and invalidates every sequence and cursor.

Subscriptions aren't a lossless audit log. A correct client detects gaps and resynchronizes, and never assumes it has seen the complete history (`FR-A05`).
