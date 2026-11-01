# Coding agents

Trellis treats coding agents as first-class panes. Each pane header has an **Agent** button, next to **Tasks**, that opens Claude Code, pi or Codex in a new tab (or, with ⌥, in a split beside the pane), in the pane's folder and on the pane's machine. While the agent runs, its tab shows the agent's icon in place of the terminal icon, and a badge says what the agent is doing: **Working**, **Needs you**, **Done** or **Error**. If the agent isn't installed where the pane runs, Trellis offers to run the vendor's own installer, on this Mac or on a [remote workspace](remote-workspaces.md)'s host.

Agents are data: each is an `<id>.agent.json` definition. Trellis ships three, and you can add your own in the Agents folder. A shared agent registry is planned (see [Roadmap](../project/roadmap.md)) and will use the same format.

All requirements here are P1 (draft).

Library projects can name an agent per pane (`"agent": "trellis-claude-code"`), so launching a project opens its agents too ([FR-PL10](project-library.md)).

## Agent definitions

Built-in definitions live in the app bundle with the `trellis-` ID prefix, which is reserved. Your own go in the **Agents** folder in the Trellis state directory (Settings → Agents → **Reveal Agents Folder**), one file per agent, named `<id>.agent.json`.

```json
{
  "version": 1,
  "id": "aider",
  "name": "Aider",
  "executable": "aider",
  "arguments": [],
  "resumeArguments": ["--restore-chat-history"],
  "integration": "none",
  "icon": { "monogram": "A" },
  "install": {
    "darwin": { "command": "python3 -m pip install --user aider-install && aider-install", "requires": ["python3"] },
    "linux": { "command": "python3 -m pip install --user aider-install && aider-install", "requires": ["python3"] }
  },
  "homepage": "https://aider.chat"
}
```

| Field | Meaning |
| --- | --- |
| `version` | Always `1`. |
| `id` | Lower-case letters, digits and `-`, up to 64; the file name. |
| `name` | What menus, tabs and VoiceOver say; up to 60 characters. |
| `executable` | A command name looked up on the login shell's `PATH`, or an absolute path. Letters, digits and `._+-` only. |
| `arguments`, `resumeArguments` | Up to 32 single-line arguments each. `resumeArguments` continue the agent's last conversation (**Resume**). |
| `integration` | How the agent reports its state: `claude-hooks`, `codex-notify`, `pi-extension` or `none`. An unknown value from a newer build means `none`. |
| `icon` | One of `{"symbol": "<SF Symbol>"}`, `{"monogram": "<1–2 characters>"}` or `{"image": "<id>.svg"}` (SVG, PNG or PDF beside the definition, at most 32 KB). |
| `install` | Per platform (`darwin`, `linux`): the vendor's install `command`, one line, and the programs it `requires` on `PATH`. |
| `homepage` | An `https` link shown in the install sheet. |

The built-in agents:

| Agent | Executable | Live state through | Resume | Installer |
| --- | --- | --- | --- | --- |
| Claude Code | `claude` | Claude Code hooks, passed with `--settings` | `--continue` | `curl -fsSL https://claude.ai/install.sh \| bash` |
| pi | `pi` | A small extension loaded with `-e` | `--continue` | `npm install -g @mariozechner/pi-coding-agent` |
| Codex | `codex` | `notify` (set with `-c`), plus its bell and notifications for approvals | `resume --last` | `npm install -g @openai/codex` |

## How an agent starts

The agent runs in your login shell, so it gets the same `PATH` as a terminal: `<shell> -l -i -c 'exec env <executable> <wiring> <arguments>'`. zsh, bash and fish read their interactive startup files (`-i`), which is often where version managers put agents on `PATH`. csh and tcsh run the line in `/bin/sh -l`, since they take `-l` only alone. Every word is single-quoted, so the line reads the same in sh, bash, zsh, ksh and fish. Because the agent runs through `env`, a missing agent exits with status 127 and no shell-specific syntax is involved.

On a remote workspace's host, the host's Trellis helper runs the same line as its login shell's command (the mechanism of FR-RW18), so it needs a helper that speaks protocol 3.

## How state reaches the tab

