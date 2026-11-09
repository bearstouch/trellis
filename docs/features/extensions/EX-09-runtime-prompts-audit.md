# EX-9: Runtime prompts (non-modal) and audit log

Part of the [Extensions specification](SPEC.md#stories). **Epic:** 2, Host and authority · **Phase:** 3a · **Requirements:** FR-EX07, FR-EX08 · **Depends on:** [EX-8](EX-08-grant-resolving.md) · **Points:** 5

**Definition.** As a Trellis user, I want dangerous extension actions to ask me first, in a way that never interrupts my typing, and to be logged, so that I stay in control and can see what an extension did.

The prompter runs after authorization and before execution. A call the user triggered within the last 5 s shows a sheet. Any other call queues: the extension's dock icon shows a "needs permission" mark and a banner appears at the top of its view and in Settings. Every mutating call and decision is written to the audit log.

## Scope

**In**

- `ExtensionPrompter` for `session.input`, `session.execute`, `session.output.read`, `session.close`, `theme.write`, `host.write`, `terminal.open` and the first `fetch` to each origin.
- The 5 s user-action window: a command, or an action in the extension's view.
- Sheet or queue: never window-modal in the background.
- Prompt text naming the extension, the action and the target. Command lines in full, monospace, with control and invisible characters made visible.
- Choices: Allow Once, Always Allow, Deny, Always Deny, with the coverage rules: `session.input` per pane until it closes and never offered for SSH or remote-workspace panes; `session.output.read` per extension; `session.execute` and `terminal.open` per exact command line; fetch per origin.
- Limits: 60 s for a sheet, 10 minutes when queued, at most 5 waiting per extension; the 6th is refused with `PROMPT_LIMIT`. A denied prompt rejects with `PROMPT_DENIED`.
- In Development mode, remembered Always Allow choices are ignored.
- The Trellis permission prompt uses a system style with the Trellis mark that no extension component can reproduce.
- The audit log: time, method, target IDs and decision, never input, output or secrets; capped at 1 MiB and rotated once.

**Out**

- The dock mark's placement in the dock (EX-23 shows it; this story raises it).
- The Settings page listing remembered choices with Revoke (EX-10).

## Acceptance criteria

- [ ] **Given** a call to a prompted capability triggered by a command less than 5 s ago, **when** it reaches the prompter, **then** a sheet shows.
- [ ] **Given** a call the user didn't just trigger, **when** it reaches the prompter, **then** no window-modal sheet appears; it queues with a "needs permission" mark and a banner, and typing in the focused terminal continues.
- [ ] **Given** a prompt, **when** I read it, **then** it names the extension, action and target, and shows any command line in full with invisible characters made visible.
- [ ] **Given** each of the four choices, **when** it is picked, **then** it behaves as named, and Always choices are remembered with the coverage above.
- [ ] **Given** a `session.input` prompt for an SSH or remote-workspace pane, **when** it shows, **then** Always Allow is not offered.
- [ ] **Given** a sheet unanswered for 60 s, or a queued request for 10 minutes (injected clock), **when** time passes, **then** it is denied.
- [ ] **Given** 5 waiting prompts, **when** a 6th arrives, **then** it is refused with `PROMPT_LIMIT`.
- [ ] **Given** Development mode, **when** an action with a remembered Always Allow runs, **then** it prompts again.
- [ ] **Given** mutating calls and decisions, **when** I read the audit log, **then** each has time, method, targets and decision, and no input, output or secret appears.
- [ ] **Given** the audit log reaches 1 MiB, **when** another entry is written, **then** it rotates once.

## Implementation notes

- New in `TrellisUI`: `ExtensionPrompter`.
- Hook after `AuthorizingControlHandler` (`Sources/TrellisControl/Authorization.swift`) and before execution, as described in EX-8.
- The audit log lives in `ExtensionData/<name>/audit.log` from EX-4.
- Reuse the visible-control-character rendering from paste review (`Sources/TrellisCore/TerminalPaste.swift`) if it fits.
- Inject the clock for the 5 s window and the timeouts.

## Tests

- `ExtensionPrompterTests`: each prompt choice; sheet versus queue; 60 s timeout; 10-minute queue timeout; 5-prompt limit; Always Allow coverage; Development mode.
- `ExtensionRegistryTests`: audit log fields, redaction and rotation.
