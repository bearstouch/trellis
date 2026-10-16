# S002 — Create the authoritative workspace model

Priority: P0 / MVP  
Status: Done — reviewed; 14 workspace tests and full 30-test suite passing
Delivery phase: 1  
Depends on: None  
Requirements: `NFR-R03`, `API-03`, `FR-A02`

## Story

As a developer, I want to route UI and automation operations through one consistent domain model.

## Acceptance criteria

- [x] **S002-AC01:** Model windows, ordered tabs, binary split trees, panes, sessions, UUIDs, selection, and monotonically increasing revisions.
- [x] **S002-AC02:** Enforce one or more tabs per existing window, one or more panes per tab, and exactly two children per split; allow zero windows.
- [x] **S002-AC03:** Serialize mutations through a store actor and shared command service; invalid operations leave the entire model unchanged.
- [x] **S002-AC04:** Keep process effects outside pure tree mutation, so a launch failure becomes a failed session without dangling pane references.

## Unit tests

These are test specifications to implement with the story, not executed tests. Names are proposed and may follow repository conventions once the Swift project exists. Isolate time, filesystem, process, Keychain, clipboard, and transport dependencies as relevant; assert observable behavior and failure safety.

| Test | Setup, action, and expected result |
| --- | --- |
| `S002_UT01_rejectDanglingReferences` | Create a tree with an unknown pane ID; reject it and preserve the previous snapshot. |
| `S002_UT02_rejectMalformedSplit` | Supply zero, one, or three split children; all variants fail without mutation. |
| `S002_UT03_rejectStaleRevision` | Apply two changes using the same revision; only the first commits and the second conflicts. |
| `S002_UT04_failedLaunchKeepsValidPane` | Inject a failed launch effect after creation; retain the pane and its failed session with valid ownership links. |

## Integration and manual verification

Exercise concurrent mutations against the real actor; compare UI and service snapshots for equivalent operations.

## Completion evidence

See [S002 evidence](../../docs/evidence/S002-workspace-model.md) for implementation boundaries, tests, review findings, and final verification.

Link the implementation and passing relevant tests; record the acceptance demo and any required real-platform results. A story is complete only when its criteria and verification evidence pass. Document blockers rather than marking unavailable checks as passed.

## Source specifications

[Overview](../01-overview/README.md), [architecture](../02-architecture/README.md), [functional requirements](../03-functional-requirements/README.md), [quality requirements](../04-non-functional-requirements/README.md), [API](../05-api/README.md), [integrations](../06-integrations/README.md), [macOS support](../07-macos-support/README.md), [themes](../03-functional-requirements/themes/README.md)
