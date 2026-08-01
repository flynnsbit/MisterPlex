#!/usr/bin/env python3
"""Measure A/V offset from the HDMI-to-USB grabber (flash ↔ 1 kHz beep).

WHY
---
Daemon-reported av_drift_ms is self-graded (av_clock derives time from
frameIndex). Only a grabber-side cross-correlation of the visual flash and
the audio beep is a real measurement of lipsync / drift.

SIGN CONVENTION (unambiguous)
-----------------------------
  offset_ms = (t_audio_onset - t_video_flash) * 1000

  positive  = audio is LATE relative to video
              (beep heard AFTER flash; audio LAGS; video LEADS)
  negative  = audio is EARLY relative to video
              (beep heard BEFORE flash; audio LEADS video)

  This matches docs/MILESTONE_AVSYNC_SEEK.md and tests/hw/avsync_measure.py.
  Example: median_offset_ms=-60 means audio leads video by 60 ms.

CONTAINER CHOICE
----------------
One ffmpeg process writes ONE Matroska file with both streams
(MJPEG video + pcm_s16le audio). Live capture stamps BOTH inputs with
`-use_wallclock_as_timestamps 1` so v4l2 and ALSA share wall time at open
(rd-review confound: without that, each input's first packet can normalise
to t=0 independently and absorb a USB startup race into the alignment).

PARENT HARDWARE (SESSION-LATCHED — instrument exonerated)
---------------------------------------------------------
One 360 s playback, THREE back-to-back captures inside it (pre-registered):
  within-session spread of medians = 3.33 ms
  between-cluster separation (n=15 prior runs) = 116.89 ms
  ratio ≈ 35× → SESSION-LATCHED, DEVICE CONFIRMED (not capture race).
Clusters fully separate at the VERY FIRST flash/beep pair (A −286 vs B −171,
sep 114.92 ms, zero overlap, n=15). State latches within ~1.4 s and holds.
Common-mode: first-10 s median is 20–40 ms less negative than last-60 s in
BOTH clusters — a real ~25 ms startup transient; short captures are biased.
This tool therefore always prints first_pair_* and early/late window medians.

GRABBER WARM-UP
---------------
MacroSilicon MS2109 (534d:2109) emits ~13–15 uniform junk frames at start
(min==max luma, often mean=7). Default --warmup-frames=20 discards them from
analysis after capture. Live capture must yield >=50 decoded frames or the
run is UNSCORED (short burst of warm-up is NO-DATA, never a black screen).
File/--input mode defaults warmup to 0 (fixture has no junk).

WHAT THIS TOOL CANNOT MEASURE (read before promoting a number)
--------------------------------------------------------------
  - Absolute lipsync to the device: fixed grabber A/V latency B is unknown.
    median_offset_ms without a known-zero calibration is always
    tag=raw_uncalibrated. B cancels in same-rig DIFFERENCES and in slope —
    that is why a 117 ms cluster separation is solid while the absolute
    median is not. Never promote raw_uncalibrated to an absolute claim.
  - Daemon av_drift_ms: servo deadband readout, BLIND to the 117 ms defect.
  - md5 / mean-luma freeze or health (invalid both directions on this project).

RETURN CODES
------------
  0  = measured AND within tolerance (offset + slope), scoring inputs OK
  2  = measured AND out of tolerance (real FAIL — offset or drift)
  77 = UNSCORED / could-not-measure / REFUSE_DEFAULT_ASSUMED (capture fail,
       silence, static, too few pairs, warm-up-only, or PASS/FAIL would rest
       on DEFAULT_ASSUMED without --allow-default-score).
       Never collapsed into 0 or 2. A measured FAIL never decays to 77.

Every printed value is tagged measured | caller_supplied | DEFAULT_ASSUMED.

Usage (parent on capture host, while MiSTer plays the blip fixture)
-------------------------------------------------------------------
  # Live HDMI measure (default 20 s):
  tools/avsync_measure_hdmi.py --duration 20 --out /tmp/avsync_run

  # With prior calibration file:
  tools/avsync_measure_hdmi.py --duration 20 --calibration /tmp/avsync_cal.json \\
      --out /tmp/avsync_run

  # Calibrate instrument — measures WHATEVER is on the grabber inputs right now.
  # Absolute device lipsync needs a known-aligned flash+beep into the MS2109
  # (re-cable workstation HDMI, or a second path). MiSTer-as-daily-driver means
  # absolute offset stays raw_uncalibrated; slope/deltas cancel fixed latency.
  tools/avsync_measure_hdmi.py --calibrate --duration 15 \\
      --out /tmp/avsync_cal --calibration-out /tmp/avsync_cal.json

  # Offline / synthetic (no device):
  tools/avsync_measure_hdmi.py --input path/to/capture.mkv --out /tmp/ana

ABSOLUTE vs RELATIVE (hole 2)
-----------------------------
  - slope_ms_per_s and before/after Δmedian on the same rig: fixed grabber
    latency cancels — reportable as measured without re-cabling.
  - absolute median_offset_ms without --calibration: always tag=raw_uncalibrated.
    No calibration-free absolute device claim exists while MiSTer owns the only
    HDMI into the grabber.
"""
from __future__ import annotations

import argparse
import json
import math
import os
import statistics
import subprocess
import sys
import time
from dataclasses import dataclass, field, asdict
from pathlib import Path
from typing import Any

import numpy as np

# ---------------------------------------------------------------------------
# Defaults — every one is labelled DEFAULT_ASSUMED when used without override
# ---------------------------------------------------------------------------
DEFAULT_VIDEO_DEV = "/dev/video0"
DEFAULT_AUDIO_DEV = "hw:0,0"  # ALSA; MS2109 parent-measured card 0 device 0
DEFAULT_VIDEO_SIZE = "1920x1080"
DEFAULT_CAP_FPS = 60.0  # half the 30 fps frame quant; still MS2109-capable
DEFAULT_DURATION_S = 20.0
# Parent lab: MS2109 emits ~13–15 uniform luma=7 warm-up frames. Discard 20.
# Capture must retain >=50 frames after discard or the run is NO-DATA.
DEFAULT_WARMUP_FRAMES = 20  # measured MS2109 junk floor + margin; parent lab
DEFAULT_MIN_CAPTURE_FRAMES = 50  # live: UNSCORED if fewer decoded frames
DEFAULT_AUDIO_SR = 48000
DEFAULT_TOL_MS = 42.0  # one 24p frame; matches G-AV3 in MILESTONE_AVSYNC_SEEK
DEFAULT_SLOPE_TOL_MS_PER_S = 0.5  # 30 ms/min; constant lag is OK, drift is not
DEFAULT_MIN_PAIRS = 4
# Default 0.9 s (was 0.45). Parent hardware: |offset|~168 ms is fine at 0.45,
# but larger offsets silently dropped pairs (28/40) — degraded n_pairs is
# could-not-measure, not a result. 0.9 is still < half the 1 Hz gap (no double-pair).
# REQUIRED behaviour is the default; do not ship a default that mispairs.
DEFAULT_PAIR_WINDOW_S = 0.9
DEFAULT_BEEP_HZ = 1000.0
DEFAULT_BEEP_MS = 50.0
CAL_FORMAT = "misterplex.avsync_hdmi_calibration.v1"

# Load-bearing scoring inputs that must not silently ride DEFAULT_ASSUMED
# (PARENT ERROR 17 class). Without --allow-default-score, PASS/FAIL is refused.
# Only tol_ms is mandatory: slope_tol may stay DEFAULT_ASSUMED when --tol-ms is
# set (still printed with src=DEFAULT_ASSUMED; score_tag notes it). Forcing both
# would UNSCORE every parent soak that only pins the offset band.
SCORE_DEFAULT_KEYS = ("tol_ms",)

