# S011 terminal selection and copy

Date: 2026-10-16. Implemented and verified. Independent review completed during S012 after the original review attempt reached its usage limit.

## Behavior

Terminal selection uses the engine's drag, double-click word/expression, triple-click line, and Select All gestures. Copy writes the selected rendered Unicode text as a plain string. ANSI styling and terminal controls are excluded while combining marks, wide characters, emoji, and joiners remain intact.

Cmd-C is consumed by the focused terminal even without a selection; it neither clears the clipboard nor sends process input. Ctrl-C retains terminal interrupt behavior. Menu-bar actions use the native responder chain. The context menu focuses the clicked pane, preserves its selection, and targets its own view for Copy, Copy All, Select All, and Paste.

Copy All reads only the currently retained buffer. Its menu title reports evicted older lines, and an alternate-screen title makes the absence of normal scrollback explicit. Clipboard access is write-only for copy and occurs only on explicit user actions. No clipboard polling or history is introduced; terminal-originated OSC 52 clipboard access remains denied.

## Verification

Full suite: **117 tests passed, zero failures**. The no-selection Cmd-C test also passed in isolation. The development bundle built and its ad-hoc signature verified.

Seven regression tests cover exact Unicode/control-free copy (including combining marks and a joined emoji), no writes/input on empty Cmd-C, Ctrl-C byte routing, focused responder targeting across two panes, retained-buffer eviction and alternate-screen limits, context-menu focus/targets, and last-column inclusion for Select All/line copy. The pane test dispatches to the hosted window’s current first responder; native menu-bar testing separately verifies application responder lookup. Tests inject write-only clipboard sinks and do not read or overwrite the user’s pasteboard.

Native checks used an isolated application identity and disposable sessions. Drag, double-click café, triple-click line selection, Cmd-A, and Cmd-C behaved as expected. Pasting copied fixture output into a controlled foreground reader preserved café, CJK, and emoji. Cmd-C with no selection left that reader running and accepting text; Ctrl-C interrupted it and returned to the shell. Context Copy round-tripped café. On an alternate screen, double-click selection and Edit → Copy retained café; the Edit menu showed Copy All Current Screen (No Scrollback). Normal-buffer restoration succeeded. One extra Return after context-menu dismissal reached an exited fixture and displayed the existing input-closed notice; it was dismissed and the clipboard result was verified separately.

Self-review found and fixed SwiftTerm’s half-open last-column edge. Terminal Select All now uses a dedicated responder action and public selection operations; the application forwards ordinary text-field Select All through AppKit. Row copy includes the full final column.

The original independent review agent reached its service usage limit before reviewing. During S012, a separate agent reviewed the complete S011 diff (032c348..e557d82), including copy selectors, native responder forwarding, retained/line selection bounds, Unicode filtering, key handling, and the seven native tests. It found no actionable defects. This closes the previously documented independent-review gap.
