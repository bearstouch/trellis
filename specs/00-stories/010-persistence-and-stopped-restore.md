# S010 — Persist workspaces and restore stopped sessions

Priority: P0 / MVP  
Status: Planned — implementation and tests not started  
Delivery phase: 2  
Depends on: [S002](002-domain-model-and-command-service.md), [S005](005-managed-window-sidebar.md), [S006](006-tabs-and-inline-renaming.md), [S007](007-nested-split-tree.md), [S009](009-safe-session-close-and-restart.md)  
Requirements: `FR-R01`, `NFR-R02`, `NFR-R05`, `MAC-11`

## Story

As a terminal user, I want to recover my organization after relaunch without silently executing old commands.

## Acceptance criteria

- [ ] **S010-AC01:** Atomically save versioned state, names, orders, ratios, selection, safe launch references, and settings; debounce normal saves and flush explicit save/shutdown.
- [ ] **S010-AC02:** Restore stable resource IDs and layout as stopped sessions, never live PID handles or replayed shell input; starting restored panes requires explicit action.
- [ ] **S010-AC03:** Keep a last-known-good backup and preserve corrupt originals; offer backup recovery or an empty workspace without destroying evidence.
- [ ] **S010-AC04:** Migrations are failure-safe; unsupported newer versions enter recovery without rewriting the source. Exclude output, input transcripts, tokens, and runtime secret environment values.

## Unit tests

These are test specifications to implement with the story, not executed tests. Names are proposed and may follow repository conventions once the Swift project exists. Isolate time, filesystem, process, Keychain, clipboard, and transport dependencies as relevant; assert observable behavior and failure safety.

| Test | Setup, action, and expected result |
| --- | --- |
| `S010_UT01_restoreNeverSpawns` | Decode a snapshot marked running at save time; restore stopped records and assert zero launch calls. |
| `S010_UT02_failedAtomicWriteKeepsBackup` | Inject failure before replacement; current or backup remains parseable and the original is preserved. |
| `S010_UT03_newerSchemaIsReadOnly` | Load a future version; expose recovery and make zero filesystem writes. |
| `S010_UT04_snapshotOmitsSecretsAndBuffers` | Seed a session with distinctive secret/input/output values; none appear in the encoded snapshot. |

## Integration and manual verification

Interrupt a real save, relaunch after a simulated crash, and migrate older fixture snapshots. Verify names and split ratios return without shell execution.

## Completion evidence

Link the implementation and passing relevant tests; record the acceptance demo and any required real-platform results. A story is complete only when its criteria and verification evidence pass. Document blockers rather than marking unavailable checks as passed.

## Source specifications

[Overview](../01-overview/README.md), [architecture](../02-architecture/README.md), [functional requirements](../03-functional-requirements/README.md), [quality requirements](../04-non-functional-requirements/README.md), [API](../05-api/README.md), [integrations](../06-integrations/README.md), [macOS support](../07-macos-support/README.md), [themes](../03-functional-requirements/themes/README.md)
