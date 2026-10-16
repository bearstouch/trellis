# Contributing to Trellis

Thanks for your interest in Trellis. This guide covers how to get set up, how changes are made, and what a pull request needs before it can be merged.

## Ground rules

- Be respectful and constructive in issues, reviews and discussions.
- **The docs are the behavior contract.** [`docs/`](docs/index.md) defines how Trellis behaves. If your change alters behavior, update the relevant page in the same pull request. If a page is ambiguous, resolve the ambiguity there instead of inventing behavior in code.
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
- Deferred features and open qualification work are listed in the [roadmap](docs/project/roadmap.md). The completed MVP stories, with their acceptance criteria and named unit tests, are in the [delivery history](docs/project/delivery-history.md).

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

5. Update the docs. Update `README.md` for user-visible changes and the relevant page under `docs/` for behavior changes. If the change closes pending work from an MVP story, update `docs/evidence/SNNN-*.md` as well.
6. Open a pull request (see [Pull requests](#pull-requests)).

## Architecture rules and code style

The rules enforced in review are in [Development rules](docs/development/rules.md). In short:

- All state changes go through `WorkspaceCommandService`.
- Restored sessions start stopped, and typed input is never replayed.
- Never signal a reused PID.
- Persistence is atomic, versioned and owner-only.
- Never log or persist terminal output, input or secrets.
- Only `TrellisTerminal` imports SwiftTerm.
- Match the surrounding dense Swift style, and keep every view accessible.

The [architecture docs](docs/architecture/index.md) explain how the pieces fit together.

## Tests

- Tests use XCTest, with one test class per area, in the test target that matches the module.
- Assert observable behavior and failure safety. For example, if an operation fails, test that the previous state is retained.
- Story tests are named `testSNNN_UTnn_camelCaseName`, for example `testS015_UT01_minimalThemeInheritsDefaults`. The four named unit tests from each MVP story (listed in the [delivery history](docs/project/delivery-history.md)) must keep exactly those IDs. See [Testing](docs/development/testing.md). Extra tests that come out of review go in `*ReviewTests.swift`.
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
