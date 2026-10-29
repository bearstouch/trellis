#!/usr/bin/env bash
# Builds the static Linux remote helpers (trellis-broker, FR-RW02) in Docker with the Swift static Linux SDK and writes
# them gzipped, with remote-helpers.json (helper and file SHA-256 digests), to OUT (default: <debug bin path>/remote,
# where `swift run Trellis` finds them). run-feasibility.sh and package-release.sh copy OUT to Contents/Helpers/remote.
# Usage: scripts/build-remote-helpers.sh [OUT]
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
out="${1:-$(cd "$root" && swift build --show-bin-path)/remote}"
image="swift:6.4.1"
sdk_url="https://download.swift.org/swift-6.4.1-release/static-sdk/swift-6.4.1-RELEASE/swift-6.4.1-RELEASE_static-linux-0.1.0.artifactbundle.tar.gz"
sdk_checksum="cef5592d7430ed3c5ae1ddda479849c6f5252bd94a5723db1559f984caf38a7c"
command -v docker >/dev/null || { echo "build-remote-helpers: docker is required" >&2; exit 69; }
mkdir -p "$out"
staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
# The checkout is mounted read-only and copied, so the host's Package.resolved and .build are never touched.
docker run --rm -v trellis-swift-sdks:/root/.swiftpm -v "$root":/src:ro -v "$staging":/out "$image" bash -c "
  set -euo pipefail
  swift sdk list | grep -q static-linux || swift sdk install '$sdk_url' --checksum '$sdk_checksum' >/dev/null
  mkdir -p /work && cp -R /src/Package.swift /src/Sources /src/Tests /work/ && cd /work
  for arch in x86_64 aarch64; do
    swift build -c release --scratch-path /tmp/b --swift-sdk \${arch}-swift-linux-musl --product trellis-broker -Xswiftc -Osize -Xlinker --gc-sections
    llvm-objcopy --strip-all \"\$(swift build -c release --scratch-path /tmp/b --swift-sdk \${arch}-swift-linux-musl --show-bin-path)/trellis-broker\" /out/trellis-broker-linux-\$arch
  done"
python3 - "$staging" "$out" <<'PY'
import gzip, hashlib, json, os, sys
staging, out = sys.argv[1], sys.argv[2]
helpers = []
for arch in ("x86_64", "aarch64"):
    raw = open(os.path.join(staging, f"trellis-broker-linux-{arch}"), "rb").read()
    packed = gzip.compress(raw, compresslevel=9, mtime=0)
    name = f"trellis-broker-linux-{arch}.gz"
    with open(os.path.join(out, name), "wb") as handle:
        handle.write(packed)
    helpers.append({"platform": f"linux-{arch}", "file": name, "digest": hashlib.sha256(raw).hexdigest(),
                    "fileDigest": hashlib.sha256(packed).hexdigest(), "fileSize": len(packed), "compressed": True})
    print(f"linux-{arch}: {len(raw)} bytes, {len(packed)} gzipped, sha256 {helpers[-1]['digest']}")
with open(os.path.join(out, "remote-helpers.json"), "w") as handle:
    json.dump({"helpers": helpers}, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
echo "build-remote-helpers: wrote $out"
