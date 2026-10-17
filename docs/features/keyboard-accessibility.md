# Keyboard, settings and accessibility

## Requirements

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| FR-U01 | Discoverable, configurable keyboard shortcuts with conflict warnings. | Menus show the shortcuts. A conflict can't silently disable a critical command. |
| FR-U02 | Readable terminal settings. | Roboto Mono, bundled with the app, is the default terminal font; JetBrains Mono, Cascadia Mono NF (with Nerd Font prompt glyphs), IBM Plex Mono, Iosevka Fixed and Atkinson Hyperlegible Mono are bundled alternatives. A missing or non-monospaced saved font falls back to Menlo or the system monospace font with a visible notice. Font family and size, the light/dark application theme, cursor style and scrollback limit all update predictably, and font zoom works. Terminal backgrounds stay dark by default under both application themes. |

## Default shortcuts

The defaults are defined in `ShortcutAction.defaultChord` (`Sources/TrellisCore/KeyboardShortcuts.swift`), and the menus are built from the current bindings in `AppDelegate.buildMenus`.

| Action | Default |
| --- | --- |
| New window / new tab | ⌘N / ⌘T |
| Close pane (closes a one-pane tab) / close tab | ⌘W / ⇧⌘W |
| Split Left/Right / Split Top/Bottom | ⌘D / ⇧⌘D |
| Focus pane left, right, up, down | ⌥⌘ + arrow |
| Move divider | ⌥⇧⌘ + arrow |
| Maximize / restore pane | ⇧⌘Return |
| Select tab 1–9 | ⌘1 – ⌘9 |
| Next / previous tab | ⇧⌘] / ⇧⌘[ |
| Next / previous window | ⌃⌘] / ⌃⌘[ |
| Find in pane / next / previous | ⌘F / ⌘G / ⇧⌘G |
| Previous / next prompt (shell integration) | ⌘↑ / ⌘↓ |
| Zoom in / out / actual size | ⌘+ (⌘= also works) / ⌘- / ⌘0 |
| Save workspace | ⌘S |
| Hide / show sidebar | ⌃⌘S |
| Rename tab, rename window, delete window, show hosts | Unbound by default |

These standard items can't be rebound: Settings (⌘,), Hide (⌘H), Quit (⌘Q), Undo and Redo, Cut, Copy, Paste, Select All, and Minimize (⌘M).

Rules for shortcuts:

- Every configurable shortcut must include ⌘, so terminal key combinations (Ctrl-C, Option sequences) always reach the shell.
- Conflicts are rejected before they're saved. Previous/Next Prompt (added with shell integration) yield to a shortcut you had already assigned to ⌘↑ or ⌘↓: that prompt action starts unbound instead of discarding your saved shortcuts.
- Settings are stored under the `keyboard.settings` user default.
- **Option as Meta** is a terminal setting and is off by default.
- Cmd-C and Cmd-V are always native copy and paste, and Ctrl-C always sends the terminal interrupt. Clipboard actions and terminal input must not fight over the responder chain.

## Settings

| Setting | Default | Range |
| --- | --- | --- |
| Chrome mode | Light | System, Dark, Light |
| Terminal font | Roboto Mono 13 (bundled) | Sizes 8–48, with zoom |
| Cursor | Block, not blinking | |
| Scrollback | 10,000 lines | 0–50,000, plus a 16 MiB cap |
| Ligatures | On | On, Off (FR-TX01); visible only with fonts that have them, such as JetBrains Mono |
| Bold as bright colors | On | On, Off (FR-TX03) |
| Use bold fonts / Use italic fonts | On / On | On, Off (FR-TX03) |
| Allow blinking text | On | On, Off (FR-TX03); always steady under Reduce Motion |
| Light / dark theme | `trellis-light` / `trellis-dark` | Any installed theme for that appearance |

Changes apply live, without restarting sessions. Settings saved by an earlier version, which have no text-rendering values, load with these defaults.

## Accessibility

- Every primary operation can be done from the keyboard, and the focus location stays visible in the terminal, tabs, sidebar and dialogs.
- VoiceOver can identify sidebar items, tabs, terminal panes, their status, and action labels. `WorkspaceAccessibility` provides them, for example "Window Project, 2 tabs, new output", "Tab Build, 1 of 2", and "Terminal Server, Exited (7), focused".
- Selection is shown by shape and weight as well as color: a semibold pane title and a tab underline. Terminal panes have no surrounding focus border. Stopped, exited and failed panes show a text status. **Color is never the only signal.**
- Trellis honors the system appearance, increased contrast, reduced motion and native text input.
- While a tab name is being edited, terminal input is suspended, so keystrokes can't leak into a shell.
- Trellis never requests Accessibility, event-tap or global-monitor permissions.

Rules for new views:

- Give every control a label and a role, and expose selected state.
- Never rely on color alone.
- Keep focus visible.

The full input matrix still has to be checked by hand: US and Portuguese layouts, dead keys, Option behavior, emoji, combining marks, wide CJK characters, and IME composition. That check and VoiceOver terminal reading are still **pending**. See [Status](../overview/status.md).
