# S007 nested terminal splits

Date: 2026-10-16. Implemented and independently reviewed; native mixed-axis interaction verified.

## Implementation

Each pane has Split Left/Right, Split Top/Bottom, and Close Pane controls. The recursive native terminal canvas renders mixed-axis trees, preserving the existing pane as the first child when it splits. New branches, panes, and sessions receive distinct IDs. A launch failure is represented in its own pane without destroying the layout or restarting a sibling.

Closing a leaf uses the shared session confirmation/drain workflow, removes only its session, and collapses its parent into its sibling. The final leaf closes its tab, and the final tab closes its managed window. Survivor IDs are retained.

The store rejects depth above 16, more than 100 total panes, and split allocations below 20 columns by 5 rows per child. Rejected changes are atomic. Native controls also validate their available canvas including pane headers. Small windows retain the tree in the minimum scrollable canvas. Focused panes have a blue border; a terminal mouse click records its active pane through the supported engine mouse handler.

## Tests

Final full suite: **81 tests passed, zero failures**. Nine S007 tests cover mixed-axis topology/session identity, local parent collapse, final-leaf cascade, accepted/rejected depth/capacity/cell boundaries, a failed new launch preserving the original pane, and a canvas-size rejection before mutation.

Review fixed committed split results being dropped during concurrent closure, native references surviving a deleted hierarchy, and focus moving outside the immediate sibling. Concurrent split/close-pane and split/close-tab regressions pass.

Native mixed-axis testing exposed a blank surviving terminal after parent collapse. A real NSHostingView regression reproduced it before the fix. Native hosts now reconcile cached terminal attachment after SwiftUI finishes replacing the tree; the regression passes. The corrected isolated native build passed: split left/right then split its right pane top/bottom; send distinct input to each right-hand pane; confirm independent 14×49 PTY dimensions; close the bottom live pane with the common confirmation; retain the top pane’s terminal ID, output, focus, and input; verify its PTY expands to 29×49 after collapse. The disposable shell then exited cleanly.

Divider dragging, directional focus, and maximize belong to S008. Existing physical display/input qualification gaps remain outstanding.
