# EX-4: Extension registry: approvals, code pinning, rules, storage, settings, audit

Part of the [Extensions specification](SPEC.md#stories). **Epic:** 1, Foundations · **Phase:** 2 · **Requirements:** FR-EX06, FR-EX27, FR-EX28 · **Depends on:** [EX-3](EX-03-extension-catalog.md) · **Points:** 5

**Definition.** As a Trellis user, I want Trellis to remember exactly what I approved for each extension, tied to the code I approved, so that an extension can't quietly gain power or inherit my approval after its files change.

The registry is the actor that owns every extension's persistent state: enabled flags, approved sets, code hashes, remembered prompt choices, storage, settings and the audit log. It is the source of truth that EX-8 turns into grants.

## Scope

**In**

- `ExtensionRegistry` actor with `<state-dir>/extensions.json`: enabled flags, approved sets (permissions, origins, OAuth providers, events) and remembered rules. Versioned, written atomically, with a last-known-good backup. A corrupt or newer file is kept and the registry becomes read-only.
- Store the approved set exactly. A later manifest that asks for more suspends the extension until the user re-approves. Asking for less never prompts.
- Code pinning: record a SHA-256 hash of the manifest and `main.js` on approval. If the files on disk no longer match, suspend the extension and stop using its remembered choices until the user approves again.
- A per-extension Development mode flag. While on, edits don't suspend, and remembered Always Allow choices are ignored.
- Bundled extensions are pinned by the app's code signature and still start Disabled.
- At most 15 enabled extensions; enabling a 16th is refused with the reason.
- Suspension reasons: asks for more, code changed (when pinned), `engines` not met, disabled after repeated crashes.
- `<state-dir>/ExtensionData/<name>/` (0700) with `storage.json`, `settings.json`, `audit.log` and `extension.log`, each 0600.
- Remembered rules: add, list and revoke.

**Out**

- The approval sheet and Settings UI (EX-10).
- Prompting and writing audit entries (EX-9); this story provides the log file and its rotation.
- The `trellis.storage` and `trellis.settings` JavaScript APIs (EX-18).
- Keychain items (EX-28, EX-29).

## Acceptance criteria

- [ ] **Given** a newly found extension, **when** the registry loads, **then** it is Disabled.
- [ ] **Given** an approved extension, **when** its manifest asks for an extra permission, origin, event or provider, **then** it becomes Suspended with that reason until re-approved.
- [ ] **Given** an approved extension, **when** its manifest asks for less, **then** it stays Enabled and nothing prompts.
- [ ] **Given** a pinned extension, **when** `main.js` or the manifest changes on disk, **then** it is Suspended and its remembered choices are not used until the user approves again.
- [ ] **Given** an extension in Development mode, **when** `main.js` changes, **then** it is not suspended, and remembered Always Allow choices are ignored.
- [ ] **Given** 15 enabled extensions, **when** the user enables a 16th, **then** it is refused with the reason.
- [ ] **Given** a corrupt or newer `extensions.json`, **when** Trellis starts, **then** the file is kept unchanged and the registry is read-only.
- [ ] **Given** the registry writes state, **when** I inspect the files, **then** `extensions.json` and each data file are 0600 and `ExtensionData/<name>/` is 0700, and a last-known-good backup exists.
- [ ] **Given** a remembered rule, **when** it is revoked, **then** the next matching action prompts again.
- [ ] **Given** a registry write that fails, **when** the write is retried or the app restarts, **then** the previous state is retained.

## Implementation notes

- New in `TrellisCore`: `ExtensionRegistry` (actor).
- Reuse `OwnerOnlyFile` and the atomic-write pattern from `Sources/TrellisControl/AutomationGrant.swift`, and the versioned, last-known-good approach of `WorkspacePersistence` (`Sources/TrellisCore/WorkspacePersistence.swift`).
- Inject the clock, file system and hashing so tests are deterministic.
- The registry later implements `GrantResolving` (EX-8).

## Tests

- `ExtensionRegistryTests`: starts disabled; suspension when asking for more; code pinning and Development mode; rules and revoke; 15-extension limit; corrupt files kept and read-only.
