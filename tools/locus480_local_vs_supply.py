#!/usr/bin/env python3
"""Within-run LOCAL vs SUPPLY locus instrument for 480p frame loss (host + device).

WHY (parent 2026-08-02 — fleet critical path)
--------------------------------------------
Degraded 480p run (quoted):
  frames=5011 wall_s=249.8 drops=356 audio_s=209.1
  wall*24=5995 needed → 984 SHORT; drops only 356 (7.1% of deficit)
  audio_s*24 ≈ frames → A/V lockstep common upstream stall
  supply_ratio alone is a VOID endpoint (socket-starved vs consumer-blocked
  both predict the same ratio). Event rate ~25% → single-run A/B has no power.

MISS (parent hardware 2026-08-02 — published, do not reintroduce)
----------------------------------------------------------------
v1 pre-register used binary indicators:
  LOCAL = recv_q>0 sustained AND any ffmpeg thread in pipe_write
  SUPPLY = recv_q~0 AND not pipe_write
Healthy soak (supply=0.993 drops=16) measured BOTH at ceiling:
  recv_q_gt0_frac=1.0  recv_q_max=83549
  ffmpeg_pipe_write_frac=1.0
Cause BY DESIGN: audio pacer back-pressures ffmpeg at 1x
(media_player.cpp audioPump / present loop) — normal paced playback
holds a full pipe and a non-empty socket. Binary LOCAL is saturated
and cannot rise in degradation. Shape (a) in w-lint audit.

FINDING THAT STANDS: recv_q>0 with tens of KB unread throughout a healthy
run independently refutes steady-state link/sender-short (socket never empty).

v2 PRE-REGISTER (magnitude / dynamics — within-run healthy baseline)
--------------------------------------------------------------------
Split each run into non-degraded (healthy portion) vs degraded seconds.
Channels (all compared degrade vs healthy baseline of THE SAME run):

  | hypothesis | recv_q magnitude / d_recv_q     | pipe_write THREAD frac   |
  |------------|----------------------------------|--------------------------|
  | LOCAL      | median_deg >> median_h OR        | mean thread_frac_deg     |
  |            | mean d_recv_q_deg > 0 sustained  | significantly > healthy  |
  | SUPPLY     | median_deg << median_h           | thread_frac not rising;  |
  |            | (collapse toward empty)          | often flat/down          |

SATURATION GUARD (generalises to every gate):
  If an indicator is at ceiling/floor on the *non-degraded* portion of the
  same run, it is marked SATURATED and MUST NOT be used for a verdict.
  Binary recv_q>0 and binary any-pipe_write are expected SATURATED under
  intentional pacing — reported for provenance, never as locus proof.
  If no unsaturated discriminative channel remains → INSUFFICIENT_EVIDENCE.

residual: never rounded. residual=1 on a multi-k frame run is reported as 1
with note residual_near_closed (|r|<=1) but NOT coerced to 0.

MODES
-----
  sample   ON-DEVICE JSONL @ 1 Hz local file only (no SSH mid-run).
  verdict  HOST score + saturation guard + magnitude locus.
  self-test  RBG: LOCAL, SUPPLY, saturated-healthy refuse, insufficient, session.

Exit codes (w-avsync aligned; capture DIRECTLY — never through a pipe):
   0  HEALTHY
   2  SUPPLY_ESTABLISHED
   3  LOCAL_ESTABLISHED
   4  LOCUS_UNKNOWN
  78  INSUFFICIENT_EVIDENCE (incl. saturated discriminators)
  79  SESSION_INVALID
  77  NO-DATA
   1  usage

Absence is NO-DATA, never 0.0. Negative counter deltas → NO-DATA.

Related:
  tools/pms_recvq_backlog_sample.sh, tools/daemon_media_ledger.py,
  tools/score_supply_starve.py (w-avsync locus names)
"""
from __future__ import annotations

import argparse
import json
import os
import re
import statistics
import subprocess
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence, Tuple

# --- exit codes (w-avsync aligned) ------------------------------------------------
RC_OK = 0
RC_USAGE = 1
RC_SUPPLY = 2          # starved_transport / SUPPLY_ESTABLISHED
RC_LOCAL = 3           # starved_consumer / LOCAL_ESTABLISHED
RC_UNKNOWN = 4         # degraded, locus not proven
RC_INSUFFICIENT = 78   # INSUFFICIENT_EVIDENCE
RC_SESSION_INVALID = 79
RC_NO_DATA = 77

PROV_MEAS = "measured"
PROV_RECON = "reconstructed"
PROV_CALLER = "caller_supplied"
PROV_DEFAULT = "DEFAULT_ASSUMED"
PROV_NODATA = "NO-DATA"

LOG_CANDIDATES = (
    "/media/fat/misterplex_v2/misterplexd.log",
    "/media/fat/misterplex_v2/log/misterplexd.log",
    "/media/fat/misterplex/misterplexd.log",
    "/media/fat/misterplex/log/misterplexd.log",
    "/var/log/misterplexd.log",
)

RE_KV = re.compile(r"([A-Za-z_][A-Za-z0-9_]*)=([^\s]+)")
SS_BIN_CANDIDATES = ("/usr/sbin/ss", "/sbin/ss", "ss")

# Thresholds — labelled DEFAULT_ASSUMED where not caller-supplied
DEFAULT_HZ = 1.0
DEFAULT_DEGRADE_SUPPLY = 0.90
DEFAULT_NEAR_ZERO_VFPS = 1.0
DEFAULT_RECV_Q_LOCAL_MIN = 1          # legacy binary (reported only; SATURATED under pace)
DEFAULT_SUSTAINED_FRAC = 0.20
DEFAULT_MIN_DEGRADED_S = 5
DEFAULT_MIN_COVERAGE = 0.50
DEFAULT_SAT_CEILING = 0.95            # frac >= this on healthy → SATURATED high
DEFAULT_SAT_FLOOR = 0.05              # frac <= this on healthy → SATURATED low
DEFAULT_RQ_RATIO_LOCAL = 2.0          # median_deg / median_h >= → LOCAL magnitude
DEFAULT_RQ_RATIO_SUPPLY = 0.5         # median_deg / median_h <= → SUPPLY collapse
DEFAULT_PW_FRAC_DELTA = 0.10          # thread_frac_deg - thread_frac_h >= → LOCAL wchan
DEFAULT_D_RQ_LOCAL = 0.0              # mean d_recv_q during deg > this → backlog growing
DEFAULT_MIN_HEALTHY_S = 5             # need healthy baseline seconds for within-run compare


def _nodata(reason: str) -> Dict[str, Any]:
    return {"v": None, "src": PROV_NODATA, "reason": reason}


def _meas(v: Any, **extra: Any) -> Dict[str, Any]:
    d: Dict[str, Any] = {"v": v, "src": PROV_MEAS}
    d.update(extra)
    return d


def clk_tck() -> int:
    try:
        return int(os.sysconf("SC_CLK_TCK"))
    except (ValueError, OSError, AttributeError):
        return 100


# --- process identity (ERROR 14: exe basename only) ------------------------------

def pids_by_exe_basename(names: Sequence[str]) -> Dict[str, List[int]]:
    want = set(names)
    out: Dict[str, List[int]] = {n: [] for n in names}
    try:
        for ent in Path("/proc").iterdir():
            if not ent.name.isdigit():
                continue
            try:
                exe = os.path.realpath(str(ent / "exe"))
            except OSError:
                continue
            base = os.path.basename(exe)
            if base in want or any(base.startswith(n) for n in want):
                # normalize misterplexd_* → misterplexd key if requested
                key = base
                for n in names:
                    if base == n or base.startswith(n):
                        key = n
                        break
                out.setdefault(key, []).append(int(ent.name))
    except OSError:
        pass
    return out


def read_wchan_bundle(pid: int) -> Dict[str, Any]:
    """Per-thread wchan for pid. Absence → NO-DATA (never empty-as-zero claim)."""
    task = Path(f"/proc/{pid}/task")
    if not task.is_dir():
        return _nodata("no_task_dir")
    counts: Dict[str, int] = {}
    n = 0
    pipe_write_n = 0
    pipe_read_n = 0
    sock_n = 0
    try:
        for tid_dir in task.iterdir():
            if not tid_dir.name.isdigit():
                continue
            wpath = tid_dir / "wchan"
            try:
                w = wpath.read_text(errors="replace").strip() or "0"
            except OSError:
                continue
            n += 1
            counts[w] = counts.get(w, 0) + 1
            wl = w.lower()
            if "pipe_write" in wl or wl in ("pipe_wait", "pipe_w"):
                # Linux often shows "pipe_write" or "0" when runnable; also check
                pass
            if "pipe_write" in wl:
                pipe_write_n += 1
            if "pipe_read" in wl:
                pipe_read_n += 1
            if any(s in wl for s in ("tcp_recv", "tcp_recvmsg", "sock_recv", "inet_recv",
                                     "wait_woken", "sk_wait", "tcp_data")):
                sock_n += 1
            # Broaden socket-read: common MiSTer/ffmpeg wchans
            if any(s in wl for s in ("recvmsg", "tcp_recvmsg", "sk_stream_wait_data",
                                     "unix_stream_read", "do_readv")):
                sock_n += 1
    except OSError:
        return _nodata("task_walk_fail")
    if n == 0:
        return _nodata("zero_threads")
    top = sorted(counts.items(), key=lambda kv: (-kv[1], kv[0]))[:8]
    return _meas(
        {
            "n_threads": n,
            "pipe_write_n": pipe_write_n,
            "pipe_read_n": pipe_read_n,
            "socket_readish_n": sock_n,
            "top": [{"wchan": w, "n": c} for w, c in top],
        }
    )


