# S031 qualification results

Generated 2026-10-16T21:53:33 by `scripts/qualify.py` on commit `2890b40`.
Release build, launched directly (no debugger) on isolated temporary state directories with a seeded test grant.

## Environment

- Hardware: MacBookPro18,3, Apple M1 Pro, 16.0 GiB RAM, arm64
- macOS: 26.6.2 (25G83)
- Engine: SwiftTerm 1.20.0 @ 5d14406844143538cd8f8851d2d8a67c1fe443e5 + Trellis patches
- Conditions: an interactive desktop session with other applications open; warm OS file cache after the first launch.

## Results

| Requirement | Measurement | Result |
| --- | --- | --- |
| NFR-P01 cold launch ≤2 s p95 | exec → control API answering with the startup workspace window created (no frame-presentation timestamp) | p95 347.8 ms (p50 316.3, max 389.3, n=20) — meets 2000 ms |
| NFR-P02 typing echo ≤50 ms p95 | **proxy**: API sendInput → PTY echo received by the app (excludes frame rendering) | p95 0.4 ms (p50 0.3, max 6.0, n=100) — meets 50 ms |
| NFR-P03 switch ≤100 ms p95 @ 50 live panes | **proxy**: `tab.focus` round trip with 100 live panes (excludes frame rendering) | p95 11.0 ms (p50 7.4, max 14.5, n=200) — meets 100 ms |
| NFR-P04 10 windows / 50 tabs / 100 sessions | API-built workspace | {'windows': 10, 'tabs': 50, 'panes': 100, 'unique_ids': True, 'running': 100} |
| NFR-P06 memory ≤300 MiB, 10 idle panes | app RSS (children separate) | 73.4 MiB app; children 4.8 MiB — meets |
| NFR-P06 idle CPU <2% of a core | CPU time over the idle window | 0.38% — meets |
| NFR-P04 memory at capacity | app RSS / children with 100 sessions | 116.1 MiB / 116.0 MiB |
| NFR-P07 flood 10 MiB/s | achieved rate (bytes the app consumed from the PTY) | 5.15 MiB/s over 60.18 s — MISSES 10 MiB/s |
| NFR-P07 navigation during flood | **proxy**: `tab.focus` round trip, alternating into the flooding tab | p95 60.1 ms (p50 6.6, max 250.0, n=817) — meets 100 ms; max RSS 160.1 MiB; journal eviction reported: True |
| NFR-R01 100 create/close cycles | app descriptors (numeric fds) and children before → after; spawned PIDs still alive | fds 8 → 8; children 0 → 0; 100 live children spawned, 0 still alive |

## Limitations

- Echo and switching are measured through the control API. They include PTY, parsing, model, and IPC time but not window-server frame presentation; NFR-P02/P03 UI targets still need an instrumented UI run.
- One machine only. The reference matrix (older macOS, Intel, displays) remains open in S001/S032.

## Raw

```json
{
  "hardware": {
    "model": "MacBookPro18,3",
    "cpu": "Apple M1 Pro",
    "memory_gib": 16.0,
    "arch": "arm64",
    "macos": "26.6.2 (25G83)"
  },
  "results": {
    "launch_ms": {
      "p50": 316.34120899252594,
      "p95": 347.78941702097654,
      "max": 389.2675000242889,
      "n": 20
    },
    "idle_cpu_percent": 0.38,
    "idle_rss_mib": 73.4,
    "idle_children_rss_mib": 4.8,
    "capacity": {
      "windows": 10,
      "tabs": 50,
      "panes": 100,
      "unique_ids": true,
      "running": 100
    },
    "capacity_rss_mib": 116.1,
    "capacity_children_rss_mib": 116.0,
    "switch_proxy_ms": {
      "p50": 7.35133420675993,
      "p95": 10.988624999299645,
      "max": 14.517165953293443,
      "n": 200
    },
    "echo_proxy_ms": {
      "p50": 0.33670803532004356,
      "p95": 0.44741597957909107,
      "max": 6.021791836246848,
      "n": 100
    },
    "flood": {
      "switch_proxy_ms": {
        "p50": 6.6118750255554914,
        "p95": 60.09549996815622,
        "max": 249.95362502522767,
        "n": 817
      },
      "rss_mib_max": 160.1,
      "journal_gap_reported": true,
      "bytes_written": 325058560.0,
      "seconds": 60.18,
      "achieved_mib_per_s": 5.15
    },
    "cleanup": {
      "descriptors_before": 8,
      "descriptors_after": 8,
      "children_before": 0,
      "children_after": 0,
      "live_children_spawned": 100,
      "spawned_still_alive": 0
    }
  }
}
```
