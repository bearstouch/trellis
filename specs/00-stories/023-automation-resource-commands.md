# S023 — Expose resource commands with revisions and idempotency

Priority: P0 / MVP  
Status: Planned — implementation and tests not started  
Delivery phase: 4  
Depends on: [S005](005-managed-window-sidebar.md), [S006](006-tabs-and-inline-renaming.md), [S007](007-nested-split-tree.md), [S008](008-pane-resize-focus-and-maximize.md), [S009](009-safe-session-close-and-restart.md), [S018](018-saved-host-library.md), [S021](021-local-control-socket.md), [S022](022-automation-grants.md)  
Requirements: `FR-A01`, `FR-A02`, `API-03`, `API-04`, `API-06`

## Story

As a script author, I want to manage windows, tabs, panes, and hosts with stable IDs and predictable conflicts.

## Acceptance criteria

- [ ] **S023-AC01:** Implement the catalogued window/tab/pane/host metadata and mutation methods, plus session.get and system.info, through the shared command service.
- [ ] **S023-AC02:** Return IDs/revisions/ownership and permission-appropriate fields; UI and API mutations obey identical tree/lifecycle rules.
- [ ] **S023-AC03:** API creation makes stopped panes unless start is explicitly requested and authorized; running closure requires allowRunning plus session.close.
- [ ] **S023-AC04:** Apply expectedRevision conflicts atomically; deduplicate identical keyed mutations for ten minutes per grant/instance and reject reused keys with different parameters.

## Unit tests

These are test specifications to implement with the story, not executed tests. Names are proposed and may follow repository conventions once the Swift project exists. Isolate time, filesystem, process, Keychain, clipboard, and transport dependencies as relevant; assert observable behavior and failure safety.

| Test | Setup, action, and expected result |
| --- | --- |
| `S023_UT01_apiCreatesStoppedHierarchy` | Create window/tab/split through RPC; assert returned relationships and zero spawn calls by default. |
| `S023_UT02_staleMutationHasNoEffects` | Mutate at revision N then submit another at N; return CONFLICT and preserve the committed state. |
| `S023_UT03_idempotencyKeyScopeAndExpiry` | Repeat a mutation before/after ten minutes and across grants/instances; deduplicate only within the documented scope/window. |
| `S023_UT04_apiUiDomainEquivalence` | Apply equivalent UI and API operations to separate fixture stores; compare resulting domain state after normalizing generated IDs. |

## Integration and manual verification

Run clients that race revisions, disconnect after a mutation, close live containers without authorization, and inspect redacted metadata. Verify the full method inventory, not only creation.

## Completion evidence

Link the implementation and passing relevant tests; record the acceptance demo and any required real-platform results. A story is complete only when its criteria and verification evidence pass. Document blockers rather than marking unavailable checks as passed.

## Source specifications

[Overview](../01-overview/README.md), [architecture](../02-architecture/README.md), [functional requirements](../03-functional-requirements/README.md), [quality requirements](../04-non-functional-requirements/README.md), [API](../05-api/README.md), [integrations](../06-integrations/README.md), [macOS support](../07-macos-support/README.md), [themes](../03-functional-requirements/themes/README.md)
