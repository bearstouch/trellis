# Trellis Security Audit — 2026-10-18

**Scope:** whole repository at `develop` (`850738b`). This covers all `Sources/` targets, the vendored
`ThirdParty/SwiftTerm` (partially), `scripts/`, `release/`, `.github/workflows/`, and `landing/`.

**Method:** four independent review agents, each with its own surface. No agent changed any repository file.

| Auditor | Surface |
| --- | --- |
| A | Local automation: control socket, JSON-RPC framing, authorization/grants, CLI, layout & portable import |
| B | MCP server (HTTP/TCP), SSH hosts, askpass, Keychain, PTY/process spawning, shell integration |
| C | Untrusted terminal output in the vendored engine (image decoders). This agent was **terminated early by an API error**. Its two findings were re-verified by hand. |
| D | Trellis's own output policy (links, clipboard, paste, notifications), persistence, launch/release pipeline, landing site |

Auditors A and C ran throwaway probes, against a scratch copy of the repo and a scratch SwiftPM package
respectively. The other findings come from reading the code. Every Critical/High/Medium item was
cross-checked by reading the cited code during consolidation (see *Verification* column).

**Threat model.** Trellis is a local desktop terminal. The realistic attackers are:

- malicious terminal output, such as `cat` of a hostile file or a compromised SSH host;
- malicious import files (layouts, `.trellis` exports, themes);
- automation clients holding a *limited* grant;
- other local users and other same-user processes;
- network peers and web pages, if the MCP server is enabled;
- the release supply chain.

## Summary

| Severity | Count |
| --- | --- |
| Critical | 0 |
| High | 2 |
| Medium | 5 |
| Low | 12 |
| Informational | 11 |

There are no Critical findings. The core security design is strong: socket and peer-UID checks, the
token scheme, HTTP parsing, ssh argv construction, spawn hygiene, and the link/clipboard policy all
hold up.

**The two High issues are availability bugs in the vendored SwiftTerm image decoders.** Any terminal
output can freeze or crash the entire app, killing every session in every window, because all panes
share one process and the engine is fed on the main thread.

**The Medium issues fall into four groups:**

- Authorization-composition gaps. These let a grant *without* `session.execute` change or choose
  where SSH connects, against the documented contract in `docs/api/authorization.md`.
- An unbounded DCS buffer in the engine.
- The bracketed-paste end marker surviving an approved paste.
- Release-pipeline integrity.

---

## High

### H1. Kitty graphics `o=z` payload sends the main thread into an infinite loop
- **Location:** `ThirdParty/SwiftTerm/Sources/SwiftTerm/KittyGraphics.swift:1878-1932` (`decompressZlib`),
  reached through `handleKittyGraphics` → `decodeKittyPayload` → `decompressKittyData` (`:704`).
- **Description:**
  - The loop calls `compression_stream_process(&stream, 0)`. It never passes `COMPRESSION_STREAM_FINALIZE`.
  - On `COMPRESSION_STATUS_OK` it executes `continue` with no check that any input was consumed or
    any output produced.
  - Kitty's `o=z` is RFC 1950 zlib, which has a 2-byte header. Apple's `COMPRESSION_ZLIB` expects raw
    deflate (RFC 1951). Given a normal zlib stream, the decoder keeps returning `OK` with zero progress,
    forever.
  - The `kittyMaxImageBytes` cap (`:704`) is checked only *after* full decompression, so a
    decompression bomb is also unbounded.
- **Impact:** a ~30-byte APC sequence in any output (a file, `curl`, or a remote host) hangs the app at
  100% CPU on the main thread. The user must force-quit and loses every session, SSH included.
  Legitimate kitty clients that send `o=z` trigger it too.
- **Evidence:** auditor C reproduced it in a release-build probe that was still spinning after 20 s;
  `sample` showed the stack in `compression_stream_process` inside `decompressZlib`. Re-verified by
  code reading.
