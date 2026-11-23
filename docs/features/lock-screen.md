# Lock screen

These requirements are P2. The lock screen is a privacy cover: one click hides the whole workspace window behind an animation
until you prove you are the Mac's user with Touch ID or the account password. Sessions keep running underneath. It guards
against someone glancing at the screen, not against a person who takes over an unlocked Mac: they can still quit Trellis, and
the local automation API keeps working. For that, use the macOS lock screen (⌃⌘Q).

## Requirements

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| FR-LK01 | Lock the workspace from the lock button at the right end of the status bar, **Window → Lock Trellis** (⌃⌘L by default, rebindable) or the command palette. | The button follows the space name in the status bar. Locking is unavailable (button and menu item disabled, with a tooltip saying why) while this Mac can't ask for Touch ID or a password, while a sheet is open on the workspace window, while the welcome tour shows, and while the workspace is restoring or in recovery. Locking closes the command palette and takes away a showing screensaver. |
| FR-LK02 | Cover the whole workspace window with an opaque lock screen. | The sidebar, tabs, panes, right sidebar and status bar are all hidden behind it, with translucent panes too. It shows a lock symbol, the time and date, "Trellis · Locked", how many sessions are running, and "Click or press any key to unlock". Nothing from the workspace (tab, space or pane names, paths, terminal text) is drawn on it. The window title stays "Trellis". Settings, Hosts and Projects windows are hidden while locked and come back after unlocking. Error alerts wait until after unlocking. |
| FR-LK03 | Keep the workspace inert while locked. | Keys pressed in the workspace window never reach a pane or a menu shortcut; the terminal loses keyboard focus and gets it back after unlocking. Clicks, scrolls and drags land on the lock screen. Workspace menu commands and the command palette are disabled, except Lock Trellis itself, which does nothing while locked. Sessions keep running and producing output, tasks and agents keep working, and the idle screensaver never starts. |
| FR-LK04 | Unlock only after the Mac's owner authenticates. | A click or key press on the lock screen asks for Touch ID, falling back to the Mac account password, through LocalAuthentication. Success removes the lock screen. Cancel or failure keeps it, and the next click or key asks again. Only one prompt is open at a time. Locked state is never saved: a relaunch opens unlocked. |
| FR-LK05 | Offer five lock screens in Settings → Appearance → **Lock screen**, drawn in the pane theme's colours. | The choices are **Vault Dial** (the default: four rings of hex digits that turn like combination tumblers around the clock), **Redacted Shell** (a shell that keeps typing, every word drawn as a bar), **Cipher Wall** (re-rolling hex digits whose brighter cells spell LOCKED), **Ridgelines** (stacked signal traces rising slowly) and **Signal Lost** (dim static with a rolling bar). Each uses the theme's background and accent, with a soft phosphor glow and scanlines in dark themes and plain ink in light ones. The settings page shows a live preview. The choice applies with **Apply Appearance** and never restyles or restarts terminals. Settings saved without it, or naming a style this build doesn't have, load as Vault Dial without discarding the other appearance settings. |
| FR-LK06 | Respect Reduce Motion and stay bounded, like the screensaver. | With Reduce Motion on, the lock screen and its preview show one still frame and appear without a fade. It draws at most 30 frames a second, and not at all while the window is hidden or covered. Each animation's state has a fixed size for the window, so a long lock never grows memory. |
| FR-LK07 | Keep it accessible. | VoiceOver reads the lock screen as "Trellis is locked" with the hint "Activate to unlock with Touch ID or your password", and activating it asks to unlock. The animation is hidden from accessibility. The on-screen text doesn't rely on colour. |

## Implementation notes

- The model owns the state (`AppWorkspaceModel+Lock.swift`): `isLocked`, `requestUnlock()` and the injected `lockGate`
  (`UserPresenceGate`, the same Touch ID / password gate saved host passwords use) and `lockAvailable`. Tests inject a fake gate.
- The app's local event monitor drops every key for the workspace window while locked and turns it into an unlock request
  (FR-LK03, FR-LK04). It also drops pointer motion in that window, which panes otherwise track under the lock screen (a
  TUI's mouse reporting, link hover). `validateShortcut` disables workspace commands while locked, and `validateMenuItem`
  disables the app's other commands (Settings, Welcome Tour, Export Diagnostics, import/export, Install Command Line Tool)
  except About. Unlocking gives the keyboard back to the view that had it, or to the active terminal.
- Hover cards and popovers are separate windows, so they close when the workspace locks. The workspace beneath is hidden from
  accessibility while locked (FR-LK07).
- The animations are screensaver scenes (`Sources/TrellisUI/Screensaver/LockScreenScenes.swift`) drawn by the same painter, which
  also strokes and fills paths for Ridgelines and the dial's rings, and adds the glow in dark themes.

## Known limits

- Quitting Trellis stays possible while locked (from the menu bar), and a relaunch opens unlocked. Kept sessions come back with
  their replayed output.
- The local automation API, CLI and MCP server keep working while locked; they already require the user's own socket or token.
- A sheet that a background event opens while locked (for example a task prompt) can show above the lock screen.
