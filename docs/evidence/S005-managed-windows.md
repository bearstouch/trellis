# S005 managed windows

Date: 2026-10-16. Implemented with independent review fixes; final suite verified by the primary agent.

## Behavior

The sidebar creates and selects independent managed windows. Its context menu renames a window, moves it up/down, or deletes it. Names and ordering pass through the authoritative command service. Reorder requests must be exact permutations; failed commands leave state unchanged.

Switching keeps the original tab/pane selections, session IDs, native terminal objects, and processes. Inactive output and exits set bounded Boolean indicators; selecting the window clears them. Output never changes selection or stores an additional transcript.

Deletion shares the native live-session confirmation used by Close and Quit. Cancellation leaves the window and sessions intact. Confirmed deletion gates new starts, stops affected processes, waits for pending launch/exit updates, then removes the hierarchy. The domain command rejects deletion of starting/running/closing sessions, preventing an alternate caller from orphaning processes. Deleting the final window reaches the welcome state.

## Verification

Final full suite: **64 tests passed, zero failures**. Nine S005 cases cover initial hierarchy IDs, selection identity, invalid/valid ordering, bounded inactive activity, atomic rejection of live deletion, empty-state deletion, and cancel/confirm live deletion with a real PTY.

Independent review fixed stale async command replies regressing visible state, unread indicators remaining on a newly selected fallback window, and a launch becoming live while a modal close prompt was open. Regression tests cover stale replies and fallback indicators; the selection fixture now includes multiple tabs, split panes, and live domain session identities. Real PTY deletion also verifies an unaffected window retains its running process ID and session ID. The review agent hit its account usage limit after applying fixes; the primary agent inspected the changes and ran the final passing suite.

Native pointer/context-menu and modal-dialog interaction remains a manual qualification check, alongside the S004 platform checks. Persistence across relaunch belongs to S010 and remains unverified here.
