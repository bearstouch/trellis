# Development rules

Review enforces these rules. Most of them exist to protect users' running sessions and data. If a rule gets in your way, change it here in a reviewed pull request; don't work around it in code.

## The docs are the contract

- These docs define how Trellis behaves. If your change alters behavior, update the relevant page in the same pull request.
- If a page is ambiguous, resolve the ambiguity in the page. Don't invent behavior in code that conflicts with it.
- Requirement IDs (`FR-…`, `API-…`, `INT-…`, `MAC-…`) are stable. Don't renumber or reuse them. New requirements get new IDs, and retired ones are marked as retired.

## Architecture

- **One mutation path.** The UI, the CLI and automation all change state through `WorkspaceCommandService` and `WorkspaceStore`. Tree invariants and lifecycle rules live there, never in views or in `AutomationService`. See [Architecture](../architecture/index.md#one-mutation-path).
- **Commands don't do I/O.** A process launch is an effect that happens after the commit, and its result is reported back with the launch attempt ID.
- **Domain shape:** Window → ordered Tabs → binary split tree (`PaneLayout`, axis `x|y`, ratio = first child's share) → Pane → Session. UUIDs stay stable across saves and stopped restores.
- **Session lifecycle:** `stopped → starting → running → exited|failed`, and `running → closing → exited`. Restarting creates a new session UUID in the same pane. Restored workspaces start **stopped**, and typed input is never replayed.
- **Closing a running pane** needs confirmation. Terminate the process group gracefully, wait 2 seconds, and force only when explicitly asked. **Never signal a reused PID.** Check `OwnedProcessIdentity` first.
- **Threading:** PTY I/O and parsing run off the main thread, and view updates run on `@MainActor`. Bound every buffer that grows with output.
- **Engine boundary:** only `TrellisTerminal` imports SwiftTerm. Record every change to `ThirdParty/SwiftTerm` in `PATCHES.md`, and regenerate `trellis.patch`.
- **Automation is never a side door.** Every control method needs an entry in the `AuthorizationPolicy` table, goes through the shared model, and treats out-of-scope IDs as `NOT_FOUND`.
- **Inject dependencies:** time, the filesystem, processes, the clipboard, the Keychain and transports are injected so tests are deterministic. `SessionClosureCoordinator(now:sleep:)` shows the pattern.

## Data and persistence

- Persisted data is versioned Codable JSON, replaced atomically, with a last-known-good backup and owner-only permissions (files `0600`, directories `0700`) and a single writer. See [Persistence](../architecture/persistence.md).
- Corrupt or newer state goes to recovery and is **never overwritten**. A failed migration leaves the original file intact.
- When you change a persisted format, bump its version, add a migration, and add a test that loads the old format.
- Settings and theme previews are never persisted. Cancelling must restore the exact previous state.

## Security and privacy

- **Never log or persist** terminal output, typed input, tokens, passwords, private keys, or environment variable values.
- Terminal output is untrusted. Don't add features where the terminal triggers clipboard access, file access or URL opening without a user gesture.
- Build processes from an executable plus an argument array. Never interpolate into a shell command line, and never add SSH trust-bypass flags.
- Tokens never go in argv, environment variables or error messages.
- Don't add telemetry or network calls.
- Be especially careful in these areas: the control socket and grants (`TrellisControl`), the MCP server (`TrellisMCP`), escape-sequence handling (OSC 52, Kitty graphics, OSC 1337 inline images, links), paste review, SSH invocation, and persistence permissions. Report vulnerabilities privately; see [Contribution workflow](workflow.md#security-issues).

## Code style

- Match the surrounding code. It's compact and dense: short `guard … else { …; return }` bodies and `;`-joined trivial statements are normal.
- Keep comments sparse, and use them to explain *why*.
- Use `public` for APIs that cross module boundaries. Core value types are `Sendable` and `Equatable`.
- Use `@MainActor` for UI and terminal-facing classes, and actors for stores, persistence and libraries.
- Error codes are `SCREAMING_SNAKE` strings shared with the API (see [Errors](../api/errors.md)).
- The build must be warning-free, and `swift format lint --strict` must print nothing.

## Accessibility

Accessibility is part of every view:

- Give controls labels and roles, and expose selected state.
- Keep focus visible.
- Never rely on color alone to convey status.

See [Keyboard and accessibility](../features/keyboard-accessibility.md).

## Naming

The product was renamed from uTerm to Trellis. Don't reintroduce `UTerm*` names. The `trellis-` theme-ID prefix is reserved for built-in themes, and the `TRELLIS_`/`UTERM_` environment prefixes are reserved for the app.
