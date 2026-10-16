# Architecture

## Platform and component design

The application MUST be native Swift. Proposed baseline: SwiftUI for the sidebar, tab strip, settings, and host editor; AppKit interoperability for the terminal surface and native responder behavior. Avoid a webview-based terminal.

| Component | Responsibility |
| --- | --- |
| App shell | Native scene/window lifecycle, menus, window sidebar and per-window tab bar, settings |
| Workspace store | Authoritative windows, tab order, split trees, active selection, revisions |
| Terminal adapter | Engine-independent terminal view, selection, paste, resize, screen/scrollback access |
| Session manager | PTY allocation, process launch, terminal size, input/output, exit and teardown |
| Host repository | Saved connection metadata and read-only SSH configuration discovery |
| Theme service | Validate/install JSON palettes, resolve built-in defaults, persist appearance mode, update SwiftUI and terminal adapter consistently |
| Persistence store | Versioned atomic snapshots, schema migration, backup and recovery |
| Command service | Validated domain operations shared by UI, CLI, and agent clients |
| Automation server | Authentication, authorization, JSON-RPC framing, subscriptions, limits |
| CLI | Structured command client with machine-readable output and explicit exit statuses |

There MUST be one authoritative mutation path through the command service. UI and automation MUST enforce the same tree invariants and process lifecycle rules. Authorization is enforced at the service boundary for automation, including direct internal calls from adapters.

## Domain model

- `Window`: UUID, name, ordered tab IDs, active tab ID, revision.
- `Tab`: UUID, window ID, title, root split node, active pane ID, revision.
- `SplitNode`: either a leaf referencing a pane, or a branch with UUID, `axis: x|y`, ratio, and exactly two ordered child nodes. Ratio represents the first child's share.
- `Pane`: UUID, tab ID, session ID, profile ID, user title if any.
- `Session`: UUID, launch descriptor, state, timestamps, optional PID and exit status. Runtime-only output buffers and process handles are not persisted.
- `Host`: UUID, name, SSH alias or hostname, optional user/port/identity-file reference, tags, revision. Never contains passwords or private-key contents.
- `AutomationGrant`: UUID, token hash, capability set, resource scope, expiration, revocation state. Secret token material is kept separately from layout data.

UUIDs remain stable across normal saves and stopped-layout restoration. Export omits runtime session IDs; import assigns new UUIDs. Declarative layout `key` values provide matching identities within a deployment namespace, not globally unique object IDs.

## Session and process lifecycle

States: `stopped → starting → running → exited|failed`; `running → closing → exited`. Explicit restart creates a new session UUID in the existing pane. A stopped pane has a session record without a process.

Creating an interactive pane launches the user's configured shell with a PTY, login-shell semantics, initial working directory, inherited environment plus allowed overrides, and initial terminal dimensions. Working directories MUST exist and be accessible before launch. A clean environment policy MUST remove application-only control secrets from child environments.

The session manager MUST establish a controlling terminal and process group, handle child exit, reap children, propagate size changes with the appropriate terminal resize notification, and close descriptors. Output parsing and PTY I/O run off the main thread; view updates run on the main actor. Large output MUST be bounded and must not block UI input.

Closing a running pane requires a confirmation unless already explicitly authorized for automation. Attempt graceful process-group termination, wait up to two seconds, then offer force termination in UI; API clients receive `close_pending` and must explicitly request `force: true`. Never signal a reused PID; retain verified ownership of the launched process group. Closing does not guarantee remote processes stop, including processes detached with tmux/nohup.

SSH uses `/usr/bin/ssh` inside the pane's PTY. SSH authentication prompts and host-key verification stay in the terminal. A live SSH client is `running`; MVP does not infer successful remote authentication from process existence or screen text.

## Terminal engine decision

Provisional candidate: SwiftTerm. Its upstream project provides an AppKit terminal surface and a local-process terminal view. The feasibility milestone must establish whether its interfaces satisfy selection, IME, output access, resize, and lifecycle requirements. Keep engine-specific types inside the adapter. Do not create a new terminal emulator as part of MVP.

Avoid duplicating PTY ownership: either use the engine's process helper behind SessionManager or own the PTY and feed the engine, selected after the spike. The final choice must cover process-group cleanup and asynchronous output.

Source: [SwiftTerm upstream repository](https://github.com/migueldeicaza/SwiftTerm). This is evidence for candidate evaluation, not a guarantee of the application's target compatibility.

## State and persistence

Persist window/tab ordering, split ratios, titles, host metadata, launch descriptions, appearance mode, selected dark/light theme IDs, and settings under the user's Application Support directory. Use versioned Codable JSON with atomic replacement, a last-known-good backup, owner-only permissions, and a single writer. Debounce ordinary UI saves; explicit save and shutdown flush outstanding state.

Do not persist terminal output, typed input, authentication material, or environment secret values by default. Saved launch descriptions may refer to shell, host, and directory but never replay previous shell input. Restoring the application creates stopped panes; a user explicitly starts a pane or uses “Start all” after reviewing the launch summary.

On corrupt state, preserve the original, offer the backup, and allow an empty workspace. Unknown newer schema versions are opened in a recovery view without overwriting the source. Failed migration leaves the original intact.

## Concurrency and consistency

Serialize workspace mutations in a store actor. Use monotonically increasing revisions for optimistic concurrency. Process creation is an effect after committing a validated pane; launch failures produce a failed session, not a dangling tree reference. Closing reserves its target while cleanup runs. Event order follows committed changes; transient output has its own bounded sequence.

A layout application validates and atomically commits its model changes, then launches requested new sessions independently. It is not a transaction over process execution. Return launch results per pane and never retry execution implicitly.

## Packaging boundary

MVP uses direct distribution without App Sandbox so it can run ordinary developer shells and access user-selected working directories under normal macOS permissions. Hardened runtime, signing, notarization, and macOS privacy controls still apply. A future sandboxed distribution requires a separate feasibility decision.

Apple documents child-process sandbox inheritance in [Protecting user data with App Sandbox](https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox); the distribution choice here is a project decision.
