# EX-10: Settings → Extensions: approval sheet, Development mode, Create, Install from Folder, Remove

Part of the [Extensions specification](SPEC.md#stories). **Epic:** 2, Host and authority · **Phase:** 3a · **Requirements:** FR-EX02, FR-EX06, FR-EX27 · **Depends on:** [EX-4](EX-04-extension-registry.md), [EX-7](EX-07-extension-supervisor.md), [EX-9](EX-09-runtime-prompts-audit.md) · **Points:** 5

**Definition.** As a Trellis user, I want one Settings page where I install, approve, inspect, reload and remove extensions, so that only I can give an extension power and I can always see what it has.

Enabling, approving and installing can't be done from the CLI or the API. Settings → Extensions is the only place an extension gains power.

## Scope

**In**

- `ExtensionSettingsView`: the installed list with name, version, state and folder.
- The detail page: an Enable toggle; permissions, origins, events and providers in words; remembered choices with Revoke; signed-in providers with Sign Out; contributed settings; load issues and the last runtime error; Reload, Reveal in Finder, Show Log, Show Audit Log and Remove….
- `ExtensionApprovalSheet`: lists, in words, every permission, network origin, OAuth provider (with scopes) and event. `git.read` says it reveals the repository's folder path.
- Development mode toggle per extension, with a "Dev" marker on the Settings row and the dock icon.
- Install from Folder…: validate, then copy into `Extensions/<name>/`; refuse to overwrite a different extension with the same name.
- Create Extension…: scaffold a working template and reveal it: `package.json`, `src/main.tsx` (a `defineView` example written in JSX), a build script that compiles JSX to `trellis.ui.h` and maps the `trellis` import to the global, `trellis.d.ts`, `README.md` and an `AGENTS.md`. Created extensions start in Development mode; installed ones start pinned.
- Remove…: a confirmation naming what will be deleted, then delete the folder, its data and its rules.
- Suspended extensions shown dimmed with the reason.

**Out**

- Sign Out's token deletion (EX-28) and Keychain cleanup on Remove (EX-28, EX-29). The buttons call into those stories.
- The contributed settings controls (EX-18).
- Reload's mechanism (EX-11).

## Acceptance criteria

- [ ] **Given** installed extensions, **when** I open Settings → Extensions, **then** each shows name, version, state and folder.
- [ ] **Given** a Disabled extension, **when** I turn on Enable, **then** the approval sheet lists every permission, origin, event and provider in words, and the extension runs only after I approve.
- [ ] **Given** a folder chosen with Install from Folder…, **when** it is valid, **then** it is copied into `Extensions/<name>/` and shows as Disabled within 1 s. **Given** a different extension with the same name exists, **then** the install is refused.
- [ ] **Given** Create Extension…, **when** I run it, **then** a template with the listed files is created and revealed, in Development mode, and it loads once built.
- [ ] **Given** Development mode is on, **when** I look at the Settings row and the dock icon, **then** both carry a "Dev" marker.
- [ ] **Given** a remembered choice, **when** I press Revoke, **then** it is removed and the next matching action prompts.
- [ ] **Given** Remove…, **when** I confirm, **then** the confirmation named the folder, data and rules, and all of them are deleted.
- [ ] **Given** the CLI or the API, **when** a client tries to enable, approve or install an extension, **then** no such method exists.
- [ ] **(manual)** **Given** VoiceOver, **when** I walk the Settings page and approval sheet, **then** every control is labelled. Stays **pending** until observed.

## Implementation notes

- New in `TrellisUI`: `ExtensionSettingsView`, `ExtensionApprovalSheet`, the scaffold template and `trellis.d.ts`.
- Follow existing Settings panes such as `Sources/TrellisUI/AutomationSettingsView.swift` and `Sources/TrellisUI/RemoteControlSettingsView.swift`.
- The template's `AGENTS.md` tells coding agents how to build an extension; its build targets ES2022.
- Inject the file system for install and remove.

## Tests

- `ExtensionRegistryTests`: install refuses a same-name different extension; remove deletes folder, data and rules; created extensions start in Development mode.
- `ExtensionSurfaceTests` or a Settings UI test for the approval sheet contents.
