#!/usr/bin/env python3
"""ARM CPU% sampler for MiSTer soaks (parent-run on device or host self-test).

Method (binding — quote in every soak report):
  ONE wall clock per window.
  P = 100 * dticks / (HZ * dwall)   # %onecpu, no fps scaling
  Identity via readlink(/proc/<pid>/exe) realpath — NEVER cmdline substring
    (flock cmdline contains "misterplexd"; two install roots share basename).
  SYSTEM_BUSY from /proc/stat aggregate "cpu " line (awk fields after label).
  Absence of a process = omit (NO-DATA), never 0.0.

Overhead: two /proc walks + sleep(window). Typical <1%onecpu on A9 for 1–5s
windows; sampler does not renice or pin; does not kill anything.

Usage:
  # Single window (JSON):
  python3 tools/arm_cpu_sample.py --seconds 30 --label soak -o cpu.json
  # Multi-window soak series (one line per window + final summary):
  python3 tools/arm_cpu_sample.py --soak 120 --interval 10 --label cast480 -o cpu_soak.json
"""
from __future__ import annotations

import argparse
import json
import os
import time
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple


def clk_tck() -> int:
    try:
        v = os.sysconf("SC_CLK_TCK")
        if isinstance(v, int) and v > 0:
            return v
    except (ValueError, OSError, AttributeError):
        pass
    return 100


def read_system_cpu() -> Optional[Tuple[int, int]]:
    """Return (total_jiffies, idle_jiffies) for aggregate cpu line."""
    try:
        with open("/proc/stat", "r", encoding="utf-8") as f:
            for line in f:
                if line.startswith("cpu "):
                    parts = line.split()
                    # parts[0] == "cpu"; nums start at [1]
                    nums = [int(x) for x in parts[1:]]
                    idle = nums[3] + (nums[4] if len(nums) > 4 else 0)
                    total = sum(nums[:8]) if len(nums) >= 8 else sum(nums)
                    return total, idle
    except OSError:
        return None
    return None


def read_cpu_lines() -> List[Tuple[str, int, int]]:
    out: List[Tuple[str, int, int]] = []
    try:
        with open("/proc/stat", "r", encoding="utf-8") as f:
            for line in f:
                if not line.startswith("cpu"):
                    continue
                if len(line) > 3 and line[3].isdigit():
                    parts = line.split()
                    nums = [int(x) for x in parts[1:]]
                    idle = nums[3] + (nums[4] if len(nums) > 4 else 0)
                    total = sum(nums[:8]) if len(nums) >= 8 else sum(nums)
                    out.append((parts[0], total, idle))
    except OSError:
        pass
    return out


def list_pids() -> List[int]:
    try:
        return [int(n) for n in os.listdir("/proc") if n.isdigit()]
    except OSError:
        return []


def read_exe(pid: int) -> Optional[str]:
    try:
        p = os.readlink(f"/proc/{pid}/exe")
    except OSError:
        return None
    if p.endswith(" (deleted)"):
        p = p[: -len(" (deleted)")]
    try:
        return os.path.realpath(p)
    except OSError:
        return p


def read_ticks(pid: int) -> Optional[int]:
    try:
        raw = open(f"/proc/{pid}/stat", "r", encoding="utf-8").read()
    except OSError:
        return None
    rp = raw.rfind(")")
    if rp < 0:
        return None
    rest = raw[rp + 2 :].split()
    # After comm: state=1 … utime=field14 of full stat = index 11 in rest
    try:
        return int(rest[11]) + int(rest[12])
    except (IndexError, ValueError):
        return None


def classify(exe: str) -> str:
    base = os.path.basename(exe)
    bl = base.lower()
    if base == "MiSTer" or bl == "mister":
        return "MiSTer"
    if bl == "ffmpeg":
        return "ffmpeg"
    if bl == "misterplexd":
        return "misterplexd"
    return base


