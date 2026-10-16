# S021 — Expose a bounded local JSON-RPC control socket

Priority: P0 / MVP  
Status: Planned — implementation and tests not started  
Delivery phase: 4  
Depends on: [S002](002-domain-model-and-command-service.md), [S004](004-native-application-shell.md)  
Requirements: `API-01`, `API-06`, `NFR-S01`, `NFR-R04`

## Story

As a script author, I want to find a running app and exchange structured requests over a local-only endpoint.

## Acceptance criteria

- [ ] **S021-AC01:** Create an owner-only runtime directory/socket and token-free control.json discovery file with version, instance ID, and a short socket path.
- [ ] **S021-AC02:** Validate owner/peer UID and reject symlink endpoints; replace stale discovery only after verifying the previous instance is gone. Never bind TCP.
- [ ] **S021-AC03:** Parse newline-framed UTF-8 JSON-RPC 2.0 objects up to 1 MiB, reject batches, and require request IDs for mutation.
- [ ] **S021-AC04:** Return sanitized protocol errors and close malformed framing safely; all domain dispatch remains authentication-gated and uses the shared service.

## Unit tests

These are test specifications to implement with the story, not executed tests. Names are proposed and may follow repository conventions once the Swift project exists. Isolate time, filesystem, process, Keychain, clipboard, and transport dependencies as relevant; assert observable behavior and failure safety.

| Test | Setup, action, and expected result |
| --- | --- |
| `S021_UT01_frameAcrossReads` | Split and combine frames across arbitrary byte chunks, including escaped newlines; yield exactly the intended requests. |
| `S021_UT02_rejectOversizedAndMalformedFrames` | Feed an over-limit frame, invalid UTF-8/JSON, a batch, and mutation notification; reject without dispatch. |
| `S021_UT03_rejectUnsafeEndpoint` | Use symlink, wrong-owner, and mismatched peer-UID fixtures; refuse endpoint use and domain dispatch. |
| `S021_UT04_discoveryContainsNoSecret` | Publish discovery from an instance fixture; assert only allowed metadata fields and no credential content. |

## Integration and manual verification

Connect through a real Unix socket; inspect file modes, same-user peer verification, socket-path limits, stale-instance handling, and absence of network listeners.

## Completion evidence

Link the implementation and passing relevant tests; record the acceptance demo and any required real-platform results. A story is complete only when its criteria and verification evidence pass. Document blockers rather than marking unavailable checks as passed.

## Source specifications

[Overview](../01-overview/README.md), [architecture](../02-architecture/README.md), [functional requirements](../03-functional-requirements/README.md), [quality requirements](../04-non-functional-requirements/README.md), [API](../05-api/README.md), [integrations](../06-integrations/README.md), [macOS support](../07-macos-support/README.md), [themes](../03-functional-requirements/themes/README.md)
