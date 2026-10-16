# Contributing to Trellis

Thanks for your interest in Trellis. This guide covers how to get set up, how changes are made, and what a pull request needs before it can be merged.

## Ground rules

- Be respectful and constructive in issues, reviews and discussions.
- **Specs are the behavior contract.** [`specs/`](specs/README.md) defines how Trellis behaves. If your change alters behavior, update the relevant spec in the same pull request. If a spec is ambiguous, resolve the ambiguity in the spec instead of inventing behavior in code.
- **Be honest about verification.** Report what you actually ran and observed. Mark checks you could not perform, such as VoiceOver, IME, other keyboard layouts, Intel Macs or older macOS versions, as *pending*. Never mark them as passed.

## Getting set up

Follow [Development setup](README.md#development-setup) in the README. You need macOS 14 or later and Xcode 26 (Swift 6.2). Nothing else is required.

While developing, always run the app with an isolated state directory so you don't touch your real workspace:

```sh
swift run Trellis --state-directory "$PWD/.build/dev-state"
```

## Finding something to work on

- Look for issues labelled `good first issue` or `help wanted`.
- For anything larger than a small fix, open an issue first and describe the problem and your proposed approach. Agreeing on direction early saves rework.
- Planned work is broken into stories in [`specs/00-stories/`](specs/00-stories/README.md). Each story has acceptance criteria and named unit tests.

## Making a change

1. Fork the repository and create a topic branch from `master`, for example `fix/split-ratio-rounding`.
2. Make the change, with tests (see [Tests](#tests)).
3. Run the full local gate. It must be clean, with no warnings and no lint output:

   ```sh
   swift format -i -r Sources Tests
   swift format lint --strict -r Sources Tests
   swift build
   swift test
   ```

4. If you changed launching, bundling or resources, also run:

   ```sh
   scripts/run-feasibility.sh --build-only
   python3 scripts/test-feasibility-launcher.py "$(swift build --configuration debug --show-bin-path)"
   ```

5. Update the docs. Update `README.md` for user-visible changes and the relevant `specs/` file for behavior changes. If the change belongs to a story, update `docs/evidence/SNNN-*.md` as well.
6. Open a pull request (see [Pull requests](#pull-requests)).

## Architecture rules

These rules are enforced in review. Most of them protect users' sessions and data.

- **One mutation path.** The UI, the CLI and automation all change state through `WorkspaceCommandService`. Tree invariants and lifecycle rules live there, never in views.
- **Domain shape:** Window → ordered Tabs → binary `SplitNode` tree (axis `x|y`, ratio = first child's share) → Pane → Session. UUIDs stay stable across saves and stopped restores.
- **Session lifecycle:** `stopped → starting → running → exited|failed`, and `running → closing → exited`. Restarting creates a new session UUID in the same pane. Restored workspaces start **stopped**, and typed input is never replayed.
- **Closing a running pane:** ask for confirmation, terminate the process group gracefully, wait 2 s, then force only on explicit request. Never signal a PID that may have been reused.
- **Threading:** PTY I/O and parsing run off the main thread, and view updates run on `@MainActor`. Large output must be bounded.
- **Persistence:** versioned Codable JSON, atomic replace, a last-known-good backup, owner-only permissions (files `0600`, directories `0700`), and a single writer. Corrupt or newer state goes to recovery and is never overwritten.
- **Privacy:** never log or persist terminal output, typed input, secrets or environment secret values.
- **Engine boundary:** only `TrellisTerminal` may import SwiftTerm. Record every change to `ThirdParty/SwiftTerm` in [`ThirdParty/SwiftTerm/PATCHES.md`](ThirdParty/SwiftTerm/PATCHES.md).
- **Injectable dependencies:** time, filesystem, processes, clipboard, Keychain and transports are injected so tests stay deterministic. `SessionClosureCoordinator(now:sleep:)` shows the pattern.
- **Naming:** the product was renamed from uTerm. Don't reintroduce `UTerm*` names. The `trellis-` theme ID prefix is reserved for built-in themes.

## Code style

- Match the surrounding code. The codebase is compact and dense: short `guard … else { …; return }` bodies and `;`-joined trivial statements are normal.
- Keep comments sparse, and use them to explain *why*, not *what*.
- Use `public` for APIs that cross module boundaries. Value types in `TrellisCore` should be `Sendable` and `Equatable`.
- Use `@MainActor` for UI and terminal-facing classes, and actors for stores, persistence and libraries.
- Error codes are `SCREAMING_SNAKE` strings shared with the API spec, for example `CONFIRMATION_REQUIRED`.
- **Accessibility is part of every view:** labels, roles, selected state, and information that never relies on color alone.
- `swift format` with the repo's [`.swift-format`](.swift-format) is the final word on layout.

## Tests

- Tests use XCTest, with one test class per area, in the test target that matches the module.
- Assert observable behavior and failure safety. For example, if an operation fails, test that the previous state is retained.
- Story tests are named `testSNNN_UTnn_camelCaseName`, for example `testS015_UT01_minimalThemeInheritsDefaults`. The four named unit tests from each story file must exist with exactly those IDs. Extra tests that come out of review go in `*ReviewTests.swift`.
- Integration tests may spawn real PTYs, but they must stay isolated: use temporary directories and `--state-directory`, and never touch the user's workspace, Keychain or hosts.
- Useful filters:

  ```sh
  swift test --filter TrellisCoreTests
  swift test --filter TrellisUITests.TabManagementTests
  swift test --filter 'S017_UT'
  ```

## Commits

- Write focused commits with imperative subjects. This repo uses a [Conventional Commits](https://www.conventionalcommits.org/) style:
  - `feat(S017): add configurable keyboard shortcuts`
  - `fix(S012): keep paste review open on cancel`
  - `docs: clarify state-directory usage`
- Use the story ID as the scope when the change belongs to a story. Otherwise use a module or area name, for example `fix(control): …`.
- Don't commit build output (`.build/`, `dist/`), personal Xcode state, or anything from your real Application Support directory.

## Pull requests

A good pull request:

- explains **what** changed and **why**, and links the issue or story;
- lists **how you verified** it: the commands you ran, the test counts, and any manual checks, with unperformed checks marked *pending*;
- includes screenshots or a short recording for UI changes, in both light and dark appearance where relevant;
- keeps to one concern. Refactors that aren't needed for the change belong in their own PR.

Maintainers review for correctness, regressions, data-loss risk, races and leaks, security, accessibility, and test gaps. Expect questions, and expect follow-up commits to be requested.

## Reporting bugs

Open an issue that includes:

- the Trellis version or commit, macOS version, and CPU (Apple silicon or Intel);
- steps to reproduce, what you expected, and what happened;
- if useful, a diagnostics report from **Help → Export Diagnostics…**. It is allow-listed and previewed before you save it, but review it before attaching.

Don't paste terminal output that contains secrets, tokens or private hostnames.

## Reporting security issues

**Don't open a public issue for security vulnerabilities.** Report them privately through GitHub's [private vulnerability reporting](https://github.com/layerx-labs/trellis/security/advisories/new) for this repository. Include the affected version, the impact, and minimal reproduction steps. We will acknowledge your report and coordinate a fix and disclosure with you.

Areas that are especially security-sensitive include the control socket and grants (`TrellisControl`), terminal escape-sequence handling (OSC 52, file transfer, links), paste review, SSH invocation, and persistence permissions.

## License

By contributing, you agree that your contributions are licensed under the project's [MIT License](LICENSE).
