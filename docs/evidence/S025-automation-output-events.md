# S025 automation output and events

Date: 2026-10-16. Implemented with independent review and fixes. Covered by automated Core, hub, and real-PTY end-to-end tests. Manual multi-client checks are **pending**.

## Behavior

### Reading output

**`session.readOutput`** requires `session.output.read` and takes a view of `screen`, `scrollback`, or `stream`.

- **Screen and scrollback** return plain text from the terminal engine, with no control sequences, plus `capturedAt` and the history notice. They keep the newest text within `maxBytes`, cut on a character boundary, and set `truncated`.
- **Stream** returns base64 of the exact raw PTY bytes, plus `nextCursor`, `truncated`, `gap`, and `capturedAt`. Without a cursor it starts at the oldest retained byte; `gap` is set if earlier bytes were already evicted.
- **Size limits:** `maxBytes` defaults to 64 KiB and allows 1–262,144 bytes; anything else returns `-32602`.

### Stream cursors

Cursors are opaque `oc1_…` tokens that encode the instance, the session, and an absolute offset.

- A cursor from another session, from a session replaced by a restart, or from another app instance returns `INVALID_CURSOR`.
- A cursor past the end, or malformed, also returns `INVALID_CURSOR`.
- A cursor that points into evicted output returns data from the oldest retained byte with `gap: true`.

### Output journal

`OutputJournal` lives in memory only.

- It shares one 8 MiB budget across all sessions and evicts oldest-first.
- Small reads are merged into chunks of up to 16 KiB, so accounting stays O(1) per append.
- A replaced or closed session's output is dropped immediately, and late PTY bytes from such a session are ignored.

### Events

`WorkspaceEvents.diff` derives ordered events from every published snapshot:

- removals
- creations and updates
- pure reorders
- layout changes
- session state and exit transitions
- selection changes

Event data contains only revisions, states, exit codes, and related IDs: never launch details or terminal text.

`EventHub` handles subscriptions:

- **Ring:** keeps 1,000 metadata events with gap-free sequence numbers.
- **`events.subscribe`:** takes topics `resources`, `selection`, `session`, and `output`, with aliases such as `session.state` and `session.output`. It also accepts optional UUID `resourceIds`, an `afterSequence`, and an optional `instanceId`. Malformed IDs return `-32602`, and a different instance returns `INVALID_CURSOR`.
- **Replay and gaps:** if `afterSequence` was already evicted, the hub sends `events.gap` with `oldestSequence` and `action: "resnapshot"`. A future sequence returns `INVALID_CURSOR`.
- **Delivery checks:** every delivery re-checks that the grant is active, so an expired or revoked grant stops observation. A subscription removed while a delivery is in progress is never delivered to.
- **Scope:** delivery is filtered by window scope and the resource filter.
- **Output events:** need `session.output.read` and window scope. They are never stored in the ring, and each carries its start and next cursors.
- **Limits:** at most 16 subscriptions per connection. Unsubscribing, disconnecting, or revoking the grant removes subscriptions.

`EventForwarder` feeds the hub from a single FIFO consumer, so delivery order matches workspace order.

- Metadata is never dropped.
- Output in flight is limited to 8 MiB. Skipped output marks the session's next event with `gap: true`, and readers can backfill through cursors.

### Slow clients

Each connection has an `Outbox` drained by its own writer thread. Replies and events share it, which keeps their order. Exceeding 1 MiB queued disconnects the client immediately and drops the queue.

## Tests

- `testS025_UT01_cursorEvictionReportsGap`: global oldest-first eviction across sessions, the gap and next offset after eviction, resume reads, errors for reads past the end and for unknown sessions, and eviction alignment after a session is removed.
- `testS025_UT02_readLimitsAndBinaryBoundaries`: split UTF-8 and binary bytes come back exact, the 64 KiB first page is truncated, and the remainder concatenates to the original.
- `testS025_UT03_metadataReplayGap`: after 1,001 events, sequence 0 gets `events.gap` (oldest 2, resnapshot), sequence 1 replays 2…1,001 in order, and a future sequence returns `INVALID_CURSOR`.
- `testS025_UT04_slowOrRevokedSubscriberStops`: a fake 2,000-byte queue budget drops the subscriber and stops output delivery; revocation stops delivery at the next event.
- Hub tests:
  - window-scope and output-capability redaction
  - cursor token round trip and rejection of garbage
  - a real socket client that stops reading is disconnected at the 1 MiB budget
- End to end, through a real PTY and the RPC path:
  - exact bytes `C3 A9 00 FF` plus text across a split write
  - an empty read at the cursor, and `maxBytes: 2`
  - screen and scrollback views, and `maxBytes` 0, 1.5, and 262,145 rejected
  - garbage, foreign, and pre-restart cursors return `INVALID_CURSOR`
  - restart drops the journal
  - model diff events fire for API mutations
- Review tests:
  - 200,000 one-byte appends stay within budget and retain the newest bytes
  - output events carry a start cursor and a gap flag, and stop after unsubscribe

Full suite: **268 tests passed, 0 failures**. Lint is clean, the build has zero warnings, and the app packages and verifies.

## Independent review

The review fixed four issues:

1. The journal did quadratic main-actor work, and its memory grew with the number of reads instead of bytes.
2. Hub reentrancy delivered events to subscriptions removed during an await.
3. Output events skipped under backpressure left gaps clients could not see.
4. Late output recreated journals and window-less output events for closed sessions.

It also made scrollback truncation cheaper and the session-state diff cheaper.

I added strict `resourceIds` validation and `instanceId` checking on subscribe.

Follow-ups, not applied:

- The subscribe reply can arrive after replayed events that already carry its `subscriptionId`.
- A client that half-closes and never reads, while under the 1 MiB budget, can keep a connection slot.
- Many pipelined `readOutput` requests in one read allocate their combined reply before the overflow check.
- `ISO8601DateFormatter` is created per event.

## Pending manual verification

These checks were not performed and are **not** marked passed:

- Run several real clients subscribed while panes are created and closed in the UI.
- Run a slow reader against heavy output (for example, `yes`).
- Observe revocation ending a live subscription in the app.
