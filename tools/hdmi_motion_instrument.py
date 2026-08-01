#!/usr/bin/env python3
"""HDMI MOTION / CORRECTNESS instrument for MiSTerPlex lab captures.

Why this exists
---------------
Parent ERROR 8:  distinct HDMI md5s do NOT prove correctness (moving garbage passes).
Parent ERROR 13: identical HDMI md5s do NOT prove a freeze (black content is identical).
Mean luma is equally blind (correct starfield mean 0.2 vs garbage mean 66).

The only signal that has ever worked is the burned-in frame counter in the avsync
fixtures (`TREK24 n=NNN`, `NTSC2397 n=NNN`, `PLEX24 n=NNN`, ...): yellow text near
the top-left of the active (letterboxed) picture. This tool reads that counter
from a directory of HDMI PNGs and emits a hard verdict.

Verdicts / exit codes
---------------------
  MOTION_OK       rc=0   counter advances at source rate; colour+structure OK
  FREEZE          rc=1   counter pinned; colour+structure OK
  COLOR_FAIL      rc=2   chroma/cast defect positively measured (hard FAIL)
  STRUCTURE_FAIL  rc=3   vertical-duplicate and/or horizontal-wrap (hard FAIL)
  RATE_FAIL       rc=4   wrong advance rate and/or non-adjacent counter revisits
  UNSCORED        rc=77  no positive failure AND no positive pass — NEVER a pass

  rc=77 is reserved for genuinely insufficient data (idle screensaver, pre-play
  window, no overlay). It must never report a positively measured defect, and
  must never be "fixed" into a pass when there is simply nothing to score.

Severity resolution (highest wins — explicit, non-negotiable)
-------------------------------------------------------------
  1. STRUCTURE_FAIL — vertical content duplication and/or horizontal wrap
                   (raw-pipe byte-desync class) hard-fails at rc=3, independent
                   of motion scorability. More specific/actionable than colour
                   alone for the 480p identity_skip desync RCA (parent: picture
                   doubled vertically + FLASH split across L/R edges).
  2. COLOR_FAIL  — green-cast fingerprint OR global channel-mean spread cast
                   (magenta/green/any saturated global cast). Hard fail rc=2,
                   **regardless of whether the counter could be OCR'd**.
                   Colour is independent evidence; motion need not be scorable.
                   A green/magenta field often *prevents* overlay OCR, so
                   "decodes=0" and "colour broken" are correlated — colour
                   must be allowed to decide alone.
  3. RATE_FAIL   — counter advances (so not FREEZE) but at the wrong rate
                   relative to **caller-supplied** source/capture FPS, or
                   non-adjacent counter revisits (stale-bank ping-pong).
                   Hard fail rc=4. Monotonic advance alone is NOT sufficient
                   (pfps collapse to 10.9 on a 24.000 source still advances
                   and would pass a pure order check).
                   **RATE_OK is never emitted when src_fps or cap_fps is
                   DEFAULT_ASSUMED** — that is RATE_UNSCORED (honest). A green
                   rate built on a guess is ERROR 17 class even when labelled.
  4. FREEZE      — counter pinned with colour+structure OK. Hard fail rc=1.
  5. MOTION_OK   — counter advances (order OK); colour+structure OK. Pass rc=0.
                   Rate may still be RATE_UNSCORED if fps were assumed.
  6. UNSCORED    — no overlay/counter AND no colour/structure/rate verdict.
                   Soft-skip rc=77. Soft-skip is never a pass AND must never
                   report a condition we have positively measured as failure.

  When multiple hard fails apply, the highest severity wins; subordinate
  dimensions stay in the report (e.g. motion=UNSCORED color=CHROMA_CAST_FAIL
  structure=VERT_DUP+HORIZ_WRAP → VERDICT=STRUCTURE_FAIL rc=3).

Rate / revisit model (parent calibration)
-----------------------------------------
  Capture FPS (MacroSilicon MJPEG burst) and source FPS are independent.
  **Neither rate is measured by this instrument.** Pass both explicitly when
  known (daemon telemetry `fps=24/1` → `--source-fps 24` / `--src-fps 24/1`).
  Provenance is always printed:
    src_fps=24.000 src=caller          # caller supplied --source-fps
    src_fps=24.000 src=DEFAULT_ASSUMED # fell back to library default
  Library assets (Plex metadata frameRate="24.000" / videoFrameRate="24p")
  are genuinely 24.000 — NOT NTSC 24000/1001. PARENT ERROR 17: a printed
  23.976 default was mistaken for a measurement and published as a defect.
  Default assumed source = 24.000; default assumed capture = 30.0.
  **When either fps is DEFAULT_ASSUMED the rate dimension is RATE_UNSCORED,
  never RATE_OK.** Ratio/endpoint/plateau gates only fire when BOTH fps are
  caller-supplied. Revisit (bank-swap) still hard-fails without fps — it is
  a pure measured sequence property.
  Healthy 24fps-on-30-capture (parent hand measure, 105-frame burst):
    84 distinct counter states, 84 runs, max plateau 2, plateau hist {1,2},
    zero non-adjacent revisits, unique/frames = 84/105 = 0.800 = 24/30.
  Expected counter delta per capture frame ≈ source_fps/capture_fps.
  Max plateau allowed = ceil(capture_fps/source_fps)+1  (default 3).
  max_plateau == allowed is a PASS with plateau_warn (bound-riding is visible).
  Non-adjacent revisit = a counter value reappears after a different value
  intervened (RLE run sequence); bank-swap ping-pong signature.

Hardcoded constants — provenance (measured | supplied | assumed | design)
-------------------------------------------------------------------------
  DEFAULT_ASSUMED_SOURCE_FPS=24.0   assumed (Plex library 24p; NOT measured)
  DEFAULT_ASSUMED_CAPTURE_FPS=30.0  assumed (MacroSilicon MJPEG lab default)
  DEFAULT_WARMUP_SKIP=15            measured (grabber junk; parent lab)
  GREEN_MEAN_*/GREEN_FRAC_HARD      measured (parent green-cast fingerprint)
  CHROMA_SPREAD_FAIL=25.0           design bound (good ~0–6; broken ~64–200)
  GREEN_CAST_MIN_FRAMES=3           design (positive colour evidence floor)
  STRUCT_MIN_FRAMES=3               design (positive structure evidence floor)
  RATE_MIN_SAMPLES=12               design (rate/revisit sample floor)
  Anything not measured is labelled assumed/design in the report so it can
  never again be mistaken for evidence (ERROR 17 class).

Grabber warm-up
---------------
MacroSilicon 534d:2109 emits ~11-15 uniform junk frames (and a single
`ffmpeg -frames:v 1` often returns false uniform black). Uniform frames are
discarded and never scored as FREEZE. Frames where the yellow overlay is not
visible are also not scored as FREEZE (black content / flash without a clean
overlay read → contribute nothing, not a pin).

Bright-frame OCR (yellow on white flash) is best-effort only. Template tier-6
reads never enter the burst motion sequence alone — only OCR tier>=7 (or the
overlay-bitmap secondary signal) can produce MOTION_OK / FREEZE.

Usage
-----
  tools/hdmi_motion_instrument.py CAPTURE_DIR
  tools/hdmi_motion_instrument.py CAPTURE_DIR --json
  tools/hdmi_motion_instrument.py FRAME.png [FRAME.png ...]   # multi-frame list
  tools/hdmi_motion_instrument.py --self-test                  # unit checks only

Dependencies: Python 3, Pillow, numpy, tesseract (already on the lab host).
No OpenCV. Does NOT touch tools/score_i420_candidate.py.
"""
from __future__ import annotations

import argparse
import hashlib
import io
import json
import math
import os
import re
import subprocess
import sys
from collections import Counter
from pathlib import Path
from typing import Any

try:
    from PIL import Image, ImageFilter, ImageOps
except ImportError:
    sys.exit("ERROR: Pillow required (pip install Pillow)")

try:
    import numpy as np
except ImportError:
    sys.exit("ERROR: numpy required")

# Exit contract (repo hard rule: 77 / UNSCORED is never a pass).
RC_MOTION_OK = 0
RC_FREEZE = 1
RC_COLOR_FAIL = 2
RC_STRUCTURE_FAIL = 3
RC_RATE_FAIL = 4
RC_UNSCORED = 77

DEFAULT_WARMUP_SKIP = 15  # measured: MacroSilicon warm-up junk length
DEFAULT_MIN_READS = 3  # design: minimum OCR reads for motion verdict
# Source vs capture rates are NOT measured here. Defaults are ASSUMED and must
# be labelled in every report (PARENT ERROR 17: 23.976 printed as if measured).
# Plex library clips are frameRate="24.000" / videoFrameRate="24p" — true 24.000.
DEFAULT_ASSUMED_SOURCE_FPS = 24.0
DEFAULT_ASSUMED_CAPTURE_FPS = 30.0
# Back-compat aliases (same values; prefer DEFAULT_ASSUMED_* in new code).
DEFAULT_SOURCE_FPS = DEFAULT_ASSUMED_SOURCE_FPS
DEFAULT_CAPTURE_FPS = DEFAULT_ASSUMED_CAPTURE_FPS
PROVENANCE_CALLER = "caller"
PROVENANCE_DEFAULT_ASSUMED = "DEFAULT_ASSUMED"
# Provenance for rates read from a capture container (ffprobe), not assumed.
PROVENANCE_CONTAINER = "container"
# Provenance for rates measured from this capture (PNG mtimes or --capture-wall-s).
PROVENANCE_MEASURED = "measured"

# Display-level skip measurement (burned-in counter jumps). Not a hard verdict
# dimension: reported as count + confidence. Parent: drops/av_drift_ms are
# inadmissible (they cannot see failed DDR publishes).
# Minimum source-frame span before skip count is scorable at all.
SKIP_MIN_CTR_SPAN = 60  # design: ~2.5s at 24fps — below this → SKIP_UNSCORED
SKIP_CONF_MEDIUM_SPAN = 200  # ~8s at 24fps
SKIP_CONF_HIGH_SPAN = 600  # ~25s at 24fps; prefer minutes for user "sustained"
# Adjacent-capture +2 is strong; RLE +2 is OCR-sensitive. Treat adjacent as
# primary. Sustained adjacent loss fraction above this is SKIP_LOSS (still does
# not override STRUCTURE/COLOR severity — informational dimension + note).
SKIP_LOSS_FRAC_SUSPECT = 0.02  # 2% of source span
SKIP_LOSS_FRAC_LOSS = 0.05  # 5%
# Startup transient window (parent 305s soak: all session drops before wall_s~48).
# Discriminator needs the CAST INSIDE the capture — first ~60s of content is enough
# because ~17 drops >> single +2 sampling noise (steady-state is NOT resolvable the
# same way; startup is).
STARTUP_DEFAULT_WINDOW_S = 60.0  # design
STARTUP_MIN_UNIQUE = 24  # design: ~1s of content at 24fps before we speak
STARTUP_DROP_MATCH_TOL = 3  # design: |gaps - daemon_drops| ≤ this → match tag
# Below this adj loss, a LOW-conf window cannot claim REAL_DISPLAY_LOSS
# (single +2 is the steady-state ambiguity floor; startup claim needs cluster).
STARTUP_MIN_ADJ_LOSS_CALL = 5  # design: ~17 expected on parent soak if (b)


def parse_fps_token(token: str | float | int | None) -> float | None:
    """Parse daemon/ffprobe fps tokens: '24/1', '24000/1001', '24', 24.0.

    Returns None if token is None/empty. Raises ValueError on garbage.
    """
    if token is None:
        return None
    if isinstance(token, (int, float)):
        v = float(token)
        if v <= 0:
            raise ValueError(f"fps must be > 0, got {token!r}")
        return v
    s = str(token).strip()
    if not s:
        return None
    if "/" in s:
        a, b = s.split("/", 1)
        num = float(a.strip())
        den = float(b.strip())
        if den == 0:
            raise ValueError(f"fps denominator 0 in {token!r}")
        v = num / den
    else:
        v = float(s)
    if v <= 0:
        raise ValueError(f"fps must be > 0, got {token!r}")
    return v


def try_probe_capture_fps(path: str | Path) -> tuple[float | None, str]:
    """Best-effort capture fps from a video container via ffprobe.

    PNG burst directories cannot yield fps (no container timeline). Returns
    (None, reason) when unreadable — caller keeps DEFAULT_ASSUMED.
    """
    p = Path(path)
    if p.is_dir():
        return None, "png_dir_has_no_container_fps"
    if not p.is_file():
        return None, "not_a_file"
    # Still images are not timed.
    if p.suffix.lower() in {".png", ".jpg", ".jpeg", ".bmp", ".webp"}:
        return None, "still_image_no_fps"
    import shutil
    import subprocess

    if not shutil.which("ffprobe"):
        return None, "ffprobe_missing"
    try:
        out = subprocess.check_output(
            [
                "ffprobe",
                "-v",
                "error",
                "-select_streams",
                "v:0",
                "-show_entries",
                "stream=r_frame_rate,avg_frame_rate",
                "-of",
                "default=noprint_wrappers=1:nokey=1",
                str(p),
            ],
            text=True,
            timeout=10,
        )
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, OSError) as e:
        return None, f"ffprobe_failed:{e}"
    lines = [ln.strip() for ln in out.splitlines() if ln.strip()]
    for ln in lines:
        try:
            v = parse_fps_token(ln)
        except ValueError:
            continue
        if v is not None and 1.0 <= v <= 240.0:
            return v, PROVENANCE_CONTAINER
    return None, f"ffprobe_no_rate lines={lines!r}"


def measure_capture_fps_from_paths(
    paths: list[str],
    *,
    wall_s: float | None = None,
) -> dict[str, Any]:
    """Measure capture fps from PNG burst timing.

    Preferred: caller passes wall_s from the capture command wall clock
    (ffmpeg start→end). Fallback: (n-1)/(mtime_last - mtime_first).

    Returns dict with capture_fps, provenance, wall_s, method — or fps=None
    with reason when unmeasurable (batch-write mtimes, too few frames).
    """
    n = len(paths)
    out: dict[str, Any] = {
        "capture_fps": None,
        "capture_fps_src": PROVENANCE_DEFAULT_ASSUMED,
        "wall_s": None,
        "n_frames": n,
        "method": None,
        "reason": None,
    }
    if n < 8:
        out["reason"] = f"too_few_frames={n}<8"
        return out

    if wall_s is not None and wall_s > 0:
        fps = (n - 1) / float(wall_s)
        out["wall_s"] = round(float(wall_s), 4)
        out["method"] = "caller_wall_s_(n-1)/wall"
        if not (5.0 <= fps <= 120.0):
            out["reason"] = f"wall_fps_out_of_range={fps:.4f}"
            return out
        out["capture_fps"] = round(fps, 4)
        out["capture_fps_src"] = PROVENANCE_MEASURED
        return out

    try:
        mtimes = [os.path.getmtime(p) for p in paths]
    except OSError as e:
        out["reason"] = f"mtime_failed:{e}"
        return out
    t0, t1 = float(mtimes[0]), float(mtimes[-1])
    wall = t1 - t0
    out["wall_s"] = round(wall, 4)
    if wall < 0.05:
        out["reason"] = "mtime_collapsed_batch_write"
        out["method"] = "png_mtime_(n-1)/wall"
        return out
    fps = (n - 1) / wall
    out["method"] = "png_mtime_(n-1)/wall"
    if not (5.0 <= fps <= 120.0):
        out["reason"] = f"mtime_fps_out_of_range={fps:.4f}"
        return out
    out["capture_fps"] = round(fps, 4)
    out["capture_fps_src"] = PROVENANCE_MEASURED
    return out


