# Mobile connect

Trellis Mobile is an iPhone and iPad app that pairs with Trellis on your Mac. From it you can follow your spaces, tabs and panes, see what each coding agent is doing, answer an agent that needs you, and type into any session the pairing allows. It works on the same network and from anywhere else, across NAT, mobile data and hotel Wi-Fi. When an agent needs you while the app is closed, a push notification tells you, and you can answer from the notification.

The phone only ever talks to the Trellis app it paired with. Session brokers keep running where they already run, on this Mac and on [remote workspace](remote-workspaces.md) hosts. The Mac app stays their only client and forwards what the phone is allowed to see. The phone never reaches a broker, an SSH host or the automation socket directly.

All requirements here are P2 (draft). Nothing on this page is implemented yet.

## How it fits together

```
 Trellis Mobile ──┬── same network: Bonjour + direct TCP ───────────┐
 (iPhone, iPad)   │                                                 ▼
                  └── elsewhere: WSS ─► Trellis relay ◄─ WSS ── Trellis.app (Mac) ──► session brokers
        ▲                       (forwards ciphertext,                                 (this Mac, remote hosts)
        │                        sends pushes)
        └──── APNs (encrypted payload) ◄── relay ◄── Mac asks for a push
```

- **One encrypted session, end to end.** Everything between the phone and the Mac runs inside one [Noise](https://noiseprotocol.org) session (`Noise_IK_25519_ChaChaPoly_SHA256`; the first pairing uses `Noise_XXpsk3`). It's the same on both paths, so the relay forwards bytes it can't read or change.
- **Same network.** The Mac advertises `_trellis-link._tcp` over Bonjour and accepts the connection on a Network.framework listener. The phone finds it with a browser and connects directly.
- **Elsewhere.** The Mac keeps one outbound WebSocket to the Trellis relay. When the phone connects to the relay, the relay asks the Mac to open a second WebSocket and joins the two. Both devices only dial out, so neither needs an open port, port forwarding or a VPN. If both are on the same Tailscale network or another VPN, the phone's direct path works over it too.
- **Racing the paths.** The phone tries the direct path and the relay at the same time, uses whichever answers first, and moves to the direct path when it appears.
- **The API.** Inside the session the phone speaks the same JSON-RPC 2.0 as the [automation API](../api/index.md): the same methods, capabilities, space scopes, event subscriptions and limits. The only difference is how it authenticates (FR-MC04).

## Pairing

1. On the Mac, open **Settings → Devices** and choose **Pair iPhone or iPad…**. Trellis shows a QR code for five minutes.
2. In Trellis Mobile, tap **Add Mac** and scan it. The code carries the Mac's public key, a one-time secret, its local addresses, and the relay address with the Mac's routing ID: `trellis-pair:v1?k=…&s=…&lan=…&relay=…&rid=…&exp=…`.
3. The phone connects and runs the pairing handshake, keyed by the one-time secret. That proves both devices saw the same code, and it gives the Mac the phone's public key and name.
4. The Mac asks **Allow "<device name>" to connect?** and lists what the phone may do (below) and which spaces it can see. Nothing is granted until you choose **Allow**.
5. The phone saves the Mac. From then on it reconnects by key, with no code and no token.

What a paired device may do is an automation grant whose principal is the device's key instead of a token:

| Permission | Default | Lets the phone |
| --- | --- | --- |
| Read workspace (`metadata.read`) | On, required | See spaces, tabs, panes, session and agent state |
| Read output (`session.output.read`) | On | See screens and follow output live |
| Send input (`session.input`) | On | Type into sessions and answer agents |
| Start and restart (`session.start`) | Off | Start stopped sessions and resume agents |
| Close (`session.close`) | Off | Close panes, with the usual confirmation for running ones |
| Notifications | On | Get pushes when an agent needs you, finishes or fails |

**Settings → Devices** lists each paired device with its permissions, its space scope, when it was last seen and over which path. **Revoke** cuts it off at once.

## What the app shows

- **Macs.** Every paired Mac, whether it's reachable, and over which path (**Local**, **Relay**).
- **Workspace.** Spaces → tabs → panes, as in the Mac sidebar, with each agent's icon and state in words: **Working**, **Needs you**, **Done**, **Error**. Panes that need you are listed at the top.
- **Agent card.** For an agent pane: the agent, its state and for how long, the last lines of its screen, quick keys (`1`, `2`, `3`, `↩`, `Esc`, `⌃C`), and a composer for a prompt (with dictation) that is sent as input. This is the default view for agent panes on iPhone.
- **Terminal.** A live mirror of any pane, drawn by SwiftTerm at the Mac's size (pinch to zoom, drag to pan), with a key bar for `Esc`, `Tab`, `⌃`, arrows and `↩`. The phone never resizes the session: the Mac's layout is unchanged. On iPad it is the default view, and a hardware keyboard types into it.
- **iPad.** A split view with the workspace on the left and the agent card or terminal on the right.

## Notifications

When an agent in a pane the device can see changes to needs you, done or error (FR-AG14's triggers), the Mac sends a push through the relay. The payload is encrypted with a key only the Mac and that phone share, so the relay and Apple see only "Trellis". On the phone, a notification extension decrypts it and shows, for example, "Claude Code needs you · api-server". The notification offers **Approve** (sends `1` `↩`), **Reject** (sends `Esc`) and **Reply** (sends the text and `↩`), each only if the device may send input. A Live Activity can show a working agent on the Lock Screen and in the Dynamic Island.

The phone registers its push token with the relay and gets back an opaque handle. It gives the handle to the Mac inside the encrypted session, and the Mac uses it to ask for pushes. The Apple push key lives only on the relay. The Mac never has it, and the relay never learns which Mac or session a push is about.

## Following a session

To show a terminal, the phone calls `session.attachMirror`. The Mac answers with the session's size, a preamble that restores the terminal's modes (the broker's mode tracking), and the most recent output, up to 256 KB. The `output` subscription then carries on from the returned cursor, so the phone's terminal reaches the same screen as the Mac's. After a reconnect, metadata subscriptions resume from the last sequence (`afterSequence`), and an `events.gap` makes the phone take a fresh snapshot.

Agent state reaches the phone through a new `agent` event topic: `agent.state` with the pane, session, agent ID, state, and when it changed. This also closes the "subscribe to agent state" gap in [Coding agents](agents.md#known-limits).

## Requirements

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| FR-MC01 | Pair a phone or iPad with a single-use QR code, approved on the Mac. | **Pair iPhone or iPad…** shows a code that expires after five minutes and works once. A scanned code starts the handshake. The Mac shows the device's name, the permissions and the space scope, and grants nothing until **Allow**. **Cancel**, an expired code, a code that was already used or a failed handshake leaves no grant behind, and the phone says why. |
| FR-MC02 | Encrypt and authenticate every byte between phone and Mac, end to end. | Both paths use the Noise profiles above, with the Mac's key pinned from the QR code. A frame that has been tampered with, replayed or reordered closes the connection. A peer whose key isn't paired is refused before any method runs. Keys are rotated after 2^20 messages or an hour. The Noise code passes the published Noise test vectors. |
| FR-MC03 | Store keys on the device only. | The Mac keeps its link keys in the Keychain (this device only). The phone keeps its private key and each Mac's record in the Keychain (`AfterFirstUnlockThisDeviceOnly`), shared with its notification extension through an app group. Neither leaves the device, appears in a backup or is logged. |
| FR-MC04 | A paired device is an automation grant bound to its key. | The device's permissions and space scope are checked by the same authorization as the automation API: a space outside the scope is `NOT_FOUND`, a method without its permission is refused. Grants are saved in `grants.json` (0600) with the device's public key and never a token. The automation socket's same-user check is unchanged. |
| FR-MC05 | Revoke a device at once. | **Revoke** in Settings → Devices closes the device's connections and subscriptions within a second, stops its pushes, and its next connection is refused. Removing the Mac on the phone deletes its keys there. |
| FR-MC06 | Find and reach the Mac on the same network. | With **Allow on this network** on, the Mac advertises `_trellis-link._tcp` with a short hash of its key, not the key. The phone connects without the relay, and Trellis Mobile asks for local network access with a reason. Turning the setting off stops the listener and the advertisement. |
| FR-MC07 | Reach the Mac from anywhere through the relay. | With **Allow from anywhere** on, the Mac keeps an outbound connection to the relay, signed with its relay key. A phone on another network connects through it with the same handshake. Only the holder of the Mac's key can register its routing ID. The relay address can be changed to a self-hosted one. Turning the setting off closes the relay connection. |
| FR-MC08 | Choose the best path and recover from network changes. | The phone races the direct path and the relay, uses the first that completes, and moves to the direct path when it becomes reachable, without losing subscriptions. After losing the connection it reconnects with backoff and resumes events from the last sequence, or takes a fresh snapshot after `events.gap`. The app shows the current path. |
| FR-MC09 | Show the workspace and agent state, in words. | The phone lists the spaces, tabs and panes in its scope, in order, with titles. Agent panes show the agent's icon and **Working**, **Needs you**, **Done** or **Error**, never color alone. Panes that need you are listed first. Changes on the Mac show within a second on the same network. VoiceOver reads, for example, "Claude Code in api-server needs your input". |
| FR-MC10 | Publish agent state as an event. | `events.subscribe` accepts the `agent` topic, and an agent's state change emits `agent.state` with the pane, session, agent ID, state and time, within the subscriber's space scope. No event carries conversation text or a command line. |
| FR-MC11 | Mirror a terminal faithfully without changing its size. | `session.attachMirror` returns the size, the mode preamble, up to 256 KB of recent output and a cursor. The phone's terminal then shows the same screen text as the Mac's for the same session. The PTY size doesn't change when the phone attaches, detaches or rotates. A session whose output dropped out of the journal reports a gap and is re-attached. |
| FR-MC12 | Answer agents from the agent card. | The quick keys and the composer send exactly their bytes through `session.sendInput`, and only with **Send input**. Without it the controls are hidden and the card is read-only. A prompt is sent as typed, with no shell or Trellis interpretation. With **Require Face ID to send** on, each sending session asks first. |
| FR-MC13 | Notify when an agent needs you, finishes or fails. | With notifications allowed, an agent state change to needs you, done or error in a pane in scope sends one push within five seconds while the Mac is awake and online. The relay and APNs see only ciphertext and a generic "Trellis" alert, and the notification extension shows the agent, state and tab title. Pushes are rate-limited per device, and none is sent while that pane is open on the phone in the foreground. |
| FR-MC14 | Act from a notification. | **Approve**, **Reject** and **Reply** appear only for a device with **Send input**. Choosing one reconnects in the background and sends `1` `↩`, `Esc`, or the reply and `↩` to that session. If the session ended or the state changed, nothing is sent and the phone says so. |
| FR-MC15 | Say what the Mac is doing when it can't be reached. | The phone shows **Mac asleep or offline** with the last-seen time, and it never shows stale state as live. On the Mac, **Keep this Mac awake while agents run** (off by default) holds a system activity while an agent pane is working. |
| FR-MC16 | Keep the relay blind and bounded. | The relay forwards bytes only after both sides connect, never parses them, and logs no payloads, push contents or IP addresses beyond rate limiting. It limits streams per routing ID, connections per address, bytes per minute and idle time. Its only secret is the Apple push key. |

## Trust and safety

- **The relay is untrusted.** It can delay or drop traffic, but it can't read, change or forge it, and it can't pair itself to your Mac. Self-host it (a Cloudflare Worker with Durable Objects, configuration in the repository) if you don't want to rely on the hosted one.
- **A lost phone.** Revoke it in Settings → Devices. Until then, it can do only what its grant allows, inside its space scope, and **Require Face ID to send** keeps input behind the device owner's face.
- **A hostile local network.** Bonjour shows only a key hash, and the connection is authenticated by key, so a look-alike Mac or a man in the middle fails the handshake.
- **The QR code** works once, for five minutes, and pairs nothing without **Allow** on the Mac. Someone who photographs it would still need you to approve their device.
- **Nothing new is stored.** Terminal output, typed input and prompts aren't saved or logged on the Mac, the relay or the phone, beyond the mirror the phone holds in memory while it's open.
- **Output is never treated as instructions** (INT-06). Notification actions send fixed bytes or your own text, and only to the session the notification is about.

## Known limits

- The Mac has to be awake and running Trellis. A sleeping Mac can't be woken from outside the local network.
- The terminal mirror uses the Mac's size, so a wide terminal is small on an iPhone until you zoom. Fitting the session to the phone is planned.
- **Approve** sends `1` `↩`, which matches Claude Code's and Codex's approval menus today. An agent whose menu differs needs the card's quick keys.
- Pushes depend on the relay and on Apple's push service, so they can arrive late or not at all.
- Live Activities and multi-Mac use on one phone come after the first release.
- Manual checks that can't run in CI stay **pending** until observed: a real device on mobile data across NAT, APNs production, VoiceOver, and a hardware keyboard on iPad.
