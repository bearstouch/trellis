# Declarative layouts

A layout document describes windows, tabs and split trees, plus safe launch references. It is **data, not shell code**. A layout can't embed commands, and validating or applying one never runs anything; starting work is always a separate, explicit API call (`NFR-S07`).

- Schema: [`layout.schema.json`](layout.schema.json) (JSON Schema 2020-12)
- Example: [`example-layout.json`](example-layout.json). The tests apply it twice and check that the result is stable.

```json
{
  "version": 1,
  "windows": [{
    "key": "project", "name": "Project",
    "tabs": [{
      "key": "development", "title": "Development",
      "root": {
        "type": "split", "key": "main-split", "axis": "x", "ratio": 0.6,
        "children": [
          {"type": "pane", "key": "editor", "title": "Editor", "launch": {"kind": "shell", "directory": "~"}},
          {"type": "pane", "key": "server", "title": "Server", "launch": {"kind": "shell", "directory": "~"}}
        ]
      }
    }]
  }]
}
```

## Document rules

| Element | Rules |
| --- | --- |
| `version` | Must be `1` |
| `windows` | At most 10. Each has `key`, `name` (1–200 characters) and 1–50 `tabs`. |
| `tab` | `key`, `title` (1–200 characters) and `root` |
| Node | Either `{type: "pane", key, title?, launch}` or `{type: "split", key, axis: x\|y, ratio: 0.1–0.9, children: [node, node]}` |
| `launch` | `{kind: "shell", directory?}` or `{kind: "host", hostId}` |
| Keys | 1–64 characters, matching `^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$`, and unique across the whole document |

The JSON Schema checks the document's shape. Service validation adds more checks: globally unique keys, nesting of at most 16 levels, at most 100 panes in total, valid host references, the path rules, and authorization.

**Paths.**

- `~` is allowed only as the complete first path segment, and it expands to the current user's home directory.
- Relative directories, variable interpolation and shell substitution are all rejected.
- Whether a directory exists is checked when the pane starts. Validation can run offline and only warns about missing directories.

## Validate, plan, apply

```sh
trellis layout validate ./project-layout.json --json
trellis layout plan ./project-layout.json --namespace project --json      # note baseRevision
trellis layout apply ./project-layout.json --namespace project --expected-revision 12 --json
```

1. **`layout.validate`** reports errors and warnings without changing anything. It needs `metadata.read`.
2. **`layout.plan`** shows the keyed changes and conflicts for a namespace, plus a `baseRevision`. A plan is advisory.
3. **`layout.apply`** needs `layout.write` and all-windows scope, and `expectedRevision` must equal the plan's `baseRevision`. If the workspace changed since the plan, the call returns `CONFLICT`. The model changes are validated and committed atomically, and any requested launches happen afterwards, each one independently. Apply isn't a transaction over process execution, and it never retries a launch.

## Matching and idempotency (FR-A04)

- Keys identify objects within a **namespace**; they aren't global IDs. Bindings from namespace and key to resource are stored in `layout-bindings.json`.
- Applying the same namespace and keys again matches the existing objects, even if their titles have changed. Applying the same document twice returns identical IDs, and starts and restarts nothing.
- A key can't change resource type.
- Apply only adds and updates. Resources the document leaves out remain in place and are reported as unmanaged; nothing is deleted implicitly.
- Changed split ratios and order can update a live layout.
- Moving a pane to another tab, or changing a live pane's launch descriptor, returns a conflict. To make that kind of change, close the pane and recreate it explicitly.
- New panes are created stopped unless you pass `startNew: true`. That starts only the panes this apply created, and needs `session.start`. Existing stopped panes need an explicit start, so a retried apply can never run sessions again.

## Export

`layout.export` produces a portable document with fresh keys. Launch details are included only for grants with execute permission, and host references only for grants with host-read permission. Without them, the output is marked as a redacted inspection document that can't be imported. Runtime session IDs and environment values are never exported. Importing a document always assigns fresh UUIDs.
