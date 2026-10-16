# S017 — Support keyboard navigation and native accessibility

Priority: P0 / MVP  
Status: Planned — implementation and tests not started  
Delivery phase: 3  
Depends on: [S004](004-native-application-shell.md), [S006](006-tabs-and-inline-renaming.md), [S008](008-pane-resize-focus-and-maximize.md), [S011](011-selection-and-copy.md), [S012](012-safe-paste-and-file-paths.md), [S014](014-appearance-and-monaco-defaults.md)  
Requirements: `FR-U01`, `NFR-U01`, `NFR-U02`, `NFR-U03`, `NFR-U04`, `MAC-07`

## Story

As a keyboard or assistive-technology user, I want to operate every primary workflow without relying on pointer input or color alone.

## Acceptance criteria

- [ ] **S017-AC01:** Expose configurable discoverable menu shortcuts, including windows/tabs/splits/search; detect conflicting bindings before saving.
- [ ] **S017-AC02:** Provide accessible labels, roles, selected states, and focus indicators for sidebar, tab bar, renaming, panes, dialogs, and statuses.
- [ ] **S017-AC03:** Support VoiceOver terminal reading, increased contrast, reduced motion, US/Portuguese layouts, dead keys, an IME, and configurable Option-as-Meta.
- [ ] **S017-AC04:** Keep native text-field editing separate from terminal control input; do not request blanket Accessibility permission to make the app usable.

## Unit tests

These are test specifications to implement with the story, not executed tests. Names are proposed and may follow repository conventions once the Swift project exists. Isolate time, filesystem, process, Keychain, clipboard, and transport dependencies as relevant; assert observable behavior and failure safety.

| Test | Setup, action, and expected result |
| --- | --- |
| `S017_UT01_rejectShortcutCollision` | Bind two enabled actions to the same key chord; report both actions and keep the previous map. |
| `S017_UT02_editingConsumesRenameKeys` | With tab-name editing active, Enter/Escape edit the title and never reach the PTY. |
| `S017_UT03_inputRoutingRespectsComposition` | Deliver marked-text composition events; committed text reaches the adapter once and intermediate text is not sent as commands. |
| `S017_UT04_accessibilityStateReflectsSelection` | Project selected window/tab/pane and session exit; expose correct labels/states plus a text status independent of color. |

## Integration and manual verification

Perform a keyboard-only daily workflow and VoiceOver reading/navigation. Test US and Portuguese layouts, dead keys, emoji/CJK, and a real IME; these are not replaced by mocked input tests.

## Completion evidence

Link the implementation and passing relevant tests; record the acceptance demo and any required real-platform results. A story is complete only when its criteria and verification evidence pass. Document blockers rather than marking unavailable checks as passed.

## Source specifications

[Overview](../01-overview/README.md), [architecture](../02-architecture/README.md), [functional requirements](../03-functional-requirements/README.md), [quality requirements](../04-non-functional-requirements/README.md), [API](../05-api/README.md), [integrations](../06-integrations/README.md), [macOS support](../07-macos-support/README.md), [themes](../03-functional-requirements/themes/README.md)
