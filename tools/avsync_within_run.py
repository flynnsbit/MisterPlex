#!/usr/bin/env python3
"""Within-run framerate + A/V-servo instrument (user 480p drop/sync bug).

USER (verbatim): verify framerate and audio sync on the 480p path; frames look dropped.

ESTABLISHED (parent-measured — do not re-litigate)
-------------------------------------------------
- Transport empty-socket starvation eliminated: recv_q>0 in 100% of 1 Hz samples.
- Degradation intermittent ~25% → single-run A/B has NO power. Within-run only.
- Degraded: audio_s*24 ≈ frames (0.15% lockstep) → common ffmpeg upstream stall.
- drops = pacer Drop only (~media_player.cpp:4185); 7.1% of deficit on parent run
  (356 of 984 short) → most loss is frames that never arrived.
- supply_ratio VOID for socket-starved vs video-consumer-blocked (same lockstep).
- Bitrate request changes delivered geometry (397→312x240 vs 2000→624x480) —
  any ladder must measure decode=WxH per arm.

TWO QUESTIONS (separate axes — never one name for the other)
------------------------------------------------------------
  (A) FPS_SUSTAINED  — is content rate held wall-second by wall-second?
  (B) AV_RELATION    — is the daemon's A/V relationship stable / unlocked?
      Glass lipsync GT remains HDMI flash↔beep only (when grabber lives).

av_drift_ms HONESTY (quoted product path)
-----------------------------------------
  clockMs = audibleClockMs(audioBytes_, audioQueuedBytes_)   # mraudio_status.hpp
  frameMs = frameContentMs(frameIndex, fpsNum, fpsDen)       # av_clock.hpp
  drift   = clockMs - frameMs                                  # avDriftMs
  avDecide HOLDs while drift+lead < 0  → steady publish sits in ~[-lead, drop)
  BY CONSTRUCTION (av_clock.hpp). When locked, absolute av_drift_ms is a
  setpoint readout, NOT lipsync accuracy and NOT "in sync" proof.

  When the servo CANNOT catch video up (production short), drift climbs
  positive (parent: -22 → +56 → +81). That climb is a real unlock signal
  WITHIN-RUN vs the healthy baseline of the SAME soak — still not glass GT.

  av_display_offset_ms = audibleClock - frameContentMs(presentCount) does NOT
  free-heal on Drop the way chasing frameIndex does (av_clock.hpp). Prefer it
  for presentation lag if present on the media line.

SATURATION GUARD (w-instr locus480 v2 lesson — do not repeat)
-------------------------------------------------------------
  Indicators pinned at ceiling/floor on the *non-degraded* portion of the
  same run are SATURATED and refuse discrimination (rc=78 for that channel).
  Example MISS: recv_q_gt0_frac=1.0 and pipe_write_frac=1.0 on healthy paced
  playback (intentional audio back-pressure media_player audioPump).

  For THIS tool:
  - Absolute av_drift near -lead with near-zero variance on healthy portion
    → SERVO_PINNED_DEADBAND (saturated as lipsync / "sync OK" claim).
  - Interval vfps at content_fps on healthy portion is EXPECTED, not saturated:
    the FPS axis detects *departure* downward; headroom exists.
  - supply_ratio is never used as a locus or pass criterion here (VOID endpoint).

PRESENT_PROFILE (w-cpu 6960d5b2) — build on, do not duplicate
-------------------------------------------------------------
  present_window 1 Hz lines classify H-READ/H-DDR/H-PACER/H-HOLD/H-BALANCED.
  This tool CONSUMES d_frames/d_presented/d_drops when those lines exist for
  the FPS axis. It does NOT re-implement the stall-locus classifier — parent
  runs PRESENT_PROFILE=1 and scores class histograms with w-cpu's recipe.
  When present_window is absent, interval rates are reconstructed from
  consecutive media: frames/presents/wall_s lines (works on ea643e99).

Exit codes (capture DIRECTLY — never through a pipe):
   0  both axes DATA and ok (FPS sustained + servo deadband stable; NOT lipsync PASS)
   2  FPS_COLLAPSE (within-run production short)
   3  SERVO_UNLOCK_CLIMB (drift/display_offset climbs vs healthy baseline)
   4  BOTH_FPS_AND_SERVO_BAD
   5  GEOMETRY_SHIFT mid-run (decode WxH changed — bitrate confound)
  78  INSUFFICIENT_EVIDENCE / saturated-only channels / short window
  79  SESSION_INVALID (epoch/pid/counter reset)
  77  NO-DATA
   6  self-test / designed sensitivity (if used)

Usage:
  python3 tools/avsync_within_run.py --self-test; echo "true rc=$?"
  python3 tools/avsync_within_run.py --daemon-log path.txt \\
      --content-fps 24 --content-fps-src caller_supplied
  echo "true rc=$?"
"""
from __future__ import annotations

import argparse
import json
import math
import re
import statistics
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence, Tuple

# --- exit codes ----------------------------------------------------------------
RC_OK = 0
RC_FPS_COLLAPSE = 2
RC_SERVO_UNLOCK = 3
RC_BOTH = 4
RC_GEOM = 5
RC_INSUFFICIENT = 78
RC_SESSION = 79
RC_NO_DATA = 77

PROV_MEAS = "measured"
PROV_CALLER = "caller_supplied"
PROV_DEFAULT = "DEFAULT_ASSUMED"
PROV_NODATA = "NO-DATA"
PROV_DERIVED = "derived"


# --- regex ----------------------------------------------------------------------
RE_MEDIA = re.compile(r"\bmedia:")
RE_PW = re.compile(r"\bpresent_window\b")
RE_FRAMES = re.compile(r"\bframes=(?P<v>\d+)")
RE_PRES = re.compile(r"\bpresents=(?P<v>\d+)")
RE_DROPS = re.compile(r"\bdrops=(?P<v>\d+)")
RE_PM = re.compile(r"\bpublish_misses=(?P<v>\d+)")
RE_WALL = re.compile(r"\bwall_s=(?P<v>[0-9.]+)")
RE_AUDIO = re.compile(r"\baudio_s=(?P<v>[0-9.]+)")
RE_DRIFT = re.compile(r"\bav_drift_ms=(?P<v>-?\d+)")
RE_DISP = re.compile(r"\bav_display_offset_ms=(?P<v>-?\d+)")
RE_LEAD = re.compile(r"\blead_ms=(?P<v>-?\d+)")
RE_SETPOINT = re.compile(r"\bav_servo_setpoint_ms=(?P<v>-?\d+)")
RE_MARGIN = re.compile(r"\bav_servo_margin_ms=(?P<v>-?\d+)")
RE_FPS = re.compile(r"\bfps=(?P<n>\d+)/(?P<d>\d+)")
RE_DECODE = re.compile(r"\bdecode=(?P<w>\d+)x(?P<h>\d+)")
RE_EPOCH = re.compile(r"\bsession_epoch=(?P<v>\S+)")
RE_PID = re.compile(r"\bpid=(?P<v>\d+)")
RE_DF = re.compile(r"\bd_frames=(?P<v>-?\d+)")
RE_DP = re.compile(r"\bd_presented=(?P<v>-?\d+)")
RE_DD = re.compile(r"\bd_drops=(?P<v>-?\d+)")
RE_CLASS = re.compile(r"\bclass=(?P<v>\S+)")
RE_WALL_US = re.compile(r"\bwall_us=(?P<v>\d+)")


