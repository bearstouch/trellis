# Declarative layouts

A layout document describes spaces, tabs and split trees, plus safe launch references. It is **data, not shell code**: a layout can't embed commands, and validating, planning or applying one never runs anything unless `layout.apply` is asked to start the panes it creates (`startNew: true`). A pane can name an agent from the agent catalog, which then runs as the app runs it; it still never carries a command line.

Projects in the [project library](../features/project-library.md) are a separate format for people; they can carry commands and repositories and are launched with [`project.launch`](methods.md#projects). A layout space can be bound to a library project with `projectId`.

- Schema: [`layout.schema.json`](layout.schema.json) (JSON Schema 2020-12)
- Example: [`example-layout.json`](example-layout.json). The tests apply it twice and check that the result is stable.

```json
{
  "version": 3,
  "spaces": [{
    "key": "project", "name": "Project",
    "tabs": [{
      "key": "development", "title": "Development",
      "root": {
        "type": "split", "key": "main-split", "axis": "x", "ratio": 0.6,
        "children": [
          {"type": "pane", "key": "editor", "title": "Editor", "launch": {"kind": "shell", "directory": "~/src/app"}, "agent": "trellis-claude-code"},
          {"type": "pane", "key": "server", "title": "Server", "launch": {"kind": "shell", "directory": "~/src/app"}}
        ]
      }
    }]
  }, {
    "key": "build-box", "name": "Build box",
    "machine": {"kind": "remote", "hostId": "6f1c…"},
    "tabs": [{"key": "remote-shell", "title": "Shell", "root": {"type": "pane", "key": "remote-pane", "launch": {"kind": "shell", "directory": "~"}}}]
  }]
}
```

## Document rules

| Element | Rules |
| --- | --- |
| `version` | `3`. Versions `1` and `2` are still accepted and read as version 3 (see [Older versions](#older-versions)); any other version is `UNSUPPORTED_VERSION`. `layout.export` writes version 3. |
| `spaces` | At most 10. Each has `key`, `name` (1–200 characters), 1–50 `tabs`, and optionally `machine` and `projectId`. |
| `machine` | `{"kind": "local"}` (the default) or `{"kind": "remote", "hostId"}`: a [remote workspace](../features/remote-workspaces.md) bound to that saved host (FR-RW01). Its shells run on the host, with paths there (FR-RW10). The host must be in the grant's host scope at its current connection. A space that already exists keeps its machine; declaring another remote host for it is a conflict (omitting `machine`, or `local`, keeps it as it is). |
| `projectId` | Binds the space to a [library project](../features/project-library.md) (FR-W08): its declared tabs become the project's tabs, and others in it read as temporary. The project must be in the grant's project scope and in the library. |
| `tab` | `key`, `title` (1–200 characters) and `root` |
| Node | Either `{type: "pane", key, title?, launch, agent?}` or `{type: "split", key, axis: x\|y, ratio: 0.1–0.9, children: [node, node]}` |
| `launch` | `{kind: "shell", directory?}` or `{kind: "ssh", hostId}` (a saved host, which must be in host scope). An ssh pane can't be in a remote space. |
| `agent` | An agent definition ID such as `trellis-claude-code`, only with a `shell` launch: the pane becomes that agent's pane (FR-AG04), started in the launch's directory on the space's machine. The agent must be in the grant's agent scope; an ID the catalog doesn't know is a warning (the pane says so when it starts, as a project's would). |
| Keys | 1–64 characters, matching `^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$`, and unique across the whole document |

The JSON Schema checks the document's shape. Service validation adds more checks: globally unique keys, nesting of at most 16 levels, at most 100 panes in total, hosts, projects and agents that exist and are in scope, the path rules, and authorization.

**Paths.**

- `~` is allowed only as the complete first path segment, and it expands to the home directory of the space's machine.
- Relative directories, variable interpolation and shell substitution are all rejected.
- Whether a directory exists is checked when the pane starts. Validation can run offline and only warns about missing directories.

### Older versions

Version 1 and 2 documents (`{"version": 2, "spaces": [...]}`) are read as version 3: a `{"kind": "host", "hostId"}` launch is read as `ssh`, and nothing else changes. `layout.validate` reports `upgradedFrom` (1 or 2) beside `version: 3`. A document that names its list `windows` (the original version 1 spelling) is refused as invalid, with an issue telling to rename it `spaces`.

## Validate, plan, apply

```sh
trellis layout validate ./project-layout.json --json
trellis layout plan ./project-layout.json --namespace project --json      # note baseRevision
trellis layout apply ./project-layout.json --namespace project --expected-revision 12 --json
```

1. **`layout.validate`** reports `valid`, `version`, `upgradedFrom?`, `errors` and `warnings` without changing anything. It needs workspace.read.
2. **`layout.plan`** shows the keyed changes and conflicts for a namespace, plus a `baseRevision`. A plan is advisory. It needs workspace.read.
3. **`layout.apply`** needs workspace.write and all-spaces scope, plus what the document asks for: session.start with `startNew`, remote.connect when a space has a remote `machine`, project.launch when a space has a `projectId`, and agent.control when a pane has an `agent`. A missing one is `PERMISSION_DENIED` with `details.missing`. `expectedRevision` is required and must equal the plan's `baseRevision`; if the workspace changed since the plan, the call returns `CONFLICT`. The model changes are validated and committed atomically, and any requested launches happen afterwards, each one independently. Apply isn't a transaction over process execution, and it never retries a launch.

The result is `{workspaceRevision, changed, mapping, creates, launches}`: `mapping` gives each key's `{kind, id}` (IDs lowercase), and with `startNew` each launch is `{key, paneId, session?, error?}`, where `session` is the session as `session.get` returns it and `error` an [error](index.md#errors-api2-03) `{code, message}`. Invalid documents are `-32602` with `details.issues: [{key?, message}]`.

## Matching and idempotency (FR-A04)

- Keys identify objects within a **namespace**; they aren't global IDs. Bindings from namespace and key to resource are stored in `layout-bindings.json`. Namespaces match the key pattern, so they never collide with the bindings project launches keep in the same file (`project:…`).
- Applying the same namespace and keys again matches the existing objects, even if their titles have changed. Applying the same document twice returns identical IDs, and starts and restarts nothing.
- A key can't change resource type, and a space can't change machine.
- Apply only adds and updates. Resources the document leaves out remain in place and are reported as unmanaged; nothing is deleted implicitly.
- Changed split ratios and order can update a live layout.
- Moving a pane to another tab, or changing a live pane's launch or agent, returns a conflict. To make that kind of change, close the pane and recreate it explicitly.
- New panes are created stopped unless you pass `startNew: true`. That starts only the panes this apply created; a pane in a remote space connects its host first, as `session.start` does. Existing stopped panes need an explicit start, so a retried apply can never run sessions again.

## Export

`layout.export {spaceIds?}` produces a version 3 document with fresh keys. Shell directories and pane `agent`s are included only for grants with session.execute; ssh hosts and a space's remote `machine` only with host.read and the host in scope; `projectId` only with project.read and the project in scope. Without them the output is marked `redacted` and `importable: false`: an inspection document that can't be applied as is. Runtime session IDs and environment values are never exported. Applying a document always assigns fresh UUIDs.