- **Fix:**
  1. Immediate: refuse `o=z` with `ENOTSUP`, the same way `t=f/t/s` are already refused.
  2. Proper: strip and validate the zlib header and the Adler-32 trailer, then decode raw deflate.
     Pass `FINALIZE` when the input is exhausted. Treat "OK with no progress" as an error. Stop as soon
     as output exceeds `kittyMaxImageBytes`.
  3. Record the change in `ThirdParty/SwiftTerm/PATCHES.md` and add a regression test.

### H2. Sixel parsing crashes on integer overflow and has unbounded CPU and memory use
- **Location:** `ThirdParty/SwiftTerm/Sources/SwiftTerm/SixelDcsHandler.swift`:
  - `nextInt` (`:33-50`): `10 * existing + digit` uses trapping arithmetic.
  - repeat loops (`for _ in 0..<reps`, `:241`, `:314`): `reps` is unbounded.
  - pixel buffer (`:122`): `Array(repeating: 0, count: maxX*maxY*4)` has no dimension cap.
  - The handler is registered unconditionally (`EscapeSequenceParser.swift:622`).
- **Description and impact:**
  - **Crash:** a DCS sixel sequence with a long digit string in a parameter, color, or `!` repeat count
    overflows `Int` and traps (SIGTRAP), in both debug and release. Every session in the app dies.
  - **Resource exhaustion:** a huge `!` repeat count makes the parser loop billions of times on the main
    thread and inflates `maxX`. A large `maxX*maxY*4` then drives a multi-gigabyte allocation, or traps
    on overflow.
- **Evidence:** auditor C reported the overflow trap in its probe (exit signal 133) before it was
  terminated. The arithmetic and the missing bounds were re-verified by code reading.
- **Fix:**
  - Use saturating parsing: stop accumulating past a sane limit such as 65535.
  - Clamp `reps` and the image dimensions, for example to the `InlineImageProtocol` limits
    (10k×10k, 40 MP).
  - Compute buffer sizes with `multipliedReportingOverflow`, and drop the image on overflow.
  - Consider not registering the sixel handler at all until it is hardened, since Trellis doesn't
    advertise sixel by default.
  - Record the change in `PATCHES.md` and add regression tests.

---

## Medium

### M1. `host.update` with JSON `null` changes connection fields without `session.execute`
- **Location:** `Sources/TrellisControl/Authorization.swift:44-47` (`hostUpdateMayChangeConnection`
  treats `value == .null` as "no change") and `Sources/TrellisUI/AutomationService.swift:1030-1038`
  (`hostDraft`: if the key is present, `null` *clears* `user`, `port`, or `identityFile`).
- **Description:**
  - The docs require `host.write` + `session.execute` to change a host's user, port, or identity file.
  - A grant with only `host.write` (for example the MCP `host_update` tool) can send
    `{"id": H, "user": null, "port": null, "identityFile": null}`.
- **Impact:**
  - ssh now uses the local username, port 22, and default keys.
  - `connectionRevision` is bumped, which invalidates every other grant's approval for the host.
  - `HostLibrary.update` (`HostLibrary.swift:258-265`) **silently deletes the saved Keychain
    password**.
- **Evidence:** found independently by auditors A and B. A probe confirmed it: `{user:"root"}` →
  `PERMISSION_DENIED`, but `{user:null, port:null}` → OK, with revision 1→2.
- **Fix:** treat the *presence* of any of `destination`, `user`, `port`, `identityFile` (null included)
  as a connection change. Better still, build the draft and compare `connectionLaunch` before and
  after in the domain. Add a `GrantAuthorizationTests` case.

### M2. `host.create` needs only `host.write`, so an all-hosts grant can create a host and connect to any server
- **Location:** `Authorization.swift:102` (`"host.create": needs(.hostWrite)`), `:105` (`host.connect`),
  and the scope check in `GrantAccess.hostAccess` (`Authorization.swift:158-166`).