@dataclass
class MediaSample:
    line_no: int
    kind: str  # "media" | "present_window"
    wall_s: Optional[float] = None
    frames: Optional[int] = None
    presents: Optional[int] = None
    drops: Optional[int] = None
    publish_misses: Optional[int] = None
    audio_s: Optional[float] = None
    av_drift_ms: Optional[int] = None
    av_display_offset_ms: Optional[int] = None
    lead_ms: Optional[int] = None
    setpoint_ms: Optional[int] = None
    margin_ms: Optional[int] = None
    fps_num: Optional[int] = None
    fps_den: Optional[int] = None
    decode_w: Optional[int] = None
    decode_h: Optional[int] = None
    session_epoch: Optional[str] = None
    pid: Optional[str] = None
    # present_window deltas
    d_frames: Optional[int] = None
    d_presented: Optional[int] = None
    d_drops: Optional[int] = None
    pw_class: Optional[str] = None
    wall_us: Optional[int] = None


@dataclass
class Interval:
    t0: float
    t1: float
    dt: float
    d_frames: Optional[int]
    d_presents: Optional[int]
    d_drops: Optional[int]
    iv_vfps: Optional[float]
    iv_pfps: Optional[float]
    drift: Optional[int]
    display_off: Optional[int]
    margin: Optional[int]
    src: str  # reconstructed_media | present_window


def _gi(rx: re.Pattern[str], line: str, cast=int):
    m = rx.search(line)
    if not m:
        return None
    try:
        return cast(m.group("v") if "v" in m.groupdict() else m.group(1))
    except (ValueError, IndexError):
        return None


def parse_log(text: str) -> List[MediaSample]:
    out: List[MediaSample] = []
    for i, line in enumerate(text.splitlines(), 1):
        if not RE_MEDIA.search(line):
            continue
        if "supply_bucket" in line or "session end" in line:
            continue
        if "A/V resync drop" in line:
            continue
        # Split DDR heartbeats are w-instr ledger territory — skip.
        if "fpga frame_tx" in line or "frame_tx ok" in line:
            continue
        kind = "present_window" if RE_PW.search(line) else "media"
        s = MediaSample(line_no=i, kind=kind)
        s.wall_s = _gi(RE_WALL, line, float)
        s.frames = _gi(RE_FRAMES, line, int)
        s.presents = _gi(RE_PRES, line, int)
        s.drops = _gi(RE_DROPS, line, int)
        s.publish_misses = _gi(RE_PM, line, int)
        s.audio_s = _gi(RE_AUDIO, line, float)
        s.av_drift_ms = _gi(RE_DRIFT, line, int)
        s.av_display_offset_ms = _gi(RE_DISP, line, int)
        s.lead_ms = _gi(RE_LEAD, line, int)
        s.setpoint_ms = _gi(RE_SETPOINT, line, int)
        s.margin_ms = _gi(RE_MARGIN, line, int)
        s.session_epoch = None
        em = RE_EPOCH.search(line)
        if em:
            s.session_epoch = em.group("v")
        pm = RE_PID.search(line)
        if pm:
            s.pid = pm.group("v")
        fm = RE_FPS.search(line)
        if fm:
            s.fps_num = int(fm.group("n"))
            s.fps_den = int(fm.group("d"))
        dm = RE_DECODE.search(line)
        if dm:
            s.decode_w = int(dm.group("w"))
            s.decode_h = int(dm.group("h"))
        if kind == "present_window":
            s.d_frames = _gi(RE_DF, line, int)
            s.d_presented = _gi(RE_DP, line, int)
            s.d_drops = _gi(RE_DD, line, int)
            cm = RE_CLASS.search(line)
            if cm:
                s.pw_class = cm.group("v")
            s.wall_us = _gi(RE_WALL_US, line, int)
            if s.wall_s is None and s.wall_us is not None:
                # wall_s on present_window is session wall; wall_us is window.
                pass
        out.append(s)
    return out


def continuity_invalid(samples: Sequence[MediaSample]) -> Tuple[bool, str]:
    epochs = {s.session_epoch for s in samples if s.session_epoch}
    pids = {s.pid for s in samples if s.pid}
    if len(epochs) > 1:
        return True, f"session_epoch_changed {sorted(epochs)}"
    if len(pids) > 1:
        return True, f"pid_changed {sorted(pids)}"
    prev_w = prev_f = None
    for s in samples:
        if s.kind != "media":
            continue
        if s.wall_s is not None:
            if prev_w is not None and s.wall_s + 0.05 < prev_w:
                return True, f"wall_s_reset {prev_w}->{s.wall_s}"
            prev_w = s.wall_s
        if s.frames is not None:
            if prev_f is not None and s.frames < prev_f:
                return True, f"frames_reset {prev_f}->{s.frames}"
            prev_f = s.frames
    return False, "continuous"


def content_fps_from_samples(
    samples: Sequence[MediaSample],
    cli_fps: Optional[float],
    cli_src: str,
) -> Dict[str, Any]:
    if cli_fps is not None:
        return {"fps": float(cli_fps), "fps_src": cli_src}
    for s in reversed(list(samples)):
        if s.fps_num and s.fps_den:
            return {
                "fps": s.fps_num / float(s.fps_den),
                "fps_src": PROV_MEAS,
                "fps_num": s.fps_num,
                "fps_den": s.fps_den,
            }
    return {"fps": 24.0, "fps_src": PROV_DEFAULT, "note": "no fps= on log; 24.0 DEFAULT_ASSUMED"}


def build_intervals_from_media(samples: Sequence[MediaSample]) -> List[Interval]:
    media = [
        s
        for s in samples
        if s.kind == "media" and s.wall_s is not None and s.frames is not None
    ]
    ivs: List[Interval] = []
    for a, b in zip(media, media[1:]):
        dt = b.wall_s - a.wall_s  # type: ignore[operator]
        if dt < 0.40:
            continue
        if dt > 5.0:
            # gap — skip rather than invent a rate
            continue
        df = b.frames - a.frames  # type: ignore[operator]
        if df < 0:
            continue
        dp = None
        if isinstance(a.presents, int) and isinstance(b.presents, int):
            dp = b.presents - a.presents
            if dp < 0:
                dp = None
        dd = None
        if isinstance(a.drops, int) and isinstance(b.drops, int):
            dd = b.drops - a.drops
            if dd < 0:
                dd = None
        ivs.append(
            Interval(
                t0=float(a.wall_s),  # type: ignore[arg-type]
                t1=float(b.wall_s),  # type: ignore[arg-type]
                dt=float(dt),
                d_frames=df,
                d_presents=dp,
                d_drops=dd,
                iv_vfps=df / dt,
                iv_pfps=(dp / dt) if dp is not None else None,
                drift=b.av_drift_ms if b.av_drift_ms is not None else a.av_drift_ms,
                display_off=b.av_display_offset_ms
                if b.av_display_offset_ms is not None
                else a.av_display_offset_ms,
                margin=b.margin_ms if b.margin_ms is not None else a.margin_ms,
                src="reconstructed_media",
            )
        )
    return ivs


