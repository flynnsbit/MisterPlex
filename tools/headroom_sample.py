#!/usr/bin/env python3
"""One-window CPU headroom sampler for MiSTerPlex (on-device or host).

Method (binding — matches docs/evidence/p480-headroom-* REPORT):
  ONE window, ONE wall clock.
  P = 100 * dticks / (HZ * dwall)   # %onecpu, no fps scaling
  HZ from sysconf(SC_CLK_TCK), typically 100 on MiSTer.
  Process identity via readlink(/proc/<pid>/exe) realpath — NEVER cmdline
  substring (ERROR 14: flock cmdline contains "misterplexd").

Usage:
  python3 tools/headroom_sample.py --label idle --seconds 10 -o headroom_idle.json
  python3 tools/headroom_sample.py --label play_480p --seconds 45 -o headroom_play480.json

Exit: 0 on success. Prints path + machine_busy summary to stdout.
true rc must be captured by the parent directly (never through a pipe alone).
"""
from __future__ import annotations

import argparse
import json
import os
import time
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

HZ_DEFAULT = 100


def clk_tck() -> int:
    try:
        v = os.sysconf("SC_CLK_TCK")
        if isinstance(v, int) and v > 0:
            return v
    except (ValueError, OSError, AttributeError):
        pass
    return HZ_DEFAULT


def ncpu() -> int:
    try:
        return max(1, len(os.sched_getaffinity(0)))
    except (AttributeError, OSError):
        return max(1, os.cpu_count() or 1)


def read_proc_stat_totals() -> Tuple[int, int]:
    """Return (total_jiffies, idle_jiffies) from /proc/stat first cpu line."""
    with open("/proc/stat", "r", encoding="utf-8") as f:
        line = f.readline()
    # cpu user nice system idle iowait irq softirq steal guest guest_nice
    parts = line.split()
    if not parts or parts[0] != "cpu":
        raise RuntimeError("unexpected /proc/stat")
    nums = [int(x) for x in parts[1:]]
    idle = nums[3] + (nums[4] if len(nums) > 4 else 0)  # idle + iowait
    total = sum(nums[:8]) if len(nums) >= 8 else sum(nums)
    return total, idle


def read_pid_stat_ticks(pid: int) -> Optional[int]:
    """utime+stime from /proc/<pid>/stat fields 14+15 (1-based)."""
    try:
        with open(f"/proc/{pid}/stat", "r", encoding="utf-8") as f:
            raw = f.read()
    except OSError:
        return None
    # comm may contain spaces/parens — split after last ')'
    rparen = raw.rfind(")")
    if rparen < 0:
        return None
    rest = raw[rparen + 2 :].split()
    # after comm: state(3) ppid(4)... utime is field 14 → index 11 in rest
    # fields after ')': 3=state ... so field N is rest[N-3]
    try:
        utime = int(rest[14 - 3])
        stime = int(rest[15 - 3])
    except (IndexError, ValueError):
        return None
    return utime + stime


def read_tid_stat(pid: int, tid: int) -> Optional[Tuple[str, int, int, int]]:
    """Return (comm, utime+stime, nvcsw, nivcsw) for a task."""
    try:
        with open(f"/proc/{pid}/task/{tid}/stat", "r", encoding="utf-8") as f:
            raw = f.read()
    except OSError:
        return None
    lparen = raw.find("(")
    rparen = raw.rfind(")")
    if lparen < 0 or rparen < 0:
        return None
    comm = raw[lparen + 1 : rparen]
    rest = raw[rparen + 2 :].split()
    try:
        utime = int(rest[14 - 3])
        stime = int(rest[15 - 3])
    except (IndexError, ValueError):
        return None
    nvcsw = nivcsw = 0
    try:
        with open(f"/proc/{pid}/task/{tid}/status", "r", encoding="utf-8") as f:
            for line in f:
                if line.startswith("voluntary_ctxt_switches:"):
                    nvcsw = int(line.split()[1])
                elif line.startswith("nonvoluntary_ctxt_switches:"):
                    nivcsw = int(line.split()[1])
    except (OSError, ValueError, IndexError):
        pass
    return comm, utime + stime, nvcsw, nivcsw


def exe_basename(pid: int) -> Optional[str]:
    try:
        path = os.readlink(f"/proc/{pid}/exe")
    except OSError:
        return None
    # " (deleted)" suffix
    if path.endswith(" (deleted)"):
        path = path[: -len(" (deleted)")]
    try:
        path = os.path.realpath(path)
    except OSError:
        pass
    base = os.path.basename(path)
    return base or None


