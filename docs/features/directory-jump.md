# Directory jump

If you work in a handful of repositories, you shouldn't have to `cd` to them again in every new tab. Trellis remembers the directories your shells have recently and frequently been in, and **Jump to Directory…** takes you back: press ⌘J, then Return.

All requirements here are P2.

## Requirements

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| FR-DJ01 | A visit is recorded when a pane's authenticated prompt mark (FR-SI02) reports a directory other than the last one it reported in that session, whether or not that one was remembered. A session's first prompt counts. Replayed marks (FR-R03) never count. Plain SSH panes (FR-SI09) and panes without shell integration record nothing. | `cd a`, `cd b`, `cd a` gives `a` two visits and `b` one. Pressing Return at a prompt adds none. Reconnecting to a kept session adds none. |
| FR-DJ02 | An entry holds its path, number of visits, last visit and machine: `local`, or the saved host's UUID, so renaming a host keeps its history. Machine and path together identify an entry. | The same path on this Mac and on a host are two entries. |
| FR-DJ03 | At most 100 entries are kept across all machines. Over the limit, the least recently visited entry is dropped. | After visiting 101 directories, the first is gone. |
| FR-DJ04 | The [skip rules](#skipped-directories) are applied before anything is stored, and again when the file is read. | Visiting `/tmp`, `~/.ssh` or a share under `/Volumes` adds nothing. |
| FR-DJ05 | **Jump to Directory…** is a command palette scope, also on **View → Jump to Directory…** (⌘J, rebindable). Rows are ranked by [frecency](#ranking), the current machine's first, under a heading per machine. They're also found by the palette's general search, with the same ranking breaking ties between similar matches. | Two folders named `trellis`: typing `trellis` lists the more frecent first. A shortcut you had already bound to ⌘J keeps it, and Jump to Directory starts unbound. With no history, the scope explains how it fills up. |
| FR-DJ06 | Return, ⌘Return and ⌥Return act as in [Jumping](#jumping). Text is typed into a pane only when its shell is verified idle at a prompt (FR-TK05); half-typed input at that prompt is cleared first, as when a task runs. | With `vim` open in the focused pane, Return opens a new tab and sends nothing to `vim`. |
| FR-DJ07 | A path is only ever used on its own machine: a remote path is never checked or opened on this Mac, and a local path is never typed into a remote shell. | From a remote workspace pane, a local row opens a tab in a local space. |
| FR-DJ08 | **Settings → Sessions → Remember directories** (on by default) stops recording new visits and keeps what's already there. **Clear Directory History…** asks first, then deletes every entry, the backup and any set-aside copy; a directory is listed again only after a shell moves to it. A file from a newer version, or one that can't be read, stays where it is and the clear reports it. Entries for a deleted host are hidden at once and dropped at the next launch, never while `hosts.json` can't be read. | Turned off, `cd` adds nothing, and existing rows still jump. After clearing, no history file remains in the state directory. |
| FR-DJ09 | History is stored in `directory-history.json`, owner-only and replaced atomically, with the previous version kept as a backup. It holds no terminal output, typed input or secret. An unparsable file is set aside and reads as empty; one from a newer version, or one that can't be read, is never written over, and changes then last until quit. Writes are batched, at most one every 2 seconds, and flushed at quit. | The file is `0600`. A corrupt file becomes `directory-history.unreadable.<uuid>.json`. Twenty quick `cd`s write once. |

## Jumping

| Key | Row on the focused pane's machine | Row on another machine |
| --- | --- | --- |
| Return | Types `cd` in the focused pane if its shell is idle at a prompt, otherwise opens a new tab there | New tab there |
| ⌘Return | New tab there | New tab there |
| ⌥Return | Split beside the focused pane; refused while a pane is maximized | New tab there |

**New tab there** means:

- **A local row:** a tab in the current space if it's local, otherwise in the first local space, otherwise in a new space.
- **A host's row:** a tab in that host's remote workspace space, otherwise a new remote workspace.

A plain SSH pane is on neither kind of machine, because its paths aren't verified, so every row opens a new tab from it.

A local directory that no longer exists shows an error and drops the entry. One that doesn't answer within 2 seconds, such as one behind a dead share, shows an error, opens nothing and keeps the row. The check runs off the main thread. A missing directory on a host starts the shell in home instead (FR-RW04), and the row stays.

## Ranking

An entry's score is its visits times a weight for how long ago the last visit was:

| Last visit | Weight |
| --- | --- |
| Under 1 hour | 4 |
| Under 1 day | 2 |
| Under 1 week | 0.5 |
| Older | 0.25 |

Ties go to the most recent visit. Eviction (FR-DJ03) ignores the score: it only looks at the last visit.

## Skipped directories

Matching ignores case, and works on whole path segments, so `/procfoo` is kept while `/proc/1` is skipped.

| Why | Paths |
| --- | --- |
| Network | `/net`, `/Network`, `/afs` |
| Linux system or sensitive | `/proc`, `/sys`, `/dev`, `/run`, `/boot`, `/tmp`, `/var/tmp`, `/var/run`, `/var/lock`, `/lost+found`, `/snap`, `/etc`, `/root` |
| macOS system | `/private/tmp`, `/private/var`, `/private/etc`, `/var/folders`, `/System` |
| Credentials and trash, anywhere in the path | `.ssh`, `.gnupg`, `.aws`, `.kube`, `.password-store`, `.Trash` |
| Not worth a jump | `/`, and home itself (`/Users/<name>`, `/home/<name>`) |
| Malformed | Not absolute, over 1024 bytes, or containing control or invisible characters |

**Network volumes on this Mac:** a path on any mount that isn't local is skipped, which covers shares under `/Volumes` and network mounts elsewhere. A path under `/Volumes` with no mount of its own is skipped too. Trellis reads the mount table without waiting on any file system and never touches the path itself, so an unresponsive share can't stall recording. When the file is read, a path on a mount that isn't local is dropped, but a path under `/Volumes` with no mount stays: that can be a disk that isn't plugged in, and looking at it can't block.

**Limits:**

- Remote hosts get the path rules only: Trellis can't inspect a host's mounts, so a network mount at an ordinary path there is recorded.
- Rules look at the path the shell reports. A symbolic link at an ordinary path that leads to a share or a skipped folder is recorded, because following it could block on that share.

## Privacy

- History is a record of where you've been, kept on this Mac only. It's on by default because the feature is empty without it, and FR-DJ08 turns it off or clears it.
- It isn't included in diagnostics, in **Export Spaces & Hosts** or in the automation API or CLI.
- Paths from a remote workspace come from its shell's nonce-checked marks (FR-RW05). A hostile host could still report made-up paths, and those rows only ever act on that host (FR-DJ07).
