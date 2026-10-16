# S008 pane resize, focus, and maximize

Date: 2026-10-16. Implemented and independently reviewed; native interaction verified.

## Behavior

Drag a split divider to change its ratio. The shared command service rejects nonfinite or out-of-range ratios and allocations below the minimum pane dimensions. Dividers occupy 5 points, have accessibility values and adjustment actions, and coalesce rapid pointer updates to a bounded pending request.

The Pane menu offers directional focus with Cmd-Option-Arrows, divider movement with Cmd-Option-Shift-Arrows, and maximize/restore with Cmd-Shift-Return. Navigation uses the full layout geometry, preferring overlapping neighbors, facing-edge distance, center distance, and a stable tree-order tie break. A blue border shows the active pane.

Maximize is a temporary per-tab view projection, leaving the authoritative tree and ratios intact. Hidden terminal objects and processes are retained. Restoring reattaches their native views. Closing the active pane uses the surviving sibling, then normal tab/window fallback rules.

## Verification

Final full suite: **89 tests passed, zero failures**. Eight new cases cover ratio/canvas rejection, asymmetric directional navigation, live PID/session identity through maximize, closure focus fallback, a real hosted-view maximize/restore cycle, and keyboard navigation/resize with temporary maximize.

Independent review anchored drag coordinates to the fixed split branch, registered canvas sizes when switching between equally sized tabs, and revalidated pane selection before applying maximize or directional-focus projections. Added regressions cover concurrent pane closure/maximize/navigation and hosted canvas registration for equally sized duplicate tabs.

Native verification used an isolated development bundle with a mixed-axis three-pane layout. Mouse dragging changed the left/right divider from 50% to 59% and its nested top/bottom divider from 50% to 58%. The bottom PTY reported 11×39 cells. Cmd-Option-Up moved input to the top sibling, which reported 16×39. Cmd-Option-Shift-Down changed the nested ratio to 63%.

Cmd-Shift-Return maximized the same terminal ID, reporting 29×102 cells; restoring recovered the exact 59%/63% ratios and all terminal IDs/output. An isolated `/usr/bin/vi -u NONE -i NONE -n` session resized correctly during a further divider drag and maximize/restore cycle, then exited without saving a file. Both disposable shells exited cleanly. The development bundle built and its ad-hoc signature verified.

Physical monitor disconnection, scale changes, native-window full-screen transitions, and prior platform qualification gaps remain outstanding. These are not inferred from the hosted-view or terminal-editor checks.
