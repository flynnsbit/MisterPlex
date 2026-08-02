#!/usr/bin/env python3
"""Glass MOTION / JUDDER instrument — hold-duration histogram on viewed pixels.

Why this exists (parent 2026-08-01)
-----------------------------------
User: "frames being dropped" (480p). Same window: daemon drops_delta=0,
vfps locked ~23.9, yet glass A/V residual_rms ~14 ms / max excursion ~51 ms.
A/V phase (flash↔beep) is LIPSYNC — it does not measure motion smoothness.
Daemon self-report of motion health is void (ERROR 20: av-lock is a literal).
Only viewed-pixel content changes settle "dropped frames / judder."

What it measures
----------------
Given an HDMI PNG burst (MacroSilicon MS2109, typically 1920x1080 @ ~30 fps):
  1. Discard warm-up frames (default 15).
  2. Content-aware inter-frame delta (block-max luma MAD on active crop) —
     NOT md5 (ERROR 8 / ERROR 13: invalid both directions).
  3. Characterise grabber/noise floor from the low tail of deltas (and optional
     static probe). Threshold sits above noise; report both.
  4. Segment into hold runs (consecutive captures with NO content change).
  5. Emit hold-duration HISTOGRAM + p50/p95/p99/max + outlier count.
     Never a single scalar mean as the verdict.

Pre-register (printed BEFORE scoring — do not move thresholds after measure)
--------------------------------------------------------------------------
  ideal_hold_cap = capture_fps / source_fps   e.g. 30/24 = 1.25
  Healthy 24→30: mass on holds {1,2}; frac(hold >= 4) small.
  Healthy 24→60: mass on holds {2,3} (3:2); frac(hold >= 5) small.
  FAIL if outlier_count (hold >= hold_outlier_min) >= outlier_count_fail
       OR frac_ge_outlier >= frac_ge_outlier_fail
       OR max_hold >= max_hold_fail
  UNSCORED if too few samples, fps DEFAULT_ASSUMED (rate axis), content too
  dark/flat to separate noise from change, or noise floor unusable.

Red-before-green
----------------
  --self-test synthesises:
    G) perfect 24@30 hold pattern → JUDDER_OK
    R) same + N forced long holds → JUDDER_FAIL recovering N outliers
  An instrument that never detects a known defect cannot report its absence.

Provenance
----------
  Every load-bearing number: measured | caller_supplied | caller_supplied_measured
  | DEFAULT_ASSUMED. Design bounds labelled DEFAULT_ASSUMED.

Exit codes
----------
  0  JUDDER_OK
  2  JUDDER_FAIL   (measured motion defect)
  3  INSTRUMENT_FAIL (internal / physics)
  77 UNSCORED      (never a pass)
  1  usage

Usage
-----
  python3 tools/glass_motion_judder.py --self-test; echo "true rc=$?"
  python3 tools/glass_motion_judder.py /tmp/cap480b --warmup-skip 15 \\
      --source-fps 24 --source-fps-src caller_supplied_measured \\
      --capture-fps 30; echo "true rc=$?"
  python3 tools/glass_motion_judder.py /tmp/cap240fs --warmup-skip 15 \\
      --source-fps 24 --source-fps-src caller_supplied_measured \\
      --capture-fps 30 --label 240p_control; echo "true rc=$?"

true rc MUST be captured directly (cmd; echo "true rc=$?") — never through a pipe.
Does NOT touch the device. Does NOT use daemon motion/av-lock strings.

Instrument floor (BLOCKING before device attribution)
----------------------------------------------------
MS2109 + host ffmpeg inject cadence irregularity. Until a floor is measured on
a NON-device source (host-generated exact cadence, or static through the same
grabber), no device number is attributable.

  python3 tools/glass_motion_judder.py --emit-floor-fixture OUTDIR
  # PARENT (owns grabber): play OUTDIR/cadence_24.000.mp4 to HDMI feeding MS2109;
  # capture PNGs; score with --role instrument_floor. See PARENT card.

Beat / quantisation
-------------------
Always prints capture vs source period, commensurate flag, pattern period.
T_cap/sqrt(12) is REJECTED as floor when rates are commensurate (24:30=4:5).
IFI histogram in ms on distinct-content intervals (rd-review form).
"""

from __future__ import annotations

import argparse
import json
import sys
import tempfile
from collections import Counter
from pathlib import Path
from typing import Any, Optional, Sequence

import numpy as np

# Allow `python3 tools/glass_motion_judder.py` without package install
import sys as _sys
from pathlib import Path as _Path
_tools = str(_Path(__file__).resolve().parent)
if _tools not in _sys.path:
    _sys.path.insert(0, _tools)
from glass_motion_beat_ifi import (  # noqa: E402
    apply_role_attribution,
    beat_quantisation_model,
    ifi_stats_from_holds,
)

try:
    from PIL import Image
except ImportError as e:  # pragma: no cover
    raise SystemExit(f"Pillow required: {e}") from e

RC_OK = 0
RC_USAGE = 1
RC_FAIL = 2
RC_INSTRUMENT = 3
RC_UNSCORED = 77

PROVENANCE_MEASURED = "measured"
PROVENANCE_CALLER = "caller_supplied"
PROVENANCE_CALLER_MEASURED = "caller_supplied_measured"
PROVENANCE_DEFAULT = "DEFAULT_ASSUMED"

DEFAULT_WARMUP_SKIP = 15  # measured lab (MS2109 junk)
DEFAULT_SOURCE_FPS = 24.0  # DEFAULT_ASSUMED — library 24p, NOT 23.976
DEFAULT_CAPTURE_FPS = 30.0  # DEFAULT_ASSUMED — lab MJPEG
assert abs(DEFAULT_SOURCE_FPS - 24000.0 / 1001.0) > 0.01

# Design bounds (DEFAULT_ASSUMED) — pre-registered, not tuned post-hoc on user data
P_NOISE_K = 6.0  # threshold = max(ABS_FLOOR, K * noise_p99)
P_ABS_FLOOR = 2.0  # luma block-MAD units; below this is always "same"
P_MIN_PAIRS = 40  # need this many post-warmup pairs to score
P_MIN_HOLDS = 15
P_DARK_LUMA_MAX = 12.0  # mean luma; below → content may be noise-blind
P_MIN_CHANGE_FRAC = 0.08  # if fewer than 8% pairs are "change", likely blind
# Outlier definition relative to ideal hold
# hold_outlier_min = ceil(ideal_hold) + 1  (first above healthy mass; 24@60 → 4)
P_FRAC_GE_OUTLIER_FAIL = 0.05  # ≥5% of holds are outliers → FAIL
P_OUTLIER_COUNT_FAIL = 3  # or ≥3 outlier holds in a short burst
P_MAX_HOLD_FAIL_EXTRA = 3  # max_hold >= ceil(ideal)+this → FAIL (e.g. 1.25→5)


def _tag(value: Any, src: str) -> str:
    if value is None:
        return f"None [{src}]"
    if isinstance(value, float):
        return f"{value:.6g} [{src}]"
    return f"{value} [{src}]"


def _is_auth_fps(src: str) -> bool:
    return src in (
        PROVENANCE_CALLER,
        PROVENANCE_CALLER_MEASURED,
        PROVENANCE_MEASURED,
        "caller",
    )


def list_frames(src: str | Path) -> list[str]:
    p = Path(src)
    if p.is_file():
        return [str(p)]
    if not p.is_dir():
        return []
    frames = sorted(p.glob("f_*.png"))
    if not frames:
        frames = sorted(p.glob("*.png"))
    return [str(f) for f in frames]


def _active_luma(rgb: np.ndarray) -> tuple[np.ndarray, float, dict[str, Any]]:
    """Return downsampled active-crop luma + mean luma + geometry meta."""
    Y = (
        0.299 * rgb[:, :, 0].astype(np.float32)
        + 0.587 * rgb[:, :, 1].astype(np.float32)
        + 0.114 * rgb[:, :, 2].astype(np.float32)
    )
    mean_luma = float(Y.mean())
    ye = Y.mean(axis=1)
    rows = np.where(ye > 3.0)[0]
    if len(rows) < 20:
        ys = Y[::8, ::8]
        return ys, mean_luma, {
            "active": False,
            "crop": None,
            "mean_luma": mean_luma,
            "mean_luma_src": PROVENANCE_MEASURED,
        }
    y0, y1 = int(rows[0]), int(rows[-1]) + 1
    xe = Y[y0:y1].mean(axis=0)
    cols = np.where(xe > 3.0)[0]
    if len(cols) < 20:
        ys = Y[::8, ::8]
        return ys, mean_luma, {
            "active": False,
            "crop": None,
            "mean_luma": mean_luma,
            "mean_luma_src": PROVENANCE_MEASURED,
        }
    x0, x1 = int(cols[0]), int(cols[-1]) + 1
    crop = Y[y0:y1, x0:x1]
    # stride-4 downsample — motion is low-frequency vs MJPEG block noise
    ys = crop[::4, ::4]
    return ys, mean_luma, {
        "active": True,
        "crop": (x0, y0, x1, y1),
        "mean_luma": mean_luma,
        "mean_luma_src": PROVENANCE_MEASURED,
    }


