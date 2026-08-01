#!/usr/bin/env python3
"""DEPRECATED for display-loss / skip: use glass_hold_skip.py +
publish_cadence_score.py. This file retains motion/OCR helpers only.

HDMI MOTION / CORRECTNESS instrument for MiSTerPlex lab captures.

*** DEPRECATION (display-side frame loss / G-fixture n= counter) ***
--------------------------------------------------------------------
For OCR-fixture / G n=NNNNNN c=D / completeness skip scoring, the **reference**
instrument is ``tools/glass_template_skip.py`` (parent-verified on /tmp/p60:
accepted=3179/3591, genuine=1 v=5578 only).

This file retains TREK24-style OCR + COLOR/STRUCTURE gates for legacy captures.
It must NOT be used as the display-loss ledger: known digit-insertion defect and
historical DEFAULT_ASSUMED src_fps printed beside measurements (ERROR 17).
Two disagreeing instruments caused false RATE_FAIL.

Prefer::

  python3 tools/glass_template_skip.py CAP_DIR --templates T.pkl --pts pts.csv \
    --source-fps 24 --capture-fps 60 --refresh-hz 60


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
  2. COLOR_FAIL  — any of: green-cast fingerprint, channel-mean spread cast
                   (magenta/blue/green), greyscale/chroma-constant lit field,
                   or U/V-swap among saturated pixels (B7). Hard fail rc=2,
                   never soft-skip. Colour is independent evidence; motion
                   need not be scorable. A cast field often *prevents* overlay
                   OCR, so "decodes=0" and "colour broken" are correlated —
                   colour must be allowed to decide alone.
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

Blind-counter rule (general — parent rchar incident)
----------------------------------------------------
  If the scored counter is exactly 0 / unchanging across windows while the
  process is provably alive and doing other work, return NO-DATA / rc=77 —
  never a defect class. See tools/instrument_blind_counter.py. Same disease
  as hallucinated OCR digits and DEFAULT_ASSUMED fps: a confident FAIL from
  a structurally blind meter.

  When multiple hard fails apply, the highest severity wins; subordinate
  dimensions stay in the report (e.g. motion=UNSCORED color=CHROMA_CAST_FAIL
  structure=VERT_DUP+HORIZ_WRAP → VERDICT=STRUCTURE_FAIL rc=3).

Rate / revisit model (parent calibration)
-----------------------------------------
  Capture FPS (MacroSilicon MJPEG burst) and source FPS are independent.
  **Neither rate is measured by this instrument.** Pass both explicitly when
  known (daemon telemetry `fps=24/1` → `--source-fps 24` / `--src-fps 24/1`).
  Provenance is always printed with tags measured | caller_supplied | DEFAULT_ASSUMED:
    src_fps=24.000 src=caller_supplied   # --source-fps
    src_fps=24.000 src=DEFAULT_ASSUMED   # fell back to library default
    cap_fps=29.9068 cap=measured         # wall_s or mtime
  Library assets (Plex metadata frameRate="24.000" / videoFrameRate="24p")
  are genuinely 24.000 — NOT NTSC 24000/1001. PARENT ERROR 17: a printed
  23.976 default was mistaken for a measurement and published as a defect.
  Default assumed source = 24.000; default assumed capture = 30.0.
  **When either fps is DEFAULT_ASSUMED the rate dimension is RATE_UNSCORED,
  never RATE_OK.** Ratio/endpoint/plateau gates only fire when BOTH fps are
  authoritative (caller_supplied / measured / container). Revisit (bank-swap)
  still hard-fails without fps — pure measured sequence property.
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

Bright-frame / low-contrast counter (ERROR 17 class for n):
  Yellow overlay on white FLASH collapses local edge luma contrast (parent-
  viewed /tmp/cap480b/f_049.png is TREK24 n=312; OCR previously hallucinated
  field_inv n=322). Instrument measures hard-yellow vs local ring dY BEFORE
  any OCR; dY < LOW_CONTRAST_DY_MAX → status=unreadable_low_contrast,
  n_src=UNREADABLE, n=None (never a digit string). Only n_src=measured enters
  rate/revisit/plateau. unreadable_frac > UNREADABLE_FRAC_MOTION_CAP demotes
  MOTION_OK → UNSCORED (never a pass). Excursion filter remains belt-and-braces.

Display loss vs grabber drop (Gap 1)
------------------------------------
PNG-only sequences have NO per-frame timestamps. This instrument therefore
ASSUMES uniform capture spacing when scoring adjacent cap_idx pairs — grabber
drops masquerade as source +2. Primary detector is presence holes in the RLE
counter span (absent n ⇒ displayed < one capture period or never, because
cap interval 33.4ms < source hold 41.7ms). Adjacent max_exp is SECONDARY only
(undercounts hold-then-jump).

With --pts-csv (ffprobe pkt_pts_time / idx,pts_s):
  dt_ratio < 1.45 → device_skip_frames
  dt_ratio >= 1.45 → grabber_drop_frames
  Never merged. loss_split_status=LOSS_SPLIT_OK.
Without PTS: loss_split_status=LOSS_UNSCORED, steady_state_loss=UNSCORED,
resolution_floor_frac is first-class (blind_frac, grabber_rate_deficit,
unsplit_presence). Do NOT report a hedged device-loss percent below the floor.

Usage
-----
  tools/hdmi_motion_instrument.py CAPTURE_DIR --source-fps 24 --capture-wall-s W
  tools/hdmi_motion_instrument.py --counters-csv ctr.csv --pts-csv pts.csv \\
      --source-fps 24 --capture-fps 29.9068
  tools/hdmi_motion_instrument.py --self-test

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
# ERROR 17 guard: never ship a 23.976 bare default that looks measured.
assert abs(DEFAULT_ASSUMED_SOURCE_FPS - 24000.0 / 1001.0) > 0.01, (
    "DEFAULT_ASSUMED_SOURCE_FPS must not be 23.976 NTSC film"
)
FORBIDDEN_FPS_LOOKALIKES = (24000.0 / 1001.0, 23.976, 23.976023976023978)

# Back-compat aliases (same values; prefer DEFAULT_ASSUMED_* in new code).
DEFAULT_SOURCE_FPS = DEFAULT_ASSUMED_SOURCE_FPS
DEFAULT_CAPTURE_FPS = DEFAULT_ASSUMED_CAPTURE_FPS
PROVENANCE_CALLER = "caller_supplied"  # ERROR 17: never print bare "caller"
# Parent read from PMS frameRate= / ffmpeg banner — still caller-supplied, but
# explicitly measured outside this tool (not a bare guess).
PROVENANCE_CALLER_MEASURED = "caller_supplied_measured"
PROVENANCE_DEFAULT_ASSUMED = "DEFAULT_ASSUMED"
# Provenance for rates read from a capture container (ffprobe), not assumed.
PROVENANCE_CONTAINER = "container"
# Provenance for rates measured from this capture (PNG mtimes or --capture-wall-s).
PROVENANCE_MEASURED = "measured"
# Accept legacy "caller" in comparisons; caller_supplied_measured is authoritative.
_PROVENANCE_CALLER_ALIASES = frozenset(
    {PROVENANCE_CALLER, PROVENANCE_CALLER_MEASURED, "caller", "caller_supplied_measured"}
)


def _tag(value: Any, src: str | None) -> str:
    """Format ``value [provenance]`` so defaults cannot look measured (ERROR 17)."""
    if value is None:
        return f"None [{src or 'UNSCORED'}]"
    if isinstance(value, float):
        s = f"{value:.6g}"
    else:
        s = str(value)
    return f"{s} [{src or 'UNSCORED'}]"


def _is_caller_prov(src: str | None) -> bool:
    return str(src or "") in _PROVENANCE_CALLER_ALIASES


def _is_cap_auth_prov(src: str | None) -> bool:
    return str(src or "") in (
        PROVENANCE_CALLER,
        PROVENANCE_CALLER_MEASURED,
        "caller",
        "caller_supplied_measured",
        PROVENANCE_CONTAINER,
        PROVENANCE_MEASURED,
    )

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
# PTS split: gap ratio vs median inter-arrival.
# ratio < GAP_NORMAL_MAX → NORMAL (device skip if counter hole)
# ratio >= GAP_ANOM_MIN → ANOMALOUS (grabber drop attribution)
PTS_GAP_NORMAL_MAX = 1.45  # design: <~1.5× median dt
PTS_GAP_ANOM_MIN = 1.45  # design: same threshold; >= is anomalous
# Presence/split scorable only above this source span (else floor swallows signal)
PRESENCE_MIN_SPAN = 60  # design


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
        _is_caller_prov(source_fps_src)
        and _is_cap_auth_prov(capture_fps_src)
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
# RK flash fixture: white field + black FLASH text + RED bar (parent-viewed).
FLASH_LUMA_MIN = 100.0  # design / parent flash mean ~171
FLASH_ACTIVE_FRAC_MIN = 0.05  # design
RED_BAR_DOM_MIN = 0.25  # design; good flash red_dom ~0.73–0.75 [measured]
RED_BAR_PX_FRAC_MIN = 0.005  # design; good ~0.019 [measured]
MAGENTA_G_MAX = 80.0  # design
MAGENTA_RB_MIN = 150.0  # design
MAGENTA_SPREAD_MIN = 80.0  # design
# Minimum frames with a structural flag before structure alone hard-fails.
STRUCT_MIN_FRAMES = 3  # design

# Counter provenance (ERROR 17 class for burned-in n). A hallucinated digit
# string is worse than blank — it mints false revisits downstream.
COUNTER_SRC_MEASURED = "measured"
COUNTER_SRC_LOW_CONF = "low_confidence"
COUNTER_SRC_UNREADABLE = "UNREADABLE"

# Luma contrast |ink_Y − bg_Y| in counter ROI.
# Parent-measured /tmp/cap480b: dark yellow-on-black dY≈138; white FLASH
# yellow-on-white dY≈4.4. Tesseract is luma-driven (blue still separates on
# flash); refuse on dY so OCR cannot mint a plausible wrong n.
LOW_CONTRAST_DY_MAX = 25.0  # DEFAULT_ASSUMED design bound
# Overlay-present frames that refused the counter. Healthy flash duty ≪ this;
# above it, MOTION_OK is not trustworthy → demote to UNSCORED (never a pass).
UNREADABLE_FRAC_MOTION_CAP = 0.35  # DEFAULT_ASSUMED design


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

    Fail classes (any one → color_fail) — B7 full set, not green-only:
      1. green_cast      — green-dominance fingerprint (U,V~0 / old daemon)
      2. chroma_cast     — global channel-mean spread (any axis cast)
      3. magenta_cast    — high R+B, crushed G (parent broken-480p magenta)
      4. blue_cast       — blue-primary global cast (subset of chroma, labelled)
      5. greyscale_flat  — lit active region with near-zero chroma (dead UV)
      6. uv_swap         — saturated primary inversion (cyan/blue vs red)
      7. red_bar_missing — flash/white field without red-dominant bar (RK fixture)

    Dark mostly-black frames skip red_bar (no white field). Letterbox black
    does not trip greyscale. All metrics tagged measured in the report.

    Throughput: operate on a stride-8 subsample (global cast is low-frequency).
    Full 1080p was ~0.19 s/frame — dominated ledger OCR cost for no gain.
    """
    empty = {
        "mean_rgb": float(rgb.mean()) if rgb.size else 0.0,
        "green_frac": 0.0,
        "green_cast": False,
        "channel_spread": 0.0,
        "channel_means": [float(rgb.mean())] * 3 if rgb.size else [0.0, 0.0, 0.0],
        "chroma_cast": False,
        "magenta_cast": False,
        "blue_cast": False,
        "greyscale_flat": False,
        "uv_swap": False,
        "flash_field": False,
        "red_bar_ok": False,
        "red_bar_missing": False,
        "red_px_frac": 0.0,
        "active_frac": 0.0,
        "active_chroma_mean": 0.0,
        "sat_frac": 0.0,
        "red_dom": 0.0,
        "blue_dom": 0.0,
        "cyan_dom": 0.0,
        "color_fail": False,
        "color_fail_kinds": [],
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

    # Stride subsample — cast metrics are global; full-res is pure cost.
    if rgb.shape[0] > 240 and rgb.shape[1] > 320:
        rgb = rgb[::8, ::8]
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

    # Explicit magenta / blue labels (still also chroma_cast when spread fires).
    r_m, g_m, b_m = means[0], means[1], means[2]
    magenta_cast = (
        channel_spread >= MAGENTA_SPREAD_MIN
        and g_m <= MAGENTA_G_MAX
        and r_m >= MAGENTA_RB_MIN
        and b_m >= MAGENTA_RB_MIN
        and g_m < min(r_m, b_m) - 40.0
    )
    blue_cast = (
        chroma_cast
        and b_m >= r_m + 40.0
        and b_m >= g_m + 40.0
        and b_m >= 100.0
        and not magenta_cast
    )

    # Absolute red pixel fraction (fixture red bar geometry).
    rch = pix[:, 0]
    gch = pix[:, 1]
    bch = pix[:, 2]
    red_px = (rch > gch + 30.0) & (rch > bch + 30.0) & (rch > 80.0)
    red_px_frac = float(red_px.mean())

    # Flash / white-field: expect red bar (RK3/RK6). Dark frames skip.
    # Do NOT require greyscale active_frac — pure white (Y>220) is outside
    # GREYSCALE_LUMA_HI by design, but is exactly the flash paper.
    white_frac = float((luma >= 180.0).mean())
    flash_field = mean_rgb >= FLASH_LUMA_MIN and white_frac >= 0.15
    red_bar_ok = False
    red_bar_missing = False
    if flash_field:
        red_bar_ok = (
            red_dom >= RED_BAR_DOM_MIN and red_px_frac >= RED_BAR_PX_FRAC_MIN
        )
        red_bar_missing = not red_bar_ok

    kinds: list[str] = []
    if green_cast:
        kinds.append("GREEN")
    if magenta_cast:
        kinds.append("MAGENTA")
    if blue_cast:
        kinds.append("BLUE")
    if chroma_cast and not magenta_cast and not blue_cast and not green_cast:
        kinds.append("CHROMA")
    elif chroma_cast and "CHROMA" not in kinds and not magenta_cast:
        # keep CHROMA visible alongside green when both fire
        if "GREEN" in kinds:
            kinds.append("CHROMA")
    if greyscale_flat:
        kinds.append("GREYSCALE")
    if uv_swap:
        kinds.append("UV_SWAP")
    if red_bar_missing:
        kinds.append("RED_BAR_MISSING")

    color_fail = bool(
        green_cast
        or chroma_cast
        or magenta_cast
        or blue_cast
        or greyscale_flat
        or uv_swap
        or red_bar_missing
    )
    return {
        "mean_rgb": round(mean_rgb, 3),
        "mean_rgb_src": PROVENANCE_MEASURED,
        "green_frac": round(green_frac, 4),
        "green_frac_src": PROVENANCE_MEASURED,
        "green_cast": bool(green_cast),
        "channel_spread": round(channel_spread, 2),
        "channel_spread_src": PROVENANCE_MEASURED,
        "channel_means": [round(x, 1) for x in means],
        "channel_means_src": PROVENANCE_MEASURED,
        "chroma_cast": bool(chroma_cast),
        "magenta_cast": bool(magenta_cast),
        "blue_cast": bool(blue_cast),
        "greyscale_flat": bool(greyscale_flat),
        "uv_swap": bool(uv_swap),
        "flash_field": bool(flash_field),
        "white_frac": round(white_frac, 4),
        "white_frac_src": PROVENANCE_MEASURED,
        "red_bar_ok": bool(red_bar_ok),
        "red_bar_missing": bool(red_bar_missing),
        "red_px_frac": round(red_px_frac, 4),
        "red_px_frac_src": PROVENANCE_MEASURED,
        "active_frac": round(active_frac, 4),
        "active_frac_src": PROVENANCE_MEASURED,
        "active_chroma_mean": round(active_chroma_mean, 3),
        "sat_frac": round(sat_frac, 4),
        "red_dom": round(red_dom, 4),
        "red_dom_src": PROVENANCE_MEASURED,
        "blue_dom": round(blue_dom, 4),
        "cyan_dom": round(cyan_dom, 4),
        "mean_cb": round(mean_cb, 2),
        "mean_cr": round(mean_cr, 2),
        "color_fail": color_fail,
        "color_fail_kinds": kinds,
        "red_bar_dom_min": RED_BAR_DOM_MIN,
        "red_bar_dom_min_src": "DEFAULT_ASSUMED",
        "flash_luma_min": FLASH_LUMA_MIN,
        "flash_luma_min_src": "DEFAULT_ASSUMED",
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

    # Half-res is enough for wrap/vdup (thresholds calibrated with margin).
    # Full 1080p structure was ~0.035 s/frame; half-res ~4× cheaper.
    if rgb.shape[0] >= 720 and rgb.shape[1] >= 1280:
        rgb = rgb[::2, ::2]
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
    flash = mean_luma > 80.0
    # Locate yellow ink. Chroma helps on mid tones but FLOODS white FLASH
    # frames (parent glass480 f_1844: chroma ink 3× hard, merges glyphs so
    # template segmentation fails and tess emits garbage). Use chroma for
    # bbox location only when needed; OCR binary prefers hard|soft on flash.
    hard = _yellow_mask(rgb)
    soft = _yellow_mask_soft(rgb)
    if flash:
        m_loc = hard | soft
        if int(m_loc.sum()) < 80:
            m_loc = m_loc | _chroma_yellow_mask(rgb)
    elif mean_luma > 40.0:
        m_loc = _chroma_yellow_mask(rgb) | hard
    else:
        m_loc = hard

    if int(m_loc.sum()) < 80:
        return None, None, "no_overlay"

    row_e = rgb.astype(np.float32).mean(axis=2).mean(axis=1)
    active = np.where(row_e > 3.0)[0]
    y_top = int(active[0]) if len(active) else 0

    ys, xs = np.where(m_loc)
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
    # adds no ink. Re-threshold the padded RGB crop so trailing glyph columns
    # become ink. FLASH: hard|soft only (no chroma flood). Dark/mid: soft+hard,
    # chroma allowed when not flash.
    crop = rgb[y0:y1, x0:x1]
    if flash:
        binary = _yellow_mask(crop) | _yellow_mask_soft(crop)
    elif mean_luma > 40.0:
        binary = (
            _chroma_yellow_mask(crop)
            | _yellow_mask(crop)
            | _yellow_mask_soft(crop)
        )
    else:
        binary = _yellow_mask(crop) | _yellow_mask_soft(crop)
    if int(binary.sum()) < 80:
        # Fall back to location mask crop rather than inventing empty ink.
        binary = m_loc[y0:y1, x0:x1]
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
    """OCR-ready images. Keep the list short — tesseract dominates cost.

    Parent glass480 defect: psm7 on the full padded glyph invented a trailing
    digit (2358→23538) while psm8/13 and the right-crop were correct. We still
    emit multiple polarities, but callers must VOTE across them — never early-
    accept the first tier-10 hit.
    """
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

    # Digit-right crop of the preferred polarity (often cleanest for n=NNNN).
    primary = ordered[0]
    w, _h = primary.size
    ordered.append(primary.crop((int(w * 0.50), 0, w, _h)))
    # Right crop of secondary polarity too (cheap; no extra tess until used).
    secondary = ordered[1]
    w2, h2 = secondary.size
    ordered.append(secondary.crop((int(w2 * 0.50), 0, w2, h2)))
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


def _collapse_spurious_digit_votes(
    votes: list[tuple[int, int, str]],
) -> list[tuple[int, int, str]]:
    """Drop phantom *extra* trailing digits — not legitimate longer counters.

    Parent glass480 f_1820: psm7 emits ``TREK24 n=23538`` while psm8/13 emit
    ``n=2358``. The 5-digit form is the artifact.

    Do NOT collapse 2492→249: a 3-digit field truncation must not beat a
    tier-10 4-digit label read (that manufactured false holes).
    Rule: only drop long when len(long)>=5 or len(long)==mode_len+1 where
    mode among high-tier votes is the shorter length, and short has tier>=8.
    """
    if len(votes) < 2:
        return votes
    by_n: dict[int, list[tuple[int, int, str]]] = {}
    for t, n, raw in votes:
        by_n.setdefault(n, []).append((t, n, raw))
    # Digit-length mode among tier>=8 votes (or all if none)
    strong = [v for v in votes if v[0] >= 8] or list(votes)
    len_mode, _ = Counter(len(str(v[1])) for v in strong).most_common(1)[0]
    drop: set[int] = set()
    ns = list(by_n.keys())
    for long_n in ns:
        s_long = str(long_n)
        max_long = max(t for t, _, _ in by_n[long_n])
        for short_n in ns:
            if short_n == long_n:
                continue
            s_short = str(short_n)
            if not (
                len(s_long) == len(s_short) + 1 and s_long.startswith(s_short)
            ):
                continue
            max_short = max(t for t, _, _ in by_n[short_n])
            n_short = len(by_n[short_n])
            n_long = len(by_n[long_n])
            # Case A: classic 4→5 insertion (2358→23538)
            if len(s_long) >= 5 and len(s_short) >= 3 and max_short >= 7:
                drop.add(long_n)
                continue
            # Case B: long is one past the strong length mode, short matches mode
            if (
                len(s_long) == len_mode + 1
                and len(s_short) == len_mode
                and max_short >= 8
                and (n_short >= n_long or max_short >= max_long)
            ):
                drop.add(long_n)
                continue
            # Case C: long never has tier>=9 label, short does
            if max_long < 9 and max_short >= 9 and n_short >= 1:
                drop.add(long_n)
    if not drop:
        return votes
    return [v for v in votes if v[1] not in drop]


def _vote_counter(
    votes: list[tuple[int, int, str]],
) -> tuple[int | None, int, str]:
    """Consensus across tesseract parses. Never first-hit-wins."""
    if not votes:
        return None, 0, ""
    votes = _collapse_spurious_digit_votes(votes)
    # Prefer digit-length mode among high-tier votes (reject lone 5-digit
    # phantoms when the field is 4 digits).
    high = [v for v in votes if v[0] >= 7] or list(votes)
    len_mode, _ = Counter(len(str(v[1])) for v in high).most_common(1)[0]
    length_ok = [v for v in high if len(str(v[1])) == len_mode]
    pool = length_ok if length_ok else high
    # Weight by tier; majority on n
    scores: dict[int, float] = {}
    raw_for: dict[int, str] = {}
    tier_for: dict[int, int] = {}
    for t, n, raw in pool:
        scores[n] = scores.get(n, 0.0) + float(t)
        if n not in raw_for or t >= tier_for.get(n, 0):
            raw_for[n] = raw
            tier_for[n] = t
    best_n = max(scores, key=lambda k: (scores[k], tier_for[k]))
    best_c = sum(1 for _, n, _ in pool if n == best_n)
    tier = tier_for[best_n]
    raw = raw_for[best_n]
    # Accept label-tier with majority or multi-vote; bare digits need agreement.
    if tier >= 9 and best_c >= 1 and (
        best_c >= 2 or scores[best_n] >= 18.0 or len(pool) == 1
    ):
        # Single tier-10 only OK if no conflicting n at tier>=7 after collapse
        rivals = [n for n in scores if n != best_n]
        if rivals and best_c == 1 and max(scores[r] for r in rivals) >= 7:
            # Ambiguous — refuse rather than invent a revisit
            return None, tier, raw
        return best_n, tier, raw
    if tier >= 7 and best_c >= 2:
        return best_n, tier, raw
    if tier >= 5 and best_c >= 2:
        return best_n, tier, raw
    if tier >= 7 and best_c == 1 and len(scores) == 1:
        return best_n, tier, raw
    return None, tier, raw


def ocr_counter(binary: np.ndarray, mean_luma: float) -> tuple[int | None, int, str]:
    """OCR the overlay binary. Returns (n|None, tier, raw_text).

    Throughput: dark frames try psm8 on the primary glyph first. A clean
    ``TREK24 n=NNNN`` (tier-10) is accepted immediately — the parent insertion
    bug was psm7 first-hit-wins (2358→23538), not psm8 labels. Only escalate
    to multi-psm vote when the first hit is weak or bare-digit.
    Flash frames should call field/template first (see read_frame).
    """
    wl_full = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789= "
    wl_digits = "0123456789nN= "
    votes: list[tuple[int, int, str]] = []
    raws: list[str] = []
    variants = _prep_variants(binary, mean_luma)

    # Fast path: one psm8 full-line call. Tier-10 TREK label is trustworthy on
    # dark frames (measured: f_1820/1821). Do NOT early-accept psm7 or bare digits.
    txt0 = _tesseract_png(variants[0], 8, wl_full)
    if txt0:
        raws.append(txt0)
        n0, t0 = _parse_counter(txt0)
        if n0 is not None and t0 >= 10 and 2 <= len(str(n0)) <= 5:
            return n0, t0, txt0
        if n0 is not None and t0 > 0:
            votes.append((t0, n0, txt0))

    # Escalate: right-crop psm8 + primary psm13. Stop on multi-vote consensus.
    imgs = [variants[0]]
    if len(variants) > 2:
        imgs.append(variants[2])
    for img_i, img in enumerate(imgs):
        for psm in ((13,) if img_i == 0 else (8, 13)):
            if img_i == 0 and psm == 8:
                continue  # already did primary psm8
            txt = _tesseract_png(img, psm, wl_full)
            if txt:
                raws.append(txt)
            n, tier = _parse_counter(txt)
            if n is not None and tier > 0:
                votes.append((tier, n, txt))
        n_c, t_c, raw_c = _vote_counter(votes)
        if n_c is not None and t_c >= 9 and sum(1 for v in votes if v[1] == n_c) >= 2:
            return n_c, t_c, raw_c
        # Single tier-10 after a second independent parse still OK if no rival
        if n_c is not None and t_c >= 10 and len({v[1] for v in votes if v[0] >= 7}) == 1:
            return n_c, t_c, raw_c

    # Only if still weak: psm7 on primary (never alone as first-hit) + digit wl
    if not any(v[0] >= 9 for v in votes):
        txt = _tesseract_png(variants[0], 7, wl_full)
        if txt:
            raws.append(txt)
            n, tier = _parse_counter(txt)
            if n is not None and tier > 0:
                votes.append((tier, n, txt))
    if not any(v[0] >= 7 for v in votes):
        txt = _tesseract_png(variants[0], 8, wl_digits)
        if txt:
            raws.append(txt)
            n, tier = _parse_counter(txt)
            if n is not None and tier > 0:
                votes.append((tier, n, txt))

    n, tier, raw = _vote_counter(votes)
    if n is None:
        return None, tier, (raw or (raws[0] if raws else ""))
    return n, tier, raw


# ---------------------------------------------------------------------------
# Per-frame + burst scoring
# ---------------------------------------------------------------------------

def _template_read_n(binary: np.ndarray) -> tuple[int | None, float, str]:
    """Digit-template read of the counter field (3–5 digits).

    Used on white-flash frames (tesseract is weak on yellow-on-white) and as a
    cross-check when tess invents a trailing digit. Templates:
    tools/hdmi_motion_digit_templates.npz (real TREK24 HDMI captures).

    Parent defects this must catch:
      - 2358 read as 23538 (extra glyph split) — digit-length scoring kills it
      - 2378↔2338 and 2352↔2353 on FLASH — template NCC on segmented glyphs
    Returns (n, min_glyph_score, raw).
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
        # Reject slivers (noise / split halves of one glyph)
        if sub.shape[1] < 3 or sub.shape[0] < 6:
            return "?", -1.0
        dn = _norm(sub)
        best, bs = "?", -1.0
        second = -1.0
        for ch, t in avg.items():
            s = _ncc(dn, t)
            if s > bs:
                second = bs
                best, bs = ch, s
            elif s > second:
                second = s
        # 3 vs 7 confusion: require a margin when top-2 are close
        if best in ("3", "7") and second >= 0 and (bs - second) < 0.04:
            # Prefer the higher absolute score only if margin ok; else weak
            if bs < 0.55:
                return best, bs * 0.85  # down-weight ambiguous 3/7
        return best, bs

    def _col_runs(mask: np.ndarray, thr_frac: float = 0.12) -> list[tuple[int, int]]:
        col = np.convolve(mask.mean(axis=0), np.ones(3) / 3.0, mode="same")
        thr = float(col.max()) * thr_frac
        if thr <= 0:
            return []
        runs: list[tuple[int, int]] = []
        i = 0
        w = int(col.shape[0])
        while i < w:
            if col[i] >= thr:
                j = i
                while j < w and col[j] >= thr:
                    j += 1
                if j - i >= 2:
                    runs.append((i, j))
                i = j
            else:
                i += 1
        return runs

    def _score_cuts(
        region: np.ndarray, cuts: list[int]
    ) -> tuple[int | None, float, str]:
        """cuts are inclusive-exclusive boundaries, len = ndigits+1."""
        nd = len(cuts) - 1
        if nd < 3 or nd > 5:
            return None, -1.0, ""
        chars: list[str] = []
        scores: list[float] = []
        for k in range(nd):
            x0, x1 = cuts[k], cuts[k + 1]
            if x1 - x0 < 2:
                return None, -1.0, ""
            ch, s = _classify(region[:, x0:x1])
            chars.append(ch)
            scores.append(s)
        if not all(c.isdigit() for c in chars):
            return None, -1.0, ""
        mn = float(min(scores))
        return int("".join(chars)), mn, "".join(chars)

    def _equal_cuts(x0: int, x1: int, nd: int) -> list[int]:
        w = x1 - x0
        return [x0 + (k * w) // nd for k in range(nd)] + [x1]

    def _attempt(b2: np.ndarray) -> tuple[int | None, float, str]:
        # Full-line column runs: label + "n=" + digits. Digits are the rightmost
        # 3–5 similar-width runs (not the whole rightmost blob alone).
        runs = _col_runs(b2, 0.10)
        if not runs:
            return None, 0.0, ""
        # Merge very tight gaps (AA bridges) then take rightmost candidates.
        merged: list[tuple[int, int]] = [runs[0]]
        for a, b in runs[1:]:
            pa, pb = merged[-1]
            gap = a - pb
            width = b - a
            if gap <= max(2, width // 5):
                merged[-1] = (pa, b)
            else:
                merged.append((a, b))
        runs = merged
        # Typical line: many runs for TREK24, then n, then 3–5 digit runs.
        # Prefer rightmost nd runs whose median width is digit-like.
        best_n: int | None = None
        best_min = -1.0
        best_raw = ""

        def _consider(n: int | None, sc: float, raw: str) -> None:
            nonlocal best_n, best_min, best_raw
            if n is None or sc < 0.32:
                return
            # Prefer higher min score; tie-break toward 4 digits (lab fixtures).
            nd = len(str(n))
            prev_nd = len(str(best_n)) if best_n is not None else 0
            if sc > best_min + 0.02 or (
                abs(sc - best_min) <= 0.02 and nd == 4 and prev_nd != 4
            ):
                best_n, best_min, best_raw = n, sc, raw

        for nd in (4, 3, 5):
            if len(runs) >= nd:
                dig_runs = runs[-nd:]
                # Reject if widths wildly inconsistent (label glyph mixed in)
                widths = [b - a for a, b in dig_runs]
                med_w = float(sorted(widths)[len(widths) // 2])
                if med_w < 4:
                    continue
                if max(widths) > med_w * 2.8 or min(widths) < med_w * 0.35:
                    continue
                x0 = dig_runs[0][0]
                x1 = dig_runs[-1][1]
                region = b2[:, x0:x1]
                # cuts relative to region
                cuts = [0]
                for a, b in dig_runs:
                    if len(cuts) == 1:
                        cuts = [a - x0]
                    cuts.append(b - x0)
                # rebuild clean cuts from dig_runs
                cuts = [a - x0 for a, _ in dig_runs] + [dig_runs[-1][1] - x0]
                n, sc, raw = _score_cuts(region, cuts)
                _consider(n, sc, raw)
                # Also equal-split the digit span (handles merged blobs)
                n2, sc2, raw2 = _score_cuts(region, _equal_cuts(0, x1 - x0, nd))
                _consider(n2, sc2, raw2)

        # Fat rightmost blob equal-split (legacy path) for 3 and 4 digits
        a, b = runs[-1]
        region = b2[:, a:b]
        rw = int(region.shape[1])
        if rw >= 20:
            for nd in (4, 3, 5):
                n, sc, raw = _score_cuts(region, _equal_cuts(0, rw, nd))
                _consider(n, sc, raw)
            # Valley splits for 4 digits on fat blob
            proj = np.convolve(region.mean(axis=0), np.ones(3) / 3.0, mode="same")
            interior = proj[3 : max(4, rw - 3)]
            mins: list[tuple[float, int]] = []
            for ii in range(1, len(interior) - 1):
                if interior[ii] < interior[ii - 1] and interior[ii] <= interior[ii + 1]:
                    mins.append((float(interior[ii]), ii + 3))
            mins.sort()
            valleys = sorted(m[1] for m in mins[:8])
            if len(valleys) >= 3:
                # pick 3 valleys that roughly quarter the blob
                best_local = None
                best_scv = 1e9
                for i0 in range(len(valleys)):
                    for i1 in range(i0 + 1, len(valleys)):
                        for i2 in range(i1 + 1, len(valleys)):
                            vs = (valleys[i0], valleys[i1], valleys[i2])
                            if vs[0] < rw * 0.1 or vs[2] > rw * 0.9:
                                continue
                            if vs[1] - vs[0] < rw * 0.1 or vs[2] - vs[1] < rw * 0.1:
                                continue
                            scv = float(proj[vs[0]] + proj[vs[1]] + proj[vs[2]])
                            if scv < best_scv:
                                best_scv = scv
                                best_local = vs
                if best_local is not None:
                    cuts = [0, best_local[0], best_local[1], best_local[2], rw]
                    n, sc, raw = _score_cuts(region, cuts)
                    _consider(n, sc, raw)

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
        return None, 0.0, ""

    tallies: dict[int, float] = {}
    raw_for: dict[int, str] = {}
    sc_for: dict[int, float] = {}
    for n, sc, raw in votes:
        tallies[n] = tallies.get(n, 0.0) + sc
        if sc >= sc_for.get(n, -1.0):
            raw_for[n] = raw
            sc_for[n] = sc
    # Prefer 4-digit when scores close (fixture counters in this range)
    best_n = max(
        tallies,
        key=lambda k: (tallies[k], 1 if len(str(k)) == 4 else 0, sc_for[k]),
    )
    best_sc = sc_for[best_n]
    agree = sum(1 for n, _, _ in votes if n == best_n)
    if agree >= 2 or best_sc >= 0.42:
        return best_n, float(best_sc), raw_for[best_n]
    return None, float(best_sc), raw_for[best_n]


def _ocr_digit_field(binary: np.ndarray) -> tuple[int | None, int, str]:
    """Isolate the right-hand counter digits and OCR/template them.

    Parent glass480 flash path: full-line tess returns garbage (``N=2``) while a
    lightly-eroded right-field crop recovers ``n=2352`` / ``=2377``. This path
    is the flash primary and a dark-frame cross-check.

    Measured failure modes (glass480 pixel-confirmed):
      f_2024 n=2521 — split=0.42 returned multi-token garbage; split=0.55 OK
      f_2652 n=3024 — erode0 split=0.42 → ``n=362``; erode1+ OK
      f_2654 n=3025 — erode0 → ``n=3625`` (phantom 6); erode1 split=0.42 OK

    So we VOTE across split∈{0.42,0.55} × erode∈{0,1,2} and never early-accept
    a lone 3-digit or 5-digit when a 4-digit rival exists.

    Returns (n, tier, raw) with tier 8 for strong field hits, 6 for template.
    """
    if binary is None or binary.size == 0:
        return None, 0, ""
    base = Image.fromarray((binary.astype(np.uint8) * 255))
    votes: list[tuple[int, int, str]] = []  # tier, n, raw
    wl = "0123456789nN="

    def _add_vote(txt: str, erode_n: int, split: float, psm: int) -> None:
        n, tier = _parse_counter(txt)
        if n is None:
            # Prefer the LONGEST digit run (avoid '1 1 135' → 135 beating 2521)
            runs = re.findall(r"\d{2,5}", txt or "")
            if runs:
                best_run = max(runs, key=lambda s: (len(s), s))
                n, tier = int(best_run), 5
        if n is None or not (2 <= len(str(n)) <= 5):
            return
        # Down-weight bare multi-token garbage and short truncations
        bonus = 0
        if tier >= 9:
            bonus += 2
        elif tier >= 7:
            bonus += 1
        if len(str(n)) == 4:
            bonus += 2
        elif len(str(n)) == 5:
            bonus -= 1  # often phantom insertion on flash
        elif len(str(n)) <= 3:
            bonus -= 1
        votes.append(
            (max(1, tier + bonus), n,
             f"field_inv_e{erode_n}_s{split:.2f}_p{psm}:{txt}")
        )

    # Pass order: cheap first. Escalate only when no solid 4-digit consensus.
    # Measured HITs need split 0.55 and/or erode>=1 on hard flash frames.
    # Do NOT early-stop on bare-digit tier-5 pairs (f_2652: 3028×2 beat 3024).
    schedules: list[tuple[int, float, tuple[int, ...]]] = [
        (0, 0.42, (8,)),
        (0, 0.55, (8,)),
        (1, 0.42, (8, 13)),
        (1, 0.55, (8,)),
        (2, 0.42, (8, 13)),
        (2, 0.55, (8,)),
        (1, 0.35, (8,)),
        (2, 0.35, (8,)),
        (1, 0.50, (8,)),
    ]
    for erode_n, split, psms in schedules:
        im = base
        for _ in range(erode_n):
            im = im.filter(ImageFilter.MinFilter(3))
        arr = np.asarray(im) > 128
        w = int(arr.shape[1])
        x_split = int(w * split)
        right = arr[:, x_split:]
        if int(right.sum()) < 40:
            continue
        ri = Image.fromarray((right.astype(np.uint8) * 255))
        ri = ri.resize((max(8, ri.width * 3), max(8, ri.height * 3)), Image.NEAREST)
        pad = Image.new("L", (ri.width + 16, ri.height + 16), 0)
        pad.paste(ri, (8, 8))
        inv = ImageOps.invert(pad)
        for psm in psms:
            txt = _tesseract_png(inv, psm, wl)
            if txt:
                _add_vote(txt, erode_n, split, psm)
        # Early stop only on labeled (tier>=9 after bonus → raw parse tier>=7
        # with n=) 4-digit multi-agree. Bare digits alone never stop the search.
        strong4 = [
            v for v in votes
            if len(str(v[1])) == 4 and v[0] >= 9 and ("n=" in v[2] or "N=" in v[2] or "=" in v[2])
        ]
        if strong4:
            cnt = Counter(v[1] for v in strong4)
            top_n, top_c = cnt.most_common(1)[0]
            if top_c >= 2:
                break

    if not votes:
        return None, 0, ""
    collapsed = _collapse_spurious_digit_votes([(t, n, r) for t, n, r in votes])
    by_n: dict[int, list[tuple[int, str]]] = {}
    for t, n, r in collapsed:
        by_n.setdefault(n, []).append((t, r))

    def _rank(n: int) -> tuple:
        hits = by_n[n]
        nd = len(str(n))
        # Labeled n= hits (raw contains n=) beat bare digits at same count.
        labeled = sum(1 for _, r in hits if "n=" in r or "N=" in r or ":=" in r or "_p" in r and "=" in r.split(":")[-1])
        # Simpler: count high-tier hits
        hi = sum(1 for t, _ in hits if t >= 9)
        return (
            2 if nd == 4 else (0 if nd == 5 else -1),
            hi,
            labeled,
            max(t for t, _ in hits),
            sum(t for t, _ in hits),
            len(hits),
        )

    best = max(by_n.keys(), key=_rank)
    hits = by_n[best]
    tier = max(t for t, _ in hits)
    # Prefer a labeled raw string when available
    labeled_hits = [r for t, r in hits if "n=" in r or "N=" in r]
    raw = labeled_hits[0] if labeled_hits else hits[0][1]
    # Prefer any 4-digit over 3-digit truncation / 5-digit phantom
    four_cands = [n for n in by_n if len(str(n)) == 4]
    if four_cands and len(str(best)) != 4:
        best = max(four_cands, key=_rank)
        hits = by_n[best]
        tier = max(t for t, _ in hits)
        labeled_hits = [r for t, r in hits if "n=" in r or "N=" in r]
        raw = labeled_hits[0] if labeled_hits else hits[0][1]
    if len(hits) >= 2 or tier >= 8:
        return best, max(tier, 8 if len(hits) >= 2 else tier), raw
    if tier >= 7 and len(str(best)) >= 3:
        return best, tier, raw
    return None, tier, raw



def _dilate_bool(mask: np.ndarray, radius: int = 2) -> np.ndarray:
    """Cheap binary dilate (no scipy). radius in pixels."""
    if mask.size == 0 or radius <= 0:
        return mask.astype(bool, copy=False)
    m = mask.astype(bool, copy=False)
    out = m.copy()
    ys, xs = np.where(m)
    if len(ys) == 0:
        return out
    h, w = m.shape
    for dy in range(-radius, radius + 1):
        for dx in range(-radius, radius + 1):
            if dy == 0 and dx == 0:
                continue
            yy = ys + dy
            xx = xs + dx
            ok = (yy >= 0) & (yy < h) & (xx >= 0) & (xx < w)
            out[yy[ok], xx[ok]] = True
    return out


def measure_counter_contrast(
    rgb: np.ndarray,
    roi: tuple[int, int, int, int] | None,
    binary: np.ndarray | None = None,
) -> dict[str, Any]:
    """Measure **local edge** luma contrast of counter glyphs.

    Physics of the flash failure mode (parent-viewed /tmp/cap480b/f_049):
    yellow ink on white paper collapses the AA edge — local |ink_Y - ring_Y|
    drops to single digits while a ROI-wide white median still shows ~50 LU
    (yellow body vs distant white). Tesseract is edge/luma driven, so the
    LOCAL ring is the right refuse signal.

    Method:
      - ink = HARD yellow when available (glyph body; soft AA skirts are the
        washed band and must not dominate ink_Y)
      - bg  = mean Y on a 1–3 px dilated ring around ink (not whole-ROI median)
      - dY  = |ink_Y - bg_Y|   [measured]
      - low_contrast iff dY < LOW_CONTRAST_DY_MAX  [DEFAULT_ASSUMED design]

    Parent-measured anchors (this host):
      dark f_030: dY ≈ 138–190 (readable TREK24)
      flash f_049: local dY ≈ 4–20 (OCR hallucinates field_inv n=322)
    """
    out: dict[str, Any] = {
        "contrast_dy": None,
        "contrast_dy_src": PROVENANCE_MEASURED,
        "ink_y": None,
        "bg_y": None,
        "low_contrast": False,
        "contrast_status": "NO_ROI",
        "low_contrast_dy_max": LOW_CONTRAST_DY_MAX,
        "low_contrast_dy_max_src": "DEFAULT_ASSUMED",
    }
    if rgb is None or roi is None:
        return out
    x0, y0, x1, y1 = (int(v) for v in roi)
    if x1 <= x0 or y1 <= y0:
        return out
    crop = rgb[y0:y1, x0:x1]
    if crop.size == 0:
        return out
    Y = (
        0.299 * crop[:, :, 0].astype(np.float32)
        + 0.587 * crop[:, :, 1].astype(np.float32)
        + 0.114 * crop[:, :, 2].astype(np.float32)
    )
    hard = _yellow_mask(crop)
    soft = _yellow_mask_soft(crop)
    if int(hard.sum()) >= 30:
        ink_m = hard
        ink_kind = "hard_yellow"
    elif binary is not None and binary.shape[:2] == crop.shape[:2] and int(np.asarray(binary).sum()) >= 30:
        ink_m = np.asarray(binary).astype(bool)
        ink_kind = "ocr_binary"
    elif int(soft.sum()) >= 30:
        ink_m = soft
        ink_kind = "soft_yellow"
    else:
        chroma = _chroma_yellow_mask(crop)
        if int(chroma.sum()) < 20:
            out["contrast_status"] = "NO_INK"
            return out
        ink_m = chroma
        ink_kind = "chroma_yellow"

    # Local ring: dilate 2, then 3 if thin. Never fall back to whole-ROI median
    # (that measures yellow-body vs distant white and misses edge washout).
    ring = _dilate_bool(ink_m, radius=2) & ~ink_m
    if int(ring.sum()) < 40:
        ring = _dilate_bool(ink_m, radius=3) & ~ink_m
    if int(ring.sum()) < 20:
        ring = _dilate_bool(ink_m, radius=5) & ~ink_m
    if int(ring.sum()) < 10:
        out["contrast_status"] = "NO_BG"
        return out

    ink_y = float(Y[ink_m].mean())
    bg_y = float(Y[ring].mean())
    dy = abs(ink_y - bg_y)
    out["ink_y"] = round(ink_y, 3)
    out["bg_y"] = round(bg_y, 3)
    out["contrast_dy"] = round(dy, 3)
    out["contrast_status"] = "ok"
    out["ink_mask"] = ink_kind
    out["low_contrast"] = bool(dy < LOW_CONTRAST_DY_MAX)
    return out


def _counter_provenance(
    *,
    n: int | None,
    tier: int,
    raw: str,
    low_contrast: bool,
    contrast_status: str,
) -> tuple[str, str]:
    """Return (n_src, status_suffix_reason).

    n_src ∈ {measured, low_confidence, UNREADABLE}.
    Only measured may enter revisit/rate statistics.
    """
    if low_contrast or contrast_status == "low_contrast":
        return COUNTER_SRC_UNREADABLE, "low_contrast"
    if n is None:
        return COUNTER_SRC_UNREADABLE, "undecoded"
    # field_inv / flash template paths are best-effort — never "measured".
    raw_l = str(raw or "").lower()
    if "field_inv" in raw_l or raw_l.startswith("tpl:") or "tpl_weak" in raw_l:
        return COUNTER_SRC_LOW_CONF, "template_or_field_inv"
    if int(tier) >= 9:
        return COUNTER_SRC_MEASURED, "trek_label"
    if int(tier) >= 7:
        return COUNTER_SRC_LOW_CONF, f"tier_{tier}"
    return COUNTER_SRC_LOW_CONF, f"weak_tier_{tier}"


def read_frame(
    path: str | Path,
    *,
    force_ocr: bool = False,
    ocr_only: bool = False,
) -> dict[str, Any]:
    """Read one PNG. Never raises on decode failure — returns status.

    force_ocr: always run OCR (single-frame mode). In burst mode, bright flash
    frames skip tesseract (dark frames carry the counter) but still try the
    digit-template fallback so a visible overlay is not silently ignored.

    ocr_only: skip colour/structure metrics (ledger identity path). Counter OCR
    + mean_luma only — ~0.2 s/frame saved. Colour/structure stay False/empty.
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
    _color_empty = {
        "mean_rgb": None,
        "green_frac": None,
        "green_cast": False,
        "channel_spread": None,
        "chroma_cast": False,
        "magenta_cast": False,
        "blue_cast": False,
        "color_fail": False,
        "greyscale_flat": False,
        "uv_swap": False,
        "flash_field": False,
        "red_bar_ok": False,
        "red_bar_missing": False,
        "color_fail_kinds": [],
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
            **_color_empty,
            **_struct_empty,
        }

    rgb = np.asarray(im)
    mean_luma = float(rgb.mean())
    if ocr_only:
        gc = dict(_color_empty)
        gc["mean_rgb"] = round(mean_luma, 3)
        sm = dict(_struct_empty)
    else:
        gc = green_cast_metrics(rgb)
        sm = structure_metrics(rgb)

    binary, roi, st = find_overlay(rgb)
    if binary is None:
        return {
            "path": path,
            "status": st,
            "n": None,
            "n_src": COUNTER_SRC_UNREADABLE,
            "n_src_reason": st,
            "tier": 0,
            "raw": "",
            "fp": None,
            "roi": None,
            "mean_luma": round(mean_luma, 3),
            "overlay_present": False,
            "low_contrast": False,
            "contrast_dy": None,
            "contrast_dy_src": PROVENANCE_MEASURED,
            "contrast_status": "NO_OVERLAY",
            **gc,
            **sm,
        }

    fp = overlay_fingerprint(binary)
    n: int | None = None
    tier = 0
    raw = ""
    flash = mean_luma > 80.0  # white FLASH frames; yellow-on-white

    # Direct low-contrast refuse (parent ERROR: yellow-on-white FLASH).
    # Measure dY BEFORE any OCR so a washed-out overlay cannot hallucinate n.
    cmet = measure_counter_contrast(rgb, roi, binary)
    if cmet.get("low_contrast"):
        return {
            "path": path,
            "status": "unreadable_low_contrast",
            "n": None,
            "n_src": COUNTER_SRC_UNREADABLE,
            "n_src_reason": "low_contrast",
            "tier": 0,
            "raw": f"UNREADABLE[low_contrast dY={cmet.get('contrast_dy')}]",
            "fp": fp,
            "roi": roi,
            "mean_luma": round(mean_luma, 3),
            "overlay_present": True,
            "low_contrast": True,
            "contrast_dy": cmet.get("contrast_dy"),
            "contrast_dy_src": PROVENANCE_MEASURED,
            "ink_y": cmet.get("ink_y"),
            "bg_y": cmet.get("bg_y"),
            "contrast_status": cmet.get("contrast_status"),
            **gc,
            **sm,
        }

    # Throughput + accuracy (parent glass480):
    #   FLASH: digit-FIELD first (full-line tess emits N=2 / 3/7 mess).
    #   DARK:  multi-psm vote (kills 2358→23538) + field cross-check.
    # FLASH: digit-field first (cheap-ish right crop). DARK: full-line vote
    # first; field only if needed (throughput — field does multiple tess calls).
    field_n: int | None = None
    field_t = 0
    field_r = ""
    if flash:
        field_n, field_t, field_r = _ocr_digit_field(binary)
        # Prefer clean 4-digit field. Lone 3/5-digit must not beat a tier-9
        # full-line TREK label (f_2654: field 3625 vs line n=3025).
        if field_n is not None and field_t >= 7 and len(str(field_n)) == 4:
            n, tier, raw = field_n, field_t, field_r
        else:
            n, tier, raw = ocr_counter(binary, mean_luma)
            if field_n is not None and (
                n is None
                or (len(str(field_n)) == 4 and len(str(n)) != 4)
                or (len(str(n)) < len(str(field_n)) and len(str(field_n)) <= 4)
            ):
                n, tier, raw = field_n, field_t, field_r
    else:
        n, tier, raw = ocr_counter(binary, mean_luma)
        # Only spend field OCR when tess looks like insertion (5+ digits) or blind
        need_field = n is None or len(str(n)) >= 5 or (tier < 9 and force_ocr)
        if need_field:
            field_n, field_t, field_r = _ocr_digit_field(binary)
            if n is None and field_n is not None:
                n, tier, raw = field_n, field_t, field_r
            elif (
                n is not None
                and field_n is not None
                and len(str(n)) == len(str(field_n)) + 1
                and str(n).startswith(str(field_n))
                and len(str(n)) >= 5
            ):
                # 23538 vs 2358 only
                n, tier, raw = field_n, max(tier, field_t), f"ext_fix:{raw}->{field_r}"

    if n is None:
        tn, tscore, traw = _template_read_n(binary)
        if tn is not None and tscore >= 0.35:
            n, tier, raw = tn, 6, f"tpl:{traw}"
        elif traw:
            raw = raw or f"tpl_weak:{traw}"

    # Final: strip 5-digit insertion only (never 4→3 truncation)
    if n is not None and len(str(n)) >= 5 and field_n is not None:
        sn, sf = str(n), str(field_n)
        if len(sn) == len(sf) + 1 and sn.startswith(sf):
            n, tier, raw = field_n, max(tier, field_t), f"final_ext_fix:{raw}"

    n_src, n_reason = _counter_provenance(
        n=n, tier=int(tier or 0), raw=str(raw or ""),
        low_contrast=False, contrast_status=str(cmet.get("contrast_status") or "ok"),
    )
    if n is None:
        status = "undecoded"
        n_src = COUNTER_SRC_UNREADABLE
    elif n_src == COUNTER_SRC_LOW_CONF:
        status = "ok_low_confidence"
    else:
        status = "ok"
    return {
        "path": path,
        "status": status,
        "n": n,
        "n_src": n_src,
        "n_src_reason": n_reason,
        "tier": tier,
        "raw": raw,
        "fp": fp,
        "roi": roi,
        "mean_luma": round(mean_luma, 3),
        "overlay_present": True,
        "low_contrast": False,
        "contrast_dy": cmet.get("contrast_dy"),
        "contrast_dy_src": PROVENANCE_MEASURED,
        "ink_y": cmet.get("ink_y"),
        "bg_y": cmet.get("bg_y"),
        "contrast_status": cmet.get("contrast_status"),
        **gc,
        **sm,
    }


def _read_frame_job(args: tuple[str, bool, bool]) -> dict[str, Any]:
    """Picklable worker for ProcessPoolExecutor."""
    path, force_ocr, ocr_only = args
    return read_frame(path, force_ocr=force_ocr, ocr_only=ocr_only)


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


def load_counters_csv(path: str | Path) -> tuple[list[tuple[int, int]], dict[str, Any]]:
    """Load parent/cache CSV with at least idx + n columns (empty n skipped).

    Returns (pairs, meta) where meta has frames_total, blind_frames, blind_frac
    measured from the CSV rows (empty n = blind/undecoded).
    """
    import csv

    pairs: list[tuple[int, int]] = []
    total = 0
    blind = 0
    with open(path, newline="") as f:
        r = csv.DictReader(f)
        if not r.fieldnames or "idx" not in r.fieldnames or "n" not in r.fieldnames:
            raise ValueError(f"counters CSV needs idx,n columns; got {r.fieldnames}")
        for row in r:
            total += 1
            ns = (row.get("n") or "").strip()
            if ns == "":
                blind += 1
                continue
            pairs.append((int(row["idx"]), int(float(ns))))
    meta = {
        "frames_total": int(total),
        "blind_frames": int(blind),
        "decoded_frames": int(len(pairs)),
        "blind_frac": (round(blind / total, 4) if total else None),
        "frames_total_src": PROVENANCE_MEASURED,
        "blind_frac_src": PROVENANCE_MEASURED,
    }
    return pairs, meta


def load_pts_csv(path: str | Path) -> dict[int, float]:
    """Load per-frame timestamps.

    Accepts:
      - one float seconds per line (index = line number)
      - csv with columns idx,pts_s  OR  pts_s only
      - ffprobe csv=p=0 single column of pkt_pts_time
    Returns map capture_idx → pts_seconds (float).
    """
    import csv

    text = Path(path).read_text(encoding="utf-8", errors="replace").strip()
    if not text:
        return {}
    lines = [ln.strip() for ln in text.splitlines() if ln.strip()]
    out: dict[int, float] = {}
    # Try headered CSV
    if "," in lines[0] and not lines[0][0].isdigit() and "pts" in lines[0].lower():
        r = csv.DictReader(lines)
        for i, row in enumerate(r):
            pts_s = row.get("pts_s") or row.get("pkt_pts_time") or row.get("pts")
            idx_s = row.get("idx") or row.get("frame")
            if pts_s is None or pts_s == "":
                continue
            idx = int(idx_s) if idx_s not in (None, "") else i
            out[idx] = float(pts_s)
        return out
    # Plain one float per line (ffprobe -of csv=p=0)
    for i, ln in enumerate(lines):
        # ffprobe sometimes emits "N/A"
        part = ln.split(",")[0].strip()
        if part.upper() == "N/A" or part == "":
            continue
        try:
            out[i] = float(part)
        except ValueError:
            continue
    return out


def analyze_presence_loss_split(
    pairs: list[tuple[int, int]],
    *,
    pts_by_idx: dict[int, float] | None = None,
    source_fps: float = DEFAULT_ASSUMED_SOURCE_FPS,
    capture_fps: float = DEFAULT_ASSUMED_CAPTURE_FPS,
    source_fps_src: str = PROVENANCE_DEFAULT_ASSUMED,
    capture_fps_src: str = PROVENANCE_DEFAULT_ASSUMED,
    frames_total: int | None = None,
    blind_frames: int | None = None,
) -> dict[str, Any]:
    """PRIMARY loss detector: absent burned-in counter values + optional PTS split.

    Parent (rule 0):
      capture interval (33.4ms) < source hold (41.7ms) ⇒ every fully-displayed
      source frame MUST be sampled ≥ once. Therefore any ABSENT counter value in
      the observed span was displayed <33.4ms or never.

    Primary metric is the set of holes between successive *distinct* observed n
    after structural OCR filter (RLE values). The per-adjacent-pair max_exp test
    UNDERCOUNTS hold-then-jump and is secondary only (see analyze_counter_skips).

    With PTS (monotonic per-frame arrival times):
      for each successive observed (n0@t0) → (n1@t1) with hole = n1-n0-1 > 0:
        ratio = (t1-t0) / median_dt
        ratio < PTS_GAP_NORMAL_MAX  → DEVICE_SKIP (normal inter-arrival)
        ratio >= PTS_GAP_ANOM_MIN   → GRABBER_DROP (anomalous gap)
      Never merge the two counters.

    Without PTS: cannot split. loss_split_status=UNSCORED. presence holes are
    candidates only. Steady-state claim below resolution_floor → UNSCORED
    (not a hedged percent). rc=77 discipline for the loss dimension.
    """
    fps_auth = _is_caller_prov(source_fps_src) and _is_cap_auth_prov(capture_fps_src)
    notes: list[str] = []
    out: dict[str, Any] = {
        "loss_split_status": "LOSS_UNSCORED",
        "device_skip_frames": None,
        "grabber_drop_frames": None,
        "device_skip_events": 0,
        "grabber_drop_events": 0,
        "presence_hole_frames": None,
        "presence_hole_events": 0,
        "presence_holes_head": [],
        "unsplit_candidate_frames": None,
        "resolution_floor_frac": None,
        "resolution_floor_src": PROVENANCE_DEFAULT_ASSUMED,
        "candidate_loss_frac": None,
        "steady_state_loss": "UNSCORED",
        "steady_state_reason": "",
        "pts_available": bool(pts_by_idx),
        "pts_src": PROVENANCE_MEASURED if pts_by_idx else PROVENANCE_DEFAULT_ASSUMED,
        "median_dt_s": None,
        "median_dt_src": PROVENANCE_DEFAULT_ASSUMED,
        "blind_frames": blind_frames,
        "blind_frac": None,
        "blind_frac_src": PROVENANCE_MEASURED if blind_frames is not None else PROVENANCE_DEFAULT_ASSUMED,
        "fps_authoritative": fps_auth,
        "source_fps": source_fps,
        "capture_fps": capture_fps,
        "source_fps_src": source_fps_src,
        "capture_fps_src": capture_fps_src,
        "loss_notes": notes,
        "loss_arithmetic": "",
        "primary_detector": "presence_holes_RLE",
        "secondary_detector": "adjacent_max_exp (undercounts hold-then-jump)",
    }

    if frames_total and frames_total > 0 and blind_frames is not None:
        out["blind_frac"] = round(blind_frames / frames_total, 4)
        out["blind_frac_src"] = PROVENANCE_MEASURED

    if len(pairs) < RATE_MIN_SAMPLES:
        notes.append(f"insufficient_pairs={len(pairs)}")
        out["steady_state_reason"] = "insufficient_samples"
        out["loss_arithmetic"] = "n/a"
        return out

    ns = [n for _, n in pairs]
    idxs = [i for i, _ in pairs]
    runs = _rle_runs(ns)
    vals = [v for v, _ in runs]
    if len(vals) < 2:
        notes.append("fewer_than_2_unique_states")
        out["steady_state_reason"] = "pinned_or_single_state"
        out["loss_arithmetic"] = "n/a"
        return out

    n_first, n_last = vals[0], vals[-1]
    ctr_span = n_last - n_first
    out["presence_n_first"] = int(n_first)
    out["presence_n_last"] = int(n_last)
    out["presence_ctr_span"] = int(ctr_span)

    # Map each RLE value → first capture idx where it appears (for PTS)
    first_idx_for_val: dict[int, int] = {}
    for cap_i, n in pairs:
        if n not in first_idx_for_val:
            first_idx_for_val[n] = cap_i

    hole_frames = 0
    hole_events = 0
    holes_detail: list[dict[str, Any]] = []
    device_frames = 0
    grabber_frames = 0
    device_events = 0
    grabber_events = 0

    # Median dt from PTS if available
    median_dt = None
    pts_src = out["pts_src"]
    if pts_by_idx:
        ordered_pts = []
        for cap_i in sorted(pts_by_idx):
            ordered_pts.append(pts_by_idx[cap_i])
        dts = [
            ordered_pts[i + 1] - ordered_pts[i]
            for i in range(len(ordered_pts) - 1)
            if ordered_pts[i + 1] > ordered_pts[i]
        ]
        if dts:
            dts_s = sorted(dts)
            median_dt = float(dts_s[len(dts_s) // 2])
            out["median_dt_s"] = round(median_dt, 6)
            out["median_dt_src"] = PROVENANCE_MEASURED
            pts_src = PROVENANCE_MEASURED
    if median_dt is None or median_dt <= 0:
        if capture_fps > 0:
            median_dt = 1.0 / capture_fps
            out["median_dt_s"] = round(median_dt, 6)
            out["median_dt_src"] = (
                capture_fps_src if pts_by_idx is None else PROVENANCE_DEFAULT_ASSUMED
            )
            if pts_by_idx is None:
                notes.append(
                    "no_pts: median_dt derived from cap_fps "
                    f"({capture_fps} src={capture_fps_src}) — CANNOT split "
                    "device vs grabber; uniform spacing ASSUMED"
                )

    for a, b in zip(vals, vals[1:]):
        if b <= a:
            continue
        hole = b - a - 1
        if hole <= 0:
            continue
        hole_frames += hole
        hole_events += 1
        i0 = first_idx_for_val.get(a)
        i1 = first_idx_for_val.get(b)
        detail: dict[str, Any] = {
            "n0": int(a),
            "n1": int(b),
            "hole": int(hole),
            "cap_idx0": i0,
            "cap_idx1": i1,
        }
        if (
            pts_by_idx
            and i0 is not None
            and i1 is not None
            and i0 in pts_by_idx
            and i1 in pts_by_idx
            and median_dt
            and median_dt > 0
        ):
            dt = float(pts_by_idx[i1] - pts_by_idx[i0])
            ratio = dt / median_dt if median_dt else None
            detail["dt_s"] = round(dt, 6)
            detail["dt_ratio"] = round(ratio, 3) if ratio is not None else None
            detail["dt_src"] = PROVENANCE_MEASURED
            if ratio is not None and ratio < PTS_GAP_NORMAL_MAX:
                device_frames += hole
                device_events += 1
                detail["class"] = "DEVICE_SKIP"
            elif ratio is not None and ratio >= PTS_GAP_ANOM_MIN:
                grabber_frames += hole
                grabber_events += 1
                detail["class"] = "GRABBER_DROP"
            else:
                detail["class"] = "UNSCORED"
        else:
            detail["class"] = "UNSPLIT_NO_PTS" if not pts_by_idx else "UNSPLIT_NO_PTS_FOR_PAIR"
        holes_detail.append(detail)

    out["presence_hole_frames"] = int(hole_frames)
    out["presence_hole_events"] = int(hole_events)
    out["presence_holes_head"] = holes_detail[:12]
    out["unsplit_candidate_frames"] = (
        int(hole_frames) if not pts_by_idx else int(
            sum(d["hole"] for d in holes_detail if d.get("class", "").startswith("UNSPLIT"))
        )
    )

    if pts_by_idx:
        out["device_skip_frames"] = int(device_frames)
        out["grabber_drop_frames"] = int(grabber_frames)
        out["device_skip_events"] = int(device_events)
        out["grabber_drop_events"] = int(grabber_events)
        out["loss_split_status"] = "LOSS_SPLIT_OK"
        notes.append(
            f"pts_split device_skip_frames={device_frames} grabber_drop_frames={grabber_frames} "
            f"(never merged; normal ratio<{PTS_GAP_NORMAL_MAX} vs anom>={PTS_GAP_ANOM_MIN})"
        )
    else:
        out["device_skip_frames"] = None
        out["grabber_drop_frames"] = None
        out["loss_split_status"] = "LOSS_UNSCORED"
        notes.append(
            "NO_PTS: device_skip vs grabber_drop INDISTINGUISHABLE — "
            "do not treat presence holes as device loss"
        )

    # --- Resolution floor (first-class) ---
    # Components (fractions of source span):
    #   blind_frac: undecoded capture samples (flash/OCR) — measured if given
    #   grabber_rate_deficit: |1 - cap_meas/cap_nom| when cap measured vs 30
    #   single_event: 1/ctr_span
    # Floor = max of available components. Claim only if candidate >> floor.
    comps: list[tuple[str, float]] = []
    if out.get("blind_frac") is not None:
        comps.append(("blind_frac", float(out["blind_frac"])))
    if (
        _is_cap_auth_prov(capture_fps_src)
        and capture_fps > 0
        and DEFAULT_ASSUMED_CAPTURE_FPS > 0
    ):
        # How short the grabber ran vs nominal 30 — order-of-magnitude for
        # "same order as candidate events" (parent 29.9068 → ~0.31% rate error;
        # integrated over span as fraction of samples missing).
        deficit = abs(DEFAULT_ASSUMED_CAPTURE_FPS - capture_fps) / DEFAULT_ASSUMED_CAPTURE_FPS
        comps.append(("grabber_rate_deficit_vs_30nom", float(deficit)))
        notes.append(
            f"grabber_rate_deficit vs DEFAULT_ASSUMED 30.0 = {deficit:.4f} "
            f"(cap_fps={capture_fps} src={capture_fps_src}) — same class as "
            "small steady-state claims"
        )
    if ctr_span > 0:
        comps.append(("one_source_frame", 1.0 / float(ctr_span)))
    # Without PTS, the entire presence-hole fraction is below-resolution for
    # *device* attribution — floor at least the unsplit candidate fraction
    # so we never mint a device-loss claim from PNG-only.
    if not pts_by_idx and ctr_span > 0 and hole_frames > 0:
        comps.append(("unsplit_presence_equals_floor", hole_frames / float(ctr_span)))

    floor = max((c for _, c in comps), default=0.02)
    out["resolution_floor_frac"] = round(floor, 4)
    out["resolution_floor_src"] = PROVENANCE_MEASURED if comps else PROVENANCE_DEFAULT_ASSUMED
    out["resolution_floor_components"] = {k: round(v, 4) for k, v in comps}

    cand_frac = (hole_frames / float(ctr_span)) if ctr_span > 0 else None
    out["candidate_loss_frac"] = round(cand_frac, 4) if cand_frac is not None else None

    # Steady-state verdict for the LOSS dimension (not main rc unless we choose)
    if ctr_span < PRESENCE_MIN_SPAN:
        out["steady_state_loss"] = "UNSCORED"
        out["steady_state_reason"] = f"ctr_span={ctr_span}<{PRESENCE_MIN_SPAN}"
    elif not pts_by_idx:
        out["steady_state_loss"] = "UNSCORED"
        out["steady_state_reason"] = (
            "below_instrument_resolution_floor_no_pts "
            f"candidate_frac={out['candidate_loss_frac']} "
            f"floor={out['resolution_floor_frac']} "
            "(PNG-only cannot separate grabber drop from device skip; "
            "do NOT report a hedged device-loss percent)"
        )
    elif cand_frac is not None and cand_frac <= floor * 1.5:
        # device-only fraction vs floor
        dev_frac = (device_frames / float(ctr_span)) if ctr_span else 0.0
        out["steady_state_loss"] = "UNSCORED"
        out["steady_state_reason"] = (
            f"device_skip_frac={dev_frac:.4f} candidate_frac={cand_frac:.4f} "
            f"<= ~1.5×floor={floor:.4f} — BELOW RESOLUTION FLOOR"
        )
    else:
        dev_frac = (device_frames / float(ctr_span)) if ctr_span else 0.0
        if dev_frac > floor * 1.5:
            out["steady_state_loss"] = "DEVICE_LOSS_ABOVE_FLOOR"
            out["steady_state_reason"] = (
                f"device_skip_frac={dev_frac:.4f} > 1.5×floor={floor:.4f}"
            )
        else:
            out["steady_state_loss"] = "UNSCORED"
            out["steady_state_reason"] = (
                f"device_skip_frac={dev_frac:.4f} not above floor={floor:.4f}"
            )

    out["loss_arithmetic"] = (
        f"PRIMARY presence: RLE distinct n; hole=n[i+1]-n[i]-1; "
        f"sum_holes={hole_frames} over ctr_span={ctr_span} "
        f"(n_first={n_first} n_last={n_last}). "
        f"capture_interval < source_hold ⇒ absent n ⇒ displayed <1 cap period or never. "
        f"PTS split: dt_ratio=(t1-t0)/median_dt; "
        f"<{PTS_GAP_NORMAL_MAX}→DEVICE_SKIP >=→GRABBER_DROP. "
        f"device_frames={out['device_skip_frames']} grabber_frames={out['grabber_drop_frames']}. "
        f"floor={out['resolution_floor_frac']} components={out['resolution_floor_components']}. "
        f"max_exp adjacent is SECONDARY only (undercounts hold-then-jump)."
    )
    out["loss_notes"] = notes
    out["pts_src"] = pts_src
    return out


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
    blind_frames: int | None = None,
    pts_by_idx: dict[int, float] | None = None,
) -> dict[str, Any]:
    """Score a pre-decoded counter sequence (e.g. parent OCR cache CSV).

    Applies the same structural OCR filter + rate/skip/startup/presence path as
    score_burst without re-reading PNGs. Colour/structure are UNSCORED here.
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
    loss_info = analyze_presence_loss_split(
        pairs,
        pts_by_idx=pts_by_idx,
        source_fps=source_fps,
        capture_fps=capture_fps,
        source_fps_src=source_fps_src,
        capture_fps_src=capture_fps_src,
        frames_total=frames_total,
        blind_frames=blind_frames,
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
        # Presence + PTS split (Gap 1)
        "loss_split_status": loss_info.get("loss_split_status"),
        "device_skip_frames": loss_info.get("device_skip_frames"),
        "grabber_drop_frames": loss_info.get("grabber_drop_frames"),
        "device_skip_events": loss_info.get("device_skip_events"),
        "grabber_drop_events": loss_info.get("grabber_drop_events"),
        "presence_hole_frames": loss_info.get("presence_hole_frames"),
        "presence_hole_events": loss_info.get("presence_hole_events"),
        "presence_holes_head": loss_info.get("presence_holes_head"),
        "resolution_floor_frac": loss_info.get("resolution_floor_frac"),
        "resolution_floor_src": loss_info.get("resolution_floor_src"),
        "resolution_floor_components": loss_info.get("resolution_floor_components"),
        "candidate_loss_frac": loss_info.get("candidate_loss_frac"),
        "steady_state_loss": loss_info.get("steady_state_loss"),
        "steady_state_reason": loss_info.get("steady_state_reason"),
        "blind_frames": loss_info.get("blind_frames"),
        "blind_frac": loss_info.get("blind_frac"),
        "blind_frac_src": loss_info.get("blind_frac_src"),
        "pts_available": loss_info.get("pts_available"),
        "pts_src": loss_info.get("pts_src"),
        "median_dt_s": loss_info.get("median_dt_s"),
        "median_dt_src": loss_info.get("median_dt_src"),
        "loss_notes": loss_info.get("loss_notes"),
        "loss_arithmetic": loss_info.get("loss_arithmetic"),
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

      1) extra digit vs neighbours (e.g. 4-digit stream, one 5-digit read
         ``1352``→``13527``) or truncation far from neighbour center
         (``1900``→``19``). Legal decade growth 9→10 / 99→100 is kept.
      2) RLE spike / trough: (b-a)>=4 and c<b (covers ``2``→``7``:
         1581,1587,1583 and 2911,2917,2913).
      3) MAD radius (not widened). Bank-swap revisits survive for RATE_FAIL.

    MAD radius is unchanged (not widened). Rejections carry printed reasons
    naming capture idx and the violated rule so RATE_FAIL cannot launder OCR.
    """
    rejections: list[dict[str, Any]] = []
    # Shallow copy so recovery rewrites do not mutate the caller's list.
    pairs = [(int(i), int(n)) for i, n in pairs]
    if len(pairs) < 3:
        return list(pairs), rejections

    # --- Pass A: local digit-count discontinuity (not global mode alone) ---
    # Counter grows 1→2→3→4 digits over a long clip — that is LEGAL.
    # Reject ONLY:
    #   • dlen > mode_len  (spurious extra digit: 1352→13527)
    #   • dlen < mode_len AND value far from neighbour center (truncation: 1900→19)
    # Do NOT reject decade boundaries (9→10, 99→100, 999→1000).
    # Extra-digit with recoverable prefix → rewrite (never emit 5-digit phantom).
    ns = [n for _, n in pairs]
    keep_idx = set(range(len(pairs)))
    for i, (cap_i, n) in enumerate(pairs):
        mode_len, mode_c = _local_digit_mode(ns, i, radius=4)
        if mode_len is None or mode_c < 2:
            continue
        dlen = len(str(n))
        if dlen == mode_len:
            continue
        neigh = [ns[j] for j in range(max(0, i - 4), min(len(ns), i + 5)) if j != i]
        if not neigh:
            continue
        med_n = float(_median_int(neigh))
        if dlen == mode_len + 1:
            # Legal decade growth (9→10, 99→100, 999→1000) vs 1352→13527.
            boundary = 10 ** mode_len
            near_boundary = (
                abs(float(n) - boundary) <= 30.0
                or abs(med_n - boundary) <= 30.0
                or (boundary <= float(n) <= boundary + 50.0 and med_n >= boundary * 0.5)
            )
            if near_boundary and float(n) < boundary * 10:
                continue  # keep legal growth
            # RECOVER: drop exactly one digit so length matches mode, pick the
            # candidate nearest the neighbour median. Covers:
            #   23538→2358 (trailing insertion, parent glass480 f_1820)
            #   29682→2962 (interior phantom digit; //10 alone yields 2968 wrong)
            # Parent: emitting the long value manufactures false revisit+gap.
            s_n = str(n)
            cands: list[int] = []
            if dlen == mode_len + 1:
                for di in range(len(s_n)):
                    c = int(s_n[:di] + s_n[di + 1 :])
                    if len(str(c)) == mode_len or (
                        c == 0 and mode_len == 1
                    ):
                        cands.append(c)
            recovered = None
            if cands:
                recovered = min(cands, key=lambda c: abs(float(c) - med_n))
                if abs(float(recovered) - med_n) > max(8.0, 0.01 * abs(med_n) + 5.0):
                    recovered = None
            if recovered is not None:
                pairs[i] = (cap_i, int(recovered))
                ns[i] = int(recovered)
                rejections.append(
                    {
                        "cap_idx": int(cap_i),
                        "n": int(n),
                        "recovered_n": int(recovered),
                        "rule": "digit_count_extra_recovered",
                        "reason": (
                            f"cap_idx={cap_i} n={n} digits={dlen} > neighbour_mode="
                            f"{mode_len}; recovered n={recovered} near med_neigh="
                            f"{med_n:.0f} (drop-one-digit; cands={cands})"
                        ),
                    }
                )
                continue
            # No safe recovery — UNRESOLVED: drop the value, never emit it.
            keep_idx.discard(i)
            rejections.append(
                {
                    "cap_idx": int(cap_i),
                    "n": int(n),
                    "rule": "digit_count_extra_unresolved",
                    "reason": (
                        f"cap_idx={cap_i} n={n} digits={dlen} > neighbour_mode="
                        f"{mode_len} (count={mode_c}) med_neigh={med_n:.0f} — "
                        f"UNRESOLVED spurious extra digit (e.g. 1352→13527)"
                    ),
                }
            )
        elif dlen > mode_len + 1:
            keep_idx.discard(i)
            rejections.append(
                {
                    "cap_idx": int(cap_i),
                    "n": int(n),
                    "rule": "digit_count_extra",
                    "reason": (
                        f"cap_idx={cap_i} n={n} digits={dlen} >> neighbour_mode="
                        f"{mode_len} (count={mode_c}) — impossible digit jump"
                    ),
                }
            )
        elif dlen < mode_len:
            # Truncation (1900→19) or flash right-crop (=252 from 2521).
            # Expand by appending digits; prefer monotonic continuity from the
            # previous sample (prev+1) over pure median when both are plausible.
            recovered_t = None
            exp = mode_len - dlen
            prev_n = ns[i - 1] if i > 0 else None
            next_n = ns[i + 1] if i + 1 < len(ns) else None
            if 1 <= exp <= 2 and n >= 0:
                base_m = n * (10 ** exp)
                cands_t = [base_m + k for k in range(10 ** exp)]
                # Score: distance to med, with bonus for prev+1 / next-1
                def _tc_score(c: int) -> float:
                    s = abs(float(c) - med_n)
                    if prev_n is not None and c == int(prev_n) + 1:
                        s -= 3.0
                    if next_n is not None and c == int(next_n) - 1:
                        s -= 3.0
                    if prev_n is not None and next_n is not None:
                        if int(prev_n) < c < int(next_n):
                            s -= 1.5
                    return s
                best_t = min(cands_t, key=_tc_score)
                if abs(float(best_t) - med_n) <= max(12.0, 0.015 * abs(med_n) + 8.0):
                    recovered_t = best_t
            if recovered_t is not None:
                pairs[i] = (cap_i, int(recovered_t))
                ns[i] = int(recovered_t)
                rejections.append(
                    {
                        "cap_idx": int(cap_i),
                        "n": int(n),
                        "recovered_n": int(recovered_t),
                        "rule": "digit_count_truncation_recovered",
                        "reason": (
                            f"cap_idx={cap_i} n={n} digits={dlen} < neighbour_mode="
                            f"{mode_len}; recovered n={recovered_t} near med_neigh="
                            f"{med_n:.0f}"
                        ),
                    }
                )
            elif abs(float(n) - med_n) > max(50.0, 0.05 * abs(med_n)):
                # UNRESOLVED truncation — never emit short value as a counter.
                keep_idx.discard(i)
                rejections.append(
                    {
                        "cap_idx": int(cap_i),
                        "n": int(n),
                        "rule": "digit_count_truncation_unresolved",
                        "reason": (
                            f"cap_idx={cap_i} n={n} digits={dlen} < neighbour_mode="
                            f"{mode_len} (count={mode_c}) med_neigh={med_n:.0f} — "
                            f"UNRESOLVED truncation misread"
                        ),
                    }
                )

    stage = [pairs[i] for i in range(len(pairs)) if i in keep_idx]
    if len(stage) < 3:
        stage = list(pairs)

    # --- Pass B: RLE SPIKES only (plateau-safe) ---
    # Parent 2→7 class often plateaus 1–2 capture frames (2917,2917).
    # Collapse runs: spike if (b-a) >= 4 and c < b (jumped up, then any drop).
    # Bank-swap 100,101,100: b-a=1 < 4 → kept (real revisit still RATE_FAIL).
    # Healthy +2 skip: a,a+2,a+3 → c>b → kept.
    #
    # Do NOT apply symmetric troughs here. On noisy startup CSVs, patterns like
    # OCR_spike, real_n, OCR_spike (85→66→87) made trough delete the REAL 66
    # between two misreads (1029 false troughs on /tmp/ctr_startup). Spike-only
    # multi-pass removes 2917-class; MAD catches residual outliers.
    changed = True
    while changed and len(stage) >= 3:
        changed = False
        ns_s = [n for _, n in stage]
        runs = _rle_runs(ns_s)
        if len(runs) < 3:
            break
        run_stage_idxs: list[list[int]] = []
        si = 0
        for _v, cnt in runs:
            run_stage_idxs.append(list(range(si, si + cnt)))
            si += cnt
        drop_stage: set[int] = set()
        vals = [v for v, _ in runs]
        rewrite_stage: dict[int, int] = {}
        for ri in range(1, len(vals) - 1):
            a, b, c = vals[ri - 1], vals[ri], vals[ri + 1]
            if not ((b - a) >= 4 and c < b):
                continue
            # Recover when neighbours bracket a short advance (flash 2759→2780→2761
            # is really 2760). Prefer rewrite over drop so we do not invent a hole.
            recovered_b = None
            if c > a and (c - a) <= 3:
                recovered_b = a + 1 if c >= a + 1 else c
                if recovered_b < a or recovered_b > c:
                    recovered_b = (a + c) // 2
            if recovered_b is not None and recovered_b != b:
                for sj in run_stage_idxs[ri]:
                    cap_j, n_j = stage[sj]
                    rewrite_stage[sj] = int(recovered_b)
                    rejections.append(
                        {
                            "cap_idx": int(cap_j),
                            "n": int(n_j),
                            "recovered_n": int(recovered_b),
                            "rule": "rle_spike_recovered",
                            "reason": (
                                f"cap_idx={cap_j} n={n_j} RLE {a}->{b}->{c} → "
                                f"recovered {recovered_b} (flash/OCR spike, not drop)"
                            ),
                        }
                    )
            else:
                for sj in run_stage_idxs[ri]:
                    drop_stage.add(sj)
                    cap_j, n_j = stage[sj]
                    rejections.append(
                        {
                            "cap_idx": int(cap_j),
                            "n": int(n_j),
                            "rule": "rle_spike_up_then_drop",
                            "reason": (
                                f"cap_idx={cap_j} n={n_j} RLE neighbours "
                                f"{a}->{b}->{c}: rle_spike_up_then_drop — OCR spike "
                                f"(e.g. trailing 2→7), not a real counter state"
                            ),
                        }
                    )
        if rewrite_stage:
            stage = [
                ((stage[k][0], rewrite_stage[k]) if k in rewrite_stage else stage[k])
                for k in range(len(stage))
                if k not in drop_stage
            ]
            changed = True
        elif drop_stage:
            stage = [p for k, p in enumerate(stage) if k not in drop_stage]
            changed = True

    if len(stage) < 3:
        stage = [pairs[i] for i in range(len(pairs)) if i in keep_idx] or list(pairs)

    # NOTE: do NOT strip all backward steps. Bank-swap ping-pong (100,101,100,101)
    # is exactly the real revisit RATE_FAIL we must still catch. Large backward
    # OCR jumps are already removed as spikes/troughs/digit-count.

    # --- Pass C: MAD gate (radius NOT widened — parent forbid) ---
    # Growing counters legally mix 1/2/3/4 digit lengths. Never drop shorter
    # lengths globally (that destroyed startup n=1..99 on /tmp/ctr_startup).
    # Only strip residual EXTRA-digit samples (mode_len+1) still in stage.
    ns2 = [n for _, n in stage]
    lengths = Counter(len(str(n)) for n in ns2)
    mode_len, mode_c = lengths.most_common(1)[0]
    by_len: list[tuple[int, int]] = []
    if mode_c >= max(3, len(ns2) // 3):
        for i, n in stage:
            if len(str(n)) > mode_len:
                if not any(r["cap_idx"] == i and r["n"] == n for r in rejections):
                    rejections.append(
                        {
                            "cap_idx": int(i),
                            "n": int(n),
                            "rule": "global_digit_extra",
                            "reason": (
                                f"cap_idx={i} n={n} digits={len(str(n))} > "
                                f"global_mode={mode_len} — residual extra digit"
                            ),
                        }
                    )
            else:
                by_len.append((i, n))
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
    src_ok = _is_caller_prov(source_fps_src)
    cap_ok = _is_cap_auth_prov(capture_fps_src)
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


def _write_counters_csv(path: str | Path, rows: list[dict[str, Any]]) -> None:
    """Write idx,n,n_src,status,tier,mean_luma,contrast_dy for export/re-score."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as f:
        f.write("idx,n,n_src,status,tier,mean_luma,contrast_dy,raw\n")
        for i, r in enumerate(rows):
            idx = int(r.get("idx", i))
            n = r.get("n")
            n_s = "" if n is None else str(int(n))
            n_src = str(r.get("n_src") or "")
            st = str(r.get("status") or "")
            tier = r.get("tier")
            tier_s = "" if tier is None else str(int(tier))
            ml = r.get("mean_luma")
            ml_s = "" if ml is None else str(ml)
            dy = r.get("contrast_dy")
            dy_s = "" if dy is None else str(dy)
            raw = str(r.get("raw") or "").replace("\n", " ").replace(",", ";")
            f.write(f"{idx},{n_s},{n_src},{st},{tier_s},{ml_s},{dy_s},{raw}\n")


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
    pts_by_idx: dict[int, float] | None = None,
    progress: bool = False,
    jobs: int = 1,
    ocr_only: bool = False,
    export_counters_csv: str | Path | None = None,
) -> dict[str, Any]:
    """Score a capture burst. See module docstring for verdicts.

    jobs>1: ProcessPoolExecutor over read_frame (tesseract-bound).
    ocr_only: skip colour/structure (glass ledger path).
    """
    results: list[dict[str, Any]] = []
    n_jobs = max(1, int(jobs))
    if n_jobs == 1 or len(frames) < 4:
        for i, path in enumerate(frames):
            r = read_frame(path, force_ocr=False, ocr_only=ocr_only)
            r["idx"] = i
            results.append(r)
            if progress and (i + 1) % 25 == 0:
                print(f"  ...scored {i + 1}/{len(frames)}", file=sys.stderr)
    else:
        # Parallel OCR — each worker is a full process (tesseract is not
        # thread-friendly). Order preserved via map.
        from concurrent.futures import ProcessPoolExecutor

        work = [(p, False, ocr_only) for p in frames]
        # chunksize keeps IPC reasonable on 2700-frame sets
        chunk = max(1, len(work) // (n_jobs * 4))
        with ProcessPoolExecutor(max_workers=n_jobs) as ex:
            # map preserves order
            for i, r in enumerate(ex.map(_read_frame_job, work, chunksize=chunk)):
                r = dict(r)
                r["idx"] = i
                results.append(r)
                if progress and (i + 1) % 50 == 0:
                    print(f"  ...scored {i + 1}/{len(frames)}", file=sys.stderr)
    if export_counters_csv:
        _write_counters_csv(export_counters_csv, results)

    warmup_n = 0
    usable: list[dict[str, Any]] = []
    for r in results:
        if r["status"] == "warmup":
            warmup_n += 1
            continue
        # Leading grabber junk that is non-uniform but still pre-picture.
        # measured ok OR low-contrast unreadable still counts as "got picture".
        if r["idx"] < warmup_skip and r.get("status") not in (
            "ok",
            "ok_low_confidence",
            "unreadable_low_contrast",
        ):
            warmup_n += 1
            continue
        usable.append(r)

    # Counter provenance (ERROR 17 class for n): only measured values enter
    # rate/revisit/plateau. low_confidence and UNREADABLE never mint revisits.
    ok_reads = [
        r
        for r in usable
        if r.get("n") is not None
        and r.get("status") in ("ok", "ok_low_confidence")
    ]
    measured_reads = [
        r
        for r in ok_reads
        if str(r.get("n_src") or "") == COUNTER_SRC_MEASURED
        or (
            # back-compat: tier-9+ TREK without n_src field
            not r.get("n_src")
            and int(r.get("tier") or 0) >= 9
            and "field_inv" not in str(r.get("raw") or "")
        )
    ]
    low_conf_reads = [
        r
        for r in ok_reads
        if str(r.get("n_src") or "") == COUNTER_SRC_LOW_CONF
        or r.get("status") == "ok_low_confidence"
    ]
    unreadable_lc = [
        r
        for r in usable
        if r.get("status") == "unreadable_low_contrast" or r.get("low_contrast")
    ]
    overlay_present_frames = [
        r for r in usable if r.get("overlay_present") or r.get("fp") is not None
    ]
    n_overlay = len(overlay_present_frames)
    unreadable_frac = (
        (len(unreadable_lc) / n_overlay) if n_overlay > 0 else 0.0
    )
    # Rate/revisit sequence: MEASURED only. Excursion filter remains belt-and-braces.
    seq_src = measured_reads
    pairs_raw = [(int(r["idx"]), int(r["n"])) for r in seq_src]
    pairs, ocr_rejections = _filter_counter_pairs(pairs_raw)
    ns_raw = [n for _, n in pairs_raw]
    ns = [n for _, n in pairs]
    blind_frames = max(0, len(usable) - len(ok_reads) - len(unreadable_lc))

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
    magenta_hits = [
        r for r in results
        if r.get("magenta_cast") and r.get("status") != "warmup"
    ]
    blue_hits = [
        r for r in results
        if r.get("blue_cast") and r.get("status") != "warmup"
    ]
    redbar_hits = [
        r for r in results
        if r.get("red_bar_missing") and r.get("status") != "warmup"
    ]
    color_flags: list[str] = []
    if len(green_hits) >= GREEN_CAST_MIN_FRAMES:
        color_flags.append("GREEN")
    if len(magenta_hits) >= GREEN_CAST_MIN_FRAMES:
        color_flags.append("MAGENTA")
    if len(blue_hits) >= GREEN_CAST_MIN_FRAMES:
        color_flags.append("BLUE")
    if len(chroma_hits) >= GREEN_CAST_MIN_FRAMES and "MAGENTA" not in color_flags:
        color_flags.append("CHROMA")
    if len(grey_hits) >= GREEN_CAST_MIN_FRAMES:
        color_flags.append("GREYSCALE")
    if len(uv_hits) >= GREEN_CAST_MIN_FRAMES:
        color_flags.append("UV_SWAP")
    if len(redbar_hits) >= GREEN_CAST_MIN_FRAMES:
        color_flags.append("RED_BAR_MISSING")
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
    loss_info = analyze_presence_loss_split(
        pairs,
        pts_by_idx=pts_by_idx,
        source_fps=source_fps,
        capture_fps=capture_fps,
        source_fps_src=source_fps_src,
        capture_fps_src=capture_fps_src,
        frames_total=len(usable),
        blind_frames=blind_frames,
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

    # Low-contrast UNREADABLE fraction: MOTION_OK is not trustworthy when a
    # large share of overlay-present frames refused the counter (parent: never
    # pass on sparse measured islands). Cap is DEFAULT_ASSUMED design (see
    # UNREADABLE_FRAC_MOTION_CAP). STRUCTURE/COLOR/RATE hard fails still win.
    unreadable_motion_demote = False
    if (
        motion == "MOTION_OK"
        and n_overlay > 0
        and unreadable_frac > UNREADABLE_FRAC_MOTION_CAP
    ):
        unreadable_motion_demote = True
        motion = "UNSCORED"
        reason = (
            f"unreadable_frac={unreadable_frac:.3f} "
            f"[measured n_unreadable_low_contrast={len(unreadable_lc)}/"
            f"n_overlay_present={n_overlay}] > "
            f"cap={UNREADABLE_FRAC_MOTION_CAP} [DEFAULT_ASSUMED] — "
            f"MOTION_OK demoted to UNSCORED (never a pass); prior={reason}"
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
        exp_v = rate_info.get("expected_ratio")
        exp_s = (
            _tag(exp_v, rate_info.get("expected_ratio_src") or "derived_src_over_cap")
            if exp_v is not None
            else "UNSCORED [UNSCORED_fps_not_authoritative]"
        )
        reason = (
            f"rate={rate_label} "
            f"unique_ratio={_tag(rate_info.get('unique_ratio'), PROVENANCE_MEASURED)} "
            f"endpoint_rate={_tag(rate_info.get('endpoint_rate'), PROVENANCE_MEASURED)} "
            f"expected={exp_s} "
            f"max_plateau={rate_info.get('max_plateau')}/"
            f"{rate_info.get('max_plateau_allowed')} [{PROVENANCE_MEASURED}] "
            f"revisits={_tag(rate_info.get('non_adjacent_revisits'), PROVENANCE_MEASURED)} "
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
        "strong_decodes": len(measured_reads),
        "measured_counter_frames": len(measured_reads),
        "low_confidence_counter_frames": len(low_conf_reads),
        "unreadable_low_contrast_frames": len(unreadable_lc),
        "overlay_present_frames": n_overlay,
        "unreadable_frac": round(unreadable_frac, 4),
        "unreadable_frac_src": PROVENANCE_MEASURED,
        "unreadable_frac_cap": UNREADABLE_FRAC_MOTION_CAP,
        "unreadable_frac_cap_src": "DEFAULT_ASSUMED",
        "unreadable_motion_demote": bool(unreadable_motion_demote),
        "low_contrast_dy_max": LOW_CONTRAST_DY_MAX,
        "low_contrast_dy_max_src": "DEFAULT_ASSUMED",
        "ns_head": ns[:10],
        "ns_tail": ns[-10:],
        "n_min": (min(ns) if ns else None),
        "n_max": (max(ns) if ns else None),
        "unique_overlay_fp": len(unique_fps),
        "green_cast_frames": len(green_hits),
        "chroma_cast_frames": len(chroma_hits),
        "magenta_cast_frames": len(magenta_hits),
        "blue_cast_frames": len(blue_hits),
        "greyscale_frames": len(grey_hits),
        "uv_swap_frames": len(uv_hits),
        "red_bar_missing_frames": len(redbar_hits),
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
        # Presence + PTS split (Gap 1) — device_skip vs grabber_drop never merged
        "loss_split_status": loss_info.get("loss_split_status"),
        "device_skip_frames": loss_info.get("device_skip_frames"),
        "grabber_drop_frames": loss_info.get("grabber_drop_frames"),
        "device_skip_events": loss_info.get("device_skip_events"),
        "grabber_drop_events": loss_info.get("grabber_drop_events"),
        "presence_hole_frames": loss_info.get("presence_hole_frames"),
        "presence_hole_events": loss_info.get("presence_hole_events"),
        "presence_holes_head": loss_info.get("presence_holes_head"),
        "resolution_floor_frac": loss_info.get("resolution_floor_frac"),
        "resolution_floor_src": loss_info.get("resolution_floor_src"),
        "resolution_floor_components": loss_info.get("resolution_floor_components"),
        "candidate_loss_frac": loss_info.get("candidate_loss_frac"),
        "steady_state_loss": loss_info.get("steady_state_loss"),
        "steady_state_reason": loss_info.get("steady_state_reason"),
        "blind_frames": loss_info.get("blind_frames"),
        "blind_frac": loss_info.get("blind_frac"),
        "blind_frac_src": loss_info.get("blind_frac_src"),
        "pts_available": loss_info.get("pts_available"),
        "pts_src": loss_info.get("pts_src"),
        "median_dt_s": loss_info.get("median_dt_s"),
        "median_dt_src": loss_info.get("median_dt_src"),
        "loss_notes": loss_info.get("loss_notes"),
        "loss_arithmetic": loss_info.get("loss_arithmetic"),
        "verdict": final,
        "reason": reason,
        "rc": rc,
        "reads": [
            {
                "f": os.path.basename(r["path"]),
                "status": r["status"],
                "n": r["n"],
                "n_src": r.get("n_src"),
                "contrast_dy": r.get("contrast_dy"),
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


def _apply_strict_fps(
    report: dict[str, Any],
    strict: bool,
    source_fps_src: str,
    capture_fps_src: str,
) -> dict[str, Any]:
    """ERROR 17: refuse scoring when load-bearing fps is DEFAULT_ASSUMED.

    When --strict-fps: if either fps is DEFAULT_ASSUMED, do not emit a green
    MOTION_OK that could be read as a rate-validated pass. Positively measured
    hard fails (STRUCTURE/COLOR/RATE/FREEZE) are preserved — never decay to 77.
    """
    report = dict(report)
    report["strict_fps"] = bool(strict)
    src_assumed = str(source_fps_src) == PROVENANCE_DEFAULT_ASSUMED
    cap_assumed = str(capture_fps_src) == PROVENANCE_DEFAULT_ASSUMED
    report["source_fps_assumed"] = src_assumed
    report["capture_fps_assumed"] = cap_assumed
    if not strict:
        return report
    if not (src_assumed or cap_assumed):
        return report
    rc = int(report.get("rc") or RC_UNSCORED)
    # Preserve positively measured failures (never decay fail → 77).
    if rc in (RC_STRUCTURE_FAIL, RC_COLOR_FAIL, RC_RATE_FAIL, RC_FREEZE):
        report["strict_fps_note"] = (
            "strict_fps: fps DEFAULT_ASSUMED but measured hard-fail rc="
            f"{rc} preserved (fail never decays to 77)"
        )
        return report
    report["verdict"] = "REFUSE_DEFAULT_ASSUMED"
    report["rc"] = RC_UNSCORED
    report["rate"] = "RATE_UNSCORED"
    prev = report.get("reason") or ""
    report["reason"] = (
        "strict_fps REFUSE: src_fps_src="
        f"{source_fps_src} cap_fps_src={capture_fps_src} — load-bearing rate "
        "inputs are DEFAULT_ASSUMED (ERROR 17); not a score. "
        + (f"prior={prev}" if prev else "")
    )
    return report


def _print_human(report: dict[str, Any], src: str) -> None:
    print(f"src={src}")
    print(
        f"frames={report['frames_total']} warmup_skipped={report['warmup_skipped']} "
        f"decodes={report['decodes']} strong={report['strong_decodes']} "
        f"measured_counter_frames={report.get('measured_counter_frames', report['strong_decodes'])} "
        f"low_confidence_counter_frames={report.get('low_confidence_counter_frames', 0)} "
        f"unreadable_low_contrast_frames={report.get('unreadable_low_contrast_frames', 0)} "
        f"overlay_present_frames={report.get('overlay_present_frames')} "
        f"unreadable_frac={_tag(report.get('unreadable_frac'), report.get('unreadable_frac_src') or PROVENANCE_MEASURED)} "
        f"unreadable_frac_cap={_tag(report.get('unreadable_frac_cap'), report.get('unreadable_frac_cap_src') or 'DEFAULT_ASSUMED')} "
        f"unique_fp={report['unique_overlay_fp']} "
        f"green_cast_frames={_tag(report['green_cast_frames'], PROVENANCE_MEASURED)} "
        f"chroma_cast_frames={_tag(report.get('chroma_cast_frames', 0), PROVENANCE_MEASURED)} "
        f"magenta_cast_frames={_tag(report.get('magenta_cast_frames', 0), PROVENANCE_MEASURED)} "
        f"blue_cast_frames={_tag(report.get('blue_cast_frames', 0), PROVENANCE_MEASURED)} "
        f"greyscale_frames={_tag(report.get('greyscale_frames', 0), PROVENANCE_MEASURED)} "
        f"uv_swap_frames={_tag(report.get('uv_swap_frames', 0), PROVENANCE_MEASURED)} "
        f"red_bar_missing_frames={_tag(report.get('red_bar_missing_frames', 0), PROVENANCE_MEASURED)} "
        f"vdup_frames={report.get('vertical_dup_frames', 0)} "
        f"wrap_frames={report.get('horiz_wrap_frames', 0)}"
    )
    if report["n_min"] is not None:
        print(
            f"counter n_min={_tag(report['n_min'], PROVENANCE_MEASURED)} "
            f"n_max={_tag(report['n_max'], PROVENANCE_MEASURED)} "
            f"head={report['ns_head']} tail={report['ns_tail']} "
            f"(only n_src=measured enter rate/revisit; "
            f"low_confidence/UNREADABLE excluded)"
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
        exp_v = report.get("expected_ratio")
        exp_src = report.get("expected_ratio_src") or (
            "derived_src_over_cap" if auth else "UNSCORED_fps_not_authoritative"
        )
        exp_s = (
            _tag(exp_v, exp_src)
            if exp_v is not None
            else "UNSCORED [UNSCORED_fps_not_authoritative]"
        )
        print(
            f"rate_metrics "
            f"unique_ratio={_tag(report.get('unique_ratio'), PROVENANCE_MEASURED)} "
            f"endpoint_rate={_tag(report.get('endpoint_rate'), PROVENANCE_MEASURED)} "
            f"expected={exp_s} "
            f"(unique_ratio and endpoint_rate comparable to expected only when "
            f"fps_authoritative) "
            f"max_plateau={report.get('max_plateau')}/"
            f"{report.get('max_plateau_allowed')} [{PROVENANCE_MEASURED}]{pw_s} "
            f"plateau_hist={report.get('plateau_hist')} "
            f"revisits={_tag(report.get('non_adjacent_revisits'), PROVENANCE_MEASURED)} "
            f"ctr_span={_tag(report.get('ctr_span'), PROVENANCE_MEASURED)} "
            f"cap_span={_tag(report.get('cap_span'), PROVENANCE_MEASURED)} "
            f"src_fps={_tag(report.get('source_fps'), report.get('source_fps_src', PROVENANCE_DEFAULT_ASSUMED))} "
            f"cap_fps={_tag(report.get('capture_fps'), report.get('capture_fps_src', PROVENANCE_DEFAULT_ASSUMED))} "
            f"{auth_s} "
            f"NOTE_ERROR17=DEFAULT_ASSUMED_src_fps_is_not_a_measurement"
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
    # Presence holes + PTS device/grabber split (Gap 1). Loss is not main rc.
    if report.get("loss_split_status") is not None or report.get("presence_hole_frames") is not None:
        print(
            f"loss_metrics status={report.get('loss_split_status')} "
            f"steady_state_loss={report.get('steady_state_loss')} "
            f"presence_hole_frames={report.get('presence_hole_frames')} "
            f"presence_hole_events={report.get('presence_hole_events')} "
            f"device_skip_frames={report.get('device_skip_frames')} "
            f"grabber_drop_frames={report.get('grabber_drop_frames')} "
            f"device_skip_events={report.get('device_skip_events')} "
            f"grabber_drop_events={report.get('grabber_drop_events')} "
            f"candidate_loss_frac={report.get('candidate_loss_frac')} "
            f"resolution_floor_frac={report.get('resolution_floor_frac')} "
            f"floor_src={report.get('resolution_floor_src')} "
            f"floor_components={report.get('resolution_floor_components')} "
            f"blind_frames={report.get('blind_frames')} "
            f"blind_frac={report.get('blind_frac')} "
            f"blind_src={report.get('blind_frac_src')} "
            f"pts_available={report.get('pts_available')} "
            f"pts_src={report.get('pts_src')} "
            f"median_dt_s={report.get('median_dt_s')} "
            f"median_dt_src={report.get('median_dt_src')}"
        )
        if report.get("steady_state_reason"):
            print(f"steady_state_reason={report.get('steady_state_reason')}")
        lnotes = report.get("loss_notes") or []
        if lnotes:
            print(f"loss_notes={' | '.join(str(n) for n in lnotes)}")
        if report.get("loss_arithmetic"):
            print(f"loss_arithmetic={report.get('loss_arithmetic')}")
        holes = report.get("presence_holes_head") or []
        for h in holes[:8]:
            print(
                f"  hole n={h.get('n0')}->{h.get('n1')} missing={h.get('hole')} "
                f"class={h.get('class')} dt_s={h.get('dt_s')} "
                f"dt_ratio={h.get('dt_ratio')}"
            )
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

    # Magenta cast (luma parked in chroma planes) — explicit MAGENTA, not green-only.
    magenta = np.zeros((100, 100, 3), dtype=np.uint8)
    magenta[:, :] = (210, 40, 240)
    gc_m = green_cast_metrics(magenta)
    assert gc_m["chroma_cast"] is True and gc_m["channel_spread"] >= CHROMA_SPREAD_FAIL, gc_m
    assert gc_m["magenta_cast"] is True, gc_m
    assert "MAGENTA" in (gc_m.get("color_fail_kinds") or []), gc_m
    assert gc_m["color_fail"] is True, gc_m
    assert gc_m["green_cast"] is False, gc_m  # must not need green to fail

    # White flash + red bar → COLOR_OK path (red_bar_ok).
    flash_ok = np.full((200, 320, 3), 230, dtype=np.uint8)
    flash_ok[40:60, 40:120] = (10, 10, 10)  # FLASH text
    flash_ok[140:170, 80:240] = (220, 30, 30)  # red bar
    gc_rb = green_cast_metrics(flash_ok)
    assert gc_rb["flash_field"] is True, gc_rb
    assert gc_rb["red_bar_ok"] is True, gc_rb
    assert gc_rb["red_bar_missing"] is False, gc_rb
    assert gc_rb["color_fail"] is False, gc_rb

    # White flash WITHOUT red bar → RED_BAR_MISSING (B7 hole closed).
    flash_bad = np.full((200, 320, 3), 230, dtype=np.uint8)
    flash_bad[40:60, 40:120] = (10, 10, 10)
    gc_rb2 = green_cast_metrics(flash_bad)
    assert gc_rb2["flash_field"] is True, gc_rb2
    assert gc_rb2["red_bar_missing"] is True, gc_rb2
    assert gc_rb2["color_fail"] is True, gc_rb2
    assert "RED_BAR_MISSING" in (gc_rb2.get("color_fail_kinds") or []), gc_rb2

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

        # Blue field → COLOR_FAIL via channel spread (B7 hole was green-only).
        bdir = tdp / "blue"
        bdir.mkdir()
        blu = np.zeros((120, 160, 3), dtype=np.uint8)
        blu[:, :] = (30, 40, 210)
        for i in range(8):
            Image.fromarray(blu).save(bdir / f"f_{i:03d}.png")
        rep_bl = score_burst(
            sorted(str(p) for p in bdir.glob("f_*.png")),
            warmup_skip=0,
            min_reads=3,
        )
        assert rep_bl["chroma_cast_frames"] >= GREEN_CAST_MIN_FRAMES, rep_bl
        assert rep_bl["rc"] in (RC_COLOR_FAIL, RC_STRUCTURE_FAIL), rep_bl
        assert rep_bl["rc"] != RC_UNSCORED, rep_bl

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

    # --- Gap 1: presence holes + PTS device vs grabber split ---
    # Build a long healthy 24-on-30 sequence then inject known holes.
    base_ns: list[int] = []
    sn = 100
    for cap_i in range(400):
        if cap_i > 0 and (cap_i % 5) != 0:
            sn += 1
        base_ns.append(sn)
    # Inject two holes at known RLE transitions by editing values after idx 50:
    # hole A: skip one source frame (device) — we'll give normal PTS gap
    # hole B: skip one source frame with 2× PTS gap (grabber)
    pairs_pres = list(enumerate(base_ns))
    # Force n sequence to jump +2 at two RLE boundaries after filter.
    # Find first two places where n advances by 1 and bump the later value.
    forced: list[tuple[int, int]] = []
    jumps_done = 0
    prev_n = None
    for i, n in pairs_pres:
        nn = n
        if prev_n is not None and n == prev_n + 1 and jumps_done < 2 and i > 80:
            nn = n + 1  # create hole of 1 between prev and nn
            jumps_done += 1
        # Keep subsequent values consistent after each forced bump
        if jumps_done >= 1 and prev_n is not None and n > prev_n:
            # once we've forced, shift all later by total forced count so far
            pass
        forced.append((i, nn if jumps_done == 0 else n + jumps_done))
        prev_n = forced[-1][1]

    # Rebuild cleaner controlled pairs: contiguous then two holes.
    ctrl: list[tuple[int, int]] = []
    sn = 500
    hole_at_cap = {120: 1, 200: 1}  # cap_idx → hole size before this sample's n
    for i in range(360):
        if i in hole_at_cap:
            sn += 1 + hole_at_cap[i]  # advance past missing n
        elif i > 0 and (i % 5) != 0:
            sn += 1
        ctrl.append((i, sn))

    # No PTS → LOSS_UNSCORED + floor; never a device-loss percent claim.
    loss_nopts = analyze_presence_loss_split(
        ctrl,
        pts_by_idx=None,
        source_fps=24.0,
        capture_fps=29.9068,
        source_fps_src=PROVENANCE_CALLER,
        capture_fps_src=PROVENANCE_MEASURED,
        frames_total=360,
        blind_frames=40,
    )
    assert loss_nopts["loss_split_status"] == "LOSS_UNSCORED", loss_nopts
    assert loss_nopts["device_skip_frames"] is None, loss_nopts
    assert loss_nopts["presence_hole_frames"] is not None
    assert loss_nopts["presence_hole_frames"] >= 2, loss_nopts
    assert loss_nopts["steady_state_loss"] == "UNSCORED", loss_nopts
    assert loss_nopts["resolution_floor_frac"] is not None
    assert loss_nopts["resolution_floor_frac"] >= 0.01, loss_nopts
    assert "no_pts" in " ".join(loss_nopts.get("loss_notes") or []).lower() or (
        "NO_PTS" in " ".join(loss_nopts.get("loss_notes") or [])
    ), loss_nopts

    # PTS: normal gap at first hole → DEVICE_SKIP; 2× gap at second → GRABBER_DROP.
    pts_map: dict[int, float] = {}
    t = 0.0
    dt = 1.0 / 30.0
    for i in range(360):
        if i == 200:
            t += dt  # extra interval → ~2× median between samples around hole
        pts_map[i] = t
        t += dt
    loss_pts = analyze_presence_loss_split(
        ctrl,
        pts_by_idx=pts_map,
        source_fps=24.0,
        capture_fps=30.0,
        source_fps_src=PROVENANCE_CALLER,
        capture_fps_src=PROVENANCE_CALLER,
        frames_total=360,
        blind_frames=5,
    )
    assert loss_pts["loss_split_status"] == "LOSS_SPLIT_OK", loss_pts
    assert loss_pts["device_skip_frames"] is not None
    assert loss_pts["grabber_drop_frames"] is not None
    assert int(loss_pts["device_skip_frames"]) >= 1, loss_pts
    assert int(loss_pts["grabber_drop_frames"]) >= 1, loss_pts
    classes = {h.get("class") for h in (loss_pts.get("presence_holes_head") or [])}
    assert "DEVICE_SKIP" in classes, loss_pts
    assert "GRABBER_DROP" in classes, loss_pts
    # Separate counters exist (may equal numerically; must not be a single merged field)
    assert "device_skip_frames" in loss_pts and "grabber_drop_frames" in loss_pts
    assert int(loss_pts["device_skip_frames"]) + int(loss_pts["grabber_drop_frames"]) == int(
        loss_pts["presence_hole_frames"]
    ), loss_pts

    # Provenance string must be caller_supplied not bare "caller"
    assert PROVENANCE_CALLER == "caller_supplied", PROVENANCE_CALLER

    # ERROR 17 RED/GREEN: half-rate under DEFAULT_ASSUMED must NOT RATE_OK
    # (wrong score). With caller fps it must RATE_FAIL (hard measured fail).
    half = []
    n = 1000
    for i in range(120):
        half.append((i, n))
        # Advance source only every 3rd capture → unique_ratio ≈ 0.33 << 0.8 expected
        if (i % 3) == 2:
            n += 1
    ri_red = analyze_counter_rate(
        half,
        source_fps=DEFAULT_ASSUMED_SOURCE_FPS,
        capture_fps=DEFAULT_ASSUMED_CAPTURE_FPS,
        source_fps_src=PROVENANCE_DEFAULT_ASSUMED,
        capture_fps_src=PROVENANCE_DEFAULT_ASSUMED,
    )
    assert ri_red["rate"] == "RATE_UNSCORED", ri_red
    assert ri_red["rate_fail"] is False, ri_red  # refuse, not wrong RATE_OK/FAIL
    ri_grn = analyze_counter_rate(
        half,
        source_fps=24.0,
        capture_fps=30.0,
        source_fps_src=PROVENANCE_CALLER,
        capture_fps_src=PROVENANCE_CALLER,
    )
    assert ri_grn["rate"] == "RATE_FAIL", ri_grn
    assert ri_grn["rate_fail"] is True, ri_grn
    # --strict-fps preserves STRUCTURE hard-fail (never decay to 77)
    fake_fail = {"rc": RC_STRUCTURE_FAIL, "verdict": "STRUCTURE_FAIL", "reason": "x", "rate": "RATE_UNSCORED"}
    out_f = _apply_strict_fps(fake_fail, True, PROVENANCE_DEFAULT_ASSUMED, PROVENANCE_DEFAULT_ASSUMED)
    assert out_f["rc"] == RC_STRUCTURE_FAIL, out_f
    fake_ok = {"rc": RC_MOTION_OK, "verdict": "MOTION_OK", "reason": "adv", "rate": "RATE_UNSCORED"}
    out_o = _apply_strict_fps(fake_ok, True, PROVENANCE_DEFAULT_ASSUMED, PROVENANCE_CALLER)
    assert out_o["rc"] == RC_UNSCORED and out_o["verdict"] == "REFUSE_DEFAULT_ASSUMED", out_o

    # --- Low-contrast counter refuse (parent flash yellow-on-white) ---
    # Dark yellow-on-black: high dY, contrast OK.
    dark_y = np.zeros((270, 480, 3), dtype=np.uint8)
    dark_y[20:48, 12:220] = (220, 220, 40)
    b_d, roi_d, st_d = find_overlay(dark_y)
    assert st_d == "ok" and b_d is not None and roi_d is not None, (st_d, roi_d)
    cm_d = measure_counter_contrast(dark_y, roi_d, b_d)
    assert cm_d["contrast_status"] == "ok", cm_d
    assert cm_d["contrast_dy"] is not None and cm_d["contrast_dy"] > LOW_CONTRAST_DY_MAX, cm_d
    assert cm_d["low_contrast"] is False, cm_d

    # White field + yellow glyph: dY collapses → low_contrast must fire.
    flash_y = np.full((270, 480, 3), 235, dtype=np.uint8)
    flash_y[20:48, 12:220] = (230, 230, 60)  # yellow-on-white, near-zero luma delta
    b_f, roi_f, st_f = find_overlay(flash_y)
    assert st_f == "ok" and b_f is not None and roi_f is not None, (st_f, roi_f)
    cm_f = measure_counter_contrast(flash_y, roi_f, b_f)
    assert cm_f["contrast_status"] == "ok", cm_f
    assert cm_f["contrast_dy"] is not None and cm_f["contrast_dy"] < LOW_CONTRAST_DY_MAX, cm_f
    assert cm_f["low_contrast"] is True, cm_f

    # Provenance helper: low_contrast → UNREADABLE; tier-10 TREK → measured.
    assert _counter_provenance(
        n=312, tier=10, raw="TREK24 n=312", low_contrast=True, contrast_status="ok"
    )[0] == COUNTER_SRC_UNREADABLE
    assert _counter_provenance(
        n=312, tier=10, raw="TREK24 n=312", low_contrast=False, contrast_status="ok"
    )[0] == COUNTER_SRC_MEASURED
    assert _counter_provenance(
        n=322, tier=7, raw="field_inv_e1_s0.50_p7:322", low_contrast=False, contrast_status="ok"
    )[0] == COUNTER_SRC_LOW_CONF

    # read_frame on synthetic flash yellow must refuse OCR (no hallucinated n).
    with tempfile.TemporaryDirectory(prefix="hdmi_motion_lc_") as td:
        tdp = Path(td)
        fp = tdp / "flash.png"
        Image.fromarray(flash_y).save(fp)
        rf = read_frame(fp, force_ocr=True)
        assert rf["status"] == "unreadable_low_contrast", rf
        assert rf["n"] is None, rf
        assert rf["n_src"] == COUNTER_SRC_UNREADABLE, rf
        assert rf.get("low_contrast") is True, rf
        assert "low_contrast" in str(rf.get("raw") or ""), rf

        # High unreadable_frac demotes MOTION_OK → UNSCORED (never pass).
        # Build a burst where every frame is low-contrast yellow-on-white.
        lcdir = tdp / "all_lc"
        lcdir.mkdir()
        for i in range(12):
            Image.fromarray(flash_y).save(lcdir / f"f_{i:03d}.png")
        rep_lc = score_burst(
            sorted(str(p) for p in lcdir.glob("f_*.png")),
            warmup_skip=0,
            min_reads=3,
            source_fps=24.0,
            capture_fps=30.0,
            source_fps_src="caller_supplied_measured",
            capture_fps_src=PROVENANCE_CALLER,
        )
        assert rep_lc["unreadable_low_contrast_frames"] >= 8, rep_lc
        assert float(rep_lc["unreadable_frac"]) > UNREADABLE_FRAC_MOTION_CAP, rep_lc
        # No measured counters → cannot be MOTION_OK / RATE_OK pass.
        assert rep_lc["rc"] != RC_MOTION_OK, rep_lc
        assert rep_lc["verdict"] != "MOTION_OK", rep_lc

    # _tag formatting must make DEFAULT_ASSUMED unmistakable.
    assert _tag(23.976, PROVENANCE_DEFAULT_ASSUMED).endswith("[DEFAULT_ASSUMED]")
    assert "[measured]" in _tag(24.0, PROVENANCE_MEASURED)

    print("SELF_TEST_OK")
    return 0


def main(argv: list[str] | None = None) -> int:
    print(
        "DEPRECATED_FOR_DISPLAY_LOSS: use tools/glass_template_skip.py "
        "for G-fixture completeness skip scoring "
        "(this tool kept for TREK24 OCR + COLOR/STRUCTURE only)",
        file=sys.stderr,
    )
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
        "--source-fps-src",
        dest="source_fps_src",
        choices=(
            PROVENANCE_CALLER,
            PROVENANCE_CALLER_MEASURED,
            PROVENANCE_DEFAULT_ASSUMED,
            PROVENANCE_MEASURED,
            PROVENANCE_CONTAINER,
        ),
        default=None,
        help=(
            "provenance tag for --source-fps. Use caller_supplied_measured when "
            "the rate was read from PMS frameRate= or an ffmpeg banner (ERROR 17). "
            "Default: caller_supplied if --source-fps given, else DEFAULT_ASSUMED."
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
            "structural OCR filter + rate/skip/startup/presence. Used to prove "
            "filter on parent caches (e.g. /tmp/ctr480.csv) without re-tesseract."
        ),
    )
    ap.add_argument(
        "--pts-csv",
        default=None,
        help=(
            "per-frame presentation timestamps (idx,pts_s CSV or one float pts "
            "per line from ffprobe). REQUIRED to split DEVICE_SKIP vs GRABBER_DROP. "
            "Without PTS: loss_split_status=LOSS_UNSCORED and steady_state_loss "
            "is BELOW RESOLUTION FLOOR (never a hedged device-loss percent)."
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
    ap.add_argument(
        "--strict-fps",
        action="store_true",
        help=(
            "REFUSE to score (rc=77, verdict REFUSE_DEFAULT_ASSUMED) when src_fps "
            "or cap_fps is DEFAULT_ASSUMED. Load-bearing rate/skip/loss must not "
            "silently run on a guess (ERROR 17). Default off: motion/color/structure "
            "still score; rate stays RATE_UNSCORED."
        ),
    )
    ap.add_argument(
        "--jobs",
        type=int,
        default=1,
        help=(
            "parallel OCR workers (ProcessPool). Default 1. Use 4–8 for long "
            "glass captures; 90s@30fps (~2700 PNG) should finish under wall time."
        ),
    )
    ap.add_argument(
        "--ocr-only",
        action="store_true",
        help=(
            "skip colour/structure metrics (glass identity ledger). Counter OCR "
            "+ mean_luma only. Pair with --export-counters-csv."
        ),
    )
    ap.add_argument(
        "--export-counters-csv",
        default=None,
        metavar="PATH",
        help=(
            "write idx,n,status,tier,mean_luma CSV while scoring (or with --one). "
            "Empty n for undecoded. Re-score later via --counters-csv without OCR."
        ),
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
            source_fps_src = (
                args.source_fps_src
                if args.source_fps_src is not None
                else PROVENANCE_DEFAULT_ASSUMED
            )
        else:
            source_fps = src_parsed
            source_fps_src = (
                args.source_fps_src
                if args.source_fps_src is not None
                else PROVENANCE_CALLER
            )
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

    pts_by_idx: dict[int, float] | None = None
    if args.pts_csv:
        try:
            pts_by_idx = load_pts_csv(args.pts_csv)
        except (OSError, ValueError) as e:
            print(f"ERROR: --pts-csv: {e}", file=sys.stderr)
            return RC_UNSCORED
        if not pts_by_idx:
            print(
                "WARN: --pts-csv produced zero timestamps; loss stays UNSCORED",
                file=sys.stderr,
            )
            pts_by_idx = None

    if args.counters_csv:
        try:
            pairs_raw, ctr_meta = load_counters_csv(args.counters_csv)
        except (OSError, ValueError) as e:
            print(f"ERROR: --counters-csv: {e}", file=sys.stderr)
            return RC_UNSCORED
        source_fps, source_fps_src, capture_fps, capture_fps_src, _meta = _resolve_fps(
            None
        )
        # If parent supplies wall_s + we know n_frames from CSV, measure cap_fps.
        if (
            capture_fps_src == PROVENANCE_DEFAULT_ASSUMED
            and args.capture_wall_s is not None
            and args.capture_wall_s > 0
            and ctr_meta.get("frames_total")
        ):
            n_fr = int(ctr_meta["frames_total"])
            if n_fr >= 2:
                capture_fps = (n_fr - 1) / float(args.capture_wall_s)
                capture_fps_src = PROVENANCE_MEASURED
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
            frames_total=int(ctr_meta.get("frames_total") or 0) or None,
            blind_frames=int(ctr_meta.get("blind_frames") or 0)
            if ctr_meta.get("blind_frames") is not None
            else None,
            pts_by_idx=pts_by_idx,
        )
        report["src"] = str(args.counters_csv)
        report["counters_csv_meta"] = ctr_meta
        report = _apply_strict_fps(report, args.strict_fps, source_fps_src, capture_fps_src)
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
        n_jobs = max(1, int(args.jobs))
        ocr_only = bool(args.ocr_only)
        if n_jobs == 1 or len(frames) < 4:
            for f in frames:
                rows.append(read_frame(f, force_ocr=True, ocr_only=ocr_only))
        else:
            from concurrent.futures import ProcessPoolExecutor

            work = [(f, True, ocr_only) for f in frames]
            chunk = max(1, len(work) // (n_jobs * 4))
            with ProcessPoolExecutor(max_workers=n_jobs) as ex:
                rows = list(ex.map(_read_frame_job, work, chunksize=chunk))
        for i, r in enumerate(rows):
            r["idx"] = i
            if r["status"] == "ok":
                any_ok = True
            if not args.json:
                print(
                    f"{os.path.basename(r['path'])}: status={r['status']} "
                    f"n={r['n']} n_src={r.get('n_src')} "
                    f"contrast_dy={r.get('contrast_dy')} "
                    f"tier={r.get('tier')} raw={r.get('raw')!r} "
                    f"mean={r.get('mean_luma')} green_cast={r.get('green_cast')} "
                    f"chroma_cast={r.get('chroma_cast')} "
                    f"spread={r.get('channel_spread')} "
                    f"vdup={r.get('vertical_dup')} wrap={r.get('horiz_wrap')} "
                    f"overlay={r.get('overlay_present', r.get('fp') is not None)}"
                )
        if args.export_counters_csv:
            _write_counters_csv(args.export_counters_csv, rows)
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
        source_fps_src = (
            args.source_fps_src
            if args.source_fps_src is not None
            else PROVENANCE_DEFAULT_ASSUMED
        )
    else:
        source_fps = src_parsed
        source_fps_src = (
            args.source_fps_src
            if args.source_fps_src is not None
            else PROVENANCE_CALLER
        )

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
        pts_by_idx=pts_by_idx,
        progress=args.progress,
        jobs=int(args.jobs),
        ocr_only=bool(args.ocr_only),
        export_counters_csv=args.export_counters_csv,
    )
    report["src"] = src_label
    if cap_measure_meta is not None:
        report["cap_fps_measure"] = cap_measure_meta
    report = _apply_strict_fps(report, args.strict_fps, source_fps_src, capture_fps_src)
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