def read_proc_ticks(pid: int) -> Optional[int]:
    try:
        st = Path(f"/proc/{pid}/stat").read_text(errors="replace")
    except OSError:
        return None
    # after comm)
    try:
        rest = st.split(")", 1)[1].split()
        utime = int(rest[11])
        stime = int(rest[12])
        return utime + stime
    except (IndexError, ValueError):
        return None


def read_system_idle_total() -> Optional[Tuple[int, int, int]]:
    """Return (total, idle+iowait, ncpu) from /proc/stat."""
    try:
        lines = Path("/proc/stat").read_text(errors="replace").splitlines()
    except OSError:
        return None
    total = idle = None
    ncpu = 0
    for ln in lines:
        parts = ln.split()
        if not parts:
            continue
        if parts[0] == "cpu":
            # fields: user nice system idle iowait irq softirq steal ...
            nums = [int(x) for x in parts[1:]]
            if len(nums) < 5:
                return None
            idle = nums[3] + nums[4]
            total = sum(nums)
        elif parts[0].startswith("cpu") and parts[0][3:].isdigit():
            ncpu += 1
    if total is None or idle is None or ncpu == 0:
        return None
    return total, idle, ncpu


def read_rx_bytes(prefer: Optional[str] = None) -> Dict[str, Any]:
    try:
        text = Path("/proc/net/dev").read_text(errors="replace")
    except OSError:
        return _nodata("no_proc_net_dev")
    best_iface = None
    best_rx = None
    for ln in text.splitlines():
        if ":" not in ln:
            continue
        iface, rest = ln.split(":", 1)
        iface = iface.strip()
        if iface == "lo":
            continue
        cols = rest.split()
        if not cols:
            continue
        try:
            rx = int(cols[0])
        except ValueError:
            continue
        if prefer and iface == prefer:
            return _meas(rx, iface=iface)
        if best_rx is None or rx > best_rx:
            best_rx = rx
            best_iface = iface
    if best_iface is None or best_rx is None:
        return _nodata("no_iface")
    return _meas(best_rx, iface=best_iface)


def find_ss_bin() -> Optional[str]:
    for c in SS_BIN_CANDIDATES:
        if c.startswith("/") and os.access(c, os.X_OK):
            return c
        path = subprocess.run(
            ["sh", "-c", f"command -v {c}"], capture_output=True, text=True
        )
        if path.returncode == 0 and path.stdout.strip():
            return path.stdout.strip()
    return None


def sample_recv_q(ffmpeg_pid: Optional[int], ss_bin: Optional[str]) -> Dict[str, Any]:
    """Recv-Q for ffmpeg's PMS TCP socket. 0 is measured; missing is NO-DATA."""
    if ffmpeg_pid is None:
        return _nodata("no_ffmpeg_pid")
    if not ss_bin:
        return _nodata("ss_missing")
    try:
        proc = subprocess.run(
            [ss_bin, "-tinp"],
            capture_output=True,
            text=True,
            timeout=2.0,
        )
    except (OSError, subprocess.TimeoutExpired):
        return _nodata("ss_exec_fail")
    blob = proc.stdout or ""
    if not blob.strip():
        return _nodata("ss_empty")

    # Parse ss -tinp multi-line records. Prefer peer :32400.
    best = None  # (prio, recv_q, tuple, bytes_received)
    cur_head = ""
    cur_body: List[str] = []

    def flush() -> None:
        nonlocal best, cur_head, cur_body
        if not cur_head and not cur_body:
            return
        buf = cur_head + "\n" + "\n".join(cur_body)
        if f"pid={ffmpeg_pid}" not in buf and f"pid={ffmpeg_pid}," not in buf:
            cur_head, cur_body = "", []
            return
        # Recv-Q is 2nd column on ESTAB head line typically:
        # ESTAB 0 0 local peer users:(...)
        parts = cur_head.split()
        rq = None
        loc = peer = ""
        for i, p in enumerate(parts):
            if p in ("ESTAB", "ESTABLISHED") or p.startswith("ESTAB"):
                if i + 1 < len(parts) and parts[i + 1].isdigit():
                    rq = int(parts[i + 1])
                # local/peer often after Recv-Q Send-Q
                addrs = [x for x in parts if ":" in x and not x.startswith("users:")]
                if len(addrs) >= 2:
                    loc, peer = addrs[0], addrs[1]
                break
        if rq is None:
            m = re.search(r"\bRecv-Q[:\s]+(\d+)", buf)
            if m:
                rq = int(m.group(1))
        br = None
        mbr = re.search(r"bytes_received:(\d+)", buf)
        if mbr:
            br = int(mbr.group(1))
        if rq is None:
            cur_head, cur_body = "", []
            return
        prio = 0
        if peer.endswith(":32400") or ":32400" in peer:
            prio = 2
        elif "32400" in buf:
            prio = 1
        cand = (prio, rq, f"{loc} {peer}".strip(), br)
        if best is None or cand[0] > best[0] or (cand[0] == best[0] and cand[1] > best[1]):
            best = cand
        cur_head, cur_body = "", []

    for ln in blob.splitlines():
        if ln[:1] in (" ", "\t"):
            cur_body.append(ln)
        else:
            if cur_head or cur_body:
                flush()
            cur_head = ln
            cur_body = []
    flush()

    if best is None:
        return _nodata("ss_no_socket_for_pid")
    return _meas(
        best[1],
        four_tuple=best[2],
        bytes_received=best[3] if best[3] is not None else PROV_NODATA,
        note="Recv-Q=rcv_nxt-copied_seq unread_app_data",
    )


def tail_media_line(log_path: Optional[Path]) -> Dict[str, Any]:
    if log_path is None or not log_path.is_file():
        return _nodata("no_media_log")
    try:
        # Read last ~64KB
        with log_path.open("rb") as f:
            f.seek(0, os.SEEK_END)
            size = f.tell()
            f.seek(max(0, size - 65536), os.SEEK_SET)
            chunk = f.read().decode("utf-8", errors="replace")
    except OSError:
        return _nodata("media_log_read_fail")
    last = None
    last_ddr = None
    for ln in chunk.splitlines():
        if "media:" not in ln:
            continue
        if "frames=" in ln and ("vfps=" in ln or "wall_s=" in ln or "presents=" in ln):
            last = ln.strip()
        if "frame_tx ok" in ln and "presents=" in ln:
            last_ddr = ln.strip()
    if last is None and last_ddr is None:
        return _nodata("no_media_frames_line")
    body = (last or last_ddr or "").split("media:", 1)[-1].strip()
    kv = {a: b for a, b in RE_KV.findall(body)}

    def gi(k: str) -> Optional[int]:
        if k not in kv or kv[k] == "NO-DATA":
            return None
        try:
            return int(float(kv[k]))
        except ValueError:
            return None

    def gf(k: str) -> Optional[float]:
        if k not in kv or kv[k] == "NO-DATA":
            return None
        try:
            return float(kv[k])
        except ValueError:
            return None

    out: Dict[str, Any] = {
        "v": {
            "raw": last,
            "raw_ddr": last_ddr,
            "frames": gi("frames"),
            "presents": gi("presents"),
            "drops": gi("drops"),
            "publish_misses": gi("publish_misses"),
            "residual": gi("residual"),
            "wall_s": gf("wall_s"),
            "audio_s": gf("audio_s"),
            "vfps": gf("vfps"),
            "pfps": gf("pfps"),
            "session_epoch": kv.get("session_epoch"),
            "process_epoch": kv.get("process_epoch"),
            "pid": kv.get("pid"),
            "fps": kv.get("fps"),
        },
        "src": PROV_MEAS,
    }
    # Parse DDR presents if missing on stats line
    if out["v"]["presents"] is None and last_ddr:
        dkv = {a: b for a, b in RE_KV.findall(last_ddr)}
        try:
            if "presents" in dkv:
                out["v"]["presents"] = int(float(dkv["presents"]))
                out["v"]["presents_src"] = PROV_RECON + "_ddr_line"
            if "frames" in dkv and out["v"].get("frames_ddr") is None:
                out["v"]["frames_ddr"] = int(float(dkv["frames"]))
        except ValueError:
            pass
    return out


def resolve_media_log(explicit: Optional[str]) -> Optional[Path]:
    if explicit:
        p = Path(explicit)
        return p if p.is_file() else None
    for c in LOG_CANDIDATES:
        p = Path(c)
        if p.is_file():
            return p
    return None


# --- SAMPLE MODE ------------------------------------------------------------------

