# Themes

A theme file describes colors for the whole application and terminal. It never contains executable code. Everything on this page is P0.

Files on this site:

- [`theme.schema.json`](../themes/theme.schema.json): the v1 JSON Schema
- [`example-dark.theme.json`](../themes/example-dark.theme.json) and [`example-light.theme.json`](../themes/example-light.theme.json): complete palettes
- [`example-minimal.theme.json`](../themes/example-minimal.theme.json): the smallest useful theme

The three examples are also bundled in `Sources/TrellisCore/Resources/Themes`. `ThemeValidationTests` checks that the bundled copies are byte-for-byte identical to the files in `docs/themes`, and that the schema's fields match the code. If you change one, change the other.

## User experience

- Trellis ships **Trellis Dark** (`trellis-dark`) and **Trellis Light** (`trellis-light`), plus 10 editor-inspired families with dark and light variants: Modern, One, Monokai, Solarized, Nord, Dracula, GitHub, Tokyo, Gruvbox, and Rose Pine. These are Trellis adaptations with complete app and terminal palettes, available immediately without importing files.
- **Settings → Appearance** offers **System**, **Dark** and **Light** chrome modes. Dark is the first-launch default; settings saved by an earlier version keep their mode. System follows macOS, and an explicit Dark or Light stays fixed.
- Users pick a theme separately for each appearance, so a custom dark theme can be paired with the built-in light one.
- **Trellis Light** has a white terminal and **Trellis Dark** a dark one. The additional families also use light terminal backgrounds in their light variants and dark backgrounds in their dark variants.
- The font isn't part of a theme. **Settings → Appearance → Terminal font** lists locally installed monospace typefaces and the bundled ones (JetBrains Mono, Roboto Mono, Cascadia Mono NF, IBM Plex Mono, Iosevka Fixed and Atkinson Hyperlegible Mono; one entry per family) and previews the selected font. JetBrains Mono is the default; if a saved font is missing or isn't monospaced, Trellis uses Menlo or the system monospace font and shows a notice. Choose **Apply Appearance** to save font changes.
- The resolved theme colors the sidebar, tabs, split dividers, focus indicators, terminal background and foreground, cursor, selection and ANSI palette. System dialogs and standard controls follow the native appearance.
- Changing the appearance updates every window and pane without restarting shells, changing terminal contents, or losing focus or selection.
- **Settings → Appearance → Background opacity** (30–100 %, default 100 %) makes the whole window translucent, so the desktop shows through (FR-TH10). The terminal panes' default background, and the diff in a Review tab, take the opacity as set. The window's chrome (the sidebar, dock, tab bar, pane headers, side panels and status bar) follows it but never goes below 60 %, so its labels stay readable. Text, icons, the cursor, selections, cells with an explicit background color, sheets, popovers, the command palette and the find bar stay opaque. **Blur behind background** (on by default) frosts what shows through, behind the whole window. The window stays opaque while macOS **Reduce Transparency** or **Increase Contrast** is on.

## Creating a theme

1. Copy `example-dark.theme.json` or `example-light.theme.json`.
2. Change `id`, `name` and whatever colors you want. Only `version`, `id`, `name` and `appearance` are required. Any color you leave out comes from the built-in theme that matches `appearance`.
3. Open **Settings → Themes → Preview JSON…**. You can inspect the sample, or choose **Preview in Workspace**; **Cancel Preview** restores the saved appearance. **Save & Use Theme** installs the theme and activates it.
4. Select it for the matching Dark or Light appearance slot.

```json
{
  "version": 1,
  "id": "my-midnight",
  "name": "My Midnight",
  "appearance": "dark",
  "terminal": { "background": "#101820", "foreground": "#E8EEF4" },
  "ui": { "accent": "#7CC7FF" }
}
```

Loading a sample doesn't install it or touch running sessions. Previewing in the workspace changes colors only temporarily, and leaving Themes or closing Settings cancels the preview.

## Format

