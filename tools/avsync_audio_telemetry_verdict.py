#!/usr/bin/env python3
"""A/V + drop verdict from AUDIO + DAEMON TELEMETRY (pixels optional).

WHY (parent 2026-08-02)
-----------------------
User: verify framerate and audio sync on 480p; frames look dropped.
Parent measured real collapse (supply_ratio 0.599, drops=1065, av_drift +56…+81)
while clock stayed av-lock-looking. HDMI grabber may be pixel-blind
(Pixelclock 0 Hz). PMS Docker on the agent host contaminates *transcode* runs
(complete=0 speed=0 vs healthy complete=1 speed=19.8) — prefer DIRECT-PLAY
fixtures and always publish concurrent host load.

This tool does NOT treat daemon av_drift_ms as lipsync ground truth.
av_drift_ms is servo error (av_clock.hpp avDecide / AV_PRESENT_LEAD_MS pin).

WHAT IT CAN SETTLE (audio + telemetry)
--------------------------------------
1. supply_ratio starvation class (Δaudio_s/Δwall_s or cumulative endpoints)
2. drops vs publish_misses vs residual free ledger — with CODE semantics
3. Whether audio markers (1 kHz beep every marker_period) arrive at designed rate
4. Whether av_drift_ms is climbing during collapse (telemetry fact, NOT lipsync)
5. content fps from ffprobe of fixture (measured) or PMS frameRate (caller_supplied)

WHAT IT CANNOT SETTLE (printed every run)
-----------------------------------------
- Glass lipsync offset without flash+video capture (PIXELS_REQUIRED)
- Whether a drop was "visible judder" (needs inter-frame instrument / w-instr)
- Path capacity vs PMS throttle (needs external bulk-pull / w-cpu-1)
- Anything about a transcoder-starved run as a device defect (host-load confound)

SIGN (when optional flash video present)
  offset_ms = (t_beep - t_flash)*1000; + = audio LATE

Exit codes (capture DIRECTLY — never through a pipe):
  0  PASS — ALL required axes have DATA and each axis ok (see coverage)
  2  STARVED — supply axis DATA and ratio < ok_min (only if coverage complete)
  3  PACER_DROPS — ledger DATA and pacer drops dominate
  4  AUDIO_MARKER_FAIL — markers axis DATA and cadence fail
  5  SERVO_DRIFT_CLIMB — drift axis DATA and climbing under starvation
  6  DESIGNED_OFFSET_DETECT — fixture sensitivity only (not session health)
  78 INSUFFICIENT_EVIDENCE — ANY required axis is NO-DATA. NEVER a pass.
     (rd-review: tool printed PASS while markers=NO-DATA — illegitimate)
  79 SESSION_INVALID — epoch/pid change (w-instr RC_SESSION_INVALID=79)
  77 NO-DATA — zero axes have any data (never a pass)

AXES (coverage declared every run — one axis never carries another's name)
-------------------------------------------------------------------------
  audio_markers   A/V cadence axis. NO-DATA ⇒ av_sync_verdict=INSUFFICIENT
                  regardless of supply (PASS on supply alone is void).
  supply_ratio    Throughput axis ONLY. **VOID_ENDPOINT for local-vs-path /
                  socket-starved vs video-consumer-blocked** — both stall
                  ffmpeg and collapse audio_s lockstep with frames (parent:
                  audio_s*fps ≈ frames within 0.15%). Tag always printed.
  ledger          frames+presents+drops closed residual (w-instr owns split
                  reconstructor). NO-DATA ⇒ insufficient.
  av_drift_servo  Servo error axis (NOT lipsync GT). NO-DATA ⇒ insufficient
                  for overall PASS of this multi-axis instrument.

PASS requires every required axis status != NO-DATA and each axis ok.
supply_ratio healthy NEVER upgrades av_sync_verdict when markers missing.

Red-before-green:
  python3 tools/avsync_audio_telemetry_verdict.py --self-test
  echo "true rc=$?"
"""
from __future__ import annotations

import argparse
import json
import math
import re
import struct
import subprocess
import sys
import wave
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence, Tuple


# --- provenance helpers -------------------------------------------------------

def tag(v: Any, src: str) -> Dict[str, Any]:
    return {"value": v, "src": src}


# --- drops semantics (quoted product path) ------------------------------------

DROPS_SEMANTICS = {
    "drops": {
        "counter": "droppedFrames_",
        "increments": "media_player.cpp present loop when avDecide returns Drop "
        "(!present path): droppedFrames_.fetch_add(1) ~:4183-4185",
        "reset": "media_player.cpp play-path droppedFrames_.store(0) ~:3010 "
        "(NOT silence-scan ~:2312; parent citation fix)",
        "means": "deliberate A/V-pacer skip of presentCleanFrame — NOT ffmpeg "
        "decode shortfall, NOT DDR publish fail",
        "does_not_mean": "frame never decoded; glass judder; network drop",
    },
    "publish_misses": {
        "counter": "publishMisses_",
        "increments": "media_player.cpp presentCleanFrame when DDR/FPGA publish "
        "fails: publishMisses_.fetch_add(1) ~:3641",
        "reset": "media_player.cpp play-path publishMisses_.store(0) ~:3011",
        "means": "present was attempted; arm publish failed",
    },
    "residual": {
        "eq": "frames - presents - drops",
        "source": "frame_ledger.hpp frameLedgerResidual",
        "note": "does not subtract publish_misses by identity; when every "
        "non-present is pacer-drop or publish-miss, residual == publish_misses",
    },
    "av_drift_ms": {
        "eq": "audioMs - frameContentMs(frameIndex)",
        "source": "av_clock.hpp avDriftMs; product store after avDecide",
        "role": "servo_error_not_lipsync — Hold while drift+lead<0 pins steady "
        "readout near -AV_PRESENT_LEAD_MS; cannot witness glass lipsync",
    },
}


# --- Goertzel beep detect (minimal; same idea as avsync_measure_hdmi) ---------

def goertzel_power(block: Sequence[float], sr: int, freq: float) -> float:
    n = len(block)
    if n <= 0:
        return 0.0
    k = int(0.5 + (n * freq) / sr)
    w = (2.0 * math.pi * k) / n
    coeff = 2.0 * math.cos(w)
    s0 = s1 = s2 = 0.0
    for x in block:
        s0 = x + coeff * s1 - s2
        s2 = s1
        s1 = s0
    return s1 * s1 + s2 * s2 - coeff * s1 * s2


