# Implementation stories and delivery plan

Status: implementation started. Date: 2026-10-16. Story progress and verification gaps are tracked below; planned test cases are not automatically passing tests.

This folder contains **32 P0 stories**, one Markdown file per story, derived from the [specification index](../README.md). Each file defines acceptance criteria, four concrete unit-test cases, integration/manual verification, dependencies, and completion evidence.

## Execution workflow and progress

Implement stories in order. For each story: implement, run the relevant checks, launch a separate review agent, resolve actionable findings, rerun affected checks, record evidence, and commit the reviewed change before beginning the next story. Keep each story's changes isolated in Git history. Never mark unperformed platform checks passed.

| Item | State | Evidence |
| --- | --- | --- |
| Specification baseline | Committed | `ee471f6` |
| S001 (`f8ecff0`) | Implemented and reviewed; manual feasibility checks pending | [S001 evidence](../../docs/evidence/S001-terminal-feasibility.md) |
| S002 | Done — reviewed and fixed; full 30-test suite passing | [S002 evidence](../../docs/evidence/S002-workspace-model.md) |
| S003 | Done — independent review/fixes; 43-test suite passing | [S003 evidence](../../docs/evidence/S003-local-sessions.md) |
| S004 | Implemented/reviewed — 55 tests pass; native lifecycle/display checks pending | [S004 evidence](../../docs/evidence/S004-native-shell.md) |
| S005 | Implemented with review fixes — 64 tests pass; native interaction qualification pending | [S005 evidence](../../docs/evidence/S005-managed-windows.md) |
| S006 | Implemented/reviewed — 72 tests and native tab checks pass | [S006 evidence](../../docs/evidence/S006-tabs.md) |
| S007–S032 | Planned | Stories below |

On 2026-10-16 the user explicitly directed continuing to the next stories after successful app launch. Continue implementation and per-story review/commits while retaining S001’s unperformed interaction checks as outstanding qualification; this instruction does not establish that VoiceOver/IME or the older-OS runtime matrix passed.

## Agreed product direction

- Native Swift application for macOS; provisional macOS 14+ and Apple silicon/Intel support, confirmed by the feasibility/release gates.
- **Native calm:** managed windows in the left sidebar; each window has its own top tab bar with multiple tabs, visible separators, a new-tab button, and inline renaming.
- **Light application chrome by default, dark terminal backgrounds, and Monaco** as the default terminal font. Light/Dark/System settings and user-authored JSON themes remain available.
- Tabs contain nested left/right and top/bottom terminal splits. Sessions continue while inactive; relaunch restores a stopped layout and never replays typed commands.
- Saved SSH hosts and a local CLI/API support user-approved scripts and agents. There is one native terminal-bearing application window in MVP.

## How to use this plan

Work by dependency order within the phases below. Story numbers are stable identifiers, not dates or estimates. Dependencies refer to other story files; later-numbered dependencies are not required. A story may use a fake boundary while another feature is pending, but its final platform verification still needs a working implementation.

Stories begin as Planned. During implementation update their status to In progress, Blocked (with a concrete reason), or Done, and link the relevant implementation/check results. Acceptance checkboxes remain unchecked until observed. The specifications remain the behavior contract; resolve any discovered ambiguity in both the specification and affected story rather than inventing a conflicting behavior.

Build the first runnable milestone from S001–S004: native host, domain store, and one real shell. Subsequent phase exit gates are listed below. No dates are assigned because team capacity and terminal-engine results are not known.

## Phase 1 — Foundation and terminal feasibility

S001 is the terminal go/no-go gate. S002 can establish pure domain invariants independently. Complete the adapter/process spike before committing to the terminal implementation.

| Story | Dependencies |
| --- | --- |
| [S001 — Validate the native terminal engine](001-terminal-engine-feasibility.md) | None |
| [S002 — Create the authoritative workspace model](002-domain-model-and-command-service.md) | None |
| [S003 — Launch and operate local PTY sessions](003-local-pty-session.md) | [S001](001-terminal-engine-feasibility.md), [S002](002-domain-model-and-command-service.md) |

**Exit gate:** A real local PTY runs in a native host, lifecycle ownership is clear, engine accessibility/IME feasibility is recorded, and the domain model enforces its invariants.

## Phase 2 — Native organization and session safety

Build the light Native calm shell, window sidebar, per-window tabs with inline renaming, mixed-axis splits, and safe stopped restoration. Do not ship live close actions until the shared closure policy is wired.

