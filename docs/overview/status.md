# Status and known limits

**Version 0.10.0, pre-release.** The MVP feature set is implemented and the full automated suite passes. Trellis isn't qualified for a 1.0 release yet: some manual and platform checks haven't been run, and two release blockers remain. The [changelog](https://github.com/layerx-labs/trellis/blob/master/CHANGELOG.md) lists what shipped.

## Release blockers

| Area | Blocker |
| --- | --- |
| Flood throughput | A 10 MiB/s output flood is consumed at about 5–7.6 MiB/s, short of the target. Navigation stays responsive during the flood. Typing and tab-switch latency meet their targets, but they were measured through API proxies rather than UI frame timing. Run `python3 scripts/qualify.py` to reproduce. |
| Distribution | Universal 2 packaging, the CLI link, the release gate and the release docs are done. Developer ID signing, notarization, clean-machine Gatekeeper checks and the OS/CPU matrix are still pending. |

## Latest qualification run

Release build, Apple M1 Pro, macOS 26.6.2, measured with `scripts/qualify.py`:

| Target | Result |
| --- | --- |
| Cold launch ≤ 2 s p95 | p95 348 ms |
| Typing echo ≤ 50 ms p95 (API proxy) | p95 0.4 ms |
| Tab switch ≤ 100 ms p95 with live panes (API proxy) | p95 11 ms with 100 panes |
| 10 windows, 50 tabs, 100 sessions | Met, with unique IDs and all sessions running |
| Idle memory ≤ 300 MiB and CPU < 2% with 10 panes | 73 MiB, 0.38% |
| 10 MiB/s flood for 60 s | 5.15 MiB/s consumed (**misses**); navigation p95 60 ms |
| 100 create/close cycles | No leaked descriptors or children |

## Pending verification

These checks can't be automated here and haven't been performed. They are recorded as pending, never as passed.

| Area | What's pending |
| --- | --- |
| Terminal engine | Real IME composition and VoiceOver terminal reading |
| Text rendering | FR-TX01 in the native app: the cursor splitting ligatures, colour changes and selections keeping them, and the setting turning them off (joined JetBrains Mono ligatures were seen on macOS 26.6.2); FR-TX02 styles seen in vim, `git diff` and a curly-underline test; FR-TX04 emoji and CJK on macOS 14's older Apple Color Emoji; VoiceOver reading concealed text; blinking text with Reduce Motion |
| Native shell | Lifecycle and display checks on external and non-Retina monitors |
| Accessibility and input | VoiceOver navigation, a real IME, US and Portuguese keyboard layouts, dead keys |
| Sidebar | FR-W06 tabs hover card in the native app: open/close delays, moving into the card, live updates, clicking a tab of another window, VoiceOver reading rows and the **Show Tabs** action |
| Hosts | Native host-library and alias-discovery demos; Connect in New Window in the native UI |
| Tabs | FR-T07 bell setting in the native app: the audible alert, the visual flash, Off staying silent; FR-T05 busy bar: the real animation with `seq`, the static bar under Reduce Motion, VoiceOver reading "output in progress"; FR-T06 input label: a real `sudo` prompt, Claude Code's bell in a background tab, VoiceOver reading "waiting for input" |
| SSH | Known, unknown and changed host keys; agent, passphrase and password prompts; saved-password login through askpass, with and without Touch ID, and with real `/usr/bin/ssh` retries and host-key prompts; dropped networks, against a controlled SSH server |
| Automation | Keychain-backed grants in the native UI; live multi-client socket checks; the installed `trellis` CLI |
| MCP server | Settings → Remote Control in the native app (status text, the network-address warning, VoiceOver labels); a real Claude Code client connecting with `claude mcp add --transport http`; a client on another Mac over a LAN address; the macOS firewall prompt for a non-loopback bind |
| Portability | Native export/import demo |
| Security | Native link, clipboard and diagnostics checks |
| Inline images | FR-IM01–FR-IM03 in the native app: iTerm2's `imgcat` for small and multipart images, `chafa -f iterm`, `timg`, `yazi` previews, and images surviving scrolling, resizing, `clear`, ⌘K and the alternate screen; tmux passthrough over SSH; drawing on Intel and non-Retina displays; how VoiceOver reads rows that hold images |
| Links and selection | FR-C06 smart double-click in the native app (URLs, paths, emails, hashes; inside vim with `set mouse=a` the click goes to vim); FR-L02–FR-L05 ⌘-click and context-menu opening of real `ls --hyperlink=auto` output and compiler `file:line:col` paths, Finder reveal of a script and an `.app`, and a saved-SSH-host pane refusing paths |

## Tested matrix

Only these combinations have been run.

| macOS | CPU | Build | Result |
| --- | --- | --- | --- |
| 26.6.2 (25G83) | Apple M1 Pro (arm64, native) | Development and release builds | Full automated suite, native checks and a qualification run |
| 26.6.2 | x86_64 slice under Rosetta | Universal release | The CLI runs. This is **not** a native Intel qualification. |

**Not yet tested:** macOS 14 (the declared minimum), macOS 15, native Intel hardware, external displays, and a clean machine.

## Known limits

- **Signing:** current builds are ad-hoc signed. Gatekeeper rejects them on other Macs.
- **Windows:** there's one native terminal window. Managed windows live in its sidebar; multiple native windows are P1.
- **MCP server:** plain HTTP with no TLS, and no server-initiated stream, so there are no event subscriptions over MCP. Use loopback or an SSH tunnel for remote agents.
- **Updates:** upgrades are manual. There's no automatic update service.
- **Sessions don't survive quitting.** Closing the app ends its local processes, and relaunching restores layouts as stopped sessions.
- **Shell knowledge:** [shell integration](../features/shell-integration.md) reports the directory, the running command and exit status for local zsh, bash and fish. Other shells, SSH sessions and disabled integration report none of this. `session.execute` still submits input without waiting for a command result, and command-completion events aren't published to automation yet.
- **File links:** relative paths open only where shell integration reports the directory. A host reached by typing `ssh` in a local shell isn't detected, so its absolute paths open if the same path exists on this Mac. `:line[:column]` suffixes aren't passed to editors, and the pointer doesn't change over links.
- **Shell integration checks pending:** fish on a Mac with fish installed (its PTY test skips without it), VoiceOver reading of the failed-command indicator, and prompt themes such as powerlevel10k and starship.
