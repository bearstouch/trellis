# S008 — Resize, focus, and maximize panes

Priority: P0 / MVP  
Status: Planned — implementation and tests not started  
Delivery phase: 2  
Depends on: [S004](004-native-application-shell.md), [S007](007-nested-split-tree.md)  
Requirements: `FR-P02`, `FR-P04`, `MAC-06`, `NFR-U01`

## Story

As a terminal user, I want to navigate and resize my split layout with a clear focused pane.

## Acceptance criteria

- [ ] **S008-AC01:** Drag or keyboard-resize split dividers using a finite ratio between 0.1 and 0.9 while maintaining at least 20 columns by 5 rows per pane.
- [ ] **S008-AC02:** Map directional navigation to pane geometry and retain a visible focus indicator; terminal input goes to one focused pane.
- [ ] **S008-AC03:** Maximize a pane temporarily and restore the exact saved split tree/ratios without restarting hidden sessions.
- [ ] **S008-AC04:** Save the active pane per tab and use a deterministic surviving neighbor when a focused pane closes.

## Unit tests

These are test specifications to implement with the story, not executed tests. Names are proposed and may follow repository conventions once the Swift project exists. Isolate time, filesystem, process, Keychain, clipboard, and transport dependencies as relevant; assert observable behavior and failure safety.

| Test | Setup, action, and expected result |
| --- | --- |
| `S008_UT01_rejectInvalidRatios` | Submit NaN, infinity, out-of-range ratios, and geometrically impossible ratios; reject without resizing. |
| `S008_UT02_directionalFocusUsesGeometry` | Use an asymmetric mixed-axis tree; choose the nearest eligible neighbor in each direction. |
| `S008_UT03_maximizeRoundTrip` | Maximize and restore; compare all tree IDs and ratios and assert zero process lifecycle calls. |
| `S008_UT04_closedFocusChoosesSurvivor` | Close the focused leaf; focus moves to a remaining pane in the same tab or the resulting selected tab. |

## Integration and manual verification

Resize via mouse and keyboard while a full-screen terminal program runs; verify focus indicators and PTY dimensions across monitor/scale changes.

## Completion evidence

Link the implementation and passing relevant tests; record the acceptance demo and any required real-platform results. A story is complete only when its criteria and verification evidence pass. Document blockers rather than marking unavailable checks as passed.

## Source specifications

[Overview](../01-overview/README.md), [architecture](../02-architecture/README.md), [functional requirements](../03-functional-requirements/README.md), [quality requirements](../04-non-functional-requirements/README.md), [API](../05-api/README.md), [integrations](../06-integrations/README.md), [macOS support](../07-macos-support/README.md), [themes](../03-functional-requirements/themes/README.md)
