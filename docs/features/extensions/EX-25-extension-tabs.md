# EX-25: Extension tabs

Part of the [Extensions specification](SPEC.md#stories). **Epic:** 5, Tabs and modals · **Phase:** 5 · **Requirements:** FR-EX19, FR-EX15 · **Depends on:** [EX-20](EX-20-swiftui-renderer.md), [EX-24](EX-24-presentation-tab-list.md) · **Points:** 5

**Definition.** As a Trellis user, I want an extension to open a tab with its own view, so that wider views like a board have room without leaving the space.

`trellis.tabs.open(id, props)`, or a command with `opens: "tab:<id>"`, adds an extension tab to the focused space after the focused tab. Extension tabs are not saved and not in the control API, but they appear in `trellis.state`.

## Scope

**In**

- `ExtensionTabView` on the presentation tab list (EX-24), showing the extension icon and title, with the accessibility label "Extension tab, <name>".
- `trellis.tabs.open(id, props)` → tabId, `setTitle`, `setBadge` and `close`.
- Several instances of one type, each with its own `props` (at most 64 KiB JSON) and state. At most 8 extension tabs per extension.
- ⌘W calls `onClose` (at most 2 s) and closes the tab, with no confirmation.
- `Row.detail` shown in a split pane inside the tab.
- Absent from the saved workspace, `layout.export`, `tab.list` and API events; present in `trellis.state` with `kind: "extension"`, and only the owning extension sees its tabs' `props`.
- Tab badges as text in a capsule, spoken as the accessibility value.

**Out**

- Persisted extension tabs and extension panes inside a split (deferred).

## Acceptance criteria

- [ ] **Given** `tabs.open("board", props)`, **when** it runs, **then** a tab with the extension icon and title opens after the focused tab and the view gets `view.props`.
- [ ] **Given** a focused extension tab, **when** I press ⌘W, **then** `onClose` is called, and the tab closes within 2 s even if `onClose` doesn't return.
- [ ] **Given** an extension tab, **when** I check the saved workspace, `layout.export` and `tab.list`, **then** it is absent. **When** an extension reads `trellis.state`, **then** it is present with `kind: "extension"`, and only its owner sees `props`.
- [ ] **Given** 8 open tabs of one extension, **when** it opens a 9th, **then** it is refused.
- [ ] **Given** `props` over 64 KiB, **when** passed to `open`, **then** it is refused.
- [ ] **Given** `tabs.setBadge`, **when** it is called, **then** the tab shows the badge as text with a spoken value.
- [ ] **Given** Trellis relaunches, **when** the workspace restores, **then** no extension tab is restored.

## Implementation notes

- New in `TrellisUI`: `ExtensionTabView`.
- Changed: `Sources/TrellisUI/WorkspaceRootView.swift` (extension tabs), the presentation tab list from EX-24, `ExtensionStateProjector` (EX-12).

## Tests

- `ExtensionSurfaceTests`: tabs absent from snapshots; ⌘W and `onClose`; limits; badge.
