# EX-16: Terminal panes (`terminal.open`)

Part of the [Extensions specification](SPEC.md#stories). **Epic:** 3, Tier 0 · **Phase:** 3b · **Requirements:** FR-EX14 · **Depends on:** [EX-9](EX-09-runtime-prompts-audit.md) · **Points:** 3

**Definition.** As a Trellis user, I want an extension to open a terminal pane running a command only after I see and allow the exact command line, so that extensions can start useful work without power over my existing panes.

`trellis.terminal.open({command, args, cwd, placement, title})` opens a normal Trellis terminal pane in the focused space, as a new tab or a split. It needs the `terminal.open` permission, which gives no power over existing panes, so the extension doesn't need `layout.write`, `session.start` or `session.execute`. It always prompts with the exact command line.

## Scope

**In**

- `trellis.terminal.open` in the bridge, with `placement: "tab"|"split"` and an optional `title` and `cwd`.
- Checked against the approved permissions, prompted every time with the exact command line, and audited. Always Allow is per exact command line.
- A normal Trellis pane through the command service, in the focused space.

**Out**

- `session.execute` and `session.input` against existing panes (through `trellis.call`, EX-8 and EX-9).

## Acceptance criteria

- [ ] **Given** an extension without `terminal.open`, **when** it calls `terminal.open`, **then** it gets `PERMISSION_DENIED`.
- [ ] **Given** `terminal.open`, **when** the extension calls it, **then** a prompt shows the exact command line in full, monospace, with invisible characters made visible.
- [ ] **Given** I allow it with `placement: "tab"`, **when** it runs, **then** a normal Trellis pane running the command opens in a new tab of the focused space. **Given** `placement: "split"`, **then** it opens as a split.
- [ ] **Given** I chose Always Allow for one command line, **when** the extension opens a different command line, **then** it prompts again.
- [ ] **Given** I deny it, **when** the call returns, **then** it rejects with `PROMPT_DENIED` and no pane opens.
- [ ] **Given** the call, **when** I read the audit log, **then** it records the method, target and decision.

## Implementation notes

- Handled by `ExtensionBridge` itself, since there is no control-API method. Open the pane through `WorkspaceCommandService`, the single mutation path.
- Prompting through `ExtensionPrompter` (EX-9).

## Tests

- `ExtensionPrompterTests`: `terminal.open` always prompts; Always Allow per command line.
- `ExtensionAuthorizationTests`: missing permission.
