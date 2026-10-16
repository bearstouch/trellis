# S020 — Open SSH sessions in tabs or splits

Priority: P0 / MVP  
Status: Planned — implementation and tests not started  
Delivery phase: 3  
Depends on: [S003](003-local-pty-session.md), [S007](007-nested-split-tree.md), [S009](009-safe-session-close-and-restart.md), [S018](018-saved-host-library.md), [S019](019-ssh-config-alias-discovery.md)  
Requirements: `FR-H02`, `FR-H04`, `FR-H05`, `INT-03`, `INT-05`, `NFR-S04`

## Story

As an operator, I want to connect to a saved host in an independent terminal with normal SSH trust and authentication behavior.

## Acceptance criteria

- [ ] **S020-AC01:** Use /usr/bin/ssh with a validated argument array in a PTY; saved fields override defaults only when explicitly supplied.
- [ ] **S020-AC02:** Connect in a new tab by default or a selected split; each attempt owns an independent session/process.
- [ ] **S020-AC03:** Leave unknown/changed host-key, password, passphrase, and agent authentication behavior to OpenSSH; never insert trust-bypass options.
- [ ] **S020-AC04:** Report running as a live SSH process rather than authenticated remote state; retain failures and exit status, and reconnect only explicitly.

## Unit tests

These are test specifications to implement with the story, not executed tests. Names are proposed and may follow repository conventions once the Swift project exists. Isolate time, filesystem, process, Keychain, clipboard, and transport dependencies as relevant; assert observable behavior and failure safety.

| Test | Setup, action, and expected result |
| --- | --- |
| `S020_UT01_buildSshArgumentsSafely` | Supply alias/user/port/key paths containing spaces where valid; construct exact arguments with no shell interpolation. |
| `S020_UT02_neverAddTrustBypass` | Generate arguments for all supported optional fields; no StrictHostKeyChecking disable or known-hosts bypass appears. |
| `S020_UT03_connectCreatesIndependentSession` | Connect the same saved host twice; allocate distinct PTY/session IDs and preserve each target hierarchy. |
| `S020_UT04_failedConnectionDoesNotRetry` | Inject SSH exit failure; expose the exit record with no timer-driven relaunch. |

## Integration and manual verification

Against a controlled local SSH server verify key/agent/password prompts, unknown/changed keys, refused connections, and network loss; inspect new-tab/split placement.

## Completion evidence

Link the implementation and passing relevant tests; record the acceptance demo and any required real-platform results. A story is complete only when its criteria and verification evidence pass. Document blockers rather than marking unavailable checks as passed.

## Source specifications

[Overview](../01-overview/README.md), [architecture](../02-architecture/README.md), [functional requirements](../03-functional-requirements/README.md), [quality requirements](../04-non-functional-requirements/README.md), [API](../05-api/README.md), [integrations](../06-integrations/README.md), [macOS support](../07-macos-support/README.md), [themes](../03-functional-requirements/themes/README.md)
