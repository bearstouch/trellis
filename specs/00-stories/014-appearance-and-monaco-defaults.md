# S014 — Apply light chrome and dark Monaco terminals

Priority: P0 / MVP  
Status: Implemented — reviewed fixes, automated regressions, and native appearance checks pass  
Delivery phase: 3  
Depends on: [S001](001-terminal-engine-feasibility.md), [S004](004-native-application-shell.md)  
Requirements: `FR-U02`, `FR-TH01`, `FR-TH05`, `FR-TH06`, `MAC-07`

## Story

As a terminal user, I want to get the agreed Native calm appearance immediately without configuring it.

## Acceptance criteria

- [x] **S014-AC01:** First launch uses light sidebar/title/tab/settings chrome and dark terminal backgrounds with light text; Monaco is the default terminal font.
- [x] **S014-AC02:** Provide Light, Dark, and System chrome modes; both built-in themes keep terminals dark. Explicit modes ignore system appearance changes.
- [x] **S014-AC03:** Allow font family/size, zoom, cursor style, and scrollback settings; if Monaco is unavailable, use Menlo/system monospace with a visible notice.
- [x] **S014-AC04:** Apply appearance/font changes without restarting sessions or losing focus/selection. Persist mode, font settings, and selected dark/light theme IDs through the persistence service.

## Unit tests

These are test specifications to implement with the story, not executed tests. Names are proposed and may follow repository conventions once the Swift project exists. Isolate time, filesystem, process, Keychain, clipboard, and transport dependencies as relevant; assert observable behavior and failure safety.

| Test | Setup, action, and expected result |
| --- | --- |
| `S014_UT01_firstLaunchPalette` | Resolve empty preferences; select light chrome, dark terminal colors, and Monaco. |
| `S014_UT02_systemModeVsExplicitMode` | Simulate system appearance changes; only System changes chrome, and both built-in terminal backgrounds remain dark. |
| `S014_UT03_missingMonacoFallback` | Use a font catalog without Monaco; choose the documented monospace fallback and expose a notice. |
| `S014_UT04_appearanceHasNoSessionEffects` | Change theme/font settings with live sessions; process spy sees zero spawn/input/termination calls and selection remains intact. |

## Integration and manual verification

Inspect light/dark/system modes on macOS, Monaco rendering and cell metrics, zoom, missing-font behavior, and preference restoration once S010 is available.

## Completion evidence

See [S014 appearance evidence](../../docs/evidence/S014-appearance.md) for the implementation, independent review findings and fixes, passing tests, native settings/zoom/restoration checks, and remaining platform qualification scope. Selection preservation applies to retained text; explicitly evicted history and alternate-screen cells clipped by a geometry change cannot be retained as a terminal selection.

## Source specifications

[Overview](../01-overview/README.md), [architecture](../02-architecture/README.md), [functional requirements](../03-functional-requirements/README.md), [quality requirements](../04-non-functional-requirements/README.md), [API](../05-api/README.md), [integrations](../06-integrations/README.md), [macOS support](../07-macos-support/README.md), [themes](../03-functional-requirements/themes/README.md)
