# EX-21: State ownership: forms, search, selection, pagination

Part of the [Extensions specification](SPEC.md#stories). **Epic:** 4, Tier 1 native UI · **Phase:** 4 · **Requirements:** FR-EX16 · **Depends on:** [EX-20](EX-20-swiftui-renderer.md) · **Points:** 5

**Definition.** As a Trellis user, I want what I type, select and scroll in an extension view to stay put while the extension updates, so that the view never fights me.

Trellis owns form values, the search query, selection, scroll position and focus. The extension is told about changes through callbacks and re-renders.

## Scope

**In**

- Form fields: Trellis holds what the user typed. A field's `value` prop is only its initial value. A re-render never overwrites it unless the node's `id` changes or the extension calls `view.resetField(id, value)`.
- A field's `onChange` handler gets the new value, debounced to 150 ms. A `Form`'s `onSubmit` handler gets every value by field `id`.
- Search: with `filtering: "local"` Trellis filters rows by title and subtitle; with `filtering: "extension"` it calls the `List`'s `onSearch` handler with the query, debounced to 150 ms.
- Selection: Trellis holds the selected row and calls that `Row`'s `onSelect` handler.
- Pagination: a `List` with `hasMore: true` shows a Load More row; activating it calls the `List`'s `onLoadMore` handler.
- Scroll position and focus survive re-renders.
- `defineView(name, setup)`: `setup(view)` runs once per view instance and returns the render function.
- `view.state(initial)`: top-level assignments schedule a re-render, and several in one turn make one render. Nested changes don't re-render.
- `view.props`, `view.close(result)`, `view.resetField(id, value)`, and the `view.onShow`, `view.onHide` and `view.onClose` hooks.
- Inline handlers on components: `onAction`, `onChange` (value), `onSubmit` (values by field `id`), `onSearch`, `onSelect`, `onLoadMore`.

**Out**

- `onShow`, `onHide` and `onClose` (EX-23, EX-25, EX-26).

## Acceptance criteria

- [ ] **Given** a view defined with `defineView`, **when** a surface first shows it, **then** setup runs once and the returned function renders.
- [ ] **Given** `state.loading = true; state.prs = list` in one turn, **when** the turn ends, **then** exactly one render is sent.
- [ ] **Given** `state.prs.push(pr)`, **when** nothing is assigned, **then** no render is sent; assigning a new array renders.
- [ ] **Given** a `TextField` I am typing in, **when** the extension re-renders with a different `value`, **then** my text is kept.
- [ ] **Given** the extension calls `view.resetField(id, value)`, **when** it runs, **then** the field shows the new value.
- [ ] **Given** typing, **when** I type several characters quickly, **then** `onChange` fires once per 150 ms pause (injected clock).
- [ ] **Given** `filtering: "local"`, **when** I type a query, **then** only rows whose title or subtitle match are shown, with no extension call.
- [ ] **Given** `filtering: "extension"`, **when** I type, **then** `onSearch` is called, debounced to 150 ms.
- [ ] **Given** I select a row, **when** selection changes, **then** `onSelect` is called with its node ID.
- [ ] **Given** `hasMore: true`, **when** I activate Load More, **then** `onLoadMore` is called.
- [ ] **Given** I have scrolled a list, **when** the extension re-renders, **then** the scroll position is kept.

## Implementation notes

- Changed in `TrellisUI`: `UINodeView` and `ExtensionBridge` (EX-20).
- Inject the clock for the debounces.

## Tests

- `ExtensionUIRendererTests`: re-renders keep typed text, selection and scroll; debounces; local filtering; Load More.
