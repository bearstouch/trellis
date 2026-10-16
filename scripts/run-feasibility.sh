#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
launch=true
if [ "${1:-}" = "--build-only" ]; then
    launch=false
    shift
fi
swift build --configuration debug
bin_path=$(swift build --configuration debug --show-bin-path)
destination="$PWD/.build/uTerm Feasibility.app"
staging=$(mktemp -d "$PWD/.build/uterm-feasibility.XXXXXX")
bundle="$staging/uTerm Feasibility.app"
previous="$staging/previous.app"
cleanup() {
    status=$?
    # Restore the previous bundle if publishing the new one failed.
    if [ "$status" -ne 0 ] && [ -d "$previous" ] && [ ! -e "$destination" ]; then
        mv "$previous" "$destination"
    fi
    rm -rf "$staging"
}
trap cleanup 0
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
# Always assemble fresh files: do not overwrite a running executable or merge
# into an old read-only resource tree or stale signature.
cp "$bin_path/uTerm" "$bundle/Contents/MacOS/uTerm"
chmod u+x "$bundle/Contents/MacOS/uTerm"
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
cp -R "$bin_path/SwiftTerm_SwiftTerm.bundle" "$bundle/Contents/Resources/"
cp -R "$bin_path/uTerm_UTermCore.bundle" "$bundle/Contents/Resources/"
# The SwiftPM command-line signature does not seal an app's Info.plist/resources.
# Sign the completed development bundle; no certificate or account is required.
/usr/bin/codesign --force --sign - --identifier dev.uterm.feasibility "$bundle"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$bundle"
if [ -e "$destination" ]; then
    mv "$destination" "$previous"
fi
mv "$bundle" "$destination"
if [ "$launch" = true ]; then
    open -n "$destination" --args "$@"
else
    printf 'Built and verified: %s\n' "$destination"
fi
