# Spaces, tabs and panes

Trellis organizes your terminals in three levels. A **space** is an entry in the left sidebar. Each space has its own row of **tabs**, and each tab can be split into several **panes**, each running its own terminal session.

Most of the time a space is what a [library project](project-library.md) becomes when you launch it: the project's tabs open in it, and you can add tabs of your own next to them. You can also create a space that stands alone, with no project.

!!! note "New in 1.2"
    Spaces were called *windows* in earlier versions. The macOS **Window** menu keeps its name, and "window" in this guide means the Trellis window itself.

## Spaces

### Create a space

Choose **File → New Space** (<kbd>⌘</kbd><kbd>N</kbd>) or click the **New Space** button in the sidebar. If you close every space, Trellis shows a welcome screen with a **New Space** button.

### Switch, rename, reorder and delete spaces

- Click a space in the sidebar to select it, or use **Window → Next Space** (<kbd>⌃</kbd><kbd>⌘</kbd><kbd>]</kbd>) and **Window → Previous Space** (<kbd>⌃</kbd><kbd>⌘</kbd><kbd>[</kbd>).
- Right-click a space for **Rename…**, **Move Up**, **Move Down** and **Delete Space…**. **File → Rename Space…** and **File → Delete Space…** do the same for the selected space.
- Drag a space onto another to reorder them. The dragged space takes the place of the one you drop it on, and an accent bar shows where it will land. Reordering never restarts anything.

Each space remembers its selected tab and focused pane, so switching back puts the keyboard where you left it.

### Sessions in other spaces keep running

Switching spaces doesn't pause anything. Programs in the spaces you're not looking at keep running, and the sidebar marks a space with:

- a dot when there's new terminal output,
- a stop symbol when a session exited,
- a keyboard symbol when a pane is waiting for input or a password.

Hover over a marker to see what it means.

### Collapse the sidebar

Choose **View → Hide Sidebar** (<kbd>⌃</kbd><kbd>⌘</kbd><kbd>S</kbd>), or click the sidebar button, to shrink the sidebar to a narrow rail. Each space then shows as a square with its initials: the first letters of its first two words, or the first two characters of a one-word name. The selected space has a border, and the activity and exit markers stay visible.

- Click a square to select the space. Right-click it for the same **Rename…**, **Move** and **Delete** choices.
- Hover over a square to see a card with the space's full name and its tabs, in order, with their live status (pane counts, **Input** or **Password**, **exit N**, **Exited**, busy). Click a tab in the card to jump straight to it.
- Drag squares to reorder spaces, as in the full sidebar.

**View → Show Sidebar** brings the full sidebar back. Trellis remembers the choice across relaunches.

## Project tabs and temporary tabs

!!! note "New in 1.2"
    Spaces remember their project, and tabs you add to them are temporary.

When you launch a [library project](project-library.md), its space remembers the project. The sidebar row shows a folder symbol, and the project's name if it differs from the space's.

Tabs the project defines are its own. Any other tab you open in that space (a new tab, a duplicate, or a tab for a host or agent) is **temporary**: its title is shown in italics, and VoiceOver reads "temporary tab". Temporary tabs are yours for this piece of work:

- Launching the project again keeps them where they are, still temporary.
- They never become part of the project, and nothing you do in the space changes the project.
- They're kept when you quit and relaunch Trellis.

A space with no project has no temporary tabs. If you delete the project, its spaces keep all their tabs, none of them temporary, and the folder symbol goes away.

## Tabs

Each space has its own tab bar above the terminal area, with its own order and selection.

### Open and switch tabs

- **File → New Tab** (<kbd>⌘</kbd><kbd>T</kbd>) or the **New Tab** button at the end of the tab bar opens a tab in the selected space.
- Click a tab, use <kbd>⌘</kbd><kbd>1</kbd> to <kbd>⌘</kbd><kbd>9</kbd> to jump to a tab by position, or **Window → Next Tab** (<kbd>⇧</kbd><kbd>⌘</kbd><kbd>]</kbd>) and **Window → Previous Tab** (<kbd>⇧</kbd><kbd>⌘</kbd><kbd>[</kbd>).

### Rename a tab

Double-click the tab's name, or right-click it and choose **Rename…** (also **File → Rename Tab…**). Press <kbd>Return</kbd> to keep the new name or <kbd>Esc</kbd> to cancel. Leaving the name empty keeps the old one. Renaming never restarts the tab's sessions.

### Color a tab

Right-click a tab and choose a **Color**: red, orange, yellow, green, blue, purple or gray. **None** removes it. A colored tab gets a stripe along its top edge, a light tint and a tinted icon. Hover over the stripe to see the color's name; VoiceOver reads it with the tab. The color is kept across relaunches, and a duplicated tab keeps it.

You can also set it from the command line with `trellis tab color` (see the [CLI](../api/cli.md)).

### Duplicate a tab

Right-click a tab and choose **Duplicate Tab**. The new tab gets the same splits and launch settings with fresh sessions. It copies no output and nothing you typed.

### Reorder tabs

Drag a tab along the tab bar. It takes the place of the tab you drop it on, and an accent bar shows where it will land. You can also right-click a tab and choose **Move Left** or **Move Right**. Reordering never restarts anything. While you're renaming a tab, dragging inside the name selects text instead.

### Close a tab

Choose **File → Close Tab** (<kbd>⇧</kbd><kbd>⌘</kbd><kbd>W</kbd>), click the tab's close button, or right-click it and choose **Close Tab…**. If anything is still running, Trellis asks first (see [Closing running sessions](#closing-running-sessions)). Closing a space's last tab closes the space.

## What a tab tells you

Tabs show what their panes are doing, in words and symbols as well as color:

- **Printing output.** A bar fills and unfills along the tab's top edge while any of its panes prints output, and stops shortly after it goes quiet. Typing echo doesn't count. Programs that redraw on a timer, such as `top` or `watch`, keep it on. With Reduce Motion on, the bar is static.
- **Waiting for you.** An **Input** label appears on the tab when a program in it needs you:
    - a **password prompt** (from `sudo`, `ssh`, `read -s` and the like), which also shows **Password** in the pane header until you answer it, even if the tab is selected;
    - a **bell** or a **notification** from a program in a pane you're not looking at. It clears when you show and focus that pane, at the shell's next prompt, or when the session ends.
- **Progress.** Programs that report progress (the ConEmu / Windows Terminal progress sequence) fill the tab's top edge to the percentage, and the tab and pane header read "50%", "Paused 50%", "Error" or "Working". An error shows red and a pause orange. Progress clears when the program removes it, after 15 seconds without an update, at the next prompt, or when the session ends.

[Coding agents](agents.md) show their own state on the tab instead.

## Bell and desktop notifications

**Settings → Appearance → Bell** chooses what a bell does in a pane: **Sound** (the macOS alert sound, the default), **Visual flash**, **Sound and flash**, or **Off**. Whatever you choose, a bell in a pane you're not looking at still labels its tab.

Programs can also ask for a desktop notification (iTerm2's OSC 9, rxvt's OSC 777 `notify`, or kitty's OSC 99). Trellis shows it in Notification Center when you're not looking at that pane: Trellis isn't the front window, or the pane isn't the focused pane of the selected tab. The notification's subtitle says where it came from, such as "api › Build · make": the space and tab, followed by the program's name when Trellis knows it. It never shows a command line. Click the notification to bring Trellis forward on that pane.

macOS asks for permission the first time. To turn notifications off, clear **Settings → Sessions → Desktop notifications**; tabs still get their **Input** label. With [shell integration](shell-integration.md), a long command that finishes out of view can notify you too.

Notification text comes from terminal output, so Trellis cleans it: control characters are removed, the title is limited to 256 characters and the body to 1,024, and each pane can post at most 5 notifications every 10 seconds.

## Panes and splits

### Split a pane

| To | Menu | Shortcut |
| --- | --- | --- |
| Split side by side | **Pane → Split Left/Right** | <kbd>⌘</kbd><kbd>D</kbd> |
| Split one above the other | **Pane → Split Top/Bottom** | <kbd>⇧</kbd><kbd>⌘</kbd><kbd>D</kbd> |

The split buttons in each pane's header do the same. You can keep splitting any pane, in either direction, to build nested layouts.

### Move between panes

Click a pane, or use **Pane → Focus Left**, **Focus Right**, **Focus Up** and **Focus Down** (<kbd>⌥</kbd><kbd>⌘</kbd> + an arrow key).

!!! note "New in 1.2"
    With more than one pane showing, the focused pane is easier to spot.

The focused pane's header gets an accent line along its bottom edge and a tint, and the other panes are slightly dimmed. Dimmed panes still take clicks, selection and scrolling. Nothing is dimmed while the Trellis window is inactive or with Increase Contrast on.

### Resize panes

Drag the divider between two panes, or use **Pane → Move Divider Left**, **Right**, **Up** and **Down** (<kbd>⌥</kbd><kbd>⇧</kbd><kbd>⌘</kbd> + an arrow key). A pane can't be made smaller than 20 columns by 5 rows. Sizes are saved with the workspace.

### Maximize a pane

Choose **Pane → Maximize / Restore Pane** (<kbd>⇧</kbd><kbd>⌘</kbd><kbd>Return</kbd>) or click the maximize button in the pane header to fill the tab with one pane. Do it again to restore the layout exactly as it was.

### Close a pane

Choose **File → Close Pane** (<kbd>⌘</kbd><kbd>W</kbd>) or click the close button in the pane header. Its neighbor grows to fill the space. Closing a tab's last pane closes the tab.

### Limits

A tab's splits can nest at most 16 levels deep, and the whole workspace holds at most 100 panes. If a split or resize can't be done, Trellis says why and leaves the layout as it was.

## Closing running sessions

Closing a pane, tab or space that still has running programs asks first. The confirmation counts the sessions and lists each one as *space / tab / pane*, so one dialog covers everything you're about to close. Choose **Close Sessions** to go ahead or **Cancel** to keep everything.

Trellis then asks the programs to stop. If they haven't finished after two seconds, it asks again whether to **Force Stop** them or **Keep Waiting**. Processes that were detached from the terminal, or that run on another machine, may keep running.

## Quitting and relaunching

### Sessions keep running after you quit

By default your sessions run in a small background helper, so they keep going when you quit Trellis, close its window, or Trellis stops unexpectedly. When you open Trellis again, each one returns to its pane, still running, with up to 4 MiB of its recent output replayed. Full-screen programs such as `vim` or `htop` redraw.

- Quitting (<kbd>⌘</kbd><kbd>Q</kbd>) doesn't ask when every session can be kept. If some can't (for example the helper couldn't start), Trellis offers **Keep Running**, **Stop Sessions** or **Cancel** and says how many will stop.
- A session that ended while Trellis was closed comes back stopped, with its output and a line saying "Session ended while Trellis was closed" and its exit code. This works as long as the helper is still running; it exits 30 seconds after its last session ends, and that output goes with it.
- If kept sessions are found that no pane claims, Trellis asks whether to **Stop Them** or **Leave Running**. Nothing is ended without asking.
- Kept sessions end when you log out or restart your Mac.

To have quitting end every session instead, turn on **Settings → Sessions → Stop sessions when Trellis quits**. Quitting then asks for confirmation when sessions are running.

### What's restored

Your spaces, tabs, names, colors and splits are saved automatically, and **File → Save Workspace** (<kbd>⌘</kbd><kbd>S</kbd>) saves at once. When Trellis opens, any pane whose session wasn't kept comes back **stopped**: nothing runs until you click **Start Session** in the pane. Trellis never re-runs a command or replays what you typed.

To see each pane's last output in a stopped pane after relaunch, turn on **Settings → Sessions → Restore scrollback after quit** (off by default). The text is shown in the pane followed by "Restored output from" and the date. Note that:

- it's saved as plain text, unencrypted, up to 1 MiB per pane;
- Trellis removes passwords, tokens, keys and similar credentials before saving, but this is best effort and can miss secrets in unusual formats;
- the saved text is deleted when you close or restart the pane or turn the setting off.

### Workspace disk writes

Trellis saves the workspace only when something changed. **Settings → Sessions → Workspace disk writes** caps how much it may write per hour (10, 25, 50, 100 or 250 MB; 50 MB by default). Past the cap, changes are saved together every 5 minutes instead of right away. <kbd>⌘</kbd><kbd>S</kbd> and quitting still save at once.

## Closing the Trellis window

Closing the window hides it; your sessions keep running, and clicking the Dock icon brings the window back with the same layout.

If **Stop sessions when Trellis quits** is on and sessions are running, closing the window asks whether to end them. If you accept, the sessions end and the window hides, but your spaces, tabs and splits stay, as stopped panes.

## Move projects and hosts to another Mac

**File → Export Projects & Hosts…** writes your [project library](project-library.md) and [saved SSH hosts](ssh-hosts.md) to a file. Passwords are never included. Spaces aren't exported: they're what projects become once launched.

**File → Import Projects & Hosts…** checks the whole file before changing anything and shows a summary: how many projects and hosts it holds, which hosts clash with ones you have (you choose what to do with each), and which projects share a name with yours (they're added as copies named "… (imported)", never over yours). Nothing opens or starts. If the import fails partway, nothing is half-imported.
