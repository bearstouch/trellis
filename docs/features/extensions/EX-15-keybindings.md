# EX-15: Keybindings

Part of the [Extensions specification](SPEC.md#stories). **Epic:** 3, Tier 0 · **Phase:** 3b · **Requirements:** FR-EX13 · **Depends on:** [EX-14](EX-14-commands.md) · **Points:** 3

**Definition.** As a Trellis user, I want to bind keys to extension commands, with the same conflict checks as built-in shortcuts, so that extensions never take over keys I rely on.

Extensions declare `contributes.keybindings` with an optional `suggested` chord, applied only if it is free. Settings → Keyboard shows an Extensions group per extension, user-editable, with the same conflict checks. Chords must include ⌘.

## Scope

**In**

- `extensionShortcuts` in the keyboard shortcut model.
- Apply a `suggested` chord only when it is free.
- Settings → Keyboard: an Extensions group per extension, editable, refusing conflicts and chords without ⌘.
- Key dispatch next to `performShortcut`, running the extension command.

**Out**

- Action `shortcut`s inside extension views (EX-22), which work only while the view has focus.

## Acceptance criteria

- [ ] **Given** a `suggested` chord that no shortcut uses, **when** the extension is enabled, **then** the chord runs the command.
- [ ] **Given** a `suggested` chord that a Trellis or other extension shortcut already uses, **when** the extension is enabled, **then** it is not applied.
- [ ] **Given** Settings → Keyboard, **when** I open it, **then** extension commands are listed in a group per extension.
- [ ] **Given** I assign a conflicting chord, **when** I confirm, **then** it is refused with the conflict named.
- [ ] **Given** I assign a chord without ⌘, **when** I confirm, **then** it is refused.
- [ ] **Given** the extension is disabled, **when** I press its chord, **then** nothing runs.

## Implementation notes

- Changed in `TrellisCore`: `Sources/TrellisCore/KeyboardShortcuts.swift` (`extensionShortcuts`, conflict checks).
- Changed in `TrellisUI`: `Sources/TrellisUI/KeyboardSettingsView.swift`.
- Changed in `TrellisApp`: key dispatch next to `performShortcut` in `Sources/TrellisApp/AppMain.swift`.

## Tests

- Additions to `KeyboardShortcutTests` (`Tests/TrellisCoreTests/KeyboardShortcutTests.swift`): suggested applied only if free; conflicts; ⌘ required.
