# S004 — Build the Native calm application shell

Priority: P0 / MVP  
Status: Implemented and independently reviewed — native lifecycle/display qualification pending  
Delivery phase: 2  
Depends on: [S001](001-terminal-engine-feasibility.md), [S002](002-domain-model-and-command-service.md)  
Requirements: `MAC-03`, `MAC-04`, `MAC-05`, `MAC-06`, `FR-W04`

## Story

As a macOS user, I want to see a familiar native app with a window sidebar and a separate tab bar.

## Acceptance criteria

- [ ] **S004-AC01:** Provide one terminal-bearing native window with sidebar, per-workspace top tab bar, settings, menu bar, Dock behavior, and an empty-state creation action.
- [x] **S004-AC02:** Use native system fonts for application chrome and start with light chrome; keep terminal styling delegated to the terminal adapter.
- [x] **S004-AC03:** Disable automatic macOS window tabbing so application tabs belong exclusively to the workspace model.
- [ ] **S004-AC04:** Support minimize, full screen, monitor changes, and restored geometry constrained to available displays; undersized terminal areas preserve their split tree using the specified minimum canvas.

## Unit tests

These are test specifications to implement with the story, not executed tests. Names are proposed and may follow repository conventions once the Swift project exists. Isolate time, filesystem, process, Keychain, clipboard, and transport dependencies as relevant; assert observable behavior and failure safety.

| Test | Setup, action, and expected result |
| --- | --- |
| `S004_UT01_emptyStateProjection` | Project a model with zero windows; show the welcome state and its create action. |
| `S004_UT02_selectedWindowOwnsTabBar` | Project two windows; the visible tab bar contains only the selected window’s ordered tabs. |
| `S004_UT03_constrainOffscreenGeometry` | Restore a rectangle outside the current display union; clamp it into an available display. |
| `S004_UT04_smallCanvasRetainsLayout` | Provide dimensions below pane minima; request a minimum-sized canvas without deleting or rewriting split nodes. |

## Integration and manual verification

Inspect the native app in full screen, on Retina and available external displays, and after disconnecting a monitor. Verify menu and Dock behavior manually.

## Completion evidence

See [S004 implementation, review, and test evidence](../../docs/evidence/S004-native-shell.md). All 55 tests pass. AC01 and AC04 remain unchecked for unperformed native lifecycle and display qualification; implementation continues under the user’s explicit instruction.

## Source specifications

[Overview](../01-overview/README.md), [architecture](../02-architecture/README.md), [functional requirements](../03-functional-requirements/README.md), [quality requirements](../04-non-functional-requirements/README.md), [API](../05-api/README.md), [integrations](../06-integrations/README.md), [macOS support](../07-macos-support/README.md), [themes](../03-functional-requirements/themes/README.md)
