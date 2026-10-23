# Status and known limits

**Version 0.12.0, pre-release.** The MVP feature set is implemented and the full automated suite passes. Trellis isn't qualified for a 1.0 release yet: some manual and platform checks haven't been run, and one release blocker remains. The [changelog](https://github.com/bearstouch/trellis/blob/master/CHANGELOG.md) lists what shipped.

## Release blockers

| Area | Blocker |
| --- | --- |
| Distribution | Universal 2 packaging, the CLI link, the release gate and the release docs are done. Developer ID signing, notarization, clean-machine Gatekeeper checks and the OS/CPU matrix are still pending. |

## Latest qualification run

Release build of commit `ee87a38`, Apple M1 Pro, macOS 26.6.2, measured with `scripts/qualify.py` on 2026-10-18 (one machine, with other applications open). Typing and tab-switch latency are measured through API proxies rather than UI frame timing; an instrumented UI run is still pending. Run `python3 scripts/qualify.py` to reproduce.


| Target | Result |
| --- | --- |
| Cold launch ≤ 2 s p95 | p95 349 ms (n=20) |
| Typing echo ≤ 50 ms p95 (API proxy) | p95 0.5 ms |
| Tab switch ≤ 100 ms p95 with live panes (API proxy) | p95 13 ms with 100 panes |
| 10 windows, 50 tabs, 100 sessions | Met, with unique IDs and all sessions running |
| Idle memory ≤ 300 MiB and CPU < 2% with 10 panes | 114 MiB, 0.23% |
| 10 MiB/s flood for 60 s | 9.96 MiB/s consumed over 60.3 s (meets; the script's pass mark is 9.9 MiB/s against a writer paced at 10 MiB/s); navigation p95 6.8 ms, peak app memory 185 MiB |
| 100 create/close cycles | No leaked descriptors or children |

## Renderer benchmark (FR-TX05)

Release build of commit `92fd666`, Apple M1 Pro, macOS 26.6.2, one display, measured with `scripts/bench-renderer.py` on 2026-10-19: each workload ran 20 s, three times per renderer with the renderers alternated; medians shown. Throughput is what the app consumed from the PTY. Run `python3 scripts/bench-renderer.py` to reproduce (its windows must stay visible).

| Workload | CoreGraphics | Metal |
| --- | --- | --- |
| Cold launch to API ready (median) | 258 ms | 274 ms (+6%) |
| Idle, 4 visible panes: app CPU / RSS | 0.1% / 101 MiB | 0.1% / 123 MiB |
| Plain flood paced at 10 MiB/s: app CPU | 88% | 63% (−29%) |
| Plain flood, unpaced: throughput / CPU per MiB | 11.9 MiB/s / 99 ms | 22.8 MiB/s (+92%) / 59 ms (−40%) |
| 256-colour and truecolor SGR, unpaced | 5.8 MiB/s / 188 ms | 9.8 MiB/s (+69%) / 119 ms (−37%) |
| Full-screen repaint, every cell restyled: throughput / frames per second | 3.2 MiB/s / 20 fps | 4.7 MiB/s (+47%) / 30 fps (+50%) |
| 4 visible panes at 2 MiB/s each: app CPU / peak RSS | 90% / 165 MiB | 88% / 188 MiB |

Metal uses more memory: each Metal pane keeps its own glyph atlas, about 5 MiB (10 idle panes: 163 MiB with Metal against 122 MiB with CoreGraphics in `scripts/qualify.py`). GPU utilization sampled from IOAccelerator stayed at 0% at this sampling rate in every workload, and WindowServer CPU stayed within 1–2.2% for both renderers. Full `scripts/qualify.py` runs with `--renderer metal` and `--renderer coregraphics` met every target except the 10 MiB/s flood, which both missed (1.07 and 0.66 MiB/s), with tab-switch p95 near 74 ms. The base commit `6cfa650`, without this change, gave the same results on the same machine that day (0.71 MiB/s, 80 ms), so the miss isn't caused by the renderer. It is open against the `ee87a38` run above, and quick runs on the same day (`--quick`) gave 13 ms switching for all three.

## Pending verification

These checks can't be automated here and haven't been performed. They are recorded as pending, never as passed.

| Area | What's pending |
| --- | --- |
| Terminal engine | Real IME composition and VoiceOver terminal reading |
| Text rendering | FR-TX01 in the native app: the cursor splitting ligatures, colour changes and selections keeping them, and the setting turning them off (joined JetBrains Mono ligatures were seen on macOS 26.6.2); FR-TX02 styles seen in vim, `git diff` and a curly-underline test; FR-TX04 emoji and CJK on macOS 14's older Apple Color Emoji; VoiceOver reading concealed text; blinking text with Reduce Motion |
| GPU rendering | FR-TX05 in the native app: Metal and CoreGraphics side by side for ligatures, decorations, emoji, BiDi rows, inline images, selection and the cursor; the setting switching live; a pane moved to a display with another scale; the CoreGraphics fallback after a GPU failure and the setting turned off and on retrying Metal (only unit tests have exercised it); the qualification run above uses the CoreGraphics default |
| Native shell | Lifecycle and display checks on external and non-Retina monitors |
| Accessibility and input | VoiceOver navigation, a real IME, US and Portuguese keyboard layouts, dead keys |
| Sidebar | FR-W06 tabs hover card in the native app: open/close delays, moving into the card, live updates, clicking a tab of another window, VoiceOver reading rows and the **Show Tabs** action |
| Hosts | Native host-library and alias-discovery demos; Connect in New Window in the native UI |
| Tabs | FR-SI08 command-finished notifications in the packaged app: the banner for `sleep 12` in a background tab and with another app in front, the failed title for a non-zero exit, clicking it revealing the pane, the Off setting (only unit tests have exercised it); FR-T09 progress in the native app: the bar and the "50%"/"Paused"/"Error"/"Working" text with `printf '\e]9;4;…\a'`, the static indeterminate bar under Reduce Motion, VoiceOver reading "progress 50 percent" on the tab and pane, and real programs that emit OSC 9;4 (only unit tests have exercised it); FR-T08 desktop notifications in the packaged app (the permission prompt and an OSC 9 banner were observed in Trellis Dev): OSC 777 and OSC 99 banners, clicking one revealing its pane, the Off toggle; FR-T07 bell setting in the native app: the audible alert, the visual flash, Off staying silent; FR-T05 busy bar: the real animation with `seq`, the static bar under Reduce Motion, VoiceOver reading "output in progress"; FR-T06 input label: a real `sudo` prompt, Claude Code's bell in a background tab, VoiceOver reading "waiting for input" |
| SSH | FR-SI09 remote marks from real iTerm2, kitty, Ghostty and WezTerm shell integrations on a remote host, and the pane header's "SSH · host:/path" with its VoiceOver hint; known, unknown and changed host keys; agent, passphrase and password prompts; saved-password login through askpass, with and without Touch ID, and with real `/usr/bin/ssh` retries and host-key prompts; dropped networks, against a controlled SSH server |
| Automation | Keychain-backed grants in the native UI; live multi-client socket checks; the installed `trellis` CLI |
| MCP server | Settings → Remote Control in the native app (status text, the network-address warning, VoiceOver labels); a real Claude Code client connecting with `claude mcp add --transport http`; a client on another Mac over a LAN address; the macOS firewall prompt for a non-loopback bind |
| Portability | Native export/import demo |
| Project files | FR-WF02–FR-WF06 in the native app: the **Load Project** hover button and the selected tab's glyph, the tab context-menu items and the VoiceOver **Load Project** action, the review and save sheets (layout, keyboard use, VoiceOver reading of commands), the folder picker, and commands typed after the first prompt of a real zsh, bash and fish with real startup files. Only unit and model-level tests with fake shells have exercised it. |
| Tasks | FR-TK02–FR-TK09 in the native app: the pane header's **Tasks** button and its popover (layout, keyboard use, VoiceOver reading of rows, buttons and the running state), the review sheet, **Edit launch.json** opening an editor, and Run, Stop and Force Stop with real zsh, bash and fish (including bash's partial command reporting, fish quoting, and `env … -c` with real startup files); Force Stop on a program that ignores SIGINT. Only unit and model-level tests with a fake shell, and the composed line in `/bin/sh`, have exercised it. |
| Command scratchpad | FR-SP01–FR-SP10 in the native app: the file selector and opening saved scratchpads, Markdown highlighting and Save File, Clear and its confirmation, the pane button and menu item, panel layout and resizing, the editor's typing behavior (no substitutions, undo, Find, IME), highlighting with each bundled theme, the language selector, Validate with real `sh`, `bash` and `node`, Run with real zsh, bash and fish, the save sheet, Save & Run with review, and VoiceOver reading of every control. Model-level tests with a fake shell and a fake checker, plus a real `bash -n`, have exercised it. |
| Command palette | FR-CP01–FR-CP08 in the native app: ⇧⌘P opening over the workspace and focus returning to the pane, typing never reaching a shell, the field's keys (arrows, ⌃P/⌃N, Return, ⌘Return and ⌥Return on a host, Tab into a scope, ⌫ out of it, Esc), the backdrop click, rows' layout at narrow widths and in every bundled theme, the open animation and Reduce Motion, live theme preview while arrowing, every action running from the palette as from its menu, a real host connecting in each placement, a task run with its review, and VoiceOver reading the field, rows, selection and result count. Only unit and model-level tests have exercised it. |
| Security | Native link, clipboard and diagnostics checks |
| Inline images | FR-IM01–FR-IM03 in the native app: iTerm2's `imgcat` for small and multipart images, `chafa -f iterm`, `timg`, `yazi` previews, and images surviving scrolling, resizing, `clear`, ⌘K and the alternate screen; tmux passthrough over SSH; drawing on Intel and non-Retina displays; how VoiceOver reads rows that hold images |
| Sessions kept after quit | Observed once natively (ad-hoc development bundle, macOS 26.6.2, arm64, driven over the control socket): with the setting on, a session ran under `trellis-broker`, survived the app being killed, came back running in its pane with its output replayed after relaunch, ended when its pane was closed, and the broker then exited by itself. Still pending: FR-R03 in the packaged, signed app: the ⌘Q **Keep Running** alert itself with `sleep 600` and a full-screen program, relaunch, `ps` showing the same processes and the panes reattached with their replay; the Stop Them / Leave Running alert after quitting with a pane closed; the broker exiting 30 s after its last session; macOS privacy (TCC) prompts and their attribution for programs run by the broker; the hardened-runtime, Developer ID-signed helper; native Intel; VoiceOver reading the alerts and the restored-output notice. Only unit tests and end-to-end tests of the built helper (spawn, disconnect, reattach with replay and input, exit status, refused client, idle exit) have exercised it. FR-R04/FR-R05: the toggle and its caption in the native app, a restored pane after a real quit, `echo GITHUB_TOKEN=ghp_…` coming back redacted (only unit tests have exercised it) |
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
- **Tasks:** Stop and Force Stop use the terminal's Ctrl-C and Ctrl-\\; a raw-mode program or one that ignores SIGINT and SIGQUIT needs Restart Pane. Run needs shell integration; detection reads only the project root (FR-TK08, FR-TK03).
- **Command scratchpad:** the syntax check uses the first interpreter found in the app's PATH and the usual Homebrew and system folders, which can differ from the shell's; it finds syntax errors only. Run needs shell integration (FR-SP04, FR-SP05).
- **Command palette:** saved scratchpads aren't listed yet, and tasks are listed only while the focused pane can run one (FR-CP03). Recents last for one launch (FR-CP05).
- **Windows:** there's one native terminal window. Managed windows live in its sidebar; multiple native windows are P1.
- **MCP server:** plain HTTP with no TLS, and no server-initiated stream, so there are no event subscriptions over MCP. Use loopback or an SSH tunnel for remote agents.
- **Updates:** upgrades are manual. There's no automatic update service.
- **Sessions survive quitting only when opted in** (FR-R03). By default closing the app ends its local processes, and relaunching restores layouts as stopped sessions. Kept sessions don't survive logout or a restart, and a broker crash ends them. When every kept session ends while Trellis is closed, the broker exits 30 s later and their replay and exit notice are gone; the panes simply come back stopped. Only sessions started after the setting was turned on are kept. Kept SSH sessions lose saved-password answers after a relaunch, because the askpass socket belonged to the previous app run; ssh then prompts. A reattached pane replays at most its newest 4 MiB, from a line boundary, so earlier output and screen state older than that are gone; a full-screen program is asked to redraw. The orphan prompt also appears in read-only recovery, where no pane can claim a session; Leave Running is the safe answer there. A broker whose executable path differs from the bundled one (a moved or replaced app) is not trusted, so its sessions are neither adopted nor stopped by Trellis.
- **Scrollback file** (FR-R04/FR-R05): opt-in, unencrypted, and redaction is best effort; secrets in formats it doesn't know stay on disk. It holds what the pane retained, so text from an alternate-screen program is the visible screen only.
- **Shell knowledge:** [shell integration](../features/shell-integration.md) reports the directory, the running command and exit status for local zsh, bash and fish. Other local shells and disabled integration report none of this. SSH panes show what the remote shell's own integration prints (FR-SI09), unverified and for display only: a remote directory is never used for file links, new panes, saved launches or `session.get`. A host reached by typing `ssh` inside a local shell isn't detected, so its marks are ignored. `session.execute` still submits input without waiting for a command result, and command-completion events aren't published to automation yet.
- **File links:** relative paths open only where shell integration reports the directory. A host reached by typing `ssh` in a local shell isn't detected, so its absolute paths open if the same path exists on this Mac. `:line[:column]` suffixes aren't passed to editors, and the pointer doesn't change over links.
- **Shell integration checks pending:** fish on a Mac with fish installed (its PTY test skips without it), VoiceOver reading of the failed-command indicator, and prompt themes such as powerlevel10k and starship. FR-SI09 has been exercised only with a fake `ssh` that prints marks: real remote iTerm2, kitty, Ghostty and WezTerm shell integrations over `/usr/bin/ssh` and `mosh`, the "SSH · host:/path" header and its VoiceOver hint in the native app are pending.
