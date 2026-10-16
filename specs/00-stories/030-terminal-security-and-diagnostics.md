# S030 — Protect terminal interactions and private diagnostics

Priority: P0 / MVP  
Status: Implemented — independently reviewed (engine patch), 295 tests pass; native link/clipboard/diagnostics checks pending  
Delivery phase: 5  
Depends on: [S003](003-local-pty-session.md), [S011](011-selection-and-copy.md), [S012](012-safe-paste-and-file-paths.md), [S022](022-automation-grants.md), [S025](025-automation-output-and-events.md)  
Requirements: `NFR-S03`, `NFR-S05`, `NFR-S08`, `NFR-S09`, `NFR-U05`, `INT-08`

## Story

As a terminal user, I want to use untrusted terminal output without exposing clipboard data, credentials, or private history.

## Acceptance criteria

- [ ] **S030-AC01:** Disable terminal-originated clipboard read/write requests including OSC 52 by default; v1 agents have no clipboard capability.
- [ ] **S030-AC02:** Open links only after a user gesture and only for http/https/mailto; reject unsafe/custom schemes and never treat output as trusted control instructions.
- [ ] **S030-AC03:** Keep logs/errors free of tokens, typed input, terminal output, passwords, and key contents; diagnostics export is explicit and previewable.
- [ ] **S030-AC04:** Collect no telemetry or clipboard history by default; denied paths/capabilities produce actionable sanitized errors rather than blanket permission requests.

## Unit tests

These are test specifications to implement with the story, not executed tests. Names are proposed and may follow repository conventions once the Swift project exists. Isolate time, filesystem, process, Keychain, clipboard, and transport dependencies as relevant; assert observable behavior and failure safety.

| Test | Setup, action, and expected result |
| --- | --- |
| `S030_UT01_osc52CannotReadOrWriteClipboard` | Feed clipboard escape sequences through the adapter; pasteboard spy receives no reads or writes. |
| `S030_UT02_validateUrlAndGesture` | Try allowed schemes with/without a gesture and forbidden file/javascript/custom URLs; open only valid user-initiated links. |
| `S030_UT03_sanitizeErrorsAndDiagnostics` | Inject recognizable secrets and terminal data into failures; public errors/logs/export previews omit them. |
| `S030_UT04_diagnosticCancelCreatesNoExport` | Cancel diagnostic preview; create no exported file or network request. |

## Integration and manual verification

Feed hostile terminal escape/link fixtures in a controlled session; inspect NSPasteboard, logs, error UI, and network activity. Review parser-boundary fuzz results without executing untrusted commands.

## Completion evidence

See [S030 terminal security evidence](../../docs/evidence/S030-terminal-security.md) for clipboard, link, Kitty-file, redaction, and diagnostics tests, review fixes, and pending native checks.

## Source specifications

[Overview](../01-overview/README.md), [architecture](../02-architecture/README.md), [functional requirements](../03-functional-requirements/README.md), [quality requirements](../04-non-functional-requirements/README.md), [API](../05-api/README.md), [integrations](../06-integrations/README.md), [macOS support](../07-macos-support/README.md), [themes](../03-functional-requirements/themes/README.md)