def block_max_mad(a: np.ndarray, b: np.ndarray, block: int = 16) -> dict[str, float]:
    """Content-aware delta: global MAD + max block MAD (catches local motion)."""
    if a.shape != b.shape:
        # reshape-safe: compare centre crop intersection
        h = min(a.shape[0], b.shape[0])
        w = min(a.shape[1], b.shape[1])
        a = a[:h, :w]
        b = b[:h, :w]
    d = np.abs(a.astype(np.float32) - b.astype(np.float32))
    mad = float(d.mean())
    bh = bw = block
    h, w = d.shape
    peak = mad
    if h >= bh and w >= bw:
        peaks: list[float] = []
        for y in range(0, h - bh + 1, bh):
            for x in range(0, w - bw + 1, bw):
                peaks.append(float(d[y : y + bh, x : x + bw].mean()))
        if peaks:
            peak = float(max(peaks))
    return {"mad": mad, "block_max_mad": peak, "max_abs": float(d.max())}


def load_luma_series(
    frames: Sequence[str], *, warmup_skip: int
) -> tuple[list[np.ndarray], list[float], list[str], dict[str, Any]]:
    lumas: list[np.ndarray] = []
    means: list[float] = []
    names: list[str] = []
    meta: dict[str, Any] = {"warmup_skipped": 0, "load_errors": 0}
    for i, path in enumerate(frames):
        if i < warmup_skip:
            meta["warmup_skipped"] += 1
            continue
        try:
            rgb = np.asarray(Image.open(path).convert("RGB"))
        except OSError:
            meta["load_errors"] += 1
            continue
        # discard near-uniform grabber junk even after warmup index
        if int(rgb.min()) == int(rgb.max()) and float(rgb.mean()) < 15.0:
            meta["warmup_skipped"] += 1
            continue
        ys, mean_luma, _g = _active_luma(rgb)
        lumas.append(ys)
        means.append(mean_luma)
        names.append(Path(path).name)
    return lumas, means, names, meta


def pair_deltas(lumas: Sequence[np.ndarray]) -> list[dict[str, float]]:
    out: list[dict[str, float]] = []
    for i in range(1, len(lumas)):
        m = block_max_mad(lumas[i - 1], lumas[i])
        m["pair_i"] = float(i)
        out.append(m)
    return out


def noise_floor_from_deltas(
    deltas: Sequence[dict[str, float]],
) -> dict[str, Any]:
    """Estimate grabber/encode noise from NEAR-ZERO hold pairs only.

    Parent trap: using the bottom 25% of *all* deltas mixes true holds (~0)
    with small content changes (counter digit ~10–30 block_max). That inflated
    noise_p99 and set threshold above real motion → false long holds.

    Method (stated):
      1) noise sample = block_max_mad <= ABS_FLOOR (true holds / grabber idle)
      2) if fewer than 5 such pairs, fall back to values <= median/2 of all
      3) threshold = max(ABS_FLOOR, K * noise_p99)
      4) also report full distribution for audit (all_p50/p99/max)
    """
    base = {
        "noise_p50": None,
        "noise_p99": None,
        "noise_max": None,
        "noise_n": 0,
        "noise_src": PROVENANCE_DEFAULT,
        "threshold": P_ABS_FLOOR,
        "threshold_src": PROVENANCE_DEFAULT,
        "threshold_rule": (
            f"max({P_ABS_FLOOR}[DEFAULT_ASSUMED], "
            f"{P_NOISE_K}[DEFAULT_ASSUMED]*noise_p99[measured_hold_pairs])"
        ),
        "noise_sample": "hold_pairs_le_abs_floor",
    }
    if not deltas:
        return base
    vals = np.array([d["block_max_mad"] for d in deltas], dtype=np.float64)
    hold_like = vals[vals <= P_ABS_FLOOR]
    sample_how = "hold_pairs_le_abs_floor"
    if len(hold_like) < 5:
        med = float(np.median(vals))
        hold_like = vals[vals <= max(P_ABS_FLOOR, 0.5 * med)]
        sample_how = "fallback_le_half_median"
    if len(hold_like) < 3:
        # Last resort: smallest 10% — but CAP noise_p99 at ABS_FLOOR so we
        # never raise threshold above content-change scale from a bad mix.
        vals_sorted = np.sort(vals)
        n_tail = max(3, int(round(0.10 * len(vals_sorted))))
        hold_like = vals_sorted[:n_tail]
        sample_how = "fallback_bottom_10pct_capped"
        p99_raw = float(np.percentile(hold_like, 99))
        p99 = min(p99_raw, P_ABS_FLOOR)
    else:
        p99 = float(np.percentile(hold_like, 99)) if len(hold_like) >= 3 else float(hold_like.max())
    p50 = float(np.percentile(hold_like, 50))
    thr = max(P_ABS_FLOOR, P_NOISE_K * p99)
    return {
        "noise_p50": round(p50, 4),
        "noise_p99": round(p99, 4),
        "noise_max": round(float(hold_like.max()), 4),
        "noise_n": int(len(hold_like)),
        "noise_n_src": PROVENANCE_MEASURED,
        "noise_src": PROVENANCE_MEASURED,
        "noise_sample": sample_how,
        "noise_sample_src": PROVENANCE_MEASURED,
        "noise_k": P_NOISE_K,
        "noise_k_src": PROVENANCE_DEFAULT,
        "abs_floor": P_ABS_FLOOR,
        "abs_floor_src": PROVENANCE_DEFAULT,
        "threshold": round(thr, 4),
        "threshold_src": "derived_hold_pair_noise",
        "threshold_rule": base["threshold_rule"],
        "all_block_max_p50": round(float(np.percentile(vals, 50)), 4),
        "all_block_max_p99": round(float(np.percentile(vals, 99)), 4),
        "all_block_max_max": round(float(vals.max()), 4),
        "all_block_max_src": PROVENANCE_MEASURED,
        "n_hold_like_pairs": int(np.sum(vals <= P_ABS_FLOOR)),
        "n_hold_like_pairs_src": PROVENANCE_MEASURED,
    }


def holds_from_changes(is_change: Sequence[bool]) -> list[int]:
    """is_change[i] True ⇒ content changed between frame i and i+1.

    Hold length = number of capture frames showing the same content.
    """
    if not is_change:
        return []
    holds: list[int] = []
    run = 1
    for ch in is_change:
        if ch:
            holds.append(run)
            run = 1
        else:
            run += 1
    holds.append(run)
    return holds


def hold_stats(holds: Sequence[int]) -> dict[str, Any]:
    if not holds:
        return {
            "n_holds": 0,
            "hist": {},
            "p50": None,
            "p95": None,
            "p99": None,
            "max": None,
            "mean": None,
            "src": PROVENANCE_MEASURED,
        }
    arr = np.array(holds, dtype=np.float64)
    hc = Counter(int(h) for h in holds)
    return {
        "n_holds": int(len(holds)),
        "hist": {str(k): int(hc[k]) for k in sorted(hc)},
        "p50": float(np.percentile(arr, 50)),
        "p95": float(np.percentile(arr, 95)),
        "p99": float(np.percentile(arr, 99)),
        "max": int(arr.max()),
        "mean": float(arr.mean()),
        "src": PROVENANCE_MEASURED,
    }


