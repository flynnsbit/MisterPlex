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

CAPTURE ARGV (binding)
----------------------
Live capture MUST stamp both inputs with wallclock and preserve timestamps:
  -use_wallclock_as_timestamps 1 on v4l2 and alsa, plus -copyts -start_at_zero.
Without that, ffmpeg normalises each live input's first packet to t=0
independently and absorbs the v4l2-vs-ALSA USB startup race into the alignment
(OLD-argv artifact: false ~117 ms multi-modality; RETRACTED 2026-08-01).
Do not pool runs across capture-config fingerprints (MIXED_CAPTURE_CONFIG).

NEW-argv residual (parent, n=16): between-run median range 25.00 ms. Per-pair
flash quant T≈33 ms does NOT set the median floor after averaging
(SE(median)≈1.8 ms, E[range 16]≈6.4 ms) — ~20 ms remains unattributed.
Short captures are biased by a ~25 ms early-vs-late startup transient.
This tool always prints first_pair_* and early/late window medians.

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
    tag=raw_uncalibrated. B cancels in same-rig DIFFERENCES and in slope under
    the same capture-config fingerprint. Never promote raw_uncalibrated to
    an absolute claim.
  - Daemon av_drift_ms: servo deadband readout, not grabber ground truth.
  - PLXD frames_done / presents / drops on RBF c5382bee: frames_done is
    bank_vsync_count (ddr_frame_store), not content frames — VOID. This tool
    never reads companion telemetry; audio is ALSA on the MS2109 grabber.
  - md5 / mean-luma freeze or health (invalid both directions on this project).

AUDIO SOURCE (common clock)
---------------------------
  MacroSilicon 534d:2109 exposes /dev/video0 (MJPEG) AND ALSA hw:CARD,0.
  ONE ffmpeg opens both with -use_wallclock_as_timestamps 1 so they share
  host wall time at open. Video is NOT the only stream on the grabber.

VISUAL MARKER vs 529×240 scanout
--------------------------------
  Fixture flash is full-frame white (drawbox w=iw h=ih) for ~2 frames @24.000.
  Survives 50% row + 17.3% column decimation; 1-px markers would not.

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
import hashlib
import json
import math
import os
import re
import statistics
import subprocess
import sys
import time
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any

import numpy as np

# ---------------------------------------------------------------------------
# Defaults — every one is labelled DEFAULT_ASSUMED when used without override
# ---------------------------------------------------------------------------
DEFAULT_VIDEO_DEV = "/dev/video0"
DEFAULT_AUDIO_DEV = "hw:0,0"  # ALSA; MS2109 parent-measured card 0 device 0
DEFAULT_VIDEO_SIZE = "1920x1080"
# PARENT-MEASURED against the actual grabber, do NOT raise without re-measuring:
#   v4l2-ctl -d /dev/video0 --list-formats-ext
#   MJPG 1920x1080 offers EXACTLY 30.000 fps and 25.000 fps. Nothing higher.
# A previous change set this to 60.0 ("still MS2109-capable") without checking.
# The hardware rejected it, every capture failed, and the tool reported the
# breakage as soft-skip rc=77 -- i.e. the only working A/V instrument in this
# project was silently dead. Frame quantisation is real but the fix is a ramped
# flash in the fixture, NOT a capture rate the hardware cannot deliver.
DEFAULT_CAP_FPS = 30.0
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
# Fixture geometry from scripts/gen_avsync_blip.py (quoted, not assumed):
#   flash_s = 2.0 / fps_val; enable='lt(mod(t,1), flash_s)'; beep 50 ms @ 1 kHz
# Host-measured on assets/avsync/sync_24fps_blip.mp4 (120 frames):
#   duty_hot=0.0833, hot pairs every 24 frames, contrast≈233, floor≈3.3 peak≈236
FIXTURE_FLASH_PERIOD_S = 1.0  # caller_supplied (generator integer-second cadence)
FIXTURE_FLASH_FRAMES = 2.0  # caller_supplied (generator: 2.0/fps)
FIXTURE_FPS = 24.0  # caller_supplied product RCA (ffprobe 24/1 — not 23.976)
FIXTURE_FLASH_DURATION_S = FIXTURE_FLASH_FRAMES / FIXTURE_FPS  # 0.083333 s
FIXTURE_FLASH_DUTY = FIXTURE_FLASH_DURATION_S / FIXTURE_FLASH_PERIOD_S  # 0.0833
FIXTURE_MIN_CONTRAST = 40.0  # DEFAULT_ASSUMED detector floor (file contrast >> 200)
# Min live capture so analysis span can hold N flash periods after warmup:
#   T >= warmup_s + N * period + 1.0 s margin
def min_capture_s_for_pairs(n_pairs: int, warmup_frames: int, cap_fps: float) -> float:
    warm_s = float(warmup_frames) / float(cap_fps) if cap_fps > 0 else 1.0
    return warm_s + float(n_pairs) * FIXTURE_FLASH_PERIOD_S + 1.0
CAL_FORMAT = "misterplex.avsync_hdmi_calibration.v1"

# Load-bearing scoring inputs that must not silently ride DEFAULT_ASSUMED
# (PARENT ERROR 17 class). Without --allow-default-score, PASS/FAIL is refused.
# Only tol_ms is mandatory: slope_tol may stay DEFAULT_ASSUMED when --tol-ms is
# set (still printed with src=DEFAULT_ASSUMED; score_tag notes it). Forcing both
# would UNSCORE every parent soak that only pins the offset band.
SCORE_DEFAULT_KEYS = ("tol_ms",)

RC_PASS = 0
RC_OFFSET_FAIL = 2       # measured lipsync offset out of tol (path/device)
RC_FAIL = RC_OFFSET_FAIL  # alias — unit tests / callers may still say FAIL
RC_INSTRUMENT_BROKEN = 3  # capture/tool broken (never soft-skip)
RC_DRIFT_FAIL = 4         # monotonic clock-rate mismatch (slope)
RC_WANDER_FAIL = 5        # high residual wander after detrend (scheduling)
RC_FIXTURE_FAIL = 6       # self-check audio/video ID failed when required
RC_UNSCORED = 77          # could-not-measure / margin inadequate / refuse default
# Distinct verdict *strings* always accompany rc — never collapse instrument vs
# device into the same (verdict, rc) pair (glass_template_skip defect).
# PROCESS DEFECT #6: rc=77 is NEVER a pass and never masks breakage (use 3).


def _tag(value: Any, src: str) -> str:
    """Format value with provenance tag."""
    if isinstance(value, float):
        return f"{value:.6g} src={src}"
    return f"{value} src={src}"


def _supported_cap_fps(video_dev: str, video_size: str) -> list[float]:
    """MEASURED list of MJPG frame rates the device offers at video_size.

    Returns [] when the capability cannot be read, so an unreadable device is
    NO-DATA (caller proceeds) rather than a false "unsupported" verdict.
    Absence of evidence is not evidence of absence.
    """
    try:
        r = subprocess.run(
            ["v4l2-ctl", "-d", video_dev, "--list-formats-ext"],
            capture_output=True, timeout=10,
        )
    except (OSError, subprocess.TimeoutExpired):
        return []
    if r.returncode != 0:
        return []
    rates: list[float] = []
    in_size = False
    for line in r.stdout.decode("utf-8", "replace").splitlines():
        s = line.strip()
        if s.startswith("Size:"):
            in_size = video_size in s
        elif in_size and "fps)" in s:
            m = re.search(r"\(([\d.]+)\s*fps\)", s)
            if m:
                rates.append(float(m.group(1)))
    return rates


def _run(cmd: list[str], timeout: float | None = None) -> subprocess.CompletedProcess[bytes]:
    return subprocess.run(cmd, capture_output=True, timeout=timeout)


