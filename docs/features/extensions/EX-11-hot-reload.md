# EX-11: Hot reload with a second process and a last-good copy

Part of the [Extensions specification](SPEC.md#stories). **Epic:** 2, Host and authority · **Phase:** 3a · **Requirements:** FR-EX03 · **Depends on:** [EX-5](EX-05-file-watcher.md), [EX-7](EX-07-extension-supervisor.md), [EX-10](EX-10-settings-extensions.md) · **Points:** 3

**Definition.** As an extension author, I want saving my code to reload the extension without ever leaving it broken, so that I can iterate quickly and a bad save doesn't take my tools away.

Hot reload applies only in Development mode. Trellis re-validates the manifest, then starts a second host process with the new files while the old one keeps running, and switches only if the new one loads. Each successful load is copied to a last-good folder so a broken state after relaunch still runs.

## Scope

**In**

- On a watcher change in Development mode: re-validate, start a second helper, switch if it loads `main.js` and defines its views within 5 s, then stop the old one.
- On switch: open views re-render from `init`; open tabs keep their `props`; the sidebar keeps its width and shown view.
- On failure (invalid manifest or `main.js` throws): discard the new helper, keep the old one running, show the issue in Settings and as a banner on the extension's views.
- Copy the manifest and `main.js` to `ExtensionData/<name>/last-good/` after each successful load. At launch, if the files on disk fail, run that copy and show the same banner. A pinned extension's copy must match its approved hash.
- A change that asks for more permissions suspends the extension in either mode.
- Reload in Settings and `trellis extension reload <name>` take the same path.

**Out**

- The CLI command itself (EX-30).
- Suspending a pinned extension on change (EX-4).

## Acceptance criteria

- [ ] **Given** Development mode, **when** I save `main.js`, **then** the extension reloads and its views re-render within 1 s.
- [ ] **Given** a save that makes `package.json` invalid or `main.js` throw, **when** the reload runs, **then** the previous process keeps running and the issue shows in Settings and as a banner.
- [ ] **Given** a broken extension folder at launch, **when** Trellis starts, **then** the last good copy runs and the banner shows.
- [ ] **Given** a pinned extension whose last-good copy doesn't match its approved hash, **when** Trellis starts, **then** that copy is not run.
- [ ] **Given** an open tab with `props` and a shown sidebar view, **when** a reload switches processes, **then** the tab keeps its `props` and the sidebar keeps its width and shown view.
- [ ] **Given** a save that asks for an extra permission, **when** the reload runs, **then** the extension is suspended until approved, in Development mode too.
- [ ] **Given** a new helper that doesn't define its views within 5 s, **when** the time passes, **then** it is discarded and the old one keeps running.

## Implementation notes

- Changed: `ExtensionSupervisor` (EX-7), `ExtensionCatalog` (last good version, EX-3).
- Uses `ExtensionWatcher` (EX-5) as the trigger.
- Inject the clock for the 5 s switch deadline.

## Tests

- `ExtensionCatalogTests`: last good version.
- `ExtensionHostTests`: second process switch; old process kept on failure.
