# Contribution workflow

## Finding work

- Look for issues labeled `good first issue` or `help wanted`.
- For anything larger than a small fix, open an issue first that describes the problem and the approach you have in mind.
- The P1/P2 backlog and open decisions are in [Roadmap](../project/roadmap.md). Before starting a deferred feature, write its requirements into the relevant docs page and get them agreed. Don't hide new scope inside an unrelated change.

## Making a change

1. Fork the repository and create a topic branch from `master`, for example `fix/split-ratio-rounding`.
2. **Specify:** if behavior changes, update the relevant docs page first or alongside the code, and add new requirement IDs where needed.
3. **Implement**, with tests. See [Testing](testing.md) and [Development rules](rules.md).
4. **Run the local gate.** It must be clean, with no warnings and no lint output:

    ```sh
    swift format -i -r Sources Tests && swift format lint --strict -r Sources Tests && swift build && swift test
    ```

5. If you changed launching, bundling or resources, also run `scripts/run-feasibility.sh --build-only` and the launcher regression.
6. **Review:** get an independent review that looks at correctness, acceptance gaps, security, data loss, races, leaks, regressions and test gaps. Fix what it finds, then run the gate again.
7. **Record evidence:** list what you verified in the pull request, including commands, test counts and manual checks. For qualification work, or for closing a pending item from an MVP story, update the matching `docs/evidence/SNNN-*.md`.
8. **Update the docs:**
    - `README.md` for user-visible changes
    - `CHANGELOG.md` under *Unreleased*
    - [Status](../overview/status.md) if a pending check or known limit changes
9. Open a pull request.

## Honesty rules

- Leave a check unticked unless you actually observed it.
- Record manual checks you couldn't perform here as **pending**, never as passed. That includes VoiceOver, a real IME, keyboard layouts, older macOS, Intel hardware and notarization.
- Document blockers instead of faking results. S031 and S032 are examples of stories recorded as *blocked* with their measurements.

## Commits

This repo uses a [Conventional Commits](https://www.conventionalcommits.org/) style with imperative subjects:

- `feat(S017): add configurable keyboard shortcuts`
- `fix(control): reject oversized subscription topic lists`
- `docs: clarify state-directory usage`

Use an MVP story ID as the scope when the change closes or fixes something in that story. Otherwise use a module or area. Don't commit build output (`.build/`, `dist/`, `site/`), personal Xcode state, or anything from your real Application Support folder.

## Pull requests

A good pull request:

- explains **what** changed and **why**, and links the issue;
- lists **how you verified it**, with any checks you couldn't run marked *pending*;
- includes screenshots or a short recording for UI changes, in light and dark chrome where relevant;
- sticks to one concern.

## Reporting bugs

Open an issue that includes:

- the Trellis version or commit, the macOS version and the CPU;
- reproduction steps, and what you expected to happen versus what did;
- if useful, a report from **Help → Export Diagnostics…**. It's allow-listed and previewed, but review it before attaching.

Don't paste terminal output that contains secrets, tokens or private hostnames.

## Security issues

**Don't open a public issue.** Report vulnerabilities through GitHub's [private vulnerability reporting](https://github.com/layerx-labs/trellis/security/advisories/new). Include the affected version, the impact and minimal reproduction steps.

## Releasing

See the [release guide](../release/README.md). In short:

1. Bump `release/manifest.json` and add the `CHANGELOG.md` section, then commit.
2. Run `git tag vX.Y.Z && git push --tags`.
3. `release.yml` tests the build, packages the DMGs and publishes the GitHub release.
