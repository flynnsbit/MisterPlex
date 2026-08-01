#!/usr/bin/env python3
"""One-window /proc schedstat sampler for MiSTer contention checks.

For each resolved process (by /proc/<pid>/exe realpath — never cmdline):
  /proc/<pid>/schedstat and each /proc/<pid>/task/<tid>/schedstat
  fields (Linux):
    $1 run_ns   — time running on a CPU (ns)
    $2 wait_ns  — time waiting on a runqueue (ns)
    $3 slices   — timeslices

ONE wall window. Report wait_frac = 100 * dwait / (drun + dwait).
High wait_frac on ffmpeg/misterplexd under load ⇒ scheduler delay (possible
Main contention). Low wait_frac ⇒ they run when they want; Main is mostly
soaking idle (elastic scavenger).

Usage:
  python3 tools/schedstat_sample.py --seconds 20 -o schedstat_play.json
"""
from __future__ import annotations

import argparse
import json
import os
import time
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple


def exe_base(pid: int) -> Optional[str]:
    try:
        path = os.readlink(f"/proc/{pid}/exe")
    except OSError:
        return None
    if path.endswith(" (deleted)"):
        path = path[: -len(" (deleted)")]
    try:
        path = os.path.realpath(path)
    except OSError:
        pass
    return os.path.basename(path) or None


def classify(base: str) -> str:
    b = base.lower()
    if b == "mister":
        return "MiSTer"
    if "ffmpeg" in b:
        return "ffmpeg"
    if "misterplexd" in b:
        return "misterplexd"
    return base


def read_schedstat(path: str) -> Optional[Tuple[int, int, int]]:
    try:
        with open(path, "r", encoding="utf-8") as f:
            parts = f.read().split()
        if len(parts) < 3:
            return None
        return int(parts[0]), int(parts[1]), int(parts[2])
    except (OSError, ValueError):
        return None


def list_pids() -> List[int]:
    return [int(n) for n in os.listdir("/proc") if n.isdigit()]


def list_tids(pid: int) -> List[int]:
    try:
        return [int(x) for x in os.listdir(f"/proc/{pid}/task") if x.isdigit()]
    except OSError:
        return []


