# EX-7: Extension supervisor: lazy start, idle stop, watchdog, backpressure, packaging

Part of the [Extensions specification](SPEC.md#stories). **Epic:** 2, Host and authority · **Phase:** 3a · **Requirements:** FR-EX05, FR-EX28 · **Depends on:** [EX-4](EX-04-extension-registry.md), [EX-6](EX-06-extension-host.md) · **Points:** 5

**Definition.** As a Trellis user, I want extension processes to start only when needed, stop when idle and be restarted or disabled when they misbehave, so that extensions cost little and never hang Trellis.

`ExtensionSupervisor` owns each helper's lifecycle. It starts the helper lazily, keeps it alive while it has work, watches its memory and heartbeat, and never blocks on it.

## Scope

**In**

- Lazy start on the first event, command or view that needs the extension, through `trellis_spawn_link` with an empty environment, no inherited descriptors except one end of a socketpair, the working directory set to the extension's data folder, and the bundle path and approved manifest on argv.
- Keep running while the extension has a shown view, an event subscription, a timer or a pending call. Stop after 60 s idle; start again on demand. Stop when the extension is disabled, reloaded or suspended, and when Trellis quits.
- The watchdog table: over 256 MB physical footprint (read with `proc_pid_rusage`) → terminate, log `MEMORY_LIMIT`, restart; no heartbeat reply within 5 s → terminate as hung, restart; a render or event handler over 2 s → warning naming the view or event; 3 crashes or kills within 60 s → disable with a notice and the last error.
- A native "Restarting…" placeholder while the helper restarts; views re-render from scratch afterwards.
- Event backpressure: a queue of at most 1 MiB per helper. On overflow, queued events are dropped and the extension gets `events.gap`. Trellis never blocks on a helper.
- Packaging: copy and sign `trellis-extension-host` in `scripts/run-feasibility.sh`, both packaging scripts and `release/manifest.json`, and the release manifest checks for the new helper.

**Out**

- Reload with a second process (EX-11).
- The renderer's placeholder view itself (EX-20); this story provides the state it shows.

## Acceptance criteria

- [ ] **Given** an enabled extension with no shown view, subscription, timer or pending call, **when** Trellis starts, **then** no helper process is running for it.
- [ ] **Given** a command of that extension runs, **when** it is invoked, **then** the helper starts and handles it.
- [ ] **Given** a helper idle for 60 s (injected clock), **when** the time passes, **then** it is stopped, and the next event starts it again.
- [ ] **Given** a helper over 256 MB, **when** the watchdog samples it, **then** it is terminated, `MEMORY_LIMIT` is logged and it restarts.
- [ ] **Given** a helper that doesn't answer a heartbeat within 5 s, **when** the watchdog checks, **then** it is terminated and restarted.
- [ ] **Given** 3 crashes or kills within 60 s, **when** the third happens, **then** the extension is disabled and a notice shows the last error.
- [ ] **Given** a handler that takes over 2 s, **when** it returns, **then** a warning naming the view or event is logged.
- [ ] **Given** a helper that stops reading, **when** queued events exceed 1 MiB, **then** they are dropped, the extension later gets `events.gap`, and the main thread is never blocked.
- [ ] **Given** the extension is disabled or Trellis quits, **when** that happens, **then** its helper is stopped and no orphan process remains.
- [ ] **Given** `scripts/run-feasibility.sh --build-only`, **when** it runs, **then** the app contains a signed `trellis-extension-host` and the release manifest checks pass.
- [ ] **(manual)** **Given** 15 active extensions, **when** memory is measured, **then** the total is recorded against the 256 MB per-helper ceiling. Stays **pending** until measured.

## Implementation notes

- New in `TrellisUI`: `ExtensionSupervisor`.
- Changed: `Package.swift`, `scripts/run-feasibility.sh`, `scripts/package-release.sh`, `scripts/package-thin-release.sh`, `release/manifest.json`, and the release manifest checks in `Sources/TrellisRelease/Release.swift`.
- Never signal a reused PID: follow the process-group and PID checks in `Sources/TrellisCore/SessionClosure.swift`.
- Inject the clock, the spawner and the memory sampler.

## Tests

- `ExtensionHostTests`: heartbeat and memory kill; restart and disable after 3 failures (injected clock); idle stop and lazy restart; queue overflow yields `events.gap`.
- Additions to `Tests/TrellisReleaseTests/ReleaseTests.swift` for the new helper.
