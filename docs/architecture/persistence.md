# Persistence

## What is saved and where

All state lives in `~/Library/Application Support/<identity>/`: `com.bearstouch.trellis` for the installed app, and `com.bearstouch.trellis.dev` for development builds (unbundled executables and the `Trellis Dev` feasibility bundle). The two identities also hold separate instance locks, so both can run at once. The `--state-directory /abs/path` launch argument replaces that location.

| File | Contents | Protection |
| --- | --- | --- |
| `workspace.json` | Windows, tabs, split trees and ratios, titles, tab colors, selection, launch descriptions and settings (shell, directory, window frame, appearance, remote control, `keepSessionsRunning`, `restoreScrollback`) | Last-known-good copy in `workspace.backup.json` |
| `hosts.json` | Saved hosts, including whether each has a saved password (never the value) | `hosts.backup.json`. An unreadable file is preserved as `hosts.unreadable.<UUID>.json`. |
| `grants.json` | Automation grant metadata, with token **hashes** only | An unreadable file is preserved, and the store becomes read-only |
| `layout-bindings.json` | Namespace/key → resource bindings for declarative layouts, and for each project's [workspace file](../features/workspace-files.md) window (namespace `workspace-file:<folder>`) | An unreadable file is preserved |
| `workspace-trust.json` | Trusted workspace files as (canonical project folder, SHA-256 digest) pairs, and folders never to offer (FR-WF03); never the commands | `0600`. An unreadable file trusts nothing and is never overwritten. |
| `control.json` | Discovery for the running control socket | Rewritten on every launch |
| `Themes/<id>.theme.json` | Custom themes | File names come only from validated IDs |
| `Scrollback/<session-uuid>.txt` | Only with **Restore scrollback after quit** (FR-R04): a pane's redacted plain text | `0600` in a `0700` folder; see [below](#opt-in-scrollback-file) |
| `broker.json` | Only after a session was kept running (FR-R03): `{protocolVersion, socketPath}` of this folder's `trellis-broker` | `0600`, read without following symlinks; no token or PID |

Some settings are also stored in `UserDefaults`: `terminal.shell`, `terminal.directory`, `app.windowFrame` and `keyboard.settings`. Grant tokens live in the Keychain, under service `Trellis Automation`. Saved-host passwords live under service `Trellis SSH Host`, with the host UUID as account. The Keychain is written before `hosts.json`, and a failed metadata write restores the previous Keychain value.

**Never persisted:**

- terminal output and typed input, except the opt-in, redacted scrollback file (FR-R04/FR-R05)
- authentication material
- environment variable values
- process IDs and session states
- custom-process arguments

Saved launch descriptions can refer to a shell, a host or a directory, but they never replay earlier input. A local shell pane's directory is the last one its shell reported through [shell integration](../features/shell-integration.md) (FR-SI07), if it still exists; otherwise it's the directory the pane was launched in. A pane that was running a custom process comes back *unconfigured*, because its arguments weren't saved.

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
- **After a crash:** the app says that sessions stopped. It never implies that processes continued, and it never replays input. The one exception is a session kept by the broker (FR-R03), which is reported as running only because the broker answered for it.

## Restoring stopped sessions

Relaunching restores windows, tabs, splits and titles with every session **stopped**. `WorkspaceStore.restoreStoppedSnapshot` accepts only stopped sessions and only into an empty store. You start panes yourself, one at a time or with "Start all" after reviewing the launch summary (`FR-R01`).

Right after the restore, and whatever the setting, the app asks this folder's broker (if `broker.json` names a live one) which sessions it holds (FR-R03). A stopped pane whose session UUID matches adopts the running process through `.adoptRunningSession(sessionID:processID:)`, which accepts only a stopped session without a launch attempt and a positive, unowned PID. Nothing is spawned, and process IDs and states are still never saved. Sessions no pane claims are offered **Stop Them** / **Leave Running**.

## Opt-in scrollback file

With **Restore scrollback after quit** on (FR-R04), quitting writes each pane's retained text to `Scrollback/<session-uuid>.txt`. This is the one exception to "terminal output is never persisted", and it exists only because the user turned it on:

- The text is plain: the engine's retained characters, never raw output bytes or escape sequences. On restore it is cleaned again to printable characters, tabs and line breaks before it reaches the parser.
- `ScrollbackRedactor` (FR-R05) runs first, over at most the newest 2 MiB; the newest 1 MiB is kept, starting at a line. The total is capped at 64 MiB; panes beyond it aren't saved.
- Files use the same owner-only atomic write as `workspace.json` (`OwnerOnlyStorage`). The folder must be a real directory owned by the user; reads use `O_NOFOLLOW`. Only `<uuid>.txt` and the store's own temporary files are ever deleted.
- Files are deleted when their pane or window closes, the pane restarts, the setting is turned off (all of them), or their session isn't in the restored workspace. They are never exported, imported, sent to automation or journaled.
- The file is **not encrypted**, and redaction is best effort. The setting's caption says so.

## Migrating from uTerm

On first launch, if `com.bearstouch.trellis` doesn't exist, Trellis copies the first existing legacy folder: `dev.trellis` (the previous bundle identifier, copied as-is except its per-instance `control.json`), then `dev.uterm` (or `dev.uterm.feasibility`) through a staging directory and then moves it into place. The originals are left alone. Custom themes whose IDs use the reserved `trellis-` prefix get the new ID `imported-<uuid>`, and their saved selections in `workspace.json` and its backup are updated to match (uTerm sources only). Preferences from the `dev.trellis` defaults domain are imported once, never overwriting a value already set. Only the installed app identity migrates. Development builds (`com.bearstouch.trellis.dev`) and paths passed with `--state-directory` are used as-is, with no migration. If an older custom library at such a path has theme IDs that begin with `trellis-`, rename those IDs yourself, along with their filenames and saved selections.