def build_intervals_from_present_window(samples: Sequence[MediaSample]) -> List[Interval]:
    """Consume w-cpu PRESENT_PROFILE lines — do not re-classify H-* locus."""
    ivs: List[Interval] = []
    for s in samples:
        if s.kind != "present_window":
            continue
        if s.d_frames is None or s.wall_us is None or s.wall_us <= 0:
            continue
        dt = s.wall_us / 1e6
        if dt < 0.2:
            continue
        t = float(s.wall_s) if s.wall_s is not None else float("nan")
        ivs.append(
            Interval(
                t0=t - dt if math.isfinite(t) else 0.0,
                t1=t if math.isfinite(t) else dt,
                dt=dt,
                d_frames=s.d_frames,
                d_presents=s.d_presented,
                d_drops=s.d_drops,
                iv_vfps=s.d_frames / dt,
                iv_pfps=(s.d_presented / dt) if s.d_presented is not None else None,
                drift=s.av_drift_ms,
                display_off=s.av_display_offset_ms,
                margin=s.margin_ms,
                src="present_window",
            )
        )
    return ivs


def pct(xs: Sequence[float], p: float) -> Optional[float]:
    if not xs:
        return None
    s = sorted(xs)
    if len(s) == 1:
        return s[0]
    k = (len(s) - 1) * p
    f = math.floor(k)
    c = math.ceil(k)
    if f == c:
        return s[int(k)]
    return s[f] * (c - k) + s[c] * (k - f)


def saturation_guard_drift(
    healthy_vals: Sequence[float],
    *,
    lead_ms: Optional[float],
    drop_ms: float = 80.0,
    var_tol: float = 6.0,
) -> Dict[str, Any]:
    """av_drift on healthy portion: low variance inside Hold deadband → PINNED.

    Steady lock publishes drift ∈ approx [-lead, drop) BY CONSTRUCTION
    (av_clock.hpp). Parent healthy cluster was about -21..-38 with lead=40 —
    not always exactly -lead. Pin = low pstdev + median inside deadband.
    That refuses absolute drift as lipsync / 'sync OK'.
    """
    name = "av_drift_ms_abs"
    if len(healthy_vals) < 3:
        return {
            "name": name,
            "status": PROV_NODATA,
            "n_healthy": len(healthy_vals),
            "usable": False,
            "reason": "need>=3 healthy samples",
            "src": PROV_NODATA,
        }
    med = statistics.median(healthy_vals)
    try:
        pstdev = statistics.pstdev(healthy_vals)
    except statistics.StatisticsError:
        pstdev = 0.0
    lead = float(lead_ms) if lead_ms is not None else 40.0
    lead_src = PROV_MEAS if lead_ms is not None else PROV_DEFAULT
    lo = -lead - 5.0
    hi = min(drop_ms, 15.0)  # locked band is negative-biased; >15 is unlock-ish
    in_band = lo <= med <= hi
    out: Dict[str, Any] = {
        "name": name,
        "n_healthy": len(healthy_vals),
        "healthy_median": med,
        "healthy_pstdev": pstdev,
        "healthy_median_src": PROV_MEAS,
        "healthy_pstdev_src": PROV_MEAS,
        "lead_ms": lead,
        "lead_ms_src": lead_src,
        "deadband_lo": lo,
        "deadband_hi": hi,
        "deadband_src": PROV_DERIVED,
        "var_tol": var_tol,
        "var_tol_src": PROV_DEFAULT,
        "in_deadband": in_band,
        "usable": True,
        "status": "ok",
        "src": PROV_MEAS,
    }
    if in_band and pstdev <= var_tol:
        out["status"] = "SATURATED_PINNED_DEADBAND"
        out["usable"] = False
        out["reason"] = (
            f"healthy av_drift median={med:.1f} in deadband[{lo:.0f},{hi:.0f}] "
            f"pstdev={pstdev:.2f}≤{var_tol} — BY CONSTRUCTION near -lead; "
            f"NOT lipsync GT (av_clock.hpp avDecide Hold)"
        )
    elif pstdev <= var_tol and med > hi:
        out["status"] = "HEALTHY_PORTION_ALREADY_UNLOCKED"
        out["usable"] = True
        out["reason"] = "healthy median already above deadband hi — unusual"
    return out


def split_healthy_degraded(
    ivs: Sequence[Interval],
    content_fps: float,
    *,
    ok_frac: float = 0.95,
    min_healthy: int = 5,
    min_degraded: int = 3,
) -> Dict[str, Any]:
    """Split intervals by iv_vfps vs content_fps (within-run; not A/B sessions)."""
    thr = content_fps * ok_frac
    h = [iv for iv in ivs if iv.iv_vfps is not None and iv.iv_vfps >= thr]
    d = [iv for iv in ivs if iv.iv_vfps is not None and iv.iv_vfps < thr]
    return {
        "thr_vfps": thr,
        "thr_vfps_src": PROV_DERIVED,
        "ok_frac": ok_frac,
        "ok_frac_src": PROV_DEFAULT,
        "n_healthy": len(h),
        "n_degraded": len(d),
        "n_total": len(ivs),
        "healthy": h,
        "degraded": d,
        "min_healthy": min_healthy,
        "min_degraded": min_degraded,
        "enough_healthy": len(h) >= min_healthy,
        "enough_degraded": len(d) >= min_degraded,
        "src": PROV_MEAS,
    }


