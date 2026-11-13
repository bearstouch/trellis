# Editor tabs

An **editor tab** lets you change a file of your project without leaving Trellis: fix the line a compiler complained
about, adjust a config file, tweak a script. It opens in the current space next to your terminal tabs, with line numbers,
syntax highlighting in your theme's colors, find and <kbd>⌘</kbd><kbd>S</kbd>.

## Open a file

- **From Files:** double-click a file in the [Files](files.md) view, or select it and press <kbd>Return</kbd>.
  **Trellis Editor** is the default in **Open in**; if you chose another app there, right-click the file and choose
  **Open in Trellis Editor**.
- **From the terminal:** hold <kbd>⌘</kbd> and click a file path that a command printed, such as
  `Sources/App.swift:12:5` from a compiler. If the file is inside the pane's project or current folder, it opens in an
  editor tab with the cursor on that line and column. Right-click the path for **Open in Trellis Editor**, or **Open**
  to use the file's default app instead.

The tab appears after the space's terminal tabs. Opening a file that is already open in the space switches to its tab.

Trellis edits UTF-8 text files up to 2 MB. A binary file, a larger file or one in another encoding opens in its default
app instead, and Trellis tells you why. Paths outside the project, and files in [SSH](ssh-hosts.md) and
[remote workspace](remote-workspaces.md) panes, open as described in [Links](terminal.md#links).

## Edit and save

| Do this | To |
| --- | --- |
| <kbd>⌘</kbd><kbd>S</kbd> or **Save** | Save the file |
| <kbd>⌘</kbd><kbd>L</kbd>, or click **Ln, Col** in the header | Go to a line |
| <kbd>⌘</kbd><kbd>F</kbd>, <kbd>⌘</kbd><kbd>G</kbd>, <kbd>⇧</kbd><kbd>⌘</kbd><kbd>G</kbd> | Find, next, previous |
| <kbd>⇧</kbd><kbd>⌘</kbd><kbd>V</kbd> | Markdown: switch between Preview and Edit |
| <kbd>⌘</kbd><kbd>W</kbd> | Close the editor tab |
| **Open With** in the header | Open the file in another editor |

Trellis keeps the file the way it was: its line endings (LF or CRLF), a byte-order mark, the final newline and its
permissions. Typing never turns quotes into smart quotes or fixes spelling.

A dot on the tab means it has unsaved changes. Closing the tab, closing its space or quitting Trellis asks whether to
save them first.

## When the file changes elsewhere

When you come back to Trellis or switch to the tab, it checks the file. If you haven't changed it, the tab quietly shows
the new version. If you have, a banner says the file changed on disk: **Reload from Disk** takes the new version and
drops your changes, **Keep Mine** keeps yours, and the next save replaces the file. If the file was deleted, saving
creates it again.

## Preview Markdown

A Markdown file's tab has a **Preview** button in its header. Click it, or press <kbd>⇧</kbd><kbd>⌘</kbd><kbd>V</kbd>, to
see the file rendered in your theme's colors; **Edit** (or the same shortcut) takes you back to the source. Each tab
remembers its own choice while Trellis is open.

The preview shows your current text, unsaved changes included, and keeps up as you type in the source. While
previewing, <kbd>⌘</kbd><kbd>S</kbd> still saves, and going back to Edit puts you where you were, with your undo history
intact. Find takes you back to Edit to search the source.

It renders headings, paragraphs, bold, italic, strikethrough, inline code, links, bullet, numbered and task lists, quotes,
code blocks (colored like the editor when they name a language it knows), tables and horizontal rules. HTML in the
file is shown as text.

Links work by clicking:

- Web and email links open in your browser or mail app.
- A link to another file in the project, such as `docs/setup.md`, opens it in an editor tab.
- A link to a heading, such as `#install`, scrolls to it.
- Anything else does nothing.

Images are never loaded, from the web or from disk: each one shows as its description instead.

## Colors and languages

The editor uses your [theme](themes.md): the same background, text, selection and colors as your terminal, and the
terminal font. Switching themes, previewing one in Settings, or changing between Light and Dark updates open editor
tabs at once.

Highlighting covers Swift, Python, JavaScript and TypeScript, JSON, Go, Rust, C, C++ and Objective-C, Java and Kotlin,
Ruby, shell scripts, Markdown, YAML, TOML, HTML and XML, and CSS. The language comes from the file name, or from a `#!`
line for scripts without an extension. Other files are shown as plain text.

## Limits

- Editor tabs are temporary. They aren't saved with your workspace and don't come back after you quit Trellis.
- Files over 512 KB are shown without highlighting, so typing stays quick.
- <kbd>⌘</kbd><kbd>1</kbd>–<kbd>⌘</kbd><kbd>9</kbd> select only terminal tabs; next and previous tab move through
  editor tabs as well.