| Story | Dependencies |
| --- | --- |
| [S004 — Build the Native calm application shell](004-native-application-shell.md) | [S001](001-terminal-engine-feasibility.md), [S002](002-domain-model-and-command-service.md) |
| [S005 — Manage windows from the sidebar](005-managed-window-sidebar.md) | [S002](002-domain-model-and-command-service.md), [S004](004-native-application-shell.md) |
| [S006 — Manage multiple renameable tabs per window](006-tabs-and-inline-renaming.md) | [S002](002-domain-model-and-command-service.md), [S004](004-native-application-shell.md), [S005](005-managed-window-sidebar.md) |
| [S007 — Create and close nested terminal splits](007-nested-split-tree.md) | [S002](002-domain-model-and-command-service.md), [S003](003-local-pty-session.md), [S006](006-tabs-and-inline-renaming.md) |
| [S008 — Resize, focus, and maximize panes](008-pane-resize-focus-and-maximize.md) | [S004](004-native-application-shell.md), [S007](007-nested-split-tree.md) |
| [S009 — Close and restart sessions safely](009-safe-session-close-and-restart.md) | [S003](003-local-pty-session.md), [S005](005-managed-window-sidebar.md), [S006](006-tabs-and-inline-renaming.md), [S007](007-nested-split-tree.md) |
| [S010 — Persist workspaces and restore stopped sessions](010-persistence-and-stopped-restore.md) | [S002](002-domain-model-and-command-service.md), [S005](005-managed-window-sidebar.md), [S006](006-tabs-and-inline-renaming.md), [S007](007-nested-split-tree.md), [S009](009-safe-session-close-and-restart.md) |

**Exit gate:** Create two windows with independent tabs, rename and reorder them, use mixed splits, close safely, and restore the same organization as stopped sessions.

## Phase 3 — Everyday terminal use

Deliver copy/paste, search, Monaco/dark terminal defaults, JSON themes, keyboard/accessibility, saved hosts, and controlled SSH connections. Validate actual terminal behavior as these land.

| Story | Dependencies |
| --- | --- |
| [S011 — Select and copy terminal text naturally](011-selection-and-copy.md) | [S001](001-terminal-engine-feasibility.md), [S003](003-local-pty-session.md), [S004](004-native-application-shell.md) |
| [S012 — Paste text and file paths safely](012-safe-paste-and-file-paths.md) | [S003](003-local-pty-session.md), [S008](008-pane-resize-focus-and-maximize.md), [S011](011-selection-and-copy.md) |
| [S013 — Retain bounded output and search a pane](013-scrollback-and-search.md) | [S001](001-terminal-engine-feasibility.md), [S003](003-local-pty-session.md) |
| [S014 — Apply light chrome and dark Monaco terminals](014-appearance-and-monaco-defaults.md) | [S001](001-terminal-engine-feasibility.md), [S004](004-native-application-shell.md) |
| [S015 — Define and validate simple JSON themes](015-json-theme-format.md) | [S014](014-appearance-and-monaco-defaults.md) |
| [S016 — Import, preview, and maintain custom themes](016-theme-library-and-preview.md) | [S010](010-persistence-and-stopped-restore.md), [S015](015-json-theme-format.md) |
| [S017 — Support keyboard navigation and native accessibility](017-keyboard-and-accessibility.md) | [S004](004-native-application-shell.md), [S006](006-tabs-and-inline-renaming.md), [S008](008-pane-resize-focus-and-maximize.md), [S011](011-selection-and-copy.md), [S012](012-safe-paste-and-file-paths.md), [S014](014-appearance-and-monaco-defaults.md) |
| [S018 — Maintain a searchable saved-host library](018-saved-host-library.md) | [S002](002-domain-model-and-command-service.md), [S004](004-native-application-shell.md), [S010](010-persistence-and-stopped-restore.md) |
| [S019 — Discover SSH aliases without changing SSH configuration](019-ssh-config-alias-discovery.md) | [S018](018-saved-host-library.md) |
| [S020 — Open SSH sessions in tabs or splits](020-ssh-connections.md) | [S003](003-local-pty-session.md), [S007](007-nested-split-tree.md), [S009](009-safe-session-close-and-restart.md), [S018](018-saved-host-library.md), [S019](019-ssh-config-alias-discovery.md) |

**Exit gate:** Complete the keyboard/copy/paste/search/theme workflows, edit and reload a JSON theme, connect to a controlled SSH host, and record the VoiceOver/input matrix.

