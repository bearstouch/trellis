# Changes

The **Changes** view of the [right sidebar](sidebar.md) lists what changed in the focused pane's git repository, as a
tree with lines added and removed, so you can find a file, read its diff in a **Review** tab and stage or unstage it
without leaving Trellis. Show it with the branch icon in the dock, second after Files, or **⌥⌘G**.

All requirements here are P1.

## What it shows

The view reads the repository that contains the focused pane's folder (the folder its shell last reported, else the one
it started in), from its top level. A `cd` into another repository, or focusing a pane in one, moves the view.

| Part | Shows |
| --- | --- |
| Branch row | The branch (or the detached commit) and how far it is ahead of and behind its upstream (↑2 ↓0) |
| Totals row | **Uncommitted**: lines added and removed across every change, and the number of changed files |
| Filter field | Narrows the tree to files whose path contains the text, ignoring case |
| Tree | Folders, then files, by name. A folder with one folder and no files inside is merged with it (`docs/features`). Each folder shows the lines added and removed under it; each file shows its own, a status letter and, when staged, a staged mark |
| Footer | The keys: ↩ Review, ⌥↩ Open in editor, ⇧⌘C Copy Path |

**Uncommitted** compares the working tree and the index with `HEAD`, so a file counts once whether its change is staged or
not, and untracked files are listed (their lines count as added). Renames show as a deletion and an addition.

| Letter | Means |
| --- | --- |
| M | Modified |
| A | Added (staged as new, or added to the index with changes) |
| D | Deleted (its name is struck through) |
| U | Untracked |
| C | Conflicted (a merge left it unresolved) |

A binary file shows "binary" in place of line counts. The status letter, the staged mark and the counts are text, never
color alone.

The view reads git only, never a pane's output. It runs git with a fixed argument list, never through a shell, with
hooks, the fsmonitor, filter drivers, external diff and text conversion switched off, as the
[pane git status](project-library.md) does (FR-PL09), so opening the view in a folder never runs a program the
repository configures. Paths are passed literally (no pathspec magic). Like that status, it doesn't look inside a
submodule's work tree (that would run git under the submodule's own settings), so a submodule is listed only when
its commit changed.

Changes works only for panes on this Mac. Its icon is dimmed for SSH panes and [remote workspace](remote-workspaces.md)
panes with the reason "Changes reads git only in panes on this Mac."

## Reviewing a diff

Clicking a file (or Return) opens its diff in the space's **Review** tab, after the terminal tabs. A space has at most
one Review tab: reviewing another file replaces its content. Selecting a terminal tab, Esc, or the tab's close button
goes back to the terminals; the Review tab stays until closed, so you can come back to it. While it is shown, **Close Pane** and **Close Tab** (⌘W, ⇧⌘W) close the Review tab, never a terminal you can't see, and the pane actions (Split, Maximize, Focus and Move Divider, Find, Previous/Next Prompt, Clear) show the terminals first and then act on the focused pane. It is never saved with the
workspace and doesn't count as a tab for the automation API.

The diff is unified: hunk headers, then each line with its old and new line numbers and a `+` or `−` mark, on a tinted
background. The header names the file, its status, its line counts and its place in the list ("12 of 17").

| Do this | To |
| --- | --- |
| `n` / `p` | Scroll to the next or previous change |
| `]` / `[` | Review the next or previous changed file |
| Return / **Open in** | Open the file in the editor chosen in [Files](files.md) |
| **Reload** | Read the list and the diff again |
| **Stage** / **Unstage** | Stage or unstage the whole file |
| Esc | Back to the terminal tabs |

A binary file says "Binary file; no text diff". A diff over 2 MB or 20,000 lines says it's too large, and offers to open
the file instead. A file that is no longer changed says so.

## Staging

**Stage** on a row (shown on hover and selection) or in the Review tab runs `git add` for that one file, including a
deletion; **Unstage** puts the index back to `HEAD` for it (`git restore --staged`, or `git rm --cached` before the first commit).
A partly staged file offers **Stage**. Staging a conflicted file (C) first asks whether to mark it resolved, since `git add` does that with the file as it is, conflict markers included; Cancel leaves the conflict alone. Nothing else changes the repository: there is no commit, discard, or hunk staging.
Staging runs the repository's own filter drivers, as `git add` in a shell would, since that is what makes Git LFS and
similar setups store the right content. When it fails, the view says which file couldn't be staged or unstaged, and the previous state stays.

