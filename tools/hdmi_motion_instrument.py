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
                   relative to source/capture FPS, or non-adjacent counter
                   revisits (stale-bank ping-pong), or DEFAULT_ASSUMED source
                   rate inconsistent with observed plateau pattern.
                   Hard fail rc=4. Monotonic advance alone is NOT sufficient
                   (pfps collapse to 10.9 on a 24.000 source still advances
                   and would pass a pure order check).
  4. FREEZE      — counter pinned with colour+structure OK. Hard fail rc=1.
  5. MOTION_OK   — counter advances at plausible source rate, no revisits,
                   colour+structure OK. Pass rc=0.
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
  known. Provenance is always printed:
    src_fps=24.000 src=caller          # caller supplied --source-fps
    src_fps=24.000 src=DEFAULT_ASSUMED # fell back to library default
  Library assets (Plex metadata frameRate="24.000" / videoFrameRate="24p")
  are genuinely 24.000 — NOT NTSC 24000/1001. PARENT ERROR 17: a printed
  23.976 default was mistaken for a measurement and published as a defect.
  Default assumed source = 24.000; default assumed capture = 30.0.
  When rate is DEFAULT_ASSUMED and the observed plateau/unique pattern is
  inconsistent with that assumption, RATE_FAIL loudly (never silent mis-score).
  Healthy 24fps-on-30-capture (parent hand measure, 105-frame burst):
    84 distinct counter states, 84 runs, max plateau 2, plateau hist {1,2},
    zero non-adjacent revisits, unique/frames = 84/105 = 0.800 = 24/30.
  Expected counter delta per capture frame ≈ source_fps/capture_fps.
  Max plateau allowed = ceil(capture_fps/source_fps)+1  (default 3).
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
CHROMA_SPREAD_FAIL = 25.0  # design bound from parent measurements
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


def _chroma_yellow_mask(rgb: np.ndarray) -> np.ndarray:
    """Stronger chroma mask for white-flash frames where plain yellow is washed out."""
    r = rgb[:, :, 0].astype(np.int16)
    g = rgb[:, :, 1].astype(np.int16)
    b = rgb[:, :, 2].astype(np.int16)
    return ((r + g) / 2 - b) > 40


