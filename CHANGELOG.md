# Changelog

All notable changes to Trellis are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- **Save as Project** keeps each pane's folder when the project is reached through a symbolic link, instead of warning that every pane is outside the project; tasks no longer add a `cd` when the shell is already in the project through a link (FR-WF06, FR-TK05).
- **Save as Project** warns that SSH panes and panes running another program will reopen as local shells, instead of saving them silently as plain shell panes (FR-WF06).
- **Scratchpad:** line numbers and issue marks no longer shift by one when the editor is scrolled into a wrapped line, and only newlines start a line, as validation counts them (FR-SP02, FR-SP04).
- **Command palette:** typing stays responsive with long queries or long task commands: each keystroke searches once, queries over 64 letters match nothing, and only the first 512 characters of a row are searched (FR-CP04).
- **Save as Project**, adding a task and **Create launch.json** refuse a `.trellis` folder that is a symbolic link, instead of writing wherever it points (FR-WF06, FR-TK02).
- **Upgrading from `dev.trellis`** while the previous app is still running no longer shares its session broker, which left Keep Running sessions unable to start; after it has quit, kept sessions are still reattached (FR-R03).
- **Command palette:** closing it while a tab is being renamed returns focus to the tab name field, instead of to a terminal whose input stays paused (FR-CP01).
- **Scratchpad:** typing no longer re-renders the whole workspace (tab bar, sidebar and every pane header) on each keystroke; only the panel updates (FR-SP02).
- **Open Project…** (⌘O) is disabled while the workspace is restoring or in recovery, and never records trust for a project it can't open (FR-WF06).
- **Scratchpad:** saving again after **Save as Task** offers the same task name and group, instead of the file name and no group (FR-SP06).
- **Scratchpad:** the private copies **Run** writes are deleted when Trellis quits, or at the next launch after a crash, instead of staying on disk (FR-SP07).
- **Scratchpad:** **Validate** no longer ties up a shared worker thread while the check runs, and its 5-second timeout can never signal a process that has already exited (FR-SP04).
- **Save as Project** keeps the existing file's `$schema` line, so editor validation keeps working after saving over it (FR-WF06).

## [0.13.0] - 2026-10-23

This release adds the command palette and the command scratchpad.

### Added

- **Command palette:** **View → Command Palette…** (⇧⌘P, rebindable) opens a searchable list over the workspace of every enabled action with its shortcut, every window, tab and pane, saved hosts, the focused pane's tasks and the installed themes; Return runs the selected row through its menu path (FR-CP01–FR-CP07).
  - Fuzzy matching with bold, underlined matched letters, alias keywords, recent items first when the field is empty, and **Go to Window/Tab/Pane…**, **Connect to Host…**, **Run Task…** and **Use Theme…** scopes (FR-CP04–FR-CP06).
  - Arrowing onto a theme previews it; Esc restores the previous colors (FR-CP08).
- **Command scratchpad:** a panel beside the panes for writing a command or script, opened with the `</>` button left of **Tasks** in a local pane's header or **View → Show Scratchpad** (⌥⌘E) (FR-SP01).
  - Syntax highlighting in the terminal's font and theme colors, with line numbers and no smart-quote or dash substitution (FR-SP02).
  - A language selector for sh, bash, JavaScript and Markdown; each language is one registry entry, so more can be added (FR-SP03).
  - **Validate** runs `sh -n`, `bash -n` or `node --check` and shows errors with their line numbers (FR-SP04).
  - **Run** types `<interpreter> '<file>'` into the focused pane when its shell is at its prompt, and follows it like a task (FR-SP05).
  - **Save as Task** asks for a task and file name, writes the script to `.trellis/scratch/` and adds a task to `launch.json`; the sheet's **Save & Run** also runs it. The header then shows the saved file's name, with **Edited** after changes (FR-SP06).
  - **Clear** starts an empty buffer, asking first when there are unsaved changes (FR-SP09).
  - A file selector in the panel header lists the project's saved scratchpads and opens one; **Markdown** notes are highlighted and saved without a task (FR-SP10).