## Phase 4 — Scripts and agents

Deliver the local authenticated control plane, scoped grants, command methods, output/events, keyed layouts, CLI, portable configuration, and theme automation. No unauthenticated domain endpoint is enabled as an intermediate feature.

| Story | Dependencies |
| --- | --- |
| [S021 — Expose a bounded local JSON-RPC control socket](021-local-control-socket.md) | [S002](002-domain-model-and-command-service.md), [S004](004-native-application-shell.md) |
| [S022 — Authorize scoped script and agent access](022-automation-grants.md) | [S010](010-persistence-and-stopped-restore.md), [S018](018-saved-host-library.md), [S021](021-local-control-socket.md) |
| [S023 — Expose resource commands with revisions and idempotency](023-automation-resource-commands.md) | [S005](005-managed-window-sidebar.md), [S006](006-tabs-and-inline-renaming.md), [S007](007-nested-split-tree.md), [S008](008-pane-resize-focus-and-maximize.md), [S009](009-safe-session-close-and-restart.md), [S018](018-saved-host-library.md), [S021](021-local-control-socket.md), [S022](022-automation-grants.md) |
| [S024 — Start sessions and submit authorized input](024-automation-session-control.md) | [S003](003-local-pty-session.md), [S009](009-safe-session-close-and-restart.md), [S012](012-safe-paste-and-file-paths.md), [S020](020-ssh-connections.md), [S022](022-automation-grants.md), [S023](023-automation-resource-commands.md) |
| [S025 — Read bounded output and subscribe to events](025-automation-output-and-events.md) | [S013](013-scrollback-and-search.md), [S021](021-local-control-socket.md), [S022](022-automation-grants.md), [S023](023-automation-resource-commands.md) |
| [S026 — Validate, plan, and apply declarative layouts](026-declarative-layout-automation.md) | [S002](002-domain-model-and-command-service.md), [S010](010-persistence-and-stopped-restore.md), [S023](023-automation-resource-commands.md), [S024](024-automation-session-control.md) |
| [S027 — Ship a script-friendly uterm CLI](027-cli-and-agent-workflows.md) | [S021](021-local-control-socket.md), [S022](022-automation-grants.md), [S023](023-automation-resource-commands.md), [S024](024-automation-session-control.md), [S025](025-automation-output-and-events.md), [S026](026-declarative-layout-automation.md) |
| [S028 — Import and export layouts and saved hosts](028-portable-import-and-export.md) | [S010](010-persistence-and-stopped-restore.md), [S018](018-saved-host-library.md), [S026](026-declarative-layout-automation.md) |
| [S029 — Control themes and appearance from scripts](029-theme-control-api.md) | [S016](016-theme-library-and-preview.md), [S021](021-local-control-socket.md), [S022](022-automation-grants.md), [S027](027-cli-and-agent-workflows.md) |

**Exit gate:** A scoped client can apply a layout twice without duplication, explicitly start work, read permitted output, observe events, and use the CLI; denied/revoked clients cannot bypass authorization.

## Phase 5 — Qualification and distribution

Complete terminal security/privacy verification, stress and responsiveness evidence, and the signed/notarized macOS release with install/upgrade/uninstall validation.

| Story | Dependencies |
| --- | --- |
| [S030 — Protect terminal interactions and private diagnostics](030-terminal-security-and-diagnostics.md) | [S003](003-local-pty-session.md), [S011](011-selection-and-copy.md), [S012](012-safe-paste-and-file-paths.md), [S022](022-automation-grants.md), [S025](025-automation-output-and-events.md) |
| [S031 — Qualify capacity, responsiveness, and lifecycle reliability](031-performance-and-reliability-qualification.md) | [S008](008-pane-resize-focus-and-maximize.md), [S009](009-safe-session-close-and-restart.md), [S010](010-persistence-and-stopped-restore.md), [S013](013-scrollback-and-search.md), [S017](017-keyboard-and-accessibility.md), [S020](020-ssh-connections.md), [S025](025-automation-output-and-events.md), [S026](026-declarative-layout-automation.md), [S029](029-theme-control-api.md), [S030](030-terminal-security-and-diagnostics.md) |
| [S032 — Package and qualify the macOS-only release](032-macos-packaging-and-release.md) | [S017](017-keyboard-and-accessibility.md), [S020](020-ssh-connections.md), [S027](027-cli-and-agent-workflows.md), [S028](028-portable-import-and-export.md), [S029](029-theme-control-api.md), [S030](030-terminal-security-and-diagnostics.md), [S031](031-performance-and-reliability-qualification.md) |

