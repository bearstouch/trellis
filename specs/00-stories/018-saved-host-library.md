# S018 — Maintain a searchable saved-host library

Priority: P0 / MVP  
Status: Planned — implementation and tests not started  
Delivery phase: 3  
Depends on: [S002](002-domain-model-and-command-service.md), [S004](004-native-application-shell.md), [S010](010-persistence-and-stopped-restore.md)  
Requirements: `FR-H01`, `INT-03`, `NFR-S03`, `MAC-12`

## Story

As an operator, I want to save and find frequently used SSH destinations without copying connection commands.

## Acceptance criteria

- [ ] **S018-AC01:** Create/edit/delete hosts with display name, alias-or-hostname destination, optional user/port/absolute identity-file reference, and tags.
- [ ] **S018-AC02:** Search names/destinations/tags; save metadata with revisions and persist without passwords, key contents, or terminal output.
- [ ] **S018-AC03:** Validate port 1–65535, destination/control-character restrictions, and identity paths before save; present actionable field errors.
- [ ] **S018-AC04:** Edits affect future connections only; deleting a host removes saved metadata without killing sessions or modifying SSH files.

## Unit tests

These are test specifications to implement with the story, not executed tests. Names are proposed and may follow repository conventions once the Swift project exists. Isolate time, filesystem, process, Keychain, clipboard, and transport dependencies as relevant; assert observable behavior and failure safety.

| Test | Setup, action, and expected result |
| --- | --- |
| `S018_UT01_validateHostBoundaries` | Exercise ports 0/1/65535/65536, leading-option destinations, control characters, and invalid identity paths; accept only valid records. |
| `S018_UT02_searchAcrossMetadata` | Query mixed-case names/tags/destinations; return matching saved IDs without altering order unexpectedly. |
| `S018_UT03_editDoesNotMutateLiveLaunch` | Edit a connected host; its stored revision changes while the live session descriptor remains unchanged. |
| `S018_UT04_deleteDoesNotTouchSshFiles` | Delete a host with fake filesystem/process dependencies; only app-owned metadata is removed and no signals are sent. |

## Integration and manual verification

Create local fixture hosts, restart, and verify persistence/search. Confirm host deletion never removes keys, config, or known-hosts files.

## Completion evidence

Link the implementation and passing relevant tests; record the acceptance demo and any required real-platform results. A story is complete only when its criteria and verification evidence pass. Document blockers rather than marking unavailable checks as passed.

## Source specifications

[Overview](../01-overview/README.md), [architecture](../02-architecture/README.md), [functional requirements](../03-functional-requirements/README.md), [quality requirements](../04-non-functional-requirements/README.md), [API](../05-api/README.md), [integrations](../06-integrations/README.md), [macOS support](../07-macos-support/README.md), [themes](../03-functional-requirements/themes/README.md)
