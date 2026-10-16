# S002 workspace model evidence

Date: 2026-10-16. Scope: authoritative in-memory workspace domain and command boundary; native controls and the RPC transport are later stories.

## Implementation

- [Workspace models](../../Sources/UTermCore/Workspace.swift): ordered windows/tabs, binary split layouts, active selection, panes, sessions, launch descriptors, stable UUIDs, lifecycle state, and revisions.
- [Store and service](../../Sources/UTermCore/WorkspaceStore.swift): actor-serialized copy/validate/commit mutations shared by future UI/API callers. Initial snapshots are validated before acceptance. Snapshot copies are values and cannot mutate the store externally.
- Existing windows require tabs; tabs require panes; split branches require exactly two children and finite valid ratios. References, ownership, selection, and resource IDs are checked globally; orphan resources are rejected. Empty application state is valid.
- Launch requests are returned as effects after committing a starting session. No domain command starts a process. An external runner returns a matching attempt/outcome; a failed effect leaves a valid failed session in the same pane. Stale/duplicate attempt completions cannot overwrite it.
- Runtime session state deliberately is not Codable: the safe stopped-restoration format belongs to S010 and must omit process handles, transient state, and secrets.

## Automated checks

[WorkspaceStoreTests](../../Tests/UTermCoreTests/WorkspaceStoreTests.swift) implements the four planned S002 unit cases and additional regression/contract checks:

1. Dangling pane references reject atomically.
2. Split branches with zero, one, or three children reject atomically.
3. Stale expectedRevision commands conflict without overwriting state.
4. Injected launch failure preserves a valid pane/session hierarchy.
5. Concurrent actor mutations preserve every committed update.
6. Initial orphan resources and invalid selection are rejected.
7. A duplicate UUID generator cannot corrupt state.
8. Stale/duplicate launch completions cannot alter running state.
9. Snapshot copies are isolated and no-op renames do not advance revisions.
10. Equivalent commands through two service facades produce equivalent domain state from the same initial snapshot.

The facade test demonstrates the shared domain boundary; actual native UI and RPC integration are not claimed to exist yet. Additional reviewed tests cover a valid multi-tab/binary split snapshot, invalid ownership/shared sessions, competing expected revisions, and duplicate live PID rejection.

## Independent review

A separate S002 review agent inspected the model, store, tests, and story requirements after implementation. It confirmed the copy/validate/commit ordering and requested stronger positive-tree/concurrent-revision coverage. It also found that two live session records could claim one PID. The fix rejects duplicate live process ownership during validation, with a regression proving a rejected launch completion leaves the second session starting and the committed snapshot unchanged.

## Verification result

**Passed:** 30 tests total, including 14 workspace-model tests, with 0 failures and no Swift 6 build warnings. Independent review findings have been fixed and reviewed. The four S002 acceptance criteria are complete. The implementation does not depend on S001’s unperformed spoken VoiceOver/physical IME checks and does not enable terminal-dependent stories past that gate.

## Reproduce

```sh
swift test
```

The model tests use fixtures and fake process outcomes; they never launch or signal a user's process. The complete package suite also includes S001's isolated real PTY fixtures.
