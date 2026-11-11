# Implementation plan (draft)

!!! warning "Draft — for review with the contract"
    How the [protocol 2 contract](index.md) gets built. Phases and estimates change as each phase's review lands.

## Strategy: build beside v1, switch once

Protocol 2 is a clean break for users, but `develop` must stay releasable between PRs. So:

- **v2 grows next to v1.** `ControlSession` dispatches by the negotiated version. Until the switch, `protocolVersion: 2` is accepted only when the app runs with `--automation-v2` (development builds and tests); release builds keep answering `UNSUPPORTED_VERSION` for 2. v1 code isn't touched except to share helpers.
- **One method catalog drives everything.** Each v2 method is declared once (name, parameter schema, result type, capabilities and conditional rules, scope rule, mutating/destructive flags, error codes). Authorization, MCP tool schemas and annotations, CLI help and the contract tests are generated from it, which is what prevents v1's schema drift.
- **The domain adapter is split by area.** `AutomationService.swift` (1,135 lines) becomes `Automation/V2/` files per area (`Workspace`, `Panes`, `Sessions`, `Agents`, `Remote`, `Projects`, `Tasks`, `Projection`), each calling the existing `AppWorkspaceModel` actions so the UI and API stay one path.
- **Each phase is one PR** following the [change workflow](../../development/workflow.md): contract updated if the phase finds a gap, tests (observable behavior and failure safety), format, lint, build, test, independent review, `status.md`.
- **The switch (phase 8)** removes v1, makes v2 the only protocol, and ships the CLI, MCP and migration together.

## Phases

| # | Phase | Delivers | Main code | Depends on |
| --- | --- | --- | --- | --- |
| 1 | Foundations | Method catalog type and generator hooks; v2 dispatch path behind `--automation-v2`; conventions helpers (result wrapping, omission, lowercase IDs, pagination, `expectedRevision` on every method); error registry shared by `knownErrorCodes`, docs check, CLI exit map and MCP; contract-test harness that walks the catalog (API2-01–03) | `TrellisControl` (new `MethodCatalog`, `ControlSession`, `Authorization`), `TerminalSecurity.swift` | — |
| 2 | Core resources | Projections for space (machine, project), tab (role, custom title, status), pane (first-class: machine, shell, attention), session (`launch` object, `kept`, times), host (password flag, remote); `workspace.get/save`, `grant.get`, space/tab/pane/session methods incl. `pane.list/get`, `tab.duplicate`, `session.stop`, `host.connect {placement}`; `host.list` tags | `Automation/V2/*`, read-only accessors on `AppWorkspaceModel` for runtime state | 1 |
| 3 | Permissions and grants | v2 capabilities and composition; scopes `created`, projects, agents; `grants.json` schema 2 with migration and `.v1.bak`; editable grants (narrow at once, widen with confirmation); presets and the redesigned grant sheet (grouped, described, localized, VoiceOver) | `AutomationGrant.swift`, `Authorization.swift`, `AutomationSettingsView.swift`, `GrantListModel` | 1 (2 for resource scope checks) |
| 4 | Events | Typed envelope; topics workspace, selection, session (+`replaced`, `launchChanged`), attention, shell, agent, remote, project, task, host, grant; ring of 2,000; `events.poll` long-poll on the socket | `EventHub.swift`, `WorkspaceEvents.swift`, sources in `AppWorkspaceModel` (+Agents hook receiver, shell marks, OSC 9;4, input waits, +Remote link changes, +Tasks runs, project launch) | 2, 3 |
| 5 | Agents | `agent.list/get/runs/start/restart/respond/install`; agent scope; `AGENT_UNAVAILABLE`; per-definition response keys if review asks for them | `Automation/V2/Agents`, `AppWorkspaceModel+Agents.swift` (`launchAgent`, `restartAgent`, `installAgent`) | 2–4 |
| 6 | Remote workspaces | `remote.open/status/reconnect/helper.install/remove`; `REMOTE_DISCONNECTED` everywhere it applies; helper-install confirmation rule | `Automation/V2/Remote`, `AppWorkspaceModel+Remote.swift`, `RemoteHostsModel` | 2–4 |
| 7 | Projects and tasks | Project CRUD and `capture`; `project.check`/`launch` through a sheet-free launch path; `task.list/get/run/stop`; `TASK_UNTRUSTED`, `SETUP_REQUIRED`; `session.execute {wait}` on the command-finished mark | `Automation/V2/Projects`, `Tasks`, `AppWorkspaceModel+ProjectLaunch.swift`, `+Tasks.swift`, `ProjectLibrary` | 2–4 (agents in launches need 5, host targets need 6) |
| 8 | Layout v3, CLI, MCP and the switch | Layout documents v3; CLI v2 nouns and server-side name resolution; MCP tools generated from the catalog, `events_poll`, new instructions and untrusted markers; remove v1 dispatch, aliases and `--automation-v2`; move `docs/api/v2/` up to `docs/api/`; README, CHANGELOG (breaking change), public docs, `status.md` | `LayoutJSON.swift`, `TrellisCLI`, `TrellisMCP/MCPTools.swift`, `MCPEndpoint.swift`, docs | 1–7 |

Phases 5, 6 and 7 are independent of each other once 4 lands and can be built in parallel; 7's agent and host targets light up when 5 and 6 are in.

## Risks and how each phase handles them

| Risk | Where | Handling |
| --- | --- | --- |
| Project launch lives in a sheet flow (`checking → ready → settingUp → opening`) | 7 | Extract a model-level `ProjectLauncher` used by both the sheet and the API before adding the method; the sheet's tests must still pass unchanged. |
| `agent.respond` keys fit Claude Code but maybe not every agent | 5 | Decide in review: fixed table, or `respond` keys in the agent definition (definition schema change). |
| Event volume from shell marks and output-driven agent `working` | 4 | Coalesce per pane (at most one `attention`/`agent` event per 250 ms), never per output chunk; a test bounds events per second under `yes`. |
| `created` scope and spaces created by the UI on the API's behalf (project and remote launches) | 3, 6, 7 | Record the creating grant on the space at creation (runtime map, persisted with the grant), and test that UI-created spaces never join it. |
| Grant edits racing in-flight calls | 3 | Every call re-reads the grant (as v1 does); edits bump the grant revision and close subscriptions that lost access before returning. |
| Main-actor load from `workspace.get` on big workspaces | 2 | Build projections from one snapshot pass; bounded by the frame limit with `LIMIT_EXCEEDED`; a test with 100 panes stays under 50 ms. |
| Clean break surprises users | 8 | Release notes and `migration.md`; `UNSUPPORTED_VERSION` names v2; the app offers to re-link an outdated CLI. |

## Verification per phase

- Unit and contract tests: every method has success, permission, scope (`NOT_FOUND`), revision-conflict and failure-safety cases; the catalog walker checks conventions.
- Integration: `TrellisUITests` drive the real model through the v2 adapter (as `testMCPToolsDriveTheWorkspaceEndToEnd` does for v1), with real PTYs where a phase touches sessions.
- Manual (recorded as **pending** until seen): the grant sheet with VoiceOver (3); agents with real Claude Code and Codex hooks (5); a real remote host through `scripts/test-remote-docker.sh` (6); a project launch with clone and setup (7); Claude Code and Codex as MCP clients over loopback and Tailscale (8).