# ---------------------------------------------------------------------------
# Capture
# ---------------------------------------------------------------------------
def build_capture_ffmpeg_argv(
    dest: Path,
    *,
    duration_s: float,
    video_dev: str,
    audio_dev: str,
    video_size: str,
    cap_fps: float,
    audio_sr: int = DEFAULT_AUDIO_SR,
) -> list[str]:
    """Exact live-capture ffmpeg argv (fingerprint source of truth).

    Wallclock on BOTH inputs + -copyts -start_at_zero is load-bearing:
    - wallclock: shared open clock (rd-review confound fix)
    - -copyts alone with wallclock: -t compares absolute epoch → truncates
      (parent-measured 33 KB / 6 s without -start_at_zero; 6.28 MB with it)
    """
    return [
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
        "-ar", str(audio_sr),
        "-i", audio_dev,
        "-map", "0:v:0",
        "-map", "1:a:0",
        "-copyts",
        "-start_at_zero",
        "-t", f"{duration_s:.3f}",
        "-c:v", "mjpeg",
        "-q:v", "5",
        "-c:a", "pcm_s16le",
        str(dest),
    ]


def capture_config_fingerprint(ffmpeg_argv: list[str] | None, *, mode: str) -> dict[str, Any]:
    """Stable capture-config stamp for JSON + bimodality mixing gate.

    Historical 15-run dataset is INVALID under corrected wallclock alignment
    (parent: median shifted ~90 ms). Classifier must HARD FAIL on mixed configs.
    Fingerprint is sha256 of the exact ffmpeg argv (or mode marker for file).
    """
    if ffmpeg_argv is None:
        canon = f"mode={mode}|no_live_ffmpeg_argv"
        argv_out: list[str] | None = None
    else:
        # Drop output path (last arg) so same capture recipe fingerprints equal
        # across out dirs; keep every flag that affects A/V alignment.
        args_for_hash = list(ffmpeg_argv)
        if args_for_hash and not args_for_hash[-1].startswith("-"):
            args_for_hash = args_for_hash[:-1] + ["<out>"]
        canon = "\0".join(args_for_hash)
        argv_out = list(ffmpeg_argv)
    digest = hashlib.sha256(canon.encode("utf-8")).hexdigest()
    return {
        "mode": mode,
        "ffmpeg_argv": argv_out,
        "fingerprint": f"sha256:{digest}",
        "fingerprint_src": "measured" if ffmpeg_argv is not None else "DEFAULT_ASSUMED",
        "canon_note": (
            "sha256 of NUL-joined argv with trailing output path replaced by <out>; "
            "live requires wallclock+copyts+start_at_zero"
        ),
    }


def preflight_capture_devices(video_dev: str, audio_dev: str) -> dict[str, Any]:
    """Host-side checks before live capture. Distinct VIDEO_BUSY vs missing."""
    meta: dict[str, Any] = {
        "video_dev": video_dev,
        "audio_dev": audio_dev,
        "video_busy": False,
        "video_busy_src": "measured",
        "preflight_ok": True,
        "preflight_reason": "",
    }
    # fuser: rc=0 means someone holds the device; rc=1 free / no fuser.
    try:
        fr = subprocess.run(
            ["fuser", video_dev],
            capture_output=True,
            text=True,
            timeout=5,
        )
        holders = (fr.stdout or "").strip() + " " + (fr.stderr or "").strip()
        if fr.returncode == 0 and holders.strip():
            meta["video_busy"] = True
            meta["video_holders"] = holders.strip()
            meta["preflight_ok"] = False
            meta["preflight_reason"] = (
                f"VIDEO_BUSY device={video_dev} holders={holders.strip()} "
                f"(not a zero; free the grabber)"
            )
            return meta
        meta["video_holders"] = holders.strip() or "none"
    except FileNotFoundError:
        meta["video_busy_src"] = "NO-DATA"
        meta["video_busy_note"] = "fuser_not_installed"
    except subprocess.TimeoutExpired:
        meta["video_busy_src"] = "NO-DATA"
        meta["video_busy_note"] = "fuser_timeout"

    if not Path(video_dev).exists():
        meta["preflight_ok"] = False
        meta["preflight_reason"] = f"VIDEO_MISSING path={video_dev}"
        return meta
    return meta