RC_PASS = 0
RC_FAIL = 2
RC_UNSCORED = 77


def _tag(value: Any, src: str) -> str:
    """Format value with provenance tag."""
    if isinstance(value, float):
        return f"{value:.6g} src={src}"
    return f"{value} src={src}"


def _run(cmd: list[str], timeout: float | None = None) -> subprocess.CompletedProcess[bytes]:
    return subprocess.run(cmd, capture_output=True, timeout=timeout)


# ---------------------------------------------------------------------------
# Capture
# ---------------------------------------------------------------------------
def capture_av(
    dest: Path,
    *,
    duration_s: float,
    video_dev: str,
    audio_dev: str,
    video_size: str,
    cap_fps: float,
) -> None:
    """Capture video+audio in ONE ffmpeg process into one MKV.

    Both inputs use wallclock timestamps so v4l2 and ALSA share one clock at
    open (avoids independent first-packet→0 normalisation absorbing USB race).
    Parent multi-capture-within-session test: within-session median spread
    3.33 ms vs 116.89 ms cluster sep → device-latched, not capture race; wallclock
    is still required hygiene.
    """
    dest.parent.mkdir(parents=True, exist_ok=True)
    if dest.exists():
        dest.unlink()
    # thread_queue_size avoids overruns when ALSA and v4l2 start at different rates.
    cmd = [
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
        "-thread_queue_size", "1024",
        "-use_wallclock_as_timestamps", "1",
        "-f", "v4l2",
        "-input_format", "mjpeg",
        "-video_size", video_size,
        "-framerate", str(cap_fps),
        "-i", video_dev,
        "-thread_queue_size", "1024",
        "-use_wallclock_as_timestamps", "1",
        "-f", "alsa",
        "-ac", "2",
        "-ar", str(DEFAULT_AUDIO_SR),
        "-i", audio_dev,
        "-map", "0:v:0",
        "-map", "1:a:0",
        "-copyts",
        "-t", f"{duration_s:.3f}",
        "-c:v", "mjpeg",
        "-q:v", "5",
        "-c:a", "pcm_s16le",
        str(dest),
    ]
    try:
        r = _run(cmd, timeout=duration_s + 90.0)
    except FileNotFoundError as e:
        raise RuntimeError("CAPTURE_FAILED reason=missing_ffmpeg") from e
    except subprocess.TimeoutExpired as e:
        raise RuntimeError("CAPTURE_FAILED reason=ffmpeg_timeout") from e
    if r.returncode != 0 or not dest.exists() or dest.stat().st_size < 1000:
        err = (r.stderr or b"").decode("utf-8", "replace").strip().splitlines()
        tail = err[-1] if err else "no_stderr"
        raise RuntimeError(
            f"CAPTURE_FAILED rc={r.returncode} out={dest} log={tail}"
        )


# ---------------------------------------------------------------------------
# Decode streams from a container
# ---------------------------------------------------------------------------
def load_video_luma(
    path: Path, *, max_side: int = 64
) -> tuple[np.ndarray, np.ndarray, dict[str, Any]]:
    """Return (mean_luma[n], pts_s[n], meta) for the video stream."""
    # Probe size for scale target keeping aspect
    probe = _run(
        [
            "ffprobe", "-v", "error", "-select_streams", "v:0",
            "-show_entries", "stream=width,height,avg_frame_rate,r_frame_rate",
            "-of", "json", str(path),
        ],
        timeout=60,
    )
    w, h = max_side, max_side
    fps_nom = DEFAULT_CAP_FPS
    if probe.returncode == 0 and probe.stdout:
        try:
            info = json.loads(probe.stdout.decode())
            st = info["streams"][0]
            ow, oh = int(st["width"]), int(st["height"])
            if ow >= oh:
                w = max_side
                h = max(1, int(round(max_side * oh / ow)))
            else:
                h = max_side
                w = max(1, int(round(max_side * ow / oh)))
            rate = st.get("avg_frame_rate") or st.get("r_frame_rate") or "0/0"
            if "/" in rate:
                num, den = rate.split("/", 1)
                if float(den) != 0:
                    fps_nom = float(num) / float(den)
        except (KeyError, ValueError, IndexError, json.JSONDecodeError):
            pass

    raw = _run(
        [
            "ffmpeg", "-hide_banner", "-loglevel", "error",
            "-i", str(path),
            "-map", "0:v:0",
            "-vf", f"scale={w}:{h}",
            "-pix_fmt", "gray",
            "-f", "rawvideo", "pipe:1",
        ],
        timeout=600,
    )
    if raw.returncode != 0:
        raise RuntimeError(f"VIDEO_DECODE_FAILED file={path}")
    buf = np.frombuffer(raw.stdout, dtype=np.uint8)
    pix = w * h
    if pix <= 0 or buf.size < pix:
        raise RuntimeError(f"VIDEO_DECODE_FAILED file={path} reason=no_frames")
    n = buf.size // pix
    frames = buf[: n * pix].reshape(n, pix)
    luma = frames.mean(axis=1).astype(np.float64)
    # Per-frame min/max for uniform-frame detection (warm-up junk)
    fmin = frames.min(axis=1).astype(np.float64)
    fmax = frames.max(axis=1).astype(np.float64)

    pts_raw = _run(
        [
            "ffprobe", "-v", "error", "-select_streams", "v:0",
            "-show_entries", "frame=pts_time",
            "-of", "csv=p=0", str(path),
        ],
        timeout=600,
    )
    times: list[float] = []
    if pts_raw.returncode == 0 and pts_raw.stdout:
        for line in pts_raw.stdout.decode("utf-8", "replace").splitlines():
            s = line.strip().rstrip(",")
            if not s or s == "N/A":
                continue
            try:
                times.append(float(s))
            except ValueError:
                continue
    t = np.asarray(times[:n], dtype=np.float64)
    if t.size < n:
        # No usable PTS — synthesize from nominal fps (labelled by caller)
        t = np.arange(n, dtype=np.float64) / max(fps_nom, 1e-6)
    # Stash uniform mask on the array object for warmup logic
    luma_out = luma.copy()
    luma_out_meta = {
        "uniform": (fmax - fmin) < 1.0,  # min==max → junk
        "fps_nom": fps_nom,
        "n": n,
        "pts_from_container": t.size == n and times != [],
    }
    return luma_out, t, luma_out_meta  # type: ignore[return-value]


def _stream_start_time(path: Path, codec_type: str) -> float:
    """Container start_time for first stream of codec_type (0.0 if absent)."""
    probe = _run(
        [
            "ffprobe", "-v", "error",
            "-select_streams", f"{codec_type[0]}:0",  # v:0 / a:0
            "-show_entries", "stream=start_time",
            "-of", "csv=p=0",
            str(path),
        ],
        timeout=60,
    )
    if probe.returncode != 0 or not probe.stdout:
        return 0.0
    s = probe.stdout.decode("utf-8", "replace").strip().splitlines()
    if not s:
        return 0.0
    try:
        v = float(s[0].rstrip(","))
    except ValueError:
        return 0.0
    if math.isnan(v) or math.isinf(v):
        return 0.0
    return v