def pre_register(
    *,
    source_fps: float,
    capture_fps: float,
    source_fps_src: str,
    capture_fps_src: str,
) -> dict[str, Any]:
    ideal = capture_fps / source_fps if source_fps > 0 else float("nan")
    ceil_ideal = int(np.ceil(ideal - 1e-9)) if ideal == ideal else 2
    floor_ideal = int(np.floor(ideal + 1e-9)) if ideal == ideal else 1
    if floor_ideal < 1:
        floor_ideal = 1
    # Outlier = first hold STRICTLY above healthy mass {floor(ideal), ceil(ideal)}.
    # Was ceil+2, which let hold=4 slip through at 24@60 (healthy {2,3}) — a pure
    # hold=4 mass (~15 fps delivered) would wrongly PASS. True-positive for ~13 fps
    # delivered (mean hold~4.6) requires outlier_min = ceil(ideal)+1 (=4 at 60/24).
    # Do NOT retune outlier_min to measured delivered rate — that normalises the defect.
    outlier_min = ceil_ideal + 1  # 24@30 → 3; 24@60 → 4
    max_fail = ceil_ideal + P_MAX_HOLD_FAIL_EXTRA  # 24@30 → 5; 24@60 → 6
    auth = _is_auth_fps(source_fps_src) and _is_auth_fps(capture_fps_src)
    return {
        "PRE_REGISTER": True,
        "source_fps": source_fps,
        "source_fps_src": source_fps_src,
        "capture_fps": capture_fps,
        "capture_fps_src": capture_fps_src,
        "fps_authoritative": auth,
        "ideal_hold_captures": round(ideal, 4),
        "ideal_hold_src": (
            "derived_cap_over_src" if auth else "UNSCORED_fps_not_authoritative"
        ),
        "healthy_hold_mass_expected": (
            f"{{{floor_ideal},{ceil_ideal}}}" if floor_ideal != ceil_ideal
            else f"{{{ceil_ideal}}}"
        ),
        "healthy_hold_min": floor_ideal,
        "healthy_hold_max": ceil_ideal,
        "healthy_hold_bounds_src": "derived_floor_ceil_ideal",
        "healthy_note": (
            "24@30 → holds 1–2; 24@60 → holds 2–3 (3:2). "
            "Outliers = abnormally long holds (repeat/judder) or missing changes."
        ),
        "hold_outlier_min": outlier_min,
        "hold_outlier_min_src": PROVENANCE_DEFAULT,
        "frac_ge_outlier_fail": P_FRAC_GE_OUTLIER_FAIL,
        "frac_ge_outlier_fail_src": PROVENANCE_DEFAULT,
        "outlier_count_fail": P_OUTLIER_COUNT_FAIL,
        "outlier_count_fail_src": PROVENANCE_DEFAULT,
        "max_hold_fail": max_fail,
        "max_hold_fail_src": PROVENANCE_DEFAULT,
        "min_pairs": P_MIN_PAIRS,
        "min_pairs_src": PROVENANCE_DEFAULT,
        "min_holds": P_MIN_HOLDS,
        "min_holds_src": PROVENANCE_DEFAULT,
        "noise_k": P_NOISE_K,
        "abs_floor": P_ABS_FLOOR,
        "PASS_if": (
            f"fps_authoritative AND n_holds>={P_MIN_HOLDS} AND "
            f"outlier_count < {P_OUTLIER_COUNT_FAIL} AND "
            f"frac_ge_outlier < {P_FRAC_GE_OUTLIER_FAIL} AND "
            f"max_hold < {max_fail}"
        ),
        "FAIL_if": (
            f"outlier_count>={P_OUTLIER_COUNT_FAIL} OR "
            f"frac_ge_outlier>={P_FRAC_GE_OUTLIER_FAIL} OR "
            f"max_hold>={max_fail}"
        ),
        "UNSCORED_if": (
            "fps not authoritative OR insufficient pairs/holds OR "
            "change_frac too low (blind) OR mean content too dark without changes"
        ),
    }


def score_holds(
    holds: Sequence[int],
    *,
    pr: dict[str, Any],
    noise: dict[str, Any],
    n_pairs: int,
    n_changes: int,
    mean_luma_med: Optional[float],
    label: str,
) -> dict[str, Any]:
    st = hold_stats(holds)
    outlier_min = int(pr["hold_outlier_min"])
    outliers = [h for h in holds if h >= outlier_min]
    n_out = len(outliers)
    frac_out = (n_out / len(holds)) if holds else None
    change_frac = (n_changes / n_pairs) if n_pairs else None

    verdict = "UNSCORED"
    rc = RC_UNSCORED
    reasons: list[str] = []

    if not pr.get("fps_authoritative"):
        reasons.append(
            "fps_not_authoritative "
            f"src={pr['source_fps_src']} cap={pr['capture_fps_src']} "
            "— refuse judder gate on DEFAULT_ASSUMED rate (ERROR 17)"
        )
    if n_pairs < int(pr["min_pairs"]):
        reasons.append(
            f"insufficient_pairs={n_pairs} < min={pr['min_pairs']} [DEFAULT_ASSUMED]"
        )
    if st["n_holds"] < int(pr["min_holds"]):
        reasons.append(
            f"insufficient_holds={st['n_holds']} < min={pr['min_holds']} [DEFAULT_ASSUMED]"
        )
    if change_frac is not None and change_frac < P_MIN_CHANGE_FRAC:
        reasons.append(
            f"change_frac={change_frac:.4f} [measured] < "
            f"{P_MIN_CHANGE_FRAC} [DEFAULT_ASSUMED] — likely blind "
            f"(threshold={noise.get('threshold')} may be above all content)"
        )
    # ERROR 13: dark content alone is not a freeze. Only refuse when we also
    # cannot see content changes (change_frac blind). TREK fixtures are mean
    # luma ~5–7 with a moving counter — scorable when threshold is honest.
    if (
        mean_luma_med is not None
        and mean_luma_med < P_DARK_LUMA_MAX
        and change_frac is not None
        and change_frac < P_MIN_CHANGE_FRAC
    ):
        reasons.append(
            f"dark_content mean_luma_med={mean_luma_med:.3f} [measured] < "
            f"{P_DARK_LUMA_MAX} [DEFAULT_ASSUMED] AND change_frac="
            f"{change_frac:.4f} < {P_MIN_CHANGE_FRAC} [DEFAULT_ASSUMED] — "
            "blind on black (ERROR 13); not a judder FAIL"
        )

    # If we already have hard UNSCORED reasons about blindness, stay UNSCORED
    blind = any(
        x.startswith("change_frac") or x.startswith("dark_content") or x.startswith("fps_")
        for x in reasons
    )
    insuff = any(x.startswith("insufficient") for x in reasons)

    if not blind and not insuff and holds:
        # Measured fail / pass
        fail = False
        # Mass outside healthy hold set (even if below outlier_min) — e.g. all hold=4
        # at 24@60 is defect vs healthy {2,3} though outlier_min=4 counts them.
        hmin = int(pr.get("healthy_hold_min") or max(1, outlier_min - 2))
        hmax = int(pr.get("healthy_hold_max") or (outlier_min - 1))
        outside = [h for h in holds if h < hmin or h > hmax]
        n_out_healthy = len(outside)
        frac_out_healthy = (n_out_healthy / len(holds)) if holds else None
        if frac_out_healthy is not None and frac_out_healthy >= float(pr["frac_ge_outlier_fail"]):
            fail = True
            reasons.append(
                f"frac_outside_healthy={frac_out_healthy:.4f} [measured] >= "
                f"{pr['frac_ge_outlier_fail']} [DEFAULT_ASSUMED] "
                f"(healthy_holds={{{hmin},{hmax}}} hist_outside_n={n_out_healthy})"
            )
        if n_out >= int(pr["outlier_count_fail"]):
            fail = True
            reasons.append(
                f"outlier_count={n_out} [measured] >= "
                f"{pr['outlier_count_fail']} [DEFAULT_ASSUMED] "
                f"(hold>={outlier_min})"
            )
        if frac_out is not None and frac_out >= float(pr["frac_ge_outlier_fail"]):
            fail = True
            reasons.append(
                f"frac_ge_outlier={frac_out:.4f} [measured] >= "
                f"{pr['frac_ge_outlier_fail']} [DEFAULT_ASSUMED]"
            )
        if st["max"] is not None and st["max"] >= int(pr["max_hold_fail"]):
            fail = True
            reasons.append(
                f"max_hold={st['max']} [measured] >= "
                f"{pr['max_hold_fail']} [DEFAULT_ASSUMED]"
            )
        if fail:
            verdict, rc = "JUDDER_FAIL", RC_FAIL
        else:
            verdict, rc = "JUDDER_OK", RC_OK
            reasons.append(
                f"hold_hist={st['hist']} p50={st['p50']} p95={st['p95']} "
                f"p99={st['p99']} max={st['max']} outliers={n_out} "
                f"frac_out={frac_out}"
            )
    else:
        verdict, rc = "UNSCORED", RC_UNSCORED
        if not reasons:
            reasons.append("unscored")

    return {
        "label": label,
        "verdict": verdict,
        "rc": rc,
        "reason": "; ".join(reasons),
        "n_pairs": n_pairs,
        "n_pairs_src": PROVENANCE_MEASURED,
        "n_changes": n_changes,
        "n_changes_src": PROVENANCE_MEASURED,
        "change_frac": None if change_frac is None else round(change_frac, 4),
        "change_frac_src": PROVENANCE_MEASURED,
        "mean_luma_med": None if mean_luma_med is None else round(mean_luma_med, 4),
        "mean_luma_med_src": PROVENANCE_MEASURED,
        "hold_n": st["n_holds"],
        "hold_hist": st["hist"],
        "hold_p50": st["p50"],
        "hold_p95": st["p95"],
        "hold_p99": st["p99"],
        "hold_max": st["max"],
        "hold_mean": st["mean"],
        "hold_stats_src": PROVENANCE_MEASURED,
        "hold_outlier_min": outlier_min,
        "hold_outlier_min_src": PROVENANCE_DEFAULT,
        "outlier_count": n_out,
        "outlier_count_src": PROVENANCE_MEASURED,
        "outlier_holds": outliers[:40],
        "frac_ge_outlier": None if frac_out is None else round(frac_out, 4),
        "frac_ge_outlier_src": PROVENANCE_MEASURED,
        "frac_outside_healthy": (
            None if not holds else round(
                sum(1 for h in holds if h < int(pr.get("healthy_hold_min") or 1)
                    or h > int(pr.get("healthy_hold_max") or 99)) / len(holds),
                4,
            )
        ),
        "frac_outside_healthy_src": PROVENANCE_MEASURED,
        "healthy_hold_min": pr.get("healthy_hold_min"),
        "healthy_hold_max": pr.get("healthy_hold_max"),
        "noise": noise,
        "pre_register": pr,
        # mean is reported but MUST NOT be the verdict alone
        "mean_note": (
            "hold_mean is informational only; verdict uses hist tail "
            "(p95/p99/max/outlier_count). mean-only is forbidden."
        ),
    }



