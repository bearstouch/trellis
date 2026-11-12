# Changelog

All notable changes to Trellis are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Copy from programs over SSH:** Claude Code, tmux, Neovim and other programs on a remote host can now put text on your Mac's clipboard (OSC 52) if you allow it. **Settings → Sessions → Programs can copy to the clipboard** is **Off** by default and offers **From SSH sessions** (saved hosts, remote workspaces, and `ssh`/`mosh`, including one you type in a shell with integration) or **From any program**, which shows a risk warning. Programs can never read the clipboard. Holding ⇧ while dragging still selects text inside programs that capture the mouse.
- **Languages:** Trellis is now available in Portuguese (Portugal), French and Spanish as well as English. It follows your Mac's language; **Settings → Appearance → Language** picks another one for Trellis alone, with no relaunch. Terminal output, names you chose, the `trellis` command and the automation API stay as they are. `--language en|pt-PT|fr|es` picks a language for one launch.
- **Model and effort for Claude Code:** the Agents view's Running list shows the model a Claude Code session uses ("Ardaven · Opus 5.5") and its reasoning effort as a small label next to the tab name, once Claude Code reports them. Trellis reads only these two settings from Claude Code's hooks.
- **Command Palette hint:** the status bar shows the Command Palette shortcut (⇧⌘P by default, or your custom binding) next to the version; clicking it opens the palette.
- **Share the MCP server over Tailscale:** **Settings → Remote Control → Share over Tailscale** publishes the MCP server to your tailnet over HTTPS with `tailscale serve`, so Claude Code, Codex or your own bots on other machines can drive Trellis without an open port or plain-HTTP tokens. Choose which tailnet devices may connect, and copy a ready setup for Claude Code, Codex or any MCP client. Trellis never uses Funnel and removes its entry when sharing stops or Trellis quits.
- **Idle timeout for kept sessions:** a session left running with Trellis closed or disconnected is now ended once it has printed nothing for 24 hours. **Settings → Session Broker → End idle kept sessions after** offers No timeout, 1, 2, 4, 12, 24, 48 and 96 hours. Sessions shown in a pane are never ended. Applies to remote workspace hosts too, once their helper is updated.

### Changed

- **Kept sessions no longer run forever by default:** before, a session kept after quit ran until it ended by itself. Pick **No timeout** to keep that behavior.

### Fixed

- **Clicking a terminal takes the keyboard again with GPU rendering on:** after typing in a sidebar field (the Changes filter, the Files search, the scratchpad), clicking a terminal left your typing in that field. The click now moves the keyboard to the terminal, as it does with GPU rendering off.

## [1.2.0] - 2026-11-10

The stable 1.2 release. Coming from 1.1.0, you also get everything listed under the 1.2 betas: windows renamed to spaces, temporary tabs in project spaces, a right sidebar with Files, Changes, Tasks, Agents and the scratchpad, agents typed in a shell with live state, the welcome tour, translucent panes, the white Trellis Light terminal, and export and import of projects and hosts.

### Added

