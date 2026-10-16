# S013 — Retain bounded output and search a pane

Priority: P0 / MVP  
Status: Implemented and reviewed — 138 tests pass; native long-output, alternate-screen, and search-focus checks verified
Delivery phase: 3  
Depends on: [S001](001-terminal-engine-feasibility.md), [S003](003-local-pty-session.md)  
Requirements: `FR-S04`, `NFR-P05`, `NFR-R06`

## Story

As a terminal user, I want to search recent output without allowing scrollback to grow without limit.

## Acceptance criteria

- [x] **S013-AC01:** Keep 10,000 lines per pane by default and an additional 16 MiB storage cap; evict oldest retained content when either limit is reached.
- [x] **S013-AC02:** Search plain-text retained output forward/backward with a visible current match; expose that earlier history may have been evicted.
- [x] **S013-AC03:** Keep screen/alternate-screen state and scrollback behavior consistent with the selected engine; search never mixes output from other panes.
- [x] **S013-AC04:** Preserve byte ordering in parsing; bounded output queues and frame coalescing do not silently reorder terminal data.

## Unit tests

All four named cases are implemented and passing, with additional real PTY ordering, wrap/last-column, capacity-recovery/reflow, small-read flood, and hosted native-focus regressions.

| Test | Setup, action, and expected result |
| --- | --- |
| `S013_UT01_evictByLineAndByteLimits` | Append many short lines and one oversized line; retain data within both budgets with an eviction marker. |
| `S013_UT02_unicodeSearchNavigatesMatches` | Find forward/backward matches containing combining marks and CJK text using stable text ranges. |
| `S013_UT03_searchIsPaneLocal` | Use identical queries in two buffers; only the requested pane supplies results. |
| `S013_UT04_evictionInvalidatesOldMatch` | Evict the current match; update selection/ranges without referencing removed content. |

## Integration and manual verification

Search a real long-output session and alternate-screen app; flood output and verify bounded storage and responsive navigation.

## Completion evidence

See [S013 evidence](../../docs/evidence/S013-scrollback-search.md) for 138 passing tests, independent review/fixes, native 12,000-row and Vim checks, keyboard focus verification, and engine-memory qualification limits. The 10,000-row/16 MiB budgets apply to historical rendered text; active-screen and engine overhead are accounted separately under NFR-P05.

## Source specifications

[Overview](../01-overview/README.md), [architecture](../02-architecture/README.md), [functional requirements](../03-functional-requirements/README.md), [quality requirements](../04-non-functional-requirements/README.md), [API](../05-api/README.md), [integrations](../06-integrations/README.md), [macOS support](../07-macos-support/README.md), [themes](../03-functional-requirements/themes/README.md)
