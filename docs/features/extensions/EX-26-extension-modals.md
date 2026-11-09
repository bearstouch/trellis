# EX-26: Extension modals with fixed chrome

Part of the [Extensions specification](SPEC.md#stories). **Epic:** 5, Tabs and modals · **Phase:** 5 · **Requirements:** FR-EX20 · **Depends on:** [EX-14](EX-14-commands.md), [EX-20](EX-20-swiftui-renderer.md) · **Points:** 5

**Definition.** As a Trellis user, I want extension modals that always show which extension they belong to and only appear when I asked for them, so that a modal can't pass as a Trellis or macOS prompt or nag me.

`trellis.modals.open(id, props)`, or a command with `opens: "modal:<id>"`, shows the view as a sheet at the declared size. Trellis draws fixed chrome the extension can't change. A modal can open only within 5 s of a user action aimed at the extension.

## Scope

**In**

- `ExtensionModalSheet` at `small` (420 pt), `medium` (560 pt) or `large` (760 pt).
- Fixed chrome: a header with the extension's icon and name ("<name> · extension"), the modal's title, a Cancel button and Esc handling.
- A `secure` text field always shows the caption "Entered into <name>".
- `open` returns a Promise resolved by `view.close(result)`, or `null` on Cancel or Esc.
- One modal per window at a time; another extension's request waits in a queue.
- The anti-nag rule: within 5 s of a command, an action in its view, or a click on its notification; otherwise `USER_GESTURE_REQUIRED`.
- Focus moves into the modal and returns to where it was when it closes. `onClose` runs with at most 2 s.

**Out**

- Trellis's own permission prompt style (EX-9).

## Acceptance criteria

- [ ] **Given** a command with `opens: "modal:checkout"`, **when** I run it, **then** a sheet at the declared size shows the extension's icon, name, the modal title and Cancel.
- [ ] **Given** the view calls `view.close(result)`, **when** it closes, **then** the Promise resolves with `result`. **Given** Cancel or Esc, **then** it resolves with `null`.
- [ ] **Given** no user action aimed at the extension in the last 5 s, **when** it calls `modals.open`, **then** it rejects with `USER_GESTURE_REQUIRED`.
- [ ] **Given** a modal is open, **when** another extension opens one, **then** it waits until the first closes.
- [ ] **Given** a `secure` field, **when** it renders, **then** it shows "Entered into <name>".
- [ ] **Given** the extension's tree, **when** it tries to change or hide the header, **then** the chrome is unchanged.
- [ ] **Given** the modal closes, **when** focus moves, **then** it returns to where it was before.

## Implementation notes

- New in `TrellisUI`: `ExtensionModalSheet`.
- Changed: `Sources/TrellisUI/WorkspaceRootView.swift` (modal sheet).
- The 5 s user-action clock is shared with EX-9 and EX-17.

## Tests

- `ExtensionSurfaceTests`: modal result, cancel, gesture rule, single modal, fixed chrome.
