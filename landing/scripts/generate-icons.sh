#!/bin/sh
# Renders the site icons in public/ from the app icon artwork in ../Design/AppIcon.
# Requires rsvg-convert (brew install librsvg) and ImageMagick (brew install imagemagick).
set -eu
cd "$(dirname "$0")/.."
art=../Design/AppIcon
out=public
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
render() { rsvg-convert --width "$2" --height "$2" "$1" --output "$3"; }
# Opaque on the page background: iOS and Android masks show transparency as black or white.
flatten() { magick "$1" -background "#0c0c0e" -flatten "$2"; }

# 16–48 px use the simplified artwork, like the app's own small icons.
cp "$art/Trellis-small.svg" "$out/favicon.svg"
for size in 16 32 48; do render "$art/Trellis-small.svg" "$size" "$tmp/$size.png"; done
magick "$tmp/16.png" "$tmp/32.png" "$tmp/48.png" "$out/favicon.ico"

render "$art/Trellis.svg" 192 "$out/icon-192.png"
render "$art/Trellis.svg" 512 "$out/icon-512.png"
render "$art/Trellis.svg" 180 "$tmp/180.png"; flatten "$tmp/180.png" "$out/apple-touch-icon.png"
render "$art/Trellis.svg" 512 "$tmp/m.png"; flatten "$tmp/m.png" "$out/icon-maskable-512.png"
ls -1 "$out"/favicon.* "$out"/icon-*.png "$out"/apple-touch-icon.png
