# macOS platform support

## Supported platform

- **MAC-01 / P0:** macOS only. Provisional minimum macOS 14; support the minimum version and each subsequent public major version through the current stable release when shipping. Publish the actual tested matrix per release. Beta OS releases are best-effort.
- **MAC-02 / P0:** Native Swift application, provisionally Universal 2 for Apple silicon and Intel. Validate dependency/build feasibility on both before making a release commitment. Rosetta is not a substitute for native Apple silicon qualification.
- **MAC-03 / P0:** SwiftUI application chrome and native AppKit terminal interaction. No Electron, browser runtime, or web-hosted terminal UI.

## Native behavior

**MAC-04:** Integrate the menu bar, settings, Dock, standard hide/minimize/full-screen actions, standard dialogs, system appearance (including explicit Dark/Light overrides and custom JSON palettes), clipboard, font selection, and keyboard responder chain. Closing the terminal-bearing native window with live sessions asks once whether to terminate affected sessions; on acceptance it closes the workspaces and returns the app to an empty state. Reopening the main window shows the current state. Quitting has its own running-session confirmation.

**MAC-05:** Distinguish application-managed tabs from macOS automatic window tabbing. Disable automatic native tabbing in MVP. All workspace tabs belong to Trellis's model and are controllable by the API.

**MAC-06:** Support Retina scaling, monitor changes, full-screen layouts, restored window geometry constrained to available displays, and consistent terminal cell sizing. When available area becomes too small, retain the tree and ratios in a scrollable minimum-sized terminal canvas instead of silently deleting panes or resizing below minimum dimensions. Exact canvas behavior must be verified in the UI spike.

**MAC-07:** Use Monaco as the default terminal font; retain native system fonts for application chrome and provide a monospace fallback with a visible notice if Monaco is unavailable. Respect IME composition, dead keys, keyboard layout differences, and configurable Option-as-Meta behavior. Cmd-C/Cmd-V remain native copy/paste; terminal Ctrl-C retains interrupt behavior. Clipboard actions and terminal input must not fight the responder chain.

## Files, credentials, and permissions

Use the user's Application Support directory for durable configuration and the Caches/runtime directory for disposable data and control discovery as appropriate. Store user preferences through native settings storage. Use Keychain for application control credentials. Keep private-key contents outside the app's stores.

**MAC-08:** Run shells and SSH as the current user, with no root helper. Request no blanket Accessibility, Screen Recording, or Full Disk Access permission on launch. Respect macOS privacy restrictions; explain a denied directory operation in context instead of requesting unrelated privileges.

**MAC-09:** Provisional MVP distribution is outside the Mac App Store, without App Sandbox. Sign the app and bundled CLI, enable compatible hardened-runtime protections, notarize, staple where appropriate, and verify Gatekeeper behavior on a clean machine. Keep signing identifiers and application name provisional until release identity is selected.

Apple's [App Sandbox guidance](https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox) informs this boundary; the exact packaging and entitlement configuration must be verified against Apple's current release tooling during implementation.

## Installation, upgrades, and removal

**MAC-10:** Distribute an application bundle in a DMG or signed installer, selected before release. Bundle the `trellis` executable; provide an explicit user-invoked setup step to install a user-local CLI link. Never change shell startup files or write system directories silently.

**MAC-11:** MVP can use manual signed upgrades; automatic update delivery is P1. Version persisted state, migrate safely, retain a last-known-good backup, and reject unsupported newer formats without overwriting them. Document downgrade limitations.

**MAC-12:** Uninstallation removes the application and optional CLI link; document how to remove application-owned configuration and Keychain items. Never delete SSH keys, SSH configuration, known-hosts files, or unrelated shell history. Removing hosts only deletes saved metadata.

## Release verification matrix

| Area | Required evidence |
| --- | --- |
| OS and architecture | Cold launch and daily-use scenario on minimum/current supported macOS; both CPU architectures where supported |
| Terminal | PTY, job control, resize, alternate screen, Unicode, mouse modes, long output, and process cleanup |
| Input | US and Portuguese layouts, an IME, dead keys, Option/Meta, shortcuts, copy/paste, multiline preview |
| Accessibility | VoiceOver navigation and terminal reading, keyboard-only operation, contrast and focus indicators |
| Lifecycle | Close/quit confirmation, crash recovery, stopped restoration, backup migration, application activation by CLI |
| Displays | Retina/non-Retina where available, monitor disconnect, full screen, small window behavior |
| Security | Gatekeeper, signing/notarization, protected paths, token revocation, same-user socket ownership and malformed clients |
| Hosts | Known/unknown/changed host keys, agent auth, passphrase/password prompts, alias configuration, dropped network |

## Deferred native-window expansion

**MAC-13 / P1:** Multiple native windows may display independent managed workspaces. A running pane must have one authoritative native host view; detaching or moving it must preserve the PTY/process and stable IDs. Decide whether a managed window maps one-to-one to a native window before implementing this expansion. No OS desktop/window tiling manager is part of this product.