**Exit gate:** Every P0 acceptance criterion has evidence, performance/reliability checks meet the agreed budgets, and install/signing/notarization/upgrade/uninstall pass on the supported matrix.

## Test strategy

- **Unit tests:** implement the 128 named cases in the story files against domain behavior, validators, state projections, and adapters. Use injected clocks/IDs and temporary app-owned fixtures; fake process/clipboard/Keychain/transport boundaries where needed. The cases specify behavior rather than prescribe a particular Swift testing framework.
- **Integration tests:** exercise real PTYs, process groups, filesystem atomicity, Unix sockets, Keychain, and a controlled local SSH server. Never aim development tests at existing user sessions or production hosts.
- **UI/manual checks:** verify native responder behavior, multiple-tab renaming, clipboard review, actual Monaco rendering, VoiceOver, IME/dead keys, displays, and macOS packaging. These checks are explicitly separated from unit tests.
- **Performance checks:** use release builds, documented reference hardware, repeatable loads, and the budgets in the quality specification. Never treat a fake transport test as proof of real latency or memory usage.
- **Contract fixtures:** reuse [layout schema](../05-api/layout.schema.json), [layout example](../05-api/example-layout.json), [theme schema](../03-functional-requirements/themes/theme.schema.json), and [dark](../03-functional-requirements/themes/example-dark.theme.json)/[light](../03-functional-requirements/themes/example-light.theme.json) theme examples. Add negative fixtures for boundaries and rejection paths.
- **Completion:** run appropriate implemented tests, demonstrate each acceptance criterion, and retain relevant evidence. Missing hardware/platform access stays an explicit verification gap; do not mark it passed.

## Requirements traceability

Every P0 requirement ID is mapped below. Architecture and overview decisions without individual IDs are also described in the relevant stories. P1/P2 items are deferred after the table.

