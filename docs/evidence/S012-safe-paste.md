# S012 safe paste and escaped paths

Date: 2026-10-16. Implemented, independently reviewed, and verified in native two-pane sessions.

## Behavior

Cmd-V and context Paste read text once on an explicit user action and route through the focused native terminal. Multiline/control-bearing text opens a review with the target, logical line count, byte count, visible control labels, and a bounded preview. Cancel discards the ephemeral payload. Paste does not append a newline, normalize line endings, or rewrite the clipboard.

Approval is bound to pane and session IDs. Pane/tab/window changes, closure, and stopped sessions invalidate a pending review; switching back cannot revive an old approval. Confirmation revalidates the current running target. Payload plus bracketed-paste framing is enqueued as one input write, and framing is used only when the terminal has negotiated it at submission time.

Paste Escaped Path is an explicit menu/context action. File URLs become filesystem paths; a text clipboard is treated as one literal path. zsh/bash/sh use single-quote escaping, including embedded apostrophes; multiple file URLs become separate quoted arguments. Other shells always show the quoted text for review with an unsupported-shell explanation. Ordinary paste remains unchanged text.

## Verification

Full suite: **126 tests passed, zero failures**. The development app built and its ad-hoc signature verified.

The four named story cases are implemented alongside bounded-preview, clipboard-action, and native/model integration checks. A real raw-mode PTY verifies exact bytes (including CR/LF, tab, Unicode, ESC, and NUL) with negotiated bracketed paste enabled and disabled. Actual zsh/bash/sh processes round-trip quoted path arguments containing spaces, apostrophes, dollar signs, and embedded newlines. The two-pane model test checks cancel, focus away/back, a queued native request followed by focus changes, closed targets, and approved input reaching exactly one surviving pane.

Independent review fixed an asynchronous native request race by checking the original terminal identity and focus epoch on both sides of pane selection. Closing a pane/tab/window now invalidates pending and queued requests immediately; failed input cannot leave stale published review state. Preview targets include pane ordinals, and NEL participates in logical line counting. The modal review sheet owns its button focus; pane/tab/window changes are the invalidation boundary.

Native verification used an isolated app identity with two active local shells. Multiline input showed Pane 2, three logical lines, exact byte count, and visible LF controls. Cancel left both buffers unchanged. Approved input appeared only in Pane 2 and remained in zsh’s negotiated bracketed-paste editor until a separate Return. Changing panes with the focus shortcut while review was open dismissed it without sending the stale text. A single-line paste remained unexecuted until Return. A control fixture displayed TAB and ESC labels and cancellation left the buffer unchanged.

Edit → Paste Escaped Path inserted the literal text path `/tmp/a b's $HOME` using single-quote escaping. No newline was added; after a separate Return, printf received exactly one argument with its apostrophe and dollar sign preserved. This native check used a text clipboard; Finder file-URL item negotiation has not been manually exercised. Both disposable shells exited with code 0 after verification.

The reviewer also completed the previously delayed S011 review with no actionable findings; its evidence and plan status now reflect that completed review.
