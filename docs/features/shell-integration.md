# Shell integration

All requirements here are P1. They implement [INT-02](../integrations.md#shells-and-local-tools).

Shell integration lets a local zsh, bash or fish shell report its current directory, the command it's running and that command's exit status. Trellis loads the bundled scripts automatically. Your dotfiles aren't edited, and they still load as usual. Integration is on by default; turn it off in **Settings → Sessions → Shell integration**. The setting applies to sessions started afterwards.

**Settings → Sessions → Shell** lists the installed shells from `/etc/shells` and the usual Homebrew locations, and marks the ones with integration. **Other…** takes any absolute path. A note under the picker says in words whether the chosen shell gets integration. Supported shells are recognized by file name, so `/opt/homebrew/bin/bash` (bash 5) qualifies too. Any local login shell keeps integration, including panes started before the default shell changed.

## Requirements

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| FR-SI01 | Inject the integration into local login shells without editing user files. zsh, bash 3.2+ (including macOS `/bin/bash`) and fish are supported. | A shell's own startup files still run: zsh `.zshenv`/`.zshrc` (an existing `ZDOTDIR` is kept), bash `/etc/profile` then `.bash_profile`/`.bash_login`/`.profile`, fish `config.fish`. SSH sessions, custom processes, fixtures, other shells and disabled integration launch unchanged. A missing script launches the plain shell. |
| FR-SI02 | Accept only authenticated, versioned integration marks. | A per-session random nonce authenticates each OSC 133 mark that changes Trellis state. The nonce never reaches child processes' environments, even when the prompt (`PS1`) is exported. `printf` of a mark without it, or with another nonce, changes nothing. |
| FR-SI03 | Track the shell's current directory, and start new splits and new tabs there. | After `cd 'x y'`, the pane header shows the new directory, and a split or a new tab starts in it. If no directory has been reported, or the directory is gone, the default directory is used. Duplicating a tab still copies saved launch settings (FR-T01). |
| FR-SI04 | Report each command's exit status. | After `false`, the tab and pane show a failure symbol with the text "Exit 1", and VoiceOver reads "Last command failed (exit 1)". The indicator clears when the next command starts. `session.get` reports `shellIntegration.lastExitStatus`. |
| FR-SI05 | Give unrenamed tabs and panes an automatic title. | A tab titled "Terminal" shows the running program (`vim`), or else the directory name (`~` for home). A renamed tab, or a pane with its own title, keeps that title. |
| FR-SI06 | Navigate between prompts. | Edit → Previous Prompt (⌘↑) and Next Prompt (⌘↓) scroll the pane to the previous or next prompt. While a text field (tab rename, search) is editing, ⌘↑/⌘↓ stay text navigation. |
| FR-SI07 | Restore each local shell pane in its last reported directory. | After `cd 'x y'`, quitting and relaunching shows `x y` in the pane header, and starting the pane opens the shell there. Quit stops the shells before saving, so the directory isn't lost. If the directory is gone when saved, or the pane's current session reported nothing (for example after Restart, before the new shell's first prompt), the pane keeps its launch directory. SSH panes and custom processes are unaffected. The live session's launch settings don't change, so Restart and Duplicate Tab behave as before (FR-T01). |

## Protocol (version 1)

Trellis starts a supported login shell with `TRELLIS_SHELL_INTEGRATION=1` (the protocol version) and `TRELLIS_SHELL_INTEGRATION_NONCE`, a fresh 128-bit hex value for each session. The script copies both into unexported shell variables and unsets them before any user command runs.

How each shell loads its script:

- **zsh:** `ZDOTDIR` points at the bundled `zsh/.zshenv`, which restores the user's `ZDOTDIR` and sources their `.zshenv`.
- **bash:** `bash --rcfile <script> -i`. The script emulates login startup, because `--rcfile` doesn't work with `-l`.
- **fish:** the bundled directory is prepended to `XDG_DATA_DIRS`, so fish loads `fish/vendor_conf.d/trellis-shell-integration.fish`. The script restores the original value.

Marks are OSC 133 sequences terminated by BEL. `A`, `C` and `D` carry `trellis=<nonce>`. `B` sits inside the prompt string, which is often exported to child processes, so it carries no nonce and changes no Trellis state:

| Mark | Sent | Extra fields |
| --- | --- | --- |
| `A` | Before each prompt | `cwd=<percent-encoded absolute path>` |
| `B` | At the end of the prompt | — |
| `C` | When a command starts | `cmdline_url=<percent-encoded command>`, at most 4,096 characters |
| `D;<exit>` | When the command finishes | — |

Every OSC 133 mark, authenticated or not, still feeds the engine's prompt tracking. That's why prompt navigation also works for marks a shell emits on its own. Only authenticated marks change the directory, the command state or titles.

## Privacy and limits

- The command line is runtime state only. It isn't persisted, logged, exported or returned by the API; only the program name is shown as a title. A reported directory is persisted only as a local shell pane's saved launch directory (FR-SI03, FR-SI07).
- `session.get` shows `currentDirectory` only to grants with execute permission, as it does for launch directories.
- bash reports the first simple command of a line (`env` for `env | grep x`). A line that starts with a subshell, such as `(exit 3)`, isn't reported as a command; its prompt and directory still are. bash's login emulation sources the profile files, but `shopt login_shell` is off and `~/.bash_logout` doesn't run.
- Remote shells aren't covered: an SSH session's marks can't carry the local nonce.
- fish has been checked by its unit and PTY tests only where fish is installed.
