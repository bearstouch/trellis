# S031 — Qualify capacity, responsiveness, and lifecycle reliability

Priority: P0 / MVP  
Status: Planned — implementation and tests not started  
Delivery phase: 5  
Depends on: [S008](008-pane-resize-focus-and-maximize.md), [S009](009-safe-session-close-and-restart.md), [S010](010-persistence-and-stopped-restore.md), [S013](013-scrollback-and-search.md), [S017](017-keyboard-and-accessibility.md), [S020](020-ssh-connections.md), [S025](025-automation-output-and-events.md), [S026](026-declarative-layout-automation.md), [S029](029-theme-control-api.md), [S030](030-terminal-security-and-diagnostics.md)  
Requirements: `NFR-P01`, `NFR-P02`, `NFR-P03`, `NFR-P04`, `NFR-P05`, `NFR-P06`, `NFR-P07`, `NFR-R01`, `NFR-R04`, `NFR-R06`

## Story

As a daily terminal user, I want to keep many sessions open without slow navigation, memory growth, or lost state.

## Acceptance criteria

- [ ] **S031-AC01:** Publish reproducible release-build measurements with hardware, OS, engine version, and workload: cold launch ≤2 s p95, typing echo ≤50 ms p95, switching ≤100 ms p95 at 50 live panes.
- [ ] **S031-AC02:** Exercise 10 windows/50 tabs/100 sessions; verify model, focus, and cleanup, plus 100 create/close cycles without retained PTYs, unreaped children, or growing descriptors.
- [ ] **S031-AC03:** Measure app memory ≤300 MiB and idle CPU <2% of one core with 10 idle panes; report child-process memory separately and document workload conditions.
- [ ] **S031-AC04:** Flood 10 MiB/s for 60 s with bounded queues/scrollback/replay and responsive navigation; fuzz protocol/tree/import boundaries and record failures rather than claiming unmeasured passes.

## Unit tests

These are test specifications to implement with the story, not executed tests. Names are proposed and may follow repository conventions once the Swift project exists. Isolate time, filesystem, process, Keychain, clipboard, and transport dependencies as relevant; assert observable behavior and failure safety.

| Test | Setup, action, and expected result |
| --- | --- |
| `S031_UT01_randomizedTreeOperationsKeepInvariants` | Generate seeded split/close/reorder sequences; after each operation verify valid ownership, binary topology, and unique stable IDs. |
| `S031_UT02_queuesRespectAllBudgets` | Drive fake high-output producers and stalled consumers; assert configured byte/line/event limits and explicit eviction/gaps. |
| `S031_UT03_repeatedCleanupReturnsToBaseline` | Run 100 fake lifecycle cycles including failures; resource registry and pending effects return to baseline. |
| `S031_UT04_measurementSummaryCalculatesP95` | Use known timing samples; compute reproducible p95 and report insufficient samples instead of a misleading result. |

## Integration and manual verification

Run real performance and descriptor/process measurements outside the debugger on the reference matrix. Attach results and remediation for misses; unit tests alone cannot certify performance.

## Completion evidence

Link the implementation and passing relevant tests; record the acceptance demo and any required real-platform results. A story is complete only when its criteria and verification evidence pass. Document blockers rather than marking unavailable checks as passed.

## Source specifications

[Overview](../01-overview/README.md), [architecture](../02-architecture/README.md), [functional requirements](../03-functional-requirements/README.md), [quality requirements](../04-non-functional-requirements/README.md), [API](../05-api/README.md), [integrations](../06-integrations/README.md), [macOS support](../07-macos-support/README.md), [themes](../03-functional-requirements/themes/README.md)