def capture_av(
    dest: Path,
    *,
    duration_s: float,
    video_dev: str,
    audio_dev: str,
    video_size: str,
    cap_fps: float,
) -> list[str]:
    """Capture video+audio in ONE ffmpeg process into one MKV.

    Both inputs use wallclock timestamps so v4l2 and ALSA share one clock at
    open (avoids independent first-packet→0 normalisation absorbing USB race).
    Parent multi-capture-within-session test: within-session median spread
    wallclock+copyts required; OLD-argv false multi-modality retracted; wallclock
    is still required hygiene.

    Returns the exact ffmpeg argv used (for capture_config fingerprint).
    """
    dest.parent.mkdir(parents=True, exist_ok=True)
    if dest.exists():
        dest.unlink()
    pf = preflight_capture_devices(video_dev, audio_dev)
    if not pf.get("preflight_ok", True):
        raise RuntimeError(f"CAPTURE_FAILED reason={pf.get('preflight_reason')}")
    cmd = build_capture_ffmpeg_argv(
        dest,
        duration_s=duration_s,
        video_dev=video_dev,
        audio_dev=audio_dev,
        video_size=video_size,
        cap_fps=cap_fps,
    )
    try:
        r = _run(cmd, timeout=duration_s + 90.0)
    except FileNotFoundError as e:
        raise RuntimeError("CAPTURE_FAILED reason=missing_ffmpeg") from e
    except subprocess.TimeoutExpired as e:
        raise RuntimeError("CAPTURE_FAILED reason=ffmpeg_timeout") from e
    if r.returncode != 0 or not dest.exists() or dest.stat().st_size < 1000:
        err = (r.stderr or b"").decode("utf-8", "replace").strip().splitlines()
        tail = err[-1] if err else "no_stderr"
        low = tail.lower()
        if "busy" in low or "resource busy" in low:
            raise RuntimeError(
                f"CAPTURE_FAILED reason=VIDEO_BUSY log={tail} "
                f"(distinct from zero-measurement; fuser -v {video_dev})"
            )
        raise RuntimeError(
            f"CAPTURE_FAILED rc={r.returncode} out={dest} size="
            f"{dest.stat().st_size if dest.exists() else 0} log={tail}"
        )
    return cmd


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
def classify_no_flash_failure(
    *,
    n_beeps: int,
    n_flashes: int,
    flash_meta: dict[str, Any],
    beep_meta: dict[str, Any] | None = None,
    min_pairs: int = 3,
) -> dict[str, Any]:
    """Discriminate beeps>0/flashes=0 (and related) — never collapse to one blob.

    Modes (parent T3):
      DISPLAY_FLAT — span long enough for expected flashes, but luma contrast
        below detector floor (black / frozen / idle / no flash on glass).
      WINDOW_TOO_SHORT — analysis span cannot hold min_pairs flash periods
        (warmup ate the window, or --duration too small).
      THRESHOLD_NO_TRIGGER — contrast OK (>= min) but zero onsets (threshold
        / separation bug or non-flash bright content).
      NO_AV_MARKERS — neither beeps nor flashes (wrong fixture or silent/static).
      AUDIO_ONLY_OK — beeps present, flashes zero (alias of above modes with
        audio leg proven).
    """
    out: dict[str, Any] = {
        "no_flash_class": "UNKNOWN",
        "no_flash_class_src": "derived",
        "n_beeps": int(n_beeps),
        "n_flashes": int(n_flashes),
        "n_beeps_src": "measured",
        "n_flashes_src": "measured",
    }
    reason = str(flash_meta.get("reason") or "")
    contrast = flash_meta.get("luma_contrast")
    min_c = float(flash_meta.get("min_contrast_required") or FIXTURE_MIN_CONTRAST)
    span = float(flash_meta.get("analysis_span_s") or 0.0)
    expected = int(flash_meta.get("expected_flashes_in_span") or 0)
    need_span = float(min_pairs) * FIXTURE_FLASH_PERIOD_S
    out["analysis_span_s"] = span
    out["analysis_span_s_src"] = str(flash_meta.get("analysis_span_s_src") or "NO-DATA")
    out["expected_flashes_in_span"] = expected
    out["expected_flashes_src"] = str(
        flash_meta.get("expected_flashes_src") or "NO-DATA"
    )
    out["min_pairs_span_s"] = need_span
    out["min_pairs_span_s_src"] = "derived"
    out["luma_contrast"] = contrast
    out["luma_contrast_src"] = "measured" if contrast is not None else "NO-DATA"
    out["min_contrast_required"] = min_c
    out["min_contrast_required_src"] = str(
        flash_meta.get("min_contrast_required_src") or "DEFAULT_ASSUMED"
    )
    out["flash_reason"] = reason
    out["fixture_flash_duty"] = FIXTURE_FLASH_DUTY
    out["fixture_flash_duty_src"] = "caller_supplied_gen_avsync_blip"
    out["fixture_flash_duration_s"] = FIXTURE_FLASH_DURATION_S
    out["fixture_flash_duration_s_src"] = "caller_supplied_gen_avsync_blip"
    # Host-measured file duty (sync_24fps_blip 120f): 0.0833 — matches generator.
    out["host_file_duty_blip24"] = 0.0833
    out["host_file_duty_blip24_src"] = "measured_assets_avsync_sync_24fps_blip"

    if n_flashes > 0:
        out["no_flash_class"] = "FLASHES_PRESENT"
        out["detail"] = "not_a_no_flash_failure"
        return out

    if reason in ("no_frames", "too_few_frames_after_warmup"):
        out["no_flash_class"] = "WINDOW_TOO_SHORT"
        out["detail"] = f"reason={reason} analysis_n_frames={flash_meta.get('analysis_n_frames')}"
        return out

    if span + 1e-9 < need_span:
        out["no_flash_class"] = "WINDOW_TOO_SHORT"
        out["detail"] = (
            f"analysis_span_s={span:.3f} < min_pairs*period={need_span:.3f} "
            f"(need duration >= warmup_s + {min_pairs}*1.0s + 1.0s margin)"
        )
        return out

    if contrast is not None and float(contrast) < min_c:
        # Long enough window, flat luma → glass not flashing (or capture of idle).
        out["no_flash_class"] = "DISPLAY_FLAT"
        out["detail"] = (
            f"luma_contrast={contrast} < min={min_c}; "
            f"expected_flashes_in_span={expected} but peak≈floor; "
            f"n_beeps={n_beeps} (audio leg "
            f"{'OK' if n_beeps > 0 else 'also_empty'})"
        )
        if n_beeps > 0:
            out["audio_leg"] = "OK_beeps_detected"
            out["audio_leg_src"] = "measured"
            out["implication"] = (
                "HDMI audio path works; video path shows no flash contrast. "
                "On a recovered device this is fixture/cast/idle — not ALSA."
            )
        else:
            out["audio_leg"] = "NO_BEEPS"
            out["audio_leg_src"] = "measured"
        return out

    if contrast is not None and float(contrast) >= min_c:
        out["no_flash_class"] = "THRESHOLD_NO_TRIGGER"
        out["detail"] = (
            f"luma_contrast={contrast} >= min={min_c} but n_flashes=0 "
            f"reason={reason or 'no_onset'}; detector/threshold bug or "
            f"non-flash bright field"
        )
        return out

    if n_beeps == 0 and n_flashes == 0:
        out["no_flash_class"] = "NO_AV_MARKERS"
        out["detail"] = "no beeps and no flashes"
        return out

    out["no_flash_class"] = "UNKNOWN"
    out["detail"] = f"unclassified reason={reason}"
    return out


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
    MIN_CONTRAST = float(FIXTURE_MIN_CONTRAST)
    meta["min_contrast_required"] = MIN_CONTRAST
    meta["min_contrast_required_src"] = "DEFAULT_ASSUMED"
    # Span of analysed video (after warmup) — used by no-flash discriminator.
    if tt.size >= 2:
        meta["analysis_span_s"] = float(tt[-1] - tt[0])
    elif tt.size == 1:
        meta["analysis_span_s"] = 0.0
    else:
        meta["analysis_span_s"] = 0.0
    meta["analysis_n_frames"] = int(lu.size)
    meta["analysis_span_s_src"] = "measured"
    # Expected flashes if fixture is 1 Hz full-frame white (generator contract).
    span = float(meta["analysis_span_s"])
    meta["fixture_flash_period_s"] = FIXTURE_FLASH_PERIOD_S
    meta["fixture_flash_period_s_src"] = "caller_supplied"
    meta["fixture_flash_duration_s"] = FIXTURE_FLASH_DURATION_S
    meta["fixture_flash_duration_s_src"] = "caller_supplied_gen_avsync_blip"
    meta["fixture_flash_duty"] = FIXTURE_FLASH_DUTY
    meta["fixture_flash_duty_src"] = "caller_supplied_gen_avsync_blip"
    meta["expected_flashes_in_span"] = (
        int(math.floor(span / FIXTURE_FLASH_PERIOD_S)) if span > 0 else 0
    )
    meta["expected_flashes_src"] = "derived_from_span_and_fixture_period"
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
    flash_hold_ms: list[float] = []
    flash_hold_frames: list[int] = []
    n_step = 0
    n_interp = 0
    i = 0
    while i < hot.size:
        if not hot[i]:
            i += 1
            continue
        run_start = i
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
        # Hold = first-hot → first-cold (or last-hot+period). Measured event
        # duration for margin (never assume 2/24 when PTS span is available).
        run_end = i  # first cold index, or len
        n_hot = int(run_end - run_start)
        flash_hold_frames.append(n_hot)
        t_a = float(tt[run_start])
        if run_end < tt.size:
            hold_ms = (float(tt[run_end]) - t_a) * 1000.0
        elif run_end - run_start >= 1 and tt.size >= 2:
            dt_loc = float(np.median(np.diff(tt)))
            hold_ms = (float(tt[run_end - 1]) - t_a + dt_loc) * 1000.0
        else:
            hold_ms = 0.0
        if hold_ms > 0:
            flash_hold_ms.append(hold_ms)
    meta["n_flashes"] = len(onsets)
    meta["flash_onset_n_step"] = n_step
    meta["flash_onset_n_interp"] = n_interp
    if flash_hold_ms:
        meta["flash_hold_ms_median"] = float(statistics.median(flash_hold_ms))
        meta["flash_hold_ms_min"] = float(min(flash_hold_ms))
        meta["flash_hold_ms_src"] = "measured"
    if flash_hold_frames:
        meta["flash_hold_frames_median"] = float(statistics.median(flash_hold_frames))
        meta["flash_hold_frames_min"] = int(min(flash_hold_frames))
        meta["flash_hold_frames_src"] = "measured"
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
    # Startup diagnostics (first pair + early/late windows)
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
    # Distribution beyond mean (parent: mean-only is a false PASS under judder)
    p05_offset_ms: float | None = None
    p95_offset_ms: float | None = None
    iqr_offset_ms: float | None = None
    # Timing class: STABLE | MONOTONIC_DRIFT | WANDER | INSUFFICIENT_SPAN
    timing_class: str = "NO-DATA"
    timing_class_reason: str = ""
    residual_rms_ms: float | None = None
    detrended_max_abs_ms: float | None = None
    # Sampling margin (ERROR 18/19 class)
    margin: dict[str, Any] = field(default_factory=dict)
    flash_meta: dict[str, Any] = field(default_factory=dict)
    beep_meta: dict[str, Any] = field(default_factory=dict)
    capture_path: str = ""
    audio_sr: int = 0


# Parent-measured common-mode startup transient windows (design defaults).
DEFAULT_EARLY_WINDOW_S = 10.0
DEFAULT_LATE_WINDOW_S = 60.0


def percentile_nearest(vals: list[float], p: float) -> float:
    """Inclusive percentile, nearest-rank (no numpy required for report path)."""
    if not vals:
        return float("nan")
    s = sorted(vals)
    if len(s) == 1:
        return float(s[0])
    k = (len(s) - 1) * (p / 100.0)
    f = int(math.floor(k))
    c = int(math.ceil(k))
    if f == c:
        return float(s[f])
    return float(s[f] * (c - k) + s[c] * (k - f))


