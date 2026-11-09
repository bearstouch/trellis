# EX-19: UI schema v1 and validator

Part of the [Extensions specification](SPEC.md#stories). **Epic:** 4, Tier 1 native UI · **Phase:** 4 · **Requirements:** FR-EX16, FR-EX28 · **Depends on:** [EX-1](EX-01-contract-docs.md) · **Points:** 5

**Definition.** As a Trellis developer, I want the UI schema v1 as a closed, versioned Codable type with a validator, so that extension trees are checked before rendering and Trellis's own redesigns never break extensions.

An extension view returns a tree of Trellis components as JSON. Trellis keeps it per view as a closed `indirect enum UINode: Codable`. The vocabulary is small and closed: 21 components in v1. Within a major version, changes are only additive.

## Scope

**In**

- `UINode` for every v1 component: `View`, `Stack`, `Section`, `Divider`, `List`, `Row`, `Text`, `Markdown`, `Code`, `KeyValue`, `Badge`, `Icon`, `Image`, `Progress`, `EmptyState`, `Form`, `TextField`/`TextArea`, `Toggle`, `Picker`, `Button`, `Action`, with their key props.
- Tones `default`, `muted`, `accent`, `success`, `warning`, `danger`.
- Unknown component types decode to a placeholder node, never failing the whole tree.
- The validator: required props (`View.title`, `Row.title`, field `label`, `Image.alt`, a text label on every interactive node), fixed spacing steps, `Image.url` only from declared origins, action `shortcut`s that include ⌘, and the caps of 5,000 nodes and 1 MiB per tree.
- `ui: 1` versioning separate from the extension API.
- The authoring library in the helper:
    - `trellis.ui.h(type, props, ...children)`, the JSX factory, and one function per component (`View`, `List`, `Row`, `Action`…), also usable without a build.
    - Folding children into schema props: `Badge`, `Accessory`, `Action` and `Detail` under `Row` become `badge`, `accessories[]`, `actions[]` and `detail`; `Action` under `View` becomes a header action; text children become `text`; `empty="…"` becomes `empty: {title}`; `key` becomes `id`.
    - Replacing each handler function with an ID derived from the node `id` and prop name, and keeping the function in a per-view table.
- `trellis.d.ts` typing every component's props and allowed children.

**Out**

- Rendering (EX-20) and state ownership (EX-21).

## Acceptance criteria

- [ ] **Given** a `Row` with `Badge`, `Accessory`, two `Action` and a `Detail` child, **when** the library serializes it, **then** the JSON has `badge`, `accessories[]`, `actions[]` in order and `detail`, and contains no functions.
- [ ] **Given** an element with `onAction={fn}`, **when** it is serialized, **then** the prop holds a stable ID built from the node `id` and prop name, and the same tree rendered twice yields the same IDs.
- [ ] **Given** the same view written with JSX and with component functions from `trellis.ui`, **when** both render, **then** the JSON trees are identical.
- [ ] **Given** a wrong prop or a disallowed child in a `.tsx` file, **when** it is type-checked against `trellis.d.ts`, **then** the build fails.
- [ ] **Given** every v1 component with valid props, **when** decoded, **then** it round-trips.
- [ ] **Given** an unknown component type, **when** decoded, **then** it becomes a "Requires a newer Trellis" placeholder and a warning is logged.
- [ ] **Given** a tree over 5,000 nodes or 1 MiB, **when** validated, **then** it is rejected.
- [ ] **Given** an interactive node without `title`, `label` or `alt`, **when** validated, **then** it is rejected with the node named.
- [ ] **Given** an `Image.url` from an undeclared origin, **when** validated, **then** it is rejected.
- [ ] **Given** the examples in `docs/api/extension-ui.md`, **when** decoded, **then** they validate.

## Implementation notes

- New in `TrellisCore`: `UINode` (UI schema v1, Codable, validator).
- Schema fixture: `docs/api/extension-ui.schema.json` from EX-1.

## Tests

- `ExtensionUIRendererTests`: every v1 component decodes; unknown type placeholder; labels required; caps.
