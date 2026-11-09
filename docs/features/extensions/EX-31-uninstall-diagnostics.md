# EX-31: Uninstall and diagnostics coverage

Part of the [Extensions specification](SPEC.md#stories). **Epic:** 7, CLI and first-party extension · **Phase:** 7 · **Requirements:** FR-EX29 · **Depends on:** [EX-4](EX-04-extension-registry.md), [EX-29](EX-29-keychain-secrets.md) · **Points:** 2

**Definition.** As a Trellis user, I want uninstalling Trellis to remove every extension file and Keychain item, and diagnostics to describe extensions without exposing their data, so that nothing is left behind and nothing private leaks.

`UninstallPlanner` gains the extension folders and the `Trellis Extension` Keychain service. Diagnostics export lists each extension's name, version, state and last error, and never storage, settings values, secrets or tokens.

## Scope

**In**

- `UninstallPlanner`: `Extensions/`, `ExtensionData/` and `extensions.json`, and `Trellis Extension` in its Keychain service list.
- Diagnostics export: each extension's name, version, state and last error, and OAuth provider IDs with signed-in states only.

**Out**

- Loading bundled extensions from the app bundle (EX-3), the other half of FR-EX29.

## Acceptance criteria

- [ ] **Given** the uninstall plan, **when** I read it, **then** it lists `Extensions/`, `ExtensionData/`, `extensions.json` and the `Trellis Extension` Keychain service.
- [ ] **Given** extensions with storage, settings, secrets and tokens, **when** I export diagnostics, **then** it holds names, versions, states, last errors and provider sign-in states, and no storage, settings values, secrets or tokens.
- [ ] **Given** the uninstall allow-list, **when** it is checked, **then** nothing outside those paths and services is added.

## Implementation notes

- Changed in `TrellisRelease`: `UninstallPlanner` in `Sources/TrellisRelease/Release.swift` (`keychainServices`).
- Changed in `TrellisUI`: `Sources/TrellisUI/DiagnosticsExporter.swift`.

## Tests

- Additions to `Tests/TrellisReleaseTests/ReleaseTests.swift`: the uninstall plan.
- Additions to `Tests/TrellisUITests/DiagnosticsExportTests.swift`: extension entries and redaction.
- `ExtensionSecretsTests`: no secrets in diagnostics.