def content_precheck(
    frames: Sequence[str],
    *,
    warmup_skip: int = DEFAULT_WARMUP_SKIP,
    threshold_override: Optional[float] = None,
) -> dict[str, Any]:
    """Cheap blindness / suitability check BEFORE full judder scoring.

    Reports change_frac + mean_luma_med after warmup. Does not emit JUDDER_OK/FAIL.
    rc: 0 SUITABLE | 77 BLIND/UNSUITABLE | 1 usage-level empty
    """
    lumas, means, names, load_meta = load_luma_series(frames, warmup_skip=warmup_skip)
    if len(lumas) < 3:
        return {
            "precheck": True,
            "suitable": False,
            "verdict": "PRECHECK_BLIND",
            "rc": RC_UNSCORED,
            "reason": f"too_few_frames_after_warmup n={len(lumas)}",
            "change_frac": None,
            "mean_luma_med": None,
            "load": load_meta,
            "n_frames_scored": len(lumas),
        }
    deltas = pair_deltas(lumas)
    noise = noise_floor_from_deltas(deltas)
    if threshold_override is not None:
        noise = dict(noise)
        noise["threshold"] = float(threshold_override)
        noise["threshold_src"] = PROVENANCE_CALLER
    thr = float(noise["threshold"])
    n_pairs = len(deltas)
    n_changes = int(sum(1 for d in deltas if d["block_max_mad"] > thr))
    change_frac = (n_changes / n_pairs) if n_pairs else 0.0
    mean_luma_med = float(np.median(means)) if means else None
    reasons = []
    suitable = True
    if n_pairs < P_MIN_PAIRS:
        suitable = False
        reasons.append(
            f"insufficient_pairs={n_pairs} < {P_MIN_PAIRS} [DEFAULT_ASSUMED]"
        )
    if change_frac < P_MIN_CHANGE_FRAC:
        suitable = False
        reasons.append(
            f"change_frac={change_frac:.4f} [measured] < "
            f"{P_MIN_CHANGE_FRAC} [DEFAULT_ASSUMED] — blind / static / black fixture "
            f"(ERROR 13 class; rk=6/rk=1 avsync blacks are unsuitable for judder)"
        )
    if (
        mean_luma_med is not None
        and mean_luma_med < P_DARK_LUMA_MAX
        and change_frac < P_MIN_CHANGE_FRAC
    ):
        suitable = False
        reasons.append(
            f"dark_content mean_luma_med={mean_luma_med:.3f} [measured] < "
            f"{P_DARK_LUMA_MAX} [DEFAULT_ASSUMED] with low change_frac"
        )
    return {
        "precheck": True,
        "suitable": suitable,
        "verdict": "PRECHECK_SUITABLE" if suitable else "PRECHECK_BLIND",
        "rc": RC_OK if suitable else RC_UNSCORED,
        "reason": "; ".join(reasons) if reasons else "content_energy_ok_for_judder",
        "n_pairs": n_pairs,
        "n_pairs_src": PROVENANCE_MEASURED,
        "n_changes": n_changes,
        "n_changes_src": PROVENANCE_MEASURED,
        "change_frac": round(change_frac, 4),
        "change_frac_src": PROVENANCE_MEASURED,
        "mean_luma_med": None if mean_luma_med is None else round(mean_luma_med, 4),
        "mean_luma_med_src": PROVENANCE_MEASURED,
        "threshold": thr,
        "threshold_src": noise.get("threshold_src"),
        "noise_p99": noise.get("noise_p99"),
        "noise_src": noise.get("noise_src"),
        "warmup_skip": warmup_skip,
        "warmup_skip_src": (
            PROVENANCE_CALLER if warmup_skip != DEFAULT_WARMUP_SKIP else PROVENANCE_DEFAULT
        ),
        "n_frames_scored": len(lumas),
        "n_frames_scored_src": PROVENANCE_MEASURED,
        "load": load_meta,
        "frame_names_head": names[:6],
        "note": (
            "PRECHECK only — not a judder PASS/FAIL. rc=77 means fixture unsuitable; "
            "rc=0 means worth full scoring. UNSCORED is never a pass."
        ),
    }


def analyze_capture(
    frames: Sequence[str],
    *,
    warmup_skip: int = DEFAULT_WARMUP_SKIP,
    source_fps: float = DEFAULT_SOURCE_FPS,
    capture_fps: float = DEFAULT_CAPTURE_FPS,
    source_fps_src: str = PROVENANCE_DEFAULT,
    capture_fps_src: str = PROVENANCE_DEFAULT,
    label: str = "",
    threshold_override: Optional[float] = None,
    role: str = "device_under_test",
    floor_baseline: Optional[dict[str, Any]] = None,
) -> dict[str, Any]:
    pr = pre_register(
        source_fps=source_fps,
        capture_fps=capture_fps,
        source_fps_src=source_fps_src,
        capture_fps_src=capture_fps_src,
    )
    lumas, means, names, load_meta = load_luma_series(frames, warmup_skip=warmup_skip)
    if len(lumas) < 3:
        return {
            "label": label or "capture",
            "verdict": "UNSCORED",
            "rc": RC_UNSCORED,
            "reason": f"too_few_frames_after_warmup n={len(lumas)}",
            "pre_register": pr,
            "load": load_meta,
        }
    deltas = pair_deltas(lumas)
    noise = noise_floor_from_deltas(deltas)
    if threshold_override is not None:
        noise = dict(noise)
        noise["threshold"] = float(threshold_override)
        noise["threshold_src"] = PROVENANCE_CALLER
        noise["threshold_override"] = True
    thr = float(noise["threshold"])
    is_change = [d["block_max_mad"] > thr for d in deltas]
    holds = holds_from_changes(is_change)
    med_luma = float(np.median(means)) if means else None
    rep = score_holds(
        holds,
        pr=pr,
        noise=noise,
        n_pairs=len(deltas),
        n_changes=int(sum(is_change)),
        mean_luma_med=med_luma,
        label=label or "capture",
    )
    rep["load"] = load_meta
    rep["n_frames_scored"] = len(lumas)
    rep["n_frames_scored_src"] = PROVENANCE_MEASURED
    rep["warmup_skip"] = warmup_skip
    rep["warmup_skip_src"] = (
        PROVENANCE_CALLER if warmup_skip != DEFAULT_WARMUP_SKIP else PROVENANCE_DEFAULT
    )
    # head of deltas for debug
    rep["delta_head"] = [
        {
            "i": int(d["pair_i"]),
            "block_max_mad": round(d["block_max_mad"], 4),
            "mad": round(d["mad"], 4),
            "change": bool(d["block_max_mad"] > thr),
        }
        for d in deltas[:12]
    ]
    rep["delta_head_src"] = PROVENANCE_MEASURED
    rep["frame_names_head"] = names[:8]
    rep["holds_head"] = list(holds[:30])
    rep["holds_head_src"] = PROVENANCE_MEASURED
    beat = beat_quantisation_model(
        source_fps=source_fps,
        capture_fps=capture_fps,
        source_fps_src=source_fps_src,
        capture_fps_src=capture_fps_src,
    )
    ifi = ifi_stats_from_holds(
        holds, capture_fps=capture_fps, source_fps=source_fps
    )
    rep["beat_quant"] = beat
    rep["ifi"] = ifi
    rep = apply_role_attribution(rep, role=role, floor_baseline=floor_baseline)
    return rep


