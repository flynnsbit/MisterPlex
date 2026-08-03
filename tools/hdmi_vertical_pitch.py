#!/usr/bin/env python3
"""Standard vertical-RESOLUTION instrument — dominant pitch (not amplitude).

WHY AMPLITUDE FAILS (parent / rd-review, measured on glass)
  STD / mean|d/dy| / adj_identical cannot separate 240-row vs 480-row store.
  Arm A (480 path) STD≈68.4 and Arm B (ceiling) STD≈67.8 — same class.
  The measurement that settles it is dominant vertical PITCH on the left
  1-row-alt zone of rk=27 FullBleed:

    upscaling cannot create spatial frequency
    480-row P=2 → pitch_disp ≈ 2 * (body_disp_h / body_src_h) ≈ 3.99
    240-row even-dup → pitch doubles ≈ 7.98

IMPROVEMENTS OVER THROWWAWAY FFT
  1. Sub-bin pitch + ERROR BAR (zero-pad FFT, parabolic peak, ACF refine).
     min=max over frames is a resolution-limit red flag, not precision.
  2. peak_share of band energy; low coherence → UNSCORED (not a fake pitch).
  3. Zones by content (active body equal-thirds + valley snap), never hardcoded
     1920 columns. Active bbox is a pure function of pixels (deterministic);
     optional --ref-bbox locks crop for arm A/B comparability.
  4. Red-before-green synth: 480→~3.99, even_dup→~7.98; 475 vs 480 honesty.

Every field: measured | caller_supplied | DEFAULT_ASSUMED | derived | NO-DATA.
Severity: STRUCTURE_FAIL 3 > COLOR_FAIL 2 > FREEZE 1 > OK 0 > UNSCORED 77.
Measured fail never decays to 77. Artifact pair required to score.

true rc: cmd; echo "true rc=$?"  — never through a pipe.
"""
from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path
from typing import Any, Optional

import numpy as np

try:
    from PIL import Image
except ImportError as e:
    raise SystemExit(f"Pillow required: {e}") from e

_TOOLS = Path(__file__).resolve().parent
if str(_TOOLS) not in sys.path:
    sys.path.insert(0, str(_TOOLS))

from artifact_stamp import add_stamp_args, require_stamp, stamp_from_namespace  # noqa: E402

RC_OK = 0
RC_USAGE = 1
RC_COLOR_FAIL = 2
RC_STRUCTURE_FAIL = 3
RC_UNSCORED = 77

DEFAULT_SRC_H = 480.0
DEFAULT_ID_FRAC = 88.0 / 480.0
DEFAULT_NOISE_FLOOR_STD = 8.0
# Peak power / band power — below this the pitch is not a measurement
DEFAULT_MIN_PEAK_SHARE = 0.12  # Arm B ~0.046 UNSCORED; Arm A ~0.22 OK
DEFAULT_FFT_PAD = 16
# Accept windows for expect gates (capture-row pitch on left P=2 after 1080 fit).
# Full-bleed 624×480→1080 NEAREST fit ⇒ scale=2.25 ⇒ P=2 pitch=4.5 exactly.
# Letterboxed glass active body ~960 ⇒ pitch≈3.99 (parent Arm A). Both in window.
PITCH_480_LO, PITCH_480_HI = 3.50, 4.80
PITCH_240_LO, PITCH_240_HI = 7.00, 9.60


def _tag(v: Any, src: str) -> dict[str, Any]:
    return {"value": v, "src": src}


def load_luma(path: Path) -> np.ndarray:
    rgb = np.asarray(Image.open(path).convert("RGB"), dtype=np.float64)
    return 0.299 * rgb[:, :, 0] + 0.587 * rgb[:, :, 1] + 0.114 * rgb[:, :, 2]


# ----- deterministic active bbox -------------------------------------------------

def detect_active_deterministic(
    luma: np.ndarray,
    *,
    black_mean: float = 8.0,
    black_std: float = 3.0,
    close_rad: int = 2,
) -> tuple[slice, slice, str, dict[str, Any]]:
    """Pure function of pixels + fixed thresholds — same pixels ⇒ same bbox.

    Morphological close (fixed radius) fills single-row dropouts without
    depending on run-length order. Thresholds are DEFAULT_ASSUMED constants
    unless caller overrides (then caller_supplied).

    Parent saw 1230×955 vs 1237×958 across RBFs: if pixels differ, bbox MUST
    differ. That is content/timing, not RNG. Compare arms with --ref-bbox or
    require bbox match within --bbox-tol.
    """
    h, w = luma.shape
    row_m = luma.mean(axis=1)
    row_s = luma.std(axis=1)
    col_m = luma.mean(axis=0)
    col_s = luma.std(axis=0)
    row_on = (row_m > black_mean) | (row_s > black_std)
    col_on = (col_m > black_mean) | (col_s > black_std)

    def close_1d(mask: np.ndarray, rad: int) -> np.ndarray:
        if rad <= 0 or not np.any(mask):
            return mask
        idx = np.flatnonzero(mask)
        out = mask.copy()
        for i in idx:
            a = max(0, i - rad)
            b = min(len(mask), i + rad + 1)
            out[a:b] = True
        return out

    row_on = close_1d(row_on, close_rad)
    col_on = close_1d(col_on, close_rad)
    meta = {
        "black_mean": _tag(black_mean, "DEFAULT_ASSUMED"),
        "black_std": _tag(black_std, "DEFAULT_ASSUMED"),
        "close_rad": _tag(close_rad, "DEFAULT_ASSUMED"),
        "deterministic": _tag(True, "derived"),
    }
    if not np.any(row_on) or not np.any(col_on):
        return slice(0, h), slice(0, w), "FAIL_active_empty", meta

    ry = np.flatnonzero(row_on)
    cx = np.flatnonzero(col_on)
    y0, y1 = int(ry[0]), int(ry[-1]) + 1
    x0, x1 = int(cx[0]), int(cx[-1]) + 1
    if y1 - y0 < 64 or x1 - x0 < 64:
        return slice(0, h), slice(0, w), "FAIL_active_too_small", meta
    meta["bbox_xyxy"] = _tag([x0, y0, x1, y1], "measured")
    meta["bbox_wh"] = _tag([x1 - x0, y1 - y0], "measured")
    return slice(y0, y1), slice(x0, x1), "measured_first_last_closed", meta