| Requirement | Stories |
| --- | --- |
| `API-01` | [S021](021-local-control-socket.md) |
| `API-02` | [S022](022-automation-grants.md) |
| `API-03` | [S002](002-domain-model-and-command-service.md), [S023](023-automation-resource-commands.md), [S024](024-automation-session-control.md), [S026](026-declarative-layout-automation.md), [S029](029-theme-control-api.md) |
| `API-04` | [S023](023-automation-resource-commands.md), [S024](024-automation-session-control.md), [S026](026-declarative-layout-automation.md), [S029](029-theme-control-api.md) |
| `API-05` | [S025](025-automation-output-and-events.md) |
| `API-06` | [S021](021-local-control-socket.md), [S023](023-automation-resource-commands.md), [S027](027-cli-and-agent-workflows.md) |
| `FR-A01` | [S023](023-automation-resource-commands.md), [S024](024-automation-session-control.md), [S027](027-cli-and-agent-workflows.md) |
| `FR-A02` | [S002](002-domain-model-and-command-service.md), [S023](023-automation-resource-commands.md), [S027](027-cli-and-agent-workflows.md) |
| `FR-A03` | [S022](022-automation-grants.md), [S024](024-automation-session-control.md) |
| `FR-A04` | [S026](026-declarative-layout-automation.md) |
| `FR-A05` | [S025](025-automation-output-and-events.md) |
| `FR-C01` | [S011](011-selection-and-copy.md) |
| `FR-C02` | [S011](011-selection-and-copy.md) |
| `FR-C03` | [S012](012-safe-paste-and-file-paths.md) |
| `FR-C04` | [S012](012-safe-paste-and-file-paths.md) |
| `FR-C05` | [S012](012-safe-paste-and-file-paths.md) |
| `FR-H01` | [S018](018-saved-host-library.md) |
| `FR-H02` | [S020](020-ssh-connections.md) |
| `FR-H03` | [S019](019-ssh-config-alias-discovery.md) |
| `FR-H04` | [S020](020-ssh-connections.md) |
| `FR-H05` | [S020](020-ssh-connections.md) |
| `FR-P01` | [S007](007-nested-split-tree.md) |
| `FR-P02` | [S008](008-pane-resize-focus-and-maximize.md) |
| `FR-P03` | [S007](007-nested-split-tree.md) |
| `FR-P04` | [S008](008-pane-resize-focus-and-maximize.md) |
| `FR-R01` | [S010](010-persistence-and-stopped-restore.md) |
| `FR-R02` | [S028](028-portable-import-and-export.md) |
| `FR-S01` | [S003](003-local-pty-session.md) |
| `FR-S02` | [S001](001-terminal-engine-feasibility.md) |
| `FR-S03` | [S003](003-local-pty-session.md), [S009](009-safe-session-close-and-restart.md) |
| `FR-S04` | [S013](013-scrollback-and-search.md) |
| `FR-S05` | [S003](003-local-pty-session.md) |
| `FR-T01` | [S006](006-tabs-and-inline-renaming.md) |
| `FR-T02` | [S006](006-tabs-and-inline-renaming.md) |
| `FR-T03` | [S006](006-tabs-and-inline-renaming.md), [S007](007-nested-split-tree.md), [S009](009-safe-session-close-and-restart.md) |
| `FR-TH01` | [S014](014-appearance-and-monaco-defaults.md) |
| `FR-TH02` | [S015](015-json-theme-format.md) |
| `FR-TH03` | [S016](016-theme-library-and-preview.md) |
| `FR-TH04` | [S015](015-json-theme-format.md), [S016](016-theme-library-and-preview.md) |
| `FR-TH05` | [S014](014-appearance-and-monaco-defaults.md), [S016](016-theme-library-and-preview.md) |
| `FR-TH06` | [S014](014-appearance-and-monaco-defaults.md), [S015](015-json-theme-format.md) |
| `FR-TH07` | [S015](015-json-theme-format.md) |
| `FR-TH08` | [S029](029-theme-control-api.md) |
| `FR-U01` | [S017](017-keyboard-and-accessibility.md) |
| `FR-U02` | [S014](014-appearance-and-monaco-defaults.md) |
| `FR-W01` | [S005](005-managed-window-sidebar.md) |
| `FR-W02` | [S005](005-managed-window-sidebar.md) |
| `FR-W03` | [S005](005-managed-window-sidebar.md), [S006](006-tabs-and-inline-renaming.md) |
| `FR-W04` | [S004](004-native-application-shell.md), [S005](005-managed-window-sidebar.md) |
| `INT-01` | [S003](003-local-pty-session.md) |
| `INT-03` | [S018](018-saved-host-library.md), [S020](020-ssh-connections.md) |
| `INT-04` | [S019](019-ssh-config-alias-discovery.md) |
| `INT-05` | [S020](020-ssh-connections.md) |
| `INT-06` | [S024](024-automation-session-control.md), [S027](027-cli-and-agent-workflows.md) |
| `INT-08` | [S011](011-selection-and-copy.md), [S012](012-safe-paste-and-file-paths.md), [S030](030-terminal-security-and-diagnostics.md) |
| `INT-09` | [S028](028-portable-import-and-export.md) |
| `INT-10` | [S015](015-json-theme-format.md), [S016](016-theme-library-and-preview.md), [S029](029-theme-control-api.md) |
| `MAC-01` | [S001](001-terminal-engine-feasibility.md), [S032](032-macos-packaging-and-release.md) |
| `MAC-02` | [S001](001-terminal-engine-feasibility.md), [S032](032-macos-packaging-and-release.md) |
| `MAC-03` | [S001](001-terminal-engine-feasibility.md), [S004](004-native-application-shell.md), [S032](032-macos-packaging-and-release.md) |
| `MAC-04` | [S004](004-native-application-shell.md), [S009](009-safe-session-close-and-restart.md) |
| `MAC-05` | [S004](004-native-application-shell.md) |
| `MAC-06` | [S004](004-native-application-shell.md), [S008](008-pane-resize-focus-and-maximize.md) |
| `MAC-07` | [S011](011-selection-and-copy.md), [S014](014-appearance-and-monaco-defaults.md), [S017](017-keyboard-and-accessibility.md) |
| `MAC-08` | [S003](003-local-pty-session.md), [S032](032-macos-packaging-and-release.md) |
| `MAC-09` | [S032](032-macos-packaging-and-release.md) |
| `MAC-10` | [S027](027-cli-and-agent-workflows.md), [S032](032-macos-packaging-and-release.md) |
| `MAC-11` | [S010](010-persistence-and-stopped-restore.md), [S032](032-macos-packaging-and-release.md) |
| `MAC-12` | [S018](018-saved-host-library.md), [S032](032-macos-packaging-and-release.md) |
| `NFR-P01` | [S031](031-performance-and-reliability-qualification.md) |
| `NFR-P02` | [S031](031-performance-and-reliability-qualification.md) |
| `NFR-P03` | [S031](031-performance-and-reliability-qualification.md) |
| `NFR-P04` | [S031](031-performance-and-reliability-qualification.md) |
| `NFR-P05` | [S013](013-scrollback-and-search.md), [S025](025-automation-output-and-events.md), [S031](031-performance-and-reliability-qualification.md) |
| `NFR-P06` | [S031](031-performance-and-reliability-qualification.md) |
| `NFR-P07` | [S031](031-performance-and-reliability-qualification.md) |
| `NFR-R01` | [S009](009-safe-session-close-and-restart.md), [S031](031-performance-and-reliability-qualification.md) |
| `NFR-R02` | [S010](010-persistence-and-stopped-restore.md) |
| `NFR-R03` | [S002](002-domain-model-and-command-service.md) |
| `NFR-R04` | [S021](021-local-control-socket.md), [S031](031-performance-and-reliability-qualification.md) |
| `NFR-R05` | [S010](010-persistence-and-stopped-restore.md) |
| `NFR-R06` | [S013](013-scrollback-and-search.md), [S031](031-performance-and-reliability-qualification.md) |
| `NFR-S01` | [S021](021-local-control-socket.md), [S022](022-automation-grants.md) |
| `NFR-S02` | [S022](022-automation-grants.md) |
| `NFR-S03` | [S018](018-saved-host-library.md), [S028](028-portable-import-and-export.md), [S030](030-terminal-security-and-diagnostics.md) |
| `NFR-S04` | [S020](020-ssh-connections.md) |
| `NFR-S05` | [S030](030-terminal-security-and-diagnostics.md) |
| `NFR-S06` | [S022](022-automation-grants.md), [S025](025-automation-output-and-events.md) |
| `NFR-S07` | [S026](026-declarative-layout-automation.md), [S028](028-portable-import-and-export.md) |
| `NFR-S08` | [S003](003-local-pty-session.md), [S022](022-automation-grants.md), [S030](030-terminal-security-and-diagnostics.md) |
| `NFR-S09` | [S030](030-terminal-security-and-diagnostics.md) |
| `NFR-U01` | [S008](008-pane-resize-focus-and-maximize.md), [S017](017-keyboard-and-accessibility.md) |
| `NFR-U02` | [S001](001-terminal-engine-feasibility.md), [S017](017-keyboard-and-accessibility.md) |
| `NFR-U03` | [S017](017-keyboard-and-accessibility.md) |
| `NFR-U04` | [S017](017-keyboard-and-accessibility.md) |
| `NFR-U05` | [S030](030-terminal-security-and-diagnostics.md) |

