# Product overview

## Purpose

Trellis is a focused native macOS terminal that makes many concurrent local and SSH sessions easy to organize and operate. It aims to replace an everyday iTerm2 workflow with fast keyboard navigation, reliable terminal emulation, easy copy and paste, nested splits, reusable hosts, and first-class control from scripts and agents.

"Replace iTerm2" describes the daily workflow. It doesn't promise compatibility with every iTerm2 feature or configuration format.

## Users and workflows

- A developer keeps a separate managed window for each project and switches between their tabs without losing running processes.
- An operator opens saved SSH hosts, inspects several machines in adjacent panes, and reconnects explicitly after a failure.
- A script creates a project workspace with named tabs, working directories and a repeatable split layout.
- An authorized agent discovers stable IDs, reads output it has been allowed to read, opens sessions, and sends commands. It goes through the same application services the UI uses.

## Vocabulary

| Term | Definition |
| --- | --- |
| Native window | A macOS application window. The MVP has one terminal-bearing native window. |
| Managed window (workspace) | A persistent, named sidebar item that holds an ordered list of tabs. The UI calls these "Windows"; the API resource is `window`. |
| Tab | A named container for one binary split tree and its active pane. |
| Pane | A visible terminal leaf in a tab. Each pane owns exactly one session. |
| Session | One PTY-backed process, usually a login shell or the system SSH client. |
| Host | Saved SSH connection metadata. It isn't a running session. Its only credential is an optional password kept in the Keychain, never in the host itself. |
| Profile | Reusable appearance and launch defaults. The MVP has a single default profile. |
| Layout | A declarative, versioned description of windows, tabs and pane trees. |
| Grant | A user-created automation credential with a capability set and a resource scope. |

Structural rules:

- A window has at least one tab, and a tab has at least one pane.
- The application can have zero windows, in which case it shows a welcome screen.
- Selecting another window or tab never stops sessions.
- There is no global "broadcast input to all panes" feature.

## Scope

| Priority | Features |
| --- | --- |
| P0 (MVP) | Sidebar windows; tabs; nested left/right and top/bottom splits; local shells; SSH hosts; native selection and clipboard; built-in dark and light themes plus custom JSON themes; terminal search; keyboard navigation; saved layouts; local CLI and API; explicit automation grants; bounded output reading; import and export of layouts and hosts |
| P1 | Multiple native windows; dragging tabs between windows; multiple profiles; shell integration (zsh, bash, fish; command-completion events for automation still to come); richer host import; a signed update mechanism; an optional MCP adapter; an opt-in session broker so sessions survive quitting, with an opt-in redacted scrollback file (FR-R03–FR-R05, implemented) |
| P2 | tmux awareness; richer terminal protocols; plugins |

Out of scope for the MVP: Windows, Linux or iOS support; cloud sync; a web UI; a remote API server; an embedded AI provider; an embedded SSH implementation; file transfer; serial ports; full iTerm2 preference import; and replaying arbitrary commands on restore.

## Primary interaction

The visual direction is **Native calm**.

- The left sidebar lists managed windows. Selecting one shows that window's own tab bar above its terminal area.
- Selecting a tab restores its split layout and its last focused pane.
- The tab bar has visible separators, a new-tab button and a rename action. Double-clicking a tab label edits it inline: Enter commits, Escape cancels, and an empty name keeps the previous title. Renaming never restarts a session or changes an ID.
- Dark application chrome is the first-launch default; Light and System are available, and settings saved by an earlier version keep their mode. Terminal panes stay dark with the default themes and use bundled JetBrains Mono by default in every appearance.
- **Hosts** opens a searchable list with connect and edit actions. Connecting opens a new tab by default, with explicit options to open a new window or a split instead.

Menus say **Split Left/Right** and **Split Top/Bottom**. In the API, `axis: x` means left/right and `axis: y` means top/bottom. This avoids the ambiguous term "vertical split".

## Definition of done for the MVP

A user can organize two projects, open local and saved SSH sessions, create nested splits, copy and paste safely, switch between running tabs, close sessions with appropriate warnings, and restore a stopped layout.

A script can build the same workspace, discover its IDs, observe the output it's permitted to read, and explicitly run a command. Every result and error it receives is documented.

### Cross-feature acceptance scenario

1. Create "Project" and "Operations" in the sidebar.
2. In Project, open a local shell, add a second tab, split it left/right and then top/bottom.
3. Copy a selected command, review a multiline paste, and check that only the focused pane receives it.
4. In Operations, connect to a saved SSH alias and inspect a failed connection.
5. Use the CLI to list the same object IDs and apply a layout twice.
6. Confirm a restricted agent can't read output.
7. Quit and reopen. Sessions keep running in the broker and come back running in their panes (FR-R03, FR-R07). With **Stop sessions when Trellis quits** on, quitting asks to end them and the layout returns stopped until it's explicitly started.

## Milestones

The MVP was delivered in five phases:

1. **Terminal feasibility:** embed the terminal engine and prove a PTY shell, resizing, Unicode and IME, selection, clipboard, alternate-screen apps, accessibility and resource cleanup.
2. **Organization:** windows, tabs, the split tree, focus, process lifecycle and restoring stopped layouts.
3. **Daily use:** SSH hosts, search, clipboard behavior, settings, shortcuts and unsaved-work warnings.
4. **Automation:** shared commands, the authenticated socket, the CLI, output and event bounds, layout validation and application, and permission checks.
5. **Release qualification:** the acceptance matrix on the supported architectures and macOS versions, signing and notarization, and published known limitations.
