# Non-functional requirements

These are release targets. Measured results, with the hardware, OS, build and method used, are in the [S031 qualification results](../evidence/S031-qualification-results.md). If you change a target, write down the reason first.

## Performance and capacity

| ID | Target | How it's verified | Latest result |
| --- | --- | --- | --- |
| NFR-P01 | Cold launch to a usable empty window ≤ 2 s p95 over 20 launches | Release build, outside the debugger | p95 348 ms |
| NFR-P02 | Input-to-render latency ≤ 50 ms p95 for ordinary local typing | Reproducible key-to-echo workload, with remote latency kept separate | p95 0.4 ms, measured through an **API proxy**; UI frame timing pending |
| NFR-P03 | Window or tab switch ≤ 100 ms p95 with 50 live panes | Mix of idle and output-producing sessions | p95 11 ms with 100 panes, measured through an **API proxy** |
| NFR-P04 | At least 10 windows, 50 tabs and 100 sessions without state corruption | Lifecycle stress test checking IDs, focus and cleanup | Met |
| NFR-P05 | 10,000 lines of scrollback per pane plus a 16 MiB cap; an 8 MiB automation replay budget | Flood long lines and check that the oldest are evicted first | Met |
| NFR-P06 | Empty app plus 10 idle panes ≤ 300 MiB resident and < 2% of one core over 60 s | Child processes measured separately | 73 MiB, 0.38% |
| NFR-P07 | A continuous 10 MiB/s flood for 60 s keeps navigation responsive and bounded | Queues bounded; any coalescing or eviction reported | Navigation p95 60 ms; **throughput 5–7.6 MiB/s, which misses the target** |

## Reliability and correctness

- **NFR-R01:** after 100 create/close cycles, there are no orphaned PTYs, no unreaped children, and no growth in descriptor count. Applies to both local and SSH sessions.
- **NFR-R02:** state writes are atomic and backup recovery is tested. An interrupted save leaves a readable current or backup snapshot.
- **NFR-R03:** resource IDs are stable and mutations are serialized. Conflicting revisions fail explicitly; concurrent layout edits are never silently overwritten.
- **NFR-R04:** failures in the engine or parser, and malformed API input, never corrupt persisted state. Protocol framing, split trees, imported files and boundary sizes are fuzzed (`BoundaryFuzzTests`).
- **NFR-R05:** an unexpected crash may end sessions. Recovery says that sessions stopped and never implies that processes continued or replays input.
- **NFR-R06:** output parsing keeps the terminal's byte order. Rendering may coalesce frames but never reorders data.

## Security and privacy

- **NFR-S01:** the local socket and its directory are owner-only. The peer's user is verified, every connection is authenticated, and grants are scoped, expiring and revocable. There is no TCP listener.
- **NFR-S02:** malware running as the same user is outside strong isolation guarantees. These controls reduce accidental and unauthorized access; they can't make a compromised account safe.
- **NFR-S03:** no passwords, private-key contents, input transcripts or terminal output in logs or saved layouts. Exporting diagnostics is opt-in and shows a preview first.
- **NFR-S04:** SSH command lines are never built through shell interpolation. Destinations are validated, an executable plus argument array is used, and no host-trust bypass is ever added.
- **NFR-S05:** terminal output is untrusted. Terminal clipboard access, including OSC 52, is off by default. Links need a user gesture, and dangerous schemes are rejected.
- **NFR-S06:** reading the screen or output and executing commands need separate capabilities. Being able to list metadata never implies being able to read or control a pane.
- **NFR-S07:** host imports and layouts are data. Validating them runs nothing, and layouts can't contain shell commands.
- **NFR-S08:** credentials stay in the system's SSH authentication flows. Automation secrets are excluded from child environments, exports, terminal output and logs.
- **NFR-S09:** no telemetry and no network reporting. The clipboard is never monitored, and nothing is kept beyond operations the user triggers.

### Diagnostics export

**Help → Export Diagnostics…** builds a `DiagnosticsReport` that contains only an allow-list of fields:

- app version, macOS version and architecture
- counts of windows, tabs and panes, and sessions per state
- counts of hosts, active grants and custom themes
- the appearance mode and whether the control socket is running
- up to 20 recent *known* error codes

The text is passed through `SecretRedactor`, which removes `trl_` tokens, `sha256:` hashes, PEM keys and email addresses, and replaces the home path with `~`. The user then sees the exact text before saving it to a `0600` file. Nothing is ever sent over the network.

## Usability and accessibility

- **NFR-U01:** every primary operation is keyboard accessible, and the focus stays visible.
- **NFR-U02:** VoiceOver identifies sidebar items, tabs, panes, status and actions. An engine that isn't accessible blocks release.
- **NFR-U03:** honor the system appearance, increased contrast, reduced motion and native text input. Color is never the only status indicator, and contrast follows the [theme rules](../features/themes.md#contrast).
- **NFR-U04:** US and Portuguese layouts, dead keys, Option behavior, emoji, combining marks, wide CJK characters and IME composition all work.
- **NFR-U05:** errors are actionable and name the target resource and a recovery action. They never contain tokens or sensitive terminal content.

## Maintainability

- The terminal engine, persistence, application state and transport each sit behind a narrow boundary so they can be replaced.
- Dependencies are pinned, and their licenses are reviewed before distribution.
- Split-tree operations, migrations, authorization, process lifecycle and API contracts are all validated automatically.
- Terminal, clipboard, IME and accessibility behavior that automation can't check reliably goes through a manual matrix.