def classify_timing(
    pairs: list[dict[str, float]],
    slope_ms_per_s: float,
    r2: float,
    *,
    slope_tol: float,
    wander_rms_tol_ms: float,
    min_pairs_class: int = 8,
) -> dict[str, Any]:
    """Distinguish monotonic drift vs residual wander vs stable.

    Mean offset alone is blind to judder-class defects (parent): exact average
    rate with ±1–2 refresh wander still looks wrong. Residual after linear
    detrend is the wander metric.
    """
    out: dict[str, Any] = {
        "timing_class": "INSUFFICIENT_SPAN",
        "timing_class_src": "derived",
        "residual_rms_ms": None,
        "residual_rms_src": "NO-DATA",
        "detrended_max_abs_ms": None,
        "slope_r_squared": r2,
    }
    if len(pairs) < min_pairs_class:
        out["timing_class_reason"] = f"n_pairs={len(pairs)}<{min_pairs_class}"
        return out
    xs = [float(p["t_flash_s"]) for p in pairs]
    ys = [float(p["offset_ms"]) for p in pairs]
    if slope_ms_per_s is None or (isinstance(slope_ms_per_s, float) and math.isnan(slope_ms_per_s)):
        out["timing_class"] = "UNKNOWN_SLOPE"
        return out
    # residual = y - (slope*x + b); b from mean
    x_mean = sum(xs) / len(xs)
    y_mean = sum(ys) / len(ys)
    b = y_mean - slope_ms_per_s * x_mean
    resid = [y - (slope_ms_per_s * x + b) for x, y in zip(xs, ys)]
    rms = math.sqrt(sum(r * r for r in resid) / len(resid))
    out["residual_rms_ms"] = rms
    out["residual_rms_src"] = "measured"
    out["detrended_max_abs_ms"] = max(abs(r) for r in resid)
    out["detrend_intercept_ms"] = b
    abs_slope = abs(slope_ms_per_s)
    # High r2 + slope beyond tol → clock-rate mismatch
    if abs_slope > slope_tol and (math.isnan(r2) or r2 >= 0.5):
        out["timing_class"] = "MONOTONIC_DRIFT"
        out["timing_class_reason"] = (
            f"abs_slope={abs_slope:.4f}>{slope_tol} r2={r2}"
        )
        return out
    if rms > wander_rms_tol_ms:
        out["timing_class"] = "WANDER"
        out["timing_class_reason"] = (
            f"residual_rms_ms={rms:.3f}>{wander_rms_tol_ms} "
            f"(scheduling/judder-class; mean may still look fine)"
        )
        return out
    out["timing_class"] = "STABLE"
    out["timing_class_reason"] = (
        f"abs_slope={abs_slope:.4f}<={slope_tol} residual_rms_ms={rms:.3f}<={wander_rms_tol_ms}"
    )
    return out