def sample_once(
    *,
    prev: Optional[Dict[str, Any]],
    log_path: Optional[Path],
    ss_bin: Optional[str],
    iface: Optional[str],
    hz_ticks: int,
) -> Dict[str, Any]:
    t_mono_ms = int(time.monotonic() * 1000)
    try:
        uptime_s = float(Path("/proc/uptime").read_text().split()[0])
    except (OSError, ValueError, IndexError):
        uptime_s = None

    pmap = pids_by_exe_basename(["ffmpeg", "misterplexd"])
    ff_pids = pmap.get("ffmpeg") or []
    d_pids = pmap.get("misterplexd") or []
    ff_pid = ff_pids[0] if ff_pids else None
    d_pid = d_pids[0] if d_pids else None

    row: Dict[str, Any] = {
        "t_mono_ms": t_mono_ms,
        "t_mono_ms_src": PROV_MEAS,
        "uptime_s": uptime_s if uptime_s is not None else PROV_NODATA,
        "uptime_s_src": PROV_MEAS if uptime_s is not None else PROV_NODATA,
        "ffmpeg_pid": ff_pid if ff_pid is not None else PROV_NODATA,
        "daemon_pid": d_pid if d_pid is not None else PROV_NODATA,
        "recv_q": sample_recv_q(ff_pid, ss_bin),
        "ffmpeg_wchan": read_wchan_bundle(ff_pid) if ff_pid else _nodata("no_ffmpeg"),
        "daemon_wchan": read_wchan_bundle(d_pid) if d_pid else _nodata("no_daemon"),
        "media": tail_media_line(log_path),
        "rx_bytes": read_rx_bytes(iface),
    }

    # CPU snapshot (absolute ticks); deltas filled vs prev
    sys_now = read_system_idle_total()
    ff_ticks = read_proc_ticks(ff_pid) if ff_pid else None
    d_ticks = read_proc_ticks(d_pid) if d_pid else None
    row["cpu_snap"] = {
        "sys_total": sys_now[0] if sys_now else None,
        "sys_idle": sys_now[1] if sys_now else None,
        "ncpu": sys_now[2] if sys_now else None,
        "ffmpeg_ticks": ff_ticks,
        "daemon_ticks": d_ticks,
        "src": PROV_MEAS if sys_now else PROV_NODATA,
    }

    # Interval fields vs previous sample
    interval: Dict[str, Any] = {"dt_mono_s": PROV_NODATA}
    if prev is not None:
        dt_ms = t_mono_ms - int(prev["t_mono_ms"])
        if dt_ms > 0:
            dt = dt_ms / 1000.0
            interval["dt_mono_s"] = dt
            interval["dt_mono_s_src"] = PROV_MEAS
            # media deltas
            m0 = (prev.get("media") or {}).get("v") or {}
            m1 = (row["media"].get("v") or {}) if isinstance(row["media"], dict) else {}
            if isinstance(m0, dict) and isinstance(m1, dict):
                for key, out_k in (
                    ("frames", "d_frames"),
                    ("presents", "d_presents"),
                    ("drops", "d_drops"),
                    ("wall_s", "d_wall_s"),
                    ("audio_s", "d_audio_s"),
                ):
                    a, b = m0.get(key), m1.get(key)
                    if isinstance(a, (int, float)) and isinstance(b, (int, float)):
                        dlt = b - a
                        if dlt < 0:
                            interval[out_k] = None
                            interval[f"{out_k}_src"] = PROV_NODATA
                            interval[f"{out_k}_reason"] = "negative_delta_counter_reset"
                        else:
                            interval[out_k] = dlt
                            interval[f"{out_k}_src"] = PROV_MEAS
                    else:
                        interval[out_k] = None
                        interval[f"{out_k}_src"] = PROV_NODATA
                # interval rates
                dw = interval.get("d_wall_s")
                df = interval.get("d_frames")
                da = interval.get("d_audio_s")
                if isinstance(dw, (int, float)) and dw > 0 and isinstance(df, (int, float)):
                    interval["interval_vfps"] = df / dw
                    interval["interval_vfps_src"] = PROV_MEAS
                else:
                    interval["interval_vfps"] = None
                    interval["interval_vfps_src"] = PROV_NODATA
                if isinstance(dw, (int, float)) and dw > 0 and isinstance(da, (int, float)):
                    interval["interval_supply"] = da / dw
                    interval["interval_supply_src"] = PROV_MEAS
                else:
                    interval["interval_supply"] = None
                    interval["interval_supply_src"] = PROV_NODATA
                # residual if closable
                fr, pr, dr = m1.get("frames"), m1.get("presents"), m1.get("drops")
                if all(isinstance(x, int) for x in (fr, pr, dr)):
                    interval["residual"] = int(fr) - int(pr) - int(dr)
                    interval["residual_src"] = PROV_MEAS
                    interval["residual_eq"] = "frames-presents-drops"
                elif (
                    isinstance(m1.get("frames_ddr"), int)
                    and isinstance(pr, int)
                    and isinstance(dr, int)
                ):
                    interval["residual"] = int(m1["frames_ddr"]) - int(pr) - int(dr)
                    interval["residual_src"] = PROV_RECON
                else:
                    interval["residual"] = None
                    interval["residual_src"] = PROV_NODATA

            # rx_bytes delta — negative is NO-DATA never a rate
            r0 = prev.get("rx_bytes") or {}
            r1 = row.get("rx_bytes") or {}
            if r0.get("src") == PROV_MEAS and r1.get("src") == PROV_MEAS:
                try:
                    dlt = int(r1["v"]) - int(r0["v"])
                except (TypeError, ValueError):
                    dlt = None
                if dlt is None:
                    interval["d_rx_bytes"] = None
                    interval["d_rx_bytes_src"] = PROV_NODATA
                elif dlt < 0:
                    interval["d_rx_bytes"] = None
                    interval["d_rx_bytes_src"] = PROV_NODATA
                    interval["d_rx_bytes_reason"] = "negative_delta"
                    interval["rx_bps"] = None
                    interval["rx_bps_src"] = PROV_NODATA
                else:
                    interval["d_rx_bytes"] = dlt
                    interval["d_rx_bytes_src"] = PROV_MEAS
                    interval["rx_bps"] = dlt / dt
                    interval["rx_bps_src"] = PROV_MEAS
            else:
                interval["d_rx_bytes"] = None
                interval["d_rx_bytes_src"] = PROV_NODATA
                interval["rx_bps"] = None
                interval["rx_bps_src"] = PROV_NODATA

            # CPU %
            c0 = prev.get("cpu_snap") or {}
            c1 = row.get("cpu_snap") or {}
            if (
                c0.get("sys_total") is not None
                and c1.get("sys_total") is not None
                and c1.get("ncpu")
            ):
                dtot = c1["sys_total"] - c0["sys_total"]
                didle = c1["sys_idle"] - c0["sys_idle"]
                if dtot > 0 and didle >= 0 and didle <= dtot:
                    busy = 100.0 * c1["ncpu"] * (1.0 - didle / dtot)
                    interval["system_busy"] = busy
                    interval["system_busy_cap"] = 100.0 * c1["ncpu"]
                    interval["system_busy_src"] = PROV_MEAS
                else:
                    interval["system_busy"] = None
                    interval["system_busy_src"] = PROV_NODATA
                    interval["system_busy_reason"] = "bad_or_negative_idle_delta"
            else:
                interval["system_busy"] = None
                interval["system_busy_src"] = PROV_NODATA

            def proc_pct(t0: Any, t1: Any) -> Tuple[Optional[float], str]:
                if t0 is None or t1 is None:
                    return None, PROV_NODATA
                dtk = t1 - t0
                if dtk < 0:
                    return None, PROV_NODATA
                return 100.0 * dtk / (hz_ticks * dt), PROV_MEAS

            fp, fs = proc_pct(c0.get("ffmpeg_ticks"), c1.get("ffmpeg_ticks"))
            interval["ffmpeg_pct_onecpu"] = fp
            interval["ffmpeg_pct_onecpu_src"] = fs
            dp, ds = proc_pct(c0.get("daemon_ticks"), c1.get("daemon_ticks"))
            interval["daemon_pct_onecpu"] = dp
            interval["daemon_pct_onecpu_src"] = ds
        else:
            interval["dt_mono_s_src"] = PROV_NODATA
            interval["dt_mono_s_reason"] = "non_positive_dt"
    row["interval"] = interval
    return row