## Requirements

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| FR-GC01 | Show Changes in the dock, for panes on this Mac. | The dock's second icon is Changes (a git branch), with Toggle Changes (⌥⌘G, rebindable, starting unbound when the chord is already taken) in the View menu, Settings → Keyboard and the command palette. For SSH and remote workspace panes the icon is dimmed with the reason "Changes reads git only in panes on this Mac." and the view hides until a local pane is focused (FR-SB04). The icon's badge counts the focused pane's changed files from its git status (FR-PL09). Showing and hiding it never changes the saved workspace. |
| FR-GC02 | List the repository's uncommitted changes as a tree. | In a repository with modified, added, deleted, untracked and conflicted files, each appears once under its folder with the right letter, its lines added and removed (vs `HEAD`, untracked as added, "binary" for binary files) and its staged state (none, partly, staged). Folders sum their files; a single-folder chain is merged into one row; folders sort before files by name. Totals and the file count match the rows. Before the first commit, everything compares with the empty tree. Outside a repository it says "No repository" and names the folder. At most 2,000 files are listed, and the totals row then says "first 2,000 files". |
| FR-GC03 | Read git safely and off the main thread. | Git runs with a fixed argument list, without a shell, off the main thread, with hooks, fsmonitor, filter drivers, external diff and text conversion off, literal pathspecs and submodule work trees not looked inside, and each git run has a five-second limit. An untracked file over 1 MB isn't read to count its lines. A newer refresh supersedes an older one. The view refreshes when shown, when the pane shows a prompt, on **Reload**, and after staging; a failed read shows "Couldn't read git status" and keeps nothing stale. Output is never logged or saved. |
| FR-GC04 | Filter and fold the tree. | Typing in the filter keeps only files whose path contains the text, with their folders open; clearing it restores the folded state. Clicking a folder (or VoiceOver's default action) folds or unfolds it; **Collapse All** folds every folder. Folded folders are kept per repository for the session, never saved. ↑ and ↓ move the selection through visible files. |
| FR-GC05 | Review a file's diff in a Review tab. | Return or a click on a file opens one Review tab per space, after the terminal tabs and selected, showing the unified diff with old and new line numbers, `+`/`−` marks, hunk headers, and the header with the file, status, counts and "N of M". Reviewing another file replaces the tab's content. Selecting a terminal tab or Esc shows the terminals and keeps the Review tab; its close button removes it, and while it is shown Close Pane and Close Tab close it rather than a terminal out of sight, and the other pane actions (split, maximize, focus, resize, find, prompts, clear) show the terminals before acting. `n`/`p` move between changes, `]`/`[` between files. Binary, too large (over 2 MB or 20,000 lines) and no-longer-changed files say so. The tab is never persisted and isn't in the automation API's tab list. |
| FR-GC06 | Stage and unstage one file. | **Stage** on an unstaged or partly staged file stages all of it (a deleted file's deletion too); **Unstage** on a staged file restores its index entry to `HEAD` (or removes it before the first commit), leaving the working tree as it was. Staging a conflicted file asks first ("Mark <file> as resolved?"); Cancel runs nothing. The list refreshes afterwards. A failure says "Couldn't stage <file>; git reported an error.", announced to VoiceOver, and changes nothing else. No other action writes to the repository. |
| FR-GC07 | Open, copy and keep the editor choice. | **Open in** (and ⌥Return) opens the file in the editor chosen in Files (FR-FB05), with the same reveal rules; a deleted file opens nothing and says so. Copy Path and Copy Relative Path work as in Files (FR-FB06). |
| FR-GC08 | Make the view and the diff accessible. | Every row is one element named after its file or folder, with a value giving its status in words, staged state, lines added and removed, and "expanded/collapsed" for folders; its default action reviews the file or folds the folder, with named **Stage**/**Unstage** and **Copy Path** actions. Each diff line reads as "Added line 12: …", "Removed line 9: …" or "Line 14: …". Status is in words and symbols, never color alone. |

## Verification

| Area | How it's checked |
| --- | --- |
| Parsing and the tree (FR-GC02, FR-GC04, FR-GC05) | `GitChangesTests`: porcelain v2 entries and staged states, numstat with binary files, unified diff line numbers, hunks, "No newline" notes and limits, folder sums, merged folder chains, ordering, filtering and folding. |
| Git on a real repository (FR-GC02, FR-GC03, FR-GC06) | `ChangesSidebarTests`: a temporary repository with every kind of change, before and after the first commit; a path starting with `:`; a filter driver that would write a marker file never running while reading, in the repository or in a dirty submodule; staging and unstaging a modified, a new and a deleted file; a failed stage keeping the previous state. |
| Dock, availability, Review tab (FR-GC01, FR-GC05, FR-GC07) | `ChangesSidebarTests`: the dock order and shortcut, dimming for a remote workspace pane, opening, replacing and closing the Review tab, a terminal tab (selected or new) hiding it, a deleted space dropping it, a closed Review tab not coming back on refresh, a late staging refresh leaving another pane's view alone, next and previous file, the snapshot unchanged, opening a file in the chosen editor. |
| Shortcut (FR-GC01) | `KeyboardShortcutTests`: ⌥⌘G default, View menu, yielding to a saved chord. |
| The view in the app, keyboard, VoiceOver (FR-GC01–FR-GC08) | Manual: **pending** (the native view's layout in each bundled theme, mouse and keyboard use of the tree and the Review tab, staging in a real repository with Git LFS, VoiceOver walk of the tree and diff). |
