# S026 declarative layout automation

Date: 2026-10-16. Implemented with independent review and fixes, and automated RPC tests through the real model, including fixture shell launches. A manual CLI demo is **pending** (the CLI is S027).

## Behavior

### Parsing and validation

**Parsing.** `LayoutJSON.parse` enforces the committed v1 schema strictly:

- `version: 1` and `windows` are required.
- Unknown fields are rejected at every level.
- Only `shell` (optional `directory`) and `host` (`hostId`) launches are accepted. Process launches and command fields are rejected as executable content.

**Validation.** `LayoutPlanner` adds service-level checks:

- Keys are unique across the document and must match the key pattern.
- Names and titles must be 1–200 characters.
- Split nesting is limited to 16, the document to 100 panes, and the workspace to 100 panes after applying.
- Ratios must be between 0.1 and 0.9.
- Host references must exist and be visible to the grant.
- Directories:
  - `~` is allowed only as the whole first segment and expands to the current user's home.
  - Other directories must be absolute.
  - Rejected: relative paths, `..`, `$`, backticks, `~user`, and control characters.
  - A missing directory is a warning; it is checked again at start time.

**`layout.validate`** returns errors and warnings without touching the workspace.

### Planning

**`layout.plan`** takes `namespace` and `document`. It never mutates and returns:

- `baseRevision`
- `applicable`
- errors, warnings, and conflicts
- the windows, tabs, and panes it would create or update
- visible unmanaged resources

Planning reconciles the document against the workspace snapshot using the namespace's key bindings:

- **Stable IDs:** bound keys keep their IDs, even when titles change, and a key can never change resource type.
- **Unmanaged resources:** windows and tabs the document omits remain in place and are reported as unmanaged. Managed tabs keep their positions in document order, and new ones are appended.
- **Conflicts:**
  - moving a pane between tabs or a tab between windows;
  - changing a live session's launch;
  - a managed tab that contains panes the document omits.
- **Changes that update the live layout:** ratios, order, names, and titles.
- **Window scope:** a window-scoped grant only sees bindings in its own windows, so planning cannot probe hidden resources.

### Applying

**`layout.apply`** requires the plan's `expectedRevision`.

- It re-plans and returns `CONFLICT` with details for a stale revision or any conflict, and `-32602` with issues for an invalid document.
- Applies run one at a time and never target windows or tabs that are closing.
- The commit is a single store command, `applyLayout(target:)`. The store re-checks that no window, tab, pane, or session is deleted or moved, that runtime ownership is unchanged, that live launches are untouched, and that new sessions are stopped. It then bumps the revisions of changed resources. Reapplying an identical document changes nothing.

**Bindings** are stored in `layout-bindings.json`, owner-only and written atomically. They are saved before the commit, restored if the store rejects it, and pruned to live resources on every save.

- An unreadable bindings file returns `INVALID_STATE` and is left untouched.
- A failed bindings write aborts the apply.

**`startNew`** requires `session.start`. It starts only the panes created by this apply, never existing stopped panes.

- Each launch is independent of the committed layout and reports its outcome per pane: `key`, `paneId`, `sessionId`, `state`, and `error` or `failureMessage`.
- A failed launch rolls back neither the layout nor processes that already started.

### Exporting

**`layout.export`** takes optional `windowIds` and returns visible windows with fresh keys.

- Launch directories require `session.execute`, and host references require host read access.
- Otherwise the document is marked `redacted: true, importable: false`.

## Tests

- **`testS026_UT01_exampleApplyTwiceIsStable`:** applies `docs/api/example-layout.json` with `startNew`.
  - All three fixture-shell panes run, and the mapping, split ratio, and pane titles are correct.
  - The second apply returns an identical mapping, 0 launches, and `changed: false`, with an identical snapshot and PIDs.
  - A directory-less shell pane also reapplies without conflict.
- **`testS026_UT02_schemaAndSemanticFailuresAreAtomic`:** 14 invalid documents are all rejected by both validate and apply, with no model or process effects:
  - duplicate keys
  - nesting depth 17
  - 101 panes
  - a relative path, `..`, `$HOME`, and `~root`
  - an unknown host
  - a process launch and a command field
  - a bad ratio and a bad key
  - version 2 and an extra field

  It also checks that a missing directory produces a warning, that control characters are rejected, and that a corrupt bindings file is preserved and reported.
- **`testS026_UT03_stalePlanAndLiveChangesConflict`:**
  - A race after planning returns `CONFLICT` with no effect.
  - Changing a running pane's directory gives a plan conflict and an apply `CONFLICT`, with an identical snapshot.
  - Moving a pane to another tab is not applicable.
  - A split key reused in a new tab gets a fresh ID.
  - A window-scoped plan cannot see hidden bindings.
- **`testS026_UT04_partialLaunchFailureIsReported`:**
  - Two new panes with `startNew` yield one running and one failed launch, and the committed layout stays valid.
  - An omitted window is reported as unmanaged.
  - An export validates as a layout.

Full suite: **272 tests passed, 0 failures**. Lint is clean, the build has zero warnings, and the app packages and verifies.

## Independent review

The review fixed six issues:

1. A running directory-less shell pane falsely conflicted on reapply.
2. A split key reused in a new tab duplicated an ID, so the store rejected an "applicable" plan.
3. A corrupt bindings file was silently overwritten, which would duplicate managed resources.
4. Bindings were saved after the commit with `try?`. They are now saved before the commit, with rollback and pruning, and applies are serialized.
5. Window-scoped plans could probe hidden resources through bindings.
6. Path checks allowed most control characters.

It also fixed a UT01 race, reported start errors per pane, and made planning faster.

I added the closing-window guard.

Follow-ups, not applied:

- A managed tab with manual extra panes, or a pane key removed from the document, always conflicts.
- Plan summaries do not list splits.
- Exports without `session.execute` mark directory-less shells as redacted.
- Shell matching ignores the executable path.
- Names are not trimmed.

## Pending manual verification

Not performed, and **not** marked passed:

- Apply the example layout through the CLI (S027) against the live app twice, and observe stable IDs and no duplicate processes.

> **Update (S027):** the live CLI demo applied `example-layout.json` twice to an isolated app instance. Both applies returned identical mapping IDs with 0 launches, and the second returned `changed: false`. See the [S027 evidence](S027-cli.md).
