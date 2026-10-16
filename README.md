# uTerm

Native Swift terminal for macOS. Product direction: light Native calm chrome, dark terminal panes, Monaco, sidebar windows and independent renameable tabs with nested splits.

Implementation is progressing one story at a time, with independent agent review, fixes, and a commit between stories; see the [story plan](specs/00-stories/README.md) and [evidence](docs/evidence/).

S001 has a runnable terminal feasibility host with manual VoiceOver/IME acceptance still pending. S002’s authoritative workspace model is complete and reviewed. The user has directed continuing with S003 and subsequent stories while S001’s manual qualification remains recorded as pending; the full application UI is not built yet.

## Development

Requires Xcode 26 / Swift 6.2, provisionally macOS 14 or later. This is a feasibility host, not the finished application.

```sh
swift build
swift test
swift run uTerm
swift run uTerm --fixture
scripts/run-feasibility.sh
scripts/run-feasibility.sh --build-only
```

`--fixture` runs a fixed, isolated shell demonstration and exits its child with code 7; the window remains inspectable. The ordinary host starts a new login shell in your home directory. Use Quit to close it with confirmation. Terminal output and typed input are not logged.

SwiftTerm 1.20.0 is vendored at revision `5d14406844143538cd8f8851d2d8a67c1fe443e5` with small font-change fixes. Its MIT license, provenance, and reproducible engine delta are in [ThirdParty/SwiftTerm](ThirdParty/SwiftTerm/PATCHES.md). Engine-specific APIs stay inside UTermTerminal; UTermCore contains the engine-independent adapter.

The launcher assembles a fresh development app, applies a local ad-hoc signature, verifies the completed bundle, then opens it. `--build-only` packages and verifies without opening a window. This local signature does not require an Apple account; distribution signing/notarization remains S032.

After building, run the isolated launcher regression with `python3 scripts/test-feasibility-launcher.py "$(swift build --configuration debug --show-bin-path)"`. It uses real signature verification and does not open windows.
