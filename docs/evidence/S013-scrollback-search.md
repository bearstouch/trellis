# S013 bounded scrollback and pane search

Date: 2026-10-16. Implemented, independently reviewed, and verified with native long-output and alternate-screen sessions.

## Behavior

Each terminal starts with 10,000 historical rendered rows. Historical text also has a 16 MiB UTF-8 budget, including a conservative separator cost per row. Exceeding either limit evicts a contiguous oldest prefix. An oversized historical row is discarded with everything older rather than joining disjoint output. The active screen and terminal-engine cell/grapheme/image overhead are accounted separately, as specified by NFR-P05; this is not a claim that the process or engine uses only 16 MiB.

The engine remains the authoritative screen/history representation. Row byte costs use the engine's Unicode grapheme resolver, cache generation metadata, and do not retain a second transcript. Budget eviction trims the engine history and preserves its visible screen. The eviction notice also appears in Copy All.

Find in Pane (Cmd-F), next (Cmd-G), and previous (Shift-Cmd-G) search rendered plain text in that terminal only. Search selects and reveals the current match. Adapter-side matching uses rendered grapheme cells with row offsets and resolves only the chosen match back to engine coordinates; it avoids the pinned engine’s last-column clamp and wrapped-Unicode search defects. No per-character position arrays are retained. The search bar lives above the terminal, with a history-eviction or alternate-screen notice. It uses no find pasteboard. Alternate-screen searches cover only that screen and return to normal history when the application restores it. Output and resize changes invalidate the selected match rather than trusting old coordinates.

PTY delivery remains serialized with a 16 KiB read bound and backpressure before the next read. Parser input is never coalesced, dropped, or reordered. The existing engine frame coalescing and the new 16 ms accessibility notification coalescing affect presentation only.

## Verification

Full suite: **138 tests passed, zero failures**. The final close-toolbar ownership adjustment passed both focused hosted-window tests and independent inspection; the final packaged app built and its ad-hoc signature verified.

New coverage includes the four named story cases, actual engine line/byte eviction, last-column and soft-wrapped combining/CJK/ZWJ searches, capacity recovery and reflow, a 12,000-row individually delivered flood, parser input split at every byte, real 80 KiB binary PTY output ordering with read chunks at most 16 KiB, and initial/reopened/repeated search-field focus plus two-field ownership.

Review replaced the engine’s faulty search range mapping, removed per-character position arrays, and made history accounting incremental. It also added capacity hysteresis under byte pressure to avoid repeated engine allocations. The 12,000-small-read byte-pressure fixture improved from 24.47 seconds to about 0.93 seconds in the full suite on this host; this is a regression-fixture observation, not release performance qualification.

Native verification generated 12,000 ordered Unicode rows in an isolated local session. The app retained recent rows, visibly highlighted row11999, reported earlier output eviction, and returned No match for row00001. A second pane could not find the first pane’s row11999. In a disposable Vim session, ALT_SEARCH was highlighted with Current screen only / No scrollback; quitting restored normal history.

Native QA caught a Cmd-F reopening race that could leave keyboard focus in the terminal. A native NSTextField focus-request bridge replaced the unreliable Boolean focus state. The final package passed initial Cmd-F, rapid close/reopen followed by typing, two open search fields, Cmd-G and Shift-Cmd-G, and clicking either field to direct navigation to its own pane. Closing another pane’s toolbar transferred both keyboard focus and active-pane ownership to that terminal. Both final verification shells exited with code 0.

The pinned engine retains a unique-grapheme dictionary independently of row eviction. Total engine/process memory, images, and the OS/CPU performance matrix remain S031 qualification work; the historical rendered-text budget is not a total-memory guarantee.
