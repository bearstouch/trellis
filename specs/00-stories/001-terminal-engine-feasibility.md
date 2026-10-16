# S001 — Validate the native terminal engine

Priority: P0 / MVP  
Status: Implemented and reviewed — manual feasibility gate pending
Delivery phase: 1  
Depends on: None  
Requirements: `MAC-01`, `MAC-02`, `MAC-03`, `NFR-U02`, `FR-S02`

## Story

As a developer, I want to prove the terminal adapter can support the required macOS workflows before building the application around it.

## Acceptance criteria

- [x] **S001-AC01:** Embed the candidate engine in a minimal native Swift host and record its pinned version, license, supported architectures, and chosen PTY ownership strategy.
- [ ] **S001-AC02:** Demonstrate a shell, resize, alternate screen, Unicode, IME composition, native selection, paste, output access, and VoiceOver terminal reading; document failures with reproducible steps.
- [x] **S001-AC03:** Keep engine-specific types behind an adapter; select a supported TERM value based on demonstrated capabilities and available terminfo.
- [ ] **S001-AC04:** Record a go/no-go decision before dependent terminal work. Accessibility or lifecycle blockers require resolving the issue or choosing another engine, not silently dropping requirements.

## Unit tests

These are test specifications to implement with the story, not executed tests. Names are proposed and may follow repository conventions once the Swift project exists. Isolate time, filesystem, process, Keychain, clipboard, and transport dependencies as relevant; assert observable behavior and failure safety.

| Test | Setup, action, and expected result |
| --- | --- |
| `S001_UT01_adapterPreservesOutputOrder` | Feed numbered byte chunks through a fake transport; adapter output preserves order without duplication. |
| `S001_UT02_adapterPropagatesResize` | Provide a cell-size change; the adapter forwards the correct rows/columns once to its PTY owner. |
| `S001_UT03_adapterDetachIsIdempotent` | Detach twice; callbacks and owned resources are released exactly once. |
| `S001_UT04_unsupportedEngineCapabilityIsExplicit` | Request an unavailable capability; adapter returns an explicit unsupported result rather than fabricated output. |

## Integration and manual verification

Run the feasibility checklist on the proposed minimum/current macOS and both CPU architectures where available. Record actual devices and outstanding coverage; dependency claims alone are insufficient.

## Completion evidence

Implementation, review findings, environment, automated evidence, and outstanding interaction checks are recorded in [S001 evidence](../../docs/evidence/S001-terminal-feasibility.md). S001-AC02/AC04 remain open; programmatic accessibility checks do not establish spoken VoiceOver quality.

Link the implementation and passing relevant tests; record the acceptance demo and any required real-platform results. A story is complete only when its criteria and verification evidence pass. Document blockers rather than marking unavailable checks as passed.

## Source specifications

[Overview](../01-overview/README.md), [architecture](../02-architecture/README.md), [functional requirements](../03-functional-requirements/README.md), [quality requirements](../04-non-functional-requirements/README.md), [API](../05-api/README.md), [integrations](../06-integrations/README.md), [macOS support](../07-macos-support/README.md), [themes](../03-functional-requirements/themes/README.md)
