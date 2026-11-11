# Events (draft)

!!! warning "Draft contract — not implemented"
    Part of the proposed [protocol 2](index.md).

v1 events only described stored-snapshot differences. v2 also reports the live state the UI shows, so an orchestrator can wait for "agent needs you", "command finished" or "task done" instead of polling a terminal. Events are delivered by subscription on the socket, and by `events.poll` on any transport, including MCP.

## Envelope

```json
{"sequence": 4182, "instanceId": "…", "type": "agent.state", "topic": "agent", "at": "2026-11-11T14:02:11.402Z",
 "resource": {"kind": "session", "id": "…"}, "spaceId": "…",
 "data": {"agentId": "trellis-claude-code", "state": "needsInput", "previous": "working"}}
```

`data` holds typed JSON (numbers as numbers). Events never carry terminal output (except the `output` topic), typed input, command text, environment values or secrets.

## Topics and types

| Topic | Types | `data` | Needs |
| --- | --- | --- | --- |
| `workspace` | `space.created/updated/deleted/reordered`, `tab.created/updated/deleted/reordered/layoutChanged`, `pane.created/updated/deleted` | `revision`; `changed: [field names]` on updates | workspace.read |
| `selection` | `selection.space/tab/pane` | ids | workspace.read |
| `session` | `session.state`, `session.exited` (`exitCode`), `session.replaced` (restart: `previousId`), `session.launchChanged` (`launch.kind`) | state, ids | workspace.read |
| `attention` | `pane.needsInput` (`reason` or cleared), `pane.progress`, `pane.bell`, `tab.busy` | reason, progress | workspace.read |
| `shell` | `command.started`, `command.finished` (`exitCode`, `durationMs`), `folder.changed` (path needs session.execute) | — | workspace.read |
| `agent` | `agent.state` (`state`, `previous`), `agent.settings` (`model`, `effort`), `agent.started`, `agent.ended`, `agent.availability` | — | workspace.read |
| `remote` | `remote.link` (`state`, `attempt?`, `reason?`), `remote.helper` (`status`) | — | host.read, host in scope |
| `project` | `project.created/updated/deleted`, `project.launched` (`spaceId`, `target`) | — | project.read, project in scope |
| `task` | `task.run` (`phase`, `exitCode?`, `durationMs?`) | — | task.read |
| `host` | `host.created/updated/deleted` (`connectionRevision`) | — | host.read |
| `appearance` | `appearance.changed` | as v1 | theme.read |
| `grant` | `grant.changed` (the subscriber's own grant was edited) | `revision` | none |
| `output` | `session.output` (`base64`, `cursor`, `nextCursor`, `gap`) — not in the replay ring | — | session.output.read |

Every event whose resource lives in a space carries `spaceId` and is delivered only to grants that can see that space (the v1 docs/code disagreement about `space.*` events is settled: scoped grants get events for their own spaces; `space.reordered` needs all-spaces).

## Subscribing (socket)

`events.subscribe {topics, resourceIds?, spaceIds?, afterSequence?, instanceId?}` returns `{subscriptionId, sequence, instanceId}`; events then arrive as `events.event` notifications. `resourceIds` matches the event's resource, its pane's session, or its space. Up to 16 subscriptions per connection; the replay ring keeps the last 2,000 events; a client too far behind gets `events.gap {oldestSequence, action: "resnapshot"}` and should call `workspace.get`.

## Polling (any transport)

`events.poll {topics, spaceIds?, afterSequence?, instanceId?, timeoutMs?, limit?}` returns `{events, nextSequence, instanceId, gap?}`. It waits up to `timeoutMs` (0–25,000, default 0) for the first matching event, then returns everything available up to `limit` (default 100). It never returns `output` events — use `session.readOutput` with a cursor. A changed `instanceId` (the app restarted) means start over from `workspace.get`.

This is how MCP clients follow live state: the `events_poll` tool.

## Requirements

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| API2-07a | Live-state events are emitted by their sources. | Agent hook events, shell-integration marks, OSC 9;4, input waits, remote link changes, task run phases and project launches each produce their event within 250 ms in tests with fakes. |
| API2-07b | Events are redacted by scope and capability. | A grant without host.read gets no `remote.*`; a `created`-scope grant gets no events from other spaces; `folder.changed` has no path without session.execute; no event contains command text. |
| API2-07c | `events.poll` works on the socket and MCP. | With `timeoutMs: 2000` and an agent state change after 500 ms, the call returns that event; with none it returns empty after 2 s; a stale `afterSequence` returns `gap`. |
| API2-07d | Restarts and launch changes are visible. | `session.restart` emits `session.replaced` with `previousId`; reconfiguring a stopped pane (agent restart, host connect) emits `session.launchChanged`. |