def analyze_counter_skips(
    pairs: list[tuple[int, int]],
    *,
    source_fps: float = DEFAULT_ASSUMED_SOURCE_FPS,
    capture_fps: float = DEFAULT_ASSUMED_CAPTURE_FPS,
    source_fps_src: str = PROVENANCE_DEFAULT_ASSUMED,
    capture_fps_src: str = PROVENANCE_DEFAULT_ASSUMED,
) -> dict[str, Any]:
    """Display-level frame-loss from burned-in counter jumps.

    Arithmetic (on outlier-filtered (cap_idx, n) pairs):
      RLE of counter values → successive distinct states v0, v1, ...
      For each step d = v_{i+1} - v_i:
        d == 1  → healthy advance (one new source frame)
        d >= 2  → rle_skip: (d-1) source frames never observed
                  (display skip OR OCR miss of intermediate n)
        d <= 0  → non-monotonic (OCR / rewind); counted separately

      Adjacent-capture skip (PRIMARY, stronger):
        when cap_idx differs by 1 and dn >= 2, the display advanced 2+
        source frames in one capture period — max expected advance over
        one capture slot is ~1 when src < cap. frames_lost_adj += dn - 1.

    Confidence:
      SKIP_UNSCORED — ctr_span < SKIP_MIN_CTR_SPAN or too few samples
      LOW/MEDIUM/HIGH by source span (prefer minutes for user claim)
      A single +2 is sampling/OCR-ambiguous; sustained rate is not.

    This is a MEASUREMENT dimension, not a hard rc verdict. Parent cannot
    use daemon drops/av_drift_ms here (blind to failed publishes).
    """
    empty: dict[str, Any] = {
        "skip_status": "SKIP_UNSCORED",
        "frames_lost_rle": None,
        "frames_lost_adj": None,
        "skip_events_rle": 0,
        "skip_events_adj": 0,
        "skip_hist_rle": {},
        "skip_hist_adj": {},
        "step_hist_rle": {},
        "ctr_span": 0,
        "unique_states": 0,
        "lost_frac_rle": None,
        "lost_frac_adj": None,
        "skip_confidence": "UNSCORED",
        "skip_notes": [],
        "arithmetic": "",
        "n_samples": len(pairs),
        "source_fps": source_fps,
        "capture_fps": capture_fps,
        "source_fps_src": source_fps_src,
        "capture_fps_src": capture_fps_src,
    }
    if len(pairs) < RATE_MIN_SAMPLES:
        empty["skip_notes"] = [
            f"insufficient_samples={len(pairs)} need>={RATE_MIN_SAMPLES}"
        ]
        empty["arithmetic"] = "n/a (too few samples)"
        return empty

    idxs = [i for i, _ in pairs]
    ns = [n for _, n in pairs]
    runs = _rle_runs(ns)
    vals = [v for v, _ in runs]
    unique_states = len(vals)
    if unique_states < 2:
        empty["skip_notes"] = ["fewer_than_2_unique_counter_states"]
        empty["unique_states"] = unique_states
        empty["arithmetic"] = "n/a (pinned or single state)"
        return empty

    n_first, n_last = vals[0], vals[-1]
    ctr_span = n_last - n_first
    empty["ctr_span"] = int(ctr_span)
    empty["unique_states"] = int(unique_states)
    empty["n_first"] = int(n_first)
    empty["n_last"] = int(n_last)

    # --- RLE step analysis ---
    hist_rle: Counter = Counter()
    step_hist: Counter = Counter()
    lost_rle = 0
    skip_ev_rle = 0
    neg_steps = 0
    for a, b in zip(vals, vals[1:]):
        d = b - a
        step_hist[d] += 1
        if d >= 2:
            hist_rle[d] += 1
            lost_rle += d - 1
            skip_ev_rle += 1
        elif d <= 0:
            neg_steps += 1

    # --- Adjacent-capture analysis (PRIMARY) ---
    hist_adj: Counter = Counter()
    lost_adj = 0
    skip_ev_adj = 0
    # Expected max source advance over di capture slots:
    # ceil(di * src/cap) + 1 slack. Requires fps; when assumed, still compute
    # with labelled assumption but confidence stays capped at LOW.
    fps_known = (
        source_fps_src == PROVENANCE_CALLER
        and capture_fps_src
        in (PROVENANCE_CALLER, PROVENANCE_CONTAINER, PROVENANCE_MEASURED)
        and source_fps > 0
        and capture_fps > 0
    )
    for (i0, n0), (i1, n1) in zip(pairs, pairs[1:]):
        di = i1 - i0
        dn = n1 - n0
        if di <= 0 or dn < 2:
            continue
        # Max source advance WITHOUT a display skip over di capture slots.
        # At 24/30, di=1 → max_exp=1, so dn=+2 is exactly one lost frame.
        # Do NOT add the plateau +1 slack here (that slack is for rate gates only).
        if fps_known:
            max_exp = max(1, int(math.ceil(di * source_fps / capture_fps)))
        else:
            # Without fps: di==1 → max_exp=1; else allow di (1 per capture upper).
            max_exp = 1 if di == 1 else di
        if dn > max_exp:
            excess = dn - max_exp
            # Record as jump size dn for histogram clarity
            hist_adj[dn] += 1
            lost_adj += excess
            skip_ev_adj += 1

    lost_frac_rle = (lost_rle / ctr_span) if ctr_span > 0 else None
    lost_frac_adj = (lost_adj / ctr_span) if ctr_span > 0 else None

    notes: list[str] = []
    if neg_steps:
        notes.append(f"non_monotonic_rle_steps={neg_steps} (OCR noise residue)")

    # Confidence from window length + fps provenance
    if ctr_span < SKIP_MIN_CTR_SPAN:
        conf = "UNSCORED"
        notes.append(
            f"window_too_short ctr_span={ctr_span}<{SKIP_MIN_CTR_SPAN} "
            f"(need >={SKIP_MIN_CTR_SPAN} source frames; prefer "
            f">={SKIP_CONF_HIGH_SPAN} / minutes for user sustained claim)"
        )
    elif not fps_known:
        conf = "LOW"
        notes.append(
            "fps_not_authoritative: skip excess uses adjacent-only bound; "
            "pass --src-fps from daemon and measure cap_fps for higher conf"
        )
        if ctr_span >= SKIP_CONF_HIGH_SPAN:
            notes.append("span_would_be_HIGH_if_fps_known")
    elif ctr_span >= SKIP_CONF_HIGH_SPAN:
        conf = "HIGH"
    elif ctr_span >= SKIP_CONF_MEDIUM_SPAN:
        conf = "MEDIUM"
    else:
        conf = "LOW"
        notes.append(
            f"span_low ctr_span={ctr_span}<{SKIP_CONF_MEDIUM_SPAN} "
            f"(single +2 can be OCR/sampling artifact)"
        )

    # Status from adjacent (primary) loss fraction
    if conf == "UNSCORED":
        status = "SKIP_UNSCORED"
    elif lost_frac_adj is not None and lost_frac_adj >= SKIP_LOSS_FRAC_LOSS and conf in (
        "MEDIUM",
        "HIGH",
    ):
        status = "SKIP_LOSS"
        notes.append(
            f"sustained_adjacent_loss lost_frac_adj={lost_frac_adj:.4f}>="
            f"{SKIP_LOSS_FRAC_LOSS} conf={conf}"
        )
    elif lost_frac_adj is not None and lost_frac_adj >= SKIP_LOSS_FRAC_SUSPECT:
        status = "SKIP_SUSPECT"
        notes.append(
            f"elevated_adjacent_loss lost_frac_adj={lost_frac_adj:.4f}>="
            f"{SKIP_LOSS_FRAC_SUSPECT}"
        )
    elif lost_adj == 0 and lost_rle > 0:
        status = "SKIP_OK"
        notes.append(
            f"rle_lost={lost_rle} but adjacent_lost=0 → likely OCR misses of "
            f"intermediate n, not display skips"
        )
    else:
        status = "SKIP_OK"

    # Arithmetic string for parent audit
    arith = (
        f"RLE: for each successive distinct n, d=n[i+1]-n[i]; "
        f"if d>=2 frames_lost_rle += (d-1). "
        f"sum={lost_rle} over ctr_span={ctr_span} "
        f"(n_first={n_first} n_last={n_last} unique_states={unique_states}). "
        f"ADJ: for consecutive filtered pairs (i0,n0)->(i1,n1), "
        f"di=i1-i0 dn=n1-n0; max_exp=max(1,ceil(di*src/cap)) "
        f"(no plateau slack; +2 on di=1 = 1 lost) "
        f"{'(fps labelled)' if fps_known else '(fps weak)'}; "
        f"if dn>max_exp frames_lost_adj += dn-max_exp → {lost_adj}. "
        f"ASSUMPTION(uniform_capture_spacing): di=cap_idx delta is treated as "
        f"di nominal capture intervals using global cap_fps — PNG sequences "
        f"without PTS cannot see grabber drops (Δt≈2/cap looks like +2 source). "
        f"Use MKV+PTS capture to split device skip vs grabber drop."
    )
    notes.append(
        "uniform_capture_spacing=ASSUMED "
        "(cap_idx adjacency ≠ measured Δt; grabber drops masquerade as +2)"
    )

    return {
        "skip_status": status,
        "frames_lost_rle": int(lost_rle),
        "frames_lost_adj": int(lost_adj),
        "skip_events_rle": int(skip_ev_rle),
        "skip_events_adj": int(skip_ev_adj),
        "skip_hist_rle": {str(k): int(v) for k, v in sorted(hist_rle.items())},
        "skip_hist_adj": {str(k): int(v) for k, v in sorted(hist_adj.items())},
        "step_hist_rle": {str(k): int(v) for k, v in sorted(step_hist.items())},
        "ctr_span": int(ctr_span),
        "unique_states": int(unique_states),
        "n_first": int(n_first),
        "n_last": int(n_last),
        "lost_frac_rle": (round(lost_frac_rle, 4) if lost_frac_rle is not None else None),
        "lost_frac_adj": (round(lost_frac_adj, 4) if lost_frac_adj is not None else None),
        "skip_confidence": conf,
        "skip_notes": notes,
        "arithmetic": arith,
        "n_samples": len(pairs),
        "non_monotonic_steps": int(neg_steps),
        "source_fps": source_fps,
        "capture_fps": capture_fps,
        "source_fps_src": source_fps_src,
        "capture_fps_src": capture_fps_src,
        "fps_known_for_skip": bool(fps_known),
    }


def analyze_startup_transient(
    pairs: list[tuple[int, int]],
    *,
    source_fps: float = DEFAULT_ASSUMED_SOURCE_FPS,
    capture_fps: float = DEFAULT_ASSUMED_CAPTURE_FPS,
    source_fps_src: str = PROVENANCE_DEFAULT_ASSUMED,
    capture_fps_src: str = PROVENANCE_DEFAULT_ASSUMED,
    window_s: float = STARTUP_DEFAULT_WINDOW_S,
    daemon_session_drops: int | None = None,
    daemon_drops_src: str = PROVENANCE_DEFAULT_ASSUMED,
) -> dict[str, Any]:
    """Startup catch-up vs real display-loss discriminator (pixels only).

    Parent dichotomy (305s soak: drops climb to 17 then FLAT; residual=0):
      (a) catch-up / no missing content on screen
      (b) real loss — source frames never reach the display

    Source fact (av_clock.hpp avDecide): Drop fires only when
      drift = audible_clock - frameContentMs > dropMs (video LATE vs audio).
    Early ffmpeg dump → negative drift → Hold, NOT Drop. So daemon `drops`
    are frames that were read (frameIndex++) and then NOT presentCleanFrame'd
    — by construction they never hit DDR. Pixel counter gaps must match if
    the capture window includes those presents.

    Method (on outlier-filtered pairs, restricted to first window_s of capture):
      1) Window by cap_idx: keep pairs with idx <= idx0 + window_s*cap_fps
      2) Run the same adjacent/RLE skip arithmetic as analyze_counter_skips
      3) Also enumerate holes in observed unique n-run sequence:
           for successive distinct n values d=n[i+1]-n[i], if d>=2 hole+=d-1
         (identical to frames_lost_rle on the window — labelled both ways)
      4) If caller passes --daemon-session-drops N (from session telemetry),
         tag match when |frames_lost_adj - N| <= STARTUP_DROP_MATCH_TOL

    Labels (MEASUREMENT dimension — never a hard rc by itself):
      STARTUP_UNSCORED          window too short / no counter
      STARTUP_CONTIGUOUS        lost_adj==0 and lost_rle==0 in window
      STARTUP_DISPLAY_LOSS      lost_adj>0 (or strong rle with adj support)
      STARTUP_CONTIGUOUS_vs_DROPS  contiguous pixels but daemon_drops>0
                                   (would falsify the Drop=missing-content
                                   reading IF the window covered the climb)

    Steady-state single +2 is ambiguous (8.4 ms margin at 30-vs-24). Startup
    with ~17 events is far above that floor — window IS resolvable.
    """
    base_notes: list[str] = []
    out: dict[str, Any] = {
        "startup_status": "STARTUP_UNSCORED",
        "startup_window_s": float(window_s),
        "startup_window_s_src": "caller" if window_s != STARTUP_DEFAULT_WINDOW_S else "DEFAULT_ASSUMED",
        "startup_cap_frames": 0,
        "startup_unique": 0,
        "startup_n_first": None,
        "startup_n_last": None,
        "startup_ctr_span": 0,
        "startup_frames_lost_adj": None,
        "startup_frames_lost_rle": None,
        "startup_skip_hist_adj": {},
        "startup_skip_hist_rle": {},
        "startup_step_hist_rle": {},
        "startup_confidence": "UNSCORED",
        "daemon_session_drops": daemon_session_drops,
        "daemon_session_drops_src": (
            daemon_drops_src
            if daemon_session_drops is not None
            else PROVENANCE_DEFAULT_ASSUMED
        ),
        "drops_match": None,
        "startup_notes": base_notes,
        "startup_arithmetic": "",
        "source_fps": source_fps,
        "capture_fps": capture_fps,
        "source_fps_src": source_fps_src,
        "capture_fps_src": capture_fps_src,
        # Parent (a)/(b) reading — labelled inference from pixels+source, not a guess
        # about unmeasured hardware.
        "hypothesis": "UNSCORED",
    }
    if not pairs or window_s <= 0 or capture_fps <= 0:
        base_notes.append("no_pairs_or_bad_window")
        out["startup_arithmetic"] = "n/a"
        return out

    idx0 = pairs[0][0]
    # Inclusive capture-index end of window. cap_fps provenance printed always.
    max_di = max(1, int(math.ceil(float(window_s) * float(capture_fps))))
    win = [(i, n) for i, n in pairs if (i - idx0) <= max_di]
    out["startup_cap_frames"] = len(win)
    if len(win) < RATE_MIN_SAMPLES:
        base_notes.append(
            f"window_samples={len(win)}<{RATE_MIN_SAMPLES} "
            f"(need capture running BEFORE cast; window_s={window_s} "
            f"cap_fps={capture_fps} cap={capture_fps_src})"
        )
        out["startup_arithmetic"] = "n/a (window too thin)"
        return out

    sk = analyze_counter_skips(
        win,
        source_fps=source_fps,
        capture_fps=capture_fps,
        source_fps_src=source_fps_src,
        capture_fps_src=capture_fps_src,
    )
    lost_adj = sk.get("frames_lost_adj")
    lost_rle = sk.get("frames_lost_rle")
    ctr_span = int(sk.get("ctr_span") or 0)
    unique = int(sk.get("unique_states") or 0)
    out["startup_unique"] = unique
    out["startup_n_first"] = sk.get("n_first")
    out["startup_n_last"] = sk.get("n_last")
    out["startup_ctr_span"] = ctr_span
    out["startup_frames_lost_adj"] = lost_adj
    out["startup_frames_lost_rle"] = lost_rle
    out["startup_skip_hist_adj"] = sk.get("skip_hist_adj") or {}
    out["startup_skip_hist_rle"] = sk.get("skip_hist_rle") or {}
    out["startup_step_hist_rle"] = sk.get("step_hist_rle") or {}
    out["startup_confidence"] = sk.get("skip_confidence") or "UNSCORED"
    base_notes.extend(list(sk.get("skip_notes") or []))

    # Match against daemon session drops when supplied (caller_supplied only).
    drops_match = None
    if daemon_session_drops is not None and lost_adj is not None:
        drops_match = abs(int(lost_adj) - int(daemon_session_drops)) <= STARTUP_DROP_MATCH_TOL
        out["drops_match"] = bool(drops_match)
        base_notes.append(
            f"daemon_session_drops={daemon_session_drops} ({daemon_drops_src}) "
            f"vs frames_lost_adj={lost_adj} tol={STARTUP_DROP_MATCH_TOL} "
            f"match={int(bool(drops_match))}"
        )

    # Primary display evidence is lost_adj (adjacent-capture jumps).
    # lost_rle alone with lost_adj==0 is the known OCR-miss pattern (same as
    # skip_metrics SKIP_OK note) — do NOT call that DISPLAY_LOSS.
    adj_loss = int(lost_adj or 0)
    rle_loss = int(lost_rle or 0)
    display_loss = adj_loss > 0

    if unique < STARTUP_MIN_UNIQUE or ctr_span < STARTUP_MIN_UNIQUE:
        status = "STARTUP_UNSCORED"
        hyp = "UNSCORED"
        base_notes.append(
            f"startup_unique={unique} ctr_span={ctr_span}<{STARTUP_MIN_UNIQUE} "
            f"— decline to score (capture may have missed cast / pre-play)"
        )
    elif display_loss:
        conf = str(out.get("startup_confidence") or "UNSCORED")
        strong_call = adj_loss >= STARTUP_MIN_ADJ_LOSS_CALL or (
            conf in ("MEDIUM", "HIGH") and adj_loss >= 2
        )
        if strong_call:
            status = "STARTUP_DISPLAY_LOSS"
            hyp = "REAL_DISPLAY_LOSS"
            base_notes.append(
                f"display counter gaps in startup window lost_adj={adj_loss} "
                f"lost_rle={rle_loss} conf={conf} — burned-in n skipped on "
                f"screen (adj primary; threshold>={STARTUP_MIN_ADJ_LOSS_CALL} "
                f"or MEDIUM+ with adj>=2)"
            )
            if drops_match is True:
                base_notes.append(
                    "gaps ≈ daemon drops → pacer Drop path explains the climb "
                    "(video late vs audio; each Drop skips presentCleanFrame)"
                )
            elif drops_match is False:
                base_notes.append(
                    "adj gaps ≉ daemon drops — partial window, OCR residue, or "
                    "additional loss path"
                )
        else:
            status = "STARTUP_SUSPECT"
            hyp = "AMBIGUOUS_SMALL_GAPS"
            base_notes.append(
                f"small adj loss lost_adj={adj_loss}<{STARTUP_MIN_ADJ_LOSS_CALL} "
                f"conf={conf} — single/double jumps are OCR/sampling-ambiguous; "
                f"not enough to claim the ~17-drop startup cluster. "
                f"Re-run with cast-inside-window + longer span."
            )
    else:
        # adj==0: contiguous at capture adjacency. rle>0 is OCR note only.
        if rle_loss > 0:
            base_notes.append(
                f"rle_lost={rle_loss} but adjacent_lost=0 → OCR misses of "
                f"intermediate n, not display skips (same rule as skip_metrics)"
            )
        if daemon_session_drops is not None and int(daemon_session_drops) > 0:
            status = "STARTUP_CONTIGUOUS_vs_DROPS"
            hyp = "CONTIGUOUS_DISPLAY_CHECK_WINDOW"
            base_notes.append(
                "counter contiguous (adj) in window while daemon_session_drops>0 — "
                "if window covered the drops climb, that contradicts "
                "Drop→missing-present; else window missed the transient "
                "(most prior parent captures started AFTER settle)"
            )
        else:
            status = "STARTUP_CONTIGUOUS"
            hyp = "NO_DISPLAY_LOSS_IN_WINDOW"
            base_notes.append(
                "no adjacent counter jumps in startup window (lost_adj=0)"
            )

    arith = (
        f"window: keep pairs with (cap_idx - idx0) <= ceil(window_s*cap_fps)="
        f"{max_di} (window_s={window_s} cap_fps={capture_fps} "
        f"cap={capture_fps_src}); then same ADJ/RLE as skip_metrics. "
        f"lost_adj={lost_adj} lost_rle={lost_rle} ctr_span={ctr_span} "
        f"n_first={out['startup_n_first']} n_last={out['startup_n_last']}. "
        f"Source: Drop only when drift=audioMs-frameMs > resyncDropMs "
        f"(default 80); maxDropRun=1 so drops interleave with presents. "
        f"Early video → Hold not Drop. Daemon drops are present-skips."
    )
    out["startup_status"] = status
    out["hypothesis"] = hyp
    out["startup_notes"] = base_notes
    out["startup_arithmetic"] = arith
    out["startup_skip_status_window"] = sk.get("skip_status")
    return out


# Minimum strong counter samples before rate/revisit can hard-fail.
RATE_MIN_SAMPLES = 12  # design
# Broken c5382bee + old-daemon green-cast fingerprint (parent-measured).
# Also matches native-480p full-green fields (U,V~0): high green_frac, mid mean.
GREEN_MEAN_LO, GREEN_MEAN_HI = 55.0, 95.0  # measured fingerprint band
GREEN_FRAC_HARD = 0.85  # measured fingerprint band
# Minimum positively-flagged frames before colour alone hard-fails the burst.
GREEN_CAST_MIN_FRAMES = 3  # design
# Global channel-mean spread (max-min of per-channel means). Correct frames are
# near-neutral (~0–6). Parent broken 480p desync measured ~200 (magenta) and
# ~90 (green). Threshold sits far above good and far below broken.
# Catches magenta / blue / any sustained single-axis cast — not green-only.
CHROMA_SPREAD_FAIL = 25.0  # design bound from parent measurements
# Near-zero chroma on a lit active region (U=V=128 greyscale / chroma killed).
GREYSCALE_CHROMA_MAX = 3.0  # design: mean per-pixel channel-range on active
GREYSCALE_ACTIVE_FRAC_MIN = 0.08  # design: enough lit picture to judge
GREYSCALE_LUMA_LO, GREYSCALE_LUMA_HI = 25.0, 220.0  # design: lit, not crushed
# UV-swap among saturated active pixels (lab flash/red-bar fixtures).
UV_SWAP_CYAN_MIN = 0.55  # design
UV_SWAP_RED_MAX = 0.18  # design
UV_SWAP_BLUE_MIN = 0.35  # design
UV_SWAP_SAT_FRAC_MIN = 0.02  # design: need enough saturated samples
# Minimum frames with a structural flag before structure alone hard-fails.
STRUCT_MIN_FRAMES = 3  # design


# ---------------------------------------------------------------------------
# Frame geometry / masks
# ---------------------------------------------------------------------------

def _is_uniform(rgb: np.ndarray) -> bool:
    return int(rgb.min()) == int(rgb.max())


def _yellow_mask(rgb: np.ndarray) -> np.ndarray:
    """Yellow burned-in overlay on dark OR flash (blue-deficit) backgrounds."""
    r = rgb[:, :, 0].astype(np.int16)
    g = rgb[:, :, 1].astype(np.int16)
    b = rgb[:, :, 2].astype(np.int16)
    return (r > 130) & (g > 130) & (r + g > 2 * b + 40) & ((r + g) > 220)


def _yellow_mask_soft(rgb: np.ndarray) -> np.ndarray:
    """AA / border skirt of the yellow overlay (drawtext borderw=2 is black+blend).

    Used only inside an already-localised padded ROI so it cannot pull in
    unrelated warm pixels from the full frame.
    """
    r = rgb[:, :, 0].astype(np.int16)
    g = rgb[:, :, 1].astype(np.int16)
    b = rgb[:, :, 2].astype(np.int16)
    return (r > 95) & (g > 95) & (r + g > 2 * b + 15) & ((r + g) > 160)


