# Themes

A theme sets the colors of the whole app and of the terminal panes. Trellis comes with a set of built-in themes, and you can write your own as a small JSON file. A theme file holds only colors; it can never contain code.

## Choose your themes

Open **Settings → Appearance** (<kbd>⌘</kbd><kbd>,</kbd>).

- **Application appearance** is **System**, **Dark** or **Light**. Dark is the default on a fresh install. System follows macOS as it switches between light and dark; Dark and Light stay fixed.
- **Light theme** and **Dark theme** pick a theme for each appearance separately, so you can pair your own dark theme with a built-in light one.

Choose **Apply Appearance** to save. The new colors reach every window and pane at once, without restarting shells, changing what's on screen, or losing your focus or selection.

The built-in themes are **Trellis Dark** and **Trellis Light**, plus dark and light versions of ten editor-inspired families: Modern, One, Monokai, Solarized, Nord, Dracula, GitHub, Tokyo, Gruvbox and Rose Pine. Each is a complete Trellis adaptation of the app and terminal palette. Light versions have light terminals and dark versions have dark terminals.

!!! note "New in 1.2"
    **Trellis Light** now has a white terminal with black text. For dark panes under light chrome, use a light theme that sets a dark terminal background.

A theme colors the sidebar, tabs, split dividers, focus indicators, the terminal's background, text, cursor and selection, and its 16 ANSI colors. System dialogs and standard controls follow macOS's own appearance.

The font isn't part of a theme. Choose it with **Terminal font** on the same page.

## Background opacity

!!! note "New in 1.2"
    Background opacity and blur are new in 1.2.

**Settings → Appearance → Background opacity** (30–100 %, default 100 %) lets the desktop show through the window. Turn on **Blur behind background** (on by default) to frost what shows through.

- The terminal panes' background takes the opacity exactly as you set it.
- The sidebar, dock, tab bar, pane headers, side panels and status bar follow it but never go below 60 %, so their labels stay readable.
- Text, icons, the cursor, selections, cells with their own background color, sheets, popovers, the command palette and the find bar stay opaque.
- The window stays opaque while **Reduce Transparency** or **Increase Contrast** is on in macOS's Accessibility settings.

Switching or previewing a theme keeps your opacity.

## Manage themes

**Settings → Themes** lists every theme under **Installed theme**. For the selected theme you can:

- **Use Theme**: make it the theme for its appearance (light or dark) and switch the app to that appearance.
- **Export…**: save the theme as you wrote it.
- **Export Resolved…**: save it with every color filled in, including the ones it inherits, for an exact copy. Built-in fallback colors can change between releases, so a theme that leaves colors out can look slightly different later.
- **Delete…**: remove one of your own themes. If it was selected, that appearance goes back to its built-in theme and Trellis tells you.

**Open Themes Folder** shows your theme files in Finder so you can edit them in any editor. **Reload Themes** picks up your edits without a restart. Files that are valid are updated; for an invalid file Trellis keeps the last valid colors and shows what's wrong.

## Create a theme

1. Download [`example-dark.theme.json`](../themes/example-dark.theme.json) or [`example-light.theme.json`](../themes/example-light.theme.json), complete palettes to start from.
2. Change `id`, `name` and whichever colors you like. Only `version`, `id`, `name` and `appearance` are required; every color you leave out comes from the built-in theme for that appearance.
3. Open **Settings → Themes** and choose **Preview JSON…** to load your file. The preview shows normal text, muted labels, selection, cursor text and status examples, with contrast advice.
4. Choose **Preview in Workspace** to try it on your real windows. **Cancel Preview** puts your saved appearance back. Leaving Themes or closing Settings cancels the preview too.
5. Choose **Save & Use Theme** to install it and switch to it.

The smallest useful theme looks like this ([`example-minimal.theme.json`](../themes/example-minimal.theme.json)):

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

Loading a file to preview it doesn't install it or touch your running sessions. Previewing, installing and reloading themes never send anything to your terminal sessions.

### Install a theme someone gave you

Use the same steps: **Preview JSON…**, then **Save & Use Theme**. Trellis copies the file into its themes folder, so you can delete the original afterwards.

If you already have a theme with the same `id`, Trellis offers **Replace Theme**, which overwrites the installed one. Replacing is all or nothing: if it fails, the previous version stays.

