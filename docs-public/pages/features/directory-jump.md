# Directory jump

If you work in a handful of repositories, you shouldn't have to `cd` to them again in every new tab. Trellis remembers the directories your shells have recently and frequently been in, and **Jump to Directory…** takes you back: press <kbd>⌘</kbd><kbd>J</kbd>, pick a directory, then press <kbd>Return</kbd>.

## Jump to a directory

Press <kbd>⌘</kbd><kbd>J</kbd>, or choose **View → Jump to Directory…**. The [command palette](command-palette.md) opens with its **Jump to Directory** list. Type part of a path to narrow it, then press one of these keys:

| Key | Directory on the focused pane's machine | Directory on another machine |
| --- | --- | --- |
| <kbd>Return</kbd> | Types `cd` into the focused pane if its shell is waiting at a prompt; otherwise opens a new tab there | Opens a new tab there |
| <kbd>⌘</kbd><kbd>Return</kbd> | Opens a new tab there | Opens a new tab there |
| <kbd>⌥</kbd><kbd>Return</kbd> | Opens a split beside the focused pane (not while a pane is maximized) | Opens a new tab there |

Trellis types `cd` only into a shell that is idle at its prompt, and clears anything half-typed there first. If a program such as `vim` is running in the pane, <kbd>Return</kbd> opens a new tab instead and sends nothing to the program.

A new tab for a directory goes where that directory lives:

- **A directory on this Mac** opens in the current space if it's a local one, otherwise in your first local space, otherwise in a new space.
- **A directory on a host** opens in that host's [remote workspace](remote-workspaces.md) space, or in a new remote workspace.

A path is only ever used on its own machine: a remote path is never opened on this Mac, and a local path is never typed into a remote shell. From an [SSH](ssh-hosts.md) pane, every directory opens in a new tab, because Trellis can't confirm which machine that pane's shell is on.

Remembered directories also show up in the palette's general search, mixed with actions, tabs and the rest.

The shortcut can be changed in **Settings → Keyboard**. If you had already given <kbd>⌘</kbd><kbd>J</kbd> to another command, your binding stays and **Jump to Directory…** starts without a shortcut.

### When a directory is gone

- A directory on this Mac that no longer exists shows an error, and Trellis forgets it.
- One that doesn't answer within 2 seconds, such as a folder on a share that's gone away, shows an error and opens nothing. Trellis keeps it in the list.
- A directory on a host that no longer exists opens the shell in your home folder on that host, and stays in the list.

## How the list fills up

A directory is remembered when a shell's prompt reports a directory different from the one it reported before. That needs [shell integration](shell-integration.md), which zsh, bash and fish get on this Mac and in remote workspaces. The first prompt of a new shell counts too.

These don't add a visit:

- Pressing Return at a prompt without changing directory.
- Reconnecting to a session that kept running.
- Plain SSH panes, and shells without shell integration.

The same path on this Mac and on a host are separate entries, each listed under a heading for its machine, with the current machine's first. Entries for a host follow it when you rename the host.

Trellis keeps at most 100 directories in total. When there are more, the one you visited longest ago is dropped.

With nothing remembered yet, the list explains how it fills up.

## How directories are ranked

Directories you visit often, and visited recently, come first. Each directory scores its number of visits times a weight for how long ago you were last there:

| Last visit | Weight |
| --- | --- |
| Under 1 hour | 4 |
| Under 1 day | 2 |
| Under 1 week | 0.5 |
| Older | 0.25 |

So a directory you visited 10 times last month (score 2.5) ranks below one you visited twice in the last hour (score 8). Ties go to the most recent visit. When two folders match what you type equally well, the higher-ranked one is listed first.

## Directories that are never remembered

Some directories are skipped before anything is stored. Matching ignores case and works on whole path segments, so `/proc/1` is skipped but `/procfoo` isn't.

| Why | Paths |
| --- | --- |
| Network | `/net`, `/Network`, `/afs` |
| Linux system or sensitive | `/proc`, `/sys`, `/dev`, `/run`, `/boot`, `/tmp`, `/var/tmp`, `/var/run`, `/var/lock`, `/lost+found`, `/snap`, `/etc`, `/root` |
| macOS system | `/private/tmp`, `/private/var`, `/private/etc`, `/var/folders`, `/System` |
| Credentials and trash, anywhere in the path | `.ssh`, `.gnupg`, `.aws`, `.kube`, `.password-store`, `.Trash` |
| Not worth a jump | `/`, and your home folder itself (`/Users/<name>`, `/home/<name>`) |
| Malformed | Not absolute, over 1024 bytes, or containing control or invisible characters |

On this Mac, a directory on any mount that isn't local is skipped too. That covers shares under `/Volumes` and network mounts anywhere else. Trellis checks this without touching the share, so a share that has stopped responding can't slow your shell down.

Two cases slip through:

- On a remote host, only the path rules above apply. Trellis can't see the host's mounts, so a network mount at an ordinary path there is remembered.
- The rules look at the path your shell reports. A symbolic link at an ordinary path that leads to a share or a skipped folder is remembered, because following it could hang on that share.

## Turn it off or clear it

**Settings → Sessions → Remember directories** is on by default. Turn it off to stop recording new visits; the directories already remembered stay and still work.

**Settings → Sessions → Clear Directory History…** asks first, then deletes every remembered directory, including the backup copy. A directory comes back only after a shell visits it again.

When you delete a saved host, its directories disappear from the list straight away.

## Privacy

- The history is a list of where your shells have been. It stays on this Mac, in `directory-history.json` in Trellis's state folder, readable only by you. It holds paths, visit counts and times, never terminal output or anything you typed.
- It isn't included in diagnostics, in **File → Export Projects & Hosts…**, or in the [automation API](../api/index.md) and [CLI](../api/cli.md).
- Directories from a remote workspace are reported by that host's shell. A hostile host could report made-up paths, but those entries only ever act on that host.
