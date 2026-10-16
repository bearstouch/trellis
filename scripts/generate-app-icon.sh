#!/bin/sh
# Regenerate the app icon PNGs, iconset and AppIcon.icns from the SVG sources in Design/AppIcon.
# Requires rsvg-convert (brew install librsvg) and iconutil (Xcode command-line tools).
set -eu
cd "$(dirname "$0")/../Design/AppIcon"
command -v rsvg-convert >/dev/null || { echo "rsvg-convert not found: brew install librsvg" >&2; exit 1; }

render() { rsvg-convert --width "$2" --height "$2" "$1" --output "$3"; }

rm -rf AppIcon.iconset png
mkdir -p AppIcon.iconset png

# 16 and 32 px use the simplified artwork; larger sizes use the full CRT artwork.
for size in 16 32 64 128 256 512 1024; do
    if [ "$size" -le 32 ]; then source=Trellis-small.svg; else source=Trellis.svg; fi
    render "$source" "$size" "png/Trellis-$size.png"
done

cp png/Trellis-16.png AppIcon.iconset/icon_16x16.png
cp png/Trellis-32.png AppIcon.iconset/icon_16x16@2x.png
cp png/Trellis-32.png AppIcon.iconset/icon_32x32.png
cp png/Trellis-64.png AppIcon.iconset/icon_32x32@2x.png
cp png/Trellis-128.png AppIcon.iconset/icon_128x128.png
cp png/Trellis-256.png AppIcon.iconset/icon_128x128@2x.png
cp png/Trellis-256.png AppIcon.iconset/icon_256x256.png
cp png/Trellis-512.png AppIcon.iconset/icon_256x256@2x.png
cp png/Trellis-512.png AppIcon.iconset/icon_512x512.png
cp png/Trellis-1024.png AppIcon.iconset/icon_512x512@2x.png
iconutil --convert icns --output AppIcon.icns AppIcon.iconset

# Menu bar template image (black on transparent; macOS tints it).
render Trellis-menubar.svg 18 png/TrellisMenuBarTemplate.png
render Trellis-menubar.svg 36 png/TrellisMenuBarTemplate@2x.png

echo "Generated $(pwd)/AppIcon.icns"
