# EX-24: Presentation tab list (Review tab moves onto it)

Part of the [Extensions specification](SPEC.md#stories). **Epic:** 5, Tabs and modals · **Phase:** 5 · **Requirements:** FR-EX19 · **Depends on:** None · **Points:** 8

**Definition.** As a Trellis user, I want tabs that aren't part of the saved workspace to sit in the tab bar and take part in tab switching like any other tab, so that extension tabs and the Review tab feel native.

The Review tab is one per space, selected by a flag, and sits outside the ordered tabs. Extension tabs need more: a per-space list of presentation tabs kept in `AppWorkspaceModel`, each with its own UUID and a position relative to the stored tabs. The Review tab moves onto the same list, so there is one mechanism. Whether that move is acceptable in phase 5 is an open question.

## Scope

**In**

- A per-space presentation tab list in `AppWorkspaceModel`: each entry has its own UUID and a position relative to the stored tabs.
- The tab bar, tab switching (next, previous, ⌘1–9) and the palette's tab list show stored and presentation tabs as one sequence.
- The Review tab moves onto this list.
- Presentation tabs never enter `WorkspaceStore`.
- Split commands are disabled while a presentation tab is focused.
- Closing a space closes its presentation tabs.

**Out**

- Extension tab content and the `trellis.tabs` API (EX-25).

## Acceptance criteria

- [ ] **Given** a space with stored tabs and a Review tab, **when** I press next and previous tab, **then** focus moves through all of them in tab-bar order.
- [ ] **Given** ⌘1–9, **when** I press them, **then** they select tabs by their position in the combined sequence.
- [ ] **Given** the palette's tab list, **when** I open it, **then** presentation tabs are listed with stored tabs.
- [ ] **Given** a presentation tab, **when** the workspace is saved, **then** it is absent from the saved file.
- [ ] **Given** the Review tab, **when** I open, switch to and close it, **then** it behaves as before the change.
- [ ] **Given** a presentation tab is focused, **when** I use a split command, **then** it is disabled.

## Implementation notes

- Changed in `TrellisUI`: `Sources/TrellisUI/AppWorkspaceModel.swift` (`reviewTabs` becomes part of the presentation list), `Sources/TrellisUI/AppWorkspaceModel+GitChanges.swift` (`ReviewTab`), `Sources/TrellisUI/ReviewTabView.swift`, `Sources/TrellisUI/WorkspaceRootView.swift` (tab bar), `Sources/TrellisUI/AppWorkspaceModel+CommandPalette.swift`.
- Follow the `ReviewTab` pattern for presentation-only tabs.

## Tests

- `ExtensionSurfaceTests`: tab switching across stored and presentation tabs.
- Existing `Tests/TrellisUITests/TabManagementTests.swift` and `ChangesSidebarTests.swift` keep passing, with the Review tab on the new list.
