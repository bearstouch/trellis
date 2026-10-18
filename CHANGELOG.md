# Changelog

All notable changes to Trellis are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Edit → Clear** (⌘K, also in the pane's context menu) clears the focused pane like Terminal's ⌘K: the scrollback and the output above the prompt go, and the prompt line with anything you've typed moves to the top. Programs in the alternate screen (vim, less) keep their screen. A ⌘K you had already bound to another action keeps working, and Clear starts unbound (FR-C07).
- Desktop notifications: programs can post macOS notifications with OSC 9, OSC 777 `notify` and kitty's OSC 99 (with chunked, base64 and query forms). They appear when you aren't looking at the pane, and clicking one jumps to it. Notification text is cleaned of control characters, length-capped and limited to 5 per pane every 10 seconds. **Settings → Appearance → Desktop notifications** turns them off; the tab's **Input** label still shows (FR-T08).

### Changed

- The DMG now opens as a drag-to-install window: the Trellis icon beside an **Applications** shortcut, over a background with an arrow, and with the Trellis icon on the mounted volume. `scripts/make-dmg.sh` builds it for both the Universal and the single-architecture DMGs.
- The status bar now always reads **Trellis** followed by the app version on the left (also in `swift run` builds), and shows the selected window's name at the right end.

## [0.10.0] - 2026-10-17

This release adds an optional MCP server, saved SSH passwords in the Keychain, richer text rendering, inline images, smart selection and file links, attention and activity cues on tabs, and a terminal bell setting. Trellis now opens in dark mode on first launch.

### Added

- **Settings → Appearance → Bell** chooses what a terminal bell does: Sound (the macOS alert sound, the default), Visual flash, Sound and flash, or Off. A bell still marks the tab as waiting for input whatever the choice (FR-T07).
- The status bar shows the Trellis icon before the window name, and `swift run` builds now show the Trellis icon in the Dock and About panel too.
- Hovering a window in the collapsed sidebar shows a card of its tabs with their live status (busy, waiting for input, failed command, exited) and pane counts; click a tab to jump straight to it (FR-W06). The card replaces the window-name tooltip.
- An optional MCP server lets agents such as Claude Code control Trellis (INT-07). Turn it on in the new **Settings → Remote Control** section, which also sets the interface and port (default `127.0.0.1:7777`). Every API method except event subscriptions is an MCP tool, authorized by the same automation grants: clients send a grant token as a bearer token, and see and run only what the grant allows. It's off by default and listens only on loopback unless you confirm a network address, which warns that the traffic is plain HTTP. Browser origins and DNS rebinding are refused, revoking a grant ends its sessions at once, and `--no-mcp` turns it off for one launch.
- Saved SSH hosts can remember a password in the macOS Keychain (Hosts → Password). It is stored only on this Mac, is never shown again, and is given to `/usr/bin/ssh` through a bundled `SSH_ASKPASS` helper only for the host's password prompt, at most once per connection. Host-key confirmations, key passphrases and any retry are still asked in the terminal. An optional per-host toggle requires Touch ID or the Mac password before each use. Changing the destination, user, port or identity file removes the saved password, as does deleting the host. Exports, the automation API and the CLI never include it.
- Hosts → **Connect in New Window** opens a saved host in a new managed window named after the host.
- Tabs show an animated bar along their top edge while a pane is printing output. Output at a shell-integrated prompt and the echo of your own typing never trigger it. Reduce Motion shows a static bar.
- Smart selection: double-clicking a URL, email address, file path (with its `:line:column` suffix), UUID, IP address, git hash, or a quote around a quoted string selects the whole thing, even across wrapped lines. Elsewhere double-click still selects a word, and programs that use the mouse (such as vim with `set mouse=a`) still receive the click.
- ⌘-click opens file paths and OSC 8 `file://` hyperlinks (`ls --hyperlink`, compilers, `rg`) in the file's default app, and the context menu offers **Open Link**, **Copy Link**, **Open**, **Reveal in Finder** and **Copy Path** over links. Apps, executables, scripts, installers and other files that could run code are only revealed in Finder. Files open only from local panes: relative paths need shell integration's directory, saved SSH host panes and panes started as `ssh` or `mosh` never open paths, `file://` links naming another host are refused, and network automount paths (`/net`, `/Network`) are never touched.
- Font ligatures, on by default and drawn on the cell grid: with JetBrains Mono, `->`, `!=` and `<=>` join, and text after them keeps its columns. The character under the cursor is drawn on its own. Settings → Appearance → **Ligatures** turns them off.
- Inline images with iTerm2's image protocol (OSC 1337): `imgcat`, `yazi`, `timg`, `chafa -f iterm` and other tools show PNG, JPEG, GIF, BMP, TIFF, WebP and HEIC images in the terminal, including images sent in parts. Sessions set `LC_TERMINAL=iTerm2` so tools detect it. File downloads (`inline=0`) are ignored, documents such as PDF and SVG aren't decoded, and oversized images are refused.
- Overline text (SGR 53/55), and rapid blink (SGR 6) blinks like SGR 5.
- Settings → Appearance adds **Bold as bright colors**, **Use bold fonts**, **Use italic fonts** and **Allow blinking text**. All are on by default; settings saved by earlier versions keep these defaults.
- Tabs show an **Input** label when their program is waiting for you: a password prompt (sudo, ssh, `read -s`) while it lasts, or a bell or terminal notification (OSC 9, OSC 777) from a pane you aren't looking at, such as a coding agent asking for permission. The window list marks windows with a waiting pane, and `session.get` reports `waitingForInput`.

### Changed

- Dark is now the first-launch appearance. Settings saved by an earlier version keep their mode.
- In the About panel, "LayerX Labs" links to https://layerx.xyz.
- Bold white text (SGR 1;37) is now drawn bright white, like bold text in the other base colours.
- Concealed text (SGR 8) is now hidden. Its background still shows, and copy and search still see the text.
- Underline, strikethrough and overline now cover the whole width of wide characters, emoji and ligatures, and dotted, dashed and curly underlines join up across colour changes.
- Any OSC or APC escape sequence longer than 8 MiB is now dropped instead of being buffered without limit.
- OSC 8 hyperlinks whose URL contains `;` are no longer cut off at the first `;` after the parameters.
- More space between the sidebar toggle and the New Window button in the collapsed sidebar.

## [0.9.2] - 2026-10-17

### Added

- Tabs can carry a color label: right-click a tab and choose **Color** (red, orange, yellow, green, blue, purple, gray, or None). A labeled tab shows a colored stripe and a light tint, VoiceOver reads the color name, and the label is saved with the workspace and kept when a tab is duplicated. Automation sets it with `tab.update` (`"color": "blue"`, or `null` to clear) and `trellis tab color --tab <tab> --color blue|none`.
- The window sidebar can be collapsed into a narrow rail that shows each window as a square with its initials. Selection, activity markers, tooltips with the full name, and the context menu still work there. Toggle it with the sidebar button or View → Hide/Show Sidebar (⌃⌘S); the choice is remembered across launches.
- Shell integration for zsh, bash (including macOS `/bin/bash` 3.2) and fish, on by default and loaded without editing dotfiles. Trellis tracks each shell's current directory, so new splits and tabs open there. A failed command shows an exit-status indicator on its tab and pane, and unrenamed tabs show the running program or directory. Edit → Previous/Next Prompt (⌘↑/⌘↓) jumps between prompts. Marks are authenticated with a per-session nonce, so output can't forge them. Turn it off in Settings → Sessions.
- Settings → Sessions → Shell is now a picker of the installed shells (`/etc/shells` and Homebrew), with **Other…** for any path. It marks which shells support shell integration.
- Five more terminal fonts ship with the app: JetBrains Mono, Cascadia Mono NF (includes Nerd Font glyphs for Powerline and icon prompts such as starship, oh-my-posh and powerlevel10k), IBM Plex Mono, Iosevka Fixed (narrow, so more columns fit in splits) and Atkinson Hyperlegible Mono (designed for legibility). Each comes in Regular, Bold, Italic and Bold Italic, appears in Settings → Appearance → Terminal font, and is registered for Trellis only.

### Fixed

- Restored workspaces reopen each local shell pane in the directory it was last in, as reported by shell integration, instead of the directory it started in. SSH panes and custom processes are unchanged.

### Changed

- Roboto Mono (Regular, Bold, Italic, Bold Italic) now ships with the app and is the default terminal font. It's registered for Trellis only, so it doesn't need to be installed and doesn't appear in other apps. The app chrome keeps system fonts. Existing workspaces keep the terminal font they saved, including Monaco; choose Roboto Mono in Settings → Appearance to switch.
- Development builds now use their own identity, `dev.trellis.dev`, separate from the installed app (`dev.trellis`). They have their own instance lock, state directory and control socket, so an installed Trellis and a development instance can run at the same time. The feasibility bundle is now named "Trellis Dev".
- The Hosts window now matches Settings: a themed sidebar with a HOSTS header and the same selection styling, a 1 px border, and a titled editor pane. It follows the active app theme.

## [0.9.1] - 2026-10-17

This release adds new themes and font choices, refines the terminal layout, and makes closing shells smoother.

### Added

- 10 editor-inspired theme families, each with dark and light variants: Modern, One, Monokai, Solarized, Nord, Dracula, GitHub, Tokyo, Gruvbox and Rose Pine. They are Trellis adaptations with complete app and terminal palettes, available without importing files. Their light variants use light terminal backgrounds; the original Trellis Light and Trellis Dark themes keep terminal panes dark.
- Settings → Appearance → Terminal font is now a picker that lists the monospace typefaces installed on your Mac (one entry per family) and previews the selected font. A saved font that is no longer installed is shown as unavailable.
- Trellis → About Trellis, showing the version, copyright and license.

### Changed

- Settings now use sidebar navigation in a wider panel.
- Trellis runs as a single app instance per user. Opening it again, including with a different `--state-directory`, brings the existing window forward. The instance lock is released automatically when the app quits or crashes.
- The terminal scrollbar stays hidden while idle. It appears when you hover over its track or when scrolling moves the viewport, and fades out one second later. Incoming output alone does not reveal it, and showing it never changes the terminal grid width.
- Terminal layout refinements: the pane border is gone, terminal content has subtle padding, the terminal toolbar rows are merged into one, the gap below the terminal grid is removed, and pane dividers are one pixel wide.
- `scripts/qualify.py` writes its report to `.build/` by default.
- The contributor documentation moved from `specs/` to an MkDocs site under `docs/`.

### Fixed

- Closing a running interactive shell no longer asks you to force-stop it. Trellis now sends SIGHUP, like a terminal hangup, instead of SIGTERM, which shells such as zsh ignore. Force (SIGKILL) is still a separate, explicit step.

## [0.9.0] - 2026-10-16

This is the first public release of Trellis, previously named uTerm. It is a native Swift terminal for macOS 14 and later, built for Apple silicon and Intel (Universal 2). This release delivers the full MVP. It is a pre-1.0 release, and some platform checks are still pending; see [Known issues](#known-issues).

### Added

#### Terminal and sessions

- A native terminal built on SwiftTerm 1.20.0, which is vendored with recorded patches. All engine-specific code is kept behind an adapter.
- Local sessions run your configured login shell in a real PTY that owns its process group. Sessions take an initial size, a working directory and allowed environment overrides. Application control secrets are removed from the child environment.
- Session states are shown throughout: stopped, starting, running, exited or failed. Exit status is reported, and the output of an exited session stays inspectable until you restart it.
- Safe closing: closing running sessions shows a summary of what will be affected, and cancelling sends no signal. If you confirm, Trellis terminates the process group gracefully and waits up to 2 s before offering an explicit force option. Trellis never signals a reused PID.
- Restart creates a fresh session in the same pane.

#### Windows, tabs and splits

- Managed windows in a left sidebar. You can create, rename, reorder, select and delete them. Each window keeps its own active tab and pane, and inactive windows show activity and exit indicators.
- A tab bar for each window with inline renaming (double-click or Rename; Enter commits, Escape cancels). You can reorder, duplicate (which copies the layout into fresh sessions, without output or typed history) and close tabs.
- Nested splits: Split Left/Right and Split Top/Bottom on any pane, up to depth 16 and 100 panes. Closing a pane collapses its parent split into the remaining sibling.
- Pane resizing by dragging or with the keyboard (each pane keeps at least 20 × 5 cells), directional focus navigation with a visible focus ring, and temporary maximize that restores the exact layout afterwards.
- One native application window with a menu bar, Dock behavior, full-screen and multi-monitor support, and an empty state. Automatic macOS window tabbing is disabled.

#### Persistence and recovery

- Atomic, versioned workspace saves (debounced, and flushed on quit) of names, order, split ratios, selection and settings. Files are owner-only (`0600`/`0700`).
- Restored workspaces open with every session **stopped**. Live processes are never resurrected and typed input is never replayed.
- A last-known-good backup and corrupt-file preservation, with a recovery choice of restoring the backup or starting an empty workspace. A newer, unsupported format opens in read-only recovery and is never overwritten.
- Terminal output, input transcripts, tokens and secret environment values are never persisted.
- Automatic migration from uTerm. On first launch Trellis copies existing uTerm data into `~/Library/Application Support/dev.trellis/` and leaves the originals untouched.

#### Copy, paste and search

- Selection by drag, word or line, plus Select All, Copy and Copy All Retained Text. Text is copied as plain Unicode. Cmd-C with no selection does not send SIGINT.
- Safe paste: pasting multiline text or text with control characters opens a review first, showing the line count, visible control characters and the target pane. Cancelling sends nothing. Bracketed paste is used only when the shell negotiates it.
- Paste Escaped Path, for pasting file paths into supported shells.
- Scrollback of 10,000 lines per pane by default, with a 16 MiB cap per pane. Per-pane search runs forward and backward and shows the current match, and Trellis tells you when older history has been evicted.

#### Appearance and themes

- Light "Native calm" application chrome with dark terminal panes and Monaco as the default font. Menlo is used as a fallback, with a notice.
- Light, Dark and System chrome modes, with separate Light and Dark theme slots.
- Font family and size, zoom, cursor style and scrollback settings. Changes apply live without restarting sessions.
- A JSON theme format (v1). A minimal theme needs only `version`, `id`, `name` and `appearance`, and anything omitted inherits from the matching built-in theme. Validation is strict: malformed JSON, duplicate keys, unknown fields, bad colors and files over 64 KiB are rejected, errors point to the exact field, and you get advisory contrast warnings.
- A theme library in Settings → Themes:
  - load a file or a bundled example;
  - preview it in a sample terminal, or temporarily across the whole workspace;
  - save it with Save & Use, or replace an existing theme with Replace Theme;
  - export a theme, either as written or with every value resolved (Export Resolved);
  - delete themes, open the Themes folder, or reload themes from disk.
  Cancelling a preview restores your exact prior appearance.

#### Keyboard and accessibility

- Rebindable menu shortcuts for windows, tabs, splits and search. Conflicting bindings are rejected before they are saved.
- A configurable Option-as-Meta setting, off by default so the Option key still types characters for your keyboard layout.
- Accessibility labels, roles, selected states and focus indicators across the sidebar, tab bar, rename fields, panes, dialogs and status text. Trellis never needs blanket Accessibility permission to work.

#### SSH hosts

- A saved host library (File → Hosts…). Each host has a display name, an alias or hostname, and optionally a user, a port, an identity-file path and tags. Hosts are searchable and validated. Only metadata is stored, in `hosts.json`; passwords and key contents are never saved.
- Read-only discovery of literal host aliases from `~/.ssh/config`, previewed before anything is added. Wildcard and `Match` sections are never materialized or executed, and Trellis never edits your SSH files.
- Connections run through `/usr/bin/ssh` with a validated argument array, in a new tab or a split. Host-key and authentication prompts are left to OpenSSH, and Trellis never adds options that bypass trust checks. Failures stay visible, and Trellis reconnects only when you ask.

#### Automation API

- A local control socket: newline-framed JSON-RPC 2.0 over an owner-only Unix socket, discovered through `control.json`. The discovery file contains no token, and the API never listens on TCP. Peer UIDs are checked, symlinked endpoints are rejected, and requests are limited to 1 MiB.
- Automation grants, created in Settings → Automation. Grants are scoped, expiring and revocable. The token is shown once, the secret is stored in the Keychain, only a hash is written to disk, and failed attempts are rate-limited.
- Separate capabilities control metadata, layout, start, input, execute, output, close, host and theme access.
- Resource methods for windows, tabs, panes and hosts, plus `session.get` and `system.info`. They support `expectedRevision` conflict checks and idempotency keys. Panes created through the API stay stopped unless you explicitly ask to start them.
- Session control:
  - `session.start` and `session.restart`;
  - `session.sendInput`, which sends literal or paste input of up to 64 KiB per call;
  - `session.execute`, which submits a shell command;
  - `host.connect`.
  Each needs its own capability, and input is never retried automatically.
- Output and events: plain-text screen and scrollback snapshots, raw output deltas read through cursors (8 MiB global budget), and ordered workspace events (a 1,000-event ring, with replay-gap signalling). Slow clients are disconnected once their outbound queue reaches 1 MiB.
- Declarative v1 layouts that you can validate, plan and apply by namespace and key, with stable IDs, and then export. New panes stay stopped unless you set `startNew`.
- Theme and appearance control: `theme.list`, `get`, `validate`, `import`, `export` and `delete`, plus `appearance.get` and `appearance.set`, behind the `theme.read` capability and a global `theme.write` capability. Theme changes never start or restart sessions.

#### `trellis` CLI

- Commands for appearance, cli, events, host, layout, pane, session, system, tab, theme and window, using explicit UUIDs.
- Credentials come only from `--token-stdin` or `--keychain-grant`, never from a token argument.
- `--json` writes a stable `ok`/`result`/`error` envelope to stdout and sends diagnostics to stderr. Exit statuses are documented, and commands are never retried automatically.
- `--launch` lets the CLI start the app. Without it, the CLI reports that the app is unavailable.
- `trellis cli install-link` creates a single symlink in a user-local directory (`~/.local/bin` by default). It never edits shell startup files or system directories.

#### Import and export

- File → Export Workspace… writes portable, versioned layout and host JSON. Runtime IDs, buffers, transcripts, keys, tokens and secret environment values are left out.
- File → Import Workspace… shows a review first, with counts, launch references and collisions. Imported resources get fresh IDs and stopped panes. Host collisions require an explicit policy, and host imports commit atomically.

#### Security and diagnostics

- Terminal output cannot use the clipboard (OSC 52 is refused) or write local files (Kitty file transfer is refused).
- Links open only on Cmd-click, and only for `http`, `https` and `mailto`.
- Logs and errors never contain tokens, typed input, terminal output, passwords or key contents.
- Help → Export Diagnostics… previews an allow-listed report before saving it.
- No telemetry and no clipboard history.

#### Release and tooling

- A Universal 2 (arm64 + x86_64) `Trellis.app` that bundles the CLI at `Contents/Helpers/trellis`. Both are signed with the hardened runtime and request no entitlements, root helpers or blanket privacy permissions.
- `scripts/package-release.sh` builds the DMG, optionally notarizes and staples it, and writes `dist/release-evidence.json`.
- `scripts/qualify.py` runs release-build performance and reliability qualification on isolated temporary state.
- `scripts/run-feasibility.sh` builds and launches an ad-hoc-signed development bundle.
- A release guide covering install, upgrade, backup, downgrade and uninstall (including the Keychain cleanup allow-list).

### Performance

Measured on the release build on an Apple M1 Pro running macOS 26.6. Reproduce with `python3 scripts/qualify.py`; see [status](docs/overview/status.md).

| Target | Result |
| --- | --- |
| Cold launch ≤ 2 s (p95) | 348 ms |
| Typing echo ≤ 50 ms (p95, API proxy) | 0.4 ms |
| Tab switch ≤ 100 ms (p95, API proxy, 100 live panes) | 11 ms |
| 10 windows / 50 tabs / 100 sessions | Met |
| App memory ≤ 300 MiB with 10 idle panes | 73 MiB |
| Idle CPU < 2 % of one core | 0.38 % |
| 100 create/close cycles leave no file descriptors or child processes behind | Met |
| 10 MiB/s output flood for 60 s | **5.15 MiB/s (missed)** |

### Known issues

- Output throughput under a sustained flood reaches about 5 MiB/s, short of the 10 MiB/s target. Navigation stays responsive during a flood, and memory stays bounded.
- Echo and tab-switch latency were measured through the control API. These measurements leave out on-screen frame rendering.
- Manual VoiceOver, IME, dead-key and keyboard-layout checks are pending.
- Only one machine has been qualified. Older macOS versions and Intel hardware have not been tested yet.
- Developer ID signing and notarization are not configured yet. Ad-hoc builds are for local testing only and are blocked by Gatekeeper on other Macs.
- The bundle identifier `dev.trellis` is provisional.
- MVP limits: one native application window (independent native windows are planned), and upgrades are manual, with no auto-update.

[Unreleased]: https://github.com/layerx-labs/trellis/compare/v0.10.0...HEAD
[0.10.0]: https://github.com/layerx-labs/trellis/compare/v0.9.2...v0.10.0
[0.9.2]: https://github.com/layerx-labs/trellis/compare/v0.9.1...v0.9.2
[0.9.1]: https://github.com/layerx-labs/trellis/compare/v0.9.0...v0.9.1
[0.9.0]: https://github.com/layerx-labs/trellis/releases/tag/v0.9.0