def check_sampling_margin(
    *,
    capture_frame_period_ms: float | None,
    flash_event_ms: float,
    flash_event_src: str,
    audio_sr: int,
    beep_event_ms: float,
    beep_event_src: str,
    goertzel_win_ms: float,
    min_event_over_sample: float = 2.0,
    flash_hold_frames_median: float | None = None,
) -> dict[str, Any]:
    """Refuse verdict when sampling cannot resolve the marker (ERROR 18/19 class).

    Parent ERROR 19: 1-refresh hold (16.67 ms) vs 60 fps capture (16.67 ms) ⇒
    zero/negative margin; a 'skip' in the gap was unsampled hold.

    Gate (video): event must cover ≥2 capture samples. Prefer discrete
    flash_hold_frames_median when measured (encoder PTS can make continuous
    ms-ratio 1.97 for a true 2-frame flash). Continuous ratio is the fallback
    and still refuses ERROR19-class ratio≈1.0.
    """
    m: dict[str, Any] = {
        "margin_ok": True,
        "margin_verdict": "MARGIN_OK",
        "min_event_over_sample": min_event_over_sample,
        "min_event_over_sample_src": "DEFAULT_ASSUMED",
        "video_sample_period_ms": capture_frame_period_ms,
        "video_sample_period_src": "measured" if capture_frame_period_ms else "NO-DATA",
        "video_event_ms": flash_event_ms,
        "video_event_src": flash_event_src,
        "flash_hold_frames_median": flash_hold_frames_median,
        "audio_sample_period_ms": 1000.0 / float(audio_sr) if audio_sr > 0 else None,
        "audio_sample_rate_hz": audio_sr,
        "audio_sample_rate_src": "caller_supplied_or_default",
        "audio_event_ms": beep_event_ms,
        "audio_event_src": beep_event_src,
        "goertzel_win_ms": goertzel_win_ms,
        "reasons": [],
    }
    if capture_frame_period_ms is None or capture_frame_period_ms <= 0:
        m["margin_ok"] = False
        m["margin_verdict"] = "MARGIN_INADEQUATE"
        m["reasons"].append("video_sample_period_NO-DATA")
    else:
        v_ratio = flash_event_ms / capture_frame_period_ms
        m["video_event_over_sample"] = v_ratio
        m["video_margin_ms"] = flash_event_ms - min_event_over_sample * capture_frame_period_ms
        # Discrete path: ≥2 hot frames ⇒ resolvable flash (fixture is 2 frames).
        if flash_hold_frames_median is not None:
            m["video_margin_basis"] = "flash_hold_frames_median"
            if float(flash_hold_frames_median) + 1e-9 < min_event_over_sample:
                m["margin_ok"] = False
                m["margin_verdict"] = "MARGIN_INADEQUATE"
                m["reasons"].append(
                    f"flash_hold_frames_median={flash_hold_frames_median} < "
                    f"{min_event_over_sample} (ERROR19-class single-sample hold)"
                )
        else:
            m["video_margin_basis"] = "continuous_ms_ratio"
            # 2% relative slack: encoder PTS can make 2-frame holds look 1.97×.
            if v_ratio + 1e-9 < min_event_over_sample * 0.98:
                m["margin_ok"] = False
                m["margin_verdict"] = "MARGIN_INADEQUATE"
                m["reasons"].append(
                    f"video_event={flash_event_ms:.3f}ms < {min_event_over_sample}×"
                    f"period={capture_frame_period_ms:.3f}ms (ratio={v_ratio:.3f})"
                )
    if audio_sr <= 0:
        m["margin_ok"] = False
        m["margin_verdict"] = "MARGIN_INADEQUATE"
        m["reasons"].append("audio_sr_invalid")
    else:
        # Beep must cover ≥2 Goertzel windows for a rising-edge onset.
        need = 2.0 * goertzel_win_ms
        m["audio_need_ms"] = need
        m["audio_margin_ms"] = beep_event_ms - need
        if beep_event_ms + 1e-9 < need:
            m["margin_ok"] = False
            m["margin_verdict"] = "MARGIN_INADEQUATE"
            m["reasons"].append(
                f"beep_event={beep_event_ms:.3f}ms < 2×goertzel_win={need:.3f}ms"
            )
    return m



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

    if not flashes:
        if not fmeta.get("reason"):
            fmeta["reason"] = "zero_onsets"
        disc = classify_no_flash_failure(
            n_beeps=len(beeps),
            n_flashes=0,
            flash_meta=fmeta,
            beep_meta=bmeta,
            min_pairs=min_pairs,
        )
        fmeta["no_flash_discriminator"] = disc
        cls = str(disc.get("no_flash_class") or "UNKNOWN")
        return MeasureResult(
            ok=False,
            unscored=True,
            reason=f"no_flashes:{cls}:{fmeta['reason']}",
            n_flashes=0,
            n_beeps=len(beeps),
            flash_meta=fmeta,
            beep_meta=bmeta,
            capture_path=str(path),
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

    # First pair — always report; useful for startup latch diagnostics.
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
    res.p05_offset_ms = percentile_nearest(offs, 5.0)
    res.p95_offset_ms = percentile_nearest(offs, 95.0)
    q25 = percentile_nearest(offs, 25.0)
    q75 = percentile_nearest(offs, 75.0)
    res.iqr_offset_ms = float(q75 - q25)
    # Margin + timing class filled by caller with fixture event durations;
    # analyse_file sets audio_sr and a provisional margin using defaults.
    res.audio_sr = int(sr)
    cap_period = fmeta.get("capture_frame_period_ms")
    # Prefer measured flash hold (hot-run span). Fallback: 2 frames @ 24.000.
    if fmeta.get("flash_hold_ms_median") is not None:
        flash_event_ms = float(fmeta["flash_hold_ms_median"])
        flash_event_src = "measured_flash_hold_median"
    else:
        flash_event_ms = 2.0 / 24.0 * 1000.0
        flash_event_src = "DEFAULT_ASSUMED_2frames_at_24fps"
    beep_event_ms = float(DEFAULT_BEEP_MS)
    res.margin = check_sampling_margin(
        capture_frame_period_ms=float(cap_period) if cap_period is not None else None,
        flash_event_ms=flash_event_ms,
        flash_event_src=flash_event_src,
        audio_sr=int(sr),
        beep_event_ms=beep_event_ms,
        beep_event_src="DEFAULT_ASSUMED_fixture_50ms",
        goertzel_win_ms=float(bmeta.get("win_ms") or 20.0),
        flash_hold_frames_median=(
            float(fmeta["flash_hold_frames_median"])
            if fmeta.get("flash_hold_frames_median") is not None
            else None
        ),
    )
    if not res.margin.get("margin_ok", False):
        res.ok = False
        res.unscored = True
        res.reason = (
            "MARGIN_INADEQUATE:" + ",".join(res.margin.get("reasons") or ["unknown"])
        )
        res.timing_class = "MARGIN_INADEQUATE"
        res.timing_class_reason = res.reason
        return res
    # timing class uses slope_tol default here; print_report reclassifies with
    # caller slope_tol when scoring.
    tc = classify_timing(
        pairs, slope, r2, slope_tol=DEFAULT_SLOPE_TOL_MS_PER_S, wander_rms_tol_ms=12.0
    )
    res.timing_class = str(tc.get("timing_class"))
    res.timing_class_reason = str(tc.get("timing_class_reason") or "")
    res.residual_rms_ms = tc.get("residual_rms_ms")
    res.detrended_max_abs_ms = tc.get("detrended_max_abs_ms")
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
        "OLD-argv false multi-modality retracted; NEW residual ~25 ms range (parent)"
    )
    print(
        "DEFAULT_ASSUMED values are NEVER measurements; PASS/FAIL refused "
        "unless every scoring threshold is caller_supplied or "
        "--allow-default-score is set"
    )
    print(
        "RETRACTED device-latch claim (OLD-argv). NEW-argv: n=16 range 25 ms; "
        "SE(median) quant model E[range]~6.4 ms → ~20 ms unattributed; "
        "early-late ~25 ms common-mode startup transient; "
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
        if res.reason and str(res.reason).startswith("MARGIN_INADEQUATE"):
            print(f"VERDICT=MARGIN_INADEQUATE rc={RC_UNSCORED}")
        else:
            print(f"VERDICT=UNSCORED rc={RC_UNSCORED}")
        print(f"reason={res.reason or 'unscored'} src=measured")
        # T3 discriminator — never collapse beeps>0/flashes=0 into one blob
        disc = None
        if res.flash_meta and isinstance(res.flash_meta.get("no_flash_discriminator"), dict):
            disc = res.flash_meta["no_flash_discriminator"]
        elif res.n_flashes == 0:
            disc = classify_no_flash_failure(
                n_beeps=int(res.n_beeps),
                n_flashes=0,
                flash_meta=res.flash_meta or {},
                beep_meta=res.beep_meta,
                min_pairs=min_pairs,
            )
        if disc:
            print(f"no_flash_class={disc.get('no_flash_class')} src=derived")
            print(f"no_flash_detail={disc.get('detail')} src=derived")
            for k in (
                "analysis_span_s",
                "expected_flashes_in_span",
                "min_pairs_span_s",
                "luma_contrast",
                "min_contrast_required",
                "fixture_flash_duty",
                "fixture_flash_duration_s",
                "host_file_duty_blip24",
                "audio_leg",
                "implication",
            ):
                if k in disc and disc[k] is not None:
                    src_k = f"{k}_src"
                    src = disc.get(src_k, "derived")
                    print(f"{k}={disc[k]} src={src}")
            print(
                "discriminator_legend: DISPLAY_FLAT=glass/idle flat luma with "
                "long enough span; WINDOW_TOO_SHORT=span < min_pairs*1s; "
                "THRESHOLD_NO_TRIGGER=contrast OK but zero onsets"
            )
        if res.margin:
            print(f"margin_verdict={res.margin.get('margin_verdict')} src=derived")
            for rk in (
                "video_sample_period_ms",
                "video_event_ms",
                "video_event_over_sample",
                "audio_sample_rate_hz",
                "audio_event_ms",
                "audio_margin_ms",
            ):
                if rk in res.margin:
                    print(f"{rk}={res.margin.get(rk)} src=derived_or_measured")
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
    # First pair — always report (startup diagnostics)
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
            f"note=startup_transient_common_mode_parent_~25ms "
            f"(short_capture_bias)"
        )
    else:
        print(f"early_minus_late_ms=None src=NO-DATA")
    print(
        "session_latch_note: OLD Q4 DEVICE-LATCH claim RETRACTED (instrument artifact); "
        "use tools/avsync_session_latch.py for spread-only SESSION_STABLE; "
        "use tools/avsync_session_latch.py on multi-capture JSON set"
    )
    print(f"median_offset_ms_raw={raw:.4f} src=measured tag=raw_uncalibrated")
    print(f"mean_offset_ms_raw={res.mean_offset_ms:.4f} src=measured")
    print(f"stdev_offset_ms={res.stdev_offset_ms:.4f} src=measured")
    print(f"min_offset_ms={res.min_offset_ms:.4f} src=measured")
    print(f"p05_offset_ms={res.p05_offset_ms:.4f} src=measured")
    print(f"p95_offset_ms={res.p95_offset_ms:.4f} src=measured")
    print(f"iqr_offset_ms={res.iqr_offset_ms:.4f} src=measured")
    print(f"max_offset_ms={res.max_offset_ms:.4f} src=measured")
    print(
        "distribution_note: mean-only is forbidden — judder can keep mean≈0 while "
        "instantaneous offset wanders (parent video hold equality 29.9%)"
    )
    # Full time series (load-bearing for drift vs wander)
    print("offset_timeseries_ms (t_flash_s,offset_ms) src=measured:")
    for p in res.pairs:
        print(f"  ts={p['t_flash_s']:.6f},offset_ms={p['offset_ms']:.4f}")
    print(f"slope_ms_per_s={res.slope_ms_per_s:.6f} src=measured")
    print(f"slope_intercept_ms={res.slope_intercept_ms:.4f} src=measured")
    print(f"slope_r_squared={res.slope_r_squared:.6f} src=measured")
    # Reclassify with caller slope_tol + wander tol
    wander_tol = 12.0  # ms RMS after detrend; DEFAULT_ASSUMED
    tc = classify_timing(
        res.pairs,
        float(res.slope_ms_per_s) if res.slope_ms_per_s is not None else float("nan"),
        float(res.slope_r_squared) if res.slope_r_squared is not None else float("nan"),
        slope_tol=float(slope_tol),
        wander_rms_tol_ms=wander_tol,
    )
    res.timing_class = str(tc.get("timing_class"))
    res.timing_class_reason = str(tc.get("timing_class_reason") or "")
    res.residual_rms_ms = tc.get("residual_rms_ms")
    res.detrended_max_abs_ms = tc.get("detrended_max_abs_ms")
    print(f"timing_class={res.timing_class} src=derived")
    print(f"timing_class_reason={res.timing_class_reason} src=derived")
    print(
        f"residual_rms_ms={res.residual_rms_ms} src="
        f"{'measured' if res.residual_rms_ms is not None else 'NO-DATA'} "
        f"wander_rms_tol_ms={wander_tol} src=DEFAULT_ASSUMED"
    )
    print(
        f"detrended_max_abs_ms={res.detrended_max_abs_ms} src="
        f"{'measured' if res.detrended_max_abs_ms is not None else 'NO-DATA'}"
    )
    if res.margin:
        print(f"margin_verdict={res.margin.get('margin_verdict')} src=derived")
        print(
            f"video_sample_period_ms={res.margin.get('video_sample_period_ms')} "
            f"src={res.margin.get('video_sample_period_src')}"
        )
        print(
            f"video_event_ms={res.margin.get('video_event_ms')} "
            f"src={res.margin.get('video_event_src')}"
        )
        print(
            f"video_event_over_sample={res.margin.get('video_event_over_sample')} "
            f"src=derived"
        )
        print(
            f"audio_sample_rate_hz={res.margin.get('audio_sample_rate_hz')} "
            f"src={res.margin.get('audio_sample_rate_src')}"
        )
        print(
            f"audio_event_ms={res.margin.get('audio_event_ms')} "
            f"src={res.margin.get('audio_event_src')}"
        )
        print(
            f"audio_margin_ms={res.margin.get('audio_margin_ms')} src=derived "
            f"goertzel_win_ms={res.margin.get('goertzel_win_ms')}"
        )

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

    tag = "caller_supplied_score" if not default_score_keys else "DEFAULT_ASSUMED_IN_SCORE"
    # Distinct failure classes — never share one rc across instrument vs path.
    # Priority: OFFSET (level) → DRIFT (monotonic) → WANDER (residual) → PASS.
    verdict_name = "PASS"
    if not offset_ok:
        why = f"abs_median={abs_med:.2f}>{tol_ms}"
        print(f"VERDICT=OFFSET_FAIL rc={RC_OFFSET_FAIL} reason={why} score_tag={tag}")
        print(
            "verdict_note: OFFSET_FAIL is a measured lipsync level defect on this "
            "capture path (not instrument broken; not margin)"
        )
        rc = RC_OFFSET_FAIL
        verdict_name = "OFFSET_FAIL"
    elif res.timing_class == "MONOTONIC_DRIFT" and slope_gate_active:
        why = (
            f"timing_class=MONOTONIC_DRIFT abs_slope={abs_slope:.4f} "
            f"slope_tol={slope_tol} residual_rms_ms={res.residual_rms_ms}"
        )
        print(f"VERDICT=DRIFT_FAIL rc={RC_DRIFT_FAIL} reason={why} score_tag={tag}")
        print(
            "verdict_note: DRIFT_FAIL = clock-rate mismatch; fix differs from wander"
        )
        rc = RC_DRIFT_FAIL
        verdict_name = "DRIFT_FAIL"
    elif res.timing_class == "WANDER":
        why = (
            f"timing_class=WANDER residual_rms_ms={res.residual_rms_ms} "
            f"detrended_max_abs_ms={res.detrended_max_abs_ms} "
            f"(mean offset may still be inside tol — still a FAIL)"
        )
        print(f"VERDICT=WANDER_FAIL rc={RC_WANDER_FAIL} reason={why} score_tag={tag}")
        print(
            "verdict_note: WANDER_FAIL = scheduling/judder-class residual after "
            "detrend; mean-only would false-PASS"
        )
        rc = RC_WANDER_FAIL
        verdict_name = "WANDER_FAIL"
    elif slope_gate_active and not slope_ok:
        why = f"abs_slope={abs_slope:.4f}>{slope_tol}"
        print(f"VERDICT=DRIFT_FAIL rc={RC_DRIFT_FAIL} reason={why} score_tag={tag}")
        rc = RC_DRIFT_FAIL
        verdict_name = "DRIFT_FAIL"
    else:
        print(f"VERDICT=PASS rc={RC_PASS} score_tag={tag}")
        print(
            f"pass_note: timing_class={res.timing_class} residual_rms_ms="
            f"{res.residual_rms_ms} — PASS requires offset AND non-wander/non-drift"
        )
        rc = RC_PASS
        verdict_name = "PASS"

    if extra:
        for k, v in extra.items():
            print(f"{k}={v}")
    # One-line parent-grepable summary (never uses PLXD frames_done/presents/drops).
    sigma = res.stdev_offset_ms if res.stdev_offset_ms is not None else float("nan")
    se_med = (
        (1.2533 * sigma / math.sqrt(res.n_pairs))
        if res.n_pairs > 0 and not math.isnan(sigma)
        else float("nan")
    )
    # Uncertainty: max(SE_median, half capture-frame quant, instrument file RMSE~1ms)
    half_quant = 16.7  # DEFAULT_ASSUMED @30fps; overwritten if margin has period
    if res.margin and res.margin.get("video_sample_period_ms"):
        try:
            half_quant = 0.5 * float(res.margin["video_sample_period_ms"])
        except (TypeError, ValueError):
            pass
    u_ms = max(
        se_med if not math.isnan(se_med) else 0.0,
        half_quant,
        1.0,  # prove100 file-path residual floor
    )
    apair = "NO-DATA"
    rbf_m = "NO-DATA"
    dae_m = "NO-DATA"
    dsrc = "NO-DATA"
    if extra:
        apair = str(extra.get("artifact_pair") or apair)
        rbf_m = str(extra.get("rbf_md5") or rbf_m)
        dae_m = str(extra.get("daemon_md5") or dae_m)
        dsrc = str(extra.get("decode_src") or dsrc)
    print(
        f"SCORE offset_ms={corrected:.4f} sigma_ms={sigma:.4f} "
        f"se_median_ms={se_med:.4f} uncertainty_ms={u_ms:.4f} "
        f"n={res.n_pairs} timing_class={res.timing_class} "
        f"residual_rms_ms={res.residual_rms_ms} "
        f"tag={corrected_tag} verdict={verdict_name} "
        f"rc={rc} src=measured "
        f"rbf_md5={rbf_m} daemon_md5={dae_m} artifact_pair={apair} "
        f"decode_src={dsrc} "
        f"note=no_PLXD_frames_done_presents_drops_no_av_drift_ms"
    )
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
    ap.add_argument(
        "--self-test",
        action="store_true",
        help="Host-only unit checks (no /dev/video0). true rc via: ...; echo true rc=$?",
    )
    ap.add_argument(
        "--cpu-pct-json",
        type=Path,
        default=None,
        help="JSON from tools/avsync_sample_arm_cpu.sh (arm_cpu_pct concurrent with soak)",
    )
    ap.add_argument(
        "--artifacts-json",
        type=Path,
        default=None,
        help="JSON from tools/avsync_stamp_artifacts.sh (rbf_md5+daemon_md5 pair)",
    )
    ap.add_argument(
        "--decode-src",
        default=None,
        help="caller_supplied|conf|… — never pool across different decode_src",
    )
    return ap