def cmd_sample(args: argparse.Namespace) -> int:
    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    log_path = resolve_media_log(args.media_log)
    ss_bin = find_ss_bin()
    hz_ticks = clk_tck()
    interval_s = float(args.interval)
    duration_s = float(args.duration) if args.duration else None
    t0 = time.monotonic()
    prev = None
    n = 0
    meta = {
        "tool": "locus480_local_vs_supply",
        "mode": "sample",
        "interval_s": interval_s,
        "interval_s_src": PROV_CALLER if args.interval != 1.0 else PROV_DEFAULT,
        "media_log": str(log_path) if log_path else PROV_NODATA,
        "ss_bin": ss_bin or PROV_NODATA,
        "hz": hz_ticks,
        "hz_src": PROV_MEAS,
        "note": "ON_DEVICE_local_file_only — do not SSH-poll mid-run",
        "t_start_uptime": None,
    }
    try:
        meta["t_start_uptime"] = float(Path("/proc/uptime").read_text().split()[0])
        meta["t_start_uptime_src"] = PROV_MEAS
    except (OSError, ValueError, IndexError):
        meta["t_start_uptime_src"] = PROV_NODATA

    with out_path.open("a", encoding="utf-8") as f:
        f.write(json.dumps({"record": "meta", **meta}, sort_keys=True) + "\n")
        f.flush()
        while True:
            if duration_s is not None and (time.monotonic() - t0) >= duration_s:
                break
            row = sample_once(
                prev=prev,
                log_path=log_path,
                ss_bin=ss_bin,
                iface=args.iface,
                hz_ticks=hz_ticks,
            )
            row["record"] = "sample"
            f.write(json.dumps(row, sort_keys=True) + "\n")
            f.flush()
            prev = row
            n += 1
            if args.max_samples and n >= args.max_samples:
                break
            # sleep remainder to hit interval on mono clock
            target = t0 + n * interval_s
            delay = target - time.monotonic()
            if delay > 0:
                time.sleep(delay)
            if args.once:
                break
    print(f"SAMPLE_DONE path={out_path} n={n} src={PROV_MEAS}")
    if n == 0:
        print(f"VERDICT=NO-DATA rc={RC_NO_DATA}")
        return RC_NO_DATA
    print(f"VERDICT=SAMPLE_OK rc={RC_OK} note=fetch_once_then_run_verdict")
    return RC_OK


# --- VERDICT MODE -----------------------------------------------------------------

@dataclass
class Agg:
    n_rows: int = 0
    n_degraded: int = 0
    n_healthy: int = 0
    n_recv_q_meas: int = 0
    n_recv_q_gt0: int = 0
    n_ff_wchan_meas: int = 0
    n_ff_pipe_write: int = 0  # binary any-thread (legacy; often SATURATED)
    n_ff_sockish: int = 0
    n_daemon_wchan_meas: int = 0
    n_daemon_pipe_read: int = 0
    n_supply_meas: int = 0
    n_vfps_meas: int = 0
    n_vfps_near_zero: int = 0
    supply_vals: List[float] = field(default_factory=list)
    vfps_vals: List[float] = field(default_factory=list)
    # split pools
    recv_q_healthy: List[int] = field(default_factory=list)
    recv_q_degraded: List[int] = field(default_factory=list)
    recv_q_all: List[int] = field(default_factory=list)
    d_recv_q_healthy: List[float] = field(default_factory=list)
    d_recv_q_degraded: List[float] = field(default_factory=list)
    pw_thread_frac_healthy: List[float] = field(default_factory=list)
    pw_thread_frac_degraded: List[float] = field(default_factory=list)
    pw_thread_frac_all: List[float] = field(default_factory=list)
    binary_rq_gt0_healthy: List[int] = field(default_factory=list)  # 0/1
    binary_pw_any_healthy: List[int] = field(default_factory=list)
    binary_rq_gt0_degraded: List[int] = field(default_factory=list)
    binary_pw_any_degraded: List[int] = field(default_factory=list)
    residual_last: Optional[int] = None
    residual_src: str = PROV_NODATA
    frames_last: Optional[int] = None
    presents_last: Optional[int] = None
    drops_last: Optional[int] = None
    session_epochs: set = field(default_factory=set)
    process_epochs: set = field(default_factory=set)
    notes: List[str] = field(default_factory=list)


def load_jsonl(path: Path) -> List[Dict[str, Any]]:
    rows = []
    text = path.read_text(encoding="utf-8", errors="replace")
    for ln in text.splitlines():
        ln = ln.strip()
        if not ln:
            continue
        try:
            rows.append(json.loads(ln))
        except json.JSONDecodeError:
            continue
    return rows


def frac(num: int, den: int) -> Optional[float]:
    if den <= 0:
        return None
    return num / den


def _median(xs: List[float]) -> Optional[float]:
    if not xs:
        return None
    return float(statistics.median(xs))


def _mean(xs: List[float]) -> Optional[float]:
    if not xs:
        return None
    return float(sum(xs) / len(xs))


def _p90(xs: List[float]) -> Optional[float]:
    if not xs:
        return None
    s = sorted(xs)
    idx = min(len(s) - 1, max(0, int(round(0.9 * (len(s) - 1)))))
    return float(s[idx])


def analyze_rows(
    rows: List[Dict[str, Any]],
    *,
    degrade_supply: float,
    near_zero_vfps: float,
    recv_q_local_min: int,
) -> Agg:
    samples = [r for r in rows if r.get("record") == "sample"]
    a = Agg(n_rows=len(samples))
    degraded_idx: List[int] = []
    healthy_idx: List[int] = []
    prev_rq: Optional[int] = None

    for i, r in enumerate(samples):
        iv = r.get("interval") or {}
        media = (r.get("media") or {}).get("v") or {}
        if isinstance(media, dict):
            if media.get("session_epoch"):
                a.session_epochs.add(str(media["session_epoch"]))
            if media.get("process_epoch"):
                a.process_epochs.add(str(media["process_epoch"]))
            if isinstance(media.get("frames"), int):
                a.frames_last = media["frames"]
            if isinstance(media.get("presents"), int):
                a.presents_last = media["presents"]
            if isinstance(media.get("drops"), int):
                a.drops_last = media["drops"]
            if isinstance(iv.get("residual"), int):
                a.residual_last = iv["residual"]
                a.residual_src = str(iv.get("residual_src", PROV_RECON))
            elif (
                isinstance(media.get("frames"), int)
                and isinstance(media.get("presents"), int)
                and isinstance(media.get("drops"), int)
            ):
                a.residual_last = (
                    int(media["frames"]) - int(media["presents"]) - int(media["drops"])
                )
                a.residual_src = PROV_MEAS

        sup = iv.get("interval_supply")
        vfps = iv.get("interval_vfps")
        is_deg = False
        has_rate = False
        if isinstance(sup, (int, float)) and iv.get("interval_supply_src") == PROV_MEAS:
            a.n_supply_meas += 1
            a.supply_vals.append(float(sup))
            has_rate = True
            if float(sup) < degrade_supply:
                is_deg = True
        if isinstance(vfps, (int, float)) and iv.get("interval_vfps_src") == PROV_MEAS:
            a.n_vfps_meas += 1
            a.vfps_vals.append(float(vfps))
            has_rate = True
            if float(vfps) < near_zero_vfps:
                a.n_vfps_near_zero += 1
                is_deg = True
        if is_deg:
            degraded_idx.append(i)
        elif has_rate:
            healthy_idx.append(i)

        # channels every sample (split later)
        rq = r.get("recv_q") or {}
        rq_v = None
        if rq.get("src") == PROV_MEAS and isinstance(rq.get("v"), int):
            a.n_recv_q_meas += 1
            rq_v = int(rq["v"])
            a.recv_q_all.append(rq_v)
            if rq_v >= recv_q_local_min:
                a.n_recv_q_gt0 += 1
            if prev_rq is not None:
                d_rq = float(rq_v - prev_rq)
                # store on this sample's bucket below
                r.setdefault("_d_recv_q", d_rq)
            prev_rq = rq_v
            r["_rq"] = rq_v

        fw = r.get("ffmpeg_wchan") or {}
        if fw.get("src") == PROV_MEAS and isinstance(fw.get("v"), dict):
            a.n_ff_wchan_meas += 1
            v = fw["v"]
            pw_n = int(v.get("pipe_write_n") or 0)
            n_th = int(v.get("n_threads") or 0)
            if pw_n > 0:
                a.n_ff_pipe_write += 1
            if int(v.get("socket_readish_n") or 0) > 0:
                a.n_ff_sockish += 1
            thr = (pw_n / n_th) if n_th > 0 else None
            if thr is not None:
                a.pw_thread_frac_all.append(thr)
                r["_pw_thr"] = thr
            r["_pw_any"] = 1 if pw_n > 0 else 0
        dw = r.get("daemon_wchan") or {}
        if dw.get("src") == PROV_MEAS and isinstance(dw.get("v"), dict):
            a.n_daemon_wchan_meas += 1
            if int(dw["v"].get("pipe_read_n") or 0) > 0:
                a.n_daemon_pipe_read += 1

    a.n_degraded = len(degraded_idx)
    a.n_healthy = len(healthy_idx)

    def absorb(idxs: List[int], kind: str) -> None:
        for i in idxs:
            r = samples[i]
            if "_rq" in r:
                rq_v = int(r["_rq"])
                if kind == "h":
                    a.recv_q_healthy.append(rq_v)
                    a.binary_rq_gt0_healthy.append(1 if rq_v >= recv_q_local_min else 0)
                else:
                    a.recv_q_degraded.append(rq_v)
                    a.binary_rq_gt0_degraded.append(1 if rq_v >= recv_q_local_min else 0)
            if "_d_recv_q" in r:
                if kind == "h":
                    a.d_recv_q_healthy.append(float(r["_d_recv_q"]))
                else:
                    a.d_recv_q_degraded.append(float(r["_d_recv_q"]))
            if "_pw_thr" in r:
                if kind == "h":
                    a.pw_thread_frac_healthy.append(float(r["_pw_thr"]))
                else:
                    a.pw_thread_frac_degraded.append(float(r["_pw_thr"]))
            if "_pw_any" in r:
                if kind == "h":
                    a.binary_pw_any_healthy.append(int(r["_pw_any"]))
                else:
                    a.binary_pw_any_degraded.append(int(r["_pw_any"]))

    absorb(healthy_idx, "h")
    absorb(degraded_idx, "d")
    if a.n_degraded == 0:
        a.notes.append("no_degraded_seconds")
    if a.n_healthy == 0:
        a.notes.append("no_healthy_baseline_seconds")
    return a


