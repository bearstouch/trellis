# EX-2: Manifest model and validator

Part of the [Extensions specification](SPEC.md#stories). **Epic:** 1, Foundations · **Phase:** 2 · **Requirements:** FR-EX28 · **Depends on:** [EX-1](EX-01-contract-docs.md) · **Points:** 3

**Definition.** As an extension author, I want Trellis to validate my `package.json` and report every problem at once, so that I can fix a broken manifest without guessing.

An extension is a folder with a `package.json` that carries a `trellis` key and one JavaScript entry file. Validation follows `AgentDefinitionValidator`: a 64 KB cap on `package.json`, a header-version decode first, every problem collected as an issue, and every reference resolved.

## Scope

**In**

- `ExtensionManifest` types for every field in the Fields table: `name`, `version`, `engines.trellis`, `displayName`, `description`, `icon`, `main`, `permissions`, `network`, `events`, `oauth`, and `contributes` (`sidebar`, `tabs`, `modals`, `commands`, `keybindings`, `settings`).
- The validator with each field rule and limit, including: the name pattern and that it equals the folder name; the reserved `trellis-` prefix; semver `version` and `engines.trellis` ranges; https origins with one leading `*.` wildcard and at most 16; unknown permission or event names failing the load; `main` as a relative `.js` path of at most 4 MB; modal sizes; `opens` and keybinding `command` references; chords that include ⌘; setting keys containing token, secret or password rejected.
- OAuth provider field rules (`id`, `flow`, `device`, `authorize`, `token`, `revoke`, `clientId` with no client-secret field, `scopes`), and that `oauth` needs `auth`.
- `dist/package.json` resolution, with paths resolved inside `dist/`. Paths never leave the extension root.
- An unmet `engines.trellis` range reported as a suspension reason that names the needed version.

**Out**

- Discovering folders and keeping issues per folder (EX-3).
- Checking that each `view` is defined by `main.js`. That needs the host (EX-6) and is reported at load time.
- Icon rendering (EX-23); this story only checks the icon field and the SVG size.

## Acceptance criteria

- [ ] **Given** the example fixture from EX-1, **when** it is validated, **then** it decodes with no issues.
- [ ] **Given** a manifest with several problems, **when** it is validated, **then** every problem is reported as a separate issue, not only the first.
- [ ] **Given** a `package.json` over 64 KB, **when** it is validated, **then** it fails before decoding with a size issue.
- [ ] **Given** an unknown permission or event name, **when** the manifest is validated, **then** the load fails and the issue names it.
- [ ] **Given** a command whose `opens` names an undeclared surface, or a keybinding whose `command` doesn't exist, **when** the manifest is validated, **then** each is reported.
- [ ] **Given** a keybinding `suggested` chord without ⌘, **when** the manifest is validated, **then** it is refused.
- [ ] **Given** a setting key containing `token`, `secret` or `password`, **when** the manifest is validated, **then** it is rejected.
- [ ] **Given** a `network` entry that isn't https or has more than one wildcard, or more than 16 origins, **when** the manifest is validated, **then** it is rejected.
- [ ] **Given** an `engines.trellis` range the running version doesn't satisfy, **when** the manifest is validated, **then** the result is a suspension that names the needed version.
- [ ] **Given** a folder with `dist/package.json`, **when** it is validated, **then** that file is read and `main` resolves inside `dist/`. **Given** a `main` path with `..` or an absolute path, **then** it is refused.
- [ ] **Given** a user folder named with the `trellis-` prefix, **when** it is validated, **then** it is refused as reserved.

## Implementation notes

- New in `TrellisCore`: `ExtensionManifest` (types and validator).
- Reuse the validation pattern of `AgentDefinitionValidator` in `Sources/TrellisCore/AgentDefinition.swift` (size cap, header decode, collected issues) and `AgentIcon` for the icon field.
- Inject the running Trellis version so `engines` checks are deterministic.

## Tests

- `ExtensionManifestTests`: fixture; field rules; unknown permission or event fails; references; `engines`; `dist/` resolution.