def detect_beeps(
    samples: Sequence[float],
    sr: int,
    *,
    beep_hz: float = 1000.0,
    win_ms: float = 20.0,
    hop_ms: float = 5.0,
    min_separation_s: float = 0.40,
) -> Tuple[List[float], Dict[str, Any]]:
    win = max(8, int(sr * win_ms / 1000.0))
    hop = max(1, int(sr * hop_ms / 1000.0))
    energy: List[float] = []
    times: List[float] = []
    i = 0
    while i + win <= len(samples):
        block = samples[i : i + win]
        energy.append(goertzel_power(block, sr, beep_hz))
        times.append(i / float(sr))
        i += hop
    meta: Dict[str, Any] = {
        "n_windows": len(energy),
        "win_ms": win_ms,
        "hop_ms": hop_ms,
        "beep_hz": beep_hz,
        "beep_hz_src": "caller_supplied" if beep_hz != 1000.0 else "DEFAULT_ASSUMED",
    }
    if not energy:
        meta["n_beeps"] = 0
        meta["reason"] = "no_audio_windows"
        return [], meta
    peak = max(energy)
    # robust floor: median of lower half
    sorted_e = sorted(energy)
    floor = sorted_e[max(0, len(sorted_e) // 4)]
    contrast = peak / floor if floor > 1e-12 else float("inf")
    thr = floor + 0.35 * (peak - floor) if peak > floor else peak * 0.5
    meta["goertzel_floor"] = floor
    meta["goertzel_peak"] = peak
    meta["goertzel_contrast"] = contrast
    meta["goertzel_thr"] = thr
    meta["thr_src"] = "measured_from_energy_distribution"
    onsets: List[float] = []
    above = False
    for t, e in zip(times, energy):
        if e >= thr and not above:
            if not onsets or (t - onsets[-1]) >= min_separation_s:
                onsets.append(t)
            above = True
        elif e < thr * 0.7:
            above = False
    meta["n_beeps"] = len(onsets)
    meta["n_beeps_src"] = "measured"
    return onsets, meta


def load_wav_mono(path: Path) -> Tuple[List[float], int]:
    with wave.open(str(path), "rb") as w:
        sr = w.getframerate()
        ch = w.getnchannels()
        n = w.getnframes()
        raw = w.readframes(n)
        if w.getsampwidth() != 2:
            raise SystemExit(f"need S16_LE wav, got sampwidth={w.getsampwidth()}")
        ints = struct.unpack("<" + "h" * (len(raw) // 2), raw)
        if ch == 1:
            samples = [x / 32768.0 for x in ints]
        else:
            samples = []
            for i in range(0, len(ints), ch):
                samples.append(sum(ints[i : i + ch]) / (ch * 32768.0))
        return samples, sr


def extract_audio_wav(media: Path, out_wav: Path) -> None:
    out_wav.parent.mkdir(parents=True, exist_ok=True)
    cmd = [
        "ffmpeg",
        "-y",
        "-hide_banner",
        "-loglevel",
        "error",
        "-i",
        str(media),
        "-vn",
        "-ac",
        "1",
        "-ar",
        "48000",
        "-f",
        "wav",
        str(out_wav),
    ]
    subprocess.check_call(cmd)


# --- ffprobe fps (measured) ---------------------------------------------------

def ffprobe_video(path: Path) -> Dict[str, Any]:
    cmd = [
        "ffprobe",
        "-v",
        "error",
        "-show_entries",
        "format=duration:stream=codec_type,width,height,r_frame_rate,avg_frame_rate,nb_frames",
        "-of",
        "json",
        str(path),
    ]
    p = subprocess.run(cmd, capture_output=True, text=True)
    if p.returncode != 0:
        return {"ok": False, "error": p.stderr.strip(), "fps_src": "NO-DATA"}
    doc = json.loads(p.stdout)
    vs = [s for s in doc.get("streams", []) if s.get("codec_type") == "video"]
    if not vs:
        return {"ok": False, "error": "no_video_stream", "fps_src": "NO-DATA"}
    v = vs[0]
    r = v.get("r_frame_rate") or "0/0"
    num, den = 0.0, 1.0
    if "/" in r:
        a, b = r.split("/", 1)
        num, den = float(a), float(b) if float(b) else 1.0
    fps = num / den if den else None
    dur = float(doc.get("format", {}).get("duration") or 0.0) or None
    nb = v.get("nb_frames")
    nb_i = int(nb) if nb and str(nb).isdigit() else None
    fps_from_count = None
    fps_from_count_src = "NO-DATA"
    if nb_i and dur and dur > 0:
        fps_from_count = nb_i / dur
        fps_from_count_src = "measured"
    return {
        "ok": True,
        "width": v.get("width"),
        "height": v.get("height"),
        "r_frame_rate": r,
        "fps": fps,
        "fps_src": "measured",
        "duration_s": dur,
        "duration_src": "measured" if dur else "NO-DATA",
        "nb_frames": nb_i,
        "fps_from_nb_duration": fps_from_count,
        "fps_from_nb_duration_src": fps_from_count_src,
    }


# --- daemon log parse ---------------------------------------------------------

RE_MEDIA = re.compile(r"\bmedia:")
RE_F = re.compile(r"\bframes=(?P<v>\d+)")
RE_P = re.compile(r"\bpresents=(?P<v>\d+)")
RE_D = re.compile(r"\bdrops=(?P<v>\d+)")
RE_M = re.compile(r"\bpublish_misses=(?P<v>\d+)")
RE_R = re.compile(r"\bresidual=(?P<v>-?\d+)")
RE_A = re.compile(r"\baudio_s=(?P<v>[0-9.]+)")
RE_W = re.compile(r"\bwall_s=(?P<v>[0-9.]+)")
RE_SR = re.compile(r"\bsupply_ratio=(?P<v>NO-DATA|[0-9.]+)")
RE_DR = re.compile(r"\bav_drift_ms=(?P<v>-?\d+)")
RE_VFPS = re.compile(r"\bvfps=(?P<v>[0-9.]+)")
RE_PFPS = re.compile(r"\bpfps=(?P<v>[0-9.]+)")
RE_EPOCH = re.compile(r"\bsession_epoch=(?P<v>\S+)")
RE_PE = re.compile(r"\bprocess_epoch=(?P<v>\d+)")
RE_PID = re.compile(r"\bpid=(?P<v>\d+)")
RE_FPS = re.compile(r"\bfps=(?P<n>\d+)/(?P<d>\d+)")


@dataclass
class MediaHit:
    line_no: int
    frames: Optional[int] = None
    presents: Optional[int] = None
    drops: Optional[int] = None
    publish_misses: Optional[int] = None
    residual: Optional[int] = None
    audio_s: Optional[float] = None
    wall_s: Optional[float] = None
    supply_ratio: Optional[float] = None
    av_drift_ms: Optional[int] = None
    vfps: Optional[float] = None
    pfps: Optional[float] = None
    session_epoch: Optional[str] = None
    process_epoch: Optional[str] = None
    pid: Optional[str] = None
    fps_num: Optional[int] = None
    fps_den: Optional[int] = None


def parse_media(text: str) -> List[MediaHit]:
    hits: List[MediaHit] = []
    for i, line in enumerate(text.splitlines(), 1):
        if not RE_MEDIA.search(line):
            continue
        if "supply_bucket" in line or "session end" in line:
            continue
        if "A/V resync drop" in line:
            continue
        # Split DDR heartbeat lines are owned by w-instr daemon_media_ledger.py.
        # Including them here false-trips frames_reset (stats frames=699 vs DDR 676)
        # and invents a second reconstructor — refuse; leave presents NO-DATA.
        if "fpga frame_tx" in line or "frame_tx ok" in line:
            continue
        h = MediaHit(line_no=i)
        for rx, attr, cast in (
            (RE_F, "frames", int),
            (RE_P, "presents", int),
            (RE_D, "drops", int),
            (RE_M, "publish_misses", int),
            (RE_R, "residual", int),
            (RE_A, "audio_s", float),
            (RE_W, "wall_s", float),
            (RE_DR, "av_drift_ms", int),
            (RE_VFPS, "vfps", float),
            (RE_PFPS, "pfps", float),
        ):
            m = rx.search(line)
            if m:
                setattr(h, attr, cast(m.group("v")))
        sm = RE_SR.search(line)
        if sm and sm.group("v") != "NO-DATA":
            try:
                h.supply_ratio = float(sm.group("v"))
            except ValueError:
                pass
        em = RE_EPOCH.search(line)
        if em:
            h.session_epoch = em.group("v")
        pm = RE_PE.search(line)
        if pm:
            h.process_epoch = pm.group("v")
        pidm = RE_PID.search(line)
        if pidm:
            h.pid = pidm.group("v")
        fm = RE_FPS.search(line)
        if fm:
            h.fps_num = int(fm.group("n"))
            h.fps_den = int(fm.group("d"))
        if h.frames is not None and h.presents is not None and h.drops is not None:
            h.residual = h.frames - h.presents - h.drops
        hits.append(h)
    return hits


def continuity_invalid(hits: List[MediaHit]) -> Tuple[bool, str]:
    epochs = {h.session_epoch for h in hits if h.session_epoch}
    peps = {h.process_epoch for h in hits if h.process_epoch}
    pids = {h.pid for h in hits if h.pid}
    if len(epochs) > 1:
        return True, f"session_epoch_changed {sorted(epochs)}"
    if len(peps) > 1:
        return True, f"process_epoch_changed {sorted(peps)}"
    if len(pids) > 1:
        return True, f"pid_changed {sorted(pids)}"
    prev_w = prev_f = None
    for h in hits:
        if h.wall_s is not None:
            if prev_w is not None and h.wall_s + 0.05 < prev_w:
                return True, f"wall_s_reset {prev_w}->{h.wall_s}"
            prev_w = h.wall_s
        if h.frames is not None:
            if prev_f is not None and h.frames < prev_f:
                return True, f"frames_reset {prev_f}->{h.frames}"
            prev_f = h.frames
    return False, "continuous"


def window_supply(hits: List[MediaHit]) -> Tuple[Optional[float], str]:
    for h in reversed(hits):
        if h.supply_ratio is not None:
            return h.supply_ratio, "measured_from_media_line"
    aw = [(h.audio_s, h.wall_s) for h in hits if h.audio_s is not None and h.wall_s is not None]
    if len(aw) >= 2:
        a0, w0 = aw[0]
        a1, w1 = aw[-1]
        dw = w1 - w0
        da = a1 - a0
        if dw >= 0.40 and da >= 0.0:
            return da / dw, "reconstructed_window_endpoints"
    if len(aw) == 1 and aw[0][1] and aw[0][1] >= 3.0:
        return aw[0][0] / aw[0][1], "cumulative_single_line"
    return None, "NO-DATA"


def last_ledger(hits: List[MediaHit]) -> Dict[str, Any]:
    """Prefer last line that can close residual; else last stats-ish line.

    Does NOT reconstruct across split stats/DDR lines — that is w-instr
    tools/daemon_media_ledger.py. Unclosable → presents/residual stay NO-DATA.
    """
    # Prefer atomic (frames+presents+drops)
    for h in reversed(hits):
        if (
            h.frames is not None
            and h.presents is not None
            and h.drops is not None
        ):
            resid = h.frames - h.presents - h.drops
            return {
                "frames": h.frames,
                "presents": h.presents,
                "drops": h.drops,
                "publish_misses": h.publish_misses
                if h.publish_misses is not None
                else "NO-DATA",
                "residual": resid,
                "residual_src": "measured",
                "residual_eq": "frames-presents-drops",
                "ledger_closable": True,
                "vfps": h.vfps if h.vfps is not None else "NO-DATA",
                "pfps": h.pfps if h.pfps is not None else "NO-DATA",
                "av_drift_ms": h.av_drift_ms if h.av_drift_ms is not None else "NO-DATA",
                "audio_s": h.audio_s,
                "wall_s": h.wall_s,
                "src": "measured",
            }
    # Partial — do not invent presents
    for h in reversed(hits):
        if h.frames is not None or h.drops is not None:
            return {
                "frames": h.frames if h.frames is not None else "NO-DATA",
                "presents": h.presents if h.presents is not None else "NO-DATA",
                "drops": h.drops if h.drops is not None else "NO-DATA",
                "publish_misses": h.publish_misses
                if h.publish_misses is not None
                else "NO-DATA",
                "residual": "NO-DATA",
                "residual_src": "NO-DATA",
                "ledger_closable": False,
                "ledger_note": (
                    "presents missing on stats line — deploy frameLedgerTelemetryFragment "
                    "daemon OR run tools/daemon_media_ledger.py (w-instr) on split logs"
                ),
                "vfps": h.vfps if h.vfps is not None else "NO-DATA",
                "pfps": h.pfps if h.pfps is not None else "NO-DATA",
                "av_drift_ms": h.av_drift_ms if h.av_drift_ms is not None else "NO-DATA",
                "audio_s": h.audio_s,
                "wall_s": h.wall_s,
                "src": "measured_partial",
            }
    return {"src": "NO-DATA", "ledger_closable": False, "residual": "NO-DATA"}

def drift_series(hits: List[MediaHit]) -> List[Tuple[float, int]]:
    out = []
    for h in hits:
        if h.wall_s is not None and h.av_drift_ms is not None:
            out.append((h.wall_s, h.av_drift_ms))
    return out


def drift_slope_ms_per_s(series: List[Tuple[float, int]]) -> Optional[float]:
    if len(series) < 4:
        return None
    # simple least squares
    xs = [p[0] for p in series]
    ys = [float(p[1]) for p in series]
    n = len(xs)
    mx = sum(xs) / n
    my = sum(ys) / n
    num = sum((x - mx) * (y - my) for x, y in zip(xs, ys))
    den = sum((x - mx) ** 2 for x in xs)
    if den <= 1e-12:
        return None
    return num / den


# --- host load ----------------------------------------------------------------

def read_host_load() -> Dict[str, Any]:
    try:
        with open("/proc/loadavg") as f:
            parts = f.read().split()
        return {
            "load1": float(parts[0]),
            "load5": float(parts[1]),
            "load15": float(parts[2]),
            "src": "measured",
            "note": "host loadavg; PMS-on-same-box confound if load high during cast",
        }
    except OSError as e:
        return {"src": "NO-DATA", "error": str(e)}


# --- marker cadence -----------------------------------------------------------

def marker_stats(onsets: List[float], period_s: float) -> Dict[str, Any]:
    if len(onsets) < 2:
        return {
            "n_intervals": 0,
            "interval_median_s": None,
            "interval_median_src": "NO-DATA",
            "period_err_ms": None,
            "class": "NO-DATA",
        }
    iv = [onsets[i + 1] - onsets[i] for i in range(len(onsets) - 1)]
    ivs = sorted(iv)
    mid = ivs[len(ivs) // 2]
    err_ms = (mid - period_s) * 1000.0
    # allow 30 ms median error on period (capture/jitter)
    ok = abs(err_ms) <= 30.0
    return {
        "n_intervals": len(iv),
        "interval_median_s": mid,
        "interval_median_src": "measured",
        "interval_p95_s": ivs[int(0.95 * (len(ivs) - 1))],
        "interval_max_s": ivs[-1],
        "designed_period_s": period_s,
        "designed_period_src": "caller_supplied",
        "period_err_ms": err_ms,
        "period_err_ms_src": "measured",
        "class": "ok" if ok else "AUDIO_MARKER_FAIL",
    }


def designed_offset_from_onsets(
    onsets: List[float], period_s: float
) -> Dict[str, Any]:
    """Estimate constant offset of beeps vs ideal grid k*period (phase only).

    Without video we cannot get lipsync; we CAN recover a constant phase of the
    beep grid relative to t=0 of the *audio file* (file-aligned fixtures).
    For live HDMI audio, t=0 is capture start — phase is NOT lipsync.
    """
    if len(onsets) < 3:
        return {"offset_ms": None, "src": "NO-DATA", "note": "need>=3 beeps"}
    # fold onsets into [0, period)
    phases = [math.fmod(t, period_s) for t in onsets]
    # circular mean via complex
    ang = [2 * math.pi * (p / period_s) for p in phases]
    re = sum(math.cos(a) for a in ang) / len(ang)
    im = sum(math.sin(a) for a in ang) / len(ang)
    mean_ang = math.atan2(im, re)
    if mean_ang < 0:
        mean_ang += 2 * math.pi
    phase_s = (mean_ang / (2 * math.pi)) * period_s
    # represent as offset in (-period/2, period/2]
    if phase_s > period_s / 2:
        phase_s -= period_s
    return {
        "audio_grid_phase_ms": phase_s * 1000.0,
        "audio_grid_phase_ms_src": "measured",
        "note": "phase of beep grid vs audio-file t=0; NOT glass lipsync; "
        "for file fixtures with beep at k*T+delay, phase≈delay",
    }


# --- classify -----------------------------------------------------------------

REQUIRED_AXES = ("audio_markers", "supply_ratio", "ledger", "av_drift_servo")

@dataclass
class Verdict:
    cls: str
    rc: int
    reasons: List[str] = field(default_factory=list)
    coverage: Dict[str, Any] = field(default_factory=dict)
    axis_verdicts: Dict[str, str] = field(default_factory=dict)


def ledger_closable(ledger: Dict[str, Any]) -> bool:
    """True only when residual = frames-presents-drops is defined (not NO-DATA)."""
    return (
        isinstance(ledger.get("frames"), int)
        and isinstance(ledger.get("presents"), int)
        and isinstance(ledger.get("drops"), int)
    )


def build_coverage(
    *,
    marker: Dict[str, Any],
    supply: Optional[float],
    supply_kind: str,
    ledger: Dict[str, Any],
    drift_last: Any,
    drift_slope: Optional[float],
    wall_s: Optional[float],
    n_media_hits: int,
    n_beeps: int,
) -> Dict[str, Any]:
    """Per-axis coverage declaration — printed every run (rd-review requirement)."""
    mclass = marker.get("class") or "NO-DATA"
    markers_data = mclass not in ("NO-DATA", None, "")
    supply_data = supply is not None
    closed = ledger_closable(ledger)
    drift_data = isinstance(drift_last, int) or (
        isinstance(drift_last, float) and drift_last == drift_last
    )
    if drift_last in (None, "NO-DATA"):
        drift_data = False

    axes = {
        "audio_markers": {
            "status": "DATA" if markers_data else "NO-DATA",
            "class": mclass,
            "n_beeps": n_beeps if markers_data else "NO-DATA",
            "n_beeps_src": "measured" if markers_data else "NO-DATA",
            "window_note": "beep onsets in provided audio capture",
            "names_verdict": "av_sync_verdict",
            "src": "measured" if markers_data else "NO-DATA",
        },
        "supply_ratio": {
            "status": "DATA" if supply_data else "NO-DATA",
            "value": supply if supply_data else "NO-DATA",
            "value_src": supply_kind if supply_data else "NO-DATA",
            "window_s": wall_s if wall_s is not None else "NO-DATA",
            "window_src": "measured" if wall_s is not None else "NO-DATA",
            "n_media_hits": n_media_hits,
            # Parent 2026-08-02: audio_s lockstep with frames — VOID for path vs local
            "discriminator_role": "VOID_ENDPOINT_local_vs_path",
            "discriminator_note": (
                "supply_ratio=Δaudio_s/Δwall_s; audio accrues on ALSA write; "
                "ffmpeg A/V one process — video pipe back-pressure stalls audio "
                "production lockstep (parent: audio_s*fps ≈ frames within 0.15%). "
                "socket-starved and video-consumer-blocked predict the SAME ratio. "
                "Do NOT use supply_ratio to separate those regimes (w-instr recv_q/"
                "wchan owns that). Throughput starvation only."
            ),
            "names_verdict": "supply_verdict",
            "src": "measured" if supply_data else "NO-DATA",
        },
        "ledger": {
            "status": "DATA" if closed else "NO-DATA",
            "closable": closed,
            "frames": ledger.get("frames", "NO-DATA"),
            "presents": ledger.get("presents", "NO-DATA"),
            "drops": ledger.get("drops", "NO-DATA"),
            "residual": ledger.get("residual", "NO-DATA") if closed else "NO-DATA",
            "residual_eq": "frames-presents-drops",
            "split_line_owner": "w-instr tools/daemon_media_ledger.py",
            "names_verdict": "ledger_verdict",
            "src": "measured" if closed else "NO-DATA",
        },
        "av_drift_servo": {
            "status": "DATA" if drift_data else "NO-DATA",
            "last_ms": drift_last if drift_data else "NO-DATA",
            "slope_ms_per_s": drift_slope if drift_slope is not None else "NO-DATA",
            "role": "servo_error_not_lipsync",
            "role_note": (
                "avDriftMs_=audibleClockMs-frameContentMs (media_player store); "
                "leadMs enters avDecide only — bounded error evidences closed loop, "
                "NOT perceived lipsync. Glass GT = flash↔beep when grabber lives."
            ),
            "names_verdict": "servo_verdict",
            "src": "measured" if drift_data else "NO-DATA",
        },
    }
    n_data = sum(1 for a in REQUIRED_AXES if axes[a]["status"] == "DATA")
    n_nodata = len(REQUIRED_AXES) - n_data
    return {
        "axes": axes,
        "required_axes": list(REQUIRED_AXES),
        "n_axes_required": len(REQUIRED_AXES),
        "n_axes_data": n_data,
        "n_axes_nodata": n_nodata,
        "coverage_complete": n_nodata == 0,
        "nodata_axes": [a for a in REQUIRED_AXES if axes[a]["status"] == "NO-DATA"],
        "rule": "ANY required axis NO-DATA ⇒ overall INSUFFICIENT_EVIDENCE rc=78; "
        "one axis never carries a verdict named for another",
        "src": "measured",
    }


def classify(
    *,
    session_invalid: bool,
    supply: Optional[float],
    supply_kind: str = "NO-DATA",
    ok_min: float,
    ledger: Dict[str, Any],
    marker: Dict[str, Any],
    drift_last: Any = "NO-DATA",
    drift_slope: Optional[float],
    designed_offset_ms: Optional[float],
    recovered_phase_ms: Optional[float],
    wall_s: Optional[float],
    n_media_hits: int = 0,
    min_wall_s: float = 5.0,
) -> Verdict:
    """Multi-axis classify. Overall PASS only if coverage complete and all ok.

    rd-review: PASS with markers=NO-DATA while reason=supply_ok is illegitimate.
    """
    n_beeps = 0
    if isinstance(marker.get("n_beeps"), int):
        n_beeps = marker["n_beeps"]
    cov = build_coverage(
        marker=marker,
        supply=supply,
        supply_kind=supply_kind,
        ledger=ledger,
        drift_last=drift_last,
        drift_slope=drift_slope,
        wall_s=wall_s,
        n_media_hits=n_media_hits,
        n_beeps=n_beeps,
    )

    if session_invalid:
        return Verdict(
            "SESSION_INVALID",
            79,
            ["session continuity broken"],
            coverage=cov,
            axis_verdicts={"session": "INVALID"},
        )

    mclass = marker.get("class") or "NO-DATA"
    closed = ledger_closable(ledger)
    has_supply = supply is not None
    has_markers = mclass not in ("NO-DATA", None, "")
    reasons: List[str] = []
    axis_v: Dict[str, str] = {}

    # --- per-axis verdicts (never cross-name) ---
    # audio / A/V
    if not has_markers:
        axis_v["av_sync_verdict"] = "INSUFFICIENT_EVIDENCE"
    elif mclass == "AUDIO_MARKER_FAIL":
        axis_v["av_sync_verdict"] = "AUDIO_MARKER_FAIL"
    elif mclass == "ok":
        axis_v["av_sync_verdict"] = "ok"
    else:
        axis_v["av_sync_verdict"] = str(mclass)

    # supply — throughput only; VOID as local-vs-path discriminator
    if not has_supply:
        axis_v["supply_verdict"] = "NO-DATA"
    elif supply is not None and supply < ok_min:
        drops = ledger.get("drops")
        frames = ledger.get("frames")
        drop_frac = None
        if isinstance(drops, int) and isinstance(frames, int) and frames > 0:
            drop_frac = drops / frames
        if isinstance(drops, int) and drops >= 50 and drop_frac is not None and drop_frac >= 0.15:
            axis_v["supply_verdict"] = "PACER_DROPS"
        else:
            axis_v["supply_verdict"] = "STARVED"
        axis_v["supply_discriminator"] = "VOID_ENDPOINT_local_vs_path"
    else:
        axis_v["supply_verdict"] = "ok_throughput"
        axis_v["supply_discriminator"] = "VOID_ENDPOINT_local_vs_path"

    # ledger
    if not closed:
        axis_v["ledger_verdict"] = "NO-DATA"
    else:
        drops = ledger.get("drops")
        frames = ledger.get("frames")
        resid = ledger.get("residual")
        if isinstance(drops, int) and isinstance(frames, int) and frames >= 100 and drops / frames >= 0.20:
            axis_v["ledger_verdict"] = "PACER_DROPS"
        elif isinstance(resid, int) and resid != 0:
            pm = ledger.get("publish_misses")
            if isinstance(pm, int) and resid == pm:
                axis_v["ledger_verdict"] = "ok_residual_eq_publish_misses"
            else:
                axis_v["ledger_verdict"] = "RESIDUAL_NONZERO"
        else:
            axis_v["ledger_verdict"] = "ok"

    # servo drift
    drift_data = cov["axes"]["av_drift_servo"]["status"] == "DATA"
    if not drift_data:
        axis_v["servo_verdict"] = "NO-DATA"
    elif (
        has_supply
        and supply is not None
        and supply < ok_min
        and drift_slope is not None
        and drift_slope > 0.5
    ):
        axis_v["servo_verdict"] = "SERVO_DRIFT_CLIMB"
    else:
        axis_v["servo_verdict"] = "servo_bounded_NOT_lipsync"

    # designed offset — instrument sensitivity (not session health / not overall PASS)
    if (
        designed_offset_ms is not None
        and recovered_phase_ms is not None
        and abs(designed_offset_ms) >= 40.0
    ):
        if abs(recovered_phase_ms - designed_offset_ms) <= 25.0:
            return Verdict(
                "DESIGNED_OFFSET_DETECT",
                6,
                [
                    f"recovered_phase_ms={recovered_phase_ms:.2f} "
                    f"≈ designed_offset_ms={designed_offset_ms:.2f} "
                    f"(instrument sensitivity OK; not session A/V PASS)"
                ],
                coverage=cov,
                axis_verdicts=axis_v,
            )
        reasons.append(
            f"designed_offset_miss recovered={recovered_phase_ms:.2f} "
            f"designed={designed_offset_ms:.2f}"
        )

    n_data = cov["n_axes_data"]
    if n_data == 0:
        return Verdict(
            "NO-DATA",
            77,
            ["all required axes NO-DATA"],
            coverage=cov,
            axis_verdicts=axis_v,
        )

    # ANY axis NO-DATA ⇒ overall insufficient (rd-review ruling)
    if not cov["coverage_complete"]:
        nodata = cov["nodata_axes"]
        reasons = [
            f"axis_{a}=NO-DATA" for a in nodata
        ] + [
            "overall INSUFFICIENT when any required axis is NO-DATA",
            "av_sync_verdict cannot be carried by supply_ratio "
            f"(av_sync={axis_v.get('av_sync_verdict')} "
            f"supply={axis_v.get('supply_verdict')})",
            "supply_ratio discriminator_role=VOID_ENDPOINT_local_vs_path",
        ]
        # still surface axis hard facts in reasons
        if axis_v.get("supply_verdict") in ("STARVED", "PACER_DROPS"):
            reasons.append(
                f"supply_axis={axis_v['supply_verdict']} (informational; "
                f"does not become overall PASS/FAIL name while coverage incomplete)"
            )
        return Verdict(
            "INSUFFICIENT_EVIDENCE",
            78,
            reasons,
            coverage=cov,
            axis_verdicts=axis_v,
        )

    # --- coverage complete: axis hard fails may become overall ---
    if axis_v.get("av_sync_verdict") == "AUDIO_MARKER_FAIL" or reasons:
        return Verdict(
            "AUDIO_MARKER_FAIL",
            4,
            reasons
            or [f"beep_period_err_ms={marker.get('period_err_ms')}"],
            coverage=cov,
            axis_verdicts=axis_v,
        )
    if axis_v.get("ledger_verdict") == "PACER_DROPS" or axis_v.get("supply_verdict") == "PACER_DROPS":
        return Verdict(
            "PACER_DROPS",
            3,
            ["pacer Drop path dominates (droppedFrames_ on !present)"],
            coverage=cov,
            axis_verdicts=axis_v,
        )
    if axis_v.get("servo_verdict") == "SERVO_DRIFT_CLIMB":
        return Verdict(
            "SERVO_DRIFT_CLIMB",
            5,
            [f"av_drift_slope_ms_per_s={drift_slope} under starvation"],
            coverage=cov,
            axis_verdicts=axis_v,
        )
    if axis_v.get("supply_verdict") == "STARVED":
        return Verdict(
            "STARVED",
            2,
            [
                f"supply_ratio={supply:.4f}<ok_min={ok_min}",
                "VOID_ENDPOINT_local_vs_path — does not prove socket vs consumer",
            ],
            coverage=cov,
            axis_verdicts=axis_v,
        )
    if axis_v.get("ledger_verdict") == "RESIDUAL_NONZERO":
        return Verdict(
            "LEDGER_RESIDUAL",
            3,
            ["residual!=0 and !=publish_misses — see w-instr ledger tool"],
            coverage=cov,
            axis_verdicts=axis_v,
        )

    # all axes DATA and ok
    if (
        axis_v.get("av_sync_verdict") == "ok"
        and axis_v.get("supply_verdict") == "ok_throughput"
        and axis_v.get("ledger_verdict") in ("ok", "ok_residual_eq_publish_misses")
        and axis_v.get("servo_verdict") == "servo_bounded_NOT_lipsync"
    ):
        return Verdict(
            "PASS",
            0,
            [
                "all_required_axes_DATA",
                "av_sync=ok",
                "supply=ok_throughput_VOID_local_vs_path",
                "ledger=ok",
                "servo=bounded_NOT_lipsync",
            ],
            coverage=cov,
            axis_verdicts=axis_v,
        )

    return Verdict(
        "INSUFFICIENT_EVIDENCE",
        78,
        [f"coverage complete but axis mix not PASS: {axis_v}"],
        coverage=cov,
        axis_verdicts=axis_v,
    )


def print_report(doc: Dict[str, Any]) -> None:
    print("=== avsync_audio_telemetry_verdict ===")
    print(f"VERDICT={doc['verdict']} gate_rc={doc['gate_rc']}")
    print(
        "severity_ladder: "
        "0=PASS(all_axes_DATA+ok) 2=STARVED 3=PACER_DROPS "
        "4=MARKER_FAIL 5=SERVO_CLIMB 6=DESIGNED_OFFSET "
        "78=INSUFFICIENT_EVIDENCE(any_axis_NO-DATA) 79=SESSION_INVALID 77=NO-DATA "
        "(78/77 never pass)"
    )
    for r in doc.get("reasons", []):
        print(f"reason: {r}")
    print("--- coverage (required every run) ---")
    print(json.dumps(doc.get("coverage"), indent=2, sort_keys=True))
    print("--- axis_verdicts (one axis never names another) ---")
    print(json.dumps(doc.get("axis_verdicts"), indent=2, sort_keys=True))
    print("--- content_fps ---")
    print(json.dumps(doc.get("content_fps"), indent=2, sort_keys=True))
    print("--- host_load ---")
    print(json.dumps(doc.get("host_load"), indent=2, sort_keys=True))
    print("--- audio_markers ---")
    print(json.dumps(doc.get("audio_markers"), indent=2, sort_keys=True))
    print("--- supply (VOID local-vs-path discriminator) ---")
    print(json.dumps(doc.get("supply"), indent=2, sort_keys=True))
    print("--- ledger ---")
    print(json.dumps(doc.get("ledger"), indent=2, sort_keys=True))
    print("--- drops_semantics (quoted product) ---")
    print(json.dumps(doc.get("drops_semantics"), indent=2, sort_keys=True))
    print("--- av_drift (servo, NOT lipsync) ---")
    print(json.dumps(doc.get("av_drift"), indent=2, sort_keys=True))
    print("--- CANNOT_SETTLE ---")
    for x in doc.get("cannot_settle", []):
        print(f"  - {x}")
    print("--- limits ---")
    for x in doc.get("limits", []):
        print(f"  - {x}")
    if doc.get("json_out"):
        print(f"json_out={doc['json_out']}")
    if doc.get("verdict") == "INSUFFICIENT_EVIDENCE":
        print(
            "NOTE: rc=78 INSUFFICIENT_EVIDENCE — any required axis NO-DATA. "
            "Never PASS on supply alone. Close ledger via w-instr "
            "daemon_media_ledger.py or atomic frameLedgerTelemetryFragment. "
            "Capture audio markers for av_sync_verdict. "
            "supply_ratio is VOID_ENDPOINT for local-vs-path (w-instr recv_q/wchan)."
        )

# --- self-test fixtures -------------------------------------------------------

def synth_beeps(
    path: Path,
    *,
    duration_s: float,
    period_s: float,
    delay_s: float,
    sr: int = 48000,
) -> None:
    n = int(duration_s * sr)
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(sr)
        for i in range(n):
            t = i / sr
            # beep 50 ms at each k*period + delay
            k = int(math.floor((t - delay_s) / period_s + 1e-12))
            t0 = k * period_s + delay_s
            in_beep = k >= 0 and 0.0 <= (t - t0) < 0.050 and t0 < duration_s
            if in_beep:
                v = int(0.9 * 32767 * math.sin(2 * math.pi * 1000.0 * t))
            else:
                v = 0
            w.writeframes(struct.pack("<h", v))


FIXTURE_COLLAPSED_LOG = """\
media: frames=100 presents=80 drops=20 publish_misses=0 residual=0 audio_s=4.000 wall_s=6.500 vfps=15.4 pfps=12.3 av_drift_ms=20 supply_ratio=0.615 fps=24/1 session_epoch=1.1 process_epoch=1 pid=100
media: frames=3316 presents=2251 drops=1065 publish_misses=0 residual=0 audio_s=138.4 wall_s=231.1 vfps=14.3 pfps=9.73 av_drift_ms=56 supply_ratio=0.599 fps=24/1 session_epoch=1.1 process_epoch=1 pid=100
"""

FIXTURE_HEALTHY_LOG = """\
media: frames=100 presents=99 drops=1 publish_misses=0 residual=0 audio_s=4.100 wall_s=4.150 vfps=23.7 pfps=23.6 av_drift_ms=-22 supply_ratio=0.988 fps=24/1 session_epoch=2.1 process_epoch=2 pid=200
media: frames=8638 presents=8590 drops=48 publish_misses=0 residual=0 audio_s=359.9 wall_s=364.2 vfps=23.7 pfps=23.6 av_drift_ms=-22 supply_ratio=0.988 fps=24/1 session_epoch=2.1 process_epoch=2 pid=200
"""

FIXTURE_RESPAWN_LOG = """\
media: frames=500 presents=480 drops=20 audio_s=20.0 wall_s=20.5 av_drift_ms=-20 session_epoch=3.1 process_epoch=3 pid=300
media: frames=10 presents=9 drops=1 audio_s=0.4 wall_s=0.5 av_drift_ms=-20 session_epoch=3.2 process_epoch=4 pid=301
"""

# Parent live 2026-08-02: supply ok but split lines — presents not on 1 Hz stats.
# Must be INSUFFICIENT_EVIDENCE rc=78, never PASS.
FIXTURE_PARENT_TONIGHT_SPLIT = """\
media: frames=699 vfps=23.6 pfps=23.6 audio_s=29.10 wall_s=29.12 supply_ratio=0.9994 drops=4 clock=av-lock av_drift_ms=-24 decode=624x480 measured=624x350 desync_risk=0 fps=24/1 session_epoch=9.1 process_epoch=9 pid=4242
media: fpga frame_tx ok via DDR presents=672 frames=676 ms=4
"""


def self_test(work: Path) -> int:
    fails = 0

    def check(cond: bool, msg: str) -> None:
        nonlocal fails
        if not cond:
            print(f"FAIL {msg}", file=sys.stderr)
            fails += 1
        else:
            print(f"PASS {msg}")

    work.mkdir(parents=True, exist_ok=True)

    # RED: +100 ms designed audio delay must be recovered as DESIGNED_OFFSET_DETECT rc=6
    wav_p100 = work / "beep_plus100.wav"
    synth_beeps(wav_p100, duration_s=12.0, period_s=1.0, delay_s=0.100)
    samples, sr = load_wav_mono(wav_p100)
    onsets, _meta = detect_beeps(samples, sr)
    phase = designed_offset_from_onsets(onsets, 1.0)
    ph = phase.get("audio_grid_phase_ms")
    check(ph is not None and abs(ph - 100.0) <= 20.0, f"plus100 phase≈100 got {ph}")
    v = classify(
        session_invalid=False,
        supply=0.99,
        supply_kind="caller_supplied",
        ok_min=0.90,
        ledger={"frames": 100, "presents": 99, "drops": 1, "residual": 0, "src": "measured"},
        marker={"class": "ok", "period_err_ms": 0.0, "n_beeps": 11},
        drift_last=-24,
        drift_slope=0.0,
        designed_offset_ms=100.0,
        recovered_phase_ms=ph,
        wall_s=12.0,
        n_media_hits=2,
    )
    check(v.cls == "DESIGNED_OFFSET_DETECT" and v.rc == 6, f"plus100 verdict {v.cls} rc={v.rc}")

    # GREEN: all four axes DATA + ok
    wav0 = work / "beep_zero.wav"
    synth_beeps(wav0, duration_s=12.0, period_s=1.0, delay_s=0.0)
    s0, sr0 = load_wav_mono(wav0)
    o0, _ = detect_beeps(s0, sr0)
    m0 = marker_stats(o0, 1.0)
    m0["n_beeps"] = len(o0)
    check(m0["class"] == "ok", f"zero marker class {m0}")
    hits_h = parse_media(FIXTURE_HEALTHY_LOG)
    inv_h, _ = continuity_invalid(hits_h)
    sup_h, sk_h = window_supply(hits_h)
    led_h = last_ledger(hits_h)
    check(sup_h is not None and sup_h >= 0.90, f"healthy supply {sup_h}")
    check(isinstance(led_h.get("drops"), int) and led_h["drops"] < 100, f"healthy drops {led_h.get('drops')}")
    vh = classify(
        session_invalid=inv_h,
        supply=sup_h,
        supply_kind=sk_h,
        ok_min=0.90,
        ledger=led_h,
        marker=m0,
        drift_last=-22,
        drift_slope=0.0,
        designed_offset_ms=0.0,
        recovered_phase_ms=0.0,
        wall_s=led_h.get("wall_s"),
        n_media_hits=len(hits_h),
    )
    check(vh.cls == "PASS" and vh.rc == 0, f"healthy verdict {vh.cls} rc={vh.rc}")
    check(vh.coverage.get("coverage_complete") is True, "healthy coverage complete")
    check(
        vh.axis_verdicts.get("supply_discriminator") == "VOID_ENDPOINT_local_vs_path",
        "supply VOID discriminator tag",
    )

    # RED collapsed — full coverage + pacer drops
    hits_c = parse_media(FIXTURE_COLLAPSED_LOG)
    sup_c, sk = window_supply(hits_c)
    led_c = last_ledger(hits_c)
    check(sup_c is not None and abs(sup_c - 0.599) < 0.02, f"collapsed supply {sup_c} kind={sk}")
    check(led_c.get("drops") == 1065, f"drops=1065 got {led_c.get('drops')}")
    check(
        led_c["frames"] - led_c["presents"] - led_c["drops"] == 0,
        "residual identity frames-presents-drops",
    )
    vc = classify(
        session_invalid=False,
        supply=sup_c,
        supply_kind=sk,
        ok_min=0.90,
        ledger=led_c,
        marker={"class": "ok", "period_err_ms": 1.0, "n_beeps": 20},
        drift_last=56,
        drift_slope=0.2,
        designed_offset_ms=None,
        recovered_phase_ms=None,
        wall_s=led_c.get("wall_s"),
        n_media_hits=len(hits_c),
    )
    check(vc.rc in (2, 3), f"collapsed rc in 2|3 got {vc.rc} {vc.cls}")
    check(vc.cls in ("STARVED", "PACER_DROPS"), f"collapsed class {vc.cls}")
    check(vc.coverage.get("coverage_complete") is True, "collapsed coverage complete")

    # RESPAWN
    hits_r = parse_media(FIXTURE_RESPAWN_LOG)
    inv_r, reason = continuity_invalid(hits_r)
    check(inv_r, f"respawn invalid {reason}")
    vr = classify(
        session_invalid=True,
        supply=0.99,
        ok_min=0.90,
        ledger={},
        marker={"class": "ok"},
        drift_last=-20,
        drift_slope=None,
        designed_offset_ms=None,
        recovered_phase_ms=None,
        wall_s=20.0,
    )
    check(vr.rc == 79, f"respawn rc=79 got {vr.rc}")

    # PARENT VOID: supply ok + markers NO-DATA → rc=78 NEVER PASS
    hits_t = parse_media(FIXTURE_PARENT_TONIGHT_SPLIT)
    sup_t, sk_t = window_supply(hits_t)
    led_t = last_ledger(hits_t)
    check(sup_t is not None and sup_t >= 0.99, f"tonight supply {sup_t}")
    vt = classify(
        session_invalid=False,
        supply=sup_t,
        supply_kind=sk_t,
        ok_min=0.90,
        ledger=led_t,
        marker={"class": "NO-DATA"},
        drift_last=-24,
        drift_slope=0.0,
        designed_offset_ms=None,
        recovered_phase_ms=None,
        wall_s=led_t.get("wall_s") if isinstance(led_t.get("wall_s"), (int, float)) else 29.0,
        n_media_hits=len(hits_t),
    )
    check(vt.cls == "INSUFFICIENT_EVIDENCE", f"tonight class {vt.cls}")
    check(vt.rc == 78, f"tonight rc=78 got {vt.rc}")
    check(vt.axis_verdicts.get("av_sync_verdict") == "INSUFFICIENT_EVIDENCE", "av_sync not carried by supply")
    check(vt.rc != 0, "tonight must never be PASS")

    # markers-only → insufficient
    vm = classify(
        session_invalid=False,
        supply=None,
        ok_min=0.90,
        ledger={"src": "NO-DATA"},
        marker={"class": "ok", "period_err_ms": 0.0, "n_beeps": 10},
        drift_last="NO-DATA",
        drift_slope=None,
        designed_offset_ms=None,
        recovered_phase_ms=None,
        wall_s=None,
    )
    check(vm.rc == 78 and vm.cls == "INSUFFICIENT_EVIDENCE", f"markers-only {vm.cls} rc={vm.rc}")

    # telemetry-only (markers NO-DATA) even with closed ledger → INSUFFICIENT (rd-review)
    v_tel = classify(
        session_invalid=False,
        supply=0.999,
        supply_kind="measured",
        ok_min=0.90,
        ledger={"frames": 699, "presents": 695, "drops": 4, "residual": 0, "src": "measured"},
        marker={"class": "NO-DATA"},
        drift_last=-24,
        drift_slope=0.0,
        designed_offset_ms=None,
        recovered_phase_ms=None,
        wall_s=30.0,
        n_media_hits=5,
    )
    check(
        v_tel.cls == "INSUFFICIENT_EVIDENCE" and v_tel.rc == 78,
        f"telemetry-only must be INSUFFICIENT got {v_tel.cls} rc={v_tel.rc}",
    )
    check("audio_markers" in str(v_tel.coverage.get("nodata_axes")), "markers in nodata_axes")

    # rk6-class void endpoint note: low bitrate does not make PASS
    check(
        cov_void := build_coverage(
            marker={"class": "NO-DATA"},
            supply=0.999,
            supply_kind="measured",
            ledger={"frames": 100, "presents": "NO-DATA", "drops": 4},
            drift_last=-24,
            drift_slope=0.0,
            wall_s=30.0,
            n_media_hits=3,
            n_beeps=0,
        ),
        "coverage builds",
    )
    check(cov_void["coverage_complete"] is False, "void endpoint incomplete coverage")
    check(
        cov_void["axes"]["supply_ratio"]["discriminator_role"] == "VOID_ENDPOINT_local_vs_path",
        "VOID_ENDPOINT tag on supply axis",
    )

    # drops semantics present
    check("droppedFrames_" in DROPS_SEMANTICS["drops"]["counter"], "drops counter name")
    check("4183" in DROPS_SEMANTICS["drops"]["increments"] or "4185" in DROPS_SEMANTICS["drops"]["increments"], "drops line cite")

    if fails:
        print(f"self_test FAIL count={fails}", file=sys.stderr)
        return 1
    print(
        "self_test OK red-before-green "
        "(plus100 rc=6, full-axis PASS rc=0, collapsed RED, respawn 79, "
        "markers-missing INSUFFICIENT rc=78, supply VOID_ENDPOINT tag)"
    )
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--audio", help="WAV or media file with audio (HDMI ALSA capture or fixture)")
    ap.add_argument("--daemon-log", help="misterplexd log excerpt with media: lines")
    ap.add_argument("--fixture", help="content fixture path for measured fps via ffprobe")
    ap.add_argument("--pms-framerate", help="PMS Metadata frameRate string (caller_supplied)")
    ap.add_argument("--marker-period-s", type=float, default=1.0)
    ap.add_argument("--ok-min", type=float, default=0.90)
    ap.add_argument(
        "--ok-min-src",
        default="DEFAULT_ASSUMED",
        help="label for ok_min; DEFAULT_ASSUMED unless conf override",
    )
    ap.add_argument(
        "--designed-offset-ms",
        type=float,
        default=None,
        help="if set (e.g. 100), expect audio grid phase ≈ this (file fixtures)",
    )
    ap.add_argument("--host-load-json", help="optional pre-sampled host load JSON")
    ap.add_argument("--work-dir", type=Path, default=None)
    ap.add_argument("--json-out", type=Path, default=None)
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()

    if args.self_test:
        wd = args.work_dir or Path(".agent-work/w-avsync/audio_telem_selftest")
        return self_test(wd)

    if not args.audio and not args.daemon_log:
        print("need --audio and/or --daemon-log (or --self-test)", file=sys.stderr)
        return 77

    work = args.work_dir or Path(".agent-work/w-avsync/audio_telem_run")
    work.mkdir(parents=True, exist_ok=True)

    # host load
    if args.host_load_json:
        try:
            host_load = json.loads(Path(args.host_load_json).read_text())
            host_load.setdefault("src", "caller_supplied")
        except Exception as e:
            host_load = {"src": "NO-DATA", "error": str(e)}
    else:
        host_load = read_host_load()

    # content fps
    content_fps: Dict[str, Any] = {"fps": None, "fps_src": "NO-DATA"}
    if args.fixture:
        content_fps = ffprobe_video(Path(args.fixture))
    if args.pms_framerate:
        content_fps["pms_frameRate"] = args.pms_framerate
        content_fps["pms_frameRate_src"] = "caller_supplied"
        # do not override measured ffprobe with PMS; keep both
        if content_fps.get("fps_src") == "NO-DATA":
            # parse PMS only if no fixture measure
            try:
                content_fps["fps"] = float(args.pms_framerate)
                content_fps["fps_src"] = "caller_supplied"
            except ValueError:
                content_fps["pms_parse"] = "unparsed_string"

    # audio markers
    audio_markers: Dict[str, Any] = {"class": "NO-DATA", "n_beeps": 0, "n_beeps_src": "NO-DATA"}
    phase_doc: Dict[str, Any] = {"src": "NO-DATA"}
    onsets: List[float] = []
    if args.audio:
        apath = Path(args.audio)
        wav_path = apath
        if apath.suffix.lower() != ".wav":
            wav_path = work / "extract.wav"
            try:
                extract_audio_wav(apath, wav_path)
            except subprocess.CalledProcessError as e:
                print(f"audio extract failed rc={e.returncode}", file=sys.stderr)
                return 77
        try:
            samples, sr = load_wav_mono(wav_path)
        except Exception as e:
            print(f"wav load failed: {e}", file=sys.stderr)
            return 77
        onsets, bmeta = detect_beeps(samples, sr)
        audio_markers = {**bmeta, **marker_stats(onsets, args.marker_period_s)}
        phase_doc = designed_offset_from_onsets(onsets, args.marker_period_s)
        audio_markers["onsets_head_s"] = onsets[:8]
        audio_markers["audio_path"] = str(apath)
        audio_markers["sr"] = sr
        audio_markers["sr_src"] = "measured"

    # daemon telemetry
    hits: List[MediaHit] = []
    inv = False
    inv_reason = "no_log"
    supply = None
    supply_kind = "NO-DATA"
    ledger: Dict[str, Any] = {"src": "NO-DATA"}
    dseries: List[Tuple[float, int]] = []
    dslope = None
    if args.daemon_log:
        text = Path(args.daemon_log).read_text(errors="replace")
        hits = parse_media(text)
        inv, inv_reason = continuity_invalid(hits)
        supply, supply_kind = window_supply(hits)
        ledger = last_ledger(hits)
        dseries = drift_series(hits)
        dslope = drift_slope_ms_per_s(dseries)

    ok_src = args.ok_min_src
    if args.ok_min != 0.90 and ok_src == "DEFAULT_ASSUMED":
        ok_src = "caller_supplied"

    recovered = phase_doc.get("audio_grid_phase_ms")
    drift_last = ledger.get("av_drift_ms", "NO-DATA")
    wall_s = ledger.get("wall_s") if isinstance(ledger.get("wall_s"), (int, float)) else None
    v = classify(
        session_invalid=inv,
        supply=supply,
        supply_kind=supply_kind,
        ok_min=args.ok_min,
        ledger=ledger,
        marker=audio_markers,
        drift_last=drift_last,
        drift_slope=dslope,
        designed_offset_ms=args.designed_offset_ms,
        recovered_phase_ms=recovered if isinstance(recovered, (int, float)) else None,
        wall_s=wall_s,
        n_media_hits=len(hits),
    )

    # drops interpretation narrative for parent numbers
    drops_interp = None
    if isinstance(ledger.get("drops"), int):
        d = ledger["drops"]
        fr = ledger.get("frames")
        pm = ledger.get("publish_misses")
        drops_interp = {
            "drops": d,
            "drops_src": "measured",
            "meaning": DROPS_SEMANTICS["drops"]["means"],
            "increment_site": DROPS_SEMANTICS["drops"]["increments"],
            "reset_site": DROPS_SEMANTICS["drops"]["reset"],
            "drop_frac_of_frames": (d / fr) if isinstance(fr, int) and fr > 0 else "NO-DATA",
            "residual": ledger.get("residual"),
            "residual_eq": "frames-presents-drops",
            "publish_misses": pm,
            "if_residual_eq_publish_misses": (
                isinstance(pm, int)
                and isinstance(ledger.get("residual"), int)
                and pm == ledger.get("residual")
            ),
            "parent_example": "drops=1065 with frames=3316 presents=2251 → "
            "1065 deliberate pacer skips; residual 0 means every non-present "
            "was a pacer Drop (not an unexplained gap)",
        }

    mclass = audio_markers.get("class") or "NO-DATA"
    closed = ledger_closable(ledger)
    doc: Dict[str, Any] = {
        "verdict": v.cls,
        "gate_rc": v.rc,
        "reasons": v.reasons,
        "coverage": v.coverage,
        "axis_verdicts": v.axis_verdicts,
        "evidence_gates": {
            "coverage_complete": v.coverage.get("coverage_complete"),
            "nodata_axes": v.coverage.get("nodata_axes"),
            "n_axes_data": v.coverage.get("n_axes_data"),
            "n_axes_required": v.coverage.get("n_axes_required"),
            "supply_ok_throughput": bool(
                supply is not None and supply >= args.ok_min
            ),
            "supply_established": supply is not None,
            "supply_discriminator_role": "VOID_ENDPOINT_local_vs_path",
            "ledger_closable": closed,
            "markers_class": mclass,
            "markers_fail": mclass == "AUDIO_MARKER_FAIL",
            "session_invalid": inv,
            "pass_requires": (
                "ALL required axes DATA (markers+supply+ledger+drift) AND each ok; "
                "ANY NO-DATA ⇒ rc=78 INSUFFICIENT; supply never names av_sync_verdict"
            ),
            "ledger_owner_split_lines": "w-instr tools/daemon_media_ledger.py",
            "session_invalid_rc": 79,
            "session_invalid_aligns": "w-instr RC_SESSION_INVALID=79",
            "insufficient_rc": 78,
            "insufficient_never_pass": True,
            "src": "measured",
        },
        "content_fps": content_fps,
        "host_load": host_load,
        "audio_markers": audio_markers,
        "audio_grid_phase": phase_doc,
        "supply": {
            "supply_ratio": supply if supply is not None else "NO-DATA",
            "supply_ratio_src": supply_kind if supply is not None else "NO-DATA",
            "ok_min": args.ok_min,
            "ok_min_src": ok_src,
            "discriminator_role": "VOID_ENDPOINT_local_vs_path",
            "discriminator_note": (
                "audio_s locksteps with video frames (ffmpeg one process); "
                "does NOT separate socket-starved from video-consumer-blocked "
                "(w-instr recv_q/wchan). Throughput only."
            ),
        },
        "ledger": ledger,
        "drops_interpretation": drops_interp,
        "drops_semantics": DROPS_SEMANTICS,
        "av_drift": {
            "last_ms": ledger.get("av_drift_ms", "NO-DATA"),
            "slope_ms_per_s": dslope if dslope is not None else "NO-DATA",
            "slope_src": "measured" if dslope is not None else "NO-DATA",
            "n_samples": len(dseries),
            "role": DROPS_SEMANTICS["av_drift_ms"]["role"],
            "eq": DROPS_SEMANTICS["av_drift_ms"]["eq"],
        },
        "continuity": {"invalid": inv, "reason": inv_reason, "src": "measured"},
        "cannot_settle": [
            "glass lipsync offset without flash↔beep video capture (PIXELS_REQUIRED)",
            "visible judder / inter-frame interval histogram (w-instr owns that channel)",
            "whether PMS Docker CPU on this host caused transcoder starvation "
            "(publish host_load + prefer direct-play; complete=0 speed=0 is contaminated)",
            "path capacity vs local limiter via supply_ratio "
            "(VOID_ENDPOINT_local_vs_path — use w-instr recv_q/wchan)",
            "av_drift_ms as lipsync accuracy — servo error; run LEAD 40→20→40 falsifier",
            "closing split stats/DDR ledger without w-instr daemon_media_ledger.py",
            "single-run A/B of intermittent ~25% supply collapse (within-run only)",
        ],
        "limits": [
            "audio-only grid phase is vs capture/file t=0, not vs glass flash",
            "supply_ratio uses submitted PCM bytes (audioBytes_), not audibleClockMs; "
            "trust intervals with d_wall>=3s",
            "ok_min=0.90 is DEFAULT_ASSUMED unless overridden",
            "rc=77 and rc=78 are never a pass",
            "rc=79 SESSION_INVALID aligns w-instr tools/daemon_media_ledger.py",
            "rk6-class ultra-low bitrate endpoints void transport claims",
        ],
        "designed_offset_ms": args.designed_offset_ms,
        "designed_offset_ms_src": "caller_supplied"
        if args.designed_offset_ms is not None
        else "NO-DATA",
    }

    if args.json_out:
        args.json_out.parent.mkdir(parents=True, exist_ok=True)
        args.json_out.write_text(json.dumps(doc, indent=2, sort_keys=True) + "\n")
        doc["json_out"] = str(args.json_out)

    print_report(doc)
    return v.rc


if __name__ == "__main__":
    sys.exit(main())
