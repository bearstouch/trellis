# EX-17: Notifications, toasts, clipboard and openURL

Part of the [Extensions specification](SPEC.md#stories). **Epic:** 3, Tier 0 · **Phase:** 3b · **Requirements:** FR-EX15 · **Depends on:** [EX-7](EX-07-extension-supervisor.md), [EX-9](EX-09-runtime-prompts-audit.md) · **Points:** 3

**Definition.** As an extension author, I want to notify the user, show toasts, set badges, copy text and open links, so that my extension can tell people what happened and hand them results.

These Tier 0 features use existing Trellis chrome. Clicking a notification or toast counts as a user action for the modal rule. Clipboard writes and `openURL` work only within 5 s of a user action, and reading the clipboard is never available.

## Scope

**In**

- `trellis.notify({title, body})`: a desktop notification through `DesktopNotifications`, needing `notifications`.
- `trellis.toast({title, body, tone})`: an in-window toast, needing `notifications`.
- `notification.clicked` events; a click counts as a user action aimed at the extension.
- `trellis.clipboard.writeText(text)`: needs `clipboard.write`, only within 5 s of a user action. Handled by the bridge, checked against approved permissions and audited.
- `trellis.openURL(url)`: https only, in the default browser, only within 5 s of a user action.
- `trellis.sidebar.setBadge(id, {count, tone})` and `trellis.tabs.setBadge(tabId, …)` stored per surface for the dock (EX-23) and tabs (EX-25) to show.

**Out**

- Drawing badges on the dock and tab bar (EX-23, EX-25).

## Acceptance criteria

- [ ] **Given** `notifications`, **when** the extension calls `notify`, **then** a desktop notification shows. **When** it calls `toast`, **then** an in-window toast shows.
- [ ] **Given** a notification or toast is clicked, **when** the extension opens a modal within 5 s, **then** it is allowed, and `notification.clicked` is delivered.
- [ ] **Given** no user action in the last 5 s, **when** the extension calls `clipboard.writeText` or `openURL`, **then** it rejects with `USER_GESTURE_REQUIRED`.
- [ ] **Given** a recent user action and `clipboard.write`, **when** the extension writes text, **then** the clipboard holds it and the audit log records the call.
- [ ] **Given** any extension, **when** it looks for a clipboard read API, **then** there is none.
- [ ] **Given** `openURL` with a non-https URL, **when** it is called, **then** it is refused.
- [ ] **Given** `setBadge` with a count and tone, **when** it is called, **then** the value is stored for its surface, and a count of zero clears it.

## Implementation notes

- Reuse `DesktopNotifications` (`Sources/TrellisUI/DesktopNotifications.swift`) and its injected notifier.
- Inject the clipboard and the URL opener so tests are deterministic.
- The 5 s user-action clock is shared with EX-9.

## Tests

- `ExtensionSurfaceTests`: gesture rule for clipboard and `openURL`; notification click counts as a user action.
- Additions to `Tests/TrellisUITests/DesktopNotificationTests.swift` for extension notifications.