- UTF-8 JSON, at most 64 KiB. Duplicate object keys are rejected.
- `version` must be `1`. `id` is a stable lowercase identifier of up to 64 characters, and `name` is a display label of up to 100.
- `appearance` is `dark` or `light`. It picks the fallback palette and the slot the theme can be selected for.
- Colors are opaque `#RRGGBB`, case-insensitive. Alpha channels and color expressions aren't supported.
- `terminal` fields: `background`, `foreground`, `cursor`, `cursorText`, `selectionBackground`, `selectionForeground`, `ansi`.
- `ansi` is optional, but if present it must contain exactly 16 colors in terminal index order: black, red, green, yellow, blue, magenta, cyan, white, then the bright variants. It replaces the whole palette.
- `ui` fields: `background`, `surface`, `sidebarBackground`, `foreground`, `mutedForeground`, `accent`, `border`, `activeTabBackground`, `activeTabForeground`, `focusRing`, `success`, `warning`, `error`.
- Unknown fields, unsupported versions, invalid colors, wrong types and malformed JSON are errors. The error message gives the field path and reason, and nothing is installed or changed.
- v1 doesn't support inheritance chains, includes, remote downloads, fonts, images or scripts.

**Resolution.** Missing fields are filled from the matching built-in theme, and then the supplied values are applied. Terminal colors are the exception for light themes. Trellis Light's terminal used to be dark, so a theme that sets a dark `terminal.background`, or sets terminal colors without a background unless its `foreground` is dark, inherits from Trellis Dark's terminal and stays readable. Set a light `terminal.background` to get a light terminal. Built-in themes ship complete palettes.

A theme sets the terminal's default colors and ANSI indexes 0–15. Indexes 16–255 depend on the terminal background:

- **Dark terminal:** they keep their exact xterm values.
- **Light terminal** (background lighter than foreground, whatever the theme's `appearance`): they are derived from the theme (FR-TH09), because xterm's values assume a dark terminal and a prompt's "dark panel" would draw as a near-black block. The cube runs from `background` (16) to `foreground` (231) through ANSI 1–6, and the grey ramp from `background` to `foreground`, both with xterm's steps. Text whose color pair uses one of these indexes is lifted to at least 4.5:1, except when it uses one index for both colors (hidden on purpose) and on Powerline separators, box-drawing and block characters, whose color belongs to a neighboring segment. Dim text (SGR 2) is dimmed after the lift, so it can fall below that.

On a light terminal, a pair of ANSI 0–15 or default colors keeps the theme's exact values unless it would be nearly invisible (below 1.5:1). Then the text is lifted to 4.5:1 too, including box-drawing lines, though not Powerline separators or block elements. The rule covers every such pair, so red on green (`\e[31;42m`) can lighten, because the bundled colors have similar brightness. Dim text is dimmed after the lift, so it can fall below 4.5:1. The bundled light themes store a light color in ANSI black and a dark one in ANSI white, so that `\e[40m` stays a light background and `\e[37m` stays readable. The lift covers what that would otherwise hide: `\e[30m` on the default background, and default text on `\e[47m` or `\e[107m`. Those two backgrounds still draw dark. A pair using one index for both colors stays hidden, as it does for 256-color indexes. If the background is true color, the pair isn't changed.

True-color values are never recolored, so a program that sends 24-bit colors keeps them on every theme. If an application temporarily overrides the palette, that override belongs to its session; reapplying a theme resets it.

## Installation and persistence

- Custom themes are stored at `<state-dir>/Themes/<id>.theme.json`. The file name comes only from the validated ID; the name is just a label.
- Importing copies the file, so the original can be deleted afterwards.
- The `trellis-` ID prefix is reserved for built-in themes.
- Installing a theme whose ID already exists requires an explicit **Replace theme** in the UI, or `replace: true` through the API. Replacing is atomic, and if it fails the previous version is kept.
- **Export** writes a portable document. **Export resolved** also includes the inherited values, for an exact reproduction. Built-in fallback colors can change between releases, which affects themes that leave fields out.
- **Open Themes Folder** and **Reload Themes** let you edit themes in any editor. Reload validates the edited files and updates the valid ones atomically. For an invalid file it keeps the last valid palette in memory and shows the errors. No restart is needed.
- Deleting a selected theme falls back to the built-in theme for that slot and shows a notice. The mode and both selected IDs are saved, and Trellis falls back safely at launch if a file is missing.
- Previewing, importing and reloading never send bytes to terminal sessions.
- Themes are global. Per-space, per-tab and per-host themes are deferred.

## Contrast

- Built-in normal text and essential labels must reach at least **4.5:1** contrast against their backgrounds.
- Focus indicators and essential boundaries must reach **3:1** against neighboring colors.
- `ui.border` supplies subtle pane and chrome separators, with a **1.2:1** visibility advisory (not a WCAG target). Use `ui.focusRing` for focus indicators; separators should not compete with text or selection.
- Selected text and cursor text are tested on their own.

For custom themes, contrast warnings are advisory and name the fields involved, and you can still save the theme. Built-in palettes must pass the check at release. Status is always shown with a label or icon too, never by color alone.

## Requirements

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| FR-TH01 | Built-in dark and light themes, plus System, Dark and Light modes. Dark is the first-launch default. | Launch with an empty state directory: the chrome is dark. In System mode, change the macOS appearance: the chrome and the terminal panes follow, white under Trellis Light and dark under Trellis Dark. Explicit modes stay fixed. |
| FR-TH02 | Simple, versioned JSON themes with per-field defaults. | Import the minimal example; colors it doesn't specify come from the matching built-in theme. |
| FR-TH03 | Import, preview, select, export, replace, delete and reload custom themes. | Complete the whole flow without restarting the app or any session. Cancelling restores the previous theme. |
| FR-TH04 | Validate themes before activating them, and recover from invalid edits. | Invalid hex, an unsupported version, unknown fields, duplicate keys, an oversized file and a wrong-length ANSI array are all rejected, and the previous theme keeps working. |
| FR-TH05 | Save the appearance mode and selected theme IDs. | Restart with a custom theme selected, then again after deleting its file: Trellis falls back to the built-in theme. |
| FR-TH06 | Keep the terminal palette and the application chrome consistent. | Check ANSI 0–15, default text, selection, cursor, focused panes, active and inactive tabs, and status indicators under both themes. |
| FR-TH07 | Make theme authoring accessible. | Preview shows normal text, muted labels, selection, cursor text and status examples, and warns about low-contrast pairs by field name. |
| FR-TH08 | Support scripted theme setup through the control API. | A client with theme permission imports and selects a theme, and a layout-only grant is denied. See [Methods](../api/methods.md#theme-automation). |
| FR-TH09 | Follow the theme in 256-color output on light terminals. | With a light terminal on either renderer, `48;5;234` draws as a soft tint of the background, not `#1C1C1C`; `38;5;76` on it and `38;5;254` on ANSI blue reach 4.5:1. True color is unchanged, and a Powerline glyph keeps its raw color. `\e[30m` on the default background and default text on `\e[47m` and `\e[107m` reach 4.5:1, while `\e[31m` keeps the theme's exact color. Switching to a dark theme live restores exact xterm values. OSC 4 overrides survive OSC 10/11, and OSC 104 restores the derived palette. |
| FR-TH10 | Let the window use a translucent background, controlled by **Background opacity** and **Blur behind background** in Settings → Appearance. | Set 70 % and apply: the desktop shows through every pane's default background under both renderers, and a pane's 8 pt margin matches its terminal area. The sidebar, dock, tab bar, pane headers, side panels and status bar show it through at 70 % too; at 30 % they stay at 60 %. Text, icons, the cursor, a selection and `\e[44m` cells stay opaque, as do sheets, popovers, the command palette and the find bar. Blur off shows the desktop unfrosted. Switching themes or previewing one keeps the opacity, and cancelling a preview restores it. Turning on Reduce Transparency or Increase Contrast makes the whole window opaque live, and turning it off restores the setting. Opacity outside 30–100 % is rejected; settings saved before this setting existed load opaque with blur on. Nothing restarts or loses content. |
