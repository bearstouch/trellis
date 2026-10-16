# S032 macOS packaging and release

Date: 2026-10-16. Packaging tooling, release decisions, CLI link management, uninstall planning, a release gate, and documentation are implemented with independent review and fixes. **Release is blocked:** there is no Developer ID signing, notarization, or clean-machine Gatekeeper evidence; the tested matrix is incomplete; and P0 stories still have pending evidence, with S031 blocked.

## Decisions (AC01)

These are recorded in `release/manifest.json` and documented in [docs/release/README.md](../release/README.md):

- identity `dev.trellis` (provisional until a Developer ID team is chosen);
- minimum macOS 14.0, matching `Package.swift` and `LSMinimumSystemVersion`;
- Universal 2 (arm64 and x86_64);
- a signed DMG;
- the CLI bundled at `Contents/Helpers/trellis`;
- SwiftTerm 1.20.0 under the MIT license, with recorded patches and the license shipped in the bundle.

The tested matrix is published honestly: macOS 26.6.2 on an Apple M1 Pro natively, plus the x86_64 slice executed under Rosetta (not a qualification). macOS 14 and 15, native Intel, and a clean machine are untested.

## Packaging (AC02)

`scripts/package-release.sh` builds each architecture natively in release mode and combines them with `lipo`. Xcode's combined multi-arch build needs a Metal toolchain for SwiftTerm's shader, so it isn't used.

The script then:

1. Assembles the app with the bundled CLI, resources, icon, and license.
2. Signs the CLI, then the app, with the hardened runtime, no entitlements, and no `--deep`.
3. Builds a DMG.
4. With `TRELLIS_SIGN_IDENTITY` and `TRELLIS_NOTARY_PROFILE` set, signs with a timestamp, notarizes with `notarytool`, and staples.
5. Writes `dist/release-evidence.json`.

There is no root helper and no privacy-permission request.

**Run here, with ad-hoc signing:**

- the app and CLI are both arm64 + x86_64;
- the strict signature check passes, and both binaries carry the hardened-runtime flag;
- the minimum OS is 14.0 and there are no manifest problems;
- local `spctl` **rejects** the app (expected for ad-hoc);
- notarized and stapled are **false**.

## CLI link (AC03)

`trellis cli install-link [--dir ~/.local/bin]`, `remove-link`, and `uninstall-plan` are explicit, local, and need no credentials. They create or remove exactly one `trellis` symlink, in a directory inside the user's home.

**Refused:**

- system directories;
- `~/.ssh`, `~/Library`, `~/.gnupg`, and git config, compared case-insensitively;
- `..` escapes;
- symlinked directories that resolve outside the home folder.

The planner never overwrites unrelated files and replaces only links that point to a Trellis app's bundled CLI. Removal uses `unlink`, so a directory can never be deleted. It never edits shell files. Only the CLI inside an app bundle installs its own link; its location comes from the executable URL, so it also works when run from `PATH`. Upgrades are manual: replace the app.

## Documentation and uninstall (AC04)

`docs/release/README.md` covers building, installing, the CLI link, upgrading, backups, migration and downgrades (newer formats are opened read-only), uninstalling, known limits, and licenses.

`uninstall-plan` lists exactly four app-owned locations (Application Support, Preferences, Caches, and Saved Application State for `dev.trellis`) plus a valid Trellis link, and the Keychain service "Trellis Automation". `UninstallPlanner.isAllowed` accepts only those exact paths, so SSH files, keys, `known_hosts`, shell startup files, and history can never be included.

`ReleaseChecklist` reports every missing item: the matrix by architecture and minimum macOS major version, the signing steps, notarization, stapling, Gatekeeper, licenses, CLI install, and S001–S031 evidence.

## Tests

- `testS032_UT01_manifestMatchesSupportPolicy`: the committed manifest has Universal 2, the bundled CLI, and an MIT license file present, and its minimum matches `Package.swift`. A product with a missing slice, an older minimum, a missing CLI, and a mismatched package minimum reports all four problems.
- `testS032_UT02_cliLinkPlanIsUserLocal`: covers create, already-installed, and replacement of a moved Trellis link. It also checks that unrelated files and links are preserved, and that system, other-user, `..`, `.ssh`/`.SSH`, `Library`/`library`, and home-root targets are refused.
- `testS032_UT03_cleanupAllowlistProtectsUserFiles`: exactly five items, all under the home folder. SSH files, keys, `known_hosts`, history, rc files, keychains, look-alike `dev.trellis` paths, other users' folders, and `..` traversal are all refused.
- `testS032_UT04_releaseChecklistRejectsMissingEvidence`: an empty checklist lists every gap. The current state (arm64 on 26.6.2, ad-hoc signing, S031 blocked) is reported exactly. Failed runs never count, `140.x` does not satisfy macOS 14, and only a complete checklist is ready.
- CLI tests:
  - the link commands are explicit, local, and refuse overwrites and system targets;
  - a real temp symlinked directory pointing outside the home is refused, and directories are never removed.

Full suite: **309 tests passed, 0 failures**. Lint is clean, the build has zero warnings, and the development app packages and verifies.

## Independent review

The review fixed five issues:

1. A symlinked link directory could escape the home folder, for example `~/bin` → `/usr/local/bin`.
2. Sensitive-folder checks were case-sensitive on a case-insensitive filesystem.
3. The uninstall allow-list used exploitable substring matching.
4. `removeItem` could recursively delete a directory swapped in between the check and the removal; it now uses `unlink`.
5. The minimum-OS evidence was matched by prefix.

It also fixed `install-link` when run from `PATH`. Packaging was re-run with ad-hoc signing, the packaged CLI was exercised against a throwaway `HOME`, and the Intel slice was exercised under Rosetta.

**Incident during development:** an early `install-link` check ignored `$HOME` and briefly created and then removed `~/.local/bin/trellis` in the developer's real home. The directory already existed, nothing else was touched, and no link remains. Home now honors `$HOME`, and every test injects or isolates its paths.

Follow-ups:

- Replace links atomically (rename) instead of removing and recreating them.
- Read the bundle identifier from the manifest in the script.
- Have UT01 read a built `Info.plist`.

## Blocked before release (not marked done)

- Developer ID signing, notarization, stapling, and Gatekeeper on a clean machine (requires an Apple developer account).
- Matrix runs on macOS 14 and 15, native Intel, and displays.
- Pending P0 evidence: S031 flood throughput; manual VoiceOver, IME, and layout checks (S017); real SSH server checks (S020); and the other native demos listed in each story's evidence.
