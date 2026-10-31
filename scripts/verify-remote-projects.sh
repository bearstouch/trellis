#!/usr/bin/env bash
# Guided manual verification of remote workspaces (FR-RW) and the project library (FR-PL) before merging.
#
# It builds the app and the Linux helpers, starts a disposable SSH host in Docker (with git and two bare repositories
# to clone), launches an isolated Trellis instance with that host saved, then walks through each check: it tells you
# what to do in the app, verifies on the host what it can, and asks what you saw. A report is written at the end.
#
# Nothing of yours is used: a separate state directory, a throwaway key, and a host on 127.0.0.1:2299. The one thing it
# touches is ~/.ssh/known_hosts, when you accept the test host's key in Trellis's ssh console (step 1); the host key is
# kept between runs so that entry stays valid. Remove it with: ssh-keygen -R "[127.0.0.1]:2299"
#
# Usage: scripts/verify-remote-projects.sh [--keep]     (--keep leaves the container and app running at the end)
# Needs: Docker, the Swift toolchain, network access for apt (once) and for the GitHub clone in the local step.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
keep=false; [ "${1:-}" = --keep ] && keep=true
command -v docker >/dev/null || { echo "Docker is required." >&2; exit 69; }

work="$root/.build/manual-verify"
port=2299
name=trellis-verify-host
image=trellis-verify-sshd
mkdir -p "$work"
state="$work/state"; projects="$work/projects"; logfile="$work/trellis.log"; report="$work/report.md"
results=()

bold() { printf '\n\033[1m%s\033[0m\n' "$*"; }
note() { printf '   %s\n' "$*"; }
ok() { printf '   \033[32m✓ %s\033[0m\n' "$*"; }
bad() { printf '   \033[31m✗ %s\033[0m\n' "$*"; }
pause() { read -r -p "   ↩  Press Return when done… " _; }
remote() { ssh -i "$work/key" -p "$port" -o UserKnownHostsFile="$work/known_hosts" -o StrictHostKeyChecking=accept-new -o BatchMode=yes dev@127.0.0.1 "$@"; }
# check "<what>" <command…>: an automatic check, recorded.
check() {
  local what="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$what"; results+=("| auto | $what | pass |"); else bad "$what"; results+=("| auto | $what | **fail** |"); fi
}
# ask "<what you should have seen>": your observation, recorded.
ask() {
  local answer
  while true; do
    read -r -p "   ?  $1 [y/n/s=skip] " answer
    case "$answer" in
      y|Y) results+=("| manual | $1 | pass |"); return ;;
      n|N) read -r -p "      What went wrong? " why; results+=("| manual | $1 | **fail**: ${why//|/\/} |"); return ;;
      s|S) results+=("| manual | $1 | skipped |"); return ;;
    esac
  done
}
app_pid() { pgrep -f "Debug/Trellis --state-directory $state" | head -1 || true; }
launch_app() {
  "$bin/Trellis" --state-directory "$state" >>"$logfile" 2>&1 &
  sleep 3
  [ -n "$(app_pid)" ] && note "Trellis is running (PID $(app_pid))." || { bad "Trellis didn't start; see $logfile"; exit 1; }
}
cleanup() {
  $keep && { note "Left running (--keep): container $name and Trellis. Stop them with: docker rm -f $name; pkill -f 'state-directory $state'"; return; }
  pkill -f "Debug/Trellis --state-directory $state" 2>/dev/null || true
  docker rm -f "$name" >/dev/null 2>&1 || true
}
trap cleanup EXIT