def _self_test() -> int:
    """RED/GREEN host checks — no grabber required."""
    # argv must include wallclock + copyts + start_at_zero (parent regressions)
    argv = build_capture_ffmpeg_argv(
        Path("/tmp/out.mkv"),
        duration_s=6.0,
        video_dev="/dev/video0",
        audio_dev="hw:0,0",
        video_size="1920x1080",
        cap_fps=30.0,
    )
    joined = " ".join(argv)
    assert "-use_wallclock_as_timestamps" in argv, argv
    assert argv.count("-use_wallclock_as_timestamps") == 2, argv
    assert "-copyts" in argv, argv
    assert "-start_at_zero" in argv, argv
    assert argv.index("-copyts") < argv.index("-start_at_zero"), argv
    assert "-framerate" in argv and "30.0" in argv, argv
    assert "60" not in argv and "60.0" not in argv, "must not default to unsupported 60"
    print("SELF_TEST capture_argv wallclock+copyts+start_at_zero+fps30 OK")

    fp1 = capture_config_fingerprint(argv, mode="live")
    argv2 = build_capture_ffmpeg_argv(
        Path("/other/dir/run2.mkv"),
        duration_s=6.0,
        video_dev="/dev/video0",
        audio_dev="hw:0,0",
        video_size="1920x1080",
        cap_fps=30.0,
    )
    fp2 = capture_config_fingerprint(argv2, mode="live")
    assert fp1["fingerprint"] == fp2["fingerprint"], (fp1, fp2)
    print("SELF_TEST fingerprint stable across out paths OK")

    argv60 = build_capture_ffmpeg_argv(
        Path("x.mkv"),
        duration_s=6.0,
        video_dev="/dev/video0",
        audio_dev="hw:0,0",
        video_size="1920x1080",
        cap_fps=60.0,
    )
    fp60 = capture_config_fingerprint(argv60, mode="live")
    assert fp60["fingerprint"] != fp1["fingerprint"], "fps must change fingerprint"
    print("SELF_TEST fingerprint differs when cap_fps differs OK")

    # Severity ladder constants
    assert RC_PASS == 0 and RC_OFFSET_FAIL == 2 and RC_FAIL == 2
    assert RC_INSTRUMENT_BROKEN == 3
    assert RC_DRIFT_FAIL == 4 and RC_WANDER_FAIL == 5 and RC_FIXTURE_FAIL == 6
    assert RC_UNSCORED == 77
    assert len({RC_PASS, RC_OFFSET_FAIL, RC_INSTRUMENT_BROKEN, RC_DRIFT_FAIL,
                RC_WANDER_FAIL, RC_FIXTURE_FAIL, RC_UNSCORED}) == 7
    print(
        "SELF_TEST RC ladder PASS=0 OFFSET_FAIL=2 BROKEN=3 DRIFT=4 "
        "WANDER=5 FIXTURE=6 UNSCORED=77 OK"
    )
    # Margin gate: 16.67 ms event @ 16.67 ms period must be INADEQUATE (ERROR 19)
    bad = check_sampling_margin(
        capture_frame_period_ms=16.67,
        flash_event_ms=16.67,
        flash_event_src="caller_supplied",
        audio_sr=48000,
        beep_event_ms=50.0,
        beep_event_src="caller_supplied",
        goertzel_win_ms=20.0,
    )
    assert bad["margin_ok"] is False and bad["margin_verdict"] == "MARGIN_INADEQUATE", bad
    good = check_sampling_margin(
        capture_frame_period_ms=33.33,
        flash_event_ms=2.0 / 24.0 * 1000.0,
        flash_event_src="caller_supplied",
        audio_sr=48000,
        beep_event_ms=50.0,
        beep_event_src="caller_supplied",
        goertzel_win_ms=20.0,
    )
    assert good["margin_ok"] is True, good
    print("SELF_TEST margin ERROR19-class refuse + 24p@30cap OK")
    # timing class: flat → STABLE; ramp → DRIFT; noise → WANDER
    flat = [{"t_flash_s": float(i), "offset_ms": 5.0} for i in range(12)]
    tc = classify_timing(flat, 0.0, 0.0, slope_tol=0.5, wander_rms_tol_ms=12.0)
    assert tc["timing_class"] == "STABLE", tc
    drift_pairs = [{"t_flash_s": float(i), "offset_ms": 2.0 * i} for i in range(12)]
    sl, _, r2 = linreg_slope([p["t_flash_s"] for p in drift_pairs],
                             [p["offset_ms"] for p in drift_pairs])
    tc = classify_timing(drift_pairs, sl, r2, slope_tol=0.5, wander_rms_tol_ms=12.0)
    assert tc["timing_class"] == "MONOTONIC_DRIFT", tc
    print("SELF_TEST timing_class STABLE/DRIFT OK")

    # T3 no-flash discriminators (red/green)
    d_flat = classify_no_flash_failure(
        n_beeps=60,
        n_flashes=0,
        flash_meta={
            "reason": "insufficient_luma_contrast",
            "luma_contrast": 0.0,
            "min_contrast_required": 40.0,
            "min_contrast_required_src": "DEFAULT_ASSUMED",
            "analysis_span_s": 58.0,
            "analysis_span_s_src": "measured",
            "expected_flashes_in_span": 58,
            "expected_flashes_src": "derived",
        },
        min_pairs=3,
    )
    assert d_flat["no_flash_class"] == "DISPLAY_FLAT", d_flat
    d_short = classify_no_flash_failure(
        n_beeps=1,
        n_flashes=0,
        flash_meta={
            "reason": "insufficient_luma_contrast",
            "luma_contrast": 0.0,
            "min_contrast_required": 40.0,
            "analysis_span_s": 1.5,
            "expected_flashes_in_span": 1,
        },
        min_pairs=3,
    )
    assert d_short["no_flash_class"] == "WINDOW_TOO_SHORT", d_short
    d_thr = classify_no_flash_failure(
        n_beeps=10,
        n_flashes=0,
        flash_meta={
            "reason": "zero_onsets",
            "luma_contrast": 200.0,
            "min_contrast_required": 40.0,
            "analysis_span_s": 20.0,
            "expected_flashes_in_span": 20,
        },
        min_pairs=3,
    )
    assert d_thr["no_flash_class"] == "THRESHOLD_NO_TRIGGER", d_thr
    print("SELF_TEST no_flash_class DISPLAY_FLAT/WINDOW_TOO_SHORT/THRESHOLD OK")
    # Fixture duty from generator must match host file measurement
    assert abs(FIXTURE_FLASH_DUTY - 0.0833333333) < 1e-6, FIXTURE_FLASH_DUTY
    assert abs(min_capture_s_for_pairs(40, 20, 30.0) - (20/30 + 40 + 1.0)) < 1e-9
    print(
        f"SELF_TEST fixture_duty={FIXTURE_FLASH_DUTY:.4f} "
        f"min_capture_40pairs@30fps={min_capture_s_for_pairs(40,20,30):.2f}s OK"
    )

    # DEFAULT_CAP_FPS must be hardware-legal (parent-measured ≤30)
    assert DEFAULT_CAP_FPS <= 30.0 + 1e-9, DEFAULT_CAP_FPS
    print(f"SELF_TEST DEFAULT_CAP_FPS={DEFAULT_CAP_FPS} <=30 OK")

    # Preflight parser on canned v4l2-ctl text (no device)
    sample = (
        "ioctl: VIDIOC_ENUM_FMT\n"
        "\tType: Video Capture\n"
        "\t[0]: 'MJPG' (Motion-JPEG, compressed)\n"
        "\t\tSize: Discrete 1920x1080\n"
        "\t\t\tInterval: Discrete 0.033s (30.000 fps)\n"
        "\t\t\tInterval: Discrete 0.040s (25.000 fps)\n"
        "\t\tSize: Discrete 1280x720\n"
        "\t\t\tInterval: Discrete 0.016s (60.000 fps)\n"
    )

    class _Fake:
        returncode = 0
        stdout = sample.encode()

    real_run = subprocess.run

    def fake_run(cmd, capture_output=True, timeout=10):  # noqa: ARG001
        return _Fake()

    subprocess.run = fake_run  # type: ignore[assignment]
    try:
        rates = _supported_cap_fps("/dev/video0", "1920x1080")
        assert 30.0 in rates and 25.0 in rates, rates
        assert 60.0 not in rates, rates
        print(f"SELF_TEST supported_cap_fps 1080p={rates} OK")
    finally:
        subprocess.run = real_run  # type: ignore[assignment]

    print("SELF_TEST_OK")
    return 0


