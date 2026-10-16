# Delivery history

Trellis's MVP was delivered as 32 P0 stories (S001–S032), implemented in order, each reviewed independently and committed as `feat(SNNN): …`. This page keeps each story's acceptance criteria and its four named unit tests, because test names (`testSNNN_UTnn_…`) and the [evidence records](../evidence/S001-terminal-feasibility.md) refer to them. The story files themselves no longer exist; the behavior they describe is documented in the rest of this site.

Acceptance checkboxes are ticked only where the behavior was actually observed. Unticked items with a pending note are open qualification work, not failures. See [Status and known limits](../overview/status.md) for the current summary.

## Phase 1 — Foundation and terminal feasibility

| Story | Status | Requirements |
| --- | --- | --- |
| [S001 — Validate the native terminal engine](#s001) | Implemented and reviewed — manual feasibility gate pending | `MAC-01`, `MAC-02`, `MAC-03`, `NFR-U02`, `FR-S02` |
| [S002 — Create the authoritative workspace model](#s002) | Done — reviewed; 14 workspace tests and full 30-test suite passing | `NFR-R03`, `API-03`, `FR-A02` |
| [S003 — Launch and operate local PTY sessions](#s003) | Done — reviewed and fixed; 43 tests passing | `FR-S01`, `FR-S03`, `FR-S05`, `INT-01`, `MAC-08`, `NFR-S08` |

## Phase 2 — Native organization and session safety

| Story | Status | Requirements |
| --- | --- | --- |
| [S004 — Build the Native calm application shell](#s004) | Implemented and independently reviewed — native lifecycle/display qualification pending | `MAC-03`, `MAC-04`, `MAC-05`, `MAC-06`, `FR-W04` |
| [S005 — Manage windows from the sidebar](#s005) | Implemented with independent review fixes — 64-test suite passing; native interaction qualification pending | `FR-W01`, `FR-W02`, `FR-W03`, `FR-W04` |
| [S006 — Manage multiple renameable tabs per window](#s006) | Implemented and independently reviewed — 72-test suite and native tab checks passing | `FR-T01`, `FR-T02`, `FR-T03`, `FR-W03` |
| [S007 — Create and close nested terminal splits](#s007) | Implemented and independently reviewed — 81-test suite and native split checks passing | `FR-P01`, `FR-P03`, `FR-T03` |
| [S008 — Resize, focus, and maximize panes](#s008) | Implemented and independently reviewed — 89 tests and native interaction checks pass | `FR-P02`, `FR-P04`, `MAC-06`, `NFR-U01` |
| [S009 — Close and restart sessions safely](#s009) | Implemented and independently reviewed — 98 tests and native close/restart checks pass | `FR-S03`, `FR-T03`, `MAC-04`, `NFR-R01` |
| [S010 — Persist workspaces and restore stopped sessions](#s010) | Implemented and reviewed — 110 tests pass; native restore/recovery verified | `FR-R01`, `NFR-R02`, `NFR-R05`, `MAC-11` |

## Phase 3 — Everyday terminal use

| Story | Status | Requirements |
| --- | --- | --- |
| [S011 — Select and copy terminal text naturally](#s011) | Implemented and reviewed — 117 tests and native copy checks pass; delayed independent review completed during S012 | `FR-C01`, `FR-C02`, `INT-08`, `MAC-07` |
| [S012 — Paste text and file paths safely](#s012) | Implemented and reviewed — 126 tests pass; native two-pane paste and escaped-path checks verified | `FR-C03`, `FR-C04`, `FR-C05`, `INT-08` |
| [S013 — Retain bounded output and search a pane](#s013) | Implemented and reviewed — 138 tests pass; native long-output, alternate-screen, and search-focus checks verified | `FR-S04`, `NFR-P05`, `NFR-R06` |
| [S014 — Apply light chrome and dark Monaco terminals](#s014) | Implemented — reviewed fixes, automated regressions, and native appearance checks pass | `FR-U02`, `FR-TH01`, `FR-TH05`, `FR-TH06`, `MAC-07` |
| [S015 — Define and validate simple JSON themes](#s015) | Implemented — independently reviewed, 171 tests and native preview checks pass | `FR-TH02`, `FR-TH04`, `FR-TH06`, `FR-TH07`, `INT-10` |
| [S016 — Import, preview, and maintain custom themes](#s016) | Implemented — independently reviewed, 184 tests and native library checks pass | `FR-TH03`, `FR-TH04`, `FR-TH05`, `INT-10` |
| [S017 — Support keyboard navigation and native accessibility](#s017) | Implemented — independently reviewed, 201 tests pass; VoiceOver/IME/layout manual checks pending | `FR-U01`, `NFR-U01`, `NFR-U02`, `NFR-U03`, `NFR-U04`, `MAC-07` |
| [S018 — Maintain a searchable saved-host library](#s018) | Implemented — independently reviewed, 211 tests pass; native persistence/search demo pending | `FR-H01`, `INT-03`, `NFR-S03`, `MAC-12` |
| [S019 — Discover SSH aliases without changing SSH configuration](#s019) | Implemented — independently reviewed, 220 tests pass; native fixture demo pending | `FR-H03`, `INT-04` |
| [S020 — Open SSH sessions in tabs or splits](#s020) | Implemented — independently reviewed, 226 tests pass; real SSH server checks pending | `FR-H02`, `FR-H04`, `FR-H05`, `INT-03`, `INT-05`, `NFR-S04` |

## Phase 4 — Scripts and agents

| Story | Status | Requirements |
| --- | --- | --- |
| [S021 — Expose a bounded local JSON-RPC control socket](#s021) | Implemented — independently reviewed, 235 tests and native socket checks pass | `API-01`, `API-06`, `NFR-S01`, `NFR-R04` |
| [S022 — Authorize scoped script and agent access](#s022) | Implemented — independently reviewed, 243 tests pass; Keychain/native grant checks pending | `API-02`, `FR-A03`, `NFR-S01`, `NFR-S02`, `NFR-S06`, `NFR-S08` |
| [S023 — Expose resource commands with revisions and idempotency](#s023) | Implemented — independently reviewed, 251 tests pass; live socket client checks pending | `FR-A01`, `FR-A02`, `API-03`, `API-04`, `API-06` |
| [S024 — Start sessions and submit authorized input](#s024) | Implemented — independently reviewed, 257 tests pass; live agent/SSH checks pending | `FR-A01`, `FR-A03`, `API-03`, `API-04`, `INT-06` |
| [S025 — Read bounded output and subscribe to events](#s025) | Implemented — independently reviewed, 268 tests pass; multi-client manual checks pending | `FR-A05`, `API-05`, `NFR-P05`, `NFR-S06` |
| [S026 — Validate, plan, and apply declarative layouts](#s026) | Implemented — independently reviewed; live CLI apply-twice demo performed in S027 | `FR-A04`, `API-03`, `API-04`, `NFR-S07` |
| [S027 — Ship a script-friendly trellis CLI](#s027) | Implemented — independently reviewed, 280 tests and a live CLI demo pass; Keychain/installed-CLI checks pending | `FR-A01`, `FR-A02`, `INT-06`, `API-06`, `MAC-10` |
| [S028 — Import and export layouts and saved hosts](#s028) | Implemented — independently reviewed, 284 tests pass; native export/import demo pending | `FR-R02`, `INT-09`, `NFR-S03`, `NFR-S07` |
| [S029 — Control themes and appearance from scripts](#s029) | Implemented — independently reviewed, 289 tests pass; installed-CLI live check pending | `FR-TH08`, `INT-10`, `API-03`, `API-04` |

## Phase 5 — Qualification and distribution

| Story | Status | Requirements |
| --- | --- | --- |
| [S030 — Protect terminal interactions and private diagnostics](#s030) | Implemented — independently reviewed (engine patch), 295 tests pass; native link/clipboard/diagnostics checks pending | `NFR-S03`, `NFR-S05`, `NFR-S08`, `NFR-S09`, `NFR-U05`, `INT-08` |
| [S031 — Qualify capacity, responsiveness, and lifecycle reliability](#s031) | Blocked — qualification run complete; NFR-P07 flood throughput misses (5–7.6 of 10 MiB/s); UI-frame latency not certified | `NFR-P01`, `NFR-P02`, `NFR-P03`, `NFR-P04`, `NFR-P05`, `NFR-P06`, `NFR-P07`, `NFR-R01`, `NFR-R04`, `NFR-R06` |
| [S032 — Package and qualify the macOS-only release](#s032) | Blocked for release — tooling, Universal 2 packaging, CLI link, docs, and release gate done (309 tests); Developer ID notarization/Gatekeeper and matrix pending | `MAC-01`, `MAC-02`, `MAC-03`, `MAC-08`, `MAC-09`, `MAC-10`, `MAC-11`, `MAC-12` |

## Stories

### S001 — Validate the native terminal engine {#s001}

- **Status:** Implemented and reviewed — manual feasibility gate pending
- **Phase:** 1 — Foundation and terminal feasibility
- **Depends on:** None
- **Requirements:** `MAC-01`, `MAC-02`, `MAC-03`, `NFR-U02`, `FR-S02`

> As a developer, I want to prove the terminal adapter can support the required macOS workflows before building the application around it.

**Acceptance criteria**

- [x] **S001-AC01:** Embed the candidate engine in a minimal native Swift host and record its pinned version, license, supported architectures, and chosen PTY ownership strategy.
- [ ] **S001-AC02:** Demonstrate a shell, resize, alternate screen, Unicode, IME composition, native selection, paste, output access, and VoiceOver terminal reading; document failures with reproducible steps.
- [x] **S001-AC03:** Keep engine-specific types behind an adapter; select a supported TERM value based on demonstrated capabilities and available terminfo.
- [ ] **S001-AC04:** Record a go/no-go decision before dependent terminal work. Accessibility or lifecycle blockers require resolving the issue or choosing another engine, not silently dropping requirements.

**Named unit tests**

| Test | Setup, action, and expected result |
| --- | --- |
| `testS001_UT01_adapterPreservesOutputOrder` | Feed numbered byte chunks through a fake transport; adapter output preserves order without duplication. |
| `testS001_UT02_adapterPropagatesResize` | Provide a cell-size change; the adapter forwards the correct rows/columns once to its PTY owner. |
| `testS001_UT03_adapterDetachIsIdempotent` | Detach twice; callbacks and owned resources are released exactly once. |
| `testS001_UT04_unsupportedEngineCapabilityIsExplicit` | Request an unavailable capability; adapter returns an explicit unsupported result rather than fabricated output. |

**Integration and manual verification**

Run the feasibility checklist on the proposed minimum/current macOS and both CPU architectures where available. Record actual devices and outstanding coverage; dependency claims alone are insufficient.

**Evidence:** Implementation, review findings, environment, automated evidence, and outstanding interaction checks are recorded in [S001 evidence](../evidence/S001-terminal-feasibility.md). S001-AC02/AC04 remain open; programmatic accessibility checks do not establish spoken VoiceOver quality.

Link the implementation and passing relevant tests; record the acceptance demo and any required real-platform results. A story is complete only when its criteria and verification evidence pass. Document blockers rather than marking unavailable checks as passed.

### S002 — Create the authoritative workspace model {#s002}

- **Status:** Done — reviewed; 14 workspace tests and full 30-test suite passing
- **Phase:** 1 — Foundation and terminal feasibility
- **Depends on:** None
- **Requirements:** `NFR-R03`, `API-03`, `FR-A02`

> As a developer, I want to route UI and automation operations through one consistent domain model.

**Acceptance criteria**

- [x] **S002-AC01:** Model windows, ordered tabs, binary split trees, panes, sessions, UUIDs, selection, and monotonically increasing revisions.
- [x] **S002-AC02:** Enforce one or more tabs per existing window, one or more panes per tab, and exactly two children per split; allow zero windows.
- [x] **S002-AC03:** Serialize mutations through a store actor and shared command service; invalid operations leave the entire model unchanged.
- [x] **S002-AC04:** Keep process effects outside pure tree mutation, so a launch failure becomes a failed session without dangling pane references.

**Named unit tests**

| Test | Setup, action, and expected result |
| --- | --- |
| `testS002_UT01_rejectDanglingReferences` | Create a tree with an unknown pane ID; reject it and preserve the previous snapshot. |
| `testS002_UT02_rejectMalformedSplit` | Supply zero, one, or three split children; all variants fail without mutation. |
| `testS002_UT03_rejectStaleRevision` | Apply two changes using the same revision; only the first commits and the second conflicts. |
| `testS002_UT04_failedLaunchKeepsValidPane` | Inject a failed launch effect after creation; retain the pane and its failed session with valid ownership links. |

**Integration and manual verification**

Exercise concurrent mutations against the real actor; compare UI and service snapshots for equivalent operations.

**Evidence:** See [S002 evidence](../evidence/S002-workspace-model.md) for implementation boundaries, tests, review findings, and final verification.

Link the implementation and passing relevant tests; record the acceptance demo and any required real-platform results. A story is complete only when its criteria and verification evidence pass. Document blockers rather than marking unavailable checks as passed.

### S003 — Launch and operate local PTY sessions {#s003}

- **Status:** Done — reviewed and fixed; 43 tests passing
- **Phase:** 1 — Foundation and terminal feasibility
- **Depends on:** [S001](#s001), [S002](#s002)
- **Requirements:** `FR-S01`, `FR-S03`, `FR-S05`, `INT-01`, `MAC-08`, `NFR-S08`

> As a terminal user, I want to run my shell or an explicitly configured process in an independent pane.

**Acceptance criteria**

- [x] **S003-AC01:** Launch the configured login shell with a controlling PTY, owned process group, initial dimensions, working directory, and allowed environment overrides.
- [x] **S003-AC02:** Validate executable and directory before spawn, preserve argument boundaries, and remove application control secrets from child environments.
- [x] **S003-AC03:** Report starting/running/exited/failed states and process exit status; a live interactive shell does not imply prompt readiness or command success.
- [x] **S003-AC04:** Handle ordered asynchronous output, terminal input, resize notifications, child reaping, and descriptor cleanup without blocking the main actor.

**Named unit tests**

| Test | Setup, action, and expected result |
| --- | --- |
| `testS003_UT01_rejectInaccessibleDirectory` | Use a denied directory fixture; report a launch error with zero spawn calls. |
| `testS003_UT02_preserveLaunchArguments` | Pass paths and arguments containing spaces and metacharacters; fake spawn receives the exact argument array. |
| `testS003_UT03_stripControlSecrets` | Seed control credentials and an allowed variable; only the allowed variable reaches the child environment. |
| `testS003_UT04_exitAndCleanupOnce` | Deliver exit and teardown twice through a fake process transport; store the exit code and release each descriptor once. |

**Integration and manual verification**

On real zsh and bash verify Ctrl-C, Ctrl-D, job control, resize, a dedicated process exiting with code 7, and reaping. Never run test commands in the user’s existing sessions.

**Evidence:** See [S003 evidence](../evidence/S003-local-sessions.md) for the implementation, real shell checks, reviewer fixes, and remaining platform qualification boundaries.

Link the implementation and passing relevant tests; record the acceptance demo and any required real-platform results. A story is complete only when its criteria and verification evidence pass. Document blockers rather than marking unavailable checks as passed.

### S004 — Build the Native calm application shell {#s004}

- **Status:** Implemented and independently reviewed — native lifecycle/display qualification pending
- **Phase:** 2 — Native organization and session safety
- **Depends on:** [S001](#s001), [S002](#s002)
- **Requirements:** `MAC-03`, `MAC-04`, `MAC-05`, `MAC-06`, `FR-W04`

> As a macOS user, I want to see a familiar native app with a window sidebar and a separate tab bar.

**Acceptance criteria**

- [ ] **S004-AC01:** Provide one terminal-bearing native window with sidebar, per-workspace top tab bar, settings, menu bar, Dock behavior, and an empty-state creation action.
- [x] **S004-AC02:** Use native system fonts for application chrome and start with light chrome; keep terminal styling delegated to the terminal adapter.
- [x] **S004-AC03:** Disable automatic macOS window tabbing so application tabs belong exclusively to the workspace model.
- [ ] **S004-AC04:** Support minimize, full screen, monitor changes, and restored geometry constrained to available displays; undersized terminal areas preserve their split tree using the specified minimum canvas.

**Named unit tests**

| Test | Setup, action, and expected result |
| --- | --- |
| `testS004_UT01_emptyStateProjection` | Project a model with zero windows; show the welcome state and its create action. |
| `testS004_UT02_selectedWindowOwnsTabBar` | Project two windows; the visible tab bar contains only the selected window’s ordered tabs. |
| `testS004_UT03_constrainOffscreenGeometry` | Restore a rectangle outside the current display union; clamp it into an available display. |
| `testS004_UT04_smallCanvasRetainsLayout` | Provide dimensions below pane minima; request a minimum-sized canvas without deleting or rewriting split nodes. |

**Integration and manual verification**

Inspect the native app in full screen, on Retina and available external displays, and after disconnecting a monitor. Verify menu and Dock behavior manually.

**Evidence:** See [S004 implementation, review, and test evidence](../evidence/S004-native-shell.md). All 55 tests pass. AC01 and AC04 remain unchecked for unperformed native lifecycle and display qualification; implementation continues under the user’s explicit instruction.

### S005 — Manage windows from the sidebar {#s005}

- **Status:** Implemented with independent review fixes — 64-test suite passing; native interaction qualification pending
- **Phase:** 2 — Native organization and session safety
- **Depends on:** [S002](#s002), [S004](#s004)
- **Requirements:** `FR-W01`, `FR-W02`, `FR-W03`, `FR-W04`

> As a developer, I want to organize independent groups of terminal tabs in named sidebar windows.

**Acceptance criteria**

- [x] **S005-AC01:** Create, rename, reorder, select, and delete managed windows; creation includes one tab and one pane.
- [x] **S005-AC02:** Preserve each window’s active tab/pane when switching; inactive sessions continue running with the same IDs.
- [x] **S005-AC03:** Show bounded activity and exit indicators for inactive windows without stealing selection.
- [x] **S005-AC04:** Deleting the last window reaches the empty state; live-session deletion uses the common closure workflow rather than bypassing it.

**Named unit tests**

| Test | Setup, action, and expected result |
| --- | --- |
| `testS005_UT01_createInitialHierarchy` | Create one window; assert exactly one initial tab, pane, and session record with distinct valid IDs. |
| `testS005_UT02_switchRestoresSelection` | Select different tabs/panes in two windows; switch back and recover each stored selection. |
| `testS005_UT03_reorderIsPermutation` | Submit missing, repeated, and unknown IDs; reject each invalid order atomically. |
| `testS005_UT04_inactiveOutputDoesNotSelect` | Deliver many output/activity notifications to an inactive window; retain the active window and bounded indicator state. |

**Integration and manual verification**

Run background output, change sidebar selection, and verify output continues. After persistence is available, restart and confirm order and names.

**Evidence:** See [S005 implementation and review evidence](../evidence/S005-managed-windows.md). Behavior is covered by nine story tests and the full 64-test suite. Native context-menu/dialog interaction and later persistence qualification remain pending; acceptance checkboxes describe implemented/tested behavior, not completed release qualification.

### S006 — Manage multiple renameable tabs per window {#s006}

- **Status:** Implemented and independently reviewed — 72-test suite and native tab checks passing
- **Phase:** 2 — Native organization and session safety
- **Depends on:** [S002](#s002), [S004](#s004), [S005](#s005)
- **Requirements:** `FR-T01`, `FR-T02`, `FR-T03`, `FR-W03`

> As a developer, I want to create and name several tabs within each window without losing running sessions.

**Acceptance criteria**

- [x] **S006-AC01:** Each window has its own ordered top tab bar with visible separators, selected state, new-tab button, and discoverable rename action.
- [x] **S006-AC02:** Double-click or Rename edits the label inline; Enter commits trimmed nonempty text, Escape cancels, and empty input retains the previous title.
- [x] **S006-AC03:** Rename, selection, and reorder preserve pane/session IDs and live processes; switching windows restores the correct tab collection and selection.
- [x] **S006-AC04:** Duplicate copies configuration and split layout into fresh IDs and processes without copying terminal output or previously typed commands; close delegates to the common closure workflow.

**Named unit tests**

| Test | Setup, action, and expected result |
| --- | --- |
| `testS006_UT01_renameCommitsWithoutRestart` | Rename a live tab via its edit model; update only the label/revision, retaining session IDs and zero spawn/terminate calls. |
| `testS006_UT02_cancelAndEmptyRenamePreserveTitle` | Exercise Escape and whitespace-only input; original title and revision remain unchanged. |
| `testS006_UT03_duplicateRemapsHierarchy` | Duplicate a mixed split tab; all new structural/session IDs are distinct while ratios and launch settings match; buffers are empty. |
| `testS006_UT04_tabOrderIsWindowLocal` | Reorder tabs in window A; window B’s order and active tab do not change. |

**Integration and manual verification**

Use two windows with three tabs each. Rename by pointer and keyboard, reorder, switch back, and after persistence is available verify saved titles. Duplicate into independent live sessions.

**Evidence:** See [S006 implementation, review fixes, and native interaction evidence](../evidence/S006-tabs.md). The full 72-test suite passes. Native inline rename, reorder, and confirmed live-tab closure passed. Saved titles across relaunch are verified with persistence in S010; prior platform qualification gaps remain pending.

### S007 — Create and close nested terminal splits {#s007}

- **Status:** Implemented and independently reviewed — 81-test suite and native split checks passing
- **Phase:** 2 — Native organization and session safety
- **Depends on:** [S002](#s002), [S003](#s003), [S006](#s006)
- **Requirements:** `FR-P01`, `FR-P03`, `FR-T03`

> As a terminal user, I want to split any pane left/right or top/bottom while retaining independent sessions.

**Acceptance criteria**

- [x] **S007-AC01:** Offer Split Left/Right (axis x) and Split Top/Bottom (axis y) on every leaf, including nested leaves; preserve the existing pane as first child.
- [x] **S007-AC02:** Assign stable IDs to new branches/panes; create a distinct session per new pane and expose launch failure without invalidating the tree.
- [x] **S007-AC03:** Closing one leaf collapses its parent into the sibling while retaining surviving IDs; the last pane closes its tab and the last tab closes its window.
- [x] **S007-AC04:** Reject splits beyond depth 16, the total capacity of 100 panes, or available minimum cell dimensions; failure leaves the original state intact.

**Named unit tests**

| Test | Setup, action, and expected result |
| --- | --- |
| `testS007_UT01_mixedAxisSplitPreservesLeaf` | Split x then y; assert expected topology, first-child order, and unchanged original session ID. |
| `testS007_UT02_closeCollapsesOnlyParent` | Remove a nested leaf; sibling replaces its parent and unrelated branches remain identical. |
| `testS007_UT03_lastLeafCascadesToEmpty` | Close the last stopped pane in the last window; end in a valid zero-window state. |
| `testS007_UT04_rejectSplitLimitsAtomically` | Try depths 16/17, totals 100/101, and insufficient cells; accept valid boundaries and leave rejected snapshots unchanged. |

**Integration and manual verification**

Interact independently with a mixed-axis three-pane layout and verify terminal resize propagates to each PTY. Confirm closure safety once S009 is available.

**Evidence:** See [S007 implementation, review fixes, tests, and native evidence](../evidence/S007-nested-splits.md). All 81 tests pass. Native mixed-axis input, confirmed leaf closure, surviving view/process identity, and PTY resize after collapse passed. Prior physical platform qualification remains pending.

### S008 — Resize, focus, and maximize panes {#s008}

- **Status:** Implemented and independently reviewed — 89 tests and native interaction checks pass
- **Phase:** 2 — Native organization and session safety
- **Depends on:** [S004](#s004), [S007](#s007)
- **Requirements:** `FR-P02`, `FR-P04`, `MAC-06`, `NFR-U01`

> As a terminal user, I want to navigate and resize my split layout with a clear focused pane.

**Acceptance criteria**

- [x] **S008-AC01:** Drag or keyboard-resize split dividers using a finite ratio between 0.1 and 0.9 while maintaining at least 20 columns by 5 rows per pane.
- [x] **S008-AC02:** Map directional navigation to pane geometry and retain a visible focus indicator; terminal input goes to one focused pane.
- [x] **S008-AC03:** Maximize a pane temporarily and restore the exact saved split tree/ratios without restarting hidden sessions.
- [x] **S008-AC04:** Save the active pane per tab and use a deterministic surviving neighbor when a focused pane closes.

**Named unit tests**

| Test | Setup, action, and expected result |
| --- | --- |
| `testS008_UT01_rejectInvalidRatios` | Submit NaN, infinity, out-of-range ratios, and geometrically impossible ratios; reject without resizing. |
| `testS008_UT02_directionalFocusUsesGeometry` | Use an asymmetric mixed-axis tree; choose the nearest eligible neighbor in each direction. |
| `testS008_UT03_maximizeRoundTrip` | Maximize and restore; compare all tree IDs and ratios and assert zero process lifecycle calls. |
| `testS008_UT04_closedFocusChoosesSurvivor` | Close the focused leaf; focus moves to a remaining pane in the same tab or the resulting selected tab. |

**Integration and manual verification**

Resize via mouse and keyboard while a full-screen terminal program runs; verify focus indicators and PTY dimensions across monitor/scale changes.

**Evidence:** See [S008 implementation, review fixes, and native evidence](../evidence/S008-pane-interaction.md). The full 89-test suite passes. Native mouse/keyboard resizing, directional focus, maximize/restore, and full-screen terminal-editor interaction passed. Physical display/scale and native-window full-screen qualification remain pending.

### S009 — Close and restart sessions safely {#s009}

- **Status:** Implemented and independently reviewed — 98 tests and native close/restart checks pass
- **Phase:** 2 — Native organization and session safety
- **Depends on:** [S003](#s003), [S005](#s005), [S006](#s006), [S007](#s007)
- **Requirements:** `FR-S03`, `FR-T03`, `MAC-04`, `NFR-R01`

> As a terminal user, I want to understand what will stop before closing panes, tabs, windows, or the app.

**Acceptance criteria**

- [x] **S009-AC01:** Running-session closure presents one affected-session summary per action; cancel sends no termination signal and changes no structure.
- [x] **S009-AC02:** After explicit acceptance, gracefully terminate only owned process groups, wait up to two seconds, and offer force termination when needed.
- [x] **S009-AC03:** Automation returns CONFIRMATION_REQUIRED without allowRunning authorization and CLOSE_PENDING after the grace interval; force requires a separate explicit request.
- [x] **S009-AC04:** Reap children and close descriptors exactly once. Restart creates a fresh session UUID in the same pane; exited output remains inspectable until restart. Remote detached processes are not reported as terminated.

**Named unit tests**

| Test | Setup, action, and expected result |
| --- | --- |
| `testS009_UT01_cancelHasNoEffects` | Cancel closure of a three-session window; process spy sees no signals and the tree remains unchanged. |
| `testS009_UT02_graceTimeoutRequiresExplicitForce` | Advance a fake clock by two seconds with a non-exiting child; return pending without a kill until explicit force. |
| `testS009_UT03_neverSignalReusedPid` | Replace ownership identity before cleanup; refuse to signal an unrelated reused process ID. |
| `testS009_UT04_restartReplacesOnlySession` | Restart an exited pane; retain pane/tab IDs, assign one new session ID, and clear old runtime buffers. |

**Integration and manual verification**

Close running local and controlled SSH sessions, test a child that ignores graceful termination, and verify quit/native-window-close summaries and descriptor cleanup.

**Evidence:** See [S009 implementation, review fixes, and verification evidence](../evidence/S009-session-safety.md). All 98 tests pass. Native restart, Cancel, Keep Waiting, and explicit Force Stop checks passed. Controlled SSH close qualification remains pending its integration story; automation result codes are tested at the shared lifecycle policy boundary, with transport/grant wiring in later stories.

### S010 — Persist workspaces and restore stopped sessions {#s010}

- **Status:** Implemented and reviewed — 110 tests pass; native restore/recovery verified
- **Phase:** 2 — Native organization and session safety
- **Depends on:** [S002](#s002), [S005](#s005), [S006](#s006), [S007](#s007), [S009](#s009)
- **Requirements:** `FR-R01`, `NFR-R02`, `NFR-R05`, `MAC-11`

> As a terminal user, I want to recover my organization after relaunch without silently executing old commands.

**Acceptance criteria**

- [x] **S010-AC01:** Atomically save versioned state, names, orders, ratios, selection, safe launch references, and settings; debounce normal saves and flush explicit save/shutdown.
- [x] **S010-AC02:** Restore stable resource IDs and layout as stopped sessions, never live PID handles or replayed shell input; starting restored panes requires explicit action.
- [x] **S010-AC03:** Keep a last-known-good backup and preserve corrupt originals; offer backup recovery or an empty workspace without destroying evidence.
- [x] **S010-AC04:** Migrations are failure-safe; unsupported newer versions enter recovery without rewriting the source. Exclude output, input transcripts, tokens, and runtime secret environment values.

**Named unit tests**

| Test | Setup, action, and expected result |
| --- | --- |
| `testS010_UT01_restoreNeverSpawns` | Decode a snapshot marked running at save time; restore stopped records and assert zero launch calls. |
| `testS010_UT02_failedAtomicWriteKeepsBackup` | Inject failure before replacement; current or backup remains parseable and the original is preserved. |
| `testS010_UT03_newerSchemaIsReadOnly` | Load a future version; expose recovery and make zero filesystem writes. |
| `testS010_UT04_snapshotOmitsSecretsAndBuffers` | Seed a session with distinctive secret/input/output values; none appear in the encoded snapshot. |

**Integration and manual verification**

Interrupt a real save, relaunch after a simulated crash, and migrate older fixture snapshots. Verify names and split ratios return without shell execution.

**Evidence:** See [S010 evidence](../evidence/S010-workspace-persistence.md) for implementation decisions, 110 passing tests, native stopped relaunch, backup recovery, and the physical power-loss qualification limit. Arbitrary process arguments are never saved; those panes require fresh configuration after restore.

### S011 — Select and copy terminal text naturally {#s011}

- **Status:** Implemented and reviewed — 117 tests and native copy checks pass; delayed independent review completed during S012
- **Phase:** 3 — Everyday terminal use
- **Depends on:** [S001](#s001), [S003](#s003), [S004](#s004)
- **Requirements:** `FR-C01`, `FR-C02`, `INT-08`, `MAC-07`

> As a terminal user, I want to select and copy text with native macOS gestures and shortcuts.

**Acceptance criteria**

- [x] **S011-AC01:** Support drag, word/line selection, Select All, copy selection, and copy all retained text as plain Unicode text without terminal control sequences.
- [x] **S011-AC02:** Cmd-C copies a selection; Cmd-C without a selection does not send SIGINT. Ctrl-C remains terminal interrupt input.
- [x] **S011-AC03:** Context-menu and menu-bar copy operate on the focused pane and honor the native responder chain.
- [x] **S011-AC04:** Copy all covers only retained content and indicates eviction when older output is unavailable; never poll or retain clipboard contents.

**Named unit tests**

| Test | Setup, action, and expected result |
| --- | --- |
| `testS011_UT01_copyStripsControlsPreservesUnicode` | Copy a fixture with ANSI colors, emoji, combining marks, and newlines; assert exact plain-text output. |
| `testS011_UT02_cmdCWithoutSelectionDoesNotInterrupt` | Invoke Cmd-C without selection; fake terminal transport receives zero bytes/signals. |
| `testS011_UT03_ctrlCStillReachesTerminal` | Route Ctrl-C with no edit field active; transport receives the intended terminal control input. |
| `testS011_UT04_copyUsesFocusedPane` | Select different content in two panes; copy writes only the focused pane’s selected text once. |

**Integration and manual verification**

Verify drag/word/line selection, alternate-screen selection behavior, menus, and Cmd-C/Ctrl-C in the real terminal view using NSPasteboard.

**Evidence:** See [S011 evidence](../evidence/S011-terminal-copy.md) for 117 passing tests, native selection/clipboard/interrupt checks, engine edge fixes, and the independent review completed during S012 after the first agent hit its service usage limit.

### S012 — Paste text and file paths safely {#s012}

- **Status:** Implemented and reviewed — 126 tests pass; native two-pane paste and escaped-path checks verified
- **Phase:** 3 — Everyday terminal use
- **Depends on:** [S003](#s003), [S008](#s008), [S011](#s011)
- **Requirements:** `FR-C03`, `FR-C04`, `FR-C05`, `INT-08`

> As a terminal user, I want to paste into exactly one pane with clear review of potentially surprising input.

**Acceptance criteria**

- [x] **S012-AC01:** Cmd-V and context paste read text only on user action and target the focused pane; use bracketed paste only when negotiated.
- [x] **S012-AC02:** Multiline or control-character text requires a preview with line count, visible controls, and target; cancellation sends zero bytes.
- [x] **S012-AC03:** Paste preserves clipboard content without appending a newline; changing focus or closing the reviewed target invalidates the pending paste and requires a new review.
- [x] **S012-AC04:** Provide explicit Paste Escaped Path for supported shells; preserve ordinary text paste and preview quoting for unsupported shells.

**Named unit tests**

| Test | Setup, action, and expected result |
| --- | --- |
| `testS012_UT01_pasteReviewClassifiesControls` | Classify single-line, CR/LF, tab, ESC, and other control fixtures; flag the inputs needing review. |
| `testS012_UT02_cancelOrStaleTargetWritesNothing` | Cancel or change/close the reviewed pane before confirmation; no transport receives any payload. |
| `testS012_UT03_bracketedPastePreservesPayload` | With negotiation on/off, assert exact framing and unchanged payload bytes with no extra newline. |
| `testS012_UT04_escapePathByShell` | Quote spaces, apostrophes, dollar signs, and newlines for zsh/bash fixtures; unsupported shells require preview instead of guessed execution. |

**Integration and manual verification**

Verify native paste, reviewed multiline commands, file paths containing spaces, and terminal bracketed-paste mode with two active panes.

**Evidence:** See [S012 evidence](../evidence/S012-safe-paste.md) for 126 passing tests, independent review/fixes, native approval/cancel/focus checks, exact byte framing, and escaped-path verification. Finder file-URL negotiation remains an unperformed manual check; native path verification used literal clipboard text.

### S013 — Retain bounded output and search a pane {#s013}

- **Status:** Implemented and reviewed — 138 tests pass; native long-output, alternate-screen, and search-focus checks verified
- **Phase:** 3 — Everyday terminal use
- **Depends on:** [S001](#s001), [S003](#s003)
- **Requirements:** `FR-S04`, `NFR-P05`, `NFR-R06`

> As a terminal user, I want to search recent output without allowing scrollback to grow without limit.

**Acceptance criteria**

- [x] **S013-AC01:** Keep 10,000 lines per pane by default and an additional 16 MiB storage cap; evict oldest retained content when either limit is reached.
- [x] **S013-AC02:** Search plain-text retained output forward/backward with a visible current match; expose that earlier history may have been evicted.
- [x] **S013-AC03:** Keep screen/alternate-screen state and scrollback behavior consistent with the selected engine; search never mixes output from other panes.
- [x] **S013-AC04:** Preserve byte ordering in parsing; bounded output queues and frame coalescing do not silently reorder terminal data.

**Named unit tests**

| Test | Setup, action, and expected result |
| --- | --- |
| `testS013_UT01_evictByLineAndByteLimits` | Append many short lines and one oversized line; retain data within both budgets with an eviction marker. |
| `testS013_UT02_unicodeSearchNavigatesMatches` | Find forward/backward matches containing combining marks and CJK text using stable text ranges. |
| `testS013_UT03_searchIsPaneLocalAndAlternateScreenDoesNotMix` | Use identical queries in two buffers; only the requested pane supplies results. |
| `testS013_UT04_evictionInvalidatesOldMatch` | Evict the current match; update selection/ranges without referencing removed content. |

**Integration and manual verification**

Search a real long-output session and alternate-screen app; flood output and verify bounded storage and responsive navigation.

**Evidence:** See [S013 evidence](../evidence/S013-scrollback-search.md) for 138 passing tests, independent review/fixes, native 12,000-row and Vim checks, keyboard focus verification, and engine-memory qualification limits. The 10,000-row/16 MiB budgets apply to historical rendered text; active-screen and engine overhead are accounted separately under NFR-P05.

### S014 — Apply light chrome and dark Monaco terminals {#s014}

- **Status:** Implemented — reviewed fixes, automated regressions, and native appearance checks pass
- **Phase:** 3 — Everyday terminal use
- **Depends on:** [S001](#s001), [S004](#s004)
- **Requirements:** `FR-U02`, `FR-TH01`, `FR-TH05`, `FR-TH06`, `MAC-07`

> As a terminal user, I want to get the agreed Native calm appearance immediately without configuring it.

**Acceptance criteria**

- [x] **S014-AC01:** First launch uses light sidebar/title/tab/settings chrome and dark terminal backgrounds with light text; Monaco is the default terminal font.
- [x] **S014-AC02:** Provide Light, Dark, and System chrome modes; both built-in themes keep terminals dark. Explicit modes ignore system appearance changes.
- [x] **S014-AC03:** Allow font family/size, zoom, cursor style, and scrollback settings; if Monaco is unavailable, use Menlo/system monospace with a visible notice.
- [x] **S014-AC04:** Apply appearance/font changes without restarting sessions or losing focus/selection. Persist mode, font settings, and selected dark/light theme IDs through the persistence service.

**Named unit tests**

| Test | Setup, action, and expected result |
| --- | --- |
| `testS014_UT01_firstLaunchPalette` | Resolve empty preferences; select light chrome, dark terminal colors, and Monaco. |
| `testS014_UT02_systemModeVsExplicitMode` | Simulate system appearance changes; only System changes chrome, and both built-in terminal backgrounds remain dark. |
| `testS014_UT03_missingMonacoFallback` | Use a font catalog without Monaco; choose the documented monospace fallback and expose a notice. |
| `testS014_UT04_appearanceHasNoSessionEffects` | Change theme/font settings with live sessions; process spy sees zero spawn/input/termination calls and selection remains intact. |

**Integration and manual verification**

Inspect light/dark/system modes on macOS, Monaco rendering and cell metrics, zoom, missing-font behavior, and preference restoration once S010 is available.

**Evidence:** See [S014 appearance evidence](../evidence/S014-appearance.md) for the implementation, independent review findings and fixes, passing tests, native settings/zoom/restoration checks, and remaining platform qualification scope. Selection preservation applies to retained text; explicitly evicted history and alternate-screen cells clipped by a geometry change cannot be retained as a terminal selection.

### S015 — Define and validate simple JSON themes {#s015}

- **Status:** Implemented — independently reviewed, 171 tests and native preview checks pass
- **Phase:** 3 — Everyday terminal use
- **Depends on:** [S014](#s014)
- **Requirements:** `FR-TH02`, `FR-TH04`, `FR-TH06`, `FR-TH07`, `INT-10`

> As a theme author, I want to create a theme by copying and editing a small JSON file.

**Acceptance criteria**

- [x] **S015-AC01:** Accept the v1 theme schema and supplied full/minimal examples; only version, id, name, and appearance are required.
- [x] **S015-AC02:** Resolve omitted fields against the matching built-in palette; an optional ANSI array replaces exactly 16 indexes. Custom terminal colors may override the dark defaults.
- [x] **S015-AC03:** Reject malformed JSON, duplicate keys, unknown fields, invalid IDs/colors, unsupported versions, wrong ANSI length, and files over 64 KiB before installation.
- [x] **S015-AC04:** Report field-path errors and advisory contrast warnings; preview text, selection, cursor, status, and ANSI colors. Theme files contain no scripts, remote includes, fonts, or executable content.

**Named unit tests**

| Test | Setup, action, and expected result |
| --- | --- |
| `testS015_UT01_minimalThemeInheritsDefaults` | Validate the documented minimal fixture; override supplied colors and inherit all other matching built-in colors. |
| `testS015_UT02_rejectMalformedThemeVariants` | Table-drive duplicate keys, extra fields, invalid hex/version/type/ID, 15/17 ANSI entries, and over-limit input; receive specific validation errors. |
| `testS015_UT03_paletteIndexesKeepOrder` | Load 16 distinct colors; engine palette indexes 0–15 match the declared order. |
| `testS015_UT04_contrastWarningsNamePairs` | Use low-contrast foreground/background, selection, and cursor pairs; produce advisory field-pair warnings without rejecting otherwise valid custom data. |

**Integration and manual verification**

Load both committed example files into the real preview and render all palette entries. Measure built-in text contrast ≥4.5:1 and essential focus/boundaries ≥3:1.

**Evidence:** See [S015 JSON theme evidence](../evidence/S015-json-themes.md) for implementation, passing tests, independent review fixes, native fixture/diagnostic checks, and the boundary with S016 theme installation.

### S016 — Import, preview, and maintain custom themes {#s016}

- **Status:** Implemented — independently reviewed, 184 tests and native library checks pass
- **Phase:** 3 — Everyday terminal use
- **Depends on:** [S010](#s010), [S015](#s015)
- **Requirements:** `FR-TH03`, `FR-TH04`, `FR-TH05`, `INT-10`

> As a terminal user, I want to try and edit JSON themes without risking my working appearance.

**Acceptance criteria**

- [x] **S016-AC01:** Import validated files into the app-owned Themes directory using validated IDs; reserve trellis- IDs for built-ins and require explicit replacement of duplicates.
- [x] **S016-AC02:** Preview is reversible, Save installs atomically, and Cancel restores the prior effective appearance without touching sessions.
- [x] **S016-AC03:** Provide export, Export Resolved, Open Themes Folder, and Reload Themes; invalid edits retain the last valid in-memory palette with actionable errors.
- [x] **S016-AC04:** Deleting a selected custom theme or launching with a missing file falls back to the built-in palette for that slot with a notice; built-ins cannot be replaced/deleted.

**Named unit tests**

| Test | Setup, action, and expected result |
| --- | --- |
| `testS016_UT01_duplicateRequiresReplace` | Import an existing ID without replacement; preserve its file and active palette. |
| `testS016_UT02_failedReplacePreservesOldFile` | Inject an atomic-write failure; both installed metadata and current palette retain the prior valid version. |
| `testS016_UT03_cancelPreviewRestoresEffectivePalette` | Preview different colors then cancel; recover mode, selected IDs, and resolved colors exactly. |
| `testS016_UT04_reloadInvalidAndMissingThemes` | Reload malformed and removed selected files; preserve last valid colors for invalid edits and select built-in fallback for missing files. |

**Integration and manual verification**

Edit a theme with an external editor, reload, export/import it, and delete it while selected. Confirm no app or shell restart is required.

**Evidence:** See [S016 theme library evidence](../evidence/S016-theme-library.md) for atomic install/failure tests, preview restoration, review findings and fixes, native reload/export/delete checks, and remaining platform qualification scope.

### S017 — Support keyboard navigation and native accessibility {#s017}

- **Status:** Implemented — independently reviewed, 201 tests pass; VoiceOver/IME/layout manual checks pending
- **Phase:** 3 — Everyday terminal use
- **Depends on:** [S004](#s004), [S006](#s006), [S008](#s008), [S011](#s011), [S012](#s012), [S014](#s014)
- **Requirements:** `FR-U01`, `NFR-U01`, `NFR-U02`, `NFR-U03`, `NFR-U04`, `MAC-07`

> As a keyboard or assistive-technology user, I want to operate every primary workflow without relying on pointer input or color alone.

**Acceptance criteria**

- [ ] **S017-AC01:** Expose configurable discoverable menu shortcuts, including windows/tabs/splits/search; detect conflicting bindings before saving.
- [ ] **S017-AC02:** Provide accessible labels, roles, selected states, and focus indicators for sidebar, tab bar, renaming, panes, dialogs, and statuses.
- [ ] **S017-AC03:** Support VoiceOver terminal reading, increased contrast, reduced motion, US/Portuguese layouts, dead keys, an IME, and configurable Option-as-Meta.
- [ ] **S017-AC04:** Keep native text-field editing separate from terminal control input; do not request blanket Accessibility permission to make the app usable.

**Named unit tests**

| Test | Setup, action, and expected result |
| --- | --- |
| `testS017_UT01_rejectShortcutCollision` | Bind two enabled actions to the same key chord; report both actions and keep the previous map. |
| `testS017_UT02_editingConsumesRenameKeys` | With tab-name editing active, Enter/Escape edit the title and never reach the PTY. |
| `testS017_UT03_inputRoutingRespectsComposition` | Deliver marked-text composition events; committed text reaches the adapter once and intermediate text is not sent as commands. |
| `testS017_UT04_accessibilityStateReflectsSelection` | Project selected window/tab/pane and session exit; expose correct labels/states plus a text status independent of color. |

**Integration and manual verification**

Perform a keyboard-only daily workflow and VoiceOver reading/navigation. Test US and Portuguese layouts, dead keys, emoji/CJK, and a real IME; these are not replaced by mocked input tests.

**Evidence:** See [S017 keyboard and accessibility evidence](../evidence/S017-keyboard-accessibility.md) for shortcut validation, rename input isolation, composition tests, review fixes, and the pending VoiceOver/IME/layout checks. Acceptance boxes stay unchecked until those native checks are observed.

### S018 — Maintain a searchable saved-host library {#s018}

- **Status:** Implemented — independently reviewed, 211 tests pass; native persistence/search demo pending
- **Phase:** 3 — Everyday terminal use
- **Depends on:** [S002](#s002), [S004](#s004), [S010](#s010)
- **Requirements:** `FR-H01`, `INT-03`, `NFR-S03`, `MAC-12`

> As an operator, I want to save and find frequently used SSH destinations without copying connection commands.

**Acceptance criteria**

- [ ] **S018-AC01:** Create/edit/delete hosts with display name, alias-or-hostname destination, optional user/port/absolute identity-file reference, and tags.
- [ ] **S018-AC02:** Search names/destinations/tags; save metadata with revisions and persist without passwords, key contents, or terminal output.
- [ ] **S018-AC03:** Validate port 1–65535, destination/control-character restrictions, and identity paths before save; present actionable field errors.
- [ ] **S018-AC04:** Edits affect future connections only; deleting a host removes saved metadata without killing sessions or modifying SSH files.

**Named unit tests**

| Test | Setup, action, and expected result |
| --- | --- |
| `testS018_UT01_validateHostBoundaries` | Exercise ports 0/1/65535/65536, leading-option destinations, control characters, and invalid identity paths; accept only valid records. |
| `testS018_UT02_searchAcrossMetadata` | Query mixed-case names/tags/destinations; return matching saved IDs without altering order unexpectedly. |
| `testS018_UT03_editDoesNotMutateLiveLaunch` | Edit a connected host; its stored revision changes while the live session descriptor remains unchanged. |
| `testS018_UT04_deleteDoesNotTouchSshFiles` | Delete a host with fake filesystem/process dependencies; only app-owned metadata is removed and no signals are sent. |

**Integration and manual verification**

Create local fixture hosts, restart, and verify persistence/search. Confirm host deletion never removes keys, config, or known-hosts files.

**Evidence:** See [S018 saved-host evidence](../evidence/S018-saved-hosts.md) for validation, revision, persistence, deletion-safety tests, review fixes, and the pending native demo.

### S019 — Discover SSH aliases without changing SSH configuration {#s019}

- **Status:** Implemented — independently reviewed, 220 tests pass; native fixture demo pending
- **Phase:** 3 — Everyday terminal use
- **Depends on:** [S018](#s018)
- **Requirements:** `FR-H03`, `INT-04`

> As an operator, I want to reuse existing SSH aliases without entering all their underlying settings again.

**Acceptance criteria**

- [ ] **S019-AC01:** Read literal aliases from the user SSH config in a best-effort discovery screen; preview selection before adding saved metadata.
- [ ] **S019-AC02:** Keep the alias as the SSH destination instead of flattening OpenSSH behavior into copied host options.
- [ ] **S019-AC03:** Do not materialize wildcard/Match sections; explain unsupported Include discovery and allow manual alias entry.
- [ ] **S019-AC04:** Never edit SSH configuration, read private-key contents, or execute Match exec commands to populate the list; unreadable files produce a recoverable error.

**Named unit tests**

| Test | Setup, action, and expected result |
| --- | --- |
| `testS019_UT01_discoverLiteralAliases` | Parse comments, whitespace, and multiple literal names per Host stanza; return the expected aliases. |
| `testS019_UT02_skipPatternsAndMatch` | Use wildcard Host and Match exec fixtures; expose supported aliases and never execute a subprocess. |
| `testS019_UT03_includeHasExplicitLimitation` | Encounter Include; return a discovery warning instead of pretending every included alias was found. |
| `testS019_UT04_unreadableConfigIsNonDestructive` | Inject a permission error; preserve existing hosts and perform zero writes. |

**Integration and manual verification**

Use an isolated SSH config fixture and compare connecting by the original alias. Do not modify or connect to production hosts during development.

**Evidence:** See [S019 alias discovery evidence](../evidence/S019-ssh-alias-discovery.md) for parser, read-only/bounded file handling, atomic import tests, review fixes, and the pending native fixture demo.

### S020 — Open SSH sessions in tabs or splits {#s020}

- **Status:** Implemented — independently reviewed, 226 tests pass; real SSH server checks pending
- **Phase:** 3 — Everyday terminal use
- **Depends on:** [S003](#s003), [S007](#s007), [S009](#s009), [S018](#s018), [S019](#s019)
- **Requirements:** `FR-H02`, `FR-H04`, `FR-H05`, `INT-03`, `INT-05`, `NFR-S04`

> As an operator, I want to connect to a saved host in an independent terminal with normal SSH trust and authentication behavior.

**Acceptance criteria**

- [ ] **S020-AC01:** Use /usr/bin/ssh with a validated argument array in a PTY; saved fields override defaults only when explicitly supplied.
- [ ] **S020-AC02:** Connect in a new tab by default or a selected split; each attempt owns an independent session/process.
- [ ] **S020-AC03:** Leave unknown/changed host-key, password, passphrase, and agent authentication behavior to OpenSSH; never insert trust-bypass options.
- [ ] **S020-AC04:** Report running as a live SSH process rather than authenticated remote state; retain failures and exit status, and reconnect only explicitly.

**Named unit tests**

| Test | Setup, action, and expected result |
| --- | --- |
| `testS020_UT01_buildSshArgumentsSafely` | Supply alias/user/port/key paths containing spaces where valid; construct exact arguments with no shell interpolation. |
| `testS020_UT02_neverAddTrustBypass` | Generate arguments for all supported optional fields; no StrictHostKeyChecking disable or known-hosts bypass appears. |
| `testS020_UT03_connectCreatesIndependentSession` | Connect the same saved host twice; allocate distinct PTY/session IDs and preserve each target hierarchy. |
| `testS020_UT04_failedConnectionDoesNotRetry` | Inject SSH exit failure; expose the exit record with no timer-driven relaunch. |

**Integration and manual verification**

Against a controlled local SSH server verify key/agent/password prompts, unknown/changed keys, refused connections, and network loss; inspect new-tab/split placement.

**Evidence:** See [S020 SSH connection evidence](../evidence/S020-ssh-connections.md) for argument construction, independent-session, no-retry tests with an ssh fixture, review fixes, and the pending controlled-server checks.

### S021 — Expose a bounded local JSON-RPC control socket {#s021}

- **Status:** Implemented — independently reviewed, 235 tests and native socket checks pass
- **Phase:** 4 — Scripts and agents
- **Depends on:** [S002](#s002), [S004](#s004)
- **Requirements:** `API-01`, `API-06`, `NFR-S01`, `NFR-R04`

> As a script author, I want to find a running app and exchange structured requests over a local-only endpoint.

**Acceptance criteria**

- [ ] **S021-AC01:** Create an owner-only runtime directory/socket and token-free control.json discovery file with version, instance ID, and a short socket path.
- [ ] **S021-AC02:** Validate owner/peer UID and reject symlink endpoints; replace stale discovery only after verifying the previous instance is gone. Never bind TCP.
- [ ] **S021-AC03:** Parse newline-framed UTF-8 JSON-RPC 2.0 objects up to 1 MiB, reject batches, and require request IDs for mutation.
- [ ] **S021-AC04:** Return sanitized protocol errors and close malformed framing safely; all domain dispatch remains authentication-gated and uses the shared service.

**Named unit tests**

| Test | Setup, action, and expected result |
| --- | --- |
| `testS021_UT01_frameAcrossReads` | Split and combine frames across arbitrary byte chunks, including escaped newlines; yield exactly the intended requests. |
| `testS021_UT02_rejectOversizedAndMalformedFrames` | Feed an over-limit frame, invalid UTF-8/JSON, a batch, and mutation notification; reject without dispatch. |
| `testS021_UT03_rejectUnsafeEndpoint` | Use symlink, wrong-owner, and mismatched peer-UID fixtures; refuse endpoint use and domain dispatch. |
| `testS021_UT04_discoveryContainsNoSecret` | Publish discovery from an instance fixture; assert only allowed metadata fields and no credential content. |

**Integration and manual verification**

Connect through a real Unix socket; inspect file modes, same-user peer verification, socket-path limits, stale-instance handling, and absence of network listeners.

**Evidence:** See [S021 control socket evidence](../evidence/S021-control-socket.md) for framing/endpoint tests, the native mode/listener/stale-instance check, and review fixes.

### S022 — Authorize scoped script and agent access {#s022}

- **Status:** Implemented — independently reviewed, 243 tests pass; Keychain/native grant checks pending
- **Phase:** 4 — Scripts and agents
- **Depends on:** [S010](#s010), [S018](#s018), [S021](#s021)
- **Requirements:** `API-02`, `FR-A03`, `NFR-S01`, `NFR-S02`, `NFR-S06`, `NFR-S08`

> As a terminal user, I want to grant scripts only the terminal capabilities and resources I approve.

**Acceptance criteria**

- [ ] **S022-AC01:** Create expiring/revocable grants in settings, show a token only during explicit creation, store secrets in Keychain and only hashes in metadata.
- [ ] **S022-AC02:** Authenticate before any domain call; verify UID/token/version and rate-limit failures. Revocation stops subscriptions and expiry requires reauthentication.
- [ ] **S022-AC03:** Enforce separate metadata/layout/start/input/execute/output/close/host/theme capabilities at the service boundary; hidden resources return NOT_FOUND.
- [ ] **S022-AC04:** Bind approved hosts to connection revisions, require reapproval after destination changes, and keep global theme privileges separate from window scopes. Explain same-user-account isolation limits.

**Named unit tests**

| Test | Setup, action, and expected result |
| --- | --- |
| `testS022_UT01_denyBeforeAuthentication` | Call domain methods before auth with valid-looking IDs; return AUTH_REQUIRED with no effects. |
| `testS022_UT02_scopeAndCapabilityMatrix` | Table-drive grants against each method and resource scope; deny output/execute to a layout-only grant and redact hidden IDs. |
| `testS022_UT03_expiryAndRevocationStopAccess` | Advance a fake clock or revoke the grant; reject later calls and stop its subscriptions. |
| `testS022_UT04_hostRevisionInvalidatesApproval` | Approve a host then change its connection revision; prevent a subsequent start until reapproved. |

**Integration and manual verification**

Create/revoke a real Keychain-backed grant; test clients with different scopes and inspect app logs/exports/child environments for distinctive test-token leakage.

**Evidence:** See [S022 automation grant evidence](../evidence/S022-automation-grants.md) for authentication, capability/scope matrix, expiry/revocation, host-approval tests, review fixes, and pending Keychain checks.

### S023 — Expose resource commands with revisions and idempotency {#s023}

- **Status:** Implemented — independently reviewed, 251 tests pass; live socket client checks pending
- **Phase:** 4 — Scripts and agents
- **Depends on:** [S005](#s005), [S006](#s006), [S007](#s007), [S008](#s008), [S009](#s009), [S018](#s018), [S021](#s021), [S022](#s022)
- **Requirements:** `FR-A01`, `FR-A02`, `API-03`, `API-04`, `API-06`

> As a script author, I want to manage windows, tabs, panes, and hosts with stable IDs and predictable conflicts.

**Acceptance criteria**

- [ ] **S023-AC01:** Implement the catalogued window/tab/pane/host metadata and mutation methods, plus session.get and system.info, through the shared command service.
- [ ] **S023-AC02:** Return IDs/revisions/ownership and permission-appropriate fields; UI and API mutations obey identical tree/lifecycle rules.
- [ ] **S023-AC03:** API creation makes stopped panes unless start is explicitly requested and authorized; running closure requires allowRunning plus session.close.
- [ ] **S023-AC04:** Apply expectedRevision conflicts atomically; deduplicate identical keyed mutations for ten minutes per grant/instance and reject reused keys with different parameters.

**Named unit tests**

| Test | Setup, action, and expected result |
| --- | --- |
| `testS023_UT01_apiCreatesStoppedHierarchy` | Create window/tab/split through RPC; assert returned relationships and zero spawn calls by default. |
| `testS023_UT02_staleMutationHasNoEffects` | Mutate at revision N then submit another at N; return CONFLICT and preserve the committed state. |
| `testS023_UT03_idempotencyKeyScopeAndExpiry` | Repeat a mutation before/after ten minutes and across grants/instances; deduplicate only within the documented scope/window. |
| `testS023_UT04_apiUiDomainEquivalence` | Apply equivalent UI and API operations to separate fixture stores; compare resulting domain state after normalizing generated IDs. |

**Integration and manual verification**

Run clients that race revisions, disconnect after a mutation, close live containers without authorization, and inspect redacted metadata. Verify the full method inventory, not only creation.

**Evidence:** See [S023 automation resource evidence](../evidence/S023-automation-resources.md) for the method inventory, revision/idempotency/closure tests, review fixes, and pending live-client checks.

### S024 — Start sessions and submit authorized input {#s024}

- **Status:** Implemented — independently reviewed, 257 tests pass; live agent/SSH checks pending
- **Phase:** 4 — Scripts and agents
- **Depends on:** [S003](#s003), [S009](#s009), [S012](#s012), [S020](#s020), [S022](#s022), [S023](#s023)
- **Requirements:** `FR-A01`, `FR-A03`, `API-03`, `API-04`, `INT-06`

> As an authorized agent, I want to start approved sessions or explicitly execute work without depending on UI clicks.

**Acceptance criteria**

- [ ] **S024-AC01:** Implement session.start/restart/sendInput/execute and host.connect using separate capability checks; arbitrary processes/environment/directories require session.execute.
- [ ] **S024-AC02:** Allow exact literal text/base64 input or negotiated paste with a 64 KiB decoded limit, targeting a running session only.
- [ ] **S024-AC03:** session.execute requires submit:true and intentionally sends shell command text plus carriage return; success means submission, not command completion.
- [ ] **S024-AC04:** Never retry input/commands implicitly after transport failure. Dedicated processes expose actual process exit status; agent disconnect leaves sessions running and no API input triggers blocking UI dialogs.

**Named unit tests**

| Test | Setup, action, and expected result |
| --- | --- |
| `testS024_UT01_rejectUnapprovedLaunchDescriptor` | Use only session.start capability with arbitrary executable/environment changes; deny before spawning. |
| `testS024_UT02_validateInputEncodingAndLimit` | Supply both/neither encodings, invalid base64, and 65536/65537 decoded bytes; accept only valid payloads within the boundary. |
| `testS024_UT03_executeRequiresSubmit` | Omit submit or set false; reject with zero bytes; with true append exactly the specified submission carriage return. |
| `testS024_UT04_disconnectDoesNotReplayOrClose` | Disconnect after accepted input; retain the session and assert no automatic re-send, restart, or termination. |

**Integration and manual verification**

Run a dedicated fixture process with a known exit code and an interactive shell command separately; demonstrate their different completion semantics and permission denials.

**Evidence:** See [S024 session control evidence](../evidence/S024-automation-session-control.md) for launch-descriptor, input-limit, execute, disconnect, and host.connect tests, review fixes, and pending live checks.

### S025 — Read bounded output and subscribe to events {#s025}

- **Status:** Implemented — independently reviewed, 268 tests pass; multi-client manual checks pending
- **Phase:** 4 — Scripts and agents
- **Depends on:** [S013](#s013), [S021](#s021), [S022](#s022), [S023](#s023)
- **Requirements:** `FR-A05`, `API-05`, `NFR-P05`, `NFR-S06`

> As an authorized agent, I want to observe terminal and resource changes while detecting incomplete history.

**Acceptance criteria**

- [ ] **S025-AC01:** Provide plain-text screen/scrollback snapshots with capture timestamps and base64 raw stream deltas with per-session opaque cursors.
- [ ] **S025-AC02:** Use 64 KiB default/256 KiB maximum read responses, an 8 MiB global replay budget, truncation/gap metadata, and explicit invalid-cursor errors across sessions/restarts.
- [ ] **S025-AC03:** Publish ordered resource/selection/state/exit events with a 1,000-event metadata ring; raw output is separately bounded and requires output-read permission.
- [ ] **S025-AC04:** Redact by grant, signal replay gaps, and disconnect slow clients beyond a 1 MiB outbound queue; revocation immediately ends observation.

**Named unit tests**

| Test | Setup, action, and expected result |
| --- | --- |
| `testS025_UT01_cursorEvictionReportsGap` | Read from an evicted stream position; report gap and next cursor; foreign-session cursors return INVALID_CURSOR. |
| `testS025_UT02_readLimitsAndBinaryBoundaries` | Request default/max/over-limit output sizes with split UTF-8 bytes; bound responses and preserve exact raw stream bytes. |
| `testS025_UT03_metadataReplayGap` | Generate 1,001 metadata events; an evicted sequence gets an explicit gap and resnapshot instruction. |
| `testS025_UT04_slowOrRevokedSubscriberStops` | Exceed a fake client queue budget or revoke its grant; stop delivery without retaining unbounded output. |

**Integration and manual verification**

Flood a real terminal with output while a slow client subscribes. Verify responsive UI, bounded buffers, snapshot redaction, instance changes, and gap recovery.

**Evidence:** See [S025 output and events evidence](../evidence/S025-automation-output-events.md) for journal/cursor, ring/gap, slow-client, redaction, and end-to-end PTY tests, review fixes, and pending multi-client checks.

### S026 — Validate, plan, and apply declarative layouts {#s026}

- **Status:** Implemented — independently reviewed; live CLI apply-twice demo performed in S027
- **Phase:** 4 — Scripts and agents
- **Depends on:** [S002](#s002), [S010](#s010), [S023](#s023), [S024](#s024)
- **Requirements:** `FR-A04`, `API-03`, `API-04`, `NFR-S07`

> As a script author, I want to repeatably create a workspace from JSON without duplicating processes or rerunning commands.

**Acceptance criteria**

- [ ] **S026-AC01:** Validate the committed v1 schema plus unique keys, type consistency, maximum nesting/panes, host references, and safe absolute/home-prefixed paths; reject executable layout content.
- [ ] **S026-AC02:** Plan keyed namespace changes without mutation, return a base revision, and require it on apply; apply commits model changes atomically before independent optional launches.
- [ ] **S026-AC03:** Reapply by namespace/key with stable IDs; update order/ratios/names, retain omitted resources as unmanaged, and reject live descriptor changes or pane moves across tabs.
- [ ] **S026-AC04:** New panes default stopped; startNew starts only newly created panes with proper grants. Existing stopped panes are never automatically started by reapply; return launch outcomes per pane without rolling back already launched processes.

**Named unit tests**

| Test | Setup, action, and expected result |
| --- | --- |
| `testS026_UT01_exampleApplyTwiceIsStable` | Apply example-layout.json twice; mapping/IDs remain identical and the second application causes zero new launches. |
| `testS026_UT02_schemaAndSemanticFailuresAreAtomic` | Supply duplicate keys, excess depth/panes, unsafe paths, unknown hosts, or commands; reject without model/process effects. |
| `testS026_UT03_stalePlanAndLiveChangesConflict` | Race a plan revision or change a running launch descriptor; return CONFLICT without partial updates. |
| `testS026_UT04_partialLaunchFailureIsReported` | Commit two new panes and fail one launch; return both per-pane outcomes and retain a valid committed layout. |

**Integration and manual verification**

Use the supplied example through a real client; validate offline, inspect plan, apply with revision, and reapply after a client reconnect without rerunning work.

**Evidence:** See [S026 declarative layout evidence](../evidence/S026-declarative-layouts.md) for validation, plan/apply atomicity, stable reapply, conflict, and partial-launch tests, review fixes, and the pending live CLI demo.

### S027 — Ship a script-friendly trellis CLI {#s027}

- **Status:** Implemented — independently reviewed, 280 tests and a live CLI demo pass; Keychain/installed-CLI checks pending
- **Phase:** 4 — Scripts and agents
- **Depends on:** [S021](#s021), [S022](#s022), [S023](#s023), [S024](#s024), [S025](#s025), [S026](#s026)
- **Requirements:** `FR-A01`, `FR-A02`, `INT-06`, `API-06`, `MAC-10`

> As a script or agent author, I want to control all supported resources with structured results and predictable exit codes.

**Acceptance criteria**

- [ ] **S027-AC01:** Expose the v1 resource/session/layout/event commands and documented flags; resolve explicit UUIDs and reject ambiguous name conveniences.
- [ ] **S027-AC02:** Discover the running app and return unavailable unless --launch explicitly permits starting it; launching keeps normal native app behavior.
- [ ] **S027-AC03:** Obtain credentials via Keychain reference or stdin, never token arguments; --json writes the stable ok/result/error envelope to stdout and diagnostics to stderr without color.
- [ ] **S027-AC04:** Use exit statuses 0/2/3/4/5/6/7/8 as documented; keep submission success separate from process exit and never automatically retry execution after uncertain transport outcomes.

**Named unit tests**

| Test | Setup, action, and expected result |
| --- | --- |
| `testS027_UT01_parseAndRejectAmbiguousArguments` | Parse documented commands/flags and multiple matching names; produce a clear argument/ambiguity failure without a mutation. |
| `testS027_UT02_jsonAndExitCodeMapping` | Map each application/transport error class; assert exact CLI status, JSON shape, and clean stdout/stderr separation. |
| `testS027_UT03_launchOnlyWhenRequested` | Simulate absent discovery with/without --launch; call the app launcher only in the explicitly allowed case. |
| `testS027_UT04_credentialsNeverInArgumentsOrLogs` | Use distinctive stdin/Keychain test tokens; spy arguments, envelopes, and diagnostics contain no secret. |

**Integration and manual verification**

Run a shell script that creates two windows, tabs, mixed splits, starts a dedicated process, reads permitted output, and reapplies a layout. Document that no built-in AI runtime is required.

**Evidence:** See [S027 CLI evidence](../evidence/S027-cli.md) for parsing, exit-code, launch, and credential tests, the live demo, review fixes, and pending checks.

### S028 — Import and export layouts and saved hosts {#s028}

- **Status:** Implemented — independently reviewed, 284 tests pass; native export/import demo pending
- **Phase:** 4 — Scripts and agents
- **Depends on:** [S010](#s010), [S018](#s018), [S026](#s026)
- **Requirements:** `FR-R02`, `INT-09`, `NFR-S03`, `NFR-S07`

> As a terminal user, I want to move reusable configuration between installations without carrying secrets or executing work.

**Acceptance criteria**

- [ ] **S028-AC01:** Export versioned portable layout/host JSON excluding runtime IDs, buffers, transcripts, private keys, tokens, and runtime environment secrets.
- [ ] **S028-AC02:** Preview imported window/tab/pane/host counts, launch references, collisions, and unsupported versions before any mutation.
- [ ] **S028-AC03:** Interactive import creates fresh resource IDs and stopped panes; namespace-based API apply keeps its separate additive matching semantics.
- [ ] **S028-AC04:** Host imports commit atomically; overwrites require an explicit selected collision policy, never only a matching name/alias. Failed validation preserves existing configuration.

**Named unit tests**

| Test | Setup, action, and expected result |
| --- | --- |
| `testS028_UT01_exportOmitsSensitiveState` | Seed runtime IDs, output, environment secrets, and authentication fixtures; export contains only portable allowed fields. |
| `testS028_UT02_interactiveImportRemapsIds` | Import the same file twice; each interactive import gets fresh IDs and zero process launches. |
| `testS028_UT03_hostCollisionNeedsPolicy` | Import an alias/name collision without an override policy; preserve the existing host and require a decision. |
| `testS028_UT04_invalidImportIsAtomic` | Fail one record in a multi-host/layout document; no subset is installed and unsupported versions are not rewritten. |

**Integration and manual verification**

Export from one clean test profile and import into another. Preview the summary, cancel once, then confirm and compare safe configuration fields.

**Evidence:** See [S028 portable transfer evidence](../evidence/S028-portable-import-export.md) for export redaction, fresh-ID import, collision-policy, and atomicity tests, review fixes, and the pending native demo.

### S029 — Control themes and appearance from scripts {#s029}

- **Status:** Implemented — independently reviewed, 289 tests pass; installed-CLI live check pending
- **Phase:** 4 — Scripts and agents
- **Depends on:** [S016](#s016), [S021](#s021), [S022](#s022), [S027](#s027)
- **Requirements:** `FR-TH08`, `INT-10`, `API-03`, `API-04`

> As an authorized script author, I want to install a JSON theme and select application appearance programmatically.

**Acceptance criteria**

- [ ] **S029-AC01:** Implement theme.list/get/validate/import/export/delete and appearance.get/set with their documented results and appearance.changed events.
- [ ] **S029-AC02:** Enforce theme.read and explicitly global theme.write permissions; layout-only or window-scoped grants cannot change global appearance.
- [ ] **S029-AC03:** Use the same validators, replacement rules, built-in protection, revision checks, and idempotency as UI theme operations.
- [ ] **S029-AC04:** Expose equivalent CLI commands, reject mismatched light/dark theme slots, preserve dark terminal defaults with light chrome, and never start/restart sessions during theme changes.

**Named unit tests**

| Test | Setup, action, and expected result |
| --- | --- |
| `testS029_UT01_themePermissionMatrix` | Call each theme/appearance method with read-only, layout-only, window-scoped, and global-write grants; enforce the documented boundary. |
| `testS029_UT02_rejectWrongAppearanceSlot` | Assign a dark theme ID to the light slot; return an error and preserve all appearance settings. |
| `testS029_UT03_protectBuiltInsAndRevision` | Replace/delete built-ins or submit a stale appearance revision; fail atomically with the specified error. |
| `testS029_UT04_appearanceEventHasNoProcessEffects` | Apply a theme once with a keyed retry; emit only committed appearance changes and make zero session lifecycle/input calls. |

**Integration and manual verification**

Use CLI commands to validate/import/export a custom theme and switch chrome modes while local/SSH sessions continue running. Confirm denied clients cannot mutate the palette.

**Evidence:** See [S029 theme control evidence](../evidence/S029-theme-control-api.md) for permission, slot, built-in/revision, and no-process-effect tests, review fixes, and the pending live check.

### S030 — Protect terminal interactions and private diagnostics {#s030}

- **Status:** Implemented — independently reviewed (engine patch), 295 tests pass; native link/clipboard/diagnostics checks pending
- **Phase:** 5 — Qualification and distribution
- **Depends on:** [S003](#s003), [S011](#s011), [S012](#s012), [S022](#s022), [S025](#s025)
- **Requirements:** `NFR-S03`, `NFR-S05`, `NFR-S08`, `NFR-S09`, `NFR-U05`, `INT-08`

> As a terminal user, I want to use untrusted terminal output without exposing clipboard data, credentials, or private history.

**Acceptance criteria**

- [ ] **S030-AC01:** Disable terminal-originated clipboard read/write requests including OSC 52 by default; v1 agents have no clipboard capability.
- [ ] **S030-AC02:** Open links only after a user gesture and only for http/https/mailto; reject unsafe/custom schemes and never treat output as trusted control instructions.
- [ ] **S030-AC03:** Keep logs/errors free of tokens, typed input, terminal output, passwords, and key contents; diagnostics export is explicit and previewable.
- [ ] **S030-AC04:** Collect no telemetry or clipboard history by default; denied paths/capabilities produce actionable sanitized errors rather than blanket permission requests.

**Named unit tests**

| Test | Setup, action, and expected result |
| --- | --- |
| `testS030_UT01_osc52CannotReadOrWriteClipboard` | Feed clipboard escape sequences through the adapter; pasteboard spy receives no reads or writes. |
| `testS030_UT02_validateUrlAndGesture` | Try allowed schemes with/without a gesture and forbidden file/javascript/custom URLs; open only valid user-initiated links. |
| `testS030_UT03_sanitizeErrorsAndDiagnostics` | Inject recognizable secrets and terminal data into failures; public errors/logs/export previews omit them. |
| `testS030_UT04_diagnosticCancelCreatesNoExport` | Cancel diagnostic preview; create no exported file or network request. |

**Integration and manual verification**

Feed hostile terminal escape/link fixtures in a controlled session; inspect NSPasteboard, logs, error UI, and network activity. Review parser-boundary fuzz results without executing untrusted commands.

**Evidence:** See [S030 terminal security evidence](../evidence/S030-terminal-security.md) for clipboard, link, Kitty-file, redaction, and diagnostics tests, review fixes, and pending native checks.

### S031 — Qualify capacity, responsiveness, and lifecycle reliability {#s031}

- **Status:** Blocked — qualification run complete; NFR-P07 flood throughput misses (5–7.6 of 10 MiB/s); UI-frame latency not certified
- **Phase:** 5 — Qualification and distribution
- **Depends on:** [S008](#s008), [S009](#s009), [S010](#s010), [S013](#s013), [S017](#s017), [S020](#s020), [S025](#s025), [S026](#s026), [S029](#s029), [S030](#s030)
- **Requirements:** `NFR-P01`, `NFR-P02`, `NFR-P03`, `NFR-P04`, `NFR-P05`, `NFR-P06`, `NFR-P07`, `NFR-R01`, `NFR-R04`, `NFR-R06`

> As a daily terminal user, I want to keep many sessions open without slow navigation, memory growth, or lost state.

**Acceptance criteria**

- [ ] **S031-AC01:** Publish reproducible release-build measurements with hardware, OS, engine version, and workload: cold launch ≤2 s p95, typing echo ≤50 ms p95, switching ≤100 ms p95 at 50 live panes.
- [ ] **S031-AC02:** Exercise 10 windows/50 tabs/100 sessions; verify model, focus, and cleanup, plus 100 create/close cycles without retained PTYs, unreaped children, or growing descriptors.
- [ ] **S031-AC03:** Measure app memory ≤300 MiB and idle CPU <2% of one core with 10 idle panes; report child-process memory separately and document workload conditions.
- [ ] **S031-AC04:** Flood 10 MiB/s for 60 s with bounded queues/scrollback/replay and responsive navigation; fuzz protocol/tree/import boundaries and record failures rather than claiming unmeasured passes.

**Named unit tests**

| Test | Setup, action, and expected result |
| --- | --- |
| `testS031_UT01_randomizedTreeOperationsKeepInvariants` | Generate seeded split/close/reorder sequences; after each operation verify valid ownership, binary topology, and unique stable IDs. |
| `testS031_UT02_queuesRespectAllBudgets` | Drive fake high-output producers and stalled consumers; assert configured byte/line/event limits and explicit eviction/gaps. |
| `testS031_UT03_repeatedCleanupReturnsToBaseline` | Run 100 fake lifecycle cycles including failures; resource registry and pending effects return to baseline. |
| `testS031_UT04_measurementSummaryCalculatesP95` | Use known timing samples; compute reproducible p95 and report insufficient samples instead of a misleading result. |

**Integration and manual verification**

Run real performance and descriptor/process measurements outside the debugger on the reference matrix. Attach results and remediation for misses; unit tests alone cannot certify performance.

**Evidence:** See [S031 qualification evidence](../evidence/S031-qualification.md) and the generated [results](../evidence/S031-qualification-results.md). Blocker: flood throughput below 10 MiB/s, with a remediation plan; typing/switching are API proxies, not UI-frame measurements.

### S032 — Package and qualify the macOS-only release {#s032}

- **Status:** Blocked for release — tooling, Universal 2 packaging, CLI link, docs, and release gate done (309 tests); Developer ID notarization/Gatekeeper and matrix pending
- **Phase:** 5 — Qualification and distribution
- **Depends on:** [S017](#s017), [S020](#s020), [S027](#s027), [S028](#s028), [S029](#s029), [S030](#s030), [S031](#s031)
- **Requirements:** `MAC-01`, `MAC-02`, `MAC-03`, `MAC-08`, `MAC-09`, `MAC-10`, `MAC-11`, `MAC-12`

> As a macOS user, I want to install, upgrade, and remove a trusted native app with a usable CLI.

**Acceptance criteria**

- [ ] **S032-AC01:** Resolve app identity, confirmed minimum macOS, CPU support, package format, and terminal dependency/license decisions; publish the actual tested OS/architecture matrix.
- [ ] **S032-AC02:** Sign app and bundled CLI, use compatible hardened runtime, notarize/staple as appropriate, and verify Gatekeeper on a clean machine; no root helper or blanket privacy prompts.
- [ ] **S032-AC03:** Provide an explicit user-local CLI-link installation step without silent shell-file/system-directory edits; manual signed upgrades are acceptable for MVP.
- [ ] **S032-AC04:** Document backup/migration/downgrade behavior, known limits, and uninstall cleanup for app-owned files/Keychain entries while protecting SSH config/keys/history. All P0 acceptance evidence is complete before release.

**Scope notes**

Packaging checks must verify current Apple tooling during implementation. Do not add an automatic update service in this MVP story.

**Named unit tests**

| Test | Setup, action, and expected result |
| --- | --- |
| `testS032_UT01_manifestMatchesSupportPolicy` | Validate release metadata/build manifest against selected minimum OS, supported architectures, and required app/CLI artifacts. |
| `testS032_UT02_cliLinkPlanIsUserLocal` | Plan CLI installation/removal with fixture home directories; reject paths outside the chosen user-local target and preserve unrelated existing files. |
| `testS032_UT03_cleanupAllowlistProtectsUserFiles` | Generate uninstall cleanup for fixtures; never include SSH directories, keys, known-hosts files, or shell history. |
| `testS032_UT04_releaseChecklistRejectsMissingEvidence` | Provide incomplete matrix/signing/license evidence to the release-checklist validator; report each missing item rather than marking release ready. |

**Integration and manual verification**

Perform real signature/notarization/Gatekeeper checks, install/upgrade/uninstall on clean test profiles, test the bundled CLI, and execute the end-to-end daily-use scenario. Unit tests do not replace Apple distribution verification.

**Evidence:** See [S032 packaging evidence](../evidence/S032-packaging-release.md) and the [release guide](../release/README.md). Blocked: Developer ID signing/notarization/clean-machine Gatekeeper, the macOS 14/15 and native Intel matrix, and outstanding P0 evidence (S031 and pending native checks).