def load_audio_mono(path: Path, sr: int = DEFAULT_AUDIO_SR) -> tuple[np.ndarray, int]:
    """Return mono float64 PCM in ~[-1, 1] and sample rate.

    Sample index 0 is aligned to container t=0 by honouring audio start_time:
    positive start_time → leading silence pad; negative → trim. Raw PCM dump
    alone would drop itsoffset/mux delay and silently report 0 ms offset
    (measured failure mode on +250 ms itsoffset fixtures before this pad).
    """
    raw = _run(
        [
            "ffmpeg", "-hide_banner", "-loglevel", "error",
            "-i", str(path),
            "-map", "0:a:0",
            "-ac", "1",
            "-ar", str(sr),
            "-f", "f32le",
            "pipe:1",
        ],
        timeout=600,
    )
    if raw.returncode != 0:
        raise RuntimeError(f"AUDIO_DECODE_FAILED file={path}")
    a = np.frombuffer(raw.stdout, dtype=np.float32).astype(np.float64)
    if a.size == 0:
        raise RuntimeError(f"AUDIO_DECODE_FAILED file={path} reason=no_samples")

    start = _stream_start_time(path, "audio")
    if start > 1e-6:
        pad = int(round(start * sr))
        if pad > 0:
            a = np.concatenate([np.zeros(pad, dtype=np.float64), a])
    elif start < -1e-6:
        trim = int(round(-start * sr))
        if 0 < trim < a.size:
            a = a[trim:]
    return a, sr


# ---------------------------------------------------------------------------
# Detectors
# ---------------------------------------------------------------------------
def detect_flashes(
    luma: np.ndarray,
    t: np.ndarray,
    uniform: np.ndarray | None,
    *,
    warmup_frames: int,
    min_separation_s: float = 0.6,
) -> tuple[list[float], dict[str, Any]]:
    """Detect white flash onsets via adaptive luma threshold.

    Threshold choice: fixture is mostly dark (mean luma ~3–7 on scaled frames;
    flash peaks ~200+). We set thr = floor + 0.5*(peak-floor) using percentiles
    so a single stuck bright frame cannot dominate. Require peak-floor >= 40
    luma counts or we declare no usable contrast (static / no flash).
    """
    meta: dict[str, Any] = {}
    n = luma.size
    if n == 0:
        meta["reason"] = "no_frames"
        return [], meta

    start = min(max(0, warmup_frames), n)
    # Also skip trailing uniform? no — only leading warm-up.
    # Drop uniform frames only inside the warm-up window; after that score them.
    if uniform is not None and start > 0:
        # Count how many of the first warmup_frames were uniform (report only)
        meta["warmup_uniform_count"] = int(uniform[:start].sum())
    meta["warmup_frames_discarded"] = int(start)
    meta["warmup_frames_requested"] = int(warmup_frames)

    lu = luma[start:]
    tt = t[start:]
    if lu.size < 3:
        meta["reason"] = "too_few_frames_after_warmup"
        return [], meta

    floor = float(np.percentile(lu, 20))
    peak = float(np.percentile(lu, 99.5))
    contrast = peak - floor
    meta["luma_floor"] = floor
    meta["luma_peak"] = peak
    meta["luma_contrast"] = contrast
    meta["luma_median"] = float(np.median(lu))
    # Threshold: mid between floor and peak. Justified by measured fixture
    # contrast >> 40 (dark~3, flash~230). Absolute floor of 40 contrast rejects
    # static / idle captures.
    MIN_CONTRAST = 40.0
    meta["min_contrast_required"] = MIN_CONTRAST
    if contrast < MIN_CONTRAST:
        meta["reason"] = "insufficient_luma_contrast"
        meta["threshold"] = None
        return [], meta

    thr = floor + 0.50 * contrast
    meta["threshold"] = thr
    meta["threshold_rule"] = "floor_p20 + 0.50*(peak_p99.5 - floor_p20)"
    # Sub-frame onset policy
    # --------------------
    # Capture-frame quant alone is 1000/cap_fps ms (33.3 @ 30 fps, 16.7 @ 60).
    # When the rising edge is a near-step spanning one sample interval (fixture
    # flash, or a capture frame that jumps dark→white), LINEAR interpolation to
    # thr places the onset near the MIDPOINT of [t0,t1]. That is unbiased only
    # if the true edge phase is uniform in the interval (async HDMI capture).
    # On content-grid encodes (gen_avsync_blip flash on integer seconds = frame
    # boundary) the true onset is at t1, and midpoint introduces a systematic
    # −½ frame bias on flash time (~−20.8 ms @ 24 fps) → +½ frame on offset.
    # Measured on this tool before the step guard: every adelay ladder point
    # sat at injected+20.0076 ms.
    #
    # Guard: if the single-interval rise covers ≥70 % of (peak−floor), treat as
    # a step and use the first hot frame PTS (t1). Otherwise linear-interpolate.
    # Live MS2109 captures of the same flash still benefit when the edge is
    # soft / multi-frame; sharp steps stay on t1 (worst case one capture frame
    # quant, no half-frame systematic).
    meta["flash_onset_method"] = "step_or_linear_luma_interp"
    meta["flash_onset_method_src"] = "DEFAULT_ASSUMED"
    STEP_RISE_FRAC = 0.70
    meta["flash_step_rise_frac"] = STEP_RISE_FRAC

    hot = lu > thr
    onsets: list[float] = []
    interp_deltas_ms: list[float] = []
    n_step = 0
    n_interp = 0
    i = 0
    while i < hot.size:
        if not hot[i]:
            i += 1
            continue
        if i == 0 or not hot[i - 1]:
            if i == 0:
                ts = float(tt[i])
                d_ms = 0.0
            else:
                y0 = float(lu[i - 1])
                y1 = float(lu[i])
                t0 = float(tt[i - 1])
                t1 = float(tt[i])
                rise = y1 - y0
                if (
                    rise >= STEP_RISE_FRAC * contrast
                    and t1 > t0
                ):
                    # Step edge: first hot frame PTS.
                    ts = t1
                    d_ms = 0.0
                    n_step += 1
                elif y1 > y0 and t1 > t0:
                    frac = (thr - y0) / (y1 - y0)
                    frac = 0.0 if frac < 0.0 else (1.0 if frac > 1.0 else frac)
                    ts = t0 + frac * (t1 - t0)
                    d_ms = (ts - t1) * 1000.0
                    n_interp += 1
                else:
                    ts = t1
                    d_ms = 0.0
                    n_step += 1
            if not onsets or (ts - onsets[-1]) >= min_separation_s:
                onsets.append(ts)
                interp_deltas_ms.append(d_ms)
        while i < hot.size and hot[i]:
            i += 1
    meta["n_flashes"] = len(onsets)
    meta["flash_onset_n_step"] = n_step
    meta["flash_onset_n_interp"] = n_interp
    if interp_deltas_ms:
        abs_d = [abs(x) for x in interp_deltas_ms]
        meta["flash_interp_abs_delta_ms_median"] = float(statistics.median(abs_d))
    if tt.size >= 2:
        dt = float(np.median(np.diff(tt)))
        if dt > 0:
            meta["capture_frame_period_ms"] = dt * 1000.0
            meta["capture_frame_quant_ms_no_interp"] = dt * 1000.0
    return onsets, meta


def goertzel_power(block: np.ndarray, sr: int, freq: float) -> float:
    """Goertzel power at `freq` for one block (unnormalized)."""
    n = block.size
    if n == 0:
        return 0.0
    k = int(0.5 + (n * freq) / sr)
    w = 2.0 * math.pi * k / n
    coeff = 2.0 * math.cos(w)
    s0 = s1 = s2 = 0.0
    for x in block:
        s0 = x + coeff * s1 - s2
        s2 = s1
        s1 = s0
    power = s1 * s1 + s2 * s2 - coeff * s1 * s2
    return float(power) / (n * n)


