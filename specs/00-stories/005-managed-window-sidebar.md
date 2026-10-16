# S005 — Manage windows from the sidebar

Priority: P0 / MVP  
Status: Implemented with independent review fixes — 64-test suite passing; native interaction qualification pending  
Delivery phase: 2  
Depends on: [S002](002-domain-model-and-command-service.md), [S004](004-native-application-shell.md)  
Requirements: `FR-W01`, `FR-W02`, `FR-W03`, `FR-W04`

## Story

As a developer, I want to organize independent groups of terminal tabs in named sidebar windows.

## Acceptance criteria

- [x] **S005-AC01:** Create, rename, reorder, select, and delete managed windows; creation includes one tab and one pane.
- [x] **S005-AC02:** Preserve each window’s active tab/pane when switching; inactive sessions continue running with the same IDs.
- [x] **S005-AC03:** Show bounded activity and exit indicators for inactive windows without stealing selection.
- [x] **S005-AC04:** Deleting the last window reaches the empty state; live-session deletion uses the common closure workflow rather than bypassing it.

## Unit tests

These are test specifications to implement with the story, not executed tests. Names are proposed and may follow repository conventions once the Swift project exists. Isolate time, filesystem, process, Keychain, clipboard, and transport dependencies as relevant; assert observable behavior and failure safety.

| Test | Setup, action, and expected result |
| --- | --- |
| `S005_UT01_createInitialHierarchy` | Create one window; assert exactly one initial tab, pane, and session record with distinct valid IDs. |
| `S005_UT02_switchRestoresSelection` | Select different tabs/panes in two windows; switch back and recover each stored selection. |
| `S005_UT03_reorderIsPermutation` | Submit missing, repeated, and unknown IDs; reject each invalid order atomically. |
| `S005_UT04_inactiveOutputDoesNotSelect` | Deliver many output/activity notifications to an inactive window; retain the active window and bounded indicator state. |

## Integration and manual verification

Run background output, change sidebar selection, and verify output continues. After persistence is available, restart and confirm order and names.

## Completion evidence

See [S005 implementation and review evidence](../../docs/evidence/S005-managed-windows.md). Behavior is covered by nine story tests and the full 64-test suite. Native context-menu/dialog interaction and later persistence qualification remain pending; acceptance checkboxes describe implemented/tested behavior, not completed release qualification.

## Source specifications

[Overview](../01-overview/README.md), [architecture](../02-architecture/README.md), [functional requirements](../03-functional-requirements/README.md), [quality requirements](../04-non-functional-requirements/README.md), [API](../05-api/README.md), [integrations](../06-integrations/README.md), [macOS support](../07-macos-support/README.md), [themes](../03-functional-requirements/themes/README.md)
