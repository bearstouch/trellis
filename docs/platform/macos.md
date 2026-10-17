# macOS support

## Supported platform

- **MAC-01 (P0):** macOS only. The minimum is macOS 14, and every later public major version is supported through the current stable release. Each release publishes the matrix that was actually tested. Beta OS releases are best-effort.
- **MAC-02 (P0):** a native Swift app, built as Universal 2. The arm64 and x86_64 slices are built natively and combined with `lipo`. Running under Rosetta doesn't count as native Apple silicon or Intel qualification.
- **MAC-03 (P0):** SwiftUI for the application chrome and AppKit for terminal interaction. No Electron, browser runtime or web-hosted terminal UI.

## Native behavior

- **MAC-04:**
    - Trellis integrates with the menu bar, Settings, the Dock, standard hide, minimize and full-screen, standard dialogs, the system appearance, the clipboard, font selection and the keyboard responder chain.
    - Closing the native window while sessions are live asks once whether to end them. Accepting closes the workspaces and returns the app to its empty state, and reopening the main window shows the current state.
    - Quitting has its own running-session confirmation.
- **MAC-05:** Trellis's tabs aren't macOS automatic window tabbing, which is disabled. Every workspace tab belongs to Trellis's model and can be controlled through the API.
- **MAC-06:**
    - Trellis supports Retina scaling, monitor changes and full-screen layouts. Restored window geometry is constrained to the displays available, and terminal cell sizing is consistent.
    - When the window gets too small, the tree and its ratios are kept in a scrollable, minimum-sized canvas. Trellis never silently deletes panes or shrinks them below their minimum.
- **MAC-07:** Six terminal typefaces (Roboto Mono, JetBrains Mono, Cascadia Mono NF, IBM Plex Mono, Iosevka Fixed, Atkinson Hyperlegible Mono, each in Regular, Bold, Italic and Bold Italic) are bundled with the app and registered for the Trellis process only. Roboto Mono is the default terminal font, with a monospace fallback and a notice, while the chrome uses system fonts. IME composition, dead keys, layout differences and the configurable Option-as-Meta setting are all respected. Cmd-C and Cmd-V stay native copy and paste, and Ctrl-C stays the terminal interrupt.

## Files, credentials and permissions

- Durable configuration goes in Application Support, and disposable data in Caches or the runtime directory. The control socket lives in the per-user `$TMPDIR`.
- Preferences use native settings storage, and automation credentials use the Keychain. Private-key contents are never stored.
- **MAC-08:** shells and SSH run as the current user, with no root helper. Trellis never asks at launch for blanket Accessibility, Screen Recording or Full Disk Access permission. If macOS denies a directory operation, Trellis explains it in context instead of requesting unrelated privileges.
- **MAC-09:** Trellis is distributed directly, not through the Mac App Store, and without App Sandbox, so that it can run ordinary developer shells. The app and the bundled CLI are signed with the hardened runtime and no entitlements, notarized and stapled. Gatekeeper is verified on a clean machine. A sandboxed build would need its own feasibility decision.

## Installation, upgrades and removal

- **MAC-10:** the app ships as a signed DMG with the `trellis` executable in `Contents/Helpers`. Installing a user-local CLI link is an explicit step the user runs. Trellis never silently edits shell startup files or writes to system directories.
- **MAC-11:** upgrades are manual and signed for the MVP; automatic updates are P1. Persisted state is versioned and migrated safely, a last-known-good backup is kept, and newer formats are rejected without being overwritten. Downgrading has known limits.
- **MAC-12:** uninstalling removes the app and the optional CLI link. `trellis cli uninstall-plan` lists the app-owned files and Keychain items. It never touches SSH keys, SSH configuration, known-hosts files or shell history. Deleting a host deletes only its metadata.

The step-by-step procedures are in the [release guide](../release/README.md).

## Release verification matrix

| Area | Required evidence |
| --- | --- |
| OS and architecture | Cold launch and the daily-use scenario on the minimum and current macOS, on both CPU architectures |
| Terminal | PTY, job control, resize, alternate screen, Unicode, mouse modes, long output and process cleanup |
| Input | US and Portuguese layouts, an IME, dead keys, Option/Meta, shortcuts, copy and paste, multiline preview |
| Accessibility | VoiceOver navigation and terminal reading, keyboard-only operation, contrast and focus indicators |
| Lifecycle | Close and quit confirmation, crash recovery, stopped restoration, backup migration, launching the app from the CLI |
| Displays | Retina and non-Retina where available, monitor disconnect, full screen, small windows |
| Security | Gatekeeper, signing and notarization, protected paths, token revocation, same-user socket ownership, malformed clients |
| Hosts | Known, unknown and changed host keys; agent authentication; passphrase and password prompts; alias configuration; dropped networks |

[Status](../overview/status.md) shows which rows are still pending.

## Deferred: multiple native windows

**MAC-13 (P1):** multiple native windows could each show independent managed workspaces. A running pane must have exactly one authoritative native host view, and detaching or moving it must keep its PTY, process and IDs. Before building this, decide whether a managed window maps one-to-one to a native window. Trellis won't be an OS-level window tiling manager.