def _chroma_yellow_mask(rgb: np.ndarray) -> np.ndarray:
    """Stronger chroma mask for white-flash frames where plain yellow is washed out."""
    r = rgb[:, :, 0].astype(np.int16)
    g = rgb[:, :, 1].astype(np.int16)
    b = rgb[:, :, 2].astype(np.int16)
    return ((r + g) / 2 - b) > 40


def _rgb_to_ycbcr_planes(rgb: np.ndarray) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """BT.601-style Y/Cb/Cr planes (float)."""
    r = rgb[:, :, 0].astype(np.float32)
    g = rgb[:, :, 1].astype(np.float32)
    b = rgb[:, :, 2].astype(np.float32)
    y = 0.299 * r + 0.587 * g + 0.114 * b
    cb = 128.0 + (-0.168736 * r - 0.331264 * g + 0.5 * b)
    cr = 128.0 + (0.5 * r - 0.418688 * g - 0.081312 * b)
    return y, cb, cr


def green_cast_metrics(rgb: np.ndarray) -> dict[str, Any]:
    """Colour integrity — not green-only.

    Fail classes (any one → color_fail):
      1. green_cast     — classic green-dominance fingerprint (U,V~0 / old daemon)
      2. chroma_cast    — global channel-mean spread (magenta/blue/any axis cast)
      3. greyscale_flat — lit active region with near-zero chroma variance
      4. uv_swap        — saturated-pixel primary inversion (cyan/blue vs red)

    Letterbox black and mostly-black clips do not trip greyscale/uv_swap.
    """
    empty = {
        "mean_rgb": float(rgb.mean()) if rgb.size else 0.0,
        "green_frac": 0.0,
        "green_cast": False,
        "channel_spread": 0.0,
        "channel_means": [float(rgb.mean())] * 3 if rgb.size else [0.0, 0.0, 0.0],
        "chroma_cast": False,
        "greyscale_flat": False,
        "uv_swap": False,
        "active_frac": 0.0,
        "active_chroma_mean": 0.0,
        "sat_frac": 0.0,
        "red_dom": 0.0,
        "blue_dom": 0.0,
        "cyan_dom": 0.0,
        "color_fail": False,
    }
    if _is_uniform(rgb):
        # Near-black uniform = grabber junk. Lit uniform grey = dead chroma defect.
        m = float(rgb.mean())
        if GREYSCALE_LUMA_LO <= m <= GREYSCALE_LUMA_HI:
            empty["mean_rgb"] = m
            empty["channel_means"] = [m, m, m]
            empty["greyscale_flat"] = True
            empty["active_frac"] = 1.0
            empty["active_chroma_mean"] = 0.0
            empty["color_fail"] = True
        return empty

    pix = rgb.reshape(-1, 3).astype(np.float32)
    mean_rgb = float(pix.mean())
    means = [float(pix[:, i].mean()) for i in range(3)]
    channel_spread = max(means) - min(means)
    gdom = (
        (pix[:, 1] > pix[:, 0] + 15)
        & (pix[:, 1] > pix[:, 2] + 15)
        & (pix[:, 1] > 40)
    )
    green_frac = float(gdom.mean())
    green_cast = (
        GREEN_MEAN_LO <= mean_rgb <= GREEN_MEAN_HI and green_frac >= GREEN_FRAC_HARD
    ) or (green_frac >= 0.90 and mean_rgb >= 40.0)
    chroma_cast = channel_spread >= CHROMA_SPREAD_FAIL

    luma = pix.mean(axis=1)
    per_chroma = pix.max(axis=1) - pix.min(axis=1)
    active = (luma >= GREYSCALE_LUMA_LO) & (luma <= GREYSCALE_LUMA_HI)
    active_frac = float(active.mean())
    active_chroma_mean = float(per_chroma[active].mean()) if active.any() else 0.0
    greyscale_flat = (
        active_frac >= GREYSCALE_ACTIVE_FRAC_MIN
        and active_chroma_mean <= GREYSCALE_CHROMA_MAX
    )

    y_pl, cb_pl, cr_pl = _rgb_to_ycbcr_planes(rgb)
    cb_f = cb_pl.reshape(-1)
    cr_f = cr_pl.reshape(-1)
    sat = np.hypot(cb_f - 128.0, cr_f - 128.0) >= 15.0
    msk = active & sat
    sat_frac = float(msk.mean())
    red_dom = blue_dom = cyan_dom = 0.0
    mean_cb = mean_cr = 0.0
    uv_swap = False
    if sat_frac >= UV_SWAP_SAT_FRAC_MIN and int(msk.sum()) >= 200:
        mp = pix[msk]
        red_dom = float(((mp[:, 0] > mp[:, 1] + 15) & (mp[:, 0] > mp[:, 2] + 15)).mean())
        blue_dom = float(((mp[:, 2] > mp[:, 1] + 15) & (mp[:, 2] > mp[:, 0] + 15)).mean())
        cyan_dom = float(((mp[:, 1] > mp[:, 0] + 10) & (mp[:, 2] > mp[:, 0] + 10)).mean())
        mean_cb = float((cb_f[msk] - 128.0).mean())
        mean_cr = float((cr_f[msk] - 128.0).mean())
        uv_swap = (
            cyan_dom >= UV_SWAP_CYAN_MIN
            and red_dom <= UV_SWAP_RED_MAX
            and blue_dom >= UV_SWAP_BLUE_MIN
            and mean_cr < -10.0
            and mean_cb > 10.0
        )

    color_fail = bool(green_cast or chroma_cast or greyscale_flat or uv_swap)
    return {
        "mean_rgb": round(mean_rgb, 3),
        "green_frac": round(green_frac, 4),
        "green_cast": bool(green_cast),
        "channel_spread": round(channel_spread, 2),
        "channel_means": [round(x, 1) for x in means],
        "chroma_cast": bool(chroma_cast),
        "greyscale_flat": bool(greyscale_flat),
        "uv_swap": bool(uv_swap),
        "active_frac": round(active_frac, 4),
        "active_chroma_mean": round(active_chroma_mean, 3),
        "sat_frac": round(sat_frac, 4),
        "red_dom": round(red_dom, 4),
        "blue_dom": round(blue_dom, 4),
        "cyan_dom": round(cyan_dom, 4),
        "mean_cb": round(mean_cb, 2),
        "mean_cr": round(mean_cr, 2),
        "color_fail": color_fail,
    }


