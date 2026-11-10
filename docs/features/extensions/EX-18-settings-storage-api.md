# EX-18: Contributed settings and storage API

Part of the [Extensions specification](SPEC.md#stories). **Epic:** 3, Tier 0 · **Phase:** 3b · **Requirements:** FR-EX15 · **Depends on:** [EX-4](EX-04-extension-registry.md), [EX-10](EX-10-settings-extensions.md) · **Points:** 3

**Definition.** As an extension author, I want to contribute settings that render natively and to keep my own small storage, so that users configure my extension in Settings and it remembers its data between runs.

Contributed settings render as native controls on the extension's Settings page and are read with `trellis.settings.get`, with change events. The `storage` permission gives the extension its own JSON key-value storage of 1 MiB, stored 0600.

## Scope

**In**

- Native controls for `contributes.settings` types `string`, `bool`, `number` and `enum` (with `options`), with defaults, on the extension's Settings page.
- `trellis.settings.get(key)` and `onChange(fn)`. Values in `ExtensionData/<name>/settings.json`.
- `trellis.storage.get/set/delete/keys`, needing `storage`, capped at 1 MiB in `ExtensionData/<name>/storage.json`.

**Out**

- Secrets (EX-29). Setting keys containing token, secret or password are already rejected by EX-2.

## Acceptance criteria

- [ ] **Given** contributed settings, **when** I open the extension's Settings page, **then** each renders as a native control with its default.
- [ ] **Given** I change a setting, **when** the extension is subscribed with `onChange`, **then** it receives the change and `settings.get` returns the new value.
- [ ] **Given** `storage`, **when** the extension sets and gets values, **then** they round-trip and survive a relaunch.
- [ ] **Given** a write that would exceed 1 MiB, **when** it is made, **then** it is rejected and the stored data is unchanged.
- [ ] **Given** no `storage` permission, **when** the extension calls `storage.set`, **then** it gets `PERMISSION_DENIED`.
- [ ] **Given** the storage and settings files, **when** I inspect them, **then** they are 0600.

## Implementation notes

- Storage and settings files are owned by `ExtensionRegistry` (EX-4).
- Controls live in `ExtensionSettingsView` (EX-10).

## Tests

- `ExtensionRegistryTests`: storage cap and failure safety; settings round-trip.
- `ExtensionStateTests` or `ExtensionSurfaceTests`: settings change events.
