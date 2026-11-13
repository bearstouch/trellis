# Languages

Trellis is available in English, Portuguese (Portugal), French and Spanish. It follows your Mac's language, and you can pick another one for Trellis alone.

## Choose a language

1. Open **Trellis → Settings…** and select **Appearance**.
2. Under **Language**, choose **System**, **English**, **Português**, **Français** or **Español**.
3. Press **Apply Appearance**.

The menus, the windows and Settings change right away; you don't need to relaunch.

**System** uses the first language in **System Settings → General → Language & Region** that Trellis has. Regional variants count: with Brazilian Portuguese you get Portuguese, and with Canadian French you get French. If none of your languages is available, Trellis is in English.

Each language is listed under its own name, so you can find yours even when the app is showing one you don't read.

## What is translated

Menus, Settings, the sidebars, dialogs, tooltips, notifications, the welcome tour and what VoiceOver reads.

These stay as they are:

- everything your shells and programs print;
- names you chose, or that come from your files: tabs, spaces, projects, hosts, tasks and themes;
- the `trellis` command and the [automation API](../api/index.md), so your scripts behave the same in every language;
- diagnostics exports.

## Try a language for one launch

Start Trellis with `--language` followed by `en`, `pt-PT`, `fr` or `es` to use that language once without changing your setting:

```sh
open -a Trellis --args --language fr
```
