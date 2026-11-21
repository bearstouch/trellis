# Idle screensaver

These requirements are P2. When the focused pane has had no input or output for a while, an animation covers its terminal
until the user comes back. The screensaver only draws over the pane: the session keeps running, nothing is written to the
PTY, and nothing about it is saved except the two settings.

## Requirements

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| FR-SS01 | Offer five animations in Settings → Appearance → **Screensaver**, plus Off (the default), and a **Start after** delay of 30 seconds, or 1, 2, 5 (the default), 10, 15, 30 or 60 minutes. | The animations are **Digital Rain** (falling katakana and hex columns that light up "CYPHERPUNKS WRITE CODE"), **Game of Life** (Conway's automaton on a torus, with gliders and the glider emblem), **Brian's Brain** (firing, refractory and resting cells), **Hex Spirals** (a 16-state cyclic automaton drawn as hex digits) and **ASCII Plasma** (sine plasma shaded with text characters). Each draws with the pane theme's background and ANSI colours, in light and dark themes. The settings page shows a live preview of the chosen one. **Start after** is disabled while the style is Off. Both settings apply with **Apply Appearance** and never restyle or restart terminals. Settings saved without them, or naming a style or delay this build doesn't have, load as Off and 5 minutes without discarding the other appearance settings. |
| FR-SS02 | Start the screensaver over the focused pane of the active tab once it has been idle for the chosen delay. | Idle means no input to and no output from that pane, and no key, click or scroll anywhere in the app. Output in other panes neither delays nor dismisses it. Focusing another pane, tab or space takes it away and starts that pane's own full countdown. It doesn't start while the window is hidden or covered, the welcome tour or command palette is open, a tab is being renamed, or the workspace is restoring or in recovery. |
| FR-SS03 | Dismiss it on any sign of the user, without the dismissing key reaching the session. | A key press in the workspace window dismisses it and isn't typed into the pane (a shortcut such as ⌘W is dropped too, so waking never closes or changes anything); a key for another window dismisses it and reaches that window; clicks, scrolls and pointer movement over it dismiss it too. New output in the covered pane dismisses it. The countdown restarts from the dismissal. |
| FR-SS04 | Respect Reduce Motion. | While Reduce Motion is on, the screensaver and the settings preview show one still frame instead of animating, and the pane fades in and out without animation. |
| FR-SS05 | Cost nothing while it can't be seen, and stay bounded. | It draws at most 30 frames a second, and not at all while its window is hidden or covered. The once-a-second idle poll runs only while a style is chosen. Each animation's state has a fixed size for its pane, so a long run never grows memory. |
| FR-SS06 | Keep it accessible. | VoiceOver reads the covered pane as "Screensaver: \<name\>" with the hint "Press any key to return", which is also shown on screen. The animation itself is hidden from accessibility. |

## Implementation notes

- The model decides when it shows (`AppWorkspaceModel+Screensaver.swift`, with the `IdleScreensaverClock` in Core); the pane
  draws it (`Sources/TrellisUI/Screensaver/`). Scenes record each frame into a `ScreensaverFrame`, which a CoreText painter
  draws with one call per font, colour and opacity, so tests run the scenes headless from a fixed seed.
- The app's local event monitor reports keys, clicks and scrolls to `noteUserEvent(keyInWorkspaceWindow:)` and drops a key that wakes the
  workspace window.
