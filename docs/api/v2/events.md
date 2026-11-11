# Events (draft)

!!! warning "Draft contract — not implemented"
    Part of the proposed [protocol 2](index.md). Built in [phase 4](implementation.md#progress) behind `--automation-v2`; every requirement stays unchecked until v2 ships.

v1 events only described stored-snapshot differences. v2 also reports the live state the UI shows, so an orchestrator can wait for "agent needs you", "command finished" or "task done" instead of polling a terminal. Events are delivered by subscription on the socket, and by `events.poll` on any transport, including MCP.

## Envelope

```json
{"sequence": 4182, "instanceId": "…", "type": "agent.state", "topic": "agent", "at": "2026-11-11T14:02:11.402Z",
 "resource": {"kind": "session", "id": "…"}, "spaceId": "…",
 "data": {"paneId": "…", "agentId": "trellis-claude-code", "state": "needsInput", "previous": "working"}}
```

`data` holds typed JSON (numbers as numbers). Events never carry terminal output (except the `output` topic), typed input, command text, environment values or secrets. `resource.id` is a lowercase UUID, an agent or task ID, or absent where there is no single resource (`space.reordered`: `{"kind": "workspace"}`; `appearance.changed`). `spaceId` is present on every event whose resource lives in a space. A pushed event also carries its `subscriptionId`.

Protocol 2 has its **own stream**: its own `sequence` (from 1 per app instance) and its own replay ring of the last **2,000** events, separate from protocol 1's (whose topics, ring of 1,000, string data and aliases are unchanged until the switch).

## Topics and types

| Topic | Types | `data` | Needs |
| --- | --- | --- | --- |
| `workspace` | `space.created/updated/deleted/reordered`, `tab.created/updated/deleted/reordered/layoutChanged`, `pane.created/updated/deleted` | `revision` (spaces and tabs; `space.reordered`: the workspace's); `changed: [field names]` on updates (space: `name`, `tabIds`, `activeTabId`, `project`, `machine`; tab: `title`, `color`, `activePaneId`, `projectKey`; pane: `title`, `sessionId`, `focused`, `maximized`); panes carry `tabId` (and `sessionId` when created). `tab.reordered`'s resource is the space | workspace.read |
| `selection` | `selection.space/tab/pane` | resource is the selected one; `selection.pane` has `tabId` | workspace.read |
| `session` | `session.state` (`state`, `previous`), `session.exited` (`state`, `exitCode`), `session.replaced` (restart: `previousId`), `session.launchChanged` (`launch.kind`) | all carry `paneId` | workspace.read |
| `attention` | `pane.needsInput` (`reason`: `password` or `attention`, or `cleared: true`; a bell is `attention`, FR-T06), `pane.progress` (`state`, `percent?`, or `cleared: true`), `tab.busy` (`busy`) | pane events carry `sessionId` | workspace.read |
| `shell` | `command.started`, `command.finished` (`exitCode?`, `durationMs`), `folder.changed` (`path`, which needs session.execute) | resource is the session; `paneId` | workspace.read |
| `agent` | `agent.state` (`state`, `previous`), `agent.settings` (`model?`, `effort?`), `agent.started`, `agent.ended`, `agent.availability` (`status`: installed, missing, checking or unknown; `hostId` for a host) | `agentId`; pane-level ones are about the session and carry `paneId` | workspace.read (+ the host's rules for a host's availability) |
| `remote` | `remote.link` (`state`, `attempt?`, `nextAttemptAt?`), `remote.helper` (`status`: current, outdated, missing, unsupported or unknown) | resource is the host | host.read, host in scope at its current connection |
| `project` | `project.created/updated/deleted` (`revision`, `changed?`), `project.launched` (`spaceId`, `target.kind`, `hostId?`, `folder?`) | — | project.read, project in scope |
| `task` | `task.run` (`phase`: submitted, running, finished or cancelled; `exitCode?`, `durationMs?`) | resource is the task ID; `paneId`, `sessionId` | task.read |
| `host` | `host.created/updated/deleted` (`connectionRevision`, `revision`, `changed?`) | — | host.read, host approved |
| `appearance` | `appearance.changed` | `mode`, `lightThemeId`, `darkThemeId`, `effectiveThemeId`, `revision` | theme.read |
| `grant` | `grant.changed` (the subscriber's own grant was edited) | `revision` | none |
| `output` | `session.output` (`base64`, `cursor`, `nextCursor`, `gap`) — not in the replay ring, no `sequence` | — | session.output.read |

## Delivery and redaction (API2-07b)

Every delivery (push, replay or poll) re-reads the grant and checks the event against it, so revocation, expiry and a narrowing edit apply to the very next event.

- **Topic capability:** the topic's capability in the table above.
- **Space scope:** every event whose resource lives in a space carries `spaceId` and is delivered only to grants that can see that space, including a `created` scope's own spaces (the v1 docs/code disagreement about `space.*` events is settled: scoped grants get events for their own spaces); a closed space's events, its `space.deleted` included, stay visible in polls and replays to the grant that created it after the space left its scope). `space.reordered` reveals every space's place, so it needs all-spaces scope.
- **Host scope:** `remote.*` and a host's `agent.availability` need host.read and the host approved **at its current connection revision**; `host.*` needs host.read and the host approved at all, so a grant learns that its approval went stale.
- **Project scope:** `project.*` needs project.read and the project in project scope.
- **Fields:** `folder.changed`'s `path` and `project.launched`'s `folder` need session.execute; `project.launched`'s `hostId` needs the host in scope. Without them the field is omitted and the event is still delivered.
- **Never sent:** command lines, program names, task commands, project commands and folders in `project.updated` (only the names of changed fields), environment values, the path an agent was found at, and remote link reasons (UI text in the user's language until [phase 6](implementation.md#phases) adds machine-readable ones).
- **Volume:** live status — `pane.needsInput`, `pane.progress`, `tab.busy`, `agent.state` and `agent.settings` — is coalesced per resource and type: the first change goes out at once, later ones within **250 ms** wait, and only the latest is sent when the window ends (the final state is never dropped, and it goes out before an event that ends its resource — `pane.deleted`, `tab.deleted`, `space.deleted`, `session.replaced`, `session.exited`, `agent.ended`; a change back to what was last sent is nothing). `agent.state`'s `previous` is the state clients were last told. Shell events are one per mark, never coalesced and never per output chunk. Marks replayed from a kept session (FR-R03) describe commands that ran while Trellis was closed and produce no events.

## Subscribing (socket)

`events.subscribe {topics, resourceIds?, spaceIds?, afterSequence?, instanceId?}` returns `{subscriptionId, sequence, instanceId}`; events then arrive as `events.event` notifications. It needs each requested topic's capability (`PERMISSION_DENIED` with `details.missing` otherwise) and is socket-only: MCP follows events with `events_poll`.

Replayed events (from `afterSequence`) are pushed **before** the `events.subscribe` reply, as in v1, so a client may see `events.event` notifications carrying a `subscriptionId` it hasn't been told yet. Buffer them until the reply arrives, then match on `subscriptionId`.

- `resourceIds` names spaces, tabs, panes or sessions in scope and matches the event's resource, its pane, session or tab, or its space. `spaceIds` matches the event's space; events without one (hosts, projects, appearance, grant, this Mac's agent availability) never match a space filter.
- Up to 16 subscriptions per connection. With `afterSequence`, retained matching events after it are replayed first (each once); a client too far behind gets `events.gap {subscriptionId, instanceId, oldestSequence, action: "resnapshot"}` and should call `workspace.get`. An `afterSequence` newer than the stream, or an `instanceId` from another app instance, is `INVALID_CURSOR`.
- `events.unsubscribe {subscriptionId}` returns `{deleted: {kind: "subscription", id}}`; another connection's subscription is `NOT_FOUND`.
- A slow client whose outbound queue passes 1 MiB is disconnected and loses its subscriptions.
- When the grant is edited, `grant.changed` reaches its own subscribers first; then, for a narrowing edit, subscriptions whose topics the grant may no longer follow end. Others stay and are filtered per event.

## Polling (any transport)

`events.poll {topics, spaceIds?, afterSequence?, instanceId?, timeoutMs?, limit?}` returns `{events, nextSequence, instanceId, gap?}`. It waits up to `timeoutMs` (0–25,000, default 0) for the first matching event the grant may see, then returns everything available up to `limit` (1–500, default 100). Without `afterSequence` it starts from now.

- `nextSequence` is what to pass as `afterSequence` next: the last returned event, or the newest event scanned (events the filter skipped are never scanned again).
- A stale `afterSequence` (evicted from the ring) returns no events, `gap: {oldestSequence, action: "resnapshot"}` and `nextSequence` at the stream's end: read `workspace.get`, then poll from there. A changed `instanceId` (the app restarted) is `INVALID_CURSOR` with `details.instanceId`: start over from `workspace.get`.
- It never returns `output` events (`topics: ["output"]` is `-32602`) — use `session.readOutput` with a cursor.
- A waiting poll suspends only itself: on the socket it is answered out of order (JSON-RPC replies carry their `id`) while the connection keeps serving later frames, and it never holds the main actor. At most **4** polls may wait per grant at once; more is `LIMIT_EXCEEDED` (retryable). Revocation ends a waiting poll with `AUTH_REQUIRED`, and closing the connection cancels it.

This is how MCP clients follow live state: the `events_poll` tool.

## Requirements

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| API2-07a | Live-state events are emitted by their sources. | Agent hook events, shell-integration marks, OSC 9;4, input waits, remote link changes, task run phases and project launches each produce their event within 250 ms in tests with fakes. |
| API2-07b | Events are redacted by scope and capability. | A grant without host.read gets no `remote.*`; a `created`-scope grant gets no events from other spaces; `folder.changed` has no path without session.execute; no event contains command text. |
| API2-07c | `events.poll` works on the socket and MCP. | With `timeoutMs: 2000` and an agent state change after 500 ms, the call returns that event; with none it returns empty after 2 s; a stale `afterSequence` returns `gap`. |
| API2-07d | Restarts and launch changes are visible. | `session.restart` emits `session.replaced` with `previousId`; reconfiguring a stopped pane (agent restart, host connect) emits `session.launchChanged`. |