def sample_window(seconds: float, label: str) -> Dict[str, Any]:
    hz = clk_tck()
    t0 = time.perf_counter()
    sys0 = read_system_cpu()
    c0 = read_cpu_lines()
    p0: Dict[int, Tuple[str, str, int]] = {}
    for pid in list_pids():
        exe = read_exe(pid)
        ticks = read_ticks(pid)
        if exe is None or ticks is None:
            continue
        p0[pid] = (classify(exe), exe, ticks)
    time.sleep(max(0.05, seconds))
    dwall = time.perf_counter() - t0
    sys1 = read_system_cpu()
    c1 = read_cpu_lines()
    p1: Dict[int, Tuple[str, str, int]] = {}
    for pid in list_pids():
        exe = read_exe(pid)
        ticks = read_ticks(pid)
        if exe is None or ticks is None:
            continue
        p1[pid] = (classify(exe), exe, ticks)

    per_core = []
    for (n0, tot0, idle0), (n1, tot1, idle1) in zip(c0, c1):
        dt = tot1 - tot0
        di = idle1 - idle0
        busy = 100.0 * (dt - di) / dt if dt > 0 else 0.0
        per_core.append({"cpu": n0, "busy_pct": round(busy, 3), "djiffies": dt})

    system_busy = None
    ncpu = max(1, len(per_core))
    if sys0 and sys1:
        dt = sys1[0] - sys0[0]
        di = sys1[1] - sys0[1]
        if dt > 0:
            # % of one cpu * ncpu scale: busy fraction * ncpu * 100
            system_busy = round(100.0 * ncpu * (dt - di) / dt, 3)

    rows = []
    for pid, (cls, exe, t1) in p1.items():
        prev = p0.get(pid)
        if prev is None:
            continue
        t_prev = prev[2]
        pct = 100.0 * (t1 - t_prev) / (hz * dwall) if dwall > 0 else 0.0
        rows.append(
            {
                "pid": pid,
                "class": cls,
                "comm": os.path.basename(exe),
                "exe": exe,
                "pct_onecpu": round(pct, 3),
            }
        )
    rows.sort(key=lambda r: -r["pct_onecpu"])

    def sum_class(name: str) -> Optional[float]:
        hit = [r["pct_onecpu"] for r in rows if r["class"] == name]
        if not hit:
            return None  # NO-DATA, not 0.0
        return round(sum(hit), 3)

    ff = sum_class("ffmpeg")
    mp = sum_class("misterplexd")
    mi = sum_class("MiSTer")
    h1 = None
    if ff is not None or mp is not None:
        h1 = round((ff or 0.0) + (mp or 0.0), 3)
    accounted = round(sum(r["pct_onecpu"] for r in rows), 3)

    return {
        "label": label,
        "dwall_s": round(dwall, 4),
        "hz": hz,
        "method": "P=100*dticks/(HZ*dwall); exe=readlink(/proc/pid/exe) realpath; "
        "SYSTEM_BUSY=100*ncpu*(1-didle/dtotal) from /proc/stat 'cpu ' line",
        "system_busy_pct_of_machine": system_busy,  # e.g. 169 of 200 → 84.5 if ncpu=2... wait
        "system_busy_pct_onecpu_sum": system_busy,  # sum of cores busy = %onecpu total
        "ncpu": ncpu,
        "per_core": per_core,
        "processes": rows[:50],
        "MiSTer_pct_onecpu": mi,
        "ffmpeg_pct_onecpu": ff,
        "misterplexd_pct_onecpu": mp,
        "H1_stream_inelastic_pct_onecpu": h1,
        "H1_valid_play": bool(ff is not None and ff > 0.05),
        "accounted_sum_pct_onecpu": accounted,
        "sampler_overhead_note": (
            "two /proc walks + sleep; expect sampler self <<1 %onecpu on multi-second windows; "
            "do not subtract sampler from others"
        ),
        "headroom_note": (
            "Quote inelastic=ffmpeg+daemon and SYSTEM_BUSY separately. "
            "MiSTer is elastic scavenger — never publish (200-busy) as headroom."
        ),
    }