Themes can also be installed and selected through the [automation API](../api/methods.md#themes-and-appearance) by a client with theme permission.

## Theme file format

A theme is a UTF-8 JSON file of at most 64 KiB. Here is a complete one, [`example-dark.theme.json`](../themes/example-dark.theme.json):

```json
{
  "version": 1,
  "id": "my-dark",
  "name": "My Dark",
  "appearance": "dark",
  "terminal": {
    "background": "#141820",
    "foreground": "#E8EEF4",
    "cursor": "#B9DCFF",
    "cursorText": "#141820",
    "selectionBackground": "#3F6AA1",
    "selectionForeground": "#FFFFFF",
    "ansi": [
      "#1B202A", "#EF8585", "#8DDAA4", "#F2CC7A",
      "#8BB8F0", "#C6A0E8", "#7FD5DD", "#CFD7E2",
      "#7C899C", "#FFA4A4", "#B3EFBC", "#FFE3A3",
      "#B9DCFF", "#E4BDFF", "#A7F2F5", "#FFFFFF"
    ]
  },
  "ui": {
    "background": "#141820",
    "surface": "#202735",
    "sidebarBackground": "#10141B",
    "foreground": "#E8EEF4",
    "mutedForeground": "#B0BAC9",
    "accent": "#8BC7FF",
    "border": "#66758B",
    "activeTabBackground": "#354C6A",
    "activeTabForeground": "#FFFFFF",
    "focusRing": "#8BC7FF",
    "success": "#8DDAA4",
    "warning": "#F2CC7A",
    "error": "#FFA4A4"
  }
}
```

### Top-level fields

| Key | Required | Value |
| --- | --- | --- |
| `version` | Yes | Always `1`. |
| `id` | Yes | A stable lowercase identifier, up to 64 characters. It names the installed file. IDs starting with `trellis-` are reserved for built-in themes. |
| `name` | Yes | The label shown in Settings, up to 100 characters. |
| `appearance` | Yes | `dark` or `light`. It decides which slot (**Dark theme** or **Light theme**) the theme can be chosen for, and which built-in theme fills in missing colors. |
| `terminal` | No | Terminal colors, below. |
| `ui` | No | App colors, below. |

### `terminal` fields

| Key | Colors |
| --- | --- |
| `background`, `foreground` | The terminal's default background and text. |
| `cursor`, `cursorText` | The cursor, and the text under it. |
| `selectionBackground`, `selectionForeground` | Selected text. |
| `ansi` | The 16 ANSI colors, in terminal order: black, red, green, yellow, blue, magenta, cyan, white, then the bright versions of each. If present, it must hold exactly 16 colors and replaces the whole palette. |

### `ui` fields

| Key | Colors |
| --- | --- |
| `background` | The window background. |
| `surface` | Panels and pane headers. |
| `sidebarBackground` | The sidebar. |
| `foreground`, `mutedForeground` | Normal and secondary text. |
| `accent` | The accent color for highlights. |
| `border` | Subtle pane and chrome separators. |
| `activeTabBackground`, `activeTabForeground` | The selected tab. |
| `focusRing` | Focus indicators. |
| `success`, `warning`, `error` | Status colors. |

### Rules

- Colors are opaque `#RRGGBB`, in upper or lower case. Transparency and color expressions aren't supported.
- Unknown keys, duplicate keys, a wrong `version`, an invalid color, a wrong type, an `ansi` list that isn't 16 long, a file over 64 KiB and malformed JSON are all errors. The message names the field and the reason, and nothing is installed or changed; your current theme keeps working.
- A theme can't include other files, inherit from another theme, download anything, or set fonts, images or scripts.

### How missing colors are filled in

Trellis starts from the built-in theme that matches `appearance` (**Trellis Dark** or **Trellis Light**) and applies your colors on top.

Light themes have one exception for terminal colors: a light theme that sets a dark `terminal.background`, or sets terminal colors without a background (unless its `foreground` is dark), takes its other terminal colors from **Trellis Dark**, so it stays readable. Set a light `terminal.background` to get a light terminal.

## Colors programs choose

A theme sets the terminal's default colors and ANSI colors 0–15. Colors that programs send in 24-bit ("true color") are never changed, on any theme.

On a dark terminal, the 256-color palette (colors 16–255) keeps its standard xterm values.

!!! note "New in 1.2"
    On light terminals, 256-color output now follows the theme, so prompts such as Powerlevel10k no longer draw near-black blocks.

On a light terminal (one whose background is lighter than its text), the standard values assume a dark background and would look wrong, so Trellis derives colors 16–255 from your theme instead: the color cube runs from your `background` through ANSI colors 1–6 to your `foreground`, and the grey ramp from `background` to `foreground`. Text drawn with these colors is lifted to a contrast of at least 4.5:1.

ANSI colors 0–15 and the default colors keep your exact values on a light terminal unless a pair would be nearly invisible (below 1.5:1); then the text is lifted to 4.5:1 too. For example, black text (`\e[30m`) on the default background stays readable.

Some things are never lifted: text deliberately drawn in the same color as its background, Powerline separators and block characters (whose color belongs to the neighboring segment), and pairs with a true-color background. Dim text is dimmed after the lift, so it can fall below 4.5:1.

If a program changes the palette while it runs, that change belongs to its session; applying a theme resets it.

## Contrast warnings

The preview checks your theme's contrast and warns about pairs that are hard to read, naming the fields involved:

- Normal text and essential labels against their backgrounds: at least **4.5:1**.
- Focus indicators and essential boundaries against neighboring colors: at least **3:1**.
- `ui.border` separators: a gentle **1.2:1** guideline so they stay visible. Use `ui.focusRing` for focus, and keep separators from competing with text or selection.
- Selected text and cursor text are checked on their own.

Warnings are advice: you can still save the theme. The built-in themes all meet these targets. Status is always shown with a label or an icon as well as a color.

## Where themes are kept

Your themes are saved as `<id>.theme.json` in the `Themes` folder of Trellis's data folder, `~/Library/Application Support/com.bearstouch.trellis/Themes/`. **Open Themes Folder** takes you there.

Your appearance mode and the two selected themes are saved. If a selected theme's file is missing at launch, Trellis falls back to the built-in theme for that appearance.

Themes apply to the whole app. You can't set a different theme per space, tab or host.