def sample(seconds: float, label: str) -> Dict[str, Any]:
    # Snapshot A
    t0 = time.perf_counter()
    proc0: Dict[int, Tuple[str, Tuple[int, int, int]]] = {}
    thr0: Dict[Tuple[int, int], Tuple[str, str, Tuple[int, int, int]]] = {}
    for pid in list_pids():
        base = exe_base(pid)
        if not base:
            continue
        name = classify(base)
        if name not in ("MiSTer", "ffmpeg", "misterplexd"):
            continue
        st = read_schedstat(f"/proc/{pid}/schedstat")
        if not st:
            continue
        proc0[pid] = (name, st)
        for tid in list_tids(pid):
            ts = read_schedstat(f"/proc/{pid}/task/{tid}/schedstat")
            if not ts:
                continue
            comm = "?"
            try:
                with open(f"/proc/{pid}/task/{tid}/comm", "r", encoding="utf-8") as f:
                    comm = f.read().strip()
            except OSError:
                pass
            thr0[(pid, tid)] = (name, comm, ts)

    end = t0 + max(0.2, float(seconds))
    while time.perf_counter() < end:
        time.sleep(0.05)
    t1 = time.perf_counter()
    dwall = t1 - t0

    procs: List[Dict[str, Any]] = []
    for pid, (name, a) in proc0.items():
        b = read_schedstat(f"/proc/{pid}/schedstat")
        if not b:
            continue
        drun = max(0, b[0] - a[0])
        dwait = max(0, b[1] - a[1])
        dslices = max(0, b[2] - a[2])
        denom = drun + dwait
        procs.append(
            {
                "pid": pid,
                "comm": name,
                "drun_ns": drun,
                "dwait_ns": dwait,
                "dslices": dslices,
                "wait_frac_pct": round(100.0 * dwait / denom, 3) if denom else 0.0,
                "run_pct_wall": round(100.0 * drun / (dwall * 1e9), 3),
                "wait_pct_wall": round(100.0 * dwait / (dwall * 1e9), 3),
            }
        )

    threads: List[Dict[str, Any]] = []
    for (pid, tid), (name, comm, a) in thr0.items():
        b = read_schedstat(f"/proc/{pid}/task/{tid}/schedstat")
        if not b:
            continue
        drun = max(0, b[0] - a[0])
        dwait = max(0, b[1] - a[1])
        dslices = max(0, b[2] - a[2])
        denom = drun + dwait
        threads.append(
            {
                "pid": pid,
                "tid": tid,
                "proc": name,
                "comm": comm,
                "drun_ns": drun,
                "dwait_ns": dwait,
                "dslices": dslices,
                "wait_frac_pct": round(100.0 * dwait / denom, 3) if denom else 0.0,
                "run_pct_wall": round(100.0 * drun / (dwall * 1e9), 3),
                "wait_pct_wall": round(100.0 * dwait / (dwall * 1e9), 3),
            }
        )

    procs.sort(key=lambda r: r["dwait_ns"], reverse=True)
    threads.sort(key=lambda r: r["dwait_ns"], reverse=True)

    def top_wait(proc_name: str, n: int = 8) -> List[Dict[str, Any]]:
        return [t for t in threads if t["proc"] == proc_name][:n]

    def agg(proc_name: str) -> Dict[str, Any]:
        """Aggregate all threads of a process class (ffmpeg is multi-threaded).

        Process-level /proc/<pid>/schedstat is the group leader only — do NOT
        use it alone for ffmpeg starvation. Sum drun/dwait across threads.
        """
        ts = [t for t in threads if t["proc"] == proc_name]
        drun = sum(t["drun_ns"] for t in ts)
        dwait = sum(t["dwait_ns"] for t in ts)
        denom = drun + dwait
        # Busy threads only (avoid noise from idle helpers)
        busy = [t for t in ts if t["run_pct_wall"] >= 2.0]
        max_wf = max((t["wait_frac_pct"] for t in busy), default=0.0)
        return {
            "n_threads": len(ts),
            "n_busy_threads": len(busy),
            "sum_drun_ns": drun,
            "sum_dwait_ns": dwait,
            "agg_wait_frac_pct": round(100.0 * dwait / denom, 3) if denom else None,
            "max_busy_thread_wait_frac_pct": max_wf if busy else None,
            "sum_run_pct_wall": round(100.0 * drun / (dwall * 1e9), 3),
            "sum_wait_pct_wall": round(100.0 * dwait / (dwall * 1e9), 3),
            "NO_DATA": len(ts) == 0,
        }

    return {
        "label": label,
        "dwall_s": round(dwall, 3),
        "formula": "wait_frac=100*dwait/(drun+dwait); run_pct_wall=100*drun/(dwall_ns); "
        "agg_*=sum over threads of class (use for ffmpeg)",
        "procs": procs,
        "ffmpeg_agg": agg("ffmpeg"),
        "misterplexd_agg": agg("misterplexd"),
        "mister_agg": agg("MiSTer"),
        "ffmpeg_top_wait_threads": top_wait("ffmpeg"),
        "misterplexd_top_wait_threads": top_wait("misterplexd"),
        "mister_top_wait_threads": top_wait("MiSTer"),
        "all_threads_top20": threads[:20],
    }


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--seconds", type=float, default=20.0)
    ap.add_argument("--label", default="schedstat")
    ap.add_argument("-o", "--output", required=True)
    args = ap.parse_args()
    data = sample(args.seconds, args.label)
    out = Path(args.output)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    print(
        f"schedstat label={data['label']} dwall={data['dwall_s']} "
        f"procs={[(p['comm'], p['wait_frac_pct'], p['run_pct_wall']) for p in data['procs']]} "
        f"out={out}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
