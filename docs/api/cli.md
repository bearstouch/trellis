# The `trellis` CLI

`trellis` is a structured client for the [automation API](index.md). Its code is in `Sources/TrellisCLI`, with the executable in `Sources/TrellisCLIMain`.

| Context | How to run it |
| --- | --- |
| Development | `swift run trellis-cli …` |
| Packaged app | `Trellis.app/Contents/Helpers/trellis`, optionally linked onto your `PATH` with `trellis cli install-link` (see the [release guide](../release/README.md#installing)) |

## Usage

```text
trellis <noun> <verb> [options]
```

- Options take the form `--opt VALUE`. The `--opt=value` form is rejected.
- Every command except `cli …` needs credentials, from exactly one of:
    - `--token-stdin`: read the token from standard input.
    - `--keychain-grant GRANT_UUID`: read the token from the Keychain.
- The CLI always rejects `--token`, `--password` and `--secret`, because command lines leak into process lists and shell history.
- `--launch` starts the app (`open -b com.bearstouch.trellis`) if it isn't already running. Without it, a missing app gives `APP_NOT_RUNNING`.
- `--state-directory DIR` points the CLI at a development instance started with the same flag.
- Mutating commands accept `--idempotency-key KEY`.
- The CLI never retries anything on its own.
- `--window`, `--tab` and `--host` accept a UUID or an exact name. An ambiguous name exits with 2, and no match exits with 3.
- Replies time out after 120 seconds. Event streams have no timeout.

## Commands

| Command | API method | Options |
| --- | --- | --- |
| `system info` | `system.info` | — |
| `window list` / `get` | `window.list` / `get` | `--window` |
| `window create` | `window.create` | `--name [--start]` |
| `window rename` | `window.update` | `--window --name --expected-revision` |
| `window reorder` | `window.reorder` | `--ids a,b,c --expected-revision` |
| `window focus` | `window.focus` | `--window` |
| `window close` | `window.close` | `--window --expected-revision [--allow-running --force]` |
| `tab list` / `get` | `tab.list` / `get` | `--window` / `--tab` |
| `tab create` | `tab.create` | `--window --title [--start]` |
| `tab rename` | `tab.update` | `--tab --title --expected-revision` |
| `tab color` | `tab.update` | `--tab --color <red\|orange\|yellow\|green\|blue\|purple\|gray\|none> --expected-revision` |
| `tab reorder` | `tab.reorder` | `--window --ids --expected-revision` |
| `tab focus` / `close` | `tab.focus` / `close` | `--tab [--expected-revision --allow-running --force]` |
| `pane split` | `pane.split` | `--pane --axis x\|y --ratio [--start]` |
| `pane resize` | `pane.resize` | `--branch --ratio --expected-revision` |
| `pane focus` / `maximize` / `close` | `pane.*` | `--pane [--restore] [--allow-running --force]` |
| `session get` | `session.get` | `--session` |
| `session start` / `restart` | `session.start` / `restart` | `--pane [--shell] [--process PATH --arg A … --directory DIR] [--host-launch ID] [--allow-running --force]` |
| `session input` | `session.sendInput` | `--session (--text T \| --base64 B) --mode literal\|paste` |
| `session execute` | `session.execute` | `--session --command CMD --submit` |
| `session output` | `session.readOutput` | `--session --view screen\|scrollback\|stream [--cursor C --max-bytes N]` |
| `host list` / `get` | `host.list` / `get` | `--query` / `--host` |
| `host create` / `update` / `delete` | `host.*` | `--name --destination --user --port --identity-file --tags`, plus `--host --expected-revision` |
| `host connect` | `host.connect` | `--host --window [--pane --axis]` |
| `layout validate` / `plan` / `apply` | `layout.*` | `FILE [--namespace NS] [--expected-revision N --start-new]` |
| `layout export` | `layout.export` | `--window …` (repeatable) |
| `events subscribe` | `events.subscribe` | `--topics resources,selection,session [--resource ID … --after-sequence N --instance ID]` |
| `theme list` / `get` / `export` / `delete` | `theme.*` | `--id ID [--resolved]` |
| `theme validate` / `import` | `theme.validate` / `import` | `FILE [--replace]` |
| `appearance get` / `set` | `appearance.*` | `--mode system\|dark\|light --light-theme ID --dark-theme ID --expected-revision` |
| `cli install-link` / `remove-link` / `uninstall-plan` | (local) | `--dir` (default `~/.local/bin`) |

The `cli` commands run locally and need no connection or credentials. `install-link` works only from the binary inside an app bundle. It creates exactly one symlink and never edits shell startup files.

`layout apply` needs `--expected-revision` (take it from `layout plan`), and `session execute` needs `--submit`. The CLI lets you leave them out, but the server rejects the call.

## Output

With `--json`, stdout always gets one stable envelope. ANSI color is never used, and diagnostics go to stderr.

```json
{"ok": true, "result": { … }}
{"ok": false, "error": {"code": "CONFLICT", "message": "…", "exitStatus": 5, "details": { … }}}
```

Without `--json`, success pretty-prints the result, and a failure prints `trellis: <message> (<code>)` to stderr.

`events subscribe` prints the subscribe envelope, then one raw notification per line until the connection closes. It then exits with 7 (`TRANSPORT`).

## Exit codes

| Exit | Meaning |
| --- | --- |
| 0 | Success |
| 2 | Argument or schema error (`-32700`, `-32600`, `-32602`, `INVALID_*`, including an invalid layout or theme) |
| 3 | Not found (`NOT_FOUND`, `-32601`) |
| 4 | Authentication or permission (`AUTH_REQUIRED`, `PERMISSION_DENIED`) |
| 5 | Conflict (`CONFLICT`, `CONFIRMATION_REQUIRED`) |
| 6 | Process launch failure (`LAUNCH_FAILED`) |
| 7 | App unavailable or transport failure (`APP_NOT_RUNNING`, `TRANSPORT`, `UNSUPPORTED_VERSION`) |
| 8 | Any other application error |

Exit 0 means the request was **accepted**. `session execute` succeeds once the input is submitted, even if the command itself later fails.

## Examples

```sh
TOKEN=~/.config/trellis/token   # owner-only file holding the grant token
t() { trellis "$@" --token-stdin --json < "$TOKEN"; }

t window list
t window create --name Project
t tab create --window Project --title Server
t pane split --pane PANE_UUID --axis x
t session start --pane PANE_UUID
t host connect --host HOST_UUID --window WINDOW_UUID
t layout plan ./project-layout.json --namespace project
t layout apply ./project-layout.json --namespace project --expected-revision 12
t session execute --session SESSION_UUID --command 'git status' --submit
t session output --session SESSION_UUID --view screen
t theme import ./my-theme.json
t appearance set --mode dark --dark-theme my-midnight
```

## Agent workflow (INT-06)

1. The user creates a scoped grant in **Settings → Automation**.
2. The agent authenticates and lists the windows it's allowed to see.
3. It validates, plans and applies a layout.
4. It explicitly starts approved sessions and subscribes to their state.
5. If its grant allows it, it reads output.
6. It sends explicit input, or runs a dedicated process and watches for `session.exit`.

When an agent disconnects, its sessions keep running. Trellis embeds no AI model, needs no provider API key, and never treats terminal output as instructions.
