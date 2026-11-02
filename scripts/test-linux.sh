#!/usr/bin/env bash
# Builds and tests the remote helper (trellis-broker, FR-RW02) on Linux in Docker. On Linux the manifest
# declares only the broker targets. Usage: scripts/test-linux.sh [--image swift:6.4.1]
# The checkout is mounted read-only and built from a copy: resolving the Linux manifest (no dependencies) would
# otherwise delete the macOS Package.resolved. Build products stay in .build/linux.
set -euo pipefail
image="swift:6.4.1"
[[ "${1:-}" == "--image" ]] && image="$2"
root="$(cd "$(dirname "$0")/.." && pwd)"
command -v docker >/dev/null || { echo "test-linux: docker is required" >&2; exit 69; }
mkdir -p "$root/.build/linux"
docker run --rm -v "$root":/src:ro -v "$root/.build/linux":/src/.build/linux "$image" bash -c '
  set -euo pipefail
  mkdir -p /work && cp -a /src/Package.swift /src/Sources /src/Tests /work/
  cd /work
  swift build --scratch-path /src/.build/linux 2>&1 | tee /tmp/build.log
  if grep -E "/Sources/[^ ]*: warning:" /tmp/build.log; then echo "test-linux: warnings in project sources" >&2; exit 1; fi
  swift test --scratch-path /src/.build/linux
'
