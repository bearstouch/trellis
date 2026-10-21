# CLAUDE.md

Guidance for Claude Code working in this repository.

## Project

**Trellis** (formerly uTerm) is a native Swift terminal for macOS: light "Native calm" chrome,
dark terminal panes, bundled JetBrains Mono terminal font, managed windows in a left sidebar, per-window renameable tabs,
and nested splits, plus saved SSH hosts and a local CLI/automation API. The MVP is implemented;
remaining qualification work is tracked in `docs/overview/status.md`.

- Behavior contract: `docs/` (MkDocs site, nav in `mkdocs.yml`): overview, architecture,
  features, automation API/CLI, integrations, macOS support, development rules. The docs win over
  assumptions; if a page is ambiguous, resolve it in the page — never invent conflicting behavior.
  Requirement IDs (`FR-`, `API-`, `INT-`, `MAC-`) are stable. Backlog: `docs/project/roadmap.md`.
- Contract fixtures read by tests:
  `docs/api/example-layout.json`, `docs/themes/*.json` (must match bundled theme copies),
  `.trellis/project.json` and `.trellis/launch.json` (this repo's own project and tasks files; must
  re-encode to identical bytes) and the examples in `docs/features/project-files.md` and `docs/features/tasks.md`.

## Toolchain and commands

Requires Xcode 26 / Swift 6.2 (Swift 6 language mode, strict concurrency), macOS 14+.

```sh
swift build                                    # build (must be warning-free)
swift test                                     # full XCTest suite (~190 tests, ~20s)
swift test --filter TrellisUITests.TabManagementTests   # one test class
swift format -i -r Sources Tests               # format (config: .swift-format)
swift format lint --strict -r Sources Tests    # lint: must print nothing
swift run Trellis                              # run the app
swift run Trellis --fixture                    # isolated fixed-shell demo workspace
swift run Trellis --state-directory /abs/path  # separate dev workspace + theme library
scripts/run-feasibility.sh [--build-only]      # assemble, ad-hoc sign, verify (and open) .app
python3 scripts/test-feasibility-launcher.py "$(swift build --configuration debug --show-bin-path)"
python3 scripts/qualify.py [--quick]        # release qualification (~5 min, opens isolated app windows; report in .build/)
python3 scripts/bench-renderer.py [--quick] # Metal vs CoreGraphics benchmarks (FR-TX05; keep its windows visible)
scripts/package-release.sh                  # Universal 2 DMG; ad-hoc unless TRELLIS_SIGN_IDENTITY / TRELLIS_NOTARY_PROFILE
```

There is no SwiftLint/SwiftFormat binary; use the toolchain's `swift format` with the repo
`.swift-format` (4-space indent, 220 columns, semicolons and multi-variable `let` allowed).
Always run format + lint + build + test before committing.

## Package layout (`Package.swift`)

| Target | Role |
| --- | --- |
| `TrellisCore` | Engine-independent domain: `WorkspaceStore` (actor, authoritative model), `WorkspaceCommandService` (single mutation path), persistence (`WorkspacePersistence` actor), session lifecycle/closure policy, paste review, themes (`ThemeDocument`, `ThemeJSON`, `ThemeLibrary` actor), appearance settings. Bundled `Resources/Themes`. |
| `TrellisPOSIX` | Small C target (`spawn.c`) for PTY/process-group spawning. |
| `TrellisBroker` / `TrellisBrokerMain` | Opt-in `trellis-broker` helper (FR-R03): owns the PTYs of sessions kept after quit, their replay ring and the owner-only AF_UNIX protocol. Depends only on `TrellisPOSIX`. |
| `TrellisTerminal` | SwiftTerm-specific code only: `NativeTerminal`, `AccessibleTerminalView`, `PTYProcess`, scrollback, search, selection bookmarks, terminal appearance. |
| `TrellisUI` | SwiftUI/AppKit views and `AppWorkspaceModel` (`@MainActor` `ObservableObject` bridging store ↔ views ↔ terminals). |
| `TrellisControl` | Local automation: AF_UNIX JSON-RPC server, framing, endpoint/discovery safety, auth-gated `ControlHandler`. |
| `TrellisMCP` | Optional MCP server (Streamable HTTP, off by default): TCP listener, HTTP parser, MCP sessions, tool table over `AuthorizingControlHandler`. Settings → Remote Control. |
| `TrellisApp` | `AppMain.swift`: app entry, menus/commands, launch arguments. |
| `TrellisRelease` | Release manifest checks, user-local CLI link planner, uninstall allow-list, release checklist. |
| `TrellisCLI` / `TrellisCLIMain` | `trellis-cli` (installed as `trellis`): injected-effect CLI over the control socket; no token argv, no retries. |
| Tests | `TrellisCoreTests`, `TrellisTerminalTests`, `TrellisUITests`, `TrellisControlTests`, `TrellisMCPTests`, `TrellisCLITests` (XCTest). |

