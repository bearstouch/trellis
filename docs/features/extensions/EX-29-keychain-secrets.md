# EX-29: Keychain secrets

Part of the [Extensions specification](SPEC.md#stories). **Epic:** 6, Network and OAuth · **Phase:** 6 · **Requirements:** FR-EX24 · **Depends on:** [EX-4](EX-04-extension-registry.md), [EX-8](EX-08-grant-resolving.md) · **Points:** 2

**Definition.** As a Trellis user, I want extensions to keep secrets I give them, such as a pasted API key, in the Keychain, so that those secrets never end up in plain files, logs or diagnostics.

`secrets.get/set/delete` store strings under the same Keychain service as OAuth tokens, `Trellis Extension`, with account `<name>/secret:<key>`. The extension can read back its own secrets, and the Settings page says so.

## Scope

**In**

- `trellis.secrets.get/set/delete(key)`, needing `secrets`.
- An injected Keychain store shared with EX-28, under service `Trellis Extension`.
- Limits: 32 keys of 16 KiB each.
- Values excluded from storage, logs, the audit log and diagnostics, and deleted with the extension.
- A note on the extension's Settings page that it can read back its own secrets.

**Out**

- OAuth tokens (EX-28).

## Acceptance criteria

- [ ] **Given** `secrets`, **when** the extension sets and gets a secret, **then** it round-trips.
- [ ] **Given** 32 stored keys, **when** a 33rd is set, **then** it is refused. **Given** a value over 16 KiB, **then** it is refused.
- [ ] **Given** a stored secret, **when** I read `storage.json`, the extension log, the audit log and a diagnostics export, **then** the value appears in none of them.
- [ ] **Given** the extension is removed, **when** removal completes, **then** its secrets are deleted from the Keychain.
- [ ] **Given** no `secrets` permission, **when** the extension calls `secrets.set`, **then** it gets `PERMISSION_DENIED`.

## Implementation notes

- Keychain access follows `Sources/TrellisCore/HostSecrets.swift` (`HostSecretStore`), with the store injected.
- One service, `Trellis Extension`, for every extension; the account prefix `<name>/` separates them.

## Tests

- `ExtensionSecretsTests`: round-trip; limits; never in storage, logs or diagnostics; cleanup.