- **Online documentation:** an end-user guide at [bearstouch.com/trellis/docs](https://bearstouch.com/trellis/docs/) covers getting started, every feature and the automation API, CLI and MCP server. It is built from `docs-public/` with `scripts/build-public-docs.sh`.

## [1.2.0-beta.3] - 2026-11-10

The third 1.2 beta.

### Added

- **User guide:** a static HTML user guide in `website/docs/` explains the Trellis concepts and how to use every feature, with keyboard shortcut and settings references, search (⌘K) and light and dark modes. Open `website/docs/index.html` or serve the folder from any static host.

- **Agents typed in a shell:** typing `claude`, `codex` or `pi` in a local zsh, bash or fish pane now runs it with the same hooks as an agent opened from the Agents view, so its tab shows **Working**, **Needs you** and **Done**, it can notify you, and the Agents view's **Running** list shows it (marked "in a shell") while it runs. Trellis adds a shell function for this; your own function or alias of the same name wins, and `command claude` skips it. Turn it off in Settings → Agents → **Connect agents typed in a shell**. See [Coding agents](docs/features/agents.md) (FR-AG18).

- **Temporary tabs:** a space opened from a library project now remembers its project, shown with a folder symbol in the sidebar. Tabs the project doesn't define (ones you add, duplicate or open for a host or agent) are temporary: their titles are in italics and VoiceOver reads "temporary tab". Launching the project again keeps them, and they never change the project. The API reports `projectId` on spaces and `temporary` on tabs. See [Workspace](docs/features/workspace.md) (FR-W08).

### Changed

- **Windows are now Spaces.** The sidebar's managed windows are called spaces everywhere: **New Space** (⌘N), Rename, Delete, Next and Previous Space, the command palette, VoiceOver and the docs. Your workspace, customized shortcuts, automation grants and launched projects carry over; the workspace file is saved as schema 4, which older Trellis builds open read-only. The API methods are now `space.*` with `spaceId`/`spaceIds`, the CLI is `trellis space` with `--space`, and MCP tools are `space_*`. `window.*`, `windowId(s)`, `trellis window` and `--window` still work for now and are deprecated; events (`space.created`, `selection.space`…), the authentication reply's `spaceScope` and MCP tool names change outright. Layout documents are version 2 (`spaces`); version 1 (`windows`) is still accepted. The macOS **Window** menu keeps its name. See [Methods](docs/api/methods.md#deprecated-names).
- **Export and import carry projects and hosts.** **File → Export Projects & Hosts…** replaces Export Windows & Hosts: the file (version 2) holds your project library and saved hosts, not spaces, which are what projects become once launched. **Import Projects & Hosts…** adds projects under new identities, never over yours (a name already in use gets " (imported)"), and opens nothing. Older exports still import their hosts and projects; their windows are skipped and the review says so. See FR-R02 and [Integrations](docs/integrations.md#configuration-import-and-export).
- **Desktop notifications:** each notification now says where it came from. Its subtitle names the space and tab ("api › Build"), followed by the agent or running program when known ("api › Build · make"); the command line itself is never shown. Agent notifications read "Waiting for your input" or "Finished its turn". See [Workspace](docs/features/workspace.md) (FR-T08), FR-SI08 and FR-AG14.

### Fixed

- **Slowdown after long sessions:** Trellis no longer gets slower the longer it stays open with the Agents view showing. On macOS 26 the **New Tab / This Tab / Split** control leaked a little bookkeeping on every interface update, so after a day or two each update took a quarter of a second and typing stalled about once a second while an agent was working. The same control in the scratchpad's Save as Task sheet, the project editor, Appearance settings and the welcome tour is fixed too.

## [1.2.0-beta.2] - 2026-11-09

The second 1.2 beta.

### Added

- **Agents view:** a **This Tab** choice opens the agent in the focused pane, in place of its idle shell, instead of a new tab or split. It's shown only while no agent runs in that tab. It replaces a running shell only while the shell is waiting at its prompt, and asks first, since any background jobs end with it. **Split Beside Pane** is now labelled **Split**. See [Coding agents](docs/features/agents.md) (FR-AG17).

### Changed

- **Settings:** the sidebar icons are redrawn as full-colour, layered tiles in the style of the macOS System Settings sidebar.
- **Pane headers:** the Git icon and its hover card are gone; the Changes icon in the dock shows the focused pane's git changes instead.
- **Pane headers:** an agent's name and state ("Claude Code · Working") are no longer repeated in the pane header; the tab already shows the agent's icon, state and title.
- **Sidebar hover card and Agents view:** busy tabs and working agents show a small spinner instead of the **Busy** label and **Working** capsule. It holds still with Reduce Motion on.
- **Agents view:** **Open** is now a play button, and it and Resume are drawn without a box.
- **Background opacity:** now applies to the whole window, not only the terminal panes. The sidebar, dock, tab bar, pane headers, side panels and status bar follow the setting, but never go below 60 % so their labels stay readable. The blur covers the whole window.

### Fixed

- **GPU rendering:** text drawn with Metal was noticeably bolder than with GPU rendering off, most of all in light themes. Both renderers now draw the same stroke weight.
- **Translucent panes:** with GPU rendering, the terminal area was lighter than the padding around it, which looked like a frame, and a thin dark line ran along the top of the terminal. Both are gone.
- **Terminal panes:** an empty strip about 15 pt wide ran down the right of every pane, kept free for the scroll bar even though it only appears while you scroll. Text now uses that width, and the scroll bar floats over it when shown.

## [1.2.0-beta.1] - 2026-11-06

The first 1.2 beta.

### Added

- **Changes view:** a new branch icon in the right sidebar's dock (⌥⌘G) lists the focused pane's uncommitted git changes as a tree, with lines added and removed per file and folder, status letters (M, A, D, U, C), a filter, and **Stage**/**Unstage** for each file. Clicking a file opens its diff in a **Review** tab with line numbers, `n`/`p` to jump between changes and `]`/`[` between files. Git runs with hooks and filters off while reading. Panes on this Mac only. See [Changes](docs/features/changes.md).
- **Files view:** a new folder icon at the top of the right sidebar's dock (⌥⌘F) shows the focused pane's project as a tree, with a search across every file name, an **Open in** button for Finder and the editors you have installed (Cursor, VS Code, Zed, Xcode, Sublime Text, JetBrains IDEs…) that remembers your choice, and Copy Path, Copy Relative Path and Insert Path in Terminal. It leaves out `.git`, build folders and what `.gitignore` ignores. Panes on this Mac only. See [Files](docs/features/files.md).
- **Welcome tour:** a fresh install opens with a short eight-step tour of windows, sessions, projects, remote work, agents and shortcuts. Its last step sets the appearance, the command line tool and whether sessions keep running after quit. Replay it from **Help → Welcome Tour** or the command palette. It shows the right sidebar and dock: step 2 introduces them, the agents step shows the Agents view, and the keyboard step lists ⌥⌘F for Files with the other sidebar shortcuts.
- **Translucent panes:** Settings → Appearance → **Background opacity** (30–100 %) lets the desktop show through the terminal background, with an optional **Blur behind background**. Text, colors, selections and the sidebar and tabs stay opaque, and panes stay opaque while Reduce Transparency or Increase Contrast is on.
- **Drop files on a pane:** dragging files from Finder onto a terminal pane inserts their escaped paths at the prompt, for every file type.

### Changed

- **Right sidebar and dock:** the scratchpad, tasks and agents now share one sidebar on the right, switched from a dock on the window's right edge (⌥⌘E, ⌥⌘T, ⌥⌘A). Each view works with the focused pane; icons that don't apply to it, such as all three in an SSH pane, are dimmed. The dock badges count running tasks and agents that need you, and the Agents view lists every running agent across windows. Pane headers no longer have Scratchpad, Tasks or Agent buttons.
- **Agent icons:** Claude Code and Codex now show their vendors' logos, Claude Code's in its own orange. Agent definitions can set `"fullColor": true` on an image icon to keep its colors.
- **Trellis Light:** the terminal is now white, with black text and a matching palette, instead of dark. Custom light themes with no terminal colors follow it; those that set terminal colors keep a dark terminal unless they set a light background or dark text. Use another theme, such as My Light from the examples, for dark panes under light chrome.
- **Pane padding:** terminals now have an 8 pt margin on every side, and the part of a row that doesn't fit is split evenly above and below the rows, so the top and bottom padding always match. Rows were pinned to the bottom before, leaving a varying gap under the pane header.
- **Focused pane:** with several panes visible, the focused pane's header gets an accent line and tint, and the other panes are slightly dimmed. Nothing is dimmed while the window is inactive or with Increase Contrast on.

### Fixed

- **Light themes:** programs using 256-color indexes, like Powerlevel10k prompts, no longer draw near-black blocks on light terminals. Those colors now follow the theme and stay readable; dark terminals keep exact xterm values, and 24-bit colors are never changed.
- **Light themes:** text that would be nearly invisible no longer vanishes, such as `\e[30m` text and default text on `\e[47m` and `\e[107m` backgrounds. Readable ANSI colors keep the theme's exact values.
- The project setup terminal and the ssh connection console now use the current theme instead of the dark default.
- Inserting columns (DECIC) no longer fills them with reverse video.
- The project editor's "Layout" and "Editor" labels no longer wrap mid-word.
- In Settings → Updates, "Current version" now lines up with the toggles below it.

## [1.1.0] - 2026-11-03

The stable 1.1 release. Coming from 1.0.0, you also get everything listed under 1.1.0-beta.1: remote workspaces, the project library, coding agents, directory jump and sessions that keep running after quit. Repository project files are replaced by the library.

### Added

- **Show in Finder:** right-click a file path, or a selected file name, in a terminal pane. **Reveal in Finder** on launchable files is now called **Show in Finder** too.
- **CLI help:** `trellis --help` works at every level (also `-h` and `trellis help …`) with no app or credentials, and `trellis --version` (`-V`) prints the version. Argument errors point to the command's help.

### Changed

- **Working agents on tabs:** a light moving along the tab's top edge and a breathing icon replace the **Working** capsule and busy bar, leaving more room for the title. Both are static with Reduce Motion.
- **Machine name:** pane headers show the machine as a symbol and a name instead of bold green text; connection problems change the symbol and color and are named in words. The bottom bar's window name gets a folder icon.
- **Settings sidebar:** larger, more detailed Liquid Glass icons.

### Fixed

- **Editor line numbers:** the project JSON editor and scratchpad could miss numbers or draw them over the title.
- **Settings → Updates:** **Current version** lines up with the page title.
- **Bottom bar:** shows the focused pane's machine instead of always **Local**.
- **New tabs in remote windows:** a tab or split opened from an agent pane, or from a shell before its first prompt, starts in that pane's folder on the host instead of the home folder.
- **Hosts named Local or SSH** no longer get the wrong pane tools or the "unverified" directory hint.
- **Lost remote connections:** "Not sent: reconnecting" appears once per outage, and tabs on that host show a red indicator and a symbol until their panes are back.
- **Panes stuck after a reconnect:** a pane that can't re-attach keeps retrying, and one whose session is gone from the host ends instead of waiting forever.

## [1.1.0-beta.1] - 2026-11-02

The first 1.1 beta.

### Added

- **Remote workspaces (preview):** **Open Remote Workspace** in **File → Hosts…** opens a window whose tabs and splits run on that host and keep running when you quit, close the window or lose the connection. Dropped connections reconnect on their own and panes resume; when ssh needs a password or host-key decision, the window offers **Reconnect…**. Host tasks and library projects run there too (FR-RW01–FR-RW16, FR-RW18).
- **Remote helper (preview):** **File → Hosts…** checks, installs, updates and removes the helper on Linux (x86_64, aarch64) or macOS hosts over your own `ssh`, with a SHA-256 check and nothing written outside `~/.trellis` (FR-RW17).
- **Project library (preview):** **Projects** in the sidebar, **File → Projects…** (⌘O) and the command palette open projects kept in Trellis (`projects.json`): tabs, splits, folders, commands and git repositories, edited as a form or JSON (FR-PL01–FR-PL05). **Launch…** sets up the folder and repositories on this Mac or a saved host, then opens or reconciles the window (FR-PL06–FR-PL08). Pane headers show git status (FR-PL09).
- **Coding agents (preview):** an **Agent** button in pane headers and **Launch Agent…** open Claude Code, pi or Codex in the pane's folder and on its machine. Tabs show the agent's icon and a **Working**, **Needs you**, **Done** or **Error** badge, with a desktop notification when out of view. Add your own as `<id>.agent.json` (FR-AG01–FR-AG14). Library projects can run agents (FR-PL10).
- **Agents typed in a shell:** `claude`, `pi` or `codex` at a prompt show the agent's icon and name, without status badges (FR-AG15).
- **Directory jump:** **View → Jump to Directory…** (⌘J) lists recent and frequent directories on this Mac and in remote workspaces. System, temporary, credential and network folders are never recorded, and **Settings → Sessions** can turn it off or clear it (FR-DJ01–FR-DJ09).
- **Install the CLI from the app:** offered at first launch from Applications and in **Trellis → Install Command Line Tool…**. It creates one link at `~/.local/bin/trellis` and never edits shell startup files (MAC-15).
- **Session broker status:** a Settings page for the local broker and each connected remote host's.

### Changed

- **Sessions keep running by default:** sessions run in `trellis-broker`, so quitting, closing the window, a crash or a force quit no longer ends them. **Settings → Sessions → Stop sessions when Trellis quits** brings back the previous behavior and replaces **Keep sessions running after quit** (FR-R03, FR-R07, MAC-04).
- **Pane machine:** headers show **Local**, **SSH** or the host's name in bold dark green (FR-RW05).
- **Remote reconnects:** panes resume four at a time, so twelve panes on a slow link return after three round trips instead of twelve.
- **Settings sidebar:** each section has a colored icon tile.

### Removed

- **Repository project files:** `.trellis/project.json` and `workspace.json` are no longer read, and **Load Project**, **Open Project…**, **Save as Project…** and **Edit Project File** are gone. ⌘O opens the library instead (FR-PL01–FR-PL09). Tasks in `.trellis/launch.json` are unchanged.

### Fixed

- **`trellis cli … --dir`:** a relative directory that doesn't exist is refused instead of hanging.

## [1.0.0] - 2026-10-29

The first stable release. Earlier versions have no updater, so install 1.0.0 from the DMG; from here on, **Check for Updates…** installs new versions in place.

### Added

- **Software updates:** **Check for Updates…** and **Settings → Updates** install new versions with Sparkle 2. Automatic checks are off until you turn them on, and a check sends no system profile. **Include beta versions** chooses whether pre-releases are offered (MAC-14).
- **Workspace disk writes:** **Settings → Sessions** caps hourly writes (50 MB by default). Past it, changes save every 5 minutes; ⌘S and Quit still save at once (FR-R06).

### Changed

- **Selection:** a brighter background in the dark themes and default palette; One Dark, Solarized Dark and Gruvbox Dark brighten selected text too.
- **Underlines:** links and dotted or dashed underlines (`4:4`, `4:5`) are drawn solid (FR-TX02).
- **Privacy:** the update check is the only network request Trellis makes by itself, and only when you check or turn on automatic checks (MAC-14).
- **Build:** works around a Swift 6.4 compiler crash in the session broker client.

### Fixed

- **Collapsed sidebar:** a click while a tabs card was open now reaches its target (FR-W06).
- **Disk writes:** an unchanged workspace is no longer rewritten; long sessions could write gigabytes (FR-R06).

## [1.0.0-beta.2] - 2026-10-24

The second 1.0 beta.

### Added

- **Edit Project File:** a `{}` button in a local pane's header opens the project file in a JSON editor with **Validate** and **Save**. Saving asks first if the file changed on disk (FR-WF08).

### Changed

- **Save as Project** shows the file as validated JSON instead of a command field per pane, and asks before replacing a `project.json` (FR-WF06).
- **Save as Project** leaves out panes outside the project folder, with a warning, instead of moving them into it (FR-WF04, FR-WF06).

### Fixed

- **Project files:** after **Open Without Commands**, **Save as Project** no longer trusts the declined commands, and commands changed in **Edit Project File** carry over (FR-WF03, FR-WF06, FR-WF08).
- **Sessions kept after quit:** a command that exits at once no longer leaves its pane running forever, a paste over 1 MiB to a program that isn't reading is reported instead of losing chunks, and moving the app no longer starts a second broker (FR-R03).
- **Saved scrollback** redacts quoted secrets whole, such as `PASSWORD="correct horse battery"` (FR-R05).
- **Find in pane** acts on the right pane after switching between tabs of the same layout.
- A launch interrupted by a cancelled quit or close leaves the pane Failed with **Restart**, instead of a **Start** that can't work.
- **MCP server:** floods of blank lines or tiny requests no longer tie up a CPU core before authentication, and `events.subscribe` with `afterSequence` replays only subscribed topics.
- **Development:** `--state-directory` launches no longer hand off to another dev instance, and `--fixture` always runs in its own empty workspace.

## [1.0.0-beta.1] - 2026-10-23

The first 1.0 beta.

### Added

- **Command palette:** **View → Command Palette…** (⇧⌘P) fuzzy-searches actions, windows, tabs, panes, hosts, tasks and themes. Arrowing onto a theme previews it; Esc restores the previous colors (FR-CP01–FR-CP08).
- **Command scratchpad:** a panel beside the panes (`</>` button or ⌥⌘E) for commands and scripts in sh, bash, JavaScript and Markdown, with highlighting and line numbers (FR-SP01–FR-SP03). **Validate** checks syntax, **Run** types it into the focused pane, **Save as Task** writes to `.trellis/scratch/` and `launch.json`, and a file selector reopens saved scratchpads (FR-SP04–FR-SP10).

### Fixed

- **Save as Project** handles projects reached through a symbolic link, warns that SSH and other non-shell panes reopen as local shells, and keeps the file's `$schema` line; tasks no longer add a needless `cd` through a link (FR-WF06, FR-TK05).
- **Upgrading from `dev.trellis`** while the old app runs no longer shares its session broker, which left Keep Running sessions unable to start (FR-R03).
- **Open Project…** (⌘O) is disabled while restoring or in recovery, and never records trust for a project it can't open (FR-WF06).
- **VoiceOver** announces a project tab as "project … available to load" (FR-WF02).

### Security

- **Save as Project**, adding a task and **Create launch.json** refuse a `.trellis` folder that is a symbolic link (FR-WF06, FR-TK02).

## [0.12.0] - 2026-10-22

### Added

- **Tasks:** a **Tasks** menu in local pane headers runs tasks from `.trellis/launch.json` and detected npm/pnpm/yarn/bun, Make, CMake, SwiftPM, Python and Cargo scripts, showing elapsed time and exit code, with **Stop** and **Force Stop** (FR-TK01–FR-TK05, FR-TK07–FR-TK09). A `launch.json` version runs only after you review it and choose **Trust and Run** (FR-TK06).
- **Drag reordering:** drag windows in the sidebar or rail and tabs along the tab bar, with VoiceOver move actions (FR-W07, FR-T10).
- **Project files:** `.trellis/project.json` describes one window: tabs, colors, splits, titles, folders and commands (FR-WF01). **Load Project** appears when a shell enters the project (FR-WF02). Commands run only after **Trust and Open**, kept per folder and SHA-256 digest (FR-WF03). Reopening reconciles the window without restarting panes (FR-WF04, FR-WF05). **File → Open Project…** (⌘O) and **Save as Project…** open and write them (FR-WF06).

### Changed

- **Clearer names:** "workspace" now means only Trellis's own saved windows, and **File → Export/Import Workspace…** is now **Export/Import Windows & Hosts…**. Pre-release `.trellis/workspace.json` files still open (FR-WF07).

### Fixed

- **Window close keeps the workspace:** the red button ends sessions but keeps windows, tabs and splits as stopped panes, so a following Quit no longer saves an empty workspace (MAC-04, FR-R01).

## [0.11.1] - 2026-10-20

The first Developer ID signed and notarized release.

### Changed

- The bundle identifier is now `com.bearstouch.trellis` (development: `com.bearstouch.trellis.dev`). First launch copies your data from `~/Library/Application Support/dev.trellis/` and leaves the old folder untouched. macOS may ask once to allow Keychain access for saved passwords and automation grants.
- JetBrains Mono, with ligatures on, is the default terminal font for new installs. Existing settings keep their font.

## [0.11.0] - 2026-10-19

### Added

- **Edit → Clear** (⌘K) clears scrollback and the screen above the prompt; an existing ⌘K binding wins (FR-C07).
- Desktop notifications from OSC 9, OSC 777 and kitty's OSC 99 when you aren't looking at the pane; text is sanitized, capped and rate-limited (FR-T08).
- OSC 9;4 progress on tabs and panes, also read by VoiceOver and reported by `session.get` (FR-T09).
- Long-command notifications with shell integration (default 10 s), never showing the command line (FR-SI08).
- Shell marks over SSH: display-only host, path, title and exit badges, never used for local paths (FR-SI09).
- **Keep sessions running after quit** (opt-in): sessions run in `trellis-broker` and reconnect with up to 4 MiB of recent output (FR-R03).
- **Restore scrollback after quit** (opt-in): 1 MiB per pane with best-effort secret redaction, stored unencrypted (FR-R04, FR-R05).
- The empty workspace shows the Trellis prompt mark.

### Changed

- Opt-in Metal rendering (**Settings → Sessions → GPU rendering**), roughly 50–90% faster output on an M1 Pro, falling back to CoreGraphics (FR-TX05).
- Scrollback and notification settings moved to Settings → Sessions.
- Large output is up to 43% faster for `cat` of big files.
- The DMG opens as a drag-to-Applications window.
- The status bar shows **Trellis** and the version on the left and the window name on the right.
- The About panel and `LICENSE` credit "bearstouch" instead of LayerX Labs.

### Fixed

- A busy tab's context menu no longer closes on its own.

### Security

- Compressed (`o=z`) and chunked kitty graphics images can no longer hang Trellis or exhaust memory.
- Oversized sixel images and numbers are refused instead of crashing or allocating.
- Pasted text can't end a bracketed paste early; `ESC[200~`/`ESC[201~` markers are stripped (FR-C03, FR-C04).
- Creating a saved host, or clearing its user, port or identity file, through the API also needs `session.execute`.
- DCS sequences are capped at 8 MiB like OSC and APC.
- Release workflow actions are pinned to commit SHAs, and packaging fails when requested notarization fails.

## [0.10.0] - 2026-10-17

Trellis now opens in dark mode on first launch.

### Added

- **MCP server** (optional, off by default) for agents such as Claude Code, in **Settings → Remote Control**, authorized by automation grants. Loopback only unless you confirm a network address, which warns about plain HTTP; browser origins and DNS rebinding are refused, and `--no-mcp` disables it for one launch (INT-07).
- **Saved SSH passwords** in the macOS Keychain, given to `/usr/bin/ssh` through an `SSH_ASKPASS` helper at most once per connection, with optional Touch ID. Changing the destination, user, port or identity file removes the password, and exports, the API and the CLI never include it.
- **Inline images** with iTerm2's protocol (OSC 1337) for `imgcat`, `yazi`, `timg` and others. Downloads are ignored, PDF and SVG aren't decoded, and oversized images are refused.
- **Smart selection:** double-click selects URLs, emails, paths, UUIDs, IPs, git hashes and quoted strings, even across wrapped lines.
- **File links:** ⌘-click opens paths and OSC 8 `file://` links in local panes only. Apps, scripts and other files that could run code are only revealed in Finder; SSH panes, other hosts' links and network automounts are never opened.
- **Ligatures,** on by default and drawn on the cell grid (Settings → Appearance).
- **Input label** on tabs when a program is waiting: password prompts, bells and notifications. `session.get` reports `waitingForInput`.
- **Activity bar** on tabs while a pane prints output, excluding your own typing; static with Reduce Motion.
- **Bell setting:** Sound, Visual flash, both or Off (FR-T07).
- **Collapsed sidebar card:** hovering a window shows its tabs' live status; click to jump (FR-W06).
- **Connect in New Window** for saved hosts.
- Overline text (SGR 53/55) and rapid blink (SGR 6).
- **Bold as bright colors**, **Use bold fonts**, **Use italic fonts** and **Allow blinking text** settings, all on by default.
- The status bar and `swift run` builds show the Trellis icon.

### Changed

- Dark is the first-launch appearance; saved settings keep their mode.
- Bold white text (SGR 1;37) is drawn bright white.
- Concealed text (SGR 8) is hidden; copy and search still see it.
- Underline, strikethrough and overline cover the full width of wide characters, emoji and ligatures, and styled underlines join across colour changes.
- OSC and APC sequences over 8 MiB are dropped instead of buffered without limit.
- OSC 8 URLs containing `;` are no longer cut off.
- "LayerX Labs" in the About panel links to https://layerx.xyz, and the collapsed sidebar's buttons have more space.

## [0.9.2] - 2026-10-17

### Added

- **Tab colors:** right-click a tab and choose **Color**; VoiceOver reads the name, and automation uses `tab.update` or `trellis tab color`.
- **Collapsible sidebar:** a narrow rail of window initials, toggled with ⌃⌘S and remembered across launches.
- **Shell integration** for zsh, bash (including 3.2) and fish, on by default with no dotfile edits: current directory for new splits and tabs, exit-status indicators, program titles and ⌘↑/⌘↓ prompt jumps. Marks are authenticated with a per-session nonce.
- **Shell picker** in Settings → Sessions, listing installed shells and **Other…**.
- **Five more fonts:** JetBrains Mono, Cascadia Mono NF, IBM Plex Mono, Iosevka Fixed and Atkinson Hyperlegible Mono, registered for Trellis only.

### Changed

- Roboto Mono ships with the app and is the default terminal font. Existing workspaces keep their font.
- Development builds use their own identity, `dev.trellis.dev`, so they can run beside an installed Trellis. The feasibility bundle is now "Trellis Dev".
- The Hosts window matches Settings and follows the app theme.

### Fixed

- Restored local shell panes reopen in their last directory reported by shell integration, instead of where they started.

## [0.9.1] - 2026-10-17

### Added

- 10 editor-inspired theme families with dark and light variants: Modern, One, Monokai, Solarized, Nord, Dracula, GitHub, Tokyo, Gruvbox and Rose Pine.
- A terminal font picker listing installed monospace families, with a preview.
- **Trellis → About Trellis.**

### Changed

- Settings use sidebar navigation in a wider panel.
- Trellis runs as a single instance per user, released automatically on quit or crash.
- The terminal scrollbar stays hidden while idle and never changes the grid width.
- Terminal layout: no pane border, subtle padding, one toolbar row and one-pixel dividers.
- `scripts/qualify.py` reports to `.build/`, and contributor docs moved to an MkDocs site under `docs/`.

### Fixed

- Closing an interactive shell no longer asks to force-stop it: Trellis sends SIGHUP instead of SIGTERM, which shells such as zsh ignore. SIGKILL is still a separate, explicit step.

## [0.9.0] - 2026-10-16

The first public release of Trellis, previously uTerm: a native Swift terminal for macOS 14 and later, Universal 2. It delivers the full MVP, with some platform checks still pending; see [Known issues](#known-issues).

### Added

- **Terminal and sessions:** vendored SwiftTerm 1.20.0 behind an adapter, and login shells in real PTYs. Sessions show their state and exit status. Closing asks first, terminates the process group gracefully, waits up to 2 s, then offers an explicit force; a reused PID is never signaled.
- **Windows, tabs and splits:** managed windows in a left sidebar, renameable tabs, and nested splits up to depth 16 and 100 panes, with resizing, directional focus and temporary maximize.
- **Persistence:** atomic, versioned, owner-only saves with a last-known-good backup and recovery. Restored sessions start stopped, typed input is never replayed, and terminal output, tokens and secret environment values are never persisted. uTerm data migrates automatically.
- **Copy, paste and search:** plain Unicode copy, a review step for multiline or control-character pastes, Paste Escaped Path, and per-pane search over 10,000 lines of scrollback (16 MiB cap).
- **Appearance and themes:** light chrome with dark panes, Light, Dark and System modes, live font and cursor settings, a strictly validated JSON theme format (v1), and a theme library with preview, import and export. Cancelling a preview restores your exact prior appearance.
- **Keyboard and accessibility:** rebindable shortcuts with conflict checks, optional Option-as-Meta, and accessibility labels, roles and focus indicators throughout.
- **SSH hosts:** a saved host library storing only metadata, read-only discovery from `~/.ssh/config`, and connections through `/usr/bin/ssh` with no trust-bypassing options.
- **Automation API:** JSON-RPC 2.0 over an owner-only Unix socket (never TCP), with scoped, expiring, revocable grants and separate capabilities. Covers resources, sessions, input, output, events, declarative layouts, themes and appearance. Input is never retried automatically.
- **`trellis` CLI:** commands over the API with credentials only from `--token-stdin` or `--keychain-grant`, a stable `--json` envelope, and `trellis cli install-link`.
- **Import and export:** portable layout and host JSON without runtime IDs, buffers, keys or secrets. Imports are reviewed first and get fresh IDs and stopped panes.
- **Security and diagnostics:** OSC 52 clipboard use and Kitty file transfer are refused, links open only on Cmd-click for `http`, `https` and `mailto`, logs never contain tokens, input or output, and **Help → Export Diagnostics…** previews its report. No telemetry and no clipboard history.
- **Release and tooling:** a hardened-runtime Universal 2 app bundling the CLI, `scripts/package-release.sh`, `scripts/qualify.py`, `scripts/run-feasibility.sh` and a release guide.

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

- Sustained output reaches about 5 MiB/s, short of the 10 MiB/s target; navigation stays responsive and memory stays bounded.
- Echo and tab-switch latency were measured through the control API, without on-screen frame rendering.
- Manual VoiceOver, IME, dead-key and keyboard-layout checks are pending.
- Only one machine has been qualified; older macOS versions and Intel are untested.
- Developer ID signing and notarization aren't configured, so Gatekeeper blocks ad-hoc builds on other Macs.
- The bundle identifier `dev.trellis` is provisional.
- MVP limits: one native application window and manual upgrades.

[Unreleased]: https://github.com/bearstouch/trellis/compare/v1.2.0...HEAD
[1.2.0]: https://github.com/bearstouch/trellis/compare/v1.2.0-beta.3...v1.2.0
[1.2.0-beta.3]: https://github.com/bearstouch/trellis/compare/v1.2.0-beta.2...v1.2.0-beta.3
[1.2.0-beta.2]: https://github.com/bearstouch/trellis/compare/v1.2.0-beta.1...v1.2.0-beta.2
[1.2.0-beta.1]: https://github.com/bearstouch/trellis/compare/v1.1.0...v1.2.0-beta.1
[1.1.0]: https://github.com/bearstouch/trellis/compare/v1.1.0-beta.1...v1.1.0
[1.1.0-beta.1]: https://github.com/bearstouch/trellis/compare/v1.0.0...v1.1.0-beta.1
[1.0.0]: https://github.com/bearstouch/trellis/compare/v1.0.0-beta.2...v1.0.0
[1.0.0-beta.2]: https://github.com/bearstouch/trellis/compare/v1.0.0-beta.1...v1.0.0-beta.2
[1.0.0-beta.1]: https://github.com/bearstouch/trellis/compare/v0.12.0...v1.0.0-beta.1
[0.12.0]: https://github.com/bearstouch/trellis/compare/v0.11.1...v0.12.0
[0.11.1]: https://github.com/bearstouch/trellis/compare/v0.11.0...v0.11.1
[0.11.0]: https://github.com/bearstouch/trellis/compare/v0.10.0...v0.11.0
[0.10.0]: https://github.com/bearstouch/trellis/compare/v0.9.2...v0.10.0
[0.9.2]: https://github.com/bearstouch/trellis/compare/v0.9.1...v0.9.2
[0.9.1]: https://github.com/bearstouch/trellis/compare/v0.9.0...v0.9.1
[0.9.0]: https://github.com/bearstouch/trellis/releases/tag/v0.9.0
