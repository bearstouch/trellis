# Coding agents

Trellis runs coding agents such as Claude Code, pi and Codex in panes of their own and shows on the tab what each one is doing: working, waiting for you, done or failed. You can leave several agents working in different tabs and spaces and see at a glance which one needs you.

Claude Code, pi and Codex are built in. You can add any other terminal-based agent with a small definition file.

## Open an agent

Agents are one of the views of the [right sidebar](sidebar.md). Open it with the sparkles icon in the dock on the window's right edge, with **View → Show Agents**, or with <kbd>⌥</kbd><kbd>⌘</kbd><kbd>A</kbd>.

The top of the view says where agents will open: the focused pane's folder and machine. Agents open on the same machine as the focused pane, so in a [remote workspace](remote-workspaces.md) they run on that host. The view works for panes on this Mac and in remote workspaces, including agent panes; the icon is dimmed for SSH panes.

Choose where the agent goes:

- **New Tab** (the default) opens it in a new tab in the same space and selects it.
- **This Tab** runs it in the focused pane itself, in place of its shell.
- **Split** opens it in a new pane to the right of the focused pane. If a pane is maximized, Trellis asks you to restore the panes first.

Trellis remembers your choice while it runs, but not after you quit. Then click an agent's play button to open it, or its circular-arrow button to resume its last conversation. <kbd>⌥</kbd>-clicking the play button uses **Split** when **New Tab** is selected, and **New Tab** otherwise.

You can also use **Launch Agent…** in the [command palette](command-palette.md): <kbd>↩</kbd> opens the agent in a new tab, <kbd>⌥</kbd><kbd>↩</kbd> in a split beside the focused pane.

A [project](project-library.md) can open agents too: set a pane's **Runs** to an agent, and launching the project opens it there.

!!! note "New in 1.2"
    The Agents view in the right sidebar, with its **Running** list, replaces the **Agent** button in pane headers, and **This Tab** is new.

### Open an agent in this tab

**This Tab** is offered only while no agent is starting or running in the focused tab; otherwise it is hidden and the play button uses **New Tab**.

A stopped, exited or failed pane is reused straight away. A running shell is replaced only while it is waiting at its prompt with no command or task running, which Trellis knows through [shell integration](shell-integration.md). Trellis first asks **Replace this shell with <agent>?**, since any background or stopped jobs in that shell end with it. **Cancel** leaves everything as it was. If the shell is busy, or has no shell integration, nothing is ended and Trellis suggests finishing the command or using a new tab.

## What the tab shows

While an agent runs, its tab shows the agent's icon in place of the terminal icon: Claude Code's mark in its orange, the OpenAI mark for Codex, and a π for pi. The icon goes back to the terminal icon when the agent exits.

| Tab | Meaning |
| --- | --- |
| A light moving along the tab's top edge, and a breathing icon | The agent is working. |
| **Needs you** | The agent is waiting for your input or an approval. |
| **Done** | The agent finished its turn. It shows until you've seen the tab. |
| **Error** | The agent's turn failed. |

**Needs you**, **Done** and **Error** appear as a word with a symbol, never as a color alone, and VoiceOver reads the tab as, for example, "Claude Code needs your input" or "Claude Code working". Hovering the icon shows "<agent>: Working". With Reduce Motion on, the working edge is a still bar and the icon holds a steady glow. With several agents in one tab, the most urgent state wins: needs you, then error, working and done.

The dock's Agents icon shows a badge with the number of agents that need you, in every space. A program's own progress report in the terminal still shows its progress bar on the tab.

### Running agents

The **Running** list in the Agents view shows every agent pane in every space, in space and tab order: its icon and name, its tab and space, and its state in words (**Ready**, **Needs you**, **Done**, **Error**, or the session's status when it isn't running). A working agent shows a small spinner. Choosing a row takes you to that pane, switching space and tab.

For Claude Code, the row also shows the model in place of the agent's name ("Ardaven · Opus 5.5") and the reasoning effort as a small label next to the tab name (`high`). They appear once Claude Code reports them: the effort with its first tool call or finished turn, and the model when Claude Code includes it or after you switch models with `/model`. Trellis reads only these two settings from Claude Code, nothing from your conversation.

