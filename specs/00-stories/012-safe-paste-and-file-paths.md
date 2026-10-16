# S012 — Paste text and file paths safely

Priority: P0 / MVP  
Status: Planned — implementation and tests not started  
Delivery phase: 3  
Depends on: [S003](003-local-pty-session.md), [S008](008-pane-resize-focus-and-maximize.md), [S011](011-selection-and-copy.md)  
Requirements: `FR-C03`, `FR-C04`, `FR-C05`, `INT-08`

## Story

As a terminal user, I want to paste into exactly one pane with clear review of potentially surprising input.

## Acceptance criteria

- [ ] **S012-AC01:** Cmd-V and context paste read text only on user action and target the focused pane; use bracketed paste only when negotiated.
- [ ] **S012-AC02:** Multiline or control-character text requires a preview with line count, visible controls, and target; cancellation sends zero bytes.
- [ ] **S012-AC03:** Paste preserves clipboard content without appending a newline; changing focus or closing the reviewed target invalidates the pending paste and requires a new review.
- [ ] **S012-AC04:** Provide explicit Paste Escaped Path for supported shells; preserve ordinary text paste and preview quoting for unsupported shells.

## Unit tests

These are test specifications to implement with the story, not executed tests. Names are proposed and may follow repository conventions once the Swift project exists. Isolate time, filesystem, process, Keychain, clipboard, and transport dependencies as relevant; assert observable behavior and failure safety.

| Test | Setup, action, and expected result |
| --- | --- |
| `S012_UT01_pasteReviewClassifiesControls` | Classify single-line, CR/LF, tab, ESC, and other control fixtures; flag the inputs needing review. |
| `S012_UT02_cancelOrStaleTargetWritesNothing` | Cancel or change/close the reviewed pane before confirmation; no transport receives any payload. |
| `S012_UT03_bracketedPastePreservesPayload` | With negotiation on/off, assert exact framing and unchanged payload bytes with no extra newline. |
| `S012_UT04_escapePathByShell` | Quote spaces, apostrophes, dollar signs, and newlines for zsh/bash fixtures; unsupported shells require preview instead of guessed execution. |

## Integration and manual verification

Verify native paste, reviewed multiline commands, file paths containing spaces, and terminal bracketed-paste mode with two active panes.

## Completion evidence

Link the implementation and passing relevant tests; record the acceptance demo and any required real-platform results. A story is complete only when its criteria and verification evidence pass. Document blockers rather than marking unavailable checks as passed.

## Source specifications

[Overview](../01-overview/README.md), [architecture](../02-architecture/README.md), [functional requirements](../03-functional-requirements/README.md), [quality requirements](../04-non-functional-requirements/README.md), [API](../05-api/README.md), [integrations](../06-integrations/README.md), [macOS support](../07-macos-support/README.md), [themes](../03-functional-requirements/themes/README.md)
