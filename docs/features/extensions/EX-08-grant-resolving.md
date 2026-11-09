# EX-8: GrantResolving and ExtensionPrincipal

Part of the [Extensions specification](SPEC.md#stories). **Epic:** 2, Host and authority · **Phase:** 3a · **Requirements:** FR-EX09 · **Depends on:** [EX-4](EX-04-extension-registry.md) · **Points:** 3

**Definition.** As a Trellis user, I want every extension call and event to pass the same authorization check as the CLI and MCP, so that an extension can never do more than I approved and disabling it takes effect at once.

Each extension is an `ExtensionPrincipal` with a stable UUID that resolves to an in-memory `AutomationGrant`. Today `AuthorizingControlHandler.dispatch` and `EventHub` both look grants up in `GrantStore` by ID on every call and every delivery. Both move to a small `GrantResolving` protocol, implemented by `GrantStore` for user grants and by the extension registry for extension grants.

## Scope

**In**

- A `GrantResolving` protocol used by `AuthorizingControlHandler` and `EventHub` in place of `GrantStore`.
- `GrantStore` implements it for user grants; `ExtensionRegistry` implements it for extension grants.
- `ExtensionPrincipal`: a stable UUID per extension, resolving to an `AutomationGrant` with capabilities = the approved permissions, space scope `all`, host scope approved-none and no expiry while enabled.
- `trellis.call(method, params)` routed through `AuthorizingControlHandler` with that grant.
- Capability checks, `NOT_FOUND` scoping and all-spaces rules apply unchanged.
- A disabled or suspended extension resolves to no grant: calls fail with `AUTH_REQUIRED` and events stop at the next delivery.
- `grants.json` is never touched.

**Out**

- Runtime prompts (EX-9). The prompter runs after authorization and before execution, and this story leaves the hook for it.
- `terminal.open` and `clipboard.write`, which the bridge handles itself (EX-16, EX-17).

## Acceptance criteria

- [ ] **Given** an extension without a method's capability, **when** it calls that method, **then** it gets `PERMISSION_DENIED`.
- [ ] **Given** an ID outside the extension's scope, **when** it is used in a call, **then** the call gets `NOT_FOUND`.
- [ ] **Given** an extension is disabled, **when** it makes its next call, **then** it gets `AUTH_REQUIRED`, and its next event delivery doesn't happen.
- [ ] **Given** an extension makes calls and is enabled and disabled, **when** I compare `grants.json` before and after, **then** it is byte-for-byte unchanged.
- [ ] **Given** existing user grants, **when** the CLI and MCP make calls, **then** they behave exactly as before the change.

## Implementation notes

- Changed in `TrellisControl`: `Sources/TrellisControl/Authorization.swift` (`AuthorizingControlHandler`), `Sources/TrellisControl/EventHub.swift`, `Sources/TrellisControl/AutomationGrant.swift` (`GrantStore`, `AutomationGrant`).
- New in `TrellisControl`: `GrantResolving`, `ExtensionPrincipal`.
- Wiring in `Sources/TrellisApp/AppMain.swift`, where `GrantStore` is passed in today.
- New in `TrellisUI`: the first part of `ExtensionBridge`, which turns bridge frames into handler calls.

## Tests

- `ExtensionAuthorizationTests`: missing capability; `NOT_FOUND`; disable takes effect at once; `grants.json` unchanged.
- Existing `Tests/TrellisControlTests/GrantAuthorizationTests.swift` and `EventHubTests.swift` keep passing against `GrantResolving`.
