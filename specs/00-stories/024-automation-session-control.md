# S024 — Start sessions and submit authorized input

Priority: P0 / MVP  
Status: Planned — implementation and tests not started  
Delivery phase: 4  
Depends on: [S003](003-local-pty-session.md), [S009](009-safe-session-close-and-restart.md), [S012](012-safe-paste-and-file-paths.md), [S020](020-ssh-connections.md), [S022](022-automation-grants.md), [S023](023-automation-resource-commands.md)  
Requirements: `FR-A01`, `FR-A03`, `API-03`, `API-04`, `INT-06`

## Story

As an authorized agent, I want to start approved sessions or explicitly execute work without depending on UI clicks.

## Acceptance criteria

- [ ] **S024-AC01:** Implement session.start/restart/sendInput/execute and host.connect using separate capability checks; arbitrary processes/environment/directories require session.execute.
- [ ] **S024-AC02:** Allow exact literal text/base64 input or negotiated paste with a 64 KiB decoded limit, targeting a running session only.
- [ ] **S024-AC03:** session.execute requires submit:true and intentionally sends shell command text plus carriage return; success means submission, not command completion.
- [ ] **S024-AC04:** Never retry input/commands implicitly after transport failure. Dedicated processes expose actual process exit status; agent disconnect leaves sessions running and no API input triggers blocking UI dialogs.

## Unit tests

These are test specifications to implement with the story, not executed tests. Names are proposed and may follow repository conventions once the Swift project exists. Isolate time, filesystem, process, Keychain, clipboard, and transport dependencies as relevant; assert observable behavior and failure safety.

| Test | Setup, action, and expected result |
| --- | --- |
| `S024_UT01_rejectUnapprovedLaunchDescriptor` | Use only session.start capability with arbitrary executable/environment changes; deny before spawning. |
| `S024_UT02_validateInputEncodingAndLimit` | Supply both/neither encodings, invalid base64, and 65536/65537 decoded bytes; accept only valid payloads within the boundary. |
| `S024_UT03_executeRequiresSubmit` | Omit submit or set false; reject with zero bytes; with true append exactly the specified submission carriage return. |
| `S024_UT04_disconnectDoesNotReplayOrClose` | Disconnect after accepted input; retain the session and assert no automatic re-send, restart, or termination. |

## Integration and manual verification

Run a dedicated fixture process with a known exit code and an interactive shell command separately; demonstrate their different completion semantics and permission denials.

## Completion evidence

Link the implementation and passing relevant tests; record the acceptance demo and any required real-platform results. A story is complete only when its criteria and verification evidence pass. Document blockers rather than marking unavailable checks as passed.

## Source specifications

[Overview](../01-overview/README.md), [architecture](../02-architecture/README.md), [functional requirements](../03-functional-requirements/README.md), [quality requirements](../04-non-functional-requirements/README.md), [API](../05-api/README.md), [integrations](../06-integrations/README.md), [macOS support](../07-macos-support/README.md), [themes](../03-functional-requirements/themes/README.md)