## [0.12.0] - 2026-10-22

This release adds project files and tasks from `.trellis/`, and drag reordering for windows and tabs.

### Added

- **Tasks:** a **Tasks** menu in each local pane's header lists the pane's project `.trellis/launch.json` tasks (name, command, optional `cwd`, `group` and `env`) and runs one in that pane's shell (FR-TK01, FR-TK02, FR-TK05).
  - Detects npm/pnpm/yarn/bun scripts, Make targets, CMake, SwiftPM, Python and Cargo builds and tests; run one directly or add it to `launch.json` with **+** (FR-TK03, FR-TK04).
  - The button shows **Running: name** with the elapsed time, then the result with its exit code; **Stop** sends Ctrl-C and becomes **Force Stop** (Ctrl-\) after 2 seconds (FR-TK07, FR-TK08).
  - Environment variables per file and per task, applied to the whole command line (FR-TK09).
  - A `launch.json` version's tasks run only after you review them and choose **Trust and Run**; any change asks again (FR-TK06).
- **Window drag reordering:** drag a window in the sidebar, or a square in the collapsed rail, to move it; an accent bar shows where it lands. VoiceOver gets **Move Up**/**Move Down** actions (FR-W07).
- **Tab drag reordering:** drag a tab along the tab bar to move it; an accent bar shows where it lands. VoiceOver gets **Move Left**/**Move Right** actions (FR-T10).
- **Project files:** a project's `.trellis/project.json`, reviewable in its repository, describes one window: tabs with color labels, splits, pane titles, folders relative to the project, and a command per pane (FR-WF01).
  - When a shell `cd`s into the project, hovering its tab shows **Load Project**. It's also in the tab's context menu and available to VoiceOver (FR-WF02).
  - Commands run only after you review every command and choose **Trust and Open**. Trust is kept per folder and SHA-256 digest, so any change to the file asks again. **Open Without Commands** opens plain shells (FR-WF03).
  - Opening creates the project's window; opening it again reconciles that window without restarting panes or rerunning commands (FR-WF04).
  - Each command is typed at its new shell's first prompt, and the shell stays when the command ends (FR-WF05).
  - **File → Open Project…** (⌘O, rebindable) opens a project folder or its file directly.
  - **Save as Project…** (window sidebar menu) and **File → Save Window as Project…** write the window with editable commands, in a stable, diff-friendly format (FR-WF06).
  - API layouts can now carry tab colors internally, but the automation layout format is unchanged and still never carries commands.

### Changed

- **Clearer names:** "workspace" now means only Trellis's own saved windows (**File → Save Workspace**). **File → Export/Import Workspace…** is now **Export/Import Windows & Hosts…**, and files from the 0.12.0 pre-release named `.trellis/workspace.json` are still opened when a project has no `project.json`; saving writes `project.json` and leaves the old file for you to remove (FR-WF07). Saved keyboard shortcuts and trust carry over.

### Fixed

- **Window close keeps the workspace:** closing the main window with the red button ends the sessions but keeps windows, tabs and splits as stopped panes, so a following Quit no longer saves an empty workspace (MAC-04, FR-R01).

## [0.11.1] - 2026-10-20

The first Developer ID signed and notarized release, under the new `com.bearstouch.trellis` bundle identifier.

### Changed

- The bundle identifier is now `com.bearstouch.trellis` (development builds: `com.bearstouch.trellis.dev`), ready for Developer ID signing. On first launch Trellis copies your workspace, themes and saved hosts from `~/Library/Application Support/dev.trellis/` and imports your preferences; the old folder is left untouched (and is listed by `uninstall-plan`). Because the app is now signed differently, macOS may ask once to allow access to saved host passwords and automation grants in the Keychain.
- JetBrains Mono is now the default terminal font for new installs, with its programming ligatures on (turn them off in Settings → Appearance). Existing settings keep the font they saved; choose JetBrains Mono in Settings → Appearance to switch.

