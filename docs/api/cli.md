# The `trellis` CLI

`trellis` is a structured client for the [automation API](index.md). It speaks protocol 2 only. Its code is in `Sources/TrellisCLI`, with the executable in `Sources/TrellisCLIMain`.

| Context | How to run it |
| --- | --- |
| Development | `swift run trellis-cli …` |
| Packaged app | `Trellis.app/Contents/Helpers/trellis`, optionally linked onto your `PATH` from the app (**Trellis → Install Command Line Tool…**) or with `trellis cli install-link` (see the [release guide](../release/README.md#installing)) |

## Usage

```text
trellis <noun> <verb> [options]
trellis help [<noun> [<verb>]]
trellis --version
```

- `trellis --help` (or `-h`, or `trellis help`) lists the nouns, options and exit codes. `trellis <noun> --help` lists a noun's verbs, and `trellis <noun> <verb> --help` gives that command's synopsis and options.
- Each command calls one [method](methods.md). Its help is generated from the method catalog: the summary, the method it calls, what the call needs (capabilities and scope) and the errors it can return. Only the synopsis and the flag texts are the CLI's own, and a test checks every catalog method has a command (`events.unsubscribe` is the one exception: a subscription ends with the CLI's connection).
- Help and `--version` (or `-V`) print to stdout and exit with 0. They need no running app or credentials, never read standard input, and are plain ASCII text of at most 80 columns.
- An argument error prints the message and a `Try 'trellis … --help'` line to stderr, naming the narrowest help that applies, and exits with 2. Running `trellis` with no arguments is an argument error. A flag a command can't run without is checked before anything is sent.
- A value that follows an option is always that option's value, so `--command --help` passes the text `--help`.
- Options take the form `--opt VALUE`. The `--opt=value` form is rejected.
- Every command except `cli …` needs credentials, from exactly one of:
    - `--token-stdin`: read the token from standard input.
    - `--keychain-grant GRANT_UUID`: read the token from the Keychain.
- The CLI always rejects `--token`, `--password` and `--secret`, because command lines leak into process lists and shell history. A rejected value is never echoed.
- `--launch` starts the app (`open -b com.bearstouch.trellis`) if it isn't already running. Without it, a missing app gives `APP_NOT_RUNNING`.
- `--state-directory DIR` points the CLI at a development instance started with the same flag.
- The convention flags follow each method's declaration: `--idempotency-key KEY` where the method is mutating, `--expected-revision N` where it takes `expectedRevision`, and `--limit N` / `--cursor C` on paginated lists.
- The CLI never retries anything on its own.
- Replies time out after 120 seconds; a call that waits on the app (`session execute --wait`, `events poll --timeout-ms`) gets its own wait on top, and one that may wait on a host, the person or a project's setup (`remote open`/`reconnect`/`helper`, `project check` on a host, `project launch` on a host or with `--setup`) gets 15 minutes on top, the setup's own bound. A reply timeout closes the connection, which cancels the call in the app. Event streams have no timeout.

### Names

`--space`, `--tab`, `--host`, `--project` and `--agent` accept an ID or an exact name, resolved by the app through filtered lists rather than by listing everything:

| Flag | Resolved with |
| --- | --- |
| `--space NAME` | `space.list {name}` |
| `--tab TITLE` | `tab.list {spaceId, title}`, in `--space` when given, otherwise in each space in scope |
| `--host NAME` (also `--ssh`, `--target`, `--machine`) | `host.list {query}`, then an exact name match |
| `--project NAME` | `project.list {query}`, then an exact name match |
| `--agent ID\|NAME` | `agent.get {id}`; if there is no such ID, `agent.list` and an exact name match |

Lookups follow `nextCursor` to the end. A name that matches several resources exits with 2 (use the ID); no match exits with 3; a lookup the grant may not make keeps its own status (4). Panes, sessions and branches are always UUIDs. Every lookup runs before the command's own call, so a failed one changes nothing.

## Commands

| Command | Method | Options |
| --- | --- | --- |
| `system info` | `system.info` | — |
| `grant get` | `grant.get` | — |
| `workspace get` | `workspace.get` | `[--include tabs,panes,sessions,agents,layout]` |
| `workspace save` | `workspace.save` | — |
| `space list` | `space.list` | `[--name NAME]` |
| `space get` / `focus` | `space.get` / `focus` | `--space` |
| `space create` | `space.create` | `--name [--start]` |
| `space rename` | `space.update` | `--space --name` |
| `space reorder` | `space.reorder` | `--ids a,b,c` |
| `space close` | `space.close` | `--space [--allow-running] [--force]` |
| `tab list` | `tab.list` | `--space [--title T] [--layout]` |
| `tab get` / `focus` | `tab.get` / `focus` | `--tab [--space]` |
| `tab create` | `tab.create` | `--space [--title] [--color] [--start]` |
| `tab rename` | `tab.update` | `--tab (--title T \| --automatic-title)` |
| `tab color` | `tab.update` | `--tab --color <red\|orange\|yellow\|green\|blue\|purple\|gray\|none>` |
| `tab duplicate` | `tab.duplicate` | `--tab [--start]` |
| `tab reorder` | `tab.reorder` | `--space --ids` |
| `tab close` | `tab.close` | `--tab [--allow-running] [--force]` |
| `pane list` | `pane.list` | `--tab` or `--space` |
| `pane get` / `focus` | `pane.get` / `focus` | `--pane` |
| `pane split` | `pane.split` | `--pane --axis x\|y [--ratio] [--start]` |
| `pane resize` | `pane.resize` | `--branch --ratio` |
| `pane maximize` | `pane.maximize` | `--pane [--restore]` |
| `pane close` | `pane.close` | `--pane [--allow-running] [--force]` |
| `session get` | `session.get` | `--session` |
| `session start` / `restart` | `session.start` / `restart` | `--pane`, and one of `--shell [--directory DIR]`, `--process PATH --directory DIR [--arg A]…`, `--ssh HOST`; `--env KEY=VALUE` (repeatable) with a shell or process; restart also `[--allow-running] [--force]` |
| `session stop` | `session.stop` | `--session [--force]` |
| `session input` | `session.sendInput` | `--session (--text T \| --base64 B) [--mode literal\|paste]` |
| `session execute` | `session.execute` | `--session --command CMD [--wait [--timeout-ms N]]` |
| `session output` | `session.readOutput` | `--session --view screen\|scrollback\|stream [--cursor C] [--max-bytes N]` |
| `agent list` | `agent.list` | `[--machine local\|HOST]` |
| `agent get` | `agent.get` | `--agent` |
| `agent runs` | `agent.runs` | `[--space] [--state ready\|working\|needsInput\|done\|error]` |
| `agent start` | `agent.start` | `--agent`, one placement, `[--directory DIR] [--resume]` |
| `agent install` | `agent.install` | `--agent`, one placement |
| `agent restart` | `agent.restart` | `--session [--resume]` |
| `agent respond` | `agent.respond` | `--session --action approve\|reject\|reply [--text T] [--expected-state S]` |
| `host list` | `host.list` | `[--query TEXT] [--tags a,b]` |
| `host get` / `delete` | `host.get` / `delete` | `--host` |
| `host create` | `host.create` | `--name --destination [--user] [--port] [--identity-file] [--tags]` |
| `host update` | `host.update` | `--host` plus any of the create fields |
| `host connect` | `host.connect` | `--host`, and one of `--space SPACE` (a new tab), `--split PANE [--axis x\|y]`, `--new-space [--name NAME]` |
| `remote open` | `remote.open` | `--host [--name NAME] [--start]` |
| `remote status` | `remote.status` | `--host` |
| `remote reconnect` | `remote.reconnect` | `--host [--interactive]` |
| `remote helper install` | `remote.helper.install` | `--host` |
| `remote helper remove` | `remote.helper.remove` | `--host [--stop-sessions]` |
| `project list` | `project.list` | `[--query TEXT]` |
| `project get` / `delete` | `project.get` / `delete` | `--project` |
| `project create` | `project.create` | `FILE` (the library's JSON form) |
| `project update` | `project.update` | `FILE --project` |
| `project capture` | `project.capture` | `--space --name` |
| `project check` | `project.check` | `--project --target local\|HOST [--folder DIR]` |
| `project launch` | `project.launch` | `--project --target local\|HOST [--folder DIR] [--setup]` |
| `task list` / `get` | `task.list` / `get` | `--pane` |
| `task run` | `task.run` | `--pane --task ID` |
| `task stop` | `task.stop` | `--pane [--force]` |
| `layout validate` | `layout.validate` | `FILE` |
| `layout plan` | `layout.plan` | `FILE --namespace NS` |
| `layout apply` | `layout.apply` | `FILE --namespace NS --expected-revision N [--start-new]` |
| `layout export` | `layout.export` | `[--space SPACE]…` (repeatable) |
| `theme list` | `theme.list` | — |
| `theme get` / `export` / `delete` | `theme.*` | `--id ID` (or `--theme ID`); export `[--resolved]` |
| `theme validate` / `import` | `theme.validate` / `import` | `FILE`; import `[--replace]` |
| `appearance get` / `set` | `appearance.*` | `[--mode system\|dark\|light] [--light-theme ID] [--dark-theme ID]` |
| `events subscribe` | `events.subscribe` | `[--topics T,…] [--resource ID]… [--space SPACE]… [--after-sequence N] [--instance ID]` |
| `events poll` | `events.poll` | `[--topics T,…] [--space SPACE]… [--after-sequence N] [--instance ID] [--timeout-ms N] [--limit N]` |
| `cli install-link` / `remove-link` / `uninstall-plan` | (local) | `[--dir DIR]` (default `~/.local/bin`) |

The placements of `agent start` and `agent install` are `--space SPACE` (a new tab), `--split PANE [--axis x|y]` (a split beside that pane) or `--pane PANE` (a pane that isn't running). Give exactly one. `--target` and `--machine` take `local` for this Mac or a saved host's ID or exact name (a host named `local` needs its ID). `--task` takes the ID `task list` shows (`file:NAME`, `detected:NAME`). Theme files go to the app as text (`documentText`), so its validator sees duplicate keys. Without `--topics`, `events subscribe` and `events poll` follow `workspace,selection,session`; see [Events](events.md) for every topic.

The `cli` commands run locally and need no connection or credentials. `install-link` works only from the binary inside an app bundle. It creates exactly one symlink and never edits shell startup files.

## Waiting for a command

`session execute --wait` sends `wait: {until: "finished"}` (with `timeoutMs` from `--timeout-ms`, 1–600,000, default 30,000) and needs shell integration in the pane. It prints the result, then **exits with the command's own exit code**:

| Result | Exit |
| --- | --- |
| The command finished | its exit code (0 when the shell reported none, for a line that ran no command) |
| `timedOut: true`: the wait ended first; the command keeps running | 124, error `TIMED_OUT` (as `timeout(1)`) |
| `sessionEnded: true`: the session ended or the pane closed first | 125, error `SESSION_ENDED` |

With `--json`, a finished command prints `{"ok": true, "result": {…, "exitCode": N}}` and exits with `N`; 124 and 125 print an error envelope whose `details` is the result. Without `--wait`, exit 0 means the line was **submitted**, not that the command succeeded.

## Output

With `--json`, stdout always gets one stable envelope. ANSI color is never used, and diagnostics go to stderr.

```json
{"ok": true, "result": { … }}
{"ok": false, "error": {"code": "CONFLICT", "message": "…", "exitStatus": 5, "retryable": false, "details": {"currentRevision": 8}}}
```

An application error keeps the app's `code`, `retryable` and `details`; a parameter error (`INVALID_PARAMS`) keeps `data.fields` as `details`. Without `--json`, success pretty-prints the result, and a failure prints `trellis: <message> (<code>)` to stderr.

With `--json`, help and version use the same envelope: `{"ok": true, "result": {"help": "…"}}` or `{"ok": true, "result": {"version": "…"}}`. The `Try …` line is left out of `--json` errors.

`events subscribe` prints the subscribe envelope, then one `events.event` notification per line until the connection closes. It then exits with 7 (`TRANSPORT`); resume with `--instance` and `--after-sequence`. `events poll` prints one poll result (`events`, `nextSequence`, `instanceId`, `gap?`) and exits.

## Exit codes

Application errors map through the [error registry](index.md#errors-api2-03) (`APIErrorCode.cliExitStatus`); the CLI's own failures use the same numbers.

| Exit | Meaning |
| --- | --- |
| 0 | Success (with `session execute --wait`, the command's exit code) |
| 2 | Arguments or schema: `INVALID_ARGUMENTS`, JSON-RPC `-32700`, `-32600`, `-32602`, an invalid layout or theme (`INVALID_LAYOUT`, `INVALID_THEME`), `INVALID_CURSOR`, `UNSUPPORTED_VERSION` |
| 3 | Not found: `NOT_FOUND`, `-32601` |
| 4 | Authentication, permission or trust: `AUTH_REQUIRED`, `PERMISSION_DENIED`, `TASK_UNTRUSTED` |
| 5 | Conflict or state: `CONFLICT`, `INVALID_STATE`, `CONFIRMATION_REQUIRED`, `CLOSE_PENDING`, `SETUP_REQUIRED` |
| 6 | Launch: `LAUNCH_FAILED`, `AGENT_UNAVAILABLE` |
| 7 | App or link unavailable: `APP_NOT_RUNNING`, `TRANSPORT`, `REMOTE_DISCONNECTED` |
| 8 | `LIMIT_EXCEEDED`, a code this CLI doesn't know, and any other failure |
| 124 / 125 | `session execute --wait` stopped waiting / the session ended first |

## Examples

```sh
TOKEN=~/.config/trellis/token   # owner-only file holding the grant token
t() { trellis "$@" --token-stdin --json < "$TOKEN"; }

t workspace get --include tabs,panes
t space create --name Build --start
t tab create --space Build --title Server
t pane split --pane PANE_UUID --axis x
t session start --pane PANE_UUID --shell --directory ~/code/app
t session execute --session SESSION_UUID --command 'swift test' --wait
t session output --session SESSION_UUID --view screen
t agent start --agent trellis-claude-code --space Build
t agent respond --session SESSION_UUID --action approve
t events poll --topics agent,attention --timeout-ms 20000
t host connect --host build-box --new-space
t remote open --host build-box --start
t project launch --project Trellis --target local --setup
t task run --pane PANE_UUID --task 'detected:swift: build'
t layout plan ./project-layout.json --namespace project
t layout apply ./project-layout.json --namespace project --expected-revision 12
t appearance set --mode dark --dark-theme my-midnight
```

## Agent workflow (INT-06)

1. The user creates a scoped grant in **Settings → Automation** (a preset is the quickest).
2. The agent authenticates and reads everything it may see with `workspace get`.
3. It validates, plans and applies a layout, or launches a project.
4. It starts approved sessions or agents, and waits with `events poll` (or `session execute --wait`) instead of polling.
5. If its grant allows it, it reads output and answers agents that need input with `agent respond`.

When an agent disconnects, its sessions keep running. Trellis embeds no AI model, needs no provider API key, and never treats terminal output as instructions.

## Changes from protocol 1

The CLI shipped with the app speaks only protocol 2 ([Migration](migration.md)):

- Removed: the `window` noun and `--window` (use `space` and `--space`), and `space focus --activate`, which never had an effect. Each is refused with what replaced it.
- `session start`/`restart --host-launch HOST` is now `--ssh HOST` (the launch kind is `ssh`); `session execute --submit` is gone (the line is always submitted) and `--wait` was added.
- `host connect` takes one placement: `--space` (new tab), `--split PANE [--axis]` (was `--pane`) or `--new-space [--name]`.
- Every pane verb takes `--pane`; `pane list` and `pane get` were added.
- New nouns: `workspace`, `grant`, `agent`, `remote`, `project`, `task`; new verbs `tab duplicate`, `session stop`, `events poll`.
- Exit codes come from the error registry: `INVALID_STATE` and `CLOSE_PENDING` are now 5, `UNSUPPORTED_VERSION` and `INVALID_CURSOR` 2, `REMOTE_DISCONNECTED` 7.
- Names resolve through filtered lists (`space.list {name}`, `tab.list {title}`, `host.list {query}`, `project.list {query}`).
- An app that publishes another protocol never gets the token: the CLI stops with `UNSUPPORTED_VERSION` (exit 2) and says to update Trellis or use the `trellis` inside the running app. An older `trellis` binary still installed elsewhere gets `UNSUPPORTED_VERSION` from the app; re-link it with `trellis cli install-link`, run from the new Trellis.app.