def structure_metrics(rgb: np.ndarray) -> dict[str, Any]:
    """Structural integrity: vertical duplicate content + horizontal wrap.

    Tuned on parent controlled pair:
      /tmp/cap480a  broken 480p identity_skip desync (must FAIL)
      /tmp/cap480b  same clip/core/daemon, scale fix (must PASS)
      /tmp/cap240fs known-good 240p (must PASS)

    Vertical duplicate
    ------------------
    Same picture content (esp. burned-in counter) appearing twice in one raster.
    Paths (any one is enough):
      A. Two left-half edge-energy peaks with high patch NCC (dual overlay on
         cast frames where yellow mask is unreliable).
      B. Active-region half-frame NCC on left half >= 0.70 with real structure
         in both halves (clean vertical doubling).

    Horizontal wrap
    ---------------
    Content split across extreme L/R edges that would be contiguous if rolled
    (parent: "ASH" left + "FLA" right of FLASH). Signature: high gradient energy
    on BOTH extreme edges while the centre strip is relatively empty. Legitimate
    full-frame flash keeps edge≈mid energy (ratio ~1); letterboxed dark frames
    have content only on the left (right edge near zero) so min(L,R) stays low.

    Black letterbox bars and mostly-black clips do not fire either check.
    """
    empty = {
        "vertical_dup": False,
        "horiz_wrap": False,
        "structure_fail": False,
        "vdup_score": 0.0,
        "vdup_dy": None,
        "vdup_path": "",
        "wrap_ratio": 0.0,
        "wrap_both_e": 0.0,
        "wrap_mid_e": 0.0,
    }
    if _is_uniform(rgb):
        return empty

    h, w = rgb.shape[:2]
    gray = rgb.astype(np.float32).mean(axis=2)
    # Horizontal gradient magnitude (text strokes / edges).
    gx = np.zeros_like(gray)
    gx[:, 1:-1] = np.abs(gray[:, 2:] - gray[:, :-2])
    col_e = gx.mean(axis=0)

    # --- Horizontal wrap ---
    ew = max(32, int(0.07 * w))
    mw = max(64, int(0.20 * w))
    left_e = float(col_e[:ew].mean())
    right_e = float(col_e[-ew:].mean())
    mid_e = float(col_e[w // 2 - mw // 2 : w // 2 + mw // 2].mean())
    both_e = min(left_e, right_e)
    wrap_ratio = both_e / (mid_e + 0.05)
    # Thresholds from controlled pair (bad wrap flash: both~2.9 ratio~25;
    # good flash: both~2.8 ratio~2.8; good dark: both~0.12).
    horiz_wrap = bool(both_e >= 2.5 and wrap_ratio >= 4.0 and mid_e < both_e * 0.45)

    # --- Vertical duplicate ---
    vdup = False
    vdup_score = 0.0
    vdup_dy: int | None = None
    vdup_path = ""
    x1 = int(0.55 * w)
    gxL = gx[:, :x1]
    gxR = gx[:, w // 2 :]
    edge_row = gxL.mean(axis=1)
    right_row = gxR.mean(axis=1)
    sm = np.convolve(edge_row, np.ones(5) / 5.0, mode="same")
    thr = max(2.0, float(np.percentile(sm, 90)))
    peaks: list[int] = []
    for i in range(20, h - 20):
        if sm[i] >= thr and sm[i] >= sm[i - 1] and sm[i] >= sm[i + 1]:
            # Left-dominant: counter side, not full-width flash structure.
            if edge_row[i] > right_row[i] * 1.2 + 0.5:
                if not peaks or i - peaks[-1] > 25:
                    peaks.append(i)
                elif sm[i] > sm[peaks[-1]]:
                    peaks[-1] = i

    bw = 28
    best = 0.0
    best_dy: int | None = None
    # Downsample patches once per peak for speed.
    peak_patches: list[tuple[int, np.ndarray]] = []
    for p0 in peaks:
        y0 = p0 - bw // 2
        if y0 < 0 or y0 + bw > h:
            continue
        patch = gray[y0 : y0 + bw, :x1]
        if float(patch.std()) < 10.0:
            continue
        small = np.asarray(
            Image.fromarray(patch.astype(np.uint8)).resize(
                (120, bw), Image.Resampling.BILINEAR
            ),
            dtype=np.float32,
        )
        peak_patches.append((p0, small))

    for i, (p0, A) in enumerate(peak_patches):
        Az = A - A.mean()
        an = float(np.linalg.norm(Az))
        if an < 1e-3:
            continue
        for p1, B in peak_patches[i + 1 :]:
            dy = p1 - p0
            if dy < 80 or dy > 700:
                continue
            Bz = B - B.mean()
            bn = float(np.linalg.norm(Bz))
            if bn < 1e-3:
                continue
            ncc = float(np.dot(Az.ravel(), Bz.ravel()) / (an * bn))
            if ncc > best:
                best, best_dy = ncc, dy
    if best >= 0.75 and best_dy is not None:
        vdup = True
        vdup_score = best
        vdup_dy = best_dy
        vdup_path = "edge_ncc"

    # Path B: half-frame NCC on left half of active picture.
    if not vdup:
        row_m = gray.mean(axis=1)
        act = np.where(row_m > 5.0)[0]
        if len(act) >= 100:
            y0 = int(act[0])
            y1 = int(act[-1]) + 1
            mid = (y0 + y1) // 2
            top = gray[y0:mid, :x1]
            bot = gray[mid : mid + (mid - y0), :x1]
            hh = min(top.shape[0], bot.shape[0])
            if hh >= 80:
                Ti = np.asarray(
                    Image.fromarray(top[:hh].astype(np.uint8)).resize(
                        (120, 80), Image.Resampling.BILINEAR
                    ),
                    dtype=np.float32,
                )
                Bi = np.asarray(
                    Image.fromarray(bot[:hh].astype(np.uint8)).resize(
                        (120, 80), Image.Resampling.BILINEAR
                    ),
                    dtype=np.float32,
                )
                if float(Ti.std()) > 12.0 and float(Bi.std()) > 12.0:
                    Tz = Ti - Ti.mean()
                    Bz = Bi - Bi.mean()
                    ncc = float(
                        np.dot(Tz.ravel(), Bz.ravel())
                        / (float(np.linalg.norm(Tz)) * float(np.linalg.norm(Bz)) + 1e-9)
                    )
                    if ncc >= 0.70:
                        vdup = True
                        vdup_score = ncc
                        vdup_dy = mid - y0
                        vdup_path = "half_ncc"

    structure_fail = bool(vdup or horiz_wrap)
    return {
        "vertical_dup": bool(vdup),
        "horiz_wrap": bool(horiz_wrap),
        "structure_fail": structure_fail,
        "vdup_score": round(float(vdup_score), 3),
        "vdup_dy": vdup_dy,
        "vdup_path": vdup_path,
        "wrap_ratio": round(float(wrap_ratio), 3),
        "wrap_both_e": round(float(both_e), 3),
        "wrap_mid_e": round(float(mid_e), 3),
    }


def find_overlay(
    rgb: np.ndarray,
) -> tuple[np.ndarray | None, tuple[int, int, int, int] | None, str]:
    """Locate yellow overlay binary in top-of-active-picture band.

    Returns (binary, roi_xyxy, status) where status is ok|warmup|no_overlay.

    ROI padding is load-bearing: the yellow mask bbox often ends mid-glyph on the
    trailing digit (AA/border pixels fall outside the hard yellow threshold).
    Parent lab evidence on /tmp/cap480_long: ROI x1=643 clipped the final glyph
    so ``1352`` OCR'd as ``13527`` and ``2912`` as ``2917``. gen_avsync_blip.py
    draws ``TREK24 n=%{n}`` at fixed (x=8,y=8) with growing digit width — a
    tight mask on early 1–3 digit frames is not the failure mode (bbox is
    recomputed every frame); per-frame right-edge clip of the *current* last
    digit is. Pad by ~2 glyph widths from ROI height so 1→4 digit growth and
    AA skirts stay inside the crop.
    """
    h, w = rgb.shape[:2]
    if _is_uniform(rgb):
        # Near-black uniform = grabber warm-up. Lit uniform grey stays scorable.
        if float(rgb.mean()) < 15.0:
            return None, None, "warmup"
        return None, None, "no_overlay"

    mean_luma = float(rgb.mean())
    # Flash frames: prefer chroma mask; dark frames: plain yellow.
    if mean_luma > 40.0:
        m = _chroma_yellow_mask(rgb) | _yellow_mask(rgb)
    else:
        m = _yellow_mask(rgb)

    if int(m.sum()) < 80:
        return None, None, "no_overlay"

    row_e = rgb.astype(np.float32).mean(axis=2).mean(axis=1)
    active = np.where(row_e > 3.0)[0]
    y_top = int(active[0]) if len(active) else 0

    ys, xs = np.where(m)
    keep = (ys >= y_top) & (ys <= y_top + int(0.40 * h)) & (xs < int(0.80 * w))
    if int(keep.sum()) < 80:
        keep = (ys < int(0.45 * h)) & (xs < int(0.80 * w))
    if int(keep.sum()) < 80:
        return None, None, "no_overlay"

    ys, xs = ys[keep], xs[keep]
    y0_raw = int(ys.min())
    y1_raw = int(ys.max()) + 1
    x0_raw = int(xs.min())
    x1_raw = int(xs.max()) + 1
    box_h = max(1, y1_raw - y0_raw)
    # ~0.6*height ≈ one DejaVu digit advance at this fontsize; pad 2+ widths
    # on the right (trailing n=NNNN growth + AA), 1 width elsewhere.
    pad_x_right = max(48, int(round(2.4 * box_h)))
    pad_x_left = max(8, int(round(0.6 * box_h)))
    pad_y = max(4, int(round(0.25 * box_h)))
    y0 = max(0, y0_raw - pad_y)
    y1 = min(h, y1_raw + pad_y)
    x0 = max(0, x0_raw - pad_x_left)
    x1 = min(w, x1_raw + pad_x_right)
    # CRITICAL: do not return the hard-mask slice alone. Padding a False skirt
    # adds no ink. Re-threshold the padded RGB crop with hard|soft|chroma so
    # the previously clipped trailing glyph columns become ink for OCR.
    crop = rgb[y0:y1, x0:x1]
    if mean_luma > 40.0:
        binary = (
            _chroma_yellow_mask(crop)
            | _yellow_mask(crop)
            | _yellow_mask_soft(crop)
        )
    else:
        binary = _yellow_mask(crop) | _yellow_mask_soft(crop)
    if int(binary.sum()) < 80:
        # Fall back to hard-mask crop rather than inventing empty ink.
        binary = m[y0:y1, x0:x1]
    return binary, (x0, y0, x1, y1), "ok"


def overlay_fingerprint(binary: np.ndarray) -> str:
    """Stable short hash of a downscaled overlay bitmap (motion secondary signal)."""
    im = Image.fromarray((binary.astype(np.uint8) * 255))
    im = im.resize((96, 24), Image.Resampling.NEAREST)
    arr = (np.asarray(im) > 128).astype(np.uint8)
    return hashlib.md5(arr.tobytes()).hexdigest()[:12]


# ---------------------------------------------------------------------------
# OCR
# ---------------------------------------------------------------------------

_LABEL_RE = re.compile(
    r"(?i)(?:TREK|PLEX|NTSC)[A-Za-z0-9]*\s*n\s*=\s*(\d{1,5})"
)
_N_EQ_RE = re.compile(r"(?i)\bn\s*=\s*(\d{1,5})")
_EQ_RE = re.compile(r"=\s*(\d{1,5})\b")


def _tesseract_png(img: Image.Image, psm: int, whitelist: str) -> str:
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    try:
        r = subprocess.run(
            [
                "tesseract",
                "stdin",
                "stdout",
                "--psm",
                str(psm),
                "-c",
                f"tessedit_char_whitelist={whitelist}",
            ],
            input=buf.getvalue(),
            capture_output=True,
            timeout=15,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return ""
    return " ".join(r.stdout.decode("utf-8", "replace").split())


def _prep_variants(binary: np.ndarray, mean_luma: float) -> list[Image.Image]:
    """A few OCR-ready images (keep call count low — tesseract is the cost)."""
    bim = Image.fromarray((binary.astype(np.uint8) * 255))
    scale = max(2.5, 64.0 / max(1, bim.height))
    bim = bim.resize(
        (max(1, int(bim.width * scale)), max(1, int(bim.height * scale))),
        Image.Resampling.LANCZOS,
    )
    arr = (np.asarray(bim) > 128).astype(np.uint8) * 255
    bim = Image.fromarray(arr).filter(ImageFilter.MaxFilter(3))
    pad = Image.new("L", (bim.width + 30, bim.height + 30), 0)
    pad.paste(bim, (15, 15))
    inv = ImageOps.invert(pad)

    # Flash: black-on-white first; dark: white-on-black first.
    ordered = [inv, pad] if mean_luma > 40.0 else [pad, inv]

    # For flash, also try chroma-as-gray autocontrast of the ROI already in binary.
    if mean_luma > 40.0:
        g = Image.fromarray((binary.astype(np.uint8) * 255))
        g = g.resize(
            (max(1, g.width * 4), max(1, g.height * 4)), Image.Resampling.NEAREST
        )
        g = ImageOps.autocontrast(g)
        ordered.append(ImageOps.invert(g))
        ordered.append(g)

    # Digit-right crop of the preferred polarity.
    primary = ordered[0]
    w, _h = primary.size
    ordered.append(primary.crop((int(w * 0.55), 0, w, _h)))
    return ordered


def _parse_counter(text: str) -> tuple[int | None, int]:
    """Return (n, tier). Higher tier = more trustworthy parse."""
    if not text:
        return None, 0
    m = _LABEL_RE.search(text)
    if m:
        return int(m.group(1)), 10
    m = _N_EQ_RE.search(text)
    if m:
        return int(m.group(1)), 9
    m = _EQ_RE.search(text)
    if m:
        return int(m.group(1)), 7
    if re.fullmatch(r"\d{2,5}", text):
        return int(text), 5
    runs = re.findall(r"\d{2,5}", text)
    if len(runs) == 1:
        return int(runs[0]), 4
    return None, 0


def ocr_counter(binary: np.ndarray, mean_luma: float) -> tuple[int | None, int, str]:
    """OCR the overlay binary. Returns (n|None, tier, raw_text)."""
    wl_full = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789= "
    wl_digits = "0123456789nN= "
    votes: list[tuple[int, int, str]] = []
    raws: list[str] = []

    for img in _prep_variants(binary, mean_luma):
        for psm in (7, 8):
            # Full whitelist first (captures TREK24 n=123).
            txt = _tesseract_png(img, psm, wl_full)
            if txt:
                raws.append(txt)
            n, tier = _parse_counter(txt)
            if n is not None and tier > 0:
                votes.append((tier, n, txt))
            # Early exit on strong label hit.
            if any(v[0] >= 9 for v in votes):
                break
        if any(v[0] >= 9 for v in votes):
            break

    # Digit-only fallback if no label-tier hit.
    if not any(v[0] >= 7 for v in votes):
        for img in _prep_variants(binary, mean_luma)[:2]:
            txt = _tesseract_png(img, 7, wl_digits)
            if txt:
                raws.append(txt)
            n, tier = _parse_counter(txt)
            if n is not None and tier > 0:
                votes.append((tier, n, txt))

    if not votes:
        return None, 0, (raws[0] if raws else "")

    max_tier = max(v[0] for v in votes)
    top = [v for v in votes if v[0] >= max_tier - 1]
    counts = Counter(v[1] for v in top)
    best_n, best_c = counts.most_common(1)[0]
    tier = max(v[0] for v in top if v[1] == best_n)
    raw = next(v[2] for v in top if v[1] == best_n)

    # Accept label-tier (>=7) with any vote; bare digits need agreement.
    if tier >= 7 or (tier >= 5 and best_c >= 2):
        return best_n, tier, raw
    return None, tier, raw


# ---------------------------------------------------------------------------
# Per-frame + burst scoring
# ---------------------------------------------------------------------------

def _template_read_n(binary: np.ndarray) -> tuple[int | None, float, str]:
    """Best-effort digit-template read of the rightmost counter field.

    Used when tesseract fails (typically white-flash frames). Templates ship in
    tools/hdmi_motion_digit_templates.npz (built from real TREK24 HDMI captures).
    Tries a few erode strengths and split strategies; majority-votes the result.
    Returns (n, min_score, raw).
    """
    tpl_path = Path(__file__).resolve().parent / "hdmi_motion_digit_templates.npz"
    if not tpl_path.is_file():
        return None, 0.0, ""
    try:
        data = np.load(tpl_path)
    except OSError:
        return None, 0.0, ""
    avg = {k[1:]: data[k].astype(np.float32) for k in data.files if k.startswith("d")}
    if len(avg) < 10:
        return None, 0.0, ""

    def _norm(mask: np.ndarray, H: int = 36, W: int = 24) -> np.ndarray:
        tim = Image.fromarray(mask.astype(np.uint8) * 255).resize((W, H), Image.NEAREST)
        return (np.asarray(tim) > 128).astype(np.float32)

    def _ncc(x: np.ndarray, y: np.ndarray) -> float:
        x = x.ravel() - x.mean()
        y = y.ravel() - y.mean()
        dx = float(np.linalg.norm(x))
        dy = float(np.linalg.norm(y))
        if dx < 1e-6 or dy < 1e-6:
            return -1.0
        return float(np.dot(x, y) / (dx * dy))

    def _classify(sub: np.ndarray) -> tuple[str, float]:
        rows = sub.any(axis=1)
        cols = sub.any(axis=0)
        if not rows.any() or not cols.any():
            return "?", -1.0
        ys = np.where(rows)[0]
        xs = np.where(cols)[0]
        sub = sub[ys.min() : ys.max() + 1, xs.min() : xs.max() + 1]
        dn = _norm(sub)
        best, bs = "?", -1.0
        for ch, t in avg.items():
            s = _ncc(dn, t)
            if s > bs:
                best, bs = ch, s
        return best, bs

    def _attempt(b2: np.ndarray) -> tuple[int | None, float, str]:
        col = np.convolve(b2.mean(axis=0), np.ones(3) / 3.0, mode="same")
        thr = float(col.max()) * 0.10
        if thr <= 0:
            return None, 0.0, ""
        runs: list[tuple[int, int]] = []
        i = 0
        w = int(col.shape[0])
        while i < w:
            if col[i] >= thr:
                j = i
                while j < w and col[j] >= thr:
                    j += 1
                runs.append((i, j))
                i = j
            else:
                i += 1
        if not runs:
            return None, 0.0, ""
        a, b = runs[-1]
        region = b2[:, a:b]
        rw = int(region.shape[1])
        if rw < 12:
            return None, 0.0, ""

        # Sub-runs inside the rightmost blob (may already be split).
        c2 = np.convolve(region.mean(axis=0), np.ones(2) / 2.0, mode="same")
        thr2 = float(c2.max()) * 0.18
        subruns: list[tuple[int, int]] = []
        i = 0
        while i < rw:
            if c2[i] >= thr2:
                j = i
                while j < rw and c2[j] >= thr2:
                    j += 1
                if j - i >= 2:
                    subruns.append((i, j))
                i = j
            else:
                i += 1

        candidates: list[list[int]] = []
        if len(subruns) >= 3:
            sa0, _ = subruns[-3]
            sa1, _ = subruns[-2]
            sa2, sb2 = subruns[-1]
            candidates.append([sa0, sa1, sa2, sb2])
        if len(subruns) >= 1:
            sa, sb = subruns[-1]
            fat_w = sb - sa
            if fat_w > 40:
                candidates.append([sa, sa + fat_w // 3, sa + 2 * fat_w // 3, sb])
                # valley pair on fat run
                fat = region[:, sa:sb]
                proj = np.convolve(fat.mean(axis=0), np.ones(3) / 3.0, mode="same")
                interior = proj[4 : max(5, fat_w - 4)]
                mins: list[tuple[float, int]] = []
                for ii in range(1, len(interior) - 1):
                    if interior[ii] < interior[ii - 1] and interior[ii] <= interior[ii + 1]:
                        mins.append((float(interior[ii]), ii + 4))
                mins.sort()
                vs = sorted(m[1] for m in mins[:6])
                best_pair = None
                best_sc = 1e9
                for i0 in range(len(vs)):
                    for i1 in range(i0 + 1, len(vs)):
                        if vs[i1] - vs[i0] < fat_w * 0.15:
                            continue
                        if vs[i0] < fat_w * 0.12 or vs[i1] > fat_w * 0.88:
                            continue
                        scv = float(proj[vs[i0]] + proj[vs[i1]])
                        if scv < best_sc:
                            best_sc = scv
                            best_pair = (vs[i0], vs[i1])
                if best_pair is not None:
                    candidates.append(
                        [sa, sa + best_pair[0], sa + best_pair[1], sb]
                    )
        # Whole right region equal thirds
        candidates.append([0, rw // 3, 2 * rw // 3, rw])

        best_n: int | None = None
        best_min = -1.0
        best_raw = ""
        for cuts in candidates:
            if len(cuts) != 4:
                continue
            chars: list[str] = []
            scores: list[float] = []
            ok = True
            for k in range(3):
                x0, x1 = cuts[k], cuts[k + 1]
                if x1 - x0 < 2:
                    ok = False
                    break
                ch, s = _classify(region[:, x0:x1])
                chars.append(ch)
                scores.append(s)
            if not ok or not all(c.isdigit() for c in chars):
                continue
            mn = float(min(scores))
            if mn < 0.30:
                continue
            if mn > best_min:
                best_min = mn
                best_n = int("".join(chars))
                best_raw = "".join(chars)
        return best_n, best_min, best_raw

    votes: list[tuple[int, float, str]] = []
    base = Image.fromarray((binary.astype(np.uint8) * 255))
    for erode_n in (0, 1, 2):
        im = base
        for _ in range(erode_n):
            im = im.filter(ImageFilter.MinFilter(3))
        b2 = np.asarray(im) > 128
        n, sc, raw = _attempt(b2)
        if n is not None:
            votes.append((n, sc, raw))

    if not votes:
        # Return weakest raw for debugging if any attempt produced digits-like text
        return None, 0.0, ""

    # Majority vote weighted by score
    tallies: dict[int, float] = {}
    raw_for: dict[int, str] = {}
    for n, sc, raw in votes:
        tallies[n] = tallies.get(n, 0.0) + sc
        raw_for[n] = raw
    best_n = max(tallies, key=lambda k: tallies[k])
    best_sc = max(sc for n, sc, _ in votes if n == best_n)
    # Require either multi-vote agreement or a strong single score
    agree = sum(1 for n, _, _ in votes if n == best_n)
    if agree >= 2 or best_sc >= 0.40:
        return best_n, float(best_sc), raw_for[best_n]
    return None, float(best_sc), raw_for[best_n]


def read_frame(path: str | Path, *, force_ocr: bool = False) -> dict[str, Any]:
    """Read one PNG. Never raises on decode failure — returns status.

    force_ocr: always run OCR (single-frame mode). In burst mode, bright flash
    frames skip tesseract (dark frames carry the counter) but still try the
    digit-template fallback so a visible overlay is not silently ignored.
    """
    path = str(path)
    _struct_empty = {
        "vertical_dup": False,
        "horiz_wrap": False,
        "structure_fail": False,
        "vdup_score": 0.0,
        "vdup_dy": None,
        "vdup_path": "",
        "wrap_ratio": 0.0,
        "wrap_both_e": 0.0,
        "wrap_mid_e": 0.0,
    }
    try:
        im = Image.open(path).convert("RGB")
    except OSError as e:
        return {
            "path": path,
            "status": "bad_file",
            "n": None,
            "tier": 0,
            "raw": str(e),
            "fp": None,
            "mean_rgb": None,
            "green_frac": None,
            "green_cast": False,
            "channel_spread": None,
            "chroma_cast": False,
            "color_fail": False,
            **_struct_empty,
        }

    rgb = np.asarray(im)
    gc = green_cast_metrics(rgb)
    sm = structure_metrics(rgb)
    mean_luma = float(rgb.mean())

    binary, roi, st = find_overlay(rgb)
    if binary is None:
        return {
            "path": path,
            "status": st,
            "n": None,
            "tier": 0,
            "raw": "",
            "fp": None,
            "roi": None,
            "mean_luma": round(mean_luma, 3),
            **gc,
            **sm,
        }

    fp = overlay_fingerprint(binary)
    n: int | None = None
    tier = 0
    raw = ""

    # Dark / mid frames: tesseract is reliable. Bright flash: tesseract is often
    # blind; prefer template fallback (and still try OCR when force_ocr).
    run_tess = force_ocr or mean_luma <= 40.0
    if run_tess:
        n, tier, raw = ocr_counter(binary, mean_luma)

    # Template fallback: only for force_ocr (single-frame inspection) or when
    # OCR is completely blind on a mid/dark frame. Burst motion scoring does
    # not need flash-frame numbers — dark frames carry the counter.
    if n is None and (force_ocr or mean_luma <= 40.0):
        tn, tscore, traw = _template_read_n(binary)
        if tn is not None and tscore >= 0.35:
            n, tier, raw = tn, 6, f"tpl:{traw}"
        elif traw:
            raw = raw or f"tpl_weak:{traw}"

    status = "ok" if n is not None else "undecoded"
    return {
        "path": path,
        "status": status,
        "n": n,
        "tier": tier,
        "raw": raw,
        "fp": fp,
        "roi": roi,
        "mean_luma": round(mean_luma, 3),
        "overlay_present": True,
        **gc,
        **sm,
    }


def list_capture_frames(src: str | Path) -> list[str]:
    """Directory of f_*.png (preferred) or any *.png; or a single file."""
    p = Path(src)
    if p.is_file():
        return [str(p)]
    if not p.is_dir():
        return []
    frames = sorted(p.glob("f_*.png"))
    if not frames:
        frames = sorted(p.glob("*.png"))
    return [str(f) for f in frames]


def load_counters_csv(path: str | Path) -> list[tuple[int, int]]:
    """Load parent/cache CSV with at least idx + n columns (empty n skipped)."""
    import csv

    pairs: list[tuple[int, int]] = []
    with open(path, newline="") as f:
        r = csv.DictReader(f)
        if not r.fieldnames or "idx" not in r.fieldnames or "n" not in r.fieldnames:
            raise ValueError(f"counters CSV needs idx,n columns; got {r.fieldnames}")
        for row in r:
            ns = (row.get("n") or "").strip()
            if ns == "":
                continue
            pairs.append((int(row["idx"]), int(float(ns))))
    return pairs


def score_counter_pairs(
    pairs_raw: list[tuple[int, int]],
    *,
    source_fps: float = DEFAULT_ASSUMED_SOURCE_FPS,
    capture_fps: float = DEFAULT_ASSUMED_CAPTURE_FPS,
    source_fps_src: str = PROVENANCE_DEFAULT_ASSUMED,
    capture_fps_src: str = PROVENANCE_DEFAULT_ASSUMED,
    startup_window_s: float = STARTUP_DEFAULT_WINDOW_S,
    daemon_session_drops: int | None = None,
    daemon_drops_src: str = PROVENANCE_DEFAULT_ASSUMED,
    frames_total: int | None = None,
) -> dict[str, Any]:
    """Score a pre-decoded counter sequence (e.g. parent OCR cache CSV).

    Applies the same structural OCR filter + rate/skip/startup path as score_burst
    without re-reading PNGs. Colour/structure are UNSCORED here (no pixels).
    """
    pairs, ocr_rejections = _filter_counter_pairs(pairs_raw)
    ns = [n for _, n in pairs]
    rate_info = analyze_counter_rate(
        pairs,
        source_fps=source_fps,
        capture_fps=capture_fps,
        source_fps_src=source_fps_src,
        capture_fps_src=capture_fps_src,
    )
    skip_info = analyze_counter_skips(
        pairs,
        source_fps=source_fps,
        capture_fps=capture_fps,
        source_fps_src=source_fps_src,
        capture_fps_src=capture_fps_src,
    )
    startup_info = analyze_startup_transient(
        pairs,
        source_fps=source_fps,
        capture_fps=capture_fps,
        source_fps_src=source_fps_src,
        capture_fps_src=capture_fps_src,
        window_s=startup_window_s,
        daemon_session_drops=daemon_session_drops,
        daemon_drops_src=daemon_drops_src,
    )
    motion = "UNSCORED"
    reason = "no_counter_reads"
    if len(ns) >= DEFAULT_MIN_READS:
        n_min, n_max = min(ns), max(ns)
        if n_max == n_min:
            motion, reason = "FREEZE", f"counter_pinned n={n_min}"
        elif n_max > n_min:
            motion = "MOTION_OK"
            reason = f"counter_advances {n_min}->{n_max} filtered={len(ns)}/{len(pairs_raw)}"
    rate_fail = bool(rate_info.get("rate_fail")) and motion != "FREEZE"
    rate_label = str(rate_info.get("rate") or "RATE_UNSCORED")
    if motion == "FREEZE":
        rate_label = "RATE_PINNED"
    if motion == "MOTION_OK" and rate_fail:
        reason = (
            f"rate_fail [{'; '.join(rate_info.get('rate_reasons') or [])}] "
            f"on top of {reason}"
        )
    if rate_fail:
        final, rc = "RATE_FAIL", RC_RATE_FAIL
    elif motion == "FREEZE":
        final, rc = "FREEZE", RC_FREEZE
    elif motion == "MOTION_OK":
        final, rc = "MOTION_OK", RC_MOTION_OK
    else:
        final, rc = "UNSCORED", RC_UNSCORED
    return {
        "frames_total": frames_total if frames_total is not None else (pairs_raw[-1][0] + 1 if pairs_raw else 0),
        "warmup_skipped": 0,
        "decodes": len(pairs_raw),
        "strong_decodes": len(pairs_raw),
        "ns_head": ns[:10],
        "ns_tail": ns[-10:],
        "n_min": (min(ns) if ns else None),
        "n_max": (max(ns) if ns else None),
        "unique_overlay_fp": 0,
        "green_cast_frames": 0,
        "chroma_cast_frames": 0,
        "greyscale_frames": 0,
        "uv_swap_frames": 0,
        "color_fail_frames": 0,
        "vertical_dup_frames": 0,
        "horiz_wrap_frames": 0,
        "structure_fail_frames": 0,
        "motion": motion,
        "color": "COLOR_UNSCORED_NO_PIXELS",
        "structure": "STRUCTURE_UNSCORED_NO_PIXELS",
        "rate": rate_label,
        "unique_ratio": rate_info.get("unique_ratio"),
        "endpoint_rate": rate_info.get("endpoint_rate"),
        "span_rate": rate_info.get("span_rate"),
        "expected_ratio": rate_info.get("expected_ratio"),
        "max_plateau": rate_info.get("max_plateau"),
        "max_plateau_allowed": rate_info.get("max_plateau_allowed"),
        "plateau_warn": rate_info.get("plateau_warn"),
        "plateau_hist": rate_info.get("plateau_hist"),
        "non_adjacent_revisits": rate_info.get("non_adjacent_revisits"),
        "cap_span": rate_info.get("cap_span"),
        "ctr_span": rate_info.get("ctr_span"),
        "fps_authoritative": rate_info.get("fps_authoritative"),
        "rate_notes": rate_info.get("rate_notes"),
        "rate_reasons": rate_info.get("rate_reasons"),
        "source_fps": rate_info.get("source_fps"),
        "capture_fps": rate_info.get("capture_fps"),
        "source_fps_src": rate_info.get("source_fps_src"),
        "capture_fps_src": rate_info.get("capture_fps_src"),
        "skip_status": skip_info.get("skip_status"),
        "frames_lost_rle": skip_info.get("frames_lost_rle"),
        "frames_lost_adj": skip_info.get("frames_lost_adj"),
        "skip_events_rle": skip_info.get("skip_events_rle"),
        "skip_events_adj": skip_info.get("skip_events_adj"),
        "skip_hist_rle": skip_info.get("skip_hist_rle"),
        "skip_hist_adj": skip_info.get("skip_hist_adj"),
        "step_hist_rle": skip_info.get("step_hist_rle"),
        "lost_frac_rle": skip_info.get("lost_frac_rle"),
        "lost_frac_adj": skip_info.get("lost_frac_adj"),
        "skip_confidence": skip_info.get("skip_confidence"),
        "skip_notes": skip_info.get("skip_notes"),
        "skip_arithmetic": skip_info.get("arithmetic"),
        "ocr_rejections": ocr_rejections,
        "ocr_rejected": len(ocr_rejections),
        "startup_status": startup_info.get("startup_status"),
        "startup_hypothesis": startup_info.get("hypothesis"),
        "startup_window_s": startup_info.get("startup_window_s"),
        "startup_window_s_src": startup_info.get("startup_window_s_src"),
        "startup_frames_lost_adj": startup_info.get("startup_frames_lost_adj"),
        "startup_frames_lost_rle": startup_info.get("startup_frames_lost_rle"),
        "startup_ctr_span": startup_info.get("startup_ctr_span"),
        "startup_n_first": startup_info.get("startup_n_first"),
        "startup_n_last": startup_info.get("startup_n_last"),
        "startup_unique": startup_info.get("startup_unique"),
        "startup_confidence": startup_info.get("startup_confidence"),
        "startup_skip_hist_adj": startup_info.get("startup_skip_hist_adj"),
        "startup_skip_hist_rle": startup_info.get("startup_skip_hist_rle"),
        "startup_step_hist_rle": startup_info.get("startup_step_hist_rle"),
        "daemon_session_drops": startup_info.get("daemon_session_drops"),
        "daemon_session_drops_src": startup_info.get("daemon_session_drops_src"),
        "startup_drops_match": startup_info.get("drops_match"),
        "startup_notes": startup_info.get("startup_notes"),
        "startup_arithmetic": startup_info.get("startup_arithmetic"),
        "verdict": final,
        "reason": reason,
        "rc": rc,
        "input_mode": "counters_csv",
    }


def _median_int(vals: list[int]) -> int:
    if not vals:
        return 0
    s = sorted(vals)
    return int(s[len(s) // 2])


def _filter_counter_outliers(ns: list[int]) -> list[int]:
    """Drop OCR blunders (extra digits, single-frame wild jumps).

    Real avsync counters are monotonic and same digit-width for a given clip
    segment. Tesseract occasionally emits 3434 for 345 or 17494 for 174; those
    must not flip a MOTION_OK median or fake a non-monotonic sequence.

    Prefer _filter_counter_pairs (structural + MAD). This ns-only path remains
    for callers that lack capture indices.
    """
    pairs = list(enumerate(ns))
    kept, _rej = _filter_counter_pairs(pairs)
    return [n for _, n in kept]


def _local_digit_mode(ns: list[int], i: int, radius: int = 4) -> tuple[int | None, int]:
    """Mode of digit-lengths in a neighbour window excluding i. (mode_len, count)."""
    lo = max(0, i - radius)
    hi = min(len(ns), i + radius + 1)
    lengths = [len(str(ns[j])) for j in range(lo, hi) if j != i]
    if not lengths:
        return None, 0
    mode_len, mode_c = Counter(lengths).most_common(1)[0]
    return int(mode_len), int(mode_c)


def _filter_counter_pairs(
    pairs: list[tuple[int, int]],
) -> tuple[list[tuple[int, int]], list[dict[str, Any]]]:
    """Filter (capture_idx, n) pairs: structural OCR rules first, then MAD.

    Structural rules are *implausible-by-construction* for a monotonic burned-in
    counter (parent false-RED on /tmp/cap480_long — NOT threshold loosening):

      1) digit-count discontinuity vs neighbours (e.g. 4-digit stream, one
         5-digit read ``1352``→``13527``): reject that sample.
      2) interior spike / backward: for triple (a,b,c) with a <= c < b, b is a
         strict local max above the continuing progression — reject b
         (covers ``2``→``7`` class: 1581,1587,1583 and 2911,2917,2913).
      3) sequential backward step after a kept level: reject the new read.

    MAD radius is unchanged (not widened). Rejections carry printed reasons
    naming capture idx and the violated rule so RATE_FAIL cannot launder OCR.
    """
    rejections: list[dict[str, Any]] = []
    if len(pairs) < 3:
        return list(pairs), rejections

    # --- Pass A: local digit-count discontinuity (not global mode alone) ---
    ns = [n for _, n in pairs]
    keep_idx = set(range(len(pairs)))
    for i, (cap_i, n) in enumerate(pairs):
        mode_len, mode_c = _local_digit_mode(ns, i, radius=4)
        if mode_len is None or mode_c < 2:
            continue
        dlen = len(str(n))
        if dlen != mode_len:
            keep_idx.discard(i)
            rejections.append(
                {
                    "cap_idx": int(cap_i),
                    "n": int(n),
                    "rule": "digit_count_discontinuity",
                    "reason": (
                        f"cap_idx={cap_i} n={n} digits={dlen} != neighbour_mode="
                        f"{mode_len} (count={mode_c}) — impossible for monotonic "
                        f"counter digit growth in one capture step"
                    ),
                }
            )

    stage = [pairs[i] for i in range(len(pairs)) if i in keep_idx]
    if len(stage) < 3:
        stage = list(pairs)

    # --- Pass B: RLE spike / trough (plateau-safe) ---
    # Parent 2→7 class often plateaus 1–2 capture frames (2917,2917) so a
    # sample-wise interior check sees neighbours (2911,2917) or (2917,2913)
    # and misses. Collapse runs first: for successive distinct values a,b,c
    #   spike if (b-a) >= 4 and c < b   # jumped up, then any drop
    #   trough if (a-b) >= 4 and c > b
    # Bank-swap 100,101,100: b-a=1 < 4 → kept (real revisit still RATE_FAIL).
    # Healthy +2 skip: a,a+2,a+3 → c>b → kept.
    changed = True
    while changed and len(stage) >= 3:
        changed = False
        ns_s = [n for _, n in stage]
        runs = _rle_runs(ns_s)
        if len(runs) < 3:
            break
        # Map run index → list of stage indices in that run
        run_stage_idxs: list[list[int]] = []
        si = 0
        for _v, cnt in runs:
            run_stage_idxs.append(list(range(si, si + cnt)))
            si += cnt
        drop_stage: set[int] = set()
        vals = [v for v, _ in runs]
        for ri in range(1, len(vals) - 1):
            a, b, c = vals[ri - 1], vals[ri], vals[ri + 1]
            rule = ""
            if (b - a) >= 4 and c < b:
                rule = "rle_spike_up_then_drop"
            elif (a - b) >= 4 and c > b:
                rule = "rle_trough_down_then_rise"
            if not rule:
                continue
            for sj in run_stage_idxs[ri]:
                drop_stage.add(sj)
                cap_j, n_j = stage[sj]
                rejections.append(
                    {
                        "cap_idx": int(cap_j),
                        "n": int(n_j),
                        "rule": rule,
                        "reason": (
                            f"cap_idx={cap_j} n={n_j} RLE neighbours "
                            f"{a}->{b}->{c}: {rule} — OCR spike/trough "
                            f"(e.g. trailing 2→7), not a real counter state"
                        ),
                    }
                )
        if drop_stage:
            stage = [p for k, p in enumerate(stage) if k not in drop_stage]
            changed = True

    if len(stage) < 3:
        stage = [pairs[i] for i in range(len(pairs)) if i in keep_idx] or list(pairs)

    # NOTE: do NOT strip all backward steps. Bank-swap ping-pong (100,101,100,101)
    # is exactly the real revisit RATE_FAIL we must still catch. Large backward
    # OCR jumps are already removed as spikes/troughs/digit-count.

    # --- Pass C: MAD gate (radius NOT widened — parent forbid) ---
    ns2 = [n for _, n in stage]
    lengths = Counter(len(str(n)) for n in ns2)
    mode_len, mode_c = lengths.most_common(1)[0]
    if mode_c >= max(3, len(ns2) // 3):
        by_len = [(i, n) for i, n in stage if len(str(n)) == mode_len]
        for i, n in stage:
            if len(str(n)) != mode_len:
                # Already mostly caught; record if still present
                if not any(r["cap_idx"] == i and r["n"] == n for r in rejections):
                    rejections.append(
                        {
                            "cap_idx": int(i),
                            "n": int(n),
                            "rule": "global_digit_mode",
                            "reason": (
                                f"cap_idx={i} n={n} digits={len(str(n))} != "
                                f"global_mode={mode_len}"
                            ),
                        }
                    )
    else:
        by_len = list(stage)
    if len(by_len) < 3:
        by_len = list(stage)
    med = _median_int([n for _, n in by_len])
    abs_dev = sorted(abs(n - med) for _, n in by_len)
    mad = abs_dev[len(abs_dev) // 2] if abs_dev else 0
    radius = max(80, 6 * mad if mad > 0 else 80)
    filtered = [(i, n) for i, n in by_len if abs(n - med) <= radius]
    for i, n in by_len:
        if abs(n - med) > radius:
            rejections.append(
                {
                    "cap_idx": int(i),
                    "n": int(n),
                    "rule": "mad_radius",
                    "reason": (
                        f"cap_idx={i} n={n} outside MAD radius={radius} med={med}"
                    ),
                }
            )
    if len(filtered) >= 3:
        out: list[tuple[int, int]] = [filtered[0]]
        level = float(filtered[0][1])
        for i, n in filtered[1:]:
            if abs(n - level) <= radius * 1.5:
                out.append((i, n))
                level = 0.7 * level + 0.3 * float(n)
            else:
                rejections.append(
                    {
                        "cap_idx": int(i),
                        "n": int(n),
                        "rule": "sequential_mad_jump",
                        "reason": (
                            f"cap_idx={i} n={n} jump from level={level:.1f} "
                            f"> radius*1.5={radius * 1.5}"
                        ),
                    }
                )
        filtered = out if len(out) >= 3 else filtered
    kept = filtered if len(filtered) >= 3 else by_len
    return kept, rejections


def _rle_runs(ns: list[int]) -> list[tuple[int, int]]:
    """Run-length encode counter sequence → [(value, plateau_len), ...]."""
    if not ns:
        return []
    runs: list[tuple[int, int]] = []
    cur, cnt = ns[0], 1
    for x in ns[1:]:
        if x == cur:
            cnt += 1
        else:
            runs.append((cur, cnt))
            cur, cnt = x, 1
    runs.append((cur, cnt))
    return runs


def analyze_counter_rate(
    pairs: list[tuple[int, int]],
    *,
    source_fps: float = DEFAULT_ASSUMED_SOURCE_FPS,
    capture_fps: float = DEFAULT_ASSUMED_CAPTURE_FPS,
    source_fps_src: str = PROVENANCE_DEFAULT_ASSUMED,
    capture_fps_src: str = PROVENANCE_DEFAULT_ASSUMED,
) -> dict[str, Any]:
    """Rate + revisit integrity on filtered (capture_idx, n) pairs.

    Parent known-good calibration (24.000 fps source, 30 fps capture, 105 frames):
      84 distinct states, max plateau 2, plateau hist {1,2}, 0 non-adjacent
      revisits, unique/frames = 0.800 = source/capture.

    source_fps / capture_fps are NEVER measured here — provenance must be
    caller or DEFAULT_ASSUMED (ERROR 17). RATE_OK requires BOTH fps
    caller-supplied. DEFAULT_ASSUMED → RATE_UNSCORED (never RATE_OK).

    Returns rate dimension RATE_OK | RATE_FAIL | RATE_UNSCORED plus metrics.
    RATE_UNSCORED = insufficient samples OR fps assumed — not a pass.
    """
    src_ok = source_fps_src == PROVENANCE_CALLER
    cap_ok = capture_fps_src in (
        PROVENANCE_CALLER,
        PROVENANCE_CONTAINER,
        PROVENANCE_MEASURED,
    )
    fps_auth = bool(src_ok and cap_ok)
    empty = {
        "rate": "RATE_UNSCORED",
        "rate_fail": False,
        "unique_ratio": None,
        "endpoint_rate": None,
        "span_rate": None,  # deprecated alias of endpoint_rate
        "expected_ratio": None,
        "max_plateau": None,
        "max_plateau_allowed": None,
        "plateau_warn": False,
        "plateau_hist": {},
        "unique_states": 0,
        "n_samples": 0,
        "non_adjacent_revisits": 0,
        "revisit_fail": False,
        "rate_reasons": [],
        "rate_notes": [],
        "fps_authoritative": fps_auth,
        "source_fps": source_fps,
        "capture_fps": capture_fps,
        "source_fps_src": source_fps_src,
        "capture_fps_src": capture_fps_src,
    }
    if source_fps <= 0 or capture_fps <= 0:
        empty["rate_reasons"] = ["invalid_fps"]
        empty["fps_authoritative"] = False
        return empty

    expected = source_fps / capture_fps
    max_plat_allowed = int(math.ceil(capture_fps / source_fps)) + 1
    empty["expected_ratio"] = round(expected, 4)
    empty["max_plateau_allowed"] = max_plat_allowed
    if not fps_auth:
        empty["rate_notes"] = [
            "rate_unscored_fps_assumed "
            f"src={source_fps_src} cap={capture_fps_src} "
            "(pass --source-fps/--capture-fps from daemon fps= token for RATE_OK)"
        ]

    if len(pairs) < RATE_MIN_SAMPLES:
        empty["n_samples"] = len(pairs)
        empty["rate_reasons"] = [f"insufficient_samples={len(pairs)} need>={RATE_MIN_SAMPLES}"]
        return empty

    idxs = [i for i, _ in pairs]
    ns = [n for _, n in pairs]
    runs = _rle_runs(ns)
    plateaus = [c for _, c in runs]
    unique_states = len(runs)
    max_plateau = max(plateaus) if plateaus else 0
    plateau_hist = dict(Counter(plateaus))
    unique_ratio = unique_states / len(ns)

    # --- endpoint_rate: counter advance per capture-index step ---
    # Definition (comparable to expected = src_fps/cap_fps on monotonic play):
    #   endpoint_rate = (n_last - n_first) / (cap_idx_last - cap_idx_first)
    # after outlier filtering. This is counter-delta per capture frame.
    #
    # HISTORY / PARENT RULE-0 FINDING:
    #   A prior revision preferred (last_third_median - first_third_median) /
    #   cap_span to dodge max−min OCR dips. On a linear ramp that estimator
    #   is systematically ~2/3 of the true endpoint span
    #   ((5/6 − 1/6) = 2/3 of full range), so known-good bursts printed
    #   endpoint-like values of ~0.53 next to expected=0.80 and still PASSED.
    #   That made the rate gate decorative. Parent called it on capboot
    #   (0.7982 → 0.5321 with stable unique_ratio=0.8191).
    #
    # NEVER use max(ns)−min(ns): a single interior OCR dip (1207 amid
    # 1262..1324) inflates the span into a false RATE_FAIL.
    # NEVER use first/last-third medians as the gated span: biased low.
    cap_span = max(1, idxs[-1] - idxs[0])
    ctr_span_end = ns[-1] - ns[0]
    if ctr_span_end > 0:
        ctr_span = ctr_span_end
    elif ctr_span_end < 0:
        # Endpoints inverted (OCR mess at edge) — refuse to invent a rate.
        ctr_span = 0
    else:
        ctr_span = 0
    endpoint_rate = ctr_span / cap_span
    # Keep span_rate as a deprecated alias of endpoint_rate for one release
    # so older parsers do not break; print path uses the honest name.
    span_rate = endpoint_rate

    # Non-adjacent revisits on RLE values (any value that reappears after
    # another value intervened). Adjacent equals are already collapsed.
    seen: dict[int, int] = {}
    revisits = 0
    for ri, (v, _c) in enumerate(runs):
        if v in seen:
            revisits += 1
        seen[v] = ri

    reasons: list[str] = []
    notes: list[str] = []
    # Authoritative rate gates need BOTH fps from the caller. Anything else
    # is a guess printed next to real numbers (ERROR 17 class). Metrics are
    # still computed under the assumed pair for visibility, but they cannot
    # mint RATE_OK and cannot mint RATE_FAIL on ratio/endpoint/plateau.
    # Source must be caller-supplied (daemon fps=). Capture may be caller or
    # container-probed (ffprobe). DEFAULT_ASSUMED on either side → not authoritative.
    # (fps_auth already computed at top of function for empty-path consistency.)
    fps_authoritative = fps_auth

    # --- Revisit gate (stale-bank ping-pong) — fps-independent ---
    # Healthy parent measure: 0. Single OCR blip after filtering is tolerated
    # once; >=2 non-adjacent revisits is a measured integrity failure.
    revisit_fail = revisits >= 2
    if revisit_fail:
        reasons.append(f"non_adjacent_revisits={revisits}>=2 (bank-swap/ping-pong)")

    # --- Plateau / unique_ratio / endpoint_rate: only gate when authoritative ---
    # Form: max_plateau_allowed = ceil(cap/src)+1. At 24/30 that is 3.
    # Parent healthy calibration maxed at 2; 3/3 is one unlucky sample from
    # fail — still PASS (strict fail is only > allowed) but plateau_warn=1 so
    # bound-riding is never silent green.
    plateau_warn = bool(max_plateau == max_plat_allowed)
    if fps_authoritative:
        if max_plateau > max_plat_allowed:
            reasons.append(
                f"max_plateau={max_plateau}>{max_plat_allowed} "
                f"(ceil(cap/src)+1)"
            )
        elif plateau_warn:
            notes.append(
                f"plateau_warn max_plateau={max_plateau}==allowed "
                f"(bound-riding; healthy cal maxed at 2 for 24/30)"
            )

        # unique_ratio vs expected (PRIMARY comparable pair)
        # Parent calibration: unique_states/frames = 84/105 = 0.800 = src/cap.
        ratio_lo = expected * 0.60  # ~0.48 at 24/30
        if unique_ratio < ratio_lo:
            reasons.append(
                f"unique_ratio={unique_ratio:.3f}<{ratio_lo:.3f} "
                f"(expected≈{expected:.3f})"
            )

        # endpoint_rate vs expected (SECOND comparable pair)
        span_lo = expected * 0.55
        span_hi = expected * 1.55
        if endpoint_rate < span_lo:
            reasons.append(
                f"endpoint_rate={endpoint_rate:.3f}<{span_lo:.3f} "
                f"(ctr_span={ctr_span}/cap_span={cap_span}, expected≈{expected:.3f})"
            )
        if endpoint_rate > span_hi:
            reasons.append(
                f"endpoint_rate={endpoint_rate:.3f}>{span_hi:.3f} "
                f"(ctr_span={ctr_span}/cap_span={cap_span}, expected≈{expected:.3f})"
            )
    else:
        notes.append(
            "rate_unscored_fps_assumed "
            f"src={source_fps_src} cap={capture_fps_src} "
            "(pass --source-fps/--capture-fps from daemon fps= token for RATE_OK)"
        )
        # Informational only under assumed fps — never fail on the guess.
        if max_plateau > max_plat_allowed:
            notes.append(
                f"info_max_plateau={max_plateau}>{max_plat_allowed}_under_assumed_fps"
            )
        if plateau_warn:
            notes.append(
                f"info_plateau_at_bound={max_plateau} under assumed fps"
            )

    rate_fail = bool(reasons)
    if rate_fail:
        rate_label = "RATE_FAIL"
    elif not fps_authoritative:
        # Never RATE_OK on DEFAULT_ASSUMED (parent attack 2 / ERROR 17 class).
        rate_label = "RATE_UNSCORED"
    else:
        rate_label = "RATE_OK"

    return {
        "rate": rate_label,
        "rate_fail": rate_fail,
        # Comparable to expected (= src_fps/cap_fps) only when fps_authoritative:
        "unique_ratio": round(unique_ratio, 4),
        "endpoint_rate": round(endpoint_rate, 4),
        "expected_ratio": round(expected, 4),
        # Deprecated alias of endpoint_rate (same value); do not reinterpret.
        "span_rate": round(span_rate, 4),
        "max_plateau": int(max_plateau),
        "max_plateau_allowed": max_plat_allowed,
        "plateau_warn": bool(plateau_warn),
        "plateau_hist": {str(k): int(v) for k, v in sorted(plateau_hist.items())},
        "unique_states": int(unique_states),
        "n_samples": len(ns),
        "cap_span": int(cap_span),
        "ctr_span": int(ctr_span),
        "n_first": int(ns[0]),
        "n_last": int(ns[-1]),
        "non_adjacent_revisits": int(revisits),
        "revisit_fail": bool(revisit_fail),
        "rate_reasons": reasons,
        "rate_notes": notes,
        "fps_authoritative": bool(fps_authoritative),
        "source_fps": source_fps,
        "capture_fps": capture_fps,
        "source_fps_src": source_fps_src,
        "capture_fps_src": capture_fps_src,
    }


def score_burst(
    frames: list[str],
    *,
    warmup_skip: int = DEFAULT_WARMUP_SKIP,
    min_reads: int = DEFAULT_MIN_READS,
    source_fps: float = DEFAULT_ASSUMED_SOURCE_FPS,
    capture_fps: float = DEFAULT_ASSUMED_CAPTURE_FPS,
    source_fps_src: str = PROVENANCE_DEFAULT_ASSUMED,
    capture_fps_src: str = PROVENANCE_DEFAULT_ASSUMED,
    startup_window_s: float = STARTUP_DEFAULT_WINDOW_S,
    daemon_session_drops: int | None = None,
    daemon_drops_src: str = PROVENANCE_DEFAULT_ASSUMED,
    progress: bool = False,
) -> dict[str, Any]:
    """Score a capture burst. See module docstring for verdicts."""
    results: list[dict[str, Any]] = []
    for i, path in enumerate(frames):
        r = read_frame(path, force_ocr=False)
        r["idx"] = i
        results.append(r)
        if progress and (i + 1) % 25 == 0:
            print(f"  ...scored {i + 1}/{len(frames)}", file=sys.stderr)

    warmup_n = 0
    usable: list[dict[str, Any]] = []
    for r in results:
        if r["status"] == "warmup":
            warmup_n += 1
            continue
        # Leading grabber junk that is non-uniform but still pre-picture.
        if r["idx"] < warmup_skip and r["status"] != "ok":
            warmup_n += 1
            continue
        usable.append(r)

    ok_reads = [r for r in usable if r["status"] == "ok" and r["n"] is not None]
    # Burst motion sequence uses OCR-grade reads only (tier >= 7).
    # Template tier-6 (flash best-effort) must never manufacture MOTION_OK alone.
    strong = [r for r in ok_reads if int(r.get("tier") or 0) >= 7]
    seq_src = strong
    pairs_raw = [(int(r["idx"]), int(r["n"])) for r in seq_src]
    pairs, ocr_rejections = _filter_counter_pairs(pairs_raw)
    ns_raw = [n for _, n in pairs_raw]
    ns = [n for _, n in pairs]

    # Secondary motion signal: distinct overlay fingerprints on DARK usable frames.
    dark_fps = [
        r["fp"]
        for r in usable
        if r.get("fp")
        and r.get("mean_luma") is not None
        and float(r["mean_luma"]) < 30.0
    ]
    unique_fps = sorted(set(dark_fps))

    # Colour is scored on every non-warmup frame (including those with no overlay).
    green_hits = [
        r
        for r in results
        if r.get("green_cast") and r.get("status") != "warmup"
    ]
    chroma_hits = [
        r
        for r in results
        if r.get("chroma_cast") and r.get("status") != "warmup"
    ]
    grey_hits = [
        r
        for r in results
        if r.get("greyscale_flat") and r.get("status") != "warmup"
    ]
    uv_hits = [
        r
        for r in results
        if r.get("uv_swap") and r.get("status") != "warmup"
    ]
    color_hits = [
        r
        for r in results
        if r.get("color_fail") and r.get("status") != "warmup"
    ]
    color_fail = len(color_hits) >= GREEN_CAST_MIN_FRAMES
    color_flags: list[str] = []
    if len(green_hits) >= GREEN_CAST_MIN_FRAMES:
        color_flags.append("GREEN")
    if len(chroma_hits) >= GREEN_CAST_MIN_FRAMES:
        color_flags.append("CHROMA")
    if len(grey_hits) >= GREEN_CAST_MIN_FRAMES:
        color_flags.append("GREYSCALE")
    if len(uv_hits) >= GREEN_CAST_MIN_FRAMES:
        color_flags.append("UV_SWAP")
    if color_flags:
        color = "+".join(color_flags) + "_CAST_FAIL"
    else:
        color = "COLOR_OK"

    # Structural integrity (vertical dup / horizontal wrap) — independent of OCR.
    vdup_hits = [
        r
        for r in results
        if r.get("vertical_dup") and r.get("status") != "warmup"
    ]
    wrap_hits = [
        r
        for r in results
        if r.get("horiz_wrap") and r.get("status") != "warmup"
    ]
    struct_hits = [
        r
        for r in results
        if r.get("structure_fail") and r.get("status") != "warmup"
    ]
    structure_fail = len(struct_hits) >= STRUCT_MIN_FRAMES
    struct_flags: list[str] = []
    if len(vdup_hits) >= STRUCT_MIN_FRAMES:
        struct_flags.append(f"VERT_DUP={len(vdup_hits)}")
    if len(wrap_hits) >= STRUCT_MIN_FRAMES:
        struct_flags.append(f"HORIZ_WRAP={len(wrap_hits)}")
    if structure_fail and not struct_flags:
        # Combined structure_fail frames without either flag alone reaching min
        # (e.g. 2 wrap + 2 vdup on different frames).
        struct_flags.append(f"STRUCT={len(struct_hits)}")
    structure = "+".join(struct_flags) if structure_fail else "STRUCTURE_OK"

    motion = "UNSCORED"
    reason = ""
    rate_info = analyze_counter_rate(
        pairs,
        source_fps=source_fps,
        capture_fps=capture_fps,
        source_fps_src=source_fps_src,
        capture_fps_src=capture_fps_src,
    )
    skip_info = analyze_counter_skips(
        pairs,
        source_fps=source_fps,
        capture_fps=capture_fps,
        source_fps_src=source_fps_src,
        capture_fps_src=capture_fps_src,
    )
    startup_info = analyze_startup_transient(
        pairs,
        source_fps=source_fps,
        capture_fps=capture_fps,
        source_fps_src=source_fps_src,
        capture_fps_src=capture_fps_src,
        window_s=startup_window_s,
        daemon_session_drops=daemon_session_drops,
        daemon_drops_src=daemon_drops_src,
    )
    if len(ns) < min_reads:
        # Secondary: overlay bitmap motion without OCR.
        # Bitmap path has no counter rate → rate stays UNSCORED (not a pass).
        if len(dark_fps) >= min_reads and len(unique_fps) >= 2:
            motion = "MOTION_OK"
            reason = (
                f"overlay_bitmap_changes unique_fp={len(unique_fps)} "
                f"dark_frames={len(dark_fps)} (OCR decodes={len(ns)}<{min_reads})"
            )
        elif len(dark_fps) >= min_reads and len(unique_fps) == 1:
            motion = "FREEZE"
            reason = (
                f"overlay_bitmap_pinned fp={unique_fps[0]} "
                f"dark_frames={len(dark_fps)} (OCR decodes={len(ns)}<{min_reads})"
            )
        else:
            motion = "UNSCORED"
            reason = (
                f"insufficient_decodes={len(ns)} need>={min_reads}; "
                f"dark_fp={len(dark_fps)} unique_fp={len(unique_fps)} "
                f"raw_decodes={len(ns_raw)}"
            )
    else:
        n_min, n_max = min(ns), max(ns)
        advances = sum(1 for a, b in zip(ns, ns[1:]) if b > a)
        k = max(1, len(ns) // 3)
        first_med = _median_int(ns[:k])
        last_med = _median_int(ns[-k:])
        mode_n, mode_c = Counter(ns).most_common(1)[0]
        mode_frac = mode_c / len(ns)

        if n_max == n_min:
            motion = "FREEZE"
            reason = f"counter_pinned n={n_min} reads={len(ns)}"
        elif last_med > first_med and (last_med - first_med) >= 1 and (n_max - n_min) >= 2:
            motion = "MOTION_OK"
            reason = (
                f"counter_advances {n_min}->{n_max} "
                f"first_med={first_med} last_med={last_med} "
                f"advances={advances}/{max(0, len(ns) - 1)} "
                f"filtered={len(ns)}/{len(ns_raw)}"
            )
        elif mode_frac >= 0.85:
            motion = "FREEZE"
            reason = f"counter_mode_pinned n={mode_n} frac={mode_c}/{len(ns)}"
        elif len(unique_fps) >= 2 and last_med >= first_med:
            # OCR noisy but overlay bitmaps change and medians non-decreasing.
            motion = "MOTION_OK"
            reason = (
                f"overlay_bitmap_changes unique_fp={len(unique_fps)} "
                f"ocr_span={n_min}->{n_max} med={first_med}->{last_med}"
            )
        else:
            motion = "UNSCORED"
            reason = (
                f"ambiguous advances={advances} span={n_min}->{n_max} "
                f"med={first_med}->{last_med} mode_frac={mode_frac:.2f}"
            )

    # Rate/revisit only hard-fails when we actually have a counter sequence.
    # FREEZE is already a measured motion fail (rate=0) — do not double-count
    # as RATE_FAIL. Bitmap-only MOTION_OK cannot claim RATE_OK.
    rate_fail = bool(rate_info.get("rate_fail")) and motion != "FREEZE"
    rate_label = str(rate_info.get("rate") or "RATE_UNSCORED")
    if motion == "FREEZE":
        rate_label = "RATE_PINNED"
    elif motion == "MOTION_OK" and rate_label == "RATE_UNSCORED" and len(ns) < RATE_MIN_SAMPLES:
        # Order-OK but too few samples for rate — keep motion, rate unscored.
        pass
    elif motion == "MOTION_OK" and rate_fail:
        # Order looked fine; rate/revisit proves it is not.
        reason = (
            f"rate_fail [{'; '.join(rate_info.get('rate_reasons') or [])}] "
            f"on top of {reason}"
        )

    # --- Severity resolution (see module docstring). Positive failure wins. ---
    # STRUCTURE > COLOR > RATE > FREEZE > MOTION_OK > UNSCORED.
    # Measured failures never collapse to rc=77, even when motion is UNSCORED.
    if structure_fail:
        final, rc = "STRUCTURE_FAIL", RC_STRUCTURE_FAIL
        reason = (
            f"structure={structure} frames={len(struct_hits)}>={STRUCT_MIN_FRAMES} "
            f"(hard FAIL independent of motion={motion} color={color} "
            f"rate={rate_label}); {reason}"
        )
    elif color_fail:
        final, rc = "COLOR_FAIL", RC_COLOR_FAIL
        reason = (
            f"color={color} frames={len(color_hits)}>={GREEN_CAST_MIN_FRAMES} "
            f"green={len(green_hits)} chroma_spread={len(chroma_hits)} "
            f"(hard FAIL independent of motion={motion} rate={rate_label}); {reason}"
        )
    elif rate_fail:
        final, rc = "RATE_FAIL", RC_RATE_FAIL
        reason = (
            f"rate={rate_label} "
            f"unique_ratio={rate_info.get('unique_ratio')} "
            f"endpoint_rate={rate_info.get('endpoint_rate')} "
            f"expected={rate_info.get('expected_ratio')} "
            f"max_plateau={rate_info.get('max_plateau')}/"
            f"{rate_info.get('max_plateau_allowed')} "
            f"revisits={rate_info.get('non_adjacent_revisits')} "
            f"(hard FAIL independent of motion={motion}); {reason}"
        )
    elif motion == "FREEZE":
        final, rc = "FREEZE", RC_FREEZE
    elif motion == "MOTION_OK":
        final, rc = "MOTION_OK", RC_MOTION_OK
    else:
        final, rc = "UNSCORED", RC_UNSCORED

    return {
        "frames_total": len(frames),
        "warmup_skipped": warmup_n,
        "decodes": len(ok_reads),
        "strong_decodes": len(strong),
        "ns_head": ns[:10],
        "ns_tail": ns[-10:],
        "n_min": (min(ns) if ns else None),
        "n_max": (max(ns) if ns else None),
        "unique_overlay_fp": len(unique_fps),
        "green_cast_frames": len(green_hits),
        "chroma_cast_frames": len(chroma_hits),
        "greyscale_frames": len(grey_hits),
        "uv_swap_frames": len(uv_hits),
        "color_fail_frames": len(color_hits),
        "vertical_dup_frames": len(vdup_hits),
        "horiz_wrap_frames": len(wrap_hits),
        "structure_fail_frames": len(struct_hits),
        "motion": motion,
        "color": color,
        "structure": structure,
        "rate": rate_label,
        "unique_ratio": rate_info.get("unique_ratio"),
        "endpoint_rate": rate_info.get("endpoint_rate"),
        "span_rate": rate_info.get("span_rate"),  # alias of endpoint_rate
        "expected_ratio": rate_info.get("expected_ratio"),
        "max_plateau": rate_info.get("max_plateau"),
        "max_plateau_allowed": rate_info.get("max_plateau_allowed"),
        "plateau_warn": rate_info.get("plateau_warn"),
        "plateau_hist": rate_info.get("plateau_hist"),
        "non_adjacent_revisits": rate_info.get("non_adjacent_revisits"),
        "cap_span": rate_info.get("cap_span"),
        "ctr_span": rate_info.get("ctr_span"),
        "fps_authoritative": rate_info.get("fps_authoritative"),
        "rate_notes": rate_info.get("rate_notes"),
        "source_fps": rate_info.get("source_fps"),
        "capture_fps": rate_info.get("capture_fps"),
        "source_fps_src": rate_info.get("source_fps_src"),
        "capture_fps_src": rate_info.get("capture_fps_src"),
        # Display-level skip measurement (count + confidence; not a hard rc).
        "skip_status": skip_info.get("skip_status"),
        "frames_lost_rle": skip_info.get("frames_lost_rle"),
        "frames_lost_adj": skip_info.get("frames_lost_adj"),
        "skip_events_rle": skip_info.get("skip_events_rle"),
        "skip_events_adj": skip_info.get("skip_events_adj"),
        "skip_hist_rle": skip_info.get("skip_hist_rle"),
        "skip_hist_adj": skip_info.get("skip_hist_adj"),
        "step_hist_rle": skip_info.get("step_hist_rle"),
        "lost_frac_rle": skip_info.get("lost_frac_rle"),
        "lost_frac_adj": skip_info.get("lost_frac_adj"),
        "skip_confidence": skip_info.get("skip_confidence"),
        "skip_notes": skip_info.get("skip_notes"),
        "skip_arithmetic": skip_info.get("arithmetic"),
        # Structural OCR rejections (digit-count / spike / backward) — printed.
        "ocr_rejections": ocr_rejections,
        "ocr_rejected": len(ocr_rejections),
        # Startup transient discriminator (measurement; not a hard rc alone).
        "startup_status": startup_info.get("startup_status"),
        "startup_hypothesis": startup_info.get("hypothesis"),
        "startup_window_s": startup_info.get("startup_window_s"),
        "startup_window_s_src": startup_info.get("startup_window_s_src"),
        "startup_frames_lost_adj": startup_info.get("startup_frames_lost_adj"),
        "startup_frames_lost_rle": startup_info.get("startup_frames_lost_rle"),
        "startup_ctr_span": startup_info.get("startup_ctr_span"),
        "startup_n_first": startup_info.get("startup_n_first"),
        "startup_n_last": startup_info.get("startup_n_last"),
        "startup_unique": startup_info.get("startup_unique"),
        "startup_confidence": startup_info.get("startup_confidence"),
        "startup_skip_hist_adj": startup_info.get("startup_skip_hist_adj"),
        "startup_skip_hist_rle": startup_info.get("startup_skip_hist_rle"),
        "startup_step_hist_rle": startup_info.get("startup_step_hist_rle"),
        "daemon_session_drops": startup_info.get("daemon_session_drops"),
        "daemon_session_drops_src": startup_info.get("daemon_session_drops_src"),
        "startup_drops_match": startup_info.get("drops_match"),
        "startup_notes": startup_info.get("startup_notes"),
        "startup_arithmetic": startup_info.get("startup_arithmetic"),
        "verdict": final,
        "reason": reason,
        "rc": rc,
        "reads": [
            {
                "f": os.path.basename(r["path"]),
                "status": r["status"],
                "n": r["n"],
                "tier": r.get("tier"),
                "fp": r.get("fp"),
                "mean": r.get("mean_luma"),
                "green_cast": r.get("green_cast"),
                "chroma_cast": r.get("chroma_cast"),
                "channel_spread": r.get("channel_spread"),
                "vertical_dup": r.get("vertical_dup"),
                "horiz_wrap": r.get("horiz_wrap"),
            }
            for r in results
        ],
    }


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def _print_human(report: dict[str, Any], src: str) -> None:
    print(f"src={src}")
    print(
        f"frames={report['frames_total']} warmup_skipped={report['warmup_skipped']} "
        f"decodes={report['decodes']} strong={report['strong_decodes']} "
        f"unique_fp={report['unique_overlay_fp']} "
        f"green_cast_frames={report['green_cast_frames']} "
        f"chroma_cast_frames={report.get('chroma_cast_frames', 0)} "
        f"greyscale_frames={report.get('greyscale_frames', 0)} "
        f"uv_swap_frames={report.get('uv_swap_frames', 0)} "
        f"vdup_frames={report.get('vertical_dup_frames', 0)} "
        f"wrap_frames={report.get('horiz_wrap_frames', 0)}"
    )
    if report["n_min"] is not None:
        print(
            f"counter n_min={report['n_min']} n_max={report['n_max']} "
            f"head={report['ns_head']} tail={report['ns_tail']}"
        )
    ocr_n = int(report.get("ocr_rejected") or 0)
    if ocr_n:
        print(f"ocr_rejected={ocr_n} (structural digit_count/spike/backward — not scored)")
        for rej in (report.get("ocr_rejections") or [])[:40]:
            print(f"  ocr_reject {rej.get('reason')}")
        if ocr_n > 40:
            print(f"  ocr_reject ... ({ocr_n - 40} more)")
    print(
        f"motion={report['motion']} color={report['color']} "
        f"structure={report.get('structure', 'STRUCTURE_OK')} "
        f"rate={report.get('rate', 'RATE_UNSCORED')}"
    )
    if report.get("unique_ratio") is not None or report.get("source_fps") is not None:
        # Print comparable pairs together; never mix incomparable quantities.
        # unique_ratio  ≈ expected  (= src_fps/cap_fps)   — primary gate
        # endpoint_rate ≈ expected  (ctr_span/cap_span)   — secondary gate
        pw = report.get("plateau_warn")
        pw_s = " plateau_warn=1" if pw else ""
        auth = report.get("fps_authoritative")
        auth_s = "fps_authoritative=1" if auth else "fps_authoritative=0"
        print(
            f"rate_metrics "
            f"unique_ratio={report.get('unique_ratio')} "
            f"endpoint_rate={report.get('endpoint_rate')} "
            f"expected={report.get('expected_ratio')} "
            f"(unique_ratio and endpoint_rate comparable to expected only when "
            f"fps_authoritative) "
            f"max_plateau={report.get('max_plateau')}/"
            f"{report.get('max_plateau_allowed')}{pw_s} "
            f"plateau_hist={report.get('plateau_hist')} "
            f"revisits={report.get('non_adjacent_revisits')} "
            f"ctr_span={report.get('ctr_span')} cap_span={report.get('cap_span')} "
            f"src_fps={report.get('source_fps')} "
            f"src={report.get('source_fps_src', PROVENANCE_DEFAULT_ASSUMED)} "
            f"cap_fps={report.get('capture_fps')} "
            f"cap={report.get('capture_fps_src', PROVENANCE_DEFAULT_ASSUMED)} "
            f"{auth_s}"
        )
        notes = report.get("rate_notes") or []
        if notes:
            print(f"rate_notes={' | '.join(str(n) for n in notes)}")
    # Display-level skip measurement (pixels only; not daemon drops/av_drift).
    if report.get("skip_status") is not None or report.get("frames_lost_adj") is not None:
        print(
            f"skip_metrics status={report.get('skip_status')} "
            f"conf={report.get('skip_confidence')} "
            f"frames_lost_adj={report.get('frames_lost_adj')} "
            f"frames_lost_rle={report.get('frames_lost_rle')} "
            f"events_adj={report.get('skip_events_adj')} "
            f"events_rle={report.get('skip_events_rle')} "
            f"hist_adj={report.get('skip_hist_adj')} "
            f"hist_rle={report.get('skip_hist_rle')} "
            f"step_hist_rle={report.get('step_hist_rle')} "
            f"lost_frac_adj={report.get('lost_frac_adj')} "
            f"lost_frac_rle={report.get('lost_frac_rle')} "
            f"ctr_span={report.get('ctr_span')}"
        )
        snotes = report.get("skip_notes") or []
        if snotes:
            print(f"skip_notes={' | '.join(str(n) for n in snotes)}")
        if report.get("skip_arithmetic"):
            print(f"skip_arithmetic={report.get('skip_arithmetic')}")
    # Startup transient (cast-in-window) discriminator — measurement only.
    if report.get("startup_status") is not None:
        print(
            f"startup_metrics status={report.get('startup_status')} "
            f"hypothesis={report.get('startup_hypothesis')} "
            f"window_s={report.get('startup_window_s')} "
            f"window_src={report.get('startup_window_s_src')} "
            f"lost_adj={report.get('startup_frames_lost_adj')} "
            f"lost_rle={report.get('startup_frames_lost_rle')} "
            f"ctr_span={report.get('startup_ctr_span')} "
            f"n_first={report.get('startup_n_first')} "
            f"n_last={report.get('startup_n_last')} "
            f"unique={report.get('startup_unique')} "
            f"conf={report.get('startup_confidence')} "
            f"hist_adj={report.get('startup_skip_hist_adj')} "
            f"hist_rle={report.get('startup_skip_hist_rle')} "
            f"daemon_drops={report.get('daemon_session_drops')} "
            f"daemon_src={report.get('daemon_session_drops_src')} "
            f"drops_match={report.get('startup_drops_match')}"
        )
        snotes = report.get("startup_notes") or []
        if snotes:
            print(f"startup_notes={' | '.join(str(n) for n in snotes)}")
        if report.get("startup_arithmetic"):
            print(f"startup_arithmetic={report.get('startup_arithmetic')}")
    print(f"reason={report['reason']}")
    print(f"VERDICT={report['verdict']} rc={report['rc']}")


def _self_test() -> int:
    """Lightweight pure checks (no capture dir required)."""
    import tempfile

    # Uniform frame → warmup
    uni = np.full((108, 192, 3), 7, dtype=np.uint8)
    b, roi, st = find_overlay(uni)
    assert st == "warmup" and b is None, st

    # Synthetic yellow "blob" top-left on black → overlay found
    dark = np.zeros((270, 480, 3), dtype=np.uint8)
    dark[20:50, 10:200] = (220, 220, 40)
    b, roi, st = find_overlay(dark)
    assert st == "ok" and b is not None and roi is not None, (st, roi)

    # Green-cast fingerprint (parent 480p full-green / old-daemon class)
    garbage = np.zeros((100, 100, 3), dtype=np.uint8)
    garbage[:, :] = (20, 90, 15)
    gc = green_cast_metrics(garbage)
    assert gc["green_cast"] is True, gc
    assert gc["color_fail"] is True, gc

    # Magenta cast (luma parked in chroma planes) — channel-spread, not green.
    magenta = np.zeros((100, 100, 3), dtype=np.uint8)
    magenta[:, :] = (210, 40, 240)
    gc_m = green_cast_metrics(magenta)
    assert gc_m["chroma_cast"] is True and gc_m["channel_spread"] >= CHROMA_SPREAD_FAIL, gc_m
    assert gc_m["color_fail"] is True, gc_m

    # Blue cast — channel-spread any direction.
    blue = np.zeros((100, 100, 3), dtype=np.uint8)
    blue[:, :] = (20, 30, 180)
    gc_b = green_cast_metrics(blue)
    assert gc_b["chroma_cast"] is True and gc_b["color_fail"] is True, gc_b

    # Mid greyscale field (dead chroma on lit picture).
    grey = np.full((120, 160, 3), 80, dtype=np.uint8)
    gc_g = green_cast_metrics(grey)
    assert gc_g["greyscale_flat"] is True and gc_g["color_fail"] is True, gc_g

    # Clean black / dark+yellow overlay is not a cast / not greyscale-fail.
    gc2 = green_cast_metrics(dark)
    assert gc2["green_cast"] is False and gc2["chroma_cast"] is False, gc2
    assert gc2["greyscale_flat"] is False, gc2

    # Neutral near-white flash is not a cast (spread small).
    flash = np.full((100, 100, 3), 220, dtype=np.uint8)
    flash[40:60, 30:70] = (10, 10, 10)  # black FLASH text
    flash[70:80, 20:80] = (200, 30, 30)  # red bar
    gc_f = green_cast_metrics(flash)
    assert gc_f["color_fail"] is False, gc_f
    assert gc_f["uv_swap"] is False, gc_f

    # UV-swap of flash+red-bar must hard-fail colour.
    y_pl, cb_pl, cr_pl = _rgb_to_ycbcr_planes(flash)
    r_s = y_pl + 1.402 * (cb_pl - 128.0)
    g_s = y_pl - 0.344136 * (cr_pl - 128.0) - 0.714136 * (cb_pl - 128.0)
    b_s = y_pl + 1.772 * (cr_pl - 128.0)
    flash_uv = np.clip(np.stack([r_s, g_s, b_s], axis=-1), 0, 255).astype(np.uint8)
    gc_uv = green_cast_metrics(flash_uv)
    assert gc_uv["uv_swap"] is True or gc_uv["chroma_cast"] is True, gc_uv
    assert gc_uv["color_fail"] is True, gc_uv

    # Parse tiers
    assert _parse_counter("TREK24 n=336") == (336, 10)
    assert _parse_counter("NTSC2397 n=166") == (166, 10)
    assert _parse_counter("n=42")[0] == 42
    assert _parse_counter("nope")[0] is None

    # Horizontal wrap synthetic: structure on both edges, empty mid.
    wrap = np.zeros((180, 320, 3), dtype=np.uint8)
    # left edge vertical bars (text-like)
    for x in range(0, 30, 3):
        wrap[:, x] = (220, 40, 40)
    for x in range(290, 320, 3):
        wrap[:, x] = (40, 40, 220)
    sm_w = structure_metrics(wrap)
    assert sm_w["horiz_wrap"] is True, sm_w

    # Letterbox-like dark with left-only overlay must NOT wrap-fail.
    letter = np.zeros((180, 320, 3), dtype=np.uint8)
    letter[40:70, 20:160] = (220, 220, 40)
    sm_l = structure_metrics(letter)
    assert sm_l["horiz_wrap"] is False, sm_l

    # Severity: green-cast with no overlay → COLOR_FAIL rc=2, NOT UNSCORED 77.
    with tempfile.TemporaryDirectory(prefix="hdmi_motion_st_") as td:
        tdp = Path(td)
        for i in range(8):
            arr = np.zeros((120, 160, 3), dtype=np.uint8)
            arr[:, :] = (20, 90, 15)  # full green field, no yellow overlay
            Image.fromarray(arr).save(tdp / f"f_{i:03d}.png")
        frames = sorted(str(p) for p in tdp.glob("f_*.png"))
        rep = score_burst(frames, warmup_skip=0, min_reads=3)
        assert "GREEN" in rep["color"], rep
        assert rep["green_cast_frames"] >= GREEN_CAST_MIN_FRAMES, rep
        assert rep["motion"] == "UNSCORED", rep
        # Pure green field may also trip structure on some paths; colour or
        # structure hard-fail both beat UNSCORED — never rc=77.
        assert rep["rc"] in (RC_COLOR_FAIL, RC_STRUCTURE_FAIL), rep
        assert rep["verdict"] in ("COLOR_FAIL", "STRUCTURE_FAIL"), rep

        # FREEZE + green-cast → hard colour/structure fail wins over freeze/unscored.
        gdir = tdp / "freeze_green"
        gdir.mkdir()
        base = np.zeros((120, 160, 3), dtype=np.uint8)
        base[:, :] = (25, 88, 18)
        for i in range(8):
            Image.fromarray(base).save(gdir / f"f_{i:03d}.png")
        rep2 = score_burst(
            sorted(str(p) for p in gdir.glob("f_*.png")),
            warmup_skip=0,
            min_reads=3,
        )
        assert rep2["rc"] in (RC_COLOR_FAIL, RC_STRUCTURE_FAIL), rep2
        assert rep2["verdict"] in ("COLOR_FAIL", "STRUCTURE_FAIL"), rep2

        # Magenta field → COLOR_FAIL via channel spread (not green-specific).
        mdir = tdp / "magenta"
        mdir.mkdir()
        mag = np.zeros((120, 160, 3), dtype=np.uint8)
        mag[:, :] = (210, 40, 240)
        for i in range(8):
            Image.fromarray(mag).save(mdir / f"f_{i:03d}.png")
        rep3 = score_burst(
            sorted(str(p) for p in mdir.glob("f_*.png")),
            warmup_skip=0,
            min_reads=3,
        )
        assert rep3["chroma_cast_frames"] >= GREEN_CAST_MIN_FRAMES, rep3
        assert rep3["rc"] in (RC_COLOR_FAIL, RC_STRUCTURE_FAIL), rep3
        assert rep3["rc"] != RC_UNSCORED, rep3

        # Greyscale lit field → COLOR_FAIL (dead chroma).
        gydir = tdp / "grey"
        gydir.mkdir()
        gy = np.full((120, 160, 3), 90, dtype=np.uint8)
        for i in range(8):
            Image.fromarray(gy).save(gydir / f"f_{i:03d}.png")
        rep_gy = score_burst(
            sorted(str(p) for p in gydir.glob("f_*.png")),
            warmup_skip=0,
            min_reads=3,
        )
        assert rep_gy["greyscale_frames"] >= GREEN_CAST_MIN_FRAMES, rep_gy
        assert rep_gy["rc"] == RC_COLOR_FAIL, rep_gy
        assert "GREYSCALE" in rep_gy["color"], rep_gy

        # UV-swapped flash burst → COLOR_FAIL.
        uvdir = tdp / "uvswap"
        uvdir.mkdir()
        for i in range(8):
            Image.fromarray(flash_uv).save(uvdir / f"f_{i:03d}.png")
        rep_uv = score_burst(
            sorted(str(p) for p in uvdir.glob("f_*.png")),
            warmup_skip=0,
            min_reads=3,
        )
        assert rep_uv["color_fail_frames"] >= GREEN_CAST_MIN_FRAMES, rep_uv
        assert rep_uv["rc"] == RC_COLOR_FAIL, rep_uv
        assert rep_uv["rc"] != RC_UNSCORED, rep_uv

        # Synthetic wrap burst → STRUCTURE_FAIL rc=3 independent of motion.
        wdir = tdp / "wrap"
        wdir.mkdir()
        for i in range(8):
            Image.fromarray(wrap).save(wdir / f"f_{i:03d}.png")
        rep4 = score_burst(
            sorted(str(p) for p in wdir.glob("f_*.png")),
            warmup_skip=0,
            min_reads=3,
        )
        assert rep4["horiz_wrap_frames"] >= STRUCT_MIN_FRAMES, rep4
        assert rep4["verdict"] == "STRUCTURE_FAIL", rep4
        assert rep4["rc"] == RC_STRUCTURE_FAIL, rep4

    # --- Rate / revisit unit checks (no PNG OCR required) ---
    # Healthy 24-on-30: hold every 5th capture → unique_ratio ≈ 0.8, max plateau 2.
    good_ns = []
    src_n = 200
    for cap_i in range(60):
        if cap_i > 0 and (cap_i % 5) != 0:
            src_n += 1
        good_ns.append(src_n)
    ri = analyze_counter_rate(
        list(enumerate(good_ns)),
        source_fps=24.0,
        capture_fps=30.0,
        source_fps_src=PROVENANCE_CALLER,
        capture_fps_src=PROVENANCE_CALLER,
    )
    assert ri["rate"] == "RATE_OK", ri
    assert ri["rate_fail"] is False, ri
    assert ri["max_plateau"] <= ri["max_plateau_allowed"], ri
    assert ri["non_adjacent_revisits"] == 0, ri
    assert ri["unique_ratio"] is not None and 0.70 <= ri["unique_ratio"] <= 0.90, ri
    assert ri["source_fps_src"] == PROVENANCE_CALLER, ri
    assert abs(float(ri["expected_ratio"]) - 0.8) < 1e-6, ri

    # DEFAULT_ASSUMED on healthy pattern → RATE_UNSCORED (never RATE_OK on a guess).
    ri_assumed = analyze_counter_rate(
        list(enumerate(good_ns)),
        source_fps=DEFAULT_ASSUMED_SOURCE_FPS,
        capture_fps=DEFAULT_ASSUMED_CAPTURE_FPS,
        source_fps_src=PROVENANCE_DEFAULT_ASSUMED,
        capture_fps_src=PROVENANCE_DEFAULT_ASSUMED,
    )
    assert ri_assumed["rate"] == "RATE_UNSCORED", ri_assumed
    assert ri_assumed["rate_fail"] is False, ri_assumed
    assert ri_assumed["fps_authoritative"] is False, ri_assumed

    # Bound-riding plateau (== allowed) is PASS + plateau_warn, not RATE_FAIL.
    # ceil(30/24)+1 = 3; force a single run of length 3 in an otherwise healthy seq.
    bound_ns = list(good_ns)
    # Overwrite a stretch to three identical counters without breaking overall rate badly.
    bound_ns[10] = bound_ns[9]
    bound_ns[11] = bound_ns[9]
    ri_bound = analyze_counter_rate(
        list(enumerate(bound_ns)),
        source_fps=24.0,
        capture_fps=30.0,
        source_fps_src=PROVENANCE_CALLER,
        capture_fps_src=PROVENANCE_CALLER,
    )
    if ri_bound["max_plateau"] == ri_bound["max_plateau_allowed"]:
        assert ri_bound["plateau_warn"] is True, ri_bound
        # warn must be set; fail only if > allowed (not ==).
        assert not any(
            "max_plateau=" in r and ">" in r for r in ri_bound["rate_reasons"]
        ), ri_bound
    assert ri_assumed["source_fps_src"] == PROVENANCE_DEFAULT_ASSUMED, ri_assumed

    # parse_fps_token accepts daemon fps=24/1 form.
    assert abs(parse_fps_token("24/1") - 24.0) < 1e-9
    assert abs(parse_fps_token("24000/1001") - (24000.0 / 1001.0)) < 1e-9
    assert parse_fps_token(None) is None

    full_rate_ns = [100 + i for i in range(60)]
    # Under DEFAULT_ASSUMED, a full-rate sequence is RATE_UNSCORED (not FAIL, not OK).
    # Ratio/endpoint gates do not fire on a guess; caller must supply fps.
    ri_bad_assume = analyze_counter_rate(
        list(enumerate(full_rate_ns)),
        source_fps=DEFAULT_ASSUMED_SOURCE_FPS,
        capture_fps=DEFAULT_ASSUMED_CAPTURE_FPS,
        source_fps_src=PROVENANCE_DEFAULT_ASSUMED,
        capture_fps_src=PROVENANCE_DEFAULT_ASSUMED,
    )
    assert ri_bad_assume["rate"] == "RATE_UNSCORED", ri_bad_assume
    assert ri_bad_assume["rate_fail"] is False, ri_bad_assume
    assert ri_bad_assume["fps_authoritative"] is False, ri_bad_assume

    # Same full-rate sequence with caller-supplied 30fps source is RATE_OK.
    ri_30 = analyze_counter_rate(
        list(enumerate(full_rate_ns)),
        source_fps=30.0,
        capture_fps=30.0,
        source_fps_src=PROVENANCE_CALLER,
        capture_fps_src=PROVENANCE_CALLER,
    )
    assert ri_30["rate"] == "RATE_OK", ri_30
    assert abs(float(ri_30["expected_ratio"]) - 1.0) < 1e-6, ri_30

    # Slow crawl: long plateaus (pfps collapse class) — unique_ratio low.
    slow_ns = []
    src_n = 100
    for cap_i in range(60):
        if cap_i > 0 and cap_i % 4 == 0:  # advance only every 4 capture frames → ~0.25
            src_n += 1
        slow_ns.append(src_n)
    ri_slow = analyze_counter_rate(
        list(enumerate(slow_ns)),
        source_fps=24.0,
        capture_fps=30.0,
        source_fps_src=PROVENANCE_CALLER,
        capture_fps_src=PROVENANCE_CALLER,
    )
    assert ri_slow["rate_fail"] is True, ri_slow
    assert ri_slow["max_plateau"] > ri_slow["max_plateau_allowed"] or (
        ri_slow["unique_ratio"] is not None and ri_slow["unique_ratio"] < 0.5
    ), ri_slow

    # 4x race: counter jumps by ~4 per capture frame.
    fast_ns = [100 + i * 4 for i in range(60)]
    ri_fast = analyze_counter_rate(
        list(enumerate(fast_ns)),
        source_fps=24.0,
        capture_fps=30.0,
        source_fps_src=PROVENANCE_CALLER,
        capture_fps_src=PROVENANCE_CALLER,
    )
    assert ri_fast["rate_fail"] is True, ri_fast
    assert ri_fast["endpoint_rate"] is not None and ri_fast["endpoint_rate"] > 1.5, ri_fast
    # Endpoint rate on linear ramp equals full span / cap_span (not ~2/3).
    good_end = analyze_counter_rate(
        list(enumerate(good_ns)),
        source_fps=24.0,
        capture_fps=30.0,
        source_fps_src=PROVENANCE_CALLER,
        capture_fps_src=PROVENANCE_CALLER,
    )
    assert good_end["endpoint_rate"] is not None
    assert good_end["endpoint_rate"] > 0.65, good_end  # must not be ~0.53 third-median bias
    assert abs(good_end["endpoint_rate"] - good_end["span_rate"]) < 1e-9, good_end

    # Bank-swap ping-pong: non-adjacent revisits.
    ping = []
    for i in range(30):
        ping.append(100 + (i % 2))  # 100,101,100,101,...
    # Real revisits must survive structural filter and still RATE_FAIL.
    ping_pairs = list(enumerate(ping * 2))
    ping_kept, ping_rej = _filter_counter_pairs(ping_pairs)
    assert len(ping_kept) >= RATE_MIN_SAMPLES, (len(ping_kept), ping_rej)
    ri_ping = analyze_counter_rate(
        ping_kept,
        source_fps=24.0,
        capture_fps=30.0,
        source_fps_src=PROVENANCE_CALLER,
        capture_fps_src=PROVENANCE_CALLER,
    )
    assert ri_ping["rate_fail"] is True, ri_ping
    assert ri_ping["revisit_fail"] is True, ri_ping
    assert ri_ping["non_adjacent_revisits"] >= 2, ri_ping

    # Parent false-RED classes: 5-digit insertion + 2→7 spike must be rejected
    # structurally (not by widening MAD), and must not mint revisits.
    ocr_bug = []
    n = 1340
    for i in range(40):
        ocr_bug.append(n)
        n += 1
        if i == 10:
            ocr_bug.append(13527)  # was 1352
        if i == 25:
            ocr_bug.append(2917)  # was 2912 mid-stream (use nearby)
    # Build explicit sequence around the lab sites
    lab_seq = (
        [(i, 1340 + i) for i in range(11)]
        + [(11, 13527)]  # misread of 1351+1
        + [(12, 1353)]
        + [(13 + k, 1354 + k) for k in range(20)]
        + [(40, 2911), (41, 2917), (42, 2913)]  # 2→7 then continue
        + [(43 + k, 2914 + k) for k in range(30)]
    )
    kept_lab, rej_lab = _filter_counter_pairs(lab_seq)
    rules = {r["rule"] for r in rej_lab}
    assert any(r["n"] == 13527 for r in rej_lab), rej_lab
    assert any(
        r["n"] == 2917 and r["cap_idx"] == 41 for r in rej_lab
    ), rej_lab  # the spike at cap 41, not later real n=2917
    assert 13527 not in {n for _, n in kept_lab}, kept_lab
    assert (41, 2917) not in kept_lab, kept_lab
    ri_lab = analyze_counter_rate(
        kept_lab,
        source_fps=24.0,
        capture_fps=30.0,
        source_fps_src=PROVENANCE_CALLER,
        capture_fps_src=PROVENANCE_CALLER,
    )
    assert ri_lab["non_adjacent_revisits"] == 0, ri_lab
    assert ri_lab.get("revisit_fail") is False, ri_lab

    # Too few samples → RATE_UNSCORED (not a fail).
    ri_few = analyze_counter_rate(
        [(0, 1), (1, 2), (2, 3)],
        source_fps=24.0,
        capture_fps=30.0,
        source_fps_src=PROVENANCE_CALLER,
        capture_fps_src=PROVENANCE_CALLER,
    )
    assert ri_few["rate"] == "RATE_UNSCORED" and ri_few["rate_fail"] is False, ri_few

    # Source caller + capture assumed → still RATE_UNSCORED (both required).
    ri_half_auth = analyze_counter_rate(
        list(enumerate(good_ns)),
        source_fps=24.0,
        capture_fps=30.0,
        source_fps_src=PROVENANCE_CALLER,
        capture_fps_src=PROVENANCE_DEFAULT_ASSUMED,
    )
    assert ri_half_auth["rate"] == "RATE_UNSCORED", ri_half_auth
    assert ri_half_auth["fps_authoritative"] is False, ri_half_auth

    # Default assumed source is 24.000, never 23.976 (ERROR 17).
    assert DEFAULT_ASSUMED_SOURCE_FPS == 24.0, DEFAULT_ASSUMED_SOURCE_FPS
    assert abs(DEFAULT_ASSUMED_SOURCE_FPS - (24000.0 / 1001.0)) > 0.01

    # --- Display-level skip measurement (RED/GREEN unit) ---
    # GREEN: healthy 24-on-30 plateau pattern over long span — adjacent lost ~0.
    long_ns = []
    src_n = 1000
    for cap_i in range(900):  # ~720 source frames at 24/30
        if cap_i > 0 and (cap_i % 5) != 0:
            src_n += 1
        long_ns.append(src_n)
    sk_ok = analyze_counter_skips(
        list(enumerate(long_ns)),
        source_fps=24.0,
        capture_fps=30.0,
        source_fps_src=PROVENANCE_CALLER,
        capture_fps_src=PROVENANCE_CALLER,
    )
    assert sk_ok["frames_lost_adj"] == 0, sk_ok
    assert sk_ok["skip_status"] == "SKIP_OK", sk_ok
    assert sk_ok["skip_confidence"] in ("MEDIUM", "HIGH"), sk_ok
    assert sk_ok["ctr_span"] >= SKIP_MIN_CTR_SPAN, sk_ok

    # RED: every 5th advance is +2 (drop one source frame regularly).
    drop_ns = []
    src_n = 2000
    for cap_i in range(900):
        if cap_i > 0 and (cap_i % 5) != 0:
            src_n += 1
            if (src_n % 10) == 0:
                src_n += 1  # skip one source number
        drop_ns.append(src_n)
    sk_bad = analyze_counter_skips(
        list(enumerate(drop_ns)),
        source_fps=24.0,
        capture_fps=30.0,
        source_fps_src=PROVENANCE_CALLER,
        capture_fps_src=PROVENANCE_CALLER,
    )
    assert sk_bad["frames_lost_rle"] is not None and sk_bad["frames_lost_rle"] >= 20, sk_bad
    assert sk_bad["frames_lost_adj"] is not None and sk_bad["frames_lost_adj"] >= 10, sk_bad
    assert sk_bad["skip_status"] in ("SKIP_SUSPECT", "SKIP_LOSS"), sk_bad
    assert sk_bad["skip_confidence"] in ("MEDIUM", "HIGH"), sk_bad

    # Short window → SKIP_UNSCORED (not a fake zero).
    sk_short = analyze_counter_skips(
        list(enumerate(good_ns[:20])),
        source_fps=24.0,
        capture_fps=30.0,
        source_fps_src=PROVENANCE_CALLER,
        capture_fps_src=PROVENANCE_CALLER,
    )
    assert sk_short["skip_status"] == "SKIP_UNSCORED", sk_short
    assert sk_short["skip_confidence"] == "UNSCORED", sk_short

    # --- Startup transient discriminator (RED/GREEN unit) ---
    # GREEN contiguous: healthy 24-on-30 over first 60s, daemon_drops=0.
    st_ok = analyze_startup_transient(
        list(enumerate(long_ns)),
        source_fps=24.0,
        capture_fps=30.0,
        source_fps_src=PROVENANCE_CALLER,
        capture_fps_src=PROVENANCE_CALLER,
        window_s=60.0,
        daemon_session_drops=0,
        daemon_drops_src=PROVENANCE_CALLER,
    )
    assert st_ok["startup_status"] == "STARTUP_CONTIGUOUS", st_ok
    assert st_ok["startup_frames_lost_adj"] == 0, st_ok
    assert st_ok["hypothesis"] == "NO_DISPLAY_LOSS_IN_WINDOW", st_ok

    # RED display loss: inject 17 single-frame jumps early (startup Drop shape).
    # maxDropRun=1 → drop, present, drop, present... ≈ +2 steps interleaved.
    su_ns = []
    sn = 10
    drops_injected = 0
    for cap_i in range(900):
        if cap_i > 0 and (cap_i % 5) != 0:
            sn += 1
            # First ~40 source advances: every other advance skips one n (17 times).
            if drops_injected < 17 and sn < 80 and (sn % 2) == 0:
                sn += 1
                drops_injected += 1
        su_ns.append(sn)
    st_bad = analyze_startup_transient(
        list(enumerate(su_ns)),
        source_fps=24.0,
        capture_fps=30.0,
        source_fps_src=PROVENANCE_CALLER,
        capture_fps_src=PROVENANCE_CALLER,
        window_s=60.0,
        daemon_session_drops=17,
        daemon_drops_src=PROVENANCE_CALLER,
    )
    assert st_bad["startup_status"] == "STARTUP_DISPLAY_LOSS", st_bad
    assert st_bad["startup_frames_lost_adj"] is not None
    assert st_bad["startup_frames_lost_adj"] >= 10, st_bad
    assert st_bad["hypothesis"] == "REAL_DISPLAY_LOSS", st_bad
    assert st_bad["drops_match"] is True, st_bad

    # Contiguous pixels + daemon_drops>0 → special tag (window/coverage check).
    st_vs = analyze_startup_transient(
        list(enumerate(long_ns)),
        source_fps=24.0,
        capture_fps=30.0,
        source_fps_src=PROVENANCE_CALLER,
        capture_fps_src=PROVENANCE_CALLER,
        window_s=60.0,
        daemon_session_drops=17,
        daemon_drops_src=PROVENANCE_CALLER,
    )
    assert st_vs["startup_status"] == "STARTUP_CONTIGUOUS_vs_DROPS", st_vs
    assert st_vs["startup_frames_lost_adj"] == 0, st_vs

    # measure_capture_fps via explicit wall_s
    m = measure_capture_fps_from_paths(
        [f"f_{i:03d}.png" for i in range(60)],
        wall_s=2.0,  # 59/2 = 29.5
    )
    assert m["capture_fps"] is not None and abs(m["capture_fps"] - 29.5) < 0.01, m
    assert m["capture_fps_src"] == PROVENANCE_MEASURED, m

    print("SELF_TEST_OK")
    return 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument(
        "inputs",
        nargs="*",
        help="capture directory and/or PNG frames",
    )
    ap.add_argument(
        "--warmup-skip",
        type=int,
        default=DEFAULT_WARMUP_SKIP,
        help=f"discard first N capture indices if not decoded (default {DEFAULT_WARMUP_SKIP})",
    )
    ap.add_argument(
        "--min-reads",
        type=int,
        default=DEFAULT_MIN_READS,
        help=f"minimum confident counter reads for a hard verdict (default {DEFAULT_MIN_READS})",
    )
    ap.add_argument(
        "--source-fps",
        "--src-fps",
        dest="source_fps",
        type=str,
        default=None,
        help=(
            "source content frame rate (REQUIRED for RATE_OK). Accepts float or "
            "daemon token '24/1'. Library 24p clips are 24.000 — NOT 23.976. "
            "If omitted, DEFAULT_ASSUMED="
            f"{DEFAULT_ASSUMED_SOURCE_FPS} and rate dimension is RATE_UNSCORED "
            "(never RATE_OK on a guess — ERROR 17 class)."
        ),
    )
    ap.add_argument(
        "--capture-fps",
        "--cap-fps",
        dest="capture_fps",
        type=str,
        default=None,
        help=(
            "HDMI grabber capture rate for the burst (float or '30/1'). "
            "If omitted, try --capture-wall-s measurement, then PNG mtimes, "
            f"then DEFAULT_ASSUMED={DEFAULT_ASSUMED_CAPTURE_FPS}."
        ),
    )
    ap.add_argument(
        "--capture-wall-s",
        type=float,
        default=None,
        help=(
            "wall-clock seconds of the capture command (ffmpeg start→end). "
            "Measures cap_fps=(n_frames-1)/wall_s labelled cap=measured. "
            "Preferred over mtime when the writer batches flushes."
        ),
    )
    ap.add_argument(
        "--probe-capture",
        default=None,
        help=(
            "optional video container path; if --capture-fps omitted, try "
            "ffprobe r_frame_rate and label cap=container on success"
        ),
    )
    ap.add_argument(
        "--startup-window-s",
        type=float,
        default=STARTUP_DEFAULT_WINDOW_S,
        help=(
            "seconds of capture (from first strong counter sample) used for the "
            f"startup catch-up vs display-loss discriminator (default {STARTUP_DEFAULT_WINDOW_S}). "
            "Cast MUST land inside this window — start grabber BEFORE cast."
        ),
    )
    ap.add_argument(
        "--daemon-session-drops",
        type=int,
        default=None,
        help=(
            "session drops=N from daemon telemetry for this play (caller-supplied). "
            "Compared to startup frames_lost_adj; tagged drops_match. "
            "Do NOT pass lifetime_drops. Inadmissible as sole evidence — pixels decide."
        ),
    )
    ap.add_argument(
        "--counters-csv",
        default=None,
        help=(
            "pre-decoded counter cache (CSV with idx,n). Skips PNG OCR; applies "
            "structural OCR filter + rate/skip/startup. Used to prove filter on "
            "parent caches (e.g. /tmp/ctr480.csv) without re-tesseract."
        ),
    )
    ap.add_argument("--json", action="store_true", help="machine-readable report")
    ap.add_argument(
        "--progress",
        action="store_true",
        help="print scoring progress to stderr",
    )
    ap.add_argument(
        "--self-test",
        action="store_true",
        help="run built-in unit checks and exit",
    )
    ap.add_argument(
        "--one",
        action="store_true",
        help="print per-frame reads only (no burst verdict); rc=0 if any ok decode",
    )
    args = ap.parse_args(argv)

    if args.self_test:
        return _self_test()

    # --- shared fps provenance resolution (used by CSV and PNG paths) ---
    def _resolve_fps(
        frames_for_measure: list[str] | None = None,
    ) -> tuple[float, str, float, str, dict[str, Any] | None]:
        try:
            src_parsed = parse_fps_token(args.source_fps)
        except ValueError as e:
            print(f"ERROR: --source-fps: {e}", file=sys.stderr)
            raise SystemExit(RC_UNSCORED) from e
        if src_parsed is None:
            source_fps = DEFAULT_ASSUMED_SOURCE_FPS
            source_fps_src = PROVENANCE_DEFAULT_ASSUMED
        else:
            source_fps = src_parsed
            source_fps_src = PROVENANCE_CALLER
        try:
            cap_parsed = parse_fps_token(args.capture_fps)
        except ValueError as e:
            print(f"ERROR: --capture-fps: {e}", file=sys.stderr)
            raise SystemExit(RC_UNSCORED) from e
        cap_measure_meta: dict[str, Any] | None = None
        if cap_parsed is not None:
            capture_fps = cap_parsed
            capture_fps_src = PROVENANCE_CALLER
        else:
            capture_fps = DEFAULT_ASSUMED_CAPTURE_FPS
            capture_fps_src = PROVENANCE_DEFAULT_ASSUMED
            if frames_for_measure:
                measured = measure_capture_fps_from_paths(
                    frames_for_measure, wall_s=args.capture_wall_s
                )
                cap_measure_meta = measured
                if measured.get("capture_fps") is not None:
                    capture_fps = float(measured["capture_fps"])
                    capture_fps_src = str(measured["capture_fps_src"])
                elif args.probe_capture:
                    probed, how = try_probe_capture_fps(args.probe_capture)
                    if probed is not None:
                        capture_fps = probed
                        capture_fps_src = PROVENANCE_CONTAINER
            elif args.capture_wall_s is not None and args.capture_wall_s > 0:
                # CSV path: parent can pass wall + n via --capture-fps preferred;
                # wall alone is not enough without n_frames.
                pass
        return source_fps, source_fps_src, capture_fps, capture_fps_src, cap_measure_meta

    if args.counters_csv:
        try:
            pairs_raw = load_counters_csv(args.counters_csv)
        except (OSError, ValueError) as e:
            print(f"ERROR: --counters-csv: {e}", file=sys.stderr)
            return RC_UNSCORED
        source_fps, source_fps_src, capture_fps, capture_fps_src, _meta = _resolve_fps(
            None
        )
        # Parent measured cap_fps=29.9068 on this burst — prefer explicit --cap-fps.
        daemon_drops = args.daemon_session_drops
        daemon_drops_src = (
            PROVENANCE_CALLER if daemon_drops is not None else PROVENANCE_DEFAULT_ASSUMED
        )
        report = score_counter_pairs(
            pairs_raw,
            source_fps=source_fps,
            capture_fps=capture_fps,
            source_fps_src=source_fps_src,
            capture_fps_src=capture_fps_src,
            startup_window_s=float(args.startup_window_s),
            daemon_session_drops=daemon_drops,
            daemon_drops_src=daemon_drops_src,
        )
        report["src"] = str(args.counters_csv)
        if args.json:
            print(json.dumps(report, indent=2))
        else:
            _print_human(report, str(args.counters_csv))
        return int(report["rc"])

    if not args.inputs:
        ap.error("provide a capture directory or PNG frames (or --self-test/--counters-csv)")

    # Resolve frames from dirs and/or files.
    frames: list[str] = []
    src_label = args.inputs[0]
    for inp in args.inputs:
        p = Path(inp)
        if p.is_dir():
            frames.extend(list_capture_frames(p))
            src_label = str(p)
        elif p.is_file():
            frames.append(str(p))
        else:
            print(f"ERROR: not found: {inp}", file=sys.stderr)
            return RC_UNSCORED

    if not frames:
        print("ERROR: no PNG frames found", file=sys.stderr)
        return RC_UNSCORED

    if args.one or (len(frames) == 1 and Path(args.inputs[0]).is_file()):
        # Single-frame / per-frame dump mode.
        any_ok = False
        rows = []
        for f in frames:
            r = read_frame(f, force_ocr=True)
            rows.append(r)
            if r["status"] == "ok":
                any_ok = True
            if not args.json:
                print(
                    f"{os.path.basename(r['path'])}: status={r['status']} "
                    f"n={r['n']} tier={r.get('tier')} raw={r.get('raw')!r} "
                    f"mean={r.get('mean_luma')} green_cast={r.get('green_cast')} "
                    f"chroma_cast={r.get('chroma_cast')} "
                    f"spread={r.get('channel_spread')} "
                    f"vdup={r.get('vertical_dup')} wrap={r.get('horiz_wrap')} "
                    f"overlay={r.get('overlay_present', r.get('fp') is not None)}"
                )
        if args.json:
            print(json.dumps(rows, indent=2))
        # Single-frame: ok decode → 0; undecoded → 77; never claim FREEZE from 1 frame.
        return RC_MOTION_OK if any_ok else RC_UNSCORED

    # Provenance: anything not supplied on the CLI is DEFAULT_ASSUMED (ERROR 17).
    # RATE_OK requires BOTH caller-supplied (or container-probed capture).
    try:
        src_parsed = parse_fps_token(args.source_fps)
    except ValueError as e:
        print(f"ERROR: --source-fps: {e}", file=sys.stderr)
        return RC_UNSCORED
    if src_parsed is None:
        source_fps = DEFAULT_ASSUMED_SOURCE_FPS
        source_fps_src = PROVENANCE_DEFAULT_ASSUMED
    else:
        source_fps = src_parsed
        source_fps_src = PROVENANCE_CALLER

    try:
        cap_parsed = parse_fps_token(args.capture_fps)
    except ValueError as e:
        print(f"ERROR: --capture-fps: {e}", file=sys.stderr)
        return RC_UNSCORED
    cap_measure_meta: dict[str, Any] | None = None
    if cap_parsed is not None:
        capture_fps = cap_parsed
        capture_fps_src = PROVENANCE_CALLER
    else:
        capture_fps = DEFAULT_ASSUMED_CAPTURE_FPS
        capture_fps_src = PROVENANCE_DEFAULT_ASSUMED
        # 1) explicit wall clock from parent capture harness
        # 2) PNG mtime span
        # 3) ffprobe container
        # 4) DEFAULT_ASSUMED
        measured = measure_capture_fps_from_paths(
            frames, wall_s=args.capture_wall_s
        )
        cap_measure_meta = measured
        if measured.get("capture_fps") is not None:
            capture_fps = float(measured["capture_fps"])
            capture_fps_src = str(measured["capture_fps_src"])
        elif args.probe_capture:
            probed, how = try_probe_capture_fps(args.probe_capture)
            if probed is not None:
                capture_fps = probed
                capture_fps_src = PROVENANCE_CONTAINER
            else:
                print(
                    f"WARN: --probe-capture failed ({how}); "
                    f"cap_fps stays DEFAULT_ASSUMED={capture_fps}",
                    file=sys.stderr,
                )
        elif measured.get("reason"):
            print(
                f"WARN: cap_fps measure failed ({measured.get('reason')}); "
                f"cap_fps stays DEFAULT_ASSUMED={capture_fps}",
                file=sys.stderr,
            )

    daemon_drops = args.daemon_session_drops
    daemon_drops_src = (
        PROVENANCE_CALLER if daemon_drops is not None else PROVENANCE_DEFAULT_ASSUMED
    )
    startup_window_s = float(args.startup_window_s)
    report = score_burst(
        frames,
        warmup_skip=args.warmup_skip,
        min_reads=args.min_reads,
        source_fps=source_fps,
        capture_fps=capture_fps,
        source_fps_src=source_fps_src,
        capture_fps_src=capture_fps_src,
        startup_window_s=startup_window_s,
        daemon_session_drops=daemon_drops,
        daemon_drops_src=daemon_drops_src,
        progress=args.progress,
    )
    report["src"] = src_label
    if cap_measure_meta is not None:
        report["cap_fps_measure"] = cap_measure_meta
    if args.json:
        # Drop bulky per-frame list unless explicitly wanted — keep it, parent wants evidence.
        print(json.dumps(report, indent=2))
    else:
        if cap_measure_meta is not None:
            print(
                f"cap_fps_measure method={cap_measure_meta.get('method')} "
                f"wall_s={cap_measure_meta.get('wall_s')} "
                f"n_frames={cap_measure_meta.get('n_frames')} "
                f"fps={cap_measure_meta.get('capture_fps')} "
                f"src={cap_measure_meta.get('capture_fps_src')} "
                f"reason={cap_measure_meta.get('reason')}"
            )
        _print_human(report, src_label)
    return int(report["rc"])


if __name__ == "__main__":
    sys.exit(main())
