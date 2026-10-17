# Trellis

[![CI](https://github.com/layerx-labs/trellis/actions/workflows/ci.yml/badge.svg)](https://github.com/layerx-labs/trellis/actions/workflows/ci.yml)

A native Swift terminal for macOS. "Native calm" chrome (dark by default, or light or following macOS), dark terminal panes in bundled Roboto Mono, a sidebar of managed windows, renameable tabs per window, and nested splits, plus saved SSH hosts and a local automation API with a `trellis` CLI.

## Features

- **Workspace:** managed windows in a left sidebar, renameable and color-labeled tabs, nested horizontal/vertical splits. Tabs show a busy bar while printing and an **Input** label when a program waits for a password or rings for your attention. Restored workspaces open with sessions **stopped**, and typed input is never replayed.
- **Terminal:** built on a vendored [SwiftTerm](ThirdParty/SwiftTerm/PATCHES.md). Includes scrollback search, safe paste review, copy, and Cmd-click links (http/https/mailto only).
- **Shell integration:** zsh, bash and fish report their current directory and each command's exit status, with no dotfile edits. New splits and tabs open where you are, failed commands are flagged, and ⌘↑/⌘↓ jump between prompts. On by default; turn it off in Settings → Sessions.
- **Appearance:** separate Light/Dark theme slots and a JSON theme library with live preview (Settings → Themes).
- **Keyboard and accessibility:** rebindable menu shortcuts (conflicts are rejected before saving), Option-as-Meta toggle, and accessibility labels throughout.
- **SSH hosts:** a saved host library (File → Hosts…) and read-only discovery of `~/.ssh/config` aliases. Connections run through `/usr/bin/ssh` and never bypass host-key trust. An optional per-host password is kept in the macOS Keychain (optionally behind Touch ID) and given to ssh only for its password prompt.
- **Automation:** an owner-only local JSON-RPC socket with scoped, expiring grants created in Settings → Automation. Covers windows, tabs, panes, sessions, input, output cursors, events, declarative layouts, themes and appearance.
- **MCP server:** optional, off by default. It exposes the same API as MCP tools over HTTP for agents such as Claude Code, using the same grants. Interface and port are set in Settings → Remote Control. See [docs/api/mcp.md](docs/api/mcp.md).
- **Portability:** export and import workspaces with a review step (File → Export/Import Workspace…).
- **Privacy:** no telemetry. Terminal output and typed input are never logged or persisted. Help → Export Diagnostics… previews an allow-listed report before saving.

## Quick start

```sh
git clone https://github.com/layerx-labs/trellis.git
cd trellis
swift build
swift run Trellis --state-directory "$PWD/.build/dev-state"
```

`--state-directory` keeps your development workspace and themes separate from your real `~/Library/Application Support/dev.trellis/` data. Use it whenever you hack on Trellis.

## Development setup

### Prerequisites

| Requirement | Version | Notes |
| --- | --- | --- |
| macOS | 14 Sonoma or later | Development is done on recent macOS on Apple silicon |
| Xcode | 26 | Provides Swift 6.2 and `swift format`. Run `sudo xcode-select -s /Applications/Xcode.app` if `xcode-select -p` points at the Command Line Tools |
| Python 3 | Any recent version | Only for `scripts/qualify.py` and the launcher test |
| `librsvg` | Optional | `brew install librsvg`, only to regenerate app icons |

Check your toolchain:

```sh
swift --version        # Apple Swift version 6.2 or later
swift format --version
```

You don't need an Apple Developer account, Homebrew packages, or a package manager bootstrap. SwiftTerm is vendored under `ThirdParty/SwiftTerm`, so `swift build` works offline.

### Editors

- **Xcode:** `open Package.swift`. Choose the `Trellis` scheme to run the app and `Trellis-Package` to run tests. To pass launch arguments such as `--state-directory /abs/path`, edit the scheme (Product → Scheme → Edit Scheme… → Arguments).
- **VS Code / Cursor:** install the [Swift extension](https://marketplace.visualstudio.com/items?itemName=swiftlang.swift-vscode). It reads `Package.swift` directly and uses SourceKit-LSP.

### Everyday commands

```sh
swift build                                   # build (must stay warning-free)
swift test                                    # full XCTest suite, about 20 s
swift test --filter TrellisUITests.TabManagementTests   # one test class
swift format -i -r Sources Tests              # format in place
swift format lint --strict -r Sources Tests   # lint: must print nothing
```

Before every commit, run this one-liner:

```sh
swift format -i -r Sources Tests && swift format lint --strict -r Sources Tests && swift build && swift test
```

Formatting uses the toolchain's `swift format` with the repo [`.swift-format`](.swift-format) (4-space indent, 220 columns). The repo has no SwiftLint or SwiftFormat dependency.

### Running the app

| Command | What it does |
| --- | --- |
| `swift run Trellis` | Runs against your **real** workspace in Application Support |
| `swift run Trellis --state-directory /abs/path` | Uses a separate workspace and theme library (recommended for development) |
| `swift run Trellis --fixture` | Starts an isolated, fixed-shell demo window whose child exits with code 7. The window stays open for inspection |
| `swift run Trellis --no-mcp` | Never starts the MCP server for this launch, whatever Settings → Remote Control says. `--fixture` implies it. |
| `scripts/run-feasibility.sh` | Assembles `.build/Trellis.app`, ad-hoc signs and verifies it, then opens it. Use this when you need a real bundle (icon, Info.plist, resources) |
| `scripts/run-feasibility.sh --build-only` | Same as above without opening a window |

An ordinary new workspace starts a login shell. Use Quit to close live sessions with confirmation.

### Using the CLI against a dev build

1. Run the app, open **Settings → Automation**, and create a grant. The token is shown only once.
2. Save the token to a file that only you can read, for example `.build/token.txt`. Never pass a token as an argument.
3. Call the CLI:

   ```sh
   swift run trellis-cli window list --token-stdin --json < .build/token.txt
   swift run trellis-cli                      # prints the available nouns
   ```

The packaged app ships this binary as `trellis` (see the [release guide](docs/release/README.md)). The protocol is documented in [`docs/api`](docs/api/index.md).

### Other scripts

```sh
python3 scripts/test-feasibility-launcher.py "$(swift build --configuration debug --show-bin-path)"  # launcher regression, no windows
python3 scripts/qualify.py [--quick]          # release qualification, about 5 min; opens isolated app windows
scripts/package-release.sh                    # Universal 2 app + DMG (ad-hoc unless TRELLIS_SIGN_IDENTITY / TRELLIS_NOTARY_PROFILE)
scripts/generate-app-icon.sh                  # regenerate icons from Design/AppIcon/*.svg (needs rsvg-convert)
```

### CI and releases

- [`ci.yml`](.github/workflows/ci.yml) runs lint, build (no new warnings in project sources), the full test suite and the launcher regression on `macos-26` with Xcode 26. It runs for every pull request to `master` or `develop`, and for every push to those branches.
- [`release.yml`](.github/workflows/release.yml) runs when you push a tag `vX.Y.Z` that matches `release/manifest.json`. It tests, packages the Universal 2 DMG, and publishes a GitHub release whose notes come from the matching `CHANGELOG.md` section. Without signing secrets the build is ad-hoc signed and published as a pre-release. The secrets it uses are listed at the top of the workflow. A manual run builds the DMG as a workflow artifact without publishing anything.

To cut a release, bump `release/manifest.json`, add the `CHANGELOG.md` section, commit, then run `git tag vX.Y.Z && git push --tags`.

## Project layout

```
Sources/
  TrellisCore/       engine-independent domain: WorkspaceStore, command service, persistence, themes
  TrellisPOSIX/      small C target for PTY / process-group spawning
  TrellisTerminal/   all SwiftTerm-specific code (the only place SwiftTerm is imported)
  TrellisUI/         SwiftUI/AppKit views and AppWorkspaceModel
  TrellisControl/    local JSON-RPC server, framing, auth-gated handler
  TrellisMCP/        optional MCP server (HTTP) over the same authorizer
  TrellisApp/        app entry point, menus, launch arguments
  TrellisRelease/    release manifest checks, CLI link planner, uninstall allow-list
  TrellisCLI/        `trellis` CLI logic (TrellisCLIMain is the executable)
Tests/               one XCTest target per module
ThirdParty/SwiftTerm vendored SwiftTerm 1.20.0 + recorded patches
docs/                documentation site (behavior contract, architecture, API, contributor guide)
docs/release/        packaging, install, upgrade and uninstall guide
Design/AppIcon/      icon sources
scripts/             launcher, qualification, packaging, icon tooling
```

Architecture in brief:

- **Window → Tabs → `SplitNode` tree → Pane → Session.**
- All mutations from the UI and the API go through a single `WorkspaceCommandService`.
- PTY I/O runs off the main thread, and views update on `@MainActor`.

The full design is in [the architecture docs](docs/architecture/index.md), and [CONTRIBUTING.md](CONTRIBUTING.md) lists the rules contributors must follow.

## Documentation

The [`docs/`](docs/index.md) folder is the behavior contract and contributor guide: product overview, architecture, features, the automation API and CLI, integrations, macOS support, and development rules. It's plain Markdown, laid out for [MkDocs Material](https://squidfunk.github.io/mkdocs-material/):

```sh
python3 -m venv .venv-docs && .venv-docs/bin/pip install mkdocs-material
.venv-docs/bin/mkdocs serve    # http://127.0.0.1:8000
```

## Data and migration

User data lives in `~/Library/Application Support/dev.trellis/`. Files there are owner-only and written atomically, with last-known-good backups. Newer or corrupt state opens in recovery mode and is never overwritten.

Trellis was previously named **uTerm**. On first launch it copies an existing uTerm workspace and theme library into the new directory and leaves the originals untouched. Existing Trellis data takes priority. Theme IDs that begin with `trellis-` are reserved for built-in themes. During the default-directory migration, any custom theme that uses this prefix gets a new ID, and its saved selections are updated to match. Paths passed with `--state-directory` are used as-is. If an older custom library at such a path has theme IDs that begin with `trellis-`, rename those IDs yourself, along with their filenames and saved selections.

## App instances

Trellis runs one app instance per signed-in user. Opening it again brings the existing window forward, including when launched directly or with a different state directory. Quitting or a crash releases the instance lock automatically.

The installed app (`dev.trellis`) and development builds are separate identities. Development builds are `swift run`, an unbundled release binary, and the `Trellis Dev` bundle from `scripts/run-feasibility.sh`, all `dev.trellis.dev`. Each identity has its own instance lock, activation notification, state directory (`~/Library/Application Support/dev.trellis.dev/` for development) and control socket, so an installed Trellis and a development instance can run at the same time. The `trellis` CLI targets the installed app unless you pass `--state-directory`.

## Themes and terminal fonts

Settings → Appearance includes 10 editor-inspired theme families, each with dark and light variants: Modern, One, Monokai, Solarized, Nord, Dracula, GitHub, Tokyo, Gruvbox, and Rose Pine. These are Trellis adaptations, with matching terminal and app colors. Choose separate light and dark palettes; System appearance switches between them automatically. The original Trellis defaults remain available.

The Terminal font picker lists the monospace typefaces installed on your Mac and previews the selected font. Apply Appearance to save your choice.

Terminals draw font ligatures (with fonts that have them, such as the bundled JetBrains Mono), colour emoji, wide CJK characters and combining marks on the cell grid, along with the usual text styles: bold, dim, italic, underline in single, double, curly, dotted and dashed styles with its own colour, strikethrough, overline, blink, inverse and concealed text. Settings → Appearance turns ligatures, bold-as-bright colours, bold and italic faces, and blinking text on or off.

Programs can show images inline with iTerm2's image protocol, so `imgcat`, `yazi`, `timg` and `chafa -f iterm` work as they do in iTerm2.

## Troubleshooting

- **`swift format` not found:** `xcode-select -p` points at the Command Line Tools. Switch it to Xcode 26.
- **Concurrency errors on build:** you're on an older toolchain. The package requires Swift 6.2 in Swift 6 language mode.
- **The app opens my real workspace:** pass `--state-directory /absolute/path` (the path must be absolute).
- **The ad-hoc `.app` is blocked by Gatekeeper when copied to another Mac:** this is expected. Only Developer ID–signed, notarized builds can be distributed.

## Contributing

Contributions are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) for the workflow, code style, test conventions and how to report security issues.

## License

Trellis is released under the [MIT License](LICENSE). The vendored SwiftTerm is also MIT-licensed. Its license, provenance and patch set are in [`ThirdParty/SwiftTerm`](ThirdParty/SwiftTerm/PATCHES.md).
