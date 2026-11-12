# EX-30: trellis extension check, list and reload

Part of the [Extensions specification](SPEC.md#stories). **Epic:** 7, CLI and first-party extension · **Phase:** 7 · **Requirements:** FR-EX25 · **Depends on:** [EX-6](EX-06-extension-host.md), [EX-11](EX-11-hot-reload.md) · **Points:** 5

**Definition.** As an extension author, I want to check my extension offline and list or reload extensions from the terminal, so that I can iterate without opening Settings.

`trellis extension check <dir>` validates the manifest, loads `main.js` in a throwaway host and renders each declared view once, with no socket needed. `list` and `reload` go through new control-API methods with stated grants. Enabling, approving and installing can't be done from the CLI.

## Scope

**In**

- `trellis extension check <dir>`: offline, validates the manifest, loads `main.js` in a throwaway host, renders each declared view once with empty state, prints every issue, exits 0 when valid and non-zero otherwise.
- `trellis extension list` through a new read-only `extension.list` method (`workspace.read`).
- `trellis extension reload <name>` through `extension.reload` (all-spaces scope and `workspace.write`), taking the same path as Reload in Settings (EX-11).
- CLI help and `docs/api/cli.md`, `docs/api/methods.md` updates.

**Out**

- Any enable, approve or install command.

## Acceptance criteria

- [ ] **Given** a valid extension folder, **when** I run `trellis extension check <dir>` with Trellis not running, **then** it prints no issues and exits 0.
- [ ] **Given** an invalid manifest, **when** I run `check`, **then** it prints the same issues Settings shows and exits non-zero.
- [ ] **Given** a view whose render throws, **when** I run `check`, **then** the render error is printed and it exits non-zero.
- [ ] **Given** a grant with `workspace.read`, **when** I run `trellis extension list`, **then** it lists installed extensions and their states.
- [ ] **Given** a grant without all-spaces scope or `workspace.write`, **when** I run `trellis extension reload <name>`, **then** it is refused. **Given** both, **then** the extension reloads as from Settings.
- [ ] **Given** the CLI, **when** I look for a way to enable, approve or install an extension, **then** there is none.

## Implementation notes

- Changed in `TrellisCLI`: `Sources/TrellisCLI/CLICommands.swift`, `Sources/TrellisCLI/CLIHelp.swift`.
- Changed in `TrellisControl`: `extension.list` and `extension.reload` methods behind `AuthorizingControlHandler`.
- `check` runs `trellis-extension-host` (EX-6) directly, without the control socket.
- No token argv and no retries, as for every CLI command.

## Tests

- Additions to `TrellisCLITests` (`Tests/TrellisCLITests/CLITests.swift`): `extension check`, `list`, `reload`.
- `ExtensionAuthorizationTests`: grants for `extension.list` and `extension.reload`.
