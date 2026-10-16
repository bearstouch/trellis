# S023 automation resource commands

Date: 2026-10-16. Implemented with independent review and fixes, and automated RPC tests against the real workspace model. Racing-client and socket-level manual checks are **pending**.

## Behavior

**Methods.** `AutomationService` (TrellisUI) is the app's `ControlDomain`. It implements:

- `system.info`, which reports the instance ID shared with discovery, capabilities, and limits
- `window.list/get/create/update/reorder/focus/close`
- `tab.list/get/create/update/reorder/focus/close`, where `get` and `create` include the split tree
- `pane.split/resize/focus/maximize/close`
- `session.get`
- `host.list/get/create/update/delete`

Session control and `host.connect` are S024; layouts, events, and themes are later stories.

**Shared path.** Every mutation goes through `AppWorkspaceModel.automationExecute`, which uses the same `WorkspaceCommandService` and tree and lifecycle rules as the UI.

- Terminals are attached from the published snapshot, so API-created panes appear in the UI.
- Creation is refused inside a window, tab, or pane that is closing.
- Automation never presents an alert or confirmation. `start(quietly:)` reports a failure through the session state instead.

**Atomic follow-ups.** Two operations run a second command atomically through `WorkspaceStore.execute(_:expecting:then:)`, which restores the saved state if the follow-up fails, so no partial tree or tab is left behind:

- `tab.create` with a title
- `pane.split` with a ratio

The existing pane is the first child of a split, and a split is refused while its tab is maximized. Panes are stopped unless `start: true` is sent, which policy allows only with `session.start`.

**Revisions.** `expectedRevision` maps to a `ResourceExpectation`:

| Method | Revision checked |
| --- | --- |
| `window.update` and `window.close` | the window's revision |
| `tab.update`, `tab.close`, and `pane.resize` | the tab's revision |
| `tab.reorder` | the owning window's revision |
| `window.reorder` | the workspace revision |

- The check runs atomically inside the store. A conflict returns `CONFLICT` with the expected and current revisions, and changes nothing.
- A malformed revision returns `-32602`.
- Omitting the revision targets the latest state.
- Results report the resource's own revision. `window.create` also returns `tabRevision` and `workspaceRevision`.

**Closing.** `automationClose` mirrors the UI ordering: closing gates, settling pending launches, recomputing the affected panes, and verifying the revision **before** any signal.

- Running sessions without `allowRunning` return `CONFIRMATION_REQUIRED` with the affected session IDs.
- Sessions that have not finished closing return a retryable `CLOSE_PENDING`. Force is honored only after the graceful two-second window.
- Policy requires `session.close` for `allowRunning` and `force`.

**Redaction.** Listings include only resources in the grant's scope.

- `session.get` reports the state and exit code. Executable, arguments, and directory appear only with `session.execute`.
- A host reference appears only with `host.read` and access to that host.
- Host validation errors return per-field details.

**Idempotency.** Mutating calls may carry an `idempotencyKey` of 1–128 bytes, cached per grant and per app instance for 10 minutes.

- The same method and params replay the first result.
- The same key with different params returns `CONFLICT`. A duplicate that is still running returns a retryable `CONFLICT`.
- Retryable failures release the key so the documented retry can run.
- Each grant is limited to 1,000 keys; beyond that the call returns `LIMIT_EXCEEDED`.
- Nothing persists across relaunch.

## Tests

- `testS023_UT01_apiCreatesStoppedHierarchy`: `window.create`, `tab.create` with a title, and `pane.split` with ratio 0.3. Relationships, branch IDs, child order, and the ratio are correct. All sessions are stopped with no processes, UI terminals exist, and the snapshot is valid.
- `testS023_UT02_staleMutationHasNoEffects`: stale window, tab, and workspace revisions return `CONFLICT` with an identical snapshot. The latest-state mutation succeeds.
- `testS023_UT03_idempotencyKeyScopeAndExpiry`: a replay executes once. A different payload conflicts. Another grant has its own key space. The key is forgotten after 601 s on a fake clock and on a new instance. An oversized key is rejected.
- `testS023_UT04_apiUiDomainEquivalence`: equivalent UI and API sequences produce identical normalized structure, including names, order, tree, ratios, selection, and states.
- Additional tests:
  - Closing a live `/bin/sleep` returns `CONFIRMATION_REQUIRED`. With only a layout grant it returns `PERMISSION_DENIED`. A stale close returns `CONFLICT`. In all three cases the process keeps running.
  - Launch details are redacted without execute.
  - `allowRunning` closes the process without any dialog; the test fails if one is shown.
  - Window-scoped listings and `NOT_FOUND` for out-of-scope windows.
  - Host field validation, stale host revisions, and deletion.
  - Review tests:
    - failed follow-ups and invalid revisions leave no effects
    - idempotency releases retryable failures and bounds keys per grant

Full suite: **251 tests passed, 0 failures**. Lint is clean, the build has zero warnings, and the app packages and verifies.

## Independent review

The review fixed eight issues:

1. `tab.create` with a title and `pane.split` with a ratio were non-atomic and could leave partial state.
2. A stale close signalled processes before reporting `CONFLICT`.
3. `automationClose` skipped the UI's gates and settle ordering.
4. Creation ignored closing gates, and terminals could be re-attached from out-of-order results.
5. `start: true` could raise a UI alert.
6. Malformed `expectedRevision` values were silently ignored.
7. Returned revisions were inconsistent across methods.
8. API maximize could hide the focused pane.

It also fixed two idempotency-cache flaws: retryable failures stayed cached, and the memory bound was global. I added the maximized-split refusal.

Follow-ups, not applied:

- Host methods read the main-actor host mirror, so a stale mirror can return a spurious conflict.
- An API split ratio is checked against a default 4096×4096 canvas for never-displayed tabs.
- When the UI and API create panes at the same moment, a terminal can be attached twice and left unused.
- Document that `CONFIRMATION_REQUIRED` is cached under its key, so a retry with `allowRunning: true` needs a new key.

## Pending manual verification

These checks were not performed and are **not** marked passed:

- Run real socket clients that race revisions.
- Disconnect a client after a mutation.
- Close live containers without authorization.
- Inspect redacted metadata in the running app.
