# Status and known limits

**Version 0.9.0, pre-release.** All 32 MVP stories (S001–S032) are implemented and independently reviewed, and the full automated suite passes. Trellis isn't qualified for a 1.0 release yet: some manual and platform checks haven't been run, and two stories are blocked. The [changelog](https://github.com/layerx-labs/trellis/blob/master/CHANGELOG.md) lists what shipped.

## Release blockers

| Story | Blocker |
| --- | --- |
| [S031](../project/delivery-history.md#s031) | **Flood throughput.** A 10 MiB/s output flood is consumed at about 5–7.6 MiB/s, which misses `NFR-P07`. Navigation stays responsive during the flood. Typing and tab-switch latency meet their targets, but they were measured through API proxies rather than UI frame timing. See the [qualification results](../evidence/S031-qualification-results.md). |
| [S032](../project/delivery-history.md#s032) | **Distribution.** Universal 2 packaging, the CLI link, the release gate and the release docs are done. Developer ID signing, notarization, clean-machine Gatekeeper checks and the OS/CPU matrix are still pending. |

## Pending verification

These checks can't be automated here and haven't been performed. They are recorded as pending, never as passed.

| Area | What's pending | Story |
| --- | --- | --- |
| Terminal feasibility | Manual engine checks: real IME composition and VoiceOver terminal reading | [S001](../project/delivery-history.md#s001) |
| Native shell | Lifecycle and display checks on external and non-Retina monitors | [S004](../project/delivery-history.md#s004) |
| Accessibility and input | VoiceOver navigation, a real IME, US and Portuguese keyboard layouts, dead keys | [S017](../project/delivery-history.md#s017) |
| Hosts | Native host-library demo; alias-discovery fixture demo | [S018](../project/delivery-history.md#s018), [S019](../project/delivery-history.md#s019) |
| SSH | Known, unknown and changed host keys; agent, passphrase and password prompts; dropped networks, against a controlled SSH server | [S020](../project/delivery-history.md#s020) |
| Automation | Keychain-backed grants in the native UI; live multi-client socket checks; the installed `trellis` CLI | [S022](../project/delivery-history.md#s022)–[S029](../project/delivery-history.md#s029) |
| Portability | Native export/import demo | [S028](../project/delivery-history.md#s028) |
| Security | Native link, clipboard and diagnostics checks | [S030](../project/delivery-history.md#s030) |

## Tested matrix

Only these combinations have been run.

| macOS | CPU | Build | Result |
| --- | --- | --- | --- |
| 26.6.2 (25G83) | Apple M1 Pro (arm64, native) | Development and release builds | Full automated suite; native checks recorded per story; S031 qualification run |
| 26.6.2 | x86_64 slice under Rosetta | Universal release | The CLI runs. This is **not** a native Intel qualification. |

**Not yet tested:** macOS 14 (the declared minimum), macOS 15, native Intel hardware, external displays, and a clean machine.

## Known limits

- **Signing:** current builds are ad-hoc signed. Gatekeeper rejects them on other Macs.
- **Windows:** there's one native terminal window. Managed windows live in its sidebar; multiple native windows are P1.
- **Updates:** upgrades are manual. There's no automatic update service.
- **Sessions don't survive quitting.** Closing the app ends its local processes, and relaunching restores layouts as stopped sessions.
- **Shell knowledge:** without shell integration (P1), Trellis doesn't know a shell's current directory, the active command, or whether a command succeeded. `session.execute` submits input; it doesn't report a command result.
