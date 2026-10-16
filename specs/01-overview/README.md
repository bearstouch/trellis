# Product overview

## Purpose

Build a focused native macOS terminal that makes many concurrent local and SSH sessions easy to organize and operate. Trellis should replace the user's everyday iTerm2 workflow through fast keyboard navigation, reliable terminal emulation, easy copy/paste, nested splits, reusable hosts, and first-class script and agent control.

“Replace iTerm2” describes the intended daily workflow, not full compatibility with every iTerm2 feature or configuration format.

## Users and workflows

- A developer keeps separate managed windows for projects and switches between their tabs without losing running processes.
- An operator opens saved SSH hosts, uses adjacent panes to inspect multiple machines, and reconnects explicitly after failure.
- A script creates a project workspace with named tabs, working directories, and a repeatable split layout.
- An authorized agent discovers stable IDs, reads explicitly permitted output, opens sessions, and sends commands through the same application services used by the UI.

## Vocabulary and product model

| Term | Definition |
| --- | --- |
| Native window | An operating-system application window. MVP has one terminal-bearing native window. |
| Managed window / workspace | Persistent named sidebar item containing an ordered collection of tabs. UI label: “Windows”; API resource: `window`. |
| Tab | Named container for a binary split tree and its active pane. |
| Pane | A visible terminal leaf in a tab; owns exactly one terminal session. |
| Session | One PTY-backed local process, typically a login shell or the system SSH client. |
| Host | Saved SSH connection metadata; it is not a running session or a credential store. |
| Profile | Reusable appearance and launch defaults. MVP includes one default profile. |
| Layout | Declarative, versioned description of windows, tabs, and pane trees. |

A window has at least one tab; a tab has at least one pane. The application may have zero windows and show a welcome screen. Selecting another managed window or tab does not stop its sessions. There is no global terminal broadcast input in MVP.

## Scope and priority

| Priority | Features |
| --- | --- |
| P0 / MVP | Sidebar windows; tabs; nested left/right and top/bottom splits; local shell; SSH hosts; native selection and clipboard; built-in dark/light and custom JSON themes; terminal search; keyboard navigation; saved layouts; local CLI/API; explicit automation grants; bounded output reading; import/export of layouts and hosts |
| P1 | Multiple native windows; drag tabs across windows; multiple profiles; optional shell integration with command completion events; richer host import; signed update mechanism; optional MCP adapter |
| P2 | Session broker for surviving application exit, tmux awareness, richer terminal protocols, plugin ecosystem |

Excluded from MVP: Windows/Linux/iOS support, cloud synchronization, web UI, remote API server, embedded AI provider, embedded SSH implementation, file transfer, serial ports, full iTerm2 preference import, and replay of arbitrary commands on restore.

## Primary interaction

Chosen visual direction: **Native calm**. The left sidebar lists managed windows. Selecting one shows its own ordered tab bar above the terminal area; each window supports multiple tabs. Selecting a tab restores its terminal layout and last focused pane. The tab bar has visible separators, a new-tab button, and a rename action. Double-clicking a tab label edits its name inline; Enter commits, Escape cancels, and an empty name preserves the previous title. Renaming never restarts a session or changes its stable ID. Light application appearance is the first-launch default; users may choose Dark or System. The sidebar, title bar, tab bar, and other application controls stay light by default. Terminal panes remain dark by default in either appearance and use Monaco. Hosts opens a searchable list with connect/edit actions; connecting creates a new tab by default, with an explicit option for a new split.

Use “Split Left/Right” and “Split Top/Bottom” in menus. API `axis: x` means left/right; `axis: y` means top/bottom. This avoids the ambiguity of “vertical split.”

The [implementation story plan](../00-stories/README.md) breaks the MVP into independently verifiable stories with dependencies, acceptance criteria, and unit-test cases.

## Milestones and release evidence

1. **Terminal feasibility:** embed the candidate terminal engine; verify a PTY shell, resizing, Unicode/IME, selection, clipboard, alternate-screen applications, accessibility, and resource cleanup. Record results and dependency license. Resolve engine choice before building a large shell around it.
2. **Organization:** implement windows, tabs, split tree, focus, process lifecycle, and restoration of stopped layouts.
3. **Daily use:** complete SSH host workflows, search, clipboard behavior, settings, shortcuts, and unsaved-work warnings.
4. **Automation:** implement shared commands, authenticated socket, CLI, output/event bounds, layout validation/application, and permission enforcement.
5. **Release qualification:** run the acceptance matrix on supported architectures and macOS versions; sign and notarize the app; publish known limitations.

MVP exits only when every P0 requirement is demonstrated. No requirement is considered passed because a dependency advertises it.

## Open decisions

| Decision | Proposed default | Decision gate |
| --- | --- | --- |
| Meaning of windows | Sidebar workspaces in one native window | Product review before UI implementation |
| Terminal engine | SwiftTerm behind a narrow adapter | Feasibility milestone |
| Minimum macOS and CPU support | macOS 14+, Apple silicon and Intel | Build and dependency feasibility |
| Default scrollback | 10,000 lines, bounded additionally by bytes | Memory measurements |
| Agent authorization UX | User-created grants with resource scope | Automation UX review |
| Application identity | Trellis working name | Before signing and release |

## Definition of done

A user can organize two projects, open local and saved SSH sessions, create nested splits, copy and paste safely, switch between running tabs, close sessions with appropriate warnings, and restore a stopped layout. A script can build the same workspace, discover its IDs, observe permitted output, and explicitly run a command, with documented results and errors.