def score_fps_axis(
    ivs: Sequence[Interval],
    content_fps: float,
    last_media: Optional[MediaSample],
    ok_frac: float,
) -> Dict[str, Any]:
    rates = [iv.iv_vfps for iv in ivs if iv.iv_vfps is not None]
    if len(rates) < 3:
        return {
            "axis": "FPS_SUSTAINED",
            "verdict": "NO-DATA",
            "status": PROV_NODATA,
            "n_intervals": len(rates),
            "src": PROV_NODATA,
        }
    thr = content_fps * ok_frac
    n_ok = sum(1 for r in rates if r >= thr)
    frac_ok = n_ok / len(rates)
    p10 = pct(rates, 0.10)
    p50 = pct(rates, 0.50)
    p90 = pct(rates, 0.90)

    # Session deficit vs content (never_arrived)
    deficit_doc: Dict[str, Any] = {"src": PROV_NODATA}
    if (
        last_media
        and last_media.frames is not None
        and last_media.wall_s is not None
        and last_media.wall_s > 1.0
    ):
        expected = content_fps * float(last_media.wall_s)
        short = expected - float(last_media.frames)
        drops = last_media.drops if isinstance(last_media.drops, int) else None
        never = short - float(drops) if drops is not None else None
        deficit_doc = {
            "wall_s": last_media.wall_s,
            "wall_s_src": PROV_MEAS,
            "frames": last_media.frames,
            "frames_src": PROV_MEAS,
            "content_fps": content_fps,
            "expected_frames": expected,
            "expected_frames_src": PROV_DERIVED,
            "short_frames": short,
            "short_frames_src": PROV_DERIVED,
            "drops": drops if drops is not None else PROV_NODATA,
            "drops_src": PROV_MEAS if drops is not None else PROV_NODATA,
            "drops_means": (
                "deliberate avDecide Drop only (media_player.cpp ~:4185 "
                "droppedFrames_.fetch_add) — NOT ffmpeg shortfall"
            ),
            "never_arrived_frames": never if never is not None else PROV_NODATA,
            "never_arrived_src": PROV_DERIVED if never is not None else PROV_NODATA,
            "drops_frac_of_short": (
                (drops / short) if drops is not None and short > 1 else PROV_NODATA
            ),
            "note": (
                "parent degraded: short≈984 drops=356 → drops only ~7% of deficit; "
                "most loss never_arrived"
            ),
            "src": PROV_MEAS,
        }

    # FPS axis saturation: healthy ceiling is EXPECTED. Guard only if variance
    # is exactly zero AND we have no degraded samples — still scorable as ok.
    # Refuse if rates empty of contrast AND entire run is one sample — handled above.

    if frac_ok >= ok_frac and (p10 is None or p10 >= thr * 0.98):
        verdict = "FPS_OK"
    elif frac_ok < ok_frac:
        verdict = "FPS_COLLAPSE"
    else:
        verdict = "FPS_MARGINAL"

    return {
        "axis": "FPS_SUSTAINED",
        "verdict": verdict,
        "n_intervals": len(rates),
        "n_intervals_src": PROV_MEAS,
        "frac_windows_at_rate": frac_ok,
        "frac_windows_at_rate_src": PROV_MEAS,
        "thr_vfps": thr,
        "thr_vfps_src": PROV_DERIVED,
        "ok_frac": ok_frac,
        "ok_frac_src": PROV_DEFAULT,
        "iv_vfps_p10": p10,
        "iv_vfps_p50": p50,
        "iv_vfps_p90": p90,
        "iv_vfps_percentile_src": PROV_MEAS,
        "content_fps": content_fps,
        "interval_src_counts": _count_src(ivs),
        "deficit": deficit_doc,
        "saturation": {
            "note": (
                "iv_vfps≈content_fps on healthy windows is EXPECTED headroom-down "
                "signal; NOT a ceiling saturation trap (unlike recv_q_gt0_frac=1.0)"
            ),
            "status": "not_applicable_headroom_down",
            "src": PROV_DEFAULT,
        },
        "cannot_settle": [
            "glass judder / motion smoothness (needs HDMI motion instrument)",
            "H-READ vs H-DDR stall locus (use PRESENT_PROFILE present_window class)",
        ],
        "src": PROV_MEAS,
    }


def _count_src(ivs: Sequence[Interval]) -> Dict[str, int]:
    c: Dict[str, int] = {}
    for iv in ivs:
        c[iv.src] = c.get(iv.src, 0) + 1
    return c


def score_sync_axis(
    split: Dict[str, Any],
    lead_ms: Optional[float],
    *,
    climb_thr_ms: float = 25.0,
) -> Dict[str, Any]:
    """Servo / display-offset relation — NOT glass lipsync."""
    h: List[Interval] = split["healthy"]
    d: List[Interval] = split["degraded"]

    h_drift = [float(iv.drift) for iv in h if iv.drift is not None]
    d_drift = [float(iv.drift) for iv in d if iv.drift is not None]
    h_disp = [float(iv.display_off) for iv in h if iv.display_off is not None]
    d_disp = [float(iv.display_off) for iv in d if iv.display_off is not None]

    setpoint = -float(lead_ms) if lead_ms is not None else None
    sat = saturation_guard_drift(h_drift, lead_ms=lead_ms)

    # Within-run climb: degraded median - healthy median
    climb = None
    climb_src = PROV_NODATA
    if len(h_drift) >= 3 and len(d_drift) >= 3:
        climb = statistics.median(d_drift) - statistics.median(h_drift)
        climb_src = PROV_MEAS

    disp_climb = None
    disp_climb_src = PROV_NODATA
    if len(h_disp) >= 3 and len(d_disp) >= 3:
        disp_climb = statistics.median(d_disp) - statistics.median(h_disp)
        disp_climb_src = PROV_MEAS

    honesty = {
        "av_drift_ms_role": "servo_error_not_lipsync",
        "eq": "audibleClockMs(audioBytes,queued) - frameContentMs(frameIndex)",
        "eq_sites": (
            "media_player.cpp ~:4143-4151 store; av_clock.hpp avDriftMs; "
            "avDecide Hold while drift+lead<0 → steady band ≈[-lead,drop)"
        ),
        "locked_means": (
            "absolute av_drift_ms is definitionally near -lead when Hold loop "
            "can keep up — USELESS as lipsync GT and USELESS as 'sync OK' alone"
        ),
        "unlock_means": (
            "when video production lags, Hold cannot pull drift back; published "
            "drift climbs positive (parent -22→+56→+81). Detect via WITHIN-RUN "
            "Δ(degraded−healthy) of same soak — still not glass lipsync"
        ),
        "display_offset": (
            "av_display_offset_ms uses presentCount; drops do not free-heal "
            "(av_clock.hpp avDisplayOffsetMs) — better presentation lag proxy"
        ),
        "glass_gt": "tools/avsync_measure_hdmi.py flash↔beep only",
        "src": PROV_MEAS,
    }

    # Verdict logic
    if len(h_drift) < 3 and len(h_disp) < 3:
        return {
            "axis": "AV_RELATION",
            "verdict": "NO-DATA",
            "status": PROV_NODATA,
            "honesty": honesty,
            "saturation": sat,
            "src": PROV_NODATA,
        }

    # If we never saw a degraded FPS portion, we can only say servo looks pinned
    if not split["enough_degraded"]:
        if sat.get("status") == "SATURATED_PINNED_DEADBAND":
            verdict = "SERVO_PINNED_DEADBAND_NO_EVENT"
            note = (
                "healthy portion pins av_drift inside Hold deadband; no FPS-degraded "
                "windows in this log to test unlock. NOT a lipsync PASS. NOT proof of "
                "sustained health across the intermittent 25% class — need a soak "
                "that includes an event, or HDMI GT."
            )
            usable_unlock = False
        else:
            verdict = "SERVO_SAMPLES_ONLY_NO_EVENT"
            note = "no degraded FPS windows; cannot test unlock climb"
            usable_unlock = False
        return {
            "axis": "AV_RELATION",
            "verdict": verdict,
            "note": note,
            "usable_as_lipsync": False,
            "usable_unlock_test": usable_unlock,
            "honesty": honesty,
            "saturation": sat,
            "healthy_drift_median": statistics.median(h_drift) if h_drift else PROV_NODATA,
            "healthy_drift_median_src": PROV_MEAS if h_drift else PROV_NODATA,
            "degraded_drift_median": PROV_NODATA,
            "climb_ms": PROV_NODATA,
            "climb_thr_ms": climb_thr_ms,
            "climb_thr_ms_src": PROV_DEFAULT,
            "src": PROV_MEAS,
        }

    # Have degraded windows — test unlock
    unlock = False
    reasons = []
    if climb is not None and climb >= climb_thr_ms:
        unlock = True
        reasons.append(f"drift_climb_ms={climb:.1f}>={climb_thr_ms}")
    if disp_climb is not None and disp_climb >= climb_thr_ms:
        unlock = True
        reasons.append(f"display_offset_climb_ms={disp_climb:.1f}>={climb_thr_ms}")

    if unlock:
        verdict = "SERVO_UNLOCK_CLIMB"
    elif sat.get("status") == "SATURATED_PINNED_DEADBAND" and (
        climb is None or abs(climb) < climb_thr_ms
    ):
        # Degraded FPS but drift did not climb — lockstep A/V stall
        verdict = "SERVO_STILL_PINNED_UNDER_FPS_COLLAPSE"
        reasons.append(
            "A/V lockstep stall can keep drift near deadband while both lag wall "
            "(parent audio_s*fps≈frames) — servo OK does NOT mean wall-rate OK"
        )
    else:
        verdict = "SERVO_RELATION_STABLE"
        reasons.append("no climb above thr")
    return {
        "axis": "AV_RELATION",
        "verdict": verdict,
        "reasons": reasons,
        "usable_as_lipsync": False,
        "usable_unlock_test": True,
        "honesty": honesty,
        "saturation": sat,
        "healthy_drift_median": statistics.median(h_drift) if h_drift else PROV_NODATA,
        "degraded_drift_median": statistics.median(d_drift) if d_drift else PROV_NODATA,
        "climb_ms": climb if climb is not None else PROV_NODATA,
        "climb_ms_src": climb_src,
        "healthy_display_offset_median": (
            statistics.median(h_disp) if h_disp else PROV_NODATA
        ),
        "degraded_display_offset_median": (
            statistics.median(d_disp) if d_disp else PROV_NODATA
        ),
        "display_offset_climb_ms": disp_climb if disp_climb is not None else PROV_NODATA,
        "display_offset_climb_ms_src": disp_climb_src,
        "climb_thr_ms": climb_thr_ms,
        "climb_thr_ms_src": PROV_DEFAULT,
        "lead_ms": lead_ms if lead_ms is not None else PROV_NODATA,
        "lead_ms_src": PROV_MEAS if lead_ms is not None else PROV_NODATA,
        "setpoint_ms": setpoint if setpoint is not None else PROV_NODATA,
        "src": PROV_MEAS,
    }


