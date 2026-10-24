# Trellis release guide

Release decisions are recorded in [`release/manifest.json`](https://github.com/bearstouch/trellis/blob/master/release/manifest.json) and checked by `ReleaseTests`.

| Decision | Value |
| --- | --- |
| App identity | Trellis, bundle identifier `com.bearstouch.trellis` (Bearstouch Developer ID team) |
| Minimum macOS | 14.0 (`LSMinimumSystemVersion`, matching `Package.swift`) |
| CPU support | Universal 2: arm64 and x86_64, each built natively and combined with `lipo` |
| Package format | Signed DMG containing `Trellis.app` |
| Bundled CLI | `Trellis.app/Contents/Helpers/trellis` |
| Terminal engine | SwiftTerm 1.20.0, MIT license, vendored with recorded patches ([PATCHES.md](https://github.com/bearstouch/trellis/blob/master/ThirdParty/SwiftTerm/PATCHES.md)) |
| Updates | Sparkle 2.10.0 (MIT), embedded as `Contents/Frameworks/Sparkle.framework`. EdDSA-signed appcast on the `appcast` branch; see [Updates](#updates) and MAC-14 |

## Building a release

```sh
scripts/package-release.sh                                   # ad-hoc signed: local testing only
TRELLIS_SIGN_IDENTITY="Developer ID Application: …" \
TRELLIS_NOTARY_PROFILE=trellis-notary scripts/package-release.sh
```

The script produces `dist/Trellis.app`, `dist/Trellis-<version>.dmg`, and `dist/release-evidence.json`. It covers:

- **Signing:** the CLI and the app are signed with the hardened runtime and no entitlements (an ad-hoc build's app alone gets `disable-library-validation`, because ad-hoc signatures have no Team ID to match the embedded Sparkle.framework; `release-evidence.json` fails a Developer ID build that has it), so there is no root helper and no blanket Accessibility, Screen Recording, or Full Disk Access request.
- **Notarization:** with a Developer ID and a notary profile, the DMG is submitted with `notarytool` and the DMG is stapled; its ticket covers the app it contains. The `dist/Trellis.app` copy outside the DMG is stapled separately. If notarization or stapling fails, the script exits non-zero and `release-evidence.json` lists the failure, so a failed submission can't pass as a finished release.
- **DMG layout:** `scripts/make-dmg.sh` puts the app beside an `Applications` shortcut over `Design/DMG/background.png` (regenerate with `swift Design/DMG/make-background.swift Design/DMG`) and sets the app icon as the volume icon. The window layout is applied through Finder AppleScript; where Finder automation is unavailable it prints a warning and the DMG keeps the shortcut without the arranged layout.
- **Release workflow:** `.github/workflows/release.yml` pins every action to a commit SHA, because the job holds the signing certificate and notary credentials; Dependabot (`.github/dependabot.yml`) keeps the pins current. A build that is signed but not notarized is published as a pre-release with a note.
- **Version:** the manifest's `version` is `X.Y.Z` or `X.Y.Z-alpha|beta|rc.N` (N < 30); anything else stops the build. macOS needs numeric bundle versions, so `CFBundleShortVersionString` is the `X.Y.Z` core and `CFBundleVersion` adds a build that sorts pre-releases first (alpha.N = N, beta.N = 30+N, rc.N = 60+N, release = 100: `1.0.0-beta.1` is `1.0.0.31`, `1.0.0` is `1.0.0.100`). The full version goes to `TrellisVersion`, which the About panel, status bar, diagnostics, `system.info` and the MCP server show.
- **Checks recorded:** the strict signature check, the hardened-runtime flag, the architectures of both binaries, the minimum OS, the version keys, the artifacts listed in the manifest, and the local `spctl` result.

## Updates

Trellis updates in place with Sparkle 2 (MAC-14).

- **Keys:** generate the EdDSA pair once with `.build/artifacts/sparkle/Sparkle/bin/generate_keys` (after `swift package resolve`). Commit the public key as `sparklePublicKey` in `release/manifest.json`, and store the private key (`generate_keys -x private.key`) as the `SPARKLE_ED_PRIVATE_KEY` repository secret. Keep an offline backup: without the private key, installed copies can never accept another update.
- **Info.plist:** `package-release.sh` writes `SUFeedURL`, `SUPublicEDKey`, `SUEnableAutomaticChecks` = false and `SUEnableSystemProfiling` = false only when `sparklePublicKey` is set. Without a key the build has no updater. `run-feasibility.sh` never writes a feed.
- **Signing:** `scripts/sign-sparkle.sh` removes Sparkle's XPC services (Trellis isn't sandboxed), then signs its nested code (`Autoupdate`, `Updater.app`) inside-out with the hardened runtime before the framework and the app. The thin DMGs thin Sparkle's binaries too.
- **Appcast:** on a tag build with a notarized release, `release.yml` signs the Universal 2 DMG with `sign_update`. `scripts/update-appcast.py` then adds the item to the published `appcast.xml`: newest first, idempotent per version, with `X.Y.Z-alpha|beta|rc.N` versions on the `beta` channel. The workflow commits it to the orphan `appcast` branch, which serves it at `https://raw.githubusercontent.com/bearstouch/trellis/appcast/appcast.xml`. The branch holds only `appcast.xml` and is created on the first publish. `sparkle:version` is the numeric `CFBundleVersion`, so pre-releases sort before their release.
- **Test locally:** build two versions with a test key pair, serve an appcast with `python3 -m http.server`, and point `SUFeedURL` at it in the older build's Info.plist (then re-sign it).

## Installing

1. Open the DMG and drag the **Trellis** icon onto the **Applications** shortcut beside it.
2. Launch it. A notarized build opens normally. An ad-hoc development build is rejected by Gatekeeper and is not for distribution.
3. Optional, to use the CLI as `trellis`:

   ```sh
   /Applications/Trellis.app/Contents/Helpers/trellis cli install-link            # creates ~/.local/bin/trellis
   /Applications/Trellis.app/Contents/Helpers/trellis cli install-link --dir ~/bin
   ```

   This creates exactly one symlink, in a directory under your home folder (creating that directory if it is missing). It refuses system directories, `~/.ssh`, `~/Library`, and any directory that is a symlink leading outside your home folder (for example `~/bin -> /usr/local/bin`). It never overwrites an unrelated file and never edits shell startup files. If the directory is not on your `PATH`, add it yourself.

## Upgrading

Quit Trellis, then replace `Trellis.app` with the new version. The CLI link keeps working because it points into the app bundle. If you moved the app, run `install-link` again; it replaces only a link that points to a Trellis CLI.

## Backups, migration, and downgrades

Data lives in `~/Library/Application Support/com.bearstouch.trellis/`:

| File | Contents | Protection |
| --- | --- | --- |
| `workspace.json` | Windows, tabs, splits, and settings | Last-known-good copy in `workspace.backup.json` |
| `hosts.json` | Saved hosts | Last-known-good copy in `hosts.backup.json` |
| `grants.json` | Automation grant metadata (hashes only) | Unreadable files are preserved |
| `layout-bindings.json` | Layout namespace bindings | Unreadable files are preserved |
| `workspace-trust.json` | Trusted project file digests | Unreadable files trust nothing and are preserved |
| `Themes/` | Custom themes | — |

All files are owner-only and written atomically.

- **Migration:** the workspace is versioned JSON. A newer format is opened in read-only recovery and never overwritten. Settings from installs named "uTerm" are copied on first launch, and the originals are left untouched.
- **Downgrading:** state written by a newer release may be refused by an older one. The older app shows recovery and leaves the file as it is. Before downgrading, keep a copy of `~/Library/Application Support/com.bearstouch.trellis`.
- **Backing up:** copy that folder while Trellis is not running. Grant tokens and saved host passwords are stored in the Keychain, not in this folder. Restored on another Mac, a host still says its password is saved, but that Keychain has no item. ssh then asks for the password in the terminal; use **Replace…** to save it again.

## Uninstalling

```sh
trellis cli uninstall-plan --json      # dry run: lists exactly what belongs to Trellis
trellis cli remove-link
```

Then:

1. Delete `Trellis.app`.
2. Delete the folders listed by `uninstall-plan`: Application Support, Preferences, Caches, and Saved Application State for `com.bearstouch.trellis`, and for `dev.trellis` (the identifier through 0.11, whose folders the migration copies and leaves in place).
3. Delete the automation tokens and saved host passwords from the Keychain, either with Keychain Access (services "Trellis Automation" and "Trellis SSH Host") or with `security delete-generic-password -s "Trellis Automation"` and `security delete-generic-password -s "Trellis SSH Host"`, repeating until no item is left.

The uninstall plan never includes `~/.ssh` (keys, config, `known_hosts`), shell startup files, or shell history. Deleting a saved host removes its Trellis metadata and its saved password.

## Tested matrix

Only these combinations have been run. Nothing else is claimed.

| macOS | CPU | Build | Result |
| --- | --- | --- | --- |
| 26.6.2 (25G83) | Apple M1 Pro (arm64, native) | Development and release builds | Full automated suite; native checks; qualification run (`scripts/qualify.py`) |
| 26.6.2 | x86_64 slice under Rosetta | Universal release | The CLI executes; **not** a native Intel qualification |

**Not yet tested:** macOS 14 (the declared minimum), macOS 15, native Intel hardware, external displays, and a clean machine.

## Known limits

- **Signing:** no Developer ID signing, notarization, or clean-machine Gatekeeper verification has been performed. The current builds are ad-hoc.
- **Latency:** typing and switching latency are measured through API proxies, not UI frame timing.
- **Accessibility and input:** VoiceOver, real IME, and keyboard-layout checks are pending.
- **SSH:** checks against a real server are pending.
- **Windows:** there is one native terminal window; managed windows live in its sidebar.
- **Updates:** no automatic updates.

## Licenses

SwiftTerm is MIT-licensed. Its license ships as `Trellis.app/Contents/Resources/SwiftTerm-LICENSE.txt`. Its provenance and Trellis's changes to it are in `ThirdParty/SwiftTerm/`.

The bundled terminal fonts are all licensed under the SIL Open Font License 1.1. Each family's license ships as `Trellis.app/Contents/Resources/<Family>-OFL.txt`, and the font files and a second copy of each license are in `Trellis.app/Contents/Resources/Trellis_TrellisCore.bundle/Fonts`. Exact revisions are pinned in `release/manifest.json`.

| Family | Version | Source | Files | Notes |
| --- | --- | --- | --- | --- |
| Roboto Mono | 3.001 | `googlefonts/RobotoMono` | `RobotoMono-*.ttf` | Unmodified. |
| JetBrains Mono | 2.304 | `JetBrains/JetBrainsMono` release | `JetBrainsMono-*.ttf` | Unmodified. |
| Cascadia Mono NF | 2407.24 | `microsoft/cascadia-code` release, `ttf/static` | `CascadiaMonoNF-*.ttf`, `CascadiaMono-OFL.txt` | Unmodified; Reserved Font Name "Cascadia Code". |
| IBM Plex Mono | 2.005 (`@ibm/plex-mono@2.5.0`) | `IBM/plex` release | `IBMPlexMono-*.ttf` | Unmodified; Reserved Font Name "Plex". |
| Iosevka Fixed | 34.9.0 | `be5invis/Iosevka` release, unhinted TTF | `IosevkaFixed-*.ttf` | Modified: subset with `pyftsubset` to Latin, Greek, Cyrillic, punctuation, symbols, arrows, math, box drawing, blocks, Braille, Private Use (Powerline) and legacy-computing ranges with default layout features (stylistic alternates dropped), about 0.5 MB per face instead of 7 MB. The Iosevka license reserves no font name, so the name is kept. |
| Atkinson Hyperlegible Mono | 2.001 | `googlefonts/atkinson-hyperlegible-next-mono`, `fonts/ttf` | `AtkinsonHyperlegibleMono-*.ttf` | Unmodified. |
