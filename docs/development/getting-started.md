# Getting started

## Prerequisites

| Requirement | Version | Notes |
| --- | --- | --- |
| macOS | 14 Sonoma or later | Development happens on recent macOS on Apple silicon |
| Xcode | 26 | Provides Swift 6.2 and `swift format`. If `xcode-select -p` points at the Command Line Tools, run `sudo xcode-select -s /Applications/Xcode.app`. |
| Python 3 | Any recent version | Only for `scripts/qualify.py`, the launcher test and building these docs |
| `librsvg` | Optional | `brew install librsvg`, only for regenerating app icons |

```sh
swift --version        # Apple Swift version 6.2 or later
swift format --version
```

You don't need an Apple Developer account, Homebrew packages or a package-manager bootstrap. SwiftTerm is vendored, so `swift build` works offline.

## Clone, build, run

```sh
git clone https://github.com/bearstouch/trellis.git
cd trellis
swift build
swift run Trellis --state-directory "$PWD/.build/dev-state"
```

**Use `--state-directory` while developing.** Development builds (`swift run`, and the `Trellis Dev` bundle from `run-feasibility.sh`) are the `com.bearstouch.trellis.dev` identity. Without the flag they use `~/Library/Application Support/com.bearstouch.trellis.dev/`, never the installed app's `com.bearstouch.trellis` data, and they have their own instance lock, so they run beside an installed Trellis. Each `--state-directory` folder has its own lock too, so an isolated run never hands off to a dev instance already open on another workspace. The path must be absolute.

## Everyday commands

```sh
swift build                                   # build (must stay warning-free)
swift test                                    # full XCTest suite, about 20 s
swift test --filter TrellisUITests.TabManagementTests   # one test class
swift format -i -r Sources Tests              # format in place
swift format lint --strict -r Sources Tests   # lint: must print nothing
```

The gate to run before every commit:

```sh
swift format -i -r Sources Tests && swift format lint --strict -r Sources Tests && swift build && swift test
```

Formatting uses the toolchain's `swift format` with the repo's `.swift-format`: 4-space indent, 220 columns, and semicolons and multi-variable `let` allowed. There's no SwiftLint or SwiftFormat dependency.

## Running the app

| Command | What it does |
| --- | --- |
| `swift run Trellis` | Runs against your **real** workspace |
| `swift run Trellis --state-directory /abs/path` | Uses a separate workspace and theme library. Recommended. |
| `swift run Trellis --fixture` | Starts an isolated demo window whose fixed shell exits with code 7. The window stays open for inspection. Without `--state-directory` it uses a new empty workspace in `$TMPDIR`, never your dev workspace. |
| `swift run Trellis --no-mcp` | Never starts the MCP server for this launch, whatever Settings → Remote Control says. `--fixture` implies it. |
| `scripts/run-feasibility.sh` | Assembles `.build/Trellis.app`, ad-hoc signs and verifies it, and opens it. Use it when you need a real bundle (icon, Info.plist, resources). |
| `scripts/run-feasibility.sh --build-only` | Same, without opening a window |

`run-feasibility.sh` copies the SwiftPM resource bundles (`SwiftTerm_SwiftTerm` and `Trellis_TrellisCore`) into the app. If you add a target with resources, add it to that script too.

## Using the CLI against a dev build

1. Run the app with `--state-directory`, open **Settings → Automation**, and create a grant. The token is shown only once.
2. Save it to a file only you can read, for example `.build/token.txt`. Never pass a token as an argument.
3. Call the CLI with the same state directory:

```sh
swift run trellis-cli window list --state-directory "$PWD/.build/dev-state" --token-stdin --json < .build/token.txt
swift run trellis-cli          # prints the available nouns
```

See [CLI](../api/cli.md) for every command.

## Editors

- **Xcode:** `open Package.swift`. The `Trellis` scheme runs the app and `Trellis-Package` runs the tests. Launch arguments go in Product → Scheme → Edit Scheme… → Arguments.
- **VS Code or Cursor:** install the [Swift extension](https://marketplace.visualstudio.com/items?itemName=swiftlang.swift-vscode), which reads `Package.swift` and uses SourceKit-LSP.

## Other scripts

```sh
python3 scripts/test-feasibility-launcher.py "$(swift build --configuration debug --show-bin-path)"  # launcher regression, no windows
python3 scripts/qualify.py [--quick] [--renderer metal|coregraphics]  # release qualification, about 5 min; opens isolated app windows
python3 scripts/bench-renderer.py [--quick] [--only NAMES]  # Metal vs CoreGraphics benchmarks, about 25 min; keep its windows visible
scripts/package-release.sh                    # Universal 2 app + DMG (ad-hoc unless TRELLIS_SIGN_IDENTITY / TRELLIS_NOTARY_PROFILE)
scripts/generate-app-icon.sh                  # regenerate icons from Design/AppIcon/*.svg (needs rsvg-convert)
```

## Repository layout

```text
Sources/
  TrellisCore/       engine-independent domain: store, command service, persistence, themes
  TrellisPOSIX/      small C target for PTY and process-group spawning
  TrellisTerminal/   all SwiftTerm-specific code (the only place SwiftTerm is imported)
  TrellisUI/         SwiftUI/AppKit views, AppWorkspaceModel, AutomationService
  TrellisControl/    local JSON-RPC server, framing, grants, events
  TrellisMCP/        optional MCP server (HTTP) over the same authorizer
  TrellisApp/        app entry point, menus, launch arguments
  TrellisRelease/    release manifest, CLI link planner, uninstall allow-list
  TrellisCLI/        `trellis` CLI logic (TrellisCLIMain is the executable)
Tests/               one XCTest target per module
ThirdParty/SwiftTerm vendored SwiftTerm 1.20.0 plus recorded patches
docs/                this documentation, including schemas and the release guide
release/manifest.json  release decisions checked by the release tests
Design/AppIcon/      icon sources
scripts/             launcher, qualification, packaging, icon tooling
mkdocs.yml           documentation site configuration
```

## Troubleshooting

- **`swift format` not found:** `xcode-select -p` points at the Command Line Tools. Switch it to Xcode 26.
- **Concurrency errors when building:** your toolchain is too old. The package needs Swift 6.2 in Swift 6 language mode.
- **The app opened my real workspace:** pass `--state-directory /absolute/path`.
- **Gatekeeper blocks the ad-hoc `.app` on another Mac:** that's expected. Only Developer ID–signed, notarized builds can be distributed.
