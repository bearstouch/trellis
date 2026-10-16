#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
swift build
bundle=".build/uTerm Feasibility.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp -f .build/debug/uTerm "$bundle/Contents/MacOS/uTerm"
cat > "$bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.uterm.feasibility</string>
<key>CFBundleName</key><string>uTerm Feasibility</string>
<key>CFBundleExecutable</key><string>uTerm</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>NSHighResolutionCapable</key><true/>
<key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
PLIST
# SwiftPM resources can be read-only; replace existing files on repeat runs
# rather than opening them for writing or changing the dependency permissions.
cp -fR .build/debug/SwiftTerm_SwiftTerm.bundle "$bundle/Contents/Resources/"
open -n "$bundle" --args "$@"