def geometry_shift(samples: Sequence[MediaSample]) -> Dict[str, Any]:
    geoms = []
    for s in samples:
        if s.decode_w and s.decode_h:
            geoms.append((s.decode_w, s.decode_h, s.wall_s))
    uniq = sorted({(w, h) for w, h, _ in geoms})
    return {
        "n_samples_with_decode": len(geoms),
        "unique_geometries": [f"{w}x{h}" for w, h in uniq],
        "shifted": len(uniq) > 1,
        "note": (
            "bitrate arms can change delivered resolution (parent: request=397→312x240, "
            "2000→624x480). Mid-run shift confounds FPS comparisons."
        ),
        "src": PROV_MEAS if geoms else PROV_NODATA,
    }


def overall_verdict(
    fps: Dict[str, Any],
    sync: Dict[str, Any],
    geom: Dict[str, Any],
    session_invalid: bool,
    inv_reason: str,
) -> Tuple[str, int, List[str]]:
    if session_invalid:
        return "SESSION_INVALID", RC_SESSION, [inv_reason]
    if geom.get("shifted"):
        return "GEOMETRY_SHIFT", RC_GEOM, [f"decode geometries={geom.get('unique_geometries')}"]

    fv = fps.get("verdict")
    sv = sync.get("verdict")
    reasons: List[str] = []

    if fv in (None, "NO-DATA") and sv in (None, "NO-DATA"):
        return "NO-DATA", RC_NO_DATA, ["no interval rates and no drift samples"]

    if fv == "NO-DATA":
        return "INSUFFICIENT_EVIDENCE", RC_INSUFFICIENT, ["fps_axis=NO-DATA"]

    fps_bad = fv == "FPS_COLLAPSE"
    sync_bad = sv == "SERVO_UNLOCK_CLIMB"

    if fps_bad and sync_bad:
        return "BOTH_FPS_AND_SERVO_BAD", RC_BOTH, [
            f"fps={fv}",
            f"sync={sv}",
        ]
    if fps_bad:
        reasons.append(f"fps={fv}")
        if sv:
            reasons.append(f"sync={sv} (informational)")
        return "FPS_COLLAPSE", RC_FPS_COLLAPSE, reasons
    if sync_bad:
        return "SERVO_UNLOCK_CLIMB", RC_SERVO_UNLOCK, [f"sync={sv}", f"fps={fv}"]

    # FPS ok paths
    if fv in ("FPS_OK", "FPS_MARGINAL") and sv in (
        "SERVO_PINNED_DEADBAND_NO_EVENT",
        "SERVO_STILL_PINNED_UNDER_FPS_COLLAPSE",
        "SERVO_RELATION_STABLE",
        "SERVO_SAMPLES_ONLY_NO_EVENT",
    ):
        if fv == "FPS_MARGINAL":
            return "INSUFFICIENT_EVIDENCE", RC_INSUFFICIENT, [
                "fps=FPS_MARGINAL",
                f"sync={sv}",
                "not a lipsync PASS — av_drift pinned≠glass",
            ]
        # Full FPS_OK
        if sv == "SERVO_PINNED_DEADBAND_NO_EVENT":
            return "FPS_OK_SERVO_PINNED_NOT_LIPSYNC", RC_OK, [
                "fps sustained within-run",
                "av_drift pinned at setpoint on healthy portion — NOT lipsync GT",
                "no degradation event in this log to test unlock",
                "intermittent ~25%: absence of event ≠ proof forever",
            ]
        if sv == "SERVO_STILL_PINNED_UNDER_FPS_COLLAPSE":
            # fps_bad already handled; if we are here FPS_OK with this sync is odd
            return "FPS_OK_SERVO_PINNED_NOT_LIPSYNC", RC_OK, [f"sync={sv}"]
        return "FPS_OK_SERVO_STABLE_NOT_LIPSYNC", RC_OK, [
            f"fps={fv}",
            f"sync={sv}",
            "NOT glass lipsync PASS",
        ]

    return "INSUFFICIENT_EVIDENCE", RC_INSUFFICIENT, [f"fps={fv}", f"sync={sv}"]


