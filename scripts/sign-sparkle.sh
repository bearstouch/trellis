#!/bin/sh
# Prepares and signs Trellis.app/Contents/Frameworks/Sparkle.framework (MAC-14), inside-out, before the app is signed.
#
#   scripts/sign-sparkle.sh <Trellis.app> <identity|-> [arm64|x86_64]
#
# Trellis isn't sandboxed, so Sparkle's XPC services are removed. With an architecture, every binary is thinned to it.
set -eu
app=$1; identity=$2; arch=${3:-}
framework="$app/Contents/Frameworks/Sparkle.framework"
[ -d "$framework" ] || { echo "No Sparkle.framework in $app" >&2; exit 1; }
rm -rf "$framework/Versions/B/XPCServices" "$framework/XPCServices"
if [ -n "$arch" ]; then
    for binary in Versions/B/Sparkle Versions/B/Autoupdate Versions/B/Updater.app/Contents/MacOS/Updater; do
        /usr/bin/lipo -thin "$arch" "$framework/$binary" -output "$framework/$binary.thin"
        mv "$framework/$binary.thin" "$framework/$binary"
    done
fi
sign() {
    if [ "$identity" = "-" ]; then
        /usr/bin/codesign --force --options runtime --sign - "$1"
    else
        /usr/bin/codesign --force --options runtime --timestamp --sign "$identity" "$1"
    fi
}
sign "$framework/Versions/B/Autoupdate"
sign "$framework/Versions/B/Updater.app"
sign "$framework"
