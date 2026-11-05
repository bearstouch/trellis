# Welcome tour

A short tour introduces Trellis the first time it opens. It floats over the workspace as an eight-step dialog: an illustration on the left, a few lines of text on the right, a step counter, **Skip Tour** and page dots. The last step offers the settings most people want to choose first.

The steps are: Welcome to Trellis; Windows, tabs and splits; Sessions keep running; Start a project in one step; Remote work that holds on; Coding agents, built in; Everything, from the keyboard; and Make it yours.

All requirements here are P2.

## Requirements

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| FR-ON01 | Show the tour once, on a fresh install. A launch that finds no saved workspace opens it over the first window; a launch that finds one, as after an upgrade, never does. Either way the answer is remembered in the `welcomeTour.seen` user default, so quitting midway doesn't bring it back. | With no state and no default, the tour opens at launch. Relaunch: it doesn't. With a saved workspace and no default: it doesn't open, and it still doesn't if the workspace is later deleted. |
| FR-ON02 | Scripted, isolated and damaged launches are left alone. `--fixture` and `--state-directory` launches, and a launch showing workspace recovery, don't open the tour and don't record an answer. | `python3 scripts/qualify.py --quick` never sees the tour. After recovery, the tour isn't open and `welcomeTour.seen` is unset. |
| FR-ON03 | Replay it at any time from **Help → Welcome Tour** and the command palette. Replaying starts at step 1 and changes nothing by itself. | Both open step 1, also in an isolated launch. If the main window is hidden, the menu item brings it back. Neither is available while the workspace is restoring or showing recovery. |
| FR-ON04 | The tour is modal over the workspace. While it's open, terminal input is suspended and the workspace's menu shortcuts are disabled. A click on the backdrop does nothing. Sessions keep running, and sheets such as a task review still appear above it. | Typing and ⌘V never reach a shell, typing never reaches the scratchpad editor, and ⌘D and ⌘F do nothing behind it, also while another window such as Settings is key, where ⌘W still closes that window. A pane created by automation while it's open takes no input until it closes. Every pane takes input again after it closes, unless a tab rename is still in progress. |
| FR-ON05 | Move through it with **Start Tour**/**Next**, **Back**, the page dots, ← and →, and Return. Esc and **Skip Tour** close it. **Start Using Trellis** closes it on the last step. Closing returns keyboard focus to the active pane. Skip Tour isn't shown on the last step, where Esc still closes it and keeps the choices made there. | Each control reaches the expected step. ← does nothing on step 1, and → does nothing on step 8. Arrow keys on a focused control, such as the appearance picker with Full Keyboard Access, stay with that control. Keys pressed while a sheet is open go to the sheet. |
| FR-ON06 | The last step sets **Appearance** (System, Dark or Light) and **Keep sessions running after quit** directly, through the same settings as the Settings window. Each change applies at once and is saved, and closing the tour doesn't undo it. | Choose Light: the app and tour turn light right away, and it's still light after a relaunch. Turn off the switch: Settings → Sessions shows **Stop sessions when Trellis quits** on. |
| FR-ON07 | The last step also installs the command line tool with the MAC-15 rules. The row appears only when the MAC-15 offer would ask, or as **Installed** when the link already exists. | A development build or a run from the DMG shows no row. **Install** creates the one link and reports its result like the menu item. See MAC-15 for how the tour replaces the first-launch sheet. |
| FR-ON08 | The dialog fits the window and the theme. It's 900 by 560 points when there's room, hides the illustration in a small window and the page dots where the footer has no room for them, and scrolls its text so the footer is always reachable. It uses the current theme's colors and terminal palette, and shows the current shortcut bindings. | At the 400 by 260 minimum window size, every step can be read and left. Rebind ⌘D: step 2 shows the new chord. Unbind it: step 2 points to the Pane menu instead. |
| FR-ON09 | Accessible by default. The dialog is a modal container with a heading on each step. The illustrations are hidden from VoiceOver, each dot is a button named for its step, and a step change is announced. Reduce Motion removes the step animation, and Increase Contrast strengthens the borders and backdrop. | Automated tests check the step names and key handling. A VoiceOver pass is **pending**. |

## Notes

The tour never stores what you do in it, beyond `welcomeTour.seen` and the settings you choose on the last step. Its illustrations are drawn in code with sample text; nothing in them comes from your sessions.
