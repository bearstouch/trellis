# S007 — Create and close nested terminal splits

Priority: P0 / MVP  
Status: Planned — implementation and tests not started  
Delivery phase: 2  
Depends on: [S002](002-domain-model-and-command-service.md), [S003](003-local-pty-session.md), [S006](006-tabs-and-inline-renaming.md)  
Requirements: `FR-P01`, `FR-P03`, `FR-T03`

## Story

As a terminal user, I want to split any pane left/right or top/bottom while retaining independent sessions.

## Acceptance criteria

- [ ] **S007-AC01:** Offer Split Left/Right (axis x) and Split Top/Bottom (axis y) on every leaf, including nested leaves; preserve the existing pane as first child.
- [ ] **S007-AC02:** Assign stable IDs to new branches/panes; create a distinct session per new pane and expose launch failure without invalidating the tree.
- [ ] **S007-AC03:** Closing one leaf collapses its parent into the sibling while retaining surviving IDs; the last pane closes its tab and the last tab closes its window.
- [ ] **S007-AC04:** Reject splits beyond depth 16, the total capacity of 100 panes, or available minimum cell dimensions; failure leaves the original state intact.

## Unit tests

These are test specifications to implement with the story, not executed tests. Names are proposed and may follow repository conventions once the Swift project exists. Isolate time, filesystem, process, Keychain, clipboard, and transport dependencies as relevant; assert observable behavior and failure safety.

| Test | Setup, action, and expected result |
| --- | --- |
| `S007_UT01_mixedAxisSplitPreservesLeaf` | Split x then y; assert expected topology, first-child order, and unchanged original session ID. |
| `S007_UT02_closeCollapsesOnlyParent` | Remove a nested leaf; sibling replaces its parent and unrelated branches remain identical. |
| `S007_UT03_lastLeafCascadesToEmpty` | Close the last stopped pane in the last window; end in a valid zero-window state. |
| `S007_UT04_rejectSplitLimitsAtomically` | Try depths 16/17, totals 100/101, and insufficient cells; accept valid boundaries and leave rejected snapshots unchanged. |

## Integration and manual verification

Interact independently with a mixed-axis three-pane layout and verify terminal resize propagates to each PTY. Confirm closure safety once S009 is available.

## Completion evidence

Link the implementation and passing relevant tests; record the acceptance demo and any required real-platform results. A story is complete only when its criteria and verification evidence pass. Document blockers rather than marking unavailable checks as passed.

## Source specifications

[Overview](../01-overview/README.md), [architecture](../02-architecture/README.md), [functional requirements](../03-functional-requirements/README.md), [quality requirements](../04-non-functional-requirements/README.md), [API](../05-api/README.md), [integrations](../06-integrations/README.md), [macOS support](../07-macos-support/README.md), [themes](../03-functional-requirements/themes/README.md)
