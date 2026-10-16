# S019 — Discover SSH aliases without changing SSH configuration

Priority: P0 / MVP  
Status: Planned — implementation and tests not started  
Delivery phase: 3  
Depends on: [S018](018-saved-host-library.md)  
Requirements: `FR-H03`, `INT-04`

## Story

As an operator, I want to reuse existing SSH aliases without entering all their underlying settings again.

## Acceptance criteria

- [ ] **S019-AC01:** Read literal aliases from the user SSH config in a best-effort discovery screen; preview selection before adding saved metadata.
- [ ] **S019-AC02:** Keep the alias as the SSH destination instead of flattening OpenSSH behavior into copied host options.
- [ ] **S019-AC03:** Do not materialize wildcard/Match sections; explain unsupported Include discovery and allow manual alias entry.
- [ ] **S019-AC04:** Never edit SSH configuration, read private-key contents, or execute Match exec commands to populate the list; unreadable files produce a recoverable error.

## Unit tests

These are test specifications to implement with the story, not executed tests. Names are proposed and may follow repository conventions once the Swift project exists. Isolate time, filesystem, process, Keychain, clipboard, and transport dependencies as relevant; assert observable behavior and failure safety.

| Test | Setup, action, and expected result |
| --- | --- |
| `S019_UT01_discoverLiteralAliases` | Parse comments, whitespace, and multiple literal names per Host stanza; return the expected aliases. |
| `S019_UT02_skipPatternsAndMatch` | Use wildcard Host and Match exec fixtures; expose supported aliases and never execute a subprocess. |
| `S019_UT03_includeHasExplicitLimitation` | Encounter Include; return a discovery warning instead of pretending every included alias was found. |
| `S019_UT04_unreadableConfigIsNonDestructive` | Inject a permission error; preserve existing hosts and perform zero writes. |

## Integration and manual verification

Use an isolated SSH config fixture and compare connecting by the original alias. Do not modify or connect to production hosts during development.

## Completion evidence

Link the implementation and passing relevant tests; record the acceptance demo and any required real-platform results. A story is complete only when its criteria and verification evidence pass. Document blockers rather than marking unavailable checks as passed.

## Source specifications

[Overview](../01-overview/README.md), [architecture](../02-architecture/README.md), [functional requirements](../03-functional-requirements/README.md), [quality requirements](../04-non-functional-requirements/README.md), [API](../05-api/README.md), [integrations](../06-integrations/README.md), [macOS support](../07-macos-support/README.md), [themes](../03-functional-requirements/themes/README.md)
