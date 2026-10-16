# S006 multiple tabs and inline rename

Date: 2026-10-16. Implemented and independently reviewed; native tab interaction verified.

## Behavior

Each managed window owns its ordered tab bar, with visible separators, selected styling, a New Tab button, and per-tab close controls. Double-click a title or use Rename from its context menu or the File menu to edit inline. Enter commits a trimmed title; Escape cancels; whitespace-only text preserves the original title and revision. New Tab uses Cmd-T; Next/Previous Tab use Cmd-Shift-]/[.

Context menus also move tabs left/right or duplicate them. Duplication copies the layout, ratios, pane metadata, and launch configuration into new structural, pane, and session IDs. It allocates fresh terminal views and processes; terminal buffers and typed commands are not copied. The original remains independent.

Closing a tab uses the same confirmation and process-drain helper as deleting a window. Closing the final tab removes its managed window; closing the last managed window reaches the welcome state. Domain deletion rejects live sessions, and tab order commands validate exact window-local permutations.

## Verification

Final full suite: **72 tests passed, zero failures**. Seven S006 tests cover live rename preserving terminal/PID/session ownership, cancel/empty/no-op rename, all-ID remapping of a mixed-axis split tree, window-local valid/invalid ordering, empty cloned buffers and copied process configuration with real PTYs, and cancel/confirm closure of the final live tab.

Independent review fixed the inactive-tab editor being canceled by delayed selection notifications and duplication using changed app defaults instead of the original effective shell/directory. A real-process regression changes Settings between original launch and duplication, then verifies copied configuration and distinct process IDs.

Native verification in an isolated development bundle confirmed New Tab, double-click rename of an inactive tab, Enter commit with terminal focus restored, Escape cancellation, empty-title preservation, and moving a tab while preserving its terminal ID/output. Closing a stopped tab selected its live sibling. Closing that live sibling showed the common confirmation; after confirmation it was removed, and closing the final tab reached the welcome state.

The native check exposed an exited child left as a zombie when the process-exit notification did not complete reaping. Review added a 250 ms fallback, EINTR retry, and cancellation on reap/deinit. A deterministic test suppresses process notifications and verifies exit code/output, closed descriptor, and waitpid ECHILD. The corrected native live-close scenario passed. The exact underlying event-delivery gap is not claimed diagnosed.

Prior platform qualification gaps and later persistence qualification remain pending.
