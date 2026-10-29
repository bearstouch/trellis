#!/usr/bin/env bash
# Builds the static Linux remote helpers (trellis-broker, FR-RW02) with the Swift static Linux SDK and writes them
# gzipped, with remote-helpers.json (helper and file SHA-256 digests), to OUT (default: <debug bin path>/remote, where
# `swift run Trellis` finds them). run-feasibility.sh and package-release.sh copy OUT to Contents/Resources/remote.
#
# On macOS it runs in Docker; on Linux with Swift installed (the release workflow's container) it builds directly.
# Usage: scripts/build-remote-helpers.sh [OUT]
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
version="6.4.1"
sdk_url="https://download.swift.org/swift-${version}-release/static-sdk/swift-${version}-RELEASE/swift-${version}-RELEASE_static-linux-0.1.0.artifactbundle.tar.gz"
sdk_checksum="cef5592d7430ed3c5ae1ddda479849c6f5252bd94a5723db1559f984caf38a7c"
staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT

build() {
  # $1: a copy of the package, so the checkout's Package.resolved and .build are never touched.
  swift sdk list | grep -q static-linux || swift sdk install "$sdk_url" --checksum "$sdk_checksum" >/dev/null
  cd "$1"
  for arch in x86_64 aarch64; do
    swift build -c release --scratch-path /tmp/trellis-remote-build --swift-sdk "${arch}-swift-linux-musl" --product trellis-broker -Xswiftc -Osize -Xlinker --gc-sections
    llvm-objcopy --strip-all "$(swift build -c release --scratch-path /tmp/trellis-remote-build --swift-sdk "${arch}-swift-linux-musl" --show-bin-path)/trellis-broker" \
      "$staging/trellis-broker-linux-$arch"
  done
}

if [ "${1:-}" = --inside ]; then
  # Re-entered inside the container: $2 is the read-only checkout, $3 the staging folder.
  staging="$3"; trap - EXIT
  work="$(mktemp -d)"; cp -R "$2/Package.swift" "$2/Sources" "$2/Tests" "$work/"
  build "$work"
  exit 0
fi

out="${1:-}"
if [ "$(uname -s)" = Linux ] && command -v swift >/dev/null; then
  out="${out:-$root/.build/remote-helpers}"
  work="$(mktemp -d)"; cp -R "$root/Package.swift" "$root/Sources" "$root/Tests" "$work/"
  (build "$work")
else
  command -v docker >/dev/null || { echo "build-remote-helpers: docker is required on macOS" >&2; exit 69; }
  out="${out:-$(cd "$root" && swift build --show-bin-path)/remote}"
  docker run --rm -v trellis-swift-sdks:/root/.swiftpm -v "$root":/src:ro -v "$staging":/out "swift:$version" /src/scripts/build-remote-helpers.sh --inside /src /out
fi

sha256() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }
mkdir -p "$out"
rm -f "$out"/trellis-broker-linux-*.gz
entries=""
for arch in x86_64 aarch64; do
  raw="$staging/trellis-broker-linux-$arch"
  packed="$out/trellis-broker-linux-$arch.gz"
  gzip -9 -n -c "$raw" > "$packed"
  digest="$(sha256 "$raw")"; file_digest="$(sha256 "$packed")"; size="$(wc -c < "$packed" | tr -d ' ')"
  echo "linux-$arch: $(wc -c < "$raw" | tr -d ' ') bytes, $size gzipped, sha256 $digest"
  entries="$entries${entries:+,}
    {\"compressed\": true, \"digest\": \"$digest\", \"file\": \"trellis-broker-linux-$arch.gz\", \"fileDigest\": \"$file_digest\", \"fileSize\": $size, \"platform\": \"linux-$arch\"}"
done
printf '{\n  "helpers": [%s\n  ]\n}\n' "$entries" > "$out/remote-helpers.json"
# The MIT notices of the libraries linked into the helpers travel with them (ThirdParty/RemoteHelpers/README.md).
cp "$root/ThirdParty/RemoteHelpers/musl-COPYRIGHT.txt" "$root/ThirdParty/RemoteHelpers/mimalloc-LICENSE.txt" "$root/ThirdParty/RemoteHelpers/musl-fts-COPYING.txt" "$out/"
echo "build-remote-helpers: wrote $out"
