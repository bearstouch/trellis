# S029 theme control API

Date: 2026-10-16. Implemented with independent review and fixes, and automated RPC tests against a real theme library and live PTY. Native verification through the installed CLI is **pending**.

## Behavior

### Methods

All methods go through the same `ThemeValidator`, `ThemeLibrary` install rules, built-in protection, and appearance model as the UI.

| Method | Behavior |
| --- | --- |
| `theme.list` | Every theme with its ID, name, appearance, built-in flag, and selected slots. Includes `appearanceRevision`. |
| `theme.get` | Summary, resolved palette, and contrast warnings. |
| `theme.validate` | Takes `document` or raw `documentText`. Returns `valid`, `errors` (path and message), and contrast `warnings`. |
| `theme.import` | Takes `document` or `documentText`, plus `replace`. Installs the theme without changing the selection. |
| `theme.export` | Takes `id` and `resolved`. Built-ins export their resolved palette. |
| `theme.delete` | Deletes a custom theme. If it was selected, its slot falls back to the built-in theme. |
| `appearance.get` | `mode`, both slot IDs, the effective theme, and `revision`. |
| `appearance.set` | Takes `mode`, `lightThemeId`, `darkThemeId`, and `expectedRevision`. |

`documentText` passes the exact bytes to the validator, so duplicate keys and number forms are checked just as in a file import. The CLI always sends files this way.

**Errors:**

- Replacing or deleting a built-in `trellis-` theme returns `INVALID_STATE`.
- Importing an existing ID without `replace` returns `CONFLICT`.
- A missing theme returns `NOT_FOUND`.
- A theme that fails validation returns `-32602` with field details.

### Appearance changes

- **Slot checks:** a theme assigned to the wrong light/dark slot returns `-32602`, and nothing changes.
- **Revisions:** a stale `expectedRevision` returns `CONFLICT` with no change.
- **Terminals:** changes reach terminals through the color-only `applyPalette` path. Font and cursor settings are not reapplied, and sessions are never started, restarted, or sent input.
- **Defaults:** the built-in dark terminal palette stays the default under light chrome.

The appearance revision advances exactly once per committed change. `appearance.changed` is emitted once, after the effective theme has settled, with the mode, slots, effective theme, and revision. Workspace previews and keyed retries emit nothing.

### Permissions

- The read methods need `theme.read`.
- `theme.import`, `theme.delete`, and `appearance.set` need `theme.write` and an all-windows grant, so window-scoped and layout-only grants cannot change global appearance.
- `appearance.changed` events need `theme.read`, independent of window scope; the hub checks this at every delivery.

### CLI

- `trellis theme list|get|validate FILE|import FILE [--replace]|export --id [--resolved]|delete --id`. `--theme` is accepted as an alias for `--id`.
- `trellis appearance get|set --mode --light-theme --dark-theme --expected-revision`.
- An invalid theme exits 2.

## Tests

- `testS029_UT01_themePermissionMatrix`: a read-only grant can read but its writes are denied. A layout-only grant is denied everything. A window-scoped grant with `theme.write` can read but its writes are denied. Only the global grant can write, and only it changed the mode.
- `testS029_UT02_rejectWrongAppearanceSlot`: a dark theme in the light slot, a light theme in the dark slot, and both slots set to the same light theme each return `-32602`. A missing ID returns `NOT_FOUND`. The settings and revision are unchanged. A correct set with the current revision succeeds and changes the effective theme.
- `testS029_UT03_protectBuiltInsAndRevision`: replacing a built-in (with or without `replace`) fails, and deleting one returns `INVALID_STATE`. A duplicate import returns `CONFLICT`, an explicit replace succeeds, and the export reflects it. A stale revision returns `CONFLICT` with no change. Invalid documents, including duplicate keys sent as raw text, are rejected. The theme directory contains only the one valid file.
- `testS029_UT04_appearanceEventHasNoProcessEffects`: a live byte-echo process runs throughout. A preview followed by a cancel emits nothing. A keyed `appearance.set` plus its retry produce one event with the settled ID and a revision exactly 1 higher. The PID, session, and running state are unchanged, and the process received no input bytes.
- CLI: documented flags map to API params, files are sent as `documentText`, a missing `--id` exits 2, and an invalid theme exits 2.

Full suite: **289 tests passed, 0 failures**. Lint is clean, the build has zero warnings, and the app packages and verifies.

## Independent review

The review fixed three issues:

1. Duplicate or early appearance events and multiple revision bumps per change, including events from uncommitted previews.
2. A theme import that reset a slot did not save the workspace.
3. CLI flags did not match the documented `--dark-theme`/`--id`.

I added `documentText` so the API applies the validator's exact duplicate-key checks.

Follow-ups, not applied:

- A grant with only `theme.read` cannot subscribe, because `events.subscribe` also needs `metadata.read`.
- Replacing a theme that is in use recolors terminals but emits no event.
- Reported state shows the previewed theme's ID while a preview is active.
- All library errors in `theme.export` are reported as `NOT_FOUND`.

## Pending

- Drive themes through the installed `trellis` CLI against the live app, and watch terminals recolor with no lifecycle change.
