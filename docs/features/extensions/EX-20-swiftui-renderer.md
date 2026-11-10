# EX-20: SwiftUI renderer

Part of the [Extensions specification](SPEC.md#stories). **Epic:** 4, Tier 1 native UI · **Phase:** 4 · **Requirements:** FR-EX16 · **Depends on:** [EX-7](EX-07-extension-supervisor.md), [EX-19](EX-19-ui-schema.md) · **Points:** 13

**Definition.** As a Trellis user, I want extension views drawn by Trellis with its own SwiftUI views, so that they look and behave exactly like built-in views in every theme and mode.

Trellis renders `UINode` with a `switch` in a `@ViewBuilder`. Every render sends the whole tree, and SwiftUI diffs it by node ID. Tones map to theme tokens, so extensions follow every theme and light or dark mode. An invalid tree keeps the last good render and shows an error banner.

## Scope

**In**

- `UINodeView`: a SwiftUI view for each v1 component, using theme tokens for tones, JetBrains Mono for `Code`.
- Identity from node `id`s (or a stable index), so typing, scrolling and selection survive updates.
- `Markdown`: a CommonMark subset (headings, emphasis, lists, code, links, tables), no HTML, no remote images. A link shows its destination host, and Trellis asks before opening an origin the extension didn't declare.
- `Image` with `url` fetched by the app from declared origins.
- `Row.detail`: push navigation with a Back button in the sidebar and modals, and a split pane in tabs.
- Placeholders: "Requires a newer Trellis" for unknown types, "Restarting…" while the helper restarts, an error placeholder for an undefined view.
- An invalid tree keeps the last good render and shows an error banner.
- At most 60 UI updates per second per view; extra updates are coalesced.
- `ExtensionBridge` routing render frames to the renderer and events back to the helper as handler IDs, which the authoring library maps to the function from the latest render.

**Out**

- Form, search, selection and pagination state rules (EX-21).
- Focus chain and VoiceOver details (EX-22).
- The surfaces that host the view (EX-23, EX-25, EX-26).

## Acceptance criteria

- [ ] **Given** each v1 component, **when** rendered in light and dark mode, **then** it uses theme tokens and matches built-in views.
- [ ] **Given** a re-render with the same node IDs, **when** it arrives, **then** text being typed, scroll position and selection are kept.
- [ ] **Given** an unknown type in a tree, **when** rendered, **then** a placeholder shows for that node and the rest renders.
- [ ] **Given** an invalid tree, **when** it arrives, **then** the last good render stays and an error banner shows.
- [ ] **Given** a Markdown link to an undeclared origin, **when** I click it, **then** Trellis asks before opening it, and the link shows its destination host.
- [ ] **Given** Markdown with HTML or a remote image, **when** rendered, **then** neither is shown as HTML or loaded.
- [ ] **Given** 200 updates in one second, **when** rendered, **then** at most 60 reach the view and the last state is shown.
- [ ] **Given** a row action, **when** I trigger it, **then** the `onAction` function written on that `Action` runs, with the data it closed over. **Given** an event whose handler ID is gone after a re-render, **then** it is dropped and logged.

## Implementation notes

- New in `TrellisUI`: `UINodeView`, the rest of `ExtensionBridge`.
- Theme tokens from `Sources/TrellisUI/WorkspaceTheme.swift`.
- Reuse the agent icon drawing (`AgentIconView`, `AgentIconImages` in `Sources/TrellisUI/AgentViews.swift`) for `Icon` assets and SVGs.
- Image fetches go through `ExtensionFetch` once EX-27 lands; until then `Image.url` can show a placeholder.

## Tests

- `ExtensionUIRendererTests`: every v1 component renders; re-renders keep identity and typed text; unknown type placeholder; invalid tree keeps the last render; update coalescing.
