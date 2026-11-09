# EX-6: trellis-extension-host helper: JavaScriptCore runtime, native globals, framed protocol

Part of the [Extensions specification](SPEC.md#stories). **Epic:** 2, Host and authority · **Phase:** 3a · **Requirements:** FR-EX04 · **Depends on:** [EX-2](EX-02-manifest-validator.md) · **Points:** 8

**Definition.** As a Trellis user, I want each extension's JavaScript to run in its own locked-down process, so that a buggy or hostile extension can't reach my files or network, or take Trellis down with it.

Each enabled extension runs in its own `trellis-extension-host` helper, which embeds JavaScriptCore. The JavaScript gets no DOM, no file system, no sockets, no `require` and no subprocesses. Its only way out is the `trellis` bridge object. JavaScriptCore has no timers, `console`, `URL`, `TextEncoder`/`TextDecoder` or `structuredClone` of its own, so Trellis implements each natively.

## Scope

**In**

- A new `TrellisExtensionHost` target and `trellis-extension-host` executable: portable Swift, macOS only.
- One `JSContext` per extension on the helper's main thread.
- Native globals: `setTimeout`/`setInterval`/`queueMicrotask`, `console` (to the extension log), `TextEncoder`/`TextDecoder`, `URL`, `structuredClone`, and the `trellis` object with bridge stubs. Nothing else.
- The framed protocol: length-prefixed JSON frames (u32 big-endian length, at most 1 MiB), each request with an ID, replies and events matched by it.
- Load `main.js` and report which views it defines.
- Each bridge call's parameters and result are capped at 1 MiB.
- Hardened runtime with no entitlements, so JavaScriptCore runs without JIT. No JIT entitlement is added.

**Out**

- Spawning, the watchdog and lifetime (EX-7).
- What each bridge call does in the app (EX-8 onwards).
- A `sandbox_init` profile (open question).

## Acceptance criteria

- [ ] **Given** a helper started by Trellis, **when** I inspect it, **then** its environment is empty and it holds no descriptors except its end of the socketpair.
- [ ] **Given** extension code calling `require`, or using a file, socket or process API, **when** it runs, **then** the call fails with ReferenceError.
- [ ] **Given** extension code using `setTimeout`, `setInterval`, `queueMicrotask`, `console`, `TextEncoder`, `TextDecoder`, `URL` or `structuredClone`, **when** it runs, **then** each behaves as documented.
- [ ] **Given** a frame over 1 MiB, or a malformed length prefix, **when** either side receives it, **then** the frame is refused and the connection closes without a crash.
- [ ] **Given** a bridge call whose parameters or result exceed 1 MiB, **when** it is made, **then** it is rejected.
- [ ] **Given** the helper is killed, **when** Trellis keeps running, **then** Trellis is unaffected.
- [ ] **Given** a release build of the helper, **when** I inspect its code signature, **then** it has the hardened runtime and no JIT entitlement.

## Implementation notes

- New target `TrellisExtensionHost` and executable product in `Package.swift`.
- Spawn through `trellis_spawn_link` in `Sources/TrellisPOSIX/spawn.c` (declared in `Sources/TrellisPOSIX/include/TrellisPOSIX.h`), which gives a child with a connected socket. Confirm it fits; if not, add a variant to `TrellisPOSIX`.
- Reuse the broker's framing and peer-check patterns in `Sources/TrellisBroker/BrokerProtocol.swift` and `Sources/TrellisControl/ControlFraming.swift`.
- Authors target ES2022, which macOS 14's system JavaScriptCore supports.
- Never import SwiftTerm here.

## Tests

- `ExtensionHostTests`: empty environment; no `require`/file/socket globals; framing caps.
