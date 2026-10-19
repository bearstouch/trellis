#!/usr/bin/env python3
"""Metal vs CoreGraphics rendering benchmarks (FR-TX05).

Launches the release app once per workload and renderer (`--renderer metal` / `--renderer coregraphics`) on an
isolated state directory, drives it over the control socket with the qualification grant, and samples the app's
CPU time, RSS, frames drawn (`appearance.get` → `rendering`), WindowServer CPU time and GPU utilization (IOAccelerator
"Device Utilization %"). Runs alternate renderers so slow drift (thermal, background work) affects both alike.

The app window must stay visible and unobstructed: an occluded window draws nothing and every figure collapses.

Usage: scripts/bench-renderer.py [--quick] [--repeats N] [--only NAMES] [--report PATH]
"""
import argparse, datetime, json, os, re, statistics, subprocess, sys, threading, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import qualify  # noqa: E402
from qualify import ROOT, App, sh, start_process, p95  # noqa: E402

RENDERERS = ["metal", "coregraphics"]


def window_server_cpu_seconds():
    pid = sh("pgrep", "-x", "WindowServer").split()
    if not pid:
        return None
    value = sh("ps", "-o", "cputime=", "-p", pid[0])
    days, _, clock = value.rpartition("-")
    seconds = 0.0
    for part in clock.split(":"):
        seconds = seconds * 60 + float(part)
    return seconds + (int(days) * 86400 if days else 0)


def gpu_utilization():
    found = re.findall(r'"Device Utilization %"=(\d+)', sh("ioreg", "-r", "-d", "1", "-c", "IOAccelerator"))
    return max(int(v) for v in found) if found else None


class Sampler:
    """Samples GPU utilization and app RSS every 250 ms on a background thread."""

    def __init__(self, app):
        self.app, self.gpu, self.rss, self.stop_event = app, [], [], threading.Event()
        self.thread = threading.Thread(target=self.run, daemon=True)

    def run(self):
        while not self.stop_event.wait(0.25):
            value = gpu_utilization()
            if value is not None:
                self.gpu.append(value)
            self.rss.append(self.app.rss_mib())

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *exc):
        self.stop_event.set()
        self.thread.join()


def rendering(client):
    return client.result("appearance.get")["rendering"]


def measure(app, seconds, settle=2.0):
    """CPU, frames, WindowServer and GPU over `seconds` of whatever the app is doing now."""
    time.sleep(settle)
    c = app.client
    before = rendering(c)
    cpu0, ws0, t0 = app.cpu_seconds(), window_server_cpu_seconds(), time.perf_counter()
    with Sampler(app) as sampler:
        time.sleep(seconds)
    elapsed = time.perf_counter() - t0
    cpu1, ws1, after = app.cpu_seconds(), window_server_cpu_seconds(), rendering(c)
    frames = (after["metalFrames"] - before["metalFrames"]) + (after["coreGraphicsFrames"] - before["coreGraphicsFrames"])
    return {
        "app_cpu_percent": round((cpu1 - cpu0) / elapsed * 100, 2),
        "windowserver_cpu_percent": round((ws1 - ws0) / elapsed * 100, 2) if ws0 is not None and ws1 is not None else None,
        "gpu_util_percent_mean": round(statistics.mean(sampler.gpu), 1) if sampler.gpu else None,
        "frames_per_second": round(frames / elapsed, 1),
        "rss_mib_max": round(max(sampler.rss), 1) if sampler.rss else round(app.rss_mib(), 1),
        "metal_panes": after["metalPanes"], "coregraphics_panes": after["coreGraphicsPanes"],
    }


def fresh(binary, renderer):
    app = App(binary, ["--renderer", renderer])
    ready = app.wait_ready()
    c = app.client
    window = c.result("window.list")["windows"][0]["id"]
    # Replace the fixture window with an empty one we control.
    created = c.result("window.create", {"name": "Bench"})
    c.result("window.close", {"id": window, "allowRunning": True})
    return app, ready, created


def check_renderer(result, renderer, panes):
    want_metal = renderer == "metal"
    got = result["metal_panes"] if want_metal else result["coregraphics_panes"]
    if got != panes:
        raise RuntimeError(f"{renderer} requested but {result['metal_panes']} Metal / {result['coregraphics_panes']} CoreGraphics panes")


def perl_writer(seconds, rate_mib, payload, stats_path):
    """Writes `payload` lines for `seconds`, paced to rate_mib MiB/s (0 = as fast as the app reads); records bytes and time."""
    return ("use Time::HiRes qw(time sleep); $| = 1; my $chunk = %s; my $start = time; my $end = $start + %d; my $n = 0; "
            "my $rate = %d * 1048576; while (time < $end) { my $t = time; print $chunk; $n += length $chunk; "
            "if ($rate > 0) { my $left = length($chunk) / $rate - (time - $t); sleep $left if $left > 0 } } "
            "open(my $f, '>', $ARGV[0]) or die; print $f \"$n \", time - $start, \"\\n\"; close $f") % (payload, seconds, rate_mib), stats_path