def analyze(
    text: str,
    *,
    content_fps: Optional[float],
    content_fps_src: str,
    ok_frac: float,
    climb_thr_ms: float,
    prefer_present_window: bool,
) -> Dict[str, Any]:
    samples = parse_log(text)
    inv, inv_reason = continuity_invalid(samples)
    cf = content_fps_from_samples(samples, content_fps, content_fps_src)
    fps_val = float(cf["fps"])

    iv_media = build_intervals_from_media(samples)
    iv_pw = build_intervals_from_present_window(samples)
    if prefer_present_window and len(iv_pw) >= 3:
        ivs = iv_pw
        iv_choice = "present_window"
    elif len(iv_media) >= 3:
        ivs = iv_media
        iv_choice = "reconstructed_media"
    elif len(iv_pw) >= 3:
        ivs = iv_pw
        iv_choice = "present_window"
    else:
        ivs = iv_media or iv_pw
        iv_choice = "sparse"

    last_media = None
    for s in reversed(samples):
        if s.kind == "media" and s.frames is not None:
            last_media = s
            break

    lead = None
    for s in reversed(samples):
        if s.lead_ms is not None:
            lead = float(s.lead_ms)
            break
        if s.setpoint_ms is not None:
            lead = float(-s.setpoint_ms)
            break

    split = split_healthy_degraded(ivs, fps_val, ok_frac=ok_frac)
    fps_axis = score_fps_axis(ivs, fps_val, last_media, ok_frac)
    sync_axis = score_sync_axis(split, lead, climb_thr_ms=climb_thr_ms)
    geom = geometry_shift(samples)

    # present_window class histogram (consume only; w-cpu owns meaning)
    pw_hist: Dict[str, int] = {}
    for s in samples:
        if s.pw_class:
            pw_hist[s.pw_class] = pw_hist.get(s.pw_class, 0) + 1

    cls, rc, reasons = overall_verdict(fps_axis, sync_axis, geom, inv, inv_reason)

    return {
        "verdict": cls,
        "gate_rc": rc,
        "reasons": reasons,
        "content_fps": cf,
        "interval_choice": iv_choice,
        "interval_choice_src": PROV_MEAS,
        "n_media_lines": sum(1 for s in samples if s.kind == "media"),
        "n_present_window_lines": sum(1 for s in samples if s.kind == "present_window"),
        "n_intervals": len(ivs),
        "split": {
            k: split[k]
            for k in split
            if k not in ("healthy", "degraded")
        },
        "fps_axis": fps_axis,
        "sync_axis": sync_axis,
        "geometry": geom,
        "present_window_class_hist": pw_hist if pw_hist else PROV_NODATA,
        "present_window_note": (
            "H-* classes owned by w-cpu present_window.hpp / PRESENT_PROFILE=1; "
            "this tool does not re-classify stall locus"
        ),
        "continuity": {"invalid": inv, "reason": inv_reason, "src": PROV_MEAS},
        "void_endpoints": {
            "supply_ratio_local_vs_path": "VOID — ffmpeg A/V lockstep",
            "av_drift_ms_lipsync": "VOID when servo locked (setpoint deadband)",
            "single_run_AB": "VOID — intermittent ~25%",
            "src": PROV_MEAS,
        },
        "cannot_settle": [
            "glass lipsync without HDMI flash↔beep",
            "H-READ vs H-DDR without PRESENT_PROFILE capture",
            "path capacity vs local limiter via supply_ratio",
            "proof of 'always healthy' from one event-free soak (~25% miss rate)",
        ],
        "pre_reg": PRE_REG,
        "src": PROV_MEAS,
    }


PRE_REG = {
    "H_FPS_OK": {
        "predict": (
            "≥ ok_frac of 1s intervals have iv_vfps ≥ content_fps*ok_frac; "
            "p10 near content_fps"
        ),
        "parent_healthy_anchor": "vfps=23.9 pfps=23.8 drops=14 supply=0.997",
    },
    "H_FPS_COLLAPSE": {
        "predict": (
            "cluster of intervals with iv_vfps≈20 not 24; "
            "never_arrived_frames >> drops (drops only ~7% of short)"
        ),
        "parent_degraded_anchor": (
            "vfps=20.0 pfps=18.6 drops=356 frames=5011 wall=249.8 "
            "short≈984 never_arrived≈628"
        ),
    },
    "H_SERVO_PINNED_HEALTHY": {
        "predict": (
            "healthy-portion av_drift median ≈ -lead (±5) pstdev≤5 → "
            "SATURATED_PINNED_SETPOINT; refuse as lipsync OK"
        ),
    },
    "H_SERVO_UNLOCK_ON_COLLAPSE": {
        "predict": (
            "IF collapse is video-behind-audio: degraded drift median − healthy "
            "≥ +25 ms. IF collapse is lockstep A/V stall: drift may STAY pinned "
            "(SERVO_STILL_PINNED_UNDER_FPS_COLLAPSE) while FPS_COLLAPSE fires — "
            "that is a HIT for lockstep, not a miss of unlock."
        ),
        "parent_hint": "av_drift climbed -22→+56→+81 on some collapses",
    },
    "H_PRESENT_WINDOW": {
        "predict": (
            "with PRESENT_PROFILE=1, degraded seconds majority H-READ or H-DDR "
            "not H-PACER-only (pacer-only falsified by supply/vfps lockstep)"
        ),
        "owner": "w-cpu present_window — this tool only histograms classes",
    },
    "MISS_RULE": (
        "Publish miss if FPS_OK while session short_frames>>drops without "
        "startup-only explanation; or if SERVO_UNLOCK claimed while climb_ms "
        "NO-DATA; or if lipsync PASS printed from av_drift alone."
    ),
}


def print_report(doc: Dict[str, Any]) -> None:
    print("=== avsync_within_run ===")
    print(f"VERDICT={doc['verdict']} gate_rc={doc['gate_rc']}")
    print(
        "severity: 0=FPS_OK_*_NOT_LIPSYNC 2=FPS_COLLAPSE 3=SERVO_UNLOCK "
        "4=BOTH 5=GEOM 78=INSUFFICIENT 79=SESSION 77=NO-DATA"
    )
    for r in doc.get("reasons", []):
        print(f"reason: {r}")
    print("--- content_fps ---")
    print(json.dumps(doc.get("content_fps"), indent=2, sort_keys=True))
    print("--- fps_axis ---")
    print(json.dumps(doc.get("fps_axis"), indent=2, sort_keys=True))
    print("--- sync_axis (NOT lipsync GT) ---")
    print(json.dumps(doc.get("sync_axis"), indent=2, sort_keys=True))
    print("--- geometry ---")
    print(json.dumps(doc.get("geometry"), indent=2, sort_keys=True))
    print("--- split ---")
    print(json.dumps(doc.get("split"), indent=2, sort_keys=True))
    print("--- present_window_class_hist (w-cpu owned) ---")
    print(json.dumps(doc.get("present_window_class_hist"), indent=2, sort_keys=True))
    print("--- void_endpoints ---")
    print(json.dumps(doc.get("void_endpoints"), indent=2, sort_keys=True))
    print("--- CANNOT_SETTLE ---")
    for x in doc.get("cannot_settle", []):
        print(f"  - {x}")
    print("--- PRE_REG ---")
    print(json.dumps(doc.get("pre_reg"), indent=2, sort_keys=True))


