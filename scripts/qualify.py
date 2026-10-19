#!/usr/bin/env python3
"""Release-build qualification: launch, latency, capacity, memory, flood, and cleanup targets.

Runs the release app on isolated temporary state directories, drives it over
the real control socket with a seeded test grant, and writes a Markdown report.
It never touches the user's workspace, Keychain, or saved hosts.

Usage: scripts/qualify.py [--quick] [--renderer metal|coregraphics] [--report PATH]
"""
import argparse, base64, datetime, hashlib, json, math, os, platform, shutil, signal, socket, subprocess, sys, tempfile, time, uuid

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def p95(samples, minimum=20):
    """Nearest-rank p95, matching MeasurementSummary; None when too few samples."""
    values = sorted(s for s in samples if s is not None and math.isfinite(s))
    if len(values) < minimum:
        return None
    rank = lambda q: values[max(0, math.ceil(q * len(values)) - 1)]
    return {"p50": rank(0.5), "p95": rank(0.95), "max": values[-1], "n": len(values)}


def sh(*args):
    return subprocess.run(args, capture_output=True, text=True).stdout.strip()


class Client:
    def __init__(self, path, token):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(30)
        self.sock.connect(path)
        self.buffer = b""
        self.next_id = 0
        reply = self.call("auth.authenticate", {"protocolVersion": 1, "token": token})
        assert "result" in reply, reply

    def call(self, method, params=None):
        self.next_id += 1
        ident = self.next_id
        self.sock.sendall((json.dumps({"jsonrpc": "2.0", "id": ident, "method": method, "params": params or {}}) + "\n").encode())
        while True:
            while b"\n" not in self.buffer:
                chunk = self.sock.recv(1 << 20)
                if not chunk:
                    raise ConnectionError("closed")
                self.buffer += chunk
            line, self.buffer = self.buffer.split(b"\n", 1)
            message = json.loads(line)
            if message.get("id") == ident:
                return message

    def result(self, method, params=None):
        # Retry only retryable INVALID_STATE (busy, e.g. still restoring): the
        # server rejected those without any effect, so a retry cannot duplicate work.
        deadline = time.time() + 15
        while True:
            reply = self.call(method, params)
            error = reply.get("error") or {}
            data = error.get("data") or {}
            if "result" in reply:
                return reply["result"]
            if data.get("code") == "INVALID_STATE" and data.get("retryable") and time.time() < deadline:
                time.sleep(0.05)
                continue
            raise RuntimeError(f"{method}: {error}")


