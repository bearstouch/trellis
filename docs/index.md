# Trellis documentation

Trellis is a native Swift terminal for macOS. It has light "Native calm" application chrome, dark terminal panes and bundled Roboto Mono as the default terminal font. Managed windows sit in a left sidebar, each window has its own renameable tabs, and every tab holds a tree of nested splits. Saved SSH hosts, JSON themes and a local automation API with a `trellis` CLI are built in.

These pages are the behavior contract for Trellis and the guide for anyone working on it. When the code and these docs disagree, treat it as a bug in one of them. Fix the code, or update the docs in the same change if the behavior is meant to change.

## Where to start

| If you want to… | Read |
| --- | --- |
| Understand what Trellis is and what it deliberately doesn't do | [Product overview](overview/product.md) |
| See what's finished and what's still pending | [Status and known limits](overview/status.md) |
| Build, run and test the app | [Getting started](development/getting-started.md) |
| Learn the rules every change must follow | [Development rules](development/rules.md) |
| Find your way around the code | [Architecture](architecture/index.md) |
| Script Trellis or build an agent on top of it | [Automation API](api/index.md) and [CLI](api/cli.md) |
| Write a theme | [Themes](features/themes.md) |
| Cut a release | [Release guide](release/README.md) |

## Map of the docs

- **Overview:** [product](overview/product.md) and [status](overview/status.md).
- **Architecture:** [modules and components](architecture/index.md), [domain model](architecture/domain-model.md), [sessions and processes](architecture/sessions.md), [persistence](architecture/persistence.md) and the [terminal engine](architecture/terminal-engine.md).
- **Features:** [workspace](features/workspace.md), [terminal](features/terminal.md), [SSH hosts](features/ssh-hosts.md), [themes](features/themes.md) and [keyboard and accessibility](features/keyboard-accessibility.md).
- **Automation API:** [overview and transport](api/index.md), [authorization](api/authorization.md), [methods](api/methods.md), [output and events](api/output-events.md), [errors](api/errors.md), [layouts](api/layouts.md) and the [CLI](api/cli.md).
- **Platform:** [integrations](integrations.md) and [macOS support](platform/macos.md).
- **Development:** [getting started](development/getting-started.md), [rules](development/rules.md), [testing](development/testing.md), [contribution workflow](development/workflow.md) and the [release guide](release/README.md).
- **Project:** [roadmap and decisions](project/roadmap.md).

## Conventions

- **MUST** marks a requirement. **SHOULD** marks a preferred behavior; an exception is allowed if it is documented.
- **P0** is the MVP, **P1** is the next follow-up and **P2** is exploratory.
- Requirement IDs are stable. The prefixes are `FR` (functional), `API`, `INT` (integrations) and `MAC` (macOS).
- A requirement passes only once it has been observed working. A dependency claiming to support something doesn't count, and checks that couldn't be run are recorded as **pending**.

## Building this site

The pages are plain Markdown, laid out for [MkDocs](https://www.mkdocs.org/) with the Material theme. `mkdocs.yml` at the repository root defines the navigation.

```sh
python3 -m venv .venv-docs && .venv-docs/bin/pip install mkdocs-material
.venv-docs/bin/mkdocs serve      # live preview at http://127.0.0.1:8000
.venv-docs/bin/mkdocs build      # static HTML in site/
```
