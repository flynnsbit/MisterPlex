#!/usr/bin/env python3
"""ARM CPU% sampler for MiSTer soaks (parent-run on device; host self-testable).

BINDING method (quote every soak report — field name + derivation):

  wall_s
    Derivation: perf_counter delta spanning the sample window (one wall clock).

  HZ
    Derivation: os.sysconf(SC_CLK_TCK), else 100 (Linux jiffy rate for /proc ticks).

  <proc>_pct_onecpu  (MiSTer / ffmpeg / misterplexd / sampler_self)
    Derivation: P = 100 * dticks / (HZ * wall_s)
      dticks = Δ(utime+stime) from /proc/<pid>/stat fields 14+15
      (after comm ')', rest indices 11+12).
    Identity: readlink(/proc/<pid>/exe) realpath basename class ONLY.
      NEVER cmdline (ERROR 14: flock cmdline contains "misterplexd").
      Two install roots share basename; full exe path is stamped.
    Absence of a class ⇒ NO-DATA (JSON null / printed NO-DATA). NEVER 0.0 for missing.

  SYSTEM_BUSY  printed as X/CAP  e.g. 169.0/200
    Derivation: 100 * ncpu * (1 - Δidle/Δtotal)
      total,idle from /proc/stat line whose field1 is the literal label "cpu"
      (use field split — never `read a b c` which mis-aligns on the label).
      idle = idle + iowait (fields 4+5 of the numeric vector, 0-based 3+4).
      ncpu = count of cpuN lines in /proc/stat (online cores observed).
      silicon CAP = 100 * ncpu  (dual A9 ⇒ 200). "86.6% of 200" ≡ SYSTEM_BUSY/CAP.

  effective_product_capacity_pct_onecpu
    Derivation: when MiSTer is observed, product work has ONE free core:
      effective = 100 (not silicon CAP). Parent 2026-08-04 /proc/stat: MiSTer is a
      pure userspace spin (~100% of one core at idle, state R, wchan=0). When
      MiSTer is NO-DATA (host self-test), effective is null — do not invent it.
    Do NOT treat (silicon_CAP - SYSTEM_BUSY) as product headroom.

  H1_inelastic
    Derivation: ffmpeg_pct_onecpu + misterplexd_pct_onecpu.
    MiSTer is INELASTIC (not an elastic scavenger). Contended-core budgets use
    effective_product_capacity, not dual-core idle headroom.

  daemon identity
    exe basename misterplexd OR kernel comm mpx-main (parent: daemon runs as
    comm=mpx-main; "search miss ≠ absent").

  rbf_md5 / rbf_path
    Derivation: md5sum of --rbf (default /media/fat/_Utility/Plex.rbf).
    Missing file ⇒ NO-DATA. Every line stamps this pair.

  daemon_md5 / daemon_exe / daemon_pid / daemon_comm
    Derivation: find pid whose basename(readlink exe)==misterplexd OR
      /proc/pid/stat comm==mpx-main; md5sum of that exe. Prefer misterplex_v2.
      Missing ⇒ NO-DATA. Stamp kernel comm (often mpx-main).

  decode_src
    Derivation: --decode-src override, else last decode_src= token in --log
    (or auto-probed misterplex logs). Empty ⇒ NO-DATA. NEVER pool soaks across
    different decode_src values.

  sampler_self_pct_onecpu
    Derivation: same P formula for this sampler's own PID over the window.
    MEASURED overhead, not an estimate.

Never kills. No pgrep/pkill/killall. No renice/pin.

Usage (device):
  python3 arm_cpu_sample.py --soak 120 --interval 10 --label cast480 \\
    -o /media/fat/misterplex_v2/cpu_soak.json
  python3 arm_cpu_sample.py --seconds 30 --label cast480
  # Always:  ... ; echo "true rc=$?"
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import time
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

DEFAULT_RBF = "/media/fat/_Utility/Plex.rbf"
LOG_CANDIDATES = (
    "/media/fat/misterplex_v2/misterplexd.log",
    "/media/fat/misterplex_v2/log/misterplexd.log",
    "/media/fat/misterplex/misterplexd.log",
    "/media/fat/misterplex/log/misterplexd.log",
    "/var/log/misterplexd.log",
)


def clk_tck() -> int:
    try:
        v = os.sysconf("SC_CLK_TCK")
        if isinstance(v, int) and v > 0:
            return v
    except (ValueError, OSError, AttributeError):
        pass
    return 100


def md5_file(path: str) -> Optional[str]:
    """md5 hex of file contents. Missing/unreadable ⇒ None (NO-DATA)."""
    try:
        h = hashlib.md5()
        with open(path, "rb") as f:
            for chunk in iter(lambda: f.read(1024 * 1024), b""):
                h.update(chunk)
        return h.hexdigest()
    except OSError:
        return None


def md5_proc_exe(pid: int, exe_path: str) -> Optional[str]:
    """Prefer hashing /proc/<pid>/exe (live mapping); fall back to path on disk."""
    for candidate in (f"/proc/{pid}/exe", exe_path):
        m = md5_file(candidate)
        if m:
            return m
    return None


def read_system_cpu() -> Optional[Tuple[int, int]]:
    """(total_jiffies, idle_jiffies) for aggregate 'cpu ' line."""
    try:
        with open("/proc/stat", "r", encoding="utf-8") as f:
            for line in f:
                if line.startswith("cpu "):
                    parts = line.split()
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
        raw = os.readlink(f"/proc/{pid}/exe")
    except OSError:
        return None
    if raw.endswith(" (deleted)"):
        raw = raw[: -len(" (deleted)")]
    try:
        return os.path.realpath(raw)
    except OSError:
        return raw


def read_ticks(pid: int) -> Optional[int]:
    try:
        with open(f"/proc/{pid}/stat", "r", encoding="utf-8", errors="replace") as f:
            raw = f.read()
    except OSError:
        return None
    rp = raw.rfind(")")
    if rp < 0:
        return None
    rest = raw[rp + 2 :].split()
    try:
        return int(rest[11]) + int(rest[12])
    except (IndexError, ValueError):
        return None


def read_comm(pid: int) -> Optional[str]:
    """Kernel comm from /proc/<pid>/stat (field between parentheses)."""
    try:
        with open(f"/proc/{pid}/stat", "r", encoding="utf-8", errors="replace") as f:
            raw = f.read()
    except OSError:
        return None
    lp = raw.find("(")
    rp = raw.rfind(")")
    if lp < 0 or rp < 0 or rp <= lp:
        return None
    return raw[lp + 1 : rp]


def classify(exe: str, comm: Optional[str] = None) -> str:
    base = os.path.basename(exe)
    bl = base.lower()
    if base == "MiSTer" or bl == "mister":
        return "MiSTer"
    if bl == "ffmpeg":
        return "ffmpeg"
    # Product daemon: exe is misterplexd; kernel comm is often mpx-main.
    if bl == "misterplexd" or (comm is not None and comm == "mpx-main"):
        return "misterplexd"
    return base


def pick_daemon(
    rows_by_pid: Dict[int, Tuple[str, str, int, Optional[str]]]
) -> Optional[Tuple[int, str, Optional[str]]]:
    """Return (pid, exe, comm) for misterplexd/mpx-main; prefer misterplex_v2."""
    cands: List[Tuple[int, str, Optional[str]]] = []
    for pid, (cls, exe, _t, comm) in rows_by_pid.items():
        if cls == "misterplexd":
            cands.append((pid, exe, comm))
    if not cands:
        return None

    def rank(item: Tuple[int, str, Optional[str]]) -> Tuple[int, str]:
        _pid, exe, _c = item
        pref = 0 if "misterplex_v2" in exe else (1 if "misterplex" in exe else 2)
        return (pref, exe)

    cands.sort(key=rank)
    return cands[0]


_DECODE_SRC_RE = re.compile(r"decode_src=([^\s]+)")
_MEAS_DEL_RE = re.compile(r"measured_delivery=([^\s]+)")
_DEL_VER_RE = re.compile(r"delivery_verified=([01])")


def scrape_log_fields(log_path: Optional[str]) -> Dict[str, Optional[str]]:
    """Last-seen decode_src / measured_delivery / delivery_verified from a log."""
    out: Dict[str, Optional[str]] = {
        "decode_src": None,
        "measured_delivery": None,
        "delivery_verified": None,
        "log_path": None,
    }
    paths: List[str] = []
    if log_path:
        paths.append(log_path)
    paths.extend(LOG_CANDIDATES)
    seen = set()
    for p in paths:
        if not p or p in seen:
            continue
        seen.add(p)
        try:
            # Tail-read last ~256 KiB to avoid full soak log scan cost
            with open(p, "rb") as f:
                f.seek(0, os.SEEK_END)
                sz = f.tell()
                f.seek(max(0, sz - 256 * 1024), os.SEEK_SET)
                text = f.read().decode("utf-8", errors="replace")
        except OSError:
            continue
        ds = md = dv = None
        for line in text.splitlines():
            m = _DECODE_SRC_RE.search(line)
            if m:
                ds = m.group(1)
            m = _MEAS_DEL_RE.search(line)
            if m:
                md = m.group(1)
            m = _DEL_VER_RE.search(line)
            if m:
                dv = m.group(1)
        if ds or md or dv:
            out["decode_src"] = ds
            out["measured_delivery"] = md
            out["delivery_verified"] = dv
            out["log_path"] = p
            return out
    return out


def sample_window(
    seconds: float,
    label: str,
    *,
    rbf_path: str,
    decode_src_override: Optional[str],
    log_path: Optional[str],
    self_pid: int,
) -> Dict[str, Any]:
    hz = clk_tck()
    # Artifact stamps (once per window; cheap)
    rbf_md5 = md5_file(rbf_path) if rbf_path else None
    log_fields = scrape_log_fields(log_path)
    decode_src = decode_src_override or log_fields.get("decode_src")

    t0 = time.perf_counter()
    sys0 = read_system_cpu()
    c0 = read_cpu_lines()
    p0: Dict[int, Tuple[str, str, int, Optional[str]]] = {}
    for pid in list_pids():
        exe = read_exe(pid)
        ticks = read_ticks(pid)
        if exe is None or ticks is None:
            continue
        comm = read_comm(pid)
        p0[pid] = (classify(exe, comm), exe, ticks, comm)
    time.sleep(max(0.05, seconds))
    dwall = time.perf_counter() - t0
    sys1 = read_system_cpu()
    c1 = read_cpu_lines()
    p1: Dict[int, Tuple[str, str, int, Optional[str]]] = {}
    for pid in list_pids():
        exe = read_exe(pid)
        ticks = read_ticks(pid)
        if exe is None or ticks is None:
            continue
        comm = read_comm(pid)
        p1[pid] = (classify(exe, comm), exe, ticks, comm)

    per_core = []
    for (n0, tot0, idle0), (_n1, tot1, idle1) in zip(c0, c1):
        dt = tot1 - tot0
        di = idle1 - idle0
        busy = 100.0 * (dt - di) / dt if dt > 0 else 0.0
        per_core.append({"cpu": n0, "busy_pct": round(busy, 3), "djiffies": dt})

    system_busy = None
    ncpu = max(1, len(per_core)) if per_core else max(1, os.cpu_count() or 1)
    if sys0 and sys1:
        dt = sys1[0] - sys0[0]
        di = sys1[1] - sys0[1]
        if dt > 0:
            system_busy = round(100.0 * ncpu * (dt - di) / dt, 3)

    rows = []
    for pid, (cls, exe, t1, comm) in p1.items():
        prev = p0.get(pid)
        if prev is None:
            continue
        t_prev = prev[2]
        pct = 100.0 * (t1 - t_prev) / (hz * dwall) if dwall > 0 else 0.0
        rows.append(
            {
                "pid": pid,
                "class": cls,
                "comm": comm if comm is not None else os.path.basename(exe),
                "exe": exe,
                "pct_onecpu": round(pct, 3),
            }
        )
    rows.sort(key=lambda r: -r["pct_onecpu"])

    def sum_class(name: str) -> Optional[float]:
        hit = [r["pct_onecpu"] for r in rows if r["class"] == name]
        if not hit:
            return None
        return round(sum(hit), 3)

    ff = sum_class("ffmpeg")
    mp = sum_class("misterplexd")
    mi = sum_class("MiSTer")
    h1 = None
    if ff is not None or mp is not None:
        h1 = round((ff or 0.0) + (mp or 0.0), 3)
    accounted = round(sum(r["pct_onecpu"] for r in rows), 3)

    # Sampler self overhead — MEASURED via own pid ticks
    sampler_pct = None
    if self_pid in p0 and self_pid in p1:
        dticks = p1[self_pid][2] - p0[self_pid][2]
        if dwall > 0 and dticks >= 0:
            sampler_pct = round(100.0 * dticks / (hz * dwall), 3)

    daemon = pick_daemon(p1) or pick_daemon(p0)
    daemon_pid = daemon[0] if daemon else None
    daemon_exe = daemon[1] if daemon else None
    daemon_comm = daemon[2] if daemon else None
    daemon_md5 = md5_proc_exe(daemon_pid, daemon_exe) if daemon else None

    silicon_cap = 100.0 * float(ncpu)
    # Parent 2026-08-04: MiSTer permanently owns ~one core (userspace spin).
    # Product decode+publish effective capacity is ONE core when MiSTer is present.
    if mi is not None:
        effective_cap: Optional[float] = 100.0
    else:
        effective_cap = None  # NO-DATA — host self-test without MiSTer
    return {
        "label": label,
        "wall_s": round(dwall, 4),
        "dwall_s": round(dwall, 4),  # alias
        "hz": hz,
        "ncpu": ncpu,
        "capacity_pct_onecpu": silicon_cap,  # silicon CAP = 100*ncpu (compat)
        "silicon_capacity_pct_onecpu": silicon_cap,
        "effective_product_capacity_pct_onecpu": effective_cap,
        "method": (
            "P=100*dticks/(HZ*wall_s); dticks=Δ(utime+stime) /proc/pid/stat f14+f15; "
            "exe=realpath(readlink /proc/pid/exe); comm=/proc/pid/stat; "
            "SYSTEM_BUSY=100*ncpu*(1-Δidle/Δtotal) from /proc/stat 'cpu ' "
            "(idle=idle+iowait); silicon_CAP=100*ncpu; "
            "effective_product_CAP=100 when MiSTer observed else NO-DATA; "
            "daemon=exe misterplexd OR comm mpx-main; absence=NO-DATA"
        ),
        "derivations": {
            "SYSTEM_BUSY": "100*ncpu*(1-Δidle/Δtotal) on /proc/stat cpu aggregate; printed X/silicon_CAP",
            "pct_onecpu": "100*Δ(utime+stime)/(HZ*wall_s)",
            "identity": "basename(realpath exe) or comm==mpx-main — never cmdline",
            "rbf_md5": f"md5 of {rbf_path}",
            "daemon_md5": "md5 of realpath exe for misterplexd/mpx-main (prefer misterplex_v2)",
            "decode_src": "--decode-src or last decode_src= in log tail",
            "sampler_self_pct_onecpu": "same P formula on sampler PID — measured overhead",
            "H1_inelastic": "ffmpeg_pct_onecpu + misterplexd_pct_onecpu",
            "effective_product_capacity_pct_onecpu": (
                "100 when MiSTer observed (one free core); null if MiSTer NO-DATA"
            ),
            "MiSTer": "INELASTIC pure userspace spin — not elastic scavenger",
        },
        "rbf_path": rbf_path,
        "rbf_md5": rbf_md5,  # None ⇒ NO-DATA
        "daemon_pid": daemon_pid,
        "daemon_exe": daemon_exe,
        "daemon_comm": daemon_comm,
        "daemon_md5": daemon_md5,
        "decode_src": decode_src,
        "measured_delivery": log_fields.get("measured_delivery"),
        "delivery_verified": log_fields.get("delivery_verified"),
        "log_path_used": log_fields.get("log_path"),
        "system_busy_pct_onecpu_sum": system_busy,
        "system_busy_pct_of_machine": system_busy,
        "per_core": per_core,
        "processes": rows[:50],
        "MiSTer_pct_onecpu": mi,
        "ffmpeg_pct_onecpu": ff,
        "misterplexd_pct_onecpu": mp,
        "H1_stream_inelastic_pct_onecpu": h1,
        "H1_valid_play": bool(ff is not None and ff > 0.05),
        "accounted_sum_pct_onecpu": accounted,
        "sampler_self_pct_onecpu": sampler_pct,
        "sampler_pid": self_pid,
        "tag": "measured",
        "headroom_note": (
            "Quote H1_inelastic, SYSTEM_BUSY, and effective_product_capacity separately. "
            "MiSTer is INELASTIC (~one core spin). Never publish (silicon_CAP-SYSTEM_BUSY) "
            "as product headroom; contended-core product capacity is one core when MiSTer lives."
        ),
    }


def _fmt(v: Optional[Any]) -> str:
    if v is None:
        return "NO-DATA"
    if isinstance(v, float):
        return f"{v:.1f}"
    return str(v)


def format_line(data: Dict[str, Any]) -> str:
    sb = data.get("system_busy_pct_onecpu_sum")
    cap = data.get("silicon_capacity_pct_onecpu") or data.get("capacity_pct_onecpu") or (
        100.0 * float(data.get("ncpu") or 2)
    )
    sb_s = "NO-DATA" if sb is None else f"{sb:.1f}/{cap:.0f}"
    eff = data.get("effective_product_capacity_pct_onecpu")
    return (
        f"arm_cpu label={data['label']} wall_s={data.get('wall_s', data.get('dwall_s'))} "
        f"SYSTEM_BUSY={sb_s} "
        f"eff_product_CAP={_fmt(eff)} "
        f"MiSTer={_fmt(data.get('MiSTer_pct_onecpu'))} "
        f"ffmpeg={_fmt(data.get('ffmpeg_pct_onecpu'))} "
        f"misterplexd={_fmt(data.get('misterplexd_pct_onecpu'))} "
        f"daemon_comm={_fmt(data.get('daemon_comm'))} "
        f"H1_inelastic={_fmt(data.get('H1_stream_inelastic_pct_onecpu'))} "
        f"accounted={_fmt(data.get('accounted_sum_pct_onecpu'))} "
        f"sampler_self={_fmt(data.get('sampler_self_pct_onecpu'))} "
        f"rbf_md5={_fmt(data.get('rbf_md5'))} "
        f"daemon_md5={_fmt(data.get('daemon_md5'))} "
        f"daemon_exe={_fmt(data.get('daemon_exe'))} "
        f"decode_src={_fmt(data.get('decode_src'))} "
        f"measured_delivery={_fmt(data.get('measured_delivery'))} "
        f"ncpu={data.get('ncpu')} "
        f"method=exe+dticks "
        f"tag=measured"
    )


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--seconds", type=float, default=20.0, help="single-window duration")
    ap.add_argument("--soak", type=float, default=0.0, help="total soak seconds (multi-window)")
    ap.add_argument("--interval", type=float, default=10.0, help="window length when --soak>0")
    ap.add_argument("--label", default="sample")
    ap.add_argument("-o", "--output", default="", help="JSON path")
    ap.add_argument("--rbf", default=DEFAULT_RBF, help="RBF path to md5-stamp (default Plex.rbf)")
    ap.add_argument(
        "--decode-src",
        default="",
        help="Partition key override (else scraped from --log). Empty=NO-DATA",
    )
    ap.add_argument(
        "--log",
        default="",
        help="misterplexd log to scrape decode_src/measured_delivery (tail 256KiB)",
    )
    args = ap.parse_args()
    self_pid = os.getpid()
    ds_over = args.decode_src.strip() or None
    log_path = args.log.strip() or None
    rbf_path = args.rbf

    if args.soak and args.soak > 0:
        interval = max(0.5, args.interval)
        t_end = time.perf_counter() + args.soak
        windows: List[Dict[str, Any]] = []
        i = 0
        while time.perf_counter() < t_end:
            left = t_end - time.perf_counter()
            win = min(interval, max(0.5, left))
            data = sample_window(
                win,
                f"{args.label}_w{i}",
                rbf_path=rbf_path,
                decode_src_override=ds_over,
                log_path=log_path,
                self_pid=self_pid,
            )
            windows.append(data)
            print(format_line(data), flush=True)
            i += 1

        def mean_key(k: str) -> Optional[float]:
            vals = [w[k] for w in windows if w.get(k) is not None]
            if not vals:
                return None
            return round(sum(vals) / len(vals), 3)

        # Artifact pair from last window (should be stable across soak)
        last = windows[-1] if windows else {}
        summary = {
            "label": args.label,
            "soak_s": args.soak,
            "interval_s": interval,
            "n_windows": len(windows),
            "method": last.get("method", ""),
            "derivations": last.get("derivations", {}),
            "rbf_path": rbf_path,
            "rbf_md5": last.get("rbf_md5"),
            "daemon_md5": last.get("daemon_md5"),
            "daemon_exe": last.get("daemon_exe"),
            "decode_src": last.get("decode_src"),
            "mean_SYSTEM_BUSY_pct_onecpu_sum": mean_key("system_busy_pct_onecpu_sum"),
            "mean_MiSTer_pct_onecpu": mean_key("MiSTer_pct_onecpu"),
            "mean_ffmpeg_pct_onecpu": mean_key("ffmpeg_pct_onecpu"),
            "mean_misterplexd_pct_onecpu": mean_key("misterplexd_pct_onecpu"),
            "mean_H1_inelastic_pct_onecpu": mean_key("H1_stream_inelastic_pct_onecpu"),
            "mean_sampler_self_pct_onecpu": mean_key("sampler_self_pct_onecpu"),
            "capacity_pct_onecpu": last.get("capacity_pct_onecpu"),
            "silicon_capacity_pct_onecpu": last.get("silicon_capacity_pct_onecpu"),
            "effective_product_capacity_pct_onecpu": last.get(
                "effective_product_capacity_pct_onecpu"
            ),
            "ncpu": last.get("ncpu"),
            "windows": windows,
            "tag": "measured",
        }
        print(
            f"arm_cpu_SOAK_SUMMARY label={args.label} n={len(windows)} "
            f"mean_SYSTEM_BUSY={_fmt(summary['mean_SYSTEM_BUSY_pct_onecpu_sum'])} "
            f"mean_MiSTer={_fmt(summary['mean_MiSTer_pct_onecpu'])} "
            f"mean_ffmpeg={_fmt(summary['mean_ffmpeg_pct_onecpu'])} "
            f"mean_daemon={_fmt(summary['mean_misterplexd_pct_onecpu'])} "
            f"mean_H1={_fmt(summary['mean_H1_inelastic_pct_onecpu'])} "
            f"mean_sampler_self={_fmt(summary['mean_sampler_self_pct_onecpu'])} "
            f"rbf_md5={_fmt(summary['rbf_md5'])} "
            f"daemon_md5={_fmt(summary['daemon_md5'])} "
            f"decode_src={_fmt(summary['decode_src'])} "
            f"tag=measured",
            flush=True,
        )
        if args.output:
            Path(args.output).parent.mkdir(parents=True, exist_ok=True)
            Path(args.output).write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
            print(f"wrote {args.output}", flush=True)
        return 0

    data = sample_window(
        args.seconds,
        args.label,
        rbf_path=rbf_path,
        decode_src_override=ds_over,
        log_path=log_path,
        self_pid=self_pid,
    )
    print(format_line(data), flush=True)
    if args.output:
        Path(args.output).parent.mkdir(parents=True, exist_ok=True)
        Path(args.output).write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
        print(f"wrote {args.output}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