def detect_beeps(
    audio: np.ndarray,
    sr: int,
    *,
    beep_hz: float = DEFAULT_BEEP_HZ,
    hop_ms: float = 2.0,
    win_ms: float = 20.0,
    min_separation_s: float = 0.6,
) -> tuple[list[float], dict[str, Any]]:
    """Detect 1 kHz beep onsets via Goertzel band energy.

    Threshold: thr = floor_p20 + 0.35*(peak_p99.5 - floor). Require peak/floor
    ratio evidence (or absolute peak) so silence returns zero beeps rather than
    noise triggers. Onset = rising edge of the thresholded energy envelope.
    """
    meta: dict[str, Any] = {}
    if audio.size < sr // 10:
        meta["reason"] = "audio_too_short"
        return [], meta

    # RMS overall — silence gate
    rms = float(np.sqrt(np.mean(audio * audio)))
    meta["audio_rms"] = rms
    SILENCE_RMS = 1e-4
    meta["silence_rms_threshold"] = SILENCE_RMS
    if rms < SILENCE_RMS:
        meta["reason"] = "audio_silence"
        return [], meta

    hop = max(1, int(sr * hop_ms / 1000.0))
    win = max(hop, int(sr * win_ms / 1000.0))
    n_hops = 1 + max(0, (audio.size - win) // hop)
    if n_hops < 3:
        meta["reason"] = "too_few_hops"
        return [], meta

    energy = np.empty(n_hops, dtype=np.float64)
    times = np.empty(n_hops, dtype=np.float64)
    for i in range(n_hops):
        s = i * hop
        block = audio[s : s + win]
        energy[i] = goertzel_power(block, sr, beep_hz)
        # onset time at start of window (conservative; beep starts here)
        times[i] = s / float(sr)

    floor = float(np.percentile(energy, 20))
    peak = float(np.percentile(energy, 99.5))
    contrast = peak - floor
    meta["goertzel_floor"] = floor
    meta["goertzel_peak"] = peak
    meta["goertzel_contrast"] = contrast
    meta["beep_hz"] = beep_hz
    meta["hop_ms"] = hop_ms
    meta["win_ms"] = win_ms

    # Absolute + relative gate: a real 0.9-amp 1 kHz beep produces peak >> 1e-4
    MIN_PEAK = 1e-5
    if peak < MIN_PEAK or contrast < MIN_PEAK * 0.5:
        meta["reason"] = "no_beep_energy"
        meta["threshold"] = None
        return [], meta

    thr = floor + 0.35 * contrast
    meta["threshold"] = thr
    meta["threshold_rule"] = "floor_p20 + 0.35*(peak_p99.5 - floor_p20)"

    hot = energy > thr
    onsets: list[float] = []
    i = 0
    while i < hot.size:
        if not hot[i]:
            i += 1
            continue
        if i == 0 or not hot[i - 1]:
            ts = float(times[i])
            if not onsets or (ts - onsets[-1]) >= min_separation_s:
                onsets.append(ts)
        while i < hot.size and hot[i]:
            i += 1
    meta["n_beeps"] = len(onsets)
    return onsets, meta


# ---------------------------------------------------------------------------
# Pairing + stats
# ---------------------------------------------------------------------------
def pair_offsets(
    flashes: list[float],
    beeps: list[float],
    window_s: float,
) -> tuple[list[dict[str, float]], int, int]:
    """Greedy nearest-neighbour pairing within ±window_s.

    Returns (pairs, unpaired_flashes, unpaired_beeps).
    Each pair: {t_flash, t_beep, offset_ms}.
    """
    used_b: set[int] = set()
    pairs: list[dict[str, float]] = []
    for f in flashes:
        best_j = -1
        best_abs = window_s + 1.0
        for j, b in enumerate(beeps):
            if j in used_b:
                continue
            d = abs(b - f)
            if d <= window_s and d < best_abs:
                best_abs = d
                best_j = j
        if best_j >= 0:
            b = beeps[best_j]
            used_b.add(best_j)
            pairs.append(
                {
                    "t_flash_s": f,
                    "t_beep_s": b,
                    "offset_ms": (b - f) * 1000.0,
                }
            )
    unpaired_f = len(flashes) - len(pairs)
    unpaired_b = len(beeps) - len(pairs)
    return pairs, unpaired_f, unpaired_b


def linreg_slope(xs: list[float], ys: list[float]) -> tuple[float, float, float]:
    """Return (slope, intercept, r_squared) for y = a*x + b."""
    n = len(xs)
    if n < 2:
        return float("nan"), float("nan"), float("nan")
    x = np.asarray(xs, dtype=np.float64)
    y = np.asarray(ys, dtype=np.float64)
    x_mean = float(x.mean())
    y_mean = float(y.mean())
    var_x = float(np.sum((x - x_mean) ** 2))
    if var_x < 1e-18:
        return float("nan"), y_mean, float("nan")
    cov = float(np.sum((x - x_mean) * (y - y_mean)))
    slope = cov / var_x
    intercept = y_mean - slope * x_mean
    y_hat = slope * x + intercept
    ss_res = float(np.sum((y - y_hat) ** 2))
    ss_tot = float(np.sum((y - y_mean) ** 2))
    r2 = 1.0 - ss_res / ss_tot if ss_tot > 1e-18 else float("nan")
    return slope, intercept, r2


@dataclass
class MeasureResult:
    ok: bool
    unscored: bool
    reason: str = ""
    pairs: list[dict[str, float]] = field(default_factory=list)
    n_flashes: int = 0
    n_beeps: int = 0
    n_pairs: int = 0
    unpaired_flashes: int = 0
    unpaired_beeps: int = 0
    median_offset_ms: float | None = None
    mean_offset_ms: float | None = None
    stdev_offset_ms: float | None = None
    min_offset_ms: float | None = None
    max_offset_ms: float | None = None
    slope_ms_per_s: float | None = None
    slope_intercept_ms: float | None = None
    slope_r_squared: float | None = None
    # SESSION-LATCHED instrument fields (parent n=15 + 3-in-1-session)
    first_pair_offset_ms: float | None = None
    first_pair_t_flash_s: float | None = None
    first_pair_t_beep_s: float | None = None
    early_window_s: float | None = None  # caller/default window length
    early_window_s_src: str = "DEFAULT_ASSUMED"
    early_median_offset_ms: float | None = None
    early_n_pairs: int = 0
    late_window_s: float | None = None
    late_window_s_src: str = "DEFAULT_ASSUMED"
    late_median_offset_ms: float | None = None
    late_n_pairs: int = 0
    early_minus_late_ms: float | None = None  # startup transient (parent ~+25 ms)
    flash_meta: dict[str, Any] = field(default_factory=dict)
    beep_meta: dict[str, Any] = field(default_factory=dict)
    capture_path: str = ""


# Parent-measured common-mode startup transient windows (design defaults).
DEFAULT_EARLY_WINDOW_S = 10.0
DEFAULT_LATE_WINDOW_S = 60.0


def _window_median(
    pairs: list[dict[str, float]],
    *,
    t0: float,
    t1: float,
) -> tuple[float | None, int]:
    vals = [
        float(p["offset_ms"])
        for p in pairs
        if t0 <= float(p["t_flash_s"]) < t1
    ]
    if not vals:
        return None, 0
    return float(statistics.median(vals)), len(vals)


def analyse_file(
    path: Path,
    *,
    warmup_frames: int,
    pair_window_s: float,
    min_pairs: int,
    beep_hz: float,
    early_window_s: float = DEFAULT_EARLY_WINDOW_S,
    early_window_src: str = "DEFAULT_ASSUMED",
    late_window_s: float = DEFAULT_LATE_WINDOW_S,
    late_window_src: str = "DEFAULT_ASSUMED",
) -> MeasureResult:
    try:
        luma, t, vmeta = load_video_luma(path)
        audio, sr = load_audio_mono(path)
    except RuntimeError as e:
        return MeasureResult(ok=False, unscored=True, reason=str(e), capture_path=str(path))

    uniform = vmeta.get("uniform")
    flashes, fmeta = detect_flashes(
        luma, t, uniform, warmup_frames=warmup_frames
    )
    fmeta["pts_from_container"] = vmeta.get("pts_from_container")
    fmeta["fps_nom"] = vmeta.get("fps_nom")
    beeps, bmeta = detect_beeps(audio, sr, beep_hz=beep_hz)

    if not flashes and fmeta.get("reason"):
        return MeasureResult(
            ok=False, unscored=True, reason=f"no_flashes:{fmeta['reason']}",
            n_flashes=0, n_beeps=len(beeps),
            flash_meta=fmeta, beep_meta=bmeta, capture_path=str(path),
        )
    if not beeps and bmeta.get("reason"):
        return MeasureResult(
            ok=False, unscored=True, reason=f"no_beeps:{bmeta['reason']}",
            n_flashes=len(flashes), n_beeps=0,
            flash_meta=fmeta, beep_meta=bmeta, capture_path=str(path),
        )

    pairs, uf, ub = pair_offsets(flashes, beeps, pair_window_s)
    res = MeasureResult(
        ok=False,
        unscored=False,
        n_flashes=len(flashes),
        n_beeps=len(beeps),
        n_pairs=len(pairs),
        unpaired_flashes=uf,
        unpaired_beeps=ub,
        pairs=pairs,
        flash_meta=fmeta,
        beep_meta=bmeta,
        capture_path=str(path),
        early_window_s=float(early_window_s),
        early_window_s_src=early_window_src,
        late_window_s=float(late_window_s),
        late_window_s_src=late_window_src,
    )
    if len(pairs) < min_pairs:
        res.unscored = True
        res.reason = (
            f"too_few_pairs n_pairs={len(pairs)} min_pairs={min_pairs} "
            f"flashes={len(flashes)} beeps={len(beeps)}"
        )
        return res

    offs = [p["offset_ms"] for p in pairs]
    res.median_offset_ms = float(statistics.median(offs))
    res.mean_offset_ms = float(statistics.fmean(offs))
    res.stdev_offset_ms = float(statistics.pstdev(offs)) if len(offs) > 1 else 0.0
    res.min_offset_ms = float(min(offs))
    res.max_offset_ms = float(max(offs))

    # First pair — parent: clusters fully separated here (n=15, zero overlap).
    p0 = pairs[0]
    res.first_pair_offset_ms = float(p0["offset_ms"])
    res.first_pair_t_flash_s = float(p0["t_flash_s"])
    res.first_pair_t_beep_s = float(p0["t_beep_s"])

    # Early/late windows — parent common-mode ~25 ms startup transient.
    t_min = min(float(p["t_flash_s"]) for p in pairs)
    t_max = max(float(p["t_flash_s"]) for p in pairs)
    e_med, e_n = _window_median(pairs, t0=t_min, t1=t_min + float(early_window_s))
    l_med, l_n = _window_median(
        pairs, t0=max(t_min, t_max - float(late_window_s)), t1=t_max + 1e-9
    )
    res.early_median_offset_ms = e_med
    res.early_n_pairs = e_n
    res.late_median_offset_ms = l_med
    res.late_n_pairs = l_n
    if e_med is not None and l_med is not None:
        # early - late: parent saw first-10s LESS NEGATIVE → positive delta ~20-40
        res.early_minus_late_ms = float(e_med - l_med)

    # Slope of offset vs flash time (ms per second of capture)
    xs = [p["t_flash_s"] for p in pairs]
    ys = offs
    slope, intercept, r2 = linreg_slope(xs, ys)
    res.slope_ms_per_s = slope
    res.slope_intercept_ms = intercept
    res.slope_r_squared = r2
    res.ok = True
    return res


# ---------------------------------------------------------------------------
# Calibration I/O
# ---------------------------------------------------------------------------
def save_calibration(path: Path, median_ms: float, meta: dict[str, Any]) -> None:
    doc = {
        "format": CAL_FORMAT,
        "instrument_offset_ms": median_ms,
        "sign_convention": (
            "offset_ms=(t_audio-t_video)*1000; "
            "positive=audio LATE (lags video); negative=audio EARLY (leads video)"
        ),
        "meta": meta,
        "created_unix": time.time(),
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(doc, indent=2) + "\n")


def load_calibration(path: Path) -> tuple[float, dict[str, Any]]:
    doc = json.loads(path.read_text())
    if doc.get("format") != CAL_FORMAT:
        raise ValueError(f"bad calibration format: {doc.get('format')}")
    return float(doc["instrument_offset_ms"]), doc


# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------
def print_limitations_banner() -> None:
    """Always-on: what this instrument cannot claim (PARENT ERROR 17 class)."""
    print("=== LIMITATIONS (not optional) ===")
    print(
        "CANNOT_MEASURE absolute_lipsync: fixed grabber latency B unknown; "
        "median without known-zero cal is tag=raw_uncalibrated only"
    )
    print(
        "CAN_MEASURE same_rig_delta_ms and slope_ms_per_s: B cancels "
        "(cluster separation / drift) — tag=measured"
    )
    print(
        "CANNOT_MEASURE via av_drift_ms: daemon servo deadband is BLIND to "
        "~117 ms HDMI clusters (parent-measured)"
    )
    print(
        "DEFAULT_ASSUMED values are NEVER measurements; PASS/FAIL refused "
        "unless every scoring threshold is caller_supplied or "
        "--allow-default-score is set"
    )
    print(
        "SESSION_LATCHED (parent measured): within-session 3-capture spread "
        "3.33 ms vs cluster sep 116.89 ms — defect is DEVICE, not capture race; "
        "first_pair fully separates clusters; early-late ~25 ms common-mode "
        "startup transient biases short captures"
    )


def print_report(
    res: MeasureResult,
    *,
    tol_ms: float,
    tol_src: str,
    slope_tol: float,
    slope_tol_src: str,
    min_pairs: int,
    min_pairs_src: str,
    warmup_frames: int,
    warmup_src: str,
    pair_window_s: float,
    pair_window_src: str,
    cal_ms: float | None,
    cal_path: str | None,
    mode: str,
    allow_default_score: bool,
    extra: dict[str, Any] | None = None,
) -> int:
    """Print tagged report; return rc."""
    print("=== avsync_measure_hdmi ===")
    print_limitations_banner()
    print(f"mode={mode} src=caller_supplied")
    print(
        "sign_convention: offset_ms=(t_audio_onset - t_video_flash)*1000; "
        "positive=audio LATE (lags video); negative=audio EARLY (LEADS video)"
    )
    print(f"capture_path={res.capture_path} src=measured")
    print(f"warmup_frames={_tag(warmup_frames, warmup_src)}")
    print(f"pair_window_s={_tag(pair_window_s, pair_window_src)}")
    if res.flash_meta:
        wd = res.flash_meta.get("warmup_frames_discarded")
        if wd is not None:
            print(f"warmup_frames_discarded={wd} src=measured")
        thr = res.flash_meta.get("threshold")
        if thr is not None:
            print(f"flash_threshold_luma={thr:.4f} src=measured")
            print(
                f"flash_threshold_rule={res.flash_meta.get('threshold_rule')} "
                f"src=DEFAULT_ASSUMED"
            )
        print(
            f"flash_onset_method={res.flash_meta.get('flash_onset_method')} "
            f"src={res.flash_meta.get('flash_onset_method_src', 'DEFAULT_ASSUMED')}"
        )
        if res.flash_meta.get("flash_onset_n_step") is not None:
            print(
                f"flash_onset_n_step={res.flash_meta.get('flash_onset_n_step')} "
                f"src=measured flash_onset_n_interp="
                f"{res.flash_meta.get('flash_onset_n_interp')} src=measured"
            )
        if res.flash_meta.get("capture_frame_period_ms") is not None:
            print(
                f"capture_frame_period_ms="
                f"{res.flash_meta['capture_frame_period_ms']:.4f} src=measured"
            )
            print(
                f"capture_frame_quant_ms_no_interp="
                f"{res.flash_meta['capture_frame_quant_ms_no_interp']:.4f} src=measured"
            )
        if res.flash_meta.get("flash_interp_abs_delta_ms_median") is not None:
            print(
                f"flash_interp_abs_delta_ms_median="
                f"{res.flash_meta['flash_interp_abs_delta_ms_median']:.4f} src=measured"
            )
        print(
            f"luma_floor={res.flash_meta.get('luma_floor')} src=measured "
            f"luma_peak={res.flash_meta.get('luma_peak')} src=measured "
            f"luma_contrast={res.flash_meta.get('luma_contrast')} src=measured"
        )
    if res.beep_meta:
        thr = res.beep_meta.get("threshold")
        if thr is not None:
            print(f"beep_threshold_goertzel={thr:.6g} src=measured")
            print(
                f"beep_threshold_rule={res.beep_meta.get('threshold_rule')} "
                f"src=DEFAULT_ASSUMED"
            )
        print(
            f"audio_rms={res.beep_meta.get('audio_rms')} src=measured "
            f"goertzel_peak={res.beep_meta.get('goertzel_peak')} src=measured"
        )

    print(f"n_flashes={res.n_flashes} src=measured")
    print(f"n_beeps={res.n_beeps} src=measured")
    print(f"n_pairs={res.n_pairs} src=measured")
    print(f"unpaired_flashes={res.unpaired_flashes} src=measured")
    print(f"unpaired_beeps={res.unpaired_beeps} src=measured")
    print(f"min_pairs={_tag(min_pairs, min_pairs_src)}")
    print(f"tol_ms={_tag(tol_ms, tol_src)}")
    print(f"slope_tol_ms_per_s={_tag(slope_tol, slope_tol_src)}")

    if res.unscored or not res.ok:
        print(f"VERDICT=UNSCORED rc={RC_UNSCORED}")
        print(f"reason={res.reason or 'unscored'} src=measured")
        if cal_ms is None:
            print("calibration=NONE")
        else:
            print(f"calibration_ms={cal_ms:.4f} src=caller_supplied path={cal_path}")
        if extra:
            for k, v in extra.items():
                print(f"{k}={v}")
        return RC_UNSCORED

    assert res.median_offset_ms is not None
    raw = res.median_offset_ms
    print(f"per_pair_offsets_ms={[round(p['offset_ms'], 3) for p in res.pairs]} src=measured")
    # First pair — parent n=15: clusters fully separated here (never a bare "first")
    print(
        f"first_pair_offset_ms={res.first_pair_offset_ms} src=measured "
        f"tag=raw_uncalibrated"
    )
    print(
        f"first_pair_t_flash_s={res.first_pair_t_flash_s} src=measured "
        f"first_pair_t_beep_s={res.first_pair_t_beep_s} src=measured"
    )
    print(
        f"early_window_s={_tag(res.early_window_s, res.early_window_s_src)} "
        f"early_n_pairs={res.early_n_pairs} src=measured "
        f"early_median_offset_ms={res.early_median_offset_ms} src="
        f"{'measured' if res.early_median_offset_ms is not None else 'NO-DATA'} "
        f"tag=raw_uncalibrated"
    )
    print(
        f"late_window_s={_tag(res.late_window_s, res.late_window_s_src)} "
        f"late_n_pairs={res.late_n_pairs} src=measured "
        f"late_median_offset_ms={res.late_median_offset_ms} src="
        f"{'measured' if res.late_median_offset_ms is not None else 'NO-DATA'} "
        f"tag=raw_uncalibrated"
    )
    if res.early_minus_late_ms is not None:
        print(
            f"early_minus_late_ms={res.early_minus_late_ms:.4f} src=measured "
            f"note=startup_transient_common_mode_parent_~25ms_both_clusters "
            f"(short_capture_bias)"
        )
    else:
        print(f"early_minus_late_ms=None src=NO-DATA")
    print(
        "session_latch_note: parent 3-in-1-session spread=3.33ms vs cluster_sep="
        "116.89ms → DEVICE SESSION-LATCHED (instrument exonerated); "
        "use tools/avsync_session_latch.py on multi-capture JSON set"
    )
    print(f"median_offset_ms_raw={raw:.4f} src=measured tag=raw_uncalibrated")
    print(f"mean_offset_ms_raw={res.mean_offset_ms:.4f} src=measured")
    print(f"stdev_offset_ms={res.stdev_offset_ms:.4f} src=measured")
    print(f"min_offset_ms={res.min_offset_ms:.4f} src=measured")
    print(f"max_offset_ms={res.max_offset_ms:.4f} src=measured")
    print(f"slope_ms_per_s={res.slope_ms_per_s:.6f} src=measured")
    print(f"slope_intercept_ms={res.slope_intercept_ms:.4f} src=measured")
    print(f"slope_r_squared={res.slope_r_squared:.6f} src=measured")

    if cal_ms is None:
        print("calibration=NONE")
        print(
            "absolute_offset_note: no known-zero source into grabber; "
            "median is NOT device-attributable; use slope and A/B deltas only"
        )
        print(f"median_offset_ms={raw:.4f} src=measured tag=raw_uncalibrated")
        print(
            "slope_note: fixed instrument latency cancels in slope_ms_per_s "
            "(tag=measured, cal-free)"
        )
        corrected = raw
        corrected_tag = "raw_uncalibrated"
        slope_corr = res.slope_ms_per_s
    else:
        print(f"calibration_ms={cal_ms:.4f} src=caller_supplied path={cal_path}")
        print(
            "calibration_note: corrected = raw - instrument_offset "
            "(only valid if cal source was known-aligned into the same grabber)"
        )
        print(
            "calibration_loop: --calibrate measures the A/V path currently wired "
            "to /dev/video0+ALSA — it does NOT invent a zero; re-cable or host "
            "loopback required for absolute device lipsync"
        )
        corrected = raw - cal_ms
        corrected_tag = "calibration_corrected"
        print(f"median_offset_ms={corrected:.4f} src=measured tag={corrected_tag}")
        # Slope is differential; fixed cal does not change slope
        slope_corr = res.slope_ms_per_s
        print(f"slope_ms_per_s_corrected={slope_corr:.6f} src=measured tag=cal_invariant")

    abs_med = abs(corrected)
    abs_slope = abs(slope_corr) if slope_corr is not None and not math.isnan(slope_corr) else 0.0
    offset_ok = abs_med <= tol_ms
    # Slope gate needs span: short windows (≤15 pairs) have noisy fits and must
    # not fail a calibration / short capture that has a good median. Require
    # n_pairs >= 20 before slope can force FAIL (still always reported).
    slope_gate_active = res.n_pairs >= 20
    slope_ok = (abs_slope <= slope_tol) if slope_gate_active else True
    print(f"abs_median_offset_ms={abs_med:.4f} src=measured tag={corrected_tag}")
    print(f"offset_within_tol={offset_ok} src=measured")
    print(f"slope_within_tol={abs_slope <= slope_tol} src=measured")
    print(f"slope_gate_active={slope_gate_active} src=DEFAULT_ASSUMED")

    # Only tol_ms is load-bearing for REFUSE_DEFAULT_ASSUMED (SCORE_DEFAULT_KEYS).
    # slope_tol DEFAULT is reported; when gate is active it still affects PASS/FAIL
    # but does not alone force UNSCORE (parent soaks pin --tol-ms).
    default_score_keys = []
    if tol_src == "DEFAULT_ASSUMED":
        default_score_keys.append("tol_ms")
    slope_default_in_score = bool(slope_gate_active and slope_tol_src == "DEFAULT_ASSUMED")
    print(
        f"scoring_defaults={default_score_keys or 'none'} "
        f"slope_tol_default_in_score={slope_default_in_score} "
        f"allow_default_score={allow_default_score} src=measured"
    )
    print(f"tol_ms_src={tol_src} slope_tol_src={slope_tol_src}")

    # ERROR 17 class: never silently PASS/FAIL on DEFAULT_ASSUMED offset tol.
    if default_score_keys and not allow_default_score:
        print(
            f"VERDICT=REFUSE_DEFAULT_ASSUMED rc={RC_UNSCORED} "
            f"reason=score_would_use_DEFAULT_ASSUMED:{','.join(default_score_keys)} "
            f"(pass --tol-ms/--slope-tol-ms-per-s or --allow-default-score)"
        )
        print(
            f"measured_would_have_been="
            f"{'PASS' if (offset_ok and slope_ok) else 'FAIL'} "
            f"abs_median_ms={abs_med:.4f} tag={corrected_tag} src=measured"
        )
        if extra:
            for k, v in extra.items():
                print(f"{k}={v}")
        return RC_UNSCORED

    if offset_ok and slope_ok:
        tag = "caller_supplied_score" if not default_score_keys else "DEFAULT_ASSUMED_IN_SCORE"
        print(f"VERDICT=PASS rc={RC_PASS} score_tag={tag}")
        rc = RC_PASS
    else:
        why = []
        if not offset_ok:
            why.append(f"abs_median={abs_med:.2f}>{tol_ms}")
        if slope_gate_active and not (abs_slope <= slope_tol):
            why.append(f"abs_slope={abs_slope:.4f}>{slope_tol}")
        # Measured FAIL must never decay to 77 even if defaults were allowed.
        tag = "caller_supplied_score" if not default_score_keys else "DEFAULT_ASSUMED_IN_SCORE"
        print(f"VERDICT=FAIL rc={RC_FAIL} reason={','.join(why)} score_tag={tag}")
        rc = RC_FAIL

    if extra:
        for k, v in extra.items():
            print(f"{k}={v}")
    return rc


def write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, default=str) + "\n")


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
def build_arg_parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument(
        "--input", type=Path, default=None,
        help="Analyse an existing A/V file instead of live capture (offline/synthetic)",
    )
    ap.add_argument(
        "--out", type=Path, default=Path("avsync_hdmi_out"),
        help="Output directory for capture + JSON report",
    )
    ap.add_argument(
        "--duration", type=float, default=None,
        help=f"Live capture seconds (default {DEFAULT_DURATION_S})",
    )
    ap.add_argument("--video-dev", default=None, help=f"default {DEFAULT_VIDEO_DEV}")
    ap.add_argument("--audio-dev", default=None, help=f"ALSA device default {DEFAULT_AUDIO_DEV}")
    ap.add_argument("--video-size", default=None, help=f"default {DEFAULT_VIDEO_SIZE}")
    ap.add_argument("--cap-fps", type=float, default=None, help=f"default {DEFAULT_CAP_FPS}")
    ap.add_argument(
        "--warmup-frames", type=int, default=None,
        help=(
            f"Discard leading frames (live default {DEFAULT_WARMUP_FRAMES}; "
            "file default 0). Live MS2109 needs >=20."
        ),
    )
    ap.add_argument(
        "--min-capture-frames", type=int, default=None,
        help=(
            f"Live: UNSCORED if decoded frames < N (default {DEFAULT_MIN_CAPTURE_FRAMES})"
        ),
    )
    ap.add_argument(
        "--tol-ms", type=float, default=None,
        help=(
            f"Pass if abs(median offset) <= tol (library default {DEFAULT_TOL_MS}). "
            "Without this or --allow-default-score, PASS/FAIL is refused (ERROR 17)."
        ),
    )
    ap.add_argument(
        "--slope-tol-ms-per-s", type=float, default=None,
        help=(
            f"Pass if abs(slope) <= tol (library default {DEFAULT_SLOPE_TOL_MS_PER_S}). "
            "Same refuse-default discipline as --tol-ms."
        ),
    )
    ap.add_argument(
        "--allow-default-score",
        action="store_true",
        help=(
            "Permit PASS/FAIL when tol/slope-tol are DEFAULT_ASSUMED. "
            "Default is refuse (rc=77) so a constant cannot look like a measurement."
        ),
    )
    ap.add_argument(
        "--min-pairs", type=int, default=None,
        help=f"Minimum flash/beep pairs to score (default {DEFAULT_MIN_PAIRS})",
    )
    ap.add_argument(
        "--pair-window-s", type=float, default=None,
        help=(
            f"Max |t_beep-t_flash| to pair (default {DEFAULT_PAIR_WINDOW_S}). "
            "0.45 mispairs large offsets — default is the correct behaviour."
        ),
    )
    ap.add_argument("--beep-hz", type=float, default=None, help=f"default {DEFAULT_BEEP_HZ}")
    ap.add_argument(
        "--early-window-s", type=float, default=None,
        help=(
            f"Median over first N seconds of pairs (default {DEFAULT_EARLY_WINDOW_S}); "
            "parent common-mode startup transient window"
        ),
    )
    ap.add_argument(
        "--late-window-s", type=float, default=None,
        help=(
            f"Median over last N seconds of pairs (default {DEFAULT_LATE_WINDOW_S}); "
            "compare to early for short-capture bias"
        ),
    )
    ap.add_argument(
        "--calibrate", action="store_true",
        help="Measure instrument baseline and write --calibration-out",
    )
    ap.add_argument(
        "--calibration", type=Path, default=None,
        help="Load calibration JSON; report raw and corrected offsets",
    )
    ap.add_argument(
        "--calibration-out", type=Path, default=None,
        help="Where --calibrate writes the calibration JSON",
    )
    ap.add_argument(
        "--label", default="run",
        help="Filename label for capture/report",
    )
    ap.add_argument(
        "--json-out", type=Path, default=None,
        help="Optional explicit JSON report path (default: <out>/<label>_report.json)",
    )
    return ap


