# S028 — Import and export layouts and saved hosts

Priority: P0 / MVP  
Status: Planned — implementation and tests not started  
Delivery phase: 4  
Depends on: [S010](010-persistence-and-stopped-restore.md), [S018](018-saved-host-library.md), [S026](026-declarative-layout-automation.md)  
Requirements: `FR-R02`, `INT-09`, `NFR-S03`, `NFR-S07`

## Story

As a terminal user, I want to move reusable configuration between installations without carrying secrets or executing work.

## Acceptance criteria

- [ ] **S028-AC01:** Export versioned portable layout/host JSON excluding runtime IDs, buffers, transcripts, private keys, tokens, and runtime environment secrets.
- [ ] **S028-AC02:** Preview imported window/tab/pane/host counts, launch references, collisions, and unsupported versions before any mutation.
- [ ] **S028-AC03:** Interactive import creates fresh resource IDs and stopped panes; namespace-based API apply keeps its separate additive matching semantics.
- [ ] **S028-AC04:** Host imports commit atomically; overwrites require an explicit selected collision policy, never only a matching name/alias. Failed validation preserves existing configuration.

## Unit tests

These are test specifications to implement with the story, not executed tests. Names are proposed and may follow repository conventions once the Swift project exists. Isolate time, filesystem, process, Keychain, clipboard, and transport dependencies as relevant; assert observable behavior and failure safety.

| Test | Setup, action, and expected result |
| --- | --- |
| `S028_UT01_exportOmitsSensitiveState` | Seed runtime IDs, output, environment secrets, and authentication fixtures; export contains only portable allowed fields. |
| `S028_UT02_interactiveImportRemapsIds` | Import the same file twice; each interactive import gets fresh IDs and zero process launches. |
| `S028_UT03_hostCollisionNeedsPolicy` | Import an alias/name collision without an override policy; preserve the existing host and require a decision. |
| `S028_UT04_invalidImportIsAtomic` | Fail one record in a multi-host/layout document; no subset is installed and unsupported versions are not rewritten. |

## Integration and manual verification

Export from one clean test profile and import into another. Preview the summary, cancel once, then confirm and compare safe configuration fields.

## Completion evidence

Link the implementation and passing relevant tests; record the acceptance demo and any required real-platform results. A story is complete only when its criteria and verification evidence pass. Document blockers rather than marking unavailable checks as passed.

## Source specifications

[Overview](../01-overview/README.md), [architecture](../02-architecture/README.md), [functional requirements](../03-functional-requirements/README.md), [quality requirements](../04-non-functional-requirements/README.md), [API](../05-api/README.md), [integrations](../06-integrations/README.md), [macOS support](../07-macos-support/README.md), [themes](../03-functional-requirements/themes/README.md)
