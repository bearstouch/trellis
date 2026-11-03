#!/bin/sh
# Regenerate the Settings sidebar icon PNGs from the SVG sources in Design/SettingsIcons.
# 56 px is the 28 pt tile at @2x. Requires rsvg-convert (brew install librsvg).
set -eu
cd "$(dirname "$0")/.."
command -v rsvg-convert >/dev/null || { echo "rsvg-convert not found: brew install librsvg" >&2; exit 1; }

output=Sources/TrellisCore/Resources/SettingsIcons
rm -rf "$output"
mkdir -p "$output"
for source in Design/SettingsIcons/*.svg; do
    rsvg-convert --width 56 --height 56 "$source" --output "$output/$(basename "$source" .svg).png"
done
echo "Generated $output"
