# S032 — Package and qualify the macOS-only release

Priority: P0 / MVP  
Status: Planned — implementation and tests not started  
Delivery phase: 5  
Depends on: [S017](017-keyboard-and-accessibility.md), [S020](020-ssh-connections.md), [S027](027-cli-and-agent-workflows.md), [S028](028-portable-import-and-export.md), [S029](029-theme-control-api.md), [S030](030-terminal-security-and-diagnostics.md), [S031](031-performance-and-reliability-qualification.md)  
Requirements: `MAC-01`, `MAC-02`, `MAC-03`, `MAC-08`, `MAC-09`, `MAC-10`, `MAC-11`, `MAC-12`

## Story

As a macOS user, I want to install, upgrade, and remove a trusted native app with a usable CLI.

## Acceptance criteria

- [ ] **S032-AC01:** Resolve app identity, confirmed minimum macOS, CPU support, package format, and terminal dependency/license decisions; publish the actual tested OS/architecture matrix.
- [ ] **S032-AC02:** Sign app and bundled CLI, use compatible hardened runtime, notarize/staple as appropriate, and verify Gatekeeper on a clean machine; no root helper or blanket privacy prompts.
- [ ] **S032-AC03:** Provide an explicit user-local CLI-link installation step without silent shell-file/system-directory edits; manual signed upgrades are acceptable for MVP.
- [ ] **S032-AC04:** Document backup/migration/downgrade behavior, known limits, and uninstall cleanup for app-owned files/Keychain entries while protecting SSH config/keys/history. All P0 acceptance evidence is complete before release.

## Unit tests

These are test specifications to implement with the story, not executed tests. Names are proposed and may follow repository conventions once the Swift project exists. Isolate time, filesystem, process, Keychain, clipboard, and transport dependencies as relevant; assert observable behavior and failure safety.

| Test | Setup, action, and expected result |
| --- | --- |
| `S032_UT01_manifestMatchesSupportPolicy` | Validate release metadata/build manifest against selected minimum OS, supported architectures, and required app/CLI artifacts. |
| `S032_UT02_cliLinkPlanIsUserLocal` | Plan CLI installation/removal with fixture home directories; reject paths outside the chosen user-local target and preserve unrelated existing files. |
| `S032_UT03_cleanupAllowlistProtectsUserFiles` | Generate uninstall cleanup for fixtures; never include SSH directories, keys, known-hosts files, or shell history. |
| `S032_UT04_releaseChecklistRejectsMissingEvidence` | Provide incomplete matrix/signing/license evidence to the release-checklist validator; report each missing item rather than marking release ready. |

## Integration and manual verification

Perform real signature/notarization/Gatekeeper checks, install/upgrade/uninstall on clean test profiles, test the bundled CLI, and execute the end-to-end daily-use scenario. Unit tests do not replace Apple distribution verification.

## Completion evidence

Link the implementation and passing relevant tests; record the acceptance demo and any required real-platform results. A story is complete only when its criteria and verification evidence pass. Document blockers rather than marking unavailable checks as passed.

## Scope notes

Packaging checks must verify current Apple tooling during implementation. Do not add an automatic update service in this MVP story.

## Source specifications

[Overview](../01-overview/README.md), [architecture](../02-architecture/README.md), [functional requirements](../03-functional-requirements/README.md), [quality requirements](../04-non-functional-requirements/README.md), [API](../05-api/README.md), [integrations](../06-integrations/README.md), [macOS support](../07-macos-support/README.md), [themes](../03-functional-requirements/themes/README.md)
