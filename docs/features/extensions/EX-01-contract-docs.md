# EX-1: Contract docs, schemas and example fixture

Part of the [Extensions specification](SPEC.md#stories). **Epic:** 1, Foundations · **Phase:** 1 · **Requirements:** Enabler · **Depends on:** None · **Points:** 5

**Definition.** As an extension author and a Trellis developer, I want the extension contract written down as docs pages, JSON schemas and a working example before any code lands, so that every later story builds against one agreed behaviour.

The spec becomes the contract pages the repo already uses for other features. Phase 1 is documentation only. It turns this draft into the feature page, the API page and the UI component reference, adds the schemas and an example extension that tests read as a fixture, and records what is deferred.

## Scope

**In**

- `docs/features/extensions.md`: the behaviour contract, with requirement IDs FR-EX01–FR-EX29 and their acceptance checks.
- `docs/api/extensions.md`: the JavaScript API, error codes, state paths and events.
- `docs/api/extension-ui.md`: the UI schema v1 component reference.
- `docs/api/extension-manifest.schema.json` and `docs/api/extension-ui.schema.json`.
- An example fixture extension in `docs/extensions/example/`.
- Updates to `mkdocs.yml`, the right sidebar page, `docs/api/permissions.md` (the new `git.read`, `terminal.open` and `clipboard.write` permissions), `docs/api/methods.md` (`extension.list`, `extension.reload`), `docs/api/events.md` (`agent.state`, `task.state`, `repository.changed`), the error table in `docs/api/index.md` (the new codes) and `docs/project/roadmap.md` (the deferred list).

**Out**

- Any Swift code. Fixtures are read by tests from EX-2 and EX-19 onwards.
- Deciding the open questions. They stay listed in the feature page until answered.

## Acceptance criteria

- [ ] **Given** the docs site, **when** I run the MkDocs build, **then** the new pages are in the nav and every internal link resolves.
- [ ] **Given** `docs/features/extensions.md`, **when** I read it, **then** it lists FR-EX01–FR-EX29 with the same acceptance checks and phases as this specification.
- [ ] **Given** the error table in `docs/api/index.md`, **when** I search it, **then** it defines `PERMISSION_DENIED`, `PROMPT_DENIED`, `PROMPT_LIMIT`, `NETWORK_NOT_DECLARED`, `USER_GESTURE_REQUIRED`, `EXTENSION_SUSPENDED`, `NOT_SIGNED_IN` and `AUTH_FAILED`.
- [ ] **Given** the example fixture in `docs/extensions/example/`, **when** I validate its `package.json` against `docs/api/extension-manifest.schema.json`, **then** it passes.
- [ ] **Given** a render tree in the API docs, **when** I validate it against `docs/api/extension-ui.schema.json`, **then** it passes, and the schema lists exactly the 21 v1 components.
- [ ] **Given** `docs/api/events.md`, **when** I read it, **then** `agent.state`, `task.state` and `repository.changed` are documented for automation clients too.
- [ ] **Given** `docs/project/roadmap.md`, **when** I read it, **then** the Deferred list from this specification is recorded there.

## Implementation notes

- New pages: `docs/features/extensions.md`, `docs/api/extensions.md`, `docs/api/extension-ui.md`, both schemas and `docs/extensions/example/`.
- Existing pages to update: `docs/features/sidebar.md`, `docs/api/permissions.md`, `docs/api/methods.md`, `docs/api/events.md`, the error table in `docs/api/index.md`, `docs/project/roadmap.md` and `mkdocs.yml`.
- Follow the style of `docs/features/sidebar.md` and `docs/features/agents.md`: short sentences, a requirements table with acceptance checks.
- Once the contract pages exist, this `SPEC.md` either becomes a pointer to them or is removed, and the stories link to the new pages.

## Tests

- No new test suite. The fixture is read by `ExtensionManifestTests` (EX-2) and the UI examples by `ExtensionUIRendererTests` (EX-19, EX-20).
- The MkDocs build must succeed with the new nav.
