# EX-23: Sidebar apps in the dock, with badges and dimming

Part of the [Extensions specification](SPEC.md#stories). **Epic:** 4, Tier 1 native UI · **Phase:** 4 · **Requirements:** FR-EX18, FR-EX15 · **Depends on:** [EX-17](EX-17-notifications-clipboard.md), [EX-20](EX-20-swiftui-renderer.md) · **Points:** 5

**Definition.** As a Trellis user, I want extension sidebar views in the dock next to the built-in ones, with badges and dimming, so that I can switch to them the same way and see when they need me.

Enabled extensions' sidebar views appear in the dock below the built-in views, after a divider. They share the sidebar's width and switching rules, and follow the focused pane. `sidebarView` becomes `SidebarItem?`, so `SidebarView` and its tests are unchanged.

## Scope

**In**

- `enum SidebarItem { case builtIn(SidebarView), extension(SurfaceID) }`, and `sidebarView` becomes `SidebarItem?`.
- A dock section below a divider, after the built-ins, which never move. Each icon has a tooltip and accessibility label from `title`, and the selected trait while shown.
- `ExtensionSidebarPanel` with the standard `SidebarHeader`: the View's `actions` as buttons, then Close.
- Shared width (FR-SB03) and switching rules (FR-SB02), one view at a time.
- Dimming by `machines` (`local`, `remote`, `ssh`; default local and remote) with the reason ("PR Board only works with local panes"); the sidebar hides and reappears as focus moves (FR-SB04).
- Badges from `sidebar.setBadge` as text in a capsule, spoken as the accessibility value.
- The "needs permission" mark (EX-9), the "Dev" marker (EX-10) and the dimmed Suspended state with its reason.
- `trellis.sidebar.open(id)`, and `onShow` and `onHide`. The view's state lives in the extension, so hiding and showing keeps it.

**Out**

- Tabs and modals (EX-25, EX-26).

## Acceptance criteria

- [ ] **Given** two enabled extensions with sidebar views, **when** a window has a pane, **then** their icons appear below a divider after the built-in icons, which keep their order.
- [ ] **Given** an extension icon, **when** I hover or inspect it, **then** it has a tooltip and accessibility label from `title`, and the selected trait while shown.
- [ ] **Given** I click it, **when** another view is shown, **then** the extension view replaces it at the same width. **Given** I click it again, **then** the sidebar hides and focus returns to the terminal.
- [ ] **Given** `machines: ["local"]` and an SSH pane is focused, **when** I look at the dock, **then** the icon is dimmed with the reason, and the sidebar hides if that view was open.
- [ ] **Given** `setBadge(id, {count: 3, tone: "warning"})`, **when** the dock shows, **then** a "3" capsule appears and the accessibility value says it.
- [ ] **Given** the sidebar is hidden and shown again, **when** it reappears, **then** the view's state is kept, and `onHide` then `onShow` were called.
- [ ] **Given** the extension is disabled, **when** the dock redraws, **then** its icon is gone. **Given** it is suspended, **then** the icon is dimmed with the reason.

## Implementation notes

- Changed in `TrellisUI`: `Sources/TrellisUI/AppWorkspaceModel+Sidebar.swift` (`SidebarItem`), `Sources/TrellisUI/RightSidebar.swift` (dock section, panel branch, `SidebarHeader`).
- New in `TrellisUI`: `ExtensionSidebarPanel`.
- Reuse the dock badge view and the dimming rules from `docs/features/sidebar.md`.

## Tests

- `ExtensionSurfaceTests`: sidebar dock order, dimming, badge.
- Additions to `Tests/TrellisUITests/RightSidebarTests.swift`: dock items.
