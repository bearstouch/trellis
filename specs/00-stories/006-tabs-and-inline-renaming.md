# S006 — Manage multiple renameable tabs per window

Priority: P0 / MVP  
Status: Implemented and independently reviewed — 72-test suite and native tab checks passing  
Delivery phase: 2  
Depends on: [S002](002-domain-model-and-command-service.md), [S004](004-native-application-shell.md), [S005](005-managed-window-sidebar.md)  
Requirements: `FR-T01`, `FR-T02`, `FR-T03`, `FR-W03`

## Story

As a developer, I want to create and name several tabs within each window without losing running sessions.

## Acceptance criteria

- [x] **S006-AC01:** Each window has its own ordered top tab bar with visible separators, selected state, new-tab button, and discoverable rename action.
- [x] **S006-AC02:** Double-click or Rename edits the label inline; Enter commits trimmed nonempty text, Escape cancels, and empty input retains the previous title.
- [x] **S006-AC03:** Rename, selection, and reorder preserve pane/session IDs and live processes; switching windows restores the correct tab collection and selection.
- [x] **S006-AC04:** Duplicate copies configuration and split layout into fresh IDs and processes without copying terminal output or previously typed commands; close delegates to the common closure workflow.

## Unit tests

These are test specifications to implement with the story, not executed tests. Names are proposed and may follow repository conventions once the Swift project exists. Isolate time, filesystem, process, Keychain, clipboard, and transport dependencies as relevant; assert observable behavior and failure safety.

| Test | Setup, action, and expected result |
| --- | --- |
| `S006_UT01_renameCommitsWithoutRestart` | Rename a live tab via its edit model; update only the label/revision, retaining session IDs and zero spawn/terminate calls. |
| `S006_UT02_cancelAndEmptyRenamePreserveTitle` | Exercise Escape and whitespace-only input; original title and revision remain unchanged. |
| `S006_UT03_duplicateRemapsHierarchy` | Duplicate a mixed split tab; all new structural/session IDs are distinct while ratios and launch settings match; buffers are empty. |
| `S006_UT04_tabOrderIsWindowLocal` | Reorder tabs in window A; window B’s order and active tab do not change. |

## Integration and manual verification

Use two windows with three tabs each. Rename by pointer and keyboard, reorder, switch back, and after persistence is available verify saved titles. Duplicate into independent live sessions.

## Completion evidence

See [S006 implementation, review fixes, and native interaction evidence](../../docs/evidence/S006-tabs.md). The full 72-test suite passes. Native inline rename, reorder, and confirmed live-tab closure passed. Saved titles across relaunch are verified with persistence in S010; prior platform qualification gaps remain pending.

## Source specifications

[Overview](../01-overview/README.md), [architecture](../02-architecture/README.md), [functional requirements](../03-functional-requirements/README.md), [quality requirements](../04-non-functional-requirements/README.md), [API](../05-api/README.md), [integrations](../06-integrations/README.md), [macOS support](../07-macos-support/README.md), [themes](../03-functional-requirements/themes/README.md)
