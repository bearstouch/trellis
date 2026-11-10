# EX-5: File watcher

Part of the [Extensions specification](SPEC.md#stories). **Epic:** 1, Foundations · **Phase:** 2 · **Requirements:** FR-EX01, FR-EX03 · **Depends on:** [EX-3](EX-03-extension-catalog.md) · **Points:** 2

**Definition.** As an extension author, I want Trellis to notice when I add or change extension files, so that new extensions appear and edits reload without restarting Trellis.

`ExtensionWatcher` watches `Extensions/` with FSEvents, debounced to 300 ms. Its clock and file system are injected so tests are deterministic. It only reports changes; what a change means (reload, suspend, rescan) is decided by the catalog, the registry and the supervisor.

## Scope

**In**

- `ExtensionWatcher` over `<state-dir>/Extensions/`, debounced to 300 ms.
- Report added, changed and removed extension folders to the catalog (EX-3).
- An injected clock and event source.

**Out**

- Reloading the host process (EX-11).
- Suspending a pinned extension on change (EX-4 decides; this story only delivers the change).

## Acceptance criteria

- [ ] **Given** a valid folder dropped into `Extensions/`, **when** the watcher fires, **then** it shows in Settings as Disabled within 1 s.
- [ ] **Given** several writes to one extension within 300 ms, **when** the watcher fires, **then** the catalog gets a single change for that extension.
- [ ] **Given** an extension folder is deleted, **when** the watcher fires, **then** the catalog reports it removed.
- [ ] **Given** the injected clock, **when** tests advance it past the debounce, **then** the change is delivered with no real waiting.

## Implementation notes

- New in `TrellisCore`: `ExtensionWatcher`.
- Wire it in `Sources/TrellisApp/AppMain.swift` alongside the registry and supervisor (EX-7, EX-10).
- Follow the injected time pattern of `SessionClosureCoordinator(now:sleep:)` in `Sources/TrellisCore/SessionClosure.swift`.

## Tests

- `ExtensionCatalogTests`: watcher-driven rescans with an injected clock and event source.
