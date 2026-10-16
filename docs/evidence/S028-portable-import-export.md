# S028 portable import and export

Date: 2026-10-16. Implemented with independent review and fixes, and automated tests through the real workspace model and host library. A native export/import demo is **pending**.

## Behavior

### Export

File → **Export Workspace…** writes a `trellis.portable` v1 document. It contains:

- `format` and `version`;
- a v1 `layout` with fresh keys, window names, tab titles, split axes and ratios, pane titles, and launches;
- `hosts`, holding portable metadata: name, destination, user, port, identity-file path, and tags.

Host references use fresh UUIDs generated for each export. They are never library or runtime IDs.

The export never contains:

- window, tab, pane, or session IDs;
- PIDs, terminal output, or transcripts;
- environment values;
- tokens or grants;
- key contents.

Custom command panes are exported as plain shells, never as their commands, and are counted; the user is told how many. The file is written atomically and set to owner-only permissions.

### Preview

File → **Import Workspace…** first parses the file strictly and shows a preview without changing anything.

- **Rejected outright:** the wrong format, an unsupported version, unknown fields, malformed hosts, repeated references, or a file over 4 MB or 1,000 hosts.
- **Preview contents:**
  - window, tab, pane, and host counts;
  - the directories and hosts that panes use;
  - every collision with an existing host, by case-insensitive destination or name;
  - errors found by the host validator and the layout planner, such as unsafe paths, limits, missing references, or identity files that don't exist on this Mac.

### Import

Import is disabled while there are errors, and while collisions exist without an explicit policy:

| Policy | Effect |
| --- | --- |
| Use my existing hosts | Panes are bound to your existing matching hosts. |
| Keep both | The imported hosts are added as new hosts. |
| Replace my existing hosts | Your matching hosts are overwritten, provided their revision hasn't changed since the preview. |

There is no default, and nothing is ever replaced on a matching name alone. Two imported hosts targeting the same existing host are refused before anything changes.

Commit runs in this order:

1. Validate all hosts and plan the layout. Planning uses empty bindings, so every window, tab, split, and pane gets a fresh ID.
2. Commit the host changes in one write.
3. Commit the layout atomically through `applyLayout` against the preview's base revision. All panes are stopped and nothing starts.

If the layout commit fails, the host import is reverted. Only the hosts it created are removed, and only replaced hosts that nobody has edited since are restored, keeping their `connectionRevision`. Concurrent edits survive the revert.

Interactive import is separate from S026's namespace apply: it never records bindings and never matches existing resources.

## Tests

- `testS028_UT01_exportOmitsSensitiveState`: the workspace holds a running process with `--password=hunter2`, `API_KEY=s3cr3t-env`, output `OUTPUT-SECRET`, a split with a host pane, and a saved host. The export contains none of the runtime IDs, the host's library ID, the secrets, the output, or the executable. Every key is in the allowed set, host metadata is kept, one conversion is reported, and the export round-trips through preview without errors.
- `testS028_UT02_interactiveImportRemapsIds`: the same file is imported twice. Counts and directories are previewed, each import gets a fresh, disjoint window ID, there are 4 panes in total, every session is stopped with no process, and the second host collision needed an explicit keep-both.
- `testS028_UT03_hostCollisionNeedsPolicy`: an import without a policy returns `decisionRequired`, leaving the existing host and an empty workspace. Use-existing binds panes to the existing host. Replace updates it and advances its connection revision. Keep-both adds a second host. Collisions are detected regardless of case and whitespace, and a double replace is refused with the library unchanged.
- `testS028_UT04_invalidImportIsAtomic`: one invalid host among three installs no host and no window. Version 2 is refused. A workspace failure after hosts were staged reverts exactly to the previous hosts. The revert keeps concurrent edits and restores replaced hosts. A directory error only the planner can find appears in the preview.

Full suite: **284 tests passed, 0 failures**. Lint is clean, the build has zero warnings, and the app packages and verifies.

## Independent review

The review fixed five issues:

1. The revert overwrote concurrent host edits and bumped every host's revision.
2. A double replacement of the same host gave a misleading error.
3. Collision checks were case- and newline-sensitive.
4. The policy picker didn't say which hosts collide. It now lists each pair with destinations.
5. Planner-only errors appeared only after Import was pressed. A failed revert was also misreported as "nothing imported".

I added owner-only export permissions and an identity-file existence check in the preview.

Follow-ups, not applied:

- A crash between the host and layout commits leaves the hosts without the layout.
- Exports can exceed the import limits; there is no warning at export time.
- Some invalid scalar fields are silently dropped.
- The policy applies to all collisions, not per host.
- The sheet window is not released, and the layout failure message is generic.

## Pending manual verification

Not performed, and **not** marked passed:

- Export from the native app, inspect the file, and re-import it in a second isolated instance.
- Exercise the collision sheet and its three policies through the UI.
