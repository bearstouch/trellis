# Testing

All tests use XCTest (`swift test`). The suite has about 310 tests and runs in roughly 20 seconds.

## Test targets

| Target | Covers | Example classes |
| --- | --- | --- |
| `TrellisCoreTests` | The store, persistence, sessions, closure policy, themes, hosts, SSH discovery, keyboard, diagnostics, scrollback, output journal | `WorkspaceStoreTests`, `WorkspacePersistenceTests`, `SessionClosureTests`, `ThemeValidationTests`, `SSHConfigDiscoveryTests` |
| `TrellisTerminalTests` | Real PTYs, process ownership, output ordering, copy, paste, search, selection, appearance | `PTYProcessTests`, `ProcessOwnershipTests`, `PTYOutputOrderingTests`, `TerminalSecurityTests` |
| `TrellisUITests` | `AppWorkspaceModel` behavior, automation methods, layouts, restore, themes | `TabManagementTests`, `SplitManagementTests`, `SessionSafetyTests`, `LayoutAutomationTests`, `AutomationOutputTests` |
| `TrellisControlTests` | Framing, endpoint safety, authorization, events, fuzzing | `ControlProtocolTests`, `GrantAuthorizationTests`, `EventHubTests`, `BoundaryFuzzTests` |
| `TrellisCLITests` | Argument parsing, exit codes, launch behavior | `CLITests` |
| `TrellisReleaseTests` | Release manifest, CLI link planner, uninstall plan | `ReleaseTests` |

## Conventions

- One test class per area, named `<Area>Tests.swift`, in the target that matches the module.
- **Story tests** are named `testSNNN_UTnn_camelCaseName`, for example `testS015_UT01_minimalThemeInheritsDefaults`. Each MVP story's four named tests are listed in the [delivery history](../project/delivery-history.md). Keep them, and don't rename them.
- Extra tests that come out of review go in `*ReviewTests.swift`.
- New work that isn't part of a story uses ordinary descriptive names, for example `testResizeRejectsRatioOutsideBounds`.
- Assert observable behavior **and failure safety**. When an operation fails, check that the previous state is untouched.
- Inject clocks, IDs, the filesystem, processes, the clipboard, the Keychain and transports. Don't sleep in tests unless you're exercising a real PTY.

## Isolation

- Integration tests may spawn real PTYs, but they must use temporary directories and `--state-directory`, and clean up their process groups.
- Never touch the user's workspace, Keychain, saved hosts or SSH configuration.
- Contract fixtures are read from `docs/` (`docs/api/example-layout.json`, `docs/themes/*.json`). If you move them, update `LayoutAutomationTests` and `ThemeValidationTests`. The bundled theme examples in `Sources/TrellisCore/Resources/Themes` must stay byte-for-byte identical to `docs/themes`.

## Useful filters

```sh
swift test --filter TrellisCoreTests
swift test --filter TrellisUITests.TabManagementTests
swift test --filter 'S017_UT'
```

## Beyond unit tests

| Check | Command | When to run it |
| --- | --- | --- |
| Launcher regression | `python3 scripts/test-feasibility-launcher.py "$(swift build --configuration debug --show-bin-path)"` | After changing launching, bundling or resources |
| App bundle | `scripts/run-feasibility.sh --build-only` | Same |
| Qualification | `python3 scripts/qualify.py [--quick]` | After changes that could affect performance or lifecycle. It writes `docs/evidence/S031-qualification-results.md`. |
| Release gate | `scripts/package-release.sh` | Before a release |

Manual checks that can't run here, such as VoiceOver, real IME, keyboard layouts, older macOS, Intel hardware and notarization, are recorded as **pending**. See [Verification](../quality/verification.md).

## CI

[`ci.yml`](https://github.com/layerx-labs/trellis/blob/master/.github/workflows/ci.yml) runs lint, the build (no new warnings in project sources), the full test suite and the launcher regression on `macos-26` with Xcode 26. It runs for every pull request and push to `master` or `develop`.
