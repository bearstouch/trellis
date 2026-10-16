# SSH hosts

Trellis doesn't implement SSH. Each connection runs the system client, `/usr/bin/ssh`, inside the pane's PTY, so your OpenSSH configuration, keys, agent, known-hosts policy and proxies all work as they normally do. The integration rules are in [Integrations](../integrations.md#ssh-and-saved-hosts) (`INT-03`–`INT-05`).

Open the host library with **File → Hosts…**.

## Requirements

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| FR-H01 | Create, edit, delete, search and tag saved SSH hosts. | Save an alias or hostname, with an optional username, port, identity-file reference and tags, and reconnect from the host list. |
| FR-H02 | Open a host in a new tab or an explicitly chosen split. | Each connection has its own SSH process. Editing a host affects only later connections. |
| FR-H03 | Discover aliases from the user's SSH config without changing it. | Imported aliases keep their SSH alias. Config details Trellis doesn't understand are left to OpenSSH. |
| FR-H04 | Keep SSH's own authentication and trust prompts. | Unknown or changed host keys and password or passphrase prompts stay interactive. No host-key bypass is ever added. |
| FR-H05 | Leave failed connections open for inspection and reconnect only when asked. | A failed SSH process shows its status and exit code. There's no automatic credential retry loop. |

## Saved host fields

| Field | Rules |
| --- | --- |
| Display name | Free text label |
| Destination kind | `alias` or `hostname` |
| Destination | Can't start with `-` (no option injection) and can't contain control characters |
| Username | Optional |
| Port | Optional, 1–65535 |
| Identity file | Optional absolute path. Trellis stores the **reference**, never the key contents. |
| Tags | Used for search and filtering |

A host never contains passwords or private-key contents. Deleting a host removes only Trellis's metadata.

## How a connection is launched

- Trellis builds an executable path plus an argument array. No shell is involved, so nothing in a host field can be interpolated.
- Fields you set explicitly override SSH defaults through documented client arguments. Fields you leave unset are left to your SSH configuration.
- There's no free-form "extra SSH arguments" field in the MVP.
- No host-trust bypass flag (such as `StrictHostKeyChecking=no`) is ever added.

## Session state for SSH

A live SSH client is `running`. That means the `ssh` process is alive, **not** that authentication succeeded; Trellis doesn't guess from screen text. When the connection fails, the pane stays open with its exit status. Reconnecting is an explicit action. Network reconnect, remote process preservation, SFTP and automatic tmux attachment are outside the MVP.

## Alias discovery

Discovery reads `~/.ssh/config` and offers its literal `Host` aliases. It's a best-effort list, not an OpenSSH parser:

- Wildcard patterns and `Match` blocks don't become hosts.
- `Include` files that discovery doesn't follow are labeled, and you can still add those aliases by hand.
- Discovery never runs `Match exec` or any other command.
- Trellis never modifies SSH configuration and never imports key contents.

Because a connection runs `ssh <alias>`, the effective SSH behavior is whatever your configuration says.