- **Description:**
  - Creating a host chooses its destination, user, port, and key. Editing those same fields requires
    `session.execute`; creating them does not.
  - With host scope "All saved hosts", a newly created host is immediately in scope.
  - So a grant with `host.write` + `session.start` + `layout.write` can do `host.create {destination:
    attacker.example, …}` and then `host.connect`, spawning ssh to an attacker-chosen server.
- **Impact:**
  - The username and offered public keys leak to the attacker's server.
  - The ssh agent is forwarded if `~/.ssh/config` enables `ForwardAgent` for `Host *`.
  - The UI label "All saved hosts" (`AutomationSettingsView.swift:212`) implies existing hosts only.
- **Evidence:** auditors A and B (B rated it Low). Auditor A's probe confirmed the `host.create` step.
- **Fix:** require `session.execute` for `host.create`, or keep grant-created hosts out of `.all`
  scope until the user approves them. Document the rule.

### M3. Unbounded DCS payload buffering (DECRQSS and other DCS) exhausts memory
- **Location:** `ThirdParty/SwiftTerm/Sources/SwiftTerm/EscapeSequenceParser.swift:757,846,937` (DCS `put`
  has no size check) and `Terminal.swift:1108-1112` (`DECRQSS.put` appends every byte).
- **Description:**
  - The existing `maxStringPayloadBytes` patch (8 MiB, `EscapeSequenceParser.swift:882`) caps only
    OSC and APC payloads.
  - An unterminated `ESC P $ q …` followed by an endless stream grows memory without limit.
  - The sixel handler's `put` (`SixelDcsHandler.swift:27-31`) buffers the same way.
- **Impact:** output-driven memory exhaustion of the single app process (all sessions).
- **Fix:** apply the 8 MiB cap to DCS passthrough in the parser, dropping the sequence once it is over
  the limit. Cap `DECRQSS.data` locally (valid requests are under 8 bytes). Record the change in
  `PATCHES.md` and add a test.

### M4. Bracketed-paste end marker is not removed from approved pastes
- **Location:** `Sources/TrellisCore/TerminalPaste.swift:56-58`, with the preview truncation at `:50`.
- **Description:**
  - Any ESC forces paste review, which is correct. But once the user confirms, an embedded
    `ESC[201~` is sent verbatim inside the brackets.
  - The shell leaves bracketed mode early, and the rest of the paste runs as typed commands, newlines
    included.
  - The preview truncates after 8192 characters. A marker placed past that point never appears in the
    review sheet, which only shows "Preview truncated".
- **Impact:** text from a web page or chat ("copy this snippet") can execute commands after one
  routine confirmation. The automation paste mode already rejects the marker; the UI path doesn't.
- **Fix:** when `bracketed` is true, strip or neutralise `ESC[200~` and `ESC[201~` in
  `data(bracketed:)`, as xterm, iTerm2, and kitty do. Report in the sheet when an ESC lies outside the
  previewed range. Add a test.

### M5. Release pipeline integrity: actions not pinned to commits, and an unnotarized build can publish
- **Location:** `.github/workflows/release.yml` (`actions/checkout@v4`, `actions/upload-artifact@v4`)
  and `scripts/package-release.sh:79-83,115`.
- **Description:**
  - The release job has `contents: write`, the Developer ID P12, and the notary credentials, yet it
    uses mutable action tags. A compromised or re-tagged action receives the signing identity.
  - In `package-release.sh`, `notarytool … && notarized=true` doesn't trip `set -e`, and the final
    Python check exits 0 when `notarized` / `stapled` are false. A failed notarization therefore still
    produces a "successful" signed release.
- **Fix:**
  - Pin every action to a full commit SHA, kept current by Dependabot.
  - When `TRELLIS_NOTARY_PROFILE` is set, exit non-zero if notarization or stapling fails. Gate
    publishing on `release-evidence.json` showing `notarized` and `stapled`.

