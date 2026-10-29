# Roadmap and decisions

## Next: finishing the MVP qualification

Everything in [Status](../overview/status.md) under *Release blockers* and *Pending verification*:

- measure UI frame latency (typing and tab switching currently meet their targets through API proxies)
- Developer ID signing and notarization
- the macOS 14 and 15, native Intel and clean-machine matrix
- VoiceOver, IME and keyboard layouts
- checks against a controlled SSH server
- native and installed-CLI checks

## Deferred scope (P1/P2)

None of these are part of the MVP. Before starting one, write its requirements into the relevant docs page (new IDs, with acceptance checks) and get them agreed. Don't fold them into unrelated changes.

| Priority | Item | Reference |
| --- | --- | --- |
| P1 | Multiple native windows and moving tabs between them | `MAC-13`, [macOS support](../platform/macos.md#deferred-multiple-native-windows) |
| P1 | Multiple profiles | [Product overview](../overview/product.md#scope) |
| P1 | Shell-integration events for automation: command-completion events and `session.execute` waiting for the exit status | `INT-02`, [Shell integration](../features/shell-integration.md) |
| P1 | Richer SSH host import | [SSH hosts](../features/ssh-hosts.md) |
| P1 | Keychain-enforced Touch ID for saved host passwords (`SecAccessControl` with a keychain-access-group entitlement, Developer ID builds) | `FR-H07`, [Saved passwords](../features/ssh-hosts.md#saved-passwords) |
| P1 | Signed automatic updates (Sparkle; in progress) | `MAC-11`, `MAC-14` |
| P1 | Clipboard API (`clipboard.read`/`clipboard.write` are reserved) | [Authorization](../api/authorization.md#capabilities) |
| P1 | Per-window, per-tab and per-host theme overrides | [Themes](../features/themes.md#installation-and-persistence) |
| P1 | Remote workspaces: windows bound to a saved host, sessions kept by a Trellis helper on the host, automatic reconnect, remote project files and tasks (draft) | `FR-RW01`–`FR-RW17`, [Remote workspaces](../features/remote-workspaces.md) |
| P2 | tmux awareness, richer terminal protocols, plugins | |
| P2 | Command palette: saved scratchpads as items (with the unsaved-changes confirmation), recents kept across launches | `FR-CP03`, `FR-CP05`, [Command palette](../features/command-palette.md#not-included) |
| P2 | Links: open `file:line:column` in a configured editor, a pointing-hand cursor over links, detecting `ssh` typed inside a local shell | `FR-L02`, `FR-L04`, [Links](../features/terminal.md#links) |

**Not planned:** Windows, Linux and iOS as platforms for the app (Linux is supported only as a remote workspace host); cloud sync; a web UI; a remote API server beyond the optional MCP server; an embedded AI provider; an embedded SSH implementation; general file transfer (the remote helper install and bounded project-file reads are the only transfers); serial ports; full iTerm2 preference import.

## Decisions

These were decided during the MVP. Reopening one needs a docs change and a review.

| Decision | Outcome | Where it's recorded |
| --- | --- | --- |
| What a "window" means | Sidebar workspaces inside one native window | [Product overview](../overview/product.md#vocabulary) |
| Terminal engine | SwiftTerm 1.20.0 behind the `TrellisTerminal` adapter, vendored and patched. Trellis owns the PTY. | [Terminal engine](../architecture/terminal-engine.md) |
| `TERM` | `xterm-256color` with `COLORTERM=truecolor` | [Sessions](../architecture/sessions.md#launching) |
| Platform | macOS 14+, Universal 2 | [macOS support](../platform/macos.md), `release/manifest.json` |
| Default scrollback | 10,000 lines plus 16 MiB per pane | [Terminal engine](../architecture/terminal-engine.md#scrollback-and-output-buffers) |
| Agent authorization | User-created grants with capabilities, window and host scope, expiry and revocation | [Authorization](../api/authorization.md) |
| Application identity | Trellis, bundle ID `com.bearstouch.trellis` (renamed from uTerm, then from `dev.trellis`). | [Release guide](../release/README.md) |
| Distribution | A direct-download DMG, without App Sandbox or the Mac App Store | `MAC-09` |
| Sessions on quit | By default, closing the app ends local processes and relaunch restores layouts as stopped sessions. Revised for FR-R03–FR-R05: an opt-in `trellis-broker` helper (per state directory, owner-only socket with peer checks both ways) can keep sessions running across quit and reattach them by session UUID with a bounded replay; an opt-in, redacted plain-text scrollback file is the only persisted output. Closing the window still ends sessions; nothing survives logout. Revised for FR-RW06: sessions in remote workspaces are kept by a `trellis-broker` on the remote host, reached only through the system `ssh`, and survive quit, window close, sleep and network loss. | [Sessions](../architecture/sessions.md#session-broker), [Persistence](../architecture/persistence.md#opt-in-scrollback-file) |
| Automation transport | A local Unix socket plus the `trellis` CLI. Revised for INT-07: an optional MCP server over HTTP, off by default, loopback unless the user confirms a network address, using the same grants and authorizer. There's no other TCP API. | [Automation API](../api/index.md), [MCP server](../api/mcp.md) |
| Visual direction | "Native calm": light chrome, dark terminals, bundled JetBrains Mono | [Product overview](../overview/product.md#primary-interaction) |
| Commands in layouts | API layouts never carry commands. Revised for FR-WF01–FR-WF06: a project's `.trellis/project.json` may give each pane a command, typed into its new shell only after the user reviews and trusts that exact file (per folder and SHA-256 digest). Automation can't open project files. | [Project files](../features/project-files.md) |
