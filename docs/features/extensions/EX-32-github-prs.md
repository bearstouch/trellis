# EX-32: Bundled GitHub PRs extension

Part of the [Extensions specification](SPEC.md#stories). **Epic:** 7, CLI and first-party extension · **Phase:** 7 · **Requirements:** FR-EX26 · **Depends on:** [EX-13](EX-13-events.md), [EX-16](EX-16-terminal-panes.md), [EX-23](EX-23-sidebar-apps.md), [EX-25](EX-25-extension-tabs.md), [EX-26](EX-26-extension-modals.md), [EX-28](EX-28-oauth-device-flow.md) · **Points:** 8

**Definition.** As a Trellis user who works with GitHub, I want a bundled extension that lists the focused repository's pull requests and checks them out, so that I can follow reviews without leaving Trellis.

Trellis bundles `trellis-github-prs`, built only on the public API and the v1 components. It is the reference example and the proof that Tier 1 is enough: if something can't be built with the components, the component set grows. Like any extension, it is listed Disabled and needs the same approval.

## Scope

**In**

- Sidebar "Pull Requests": a `View` with a search bar and a segmented `Picker` (All, Mine, Review requested), and a `List` of `Row`s with title, `#number · author · updated`, a draft `Badge`, and review decision and checks as accessories in words with a tone. A selected row's detail shows `KeyValue` metadata (branch, base, reviewers, checks) and the body as `Markdown`.
- Tab "PR Board": the same data in `Section`s by review state.
- Modal "Check Out Pull Request": a `Form` with a `TextField` for the PR number or URL, a `Picker` for placement (new tab or split) and a primary Check Out button.
- Repository from `state.repository`: the `origin` remote on github.com, otherwise the first github.com remote. Follows focus. Outside a GitHub repository: an `EmptyState` "Not a GitHub repository" and no badge.
- Dock badge: PRs where your review is requested, tone `warning`.
- Row actions: Open in Browser (Return); Check Out (⌘↩), opening a terminal pane running `gh pr checkout <n>` if `gh` is installed, otherwise `git fetch origin pull/<n>/head:pr-<n> && git switch pr-<n>`, always prompting with the exact command; Copy Branch Name.
- Commands (unbound): "GitHub PRs: Refresh", "GitHub PRs: Open Board", "GitHub PRs: Check Out PR…" (opens the modal).
- Refresh on focus change, `repository.changed`, the Refresh command, and every 2 minutes while the sidebar is shown, with ETag conditional requests. The badge refreshes every 5 minutes even when the sidebar is hidden.
- Sign in with the GitHub device flow through a GitHub App with read-only access to pull requests, checks and metadata; no client secret, no redirect, no `repo` scope. An `EmptyState` with Sign In until signed in.
- Setting "Include drafts" (on by default).
- Manifest: permissions `workspace.read`, `git.read`, `terminal.open`, `clipboard.write`, `auth`, `storage`, `notifications`; network `https://api.github.com`; events `selection.pane`, `repository.changed`.

**Out**

- Registering the GitHub App. Bearstouch registers it, with the device flow enabled, to get the client ID; users install it on the accounts or organizations they want listed. This is a prerequisite outside the code.
- Any HTML or web view fallback.

## Acceptance criteria

- [ ] **Given** a fresh install, **when** I open Settings → Extensions, **then** GitHub PRs is listed as Disabled and loads from the app bundle.
- [ ] **Given** I enable it, **when** the approval sheet shows, **then** it lists the manifest's permissions, origin, events and the GitHub provider.
- [ ] **Given** a pane outside a GitHub repository is focused, **when** the sidebar shows, **then** it shows "Not a GitHub repository" and the dock has no badge.
- [ ] **Given** I'm not signed in, **when** the sidebar shows, **then** it shows an `EmptyState` with Sign In.
- [ ] **Given** a stubbed GitHub API, **when** the sidebar loads, **then** rows show title, number, author, updated, draft badge and checks in words, and the Picker filters All, Mine and Review requested.
- [ ] **Given** PRs with my review requested, **when** the badge updates, **then** it shows their count with tone `warning`.
- [ ] **Given** Check Out on a row, **when** I trigger it, **then** a prompt shows `gh pr checkout <n>` (or the `git fetch … && git switch …` line when `gh` is missing), and on Allow a terminal pane runs it.
- [ ] **Given** a refresh with an unchanged ETag, **when** it runs, **then** a conditional request is sent and the view keeps its data.
- [ ] **Given** the extension's manifest, **when** checked with `trellis extension check`, **then** it is valid.
- [ ] **(manual)** **Given** a real GitHub account with the App installed, **when** I sign in and use the sidebar, tab and modal end to end, **then** they behave as described. Stays **pending** until observed.

## Implementation notes

- New bundled resource: the `trellis-github-prs` extension in the app bundle's `Extensions/` folder, built from source in the repo and copied by `scripts/run-feasibility.sh` and both packaging scripts.
- Uses only the public API: `trellis.state`, `trellis.events`, `trellis.auth.fetch`, `trellis.terminal.open`, `trellis.clipboard.writeText`, `trellis.openURL`, `trellis.sidebar.setBadge`, `trellis.tabs.open`, `trellis.modals.open`, `trellis.storage`, `trellis.settings`.
- Depends on the remotes confirmation in EX-12.

## Tests

- `ExtensionCatalogTests`: the bundled extension loads, is read-only and starts Disabled.
- A fixture-driven test of the extension's views against a stubbed GitHub transport, through `ExtensionUIRendererTests` and `ExtensionFetchTests` / `ExtensionOAuthTests`.