---

## Low

### L1. Global authentication rate limiters let one client lock out valid tokens
- **Location:** `Authorization.swift:183-200` (`AuthenticationRateLimiter`), `:277-287` (socket),
  `:310-317` (MCP).
- **Description:**
  - The limit is five failed attempts per minute, shared across *all* clients.
  - On MCP the limit is checked *before* the token is validated.
  - Any reachable peer that sends five bad attempts a minute keeps every client locked out, including
    clients with valid tokens. On the socket this takes a same-user process; on MCP it takes any peer
    that can reach the port, including other local users on a loopback bind.
  - With 256-bit tokens, brute force isn't the realistic threat.
- **Fix:** validate first and count only failures per connection or per peer address. Always let a
  correct token through.

### L2. Connection-slot exhaustion on the control socket and the MCP listener
- **Locations:**
  - Control socket: `Sources/TrellisControl/ControlServer.swift:7,120-124,146-157`.
  - MCP listener: `Sources/TrellisMCP/MCPListener.swift:184-208` (`:207` resets the deadline after
    every response).
- **Description:**
  - **Control socket:** 16 connections that never authenticate occupy every slot indefinitely, and
    each one holds two threads.
  - **MCP:** the 30 s deadline restarts after any completed request, even a 401/403/404/405 reply. So
    16 keep-alive connections that send a junk `GET` every 25 s deny service to everyone.
- **Fix:**
  - Close connections that haven't authenticated within 5–10 s.
  - On MCP, send `Connection: close` on unauthenticated or error responses, and extend the deadline
    only after an authenticated request.
  - Optionally add a per-peer cap.

### L3. One grant can evict other grants' MCP sessions
- **Location:** `Sources/TrellisMCP/MCPEndpoint.swift:134-138`. There are 32 sessions in total, evicted
  least-recently-used first.
- **Description:** a low-privilege grant that loops `initialize` pushes out more privileged clients'
  sessions.
- **Fix:** cap sessions per grant, and evict only within the requesting grant.

### L4. A layout can choose a shell's working directory without `session.execute`
- **Location:** `Sources/TrellisCore/LayoutDocument.swift:115-121,158-161,200-209`,
  `Sources/TrellisControl/LayoutJSON.swift:39-43`, and `AutomationService.swift:590-593`.
- **Description:**
  - `session.start {kind: shell, directory}` correctly requires `session.execute`.
  - `layout.apply {startNew: true}` with the same directory needs only `layout.write` + `session.start`.
    Auditor A's probe started a shell in `/private/etc`.
  - Directory-triggered hooks (direnv `.envrc`, git `core.fsmonitor` with a git-aware prompt, `mise`)
    can turn this into code execution if a malicious repo is on disk.
- **Fix:** require `session.execute` when a layout sets a directory and starts sessions, or document
  the exception explicitly.

### L5. A `session.start`-only grant can re-run another grant's arbitrary process, which is labeled "shell"
- **Location:**
  - `AutomationService.swift:254-284`: with `launch == nil`, the stored launch is reused.
  - `WorkspaceStore.swift:184`.
  - Labeling at `AutomationService.swift:629-630,867` and `PortableDocument.swift:59`.
- **Description:**
  - A pane whose stored launch is `.process(X, args)` (set by an execute-capable grant) can be
    restarted by a grant that has only `session.start`. Auditor A's probe confirmed it.
  - Any `.process(_, ["-l"])` is reported or exported as `launchKind: "shell"`, which hides that the
    pane runs an arbitrary binary.
- **Fix:** require `session.execute` to start or restart a `.process` launch that isn't the default
  login shell. Base the shell label on the executable *and* the arguments.

