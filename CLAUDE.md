# CLAUDE.md

Guidance for Claude Code working in this repository.

## Project

**Trellis** (formerly uTerm) is a native Swift terminal for macOS: light "Native calm" chrome,
dark terminal panes, Monaco font, managed windows in a left sidebar, per-window renameable tabs,
and nested splits. Saved SSH hosts and a local CLI/automation API are planned.

- Behavior contract: `specs/` (overview, architecture, functional/non-functional requirements,
  API, integrations, macOS support). The specs win over assumptions; if a spec is ambiguous,
  resolve it in both the spec and the affected story — never invent conflicting behavior.
- Delivery plan: `specs/00-stories/NNN-*.md` (32 P0 stories) and the progress table in
  `specs/00-stories/README.md`.
- Per-story evidence: `docs/evidence/SNNN-*.md`.

## Toolchain and commands

Requires Xcode 26 / Swift 6.2 (Swift 6 language mode, strict concurrency), macOS 14+.

```sh
swift build                                    # build (must be warning-free)
swift test                                     # full XCTest suite (~190 tests, ~20s)
swift test --filter TrellisUITests.TabManagementTests   # one test class
swift test --filter 'S017_UT'                  # one story's named tests
swift format -i -r Sources Tests               # format (config: .swift-format)
swift format lint --strict -r Sources Tests    # lint: must print nothing
swift run Trellis                              # run the app
swift run Trellis --fixture                    # isolated fixed-shell demo workspace
swift run Trellis --state-directory /abs/path  # separate dev workspace + theme library
scripts/run-feasibility.sh [--build-only]      # assemble, ad-hoc sign, verify (and open) .app
python3 scripts/test-feasibility-launcher.py "$(swift build --configuration debug --show-bin-path)"
```

There is no SwiftLint/SwiftFormat binary; use the toolchain's `swift format` with the repo
`.swift-format` (4-space indent, 220 columns, semicolons and multi-variable `let` allowed).
Always run format + lint + build + test before committing.

## Package layout (`Package.swift`)

| Target | Role |
| --- | --- |
| `TrellisCore` | Engine-independent domain: `WorkspaceStore` (actor, authoritative model), `WorkspaceCommandService` (single mutation path), persistence (`WorkspacePersistence` actor), session lifecycle/closure policy, paste review, themes (`ThemeDocument`, `ThemeJSON`, `ThemeLibrary` actor), appearance settings. Bundled `Resources/Themes`. |
| `TrellisPOSIX` | Small C target (`spawn.c`) for PTY/process-group spawning. |
| `TrellisTerminal` | SwiftTerm-specific code only: `NativeTerminal`, `AccessibleTerminalView`, `PTYProcess`, scrollback, search, selection bookmarks, terminal appearance. |
| `TrellisUI` | SwiftUI/AppKit views and `AppWorkspaceModel` (`@MainActor` `ObservableObject` bridging store ↔ views ↔ terminals). |
| `TrellisApp` | `AppMain.swift`: app entry, menus/commands, launch arguments. |
| Tests | `TrellisCoreTests`, `TrellisTerminalTests`, `TrellisUITests` (XCTest). |

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
  input, secrets, or environment secret values. Corrupt/newer state → recovery, never overwrite.
- Terminal output and typed input are never logged.
- Inject time, filesystem, process, clipboard, Keychain and transport dependencies so tests are
  deterministic (see `SessionClosureCoordinator(now:sleep:)` for the pattern).

## Code style

- Match the surrounding code: compact, dense Swift; short `guard … else { …; return }` bodies and
  `;`-joined trivial statements are normal here. Comments are sparse and explain *why*.
- `public` APIs across module boundaries; `Sendable`/`Equatable` value types in Core.
- `@MainActor` for UI and terminal-facing classes; actors for stores/persistence/library.
- Error codes are SCREAMING_SNAKE strings (e.g. `CONFIRMATION_REQUIRED`) shared with the API spec.
- Keep accessibility in mind for every view: labels, roles, selected state, text not color-only.

## Tests

- XCTest, one class per area. Story test names follow `testSNNN_UTnn_camelCaseName`
  (e.g. `testS015_UT01_minimalThemeInheritsDefaults`); the four named unit tests from each story
  file must exist with those IDs. Review-driven extras go in `*ReviewTests.swift`.
- Assert observable behavior and failure safety (previous state retained on error).
- Integration tests may spawn real PTYs; keep them isolated (temp dirs, `--state-directory`).

## Story workflow (one story at a time, in order)

1. Read the story file, its dependencies, and the referenced spec sections.
2. Set the story `Status:` to In progress; implement with the four named unit tests plus any
   needed extra tests.
3. Format, lint, build, test — all clean.
4. Launch an independent review agent (fresh eyes; correctness, acceptance-criteria gaps,
   security, data loss, races, leaks, regressions, test gaps). It fixes crucial issues, then
   formats, lints, builds and tests again.
5. Record evidence in `docs/evidence/SNNN-<slug>.md` (behavior, review findings/fixes, test
   counts, what was verified natively, and what remains pending). Update the story status, the
   progress table in `specs/00-stories/README.md`, and `README.md` if user-visible.
6. Commit on `master` (repo convention), one commit per story:
   `feat(SNNN): <concise description>`; fixes use `fix(SNNN): …`.

Honesty rules: acceptance checkboxes stay unchecked unless actually observed. Manual checks that
cannot be performed here (VoiceOver, real IME, keyboard layouts, older macOS/Intel, notarization)
are recorded as **pending**, never as passed. Document blockers instead of faking results.

## Gotchas

- Product renamed uTerm → Trellis; migration copies the old Application Support data and the
  `trellis-` theme-ID prefix is reserved for built-ins. Don't reintroduce `UTerm*` names.
- `--fixture` runs a fixed shell that exits with code 7; the window stays inspectable.
- `scripts/run-feasibility.sh` copies the SwiftPM resource bundles (`SwiftTerm_SwiftTerm`,
  `Trellis_TrellisCore`) into the app; a new target with resources must be added there too.
- Settings/theme preview state is never persisted; cancelling must restore exact prior state.
