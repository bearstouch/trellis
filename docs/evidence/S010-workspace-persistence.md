# S010 workspace persistence and stopped restore

Date: 2026-10-16. Implemented and independently reviewed; native relaunch and backup recovery verified.

## Behavior

A versioned JSON document stores the workspace graph, stable IDs, names, ordering, selections, split ratios, safe launch references, default shell/directory, and native window frame. Normal changes debounce for 300 ms; Save Workspace and successful shutdown flush pending changes. Geometry changes participate in the same save path.

Restoration builds stopped sessions and empty native buffers without launching processes or replaying input. Shell executable/directory and saved host IDs are safe launch references. Arbitrary process arguments and executable names are deliberately omitted because they may contain commands or credentials; those panes require explicit fresh configuration and offer Start Shell Instead. Runtime process IDs, exit diagnostics, environment values, input, output, and transcripts are excluded.

The single persistence writer publishes same-directory temporary files using fsync and atomic rename, with owner-only permissions. A validated previous document becomes the last-known-good backup before replacement. Recovery explicitly archives corrupt source bytes before writing a replacement. A newer schema permits a temporary workspace while keeping the source read-only. Files are bounded to 4 MiB, recursive JSON depth is bounded before decoding, and the decoded graph must pass domain validation.

Prototype schema 0 uses the same graph with optional settings. Migration supplies defaults in memory; the next successful atomic save publishes schema 1 and retains the previous document as backup. This fixture represents a prototype migration contract, not a previously released format.

## Verification

Final full suite: **110 tests passed, zero failures**. The development bundle built and its ad-hoc signature verified.

Native verification used an isolated app identity and repository-local state directory. A two-tab workspace with nested left/right and top/bottom splits was saved with a renamed tab. Quit closed three disposable local shells. Relaunch restored the selected tab, names, stable pane IDs and 50/50 split ratios, with all four panes stopped and empty buffers. The former fixture output was absent. Explicit Start Session launched only its selected pane; the remaining panes stayed stopped. The shell then exited successfully.

A deliberately malformed disposable state file presented Use Backup / Start Empty. Use Backup restored the same stopped split layout; filesystem inspection confirmed byte-for-byte preservation of the malformed original, a parseable replacement and backup, and owner-only document permissions. Atomic failure is exercised by an injected failure immediately before replacement; an actual power loss during disk I/O has not been simulated. Prototype migration and future-schema read-only behavior passed automated filesystem/model tests.

Independent review fixed geometry save scheduling and restored frame application, protected the saved graph when Quit cancels startup, and reopened the command gate when a failed shutdown save cancels Quit. Regression tests cover these paths in addition to stopped restore, failed replacement, read-only future versions, secret/output omission, corruption recovery, and prototype migration.
