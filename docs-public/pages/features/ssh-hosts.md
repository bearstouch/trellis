# SSH hosts

Save the servers you connect to and open them in a tab or a space with one click. Trellis doesn't implement SSH itself: every connection runs the system client, `/usr/bin/ssh`, inside the pane, so your `~/.ssh/config`, keys, ssh agent, known-hosts policy and proxies work exactly as they do in any other terminal.

Open the host library with **File → Hosts…**. Your saved hosts are also listed in the command palette (<kbd>⇧</kbd><kbd>⌘</kbd><kbd>P</kbd>).

## Save a host

1. Open **File → Hosts…** and choose **New Host**.
2. Fill in the fields below. Only a name and a destination are needed.
3. Choose **Add Host**.

To change a host, select it, edit its fields and choose **Save Changes**. Changes apply only to connections you open afterwards; sessions that are already running aren't touched.

| Field | What it holds |
| --- | --- |
| **Name** | A label for the host, such as "Production API". |
| **SSH alias or hostname** | An alias from your `~/.ssh/config` (`prod-api`) or a hostname (`api.example.com`). It can't start with `-` or contain control characters. |
| **User (optional)** | The login name. Leave it empty to use your SSH configuration's. |
| **Port (optional)** | 1–65535. Leave it empty to use your SSH configuration's. |
| **Identity file (optional)** | The absolute path to a private key. **Choose…** picks one in Finder. Trellis stores only the path, never the key. |
| **Tags (comma-separated)** | Words to search and filter by, such as `prod, api`. |
| **Password (optional)** | A password saved in your Keychain. See [Saved passwords](#saved-passwords). |

Fields you fill in override your SSH configuration for that host; fields you leave empty are left to it. There's no field for extra ssh arguments. Put those in `~/.ssh/config` instead.

The search field at the top of the list matches names, destinations, users and tags.

## Connect to a host

Select a host and choose:

- **Connect in New Tab** to open it in a new tab of the current space.
- **Connect in New Space** to open a new space named after the host, with one tab connected to it.
- **Open Remote Workspace** to open a space whose sessions run on the host and keep running when the connection drops. See [Remote workspaces](remote-workspaces.md).

Save or revert unsaved edits before connecting. Every connection starts its own `ssh` process.

Trellis launches ssh directly with a list of arguments, never through a shell, so nothing you type into a host field can be run as a command. It never adds options that skip host-key checks.

### Prompts stay in the terminal

ssh asks its usual questions in the pane: confirming an unknown or changed host key, your password, a key passphrase or a one-time code. Trellis never answers them for you, except a password you chose to save, and never bypasses a host-key warning.

### When a connection ends or fails

An SSH session counts as running as long as the `ssh` process is alive. That doesn't mean you're logged in yet; Trellis doesn't guess from what's on screen.

When ssh exits, whether you logged out or the connection failed, the pane stays open so you can read what happened, and its header shows the status and exit code. Trellis never reconnects or retries a password on its own. Choose **Reconnect** in the pane header to start a new connection in the same pane.

To keep remote programs running across disconnects and have Trellis reconnect for you, open the host as a [remote workspace](remote-workspaces.md) instead.

## Saved passwords

You can save a password for a host in your Mac's Keychain, so you don't have to type it at ssh's password prompt.

- **Add one:** type it in the host's **Password** field and save the host. It can be up to 1,023 bytes and can't contain line breaks.
- **Change or remove it:** choose **Replace…** or **Remove**. A saved password is never shown again, not even to you.
- **Require Touch ID or Mac password to use:** turn this on to be asked before each connection that would use the saved password. If you decline or the check fails, you type the password in the terminal instead. Turning the option off also asks you first.

Trellis gives the saved password to ssh only when ssh asks for that host's password, and only once per connection. Host-key questions, key passphrases, one-time codes, a request for a new password and any second password prompt are still asked in the pane, as ssh would ask them.

A saved password belongs to the connection it was saved for. Changing the host's destination, user, port or identity file removes it (from the editor, an import or automation alike), and Trellis tells you so. Renaming the host or changing its tags keeps it. A session started before an edit can't use a password saved after it.

!!! tip
    Saved passwords are used only when you connect yourself. A [remote workspace](remote-workspaces.md) that drops its connection can reconnect on its own only with keys or an ssh agent.

### Where the password goes

- It's stored only in this Mac's Keychain, as a generic password named **Trellis SSH Host**, available when the Mac is unlocked and never synced to other devices.
- It never appears in Trellis's host file, exports, the [automation API](../api/index.md), the [CLI](../api/cli.md), command lines, environment variables, logs or the pane.
- Trellis hands it to ssh through a small bundled helper, `trellis-askpass`, which ssh runs at its password prompt. Trellis answers only that helper, started by the ssh process it launched for that connection.
- If the Keychain can't save or remove the password, the host is left as it was.

## Delete a host

Select the host, choose **Delete…** and confirm with **Delete Host**. Trellis removes its saved details and any saved password from the Keychain. Your SSH keys, `~/.ssh/config` and `known_hosts` aren't changed, and open sessions keep running.

## Import aliases from your SSH config

Choose **Discover SSH Aliases…** in the host library. Trellis reads the literal `Host` names in `~/.ssh/config` without changing the file, lists them with their line numbers, and marks the ones you've already saved. Select the ones you want and choose **Add N Selected**.

Each alias is saved as the host's destination, so connecting runs `ssh <alias>` and everything in your SSH config for that alias still applies. Discovery is a convenience, not a full OpenSSH parser:

- Wildcard patterns (`Host *.internal`) and `Match` blocks don't become hosts.
- `Include` files that discovery doesn't follow are noted in the list. You can still add those aliases by hand with **New Host**.
- Discovery never runs `Match exec` or any other command.
- Trellis never modifies your SSH configuration and never imports key contents.

If there's no `~/.ssh/config`, add hosts by hand with **New Host**.

## Privacy

- A saved host holds only the fields above. It never contains private keys or password values; the identity file is stored as a path.
- Passwords live only in the Keychain, as described in [Saved passwords](#saved-passwords).
- **File → Export Projects & Hosts…** exports your hosts without passwords.
