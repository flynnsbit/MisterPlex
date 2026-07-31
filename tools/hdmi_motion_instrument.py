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
  MOTION_OK   rc=0   counter strictly advances across the burst (colour OK)
  FREEZE      rc=1   counter pinned (same n, enough confident reads); colour OK
  COLOR_FAIL  rc=2   green-cast fingerprint positively measured (hard FAIL)
  UNSCORED    rc=77  no positive failure AND no positive pass — NEVER a pass

Severity resolution (highest wins — explicit, non-negotiable)
-------------------------------------------------------------
  1. COLOR_FAIL  — any positively detected green-cast (enough frames) hard-fails
                   at rc=2, **regardless of whether the counter could be OCR'd**.
                   Colour is independent evidence; motion need not be scorable.
                   A green field often *prevents* overlay OCR (yellow-on-green),
                   so "decodes=0" and "colour broken" are correlated — colour
                   must be allowed to decide alone. (Parent RCA: native 480p
                   DECODE=624x480 full green field was flagged GREEN_CAST_FAIL
                   then wrongly reported UNSCORED rc=77; that leak is closed.)
  2. FREEZE      — counter pinned with colour OK. Hard fail rc=1.
  3. MOTION_OK   — counter advances with colour OK. Pass rc=0.
  4. UNSCORED    — no overlay/counter AND no colour verdict. Soft-skip rc=77.
                   Soft-skip is never a pass AND must never report a condition
                   we have positively measured to be a failure.

  FREEZE + green-cast → COLOR_FAIL (rc=2). Both are hard fails; colour wins
  because it is the more specific actionable RCA class (UV plane / chroma path)
  and remains visible in the report as motion=FREEZE color=GREEN_CAST_FAIL.

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
RC_UNSCORED = 77

DEFAULT_WARMUP_SKIP = 15
DEFAULT_MIN_READS = 3
# Broken c5382bee + old-daemon green-cast fingerprint (parent-measured).
# Also matches native-480p full-green fields (U,V~0): high green_frac, mid mean.
GREEN_MEAN_LO, GREEN_MEAN_HI = 55.0, 95.0
GREEN_FRAC_HARD = 0.85
# Minimum positively-flagged frames before colour alone hard-fails the burst.
GREEN_CAST_MIN_FRAMES = 3


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
    """Detect the green-cast garbage fingerprint (mean_rgb~72, green_frac~0.97)."""
    if _is_uniform(rgb):
        return {"mean_rgb": float(rgb.mean()), "green_frac": 0.0, "green_cast": False}
    pix = rgb.reshape(-1, 3).astype(np.float32)
    mean_rgb = float(pix.mean())
    gdom = (
        (pix[:, 1] > pix[:, 0] + 15)
        & (pix[:, 1] > pix[:, 2] + 15)
        & (pix[:, 1] > 40)
    )
    green_frac = float(gdom.mean())
    green_cast = (
        GREEN_MEAN_LO <= mean_rgb <= GREEN_MEAN_HI and green_frac >= GREEN_FRAC_HARD
    ) or (green_frac >= 0.90 and mean_rgb >= 40.0)
    return {
        "mean_rgb": round(mean_rgb, 3),
        "green_frac": round(green_frac, 4),
        "green_cast": bool(green_cast),
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
        }

    rgb = np.asarray(im)
    gc = green_cast_metrics(rgb)
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


def score_burst(
    frames: list[str],
    *,
    warmup_skip: int = DEFAULT_WARMUP_SKIP,
    min_reads: int = DEFAULT_MIN_READS,
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
    ns_raw = [int(r["n"]) for r in seq_src]
    ns = _filter_counter_outliers(ns_raw)

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
    color_fail = len(green_hits) >= GREEN_CAST_MIN_FRAMES
    color = "GREEN_CAST_FAIL" if color_fail else "COLOR_OK"

    motion = "UNSCORED"
    reason = ""
    if len(ns) < min_reads:
        # Secondary: overlay bitmap motion without OCR.
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

    # --- Severity resolution (see module docstring). Positive failure wins. ---
    if color_fail:
        # Colour defect alone is a hard FAIL even when motion is UNSCORED
        # (green-on-green overlay is often unreadable — that is a symptom).
        final, rc = "COLOR_FAIL", RC_COLOR_FAIL
        reason = (
            f"green_cast_frames={len(green_hits)}>={GREEN_CAST_MIN_FRAMES} "
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
        "motion": motion,
        "color": color,
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
        f"green_cast_frames={report['green_cast_frames']}"
    )
    if report["n_min"] is not None:
        print(
            f"counter n_min={report['n_min']} n_max={report['n_max']} "
            f"head={report['ns_head']} tail={report['ns_tail']}"
        )
    print(f"motion={report['motion']} color={report['color']}")
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

    # Clean black is not green-cast
    gc2 = green_cast_metrics(dark)
    assert gc2["green_cast"] is False, gc2

    # Parse tiers
    assert _parse_counter("TREK24 n=336") == (336, 10)
    assert _parse_counter("NTSC2397 n=166") == (166, 10)
    assert _parse_counter("n=42")[0] == 42
    assert _parse_counter("nope")[0] is None

    # Severity: green-cast with no overlay → COLOR_FAIL rc=2, NOT UNSCORED 77.
    with tempfile.TemporaryDirectory(prefix="hdmi_motion_st_") as td:
        tdp = Path(td)
        for i in range(8):
            arr = np.zeros((120, 160, 3), dtype=np.uint8)
            arr[:, :] = (20, 90, 15)  # full green field, no yellow overlay
            Image.fromarray(arr).save(tdp / f"f_{i:03d}.png")
        frames = sorted(str(p) for p in tdp.glob("f_*.png"))
        rep = score_burst(frames, warmup_skip=0, min_reads=3)
        assert rep["color"] == "GREEN_CAST_FAIL", rep
        assert rep["green_cast_frames"] >= GREEN_CAST_MIN_FRAMES, rep
        assert rep["motion"] == "UNSCORED", rep
        assert rep["verdict"] == "COLOR_FAIL", rep
        assert rep["rc"] == RC_COLOR_FAIL, rep

        # FREEZE + green-cast → COLOR_FAIL wins (more specific RCA); motion kept.
        # Build by painting green over identical frames (no counter → bitmap freeze
        # path may UNSCORE; force colour path still COLOR_FAIL).
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
        assert rep2["rc"] == RC_COLOR_FAIL and rep2["verdict"] == "COLOR_FAIL", rep2

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
                    f"overlay={r.get('overlay_present', r.get('fp') is not None)}"
                )
        if args.json:
            print(json.dumps(rows, indent=2))
        # Single-frame: ok decode → 0; undecoded → 77; never claim FREEZE from 1 frame.
        return RC_MOTION_OK if any_ok else RC_UNSCORED

    report = score_burst(
        frames,
        warmup_skip=args.warmup_skip,
        min_reads=args.min_reads,
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
