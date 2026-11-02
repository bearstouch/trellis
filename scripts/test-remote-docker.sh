#!/usr/bin/env bash
# Runs the remote-link tests against a real sshd in a disposable Docker container (FR-RW02, FR-RW03, FR-RW17). Uses a
# throwaway key and known_hosts file; your ~/.ssh is never read or changed. Builds the Linux helpers first if missing.
# Usage: scripts/test-remote-docker.sh
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
command -v docker >/dev/null || { echo "test-remote-docker: docker is required" >&2; exit 69; }
helpers="$root/.build/remote-helpers"
[ -f "$helpers/remote-helpers.json" ] || scripts/build-remote-helpers.sh "$helpers"
work="$(mktemp -d)"
name="trellis-remote-test-$$"
trap 'docker rm -f "$name" >/dev/null 2>&1 || true; rm -rf "$work"' EXIT
ssh-keygen -q -t ed25519 -N "" -C trellis-remote-test -f "$work/key"
docker build -q -t trellis-remote-sshd --build-arg PUBLIC_KEY="$(cat "$work/key.pub")" Tests/Fixtures/remote-sshd >/dev/null
docker run -d --name "$name" -p 127.0.0.1::22 trellis-remote-sshd >/dev/null
port="$(docker port "$name" 22/tcp | head -1 | sed 's/.*://')"
for _ in $(seq 1 50); do
  ssh -i "$work/key" -p "$port" -o UserKnownHostsFile="$work/known_hosts" -o StrictHostKeyChecking=accept-new -o BatchMode=yes \
    dev@127.0.0.1 true 2>/dev/null && break
  sleep 0.2
done
# The host key is now pinned in the throwaway known_hosts; the tests connect with ordinary host-key checking.
export TRELLIS_REMOTE_TEST_DESTINATION="dev@127.0.0.1"
export TRELLIS_REMOTE_TEST_OPTIONS="-p $port -i $work/key -o UserKnownHostsFile=$work/known_hosts"
export TRELLIS_REMOTE_TEST_HELPERS="$helpers"
swift test --filter RemoteDockerTests
