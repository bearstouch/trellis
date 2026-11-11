# Migration from v1 (draft)

!!! warning "Draft contract — not implemented"
    Part of the proposed [protocol 2](index.md).

v2 is a **clean break**: the release that ships it speaks only protocol 2 on the socket, the CLI and MCP. Grants survive the upgrade; scripts and MCP configurations that call v1 methods must be updated. The release notes link this page.

## What happens on upgrade

- `grants.json` is migrated once to schema 2, after a backup (`grants.json.v1.bak`, mode 0600). Every grant keeps its token, expiry and scope; capabilities are mapped as below. New capabilities are **never** added: a v1 grant can do exactly what it did, and no more. Its preset is `custom`.
- Layout bindings in `layout-bindings.json` are kept; layout documents version 1 and 2 are still accepted by `layout.validate`/`plan`/`apply` and rewritten to version 3, except v1 `windows`, which is refused (it was already import-only).
- The CLI shipped in the same app speaks v2. An older `trellis` binary still installed elsewhere gets `UNSUPPORTED_VERSION` and should be re-linked with `trellis cli install-link`.
- MCP clients keep their URL and token; their tool list changes to the v2 tools on their next `tools/list`.

## Capabilities

| v1 | v2 |
| --- | --- |
| `metadata.read` | `workspace.read` |
| `layout.write` | `workspace.write` |
| `session.start`, `session.input`, `session.execute`, `session.output.read`, `session.close` | unchanged |
| `host.read`, `host.write`, `theme.read`, `theme.write` | unchanged |
| — | `agent.*`, `remote.*`, `project.*`, `task.*`: not granted to migrated grants |

## Methods

| v1 | v2 |
| --- | --- |
| `auth.authenticate {protocolVersion: 1}` | `{protocolVersion: 2}`; result has the full `grant` |
| `system.info` (`apiVersion`) | `system.info` (`protocolVersion`) |
| `window.*`, `windowId(s)` aliases | removed |
| `space.*` | same names; results wrapped (`{"space": …}`), lowercase IDs, `machine` and `project` fields |
| `space.reorder` → `{ids, revision}` | → `{spaces, revision}` |
| `tab.reorder` → space | → `{tabs, revision}` |
| `tab.update {title}` | `title: null` returns to the automatic title; `role` replaces `temporary` |
| `pane.*` tree nodes | panes are resources: `pane.list`, `pane.get`; `pane.split` takes `id` (was `paneId`) |
| `pane.close` (ignored `expectedRevision`) | honours it |
| `session.get` `launchKind` + flat fields | `launch {kind, …}`, `kept`, times; `waitingForInput`/`progress`/`shellIntegration` move to `pane.attention` and `pane.shell` |
| `launchKind: "host"` | `launch.kind: "ssh"` |
| `session.start {launch: {kind: "agent"}}` (refused in v1) | `agent.start` |
| `session.execute` | adds `wait` |
| `host.connect {hostId, spaceId, paneId?, axis?}` | `host.connect {hostId, placement}` |
| `host.list` (documented `tags`, not implemented) | `tags` implemented, pagination |
| `events.subscribe` topics `resources`, `session`, `selection`, `output`, `appearance` (+ aliases) | topics in [Events](events.md); `resources` → `workspace`; aliases removed; data is typed |
| — | `workspace.get`, `grant.get`, `events.poll`, `agent.*`, `remote.*`, `project.*`, `task.*`, `tab.duplicate`, `session.stop`, `workspace.save` |
| Empty-string IDs (`sessionId: ""`) | field omitted |
| Revisions as strings in events | numbers |

## CLI

The CLI keeps its shape (`trellis <noun> <verb>`), exit codes (now generated from the [error registry](index.md#errors-api2-03)) and token handling (`--token-stdin`, `--keychain-grant`; never argv). Changes:

- Removed: `window` noun, `--window`, `space focus --activate` (it never had an effect).
- `pane` verbs take `--pane` everywhere; `pane list`, `pane get` added.
- New nouns: `agent` (`list`, `runs`, `start`, `restart`, `respond`, `install`), `remote` (`open`, `status`, `reconnect`, `helper install|remove`), `project` (`list`, `get`, `create`, `update`, `delete`, `capture`, `check`, `launch`), `task` (`list`, `run`, `stop`, `get`), `grant` (`get`), `workspace` (`get`, `save`).
- `events poll` added beside `events subscribe`; `session execute --wait` prints the exit code and exits with it.
- `--space`, `--tab`, `--project`, `--host`, `--agent` resolve names server-side through filtered lists instead of listing everything.

## MCP

- Tools stay one per method, snake_case (`agent_respond`, `project_launch`, `events_poll`), filtered by the grant in `tools/list`.
- Schemas are generated from the method catalog, so the v1 drift (`space_create.name` not required, `session_restart` missing `force`, `theme_*` missing `documentText`, …) can't recur; a test compares them.
- `events_poll` replaces polling `session_get`; the `initialize` instructions point agents to `workspace_get` first and `events_poll` to wait.
- Annotations: read-only tools `readOnlyHint`; `destructiveHint` on close, stop, restart, delete, input, execute, `agent_respond`, `task_run`, `project_launch`, `remote_helper_*`; `openWorldHint` stays false.
- Result text items for untrusted content (output, program-set titles, task commands, agent-reported settings) start with the untrusted-data notice.

## Out of scope for v2

Kept UI-only for now: the scratchpad, the Files view, the Changes view and staging, desktop notifications, keyboard settings, Remote Control settings, saved passwords and trusting `launch.json`. They can be added later without another protocol break.
