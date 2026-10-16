# S003 — Launch and operate local PTY sessions

Priority: P0 / MVP  
Status: Done — reviewed and fixed; 43 tests passing
Delivery phase: 1  
Depends on: [S001](001-terminal-engine-feasibility.md), [S002](002-domain-model-and-command-service.md)  
Requirements: `FR-S01`, `FR-S03`, `FR-S05`, `INT-01`, `MAC-08`, `NFR-S08`

## Story

As a terminal user, I want to run my shell or an explicitly configured process in an independent pane.

## Acceptance criteria

- [x] **S003-AC01:** Launch the configured login shell with a controlling PTY, owned process group, initial dimensions, working directory, and allowed environment overrides.
- [x] **S003-AC02:** Validate executable and directory before spawn, preserve argument boundaries, and remove application control secrets from child environments.
- [x] **S003-AC03:** Report starting/running/exited/failed states and process exit status; a live interactive shell does not imply prompt readiness or command success.
- [x] **S003-AC04:** Handle ordered asynchronous output, terminal input, resize notifications, child reaping, and descriptor cleanup without blocking the main actor.

## Unit tests

These are test specifications to implement with the story, not executed tests. Names are proposed and may follow repository conventions once the Swift project exists. Isolate time, filesystem, process, Keychain, clipboard, and transport dependencies as relevant; assert observable behavior and failure safety.

| Test | Setup, action, and expected result |
| --- | --- |
| `S003_UT01_rejectInaccessibleDirectory` | Use a denied directory fixture; report a launch error with zero spawn calls. |
| `S003_UT02_preserveLaunchArguments` | Pass paths and arguments containing spaces and metacharacters; fake spawn receives the exact argument array. |
| `S003_UT03_stripControlSecrets` | Seed control credentials and an allowed variable; only the allowed variable reaches the child environment. |
| `S003_UT04_exitAndCleanupOnce` | Deliver exit and teardown twice through a fake process transport; store the exit code and release each descriptor once. |

## Integration and manual verification

On real zsh and bash verify Ctrl-C, Ctrl-D, job control, resize, a dedicated process exiting with code 7, and reaping. Never run test commands in the user’s existing sessions.

## Completion evidence

See [S003 evidence](../../docs/evidence/S003-local-sessions.md) for the implementation, real shell checks, reviewer fixes, and remaining platform qualification boundaries.

Link the implementation and passing relevant tests; record the acceptance demo and any required real-platform results. A story is complete only when its criteria and verification evidence pass. Document blockers rather than marking unavailable checks as passed.

## Source specifications

[Overview](../01-overview/README.md), [architecture](../02-architecture/README.md), [functional requirements](../03-functional-requirements/README.md), [quality requirements](../04-non-functional-requirements/README.md), [API](../05-api/README.md), [integrations](../06-integrations/README.md), [macOS support](../07-macos-support/README.md), [themes](../03-functional-requirements/themes/README.md)
