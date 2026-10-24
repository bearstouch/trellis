#!/bin/sh
# Builds a Universal 2 release of Trellis with the bundled `trellis` CLI, signs
# it with the hardened runtime, packages a DMG, optionally notarizes and
# staples, verifies, and records evidence in dist/release-evidence.json.
#
#   TRELLIS_SIGN_IDENTITY   "Developer ID Application: …" (default "-" = ad-hoc, not distributable)
#   TRELLIS_NOTARY_PROFILE  notarytool keychain profile; notarization is skipped when unset
set -eu
cd "$(dirname "$0")/.."
identity="${TRELLIS_SIGN_IDENTITY:--}"
version=$(python3 -c 'import json;print(json.load(open("release/manifest.json"))["version"])')
minimum=$(python3 -c 'import json;print(json.load(open("release/manifest.json"))["minimumMacOS"])')
# MAC-14: a build gets an update feed only when the manifest records the Sparkle public key.
sparkle_key=$(python3 -c 'import json;print(json.load(open("release/manifest.json")).get("sparklePublicKey") or "")')
feed_url="https://raw.githubusercontent.com/bearstouch/trellis/appcast/appcast.xml"
# macOS wants numeric bundle versions: CFBundleShortVersionString is the X.Y.Z core, and CFBundleVersion adds a build
# that orders pre-releases before the release (alpha.N = N, beta.N = 30+N, rc.N = 60+N, release = 100). The full
# version, label included, goes to TrellisVersion for the app to show.
bundle_versions=$(python3 - "$version" <<'PY'
import re, sys
match = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)(?:-(alpha|beta|rc)\.([1-9]\d?))?", sys.argv[1])
if not match or (match[5] and int(match[5]) >= 30): sys.exit(f"Unsupported version {sys.argv[1]!r}: use X.Y.Z or X.Y.Z-alpha|beta|rc.N with N < 30.")
core = ".".join(match.group(1, 2, 3))
build = 100 if not match[4] else {"alpha": 0, "beta": 30, "rc": 60}[match[4]] + int(match[5])
print(core, f"{core}.{build}")
PY
)
short_version=${bundle_versions% *}
bundle_version=${bundle_versions#* }
dist="$PWD/dist"
rm -rf "$dist"
mkdir -p "$dist"

# Per-architecture native builds (the multi-arch Xcode path needs a Metal
# toolchain for SwiftTerm's shader), combined into Universal 2 with lipo.
for arch in arm64 x86_64; do
    for product in Trellis trellis-cli trellis-askpass trellis-broker; do
        swift build --configuration release --triple "$arch-apple-macosx$minimum" --product "$product"
    done
done
arm=$(swift build --configuration release --triple "arm64-apple-macosx$minimum" --show-bin-path)
intel=$(swift build --configuration release --triple "x86_64-apple-macosx$minimum" --show-bin-path)
bin="$dist/universal"
mkdir -p "$bin"
for product in Trellis trellis-cli trellis-askpass trellis-broker; do
    /usr/bin/lipo -create "$arm/$product" "$intel/$product" -output "$bin/$product"
done
# Resource bundles are architecture-independent; Sparkle's framework is already Universal 2.
cp -R "$arm/SwiftTerm_SwiftTerm.bundle" "$arm/Trellis_TrellisCore.bundle" "$bin/"
/usr/bin/ditto "$arm/Sparkle.framework" "$bin/Sparkle.framework"

app="$dist/Trellis.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers" "$app/Contents/Resources" "$app/Contents/Frameworks"
cp "$bin/Trellis" "$app/Contents/MacOS/Trellis"
cp "$bin/trellis-cli" "$app/Contents/Helpers/trellis"
cp "$bin/trellis-askpass" "$app/Contents/Helpers/trellis-askpass"
cp "$bin/trellis-broker" "$app/Contents/Helpers/trellis-broker"
cp -R "$bin/SwiftTerm_SwiftTerm.bundle" "$bin/Trellis_TrellisCore.bundle" "$app/Contents/Resources/"
/usr/bin/ditto "$bin/Sparkle.framework" "$app/Contents/Frameworks/Sparkle.framework"
rm -rf "$bin"
cp Design/AppIcon/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cp ThirdParty/SwiftTerm-LICENSE.txt "$app/Contents/Resources/SwiftTerm-LICENSE.txt"
cp ThirdParty/Sparkle-LICENSE.txt "$app/Contents/Resources/Sparkle-LICENSE.txt"
if [ -n "$sparkle_key" ]; then
    updates="<key>SUFeedURL</key><string>$feed_url</string>
<key>SUPublicEDKey</key><string>$sparkle_key</string>
<key>SUEnableAutomaticChecks</key><false/>
<key>SUEnableSystemProfiling</key><false/>"
else
    echo "warning: release/manifest.json has no sparklePublicKey; this build has no updater." >&2
    updates=""
fi
cp Sources/TrellisCore/Resources/Fonts/*-OFL.txt "$app/Contents/Resources/"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.bearstouch.trellis</string>
<key>CFBundleName</key><string>Trellis</string>
<key>CFBundleExecutable</key><string>Trellis</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$short_version</string>
<key>CFBundleVersion</key><string>$bundle_version</string>
<key>TrellisVersion</key><string>$version</string>
<key>NSHighResolutionCapable</key><true/>
<key>LSMinimumSystemVersion</key><string>$minimum</string>
$updates
</dict></plist>
PLIST

# Hardened runtime, no entitlements: no sandbox exceptions, no privacy prompts.
sign() {
    if [ "$identity" = "-" ]; then
        /usr/bin/codesign --force --options runtime --sign - --identifier "$2" "$1"
    else
        /usr/bin/codesign --force --options runtime --timestamp --sign "$identity" --identifier "$2" "$1"
    fi
}
sign "$app/Contents/Helpers/trellis" com.bearstouch.trellis.cli
sign "$app/Contents/Helpers/trellis-askpass" com.bearstouch.trellis.askpass
sign "$app/Contents/Helpers/trellis-broker" com.bearstouch.trellis.broker
scripts/sign-sparkle.sh "$app" "$identity"
# Ad-hoc signatures have no Team ID, so library validation would refuse the embedded Sparkle.framework. Only these
# non-distributable builds relax it; Developer ID builds keep library validation.
if [ "$identity" = "-" ]; then
    entitlements="$dist/adhoc.entitlements"
    printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
        '<plist version="1.0"><dict><key>com.apple.security.cs.disable-library-validation</key><true/></dict></plist>' > "$entitlements"
    /usr/bin/codesign --force --options runtime --sign - --identifier com.bearstouch.trellis --entitlements "$entitlements" "$app"
else
    sign "$app" com.bearstouch.trellis
fi

dmg="$dist/Trellis-$version.dmg"
scripts/make-dmg.sh "$app" "$dmg" "Trellis $version"
if [ "$identity" != "-" ]; then /usr/bin/codesign --force --timestamp --sign "$identity" "$dmg"; fi

notarized=false
stapled=false
notary_requested=false
if [ -n "${TRELLIS_NOTARY_PROFILE:-}" ] && [ "$identity" != "-" ]; then
    notary_requested=true
    /usr/bin/xcrun notarytool submit "$dmg" --keychain-profile "$TRELLIS_NOTARY_PROFILE" --wait && notarized=true
    if [ "$notarized" = true ]; then
        /usr/bin/xcrun stapler staple "$app" && /usr/bin/xcrun stapler staple "$dmg" && stapled=true
    fi
fi

verified=false
/usr/bin/codesign --verify --deep --strict --verbose=2 "$app" && verified=true
runtime=false
# The CodeDirectory flags list "runtime" for hardened-runtime signatures (with or without adhoc).
/usr/bin/codesign --display --verbose=4 "$app" 2>&1 | grep -Eq "^CodeDirectory .*flags=0x[0-9a-f]+\([^)]*runtime" && \
    /usr/bin/codesign --display --verbose=4 "$app/Contents/Helpers/trellis" 2>&1 | grep -Eq "^CodeDirectory .*flags=0x[0-9a-f]+\([^)]*runtime" && \
    /usr/bin/codesign --display --verbose=4 "$app/Contents/Helpers/trellis-askpass" 2>&1 | grep -Eq "^CodeDirectory .*flags=0x[0-9a-f]+\([^)]*runtime" && \
    /usr/bin/codesign --display --verbose=4 "$app/Contents/Helpers/trellis-broker" 2>&1 | grep -Eq "^CodeDirectory .*flags=0x[0-9a-f]+\([^)]*runtime" && \
    /usr/bin/codesign --display --verbose=4 "$app/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate" 2>&1 | grep -Eq "^CodeDirectory .*flags=0x[0-9a-f]+\([^)]*runtime" && runtime=true
gatekeeper=$(/usr/sbin/spctl --assess --type execute --verbose=2 "$app" 2>&1 || true)
python3 - "$app" "$dmg" "$identity" "$verified" "$runtime" "$notarized" "$stapled" "$gatekeeper" "$notary_requested" <<'PY'
import json, plistlib, subprocess, sys, os
app, dmg, identity, verified, runtime, notarized, stapled, gatekeeper, notary_requested = sys.argv[1:]
manifest = json.load(open("release/manifest.json"))
info = plistlib.load(open(os.path.join(app, "Contents/Info.plist"), "rb"))
archs = lambda p: sorted(subprocess.run(["lipo", "-archs", p], capture_output=True, text=True).stdout.split())
files = {a for a in manifest["artifacts"] if os.path.exists(os.path.join(os.path.dirname(app), a))}
problems = []
if info["LSMinimumSystemVersion"] != manifest["minimumMacOS"]: problems.append("minimum macOS mismatch")
if info["CFBundleIdentifier"] != manifest["bundleIdentifier"]: problems.append("bundle identifier mismatch")
if info.get("TrellisVersion") != manifest["version"] or not manifest["version"].startswith(info["CFBundleShortVersionString"]): problems.append("version mismatch")
for binary in ["Contents/MacOS/Trellis", "Contents/Helpers/trellis", "Contents/Helpers/trellis-askpass", "Contents/Helpers/trellis-broker"]:
    missing = set(manifest["architectures"]) - set(archs(os.path.join(app, binary)))
    if missing: problems.append(f"{binary} lacks {sorted(missing)}")
problems += [f"missing {a}" for a in manifest["artifacts"] if a not in files]
if info.get("SUPublicEDKey", "") != (manifest.get("sparklePublicKey") or ""): problems.append("SUPublicEDKey does not match the manifest")
entitlements = subprocess.run(["codesign", "--display", "--entitlements", "-", app], capture_output=True, text=True).stdout
if identity != "-" and "disable-library-validation" in entitlements: problems.append("a distributable build must keep library validation")
# A requested notarization that fails must not leave a "successful" signed build behind.
if notary_requested == "true" and stapled != "true": problems.append("notarization or stapling failed")
evidence = {
    "version": manifest["version"], "dmg": os.path.basename(dmg), "signingIdentity": "ad-hoc (not distributable)" if identity == "-" else identity,
    "architectures": {"app": archs(os.path.join(app, "Contents/MacOS/Trellis")), "cli": archs(os.path.join(app, "Contents/Helpers/trellis"))},
    "minimumMacOS": info["LSMinimumSystemVersion"], "signatureVerified": verified == "true", "hardenedRuntime": runtime == "true",
    "notarized": notarized == "true", "stapled": stapled == "true", "gatekeeperLocal": gatekeeper.strip(),
    "updateFeed": info.get("SUFeedURL"), "manifestProblems": problems,
}
json.dump(evidence, open(os.path.join(os.path.dirname(app), "release-evidence.json"), "w"), indent=2)
print(json.dumps(evidence, indent=2))
sys.exit(1 if problems or verified != "true" else 0)
PY
