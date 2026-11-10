# EX-22: Keyboard and accessibility of extension views

Part of the [Extensions specification](SPEC.md#stories). **Epic:** 4, Tier 1 native UI · **Phase:** 4 · **Requirements:** FR-EX17 · **Depends on:** [EX-20](EX-20-swiftui-renderer.md) · **Points:** 5

**Definition.** As a keyboard and VoiceOver user, I want extension views to join Trellis's focus chain and speak properly, so that I can use them without a mouse and without guessing.

Views join Trellis's existing focus, shortcut and accessibility model. Trellis builds VoiceOver labels, values, selected state and headings from the schema.

## Scope

**In**

- Tab and Shift-Tab move between the header, the search field, the list and the detail. Esc returns focus to the terminal.
- Arrow keys move in lists; Return runs the row's first action.
- Action `shortcut`s must include ⌘, work only while the view has focus and never override a Trellis shortcut; a conflict is ignored and logged.
- Required text labels (`title`, `label` or `alt`) on every interactive node.
- VoiceOver labels, values (badges and accessories read as text), selected state and headings (`Section` headers) built from the schema.
- Tone never conveyed by color alone.
- Reduce Motion, Increase Contrast and the user's text size are respected.
- The row's actions also appear in its context menu.

**Out**

- Focus inside modals (EX-26) and tabs (EX-25), which reuse this.

## Acceptance criteria

- [ ] **Given** a sidebar view with a header, search field, list and detail, **when** I press Tab and Shift-Tab, **then** focus moves through those regions in order.
- [ ] **Given** a focused list, **when** I press the arrow keys and Return, **then** selection moves and the row's first action runs.
- [ ] **Given** focus in an extension view, **when** I press Esc, **then** focus returns to the focused terminal.
- [ ] **Given** an action shortcut that conflicts with a Trellis shortcut, **when** I press it, **then** Trellis's action runs and the conflict is logged.
- [ ] **Given** an action shortcut, **when** the view doesn't have focus, **then** it does nothing.
- [ ] **Given** a badge or accessory with a tone, **when** read by the accessibility tree, **then** its text is the value, not only the color.
- [ ] **Given** Reduce Motion or Increase Contrast, **when** a view renders, **then** it respects the setting.
- [ ] **(manual)** **Given** VoiceOver, **when** I walk a sidebar view, a tab and a modal, **then** labels, values, selected state and headings are spoken. Stays **pending** until observed.

## Implementation notes

- Changed in `TrellisUI`: `UINodeView` (EX-20).
- Follow the focus handling in `Sources/TrellisUI/RightSidebar.swift` and `Sources/TrellisUI/WorkspaceRootView.swift`, and the conflict checks in `Sources/TrellisCore/KeyboardShortcuts.swift`.
- See `docs/features/keyboard-accessibility.md` for existing rules.

## Tests

- `ExtensionUIRendererTests`: labels required; accessibility values for badges and accessories.
- Additions to `Tests/TrellisUITests/KeyboardAccessibilityTests.swift`: focus regions and Esc.
