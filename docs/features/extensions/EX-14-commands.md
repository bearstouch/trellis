# EX-14: Commands in the palette and View menu

Part of the [Extensions specification](SPEC.md#stories). **Epic:** 3, Tier 0 · **Phase:** 3b · **Requirements:** FR-EX12 · **Depends on:** [EX-7](EX-07-extension-supervisor.md), [EX-10](EX-10-settings-extensions.md) · **Points:** 3

**Definition.** As a Trellis user, I want extension commands in the command palette and the View menu, so that I can run them the same way as built-in commands.

Commands are declared in `contributes.commands` and handled with `trellis.commands.on(id, fn)`. A command with `opens` also shows the named sidebar view, tab or modal. Running a command counts as a user action for the 5 s rules.

## Scope

**In**

- A palette target `.extension(name, command)` and an "Extensions" section, hidden while the extension is disabled.
- View → Extensions ▸ … with each enabled extension's commands.
- Recents keyed `ext:<name>.<cmd>`.
- `trellis.commands.on(id, fn)` and the `command.<id>` event.
- `opens` = `sidebar:<id>` | `tab:<id>` | `modal:<id>`, opening that surface after the handler is called.
- Running a command starts the helper if needed (EX-7) and marks a user action for prompts, modals, sign-in, clipboard and `openURL`.

**Out**

- Keybindings (EX-15).
- The sidebar, tab and modal surfaces themselves (EX-23, EX-25, EX-26). Before they land, `opens` is validated but has nothing to show.

## Acceptance criteria

- [ ] **Given** an enabled extension with commands, **when** I open the palette, **then** they appear under an Extensions section.
- [ ] **Given** the same extension, **when** I open View → Extensions, **then** its commands are listed.
- [ ] **Given** the extension is disabled, **when** I open the palette or the menu, **then** its commands are hidden.
- [ ] **Given** I run a command, **when** it executes, **then** the handler registered with `commands.on` is called and the surface named in `opens` opens.
- [ ] **Given** I run a command, **when** I open the palette again, **then** it appears in recents under `ext:<name>.<cmd>`.
- [ ] **Given** a command handler that triggers a prompted action within 5 s, **when** it runs, **then** the prompt shows as a sheet, not queued.

## Implementation notes

- Changed in `TrellisCore`: `Sources/TrellisCore/CommandPalette.swift` (`.extension(name, command)` target).
- Changed in `TrellisUI`: `Sources/TrellisUI/AppWorkspaceModel+CommandPalette.swift`.
- Changed in `TrellisApp`: the View → Extensions menu in `Sources/TrellisApp/AppMain.swift`.

## Tests

- Additions to `CommandPaletteTests` (`Tests/TrellisCoreTests/CommandPaletteTests.swift`, `Tests/TrellisUITests/CommandPaletteTests.swift`): Extensions section; hidden while disabled; recents key.