# --- fixtures / self-test -------------------------------------------------------

def _synth_media_line(
    *,
    wall: float,
    frames: int,
    presents: int,
    drops: int,
    audio_s: float,
    drift: int,
    lead: int = 40,
    decode: str = "624x480",
    epoch: str = "1.1",
    disp: Optional[int] = None,
) -> str:
    sp = -lead
    margin = drift + lead
    do = disp if disp is not None else drift
    return (
        f"media: frames={frames} presents={presents} drops={drops} "
        f"publish_misses=0 residual={frames-presents-drops} "
        f"audio_s={audio_s:.3f} wall_s={wall:.3f} "
        f"av_drift_ms={drift} av_servo_error_ms={drift} "
        f"av_servo_setpoint_ms={sp} av_servo_margin_ms={margin} lead_ms={lead} "
        f"av_display_offset_ms={do} av_pipe_ahead_ms=0 "
        f"av_drift_role=servo_error_not_lipsync "
        f"fps=24/1 decode={decode} session_epoch={epoch} pid=100"
    )


def fixture_healthy(n: int = 40) -> str:
    """~24 fps, drift pinned at -32 (lead=40 deadband)."""
    lines = []
    for i in range(n):
        wall = 5.0 + i * 1.0
        frames = int(round(24.0 * wall))
        presents = frames - 1
        drops = 1
        audio = wall * 0.997
        lines.append(
            _synth_media_line(
                wall=wall,
                frames=frames,
                presents=presents,
                drops=drops,
                audio_s=audio,
                drift=-32,
            )
        )
    return "\n".join(lines) + "\n"


def fixture_degraded_lockstep(n_h: int = 20, n_d: int = 20) -> str:
    """Healthy then collapse to ~20 fps; drift STAYS pinned (lockstep stall)."""
    lines = []
    frames = int(24 * 5)
    drops = 2
    for i in range(n_h):
        wall = 5.0 + i * 1.0
        frames = int(round(24.0 * wall))
        lines.append(
            _synth_media_line(
                wall=wall,
                frames=frames,
                presents=frames - drops,
                drops=drops,
                audio_s=wall * 0.995,
                drift=-30,
            )
        )
    # collapse: 20 fps from wall base
    wall0 = 5.0 + n_h
    f0 = int(round(24.0 * wall0))
    for j in range(n_d):
        wall = wall0 + (j + 1) * 1.0
        frames = f0 + int(round(20.0 * (j + 1)))
        drops = 2 + int(0.15 * (j + 1) * 20)  # some pacer drops
        audio = wall * 0.837  # lockstep-ish cumulative
        # keep drift pinned — lockstep A/V
        lines.append(
            _synth_media_line(
                wall=wall,
                frames=frames,
                presents=frames - drops,
                drops=drops,
                audio_s=audio,
                drift=-28,
            )
        )
    return "\n".join(lines) + "\n"


def fixture_degraded_unlock(n_h: int = 20, n_d: int = 20) -> str:
    """Healthy then collapse with drift climb (video behind audio)."""
    lines = []
    for i in range(n_h):
        wall = 5.0 + i * 1.0
        frames = int(round(24.0 * wall))
        lines.append(
            _synth_media_line(
                wall=wall,
                frames=frames,
                presents=frames - 1,
                drops=1,
                audio_s=wall * 0.995,
                drift=-32,
                disp=-32,
            )
        )
    wall0 = 5.0 + n_h
    f0 = int(round(24.0 * wall0))
    for j in range(n_d):
        wall = wall0 + (j + 1) * 1.0
        frames = f0 + int(round(20.0 * (j + 1)))
        drops = 2 + j * 2
        # audio keeps closer to wall than video content → drift climbs
        audio = wall * 0.95
        drift = -32 + int(4 * (j + 1))  # climbs toward +48
        disp = drift + 10
        lines.append(
            _synth_media_line(
                wall=wall,
                frames=frames,
                presents=frames - drops,
                drops=drops,
                audio_s=audio,
                drift=drift,
                disp=disp,
            )
        )
    return "\n".join(lines) + "\n"


def fixture_geom_shift() -> str:
    lines = []
    for i in range(10):
        wall = 5.0 + i
        frames = int(24 * wall)
        lines.append(
            _synth_media_line(
                wall=wall,
                frames=frames,
                presents=frames,
                drops=0,
                audio_s=wall,
                drift=-30,
                decode="312x240",
            )
        )
    for i in range(10, 20):
        wall = 5.0 + i
        frames = int(24 * wall)
        lines.append(
            _synth_media_line(
                wall=wall,
                frames=frames,
                presents=frames,
                drops=0,
                audio_s=wall,
                drift=-30,
                decode="624x480",
            )
        )
    return "\n".join(lines) + "\n"


def fixture_respawn() -> str:
    a = fixture_healthy(10)
    b = fixture_healthy(10).replace("session_epoch=1.1", "session_epoch=2.2").replace(
        "pid=100", "pid=200"
    )
    return a + b