### L6. File-existence oracles available to low-privilege grants
- **Locations:**
  - `host.create` / `host.update` with `identityFile`: `SavedHost.swift:176-185` (`stat` follows
    symlinks). Needs only `host.write`.
  - `layout.validate` / `layout.plan`: `AutomationService.swift:537-539`, `LayoutDocument.swift:117`.
    Needs only `metadata.read`. Auditor A's probe confirmed it.
- **Description:** a grant can test whether arbitrary paths exist (regular files or directories) outside
  the workspace model.
- **Fix:** skip the checks, or use a generic error, for grants that lack `session.execute`.

### L7. A revocation that fails to persist comes back after relaunch
- **Location:** `Sources/TrellisControl/AutomationGrant.swift:203-213`.
- **Description:** the in-memory revoke and the Keychain delete succeed, then `persist` throws (disk
  full, I/O error). `grants.json` still marks the grant active, so after relaunch a copied token
  authenticates again. The UI does warn.
- **Fix:** keep a durable deny-list, or retry persisting and refuse pending-revocation grants at load
  (fail closed).

### L8. State-directory and migrated-file permissions are not enforced
- **Location:** `WorkspacePersistence.swift:211`, `ThemeLibrary.swift:42`, and
  `ApplicationSupportLocation.swift:21,49,66`.
- **Description:**
  - `createDirectory(attributes:)` applies 0700 only to directories it creates. An existing
    `--state-directory` with 0755 stays readable.
  - Migration uses `copyItem` and `Data.write(.atomic)`, so files end up 0644. This breaks the
    documented 0600/0700 guarantee.
  - Impact is reduced because `~/Library` is normally 0700.
- **Fix:** after preparing, `lstat` the directory, verify the owner, and `chmod 0700`. Write migrated
  files through the existing `O_EXCL` 0600 writer, or `fchmod` them afterwards.

### L9. OSC 8 hyperlink target is never shown before opening
- **Location:** `Sources/TrellisTerminal/NativeTerminal.swift:438-457`,
  `AccessibleTerminalView.swift:249-265`.
- **Description:** the visible text can differ from the actual target, and the context menu says only
  "Open Link". The scheme allow-list, the ban on credentials, and the click requirement are correct,
  so this only helps phishing.
- **Fix:** show the resolved URL (host first, IDN as punycode) in a tooltip or in the menu item.

### L10. Terminal-originated notifications can spoof system prompts
- **Location:** `Sources/TrellisUI/AppWorkspaceModel.swift:801-803`, `TerminalNotification.swift`.
- **Description:**
  - OSC 9, 777, and 99 fully control the notification title, which is posted under the Trellis
    identity (for example "Software Update: enter your password").
  - `o=always` shows it even while the pane is focused.
- **Fix:** always put the pane or tab name in the title or subtitle, and put program text only in the
  body.

### L11. Vendored engine: title stack grows without limit (CSI 22 t)
- **Location:** `ThirdParty/SwiftTerm/Sources/SwiftTerm/Terminal.swift:4047-4053`.
- **Description:** each push copies the whole array (`stack = stack + [...]`), so repeated pushes cost
  quadratic CPU and linear memory, driven by output.
- **Fix:** cap the stack at about 10 entries, as xterm does, and use `append`. Record the change in
  `PATCHES.md`.

### L12. Landing site deployment hardening
- **Location:** `landing/nginx/default.conf.template`, `landing/Dockerfile`, `landing/.dockerignore`.
- **Description:**
  - `location /assets/` declares its own `add_header`, so the server-level CSP, `X-Frame-Options`, and
    `Referrer-Policy` aren't inherited for `/assets/*`.
  - There's no HSTS header and no `Permissions-Policy` header.
  - The base images are pinned by tag only (`nginx:1.27-alpine` is past end of life), and the nginx
    master process runs as root.
  - `.dockerignore` doesn't exclude `.env*`.
- **Fix:** repeat the headers in `/assets/` (an `include` snippet works), and add HSTS and
  `Permissions-Policy`. Use `nginxinc/nginx-unprivileged` on a current stable release, pinned by
  digest. Add `.env*`, `.DS_Store`, and `og/` to `.dockerignore`.