Each agent session gets a nonce and the path of an owner-only socket in two environment variables, `TRELLIS_AGENT_NONCE` and `TRELLIS_AGENT_SOCKET`, set by Trellis only. The agent's own hooks run `trellis-broker agent-hook <event>`, which sends one datagram to that socket: `TRELLIS-AGENT-1 <nonce> <event>`, where the event is one of `start`, `working`, `needs-input`, `done`, `error` or `end`. Nothing else crosses: the hook's input (prompts, tool arguments) is read and discarded, and the command always exits 0 and prints nothing, so it can never block or steer the agent.

The process that owns the session receives it:

- The session broker, for sessions it keeps (the default). It maps the nonce to the session and sends `agentEvent` to the app only if the app said it can read one. It also keeps the last event, so a pane that re-attaches after a relaunch or a reconnect shows the state it missed.
- A remote workspace host's broker, for agents running there. The event travels over the existing SSH link.
- The app itself, for a session started without the broker, through a socket in a fresh owner-only folder.

The hook wiring is passed on the agent's command line and never written into your agent configuration:

- **Claude Code:** `--settings '<json>'` adds hooks. `UserPromptSubmit`, `PreToolUse` and `PostToolUse` mean working, `PermissionRequest` and the `permission_prompt` or `elicitation_dialog` notifications mean needs you, `Stop` means done and `StopFailure` means error. Your own settings and hooks still apply.
- **Codex:** `-c notify=["<helper>","agent-hook","done"]` reports each finished turn. Codex has no hook for a starting prompt or an approval, so pressing Return in the pane counts as working, and its bell or OSC 9 notification counts as needs you.
- **pi:** `-e trellis-pi-extension.ts` loads an extension that reports `agent_start`, `tool_call` and `agent_end`. On a remote host, Trellis writes it to `~/.trellis/agents/` first.
- **`none`:** only the terminal's own signals (FR-AG11).

