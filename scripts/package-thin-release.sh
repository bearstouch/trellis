#!/bin/sh
# Derives single-architecture DMGs (Apple silicon and Intel) from the Universal 2
# dist/Trellis.app produced by scripts/package-release.sh. Each thinned app is re-signed,
# packaged, and notarized/stapled with the same TRELLIS_SIGN_IDENTITY / TRELLIS_NOTARY_PROFILE.
set -eu
cd "$(dirname "$0")/.."
identity="${TRELLIS_SIGN_IDENTITY:--}"
version=$(python3 -c 'import json;print(json.load(open("release/manifest.json"))["version"])')
universal="$PWD/dist/Trellis.app"
[ -d "$universal" ] || { echo "Run scripts/package-release.sh first." >&2; exit 1; }

sign() {
    if [ "$identity" = "-" ]; then
        /usr/bin/codesign --force --options runtime --sign - --identifier "$2" "$1"
    else
        /usr/bin/codesign --force --options runtime --timestamp --sign "$identity" --identifier "$2" "$1"
    fi
}

for pair in arm64:apple-silicon x86_64:intel; do
    arch=${pair%%:*}; label=${pair#*:}
    stage="$PWD/dist/$label"
    rm -rf "$stage"; mkdir -p "$stage"
    app="$stage/Trellis.app"
    cp -R "$universal" "$app"
    for binary in Contents/MacOS/Trellis Contents/Helpers/trellis Contents/Helpers/trellis-askpass Contents/Helpers/trellis-broker; do
        /usr/bin/lipo -thin "$arch" "$app/$binary" -output "$app/$binary.thin"
        mv "$app/$binary.thin" "$app/$binary"
    done
    sign "$app/Contents/Helpers/trellis" com.bearstouch.trellis.cli
    sign "$app/Contents/Helpers/trellis-askpass" com.bearstouch.trellis.askpass
    sign "$app/Contents/Helpers/trellis-broker" com.bearstouch.trellis.broker
    sign "$app" com.bearstouch.trellis
    /usr/bin/codesign --verify --deep --strict "$app"
    [ "$(/usr/bin/lipo -archs "$app/Contents/MacOS/Trellis")" = "$arch" ] || { echo "$label app is not $arch" >&2; exit 1; }
    [ "$(/usr/bin/lipo -archs "$app/Contents/Helpers/trellis")" = "$arch" ] || { echo "$label CLI is not $arch" >&2; exit 1; }

    dmg="$PWD/dist/Trellis-$version-$label.dmg"
    scripts/make-dmg.sh "$app" "$dmg" "Trellis $version"
    if [ "$identity" != "-" ]; then
        /usr/bin/codesign --force --timestamp --sign "$identity" "$dmg"
        if [ -n "${TRELLIS_NOTARY_PROFILE:-}" ]; then
            /usr/bin/xcrun notarytool submit "$dmg" --keychain-profile "$TRELLIS_NOTARY_PROFILE" --wait
            /usr/bin/xcrun stapler staple "$dmg"
        fi
    fi
    rm -rf "$stage"
    echo "$dmg ($arch)"
done