def classify_locus(
    a: Agg,
    *,
    sustained_frac: float,
    min_degraded_s: int,
    min_coverage: float,
    degrade_supply: float,
    sat_ceiling: float,
    sat_floor: float,
    rq_ratio_local: float,
    rq_ratio_supply: float,
    pw_frac_delta: float,
    d_rq_local: float,
    min_healthy_s: int,
) -> Tuple[str, int, str, Dict[str, Any]]:
    """Return verdict, rc, reason, metrics dict."""
    metrics: Dict[str, Any] = {}
    notes: List[str] = list(a.notes)

    if len(a.session_epochs) > 1 or len(a.process_epochs) > 1:
        return (
            "SESSION_INVALID",
            RC_SESSION_INVALID,
            f"epoch_changed sessions={sorted(a.session_epochs)} "
            f"process={sorted(a.process_epochs)}",
            metrics,
        )

    if a.n_rows < 2:
        return "NO-DATA", RC_NO_DATA, "need_ge_2_samples", metrics

    fnz = frac(a.n_vfps_near_zero, a.n_vfps_meas)
    metrics["frac_near_zero"] = fnz if fnz is not None else PROV_NODATA
    metrics["frac_near_zero_src"] = PROV_MEAS if fnz is not None else PROV_NODATA
    metrics["frac_near_zero_n"] = a.n_vfps_near_zero
    metrics["frac_near_zero_den"] = a.n_vfps_meas
    metrics["n_degraded_s"] = a.n_degraded
    metrics["n_healthy_s"] = a.n_healthy
    metrics["n_rows"] = a.n_rows

    # ledger — never round residual
    metrics["frames"] = a.frames_last if a.frames_last is not None else PROV_NODATA
    metrics["presents"] = a.presents_last if a.presents_last is not None else PROV_NODATA
    metrics["drops"] = a.drops_last if a.drops_last is not None else PROV_NODATA
    metrics["residual"] = a.residual_last if a.residual_last is not None else PROV_NODATA
    metrics["residual_src"] = a.residual_src
    if (
        isinstance(a.frames_last, int)
        and isinstance(a.presents_last, int)
        and isinstance(a.drops_last, int)
    ):
        rc_calc = a.frames_last - a.presents_last - a.drops_last
        metrics["ledger"] = "closable"
        metrics["residual_calc"] = rc_calc
        if a.residual_last is None:
            metrics["residual"] = rc_calc
            metrics["residual_src"] = PROV_MEAS
        # exact residual; near-closed is a label only
        if abs(int(metrics["residual"])) <= 1:
            metrics["residual_class"] = "near_closed_abs_le_1"
            notes.append(
                f"residual={metrics['residual']} exact — NOT rounded to 0; "
                f"|r|<=1 on frames={a.frames_last} is near-closed but still reported"
            )
        else:
            metrics["residual_class"] = "open"
    else:
        metrics["ledger"] = "unclosable"
        metrics["residual_calc"] = PROV_NODATA
        metrics["residual_class"] = PROV_NODATA

    mean_supply = _mean(a.supply_vals)
    metrics["mean_interval_supply"] = mean_supply if mean_supply is not None else PROV_NODATA
    metrics["mean_interval_supply_src"] = PROV_MEAS if mean_supply is not None else PROV_NODATA

    # --- coverage (whole run) ---
    cov_rq = frac(a.n_recv_q_meas, a.n_rows)
    cov_ff = frac(a.n_ff_wchan_meas, a.n_rows)
    metrics["coverage_recv_q"] = cov_rq if cov_rq is not None else PROV_NODATA
    metrics["coverage_ffmpeg_wchan"] = cov_ff if cov_ff is not None else PROV_NODATA

    if cov_rq is None or cov_ff is None or cov_rq < min_coverage or cov_ff < min_coverage:
        return (
            "INSUFFICIENT_EVIDENCE",
            RC_INSUFFICIENT,
            f"coverage_below_min cov_rq={cov_rq} cov_ff={cov_ff} min={min_coverage}",
            metrics,
        )

    # --- legacy binary (always printed; saturation-checked on HEALTHY portion) ---
    bin_rq_h = frac(sum(a.binary_rq_gt0_healthy), len(a.binary_rq_gt0_healthy))
    bin_pw_h = frac(sum(a.binary_pw_any_healthy), len(a.binary_pw_any_healthy))
    bin_rq_d = frac(sum(a.binary_rq_gt0_degraded), len(a.binary_rq_gt0_degraded))
    bin_pw_d = frac(sum(a.binary_pw_any_degraded), len(a.binary_pw_any_degraded))
    bin_rq_all = frac(a.n_recv_q_gt0, a.n_recv_q_meas)
    bin_pw_all = frac(a.n_ff_pipe_write, a.n_ff_wchan_meas)
    metrics["recv_q_gt0_frac_all"] = bin_rq_all if bin_rq_all is not None else PROV_NODATA
    metrics["recv_q_gt0_frac_healthy"] = bin_rq_h if bin_rq_h is not None else PROV_NODATA
    metrics["recv_q_gt0_frac_degraded"] = bin_rq_d if bin_rq_d is not None else PROV_NODATA
    metrics["ffmpeg_pipe_write_any_frac_all"] = (
        bin_pw_all if bin_pw_all is not None else PROV_NODATA
    )
    metrics["ffmpeg_pipe_write_any_frac_healthy"] = (
        bin_pw_h if bin_pw_h is not None else PROV_NODATA
    )
    metrics["ffmpeg_pipe_write_any_frac_degraded"] = (
        bin_pw_d if bin_pw_d is not None else PROV_NODATA
    )

    sat_binary_rq = bin_rq_h is not None and bin_rq_h >= sat_ceiling
    sat_binary_pw = bin_pw_h is not None and bin_pw_h >= sat_ceiling
    metrics["sat_binary_recv_q_gt0"] = (
        "SATURATED_HIGH" if sat_binary_rq else ("OK" if bin_rq_h is not None else PROV_NODATA)
    )
    metrics["sat_binary_pipe_write_any"] = (
        "SATURATED_HIGH" if sat_binary_pw else ("OK" if bin_pw_h is not None else PROV_NODATA)
    )
    if sat_binary_rq or sat_binary_pw:
        notes.append(
            "MISS_v1: binary recv_q>0 / any-pipe_write saturated on healthy portion "
            f"(rq_h={bin_rq_h} pw_h={bin_pw_h}) — intentional pacing back-pressure; "
            "DISABLED for locus (parent 2026-08-02 hardware)"
        )

    # --- magnitude / dynamics (v2) ---
    med_h = _median([float(x) for x in a.recv_q_healthy])
    med_d = _median([float(x) for x in a.recv_q_degraded])
    p90_h = _p90([float(x) for x in a.recv_q_healthy])
    p90_d = _p90([float(x) for x in a.recv_q_degraded])
    mean_drq_h = _mean(a.d_recv_q_healthy)
    mean_drq_d = _mean(a.d_recv_q_degraded)
    metrics["recv_q_median_healthy"] = med_h if med_h is not None else PROV_NODATA
    metrics["recv_q_median_degraded"] = med_d if med_d is not None else PROV_NODATA
    metrics["recv_q_p90_healthy"] = p90_h if p90_h is not None else PROV_NODATA
    metrics["recv_q_p90_degraded"] = p90_d if p90_d is not None else PROV_NODATA
    metrics["recv_q_max_all"] = max(a.recv_q_all) if a.recv_q_all else PROV_NODATA
    metrics["d_recv_q_mean_healthy"] = mean_drq_h if mean_drq_h is not None else PROV_NODATA
    metrics["d_recv_q_mean_degraded"] = mean_drq_d if mean_drq_d is not None else PROV_NODATA

    rq_ratio = None
    if med_h is not None and med_d is not None and med_h > 0:
        rq_ratio = med_d / med_h
    elif med_h == 0 and med_d is not None:
        rq_ratio = float("inf") if med_d > 0 else 1.0
    metrics["recv_q_median_ratio_deg_over_h"] = (
        rq_ratio if rq_ratio is not None else PROV_NODATA
    )

    # magnitude channel saturation: uninformative if both sides missing or ratio~1
    # with no degraded window to compare
    mag_usable = (
        a.n_healthy >= min_healthy_s
        and a.n_degraded >= min_degraded_s
        and med_h is not None
        and med_d is not None
    )
    # If healthy median is 0 and degraded also ~0, magnitude cannot show LOCAL growth
    # but CAN show SUPPLY (already empty). Still usable for SUPPLY collapse check.
    metrics["channel_recv_q_magnitude"] = "USABLE" if mag_usable else "NO-DATA_BASELINE"

    thr_h = _mean(a.pw_thread_frac_healthy)
    thr_d = _mean(a.pw_thread_frac_degraded)
    metrics["pipe_write_thread_frac_mean_healthy"] = (
        thr_h if thr_h is not None else PROV_NODATA
    )
    metrics["pipe_write_thread_frac_mean_degraded"] = (
        thr_d if thr_d is not None else PROV_NODATA
    )
    thr_delta = None
    if thr_h is not None and thr_d is not None:
        thr_delta = thr_d - thr_h
    metrics["pipe_write_thread_frac_delta_deg_minus_h"] = (
        thr_delta if thr_delta is not None else PROV_NODATA
    )

    # thread-frac saturation: if healthy mean already >= ceiling, cannot rise
    sat_thr = thr_h is not None and thr_h >= sat_ceiling
    sat_thr_floor = thr_h is not None and thr_h <= sat_floor
    metrics["sat_pipe_write_thread_frac"] = (
        "SATURATED_HIGH"
        if sat_thr
        else (
            "SATURATED_LOW"
            if sat_thr_floor
            else ("OK" if thr_h is not None else PROV_NODATA)
        )
    )
    thr_usable = (
        a.n_healthy >= min_healthy_s
        and a.n_degraded >= min_degraded_s
        and thr_h is not None
        and thr_d is not None
        and not sat_thr
    )
    metrics["channel_pipe_write_thread_frac"] = (
        "USABLE" if thr_usable else ("SATURATED" if sat_thr else "NO-DATA_BASELINE")
    )

    # FINDING: healthy non-empty socket
    if bin_rq_h is not None and bin_rq_h >= sat_ceiling and med_h is not None and med_h > 0:
        metrics["finding_socket_never_empty_healthy"] = 1
        notes.append(
            f"FINDING: healthy recv_q_gt0_frac={bin_rq_h} median={med_h} — "
            f"socket never empty under intentional pacing; steady-state "
            f"link/sender-short refuted for this run"
        )
    else:
        metrics["finding_socket_never_empty_healthy"] = 0

    metrics["notes_internal"] = notes

    # --- HEALTHY run (too few degraded) ---
    if a.n_degraded < min_degraded_s and (
        mean_supply is None or mean_supply >= degrade_supply
    ):
        # Publish saturation state; do not claim LOCAL from binary ceilings
        if sat_binary_rq and sat_binary_pw:
            return (
                "INSUFFICIENT_EVIDENCE",
                RC_INSUFFICIENT,
                "healthy_run_binary_discriminators_SATURATED "
                f"n_degraded={a.n_degraded}<{min_degraded_s} "
                f"recv_q_gt0_h={bin_rq_h} pipe_write_any_h={bin_pw_h} "
                f"recv_q_median_h={med_h} — extend soak for degraded window; "
                f"v1 LOCAL indicators disabled",
                metrics,
            )
        if fnz is not None and fnz < 0.10:
            return (
                "HEALTHY",
                RC_OK,
                f"n_degraded={a.n_degraded}<{min_degraded_s} frac_near_zero={fnz} "
                f"mean_supply={mean_supply}",
                metrics,
            )
        return (
            "INSUFFICIENT_EVIDENCE",
            RC_INSUFFICIENT,
            f"too_few_degraded_seconds n={a.n_degraded} need>={min_degraded_s}",
            metrics,
        )

    # --- need healthy baseline for within-run magnitude ---
    if a.n_healthy < min_healthy_s:
        return (
            "INSUFFICIENT_EVIDENCE",
            RC_INSUFFICIENT,
            f"no_within_run_healthy_baseline n_healthy={a.n_healthy} "
            f"need>={min_healthy_s} (cannot saturation-guard or ratio-test)",
            metrics,
        )

    # Discriminative signals (unsaturated only)
    local_mag = False
    supply_mag = False
    local_thr = False
    supply_thr = False
    reasons = []

    if mag_usable and rq_ratio is not None:
        if rq_ratio >= rq_ratio_local:
            local_mag = True
            reasons.append(
                f"recv_q_median_ratio={rq_ratio:.3f}>={rq_ratio_local} "
                f"(deg={med_d} h={med_h})"
            )
        if rq_ratio <= rq_ratio_supply:
            supply_mag = True
            reasons.append(
                f"recv_q_median_ratio={rq_ratio:.3f}<={rq_ratio_supply} "
                f"(collapse deg={med_d} h={med_h})"
            )
        # dynamics: growing backlog during degrade
        if mean_drq_d is not None and mean_drq_d > d_rq_local and (
            mean_drq_h is None or mean_drq_d > mean_drq_h + 1e-6
        ):
            local_mag = True
            reasons.append(
                f"d_recv_q_mean_deg={mean_drq_d:.1f}>h={mean_drq_h}"
            )
        if mean_drq_d is not None and mean_drq_d < -1.0 and (
            med_d is not None and med_h is not None and med_d < med_h * rq_ratio_supply
        ):
            supply_mag = True
            reasons.append(f"d_recv_q_mean_deg={mean_drq_d:.1f} draining")
    elif not mag_usable:
        reasons.append("recv_q_magnitude_channel_not_usable")

    if thr_usable and thr_delta is not None:
        if thr_delta >= pw_frac_delta:
            local_thr = True
            reasons.append(
                f"pipe_write_thread_frac_delta={thr_delta:.3f}>={pw_frac_delta}"
            )
        if thr_delta <= -pw_frac_delta:
            supply_thr = True
            reasons.append(
                f"pipe_write_thread_frac_delta={thr_delta:.3f} falling"
            )
    elif sat_thr:
        reasons.append("pipe_write_thread_frac_SATURATED_HIGH_on_healthy")

    # Hard refuse: if BOTH magnitude and thread channels unusable → 78
    if not mag_usable and not thr_usable:
        return (
            "INSUFFICIENT_EVIDENCE",
            RC_INSUFFICIENT,
            "all_locus_channels_SATURATED_or_NO-DATA " + "; ".join(reasons),
            metrics,
        )

    # LOCAL needs magnitude growth (primary); thread frac optional boost
    # Do NOT use saturated binary channels.
    if local_mag and (local_thr or not thr_usable or sat_thr):
        # if thr usable and moves opposite, conflict
        if thr_usable and supply_thr and not local_thr:
            return (
                "LOCUS_UNKNOWN",
                RC_UNKNOWN,
                "conflict local_mag vs supply_thr " + "; ".join(reasons),
                metrics,
            )
        return (
            "LOCAL_ESTABLISHED",
            RC_LOCAL,
            "v2_magnitude " + "; ".join(reasons),
            metrics,
        )

    if supply_mag and not local_mag:
        if thr_usable and local_thr:
            return (
                "LOCUS_UNKNOWN",
                RC_UNKNOWN,
                "conflict supply_mag vs local_thr " + "; ".join(reasons),
                metrics,
            )
        return (
            "SUPPLY_ESTABLISHED",
            RC_SUPPLY,
            "v2_magnitude " + "; ".join(reasons),
            metrics,
        )

    if local_thr and not supply_mag and thr_usable and not local_mag:
        # thread-only LOCAL is weaker; require magnitude agree or ratio unavailable
        if mag_usable:
            return (
                "LOCUS_UNKNOWN",
                RC_UNKNOWN,
                "thread_frac_local_without_recv_q_magnitude " + "; ".join(reasons),
                metrics,
            )
        return (
            "LOCAL_ESTABLISHED",
            RC_LOCAL,
            "v2_thread_frac_only " + "; ".join(reasons),
            metrics,
        )

    if a.n_degraded >= min_degraded_s:
        # Explicit: binary would have said LOCAL — refuse
        if sat_binary_rq and sat_binary_pw:
            notes.append(
                "refused_v1_LOCAL_despite_binary_ceiling_on_degraded_too"
            )
        return (
            "LOCUS_UNKNOWN",
            RC_UNKNOWN,
            "degraded_but_v2_locus_unproven " + "; ".join(reasons),
            metrics,
        )

    return (
        "INSUFFICIENT_EVIDENCE",
        RC_INSUFFICIENT,
        "no_clear_healthy_or_locus " + "; ".join(reasons),
        metrics,
    )