---

## Informational

| # | Finding | Location | Note / fix |
| --- | --- | --- | --- |
| I1 | The Keychain accessibility attribute is probably ignored. `WhenUnlockedThisDeviceOnly` applies only to the data-protection keychain. | `AutomationGrant.swift:96-103`, `docs/api/authorization.md:10` | Set `kSecUseDataProtectionKeychain` (needs a signed app with a keychain-access-group entitlement), or correct the docs. After "Always Allow", any same-user process can drive the CLI with `--keychain-grant`. |
| I2 | Event subscriptions survive re-authentication on the same connection. | `ControlSession.swift:176-184`, `EventHub.swift:95,162-169` | This is not an escalation, since each event is re-checked against grant A. Call `events.removeConnection` at the start of `authenticate`. |
| I3 | The CLI takes `--text` / `--base64` / `--command` in argv, so they show in `ps` and shell history. | `Sources/TrellisCLI/CLICommands.swift:60-61` | Add `--text-stdin` / `--command-stdin` options. |
| I4 | The portable-import preview doesn't show new hosts' destinations, so a host named "Production" could point at `evil.example`. | `ImportPreviewView.swift:26-31`, `PortableDocument.swift:151-153` | Show `user@destination:port` and the identity file. |
| I5 | The shell-integration nonce is visible in the API `stream` output view, so a holder of `session.output.read` could forge OSC 133 marks. | `AutomationService.swift` (`readOutput`) | Strip authenticated OSC 133 sequences from the journal or the stream view. |
| I6 | On wildcard MCP binds (`0.0.0.0`/`::`) the Host-header check is off, even for loopback connections. Browsers are still blocked by the Origin check. | `MCPEndpoint.swift:47-50`, `MCPServer.swift:29` | Apply the Host check when `getsockname` shows a loopback local address. |
| I7 | The HTTP parser keeps a bare CR or LF inside header values, and up to 1 MiB of JSON is parsed before the token is validated. | `HTTPMessage.swift:133-148` | Reject CR, LF, and NUL in header values. Not exploitable today. |
| I8 | `AskpassBroker.stop()` closes `listenFD` while the thread may still be blocked in `accept()` (an fd-reuse race), and accepting isn't capped. With ProxyJump, the nonce is consumed by the jump host's helper. | `AskpassBroker.swift:52-59` | Use the wake-pipe pattern from `MCPListener`. The ProxyJump behavior is a functional surprise, not a leak. |
| I9 | Reading `hosts.json` doesn't verify the file owner. | `HostLibrary.swift:48-63` | Use `OwnerOnlyFile.read`. The parent directory is 0700, so impact is minimal. |
| I10 | A file link has a small window between being checked and being opened. `.ics`, `.vcf`, `.html`, `.svg`, and `.webarchive` files open directly. | `FileLinkPolicy.swift:158-166`, `NativeTerminal.swift:442-444` | Re-check just before opening, and reveal (not open) types with side effects. |
| I11 | Minor leaks and other nits: `layout.plan` returns the global `baseRevision` and counts panes in hidden windows (one bit of information); Keychain items for expired grants are never cleaned up; `revertImport` loses a replaced host's saved password (data loss); the CLI reads files before its 1 MB check. | Various (see auditor A, #13) | Low priority. |

---

## What is done well

- **Control endpoint:**
  - The runtime directory has a random name, is 0700, and is checked with `lstat`.
  - The socket is 0600 and verified as a socket.
  - Symlinks are refused.
  - The discovery file is written with `O_EXCL|O_NOFOLLOW` and holds no token.
  - The peer UID is checked with `getpeereid` at three points.
