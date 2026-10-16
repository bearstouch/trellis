# S026 — Validate, plan, and apply declarative layouts

Priority: P0 / MVP  
Status: Implemented — independently reviewed; live CLI apply-twice demo performed in S027  
Delivery phase: 4  
Depends on: [S002](002-domain-model-and-command-service.md), [S010](010-persistence-and-stopped-restore.md), [S023](023-automation-resource-commands.md), [S024](024-automation-session-control.md)  
Requirements: `FR-A04`, `API-03`, `API-04`, `NFR-S07`

## Story

As a script author, I want to repeatably create a workspace from JSON without duplicating processes or rerunning commands.

## Acceptance criteria

- [ ] **S026-AC01:** Validate the committed v1 schema plus unique keys, type consistency, maximum nesting/panes, host references, and safe absolute/home-prefixed paths; reject executable layout content.
- [ ] **S026-AC02:** Plan keyed namespace changes without mutation, return a base revision, and require it on apply; apply commits model changes atomically before independent optional launches.
- [ ] **S026-AC03:** Reapply by namespace/key with stable IDs; update order/ratios/names, retain omitted resources as unmanaged, and reject live descriptor changes or pane moves across tabs.
- [ ] **S026-AC04:** New panes default stopped; startNew starts only newly created panes with proper grants. Existing stopped panes are never automatically started by reapply; return launch outcomes per pane without rolling back already launched processes.

## Unit tests

These are test specifications to implement with the story, not executed tests. Names are proposed and may follow repository conventions once the Swift project exists. Isolate time, filesystem, process, Keychain, clipboard, and transport dependencies as relevant; assert observable behavior and failure safety.

| Test | Setup, action, and expected result |
| --- | --- |
| `S026_UT01_exampleApplyTwiceIsStable` | Apply example-layout.json twice; mapping/IDs remain identical and the second application causes zero new launches. |
| `S026_UT02_schemaAndSemanticFailuresAreAtomic` | Supply duplicate keys, excess depth/panes, unsafe paths, unknown hosts, or commands; reject without model/process effects. |
| `S026_UT03_stalePlanAndLiveChangesConflict` | Race a plan revision or change a running launch descriptor; return CONFLICT without partial updates. |
| `S026_UT04_partialLaunchFailureIsReported` | Commit two new panes and fail one launch; return both per-pane outcomes and retain a valid committed layout. |

## Integration and manual verification

Use the supplied example through a real client; validate offline, inspect plan, apply with revision, and reapply after a client reconnect without rerunning work.

## Completion evidence

See [S026 declarative layout evidence](../../docs/evidence/S026-declarative-layouts.md) for validation, plan/apply atomicity, stable reapply, conflict, and partial-launch tests, review fixes, and the pending live CLI demo.

## Source specifications

[Overview](../01-overview/README.md), [architecture](../02-architecture/README.md), [functional requirements](../03-functional-requirements/README.md), [quality requirements](../04-non-functional-requirements/README.md), [API](../05-api/README.md), [integrations](../06-integrations/README.md), [macOS support](../07-macos-support/README.md), [themes](../03-functional-requirements/themes/README.md)