def detect_id_bottom(active: np.ndarray) -> tuple[int, str]:
    h, w = active.shape
    lim = max(8, int(h * 0.25))
    left = active[:, : max(8, w // 3)]
    d = np.abs(np.diff(left.astype(np.float64), axis=0)).mean(axis=1)
    lower_med = float(np.median(d[len(d) // 2 :])) if len(d) > 4 else 1.0
    thr = max(3.0, 0.5 * lower_med)
    run = 0
    for i, v in enumerate(d[:lim]):
        if v >= thr:
            run += 1
            if run >= 3:
                return max(0, i - run + 1), "measured_left_energy_onset"
        else:
            run = 0
    y = int(round(h * DEFAULT_ID_FRAC))
    return min(y, lim), "DEFAULT_ASSUMED_frac_88_of_480"


def split_thirds(body: np.ndarray) -> tuple[
    Optional[tuple[int, int]],
    Optional[tuple[int, int]],
    Optional[tuple[int, int]],
    str,
]:
    """Equal thirds of measured body width + optional valley snap (±8%)."""
    h, w = body.shape
    if w < 30 or h < 32:
        return None, None, None, "FAIL_body_too_small"
    s1, s2 = w // 3, 2 * w // 3
    col_std = body.std(axis=0)
    k = max(3, w // 50)
    sm = np.convolve(col_std, np.ones(k) / k, mode="same")

    def snap(idx: int) -> tuple[int, bool]:
        rad = max(3, int(w * 0.08))
        a, b = max(1, idx - rad), min(w - 1, idx + rad)
        j = int(a + np.argmin(sm[a:b]))
        neigh = float(sm[max(0, idx - rad) : min(w, idx + rad)].mean())
        ok = float(sm[j]) < 0.85 * neigh
        return (j if ok else idx), ok

    x1, sn1 = snap(s1)
    x2, sn2 = snap(s2)
    if x2 <= x1 + w // 10:
        x1, x2 = s1, s2
        how = "measured_active_equal_thirds_snap_rejected"
    elif sn1 or sn2:
        how = "measured_active_equal_thirds_valley_snap"
    else:
        how = "measured_active_equal_thirds"
    left, mid, right = (0, x1), (x1, x2), (x2, w)
    for name, seg in ("L", left), ("M", mid), ("R", right):
        if seg[1] - seg[0] < w // 8:
            return None, None, None, f"FAIL_zone_width_{name}"
    return left, mid, right, how


# ----- pitch estimator ------------------------------------------------------------

def _parabolic_peak(y: np.ndarray, i: int) -> tuple[float, float]:
    """Return (i_refined, y_refined) with parabolic interpolation."""
    if i <= 0 or i >= len(y) - 1:
        return float(i), float(y[i])
    a, b, c = float(y[i - 1]), float(y[i]), float(y[i + 1])
    denom = a - 2.0 * b + c
    if abs(denom) < 1e-18:
        return float(i), b
    delta = 0.5 * (a - c) / denom
    delta = float(np.clip(delta, -0.5, 0.5))
    y_ref = b - 0.25 * (a - c) * delta
    return float(i) + delta, float(y_ref)


def estimate_dominant_pitch(
    profile: np.ndarray,
    *,
    pad_factor: int = DEFAULT_FFT_PAD,
    min_period: float = 2.0,
    max_period: Optional[float] = None,
    min_peak_share: float = DEFAULT_MIN_PEAK_SHARE,
    noise_floor_std: float = DEFAULT_NOISE_FLOOR_STD,
) -> dict[str, Any]:
    """Dominant vertical pitch in profile samples (capture rows).

    Returns pitch, error bar, peak_share, coherence verdict.
    """
    p = np.asarray(profile, dtype=np.float64).ravel()
    n = int(p.size)
    out: dict[str, Any] = {
        "n_rows": _tag(n, "measured"),
        "profile_std": _tag(float(p.std()) if n else 0.0, "measured"),
        "profile_mean": _tag(float(p.mean()) if n else 0.0, "measured"),
        "pad_factor": _tag(pad_factor, "DEFAULT_ASSUMED"),
        "min_peak_share": _tag(min_peak_share, "caller_supplied"),
        "noise_floor_std": _tag(noise_floor_std, "caller_supplied"),
    }
    if n < 32:
        out["verdict"] = "UNSCORED"
        out["reason"] = "profile_too_short"
        out["pitch_rows"] = _tag(None, "NO-DATA")
        return out

    std = float(p.std())
    if std < noise_floor_std:
        out["verdict"] = "UNSCORED"
        out["reason"] = (
            f"profile_std={std:.3f} < noise_floor={noise_floor_std} — NO-DATA "
            f"(amplitude collapse is NOT a pitch; solid left is a separate gate)"
        )
        out["pitch_rows"] = _tag(None, "NO-DATA")
        out["peak_share"] = _tag(None, "NO-DATA")
        out["note_amplitude"] = _tag(
            "STD alone cannot separate 240 vs 480 store (parent/rd-review)",
            "caller_supplied",
        )
        return out

    # detrend
    x = np.arange(n, dtype=np.float64)
    coef = np.polyfit(x, p, 1)
    d = p - np.polyval(coef, x)
    d = d - d.mean()
    win = np.hanning(n)
    dw = d * win

    if max_period is None:
        max_period = float(n) / 3.0

    # ---- UNPADDED spectrum for peak_share (parent Arm A~0.22 / B~0.046) ----
    # Share = fundamental lobe / total AC power on native length. Zero-pad
    # dilutes single-bin share and must not define coherence.
    spec_u = np.fft.rfft(dw, n=n)
    power_u = (np.abs(spec_u) ** 2).astype(np.float64)
    power_u[0] = 0.0
    freqs_u = np.fft.rfftfreq(n, d=1.0)
    f_lo = 1.0 / max_period
    f_hi = 1.0 / min_period
    band_u = (freqs_u >= f_lo) & (freqs_u <= f_hi) & (np.arange(len(freqs_u)) >= 1)
    if not np.any(band_u):
        out["verdict"] = "UNSCORED"
        out["reason"] = "empty_period_band"
        out["pitch_rows"] = _tag(None, "NO-DATA")
        return out
    band_idx_u = np.flatnonzero(band_u)
    j_u = int(np.argmax(power_u[band_u]))
    k_u = int(band_idx_u[j_u])
    total_ac = float(power_u[1:].sum()) + 1e-18
    # lobe ±1 native bin around fundamental
    k0u, k1u = max(1, k_u - 1), min(len(power_u) - 1, k_u + 1)
    peak_share = float(power_u[k0u : k1u + 1].sum()) / total_ac
    # also band-local share (matches "share of band energy")
    total_band_u = float(power_u[band_u].sum()) + 1e-18
    peak_share_band = float(power_u[k0u : k1u + 1].sum()) / total_band_u

    # ---- ZERO-PADDED FFT for sub-bin pitch ----
    nfft = int(2 ** math.ceil(math.log2(max(n * pad_factor, n + 1))))
    spec = np.fft.rfft(dw, n=nfft)
    power = (np.abs(spec) ** 2).astype(np.float64)
    freqs = np.fft.rfftfreq(nfft, d=1.0)
    band = (freqs >= f_lo) & (freqs <= f_hi) & (np.arange(len(freqs)) >= 1)
    band_idx = np.flatnonzero(band)
    j_local = int(np.argmax(power[band]))
    k_peak = int(band_idx[j_local])
    k_ref, _ = _parabolic_peak(power, k_peak)
    f_ref = float(k_ref) / float(nfft)
    if f_ref <= 1e-15:
        out["verdict"] = "UNSCORED"
        out["reason"] = "fft_peak_dc"
        out["pitch_rows"] = _tag(None, "NO-DATA")
        return out
    pitch_fft = 1.0 / f_ref

    period_at_peak = pitch_fft
    bin_limit_unpadded = (period_at_peak ** 2) / float(n)
    fft_resolvable = 0.5 * bin_limit_unpadded

    # ---- ACF: first strong peak near FFT (avoid 2× harmonic lag) ----
    acf = np.correlate(d, d, mode="full")
    acf = acf[len(acf) // 2 :]
    if acf[0] > 0:
        acf = acf / acf[0]
    lo = max(2, int(math.floor(min_period)))
    hi = min(len(acf) - 1, int(math.ceil(max_period)))
    pitch_acf: Optional[float] = None
    acf_peak_h = 0.0
    if hi > lo + 1:
        # candidates: local maxima above 0.08
        cands: list[tuple[float, float]] = []
        for i in range(lo + 1, hi - 1):
            if acf[i] >= acf[i - 1] and acf[i] >= acf[i + 1] and acf[i] > 0.08:
                lr, yh = _parabolic_peak(acf, i)
                cands.append((float(lr), float(yh)))
        if cands:
            # prefer lag closest to pitch_fft among strong peaks
            cands.sort(key=lambda t: (abs(t[0] - pitch_fft), -t[1]))
            pitch_acf, acf_peak_h = cands[0]
        else:
            i_local = lo + int(np.argmax(acf[lo:hi]))
            lag_ref, acf_peak_h = _parabolic_peak(acf, i_local)
            if acf_peak_h > 0.05:
                pitch_acf = float(lag_ref)

    method = "fft_pad_parabolic"
    pitch = pitch_fft
    err_methods = fft_resolvable
    if pitch_acf is not None:
        disagree = abs(pitch_acf - pitch_fft)
        if disagree < max(0.35, 0.12 * pitch_fft):
            pitch = 0.5 * (pitch_fft + pitch_acf)
            err_methods = max(
                fft_resolvable,
                0.5 * disagree,
                0.25 * abs(pitch_acf - round(pitch_acf)),
            )
            method = "fft_acf_mean"
        else:
            # keep FFT; enlarge err; do not let 2× ACF lag win
            err_methods = max(fft_resolvable, 0.25 * disagree)
            method = "fft_pad_parabolic_acf_harmonic_ignored"

    out["pitch_fft"] = _tag(pitch_fft, "measured")
    out["pitch_acf"] = _tag(pitch_acf, "measured" if pitch_acf is not None else "NO-DATA")
    out["acf_peak_height"] = _tag(acf_peak_h, "measured")
    out["peak_share"] = _tag(peak_share, "measured")
    out["peak_share_band"] = _tag(peak_share_band, "measured")
    out["peak_share_def"] = _tag(
        "unpadded: sum(power[k_fund±1]) / sum(power[1:]) — NOT pad-diluted",
        "derived",
    )
    out["fft_n"] = _tag(n, "measured")
    out["fft_nfft"] = _tag(nfft, "derived")
    out["fft_k_peak"] = _tag(k_ref, "measured")
    out["bin_limit_unpadded_rows"] = _tag(bin_limit_unpadded, "derived")
    out["resolvable_delta_rows"] = _tag(fft_resolvable, "derived")
    out["resolvable_note"] = _tag(
        "Half unpadded FFT bin at this period (P^2/(2n)). "
        "min=max over frames at bin centre is FAKE precision. "
        "Separating 4.03 vs 3.99 needs delta≥resolvable and high peak_share.",
        "derived",
    )
    out["period_method"] = _tag(method, "derived")

    # Coherence: peak_share (AC total) OR band share; Arm B ~0.046 fails both
    coherent = (peak_share >= min_peak_share) or (
        peak_share_band >= min_peak_share and acf_peak_h >= 0.12
    )
    if not coherent:
        out["verdict"] = "UNSCORED"
        out["reason"] = (
            f"peak_share={peak_share:.4f} peak_share_band={peak_share_band:.4f} "
            f"acf_h={acf_peak_h:.3f} < min_peak_share={min_peak_share} "
            f"— low coherence; pitch is NOT a measurement (Arm-B class ~0.046). "
            f"Would-be pitch_fft={pitch_fft:.4f} suppressed."
        )
        out["pitch_rows"] = _tag(None, "NO-DATA")
        out["pitch_err_rows"] = _tag(None, "NO-DATA")
        out["suppressed_pitch_fft"] = _tag(pitch_fft, "measured")
        return out

    out["verdict"] = "SCORED"
    out["pitch_rows"] = _tag(pitch, "measured")
    out["pitch_err_rows"] = _tag(err_methods, "derived")
    out["pitch_ci95_rows"] = _tag(
        [pitch - 1.96 * err_methods, pitch + 1.96 * err_methods],
        "derived",
    )
    return out


def body_src_height(src_h: float, id_how: str, id_bottom: int, body_h: int) -> tuple[float, str]:
    id_frac = float(id_bottom) / float(max(1, id_bottom + body_h))
    if id_how.startswith("measured"):
        return float(src_h) * (1.0 - id_frac), "derived_from_measured_id_frac"
    return float(src_h) * (1.0 - DEFAULT_ID_FRAC), "DEFAULT_ASSUMED_body_392_of_480"


def predict_pitch_disp(body_disp_h: int, body_src_h: float, store_unique_rows: float) -> float:
    """Expected capture pitch for source P=2 under store unique-row count.

    One-way: store with U unique rows can emit finest period 2 in store space,
    mapped to display by body_disp_h / U (if store fills body).
    For full 480 unique: pitch = 2 * body_disp_h / body_src_h
    For 240 even-dup: content period doubles in coded space → 4 * body_disp_h / body_src_h
    """
    # store_unique_rows relative to body_src_h design
    # scale_disp_per_src = body_disp_h / body_src_h
    # finest emitted period in src rows under ceiling U: 2 * (body_src_h / U)
    # pitch_disp = period_src * scale
    scale = float(body_disp_h) / float(body_src_h)
    period_src = 2.0 * (float(body_src_h) / float(store_unique_rows))
    return period_src * scale


# ----- frame analyze --------------------------------------------------------------

def analyze_frame(
    luma: np.ndarray,
    *,
    src_h: float = DEFAULT_SRC_H,
    src_h_tag: str = "DEFAULT_ASSUMED",
    min_peak_share: float = DEFAULT_MIN_PEAK_SHARE,
    noise_floor: float = DEFAULT_NOISE_FLOOR_STD,
    pad_factor: int = DEFAULT_FFT_PAD,
    ref_bbox: Optional[list[int]] = None,
    bbox_tol: int = 4,
    lock_ref_bbox: bool = False,
) -> dict[str, Any]:
    ys, xs, how, ameta = detect_active_deterministic(luma)
    if how.startswith("FAIL"):
        return {
            "verdict": "UNSCORED",
            "rc": RC_UNSCORED,
            "reason": how,
            "active": ameta,
        }

    bbox = [int(xs.start), int(ys.start), int(xs.stop), int(ys.stop)]
    bbox_note = None
    if ref_bbox is not None:
        diffs = [abs(bbox[i] - ref_bbox[i]) for i in range(4)]
        max_d = max(diffs)
        ameta["ref_bbox"] = _tag(ref_bbox, "caller_supplied")
        ameta["bbox_abs_diff"] = _tag(diffs, "measured")
        ameta["bbox_max_abs_diff"] = _tag(max_d, "measured")
        if max_d > bbox_tol:
            bbox_note = (
                f"BBOX_DRIFT max_abs_diff={max_d} > tol={bbox_tol} — arms may not "
                f"crop the same pixels (real scale/timing OR detector; detector is "
                f"deterministic on identical pixels)."
            )
            ameta["bbox_drift"] = _tag(True, "derived")
            if lock_ref_bbox:
                # force crop to ref for fair pitch compare
                x0, y0, x1, y1 = ref_bbox
                ys, xs = slice(y0, y1), slice(x0, x1)
                bbox = list(ref_bbox)
                ameta["crop"] = _tag("locked_to_ref_bbox", "caller_supplied")
            else:
                ameta["crop"] = _tag("auto_despite_drift", "measured")
        else:
            ameta["bbox_drift"] = _tag(False, "derived")

    active = luma[ys, xs]
    id_bottom, id_how = detect_id_bottom(active)
    body = active[id_bottom:, :]
    if body.shape[0] < 32:
        return {
            "verdict": "UNSCORED",
            "rc": RC_UNSCORED,
            "reason": "body_too_small",
            "active": ameta,
        }

    # flash skip
    if float(body.mean()) > 240.0:
        return {
            "verdict": "UNSCORED",
            "rc": RC_UNSCORED,
            "reason": "flash_frame_body_white",
            "body_mean": _tag(float(body.mean()), "measured"),
        }

    left, mid, right, third_how = split_thirds(body)
    if left is None:
        return {
            "verdict": "UNSCORED",
            "rc": RC_UNSCORED,
            "reason": third_how,
        }

    bh = body.shape[0]
    b_src, b_src_tag = body_src_height(src_h, id_how, id_bottom, bh)
    lz = body[:, left[0] : left[1]]
    prof = lz.mean(axis=1)
    pitch = estimate_dominant_pitch(
        prof,
        pad_factor=pad_factor,
        min_peak_share=min_peak_share,
        noise_floor_std=noise_floor,
        min_period=2.0,
        max_period=max(12.0, bh / 4.0),
    )

    pred_480 = predict_pitch_disp(bh, b_src, store_unique_rows=b_src)  # U=body_src ≈ full
    # store unique = body_src means period_src=2
    pred_480 = 2.0 * float(bh) / float(b_src)
    pred_240 = 4.0 * float(bh) / float(b_src)  # doubled content period
    pred_475 = 2.0 * float(bh) / (float(b_src) * 475.0 / 480.0)

    # mid p4 control (invariant under even-cull) — report only
    zh = bh // 4
    mid_p4 = body[zh : 2 * zh, mid[0] : mid[1]].mean(axis=1)
    pitch_mid4 = estimate_dominant_pitch(
        mid_p4,
        pad_factor=pad_factor,
        min_peak_share=min_peak_share * 0.5,
        noise_floor_std=noise_floor,
        min_period=3.0,
        max_period=max(20.0, bh / 3.0),
    )

    rep: dict[str, Any] = {
        "active_bbox_xyxy": _tag(bbox, "measured"),
        "active_how": _tag(how, "measured"),
        "active_meta": ameta,
        "id_bottom": _tag(id_bottom, "measured" if id_how.startswith("measured") else "DEFAULT_ASSUMED"),
        "id_how": _tag(id_how, "measured" if id_how.startswith("measured") else "DEFAULT_ASSUMED"),
        "body_h": _tag(bh, "measured"),
        "body_src_h": _tag(b_src, b_src_tag),
        "src_h": _tag(src_h, src_h_tag),
        "thirds_how": _tag(third_how, "measured"),
        "thirds_x": _tag({"left": list(left), "mid": list(mid), "right": list(right)}, "measured"),
        "left_zone": pitch,
        "mid_period_4": pitch_mid4,
        "predict_pitch_480": _tag(pred_480, "derived"),
        "predict_pitch_240": _tag(pred_240, "derived"),
        "predict_pitch_475_on_same_body_h": _tag(pred_475, "derived"),
        "HEADLINE_pitch_rows": pitch.get("pitch_rows", _tag(None, "NO-DATA")),
        "HEADLINE_pitch_err_rows": pitch.get("pitch_err_rows", _tag(None, "NO-DATA")),
        "HEADLINE_peak_share": pitch.get("peak_share", _tag(None, "NO-DATA")),
        "HEADLINE_resolvable_delta_rows": pitch.get("resolvable_delta_rows", _tag(None, "NO-DATA")),
        "HEADLINE_note": _tag(
            "PRIMARY=left P=2 dominant pitch_rows; STD/amplitude is NOT a V-res gate; "
            "low peak_share → UNSCORED; compare pitch to predict_480≈3.99 vs predict_240≈7.98",
            "caller_supplied",
        ),
    }
    if bbox_note:
        rep["bbox_note"] = _tag(bbox_note, "derived")

    if pitch.get("verdict") != "SCORED":
        rep["verdict"] = "UNSCORED"
        rep["rc"] = RC_UNSCORED
        rep["reason"] = pitch.get("reason", "left_zone_unscored")
        # keep HEADLINE_* so apply_expect can turn SOLID/low-coh into STRUCTURE_FAIL
        return rep

    rep["verdict"] = "REPORT_ONLY"
    rep["rc"] = RC_OK
    return rep


def apply_expect(rep: dict[str, Any], expect: Optional[str]) -> dict[str, Any]:
    """Apply pitch expect gate.

    Missing / low-coherence pitch under an expect is STRUCTURE_FAIL when the
    left zone is SOLID or suppressed (ceiling ate P=2) — not a quiet 77.
    Only geometry/setup failures stay UNSCORED.
    """
    if expect is None:
        if "rc" not in rep:
            rep["rc"] = RC_OK if rep.get("verdict") != "UNSCORED" else RC_UNSCORED
        return rep

    pr = rep.get("HEADLINE_pitch_rows", {}).get("value")
    share = rep.get("HEADLINE_peak_share", {}).get("value")
    reason = str(rep.get("reason") or "")
    setup_fail = any(
        s in reason
        for s in (
            "FAIL_active",
            "body_too_small",
            "FAIL_zone",
            "FAIL_body",
            "flash_frame",
            "empty_period",
        )
    )
    if setup_fail:
        rep["verdict"] = "UNSCORED"
        rep["rc"] = RC_UNSCORED
        return rep

    def in_win(lo, hi, v):
        return v is not None and lo <= v <= hi

    # No scored pitch: solid collapse or low-coherence under expect → measured miss
    if pr is None:
        std = None
        lz = rep.get("left_zone") or {}
        if isinstance(lz, dict):
            std = (lz.get("profile_std") or {}).get("value")
        suppressed = (lz.get("suppressed_pitch_fft") or {}).get("value") if isinstance(lz, dict) else None
        if expect == "pitch_480":
            # Wanted ~4; got nothing or would-be ~8 class
            if suppressed is not None and in_win(PITCH_240_LO, PITCH_240_HI, suppressed):
                rep["verdict"] = "STRUCTURE_FAIL_PITCH_240_UNDER_EXPECT_480"
            elif std is not None and std < DEFAULT_NOISE_FLOOR_STD:
                rep["verdict"] = "STRUCTURE_FAIL_SOLID_NO_PITCH_UNDER_EXPECT_480"
            else:
                rep["verdict"] = "STRUCTURE_FAIL_NO_COHERENT_PITCH_UNDER_EXPECT_480"
            rep["rc"] = RC_STRUCTURE_FAIL
            rep["expect_window"] = _tag([PITCH_480_LO, PITCH_480_HI], "DEFAULT_ASSUMED")
            return rep
        if expect == "pitch_240":
            # Wanted doubled pitch; solid/no-pitch is still a 240-class ceiling OK
            # only if left is SOLID (even-cull of P=2). Low-coherent ~4 is FAIL.
            if std is not None and std < DEFAULT_NOISE_FLOOR_STD:
                rep["verdict"] = "PITCH_240_SOLID_OK"
                rep["rc"] = RC_OK
                rep["note"] = _tag(
                    "even-cull P=2 → solid; pitch undefined; SOLID accepted as 240-class",
                    "derived",
                )
            elif suppressed is not None and in_win(PITCH_480_LO, PITCH_480_HI, suppressed):
                rep["verdict"] = "STRUCTURE_FAIL_PITCH_480_UNDER_EXPECT_240"
                rep["rc"] = RC_STRUCTURE_FAIL
            else:
                rep["verdict"] = "STRUCTURE_FAIL_NO_COHERENT_PITCH_UNDER_EXPECT_240"
                rep["rc"] = RC_STRUCTURE_FAIL
            rep["expect_window"] = _tag([PITCH_240_LO, PITCH_240_HI], "DEFAULT_ASSUMED")
            return rep

    if expect == "pitch_480":
        if in_win(PITCH_480_LO, PITCH_480_HI, pr):
            rep["verdict"] = "PITCH_480_OK"
            rep["rc"] = RC_OK
        elif in_win(PITCH_240_LO, PITCH_240_HI, pr):
            rep["verdict"] = "STRUCTURE_FAIL_PITCH_240_UNDER_EXPECT_480"
            rep["rc"] = RC_STRUCTURE_FAIL
        else:
            rep["verdict"] = "STRUCTURE_FAIL_PITCH_OUT_OF_WINDOW"
            rep["rc"] = RC_STRUCTURE_FAIL
        rep["expect_window"] = _tag([PITCH_480_LO, PITCH_480_HI], "DEFAULT_ASSUMED")
        rep["peak_share_at_gate"] = _tag(share, "measured" if share is not None else "NO-DATA")
        return rep

    if expect == "pitch_240":
        if in_win(PITCH_240_LO, PITCH_240_HI, pr):
            rep["verdict"] = "PITCH_240_OK"
            rep["rc"] = RC_OK
        elif in_win(PITCH_480_LO, PITCH_480_HI, pr):
            rep["verdict"] = "STRUCTURE_FAIL_PITCH_480_UNDER_EXPECT_240"
            rep["rc"] = RC_STRUCTURE_FAIL
        else:
            rep["verdict"] = "STRUCTURE_FAIL_PITCH_OUT_OF_WINDOW"
            rep["rc"] = RC_STRUCTURE_FAIL
        rep["expect_window"] = _tag([PITCH_240_LO, PITCH_240_HI], "DEFAULT_ASSUMED")
        return rep

    rep["verdict"] = "UNSCORED"
    rep["rc"] = RC_UNSCORED
    rep["reason"] = f"unknown_expect={expect}"
    return rep


# ----- synth / self-test ----------------------------------------------------------

def synth_coded(even_dup: bool = False, src_h: int = 480, src_w: int = 624) -> np.ndarray:
    """rk=27-like coded frame; left P=2.

    even_dup=True models a 240-unique-row store: build body at body_h//2 with
    the same designed periods, then line-double to body_h. That is the
    frequency-halving the one-way argument predicts (pitch ~2×), NOT the
    solid field from naively copying even rows of an already-P=2 raster
    (that collapses P=2→DC and is a separate SOLID gate).
    """
    id_bottom = int(round(src_h * DEFAULT_ID_FRAC))
    body_h = src_h - id_bottom
    rgb = np.zeros((src_h, src_w), dtype=np.float64)
    rgb[:id_bottom, :] = 20.0
    rgb[id_bottom:, :] = 48.0
    x0, x1, x2 = 0, src_w // 3, 2 * src_w // 3

    def paint_body(bh: int) -> np.ndarray:
        body = np.full((bh, src_w), 48.0, dtype=np.float64)
        ys = np.arange(bh)
        alt = np.where((ys % 2) == 0, 255.0, 0.0)
        body[:, x0:x1] = alt[:, None]
        zone_h = max(1, bh // 4)
        for zi, period in enumerate((2, 4, 8, 16)):
            y0 = zi * zone_h
            y1 = (zi + 1) * zone_h if zi < 3 else bh
            for y in range(y0, y1):
                v = 255.0 if ((y - y0) % period) < max(1, period // 2) else 0.0
                body[y, x1:x2] = v
        y_loc = ys.astype(np.float64)
        p = 2.0 + 30.0 * (y_loc / max(bh - 1, 1))
        phase = np.cumsum(2.0 * np.pi / p)
        body[:, x2:] = (255.0 * (0.5 + 0.5 * np.sin(phase)))[:, None]
        return body

    if not even_dup:
        rgb[id_bottom:, :] = paint_body(body_h)
    else:
        half = paint_body(max(2, body_h // 2))
        # line-double 240 unique → 480 coded body (period doubles in coded rows)
        doubled = np.repeat(half, 2, axis=0)[:body_h]
        if doubled.shape[0] < body_h:
            pad = np.repeat(doubled[-1:], body_h - doubled.shape[0], axis=0)
            doubled = np.concatenate([doubled, pad], axis=0)
        rgb[id_bottom:, :] = doubled
    return rgb


def upscale_letterbox(luma: np.ndarray, out_w: int = 1920, out_h: int = 1080) -> np.ndarray:
    h, w = luma.shape
    scale = min(out_w / w, out_h / h)
    nw, nh = max(1, int(round(w * scale))), max(1, int(round(h * scale)))
    im = Image.fromarray(luma.astype(np.uint8), mode="L").resize((nw, nh), Image.Resampling.NEAREST)
    canvas = np.zeros((out_h, out_w), dtype=np.float64)
    y0 = (out_h - nh) // 2
    x0 = (out_w - nw) // 2
    canvas[y0 : y0 + nh, x0 : x0 + nw] = np.asarray(im, dtype=np.float64)
    return canvas


def synth_profile_pitch(n: int, period: float, amp: float = 120.0) -> np.ndarray:
    """Pure sinusoid profile for resolution honesty (no geometry confounds)."""
    x = np.arange(n, dtype=np.float64)
    return 128.0 + amp * np.sin(2.0 * np.pi * x / period)


def run_self_test() -> int:
    print("PRE-REGISTER vertical pitch instrument:")
    print("  full 480 left → pitch ~3.99 (window 3.5–4.5), high peak_share, rc=0 under --expect-pitch-480")
    print("  even_dup 240 → pitch ~7.98 (window 7–9), rc=0 under --expect-pitch-240; rc=3 under expect-480")
    print("  low-coherence noise → UNSCORED 77 (not a printed fake pitch)")
    print("  475 vs 480 pure profiles: report CAN_RESOLVE or CANNOT_RESOLVE with err bars")
    print("  amplitude STD must NOT be the gate")

    ok = True
    stamp = {
        "rbf_md5": "8fdf440faaaaaaaaaaaaaaaaaaaaaaaa",
        "daemon_md5": "7c991e47aaaaaaaaaaaaaaaaaaaaaaaa",
        "decode_src": "caller_supplied",
    }

    def score(img, expect):
        r = analyze_frame(img)
        r = apply_expect(r, expect)
        return r

    full = upscale_letterbox(synth_coded(False))
    half = upscale_letterbox(synth_coded(True))

    r480 = score(full, "pitch_480")
    r240_as480 = score(half, "pitch_480")
    r240 = score(half, "pitch_240")
    r480_as240 = score(full, "pitch_240")

    def show(tag, r):
        print(
            f"  {tag}: verdict={r.get('verdict')} rc={r.get('rc')} "
            f"pitch={r.get('HEADLINE_pitch_rows', {}).get('value')} "
            f"err={r.get('HEADLINE_pitch_err_rows', {}).get('value')} "
            f"share={r.get('HEADLINE_peak_share', {}).get('value')} "
            f"pred480={r.get('predict_pitch_480', {}).get('value')} "
            f"pred240={r.get('predict_pitch_240', {}).get('value')}"
        )

    show("full_expect480", r480)
    show("half_expect480", r240_as480)
    show("half_expect240", r240)
    show("full_expect240", r480_as240)

    if r480.get("rc") != RC_OK:
        print("FAIL full expect480"); ok = False
    else:
        print(f"PASS full expect480 rc=0 pitch={r480['HEADLINE_pitch_rows']['value']:.4f}")
    if r240_as480.get("rc") != RC_STRUCTURE_FAIL:
        print(f"FAIL half under expect480 want rc=3 got {r240_as480.get('rc')}"); ok = False
    else:
        print("PASS half expect480 STRUCTURE_FAIL rc=3")
    p240 = r240.get("HEADLINE_pitch_rows", {}).get("value")
    if r240.get("rc") != RC_OK:
        print(f"FAIL half expect240 rc={r240.get('rc')} pitch={p240}"); ok = False
    else:
        print(f"PASS half expect240 rc=0 pitch={p240}")
        if p240 is not None and not (PITCH_240_LO <= p240 <= PITCH_240_HI):
            print(f"FAIL half pitch {p240} outside 240 window"); ok = False
    if r480_as240.get("rc") != RC_STRUCTURE_FAIL:
        print("FAIL full under expect240 want STRUCTURE_FAIL"); ok = False
    else:
        print("PASS full expect240 STRUCTURE_FAIL rc=3")

    # coherence: structured-looking noise without stable period
    rng = np.random.default_rng(0)
    noise = np.zeros((1080, 1920), dtype=np.float64)
    noise[100:980, 200:1720] = rng.normal(80, 40, size=(880, 1520))
    rn = analyze_frame(noise, min_peak_share=DEFAULT_MIN_PEAK_SHARE)
    rn = apply_expect(rn, None)
    print(
        f"  noise: verdict={rn.get('verdict')} rc={rn.get('rc')} "
        f"share={rn.get('HEADLINE_peak_share', {}).get('value')} "
        f"reason={rn.get('reason')}"
    )
    if rn.get("verdict") == "UNSCORED" or (
        rn.get("HEADLINE_peak_share", {}).get("value") is not None
        and rn.get("HEADLINE_peak_share", {}).get("value") < DEFAULT_MIN_PEAK_SHARE
    ) or rn.get("HEADLINE_pitch_rows", {}).get("value") is None:
        print("PASS noise low-coherence path (no false high-share pitch)")
    else:
        # if random luck makes a peak, still require share gate in estimate
        print(f"FAIL noise produced scored pitch {rn.get('HEADLINE_pitch_rows')}"); ok = False

    # deterministic bbox: identical pixels → identical bbox
    a1 = detect_active_deterministic(full)
    a2 = detect_active_deterministic(full)
    if a1[0] != a2[0] or a1[1] != a2[1]:
        print("FAIL bbox nondeterministic on identical pixels"); ok = False
    else:
        print(f"PASS bbox deterministic wh={a1[3].get('bbox_wh',{}).get('value')}")

    # 475 vs 480 pure sinusoid on n=960
    n = 960
    p480 = 2.0 * n / 480.0  # 4.0
    p475 = 2.0 * n / 475.0  # ≈4.0421
    e480 = estimate_dominant_pitch(synth_profile_pitch(n, p480), pad_factor=16, min_peak_share=0.05)
    e475 = estimate_dominant_pitch(synth_profile_pitch(n, p475), pad_factor=16, min_peak_share=0.05)
    m480 = e480["pitch_rows"]["value"]
    m475 = e475["pitch_rows"]["value"]
    err480 = e480["pitch_err_rows"]["value"]
    err475 = e475["pitch_err_rows"]["value"]
    res = e480["resolvable_delta_rows"]["value"]
    delta = abs(m475 - m480)
    # non-overlapping CI as resolve criterion
    lo480, hi480 = m480 - 1.96 * err480, m480 + 1.96 * err480
    lo475, hi475 = m475 - 1.96 * err475, m475 + 1.96 * err475
    overlap = not (hi480 < lo475 or hi475 < lo480)
    can = (delta > res) and (not overlap)
    print(
        f"  resolve 475 vs 480: true_p480={p480:.4f} true_p475={p475:.4f} "
        f"meas480={m480:.4f}±{err480:.4f} meas475={m475:.4f}±{err475:.4f} "
        f"delta={delta:.4f} resolvable={res:.4f} overlap_ci={overlap} "
        f"CAN_RESOLVE={can}"
    )
    print(
        f"  HONEST: instrument {'CAN' if can else 'CANNOT'} separate 475-row from 480-row "
        f"pitch on pure SNR profile n={n} (live MJPG will be harder)."
    )
    if m480 is None or abs(m480 - p480) > 0.15:
        print("FAIL pure 480 pitch recovery"); ok = False
    else:
        print("PASS pure 480 pitch recovery")
    if m475 is None or abs(m475 - p475) > 0.15:
        print("FAIL pure 475 pitch recovery"); ok = False
    else:
        print("PASS pure 475 pitch recovery")

    # STD must not discriminate in self-check messaging
    std_f = float(full[200:900, 400:800].std())
    std_h = float(half[200:900, 400:800].std())
    print(f"  amplitude note: crop STD full={std_f:.2f} half={std_h:.2f} (not used as gate)")

    print("QUOTE true rc full_expect480=%s half_expect480=%s" % (r480.get("rc"), r240_as480.get("rc")))
    if ok:
        print("SELF_TEST_OK")
        return 0
    print("SELF_TEST_FAIL")
    return 2


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("image", nargs="?", type=Path, help="1920x1080 capture PNG")
    ap.add_argument("--self-test", action="store_true")
    ap.add_argument("--expect-pitch-480", action="store_true", help="gate: left pitch in ~3.99 window")
    ap.add_argument("--expect-pitch-240", action="store_true", help="gate: left pitch in ~7.98 window")
    ap.add_argument("--src-h", type=float, default=None, help="source coded height (default 480 ASSUMED)")
    ap.add_argument("--min-peak-share", type=float, default=DEFAULT_MIN_PEAK_SHARE)
    ap.add_argument("--noise-floor-std", type=float, default=DEFAULT_NOISE_FLOOR_STD)
    ap.add_argument("--fft-pad", type=int, default=DEFAULT_FFT_PAD)
    ap.add_argument("--ref-bbox", type=str, default=None, help="x0,y0,x1,y1 lock/compare")
    ap.add_argument("--bbox-tol", type=int, default=4)
    ap.add_argument("--lock-ref-bbox", action="store_true", help="crop to --ref-bbox if drift")
    ap.add_argument("--json-out", type=Path, default=None)
    add_stamp_args(ap)
    args = ap.parse_args()

    if args.self_test:
        return run_self_test()
    if args.image is None:
        ap.error("image required unless --self-test")
    if args.expect_pitch_480 and args.expect_pitch_240:
        print("UNSCORED: conflicting expect flags", file=sys.stderr)
        return RC_UNSCORED

    st = stamp_from_namespace(args)
    print("STAMP", st.header_kv())
    ok_pair, stamp_reason, _ = require_stamp(st)
    if not ok_pair and not getattr(args, "allow_unstamped", False):
        print(f"VERDICT=UNSCORED rc={RC_UNSCORED} reason={stamp_reason}")
        return RC_UNSCORED
    if not ok_pair and getattr(args, "allow_unstamped", False):
        print(f"WARN allow_unstamped forensic only — product claim FORBIDDEN reason={stamp_reason}")

    src_h = float(args.src_h) if args.src_h is not None else DEFAULT_SRC_H
    src_tag = "caller_supplied" if args.src_h is not None else "DEFAULT_ASSUMED"
    ref = None
    if args.ref_bbox:
        parts = [int(x) for x in args.ref_bbox.split(",")]
        if len(parts) != 4:
            print("UNSCORED: --ref-bbox needs x0,y0,x1,y1", file=sys.stderr)
            return RC_UNSCORED
        ref = parts

    if not args.image.is_file():
        print("NO_DATA image missing — empty is not zero")
        return RC_UNSCORED

    luma = load_luma(args.image)
    rep = analyze_frame(
        luma,
        src_h=src_h,
        src_h_tag=src_tag,
        min_peak_share=float(args.min_peak_share),
        noise_floor=float(args.noise_floor_std),
        pad_factor=int(args.fft_pad),
        ref_bbox=ref,
        bbox_tol=int(args.bbox_tol),
        lock_ref_bbox=bool(args.lock_ref_bbox),
    )
    expect = "pitch_480" if args.expect_pitch_480 else ("pitch_240" if args.expect_pitch_240 else None)
    # Always apply expect: SOLID/low-coherence under expect → STRUCTURE_FAIL (not quiet 77)
    rep = apply_expect(rep, expect)
    # allow_unstamped: still force UNSCORED unless measured STRUCTURE_FAIL (never decay)
    if not ok_pair:
        if int(rep.get("rc", RC_UNSCORED)) != RC_STRUCTURE_FAIL:
            rep["verdict"] = "UNSCORED"
            rep["rc"] = RC_UNSCORED
            rep["reason"] = stamp_reason
        else:
            rep["stamp_override_note"] = _tag(
                "STRUCTURE_FAIL retained without pair — still not a product cite",
                "derived",
            )
    rep["stamp"] = st.to_dict()
    rep["artifact_pair"] = _tag(st.artifact_pair, "caller_supplied" if ok_pair else "NO-DATA")
    rep["rbf_md5"] = _tag(st.rbf_md5, st.rbf_md5_src)
    rep["daemon_md5"] = _tag(st.daemon_md5, st.daemon_md5_src)
    if st.decode_src and st.decode_src != "NO-DATA":
        rep["decode_src"] = _tag(st.decode_src, st.decode_src_src)

    rc = int(rep.get("rc", RC_UNSCORED))

    print(
        f"STAMP_PAIR pair={st.artifact_pair} "
        f"rbf={st.rbf_md5} daemon={st.daemon_md5} "
        f"decode_src={st.decode_src}"
    )
    print(
        f"VERDICT={rep.get('verdict')} rc={rc} "
        f"pitch={rep.get('HEADLINE_pitch_rows', {}).get('value')} "
        f"err={rep.get('HEADLINE_pitch_err_rows', {}).get('value')} "
        f"peak_share={rep.get('HEADLINE_peak_share', {}).get('value')} "
        f"resolvable_delta={rep.get('HEADLINE_resolvable_delta_rows', {}).get('value')}"
    )
    print(
        f"PREDICT pitch_480={rep.get('predict_pitch_480', {}).get('value')} "
        f"pitch_240={rep.get('predict_pitch_240', {}).get('value')} "
        f"pitch_475={rep.get('predict_pitch_475_on_same_body_h', {}).get('value')} "
        f"bbox={rep.get('active_bbox_xyxy', {}).get('value')} "
        f"body_h={rep.get('body_h', {}).get('value')} "
        f"thirds={rep.get('thirds_how', {}).get('value')}"
    )
    if rep.get("reason"):
        print(f"REASON {rep.get('reason')}")
    if rep.get("bbox_note"):
        print(f"BBOX {rep['bbox_note'].get('value')}")
    lz = rep.get("left_zone", {})
    if isinstance(lz, dict) and lz.get("resolvable_note"):
        print(f"RESOLUTION {lz['resolvable_note'].get('value')}")

    if args.json_out:
        args.json_out.parent.mkdir(parents=True, exist_ok=True)

        def conv(o):
            if isinstance(o, dict):
                return {k: conv(v) for k, v in o.items()}
            if isinstance(o, (list, tuple)):
                return [conv(x) for x in o]
            if isinstance(o, (np.floating, float)):
                return float(o)
            if isinstance(o, (np.integer, int)):
                return int(o)
            if o is None or isinstance(o, (str, bool)):
                return o
            return str(o)

        args.json_out.write_text(json.dumps(conv(rep), indent=2) + "\n")
        print(f"JSON {args.json_out}")

    return rc


if __name__ == "__main__":
    try:
        sys.exit(main())
    except BrokenPipeError:
        sys.exit(0)