def print_verdict(
    verdict: str,
    rc: int,
    reason: str,
    metrics: Dict[str, Any],
    notes: List[str],
) -> int:
    print("=== locus480_local_vs_supply verdict ===")
    print(
        "MISS_v1_PUBLISHED: binary recv_q>0 + any-pipe_write SATURATED on healthy "
        "paced playback (parent hardware recv_q_gt0_frac=1.0 pipe_write_frac=1.0) "
        "— DISABLED for locus"
    )
    print(
        "PRE_REGISTER_v2: LOCAL=recv_q median_deg/median_h high OR d_recv_q>0; "
        "SUPPLY=recv_q median collapses; pipe_write THREAD frac delta; "
        "within-run healthy baseline required"
    )
    print(
        "VOID_ENDPOINT supply_ratio_alone; VOID_ENDPOINT binary_recv_q_gt0; "
        "VOID_ENDPOINT binary_any_pipe_write under intentional pacing"
    )
    for k in (
        "n_rows",
        "n_degraded_s",
        "n_healthy_s",
        "frac_near_zero",
        "frac_near_zero_src",
        "frac_near_zero_n",
        "frac_near_zero_den",
        "mean_interval_supply",
        "mean_interval_supply_src",
        "recv_q_gt0_frac_all",
        "recv_q_gt0_frac_healthy",
        "recv_q_gt0_frac_degraded",
        "sat_binary_recv_q_gt0",
        "ffmpeg_pipe_write_any_frac_all",
        "ffmpeg_pipe_write_any_frac_healthy",
        "sat_binary_pipe_write_any",
        "recv_q_median_healthy",
        "recv_q_median_degraded",
        "recv_q_median_ratio_deg_over_h",
        "recv_q_p90_healthy",
        "recv_q_p90_degraded",
        "recv_q_max_all",
        "d_recv_q_mean_healthy",
        "d_recv_q_mean_degraded",
        "channel_recv_q_magnitude",
        "pipe_write_thread_frac_mean_healthy",
        "pipe_write_thread_frac_mean_degraded",
        "pipe_write_thread_frac_delta_deg_minus_h",
        "sat_pipe_write_thread_frac",
        "channel_pipe_write_thread_frac",
        "finding_socket_never_empty_healthy",
        "coverage_recv_q",
        "coverage_ffmpeg_wchan",
        "frames",
        "presents",
        "drops",
        "residual",
        "residual_src",
        "residual_calc",
        "residual_class",
        "ledger",
    ):
        if k in metrics:
            print(f"{k}={metrics[k]}")
    extra_notes = list(notes)
    if isinstance(metrics.get("notes_internal"), list):
        extra_notes = list(metrics["notes_internal"]) + extra_notes
    for n in extra_notes:
        print(f"NOTE: {n}")
    print(f"reason={reason}")
    print(f"VERDICT={verdict} rc={rc}")
    if rc == RC_INSUFFICIENT:
        print("NOTE: rc=78 INSUFFICIENT_EVIDENCE aligns w-avsync — never a pass")
    if rc == RC_SESSION_INVALID:
        print("NOTE: rc=79 SESSION_INVALID aligns w-avsync/w-instr ledger")
    if rc == RC_NO_DATA:
        print("NOTE: rc=77 NO-DATA is never a pass")
    if rc == RC_LOCAL:
        print("NOTE: LOCAL=consumer too slow vs same-run healthy baseline (magnitude)")
    if rc == RC_SUPPLY:
        print("NOTE: SUPPLY=backlog collapse vs same-run healthy baseline")
    return rc



