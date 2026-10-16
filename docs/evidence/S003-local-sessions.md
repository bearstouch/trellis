# S003 configurable local sessions

Status: implemented and independently reviewed. Date: 2026-10-16. S001's unperformed physical VoiceOver/IME checks remain outstanding; the user explicitly instructed continuing implementation without treating them as passed.

## Changes

- [LocalLaunch](../../Sources/TrellisCore/LocalLaunch.swift) validates executable/directory access, rejects embedded NULs and malformed environment entries, preserves argv boundaries, applies overrides, and removes reserved Trellis control credentials from inherited/overridden environments. Login shells use the system account shell or an explicit configured path and `-l`.
- [LocalSessionController](../../Sources/TrellisCore/LocalSessionController.swift) reports stopped/starting/running/closing/exited/failed states, buffers early exits until launch completes, preserves a resize made during asynchronous launch, and makes stop/exit callbacks idempotent. It does not infer prompt readiness or shell-command completion.
- [POSIX shim](../../Sources/TrellisPOSIX/spawn.c) allocates a controlling PTY and process group, applies cwd/argv/environment, closes unrelated inherited descriptors, resets inherited signal policy, and reports exec/chdir failures over a close-on-exec pipe. Only async-signal-safe C operations run between fork and exec.
- [PTYProcess](../../Sources/TrellisTerminal/PTYProcess.swift) moves filesystem preflight/spawn off the UI actor and uses DispatchIO for asynchronous reads/writes. One read of at most 16 KiB is delivered before the next is armed, bounding queued UI output. Native input remains bounded to 1 MiB with explicit overload/failure reporting. DispatchIO exclusively owns descriptor release.
- [NativeTerminal](../../Sources/TrellisTerminal/NativeTerminal.swift) accepts configurable local launch values while retaining the fixed isolated fixture for regression work. Terminal parsing/rendering stays on the native view's main actor in bounded batches; responsiveness/performance budgets require S031 measurements.

## Review fixes

The independent reviewer found and fixed four defects: an implicitly main-actor-isolated DispatchIO cleanup callback invoked off actor; inherited GCD signal masks preventing Ctrl-C; inherited app descriptors leaking into children; and terminal size changes lost while validation/spawn awaited completion. Each fix has regression coverage. The C shim also keeps handshake descriptors above standard input/output/error when host stdio is absent.

## Acceptance evidence

- Planned unit tests cover rejected inaccessible directories with zero spawn calls, exact argument preservation, credential filtering, and duplicate stop/exit handling.
- Real PTY fixtures verify cwd containing spaces, literal metacharacter argv, environment overrides, initial/changed terminal size, terminal foreground process-group ownership, and final-output/descriptor cleanup.
- Exec/chdir failures after permissive preflight return typed spawn failures. A successfully executed shell exiting 127 remains an ordinary exit, not a launch failure.
- Both `/bin/zsh -f` and `/bin/bash --noprofile --norc -i` passed isolated job-control tests: start foreground sleep, Ctrl-Z, foreground resume, Ctrl-C, then Ctrl-D exit. They do not attach to existing sessions or read user shell startup files.
- Existing Unicode/accessibility/alternate-screen, large-input/backpressure, EOF, reaping, and model tests remain in the suite. Review added explicit inherited-descriptor and launch-time-resize checks.

Full suite: **43 tests passed, 0 failures**, with a clean Swift 6 build. The reviewer’s final stopped-job cleanup improvement was applied and the zsh/bash integration test was rerun successfully. No global credentials, terminal transcripts, or user session output are saved as test artifacts. Supported OS/architecture runtime qualification and the S001 physical interaction checks are not inferred from these tests.

## Reproduce

```sh
swift test
scripts/run-feasibility.sh
```