## Requirements

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| FR-AG01 | Ship Claude Code, pi and Codex as built-in agent definitions. | Settings → Agents lists all three as **Built-in** with their live-state kind. Their IDs start with `trellis-`. Each has an installer for `darwin` and `linux` and resume arguments. |
| FR-AG02 | Load the user's own definitions from the Agents folder, strictly. | A valid `<id>.agent.json` appears in the Agent menu and in Settings → Agents, after the built-ins, in name order. A file whose name doesn't match its ID, that uses the `trellis-` prefix, that is malformed, over 16 KB, a symbolic link, or has an executable with anything but letters, digits and `._+-` (or a `..` part or a leading `-`), or a multi-line argument or install command is listed under **Files that couldn't be used** with the reason, and the other agents are unaffected. **Reload** reads the folder again. |
| FR-AG03 | Keep a newer definition usable. | An `integration` or `icon` this build doesn't know degrades to `none` and the default icon; an unknown schema `version` is refused with its number. |
| FR-AG04 | Run an agent pane in the pane's folder and on its machine. | The new pane's session is `launchKind: "agent"` with the agent's ID and folder. It starts in the source shell's authenticated directory, else the folder the source pane started in, else the default folder. In a remote workspace it runs on that window's host, in the folder its shell reported there. A local agent can't be put in a remote window, or a remote one in a local window. |
| FR-AG05 | Save agent panes without their command line. | The workspace file stores only the agent's ID, host and folder, never its arguments, hook wiring or `resume`. A workspace with an agent pane is saved as schema 3; one without is saved as before, so an older Trellis still opens it, and opens a schema 3 file read-only, never as corrupt. |
| FR-AG06 | Restore agent panes stopped, and offer Resume. | After relaunch an agent pane is stopped and shows **Start <agent>** and **Resume Last Conversation**; nothing runs or is typed by itself. An exited agent pane shows **Restart** and **Resume**. Resume starts the agent with its resume arguments. |
| FR-AG07 | An **Agent** button in each pane header opens an agent in a new tab. | Local shells and remote workspace panes show **Agent** after **Tasks**; agent panes show their agent and state, then **Agent**. The menu lists every agent with its status on that machine ("not installed, Install…" when a check or a launch found it missing), **Resume Last Conversation**, and **Add Agent Definition…**. Choosing an agent opens it in a new tab in the same window, selected; ⌥ opens it in a split to the right of the pane instead (with a maximized pane that asks you to restore panes first). The command palette's **Launch Agent…** lists the same agents for the focused pane: ↩ opens a new tab, ⌥↩ a split. |
| FR-AG08 | Carry agent state through a pane-scoped hook channel. | A session's own `agent-hook` reaches its pane; an event with another nonce, an unknown event or a malformed datagram changes nothing; more than 20 events a second from one session are dropped. `TRELLIS_AGENT_*` variables inherited from Trellis's own environment or supplied by automation never reach a session. The hook exits 0 and prints nothing in every case, including outside an agent session. An older remote helper ignores the request and the agent runs with FR-AG11 only. |
| FR-AG09 | Show the agent's icon in place of the terminal icon. | While an agent runs in a tab, the tab's leading icon is the agent's (its focused pane's agent, else its first running agent pane's), in the tab's color. It returns to the terminal icon when the agent exits. The sidebar hover card shows the same icon. An unusable icon file shows the default symbol and never blocks a launch. |
| FR-AG10 | Show the agent's state on the tab, in words. | The tab shows **Working**, **Needs you** or **Error** in a capsule with a symbol, never color alone, and it replaces the generic **Input** capsule. **Done** shows until the tab has been seen. With several agents in a tab, the most urgent wins: needs you, error, working, done. VoiceOver reads the tab as, for example, "Claude Code needs your input". The pane header shows the agent's name and state. The hover card shows the same badge. |
| FR-AG11 | Use the terminal's own signals where hooks say nothing. | In an agent pane, a bell, OSC 9/777/99 notification or password prompt means needs you, except right after the agent finished; OSC 9;4 progress means working; Return means working for agents without prompt hooks (Codex, `none`). Hook events always win. |
| FR-AG12 | Offer the vendor's installer when the agent is missing. | An agent that exits with 127 before any hook spoke opens a sheet naming the machine ("this Mac" or the host), the exact install command, what it needs on `PATH` (and, on this Mac, which of those is missing, which disables Install), and the vendor's page. **Cancel** runs nothing. **Install and Launch** runs `<install command> && <agent line>` in the same pane, in the login shell, visibly, without sudo; if the agent is still missing afterwards the sheet says so. Trellis never uploads or bundles an agent. |
| FR-AG13 | Report agents to automation. | `session.get` reports `launchKind: "agent"`, `agentId` and, while it runs, `agentState` (`ready`, `working`, `needsInput`, `done` or `error`), with the host (host-read) and folder (execute) under the usual rules. It never reports the agent's command line. |
| FR-AG14 | Notify when an agent needs you or finishes out of view. | With desktop notifications and Settings → Agents → **Notify me…** on, a hook's needs-you or done while the pane isn't visible posts "<agent> needs you" or "<agent> finished" with the tab's title, within the FR-T08 rate limit. Bells and OSC notifications keep their own FR-T08 notification, so none is posted twice. |

## Trust and safety

- A hook can only set its own pane's state. It gets no automation token, and the socket accepts nothing but an event name.
- Nothing from the conversation reaches Trellis: the hook's input is discarded, and no event carries text.
- Trellis never edits your agent configuration. Claude Code's hooks are passed on its command line, Codex's `notify` too, and pi's extension is a file in the app bundle (or under `~/.trellis/agents/` on a host).
- Installers are the vendors' own commands from the definition, shown in full before anything runs, and run in your shell where you can see and answer them. A definition in your Agents folder can name any installer, so only add definitions you trust.
- Trellis never interprets terminal output as instructions (INT-06); it only reads events from the hook channel and the terminal's existing signals.

## Known limits

- Claude Code's hooks need a version with `--settings` and the `PermissionRequest` hook; with an older one the tab falls back to FR-AG11.
- Codex reports only finished turns; "Working" comes from pressing Return, so Return in one of its menus can show Working until the next turn ends.
- pi has no approvals, so it never reports Needs you by itself.
- `zsh -i`, `bash -i` and `fish -i` read your interactive startup files before the agent starts; a startup file that waits for input holds the agent until you answer it in the pane.
- On a host, Trellis learns that an agent is missing only when a launch exits 127; it doesn't check ahead.
- A re-attached pane shows the last hook event the broker kept; Done then shows as seen.
- Automation can't yet start agent panes, list agents or subscribe to agent state (planned: `agent.list`, `launch.kind: "agent"`, an `agent.state` event).
- Per-agent extra arguments aren't configurable yet; add a definition of your own in the Agents folder instead.