bold "Setup"
note "Building Trellis and the Linux helpers (the helpers need Docker; a few minutes the first time)…"
swift build >/dev/null
bin="$(swift build --show-bin-path)"
scripts/build-remote-helpers.sh "$bin/remote" >/dev/null
[ -f "$work/key" ] || ssh-keygen -q -t ed25519 -N "" -C trellis-verify -f "$work/key"
# A stable host key, so the entry Trellis's ssh adds to ~/.ssh/known_hosts stays valid on the next run.
[ -f "$work/ssh_host_ed25519_key" ] || ssh-keygen -q -t ed25519 -N "" -C trellis-verify-host -f "$work/ssh_host_ed25519_key"
cat >"$work/Dockerfile" <<'EOF'
FROM trellis-remote-sshd
RUN apt-get update -qq && apt-get install -y -qq git openssh-client >/dev/null && rm -rf /var/lib/apt/lists/*
COPY ssh_host_ed25519_key ssh_host_ed25519_key.pub /etc/ssh/
RUN chmod 600 /etc/ssh/ssh_host_ed25519_key && rm -f /etc/ssh/ssh_host_rsa_key* /etc/ssh/ssh_host_ecdsa_key*
EOF
docker build -q -t trellis-remote-sshd --build-arg PUBLIC_KEY="$(cat "$work/key.pub")" Tests/Fixtures/remote-sshd >/dev/null
docker build -q -t "$image" -f "$work/Dockerfile" "$work" >/dev/null
docker rm -f "$name" >/dev/null 2>&1 || true
docker run -d --name "$name" -p "127.0.0.1:$port:22" "$image" >/dev/null
for _ in $(seq 1 50); do remote true 2>/dev/null && break; sleep 0.2; done
remote true || { bad "The test host doesn't accept the key"; exit 1; }
ok "Test host up on 127.0.0.1:$port (user dev, Debian, $(remote uname -m))"

# Two bare repositories on the host, cloned over ssh to the host itself (dev@localhost:repos/<name>.git).
remote 'set -e
  mkdir -p ~/.ssh && [ -f ~/.ssh/id_ed25519 ] || ssh-keygen -q -t ed25519 -N "" -f ~/.ssh/id_ed25519
  cat ~/.ssh/id_ed25519.pub >> ~/.ssh/authorized_keys
  printf "Host localhost\n  StrictHostKeyChecking accept-new\n" > ~/.ssh/config; chmod 600 ~/.ssh/config
  git config --global user.email dev@verify; git config --global user.name Dev; git config --global init.defaultBranch main
  for repo in api web; do
    git init -q --bare ~/repos/$repo.git
    rm -rf /tmp/seed && git init -q /tmp/seed && cd /tmp/seed
    echo "# $repo" > README.md && git add README.md && git commit -qm "Initial $repo"
    git push -q ~/repos/$repo.git main
  done'
ok "Bare repositories on the host: repos/api.git, repos/web.git"

# A fresh, isolated Trellis state with the test host saved.
rm -rf "$state" "$projects" "$work/local"
mkdir -p "$state" "$projects" "$work/local"
chmod 700 "$state"
host_id="$(uuidgen)"
cat >"$state/hosts.json" <<EOF
{"schemaVersion": 1, "revision": 1, "hosts": [{"id": "$host_id", "name": "Verify Box", "destination": "127.0.0.1", "user": "dev", "port": $port,
  "identityFile": "$work/key", "tags": ["verify"], "revision": 1, "connectionRevision": 1}]}
EOF
chmod 600 "$state/hosts.json"
cat >"$projects/remote-shop.json" <<'EOF'
{
  "name": "Verify Shop",
  "notes": "Remote project for manual verification",
  "tabs": [
    {"title": "API", "color": "green", "directory": "api", "repository": {"url": "dev@localhost:repos/api.git"},
     "root": {"type": "split", "axis": "x", "ratio": 0.5, "children": [
       {"type": "pane", "title": "Log", "command": "git log --oneline -1"},
       {"type": "pane", "title": "Shell"}]}},
    {"title": "Web", "color": "blue", "repository": {"url": "dev@localhost:repos/web.git", "branch": "main"}, "directory": "web",
     "root": {"type": "pane", "command": "cat README.md"}}
  ]
}
EOF
cat >"$projects/local-hello.json" <<'EOF'
{"name": "Verify Hello", "tabs": [{"title": "Hello", "directory": "hello", "repository": {"url": "https://github.com/octocat/Hello-World.git"},
 "root": {"type": "pane", "command": "git log --oneline -1"}}]}
EOF
cat >"$projects/broken.json" <<'EOF'
{"name": "Verify Broken", "tabs": [{"title": "Missing", "directory": "missing", "repository": {"url": "dev@localhost:repos/missing.git"}}]}
EOF
ok "Project files to import: $projects"
: >"$logfile"
launch_app

bold "1 · Install the helper (FR-RW17, FR-RW02)"
note "Hosts (sidebar bottom) → select “Verify Box” → Check Helper Status, then Install Trellis Helper…"
note "The ssh console asks to accept the host key the first time: type yes. Then confirm the install sheet."
pause
check "Helper installed under ~/.trellis/remote, owner-only" remote 'f=$(ls ~/.trellis/remote/*/trellis-broker | head -1) && [ "$(stat -c %a "$f")" = 700 ]'
check "Nothing written outside ~/.trellis (no other new dot-folders)" remote '[ "$(ls -A ~ | grep -v -E "^(\.trellis|\.ssh|\.gitconfig|repos|\.bash_logout|\.bashrc|\.profile|\.bash_history|code)$" | wc -l)" = 0 ]'
ask "The status line said Installed, up to date (Linux $(remote uname -m))"

bold "2 · Open a remote workspace (FR-RW01, FR-RW04)"
note "Same host → Open Remote Workspace. In the new window's pane run:"
note "    cd /tmp && sleep 900 & for i in \$(seq 1 40); do echo line-\$i; sleep 1; done"
pause
check "The shell runs on the host (sleep 900 is there)" remote 'pgrep -u dev -f "sleep 900"'
ask "The sidebar shows the window as Connected · Verify Box, and the pane header shows Verify Box's path (/tmp)"
note "Now split the pane (⌘D)."
pause
ask "The new pane opened in /tmp on the host (run pwd in it)"