# ---------------------------------------------------------------------------
# Synthetic ground truth
# ---------------------------------------------------------------------------

def _synth_frame(seed: int, *, w: int = 320, h: int = 180, flash: bool = False) -> np.ndarray:
    """Synthetic active picture with visible moving feature (not near-black)."""
    rng = np.random.RandomState(seed)
    if flash:
        img = np.full((h, w, 3), 230, dtype=np.uint8)
        img[20:50, 30:120] = (10, 10, 10)
        img[120:150, 60:200] = (220, 30, 30)
    else:
        img = np.zeros((h, w, 3), dtype=np.uint8)
        img[:] = (8, 10, 12)
        # moving bar + counter-like block keyed by seed
        x = 20 + (seed * 17) % (w - 80)
        img[40:80, x : x + 40] = (220, 220, 40)
        img[100:130, 40:80] = (40, 40, 200)
        # mild texture so downsampling still sees structure
        noise = rng.randint(0, 3, (h, w, 1), dtype=np.uint8)
        img = np.clip(img.astype(np.int16) + noise, 0, 255).astype(np.uint8)
    return img


def synth_sequence(
    *,
    n_source: int,
    hold_pattern: Sequence[int],
    extra_long_holds: Sequence[int] | None = None,
) -> list[np.ndarray]:
    """Build capture frames from source indices with given hold lengths.

    hold_pattern repeats across source frames. extra_long_holds replaces the
    next natural holds with forced long ones (known defect count).
    """
    frames: list[np.ndarray] = []
    pat = list(hold_pattern)
    pi = 0
    extras = list(extra_long_holds or [])
    ei = 0
    for s in range(n_source):
        if ei < len(extras):
            hold = int(extras[ei])
            ei += 1
        else:
            hold = int(pat[pi % len(pat)])
            pi += 1
        flash = (s % 20 == 7)
        img = _synth_frame(s, flash=flash)
        for _ in range(hold):
            frames.append(img.copy())
    return frames


def write_png_dir(frames: Sequence[np.ndarray], directory: Path) -> list[str]:
    directory.mkdir(parents=True, exist_ok=True)
    paths: list[str] = []
    for i, fr in enumerate(frames):
        p = directory / f"f_{i:03d}.png"
        Image.fromarray(fr).save(p)
        paths.append(str(p))
    return paths



