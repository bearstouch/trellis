# S019 SSH alias discovery

Date: 2026-10-16. Implemented with independent review and fixes, and automated tests. A native fixture demo is **pending**.

## Behavior

Hosts → **Discover SSH Aliases…** opens a preview sheet.

**Reading the config.** `SSHConfigDiscovery.readConfig` reads `~/.ssh/config` and never writes it.

- Symlinked dotfiles are followed.
- The file is opened `O_NONBLOCK`, and `fstat` must report a regular file of at most 1 MiB; at most limit+1 bytes are read.
- A missing file reports "missing". Any other error becomes a recoverable message: no permission, a FIFO, a directory, a symlink loop, or an oversized file. Nothing in the host library changes.

**What is listed.** The best-effort parser (not an OpenSSH replacement) lists literal `Host` names.

- Keywords are case-insensitive. The keyword separator may be whitespace or one `=`, with optional whitespace around it.
- Double quotes, several names per line, and comments are handled. A `#` that starts a word begins a comment; a `#` inside a word is kept.
- Wildcard (`*`, `?`) and negated (`!`) patterns are reported as warnings, not listed.
- `Match` blocks are reported and never evaluated; `Match exec` is never run.
- `Include` produces an explicit "not followed — add them manually" warning.
- Names that fail S018 destination validation, such as `-oProxyCommand=x`, are reported and skipped.

**Adding hosts.** The user selects aliases. Ones already saved are shown as "Already saved" and disabled.

- `HostLibrary.importAliases` saves each selected alias with the alias as both name and destination, tagged `ssh-config`. The resulting launch is `/usr/bin/ssh -- <alias>`, so OpenSSH still applies the real configuration.
- No HostName, User, IdentityFile, or other options are copied.
- Inside the actor, aliases already saved or repeated in the selection are skipped.
- The rest are validated together and saved in one commit, so a failed selection saves nothing.
- Key contents are never read.

## Tests

- `testS019_UT01_discoverLiteralAliases`: comments, indentation and tabs, two aliases on one line, `Host=`, quoting, duplicates, and line numbers.
- `testS019_UT02_skipPatternsAndMatch`: `*`, `*.corp`, `!negated`, `web?`, `Match exec "touch <marker>"`, and an option-like name. Only `bastion` is listed, and the marker file is never created.
- `testS019_UT03_includeHasExplicitLimitation`: `Include` yields an explicit warning that mentions manual entry.
- `testS019_UT04_unreadableConfigIsNonDestructive`: an injected permission error gives a recoverable failure. Existing hosts, the stored bytes, and the write count are unchanged.
- Additional tests:
  - an atomic import that keeps the alias as the destination, where an invalid selection saves nothing
  - bounded symlink, directory, and oversized reads
  - review tests:
    - `Host = foo` and `Host =foo`
    - a real FIFO and a symlink loop do not block
    - a no-op import of already-saved or repeated aliases performs zero writes

Full suite: **220 tests passed, 0 failures**. Lint is clean, the build has no warnings, and the app packages and verifies.

## Independent review

Three issues were fixed:

1. `=` separators with surrounding whitespace were parsed incorrectly, so aliases were dropped or reported invalid.
2. The type check and the open were separate steps, so a FIFO swapped in between could block the open. A symlink loop was also misreported as "missing".
3. Duplicate filtering existed only in the view, so it could run on a stale list. It is now enforced in the library.

The import sheet now explains an invalid-alias failure in its own terms, instead of showing the editor's "highlighted fields" text.

Follow-ups, not applied:

- Unterminated quotes are accepted, while OpenSSH rejects them.
- Duplicate detection is case-sensitive.
- A long warning list is not scrollable.
- "Already saved" compares only the destination.

## Pending manual verification

These were not performed and are **not** marked passed:

- Discover aliases from an isolated fixture config in the native sheet.
- Compare a connection by the original alias. This requires S020; do not connect to production hosts.