## [0.11.0] - 2026-10-19

This release adds sessions that keep running after quit, restored scrollback, desktop and long-command notifications, progress on tabs, shell marks over SSH, ⌘K Clear and opt-in Metal rendering, plus several security fixes.

### Added

- **Edit → Clear** (⌘K, also in the pane's context menu) clears scrollback and the screen above the prompt, like Terminal. Alternate-screen programs keep their screen; an existing ⌘K binding wins (FR-C07).
- Desktop notifications from OSC 9, OSC 777 and kitty's OSC 99, shown when you aren't looking at the pane; clicking one jumps to it. Text is sanitized, length-capped and rate-limited (FR-T08).
- OSC 9;4 progress on tabs and panes: a filled top edge plus a "50%", "Paused", "Error" or "Working" label, also read by VoiceOver and reported by `session.get` (FR-T09).
- Long-command notifications: with shell integration, a command that ran past a threshold (default 10 s, set in Settings → Sessions) notifies when it finishes out of view. The command line is never shown (FR-SI08).
- Shell marks over SSH: a remote shell's OSC 133/7/1337 marks show "SSH · host:/path", titles, exit badges and notifications. They're display-only and never used for local paths (FR-SI09).
- **Keep sessions running after quit** (opt-in): sessions run in a bundled `trellis-broker` helper and reconnect at next launch with up to 4 MiB of recent output. ⌘Q offers Keep Running, Stop Sessions or Cancel (FR-R03).
- **Restore scrollback after quit** (opt-in): each pane's text, with secrets redacted best-effort, is shown in the stopped pane next launch; 1 MiB per pane, stored unencrypted (FR-R04, FR-R05).
- The empty workspace shows the Trellis prompt mark with a blinking cursor (solid with Reduce Motion).

### Changed

- Opt-in GPU rendering with Metal (**Settings → Sessions → GPU rendering**), matching CoreGraphics output and falling back to it automatically. Roughly 50–90% faster output on an M1 Pro; `appearance.get` reports each pane's renderer (FR-TX05).
- Scrollback and notification settings moved from Appearance to Settings → Sessions.
- Large output is faster: up to 43% for `cat` of big files.
- The DMG opens as a drag-to-Applications window.
- The status bar shows **Trellis** and the app version on the left and the window name on the right.
- The About panel and `LICENSE` credit "bearstouch" instead of LayerX Labs; the panel links to https://github.com/bearstouch.

### Fixed

- A busy tab's context menu (including the Color submenu) no longer closes on its own.

### Security

- Compressed (`o=z`) and chunked kitty graphics images can no longer hang Trellis or exhaust memory.
- Oversized sixel images and numbers are refused instead of crashing or allocating.
- Pasted text can't end a bracketed paste early; `ESC[200~`/`ESC[201~` markers are stripped (FR-C03, FR-C04).
- Creating a saved host, or clearing its user, port or identity file, through the API now also needs `session.execute`.
- DCS sequences are capped at 8 MiB like OSC and APC.
- Release workflow actions are pinned to commit SHAs, and packaging fails when requested notarization fails.

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

[Unreleased]: https://github.com/bearstouch/trellis/compare/v0.13.0...HEAD
[0.13.0]: https://github.com/bearstouch/trellis/compare/v0.12.0...v0.13.0
[0.12.0]: https://github.com/bearstouch/trellis/compare/v0.11.1...v0.12.0
[0.11.1]: https://github.com/bearstouch/trellis/compare/v0.11.0...v0.11.1
[0.11.0]: https://github.com/bearstouch/trellis/compare/v0.10.0...v0.11.0
[0.10.0]: https://github.com/bearstouch/trellis/compare/v0.9.2...v0.10.0
[0.9.2]: https://github.com/bearstouch/trellis/compare/v0.9.1...v0.9.2
[0.9.1]: https://github.com/bearstouch/trellis/compare/v0.9.0...v0.9.1
[0.9.0]: https://github.com/bearstouch/trellis/releases/tag/v0.9.0
