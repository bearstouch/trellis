# Persistence

## What is saved and where

All state lives in `~/Library/Application Support/<identity>/`: `dev.trellis` for the installed app, and `dev.trellis.dev` for development builds (unbundled executables and the `Trellis Dev` feasibility bundle). The two identities also hold separate instance locks, so both can run at once. The `--state-directory /abs/path` launch argument replaces that location.

| File | Contents | Protection |
| --- | --- | --- |
| `workspace.json` | Windows, tabs, split trees and ratios, titles, selection, launch descriptions and settings (shell, directory, window frame, appearance) | Last-known-good copy in `workspace.backup.json` |
| `hosts.json` | Saved hosts | `hosts.backup.json`. An unreadable file is preserved as `hosts.unreadable.<UUID>.json`. |
| `grants.json` | Automation grant metadata, with token **hashes** only | An unreadable file is preserved, and the store becomes read-only |
| `layout-bindings.json` | Namespace/key → resource bindings for declarative layouts | An unreadable file is preserved |
| `control.json` | Discovery for the running control socket | Rewritten on every launch |
| `Themes/<id>.theme.json` | Custom themes | File names come only from validated IDs |

Some settings are also stored in `UserDefaults`: `terminal.shell`, `terminal.directory`, `app.windowFrame` and `keyboard.settings`. Grant tokens live in the Keychain, under service `Trellis Automation`.

**Never persisted:**

- terminal output and typed input
- authentication material
- environment variable values
- process IDs and session states
- custom-process arguments

Saved launch descriptions can refer to a shell, a host or a directory, but they never replay earlier input. A pane that was running a custom process comes back *unconfigured*, because its arguments weren't saved.

## Writing safely

Every write follows the same steps (`WorkspacePersistence`):

1. Create the directory with mode `0700` if it's missing.
2. Write to a new temporary file, opened with `O_EXCL | O_NOFOLLOW` and mode `0600`.
3. `fsync` the file, `rename` it over the target, then `fsync` the directory.
4. On a successful save, the previous valid `workspace.json` becomes `workspace.backup.json`.

Reads use `O_NOFOLLOW`, require a regular file, and are capped at 4 MiB and 128 levels of JSON nesting.

Only one writer runs at a time, and writes are sequence-gated, so an older save can't overwrite a newer one. Ordinary UI changes are debounced by **300 ms**. ⌘S and Quit flush immediately, and if the save fails, Quit is cancelled.

Interrupting a save at any point must still leave a readable current file or backup.

## Versions and migration

- `WorkspaceSnapshotCodec.currentVersion` is `1`, and `HostLibraryCodec.currentVersion` is `1`. Version 0 workspaces are migrated in memory when loaded.
- When you change the on-disk format, bump the version, add a migration, and add a test that loads the old format. A failed migration must leave the original file untouched.
- A **newer, unknown** version opens in read-only recovery and is never overwritten. Downgrading isn't supported, so keep a copy of the folder before you try.

## Recovery

Loading returns `.missing`, `.loaded` or `.recovery(reason, backup?)`.

- **Corrupt file:** the user chooses **Recover backup** or **Start empty**. Before anything is written, the original is preserved as `workspace.corrupt.<UUID>.json`.
- **Unsupported version:** persistence stays read-only for the rest of the session.
- **After a crash:** the app says that sessions stopped. It never implies that processes continued, and it never replays input.

## Restoring stopped sessions

Relaunching restores windows, tabs, splits and titles with every session **stopped**. `WorkspaceStore.restoreStoppedSnapshot` accepts only stopped sessions and only into an empty store. You start panes yourself, one at a time or with "Start all" after reviewing the launch summary (`FR-R01`).

## Migrating from uTerm

On first launch, if `dev.trellis` doesn't exist, Trellis copies `dev.uterm` (or `dev.uterm.feasibility`) through a staging directory and then moves it into place. The originals are left alone. Custom themes whose IDs use the reserved `trellis-` prefix get the new ID `imported-<uuid>`, and their saved selections in `workspace.json` and its backup are updated to match. Only the installed app identity migrates. Development builds (`dev.trellis.dev`) and paths passed with `--state-directory` are used as-is, with no migration.
