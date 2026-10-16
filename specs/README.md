# uTerm specifications

Status: initial draft for review. Date: 2026-10-16. Implementation has not started.

uTerm is a native Swift terminal application for macOS, intended to replace iTerm2 for everyday local and SSH work. Its organizing hierarchy is **managed window → tab → pane → terminal session**. A left sidebar lists managed windows; selecting one reveals its tabs and terminal layout.

## Specification index

| Folder | Contents |
| --- | --- |
| [00-stories](00-stories/README.md) | Implementation plan, dependencies, acceptance criteria, and unit-test specifications |
| [01-overview](01-overview/README.md) | Product scope, vocabulary, priorities, milestones, and assumptions |
| [02-architecture](02-architecture/README.md) | Components, models, terminal engine, lifecycle, persistence, and decisions |
| [03-functional-requirements](03-functional-requirements/README.md) | User workflows, testable functional requirements, and [JSON themes](03-functional-requirements/themes/README.md) |
| [04-non-functional-requirements](04-non-functional-requirements/README.md) | Performance budgets, reliability, security, accessibility, and verification |
| [05-api](05-api/README.md) | Versioned local control protocol, CLI, errors, events, and declarative layouts |
| [06-integrations](06-integrations/README.md) | Shells, SSH, agents, clipboard, and integration boundaries |
| [07-macos-support](07-macos-support/README.md) | Native platform behavior, support policy, packaging, and release gates |

## Reading conventions

- MUST identifies a release requirement; SHOULD identifies a preferred behavior with a documented exception allowed.
- P0 is required for the MVP; P1 is a follow-up; P2 is exploratory.
- FR, NFR, API, INT, and MAC identifiers are stable references for implementation and acceptance checks.
- A design decision marked provisional is a planning choice, not a verified implementation claim.
- These documents define intended behavior. Performance targets and engine capabilities must be validated before release.

## Proposed defaults needing product validation

1. A “managed window” is a saved workspace in the sidebar. MVP has one native application window. Independent native windows and moving tabs between them are P1.
2. macOS 14 or later, with Apple silicon and Intel builds, is the provisional support baseline.
3. Distribution is a signed, notarized direct download. Mac App Store distribution is outside MVP.
4. SwiftUI provides application chrome; an AppKit terminal view provides terminal interaction. SwiftTerm is the provisional engine, subject to a compatibility spike.
5. Closing the application ends its local terminal processes. Reopening restores layouts as stopped sessions; it does not resurrect processes.
6. Automation uses a local Unix-domain socket and an accompanying `uterm` CLI. Remote network control and a built-in AI agent are outside MVP.

Implementation order and unresolved decisions are maintained in [the overview](01-overview/README.md). Changes to defaults must update the affected requirements and API examples together.

## Confirmed visual preferences

- **Native calm:** windows in the left sidebar, each with its own tab bar above the terminals; multiple tabs and inline renaming are required.
- The app starts with **light application chrome** and **dark terminal panes**; Dark and System appearance options remain available.
- Terminal panes have a **dark background by default**, including with light application chrome.
- **Monaco** is the default terminal font; users can change it in terminal settings.