def fixture_parent_anchors() -> str:
    """Sparse two-point anchors matching parent session totals (interval weak)."""
    # Build dense 1 Hz from parent-like rates instead
    lines = []
    # 30 s healthy 24 fps
    for i in range(30):
        wall = 10.0 + i
        frames = int(round(23.9 * wall))
        lines.append(
            _synth_media_line(
                wall=wall,
                frames=frames,
                presents=int(round(23.8 * wall)),
                drops=max(0, frames - int(round(23.8 * wall))),
                audio_s=wall * 0.997,
                drift=-30,
            )
        )
    # 40 s degraded ~20 fps
    wall0 = 40.0
    f0 = int(round(23.9 * wall0))
    p0 = int(round(23.8 * wall0))
    d0 = f0 - p0
    for j in range(40):
        wall = wall0 + (j + 1)
        frames = f0 + int(round(20.0 * (j + 1)))
        presents = p0 + int(round(18.6 * (j + 1)))
        drops = d0 + int(round(1.4 * (j + 1)))  # pfps gap
        lines.append(
            _synth_media_line(
                wall=wall,
                frames=frames,
                presents=presents,
                drops=drops,
                audio_s=wall * 0.837,
                drift=-28 + (j // 5),  # mild climb
            )
        )
    return "\n".join(lines) + "\n"


def self_test() -> int:
    fails = 0

    def check(cond: bool, msg: str) -> None:
        nonlocal fails
        if not cond:
            print(f"FAIL {msg}", file=sys.stderr)
            fails += 1
        else:
            print(f"PASS {msg}")

    # 1) healthy → FPS ok, servo pinned, rc=0, NOT lipsync
    d = analyze(
        fixture_healthy(),
        content_fps=24.0,
        content_fps_src=PROV_CALLER,
        ok_frac=0.95,
        climb_thr_ms=25.0,
        prefer_present_window=False,
    )
    check(d["gate_rc"] == RC_OK, f"healthy rc=0 got {d['gate_rc']} {d['verdict']}")
    check(d["fps_axis"]["verdict"] == "FPS_OK", f"healthy fps {d['fps_axis']['verdict']}")
    check(
        d["sync_axis"]["verdict"] == "SERVO_PINNED_DEADBAND_NO_EVENT",
        f"healthy sync {d['sync_axis']['verdict']}",
    )
    check(
        d["sync_axis"].get("usable_as_lipsync") is False,
        "healthy must not claim lipsync",
    )
    check(
        d["sync_axis"]["saturation"]["status"] == "SATURATED_PINNED_DEADBAND",
        f"sat {d['sync_axis']['saturation']}",
    )
    check(
        "NOT_LIPSYNC" in d["verdict"] or d["verdict"].endswith("NOT_LIPSYNC"),
        f"healthy verdict names not-lipsync got {d['verdict']}",
    )

    # 2) lockstep collapse → FPS_COLLAPSE, servo may stay pinned
    d2 = analyze(
        fixture_degraded_lockstep(),
        content_fps=24.0,
        content_fps_src=PROV_CALLER,
        ok_frac=0.95,
        climb_thr_ms=25.0,
        prefer_present_window=False,
    )
    check(
        d2["gate_rc"] == RC_FPS_COLLAPSE,
        f"lockstep collapse rc=2 got {d2['gate_rc']} {d2['verdict']}",
    )
    check(
        d2["fps_axis"]["verdict"] == "FPS_COLLAPSE",
        f"lockstep fps {d2['fps_axis']['verdict']}",
    )
    check(
        d2["sync_axis"]["verdict"]
        in ("SERVO_STILL_PINNED_UNDER_FPS_COLLAPSE", "SERVO_RELATION_STABLE"),
        f"lockstep sync {d2['sync_axis']['verdict']}",
    )

    # 3) unlock climb → SERVO_UNLOCK or BOTH
    d3 = analyze(
        fixture_degraded_unlock(),
        content_fps=24.0,
        content_fps_src=PROV_CALLER,
        ok_frac=0.95,
        climb_thr_ms=25.0,
        prefer_present_window=False,
    )
    check(
        d3["gate_rc"] in (RC_SERVO_UNLOCK, RC_BOTH, RC_FPS_COLLAPSE),
        f"unlock rc in 2|3|4 got {d3['gate_rc']} {d3['verdict']}",
    )
    check(
        d3["sync_axis"]["verdict"] == "SERVO_UNLOCK_CLIMB"
        or d3["gate_rc"] == RC_BOTH,
        f"unlock sync {d3['sync_axis']['verdict']}",
    )
    climb = d3["sync_axis"].get("climb_ms")
    check(
        isinstance(climb, (int, float)) and climb >= 25.0,
        f"climb_ms>={25} got {climb}",
    )

    # 4) geometry shift
    d4 = analyze(
        fixture_geom_shift(),
        content_fps=24.0,
        content_fps_src=PROV_CALLER,
        ok_frac=0.95,
        climb_thr_ms=25.0,
        prefer_present_window=False,
    )
    check(d4["gate_rc"] == RC_GEOM, f"geom rc=5 got {d4['gate_rc']}")

    # 5) respawn
    d5 = analyze(
        fixture_respawn(),
        content_fps=24.0,
        content_fps_src=PROV_CALLER,
        ok_frac=0.95,
        climb_thr_ms=25.0,
        prefer_present_window=False,
    )
    check(d5["gate_rc"] == RC_SESSION, f"respawn rc=79 got {d5['gate_rc']}")

    # 6) parent-shaped soak
    d6 = analyze(
        fixture_parent_anchors(),
        content_fps=24.0,
        content_fps_src=PROV_CALLER,
        ok_frac=0.95,
        climb_thr_ms=25.0,
        prefer_present_window=False,
    )
    check(
        d6["fps_axis"]["verdict"] == "FPS_COLLAPSE",
        f"parent-shaped fps {d6['fps_axis']['verdict']}",
    )
    check(d6["gate_rc"] in (RC_FPS_COLLAPSE, RC_BOTH), f"parent-shaped rc {d6['gate_rc']}")
    # deficit never_arrived path exists when drops present
    def_ = d6["fps_axis"].get("deficit") or {}
    check(def_.get("short_frames") not in (None, PROV_NODATA), f"deficit {def_}")

    # 7) empty
    d7 = analyze(
        "",
        content_fps=24.0,
        content_fps_src=PROV_CALLER,
        ok_frac=0.95,
        climb_thr_ms=25.0,
        prefer_present_window=False,
    )
    check(d7["gate_rc"] == RC_NO_DATA, f"empty rc=77 got {d7['gate_rc']}")

    # 8) supply_ratio not in pass criteria
    check(
        "supply_ratio" not in json.dumps(d["reasons"]),
        "supply_ratio must not drive healthy reasons",
    )

    if fails:
        print(f"self_test FAIL count={fails}", file=sys.stderr)
        return 1
    print(
        "self_test OK within-run "
        "(healthy rc=0 pinned-not-lipsync, lockstep FPS_COLLAPSE rc=2, "
        "unlock climb, geom 5, respawn 79, empty 77)"
    )
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("--daemon-log", help="misterplexd log with media: lines")
    ap.add_argument(
        "--content-fps",
        type=float,
        default=None,
        help="content frame rate (prefer measured PMS/ffprobe)",
    )
    ap.add_argument(
        "--content-fps-src",
        default=PROV_DEFAULT,
        help="measured | caller_supplied | DEFAULT_ASSUMED",
    )
    ap.add_argument(
        "--ok-frac",
        type=float,
        default=0.95,
        help="fraction of windows that must meet content_fps*ok_frac (DEFAULT_ASSUMED)",
    )
    ap.add_argument(
        "--climb-thr-ms",
        type=float,
        default=25.0,
        help="degraded−healthy drift median climb for SERVO_UNLOCK (DEFAULT_ASSUMED)",
    )
    ap.add_argument(
        "--prefer-present-window",
        action="store_true",
        help="prefer PRESENT_PROFILE d_frames intervals when ≥3 lines",
    )
    ap.add_argument("--json-out", type=Path, default=None)
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()

    if args.self_test:
        return self_test()

    if not args.daemon_log:
        print("need --daemon-log or --self-test", file=sys.stderr)
        return RC_NO_DATA

    text = Path(args.daemon_log).read_text(errors="replace")
    src = args.content_fps_src
    if args.content_fps is not None and src == PROV_DEFAULT:
        src = PROV_CALLER
    doc = analyze(
        text,
        content_fps=args.content_fps,
        content_fps_src=src,
        ok_frac=args.ok_frac,
        climb_thr_ms=args.climb_thr_ms,
        prefer_present_window=args.prefer_present_window,
    )
    if args.json_out:
        args.json_out.parent.mkdir(parents=True, exist_ok=True)
        args.json_out.write_text(json.dumps(doc, indent=2, sort_keys=True) + "\n")
        doc["json_out"] = str(args.json_out)
    print_report(doc)
    return int(doc["gate_rc"])


if __name__ == "__main__":
    sys.exit(main())
