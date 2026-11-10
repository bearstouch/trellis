# EX-3: Extension catalog: discovery, issues, bundled extensions

Part of the [Extensions specification](SPEC.md#stories). **Epic:** 1, Foundations · **Phase:** 2 · **Requirements:** FR-EX01, FR-EX29 · **Depends on:** [EX-2](EX-02-manifest-validator.md) · **Points:** 3

**Definition.** As a Trellis user, I want extension folders I drop into `Extensions/` to show up in Trellis, with any problems explained, so that I can see what is installed and why something doesn't load.

The catalog finds extension folders, validates each one and keeps its issues. An invalid folder never hides valid ones. Bundled extensions, with the reserved `trellis-` prefix, load from the app bundle instead of the state directory.

## Scope

**In**

- `ExtensionCatalog`: scan `<state-dir>/Extensions/<name>/`, validate each folder with EX-2, keep issues per folder.
- Load bundled extensions from the app bundle's `Extensions/` resource folder. They are read-only and the `trellis-` prefix is accepted only there.
- The five lifecycle states as a model: Disabled, Enabled, Suspended, Invalid, Removed. A newly found valid folder is Disabled.
- Track the last good version of each extension for EX-11.
- Symlinks that point outside the extension root are refused.
- `--state-directory` and `--fixture` each get their own isolated `Extensions/` folder.

**Out**

- Watching for changes (EX-5). The catalog exposes a rescan that the watcher calls.
- Approvals and enabled flags (EX-4).
- Install from Folder… and its UI (EX-10).
- Pinning bundled extensions by the app's code signature (EX-4).

## Acceptance criteria

- [ ] **Given** a valid folder in `Extensions/`, **when** the catalog scans, **then** it is listed as Disabled.
- [ ] **Given** one invalid and one valid folder, **when** the catalog scans, **then** the valid one is listed and the invalid one is Invalid with its issues.
- [ ] **Given** a folder whose name doesn't match `name` in its manifest, **when** the catalog scans, **then** it is Invalid with that issue.
- [ ] **Given** a user folder named `trellis-something`, **when** the catalog scans, **then** it is refused as reserved.
- [ ] **Given** a bundled extension in the app bundle, **when** the catalog scans, **then** it is listed as Disabled and read-only, loaded from the bundle and not from the state directory.
- [ ] **Given** a symlink inside an extension folder that points outside it, **when** the catalog loads that extension, **then** the link is refused and reported.
- [ ] **Given** `--state-directory /abs/path` or `--fixture`, **when** Trellis starts, **then** it uses an `Extensions/` folder isolated to that run.

## Implementation notes

- New in `TrellisCore`: `ExtensionCatalog`.
- Reuse the `AgentCatalog` pattern in `Sources/TrellisCore/AgentDefinition.swift`, including how bundled agent definitions load from `Sources/TrellisCore/Resources/Agents/`.
- A new resource folder for bundled extensions must be copied into the app by `scripts/run-feasibility.sh` and both packaging scripts (`scripts/package-release.sh`, `scripts/package-thin-release.sh`).
- Inject the file system so tests don't touch the real Application Support folder.

## Tests

- `ExtensionCatalogTests`: issues per folder; last good version; reserved prefix; symlinks; starts disabled.
