# Theme specification

Status: v1 validation, preview, and theme library management implemented in S015/S016. All requirements here are P0. Theme files describe colors for the entire application and terminal; they do not contain executable code.

## User experience

Ship built-in **uTerm Dark** and **uTerm Light** themes. Settings → Appearance provides **System**, **Dark**, and **Light** modes. Light is the first-launch default for application chrome; terminal panes keep their dark palette. System follows macOS appearance changes; explicit Dark/Light modes remain fixed. Persist the user’s selected mode. Users select a theme separately for each appearance, so a custom dark theme can be paired with the built-in light theme.

**Chosen defaults:** Terminal panes use a dark background, light foreground, and Monaco in both built-in application themes. System/Light/Dark controls the application chrome; switching to light chrome does not turn the terminal background white. A custom JSON theme may explicitly override terminal colors. Monaco is a terminal setting, separate from color-only theme files; users can change it in terminal settings. Use Menlo or system monospace with a visible notice if Monaco is unavailable.

Apply the resolved theme consistently to the sidebar, tabs, split dividers, focus indicators, terminal background, default foreground, cursor, selection, and ANSI palette. System dialogs and standard native controls follow the resolved native appearance using system styling where custom colors are inappropriate. Appearance changes update all windows and panes without restarting shells, altering terminal contents, or losing focus/selection.

## Creating a theme

1. Copy [example-dark.theme.json](example-dark.theme.json) or [example-light.theme.json](example-light.theme.json).
2. Change `id`, `name`, and desired colors. Only `version`, `id`, `name`, and `appearance` are required; omitted colors inherit from the built-in theme matching `appearance`.
3. Open Settings → Themes and choose “Preview JSON…”. Inspect the sample or choose “Preview in Workspace”; “Cancel Preview” restores the saved appearance. Choose “Save & Use Theme” to install and activate it.
4. Choose it for the corresponding Dark or Light appearance slot.

For example, this is a complete minimal theme file:

```json
{
  "version": 1,
  "id": "my-midnight",
  "name": "My Midnight",
  "appearance": "dark",
  "terminal": {
    "background": "#101820",
    "foreground": "#E8EEF4"
  },
  "ui": {
    "accent": "#7CC7FF"
  }
}
```

The [JSON Schema](theme.schema.json) describes accepted fields. Full examples enumerate every supported color for discoverability; most authors only need to override a few colors. No theme inheritance chains, external includes, remote downloads, fonts, images, or scripts are supported in v1.

The [minimal example](example-minimal.theme.json) is also available as a standalone file. Settings → Themes loads any local JSON file or the three bundled examples, renders the palette in a sample terminal and application chrome, and reports validation errors or advisory contrast warnings. Loading a sample does not install it or alter working sessions. Workspace preview changes colors temporarily; leaving Themes or closing Settings also cancels it. Separate Light/Dark theme choices are available in Appearance settings.

## Format and resolution

- UTF-8 JSON, at most 64 KiB per file; reject duplicate object keys.
- `version` must equal 1. `id` is a stable lowercase identifier, up to 64 characters; `name` is a display label up to 100 characters.
- `appearance` is `dark` or `light`. It identifies the fallback palette and the appearance slot where the theme can be selected.
- Color values use opaque `#RRGGBB` notation; parsing is case-insensitive. No alpha channel or color expressions in v1.
- `terminal` colors: `background`, `foreground`, `cursor`, `cursorText`, `selectionBackground`, `selectionForeground`, and `ansi`.
- `ansi` is an optional array of exactly 16 colors, in terminal index order: black, red, green, yellow, blue, magenta, cyan, white, followed by their bright variants. If supplied, replace the entire palette; otherwise inherit the built-in palette.
- `ui` colors: `background`, `surface`, `sidebarBackground`, `foreground`, `mutedForeground`, `accent`, `border`, `activeTabBackground`, `activeTabForeground`, `focusRing`, `success`, `warning`, `error`.
- Resolve missing fields against the matching built-in theme first, then apply supplied values. Built-in themes ship complete palettes and cannot depend on themselves.
- Theme colors control terminal defaults and ANSI indexes 0–15. Terminal applications may explicitly choose 256-color or true-color values; do not recolor those values. Engine-supported temporary terminal palette overrides are session-local and never modify the JSON; reapplying a theme resets defaults and the base palette.
- Unknown fields, unsupported versions, invalid color values, wrong types, and malformed JSON are errors. Show the field path and reason before changing installed themes or current appearance.

## Installation and persistence

Store validated custom themes under `Application Support/<app-identity>/Themes/<id>.theme.json`; derive the filename only from the validated ID. Reserve the `uterm-` prefix for built-in IDs. Names are labels, not filenames. Imported files are copied into this directory; the application does not depend on the original source file remaining available.

A duplicate ID requires an explicit “Replace theme” action in the UI or `replace: true` in an authorized API request. Replacement is atomic and preserves the previous valid version on failure. Export writes a portable theme document; “Export resolved” can include inherited values for exact reproduction. Changes to built-in fallback colors across application versions may affect themes that omit fields.

Provide “Open Themes Folder” and “Reload Themes” so users can edit JSON with any editor. Reload validates edited files, atomically updates valid themes, and keeps the last valid in-memory palette for invalid files while showing errors. File watching is optional. No restart is required. Deleting a selected theme falls back to the built-in palette for that slot and displays a notice. Persist the mode and both selected theme IDs, and fall back safely if files are missing at launch.

Preview is temporary and reversible: cancel restores the previous effective appearance. Preview/import/reload never sends bytes to terminal sessions. A theme is global in MVP; per-window, per-tab, and per-host overrides are deferred.

## Acceptance requirements

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| FR-TH01 | Built-in dark/light themes and System/Dark/Light modes. | Change macOS appearance in System mode and verify application chrome follows while default terminal panes stay dark; explicit chrome modes stay fixed. |
| FR-TH02 | Simple, versioned JSON themes with per-field defaults. | Import the minimal example and verify unspecified colors inherit from the matching built-in theme. |
| FR-TH03 | Import, preview, select, export, replace, delete, and reload custom themes. | Complete the flow without restarting the app or any session; cancellation restores the previous theme. |
| FR-TH04 | Validate themes before activation and recover from invalid edits. | Test invalid hex, unsupported version, unknown fields, duplicate keys, oversized files, and an ANSI array of the wrong length; prior theme remains usable. |
| FR-TH05 | Persist appearance mode and selected theme IDs. | Restart with a custom theme selected, then repeat with its file removed and verify built-in fallback. |
| FR-TH06 | Keep terminal palette and application chrome consistent. | Render ANSI indexes 0–15, default text, selection, cursor, focused panes, active/inactive tabs, and status indicators under both themes. |
| FR-TH07 | Make authoring accessible. | Preview shows normal text, muted labels, selection, cursor text, and status examples; warn about low-contrast pairs with field names. Custom colors may still be saved after warning. |
| FR-TH08 | Support scripted theme setup through the existing control API. | A theme-authorized client imports/selects a theme; a layout-only grant is denied. |

Built-in normal text and essential UI labels target at least 4.5:1 contrast against their backgrounds; focus indicators and essential boundaries target 3:1 against adjacent colors. Test selected text and cursor text separately. Theme warnings are advisory for user-authored palettes; built-in palettes must pass release checks. Status is also conveyed through labels/icons.
