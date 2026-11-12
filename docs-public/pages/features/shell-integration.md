# Shell integration

Shell integration lets your shell tell Trellis which directory it's in, which command it's running and how that command ended. Trellis uses it to open new tabs and splits where you are, title tabs after what's running, mark failed commands, jump between prompts and tell you when a long command finishes.

It works with zsh, bash (3.2 and later, including the `/bin/bash` that comes with macOS) and fish, and it's on by default. You don't need to install anything or edit your dotfiles.

## What you get

- **New tabs and splits start where you are.** After `cd ~/src/app`, a split or a new tab opens in `~/src/app`, and the pane header shows the new folder. If the shell hasn't reported a folder yet, or the folder is gone, Trellis uses the default directory. **Duplicate Tab** still copies the tab's saved launch settings.
- **Panes reopen where you left them.** When you quit and relaunch, each local shell pane starts in the last folder its shell reported. If that folder no longer exists, the pane starts where it was first launched. Restart and Duplicate Tab are unaffected.
- **Failed commands are marked.** After a command fails, such as `false`, the tab and pane show a failure symbol with the text "Exit 1", and VoiceOver reads "Last command failed (exit 1)". The mark clears when the next command starts.
- **Automatic titles.** A tab you haven't renamed (titled "Terminal") shows the program that's running, such as `vim`, or else the folder name (`~` for your home folder). A tab you've renamed, or a pane with its own title, keeps its name. When the program is a [coding agent](agents.md) such as `claude`, the tab shows that agent's icon and name.
- **Jump between prompts.** **Edit → Previous Prompt** (<kbd>⌘</kbd><kbd>↑</kbd>) and **Edit → Next Prompt** (<kbd>⌘</kbd><kbd>↓</kbd>) scroll the pane to the previous or next prompt. While you're editing text, such as renaming a tab or searching, these keys keep moving the text cursor instead.
- **A quieter busy bar.** Output while you sit at the prompt doesn't make the tab look busy.
- **Notifications for long commands.** See [below](#get-notified-when-a-long-command-finishes).
- **Your project follows you.** The folder your shell reports decides which project's [tasks](tasks.md), [files](files.md) and [changes](changes.md) the sidebar shows, and feeds [directory jump](directory-jump.md).

## Turn it on or off

Shell integration is on by default. To turn it off, clear **Settings → Sessions → Shell integration (zsh, bash, fish)**. The change applies to sessions you start afterwards; panes already running keep what they had.

## Choose a supported shell

**Settings → Sessions → Shell** lists the shells installed on your Mac, from `/etc/shells` and the usual Homebrew locations. Shells that get integration are marked **Shell integration**, and a note under the picker says in words whether the chosen shell supports it. **Other…** lets you type any absolute path.

Trellis recognizes zsh, bash and fish by their file name, so a Homebrew bash such as `/opt/homebrew/bin/bash` gets integration too. Other shells start normally, without it.

## Your dotfiles still load

Trellis loads its own small script alongside your usual startup files, without changing them:

- **zsh** still reads your `.zshenv` and `.zshrc`, and keeps your `ZDOTDIR` if you set one.
- **bash** reads `/etc/profile`, then `.bash_profile`, `.bash_login` or `.profile`, as a login shell would.
- **fish** reads your `config.fish`.

Integration applies only to local shell panes. [SSH](ssh-hosts.md) panes, panes running a custom command, and shells Trellis doesn't support start unchanged. [Remote workspaces](remote-workspaces.md) install the same scripts on the host along with the remote helper.

## Get notified when a long command finishes

When a command that ran for a while finishes and you aren't looking at its pane (Trellis isn't the active app, or the pane isn't the focused pane of the selected tab), Trellis posts a desktop notification.

Choose how long a command must run in **Settings → Sessions → Notify when a command finishes**: **Off**, or after 5, 10 (the default), 30 or 60 seconds. The setting is unavailable while **Desktop notifications** is off, which turns these notifications off too.

- The title is "Command finished", or "Command failed (exit 3)" when the command exited with an error.
- The text names only the program and how long it ran, such as "make ran for 12 s". It never shows the command line or its arguments, so `TOKEN=x make deploy` shows just "make".
- The subtitle names the space and tab it ran in, such as "api › Build".
- Clicking the notification takes you to the pane.

A pane posts at most 5 notifications in 10 seconds, counting notifications from programs too. Reconnecting to a session that kept running after quit doesn't notify for commands that finished while you were away.

## SSH panes

For [SSH](ssh-hosts.md) panes (a saved host's pane, or a pane started straight into `ssh`, `mosh` or `autossh`), Trellis installs nothing on the server. If the remote shell already has its own shell integration, Trellis reads what it prints and shows:

- the host and folder in the pane header, as "SSH · host:/srv/app",
- automatic titles that follow `cd` and the running program,
- the "Exit 1" mark for failed commands,
- notifications for long commands.

The easiest way to get this is [iTerm2's shell integration](https://iterm2.com/documentation-shell-integration.html) on the server. Trellis tells it that the terminal supports it (it sets `LC_TERMINAL=iTerm2`, which the macOS `ssh` client forwards). The shell integrations of kitty, Ghostty and WezTerm usually only turn themselves on inside their own terminal.

Because anything printed in an SSH pane could imitate these reports, Trellis treats them as unverified and uses them for display only. The pane header's tooltip and VoiceOver hint say the folder was reported by the remote shell. A remote folder is never used to open links, start new tabs or splits, or restore the pane, and it's never saved.

A host you reach by typing `ssh` inside a local shell isn't treated as remote: its reports are ignored. Turning shell integration off ignores remote reports too, for sessions started afterwards.

## Privacy

- The command line is kept only while the session runs. It's never saved, logged, exported or shown to the automation API. Only the program name appears, as a title and in notifications.
- The folder a shell reports is saved only as a local pane's starting folder for next launch and, unless you turn it off, in your [directory history](directory-jump.md). A folder reported in an SSH pane is never saved.
- Programs you run can't fake the reports of a local shell: each session uses a random secret that Trellis doesn't pass on to them.
- Through the [automation API](../api/index.md), `pane.get` reports a pane's last exit status, and its current folder only to clients allowed to run commands; `session.execute` can wait for a command and return its exit status, and `command.finished` events report each command.

## Limits

- bash reports only the first simple command of a line, so `env | grep x` is titled `env`. A line that starts with a subshell, such as `(exit 3)`, isn't reported as a command; its prompt and folder still are.
- To read your profile files, bash starts as an interactive shell that behaves like a login shell. `shopt login_shell` is off, and `~/.bash_logout` doesn't run.

## Reference: marks Trellis reads

Shell integration uses standard terminal escape sequences, ended by BEL. You only need this to set up a remote shell by hand.

**Any pane:** OSC 133 prompt marks (`A` before each prompt, `B` at the end of the prompt, `C` when a command starts, `D;<exit>` when it finishes) let **Previous Prompt** and **Next Prompt** work, even from a shell that sends them on its own. In a local pane they change nothing else unless they carry the session's secret.

**SSH panes** also accept, for display only:

| Sequence | Reports |
| --- | --- |
| OSC 133 `A` | A new prompt |
| OSC 133 `C`, with an optional `cmdline_url=<percent-encoded command>` | A command started |
| OSC 133 `D;<exit>` | The command finished with this exit status |
| OSC 7 `file://host/path` (percent-encoded) | The current folder |
| OSC 1337 `CurrentDir=<path>` | The current folder |
| OSC 1337 `RemoteHost=<user@host>` | The host |

A path must be absolute and contain no control characters. A host name can be up to 253 letters, digits or `.-_:[]`.
