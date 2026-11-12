# Roadmap and decisions

## Next: finishing qualification

Version 1.1.0 is released, but some of its checks are still open. This covers everything in [Status](../overview/status.md) under *Distribution checks* and *Pending verification*, plus the open flood result:

- measure UI frame latency (typing and tab switching currently meet their targets through API proxies)
- Gatekeeper on a clean machine with a downloaded DMG (release CI already signs with Developer ID, notarizes and staples)
- the macOS 14 and 15, native Intel, external display and clean-machine matrix
- VoiceOver, IME and keyboard layouts
- checks against a controlled SSH server
- native and installed-CLI checks
- the 10 MiB/s flood: the `ee87a38` run met it, but later full runs of `scripts/qualify.py` missed it, including on a base commit without the renderer change
- the checks for the features below that shipped after the MVP

## Shipped since the MVP, qualification pending

These were P1 items on this roadmap. They are released, but their acceptance checks stay open until observed. The [changelog](https://github.com/bearstouch/trellis/blob/master/CHANGELOG.md) lists everything else that shipped.

| Item | Shipped in | Main checks still pending | Reference |
| --- | --- | --- | --- |
| Signed automatic updates (Sparkle) | 1.0.0 | An update offered, installed and relaunched, a tampered DMG rejected, quit confirmation and **Keep Running** during an install, beta-channel filtering, and the first in-place update on a clean Mac | `MAC-11`, `MAC-14`, [macOS support](../platform/macos.md) |
| Project library | 1.1.0 (preview) | The library, launch and setup UI in the native app, cloning a private repository through a forwarded agent on a real host, and setup under fish and ash | `FR-PL01`–`FR-PL10`, [Project library](../features/project-library.md) |
| Remote workspaces | 1.1.0 (preview) | Real Linux and x86_64 hosts, a remote macOS host, interactive prompts in the connection console, real sleep, wake and network changes, and latency over a real network | `FR-RW01`–`FR-RW18`, [Remote workspaces](../features/remote-workspaces.md) |
| Automation API v2: protocol 2 replaces protocol 1 on the socket, the CLI and MCP (spaces, panes, agents, remote workspaces, projects and tasks; presets and editable grants; live-state events and `events.poll`, including shell-integration `command.finished` events and `session.execute {wait}`; layout v3) | Unreleased | The grant sheet with VoiceOver, real agents answered through `agent.respond`, a real remote host and a real project launch through the API, Claude Code and Codex as MCP clients over loopback and Tailscale, and upgrading a released `grants.json` ([Status](../overview/status.md)) | `API2-01`–`API2-08`, `INT-02`, [Automation API](../api/index.md), [implementation history](api-v2-implementation.md) |
| Coding agents | 1.1.0 (preview) | Claude Code's Needs you in an interactive session, Codex and pi end to end, vendor installers on a clean Mac and on Linux hosts, a remote agent on a real host, and VoiceOver | `FR-AG01`–`FR-AG15`, [Coding agents](../features/agents.md) |

## Deferred scope (P1/P2)

None of these are part of the MVP. Before starting one, write its requirements into the relevant docs page (new IDs, with acceptance checks) and get them agreed. Don't fold them into unrelated changes.

| Priority | Item | Reference |
| --- | --- | --- |
| P1 | Multiple native windows and moving tabs between them | `MAC-13`, [macOS support](../platform/macos.md#deferred-multiple-native-windows) |
| P1 | Multiple profiles | [Product overview](../overview/product.md#scope) |
| P1 | Richer SSH host import | [SSH hosts](../features/ssh-hosts.md) |
| P1 | Keychain-enforced Touch ID for saved host passwords (`SecAccessControl` with a keychain-access-group entitlement, Developer ID builds) | `FR-H07`, [Saved passwords](../features/ssh-hosts.md#saved-passwords) |
| P1 | Clipboard API (`clipboard.read`/`clipboard.write` reserved names) | [Permissions](../api/permissions.md#capabilities-api2-06) |
| P1 | Per-space, per-tab and per-host theme overrides | [Themes](../features/themes.md#installation-and-persistence) |
| P2 | Mobile connect: an iPhone and iPad companion paired with the Mac, end-to-end encrypted over the local network or a relay, with agent notifications and answers (draft, not implemented) | `FR-MC01`–`FR-MC16`, [Mobile connect](../features/mobile-connect.md) |
| P2 | Agent registry: a signed, hosted index of agent definitions in the same schema, browsed and installed from Settings → Agents; per-agent extra arguments | [Coding agents](../features/agents.md#known-limits) |
| P2 | tmux awareness, richer terminal protocols, plugins | |
| P2 | Command palette: saved scratchpads as items (with the unsaved-changes confirmation), recents kept across launches | `FR-CP03`, `FR-CP05`, [Command palette](../features/command-palette.md#not-included) |
| P2 | Links: open `file:line:column` in a configured editor, a pointing-hand cursor over links, detecting `ssh` typed inside a local shell | `FR-L02`, `FR-L04`, [Links](../features/terminal.md#links) |

**Not planned:** Spaces, Linux and iOS as platforms for the app (Linux is supported only as a remote workspace host, and iOS only as the proposed Mobile connect companion to a paired Mac); cloud sync; a web UI; a remote API server beyond the optional MCP server and the proposed Mobile connect link; an embedded AI provider; an embedded SSH implementation; general file transfer (the remote helper install and bounded project-file reads are the only transfers); serial ports; full iTerm2 preference import.

## Decisions

These were decided during the MVP, and some have been revised since. Reopening one needs a docs change and a review.

| Decision | Outcome | Where it's recorded |
| --- | --- | --- |
| What a "space" means | Sidebar workspaces inside one native window | [Product overview](../overview/product.md#vocabulary) |
| Terminal engine | SwiftTerm 1.20.0 behind the `TrellisTerminal` adapter, vendored and patched. Trellis owns the PTY. | [Terminal engine](../architecture/terminal-engine.md) |
| `TERM` | `xterm-256color` with `COLORTERM=truecolor` | [Sessions](../architecture/sessions.md#launching) |
| Platform | macOS 14+, Universal 2 | [macOS support](../platform/macos.md), `release/manifest.json` |
| Default scrollback | 10,000 lines plus 16 MiB per pane | [Terminal engine](../architecture/terminal-engine.md#scrollback-and-output-buffers) |
| Agent authorization | User-created grants with presets, capabilities, space, project, host and agent scope, expiry, editing and revocation | [Permissions](../api/permissions.md) |
| Application identity | Trellis, bundle ID `com.bearstouch.trellis` (renamed from uTerm, then from `dev.trellis`). | [Release guide](../release/README.md) |
| Distribution | A direct-download DMG, without App Sandbox or the Mac App Store. Revised for MAC-14: installed copies can also update in place with Sparkle. | `MAC-09`, `MAC-14` |
| Sessions on quit | Revised for FR-R07: every session runs in the `trellis-broker` helper (per state directory, owner-only socket with peer checks both ways), so quitting, closing the window, a crash or a force quit leave it running, and the next launch reattaches it by session UUID with a bounded replay. **Stop sessions when Trellis quits** restores ending sessions at quit and window close. An opt-in, redacted plain-text scrollback file is the only persisted output. Nothing survives logout. Revised for FR-RW06: sessions in remote workspaces are kept by a `trellis-broker` on the remote host, reached only through the system `ssh`. | [Sessions](../architecture/sessions.md#session-broker), [Persistence](../architecture/persistence.md#opt-in-scrollback-file) |
| Automation transport | A local Unix socket plus the `trellis` CLI. Revised for INT-07: an optional MCP server over HTTP, off by default, loopback unless the user confirms a network address, using the same grants and authorizer. There's no other TCP API. | [Automation API](../api/index.md), [MCP server](../api/mcp.md) |
| Visual direction | "Native calm": dark chrome on first launch (with Light and System modes), themed terminals, bundled JetBrains Mono | [Product overview](../overview/product.md#primary-interaction) |
| Commands in layouts | API layouts never carry commands. Revised for FR-PL01–FR-PL10: projects in Trellis's own project library may give each pane a command or an agent and name git repositories; you write them in the app, so launching runs them without a review. The earlier repository project files (`.trellis/project.json`, FR-WF01–FR-WF08) were removed. Automation can't launch projects. | [Project library](../features/project-library.md) |