class App:
    """One isolated release-app instance with a seeded all-capability grant."""

    def __init__(self, binary, extra_args=()):
        self.state = tempfile.mkdtemp(prefix="trellis-q-")
        os.chmod(self.state, 0o700)
        self.token = "trl_QUALIFY_" + uuid.uuid4().hex
        now = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)
        grant = {
            "id": str(uuid.uuid4()).upper(), "name": "qualification", "tokenHash": "sha256:" + hashlib.sha256(self.token.encode()).hexdigest(),
            "capabilities": ["metadata.read", "layout.write", "session.start", "session.input", "session.execute", "session.output.read",
                             "session.close", "theme.read", "host.read"],
            "windowScope": {"all": {}}, "hostScope": {"all": {}},
            "createdAt": now.isoformat().replace("+00:00", "Z"), "expiresAt": (now + datetime.timedelta(hours=2)).isoformat().replace("+00:00", "Z"),
        }
        path = os.path.join(self.state, "grants.json")
        with open(path, "w") as handle:
            json.dump([grant], handle)
        os.chmod(path, 0o600)
        self.started = time.perf_counter()
        # --fixture: the initial window runs a fixed `zsh -f` demo, never the user's login shell.
        self.process = subprocess.Popen([binary, "--fixture", "--state-directory", self.state, *extra_args], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def wait_ready(self, timeout=20):
        """Seconds from exec until the control API answers and the startup workspace window exists."""
        deadline = time.time() + timeout
        discovery = os.path.join(self.state, "control.json")
        while time.time() < deadline:
            try:
                with open(discovery) as handle:
                    self.socket_path = json.load(handle)["socketPath"]
                if not hasattr(self, "client"):
                    self.client = Client(self.socket_path, self.token)
                # The app window is ordered front before the socket starts; the
                # workspace window is created after state load, so wait for it too.
                if self.client.result("window.list")["windows"]:
                    return time.perf_counter() - self.started
                time.sleep(0.005)
            except (OSError, ValueError, KeyError, ConnectionError, AssertionError):
                self.__dict__.pop("client", None)
                time.sleep(0.01)
        raise TimeoutError("app did not become ready")

    def rss_mib(self):
        return int(sh("ps", "-o", "rss=", "-p", str(self.process.pid)) or 0) / 1024

    def children(self):
        return [int(p) for p in sh("pgrep", "-P", str(self.process.pid)).split()]

    def children_rss_mib(self):
        pids = self.children()
        return sum(int(sh("ps", "-o", "rss=", "-p", str(p)) or 0) for p in pids) / 1024 if pids else 0.0

    def cpu_seconds(self):
        # macOS prints [[dd-]hh:]mm:ss.ss (minutes may exceed 59).
        value = sh("ps", "-o", "cputime=", "-p", str(self.process.pid))
        days, _, clock = value.rpartition("-")
        seconds = 0.0
        for part in clock.split(":"):
            seconds = seconds * 60 + float(part)
        return seconds + (int(days) * 86400 if days else 0)

    def descriptors(self):
        # Numeric descriptors only; cwd/txt/mapped-file rows are not descriptors.
        return sum(1 for line in sh("lsof", "-n", "-P", "-p", str(self.process.pid), "-F", "f").splitlines() if line[:1] == "f" and line[1:].isdigit())

    def stop(self):
        children = [(pid, sh("ps", "-o", "pgid=,lstart=,command=", "-p", str(pid))) for pid in self.children()] if self.process.poll() is None else []
        try:
            self.process.send_signal(signal.SIGTERM)
            self.process.wait(timeout=10)
        except Exception:
            self.process.kill()
            self.process.wait()
        # Sessions run in their own process groups; never leave them behind after a failed run.
        # Only a group whose leader is still the same process (same start time and command), so a reused PID is never signalled.
        for pid, identity in children:
            if identity and identity.split()[0] == str(pid) and sh("ps", "-o", "pgid=,lstart=,command=", "-p", str(pid)) == identity:
                try:
                    os.killpg(pid, signal.SIGKILL)
                except OSError:
                    pass
        shutil.rmtree(self.state, ignore_errors=True)


def start_process(client, pane, script, executable="/bin/sh", arguments=None):
    launch = {"kind": "process", "executable": executable, "arguments": arguments or ["-c", script], "directory": "/tmp"}
    return client.result("session.start", {"paneId": pane, "launch": launch})


def first_pane(client, window_id):
    tab = client.result("window.get", {"id": window_id})["activeTabId"]
    return client.result("tab.get", {"id": tab})["paneIds"][0]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--quick", action="store_true", help="shorter runs for smoke testing (not a qualification)")
    parser.add_argument("--renderer", choices=["metal", "coregraphics"], help="renderer for every launch (default: the GPU rendering setting, off)")
    parser.add_argument("--report", default=os.path.join(ROOT, ".build/qualification-results.md"))
    args = parser.parse_args()
    extra = ["--renderer", args.renderer] if args.renderer else []
    launches, idle_seconds, flood_seconds = (5, 10, 10) if args.quick else (20, 60, 60)

    subprocess.run(["swift", "build", "-c", "release", "--product", "Trellis"], cwd=ROOT, check=True, capture_output=True)
    binary = os.path.join(sh("swift", "build", "-c", "release", "--show-bin-path"), "Trellis")
    results, notes = {}, []

    # cold launch to a responding app (the window is ordered front before the socket starts).
    samples = []
    for _ in range(launches):
        app = App(binary, extra)
        try:
            samples.append(app.wait_ready() * 1000)
        finally:
            app.stop()
    results["launch_ms"] = p95(samples, minimum=launches)

    app = App(binary, extra)
    try:
        app.wait_ready()
        c = app.client
        pid = app.process.pid

        # Start from an empty workspace: wait for the startup fixture window, then close it.
        deadline = time.time() + 15
        while not c.result("window.list")["windows"] and time.time() < deadline:
            time.sleep(0.05)
        for window in c.result("window.list")["windows"]:
            c.result("window.close", {"id": window["id"], "allowRunning": True})

        # 10 idle panes (cat waiting for input, no output, no blinking).
        windows = []
        for index in range(10):
            created = c.result("window.create", {"name": f"Q{index}"})
            windows.append(created["windowId"])
            start_process(c, created["panes"][0]["paneId"], "exec /bin/cat")
        time.sleep(5)
        cpu_before = app.cpu_seconds()
        time.sleep(idle_seconds)
        results["idle_cpu_percent"] = round((app.cpu_seconds() - cpu_before) / idle_seconds * 100, 2)
        results["idle_rss_mib"] = round(app.rss_mib(), 1)
        results["idle_children_rss_mib"] = round(app.children_rss_mib(), 1)

        # 10 windows, 50 tabs, 100 sessions.
        for window in windows:
            for _ in range(4):
                tab = c.result("tab.create", {"windowId": window})
                start_process(c, tab["paneIds"][0], "exec /bin/cat")
        for window in windows:
            for tab in c.result("tab.list", {"windowId": window})["tabs"]:
                pane = tab["paneIds"][0]
                split = c.result("pane.split", {"paneId": pane, "axis": "x"})
                start_process(c, split["pane"]["paneId"], "exec /bin/cat")
        listed = c.result("window.list")["windows"]
        tabs = [t for w in listed for t in c.result("tab.list", {"windowId": w["id"]})["tabs"]]
        panes = [p for t in tabs for p in t["paneIds"]]
        sessions = [c.result("tab.get", {"id": t["id"]}) for t in tabs]
        running = 0
        for t in sessions:
            stack = [t["layout"]]
            while stack:
                node = stack.pop()
                if node["type"] == "split":
                    stack.extend(node["children"])
                elif node["state"] == "running":
                    running += 1
        results["capacity"] = {"windows": len(listed), "tabs": len(tabs), "panes": len(panes), "unique_ids": len(set(panes)) == len(panes), "running": running}
        results["capacity_rss_mib"] = round(app.rss_mib(), 1)
        results["capacity_children_rss_mib"] = round(app.children_rss_mib(), 1)

        # Proxy: focus round trips across 50 tabs with 100 live panes.
        switch = []
        for index in range(200):
            begin = time.perf_counter()
            c.result("tab.focus", {"id": tabs[index % len(tabs)]["id"]})
            switch.append((time.perf_counter() - begin) * 1000)
        results["switch_proxy_ms"] = p95(switch)

        # Proxy: one byte to a cat pane until the PTY echo reaches the app.
        echo_pane = panes[0]
        echo_session = c.result("session.get", {"id": c.result("tab.get", {"id": tabs[0]["id"]})["layout"]["children"][0]["sessionId"]})["id"]
        cursor = c.result("session.readOutput", {"id": echo_session, "view": "stream"})["nextCursor"]
        echo = []
        for _ in range(100):
            begin = time.perf_counter()
            c.result("session.sendInput", {"id": echo_session, "text": "x"})
            deadline = time.time() + 5
            while time.time() < deadline:
                read = c.result("session.readOutput", {"id": echo_session, "view": "stream", "cursor": cursor})
                if read["base64"]:
                    cursor = read["nextCursor"]
                    break
            else:
                raise TimeoutError("no echo within 5 s")
            echo.append((time.perf_counter() - begin) * 1000)
        results["echo_proxy_ms"] = p95(echo)

        # 10 MiB/s for the flood period in one pane, navigation sampled meanwhile.
        # Free one window (10 panes) for the flood; 90 live panes remain.
        c.result("window.close", {"id": windows[-1], "allowRunning": True})
        tabs = [t for t in tabs if t["windowId"] != windows[-1]]
        flood_window = c.result("window.create", {"name": "Flood"})
        flood_pane = flood_window["panes"][0]["paneId"]
        # 10 MiB per wall-clock second (sub-second timer), paced; a slow reader blocks the writer, so the
        # achieved rate is what the app actually consumed. The writer records it for the report.
        stats_path = os.path.join(app.state, "flood-stats.txt")
        code = ("use Time::HiRes qw(time sleep); $| = 1; my $chunk = ((\"y\" x 1023) . \"\\n\") x 1024; my $start = time; "
                "my $end = $start + %d; my $n = 0; while (time < $end) { my $t = time; for (1..10) { print $chunk; $n += length $chunk } "
                "my $left = 1 - (time - $t); sleep $left if $left > 0 } open(my $f, '>', $ARGV[0]) or die; print $f \"$n \", time - $start, \"\\n\"; close $f") % flood_seconds
        start_process(c, flood_pane, None, executable="/usr/bin/perl", arguments=["-e", code, stats_path])
        flood_switch, flood_rss = [], []
        end = time.time() + flood_seconds
        while time.time() < end:
            begin = time.perf_counter()
            # Alternate into the flooding tab so switches also land on a pane that is rendering output.
            target = flood_window["tabId"] if len(flood_switch) % 2 == 0 else tabs[(len(flood_switch) // 2) % len(tabs)]["id"]
            c.result("tab.focus", {"id": target})
            flood_switch.append((time.perf_counter() - begin) * 1000)
            if len(flood_switch) % 20 == 0:
                flood_rss.append(app.rss_mib())
            time.sleep(0.05)
        flood_session = c.result("tab.get", {"id": flood_window["tabId"]})["layout"]["sessionId"]
        read = c.result("session.readOutput", {"id": flood_session, "view": "stream", "maxBytes": 1})
        deadline = time.time() + 30
        while not os.path.exists(stats_path) and time.time() < deadline:
            time.sleep(0.1)
        try:
            with open(stats_path) as handle:
                written, elapsed = (float(x) for x in handle.read().split())
            rate = round(written / 2**20 / elapsed, 2)
        except (OSError, ValueError):
            written, elapsed, rate = None, None, None
            notes.append("flood writer did not report its achieved rate")
        results["flood"] = {
            "switch_proxy_ms": p95(flood_switch), "rss_mib_max": round(max(flood_rss), 1) if flood_rss else None,
            "journal_gap_reported": read["gap"], "bytes_written": written, "seconds": round(elapsed, 2) if elapsed else None,
            "achieved_mib_per_s": rate,
        }

        # 100 create/close cycles leave no descriptors or children behind.
        for window in [w["id"] for w in c.result("window.list")["windows"]]:
            c.call("window.close", {"id": window, "allowRunning": True})
        time.sleep(3)
        fds_before, children_before = app.descriptors(), len(app.children())
        spawned = set()
        for index in range(100):
            created = c.result("window.create", {"name": f"Cycle {index}"})
            existing = set(app.children())
            start_process(c, created["panes"][0]["paneId"], "exec /bin/sleep 30")
            spawned |= set(app.children()) - existing
            reply = c.call("window.close", {"id": created["windowId"], "allowRunning": True})
            if "result" not in reply:
                notes.append(f"cycle {index}: {reply.get('error')}")
        time.sleep(3)

        def alive(pid):
            try:
                os.kill(pid, 0)
                return True
            except ProcessLookupError:
                return False
            except PermissionError:
                return True
        # Orphans are reparented away from the app, so check every spawned PID directly as well.
        results["cleanup"] = {"descriptors_before": fds_before, "descriptors_after": app.descriptors(),
                              "children_before": children_before, "children_after": len(app.children()),
                              "live_children_spawned": len(spawned), "spawned_still_alive": sum(alive(p) for p in spawned)}
    finally:
        app.stop()

    write_report(args, results, notes)


def write_report(args, results, notes):
    hardware = {
        "model": sh("sysctl", "-n", "hw.model"), "cpu": sh("sysctl", "-n", "machdep.cpu.brand_string"),
        "memory_gib": round(int(sh("sysctl", "-n", "hw.memsize") or 0) / 2**30, 1), "arch": platform.machine(),
        "macos": f"{sh('sw_vers', '-productVersion')} ({sh('sw_vers', '-buildVersion')})",
    }
    engine = "SwiftTerm 1.20.0 @ 5d14406844143538cd8f8851d2d8a67c1fe443e5 + Trellis patches"
    commit = sh("git", "-C", ROOT, "rev-parse", "--short", "HEAD")

    def verdict(summary, limit):
        if summary is None:
            return "insufficient samples"
        return f"p95 {summary['p95']:.1f} ms (p50 {summary['p50']:.1f}, max {summary['max']:.1f}, n={summary['n']}) — {'meets' if summary['p95'] <= limit else 'MISSES'} {limit} ms"

    r = results
    rate = r["flood"]["achieved_mib_per_s"]
    flood_rate = ("not measured" if rate is None else
                  f"{rate} MiB/s over {r['flood']['seconds']} s — {'meets' if rate >= 9.9 else 'MISSES'} 10 MiB/s")
    lines = [
        "# Qualification results", "",
        f"Generated {datetime.datetime.now().isoformat(timespec='seconds')} by `scripts/qualify.py{' --quick' if args.quick else ''}` on commit `{commit}`.",
        "Release build, launched directly (no debugger) on isolated temporary state directories with a seeded test grant.", "",
        "## Environment", "",
        f"- Hardware: {hardware['model']}, {hardware['cpu']}, {hardware['memory_gib']} GiB RAM, {hardware['arch']}",
        f"- macOS: {hardware['macos']}", f"- Engine: {engine}", f"- Renderer: {args.renderer or 'setting default (CoreGraphics)'}",
        "- Conditions: an interactive desktop session with other applications open; warm OS file cache after the first launch.", "",
        "## Results", "",
        "| Requirement | Measurement | Result |", "| --- | --- | --- |",
        f"| cold launch ≤2 s p95 | exec → control API answering with the startup workspace window created (no frame-presentation timestamp) | {verdict(r['launch_ms'], 2000)} |",
        f"| typing echo ≤50 ms p95 | **proxy**: API sendInput → PTY echo received by the app (excludes frame rendering) | {verdict(r['echo_proxy_ms'], 50)} |",
        f"| switch ≤100 ms p95 @ 50 live panes | **proxy**: `tab.focus` round trip with 100 live panes (excludes frame rendering) | {verdict(r['switch_proxy_ms'], 100)} |",
        f"| 10 windows / 50 tabs / 100 sessions | API-built workspace | {r['capacity']} |",
        f"| memory ≤300 MiB, 10 idle panes | app RSS (children separate) | {r['idle_rss_mib']} MiB app; children {r['idle_children_rss_mib']} MiB — {'meets' if r['idle_rss_mib'] <= 300 else 'MISSES'} |",
        f"| idle CPU <2% of a core | CPU time over the idle window | {r['idle_cpu_percent']}% — {'meets' if r['idle_cpu_percent'] < 2 else 'MISSES'} |",
        f"| memory at capacity | app RSS / children with 100 sessions | {r['capacity_rss_mib']} MiB / {r['capacity_children_rss_mib']} MiB |",
        f"| flood 10 MiB/s | achieved rate (bytes the app consumed from the PTY) | {flood_rate} |",
        f"| navigation during flood | **proxy**: `tab.focus` round trip, alternating into the flooding tab | {verdict(r['flood']['switch_proxy_ms'], 100)}; max RSS {r['flood']['rss_mib_max']} MiB; journal eviction reported: {r['flood']['journal_gap_reported']} |",
        f"| 100 create/close cycles | app descriptors (numeric fds) and children before → after; spawned PIDs still alive | fds {r['cleanup']['descriptors_before']} → {r['cleanup']['descriptors_after']}; children {r['cleanup']['children_before']} → {r['cleanup']['children_after']}; {r['cleanup']['live_children_spawned']} live children spawned, {r['cleanup']['spawned_still_alive']} still alive |",
        "",
        "## Limitations", "",
        "- Echo and switching are measured through the control API. They include PTY, parsing, model, and IPC time but not window-server frame presentation; the typing and switching UI targets still need an instrumented UI run.",
        "- One machine only. The reference matrix (older macOS, Intel, displays) remains open.",
    ]
    if args.quick:
        lines.append("- `--quick` run: shortened windows and sample counts. Not a qualification result.")
    if notes:
        lines += ["", "## Notes", ""] + [f"- {note}" for note in notes]
    lines += ["", "## Raw", "", "```json", json.dumps({"hardware": hardware, "results": r}, indent=2), "```", ""]
    with open(args.report, "w") as handle:
        handle.write("\n".join(lines))
    print("\n".join(lines))


if __name__ == "__main__":
    main()