def green_cast_metrics(rgb: np.ndarray) -> dict[str, Any]:
    """Colour integrity: classic green-cast + global channel-spread cast.

    Green-cast: parent c5382bee+old-daemon fingerprint (mean_rgb~72, green_frac
    ~0.97) and native-480p U,V~0 full-green fields.

    Channel spread: max(mean_R,mean_G,mean_B) - min(...). Correct lab frames are
    near-neutral (spread ~0–6). Desync that parks luma-magnitude bytes into
    chroma planes produces magenta/green global casts with spread ~64–200.
    This generalises beyond green so a magenta field cannot slip through.
    """
    if _is_uniform(rgb):
        return {
            "mean_rgb": float(rgb.mean()),
            "green_frac": 0.0,
            "green_cast": False,
            "channel_spread": 0.0,
            "channel_means": [float(rgb.mean())] * 3,
            "chroma_cast": False,
            "color_fail": False,
        }
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
    color_fail = bool(green_cast or chroma_cast)
    return {
        "mean_rgb": round(mean_rgb, 3),
        "green_frac": round(green_frac, 4),
        "green_cast": bool(green_cast),
        "channel_spread": round(channel_spread, 2),
        "channel_means": [round(m, 1) for m in means],
        "chroma_cast": bool(chroma_cast),
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
    """
    h, w = rgb.shape[:2]
    if _is_uniform(rgb):
        return None, None, "warmup"

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
    y0 = max(0, int(ys.min()) - 2)
    y1 = min(h, int(ys.max()) + 3)
    x0 = max(0, int(xs.min()) - 2)
    x1 = min(w, int(xs.max()) + 3)
    return m[y0:y1, x0:x1], (x0, y0, x1, y1), "ok"


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
    """
    if len(ns) < 3:
        return list(ns)

    # 1) Majority digit-length (3-digit TREK clips, 4-digit long soaks, ...).
    lengths = Counter(len(str(n)) for n in ns)
    mode_len, mode_c = lengths.most_common(1)[0]
    if mode_c >= max(3, len(ns) // 3):
        by_len = [n for n in ns if len(str(n)) == mode_len]
    else:
        by_len = list(ns)
    if len(by_len) < 3:
        by_len = list(ns)

    # 2) MAD gate around the median (robust to remaining strays).
    med = _median_int(by_len)
    abs_dev = sorted(abs(n - med) for n in by_len)
    mad = abs_dev[len(abs_dev) // 2] if abs_dev else 0
    # Frame counters advance slowly vs OCR jumps of thousands.
    radius = max(80, 6 * mad if mad > 0 else 80)
    filtered = [n for n in by_len if abs(n - med) <= radius]

    # 3) Sequential gate: drop points that jump > radius from a robust running level.
    if len(filtered) >= 3:
        out: list[int] = [filtered[0]]
        level = float(filtered[0])
        for n in filtered[1:]:
            if abs(n - level) <= radius * 1.5:
                out.append(n)
                # slow EMA toward accepted points
                level = 0.7 * level + 0.3 * float(n)
            # else drop as OCR spike
        filtered = out if len(out) >= 3 else filtered

    return filtered if len(filtered) >= 3 else by_len


def _filter_counter_pairs(
    pairs: list[tuple[int, int]],
) -> list[tuple[int, int]]:
    """Filter (capture_idx, n) pairs with the same outlier rules as ns-only."""
    if len(pairs) < 3:
        return list(pairs)
    ns = [n for _, n in pairs]
    lengths = Counter(len(str(n)) for n in ns)
    mode_len, mode_c = lengths.most_common(1)[0]
    if mode_c >= max(3, len(ns) // 3):
        by_len = [(i, n) for i, n in pairs if len(str(n)) == mode_len]
    else:
        by_len = list(pairs)
    if len(by_len) < 3:
        by_len = list(pairs)
    med = _median_int([n for _, n in by_len])
    abs_dev = sorted(abs(n - med) for _, n in by_len)
    mad = abs_dev[len(abs_dev) // 2] if abs_dev else 0
    radius = max(80, 6 * mad if mad > 0 else 80)
    filtered = [(i, n) for i, n in by_len if abs(n - med) <= radius]
    if len(filtered) >= 3:
        out: list[tuple[int, int]] = [filtered[0]]
        level = float(filtered[0][1])
        for i, n in filtered[1:]:
            if abs(n - level) <= radius * 1.5:
                out.append((i, n))
                level = 0.7 * level + 0.3 * float(n)
        filtered = out if len(out) >= 3 else filtered
    return filtered if len(filtered) >= 3 else by_len


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
    caller or DEFAULT_ASSUMED (ERROR 17). When DEFAULT_ASSUMED and the observed
    plateau/unique pattern is inconsistent with that assumption, RATE_FAIL
    loudly rather than silently certifying a mis-scored rate.

    Returns rate dimension RATE_OK | RATE_FAIL | RATE_UNSCORED plus metrics.
    RATE_UNSCORED means insufficient samples — not a pass and not a measured fail.
    """
    empty = {
        "rate": "RATE_UNSCORED",
        "rate_fail": False,
        "unique_ratio": None,
        "endpoint_rate": None,
        "span_rate": None,  # deprecated alias of endpoint_rate
        "expected_ratio": None,
        "max_plateau": None,
        "max_plateau_allowed": None,
        "plateau_hist": {},
        "unique_states": 0,
        "n_samples": 0,
        "non_adjacent_revisits": 0,
        "revisit_fail": False,
        "rate_reasons": [],
        "source_fps": source_fps,
        "capture_fps": capture_fps,
        "source_fps_src": source_fps_src,
        "capture_fps_src": capture_fps_src,
    }
    if source_fps <= 0 or capture_fps <= 0:
        empty["rate_reasons"] = ["invalid_fps"]
        return empty

    expected = source_fps / capture_fps
    max_plat_allowed = int(math.ceil(capture_fps / source_fps)) + 1
    empty["expected_ratio"] = round(expected, 4)
    empty["max_plateau_allowed"] = max_plat_allowed

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
    # --- Plateau gate (slow / stuck stretches) ---
    if max_plateau > max_plat_allowed:
        reasons.append(
            f"max_plateau={max_plateau}>{max_plat_allowed} "
            f"(ceil(cap/src)+1)"
        )

    # --- unique_ratio vs expected (PRIMARY comparable pair) ---
    # Parent calibration: unique_states/frames = 84/105 = 0.800 = src/cap.
    # This is the quantity legitimately compared to expected.
    # Slow crawl: too few distinct states (parent pfps 10.9 → ~0.36).
    # Bounds from good corpus (0.77–0.83) with slack; never weaken for RED.
    ratio_lo = expected * 0.60  # ~0.48 at 24/30
    ratio_hi = min(1.0, expected * 1.25 + 0.05)  # ~1.0 ceiling
    if unique_ratio < ratio_lo:
        reasons.append(
            f"unique_ratio={unique_ratio:.3f}<{ratio_lo:.3f} "
            f"(expected≈{expected:.3f})"
        )
    # unique_ratio saturates at 1.0 — cannot alone catch a 4x race.

    # --- endpoint_rate vs expected (SECOND comparable pair) ---
    # Same units as expected: counter frames advanced per capture frame.
    # Half-rate → ~0.40; double/race → >1.2. Bounds unchanged (not loosened).
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

    # --- Revisit gate (stale-bank ping-pong) ---
    # Healthy parent measure: 0. Single OCR blip after filtering is tolerated
    # once; >=2 non-adjacent revisits is a measured integrity failure.
    revisit_fail = revisits >= 2
    if revisit_fail:
        reasons.append(f"non_adjacent_revisits={revisits}>=2 (bank-swap/ping-pong)")

    # --- Assumed-rate consistency (ERROR 17 class) ---
    # When the caller did not supply source_fps, do not silently certify a rate
    # that contradicts the assumption. If the observed unique_ratio is far from
    # expected under DEFAULT_ASSUMED, hard-fail with an explicit provenance tag
    # even if other gates were soft. Prefer another common rate only as a hint.
    assumed_src = source_fps_src == PROVENANCE_DEFAULT_ASSUMED
    if assumed_src and not reasons:
        # Tighter consistency window when rate is assumed (not caller-measured).
        assume_lo = expected * 0.70  # ~0.56 at 24/30
        assume_hi = min(1.05, expected * 1.20)  # ~0.96 at 24/30
        if unique_ratio < assume_lo or unique_ratio > assume_hi:
            # Hint nearest common content rate for the operator (not auto-used).
            common = (23.976, 24.0, 25.0, 29.97, 30.0, 50.0, 59.94, 60.0)
            hint = min(common, key=lambda f: abs((f / capture_fps) - unique_ratio))
            reasons.append(
                f"assumed_src_fps_inconsistent unique_ratio={unique_ratio:.3f} "
                f"not in [{assume_lo:.3f},{assume_hi:.3f}] for "
                f"DEFAULT_ASSUMED src_fps={source_fps} "
                f"(hint_nearest_common_src≈{hint}; pass --source-fps explicitly)"
            )

    rate_fail = bool(reasons)
    return {
        "rate": "RATE_FAIL" if rate_fail else "RATE_OK",
        "rate_fail": rate_fail,
        # Comparable to expected (= src_fps/cap_fps):
        "unique_ratio": round(unique_ratio, 4),
        "endpoint_rate": round(endpoint_rate, 4),
        "expected_ratio": round(expected, 4),
        # Deprecated alias of endpoint_rate (same value); do not reinterpret.
        "span_rate": round(span_rate, 4),
        "max_plateau": int(max_plateau),
        "max_plateau_allowed": max_plat_allowed,
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
    pairs = _filter_counter_pairs(pairs_raw)
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
    color_hits = [
        r
        for r in results
        if r.get("color_fail") and r.get("status") != "warmup"
    ]
    color_fail = len(color_hits) >= GREEN_CAST_MIN_FRAMES
    if len(green_hits) >= GREEN_CAST_MIN_FRAMES and len(chroma_hits) >= GREEN_CAST_MIN_FRAMES:
        color = "GREEN+CHROMA_CAST_FAIL"
    elif len(green_hits) >= GREEN_CAST_MIN_FRAMES:
        color = "GREEN_CAST_FAIL"
    elif len(chroma_hits) >= GREEN_CAST_MIN_FRAMES:
        color = "CHROMA_CAST_FAIL"
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
        "plateau_hist": rate_info.get("plateau_hist"),
        "non_adjacent_revisits": rate_info.get("non_adjacent_revisits"),
        "cap_span": rate_info.get("cap_span"),
        "ctr_span": rate_info.get("ctr_span"),
        "source_fps": rate_info.get("source_fps"),
        "capture_fps": rate_info.get("capture_fps"),
        "source_fps_src": rate_info.get("source_fps_src"),
        "capture_fps_src": rate_info.get("capture_fps_src"),
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
        f"vdup_frames={report.get('vertical_dup_frames', 0)} "
        f"wrap_frames={report.get('horiz_wrap_frames', 0)}"
    )
    if report["n_min"] is not None:
        print(
            f"counter n_min={report['n_min']} n_max={report['n_max']} "
            f"head={report['ns_head']} tail={report['ns_tail']}"
        )
    print(
        f"motion={report['motion']} color={report['color']} "
        f"structure={report.get('structure', 'STRUCTURE_OK')} "
        f"rate={report.get('rate', 'RATE_UNSCORED')}"
    )
    if report.get("unique_ratio") is not None or report.get("source_fps") is not None:
        # Print comparable pairs together; never mix incomparable quantities.
        # unique_ratio  ≈ expected  (= src_fps/cap_fps)   — primary gate
        # endpoint_rate ≈ expected  (ctr_span/cap_span)   — secondary gate
        print(
            f"rate_metrics "
            f"unique_ratio={report.get('unique_ratio')} "
            f"endpoint_rate={report.get('endpoint_rate')} "
            f"expected={report.get('expected_ratio')} "
            f"(unique_ratio and endpoint_rate are both comparable to expected) "
            f"max_plateau={report.get('max_plateau')}/"
            f"{report.get('max_plateau_allowed')} "
            f"plateau_hist={report.get('plateau_hist')} "
            f"revisits={report.get('non_adjacent_revisits')} "
            f"ctr_span={report.get('ctr_span')} cap_span={report.get('cap_span')} "
            f"src_fps={report.get('source_fps')} "
            f"src={report.get('source_fps_src', PROVENANCE_DEFAULT_ASSUMED)} "
            f"cap_fps={report.get('capture_fps')} "
            f"cap={report.get('capture_fps_src', PROVENANCE_DEFAULT_ASSUMED)}"
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

    # Magenta cast (luma parked in chroma planes) — channel-spread, not green.
    magenta = np.zeros((100, 100, 3), dtype=np.uint8)
    magenta[:, :] = (210, 40, 240)
    gc_m = green_cast_metrics(magenta)
    assert gc_m["chroma_cast"] is True and gc_m["channel_spread"] >= CHROMA_SPREAD_FAIL, gc_m
    assert gc_m["color_fail"] is True, gc_m

    # Clean black / dark+yellow overlay is not a cast.
    gc2 = green_cast_metrics(dark)
    assert gc2["green_cast"] is False and gc2["chroma_cast"] is False, gc2

    # Neutral near-white flash is not a cast (spread small).
    flash = np.full((100, 100, 3), 220, dtype=np.uint8)
    flash[40:60, 30:70] = (10, 10, 10)  # black FLASH text
    flash[70:80, 20:80] = (200, 30, 30)  # red bar
    gc_f = green_cast_metrics(flash)
    assert gc_f["color_fail"] is False, gc_f

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

    # DEFAULT_ASSUMED on healthy 24/30 pattern still RATE_OK (labelled assumed).
    ri_assumed = analyze_counter_rate(
        list(enumerate(good_ns)),
        source_fps=DEFAULT_ASSUMED_SOURCE_FPS,
        capture_fps=DEFAULT_ASSUMED_CAPTURE_FPS,
        source_fps_src=PROVENANCE_DEFAULT_ASSUMED,
        capture_fps_src=PROVENANCE_DEFAULT_ASSUMED,
    )
    assert ri_assumed["rate"] == "RATE_OK", ri_assumed
    assert ri_assumed["source_fps_src"] == PROVENANCE_DEFAULT_ASSUMED, ri_assumed

    # DEFAULT_ASSUMED + pattern inconsistent with 24/30 → loud RATE_FAIL.
    # unique_ratio ≈ 1.0 (advance every capture) is not 24-on-30.
    full_rate_ns = [100 + i for i in range(60)]
    ri_bad_assume = analyze_counter_rate(
        list(enumerate(full_rate_ns)),
        source_fps=DEFAULT_ASSUMED_SOURCE_FPS,
        capture_fps=DEFAULT_ASSUMED_CAPTURE_FPS,
        source_fps_src=PROVENANCE_DEFAULT_ASSUMED,
        capture_fps_src=PROVENANCE_DEFAULT_ASSUMED,
    )
    assert ri_bad_assume["rate_fail"] is True, ri_bad_assume
    assert any("assumed_src_fps_inconsistent" in r for r in ri_bad_assume["rate_reasons"]), (
        ri_bad_assume
    )

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
    )
    assert ri_fast["rate_fail"] is True, ri_fast
    assert ri_fast["endpoint_rate"] is not None and ri_fast["endpoint_rate"] > 1.5, ri_fast
    # Endpoint rate on linear ramp equals full span / cap_span (not ~2/3).
    good_end = analyze_counter_rate(
        list(enumerate(good_ns)),
        source_fps=24.0,
        capture_fps=30.0,
        source_fps_src=PROVENANCE_CALLER,
    )
    assert good_end["endpoint_rate"] is not None
    assert good_end["endpoint_rate"] > 0.65, good_end  # must not be ~0.53 third-median bias
    assert abs(good_end["endpoint_rate"] - good_end["span_rate"]) < 1e-9, good_end

    # Bank-swap ping-pong: non-adjacent revisits.
    ping = []
    for i in range(30):
        ping.append(100 + (i % 2))  # 100,101,100,101,...
    ri_ping = analyze_counter_rate(
        list(enumerate(ping * 2)),
        source_fps=24.0,
        capture_fps=30.0,
        source_fps_src=PROVENANCE_CALLER,
    )
    assert ri_ping["rate_fail"] is True, ri_ping
    assert ri_ping["revisit_fail"] is True, ri_ping
    assert ri_ping["non_adjacent_revisits"] >= 2, ri_ping

    # Too few samples → RATE_UNSCORED (not a fail).
    ri_few = analyze_counter_rate(
        [(0, 1), (1, 2), (2, 3)],
        source_fps=24.0,
        capture_fps=30.0,
        source_fps_src=PROVENANCE_CALLER,
    )
    assert ri_few["rate"] == "RATE_UNSCORED" and ri_few["rate_fail"] is False, ri_few

    # Default assumed source is 24.000, never 23.976 (ERROR 17).
    assert DEFAULT_ASSUMED_SOURCE_FPS == 24.0, DEFAULT_ASSUMED_SOURCE_FPS
    assert abs(DEFAULT_ASSUMED_SOURCE_FPS - (24000.0 / 1001.0)) > 0.01

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
        type=float,
        default=None,
        help=(
            "source content frame rate (REQUIRED for authoritative rate scoring). "
            "Library 24p clips are 24.000 — NOT 23.976. If omitted, falls back to "
            f"DEFAULT_ASSUMED={DEFAULT_ASSUMED_SOURCE_FPS} and labels src=DEFAULT_ASSUMED; "
            "inconsistent plateau patterns then hard-fail rather than silent mis-score."
        ),
    )
    ap.add_argument(
        "--capture-fps",
        type=float,
        default=None,
        help=(
            "HDMI grabber capture rate for the burst. If omitted, falls back to "
            f"DEFAULT_ASSUMED={DEFAULT_ASSUMED_CAPTURE_FPS} labelled cap=DEFAULT_ASSUMED. "
            "Independent of source_fps; healthy unique_ratio ≈ source/capture."
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

    if not args.inputs:
        ap.error("provide a capture directory or PNG frames (or --self-test)")

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
    if args.source_fps is None:
        source_fps = DEFAULT_ASSUMED_SOURCE_FPS
        source_fps_src = PROVENANCE_DEFAULT_ASSUMED
    else:
        source_fps = float(args.source_fps)
        source_fps_src = PROVENANCE_CALLER
    if args.capture_fps is None:
        capture_fps = DEFAULT_ASSUMED_CAPTURE_FPS
        capture_fps_src = PROVENANCE_DEFAULT_ASSUMED
    else:
        capture_fps = float(args.capture_fps)
        capture_fps_src = PROVENANCE_CALLER

    report = score_burst(
        frames,
        warmup_skip=args.warmup_skip,
        min_reads=args.min_reads,
        source_fps=source_fps,
        capture_fps=capture_fps,
        source_fps_src=source_fps_src,
        capture_fps_src=capture_fps_src,
        progress=args.progress,
    )
    report["src"] = src_label
    if args.json:
        # Drop bulky per-frame list unless explicitly wanted — keep it, parent wants evidence.
        print(json.dumps(report, indent=2))
    else:
        _print_human(report, src_label)
    return int(report["rc"])


if __name__ == "__main__":
    sys.exit(main())