def cmd_verdict(args: argparse.Namespace) -> int:
    path = Path(args.inp)
    if not path.is_file():
        print(f"ERROR: missing {path}", file=sys.stderr)
        return RC_USAGE
    rows = load_jsonl(path)
    # Optional merge of plain media log for ledger via daemon_media_ledger semantics
    if args.media_log:
        try:
            from daemon_media_ledger import classify as led_classify  # type: ignore
            from daemon_media_ledger import parse_events

            text = Path(args.media_log).read_text(encoding="utf-8", errors="replace")
            led = led_classify(parse_events(text))
            print(
                f"LEDGER_SIDE verdict={led.verdict} rc={led.rc} "
                f"residual={led.last.residual if led.last else 'NO-DATA'} "
                f"src={led.last.residual_src if led.last else PROV_NODATA}"
            )
            if led.rc == RC_SESSION_INVALID:
                return print_verdict(
                    "SESSION_INVALID",
                    RC_SESSION_INVALID,
                    led.reason,
                    {},
                    led.notes,
                )
        except Exception as e:  # noqa: BLE001 — optional side channel
            print(f"LEDGER_SIDE NO-DATA reason={e!r} src={PROV_NODATA}")

    a = analyze_rows(
        rows,
        degrade_supply=float(args.degrade_supply),
        near_zero_vfps=float(args.near_zero_vfps),
        recv_q_local_min=int(args.recv_q_local_min),
    )
    verdict, rc, reason, metrics = classify_locus(
        a,
        sustained_frac=float(args.sustained_frac),
        min_degraded_s=int(args.min_degraded_s),
        min_coverage=float(args.min_coverage),
        degrade_supply=float(args.degrade_supply),
        sat_ceiling=float(args.sat_ceiling),
        sat_floor=float(args.sat_floor),
        rq_ratio_local=float(args.rq_ratio_local),
        rq_ratio_supply=float(args.rq_ratio_supply),
        pw_frac_delta=float(args.pw_frac_delta),
        d_rq_local=float(args.d_rq_local),
        min_healthy_s=int(args.min_healthy_s),
    )
    # provenance labels on thresholds
    print(
        f"threshold degrade_supply={args.degrade_supply} src="
        f"{PROV_CALLER if args.degrade_supply != DEFAULT_DEGRADE_SUPPLY else PROV_DEFAULT}"
    )
    print(
        f"threshold sustained_frac={args.sustained_frac} src="
        f"{PROV_CALLER if args.sustained_frac != DEFAULT_SUSTAINED_FRAC else PROV_DEFAULT}"
    )
    print(
        f"threshold min_degraded_s={args.min_degraded_s} src="
        f"{PROV_CALLER if args.min_degraded_s != DEFAULT_MIN_DEGRADED_S else PROV_DEFAULT}"
    )
    return print_verdict(verdict, rc, reason, metrics, a.notes)


# --- SELF-TEST (RBG both directions) ---------------------------------------------

def _synth_row(
    *,
    t: int,
    supply: float,
    vfps: float,
    recv_q: Optional[int],
    pipe_write_n: int,
    n_threads: int = 8,
    sock_n: int = 0,
    daemon_pipe_read_n: int = 0,
    frames: int = 0,
    presents: int = 0,
    drops: int = 0,
    session_epoch: str = "1.1",
) -> Dict[str, Any]:
    rq = (
        _meas(recv_q, four_tuple="x:1 y:32400")
        if recv_q is not None
        else _nodata("test")
    )
    return {
        "record": "sample",
        "t_mono_ms": t,
        "recv_q": rq,
        "ffmpeg_wchan": _meas(
            {
                "n_threads": n_threads,
                "pipe_write_n": pipe_write_n,
                "pipe_read_n": 0,
                "socket_readish_n": sock_n,
                "top": [],
            }
        ),
        "daemon_wchan": _meas(
            {
                "n_threads": 4,
                "pipe_write_n": 0,
                "pipe_read_n": daemon_pipe_read_n,
                "socket_readish_n": 0,
                "top": [],
            }
        ),
        "media": _meas(
            {
                "frames": frames,
                "presents": presents,
                "drops": drops,
                "wall_s": t / 1000.0,
                "audio_s": supply * (t / 1000.0),
                "session_epoch": session_epoch,
                "process_epoch": "1",
            }
        ),
        "interval": {
            "dt_mono_s": 1.0,
            "dt_mono_s_src": PROV_MEAS,
            "interval_supply": supply,
            "interval_supply_src": PROV_MEAS,
            "interval_vfps": vfps,
            "interval_vfps_src": PROV_MEAS,
            "d_frames": vfps,
            "d_frames_src": PROV_MEAS,
            "residual": frames - presents - drops,
            "residual_src": PROV_MEAS,
        },
    }


def _kw_classify(a: Agg) -> Tuple[str, int, str, Dict[str, Any]]:
    return classify_locus(
        a,
        sustained_frac=DEFAULT_SUSTAINED_FRAC,
        min_degraded_s=DEFAULT_MIN_DEGRADED_S,
        min_coverage=DEFAULT_MIN_COVERAGE,
        degrade_supply=DEFAULT_DEGRADE_SUPPLY,
        sat_ceiling=DEFAULT_SAT_CEILING,
        sat_floor=DEFAULT_SAT_FLOOR,
        rq_ratio_local=DEFAULT_RQ_RATIO_LOCAL,
        rq_ratio_supply=DEFAULT_RQ_RATIO_SUPPLY,
        pw_frac_delta=DEFAULT_PW_FRAC_DELTA,
        d_rq_local=DEFAULT_D_RQ_LOCAL,
        min_healthy_s=DEFAULT_MIN_HEALTHY_S,
    )