## Deferred scope

P1/P2 work is outside this MVP execution plan: multiple native windows and moving tabs across them (MAC-13), multiple profiles, structured shell integration (INT-02), richer SSH config import, an MCP adapter (INT-07), automatic signed updates, process continuity through an application-independent broker, tmux awareness, richer terminal protocols, and plugins. Create separate stories before starting those features; do not hide them inside the P0 stories.

## Decisions and implementation risks

- S001 confirms the terminal engine, TERM/terminfo choice, PTY ownership, minimum OS, and CPU feasibility; blockers must be resolved before dependent work proceeds.
- S022 must settle the scoped-grant settings UX while preserving the specified capability/revocation boundary.
- S008/S004 verify minimum terminal canvas behavior and focus across real displays; the conversation preview is a style reference, not an implemented terminal.
- S015/S016 confirm engine palette override behavior and contrast under both chrome appearances. Partial custom themes inherit shipped defaults.
- S032 resolves release identity, package format, signing credentials, and the actual supported OS/CPU evidence. Apple distribution commands need current verification during implementation.

## End-to-end release scenario

Create Project and Operations windows with independent tabs. Rename a tab inline, create nested x/y splits, run local commands, copy a selection, and review a multiline paste. Keep chrome light, terminals dark, and Monaco active; import/reload a custom JSON theme. Connect to a controlled saved SSH host. Use the CLI with an approved grant to discover IDs, apply the example layout twice, explicitly start a process, observe its exit and permitted output, and verify a layout-only grant cannot read or execute. Revoke the grant. Quit with one running-session summary, relaunch, and verify all saved layouts return stopped without input replay.
