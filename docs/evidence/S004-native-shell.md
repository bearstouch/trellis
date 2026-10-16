# S004 native application shell

Date: 2026-10-16. Implemented and independently reviewed; physical platform/lifecycle interaction checks remain pending.

## Implementation

- SwiftUI application chrome hosted by an AppKit window, with a window sidebar, a separate per-workspace tab strip, terminal canvas, status bar, welcome state, and launch settings.
- Light native chrome and system interface fonts surround the terminal adapter's dark background and Monaco text. Automatic macOS window tabbing is disabled.
- Window geometry is restored and clamped to current visible screens. A minimum canvas preserves pane layout when the available view is too small.
- Menu commands provide Settings, New Window, Close, Hide, minimize, zoom, full screen, copy, paste, select all, and Quit. Dock reopening restores the main window.
- Shared model commands track local process launch and exit; the native views remain attached to their original sessions when sidebar selection changes.

## Independent review

Review found a stale terminal view after changing workspace selection, launch cancellation producing an invalid shared state transition, and reopening a minimized window without restoring it. Each has been corrected; selection and cancellation have regression coverage. The main-window Close path now freezes new launches, drains sessions, clears the workspaces, and keeps the application available for Dock reopening; Quit drains sessions separately. Regression tests cover pending creates and launch cancellation.

## Verification

The planned projection, tab ownership, offscreen geometry, and minimum-canvas unit cases are implemented. Tests also cover stopped workspaces, fast process exit ordering, invalid launch preferences, terminal view replacement, and cancellation during launch. Full suite: **55 tests passed, zero failures**. After tightening test scheduling, all **12 AppShellTests passed** again. The development app built and its ad-hoc bundle signature verified.

Native UI inspection verified light chrome, a separate tab strip, dark terminal text in Monaco, Unicode fixture output, accessible terminal fields, Settings fields, creation of a second workspace with a real shell, and switching back to the original terminal with its original ID/output intact. Close/Quit dialog interaction remains pending: the computer-use layer repeatedly reported concurrent user changes and did not reliably deliver those actions; source inspection found no concrete routing defect. No dialog behavior is claimed passed.

Physical external-monitor disconnection, non-Retina display behavior, and the full supported OS/CPU runtime matrix remain pending. These are not inferred from geometry unit tests. S001's physical VoiceOver/IME checks remain pending under the user's instruction to continue implementation.
