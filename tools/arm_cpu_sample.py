#!/usr/bin/env python3
"""Per-process + per-core %onecpu sampler for MiSTer soaks (parent-run).

Method (binding):
  ONE window, ONE wall clock.
  P = 100 * dticks / (HZ * dwall)   # %onecpu, no fps scaling
  Identity via readlink(/proc/<pid>/exe) realpath — NEVER cmdline substring.

Outputs JSON with:
  - per_core[cpuN].busy_pct
  - processes[] sorted by pct_onecpu (exe basename + full path)
  - H1_stream_inelastic = ffmpeg + misterplexd only
  - MiSTer_elastic listed separately (do NOT subtract into headroom)
  - H1_valid_play if ffmpeg present by exe

Usage:
  python3 tools/arm_cpu_sample.py --seconds 20 --label play240 -o arm_cpu.json
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


def read_cpu_lines() -> List[Tuple[str, int, int]]:
    """(name, total_jiffies, idle_jiffies) for cpu0, cpu1, ..."""
    out: List[Tuple[str, int, int]] = []
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
    return out


def list_pids() -> List[int]:
    return [int(n) for n in os.listdir("/proc") if n.isdigit()]


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
    try:
        return int(rest[14 - 3]) + int(rest[15 - 3])
    except (IndexError, ValueError):
        return None


def classify(exe: str) -> str:
    base = os.path.basename(exe)
    bl = base.lower()
    if base == "MiSTer" or bl == "mister":
        return "MiSTer"
    if "ffmpeg" in bl:
        return "ffmpeg"
    if "misterplexd" in bl:
        return "misterplexd"
    return base


def sample(seconds: float, label: str) -> Dict[str, Any]:
    hz = clk_tck()
    t0 = time.perf_counter()
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

    rows = []
    for pid, (cls, exe, t1) in p1.items():
        t_prev = p0.get(pid, (None, None, None))[2]
        if t_prev is None:
            continue
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

    def sum_class(name: str) -> float:
        return round(sum(r["pct_onecpu"] for r in rows if r["class"] == name), 3)

    ff = sum_class("ffmpeg")
    mp = sum_class("misterplexd")
    mi = sum_class("MiSTer")
    h1 = round(ff + mp, 3)
    valid = ff > 0.05

    return {
        "label": label,
        "dwall_s": round(dwall, 4),
        "hz": hz,
        "method": "P=100*dticks/(HZ*dwall); exe=readlink realpath",
        "per_core": per_core,
        "processes": rows[:40],
        "H1_stream_inelastic_pct_onecpu": h1,
        "H1_ffmpeg_pct_onecpu": ff,
        "H1_misterplexd_pct_onecpu": mp,
        "H1_valid_play": valid,
        "MiSTer_elastic_pct_onecpu": mi,
        "headroom_note": (
            "Quote H1 + per_core + top processes. "
            "MiSTer is elastic scavenger — never publish (200 - sum) as headroom."
        ),
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--seconds", type=float, default=20.0)
    ap.add_argument("--label", default="sample")
    ap.add_argument("-o", "--output", required=True)
    args = ap.parse_args()
    data = sample(args.seconds, args.label)
    out = Path(args.output)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    print(
        f"arm_cpu_sample label={data['label']} dwall={data['dwall_s']} "
        f"H1={data['H1_stream_inelastic_pct_onecpu']} valid={data['H1_valid_play']} "
        f"ff={data['H1_ffmpeg_pct_onecpu']} d={data['H1_misterplexd_pct_onecpu']} "
        f"MiSTer={data['MiSTer_elastic_pct_onecpu']} "
        f"cores={[c['busy_pct'] for c in data['per_core']]} out={out}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
