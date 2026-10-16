# S029 — Control themes and appearance from scripts

Priority: P0 / MVP  
Status: Implemented — independently reviewed, 289 tests pass; installed-CLI live check pending  
Delivery phase: 4  
Depends on: [S016](016-theme-library-and-preview.md), [S021](021-local-control-socket.md), [S022](022-automation-grants.md), [S027](027-cli-and-agent-workflows.md)  
Requirements: `FR-TH08`, `INT-10`, `API-03`, `API-04`

## Story

As an authorized script author, I want to install a JSON theme and select application appearance programmatically.

## Acceptance criteria

- [ ] **S029-AC01:** Implement theme.list/get/validate/import/export/delete and appearance.get/set with their documented results and appearance.changed events.
- [ ] **S029-AC02:** Enforce theme.read and explicitly global theme.write permissions; layout-only or window-scoped grants cannot change global appearance.
- [ ] **S029-AC03:** Use the same validators, replacement rules, built-in protection, revision checks, and idempotency as UI theme operations.
- [ ] **S029-AC04:** Expose equivalent CLI commands, reject mismatched light/dark theme slots, preserve dark terminal defaults with light chrome, and never start/restart sessions during theme changes.

## Unit tests

These are test specifications to implement with the story, not executed tests. Names are proposed and may follow repository conventions once the Swift project exists. Isolate time, filesystem, process, Keychain, clipboard, and transport dependencies as relevant; assert observable behavior and failure safety.

| Test | Setup, action, and expected result |
| --- | --- |
| `S029_UT01_themePermissionMatrix` | Call each theme/appearance method with read-only, layout-only, window-scoped, and global-write grants; enforce the documented boundary. |
| `S029_UT02_rejectWrongAppearanceSlot` | Assign a dark theme ID to the light slot; return an error and preserve all appearance settings. |
| `S029_UT03_protectBuiltInsAndRevision` | Replace/delete built-ins or submit a stale appearance revision; fail atomically with the specified error. |
| `S029_UT04_appearanceEventHasNoProcessEffects` | Apply a theme once with a keyed retry; emit only committed appearance changes and make zero session lifecycle/input calls. |

## Integration and manual verification

Use CLI commands to validate/import/export a custom theme and switch chrome modes while local/SSH sessions continue running. Confirm denied clients cannot mutate the palette.

## Completion evidence

See [S029 theme control evidence](../../docs/evidence/S029-theme-control-api.md) for permission, slot, built-in/revision, and no-process-effect tests, review fixes, and the pending live check.

## Source specifications

[Overview](../01-overview/README.md), [architecture](../02-architecture/README.md), [functional requirements](../03-functional-requirements/README.md), [quality requirements](../04-non-functional-requirements/README.md), [API](../05-api/README.md), [integrations](../06-integrations/README.md), [macOS support](../07-macos-support/README.md), [themes](../03-functional-requirements/themes/README.md)