- **Tokens:**
  - 256-bit tokens come from `arc4random_buf`.
  - Only SHA-256 hashes are stored, in owner-only files, and compared in constant time.
  - The CLI refuses tokens in argv.
  - `TRELLIS_*` variables are stripped from child environments.
- **Authorization:**
  - Every method except `auth.authenticate` requires an identity.
  - Expiry and revocation are re-checked on every call and every event.
  - Out-of-scope IDs return `NOT_FOUND`.
  - Host approvals are bound to `connectionRevision`.
- **Framing:** frames are capped at 1 MiB, nesting depth at 64, outboxes are bounded, and batches are
  refused.
- **MCP:**
  - Off by default, loopback-only by default.
  - Strict Origin and Host checks, no CORS.
  - The parser is strict (no `Transfer-Encoding`, no conflicting Content-Length) with size limits.
  - Sessions are bound to the token hash.
  - Every tool call is re-authorized.
- **SSH:**
  - Options come before `--`, followed by the destination.
  - No shell is involved.
  - The destination and user fields have strict allow-lists.
  - ssh_config discovery reads only `Host` names.
  - Saved passwords never reach argv or the environment, and are bound to the connection revision.
- **Askpass:** one-time nonce, plus uid, executable, and parent-pid checks on the helper.
- **Spawning:**
  - `forkpty` gives a new session.
  - Signals are reset, and every fd ≥3 is closed using async-signal-safe calls.
  - The master fd and the error pipe are CLOEXEC.
  - `signalGroup` never signals a reused PID.
- **Output policy:**
  - OSC 52 clipboard reading and writing are both disabled.
  - Title and OSC 7 reports don't echo input.
  - Links are limited to `http`, `https`, and `mailto`, and require a real click.
  - `file://` links must be local hosts, and launchable files are only revealed.
  - Kitty file, temp-file, and shared-memory transfers are refused.
  - Trellis's own inline-image path bounds dimensions before decoding.
- **Persistence:**
  - Writes use `O_NOFOLLOW|O_EXCL` 0600 temp files, then fsync, rename, and a directory fsync.
  - Files are capped in size and nesting depth.
  - Corrupt or newer state goes to read-only recovery.
  - Themes are strictly validated, including the reserved prefix.
- **Release:**
  - Hardened runtime with no entitlements.
  - The CLI-link and uninstall code uses strict allow-lists and only `unlink`.

---

## Verification and coverage notes

- **Probe-confirmed:** H1 (auditor C), H2 crash (auditor C, partial output), M1, M2 (create step), L4,
  L5, and L6 (layout part) (auditor A).
- **Re-verified by reading the code during consolidation:** H1, H2, M1, M4, M5 (the
  `package-release.sh` exit path), and the sixel handler's unconditional registration.
- **Coverage gaps (pending, not passed):**
  - Auditor C was terminated by an API error after reporting two findings. Its scope was re-run by
    auditor D, which excluded the sixel and kitty decoders.
  - The rest of the **vendored SwiftTerm** received only targeted review (DCS, title stack, OSC
    handlers). A full engine fuzzing pass is recommended (see below).
  - Nothing was tested against a live app instance, a real network bind, or a signed or notarized
    build.
  - The I1 Keychain behavior was not tested on a device.

## Recommended remediation order

1. **H1, H2, M3:** harden the vendored engine. Refuse `o=z` (or fix it), clamp sixel parsing, and
   cap DCS buffers. Add regression tests and `PATCHES.md` entries. Consider a fuzz test target that
   feeds random escape sequences to `Terminal` with a watchdog.
2. **M1, M2, L4, L5, L6:** close the authorization-composition gaps in `Authorization.swift` and
   update `docs/api/authorization.md` with the final rules and tests.
3. **M4:** strip bracketed-paste markers from approved pastes.
4. **M5:** pin the workflow actions and fail the release on a failed notarization.
5. **L1–L3, L7, L8:** availability and fail-closed fixes.
6. **L9–L12 and the Informational items:** fix as convenient.
