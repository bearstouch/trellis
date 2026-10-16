# S017 keyboard navigation and native accessibility

Date: 2026-10-16. Implemented with independent review and fixes and automated tests. Native interactive checks (VoiceOver, a real IME, keyboard layouts) are still **pending**.

## Behavior

**Shortcuts (AC01).** `ShortcutMap` (TrellisCore) defines every configurable command with the FR-U01 defaults: ⌘N window, ⌘T tab, ⌘W pane (a one-pane tab closes), ⌘⇧W tab, ⌘D / ⌘⇧D splits, ⌘F/⌘G/⌘⇧G search, ⌘1–⌘9 tabs, ⌘⌥Arrow focus, ⌘⌥⇧Arrow divider, ⌘⇧↩ maximize, ⌘⇧[ / ⌘⇧] tabs, ⌃⌘[ / ⌃⌘] windows. Rename Tab/Window and Delete Window have no default chord. They stay reachable from the menus. The menus are rebuilt from the saved map, so each item shows its current chord. Settings → Keyboard lists actions by menu and records chords with a local monitor that sees the chord before the menus do. Escape cancels recording, and so does a key from another window. Clear unbinds an action and Restore Defaults resets the map.

Before saving, validation reports conflicts by naming both actions. It also rejects chords without ⌘, which protects terminal control keys such as ⌃C. Reserved native chords (⌘C/V/X/A/Z/⇧Z/Q/H/⌥H/,/M/`) and unsupported keys are rejected too. Save stays disabled while there is a problem. `saveKeyboardSettings` returns the issues and keeps the previous map and the stored preferences. Only overrides of the defaults are stored, in UserDefaults under `keyboard.settings`. Unknown actions are ignored. A conflicting stored map is never applied: the defaults load instead, with a notice. While the Settings window is key, ⌘W and ⌘⇧W close it.

**Accessibility (AC02).** `WorkspaceAccessibility` projects labels, values, and selected states for windows, tabs, and panes, plus a word status for the focused pane. Examples: "Window Project", "2 tabs, new output"; "Tab Build", "1 of 2"; "Terminal Server", "Exited (7), focused". Views render these strings. Sidebar rows, tabs (button trait, Select and Rename actions), pane headers, the rename field ("Tab name", Return saves / Escape cancels), the status bar, and the shortcut rows expose them. Each terminal view's VoiceOver label is updated to the pane name and status, and its value remains the retained text (S001). Selection is shown by shape and weight as well as color: semibold selected tab/window/pane title, tab underline, and a 2 pt focus ring (previously 1 pt). Stopped, exited, and failed panes show a text status in their header.

**Platform input (AC03).** Increased Contrast thickens the focus ring and tab underline to 3 pt. Reduce Motion keeps the cursor steady without changing the saved blink preference. Both follow `NSWorkspace` accessibility display notifications. Option-as-Meta is a saved Keyboard setting and is **off by default**, so Option still composes Portuguese/US layout characters and dead keys. SwiftTerm silently toggled Meta on ⌘⌥(⌃)O; the terminal now passes that chord to the menu and never to the engine's toggle. IME and dead-key composition use SwiftTerm's NSTextInputClient: marked text is never sent, and committed text is sent once.

**Separation (AC04).** Tab renaming is owned by the model. While a tab name is being edited, every terminal sets `inputSuspended`, so keyboard and mouse-report bytes are dropped before they reach the PTY. The terminal also does not take focus away from the rename field. Committing, cancelling, clicking a terminal (which commits), changing tabs, or deleting the tab ends the edit and resumes input. Every configurable shortcut requires ⌘. Undo/Redo/Cut menu items now exist so native text fields edit normally. The app adds no Accessibility, event-tap, or global-monitor permission request, and it never logs typed input.

## Tests

- `testS017_UT01_rejectShortcutCollision`: binding New Tab to ⌘D reports New Tab and Split Left/Right, and the previous map is unchanged. A draft swap made in two steps resolves the conflict.
- `testS017_UT02_editingConsumesRenameKeys`: runs a real `cat` PTY. During rename, text, Return, and Escape delivered to the terminal never reach it; Enter commits and Escape cancels the title. Text typed after the edit arrives. A mutation check with the guard removed made this test fail.
- `testS017_UT03_inputRoutingRespectsComposition`: covers IME romaji→kana→kanji, dead key ´+e, an abandoned composition, and emoji with a combining mark. Only committed text is sent, exactly once.
- `testS017_UT04_accessibilityStateReflectsSelection`: checks the window, tab, and pane labels, values, and selected states, and the exit described in words.
- Additional tests: conflict-free spec defaults, command/reserved/unsupported rejection, override-only persistence, conflict rejection at the model level and with stored preferences, settings reaching live terminals, Reduce Motion, terminal VoiceOver labels, the ⌘⌥O/⌘⌥⌃O swallow, the configurable Find chord, and layout-based chord recording for arrows and Escape.

Full suite: **201 tests passed, 0 failures**. `swift format lint --strict` is clean and the build has zero warnings. The development app packages and its ad-hoc signature verifies; the launcher regression passes.

## Independent review

The review found and fixed three issues:

1. Renaming an unselected tab could let the newly shown terminal take focus away from the rename field while its input was suspended. The terminal now does not take focus while a rename is active.
2. Closing Settings while recording could leave the key monitor installed, so it would capture a later terminal keystroke. The monitor is now bound to the Settings window and stops on keys from any other window.
3. ⌘⌥⌃O still reached SwiftTerm's Meta toggle. The swallow now matches the engine's own condition, and a test covers it.

Recorded follow-ups (not applied):

- Lowercase normalization of hand-edited stored chords.
- Shifted-symbol and digit chords on AZERTY-style layouts need real-layout checks.
- Increased Contrast does not change palette colors.
- Tab-key focus does not move through the sidebar and tab bar, which are reachable by menu shortcuts and VoiceOver actions.
- A rename field could commit when it loses focus.

## Pending manual verification

These were not performed in this session and are **not** marked passed:

- A keyboard-only daily workflow in the native app.
- VoiceOver navigation and terminal reading.
- US and Portuguese layouts, dead keys, emoji/CJK input with a real IME, and Option-as-Meta on/off.
- Increased Contrast and Reduce Motion toggled in System Settings.
- Settings-window ⌘W.
- Visible keyboard focus in the sidebar and tab bar.
