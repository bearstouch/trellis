# Integrations

## Shells and local tools

**INT-01 / P0:** Start the user's configured login shell; validate zsh and bash on macOS. Support a custom absolute executable path through settings. Set `TERM` to a value whose capabilities the selected terminal engine and installed terminfo actually support; finalize this in the engine spike rather than claiming an unverified terminal type.

Expose terminal dimensions and normal terminal input, job control, signals, colors, alternate screen, mouse modes, and bracketed paste when supported. Test vim, less, top, git, and a long-running development server. Optional shell integration must not be required for basic use.

The application may know an initial local working directory; without shell integration it must not claim to know the shell's current directory, active command, or command completion. Process exit status means the launched process exited, not that the last command in an interactive shell succeeded.

**INT-02 / P1:** Opt-in zsh/bash integration can report prompt readiness, local current directory, command start/end, and exit status. Version the integration protocol and distinguish authenticated integration messages from arbitrary output. Do not assume a remote command is observable unless integration is installed there too.

## SSH and saved hosts

**INT-03 / P0:** Delegate SSH to `/usr/bin/ssh` in a PTY. Use existing OpenSSH configuration, keys, agent, known-hosts policies, and configured proxy behavior. Preserve host-key verification and interactive authentication. Do not implement SSH or credential management from scratch.

Saved host fields: display name, destination kind (`alias` or `hostname`), destination, optional username, optional port 1–65535, optional absolute identity-file reference, and tags. Reject leading-option destinations and control characters. Construct arguments without a shell; do not expose unrestricted extra SSH arguments in MVP. Explicit fields override SSH defaults through documented client arguments, while unset fields remain delegated to configuration.

**INT-04 / P0:** Provide read-only discovery of literal aliases from `~/.ssh/config`. This is best-effort discovery, not a replacement OpenSSH parser. Wildcards and `Match` rules are not materialized as hosts; label unsupported `Include` discovery and allow manual aliases. Running the system client against the chosen alias preserves effective SSH behavior. Do not execute `Match exec` or shell commands merely to populate the host list. Never modify SSH configuration or import key contents.

**INT-05 / P0:** Each connection is a local SSH process with normal lifecycle reporting. “Running” means the SSH process is live, not that authentication completed. Disconnect and retry are explicit. Network reconnect, remote process preservation, SFTP, and automatic tmux attachment are outside MVP.

## Automation scripts and agents

**INT-06 / P0:** Scripts and external agents use the same local API and CLI. Publish version discovery, structured JSON results, resource IDs, bounded output cursors, and layout examples. Scripts should validate/plan/apply layouts first, then explicitly start sessions or execute commands.

A supported agent flow is: obtain a scoped user-approved grant; authenticate; enumerate allowed windows; create/apply a layout; start approved sessions; subscribe to status; request output only when granted; submit explicit input; observe process exit when using dedicated command processes. Agent disconnect does not close sessions.

The application does not embed an AI model, obtain provider API keys, or interpret terminal output as instructions. Agents may be any local client capable of invoking the CLI or socket contract. No vendor-specific agent runtime is required.

**INT-07 / P1:** An optional MCP adapter may translate tools to the existing command service. It cannot expand grant permissions and must preserve output limits, redaction, and execution semantics. Do not add a second independent automation implementation.

## Clipboard and macOS services

**INT-08 / P0:** Use NSPasteboard for user-triggered copy/paste and AppKit selection semantics. Read clipboard text only on paste; do not poll. Copy strips terminal control sequences. Pasting files as escaped paths is explicit, with a preview when shell escaping is uncertain.

Terminal-originated clipboard requests are disabled by default. Do not grant clipboard access to agents in v1. Opening hyperlinks uses system URL handling after a user gesture and validates allowed schemes (`https`, `http`, `mailto`). Custom schemes and automatic opening are disabled.

## Configuration import/export

**INT-09 / P0:** Export portable JSON layouts and host metadata with schema versions, excluding credentials, output history, and runtime environment secrets. Preview import counts, hosts, and launch references before applying. Host import is atomic; existing hosts remain unchanged unless the user explicitly selects a collision policy. Alias/name matches alone do not authorize overwriting an existing host. Layout API apply follows its additive semantics; interactive import creates fresh resources.

Full iTerm2 profile or proprietary automation compatibility is not promised. A later importer must map only supported fields and explain omissions.

## JSON theme files

**INT-10 / P0:** Import/export local JSON themes using the [theme format](../03-functional-requirements/themes/README.md). Support standalone files authored by users, scripts, or agents, with no terminal-engine-specific configuration needed. Theme import never executes code or loads remote assets.

## Dependencies and verification

Evaluate SwiftTerm through its [upstream repository](https://github.com/migueldeicaza/SwiftTerm). Record a pinned version, license obligations, and actual compatibility results before implementation commits to the engine. Rely on system OpenSSH for configuration and authentication behavior; use local manual pages and controlled test hosts during integration qualification. Do not test against or alter a user's production hosts during development without explicit instruction.
