# S027 — Ship a script-friendly trellis CLI

Priority: P0 / MVP  
Status: Planned — implementation and tests not started  
Delivery phase: 4  
Depends on: [S021](021-local-control-socket.md), [S022](022-automation-grants.md), [S023](023-automation-resource-commands.md), [S024](024-automation-session-control.md), [S025](025-automation-output-and-events.md), [S026](026-declarative-layout-automation.md)  
Requirements: `FR-A01`, `FR-A02`, `INT-06`, `API-06`, `MAC-10`

## Story

As a script or agent author, I want to control all supported resources with structured results and predictable exit codes.

## Acceptance criteria

- [ ] **S027-AC01:** Expose the v1 resource/session/layout/event commands and documented flags; resolve explicit UUIDs and reject ambiguous name conveniences.
- [ ] **S027-AC02:** Discover the running app and return unavailable unless --launch explicitly permits starting it; launching keeps normal native app behavior.
- [ ] **S027-AC03:** Obtain credentials via Keychain reference or stdin, never token arguments; --json writes the stable ok/result/error envelope to stdout and diagnostics to stderr without color.
- [ ] **S027-AC04:** Use exit statuses 0/2/3/4/5/6/7/8 as documented; keep submission success separate from process exit and never automatically retry execution after uncertain transport outcomes.

## Unit tests

These are test specifications to implement with the story, not executed tests. Names are proposed and may follow repository conventions once the Swift project exists. Isolate time, filesystem, process, Keychain, clipboard, and transport dependencies as relevant; assert observable behavior and failure safety.

| Test | Setup, action, and expected result |
| --- | --- |
| `S027_UT01_parseAndRejectAmbiguousArguments` | Parse documented commands/flags and multiple matching names; produce a clear argument/ambiguity failure without a mutation. |
| `S027_UT02_jsonAndExitCodeMapping` | Map each application/transport error class; assert exact CLI status, JSON shape, and clean stdout/stderr separation. |
| `S027_UT03_launchOnlyWhenRequested` | Simulate absent discovery with/without --launch; call the app launcher only in the explicitly allowed case. |
| `S027_UT04_credentialsNeverInArgumentsOrLogs` | Use distinctive stdin/Keychain test tokens; spy arguments, envelopes, and diagnostics contain no secret. |

## Integration and manual verification

Run a shell script that creates two windows, tabs, mixed splits, starts a dedicated process, reads permitted output, and reapplies a layout. Document that no built-in AI runtime is required.

## Completion evidence

Link the implementation and passing relevant tests; record the acceptance demo and any required real-platform results. A story is complete only when its criteria and verification evidence pass. Document blockers rather than marking unavailable checks as passed.

## Source specifications

[Overview](../01-overview/README.md), [architecture](../02-architecture/README.md), [functional requirements](../03-functional-requirements/README.md), [quality requirements](../04-non-functional-requirements/README.md), [API](../05-api/README.md), [integrations](../06-integrations/README.md), [macOS support](../07-macos-support/README.md), [themes](../03-functional-requirements/themes/README.md)