def cmd_self_test() -> int:
    # --- MISS demonstration: healthy paced run saturates binary LOCAL ---
    # Like parent hardware: recv_q always >0, always some pipe_write, high supply
    paced = []
    rq = 40000
    for i in range(1, 40):
        rq = min(90000, rq + 500)  # mild wander, always >>0
        paced.append(
            _synth_row(
                t=1000 * i,
                supply=0.99,
                vfps=23.5,
                recv_q=rq,
                pipe_write_n=2,
                n_threads=8,
                frames=24 * i,
                presents=24 * i - 3,  # residual = frames - presents - drops = 1
                drops=2,
            )
        )
    a = analyze_rows(
        paced,
        degrade_supply=DEFAULT_DEGRADE_SUPPLY,
        near_zero_vfps=DEFAULT_NEAR_ZERO_VFPS,
        recv_q_local_min=1,
    )
    v, rc, reason, m = _kw_classify(a)
    assert rc == RC_INSUFFICIENT, (v, rc, reason, m)
    assert m.get("sat_binary_recv_q_gt0") == "SATURATED_HIGH", m
    assert m.get("sat_binary_pipe_write_any") == "SATURATED_HIGH", m
    assert m.get("finding_socket_never_empty_healthy") == 1, m
    print("SELF_TEST paced_healthy SATURATED refuse rc=78 OK finding_socket_never_empty")

    # residual=1 never rounded
    assert m.get("residual") == 1, m
    assert m.get("residual_calc") == 1, m
    assert m.get("residual_class") == "near_closed_abs_le_1", m
    print("SELF_TEST residual=1 near_closed NOT rounded OK")

    # --- LOCAL v2: healthy baseline backlog ~20k; degrade climbs to ~80k ---
    local_rows = []
    rq = 20000
    for i in range(1, 40):
        deg = i >= 15
        if deg:
            rq = min(120000, rq + 4000)  # growing backlog
            supply, vfps, pw_n = 0.45, 0.4, 5
        else:
            rq = 20000 + (i % 5) * 200
            supply, vfps, pw_n = 0.99, 23.0, 2
        local_rows.append(
            _synth_row(
                t=1000 * i,
                supply=supply,
                vfps=vfps,
                recv_q=rq,
                pipe_write_n=pw_n,
                n_threads=8,
                frames=10 * i,
                presents=8 * i,
                drops=i,
            )
        )
    a = analyze_rows(
        local_rows,
        degrade_supply=DEFAULT_DEGRADE_SUPPLY,
        near_zero_vfps=DEFAULT_NEAR_ZERO_VFPS,
        recv_q_local_min=1,
    )
    v, rc, reason, m = _kw_classify(a)
    assert v == "LOCAL_ESTABLISHED" and rc == RC_LOCAL, (v, rc, reason, m)
    assert m["frac_near_zero"] != PROV_NODATA and float(m["frac_near_zero"]) > 0.2
    print("SELF_TEST LOCAL_ESTABLISHED rc=3 OK ratio=", m.get("recv_q_median_ratio_deg_over_h"))

    # --- SUPPLY v2: healthy backlog ~40k; degrade collapses toward 0 ---
    supply_rows = []
    rq = 40000
    for i in range(1, 40):
        deg = i >= 15
        if deg:
            rq = max(0, rq - 3000)
            supply, vfps, pw_n = 0.45, 0.4, 1
        else:
            rq = 40000 + (i % 3) * 500
            supply, vfps, pw_n = 0.99, 23.0, 2
        supply_rows.append(
            _synth_row(
                t=1000 * i,
                supply=supply,
                vfps=vfps,
                recv_q=rq,
                pipe_write_n=pw_n,
                n_threads=8,
                sock_n=4 if deg else 1,
                daemon_pipe_read_n=2 if deg else 0,
                frames=10 * i,
                presents=10 * i - 4,
                drops=4,
            )
        )
    a = analyze_rows(
        supply_rows,
        degrade_supply=DEFAULT_DEGRADE_SUPPLY,
        near_zero_vfps=DEFAULT_NEAR_ZERO_VFPS,
        recv_q_local_min=1,
    )
    v, rc, reason, m = _kw_classify(a)
    assert v == "SUPPLY_ESTABLISHED" and rc == RC_SUPPLY, (v, rc, reason, m)
    print("SELF_TEST SUPPLY_ESTABLISHED rc=2 OK ratio=", m.get("recv_q_median_ratio_deg_over_h"))

    # --- false LOCAL trap: binary would fire, magnitude does not (flat backlog) ---
    trap = []
    for i in range(1, 40):
        deg = i >= 15
        trap.append(
            _synth_row(
                t=1000 * i,
                supply=0.45 if deg else 0.99,
                vfps=0.4 if deg else 23.0,
                recv_q=50000,  # flat non-zero always
                pipe_write_n=2,  # always some pipe_write
                n_threads=8,
                frames=10 * i,
                presents=10 * i - 4,
                drops=4,
            )
        )
    a = analyze_rows(
        trap,
        degrade_supply=DEFAULT_DEGRADE_SUPPLY,
        near_zero_vfps=DEFAULT_NEAR_ZERO_VFPS,
        recv_q_local_min=1,
    )
    v, rc, reason, m = _kw_classify(a)
    assert rc != RC_LOCAL, (v, rc, reason, m)
    assert rc in (RC_UNKNOWN, RC_INSUFFICIENT, RC_SUPPLY), (v, rc, reason)
    print("SELF_TEST false_LOCAL_trap refused rc=", rc, v)

    # INSUFFICIENT: no recv_q channel
    thin = [
        _synth_row(
            t=1000 * i,
            supply=0.4,
            vfps=0.2,
            recv_q=None,
            pipe_write_n=0,
            frames=i,
            presents=i,
            drops=0,
        )
        for i in range(1, 15)
    ]
    a = analyze_rows(
        thin,
        degrade_supply=DEFAULT_DEGRADE_SUPPLY,
        near_zero_vfps=DEFAULT_NEAR_ZERO_VFPS,
        recv_q_local_min=1,
    )
    v, rc, reason, m = _kw_classify(a)
    assert v == "INSUFFICIENT_EVIDENCE" and rc == RC_INSUFFICIENT, (v, rc, reason)
    print("SELF_TEST INSUFFICIENT_EVIDENCE rc=78 OK")

    # SESSION_INVALID
    bad = [
        _synth_row(
            t=1000,
            supply=0.9,
            vfps=23,
            recv_q=100,
            pipe_write_n=1,
            session_epoch="1.1",
            frames=10,
            presents=10,
            drops=0,
        ),
        _synth_row(
            t=2000,
            supply=0.9,
            vfps=23,
            recv_q=100,
            pipe_write_n=1,
            session_epoch="2.1",
            frames=20,
            presents=20,
            drops=0,
        ),
    ]
    a = analyze_rows(
        bad,
        degrade_supply=DEFAULT_DEGRADE_SUPPLY,
        near_zero_vfps=DEFAULT_NEAR_ZERO_VFPS,
        recv_q_local_min=1,
    )
    v, rc, reason, m = _kw_classify(a)
    assert v == "SESSION_INVALID" and rc == RC_SESSION_INVALID, (v, rc, reason)
    print("SELF_TEST SESSION_INVALID rc=79 OK")

    print("SELF_TEST_OK v2 magnitude LOCAL/SUPPLY + saturation guard")
    return 0



def main(argv: Optional[Sequence[str]] = None) -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    sub = ap.add_subparsers(dest="cmd", required=True)

    sp = sub.add_parser("sample", help="ON-DEVICE 1 Hz JSONL sampler")
    sp.add_argument(
        "--out",
        required=True,
        help="local path on device e.g. /media/fat/misterplex_v2/locus480.jsonl",
    )
    sp.add_argument("--interval", type=float, default=DEFAULT_HZ)
    sp.add_argument("--duration", type=float, default=None, help="seconds; omit=until killed")
    sp.add_argument("--max-samples", type=int, default=None)
    sp.add_argument("--once", action="store_true")
    sp.add_argument("--media-log", default=None)
    sp.add_argument("--iface", default=None, help="prefer this NIC for rx_bytes")

    vp = sub.add_parser("verdict", help="HOST score of fetched JSONL")
    vp.add_argument("--in", dest="inp", required=True)
    vp.add_argument("--media-log", default=None, help="optional full daemon log for ledger")
    vp.add_argument("--degrade-supply", type=float, default=DEFAULT_DEGRADE_SUPPLY)
    vp.add_argument("--near-zero-vfps", type=float, default=DEFAULT_NEAR_ZERO_VFPS)
    vp.add_argument("--recv-q-local-min", type=int, default=DEFAULT_RECV_Q_LOCAL_MIN)
    vp.add_argument("--sustained-frac", type=float, default=DEFAULT_SUSTAINED_FRAC)
    vp.add_argument("--min-degraded-s", type=int, default=DEFAULT_MIN_DEGRADED_S)
    vp.add_argument("--min-coverage", type=float, default=DEFAULT_MIN_COVERAGE)
    vp.add_argument("--sat-ceiling", type=float, default=DEFAULT_SAT_CEILING)
    vp.add_argument("--sat-floor", type=float, default=DEFAULT_SAT_FLOOR)
    vp.add_argument("--rq-ratio-local", type=float, default=DEFAULT_RQ_RATIO_LOCAL)
    vp.add_argument("--rq-ratio-supply", type=float, default=DEFAULT_RQ_RATIO_SUPPLY)
    vp.add_argument("--pw-frac-delta", type=float, default=DEFAULT_PW_FRAC_DELTA)
    vp.add_argument("--d-rq-local", type=float, default=DEFAULT_D_RQ_LOCAL)
    vp.add_argument("--min-healthy-s", type=int, default=DEFAULT_MIN_HEALTHY_S)

    sub.add_parser("self-test", help="RBG LOCAL + SUPPLY + saturated + insufficient + session")

    args = ap.parse_args(list(argv) if argv is not None else None)
    if args.cmd == "sample":
        return cmd_sample(args)
    if args.cmd == "verdict":
        return cmd_verdict(args)
    if args.cmd == "self-test":
        return cmd_self_test()
    return RC_USAGE


if __name__ == "__main__":
    sys.exit(main())