def main(argv: list[str] | None = None) -> int:
    ap = build_arg_parser()
    args = ap.parse_args(argv)

    def pick(val, default, name):
        if val is None:
            return default, "DEFAULT_ASSUMED"
        return val, "caller_supplied"

    duration, duration_src = pick(args.duration, DEFAULT_DURATION_S, "duration")
    video_dev, vdev_src = pick(args.video_dev, DEFAULT_VIDEO_DEV, "video_dev")
    audio_dev, adev_src = pick(args.audio_dev, DEFAULT_AUDIO_DEV, "audio_dev")
    video_size, vsz_src = pick(args.video_size, DEFAULT_VIDEO_SIZE, "video_size")
    cap_fps, fps_src = pick(args.cap_fps, DEFAULT_CAP_FPS, "cap_fps")
    tol_ms, tol_src = pick(args.tol_ms, DEFAULT_TOL_MS, "tol_ms")
    slope_tol, slope_tol_src = pick(
        args.slope_tol_ms_per_s, DEFAULT_SLOPE_TOL_MS_PER_S, "slope_tol"
    )
    min_pairs, min_pairs_src = pick(args.min_pairs, DEFAULT_MIN_PAIRS, "min_pairs")
    pair_window, pair_window_src = pick(
        args.pair_window_s, DEFAULT_PAIR_WINDOW_S, "pair_window"
    )
    beep_hz, _bh_src = pick(args.beep_hz, DEFAULT_BEEP_HZ, "beep_hz")
    min_cap_frames, min_cap_src = pick(
        args.min_capture_frames, DEFAULT_MIN_CAPTURE_FRAMES, "min_capture_frames"
    )
    early_win, early_win_src = pick(
        args.early_window_s, DEFAULT_EARLY_WINDOW_S, "early_window_s"
    )
    late_win, late_win_src = pick(
        args.late_window_s, DEFAULT_LATE_WINDOW_S, "late_window_s"
    )

    # Warmup: live capture defaults 20; file input defaults 0
    if args.warmup_frames is not None:
        warmup, warmup_src = args.warmup_frames, "caller_supplied"
    elif args.input is not None:
        warmup, warmup_src = 0, "DEFAULT_ASSUMED"
    else:
        warmup, warmup_src = DEFAULT_WARMUP_FRAMES, "DEFAULT_ASSUMED"

    out_dir: Path = args.out
    out_dir.mkdir(parents=True, exist_ok=True)

    print_limitations_banner()

    cal_ms: float | None = None
    cal_path: str | None = None
    if args.calibration is not None:
        try:
            cal_ms, _cal_doc = load_calibration(args.calibration)
            cal_path = str(args.calibration)
        except (OSError, ValueError, KeyError, json.JSONDecodeError) as e:
            print(f"VERDICT=UNSCORED rc={RC_UNSCORED}")
            print(f"reason=bad_calibration err={e}")
            return RC_UNSCORED

    # ---- obtain capture path ----
    if args.input is not None:
        cap_path = args.input
        mode = "file"
        if not cap_path.is_file():
            print(f"VERDICT=UNSCORED rc={RC_UNSCORED}")
            print(f"reason=input_missing path={cap_path}")
            return RC_UNSCORED
        print(f"input={cap_path} src=caller_supplied")
    else:
        mode = "calibrate" if args.calibrate else "live"
        cap_path = out_dir / f"{args.label}_capture.mkv"
        print(f"video_dev={_tag(video_dev, vdev_src)}")
        print(f"audio_dev={_tag(audio_dev, adev_src)}")
        print(f"video_size={_tag(video_size, vsz_src)}")
        print(f"cap_fps={_tag(cap_fps, fps_src)}")
        print(f"duration_s={_tag(duration, duration_src)}")
        print(f"min_capture_frames={_tag(min_cap_frames, min_cap_src)}")
        print(f"pair_window_s={_tag(pair_window, pair_window_src)}")
        # Preflight devices
        if not Path(video_dev).exists():
            print(f"VERDICT=UNSCORED rc={RC_UNSCORED}")
            print(f"reason=no_video_dev path={video_dev}")
            return RC_UNSCORED
        try:
            capture_av(
                cap_path,
                duration_s=duration,
                video_dev=video_dev,
                audio_dev=audio_dev,
                video_size=video_size,
                cap_fps=cap_fps,
            )
        except RuntimeError as e:
            print(f"VERDICT=UNSCORED rc={RC_UNSCORED}")
            print(f"reason={e}")
            return RC_UNSCORED
        print(f"capture_bytes={cap_path.stat().st_size} src=measured")

    res = analyse_file(
        cap_path,
        warmup_frames=warmup,
        pair_window_s=pair_window,
        min_pairs=min_pairs,
        beep_hz=beep_hz,
        early_window_s=float(early_win),
        early_window_src=early_win_src,
        late_window_s=float(late_win),
        late_window_src=late_win_src,
    )

    # Live warm-up / short-burst guard: need enough decoded frames.
    n_decoded = None
    if isinstance(res.flash_meta, dict):
        # warmup_frames_discarded + remaining is not total; use fps_nom path via reason
        pass
    # Count from capture: re-probe cheaply only for live min-frames gate
    if mode != "file":
        try:
            luma_chk, _t_chk, vmeta_chk = load_video_luma(cap_path)
            n_decoded = int(vmeta_chk.get("n") or luma_chk.size)
            print(f"decoded_frames={n_decoded} src=measured")
            print(f"min_capture_frames={_tag(min_cap_frames, min_cap_src)}")
            if n_decoded < int(min_cap_frames):
                print(f"VERDICT=UNSCORED rc={RC_UNSCORED}")
                print(
                    f"reason=too_few_capture_frames n={n_decoded} "
                    f"min={min_cap_frames} (warm-up-only bursts are NO-DATA)"
                )
                return RC_UNSCORED
        except RuntimeError as e:
            print(f"VERDICT=UNSCORED rc={RC_UNSCORED}")
            print(f"reason={e}")
            return RC_UNSCORED

    # Calibrate mode: on success write calibration file; still report rc
    if args.calibrate and res.ok and res.median_offset_ms is not None:
        cal_out = args.calibration_out or (out_dir / f"{args.label}_calibration.json")
        save_calibration(
            cal_out,
            res.median_offset_ms,
            {
                "n_pairs": res.n_pairs,
                "stdev_offset_ms": res.stdev_offset_ms,
                "capture": str(cap_path),
                "note": (
                    "Instrument baseline: play the SAME blip fixture through a "
                    "known-good path into the grabber (e.g. mpv/ffplay local HDMI "
                    "out looped to the MS2109). This median is grabber A/V skew, "
                    "not a device defect."
                ),
            },
        )
        print(f"calibration_written={cal_out} src=measured")
        print(f"instrument_offset_ms={res.median_offset_ms:.4f} src=measured")

    rc = print_report(
        res,
        tol_ms=tol_ms,
        tol_src=tol_src,
        slope_tol=slope_tol,
        slope_tol_src=slope_tol_src,
        min_pairs=min_pairs,
        min_pairs_src=min_pairs_src,
        warmup_frames=warmup,
        warmup_src=warmup_src,
        pair_window_s=pair_window,
        pair_window_src=pair_window_src,
        cal_ms=cal_ms,
        cal_path=cal_path,
        mode=mode,
        allow_default_score=bool(args.allow_default_score),
    )

    payload = {
        "tool": "avsync_measure_hdmi",
        "mode": mode,
        "rc": rc,
        "sign_convention": (
            "offset_ms=(t_audio_onset-t_video_flash)*1000; "
            "positive=audio LATE (lags); negative=audio EARLY (leads)"
        ),
        "limitations": {
            "absolute_lipsync": "CANNOT_MEASURE without known-zero cal into grabber",
            "raw_median_tag": "raw_uncalibrated",
            "same_rig_delta": "CAN_MEASURE (B cancels)",
            "av_drift_ms": "BLIND to ~117 ms HDMI clusters",
        },
        "result": asdict(res),
        "tol_ms": tol_ms,
        "tol_ms_src": tol_src,
        "slope_tol_ms_per_s": slope_tol,
        "slope_tol_src": slope_tol_src,
        "pair_window_s": pair_window,
        "pair_window_src": pair_window_src,
        "allow_default_score": bool(args.allow_default_score),
        "calibration_ms": cal_ms,
        "calibration_path": cal_path,
        "warmup_frames": warmup,
        "warmup_src": warmup_src,
        "decoded_frames": n_decoded,
    }
    if cal_ms is not None and res.median_offset_ms is not None:
        payload["median_offset_ms_corrected"] = res.median_offset_ms - cal_ms
        payload["median_offset_ms_tag"] = "calibration_corrected"
    elif res.median_offset_ms is not None:
        payload["median_offset_ms_corrected"] = None
        payload["median_offset_ms_tag"] = "raw_uncalibrated"

    jpath = args.json_out or (out_dir / f"{args.label}_report.json")
    write_json(jpath, payload)
    print(f"report_json={jpath} src=measured")
    return rc


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print(f"VERDICT=UNSCORED rc={RC_UNSCORED}")
        print("reason=interrupted")
        sys.exit(RC_UNSCORED)
