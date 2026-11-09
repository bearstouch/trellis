# EX-12: Trellis state snapshot and watch

Part of the [Extensions specification](SPEC.md#stories). **Epic:** 3, Tier 0 · **Phase:** 3b · **Requirements:** FR-EX10 · **Depends on:** [EX-7](EX-07-extension-supervisor.md), [EX-8](EX-08-grant-resolving.md) · **Points:** 5

**Definition.** As an extension author, I want a read-only snapshot of Trellis state that I can watch for changes, so that my extension can follow spaces, tabs, panes, agents and the focused repository without polling.

`trellis.state.get()` returns a snapshot and `trellis.state.watch(selector, fn)` calls `fn` when the selected part changes, at most 10 times a second. Both come from the same `WorkspaceStore` snapshots the automation API uses, filtered by the extension's grant with the API's redaction rules. IDs are the control API's stable UUIDs.

## Scope

**In**

- `ExtensionStateProjector` producing the State table: `focus`, `spaces[]`, `spaces[].tabs[]`, `…panes[]`, `…panes[].cwd`, `repository`, `hosts[]`, `appearance`, `tasks[]`, each gated by its permission. `focus.machine` is always present.
- `repository` for the focused local pane: root, branch, head, ahead, behind, changed and remotes (`name`, `url`, `host`, `owner`, `repo`), or `null`. Local panes only in v1.
- `tasks[]`: a small projection of running task runs from the UI model.
- `watch` coalescing: fires within 100 ms of a change, at most 10 times a second.
- Confirm whether Trellis already reads remotes. If not, the Changes reader gains one `git remote -v` call per repository, cached until `repository.changed`.

**Out**

- Extension tabs in `spaces[].tabs[]` with `kind: "extension"` (EX-25 adds them).
- Events (EX-13).

## Acceptance criteria

- [ ] **Given** an extension with only `metadata.read`, **when** it calls `state.get()`, **then** it gets `focus`, `spaces`, tabs, panes and `tasks`, but no `cwd`, `repository`, `hosts` or `appearance`.
- [ ] **Given** `git.read`, **when** a local pane in a git repository is focused, **then** `repository` has root, branch, head, ahead, behind, changed and remotes. **Given** a remote or SSH pane, **then** it is `null`.
- [ ] **Given** an extension without `session.execute`, **when** it reads panes, **then** `cwd` is absent.
- [ ] **Given** IDs in the snapshot, **when** the extension passes them to `trellis.call`, **then** they resolve to the same spaces, tabs and panes.
- [ ] **Given** a watch on `spaces`, **when** a tab is created, **then** `fn` fires within 100 ms.
- [ ] **Given** 50 changes in one second, **when** watched, **then** `fn` fires at most 10 times with the latest state.
- [ ] **Given** the snapshot, **when** the extension changes it, **then** Trellis state is unaffected.

## Implementation notes

- New in `TrellisUI`: `ExtensionStateProjector`.
- Sources: `WorkspaceStore` (`Sources/TrellisCore/WorkspaceStore.swift`), agent state (`Sources/TrellisCore/AgentState.swift`), task runs (`Sources/TrellisCore/TaskRun.swift`, `Sources/TrellisUI/AppWorkspaceModel+Tasks.swift`), git status (`Sources/TrellisCore/GitRepository.swift`, `Sources/TrellisUI/AppWorkspaceModel+GitStatus.swift`).
- Reuse the API's redaction rules (see `Sources/TrellisUI/AutomationService.swift` and the capability table in `Sources/TrellisControl/Authorization.swift`) so extensions and API clients see the same filtering.
- Inject the clock for coalescing.

## Tests

- `ExtensionStateTests`: redaction per permission; watch coalescing; IDs match the control API.