`ThirdParty/SwiftTerm` is a vendored SwiftTerm 1.20.0 with small patches. Record any engine
change in `ThirdParty/SwiftTerm/PATCHES.md`. Never import SwiftTerm outside `TrellisTerminal`.

## Architecture rules

- One authoritative mutation path: UI (and future CLI/automation) go through the command
  service; tree invariants and lifecycle rules are enforced there, not in views.
- Domain: Window → ordered Tabs → binary `SplitNode` tree (axis x|y, ratio = first child share)
  → Pane → Session. UUIDs stay stable across saves and stopped restore.
- Session states: `stopped → starting → running → exited|failed`; `running → closing → exited`.
  Restart creates a new session UUID in the same pane. Restored workspaces start **stopped**;
  never replay typed input.
- Closing a running pane needs confirmation; graceful group termination, 2 s wait, then explicit
  force. Never signal a reused PID.
- PTY I/O and parsing off the main thread; view updates on `@MainActor`. Bound large output.
- Persistence: versioned Codable JSON, atomic replace, last-known-good backup, owner-only
  permissions (files 0600, dirs 0700), single writer. Never persist terminal output, typed
  input, secrets, or environment secret values — except the opt-in, redacted scrollback file
  (FR-R04/FR-R05). Corrupt/newer state → recovery, never overwrite.
- Terminal output and typed input are never logged.
- Inject time, filesystem, process, clipboard, Keychain and transport dependencies so tests are
  deterministic (see `SessionClosureCoordinator(now:sleep:)` for the pattern).

## Code style

- Match the surrounding code: compact, dense Swift; short `guard … else { …; return }` bodies and
  `;`-joined trivial statements are normal here. Comments are sparse and explain *why*.
- `public` APIs across module boundaries; `Sendable`/`Equatable` value types in Core.
- `@MainActor` for UI and terminal-facing classes; actors for stores/persistence/library.
- Error codes are SCREAMING_SNAKE strings (e.g. `CONFIRMATION_REQUIRED`) shared with the API docs (`docs/api/errors.md`).
- Keep accessibility in mind for every view: labels, roles, selected state, text not color-only.

## Tests

- XCTest, one class per area. Use descriptive test names; keep existing names stable.
  Review-driven extras go in `*ReviewTests.swift`.
- Assert observable behavior and failure safety (previous state retained on error).
- Integration tests may spawn real PTYs; keep them isolated (temp dirs, `--state-directory`).

## Change workflow (see `docs/development/workflow.md`)

1. Read the relevant docs pages. For behavior changes or new (P1/P2) features, update the
   contract page first or alongside the code, adding new requirement IDs with acceptance checks.
2. Implement with tests (observable behavior + failure safety).
3. Format, lint, build, test — all clean.
4. Launch an independent review agent (fresh eyes; correctness, acceptance gaps, security, data
   loss, races, leaks, regressions, test gaps). It fixes crucial issues, then formats, lints,
   builds and tests again.
5. Record what was verified and what remains pending (in the PR/commit). Closing a pending check
   or changing a known limit updates `docs/overview/status.md`. Update `README.md` /
   `CHANGELOG.md` if user-visible.
6. Commit on `master` (repo convention) with Conventional Commits: `feat(<scope>): …` / `fix(<scope>): …`, using a module or
   area as scope.

Honesty rules: acceptance checkboxes stay unchecked unless actually observed. Manual checks that
cannot be performed here (VoiceOver, real IME, keyboard layouts, older macOS/Intel, notarization)
are recorded as **pending**, never as passed. Document blockers instead of faking results.

## Gotchas

- Product renamed uTerm → Trellis; migration copies the old Application Support data and the
  `trellis-` theme-ID prefix is reserved for built-ins. Don't reintroduce `UTerm*` names.
- `--fixture` runs a fixed shell that exits with code 7; the window stays inspectable.
- `scripts/run-feasibility.sh` copies the SwiftPM resource bundles (`SwiftTerm_SwiftTerm`,
  `Trellis_TrellisCore`) into the app; a new target with resources must be added there too.
  It also copies and signs the bundled helpers (`trellis-askpass`, `trellis-broker`); a new helper
  goes there, in both packaging scripts and in `release/manifest.json`.
- Settings/theme preview state is never persisted; cancelling must restore exact prior state.
