# Public docs (bearstouch.com/trellis/docs)

End-user documentation for Trellis, built by `scripts/build-public-docs.sh` from `mkdocs.public.yml`.

- `pages/` holds the user guide: the home page, getting started and one page per feature. A file here replaces the
  `docs/` page at the same path, so cross-links between the guide and the reference resolve the same way.
- The automation reference (`docs/api/`) is published straight from the contract; `hooks.py` strips requirement IDs,
  requirement/verification sections and ID tables from it.
- `overrides/` is the Material theme override that keeps every page within the landing site's CSP.

`docs/` stays the behavior contract and the source of truth. When a user-visible behavior changes there, update the
matching page in `pages/` in the same change.

## Writing the user guide

Write for someone who uses Trellis, not for someone who builds or tests it.

- **Task first.** Explain what a feature is for in a sentence or two, then how to use it: where it is (menu, button,
  shortcut, setting), what happens, and what to do when something goes wrong. Use second person ("you") and the
  present tense. Short paragraphs, `##` sections named after tasks or things ("Split a pane", "Saved passwords").
- **No contract language.** No requirement IDs (`FR-…`, `API-…`, `INT-…`, `MAC-…`), no MUST/SHOULD, no acceptance
  checks, no P0/P1/P2, no "pending" or verification notes, no internal type, module or file names unless the user
  types or sees them (a settings file path, a CLI command, a JSON key in a theme or tasks file).
- **Only what ships.** Describe behavior the contract states as implemented. Leave out anything marked pending,
  unimplemented, planned or roadmap. If `CHANGELOG.md` shows a feature first shipped in the latest minor version, open its
  section with `!!! note "New in 1.2"` (with that version); drop the notes a release or two later.
- **Exact UI names.** Menu items, buttons, settings and shortcuts in **bold** exactly as the app shows them
  (**File → Projects…**, **Settings → Automation**). Shortcuts as `<kbd>⌘</kbd><kbd>D</kbd>`. Check menu titles and
  shortcuts against the code (`Sources/TrellisApp/AppMain.swift`, `Sources/TrellisUI`) when the contract is unclear.
- **Limits users hit.** Keep limits and safety behavior a user will notice (size caps, confirmations, what is never
  saved, what needs a permission), phrased as facts about the app, in a short "Limits" or "Privacy" section.
- **Formats stay precise.** Where users write files (tasks, agents, themes, layouts), keep the format tables and
  examples, minus requirement columns.
- **Links.** Link other guide pages and the reference with relative links (`ssh-hosts.md`, `../api/cli.md`). Don't
  link contributor pages (architecture, development, status, roadmap).
- Use admonitions sparingly (`!!! tip`, `!!! warning`). Match the tone of bearstouch.com: plain, calm, specific.
