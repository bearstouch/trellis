# Terminal sessions, copy, paste and search

Every pane in Trellis runs a real terminal session: your login shell by default, with full job control, colors, mouse support and Unicode. Programs such as `vim`, `less` and `top` work as they do in any terminal. This page covers what you see in a pane and how to work with its text.

## Sessions

### Shell and starting folder

New local sessions use the shell and working directory set in **Settings → Sessions**:

- **Shell** lists the shells on your Mac; choose **Other…** to type a path.
- **Working directory** is the folder new sessions start in. Use an absolute path. A folder that doesn't exist or can't be opened is refused before anything starts.

Click **Save** to apply them. They affect new sessions, not ones already running.

### Session status

When a pane's session isn't running, its header says so in words:

| Status | Meaning |
| --- | --- |
| **Stopped** | Not started yet, for example after a relaunch. Click **Start Session** in the pane. |
| **Starting** | The session is being launched. |
| **Closing** | Trellis is ending the session. |
| **Exited (N)** | The program ended with exit code N. Its last output stays visible. |
| **Failed to start** | The program couldn't be launched. |

### Restart a session

When a session has exited or failed, click **Restart** in the pane header to start a fresh session in the same pane. For a pane connected to a [saved SSH host](ssh-hosts.md), the button reads **Reconnect** and opens a new connection; Trellis never reconnects on its own.

### Option as Meta

**Settings → Keyboard → Use Option as Meta key** (off by default) makes the Option key send Meta, as many shell and editor key bindings expect. Configurable shortcuts always include <kbd>⌘</kbd>, so terminal keys such as <kbd>⌃</kbd><kbd>C</kbd> always reach the program.

## Fonts and text

Terminal text settings are in **Settings → Appearance**. Click **Apply Appearance** to save them; changes apply to every pane without restarting sessions.

- **Terminal font**: JetBrains Mono is the default and is bundled with Trellis. Roboto Mono, Cascadia Mono NF (with Nerd Font prompt glyphs), IBM Plex Mono, Iosevka Fixed and Atkinson Hyperlegible Mono are bundled too, and any monospaced font installed on your Mac is listed. If a saved font is missing, Trellis falls back to Menlo or the system monospaced font and tells you.
- **Font size**: 8 to 48 points. **View → Zoom In** (<kbd>⌘</kbd><kbd>+</kbd>), **Zoom Out** (<kbd>⌘</kbd><kbd>-</kbd>) and **Actual Size** (<kbd>⌘</kbd><kbd>0</kbd>, 13 points) change it quickly.
- **Cursor**: Block, Underline or Bar, and **Blink cursor**.
- **Ligatures** (on by default): joins sequences such as `->`, `!=` and `<=>` in fonts that include ligatures, like JetBrains Mono. Turn it off to see the separate characters. Text after a ligature keeps its columns.
- **Bold as bright colors**: draws bold text in the basic ANSI colors with their bright versions.
- **Use bold fonts** and **Use italic fonts**: turn them off to draw that text with the regular face.
- **Allow blinking text**: turn it off to draw blinking text steadily. Blinking also stops while Reduce Motion is on or Trellis isn't in front.

All four text-style options are on by default. Trellis draws bold, dim, italic, the underline styles (single, double, curly, dotted and dashed, the last two drawn solid), underline colors, strikethrough, overline, inverse and hidden text. Emoji, flags, skin tones, combining accents and CJK characters each take a fixed number of cells, so columns stay lined up.

### GPU rendering

**Settings → Sessions → GPU rendering (Metal)** (off by default) draws terminals on the GPU. Text looks the same either way. Turning it on or off switches open panes at once, without resetting sessions. If Metal fails, the pane falls back to CPU drawing without losing its content. Each GPU pane uses about 5 MiB more memory.

## Select and copy

- Drag to select text. Double-click selects a word, and triple-click a line.
- Double-click also recognizes whole items: a URL (without trailing punctuation), an email address, a file path with an optional `:line:column` suffix, a UUID, an IP address with an optional port, a git hash, or a quoted string when you click one of its quotes. Dragging after the double-click extends the selection by whole items.
- **Edit → Copy** (<kbd>⌘</kbd><kbd>C</kbd>) copies the selection as plain text, without terminal escape sequences. With nothing selected, <kbd>⌘</kbd><kbd>C</kbd> does nothing: it never interrupts the program. Use <kbd>⌃</kbd><kbd>C</kbd> to interrupt.
- **Edit → Copy All Retained Text** copies everything the pane still holds in its scrollback. The menu item says when older lines have been dropped, and in a full-screen program it copies only the current screen.
- **Edit → Select All** (<kbd>⌘</kbd><kbd>A</kbd>) selects the pane's text.

Right-click a pane for **Copy**, **Copy All Retained Text**, **Select All**, **Paste**, **Paste Escaped Path**, **Find…** and **Clear**.

While a program captures the mouse (for example `vim` with mouse support on), clicks and double-clicks go to the program.

## Paste

**Edit → Paste** (<kbd>⌘</kbd><kbd>V</kbd>) pastes into the focused pane only. When the shell supports bracketed paste, Trellis uses it, and it removes any bracketed-paste markers hidden in the clipboard text, so a paste can't end early and run the rest as typed commands. Trellis never adds a newline that wasn't in the clipboard.

### Paste review

Pasting several lines, or text that contains control characters, opens a **Review Paste** sheet before anything is sent. It shows:

- the target pane,
- the number of lines and bytes, and "No newline added",
- a preview with invisible control characters shown in ⟨brackets⟩.

Click **Paste** to send it or **Cancel** to send nothing. A long preview is cut off after 8,192 characters, and the sheet tells you if the hidden part contains escape characters. Switching to another pane discards the review.

