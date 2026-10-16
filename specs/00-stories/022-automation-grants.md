# S022 — Authorize scoped script and agent access

Priority: P0 / MVP  
Status: Implemented — independently reviewed, 243 tests pass; Keychain/native grant checks pending  
Delivery phase: 4  
Depends on: [S010](010-persistence-and-stopped-restore.md), [S018](018-saved-host-library.md), [S021](021-local-control-socket.md)  
Requirements: `API-02`, `FR-A03`, `NFR-S01`, `NFR-S02`, `NFR-S06`, `NFR-S08`

## Story

As a terminal user, I want to grant scripts only the terminal capabilities and resources I approve.

## Acceptance criteria

- [ ] **S022-AC01:** Create expiring/revocable grants in settings, show a token only during explicit creation, store secrets in Keychain and only hashes in metadata.
- [ ] **S022-AC02:** Authenticate before any domain call; verify UID/token/version and rate-limit failures. Revocation stops subscriptions and expiry requires reauthentication.
- [ ] **S022-AC03:** Enforce separate metadata/layout/start/input/execute/output/close/host/theme capabilities at the service boundary; hidden resources return NOT_FOUND.
- [ ] **S022-AC04:** Bind approved hosts to connection revisions, require reapproval after destination changes, and keep global theme privileges separate from window scopes. Explain same-user-account isolation limits.

## Unit tests

These are test specifications to implement with the story, not executed tests. Names are proposed and may follow repository conventions once the Swift project exists. Isolate time, filesystem, process, Keychain, clipboard, and transport dependencies as relevant; assert observable behavior and failure safety.

| Test | Setup, action, and expected result |
| --- | --- |
| `S022_UT01_denyBeforeAuthentication` | Call domain methods before auth with valid-looking IDs; return AUTH_REQUIRED with no effects. |
| `S022_UT02_scopeAndCapabilityMatrix` | Table-drive grants against each method and resource scope; deny output/execute to a layout-only grant and redact hidden IDs. |
| `S022_UT03_expiryAndRevocationStopAccess` | Advance a fake clock or revoke the grant; reject later calls and stop its subscriptions. |
| `S022_UT04_hostRevisionInvalidatesApproval` | Approve a host then change its connection revision; prevent a subsequent start until reapproved. |

## Integration and manual verification

Create/revoke a real Keychain-backed grant; test clients with different scopes and inspect app logs/exports/child environments for distinctive test-token leakage.

## Completion evidence

See [S022 automation grant evidence](../../docs/evidence/S022-automation-grants.md) for authentication, capability/scope matrix, expiry/revocation, host-approval tests, review fixes, and pending Keychain checks.

## Source specifications

[Overview](../01-overview/README.md), [architecture](../02-architecture/README.md), [functional requirements](../03-functional-requirements/README.md), [quality requirements](../04-non-functional-requirements/README.md), [API](../05-api/README.md), [integrations](../06-integrations/README.md), [macOS support](../07-macos-support/README.md), [themes](../03-functional-requirements/themes/README.md)