PLAIN = r'((("y" x 1023) . "\n") x 1024)'
SGR = (r'(join("", map { "\e[38;5;" . ($_ % 256) . "m" . ("x" x 7) . "\e[48;2;" . ($_ % 200) . ";40;80m" . ("y" x 7) . "\e[0m " } 0..39) . "\r\n") x 128')
# One full-screen frame sized to the pane (stty size): cursor home, then every row filled with 256-colour
# text in bold/underline runs. The last row has no newline, so frames repaint in place instead of scrolling.
TUI = (r'"\e[H" . do { my ($h, $w) = split " ", qx(stty size); join("", map { my $r = $_; join("", map { "\e[" . (($r + $_) % 3 ? "1" : "4") '
       r'. ";38;5;" . (($r * 7 + $_) % 256) . "m" . chr(65 + ($r + $_) % 26) } 0..$w-1) . "\e[0m" . ($r < $h - 1 ? "\r\n" : "") } 0..$h-1) }')



def run_writer(app, pane, seconds, rate, payload, name):
    stats_path = os.path.join(app.state, f"{name}-stats.txt")
    code, path = perl_writer(seconds, rate, payload, stats_path)
    start_process(app.client, pane, None, executable="/usr/bin/perl", arguments=["-e", code, path])
    return stats_path


def read_rate(stats_path, timeout=30):
    deadline = time.time() + timeout
    while not os.path.exists(stats_path) and time.time() < deadline:
        time.sleep(0.1)
    try:
        with open(stats_path) as handle:
            written, elapsed = (float(x) for x in handle.read().split())
        return round(written / 2**20 / elapsed, 2), written
    except (OSError, ValueError):
        return None, None


def workload_idle(binary, renderer, seconds):
    app, _, created = fresh(binary, renderer)
    try:
        c, pane = app.client, created["panes"][0]["paneId"]
        panes = [pane]
        for axis in ["x", "y", "y"]:
            split = c.result("pane.split", {"paneId": panes[-1], "axis": axis})
            panes.append(split["pane"]["paneId"])
        for p in panes:
            start_process(c, p, "exec /bin/cat")
        result = measure(app, seconds, settle=4)
        check_renderer(result, renderer, len(panes))
        return result
    finally:
        app.stop()


