# Integrations

Trellis relies on the system and on existing tools rather than reimplementing them. This page sets the boundaries.

## Shells and local tools

**INT-01 (P0).**

- Start the user's login shell, from the account database with `-l`. zsh and bash are both validated on macOS, and settings accept a custom absolute shell path.
- Children get `TERM=xterm-256color`. Only claim a terminal type that the engine and the installed terminfo really support.
- Support terminal dimensions, normal input, job control, signals, colors, the alternate screen, mouse modes and bracketed paste. vim, less, top, git and long-running dev servers are the reference workloads.
- Basic use must never depend on shell integration.
- Without shell integration, Trellis knows only the *initial* working directory. It must not claim to know the shell's current directory, the active command, or whether a command completed. The one exception is an SSH pane showing what its remote shell reported, labelled unverified ([FR-SI09](features/shell-integration.md)).

**INT-02 (P1).** zsh, bash and fish integration reports prompt readiness, the local current directory, command start and end, and exit status. See [Shell integration](features/shell-integration.md).

- It's on by default, can be turned off in Settings, and never requires editing dotfiles.
- The protocol is versioned (`TRELLIS_SHELL_INTEGRATION=1`). Every mark that changes Trellis state carries a per-session nonce, so integration messages are distinguishable from ordinary output.
- Unsupported shells, SSH sessions and custom processes keep the INT-01 rule: no claims about their directory or commands.
- Exception for SSH panes ([FR-SI09](features/shell-integration.md)): a remote shell's own nonce-less marks are shown as the remote directory, titles, exit status and command notifications. They are labelled unverified, and never become a local directory claim: no file links, new-pane directories, saved launch directories or automation `currentDirectory`.

## SSH and saved hosts

**INT-03 (P0).**

- SSH runs as `/usr/bin/ssh` inside a PTY, so the user's OpenSSH configuration, keys, agent, known-hosts policy and proxy settings all apply.
- Host-key verification and interactive authentication stay in the terminal.
- Trellis doesn't implement SSH. Its only credential handling is an optional per-host password in the macOS Keychain, given to ssh through `SSH_ASKPASS` for its password prompt only ([FR-H06–FR-H09](features/ssh-hosts.md#saved-passwords)).
- Arguments are built without a shell. There's no unrestricted "extra arguments" field, and destinations that start with `-` or contain control characters are rejected.

**INT-04 (P0).** Discovery reads literal aliases from `~/.ssh/config`, as a best effort; it isn't an OpenSSH parser.

- Wildcards and `Match` rules don't become hosts.
- `Include` files discovery doesn't follow are labeled, and those aliases can still be added by hand.
- Discovery never runs `Match exec` or any other command.
- Trellis never modifies SSH configuration and never imports key contents.

**INT-05 (P0).**

- Each connection is a local SSH process with normal lifecycle reporting. "Running" means the process is alive, not that authentication finished.
- Disconnecting and retrying are always explicit for SSH panes.
- Exception: a [remote workspace](features/remote-workspaces.md) link reconnects automatically, but only with `BatchMode=yes`, so it never retries a credential prompt (FR-RW07). Remote workspaces keep remote processes alive through a Trellis helper on the host.
- SFTP and automatic tmux attachment are outside the MVP.

See [SSH hosts](features/ssh-hosts.md).

## Scripts and agents

**INT-06 (P0).**

- Scripts and external agents use the same local API and CLI.
- Trellis publishes everything a client needs: version discovery, structured JSON results, resource IDs, bounded output cursors and layout examples.
- Recommended flow: validate, plan and apply a layout first, then explicitly start sessions or execute commands. See [CLI → Agent workflow](api/cli.md#agent-workflow-int-06).
- Trellis doesn't embed an AI model, obtain provider API keys, or interpret terminal output as instructions. Any local client that can run the CLI or speak the socket protocol can act as an agent.

**INT-07 (P1).** An optional MCP adapter exposes the existing command service as tools. It can't expand a grant's permissions, it must keep the output limits, redaction and execution semantics, and it must not be a second, independent automation implementation. It's implemented as the [MCP server](api/mcp.md), off by default and enabled in Settings → Remote Control.

## Clipboard and macOS services

**INT-08 (P0).**

- Copy and paste use `NSPasteboard` and AppKit selection semantics, and only when the user triggers them.
- The clipboard is read only on paste and is never polled. Copy strips terminal control sequences.
- Pasting files as escaped paths is an explicit action, and shows a preview when shell escaping is uncertain.
- Clipboard requests from the terminal (OSC 52) are disabled, and agents get no clipboard access in v1.
- Links open through the system URL handler, only after a user gesture, and only for `https`, `http`, `mailto` and existing local files. Files that could run code are revealed in Finder instead (FR-L03).

## Configuration import and export

**INT-09 (P0).**

- Exports are portable JSON with schema versions. They exclude credentials (including saved host passwords and whether one exists), output history and runtime environment values. Imports never set a password.
- Before applying an import, Trellis previews the counts, hosts and launch references.
- Host import is atomic. Existing hosts don't change unless the user explicitly picks a collision policy, and a matching alias or name alone never authorizes overwriting a host.
- `layout.apply` through the API follows its [additive semantics](api/layouts.md#matching-and-idempotency-fr-a04). An interactive import always creates fresh resources.
- Full compatibility with iTerm2 profiles or proprietary automation isn't promised. A future importer must map only the fields it supports and explain what it leaves out.

## JSON themes

**INT-10 (P0).** Local JSON themes are imported and exported in the [theme format](features/themes.md). Users, scripts and agents can all write them, and no engine-specific configuration is needed. Importing a theme never runs code or loads remote assets.

## Dependencies

- **SwiftTerm** is pinned and vendored, MIT-licensed, and its patches are recorded. See [Terminal engine](architecture/terminal-engine.md).
- **OpenSSH** is the system's own. Use local manual pages and controlled test hosts for integration checks.
- **Never** test against a user's production hosts or existing sessions during development without explicit instruction.
