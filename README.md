# Trellis

Previously named uTerm. On first launch, Trellis copies an existing default workspace and theme library into its new Application Support directory, preserving the original files. Existing Trellis data takes priority. Saved built-in theme IDs are upgraded when loaded. During this default-directory migration, custom themes using the newly reserved `trellis-` prefix receive new IDs and their saved selections are updated.

Explicit `--state-directory` paths are used directly. For an older custom library at such a path, change any custom theme IDs beginning with `trellis-` (including their filenames and saved selections) before using Trellis; other custom IDs continue to work unchanged.

Native Swift terminal for macOS. Product direction: light Native calm chrome, dark terminal panes, Monaco, sidebar windows and independent renameable tabs with nested splits.

Implementation is progressing one story at a time, with independent agent review, fixes, and a commit between stories; see the [story plan](specs/00-stories/README.md) and [evidence](docs/evidence/).

Stories S001–S019 now provide the native workspace, local sessions, tabs/splits, clipboard, search, persistence, appearance settings, JSON theme library, configurable keyboard shortcuts with accessibility labels, and a saved SSH host library (File → Hosts…; metadata only, stored in `hosts.json`) with read-only discovery of literal aliases from `~/.ssh/config`. Settings → Keyboard rebinds menu shortcuts (conflicts are rejected before saving) and toggles Option-as-Meta (off by default so Option composes layout characters). Manual VoiceOver/IME and the macOS/CPU release qualification remain pending as recorded in the story evidence.

## Development

Requires Xcode 26 / Swift 6.2, provisionally macOS 14 or later. This is a feasibility host, not the finished application.

```sh
swift build
swift test
swift run Trellis
swift run Trellis --fixture
scripts/run-feasibility.sh
scripts/run-feasibility.sh --build-only
```

`--fixture` runs a fixed, isolated shell demonstration on a new workspace and exits its child with code 7; the window remains inspectable. An ordinary new workspace starts a login shell; saved workspaces restore with sessions stopped. Use Quit to close live sessions with confirmation. Terminal output and typed input are not logged. Use `--state-directory /absolute/path` for a separate development workspace and theme library.

Settings → Themes can load a JSON file or bundled example, preview it in the sample or temporarily in the workspace, and Save & Use it. Cancel Preview, leaving the Themes tab, or closing Settings restores the saved appearance. Existing IDs require the separate Replace Theme action. The same pane offers export, resolved export, deletion, Open Themes Folder, and Reload Themes. Invalid edits keep the last valid in-memory colors; missing selected themes fall back to the matching built-in theme with a notice. Appearance settings choose separate Light/Dark slots. Built-in exports keep reserved IDs; change their ID before importing as a custom copy.

SwiftTerm 1.20.0 is vendored at revision `5d14406844143538cd8f8851d2d8a67c1fe443e5` with small font-change fixes. Its MIT license, provenance, and reproducible engine delta are in [ThirdParty/SwiftTerm](ThirdParty/SwiftTerm/PATCHES.md). Engine-specific APIs stay inside TrellisTerminal; TrellisCore contains the engine-independent adapter.

The launcher assembles a fresh development app, applies a local ad-hoc signature, verifies the completed bundle, then opens it. `--build-only` packages and verifies without opening a window. This local signature does not require an Apple account; distribution signing/notarization remains S032.

The app icon sources live in `Design/AppIcon` (`Trellis.svg` for 64 px and up, `Trellis-small.svg` for 16–32 px, `Trellis-menubar.svg` as a menu bar template). Run `scripts/generate-app-icon.sh` (needs `rsvg-convert`) to regenerate the PNGs, iconset and the `AppIcon.icns` the launcher bundles.

After building, run the isolated launcher regression with `python3 scripts/test-feasibility-launcher.py "$(swift build --configuration debug --show-bin-path)"`. It uses real signature verification and does not open windows.
