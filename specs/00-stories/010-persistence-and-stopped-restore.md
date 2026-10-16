# S010 — Persist workspaces and restore stopped sessions

Priority: P0 / MVP  
Status: Implemented and reviewed — 110 tests pass; native restore/recovery verified
Delivery phase: 2  
Depends on: [S002](002-domain-model-and-command-service.md), [S005](005-managed-window-sidebar.md), [S006](006-tabs-and-inline-renaming.md), [S007](007-nested-split-tree.md), [S009](009-safe-session-close-and-restart.md)  
Requirements: `FR-R01`, `NFR-R02`, `NFR-R05`, `MAC-11`

## Story

As a terminal user, I want to recover my organization after relaunch without silently executing old commands.

## Acceptance criteria

- [x] **S010-AC01:** Atomically save versioned state, names, orders, ratios, selection, safe launch references, and settings; debounce normal saves and flush explicit save/shutdown.
- [x] **S010-AC02:** Restore stable resource IDs and layout as stopped sessions, never live PID handles or replayed shell input; starting restored panes requires explicit action.
- [x] **S010-AC03:** Keep a last-known-good backup and preserve corrupt originals; offer backup recovery or an empty workspace without destroying evidence.
- [x] **S010-AC04:** Migrations are failure-safe; unsupported newer versions enter recovery without rewriting the source. Exclude output, input transcripts, tokens, and runtime secret environment values.

## Unit tests

All four named cases are implemented and passing, with additional filesystem and native-view restoration regressions. Tests use isolated temporary storage and preferences.

| Test | Setup, action, and expected result |
| --- | --- |
| `S010_UT01_restoreNeverSpawns` | Decode a snapshot marked running at save time; restore stopped records and assert zero launch calls. |
| `S010_UT02_failedAtomicWriteKeepsBackup` | Inject failure before replacement; current or backup remains parseable and the original is preserved. |
| `S010_UT03_newerSchemaIsReadOnly` | Load a future version; expose recovery and make zero filesystem writes. |
| `S010_UT04_snapshotOmitsSecretsAndBuffers` | Seed a session with distinctive secret/input/output values; none appear in the encoded snapshot. |

## Integration and manual verification

Interrupt a real save, relaunch after a simulated crash, and migrate older fixture snapshots. Verify names and split ratios return without shell execution.

## Completion evidence

See [S010 evidence](../../docs/evidence/S010-workspace-persistence.md) for implementation decisions, 110 passing tests, native stopped relaunch, backup recovery, and the physical power-loss qualification limit. Arbitrary process arguments are never saved; those panes require fresh configuration after restore.

## Source specifications

[Overview](../01-overview/README.md), [architecture](../02-architecture/README.md), [functional requirements](../03-functional-requirements/README.md), [quality requirements](../04-non-functional-requirements/README.md), [API](../05-api/README.md), [integrations](../06-integrations/README.md), [macOS support](../07-macos-support/README.md), [themes](../03-functional-requirements/themes/README.md)
