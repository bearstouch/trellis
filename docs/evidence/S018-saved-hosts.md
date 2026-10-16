# S018 saved-host library

Date: 2026-10-16. Implemented with independent review and fixes, and covered by automated tests. Native interactive checks are still **pending**.

## Behavior

`HostLibrary` (TrellisCore) is the host repository. It is separate from the workspace store, so recovering a workspace never drops saved hosts.

**Fields.** Each host has:

- a display name
- an SSH alias or hostname
- an optional user
- an optional port
- an optional absolute identity-file *path*
- tags

**Revisions and order.** Every committed change advances the library revision and stamps the changed host with it. Updates and deletes carry the revision the editor loaded, and a stale editor gets a conflict. Saving with no changes keeps the revision. Hosts are listed by name.

**Search.** Search is case-insensitive across name, destination, user, and tags. Every whitespace-separated term must match, and results keep the caller's order.

**Validation.** It runs before any write and reports one actionable message per field:

- Port must be 1–65535, using ASCII digits.
- The destination must be non-empty and at most 255 bytes. It cannot start with `-`, contain `@`, whitespace, or control characters, and may only use alias/hostname/IP characters.
- The user cannot start with `-`. It cannot contain `@`, whitespace, control characters, or shell metacharacters, which OpenSSH can substitute into `ProxyCommand`/`Match exec`.
- The identity file must be an absolute, normalized path to an existing regular file. The file is checked with `stat`; its contents are never read.
- Tags are comma-separated, de-duplicated without regard to case, at most 64 characters each, and at most 32 per host.

**Storage.** Persistence goes to `hosts.json` in the state directory:

- The document is versioned JSON, published by fsync and an atomic same-directory rename.
- The file is mode 0600, with a last-known-good `hosts.backup.json`.
- No passwords, key contents, or terminal output are stored.
- Loading re-validates every record, rejects duplicate IDs, and rejects host revisions newer than the document revision. A hand-edited `-oProxyCommand` destination or a forged revision is never accepted.
- If the file is unreadable or newer, the library is read-only. Reset Host Library renames the file aside (`hosts.unreadable.<uuid>.json`) before starting empty.
- A failed write leaves the previous library in memory and on disk.

**Connections.** `SavedHost.connectionLaunch` builds the argument array for a future `/usr/bin/ssh` launch: `-p`, `-l`, and `-i` options, then `--`, then the destination. A session freezes this launch when it starts (through `startSession(resolvedLaunch:)`), so edits affect only later connections. Connecting from the UI is S020.

**Deletion.** Deleting a host removes only its metadata. Sessions, processes, SSH keys, `ssh_config`, and `known_hosts` are untouched, and the confirmation dialog says so.

**UI.** The Hosts window opens from File → Hosts… (configurable, no default shortcut) or from the sidebar Hosts button. It has:

- a search field and an accessible host list
- New Host
- an editor with per-field errors that are spoken in the field's accessibility value
- an identity-file chooser that records only the path
- Delete… with confirmation
- a recovery button when the file is unreadable

Results from an asynchronous save or delete are applied only if the user has not switched to another host since.

## Tests

- `testS018_UT01_validateHostBoundaries`: ports 0/1/65535/65536 and a full-width port, a leading-option destination, `user@host`, control characters, spaces, ANSI in the name, a `-l` user, and relative, missing, and `..` identity paths. Only valid records are accepted, and all field errors are reported together.
- `testS018_UT02_searchAcrossMetadata`: mixed-case name, tag, destination, and user terms, multi-term AND, empty and no-match queries, and stable order.
- `testS018_UT03_editDoesNotMutateLiveLaunch`: a running session keeps its frozen ssh descriptor while the host revision advances. A stale editor gets a conflict, and an unchanged save keeps the revision.
- `testS018_UT04_deleteDoesNotTouchSshFiles`: uses a real temporary state directory and fixture SSH files. Only `hosts.json` and its backup are written, the store snapshot (with a running session) is unchanged, the SSH files are byte-identical, and no key contents are stored.
- Additional tests:
  - owner-only file mode and reload
  - a tampered file is preserved and read-only, then reset
  - a failed write keeps the previous library
  - review tests: shell metacharacters in the user, a forged revision, and reset of an oversized unreadable file preserving its bytes

Full suite: **211 tests passed, 0 failures**. `swift format lint --strict` is clean, the build has no warnings, and the development app packages and verifies.

## Independent review

The review found and fixed four issues:

1. User names containing shell metacharacters were accepted and could reach `%r` expansion on older OpenSSH.
2. Reset copied the unreadable file through a read that could fail silently, so it could lose that file. It now renames the file aside or aborts.
3. A forged host revision higher than the library revision could defeat stale-edit detection.
4. Late save or delete results overwrote a newer host selection or draft.

Recorded follow-ups, not applied:

- INT-03's "destination kind" is not stored separately.
- There is no automatic fallback to `hosts.backup.json`.
- Bracketed IPv6 and non-ASCII destinations should be checked against real `ssh` in S020.
- `%` in an identity path is expanded by ssh.
- The permissions of an existing state directory are not tightened.

## Pending manual verification

Not performed in this session, and **not** marked passed:

- Create fixture hosts in the native Hosts window, relaunch, and verify persistence and search.
- Delete a host and confirm `~/.ssh` is unchanged.
- VoiceOver reading of the editor's field errors.
