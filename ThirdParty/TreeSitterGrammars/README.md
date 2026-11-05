# Vendored tree-sitter grammars

The tool dock's editor highlights files with tree-sitter (see `docs/features/tool-dock.md`). Most grammars are remote
SwiftPM packages pinned in `Package.swift`. These two are vendored because their upstream manifests leave out
`scanner.c` when SwiftPM evaluates them, which fails to link.

| Grammar | Upstream | Version | Commit | License |
| --- | --- | --- | --- | --- |
| JavaScript | `tree-sitter/tree-sitter-javascript` | v0.25.0 | `44c892e0be055ac465d5eeddae6d3e194424e7de` | MIT (`JavaScript/LICENSE`) |
| YAML | `tree-sitter-grammars/tree-sitter-yaml` | v0.7.2 | `7708026449bed86239b1cd5bce6e3c34dbca6415` | MIT (`YAML/LICENSE`) |

Copied unchanged from each tag: `src/parser.c`, `src/scanner.c` (and YAML's `src/schema.*.c`, which `scanner.c`
includes), `src/tree_sitter/`, `queries/`, the Swift binding header (moved to `include/`) and `LICENSE`. Only
`Package.swift` is Trellis's own.

To update: replace those files from the new tag, update the table, and rebuild. Drop a grammar from here once its
upstream manifest lists `scanner.c` unconditionally, and depend on its package instead.
