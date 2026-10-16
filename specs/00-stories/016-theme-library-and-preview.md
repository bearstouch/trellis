# S016 — Import, preview, and maintain custom themes

Priority: P0 / MVP  
Status: Implemented — independently reviewed, 184 tests and native library checks pass  
Delivery phase: 3  
Depends on: [S010](010-persistence-and-stopped-restore.md), [S015](015-json-theme-format.md)  
Requirements: `FR-TH03`, `FR-TH04`, `FR-TH05`, `INT-10`

## Story

As a terminal user, I want to try and edit JSON themes without risking my working appearance.

## Acceptance criteria

- [x] **S016-AC01:** Import validated files into the app-owned Themes directory using validated IDs; reserve trellis- IDs for built-ins and require explicit replacement of duplicates.
- [x] **S016-AC02:** Preview is reversible, Save installs atomically, and Cancel restores the prior effective appearance without touching sessions.
- [x] **S016-AC03:** Provide export, Export Resolved, Open Themes Folder, and Reload Themes; invalid edits retain the last valid in-memory palette with actionable errors.
- [x] **S016-AC04:** Deleting a selected custom theme or launching with a missing file falls back to the built-in palette for that slot with a notice; built-ins cannot be replaced/deleted.

## Unit tests

These are test specifications to implement with the story, not executed tests. Names are proposed and may follow repository conventions once the Swift project exists. Isolate time, filesystem, process, Keychain, clipboard, and transport dependencies as relevant; assert observable behavior and failure safety.

| Test | Setup, action, and expected result |
| --- | --- |
| `S016_UT01_duplicateRequiresReplace` | Import an existing ID without replacement; preserve its file and active palette. |
| `S016_UT02_failedReplacePreservesOldFile` | Inject an atomic-write failure; both installed metadata and current palette retain the prior valid version. |
| `S016_UT03_cancelPreviewRestoresEffectivePalette` | Preview different colors then cancel; recover mode, selected IDs, and resolved colors exactly. |
| `S016_UT04_reloadInvalidAndMissingThemes` | Reload malformed and removed selected files; preserve last valid colors for invalid edits and select built-in fallback for missing files. |

## Integration and manual verification

Edit a theme with an external editor, reload, export/import it, and delete it while selected. Confirm no app or shell restart is required.

## Completion evidence

See [S016 theme library evidence](../../docs/evidence/S016-theme-library.md) for atomic install/failure tests, preview restoration, review findings and fixes, native reload/export/delete checks, and remaining platform qualification scope.

## Source specifications

[Overview](../01-overview/README.md), [architecture](../02-architecture/README.md), [functional requirements](../03-functional-requirements/README.md), [quality requirements](../04-non-functional-requirements/README.md), [API](../05-api/README.md), [integrations](../06-integrations/README.md), [macOS support](../07-macos-support/README.md), [themes](../03-functional-requirements/themes/README.md)
