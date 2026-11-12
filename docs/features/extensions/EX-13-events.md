# EX-13: Events, including agent.state, task.state and repository.changed

Part of the [Extensions specification](SPEC.md#stories). **Epic:** 3, Tier 0 · **Phase:** 3b · **Requirements:** FR-EX11, FR-EX28 · **Depends on:** [EX-7](EX-07-extension-supervisor.md), [EX-8](EX-08-grant-resolving.md) · **Points:** 5

**Definition.** As an extension author, I want to subscribe to the Trellis events my manifest declares, including agent, task and repository changes, so that my extension reacts as things happen.

Events come from `EventHub`, the same source as API clients. Extensions get only the events their manifest lists, and each still needs its capability. Three new events, `agent.state`, `task.state` and `repository.changed`, are added for automation clients too.

## Scope

**In**

- `trellis.events.subscribe(name, fn)` returning an unsubscribe function, refused for undeclared names.
- The event table: `space.*`, `tab.*`, `pane.*`, `selection.*`, `session.state`, `session.exit`, `session.output` (needs `session.output.read`, prompted), `agent.state`, `task.state`, `repository.changed`, `appearance.changed`, `command.<id>`, `notification.clicked`.
- New `WorkspaceEvents` topics `agent.state` (`working`, `needsYou`, `ready`, `exited`), `task.state` and `repository.changed`, delivered to API clients as well.
- A synthetic EventHub connection ID per extension. The delivery closure in `AppMain` routes extension IDs to the extension host and every other ID to `control.push`.
- Replay and gaps as for API clients: an extension that falls behind the 1,000-event ring gets `events.gap`.
- Subscriptions end when the extension is disabled, reloaded or suspended.

**Out**

- The supervisor's queue overflow (EX-7), which also yields `events.gap`.
- `command.<id>` and `notification.clicked` producers (EX-14, EX-17).

## Acceptance criteria

- [ ] **Given** an event not in the manifest, **when** the extension subscribes, **then** the subscription is refused.
- [ ] **Given** a declared `session.output`, **when** the extension subscribes without `session.output.read`, **then** it gets nothing until that permission is granted and prompted.
- [ ] **Given** an agent pane changes to Needs you, **when** subscribed to `agent.state`, **then** the extension receives `needsYou` for that pane.
- [ ] **Given** a task run starts and finishes, **when** subscribed to `task.state`, **then** both are delivered.
- [ ] **Given** the focused repository's branch or changed-file count changes, **when** subscribed to `repository.changed` with `git.read`, **then** it is delivered.
- [ ] **Given** an API client subscribed to the new topics, **when** they occur, **then** it receives them as documented in `docs/api/events.md`.
- [ ] **Given** an extension falls behind the 1,000-event ring, **when** it catches up, **then** it gets `events.gap`.
- [ ] **Given** the extension is disabled, **when** the next event is delivered, **then** it doesn't reach the extension.

## Implementation notes

- Changed in `TrellisCore`: `Sources/TrellisCore/WorkspaceEvents.swift` (new topics).
- Changed in `TrellisControl`: `Sources/TrellisControl/EventHub.swift` (new topics, `GrantResolving` from EX-8).
- Changed in `TrellisApp`: the delivery router at `events.setDelivery` in `Sources/TrellisApp/AppMain.swift`.
- Agent states come from `Sources/TrellisCore/AgentState.swift`; task runs from `Sources/TrellisUI/AppWorkspaceModel+Tasks.swift`.

## Tests

- `ExtensionEventTests`: undeclared events refused; capability still required; new event types; gap; stop on disable.
- Additions to `Tests/TrellisControlTests/EventHubTests.swift` for the new topics.