def classify_proc(exe_base: str) -> str:
    """Stable short name from resolved exe basename (not cmdline)."""
    b = exe_base.lower()
    if b == "mister" or b.endswith("/mister"):
        return "MiSTer"
    if "ffmpeg" in b:
        return "ffmpeg"
    if "misterplexd" in b:
        return "misterplexd"
    return exe_base


def list_pids() -> List[int]:
    out: List[int] = []
    for name in os.listdir("/proc"):
        if name.isdigit():
            out.append(int(name))
    return out


def list_tids(pid: int) -> List[int]:
    try:
        return [int(x) for x in os.listdir(f"/proc/{pid}/task") if x.isdigit()]
    except OSError:
        return []


def pct(dticks: int, hz: int, dwall: float) -> float:
    if dwall <= 0 or hz <= 0:
        return 0.0
    return 100.0 * float(dticks) / (float(hz) * dwall)


def sample(label: str, seconds: float, top_n: int = 15, top_thr: int = 25) -> Dict[str, Any]:
    hz = clk_tck()
    n_cpu = ncpu()

    # Snapshot A
    t0 = time.perf_counter()
    stat0_tot, stat0_idle = read_proc_stat_totals()
    pid_ticks0: Dict[int, int] = {}
    pid_name0: Dict[int, str] = {}
    thr0: Dict[Tuple[int, int], Tuple[str, int, int, int]] = {}

    for pid in list_pids():
        name = exe_basename(pid)
        if not name:
            # kernel threads have no exe — skip for product table; still optional
            continue
        ticks = read_pid_stat_ticks(pid)
        if ticks is None:
            continue
        pid_ticks0[pid] = ticks
        pid_name0[pid] = classify_proc(name)
        for tid in list_tids(pid):
            info = read_tid_stat(pid, tid)
            if info:
                thr0[(pid, tid)] = info

    # Wait wall window
    end = t0 + max(0.1, float(seconds))
    while True:
        now = time.perf_counter()
        if now >= end:
            break
        time.sleep(min(0.25, end - now))

    # Snapshot B
    t1 = time.perf_counter()
    dwall = t1 - t0
    stat1_tot, stat1_idle = read_proc_stat_totals()
    dtotal = max(0, stat1_tot - stat0_tot)
    didle = max(0, stat1_idle - stat0_idle)

    proc_rows: List[Dict[str, Any]] = []
    thr_rows: List[Dict[str, Any]] = []
    ffmpeg_thr: List[Dict[str, Any]] = []
    mplex_thr: List[Dict[str, Any]] = []

    for pid, t0v in pid_ticks0.items():
        t1v = read_pid_stat_ticks(pid)
        if t1v is None:
            continue
        dt = max(0, t1v - t0v)
        name = pid_name0.get(pid) or classify_proc(exe_basename(pid) or f"pid{pid}")
        proc_rows.append(
            {
                "pid": pid,
                "comm": name,
                "dticks": dt,
                "pct_onecpu": round(pct(dt, hz, dwall), 3),
            }
        )
        for tid in list_tids(pid):
            info1 = read_tid_stat(pid, tid)
            info0 = thr0.get((pid, tid))
            if not info1 or not info0:
                continue
            comm1, ticks1, nvcsw1, nivcsw1 = info1
            _comm0, ticks0, nvcsw0, nivcsw0 = info0
            dtt = max(0, ticks1 - ticks0)
            row = {
                "tid": tid,
                "pid": pid,
                "comm": comm1,
                "proc": name,
                "dticks": dtt,
                "pct_onecpu": round(pct(dtt, hz, dwall), 3),
                "nvcsw_d": max(0, nvcsw1 - nvcsw0),
                "nivcsw_d": max(0, nivcsw1 - nivcsw0),
                "flag": "ok",
            }
            thr_rows.append(row)
            if name == "ffmpeg":
                ffmpeg_thr.append(row)
            elif name == "misterplexd":
                mplex_thr.append(row)

    proc_rows.sort(key=lambda r: r["pct_onecpu"], reverse=True)
    thr_rows.sort(key=lambda r: r["pct_onecpu"], reverse=True)
    ffmpeg_thr.sort(key=lambda r: r["pct_onecpu"], reverse=True)
    mplex_thr.sort(key=lambda r: r["pct_onecpu"], reverse=True)

    top_procs = proc_rows[:top_n]
    top_threads = thr_rows[:top_thr]

    machine_busy = pct(dtotal - didle, hz, dwall)
    # machine busy is already across all CPUs in jiffies; /proc/stat total is
    # sum over CPUs, so P=100*dwork/(HZ*dwall) yields %onecpu of the *machine*
    # (0..ncpu*100). Matches evidence JSON (idle ~108, play ~174 on 2 CPUs).
    machine_idle = max(0.0, float(n_cpu) * 100.0 - machine_busy)

    ff_sum = round(sum(r["pct_onecpu"] for r in ffmpeg_thr), 3)
    ff_top = round(ffmpeg_thr[0]["pct_onecpu"], 3) if ffmpeg_thr else 0.0
    mp_sum = round(sum(r["pct_onecpu"] for r in mplex_thr), 3)
    mp_top = round(mplex_thr[0]["pct_onecpu"], 3) if mplex_thr else 0.0

    def proc_pct(name: str) -> float:
        for r in proc_rows:
            if r["comm"] == name:
                return float(r["pct_onecpu"])
        return 0.0

    ff_proc = proc_pct("ffmpeg")
    mp_proc = proc_pct("misterplexd")
    mi_proc = proc_pct("MiSTer")
    # H1: inelastic stream only — NEVER subtract MiSTer (elastic scavenger).
    h1 = round(ff_proc + mp_proc, 3)
    valid_play = ff_proc > 0.05  # absence is NO-DATA, not 0 headroom

    return {
        "label": label,
        "hz": hz,
        "ncpu": n_cpu,
        "dwall_s": round(dwall, 3),
        "formula": "P=100*dticks/(HZ*dwall)",
        "machine_busy_pct_onecpu": round(machine_busy, 3),
        "machine_idle_pct_onecpu": round(machine_idle, 3),
        "proc_stat_dtotal": dtotal,
        "proc_stat_didle": didle,
        "top_procs": top_procs,
        "top_threads": top_threads,
        "ffmpeg_thread_sum_pct": ff_sum,
        "ffmpeg_top_thread_pct": ff_top,
        "ffmpeg_threads": ffmpeg_thr,
        "misterplexd_thread_sum_pct": mp_sum,
        "misterplexd_top_thread_pct": mp_top,
        "misterplexd_threads": mplex_thr,
        "sum_top15_procs_pct": round(sum(r["pct_onecpu"] for r in top_procs), 3),
        # --- headroom v2 (do not use 200-machine_busy) ---
        "H1_stream_inelastic_pct_onecpu": h1,
        "H1_ffmpeg_pct_onecpu": round(ff_proc, 3),
        "H1_misterplexd_pct_onecpu": round(mp_proc, 3),
        "MiSTer_elastic_pct_onecpu": round(mi_proc, 3),
        "H1_valid_play": valid_play,
        "headroom_note": (
            "Use H1_stream_inelastic only. MiSTer is elastic scavenger — "
            "do NOT publish (200 - machine_busy) as headroom."
        ),
    }


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--label", default="sample", help="label field in JSON")
    ap.add_argument("--seconds", type=float, default=10.0, help="wall window seconds")
    ap.add_argument("-o", "--output", required=True, help="output JSON path")
    ap.add_argument("--top-procs", type=int, default=15)
    ap.add_argument("--top-threads", type=int, default=25)
    args = ap.parse_args()

    data = sample(args.label, args.seconds, top_n=args.top_procs, top_thr=args.top_threads)
    out = Path(args.output)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")

    # Compact greppable summary
    def find_pct(name: str) -> float:
        for r in data["top_procs"]:
            if r["comm"] == name:
                return float(r["pct_onecpu"])
        return 0.0

    print(
        f"headroom_sample label={data['label']} dwall={data['dwall_s']} "
        f"H1={data['H1_stream_inelastic_pct_onecpu']} valid_play={data['H1_valid_play']} "
        f"ffmpeg={data['H1_ffmpeg_pct_onecpu']} misterplexd={data['H1_misterplexd_pct_onecpu']} "
        f"MiSTer_elastic={data['MiSTer_elastic_pct_onecpu']} "
        f"busy={data['machine_busy_pct_onecpu']} "
        f"(do_not_use_idle_rem={data['machine_idle_pct_onecpu']}) out={out}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