def workload_stream(binary, renderer, seconds, rate, payload, name, splits=0):
    app, _, created = fresh(binary, renderer)
    try:
        c = app.client
        panes = [created["panes"][0]["paneId"]]
        for index in range(splits):
            split = c.result("pane.split", {"paneId": panes[index // 2], "axis": "x" if index % 2 == 0 else "y"})
            panes.append(split["pane"]["paneId"])
        stats = [run_writer(app, p, seconds + 4, rate, payload, f"{name}{i}") for i, p in enumerate(panes)]
        result = measure(app, seconds, settle=2)
        check_renderer(result, renderer, len(panes))
        rates = [read_rate(path)[0] for path in stats]
        result["achieved_mib_per_s"] = round(sum(r for r in rates if r is not None), 2) if any(r is not None for r in rates) else None
        if result["achieved_mib_per_s"]:
            # Unpaced runs read as much as the app keeps up with, so CPU per MiB compares the work done.
            result["cpu_ms_per_mib"] = round(result["app_cpu_percent"] * 10 / result["achieved_mib_per_s"], 1)
        return result
    finally:
        app.stop()


def workload_launch(binary, renderer, launches):
    samples = []
    for _ in range(launches):
        app = App(binary, ["--renderer", renderer])
        try:
            samples.append(app.wait_ready() * 1000)
        finally:
            app.stop()
    return {"launch_ms_median": round(statistics.median(samples), 1), "launch_ms_max": round(max(samples), 1)}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--quick", action="store_true", help="short windows for smoke testing")
    parser.add_argument("--repeats", type=int, default=None)
    parser.add_argument("--only", help="comma-separated workload names (launch, idle, flood_plain, flood_unpaced, sgr_unpaced, tui_repaint, split_sgr)")
    parser.add_argument("--report", default=os.path.join(ROOT, ".build/bench-renderer.md"))
    args = parser.parse_args()
    seconds = 5 if args.quick else 20
    repeats = args.repeats or (1 if args.quick else 3)

    subprocess.run(["swift", "build", "-c", "release", "--product", "Trellis"], cwd=ROOT, check=True, capture_output=True)
    binary = os.path.join(sh("swift", "build", "-c", "release", "--show-bin-path"), "Trellis")

    workloads = [
        ("launch", "Cold launch to API ready", lambda r: workload_launch(binary, r, 3 if args.quick else 10)),
        ("idle", "Idle: 4 visible split panes running cat", lambda r: workload_idle(binary, r, seconds)),
        ("flood_plain", "Plain-text flood paced at 10 MiB/s, one pane", lambda r: workload_stream(binary, r, seconds, 10, PLAIN, "plain")),
        ("flood_unpaced", "Plain-text flood, unpaced (as fast as the app reads)", lambda r: workload_stream(binary, r, seconds, 0, PLAIN, "unpaced")),
        ("sgr_unpaced", "256-colour + truecolor SGR text, unpaced", lambda r: workload_stream(binary, r, seconds, 0, SGR, "sgr")),
        ("tui_repaint", "Full-screen repaint (cursor home + every cell restyled), unpaced", lambda r: workload_stream(binary, r, seconds, 0, TUI, "tui")),
        ("split_sgr", "4 visible split panes, SGR text at 2 MiB/s each", lambda r: workload_stream(binary, r, seconds, 2, SGR, "split", splits=3)),
    ]
    if args.only:
        workloads = [w for w in workloads if w[0] in args.only.split(",")]
    results = {name: {r: [] for r in RENDERERS} for name, _, _ in workloads}
    for name, title, run in workloads:
        for repeat in range(repeats):
            order = RENDERERS if repeat % 2 == 0 else list(reversed(RENDERERS))
            for renderer in order:
                print(f"[{name}] {renderer} run {repeat + 1}/{repeats}", flush=True)
                results[name][renderer].append(run(renderer))
    write_report(args, workloads, results, seconds, repeats)


def median_of(runs, key):
    values = [run[key] for run in runs if run.get(key) is not None]
    return round(statistics.median(values), 2) if values else None


def write_report(args, workloads, results, seconds, repeats):
    hardware = {
        "model": sh("sysctl", "-n", "hw.model"), "cpu": sh("sysctl", "-n", "machdep.cpu.brand_string"),
        "memory_gib": round(int(sh("sysctl", "-n", "hw.memsize") or 0) / 2**30, 1),
        "macos": f"{sh('sw_vers', '-productVersion')} ({sh('sw_vers', '-buildVersion')})",
        "displays": sh("system_profiler", "SPDisplaysDataType").count("Resolution:"),
    }
    commit = sh("git", "-C", ROOT, "rev-parse", "--short", "HEAD")
    metrics = [("app_cpu_percent", "App CPU %", True), ("windowserver_cpu_percent", "WindowServer CPU %", True),
               ("gpu_util_percent_mean", "GPU util % (mean)", None), ("frames_per_second", "Frames/s", None),
               ("achieved_mib_per_s", "Throughput MiB/s", False), ("cpu_ms_per_mib", "App CPU ms per MiB", True),
               ("rss_mib_max", "Peak RSS MiB", True),
               ("launch_ms_median", "Launch ms (median)", True), ("launch_ms_max", "Launch ms (max)", True)]
    lines = ["# Renderer benchmark: Metal vs CoreGraphics", "",
             f"Generated {datetime.datetime.now().isoformat(timespec='seconds')} by `scripts/bench-renderer.py{' --quick' if args.quick else ''}` on commit `{commit}`.",
             f"Release build; each workload measured for {seconds} s, {repeats} run(s) per renderer, renderers alternated; medians shown.", "",
             f"- Hardware: {hardware['model']}, {hardware['cpu']}, {hardware['memory_gib']} GiB RAM; {hardware['displays']} display(s)",
             f"- macOS: {hardware['macos']}", ""]
    for name, title, _ in workloads:
        lines += [f"## {title}", "", "| Metric | CoreGraphics | Metal | Δ (Metal vs CG) |", "| --- | --- | --- | --- |"]
        for key, label, lower_is_better in metrics:
            cg, metal = median_of(results[name]["coregraphics"], key), median_of(results[name]["metal"], key)
            if cg is None and metal is None:
                continue
            if cg not in (None, 0) and metal is not None:
                delta = (metal - cg) / cg * 100
                better = "" if lower_is_better is None else (" better" if (delta < 0) == lower_is_better and abs(delta) >= 0.5 else (" worse" if abs(delta) >= 0.5 else ""))
                delta_text = f"{delta:+.1f}%{better}"
            else:
                delta_text = "—"
            lines.append(f"| {label} | {cg} | {metal} | {delta_text} |")
        lines.append("")
    lines += ["## Notes", "",
              "- Frames/s counts Metal presented frames or CoreGraphics `draw(_:)` passes of the panes; the two renderers coalesce updates differently, so it shows work done, not smoothness.",
              "- WindowServer CPU and GPU utilization are system-wide: other activity on the machine is included.",
              "- Throughput is what the app consumed from the PTY (the writer blocks when the app reads slower).", "",
              "## Raw", "", "```json", json.dumps({"hardware": hardware, "results": results}, indent=2), "```", ""]
    with open(args.report, "w") as handle:
        handle.write("\n".join(lines))
    with open(os.path.splitext(args.report)[0] + ".json", "w") as handle:
        json.dump({"hardware": hardware, "results": results}, handle, indent=2)
    print("\n".join(lines))


if __name__ == "__main__":
    main()
