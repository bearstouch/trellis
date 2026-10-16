# Non-functional requirements

These are proposed release targets, not measured claims. The feasibility milestone must record the reference hardware, OS/build, engine version, workloads, and measurement method. If targets change, record the reason before implementation proceeds.

## Performance and capacity

| ID | Target | Verification |
| --- | --- | --- |
| NFR-P01 | Cold launch to usable empty window ≤2 seconds p95 over 20 launches on the reference machine. | Measure release build outside debugger; report OS caching conditions. |
| NFR-P02 | Input-to-render latency ≤50 ms p95 during ordinary local typing. | Timestamp a reproducible key-to-echo workload; separate remote network latency. |
| NFR-P03 | Window/tab switch ≤100 ms p95 with 50 live panes. | Exercise mixed idle and output-producing sessions. |
| NFR-P04 | Support at least 10 managed windows, 50 tabs, and 100 total sessions without state corruption. | Stress lifecycle and verify IDs, focus, and cleanup. This is a capacity test, not a promise that arbitrary processes fit memory. |
| NFR-P05 | Default scrollback is 10,000 lines per pane with a 16 MiB additional storage cap; initial automation replay budget is 8 MiB total. | Flood output with long lines and verify oldest-first eviction and bounded application-owned buffers. Engine memory overhead is measured separately. |
| NFR-P06 | Empty app plus 10 idle panes uses ≤300 MiB resident app memory and <2% of one CPU core averaged over 60 seconds. | Exclude child-process memory; report it separately. Measure idle with no blinking animation workload or output. |
| NFR-P07 | A continuous output flood keeps navigation responsive and bounded. | Stream 10 MiB/s for 60 seconds; retain keyboard responsiveness, bound queues, and report any visual coalescing/output eviction. |

## Reliability and correctness

- **NFR-R01:** No orphaned PTYs, unreaped children, or growing descriptor count after 100 create/close cycles. Verify cleanup for local and SSH sessions.
- **NFR-R02:** Atomic state writes and tested backup recovery; interruption during save must leave a readable current or backup snapshot.
- **NFR-R03:** Stable resource IDs and serialized mutations. Conflicting revisions fail explicitly; no silently overwritten concurrent layout edits.
- **NFR-R04:** Engine/parser failures and malformed API input must not corrupt persisted state. Fuzz protocol framing, split trees, imported files, and boundary sizes.
- **NFR-R05:** An unexpected app crash may end sessions. Recovery must say that sessions stopped, and never imply process continuity or replay input.
- **NFR-R06:** Output parsing must preserve terminal byte ordering. UI rendering may coalesce frames but must not silently reorder data.

## Security and privacy

- **NFR-S01:** Local socket and containing directory are owner-only; verify peer user identity, authenticate every connection, and enforce scoped expiring/revocable grants. No TCP listener in MVP.
- **NFR-S02:** Same-user malware is outside strong isolation guarantees. These controls reduce accidental and unauthorized client access; they cannot make a compromised user account safe.
- **NFR-S03:** Store no passwords, private-key contents, input transcripts, or terminal output in application logs or saved layouts. Diagnostic export is opt-in and previewable.
- **NFR-S04:** Do not construct SSH command lines through shell interpolation. Validate destinations and use an executable plus argument array; never add host-trust bypass flags.
- **NFR-S05:** Treat terminal output as untrusted. Disable terminal-initiated clipboard writes/reads (including OSC 52) by default; opening a link requires a user gesture, and reject dangerous URL schemes.
- **NFR-S06:** Screen capture/output access and command execution require separate capabilities. Never assume an agent may read or control every pane because it can enumerate metadata.
- **NFR-S07:** Host imports and layouts are data; validation does not execute startup commands. Layout application cannot contain embedded shell commands. Execution is a separate explicit API operation.
- **NFR-S08:** Credentials stay in system-supported SSH authentication flows. Automation secrets are excluded from child environments, exports, terminal output, and log messages.
- **NFR-S09:** No telemetry or network reporting by default. No clipboard monitoring or retention beyond user-triggered operations.

## Native usability and accessibility

- **NFR-U01:** Every primary operation is keyboard accessible; focus location remains visible in terminal, tabs, sidebar, and dialogs.
- **NFR-U02:** VoiceOver can identify sidebar items, tabs, terminal panes, statuses, and action labels. Terminal reading behavior must be evaluated during the engine spike; an inaccessible engine blocks release.
- **NFR-U03:** Honor system appearance, increased contrast, reduced motion, and native text input. Color must not be the sole status indicator. Built-in palettes must meet the contrast requirements in the [theme specification](../03-functional-requirements/themes/README.md); custom palettes receive actionable contrast warnings.
- **NFR-U04:** Verify US and Portuguese keyboard layouts, dead keys, Option-key behavior, emoji, combining marks, wide CJK characters, and an IME composition workflow.
- **NFR-U05:** Use actionable errors with target resource and recovery action; never expose tokens or sensitive terminal content in error payloads.

## Maintainability and release checks

Keep terminal engine, persistence, application state, and transport replaceable through narrow boundaries. Pin dependencies and review licenses before distribution. Validate split-tree operations, migrations, authorization, process lifecycle, and API contracts automatically; use a manual terminal/clipboard/IME/accessibility matrix for behaviors automation cannot reliably verify. Every release must run on the macOS and CPU matrix defined in platform support.