bold "3 · Survive a network drop (FR-RW06–FR-RW08)"
note "Run the line counter again in a pane, then press Return here: the host is frozen for 25 s."
note "    for i in \$(seq 1 60); do echo line-\$i; sleep 1; done"
pause
docker pause "$name" >/dev/null; note "Host paused…"; sleep 25; docker unpause "$name" >/dev/null; note "Host back."
pause
ask "The sidebar went to Reconnecting (with an attempt number) and back to Connected on its own"
ask "The counter continued with no repeated or missing line numbers"

bold "4 · Quit and relaunch (FR-RW06, FR-RW09)"
note "Quit Trellis now (⌘Q)."
while [ -n "$(app_pid)" ]; do sleep 1; done
check "The host's sessions kept running after quit" remote 'pgrep -u dev -f "sleep 900"'
note "Relaunching…"; launch_app
pause
ask "The remote window came back and its panes re-attached with their earlier output"

bold "5 · Project library: import and edit (FR-PL01–FR-PL04)"
note "Projects (sidebar bottom, or ⌘O) → Import JSON… → $projects/remote-shop.json → Add Project."
note "Try the form: select tabs and panes, change a title, switch Form/JSON and back, Save."
pause
check "projects.json is stored owner-only" test "$(stat -f %Lp "$state/projects.json")" = 600
ask "The form showed the API split, the Web tab, and each repository; JSON and Form matched; Save worked"

bold "6 · Launch on the host: set up and open (FR-PL06–FR-PL08, FR-RW18)"
note "Select Verify Shop → Launch… → target Verify Box, folder code/shop → Set Up & Open."
pause
check "api was cloned on the host" remote 'test -d ~/code/shop/api/.git'
check "web was cloned on the host, branch main" remote '[ "$(git -C ~/code/shop/web rev-parse --abbrev-ref HEAD)" = main ]'
ask "The plan listed Create ~/code/shop and two clones; the setup terminal showed git; the window opened bound to Verify Box"
ask "The Log pane printed the api commit and the Web tab printed # web (each command ran once)"
ask "Pane headers show the git branch (main)"

bold "7 · Launch again with one repository missing (FR-PL07, FR-PL08)"
remote 'rm -rf ~/code/shop/web'
note "web was removed on the host. Launch Verify Shop on Verify Box again (same folder)."
pause
check "web was cloned again" remote 'test -d ~/code/shop/web/.git'
ask "The plan listed only the web clone, and the same window was selected (no second window)"

bold "8 · Git status (FR-PL09)"
note "In the API pane run:  cd ~/code/shop/api && touch new.txt"
pause
ask "The header shows main ●1 (and VoiceOver, if on, reads Git branch main, 1 change)"

bold "9 · A failing setup (FR-PL07)"
note "Import $projects/broken.json, add it, Launch on Verify Box (folder code/broken) → Set Up & Open."
pause
check "Nothing was cloned for the missing repository" remote '! test -e ~/code/broken/missing'
ask "The sheet stayed open with git's error and Retry / Open Anyway / Cancel; Cancel closed it with no window"

bold "10 · Launch on this Mac (FR-PL06–FR-PL08)"
note "Import $projects/local-hello.json, add it, Launch on This Mac, folder $work/local/hello-project → Set Up & Open."
note "(This clone comes from GitHub over https.)"
pause
check "The repository was cloned on this Mac" test -d "$work/local/hello-project/hello/.git"
ask "A local window opened and its pane printed the latest commit"

bold "11 · Export a project (FR-PL04)"
note "Select Verify Shop → Export JSON… → save it as $work/exported.json"
pause
check "The exported file has the project and no launch history" sh -c "grep -q 'Verify Shop' '$work/exported.json' && ! grep -q 'code/shop' '$work/exported.json'"

bold "12 · Session broker status (Settings → Sessions)"
note "Settings → Sessions → Session broker → Refresh."
pause
ask "It shows this Mac's broker (PID, protocol 3, sessions) and Verify Box's broker (Linux, PID, sessions)"

bold "13 · Remove the helper (FR-RW17)"
note "Close the remote windows (stopping their sessions), then Hosts → Verify Box → Remove Helper…"
pause
check "The helper is gone from the host" remote '! test -e ~/.trellis/remote'

{
  echo "# Manual verification: remote workspaces + project library"
  echo
  echo "- Date: $(date '+%Y-%m-%d %H:%M')"
  echo "- Commit: $(git rev-parse --short HEAD) ($(git rev-parse --abbrev-ref HEAD))"
  echo "- Host: Debian ($(remote uname -m 2>/dev/null || echo unknown)) in Docker; macOS $(sw_vers -productVersion)"
  echo
  echo "| Kind | Check | Result |"
  echo "| --- | --- | --- |"
  printf '%s\n' "${results[@]}"
} >"$report"
bold "Done"
fails=$(printf '%s\n' "${results[@]}" | grep -c '\*\*fail' || true)
note "$(( ${#results[@]} - fails )) of ${#results[@]} checks passed or were skipped; $fails failed."
note "Report: $report"
note "Trellis log: $logfile"
