# Getting started

This page takes you from download to a working setup: installing Trellis, the few ideas it is built on, the `trellis` command-line tool, updates, and what Trellis keeps on your Mac.

## Requirements

- macOS 14 Sonoma or later.
- An Apple silicon or Intel Mac. Trellis is a single Universal app that runs natively on both.

Trellis is distributed directly from GitHub, not through the Mac App Store.

## Install Trellis

1. Download the latest DMG from the [releases page](https://github.com/bearstouch/trellis/releases/latest).
2. Open the DMG and drag the **Trellis** icon onto the **Applications** shortcut beside it.
3. Open Trellis from your Applications folder.

Trellis runs one copy per user. Opening it again brings the existing window forward.

## First launch and the welcome tour

!!! note "New in 1.2 beta"
    The welcome tour first shipped in 1.2.0-beta.1.

The first time Trellis opens on a Mac with no saved workspace, a short eight-step tour appears over the window. It covers spaces, tabs and splits; sessions that keep running; starting a project; remote work; coding agents; the keyboard; and making Trellis your own.

- Move with **Start Tour** / **Next** and **Back**, the page dots, <kbd>←</kbd> and <kbd>→</kbd>, or <kbd>Return</kbd>.
- **Skip Tour** or <kbd>Esc</kbd> closes it. **Start Using Trellis** closes it on the last step.
- While the tour is open, nothing you type reaches a shell. Your sessions keep running behind it.

The last step offers the settings most people choose first:

- **Appearance**: **System**, **Dark** or **Light**.
- **Keep sessions running after quit**: on by default (see [Sessions keep running](#sessions-keep-running)).
- The `trellis` command-line tool, with an **Install** button, when it can be installed.

Each choice applies at once and is saved, the same as in Settings. The tour shows once. Upgrading from an earlier version doesn't open it, and quitting midway doesn't bring it back. Replay it at any time from **Help → Welcome Tour** or the [command palette](features/command-palette.md); replaying changes nothing by itself.

## The core ideas

Trellis organizes your terminals in four levels:

| Thing | What it is |
| --- | --- |
| **Space** | An entry in the left sidebar. A space holds an ordered set of tabs. Usually it's a project you've opened from the [project library](features/project-library.md), but you can also create one on its own with **File → New Space** (<kbd>⌘</kbd><kbd>N</kbd>). |
| **Tab** | A named tab in the selected space's tab bar. Each space has its own tabs. Double-click a tab to rename it. |
| **Pane** | A terminal inside a tab. Split a pane left/right or top/bottom, and split again, to put several terminals side by side. |
| **Session** | The program running in a pane, usually your login shell or `ssh`. Each pane has exactly one session. |

Two more things you'll meet:

- A **project** is a saved recipe for a space: its tabs, splits, folders, commands and git repositories. Launching a project opens its space. Tabs you add to that space yourself are **temporary**: shown in italics, kept when you launch the project again, and never written back to the project.
- A **host** is a saved SSH connection: a name, destination, user and port. It isn't a running session; connecting to it opens one. See [SSH hosts](features/ssh-hosts.md).

Switching spaces or tabs never stops anything; sessions in the background keep running. A tab always has at least one pane, and a space at least one tab. If you delete every space, Trellis shows a welcome screen where you can start a new one.

More on each: [Spaces, tabs and panes](features/workspace.md), [Terminal](features/terminal.md), [Project library](features/project-library.md), [Remote workspaces](features/remote-workspaces.md).

## Sessions keep running

By default, quitting Trellis doesn't end your sessions. They keep running in a small helper process, and the next time you open Trellis they return to their panes, with recent output replayed. A crash or force quit doesn't end them either. Closing the window only hides it; click the Dock icon to bring it back.

If you prefer sessions to end when you quit, turn on **Settings → Sessions → Stop sessions when Trellis quits**. Trellis then asks before quitting with running sessions, and the next launch restores your spaces, tabs and splits as stopped panes. Nothing is started or replayed until you start it.

## Your shell

New panes start your login shell, the one set for your user account. To use a different one, choose it from **Settings → Sessions → Shell**, or pick **Other…** and enter its full path, then click **Save**. zsh, bash and fish get [shell integration](features/shell-integration.md) automatically, with no changes to your dotfiles.

SSH uses the system's own `/usr/bin/ssh`, so your `~/.ssh/config`, keys, agent and known-hosts settings all apply.

## Install the command-line tool

The `trellis` command controls Trellis from any terminal or script. See the [CLI reference](api/cli.md).

It's built into the app. To put it on your `PATH`:

- Accept the offer on first launch, or in the tour's last step, or
- Choose **Trellis → Install Command Line Tool…** at any time.

Either creates one link, `~/.local/bin/trellis`. Trellis never edits your shell's startup files. Afterwards it tells you whether `trellis` is ready to use or whether `~/.local/bin` needs adding to your `PATH`, with a command you can copy and run yourself.

The offer only appears for a copy of Trellis in `/Applications` or `~/Applications`. If you run Trellis straight from the DMG, move it to Applications first.

You can also create the link from a terminal, and choose its folder:

```sh
/Applications/Trellis.app/Contents/Helpers/trellis cli install-link            # creates ~/.local/bin/trellis
/Applications/Trellis.app/Contents/Helpers/trellis cli install-link --dir ~/bin
```

The link must go in a folder under your home folder. Trellis never overwrites a file that isn't its own link. If the folder isn't on your `PATH`, add it yourself.

## Updates

Choose **Trellis → Check for Updates…**, or **Settings → Updates → Check Now**, to look for a new version. An update installs only if its signature checks out. **Install and Relaunch** quits Trellis the normal way: if sessions are running, the usual quit confirmation appears first, and cancelling it postpones the update.

- Automatic daily checks are off until you turn on **Settings → Updates → Automatically check for updates**.
- Beta versions are offered only with **Include beta versions** on. It starts on if you're running a beta.
- A check sends no identifier, workspace data or usage data. It's the only network request Trellis makes on its own.

You can also update by hand: quit Trellis and replace `Trellis.app` with the new version. The `trellis` link keeps working, because it points into the app. Your saved data is migrated to the new version, and a backup of the previous workspace is kept.

!!! warning "Going back to an older version"
    A workspace saved by a newer Trellis may not open in an older one. The older version shows a recovery screen and leaves the file alone. Before downgrading, keep a copy of `~/Library/Application Support/com.bearstouch.trellis`.

## Where Trellis keeps your data

Trellis keeps its files in `~/Library/Application Support/com.bearstouch.trellis/`, readable only by you:

| File | Contents |
| --- | --- |
| `workspace.json` | Spaces, tabs, splits and most settings, with a backup copy in `workspace.backup.json` |
| `hosts.json` | Saved SSH hosts, with a backup copy |
| `projects.json` | The project library, with a backup copy |
| `Themes/` | Your custom themes |

Keyboard shortcuts and a few other preferences are in the standard macOS preferences. Automation tokens and saved host passwords are in your login Keychain, under **Trellis Automation** and **Trellis SSH Host**.

To back up Trellis, copy that folder while Trellis isn't running. Passwords and tokens stay in the Keychain and don't travel with it. To move projects and hosts to another Mac, use **File → Export Projects & Hosts…** and **File → Import Projects & Hosts…**. Exports never include passwords, and an import shows a summary before it changes anything.

## Privacy

Trellis never saves:

- what your terminals print, or what you type, unless you turn on **Settings → Sessions → Restore scrollback after quit** (off by default), which saves each pane's text with secrets redacted as best it can
- passwords and other credentials, outside the Keychain
- environment variable values

It has no telemetry, and it doesn't log terminal output or typed input. It reads the clipboard only when you paste.

## Permissions

Your shells and `ssh` run as you, with no administrator helper. Trellis never asks for Accessibility, Screen Recording or Full Disk Access permission. If macOS blocks access to a folder, Trellis explains what happened where you tried it, rather than asking for broader access.

## Uninstall Trellis

1. Quit Trellis. If it asks about running sessions, choose **Stop Sessions**, so no session keeps running in the background.
2. Run `trellis cli uninstall-plan` to list every file and Keychain item that belongs to Trellis, then `trellis cli remove-link` to remove the command-line link. If you never installed the link, run the tool from inside the app instead: `/Applications/Trellis.app/Contents/Helpers/trellis cli uninstall-plan`.
3. Delete `Trellis.app`.
4. Delete the folders the plan lists: Application Support, Preferences, Caches and Saved Application State for `com.bearstouch.trellis` (and `dev.trellis`, if you used Trellis 0.11 or earlier).
5. In Keychain Access, delete the items for the services **Trellis Automation** and **Trellis SSH Host**.

Trellis never touches your `~/.ssh` folder (keys, config, `known_hosts`), your shell startup files or your shell history, so those stay as they were.
