# Verification strategy

A requirement passes only once it has been **observed**. A dependency claiming to support something doesn't count, and a check that couldn't be run is recorded as **pending**. Never mark it as passed. The [testing guide](../development/testing.md) covers the day-to-day mechanics.

## Layers

| Layer | What it covers | Where |
| --- | --- | --- |
| Unit tests | Domain behavior, validators, state projections and adapters. Clocks, IDs, the filesystem, processes, the clipboard, the Keychain and transports are injected or faked. | `Tests/*` (XCTest) |
| Integration tests | Real PTYs, process groups, filesystem atomicity, Unix sockets and the launcher | `TrellisTerminalTests`, `TrellisControlTests`, `scripts/test-feasibility-launcher.py` |
| Contract fixtures | The [layout schema](../api/layout.schema.json) and [example](../api/example-layout.json), the [theme schema](../themes/theme.schema.json) and examples, plus negative fixtures for boundaries and rejection paths | `docs/api`, `docs/themes`, loaded directly by tests |
| Fuzzing | Protocol framing, split trees, imported files and boundary sizes | `BoundaryFuzzTests` |
| UI and manual checks | Native responder behavior, tab renaming, clipboard review, real Monaco rendering, VoiceOver, IME and dead keys, displays, packaging | Recorded in `docs/evidence/SNNN-*.md` |
| Performance qualification | Release build, documented hardware, repeatable loads, the [NFR budgets](non-functional.md) | `python3 scripts/qualify.py [--quick]` writes [`S031-qualification-results.md`](../evidence/S031-qualification-results.md) |
| Release gate | Signature, hardened runtime, architectures, minimum OS, manifest artifacts, `spctl` | `scripts/package-release.sh` writes `dist/release-evidence.json`; `ReleaseChecklist` |

Faked transports never prove real latency or memory use, so performance claims come only from `qualify.py` running against a release build.

## Safety rules for tests

- Tests must never touch the user's real workspace, Keychain, saved hosts, SSH configuration or production hosts.
- Use temporary directories and `--state-directory`.
- Integration tests that spawn real PTYs must clean up their process groups.
- `qualify.py` runs the release app on isolated temporary state, with a seeded test grant, over the real socket.

## End-to-end release scenario

1. Create Project and Operations windows with independent tabs, and rename a tab inline.
2. Create nested x/y splits and run local commands.
3. Copy a selection and review a multiline paste.
4. Check that the chrome is light, the terminals are dark, and Monaco is active. Import a custom JSON theme and reload it.
5. Connect to a controlled saved SSH host.
6. With the CLI and an approved grant:
    1. discover the IDs;
    2. apply the example layout twice;
    3. explicitly start a process, then observe its exit and the output you're allowed to read;
    4. confirm that a layout-only grant can't read output or execute anything;
    5. revoke the grant.
7. Quit, accepting the single running-session summary. Relaunch, and check that every saved layout comes back stopped with no input replayed.

The [macOS release matrix](../platform/macos.md#release-verification-matrix) lists the platform evidence each release needs.