def emit_floor_fixture(out_dir: Path, *, n_source: int = 240, fps: float = 24.0) -> dict[str, Any]:
    """Host-generated exact-cadence + static fixtures for MS2109 floor capture.

    Produces:
      OUT/png_src/f_XXXX.png  — one PNG per source frame (counter bar)
      OUT/cadence_24.000.mp4 — CFR ffmpeg encode at exact fps
      OUT/static_frame.png   — single frame for static-hold floor
      OUT/README_PARENT.txt  — exact parent capture commands

    Agent does NOT play or capture; parent owns /dev/video0.
    """
    import subprocess

    out_dir = Path(out_dir)
    png_dir = out_dir / "png_src"
    png_dir.mkdir(parents=True, exist_ok=True)
    w, h = 1280, 720
    paths = []
    for s in range(n_source):
        img = np.zeros((h, w, 3), dtype=np.uint8)
        img[:] = (12, 14, 18)
        # high-contrast moving block keyed by frame index (not dark-fixture trap)
        x = 40 + (s * 9) % (w - 200)
        img[200:360, x : x + 120] = (240, 220, 40)
        # frame index as block ticks (binary-ish bars) — content-aware change
        for bit in range(12):
            on = (s >> bit) & 1
            col = 40 + bit * 90
            img[40:140, col : col + 60] = (230, 230, 230) if on else (30, 30, 30)
        # red bar reference
        img[500:560, 100:700] = (220, 30, 30)
        p = png_dir / f"f_{s:04d}.png"
        Image.fromarray(img).save(p)
        paths.append(p)
    static_path = out_dir / "static_frame.png"
    Image.fromarray(
        np.array(Image.open(paths[n_source // 2]))
    ).save(static_path)

    mp4 = out_dir / f"cadence_{fps:.3f}.mp4"
    # Exact CFR: -framerate in, -r out, +cfr via vsync cfr
    cmd = [
        "ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
        "-framerate", str(fps),
        "-i", str(png_dir / "f_%04d.png"),
        "-c:v", "libx264", "-pix_fmt", "yuv420p",
        "-crf", "18",
        "-vf", f"fps={fps}",
        "-an",
        str(mp4),
    ]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    readme = out_dir / "README_PARENT.txt"
    readme.write_text(
        f"""PARENT — MS2109 instrument-floor capture (agent does not touch device)

Fixture: exact source cadence fps={fps} n_source={n_source}
mp4={mp4.name}  static={static_path.name}
ffmpeg_rc={proc.returncode}

PRE_REGISTER floor expectation (locked):
  Host plays exact {fps} fps CFR into display → HDMI → MS2109 → ffmpeg PNG burst.
  After warmup_skip=15, content-aware holds should cluster on healthy mass for
  capture_fps/source_fps (30/24 → holds {{1,2}}). Floor TAIL (p95/p99/max,
  outlier_count) is the instrument envelope. Device claims require device tail
  exceeding this floor by margin (see --floor-json).

A) CADENCE FLOOR (known-exact motion through grabber path)
  1. fuser -v /dev/video0   # must be free
  2. On the display that feeds the MS2109 HDMI input:
       mpv --fs --no-osc --loop=no {mp4.name}
     (or ffplay -fs {mp4.name})
  3. While playing:
       mkdir -p floor_cap_cadence
       ffmpeg -v error -f v4l2 -input_format mjpeg -video_size 1920x1080 \
         -i /dev/video0 -frames:v 120 -y floor_cap_cadence/f_%03d.png
       echo "true rc=$?"
  4. Score:
       python3 tools/glass_motion_judder.py floor_cap_cadence --role instrument_floor \
         --source-fps {fps} --source-fps-src caller_supplied_measured \
         --capture-fps 30 --capture-fps-src caller_supplied \
         --label floor_cadence_host --json > floor_cadence.json
       python3 tools/glass_motion_judder.py floor_cap_cadence --role instrument_floor \
         --source-fps {fps} --source-fps-src caller_supplied_measured \
         --capture-fps 30 --capture-fps-src caller_supplied \
         --label floor_cadence_host; echo "true rc=$?"

B) STATIC FLOOR (grabber duplication/noise only — no source motion)
  1. Pause on one frame or display static_frame.png fullscreen.
  2. mkdir -p floor_cap_static
     ffmpeg -v error -f v4l2 -input_format mjpeg -video_size 1920x1080 \
       -i /dev/video0 -frames:v 90 -y floor_cap_static/f_%03d.png
     echo "true rc=$?"
  3. Score (expect near-zero changes; UNSCORED-or-floor with holds≈all-one-run):
       python3 tools/glass_motion_judder.py floor_cap_static --role instrument_floor \
         --source-fps {fps} --source-fps-src caller_supplied_measured \
         --capture-fps 30 --capture-fps-src caller_supplied \
         --label floor_static; echo "true rc=$?"

C) DEVICE (only AFTER floor JSON exists)
       python3 tools/glass_motion_judder.py /tmp/cap480b --role device_under_test \
         --floor-json floor_cadence.json \
         --source-fps 24 --source-fps-src caller_supplied_measured \
         --capture-fps 30 --capture-fps-src caller_supplied; echo "true rc=$?"

BEAT (24.000 @ 30.000): commensurate 4:5, pattern period 5 cap frames = 166.667 ms.
Discrete IFI on grid: 33.333 and 66.667 ms (mean 41.667). Reject T_cap/sqrt(12).
"""
    )
    return {
        "out_dir": str(out_dir),
        "n_source": n_source,
        "fps": fps,
        "mp4": str(mp4),
        "mp4_exists": mp4.is_file(),
        "ffmpeg_rc": proc.returncode,
        "ffmpeg_err": (proc.stderr or "")[:500],
        "static": str(static_path),
        "readme": str(readme),
        "png_count": len(paths),
    }


def _self_test() -> int:
    print("PRE_REGISTER self-test (locked before synthetic measure):")
    pr = pre_register(
        source_fps=24.0,
        capture_fps=30.0,
        source_fps_src=PROVENANCE_CALLER_MEASURED,
        capture_fps_src=PROVENANCE_CALLER,
    )
    print(
        f"  ideal_hold={_tag(pr['ideal_hold_captures'], pr['ideal_hold_src'])} "
        f"outlier_min={_tag(pr['hold_outlier_min'], pr['hold_outlier_min_src'])} "
        f"max_fail={_tag(pr['max_hold_fail'], pr['max_hold_fail_src'])} "
        f"PASS_if={pr['PASS_if']}"
    )

    with tempfile.TemporaryDirectory(prefix="judder_st_") as td:
        tdp = Path(td)

        # --- Grabber-noise characterisation on STATIC sequence ---
        static = [_synth_frame(0) for _ in range(40)]
        # add tiny encode-like jitter on copies
        rng = np.random.RandomState(1)
        static_j = []
        for im in static:
            j = im.astype(np.int16) + rng.randint(0, 2, im.shape, dtype=np.int16)
            static_j.append(np.clip(j, 0, 255).astype(np.uint8))
        sp = write_png_dir(static_j, tdp / "static")
        # no warmup; force threshold path via analyze
        lumas, means, names, _ = load_luma_series(sp, warmup_skip=0)
        d_static = pair_deltas(lumas)
        nf = noise_floor_from_deltas(d_static)
        print(
            f"NOISE_STATIC noise_p99={_tag(nf['noise_p99'], nf['noise_src'])} "
            f"threshold={_tag(nf['threshold'], nf['threshold_src'])} "
            f"rule={nf['threshold_rule']}"
        )
        assert nf["noise_p99"] is not None and nf["noise_p99"] < 5.0, nf

        # --- GREEN: healthy 24@30 pattern holds 1,2,1,2,... ---
        # 48 source frames → ~60 captures
        healthy = synth_sequence(n_source=48, hold_pattern=(1, 2))
        hp = write_png_dir(healthy, tdp / "healthy")
        # prepend 15 black warmup frames
        warm = [np.full((180, 320, 3), 7, dtype=np.uint8) for _ in range(15)]
        wp = write_png_dir(warm + healthy, tdp / "healthy_warm")
        rep_g = analyze_capture(
            wp,
            warmup_skip=15,
            source_fps=24.0,
            capture_fps=30.0,
            source_fps_src=PROVENANCE_CALLER_MEASURED,
            capture_fps_src=PROVENANCE_CALLER,
            label="synth_healthy_24at30",
        )
        print(
            f"GREEN verdict={rep_g['verdict']} rc={rep_g['rc']} "
            f"hist={rep_g.get('hold_hist')} outliers={rep_g.get('outlier_count')} "
            f"max={rep_g.get('hold_max')} reason={rep_g.get('reason')}"
        )
        assert rep_g["rc"] == RC_OK, rep_g
        assert rep_g["verdict"] == "JUDDER_OK", rep_g
        assert rep_g.get("outlier_count", 99) == 0, rep_g

        # --- RED: inject 5 long holds (duplicated frames) ---
        # First 5 source frames get hold=6 (outlier_min at 30/24 is 4)
        n_inject = 5
        broken = synth_sequence(
            n_source=48,
            hold_pattern=(1, 2),
            extra_long_holds=[6] * n_inject,
        )
        bp = write_png_dir(warm + broken, tdp / "broken")
        rep_r = analyze_capture(
            bp,
            warmup_skip=15,
            source_fps=24.0,
            capture_fps=30.0,
            source_fps_src=PROVENANCE_CALLER_MEASURED,
            capture_fps_src=PROVENANCE_CALLER,
            label="synth_broken_5x_hold6",
        )
        print(
            f"RED   verdict={rep_r['verdict']} rc={rep_r['rc']} "
            f"hist={rep_r.get('hold_hist')} outliers={rep_r.get('outlier_count')} "
            f"max={rep_r.get('hold_max')} reason={rep_r.get('reason')}"
        )
        assert rep_r["rc"] == RC_FAIL, rep_r
        assert rep_r["verdict"] == "JUDDER_FAIL", rep_r
        # Must recover approximately N injected outliers
        got = int(rep_r.get("outlier_count") or 0)
        assert got >= n_inject, (
            f"expected >= {n_inject} outliers, got {got} hist={rep_r.get('hold_hist')}"
        )
        print(
            f"RECOVERED outlier_count={got} [measured] "
            f"injected={n_inject} [caller_supplied]  ( >= injected )"
        )

        # --- ERROR 17: DEFAULT_ASSUMED fps → UNSCORED not OK ---
        rep_u = analyze_capture(
            wp,
            warmup_skip=15,
            source_fps=24.0,
            capture_fps=30.0,
            source_fps_src=PROVENANCE_DEFAULT,
            capture_fps_src=PROVENANCE_DEFAULT,
            label="synth_assumed_fps",
        )
        assert rep_u["rc"] == RC_UNSCORED, rep_u
        print(f"UNSCORED_fps verdict={rep_u['verdict']} rc={rep_u['rc']}")

        # --- md5 trap: near-black static must not be scored as healthy motion ---
        black = [np.full((180, 320, 3), 5, dtype=np.uint8) for _ in range(60)]
        blp = write_png_dir(black, tdp / "black")
        rep_b = analyze_capture(
            blp,
            warmup_skip=0,
            source_fps=24.0,
            capture_fps=30.0,
            source_fps_src=PROVENANCE_CALLER,
            capture_fps_src=PROVENANCE_CALLER,
            label="synth_black",
        )
        assert rep_b["rc"] == RC_UNSCORED, rep_b
        print(f"BLACK_UNSCORED verdict={rep_b['verdict']} rc={rep_b['rc']}")

        # --- Beat model (24@30 commensurate) ---
        b = beat_quantisation_model(
            source_fps=24.0,
            capture_fps=30.0,
            source_fps_src=PROVENANCE_CALLER_MEASURED,
            capture_fps_src=PROVENANCE_CALLER,
        )
        assert b["commensurate"] is True, b
        assert b["continuous_quant_rms_usable"] is False, b
        assert abs(b["ideal_content_ifi_ms"] - (1000.0 / 24.0)) < 1e-6, b
        assert b["cap_over_src_ratio"] == "5/4", b
        print(
            f"BEAT commensurate={b['commensurate']} ratio={b['cap_over_src_ratio']} "
            f"pattern_ms={b['pattern_period_ms']} "
            f"discrete_ifi={b['discrete_ifi_ms_on_capture_grid']} "
            f"cont_rms_usable={b['continuous_quant_rms_usable']} "
            f"cont_rms_ms={b['continuous_quant_rms_ms']}"
        )

        # --- IFI on healthy synth: only 33.333 and 66.667 ---
        ifi_g = rep_g.get("ifi") or {}
        print(
            f"IFI_GREEN hist={ifi_g.get('ifi_ms_hist')} p50={ifi_g.get('p50')} "
            f"p95={ifi_g.get('p95')} max={ifi_g.get('max')} "
            f"frac_ge_drop={ifi_g.get('frac_ge_drop_signature')}"
        )
        assert ifi_g.get("frac_ge_drop_signature", 1) == 0.0, ifi_g
        ifi_r = rep_r.get("ifi") or {}
        print(
            f"IFI_RED hist={ifi_r.get('ifi_ms_hist')} p95={ifi_r.get('p95')} "
            f"max={ifi_r.get('max')} frac_ge_drop={ifi_r.get('frac_ge_drop_signature')}"
        )
        assert (ifi_r.get("max") or 0) >= 6 * (1000.0 / 30.0) - 0.1, ifi_r

        # --- 24@60 pre-register: ~13 fps delivered must be TRUE POSITIVE ---
        pr60 = pre_register(
            source_fps=24.0,
            capture_fps=60.0,
            source_fps_src=PROVENANCE_CALLER_MEASURED,
            capture_fps_src=PROVENANCE_MEASURED,
        )
        assert pr60["hold_outlier_min"] == 4, pr60
        assert pr60["healthy_hold_mass_expected"] in ("{2,3}", "{2, 3}"), pr60
        print(
            f"PREREG_24at60 ideal={pr60['ideal_hold_captures']} "
            f"healthy={pr60['healthy_hold_mass_expected']} "
            f"outlier_min={pr60['hold_outlier_min']} max_fail={pr60['max_hold_fail']}"
        )
        # Pure hold=4 mass (15 fps) must FAIL — was a blind spot when outlier_min=5
        holds_15fps = [4] * 40
        # score_holds is in-module
        noise_z = {"threshold": 2.0, "threshold_src": PROVENANCE_DEFAULT}
        rep_15 = score_holds(
            holds_15fps,
            pr=pr60,
            noise=noise_z,
            n_pairs=160,
            n_changes=40,
            mean_luma_med=40.0,
            label="sim_15fps_hold4",
        )
        print(
            f"SIM_15fps_hold4 verdict={rep_15['verdict']} rc={rep_15['rc']} "
            f"outliers={rep_15['outlier_count']} frac_out_h={rep_15.get('frac_outside_healthy')}"
        )
        assert rep_15["rc"] == RC_FAIL, rep_15
        # ~13 fps: mix hold 4 and 5
        holds_13 = [4] * 20 + [5] * 20
        rep_13 = score_holds(
            holds_13,
            pr=pr60,
            noise=noise_z,
            n_pairs=180,
            n_changes=40,
            mean_luma_med=40.0,
            label="sim_13fps",
        )
        print(
            f"SIM_13fps_hold45 verdict={rep_13['verdict']} rc={rep_13['rc']} "
            f"outliers={rep_13['outlier_count']} max={rep_13['hold_max']}"
        )
        assert rep_13["rc"] == RC_FAIL, rep_13
        # Healthy 24@60 {2,3}
        holds_ok60 = [2, 3] * 30
        rep_ok60 = score_holds(
            holds_ok60,
            pr=pr60,
            noise=noise_z,
            n_pairs=150,
            n_changes=60,
            mean_luma_med=40.0,
            label="sim_24at60_healthy",
        )
        print(
            f"SIM_24at60_OK verdict={rep_ok60['verdict']} rc={rep_ok60['rc']} "
            f"outliers={rep_ok60['outlier_count']}"
        )
        assert rep_ok60["rc"] == RC_OK, rep_ok60

        # --- Floor role relabel ---
        rep_f = analyze_capture(
            wp,
            warmup_skip=15,
            source_fps=24.0,
            capture_fps=30.0,
            source_fps_src=PROVENANCE_CALLER_MEASURED,
            capture_fps_src=PROVENANCE_CALLER,
            label="synth_as_floor",
            role="instrument_floor",
        )
        assert rep_f["verdict"] == "FLOOR_OK", rep_f
        assert rep_f["device_attributable"] is False, rep_f
        print(
            f"FLOOR_ROLE verdict={rep_f['verdict']} "
            f"attributable={rep_f['device_attributable']}"
        )

        # Device without floor → not attributable flag
        assert rep_g.get("device_attributable") is False, rep_g
        print(
            f"DEVICE_NO_FLOOR attributable={rep_g.get('device_attributable')} "
            f"note={rep_g.get('attribution_note')}"
        )

        # Device with floor baseline that is clean → attributable True (envelope)
        rep_d = analyze_capture(
            wp,
            warmup_skip=15,
            source_fps=24.0,
            capture_fps=30.0,
            source_fps_src=PROVENANCE_CALLER_MEASURED,
            capture_fps_src=PROVENANCE_CALLER,
            label="synth_device_with_floor",
            role="device_under_test",
            floor_baseline=rep_f,
        )
        assert rep_d.get("device_attributable") is True, rep_d
        print(
            f"DEVICE_WITH_FLOOR attributable={rep_d.get('device_attributable')} "
            f"exceeds={rep_d.get('floor_compare_exceeds')}"
        )

    print("SELF_TEST_OK glass_motion_judder")
    return RC_OK


def _print_human(rep: dict[str, Any]) -> None:
    pr = rep.get("pre_register") or {}
    print(f"label={rep.get('label')}")
    if pr:
        print(
            "PRE_REGISTER "
            f"ideal_hold={_tag(pr.get('ideal_hold_captures'), pr.get('ideal_hold_src'))} "
            f"healthy_mass={pr.get('healthy_hold_mass_expected')} "
            f"outlier_min={_tag(pr.get('hold_outlier_min'), pr.get('hold_outlier_min_src'))} "
            f"frac_ge_outlier_fail={_tag(pr.get('frac_ge_outlier_fail'), pr.get('frac_ge_outlier_fail_src'))} "
            f"outlier_count_fail={_tag(pr.get('outlier_count_fail'), pr.get('outlier_count_fail_src'))} "
            f"max_hold_fail={_tag(pr.get('max_hold_fail'), pr.get('max_hold_fail_src'))} "
            f"src_fps={_tag(pr.get('source_fps'), pr.get('source_fps_src'))} "
            f"cap_fps={_tag(pr.get('capture_fps'), pr.get('capture_fps_src'))} "
            f"fps_authoritative={pr.get('fps_authoritative')}"
        )
        print(f"PRE_REGISTER_PASS_if={pr.get('PASS_if')}")
        print(f"PRE_REGISTER_FAIL_if={pr.get('FAIL_if')}")
    noise = rep.get("noise") or {}
    if noise:
        print(
            "noise_floor "
            f"p50={_tag(noise.get('noise_p50'), noise.get('noise_src'))} "
            f"p99={_tag(noise.get('noise_p99'), noise.get('noise_src'))} "
            f"threshold={_tag(noise.get('threshold'), noise.get('threshold_src'))} "
            f"rule={noise.get('threshold_rule')} "
            f"all_p50={_tag(noise.get('all_block_max_p50'), noise.get('all_block_max_src'))} "
            f"all_p99={_tag(noise.get('all_block_max_p99'), noise.get('all_block_max_src'))} "
            f"all_max={_tag(noise.get('all_block_max_max'), noise.get('all_block_max_src'))}"
        )
    print(
        f"pairs={_tag(rep.get('n_pairs'), rep.get('n_pairs_src', PROVENANCE_MEASURED))} "
        f"changes={_tag(rep.get('n_changes'), rep.get('n_changes_src', PROVENANCE_MEASURED))} "
        f"change_frac={_tag(rep.get('change_frac'), rep.get('change_frac_src', PROVENANCE_MEASURED))} "
        f"mean_luma_med={_tag(rep.get('mean_luma_med'), rep.get('mean_luma_med_src', PROVENANCE_MEASURED))} "
        f"frames_scored={_tag(rep.get('n_frames_scored'), rep.get('n_frames_scored_src', PROVENANCE_MEASURED))} "
        f"warmup_skip={_tag(rep.get('warmup_skip'), rep.get('warmup_skip_src', PROVENANCE_DEFAULT))}"
    )
    print(
        f"hold_hist={rep.get('hold_hist')} "
        f"n_holds={_tag(rep.get('hold_n'), PROVENANCE_MEASURED)} "
        f"p50={_tag(rep.get('hold_p50'), PROVENANCE_MEASURED)} "
        f"p95={_tag(rep.get('hold_p95'), PROVENANCE_MEASURED)} "
        f"p99={_tag(rep.get('hold_p99'), PROVENANCE_MEASURED)} "
        f"max={_tag(rep.get('hold_max'), PROVENANCE_MEASURED)} "
        f"mean={_tag(rep.get('hold_mean'), PROVENANCE_MEASURED)} "
        f"NOTE={rep.get('mean_note')}"
    )
    print(
        f"outliers count={_tag(rep.get('outlier_count'), PROVENANCE_MEASURED)} "
        f"frac={_tag(rep.get('frac_ge_outlier'), PROVENANCE_MEASURED)} "
        f"min_hold_for_outlier={_tag(rep.get('hold_outlier_min'), rep.get('hold_outlier_min_src', PROVENANCE_DEFAULT))} "
        f"outlier_holds_head={rep.get('outlier_holds')}"
    )
    beat = rep.get("beat_quant") or {}
    if beat:
        print(
            "beat_quant "
            f"t_src_ms={_tag(beat.get('t_src_ms'), beat.get('t_src_ms_src'))} "
            f"t_cap_ms={_tag(beat.get('t_cap_ms'), beat.get('t_cap_ms_src'))} "
            f"ratio={beat.get('cap_over_src_ratio')} "
            f"commensurate={beat.get('commensurate')} "
            f"pattern_period_ms={beat.get('pattern_period_ms')} "
            f"pattern_frames_cap/src="
            f"{beat.get('pattern_period_capture_frames')}/"
            f"{beat.get('pattern_period_source_frames')} "
            f"ideal_ifi_ms={_tag(beat.get('ideal_content_ifi_ms'), beat.get('ideal_content_ifi_ms_src'))} "
            f"discrete_ifi_ms={beat.get('discrete_ifi_ms_on_capture_grid')} "
            f"drop_sig_ifi_ms={beat.get('drop_signature_ifi_ms')} "
            f"continuous_quant_rms_ms={_tag(beat.get('continuous_quant_rms_ms'), beat.get('continuous_quant_rms_ms_src'))} "
            f"continuous_quant_rms_usable={beat.get('continuous_quant_rms_usable')}"
        )
        print(f"quant_note={beat.get('quant_note')}")
    ifi = rep.get("ifi") or {}
    if ifi:
        print(
            "ifi_ms "
            f"hist={ifi.get('ifi_ms_hist')} "
            f"n={_tag(ifi.get('n_ifi'), PROVENANCE_MEASURED)} "
            f"p50={_tag(ifi.get('p50'), PROVENANCE_MEASURED)} "
            f"p95={_tag(ifi.get('p95'), PROVENANCE_MEASURED)} "
            f"p99={_tag(ifi.get('p99'), PROVENANCE_MEASURED)} "
            f"max={_tag(ifi.get('max'), PROVENANCE_MEASURED)} "
            f"mean={_tag(ifi.get('mean'), PROVENANCE_MEASURED)} "
            f"frac_near_ideal={_tag(ifi.get('frac_near_ideal'), PROVENANCE_MEASURED)} "
            f"frac_ge_drop_sig={_tag(ifi.get('frac_ge_drop_signature'), PROVENANCE_MEASURED)} "
            f"NOTE={ifi.get('mean_note')}"
        )
    print(
        f"role={_tag(rep.get('role'), rep.get('role_src', PROVENANCE_CALLER))} "
        f"device_attributable={rep.get('device_attributable')} "
        f"[{rep.get('device_attributable_src', PROVENANCE_DEFAULT)}] "
        f"attribution_note={rep.get('attribution_note')}"
    )
    print(f"reason={rep.get('reason')}")
    print(f"VERDICT={rep.get('verdict')} rc={rep.get('rc')}")


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument("inputs", nargs="*", help="capture directory or PNG frames")
    ap.add_argument("--self-test", action="store_true")
    ap.add_argument("--warmup-skip", type=int, default=DEFAULT_WARMUP_SKIP)
    ap.add_argument("--source-fps", type=float, default=None)
    ap.add_argument(
        "--source-fps-src",
        choices=(
            PROVENANCE_CALLER,
            PROVENANCE_CALLER_MEASURED,
            PROVENANCE_DEFAULT,
            PROVENANCE_MEASURED,
        ),
        default=None,
    )
    ap.add_argument("--capture-fps", type=float, default=None)
    ap.add_argument(
        "--capture-fps-src",
        choices=(
            PROVENANCE_CALLER,
            PROVENANCE_CALLER_MEASURED,
            PROVENANCE_DEFAULT,
            PROVENANCE_MEASURED,
        ),
        default=None,
    )
    ap.add_argument("--label", default="")
    ap.add_argument(
        "--threshold",
        type=float,
        default=None,
        help="override change threshold (caller_supplied); default=derived from noise tail",
    )
    ap.add_argument("--json", action="store_true")
    ap.add_argument(
        "--role",
        choices=("device_under_test", "instrument_floor", "instrument_floor_capture_timing"),
        default="device_under_test",
        help="instrument_floor = MS2109 path floor (non-device source); "
        "device_under_test requires --floor-json for attribution",
    )
    ap.add_argument(
        "--floor-json",
        default=None,
        help="JSON report from a prior --role instrument_floor run",
    )
    ap.add_argument(
        "--emit-floor-fixture",
        default=None,
        metavar="DIR",
        help="write host exact-cadence mp4 + static PNG + parent README",
    )
    ap.add_argument("--beat-only", action="store_true", help="print beat/quant model and exit 0")
    ap.add_argument(
        "--precheck-only",
        action="store_true",
        help="cheap content suitability (change_frac, mean_luma_med) then exit; "
        "rc=0 suitable, rc=77 blind — not a judder verdict",
    )
    args = ap.parse_args(argv)

    if args.self_test:
        return _self_test()

    if args.beat_only:
        src = float(args.source_fps) if args.source_fps is not None else DEFAULT_SOURCE_FPS
        cap = float(args.capture_fps) if args.capture_fps is not None else DEFAULT_CAPTURE_FPS
        ss = args.source_fps_src or (
            PROVENANCE_CALLER if args.source_fps is not None else PROVENANCE_DEFAULT
        )
        cs = args.capture_fps_src or (
            PROVENANCE_CALLER if args.capture_fps is not None else PROVENANCE_DEFAULT
        )
        b = beat_quantisation_model(
            source_fps=src, capture_fps=cap, source_fps_src=ss, capture_fps_src=cs
        )
        print(json.dumps(b, indent=2))
        return RC_OK

    if args.emit_floor_fixture:
        info = emit_floor_fixture(Path(args.emit_floor_fixture))
        print(json.dumps(info, indent=2))
        return RC_OK if info.get("ffmpeg_rc") == 0 else RC_INSTRUMENT

    if not args.inputs:
        ap.error("provide capture dir, --self-test, --emit-floor-fixture, or --beat-only")

    frames: list[str] = []
    label = args.label
    for inp in args.inputs:
        p = Path(inp)
        if p.is_dir():
            frames.extend(list_frames(p))
            if not label:
                label = p.name
        elif p.is_file():
            frames.append(str(p))
        else:
            print(f"ERROR: not found: {inp}", file=sys.stderr)
            return RC_UNSCORED
    if not frames:
        print("ERROR: no PNG frames", file=sys.stderr)
        return RC_UNSCORED

    if args.precheck_only:
        pc = content_precheck(
            frames,
            warmup_skip=int(args.warmup_skip),
            threshold_override=args.threshold,
        )
        if args.json:
            print(json.dumps(pc, indent=2, default=str))
        else:
            print(f"label={label or 'precheck'}")
            print(
                f"precheck suitable={pc.get('suitable')} "
                f"verdict={pc.get('verdict')} rc={pc.get('rc')}"
            )
            print(
                f"change_frac={_tag(pc.get('change_frac'), pc.get('change_frac_src'))} "
                f"mean_luma_med={_tag(pc.get('mean_luma_med'), pc.get('mean_luma_med_src'))} "
                f"pairs={_tag(pc.get('n_pairs'), pc.get('n_pairs_src'))} "
                f"changes={_tag(pc.get('n_changes'), pc.get('n_changes_src'))} "
                f"threshold={_tag(pc.get('threshold'), pc.get('threshold_src'))} "
                f"frames_scored={_tag(pc.get('n_frames_scored'), pc.get('n_frames_scored_src'))} "
                f"warmup_skip={_tag(pc.get('warmup_skip'), pc.get('warmup_skip_src'))}"
            )
            print(f"reason={pc.get('reason')}")
            print(f"NOTE={pc.get('note')}")
        return int(pc.get("rc", RC_UNSCORED))

    if args.source_fps is None:
        source_fps = DEFAULT_SOURCE_FPS
        source_fps_src = args.source_fps_src or PROVENANCE_DEFAULT
    else:
        source_fps = float(args.source_fps)
        source_fps_src = args.source_fps_src or PROVENANCE_CALLER
    if args.capture_fps is None:
        capture_fps = DEFAULT_CAPTURE_FPS
        capture_fps_src = args.capture_fps_src or PROVENANCE_DEFAULT
    else:
        capture_fps = float(args.capture_fps)
        capture_fps_src = args.capture_fps_src or PROVENANCE_CALLER

    floor_baseline = None
    if args.floor_json:
        fp = Path(args.floor_json)
        if not fp.is_file():
            print(f"ERROR: --floor-json not found: {fp}", file=sys.stderr)
            return RC_UNSCORED
        floor_baseline = json.loads(fp.read_text())

    rep = analyze_capture(
        frames,
        warmup_skip=int(args.warmup_skip),
        source_fps=source_fps,
        capture_fps=capture_fps,
        source_fps_src=source_fps_src,
        capture_fps_src=capture_fps_src,
        label=label,
        threshold_override=args.threshold,
        role=str(args.role),
        floor_baseline=floor_baseline,
    )
    if args.json:
        print(json.dumps(rep, indent=2, default=str))
    else:
        _print_human(rep)
    return int(rep.get("rc", RC_UNSCORED))


if __name__ == "__main__":
    raise SystemExit(main())
