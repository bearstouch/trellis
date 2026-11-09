# EX-28: OAuth device flow and auth.fetch

Part of the [Extensions specification](SPEC.md#stories). **Epic:** 6, Network and OAuth · **Phase:** 6 · **Requirements:** FR-EX22, FR-EX23 · **Depends on:** [EX-27](EX-27-native-fetch.md), [EX-29](EX-29-keychain-secrets.md) · **Points:** 5

**Definition.** As a Trellis user, I want to sign extensions in to services without the extension ever seeing my token, so that a compromised extension can't steal my credentials.

OAuth runs entirely in the app. Tokens go from the provider to the Keychain, and from the Keychain onto requests the app sends. v1 ships the device authorization grant only; the authorization code flow with PKCE is designed but deferred.

## Scope

**In**

- `ExtensionOAuth` for providers declared in `trellis.oauth`, needing `auth`. All of a provider's origins are approved with the extension.
- `auth.signIn(provider)`, only within 5 s of a user action aimed at the extension.
- The device flow: a native sheet with the user code (large, monospace, copyable), Open in Browser and Cancel, polling at the provider's interval.
- Tokens `{access, refresh, expiry, scopes}` in the Keychain under the service `Trellis Extension`, account `<name>/oauth:<provider>`, accessibility when unlocked, this device only.
- Result `{signedIn, scopes, expiresAt}`; a cancelled sign-in returns `signedIn: false`; failures reject with `AUTH_FAILED`.
- `auth.fetch(provider, url, init)`: adds `Authorization: Bearer …` in the app, only to origins in `network`. On a 401, or within 60 s of expiry, refresh once and retry. If the refresh fails, delete the tokens and reject with `NOT_SIGNED_IN`.
- `auth.status` never returns a token; no API reads one.
- Sign Out (API or Settings), disabling and removing delete the tokens, calling `revoke` when declared.

**Out**

- The `code` flow with `ASWebAuthenticationSession` (deferred until an extension needs it).
- Diagnostics coverage (EX-31).

## Acceptance criteria

- [ ] **Given** no user action in the last 5 s, **when** the extension calls `auth.signIn`, **then** it rejects with `USER_GESTURE_REQUIRED`.
- [ ] **Given** the device flow, **when** sign-in starts, **then** a native sheet shows the user code with Open in Browser and Cancel, and polling uses the provider's interval (injected clock).
- [ ] **Given** a successful sign-in, **when** I inspect the Keychain, **then** the tokens are under `Trellis Extension` with account `<name>/oauth:<provider>`, and no API, frame or log contains them.
- [ ] **Given** I cancel, **when** the call returns, **then** it resolves with `signedIn: false`.
- [ ] **Given** `auth.fetch` and a 401, **when** the call runs, **then** the token is refreshed once and the request retried. **Given** the refresh fails, **then** the tokens are deleted and the call rejects with `NOT_SIGNED_IN`.
- [ ] **Given** `auth.fetch` to an origin not in `network`, **when** called, **then** it rejects with `NETWORK_NOT_DECLARED`.
- [ ] **Given** Sign Out, disabling or removing, **when** it completes, **then** the Keychain items are deleted.
- [ ] **(manual)** **Given** a real GitHub App, **when** I sign in with the device flow, **then** it succeeds. Stays **pending** until observed.

## Implementation notes

- New in `TrellisUI`: `ExtensionOAuth`.
- Follow the grant Keychain conventions in `Sources/TrellisControl/AutomationGrant.swift` (`GrantSecretStore`) and `Sources/TrellisCore/HostSecrets.swift` (`HostSecretStore`, `KeychainHostSecretStore`), with an injected Keychain store.
- `Package.swift` gains AuthenticationServices when the `code` flow lands.
- Inject the transport and the clock.

## Tests

- `ExtensionOAuthTests`: the device flow; refresh on 401; token never returned; cleanup on Sign Out, disable and remove.
