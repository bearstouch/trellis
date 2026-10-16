# S001 terminal feasibility evidence

Date: 2026-10-16. Decision: **conditional candidate acceptance; manual acceptance gate remains open**. This is an engineering spike, not the finished application or a qualified release.

## Reproducible environment

- Host: Apple silicon (arm64), macOS 26.6.2 (25G83).
- Xcode 26.0.1 (17A400), Apple Swift 6.2; project uses Swift 6 language mode.
- Deployment target: macOS 14, provisionally. Runtime qualification on macOS 14 and Intel is outstanding.
- SwiftTerm: exact 1.20.0, revision `5d14406844143538cd8f8851d2d8a67c1fe443e5`; dependency graph locked in Package.resolved.
- License: MIT; complete upstream notice retained in [ThirdParty](https://github.com/layerx-labs/trellis/blob/master/ThirdParty/SwiftTerm-LICENSE.txt). Any additional transitive distribution obligations must be checked in S032.

## Architecture decision

SwiftTerm supplies only terminal parsing/rendering/input behavior. [TrellisTerminal](https://github.com/layerx-labs/trellis/blob/master/Sources/TrellisTerminal/NativeTerminal.swift) contains engine-specific APIs. [TerminalAdapter](https://github.com/layerx-labs/trellis/blob/master/Sources/TrellisCore/TerminalAdapter.swift) exposes engine-neutral data, size, retained text, and lifecycle operations.

The application owns PTY/process I/O and reaping through [PTYProcess](https://github.com/layerx-labs/trellis/blob/master/Sources/TrellisTerminal/PTYProcess.swift), using SwiftTerm's small fork/exec helper for process creation. It deliberately avoids LocalProcess/LocalProcessTerminalView: observed source behavior conflates PTY EOF with running state, returns raw wait status, and complicates resource release while keeping the exited terminal view alive. Process state and I/O state are separate in the application wrapper. The eventual configurable/validated launch interface belongs to S003.

TERM is `xterm-256color`: system `infocmp xterm-256color` succeeded; ANSI rendering and alternate-screen round trips passed the fixture. This is a conservative startup choice, not a claim of complete xterm/iTerm2 compatibility. Extended protocols are outside this milestone.

## Verification observed

- Build and XCTest execution on this arm64 host.
- Intel x86_64 cross-build passed with `swift build --arch x86_64 --scratch-path .build/intel`; this verifies compilation only, not Intel runtime behavior.
- Adapter unit cases: ordered output, deduplicated resize forwarding, idempotent detach/rejected post-detach input, explicit unsupported read capability.
- Engine/PTY checks: Unicode including emoji/CJK/combining text, alternate-screen restoration, real shell output, terminal dimensions, and a child exit code of 7.
- Native AppKit host launched with `scripts/run-feasibility.sh --fixture`. Actual window displayed dark terminal background, Monaco text, Unicode, terminal size, and `Fixture complete`; light native title bar remained visible.
- Computer-use accessibility inspection exposed a focused native text area labeled Terminal session containing the actual Unicode fixture output. This proves the accessible text is observable; it does **not** prove spoken VoiceOver navigation quality.
- Terminal-originated clipboard callbacks are explicitly denied. No terminal output/input transcript is saved or logged by the host.

Latest reviewed automated run: **16 tests passed, 0 failures**, Swift 6 build clean. This includes a 128 KiB native-input integrity test, pending-input overload rejection, independent write-source descriptor cleanup under backpressure, actual EOF-before-exit termination, native selection ranges, and programmatic marked-text composition. These are implemented tests, not only the original story test plan.

## Independent review and fixes

A separate review agent inspected the implementation after it was written. The following findings were fixed before this story’s implementation commit:

1. Child exits during a modal quit confirmation: recheck child state after the alert before returning terminate-later.
2. PTY EOF preceding child exit: use actual child ownership/exit state for termination; regression closes terminal descriptors while the child stays alive.
3. Retained terminal views holding exited PTY descriptors: drain final output and release the master through its dispatch-source cancellation handler after reaping.
4. Shared read/write descriptor cancellation: give a pending write source its own descriptor so close ordering cannot race its registration.
5. Large input silently dropped: native input queues are bounded separately from the later API limit, and rejection/I/O failure is explicit to callers and visible in the host.
6. Accessibility limitations: supply a native text-area interface, Unicode-correct extraction, UTF-16 ranges, and value/selection notifications; keep real VoiceOver qualification pending.

Tests also exposed `getBufferAsData` emitting wide-cell NUL continuations and failing to resolve grapheme-table characters. The bridge now uses the engine's Unicode-aware `getText` path for readable snapshots; tests preserve emoji and CJK.

## Outstanding acceptance checks

S001-AC02 and S001-AC04 must remain unchecked until the real interaction checks below pass. Do not call this story Done solely because unit tests pass.

| Check | Current result | Reproduction / required evidence |
| --- | --- | --- |
| Spoken VoiceOver terminal reading and selection navigation | Pending | Run the native host, enable/use VoiceOver through the user's normal setup, read fixture text including emoji/CJK, navigate/select lines, and record actual behavior. Do not grant new system permissions just to claim a pass. |
| Physical IME/dead-key composition | Pending | Run a live host with the user's installed IME, compose and commit text, and verify it reaches the shell once; programmatic marked-text tests are supporting evidence only. |
| Pointer selection and native copy/paste | Pending | Select real rendered Unicode output; use Copy/Paste in the newly created test shell; verify retained text and native responder behavior. Full paste review is S012. |
| Interactive full-screen terminal program and resize | Pending | In an isolated host run less/vim, resize, and confirm screen restoration and input. Automated alternate-screen checks cover the parser boundary only. |
| Minimum macOS and Intel runtime matrix | Pending | Execute the same checklist on available target machines; record exact versions. A cross-compiled executable is build evidence, not runtime qualification. |

## Run locally

```sh
swift test
scripts/run-feasibility.sh --fixture
scripts/run-feasibility.sh
```

The fixture creates its own child and exits it; the normal host creates a new local login shell. It never attaches to an existing terminal session. The temporary development bundle is locally ad-hoc signed and is not notarized for distribution. Native chrome/sidebar/tabs are later stories; this host intentionally tests one terminal surface.

## Follow-up: repeat-launch resource permissions

The user reported a successful Swift build followed by `Permission denied` while copying `Shaders.metal` into an existing development bundle. SwiftPM's shader and its copied destination are read-only (0444); the original recursive copy attempted to overwrite the destination in place.

Updated the launcher to use `cp -f` for the executable and `cp -fR` for the resource bundle. This replaces destination files through their writable parent directories while preserving dependency permissions.

Verification: reproduced the original second-run failure in an isolated app fixture; the patched script then passed two repeated runs, including a read-only executable destination, exact resource contents, unchanged source permissions, and preserved `--fixture` launch arguments. The actual existing app resource bundle was also refreshed twice successfully without opening/closing user windows. Shell syntax check passed. A separate review agent reported no findings. Swift source was unchanged, so the Swift test suite was not rerun for this script-only fix. Manual VoiceOver/IME acceptance remains pending.

## Follow-up: native launch rejected after successful build

The user reported Launch Services `RBSRequestErrorDomain Code=5` with underlying POSIX 162. Local inspection found the generated app failed `codesign --verify --deep --strict` with “code has no resources but signature indicates they must be present,” while the standalone SwiftPM executable verified successfully. The copied executable retained its command-line signature instead of a signature sealing the assembled app.

The launcher now assembles executable, Info.plist, and resources in a fresh staging directory, signs the completed bundle ad hoc with the development bundle identifier, and strictly verifies it before publishing. It uses SwiftPM’s reported bin path, preserves the prior bundle on pre-publication failures, and cleans staging artifacts. Fresh assembly also covers the earlier read-only-resource case without rewriting an executable in place. `--build-only` permits packaging/signature verification without UI launch.

Verification: a real build-only run succeeded, followed by a successful `--fixture` native launch; accessibility inspection showed the fixture terminal output. The normal launch command also succeeded; a process check confirmed the newly launched app remained running with its own `/bin/zsh` child. The installed app passes strict signature verification. The isolated regression in [test-feasibility-launcher.py](https://github.com/layerx-labs/trellis/blob/master/scripts/test-feasibility-launcher.py) passed real signing/seal verification, repeated assembly with a fresh executable inode, read-only shader preservation, unchanged Swift build product, argument forwarding with spaces, build-only behavior, and preservation of the previous signed app after a missing-resource packaging failure. Swift/open are stubbed only inside this isolated regression; real native launch was checked separately. Independent review found no actionable issues. Swift source was unchanged.

Signing follows Apple’s requirement to seal the final bundle contents, described in [Understanding the Code Signature](https://developer.apple.com/library/archive/documentation/Security/Conceptual/CodeSigningGuide/AboutCS/AboutCS.html). This is local development signing, not the distribution qualification scheduled for S032. Manual VoiceOver/IME acceptance remains pending.
