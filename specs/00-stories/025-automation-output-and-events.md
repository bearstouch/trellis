# S025 — Read bounded output and subscribe to events

Priority: P0 / MVP  
Status: Implemented — independently reviewed, 268 tests pass; multi-client manual checks pending  
Delivery phase: 4  
Depends on: [S013](013-scrollback-and-search.md), [S021](021-local-control-socket.md), [S022](022-automation-grants.md), [S023](023-automation-resource-commands.md)  
Requirements: `FR-A05`, `API-05`, `NFR-P05`, `NFR-S06`

## Story

As an authorized agent, I want to observe terminal and resource changes while detecting incomplete history.

## Acceptance criteria

- [ ] **S025-AC01:** Provide plain-text screen/scrollback snapshots with capture timestamps and base64 raw stream deltas with per-session opaque cursors.
- [ ] **S025-AC02:** Use 64 KiB default/256 KiB maximum read responses, an 8 MiB global replay budget, truncation/gap metadata, and explicit invalid-cursor errors across sessions/restarts.
- [ ] **S025-AC03:** Publish ordered resource/selection/state/exit events with a 1,000-event metadata ring; raw output is separately bounded and requires output-read permission.
- [ ] **S025-AC04:** Redact by grant, signal replay gaps, and disconnect slow clients beyond a 1 MiB outbound queue; revocation immediately ends observation.

## Unit tests

These are test specifications to implement with the story, not executed tests. Names are proposed and may follow repository conventions once the Swift project exists. Isolate time, filesystem, process, Keychain, clipboard, and transport dependencies as relevant; assert observable behavior and failure safety.

| Test | Setup, action, and expected result |
| --- | --- |
| `S025_UT01_cursorEvictionReportsGap` | Read from an evicted stream position; report gap and next cursor; foreign-session cursors return INVALID_CURSOR. |
| `S025_UT02_readLimitsAndBinaryBoundaries` | Request default/max/over-limit output sizes with split UTF-8 bytes; bound responses and preserve exact raw stream bytes. |
| `S025_UT03_metadataReplayGap` | Generate 1,001 metadata events; an evicted sequence gets an explicit gap and resnapshot instruction. |
| `S025_UT04_slowOrRevokedSubscriberStops` | Exceed a fake client queue budget or revoke its grant; stop delivery without retaining unbounded output. |

## Integration and manual verification

Flood a real terminal with output while a slow client subscribes. Verify responsive UI, bounded buffers, snapshot redaction, instance changes, and gap recovery.

## Completion evidence

See [S025 output and events evidence](../../docs/evidence/S025-automation-output-events.md) for journal/cursor, ring/gap, slow-client, redaction, and end-to-end PTY tests, review fixes, and pending multi-client checks.

## Source specifications

[Overview](../01-overview/README.md), [architecture](../02-architecture/README.md), [functional requirements](../03-functional-requirements/README.md), [quality requirements](../04-non-functional-requirements/README.md), [API](../05-api/README.md), [integrations](../06-integrations/README.md), [macOS support](../07-macos-support/README.md), [themes](../03-functional-requirements/themes/README.md)