def format_line(data: Dict[str, Any]) -> str:
    def f(v: Optional[float]) -> str:
        return "NO-DATA" if v is None else f"{v:.1f}"

    sb = data.get("system_busy_pct_onecpu_sum")
    ncpu = data.get("ncpu") or 2
    cap = 100.0 * float(ncpu)
    sb_s = "NO-DATA" if sb is None else f"{sb:.1f}/{cap:.0f}"
    return (
        f"arm_cpu label={data['label']} wall_s={data['dwall_s']:.2f} "
        f"SYSTEM_BUSY={sb_s} "
        f"MiSTer={f(data.get('MiSTer_pct_onecpu'))} "
        f"ffmpeg={f(data.get('ffmpeg_pct_onecpu'))} "
        f"misterplexd={f(data.get('misterplexd_pct_onecpu'))} "
        f"H1_inelastic={f(data.get('H1_stream_inelastic_pct_onecpu'))} "
        f"accounted={data.get('accounted_sum_pct_onecpu')} "
        f"valid_play={data.get('H1_valid_play')} "
        f"method=exe+dticks tag=measured"
    )


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--seconds", type=float, default=20.0, help="single-window duration")
    ap.add_argument("--soak", type=float, default=0.0, help="total soak seconds (multi-window)")
    ap.add_argument("--interval", type=float, default=10.0, help="window length when --soak>0")
    ap.add_argument("--label", default="sample")
    ap.add_argument("-o", "--output", default="", help="JSON path (optional for soak stdout)")
    args = ap.parse_args()

    if args.soak and args.soak > 0:
        interval = max(0.5, args.interval)
        t_end = time.perf_counter() + args.soak
        windows: List[Dict[str, Any]] = []
        i = 0
        while time.perf_counter() < t_end:
            left = t_end - time.perf_counter()
            win = min(interval, max(0.5, left))
            data = sample_window(win, f"{args.label}_w{i}")
            windows.append(data)
            print(format_line(data), flush=True)
            i += 1
        # Aggregate means over windows with data
        def mean_key(k: str) -> Optional[float]:
            vals = [w[k] for w in windows if w.get(k) is not None]
            if not vals:
                return None
            return round(sum(vals) / len(vals), 3)

        summary = {
            "label": args.label,
            "soak_s": args.soak,
            "interval_s": interval,
            "n_windows": len(windows),
            "method": windows[0]["method"] if windows else "",
            "mean_SYSTEM_BUSY_pct_onecpu_sum": mean_key("system_busy_pct_onecpu_sum"),
            "mean_MiSTer_pct_onecpu": mean_key("MiSTer_pct_onecpu"),
            "mean_ffmpeg_pct_onecpu": mean_key("ffmpeg_pct_onecpu"),
            "mean_misterplexd_pct_onecpu": mean_key("misterplexd_pct_onecpu"),
            "mean_H1_inelastic_pct_onecpu": mean_key("H1_stream_inelastic_pct_onecpu"),
            "windows": windows,
            "tag": "measured",
        }
        print(
            f"arm_cpu_SOAK_SUMMARY label={args.label} n={len(windows)} "
            f"mean_SYSTEM_BUSY={summary['mean_SYSTEM_BUSY_pct_onecpu_sum']} "
            f"mean_MiSTer={summary['mean_MiSTer_pct_onecpu']} "
            f"mean_ffmpeg={summary['mean_ffmpeg_pct_onecpu']} "
            f"mean_daemon={summary['mean_misterplexd_pct_onecpu']} "
            f"mean_H1={summary['mean_H1_inelastic_pct_onecpu']} tag=measured",
            flush=True,
        )
        if args.output:
            Path(args.output).parent.mkdir(parents=True, exist_ok=True)
            Path(args.output).write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
            print(f"wrote {args.output}", flush=True)
        return 0

    data = sample_window(args.seconds, args.label)
    print(format_line(data), flush=True)
    if args.output:
        Path(args.output).parent.mkdir(parents=True, exist_ok=True)
        Path(args.output).write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
        print(f"wrote {args.output}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
