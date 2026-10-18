#!/bin/sh
# Renders og/og.html to public/og.png (1200x630) with headless Google Chrome.
set -eu
cd "$(dirname "$0")/.."
chrome="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
"$chrome" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=1 --allow-file-access-from-files \
    --window-size=1200,630 --virtual-time-budget=3000 --screenshot="$PWD/public/og.png" "file://$PWD/og/og.html" 2>/dev/null
echo "public/og.png"