### Paste a file path

**Edit → Paste Escaped Path** pastes the path of a file you copied in Finder, escaped for your shell. If Trellis can't escape paths for your shell, it opens a **Review Escaped Path** sheet with a quoted version for you to check, and a **Paste Quoted Text** button. Ordinary **Paste** always pastes plain text.

### Drop files on a pane

!!! note "New in 1.2"
    Dropping files from Finder onto a pane inserts their paths.

Drag files from Finder onto a pane's terminal area to type their paths at the cursor, separated by spaces and in the order you dragged them, escaped the same way as **Paste Escaped Path**. Nothing is run, opened or uploaded, and no newline is added. The pane under the pointer takes focus first, and Trellis comes to the front.

A pane doesn't accept a drop while its session isn't running, while you're renaming a tab or using the [command palette](command-palette.md), or while a sheet is open. Only files are accepted, not text or web links.

## Clear a pane

**Edit → Clear** (<kbd>⌘</kbd><kbd>K</kbd>, also in the pane's context menu) works like Terminal's <kbd>⌘</kbd><kbd>K</kbd>: it drops the scrollback and everything above the cursor's line, and moves that line to the top, so your prompt and anything you've typed stay. Nothing is sent to the program. In a full-screen program such as `vim` or `less`, the program's screen stays. Other panes are untouched.

## Scrollback and search

Each pane keeps the last 10,000 lines of output by default, up to 16 MiB of text. Change the number in **Settings → Sessions → Scrollback lines** (0 to 50,000) and click **Save**; lowering it drops older output. The oldest lines go first when the limit is reached.

To search a pane:

1. Choose **Edit → Find in Pane…** (<kbd>⌘</kbd><kbd>F</kbd>) or **Find…** in the pane's context menu.
2. Type in the **Find in this pane** field and press <kbd>Return</kbd>.
3. Use **Edit → Find Next** (<kbd>⌘</kbd><kbd>G</kbd>) and **Find Previous** (<kbd>⇧</kbd><kbd>⌘</kbd><kbd>G</kbd>) to move between matches.
4. Press <kbd>Esc</kbd> to close the find bar.

The find bar says when earlier output has been dropped and can't be searched. A full-screen program's screen (such as `vim`, `less` or `top`) is searched on its own, apart from the shell's history.

The scroll bar stays hidden until you need it. Move the pointer to the right edge of a pane with scrollback, or scroll, to show it; it fades out a second after you stop.

## Links

Hold <kbd>⌘</kbd> and hover over a link to underline it, then <kbd>⌘</kbd>-click to open it. Links come from programs that mark them (such as `ls --hyperlink`, compilers and `rg`) or are detected in plain text.

- **Web and mail links** (`http`, `https`, `mailto`) open in your default browser or mail app.
- **File paths** (absolute, `~/` or relative) open in the file's default app. A `:line:column` suffix is ignored when opening.
- **Files that could run code** (executables, apps and other packages, scripts such as `.command`, `.sh` or `.py`, installers, disk images, aliases and URL shortcut files) are never opened: they're shown in Finder instead.

Right-click a link for **Open Link** and **Copy Link**, or a file path for **Open**, **Show in Finder** and **Copy Path**. You can also select a file name or link, including a bare name like `README.md`, and right-click inside the selection to get the same actions.

### When a link doesn't open

- Output alone never opens anything, and one click opens at most one link.
- Missing files, devices and sockets do nothing.
- Relative paths open only when [shell integration](shell-integration.md) has told Trellis the shell's current folder.
- Panes connected to a saved SSH host, or started as `ssh` or `mosh`, never open file paths, since they name files on another machine. Paths under the `/net` and `/Network` network folders, and `file://` links that name another host, are refused too.
- A marked link whose target has no scheme is refused, because its visible text can differ from where it points.
- Custom URL schemes never open.

Trellis can't tell when you typed `ssh` inside a local shell, so a path printed by a remote host opens if the same path happens to exist on your Mac. A `:line:column` suffix isn't passed on to your editor.

## Inline images

Programs can show images right in the terminal using iTerm2's inline image protocol. `imgcat`, `yazi`, `timg`, `chafa -f iterm` and `viu` all work. An image sits in the cells it covers, scrolls with the text and stays in the scrollback.

- PNG, JPEG, GIF, BMP, TIFF, WebP and HEIC images are shown. Animated GIFs show their first frame. PDF, EPS and SVG are not shown.
- An image wider than the pane, or very tall, is shrunk to fit and keeps its shape.
- Large images sent in parts, as newer `imgcat` does, work too.
- Local sessions set `LC_TERMINAL=iTerm2` so tools know the protocol is available. Over SSH, tools only see it if the server accepts `LC_*` variables.

Limits: an image can be at most 10,000 pixels on a side and 40 megapixels, and a single image can be at most about 6 MiB. Larger images, file downloads through the protocol, and damaged transfers show nothing, and the terminal keeps working. A very large image can pause drawing briefly. VoiceOver doesn't announce images.

## Why Trellis treats terminal output as untrusted

Anything can print to your terminal: a build script, a file you `cat`, a web page you `curl`, a remote server. Trellis assumes that output could be hostile, so it can't take actions on your behalf:

- Programs can't read or write your clipboard through the terminal.
- Links only open when you <kbd>⌘</kbd>-click them or choose an action from the context menu, and only web, mail and local file links open. Files that could run code are only shown in Finder.
- Copied text never carries hidden escape sequences.
- Inline images never download or open files, and oversized data is dropped.
- Nothing printed in a terminal can change Trellis's permissions, including text written to look like instructions to a coding agent.
