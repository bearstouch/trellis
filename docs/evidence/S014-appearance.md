# S014 appearance and Monaco defaults

Date: 2026-10-16. Appearance implementation reviewed by an independent agent; review findings fixed, with additional engine fixes and regression tests completed by the primary agent after the reviewer hit its usage limit.

## Behavior

First launch uses native light chrome, a dark `#151719` terminal background, light text, and Monaco 13 pt. Settings offers Light, Dark, and System chrome independently of the dark terminal palette. Explicit modes set an AppKit appearance; System clears the override and follows macOS. SwiftUI settings and workspace chrome use the same policy.

Appearance settings include a monospaced font name, 8–48 pt size, block/underline/bar cursor, optional blinking, and 0–50,000 historical rendered rows. The existing 16 MiB historical-text bound remains in force. An unavailable or proportional font falls back to Menlo, then system monospace, with a visible notice in settings and the workspace footer. View menu zoom applies to all panes; Cmd-+ and Cmd-= increase, Cmd-- decreases, and Cmd-0 restores 13 pt.

Changes update existing native terminal views without changing session identity, launching/stopping a process, sending terminal input, or moving keyboard focus. Font reflow preserves selections in retained logical text, including full-width completed/current rows, combining/CJK/ZWJ characters, and repeated text. History reductions remap surviving selections and clear selections whose original text was evicted; an identical later occurrence is never substituted. Alternate-screen applications retain their screen-oriented resize behavior, so clipped cells and evicted history are outside the retained-text guarantee.

The workspace persistence service saves appearance mode, font, cursor, history limit, and separate light/dark theme IDs. Pre-S014 settings decode with the agreed defaults. Theme IDs are stored independently of font settings; JSON color themes and library selection are S015/S016 work.

## Review and engine changes

Independent review fixed full-row final-cell selection, wide-glyph continuation boundaries, repeated text anchoring, and history-only selection relocation. It also strengthened the live-session test to observe zero outbound terminal bytes.

Review exposed two pinned-engine font issues: the font setter invoked DECSTR, resetting live application modes/attributes, and current-cursor logical lines were excluded from reflow and could be truncated. The repository now vendors the exact SwiftTerm 1.20.0 source snapshot with a minimal macOS library manifest. [Engine provenance and update instructions](https://github.com/layerx-labs/trellis/blob/master/ThirdParty/SwiftTerm/PATCHES.md) and the three-file `trellis.patch` make the changes reproducible and reviewable. A font-only opt-in reflows the normal-buffer cursor line and maps the cursor to a destination row identity, including when earlier rows are evicted. Ordinary frame resizing and alternate-screen policies retain upstream behavior. Font changes resize without DECSTR.

The initial agent review completed and its fixes were applied. Its follow-up review hit an account usage limit; the primary agent completed and inspected the engine delta. A second independent review of that final engine delta was unavailable and is not claimed here.

## Verification

Full suite: **154 tests passed, zero failures**. The native development bundle builds and its ad-hoc signature verifies.

Coverage includes all four named story cases; simulated system/explicit-mode resolution; missing-Monaco → Menlo → system fallback; old settings decoding and persistence of custom theme IDs; stable terminal-view/workspace identity; actual child PID/session continuity; zero outbound input; unchanged focus and Unicode selection; preserved application-cursor, bracketed-paste, and active SGR attributes; cursor continuation after narrowing/widening; eviction of a long cursor line's beginning; alternate-screen scope; and surviving/evicted selection behavior under history reductions.

Native verification on this Apple Silicon development host confirmed light and dark native settings, System mode selection, dark terminal rendering with light chrome, Monaco, visible missing-font fallback to Menlo, View → Zoom In, Cmd-=, Cmd--, and Cmd-0. An isolated saved workspace reopened with its terminal stopped and restored Dark mode, Monaco 14 pt, and blinking enabled. The shortcuts then changed size to 15 pt and restored 13 pt. Packaged app signature verification passed after the engine fix.

Actual macOS-wide appearance toggling was not performed; deterministic policy tests cover simulated system changes, and native System mode uses AppKit's automatic appearance. Older supported macOS versions, Intel, font/renderer visual qualification across displays, and release capacity/performance remain the S031/S032 platform qualification work.
