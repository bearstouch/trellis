# S009 — Close and restart sessions safely

Priority: P0 / MVP  
Status: Implemented and independently reviewed — 98 tests and native close/restart checks pass
Delivery phase: 2  
Depends on: [S003](003-local-pty-session.md), [S005](005-managed-window-sidebar.md), [S006](006-tabs-and-inline-renaming.md), [S007](007-nested-split-tree.md)  
Requirements: `FR-S03`, `FR-T03`, `MAC-04`, `NFR-R01`

## Story

As a terminal user, I want to understand what will stop before closing panes, tabs, windows, or the app.

## Acceptance criteria

- [x] **S009-AC01:** Running-session closure presents one affected-session summary per action; cancel sends no termination signal and changes no structure.
- [x] **S009-AC02:** After explicit acceptance, gracefully terminate only owned process groups, wait up to two seconds, and offer force termination when needed.
- [x] **S009-AC03:** Automation returns CONFIRMATION_REQUIRED without allowRunning authorization and CLOSE_PENDING after the grace interval; force requires a separate explicit request.
- [x] **S009-AC04:** Reap children and close descriptors exactly once. Restart creates a fresh session UUID in the same pane; exited output remains inspectable until restart. Remote detached processes are not reported as terminated.

## Unit tests

These are test specifications to implement with the story, not executed tests. Names are proposed and may follow repository conventions once the Swift project exists. Isolate time, filesystem, process, Keychain, clipboard, and transport dependencies as relevant; assert observable behavior and failure safety.

| Test | Setup, action, and expected result |
| --- | --- |
| `S009_UT01_cancelHasNoEffects` | Cancel closure of a three-session window; process spy sees no signals and the tree remains unchanged. |
| `S009_UT02_graceTimeoutRequiresExplicitForce` | Advance a fake clock by two seconds with a non-exiting child; return pending without a kill until explicit force. |
| `S009_UT03_neverSignalReusedPid` | Replace ownership identity before cleanup; refuse to signal an unrelated reused process ID. |
| `S009_UT04_restartReplacesOnlySession` | Restart an exited pane; retain pane/tab IDs, assign one new session ID, and clear old runtime buffers. |

## Integration and manual verification

Close running local and controlled SSH sessions, test a child that ignores graceful termination, and verify quit/native-window-close summaries and descriptor cleanup.

## Completion evidence

See [S009 implementation, review fixes, and verification evidence](../../docs/evidence/S009-session-safety.md). All 98 tests pass. Native restart, Cancel, Keep Waiting, and explicit Force Stop checks passed. Controlled SSH close qualification remains pending its integration story; automation result codes are tested at the shared lifecycle policy boundary, with transport/grant wiring in later stories.

## Source specifications

[Overview](../01-overview/README.md), [architecture](../02-architecture/README.md), [functional requirements](../03-functional-requirements/README.md), [quality requirements](../04-non-functional-requirements/README.md), [API](../05-api/README.md), [integrations](../06-integrations/README.md), [macOS support](../07-macos-support/README.md), [themes](../03-functional-requirements/themes/README.md)
