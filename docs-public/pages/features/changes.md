# Changes

!!! note "New in 1.2 beta"
    The Changes view and the Review tab arrived in 1.2.0-beta.1.

The **Changes** view in the [right sidebar](sidebar.md) lists what has changed in the focused pane's git repository, as a tree with lines added and removed. Use it to find a changed file, read its diff in a **Review** tab, and stage or unstage it without leaving Trellis. Show it with the branch icon in the dock, second after Files, or press <kbd>⌥</kbd><kbd>⌘</kbd><kbd>G</kbd> (**View → Show Changes**).

The dock icon's badge shows how many files have changed in the focused pane's repository.

## Which repository it shows

The view shows the repository that contains the focused pane's folder, from its top level. The pane's folder is the one its shell last reported through [shell integration](shell-integration.md), or else the one it started in. When you `cd` into another repository, or focus a pane in one, the view follows. Outside a repository it says "No repository" and names the folder.

Changes works only for panes on this Mac. Its icon is dimmed for [SSH](ssh-hosts.md) panes and [remote workspace](remote-workspaces.md) panes, with the reason "Changes reads git only in panes on this Mac."

## Read the list

| Part | Shows |
| --- | --- |
| Branch row | The branch (or the detached commit) and how far it is ahead of and behind its upstream, such as ↑2 ↓0 |
| **Uncommitted** | Lines added and removed across every change, and the number of changed files |
| **Filter changed files** | Narrows the tree to files whose path contains what you type, ignoring case |
| Tree | Folders first, then files, by name. Each folder shows the lines added and removed inside it; each file shows its own, a status letter and, when staged, a staged mark |
| Footer | A reminder of the keys: <kbd>Return</kbd> to review, <kbd>⌥</kbd><kbd>Return</kbd> to open in your editor, <kbd>⇧</kbd><kbd>⌘</kbd><kbd>C</kbd> to copy the path |

A folder that only holds one other folder is shown merged with it, as in `docs/features`, to keep the tree short.

| Letter | Means |
| --- | --- |
| M | Modified |
| A | Added (staged as a new file, or added to the index and then changed) |
| D | Deleted (its name is struck through) |
| U | Untracked |
| C | Conflicted (a merge left it unresolved) |

**Uncommitted** compares your working tree and index with the last commit (`HEAD`), so a file counts once whether its change is staged or not. Untracked files are listed, and all their lines count as added. A renamed file shows as a deletion and an addition. A binary file shows "binary" instead of line counts. Before the first commit, everything counts as new.

When nothing has changed, the view says the working tree matches `HEAD`.

### Move around the tree

- Click a folder to fold or unfold it. The collapse button at the top folds every folder.
- <kbd>↑</kbd> and <kbd>↓</kbd> move the selection through the visible files.
- While you filter, matching files are shown with their folders open; clear the filter to get your folded tree back.
- Folded folders are remembered per repository until you quit; they're never saved.

### When it updates

The list is read again when you show the view, each time the pane comes back to a prompt, after you stage or unstage, and when you click the reload button. If git can't be read, the view says "Couldn't read git status" rather than showing an old list.

## Review a diff

Click a file, or select it and press <kbd>Return</kbd>, to open its diff in the space's **Review** tab, after your terminal tabs. A space has one Review tab: reviewing another file replaces what it shows.

The diff is unified: hunk headers, then each line with its old and new line numbers and a `+` or `−` mark on a tinted background. The header names the file, its status, its line counts and its place in the list ("12 of 17").

| Do this | To |
| --- | --- |
| <kbd>n</kbd> / <kbd>p</kbd> | Scroll to the next or previous change |
| <kbd>]</kbd> / <kbd>[</kbd> | Review the next or previous changed file |
| <kbd>Return</kbd>, or **Open in** | Open the file in the editor you chose in [Files](files.md) |
| The reload button | Read the diff again |
| **Stage** / **Unstage** | Stage or unstage the whole file |
| <kbd>Esc</kbd> | Go back to the terminal tabs |

Selecting a terminal tab or pressing <kbd>Esc</kbd> takes you back to your terminals, and the Review tab stays so you can return to it. Its close button removes it.

While the Review tab is shown, **Close Pane** and **Close Tab** (<kbd>⌘</kbd><kbd>W</kbd>, <kbd>⇧</kbd><kbd>⌘</kbd><kbd>W</kbd>) close the Review tab, never a terminal you can't see. Pane commands such as split, maximize, find, **Previous Prompt** and **Next Prompt** first bring your terminals back, then act on the focused pane.

The Review tab is never saved with your workspace, and the [automation API](../api/index.md) doesn't list it as a tab.

Some files can't show a diff:

- A binary file says "Binary file; no text diff".
- A diff over 2 MB or 20,000 lines is too large to show; open the file in your editor to see it.
- A file that's no longer changed says so.

## Stage and unstage

Hover or select a file to show its **Stage** or **Unstage** button; the same button is in the Review tab and in the file's context menu.

- **Stage** runs `git add` for that one file, including a deletion. A partly staged file offers **Stage**, which stages all of it.
- **Unstage** puts the file's index entry back to `HEAD` and leaves your working copy as it is.

Staging a conflicted file (C) first asks "Mark <file> as resolved?", because `git add` marks it resolved with the file as it is, conflict markers included. **Cancel** leaves the conflict alone.

If staging fails, the view says which file couldn't be staged or unstaged, and nothing else changes.

That's all the view writes to your repository: there's no commit, discard or staging of single hunks. Use the terminal for those.

## Open, reveal and copy

Right-click a file for **Review Changes**, **Stage** or **Unstage**, **Open in** your chosen editor, **Reveal in Finder**, **Copy Path** and **Copy Relative Path**. <kbd>⌥</kbd><kbd>Return</kbd> opens the selected file in your editor, and <kbd>⇧</kbd><kbd>⌘</kbd><kbd>C</kbd> copies its path. A deleted file has nothing to open, and Trellis says so.

## Safety and limits

- Reading the list never runs a program your repository configures. Trellis runs git directly, not through a shell, with hooks, the fsmonitor, filter drivers, external diff and text conversion turned off. Paths are passed literally.
- Staging does run the repository's filter drivers, just as `git add` in a shell would, so Git LFS and similar setups store the right content.
- Trellis doesn't look inside a submodule's files, so a submodule is listed only when its commit changed.
- The view reads git only, never the pane's output. Git's output is never logged or saved.
- At most 2,000 files are listed; the **Uncommitted** row then says "first 2,000 files".
- An untracked file over 1 MB isn't read to count its lines.
- Each git command has five seconds to finish.
