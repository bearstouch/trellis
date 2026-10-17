# SSH hosts

Trellis doesn't implement SSH. Each connection runs the system client, `/usr/bin/ssh`, inside the pane's PTY, so your OpenSSH configuration, keys, agent, known-hosts policy and proxies all work as they normally do. The integration rules are in [Integrations](../integrations.md#ssh-and-saved-hosts) (`INT-03`–`INT-05`).

Open the host library with **File → Hosts…**.

## Requirements

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| FR-H01 | Create, edit, delete, search and tag saved SSH hosts. | Save an alias or hostname, with an optional username, port, identity-file reference, tags and saved password, and reconnect from the host list. |
| FR-H02 | Open a host in a new tab or an explicitly chosen split. | The Hosts window offers a new tab; a split is chosen through automation (`host.connect` with a split target). Each connection has its own SSH process. Editing a host affects only later connections. |
| FR-H03 | Discover aliases from the user's SSH config without changing it. | Imported aliases keep their SSH alias. Config details Trellis doesn't understand are left to OpenSSH. |
| FR-H04 | Keep SSH's own authentication and trust prompts. | Unknown or changed host keys and password or passphrase prompts stay interactive. No host-key bypass is ever added. |
| FR-H05 | Leave failed connections open for inspection and reconnect only when asked. | A failed SSH process shows its status and exit code. There's no automatic credential retry loop. |
| FR-H06 | Optionally save a password per host in the macOS Keychain. | The password is stored as a generic password (service `Trellis SSH Host`, account = host UUID, accessible when unlocked, this device only). It can be added (up to 1,023 bytes, the most ssh reads from askpass, without line breaks), replaced or removed, but never shown again. It never appears in `hosts.json`, exports, the automation API, the CLI, argv, the environment, logs or the pane. A Keychain failure leaves the host unchanged. |
| FR-H07 | Optionally require Touch ID or the Mac password before each use. | With the per-host toggle on, each connection that would use the saved password asks first. Declining or failing falls back to typing the password in the terminal. Turning the toggle off also asks first, and a declined check leaves it on. |
| FR-H08 | Give the saved password to ssh only for its password prompt, at most once per connection. | ssh runs with `SSH_ASKPASS` pointing at the bundled `trellis-askpass` helper. Host-key confirmations, key passphrases, one-time codes, new-password prompts and any second password prompt are asked in the pane, exactly as ssh would ask them (FR-H04, FR-H05). argv is unchanged. |
| FR-H09 | Keep a saved password bound to the connection it was saved for. | Changing the destination, user, port or identity file, whether in the editor, through the API or by an import, removes the saved password and its Keychain item. Renaming or retagging keeps it. Deleting the host deletes its Keychain item. A session started before an edit can't read the newer password. |

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

A host never contains private-key contents or password values. A saved password lives only in the Keychain; the host records only that one exists and whether using it needs Touch ID (FR-H06, FR-H07). Deleting a host removes Trellis's metadata and that Keychain item, nothing else.

## Saved passwords

The Secure Enclave can't hold passwords; it holds only P-256 keys. ssh also has to send the password to the server. So the password necessarily leaves the Keychain into memory for the moment ssh asks for it:

1. When a session starts for a host with a saved password, Trellis registers a random one-time nonce with its askpass broker. The broker is an owner-only AF_UNIX socket in the per-user temporary directory.
2. ssh is launched with `SSH_ASKPASS=<app>/Contents/Helpers/trellis-askpass`, `SSH_ASKPASS_REQUIRE=force` and the socket path and nonce. None of these is a secret.
3. When ssh asks for `…password:`, the helper sends the nonce. The broker consumes the nonce first. It answers only if the peer runs as the same user, the peer's executable is the bundled helper, and the peer's parent is the ssh process Trellis spawned for that session. It also requires the host to still have the connection revision the session started with, and any Touch ID check to have passed.
4. The helper writes the password to ssh's pipe and exits. Trellis and the helper zero the buffers they own once they're done; ssh and Foundation may still hold short-lived copies. Anything not answered is asked on the pane's terminal by the helper itself.

The Touch ID requirement is enforced by Trellis through LocalAuthentication, not by the Keychain item. Builds without a keychain-access-group entitlement, which includes ad-hoc builds, can't use `SecAccessControl`. A Keychain-enforced gate for Developer ID builds is on the [roadmap](../project/roadmap.md). Processes that ssh itself starts, such as a `ProxyCommand`, inherit the nonce, as they inherit everything else from ssh.

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