def main(argv: list[str] | None = None) -> int:
    ap = build_arg_parser()
    args = ap.parse_args(argv)
    if args.self_test:
        return _self_test()

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
    ffmpeg_argv: list[str] | None = None
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
        # Preflight devices — missing grabber is NO-DATA (UNSCORED), not broken tool.
        if not Path(video_dev).exists():
            print(f"VERDICT=UNSCORED rc={RC_UNSCORED}")
            print(f"reason=no_video_dev path={video_dev}")
            return RC_UNSCORED
        # Preflight CAPABILITY: refuse a rate the hardware does not offer, loudly.
        # A default of 60 fps was once asserted as "MS2109-capable" without being
        # checked; MJPG 1920x1080 offers only ≤30, so every capture failed and the
        # breakage hid behind soft-skip rc=77 (PROCESS DEFECT #6).
        rates = _supported_cap_fps(video_dev, video_size)
        if rates and not any(abs(cap_fps - r) < 0.5 for r in rates):
            print(f"VERDICT=INSTRUMENT_BROKEN rc={RC_INSTRUMENT_BROKEN}")
            print(
                f"reason=cap_fps_unsupported requested={cap_fps} "
                f"supported={sorted(rates)} src=measured dev={video_dev} size={video_size}"
            )
            return RC_INSTRUMENT_BROKEN
        try:
            ffmpeg_argv = capture_av(
                cap_path,
                duration_s=duration,
                video_dev=video_dev,
                audio_dev=audio_dev,
                video_size=video_size,
                cap_fps=cap_fps,
            )
        except RuntimeError as e:
            print(f"VERDICT=INSTRUMENT_BROKEN rc={RC_INSTRUMENT_BROKEN}")
            print(f"reason={e}")
            return RC_INSTRUMENT_BROKEN
        print(f"capture_bytes={cap_path.stat().st_size} src=measured")

    cap_cfg = capture_config_fingerprint(ffmpeg_argv, mode=mode)
    # Extend fingerprint inputs that affect pairing/scoring of the same capture.
    cap_cfg["cap_fps"] = float(cap_fps)
    cap_cfg["cap_fps_src"] = fps_src
    cap_cfg["video_size"] = str(video_size)
    cap_cfg["duration_s"] = float(duration) if mode != "file" else None
    cap_cfg["pair_window_s"] = float(pair_window)
    cap_cfg["pair_window_src"] = pair_window_src
    cap_cfg["warmup_frames"] = int(warmup)
    cap_cfg["warmup_src"] = warmup_src
    print(f"capture_config_fingerprint={cap_cfg['fingerprint']} src={cap_cfg['fingerprint_src']}")
    if ffmpeg_argv is not None:
        print(f"capture_ffmpeg_argv={' '.join(ffmpeg_argv)} src=measured")

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
    if mode != "file":
        try:
            luma_chk, _t_chk, vmeta_chk = load_video_luma(cap_path)
            n_decoded = int(vmeta_chk.get("n") or luma_chk.size)
            print(f"decoded_frames={n_decoded} src=measured")
            print(f"min_capture_frames={_tag(min_cap_frames, min_cap_src)}")
            if n_decoded < int(min_cap_frames):
                # If duration×fps should have delivered ≥ min frames, the instrument
                # (or truncated capture) is broken — not soft-skip NO-DATA.
                expected = float(duration) * float(cap_fps)
                if expected >= float(min_cap_frames):
                    print(f"VERDICT=INSTRUMENT_BROKEN rc={RC_INSTRUMENT_BROKEN}")
                    print(
                        f"reason=too_few_capture_frames n={n_decoded} "
                        f"min={min_cap_frames} expected_ge={expected:.1f} "
                        f"(truncated_or_grabber_fail; not soft-skip)"
                    )
                    # Still write JSON so fingerprint is on disk for forensics.
                    jpath = args.json_out or (out_dir / f"{args.label}_report.json")
                    write_json(
                        jpath,
                        {
                            "tool": "avsync_measure_hdmi",
                            "mode": mode,
                            "rc": RC_INSTRUMENT_BROKEN,
                            "capture_config": cap_cfg,
                            "decoded_frames": n_decoded,
                            "reason": "too_few_capture_frames",
                        },
                    )
                    print(f"report_json={jpath} src=measured")
                    return RC_INSTRUMENT_BROKEN
                print(f"VERDICT=UNSCORED rc={RC_UNSCORED}")
                print(
                    f"reason=too_few_capture_frames n={n_decoded} "
                    f"min={min_cap_frames} (caller duration too short for min frames)"
                )
                return RC_UNSCORED
        except RuntimeError as e:
            # Live capture produced a file we cannot decode → instrument broken.
            print(f"VERDICT=INSTRUMENT_BROKEN rc={RC_INSTRUMENT_BROKEN}")
            print(f"reason=decode_failed_after_capture err={e}")
            return RC_INSTRUMENT_BROKEN

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

    # Concurrent CPU is parent-supplied via --cpu-pct-json (soak wrapper).
    cpu_extra: dict[str, Any] = {}
    if getattr(args, "cpu_pct_json", None) is not None:
        try:
            cdoc = json.loads(Path(args.cpu_pct_json).read_text())
            cpu_extra["arm_cpu_pct"] = cdoc.get("arm_cpu_pct")
            cpu_extra["arm_cpu_pct_src"] = cdoc.get("arm_cpu_pct_src", "measured")
            cpu_extra["arm_cpu_sample_note"] = cdoc.get("note", "")
        except (OSError, json.JSONDecodeError, TypeError) as e:
            cpu_extra["arm_cpu_pct"] = None
            cpu_extra["arm_cpu_pct_src"] = "NO-DATA"
            cpu_extra["arm_cpu_pct_error"] = str(e)
    else:
        cpu_extra["arm_cpu_pct"] = None
        cpu_extra["arm_cpu_pct_src"] = "NO-DATA"
        cpu_extra["arm_cpu_pct_note"] = "pass --cpu-pct-json from soak wrapper"

    # Fleet rule: every measurement carries RBF+daemon md5 artifact pair.
    art: dict[str, Any] = {}
    if getattr(args, "artifacts_json", None) is not None:
        try:
            adoc = json.loads(Path(args.artifacts_json).read_text())
            art = dict(adoc) if isinstance(adoc, dict) else {}
            art.setdefault("artifacts_src", "measured")
        except (OSError, json.JSONDecodeError, TypeError) as e:
            art = {
                "rbf_md5": "NO-DATA",
                "daemon_md5": "NO-DATA",
                "artifact_pair": "NO-DATA",
                "artifacts_src": "NO-DATA",
                "artifacts_error": str(e),
            }
    else:
        art = {
            "rbf_md5": "NO-DATA",
            "daemon_md5": "NO-DATA",
            "artifact_pair": "NO-DATA",
            "artifacts_src": "NO-DATA",
            "artifacts_note": "pass --artifacts-json from soak (avsync_stamp_artifacts.sh)",
        }
    if getattr(args, "decode_src", None):
        art["decode_src"] = str(args.decode_src)
        art["decode_src_src"] = "caller_supplied"
    else:
        art.setdefault("decode_src", "NO-DATA")
        art.setdefault("decode_src_src", "NO-DATA")
    cpu_extra["rbf_md5"] = art.get("rbf_md5")
    cpu_extra["rbf_md5_src"] = art.get("rbf_md5_src", art.get("artifacts_src"))
    cpu_extra["daemon_md5"] = art.get("daemon_md5")
    cpu_extra["daemon_md5_src"] = art.get("daemon_md5_src", art.get("artifacts_src"))
    cpu_extra["artifact_pair"] = art.get("artifact_pair")
    cpu_extra["decode_src"] = art.get("decode_src")
    cpu_extra["decode_src_src"] = art.get("decode_src_src")

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
        extra=cpu_extra,
    )
    # Time series CSV — required artifact (mean-only is forbidden)
    ts_path = out_dir / f"{args.label}_offset_timeseries.csv"
    with ts_path.open("w") as fts:
        fts.write("t_flash_s,t_beep_s,offset_ms,src\n")
        for p in res.pairs:
            fts.write(
                f"{p.get('t_flash_s','')},{p.get('t_beep_s','')},"
                f"{p.get('offset_ms','')},measured\n"
            )
    print(f"offset_timeseries_csv={ts_path} src=measured")

    payload = {
        "tool": "avsync_measure_hdmi",
        "mode": mode,
        "rc": rc,
        "capture_config": cap_cfg,
        "sign_convention": (
            "offset_ms=(t_audio_onset-t_video_flash)*1000; "
            "positive=audio LATE (lags); negative=audio EARLY (leads)"
        ),
        "limitations": {
            "absolute_lipsync": "CANNOT_MEASURE without known-zero cal into grabber",
            "raw_median_tag": "raw_uncalibrated",
            "same_rig_delta": "CAN_MEASURE (B cancels)",
            "av_drift_ms": "servo deadband; not grabber GT (parent-measured blindness on OLD artifact)",
            "historical_dataset": (
                "pre-wallclock+start_at_zero runs INVALID for absolute compare; "
                "re-establish bimodality on fingerprinted captures only"
            ),
            "mean_only": "FORBIDDEN — report time series + timing_class",
        },
        "result": asdict(res),
        "timing_class": res.timing_class,
        "residual_rms_ms": res.residual_rms_ms,
        "margin": res.margin,
        "arm_cpu_pct": cpu_extra.get("arm_cpu_pct"),
        "arm_cpu_pct_src": cpu_extra.get("arm_cpu_pct_src"),
        "artifacts": art,
        "rbf_md5": art.get("rbf_md5"),
        "daemon_md5": art.get("daemon_md5"),
        "artifact_pair": art.get("artifact_pair"),
        "decode_src": art.get("decode_src"),
        "decode_src_src": art.get("decode_src_src"),
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
        "offset_timeseries_csv": str(ts_path),
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
