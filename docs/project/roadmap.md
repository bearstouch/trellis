# Roadmap and decisions

## Next: finishing the MVP qualification

Everything in [Status](../overview/status.md) under *Release blockers* and *Pending verification*:

- raise flood throughput to the 10 MiB/s target
- measure UI frame latency
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
| P1 | Signed automatic updates | `MAC-11` |
| P1 | Optional MCP adapter over the existing command service | `INT-07`, [Integrations](../integrations.md#scripts-and-agents) |
| P1 | Clipboard API (`clipboard.read`/`clipboard.write` are reserved) | [Authorization](../api/authorization.md#capabilities) |
| P1 | Per-window, per-tab and per-host theme overrides | [Themes](../features/themes.md#installation-and-persistence) |
| P2 | A session broker so sessions survive application exit | |
| P2 | tmux awareness, richer terminal protocols, plugins | |

**Not planned:** Windows, Linux and iOS; cloud sync; a web UI; a remote API server; an embedded AI provider; an embedded SSH implementation; file transfer; serial ports; full iTerm2 preference import.

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
| Application identity | Trellis, bundle ID `dev.trellis` (renamed from uTerm). Provisional until a Developer ID team is chosen. | [Release guide](../release/README.md) |
| Distribution | A direct-download DMG, without App Sandbox or the Mac App Store | `MAC-09` |
| Sessions on quit | Closing the app ends local processes. Relaunch restores layouts as stopped sessions. | [Persistence](../architecture/persistence.md#restoring-stopped-sessions) |
| Automation transport | A local Unix socket plus the `trellis` CLI. No TCP or remote control. | [Automation API](../api/index.md) |
| Visual direction | "Native calm": light chrome, dark terminals, bundled Roboto Mono | [Product overview](../overview/product.md#primary-interaction) |