### Notifications

With desktop notifications allowed and **Settings → Agents → Notify me when an agent needs me or finishes while its pane is out of view** on, Trellis posts "<agent> needs you" or "<agent> finished" when that happens in a pane you can't see. The notification's subtitle names the space and tab.

## Agents you type in a shell

When you type `claude`, `codex` or `pi` (or any agent's command) at a prompt, the tab shows that agent's icon and its title becomes "<agent> · <folder>" while it runs. A tab you renamed keeps its name. Everything goes back when the command finishes.

In a zsh, bash or fish pane on this Mac with shell integration, Trellis also wires the agent up so it reports its state: the tab shows working, **Needs you** and **Done**, notifications work, and the Running list shows it, marked "in a shell". Trellis does this with a shell function named after the agent's command that exists only in that pane's shell.

- A function or alias of the same name that you define yourself wins.
- `command claude` runs the agent without the wiring.
- Turn it off with **Settings → Agents → Connect agents typed in a shell**. The change applies to shells started afterwards.

A typed agent stays an ordinary shell command: it isn't saved with the workspace, and **Start**, **Resume** and the installer offer don't apply to it.

!!! note "New in 1.2"
    Agents typed in a shell now report **Working**, **Needs you** and **Done**, and appear in the Running list.

## Restore and resume

Agent panes are saved with your workspace by agent, host and folder only, never with their command line. After you relaunch Trellis, an agent pane is stopped and offers **Start <agent>** and **Resume Last Conversation**; nothing runs by itself. An agent pane that has exited offers **Restart** and **Resume**. Resume starts the agent with its resume arguments, so it continues its last conversation.

## When an agent isn't installed

If the agent's program isn't found where the pane runs, Trellis opens a sheet that names the machine ("this Mac" or the host), shows the vendor's exact install command, what it needs on your `PATH` (on this Mac, also which of those are missing), and the vendor's page.

- **Install and Launch** runs the install command and then the agent in the same pane, in your login shell, where you can see and answer it. It never uses `sudo`. If the agent is still missing afterwards, the sheet says so.
- **Cancel** runs nothing.

Trellis never uploads or bundles an agent. In the Agents view, an agent found missing shows **Not installed** with **Install…**.

## The built-in agents

| Agent | Command | Live state through | Resume | Installer |
| --- | --- | --- | --- | --- |
| Claude Code | `claude` | Claude Code hooks, passed with `--settings` | `--continue` | `curl -fsSL https://claude.ai/install.sh \| bash` |
| pi | `pi` | A small extension loaded with `-e` | `--continue` | `npm install -g @mariozechner/pi-coding-agent` |
| Codex | `codex` | `notify` (set with `-c`), plus its bell and notifications for approvals | `resume --last` | `npm install -g @openai/codex` |

Their IDs are `trellis-claude-code`, `trellis-pi` and `trellis-codex`. **Settings → Agents** lists them as **Built-in**, with how each reports its state.

### How an agent starts

The agent runs through your login shell, so it gets the same `PATH` as a terminal, including version managers set up in your interactive startup files. Trellis runs `<shell> -l -i -c 'exec env <command> <wiring> <arguments>'`; with csh or tcsh, it uses `/bin/sh -l` instead. On a remote workspace host, the host's Trellis helper runs the same line.

The wiring that lets an agent report its state is passed on its command line. Trellis never edits your agent configuration:

- **Claude Code** gets extra hooks through `--settings`. Your own settings and hooks still apply.
- **Codex** gets `notify` through `-c`, which reports each finished turn. Codex has no hook for a new prompt or an approval, so pressing Return in its pane counts as working, and its bell or notification counts as needs you.
- **pi** loads a small extension with `-e`. On a remote host, Trellis puts it in `~/.trellis/agents/` first.

Where the agent says nothing, Trellis uses the terminal's own signals: a bell, a desktop notification or a password prompt means it needs you, and a progress report means it is working.

## Add your own agent

Your own agents are definition files in the **Agents** folder in Trellis's state folder. Open it with **Settings → Agents → Reveal Agents Folder**, or **Add Agent Definition…** in the Agents view. Each agent is one file named `<id>.agent.json`:

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
| `id` | Lower-case letters, digits and `-`, up to 64 characters. It must match the file name, and can't start with `trellis-`, which is reserved for the built-ins. |
| `name` | What menus, tabs and VoiceOver say; up to 60 characters. |
| `executable` | A command name looked up on your login shell's `PATH`, or an absolute path. Letters, digits and `._+-` only, with no `..` part and no leading `-`. |
| `arguments`, `resumeArguments` | Up to 32 single-line arguments each. `resumeArguments` continue the agent's last conversation (**Resume**); without them the agent has no Resume button. |
| `integration` | How the agent reports its state: `claude-hooks`, `codex-notify`, `pi-extension` or `none`. With `none`, Trellis relies on the terminal's own signals, and pressing Return counts as working. |
| `icon` | One of `{"symbol": "<SF Symbol>"}`, `{"monogram": "<1–2 characters>"}` or `{"image": "<id>.svg"}` (an SVG, PNG or PDF file beside the definition, at most 32 KB), drawn in the tab's color. Add `"fullColor": true` to draw an image in its own colors. |
| `install` | Per platform (`darwin` for macOS, `linux`): the vendor's install `command`, one line, and the programs it `requires` on `PATH`. |
| `homepage` | An `https` link shown in the install sheet. |

Valid definitions appear in the Agents view, the command palette and **Settings → Agents**, after the built-ins, in name order. A file that can't be used, because it is malformed, over 16 KB, a symbolic link, named differently from its `id`, or has a multi-line argument or install command, is listed in **Settings → Agents** under **Files that couldn't be used** with the reason; your other agents are unaffected. **Reload** reads the folder again.

A definition written for a newer Trellis keeps working: an `integration` or `icon` this version doesn't know falls back to `none` and the default icon. An unknown `version` is refused. An icon file that can't be used shows the default symbol and never stops the agent from opening.

## Trust and safety

- Trellis never edits your agent configuration. Claude Code's hooks and Codex's `notify` are passed on the command line, and pi's extension is a file that ships with Trellis (or lives in `~/.trellis/agents/` on a host).
- The channel an agent uses to report its state can only set its own pane's state. It carries an event name and nothing else: no prompt, tool argument or other text from the conversation reaches Trellis, and it gives the agent no access to Trellis's automation.
- Trellis never treats terminal output as instructions. It only reads the agent's state reports and the terminal's usual signals.
- Installers are the vendors' own commands from the definition, shown in full before anything runs, and run in your shell where you can see and answer them. A definition in your Agents folder can name any installer, so only add definitions you trust.

## Limits

- Claude Code needs a version that supports `--settings` and the `PermissionRequest` hook for live state; with an older one, the tab relies on the terminal's own signals.
- Codex reports only finished turns. **Working** comes from pressing Return, so pressing Return in one of its menus can show working until the next turn ends.
- pi has no approvals, so it never reports **Needs you** by itself.
- Your interactive shell startup files run before the agent starts. One that waits for input holds the agent until you answer it in the pane.
- On a remote host, Trellis learns that an agent is missing only when it fails to start; it doesn't check ahead.
- After Trellis reconnects to a pane that kept running, the tab shows the agent's last reported state; **Done** then counts as seen.
- Automation reports an agent pane and its state (see [Methods](../api/methods.md)), but can't yet start agent panes or list agents.
- Extra arguments per agent aren't configurable; add a definition of your own instead.
- Typed agents are recognised by the program name alone. `npx claude` and `cd x && claude` aren't recognised, and neither is an alias in zsh or fish (bash reports the expanded command, so an alias works there). An agent started over `ssh`, in a nested shell or resumed with `fg` isn't recognised either. Another program with the same name, such as a different `pi`, shows that agent's icon, and gets its wiring arguments through the shell function; run it with `command pi` or turn the setting off.
- A typed agent gets live state only on this Mac, with the setting on, in a shell started after it was turned on, and when your own function or alias doesn't take its place. Otherwise a bell shows the generic **Input** badge, as for any program. Open the agent from the Agents view to get live state there.
