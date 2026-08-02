#!/usr/bin/env python3
"""Beat/quantisation model + IFI histogram helpers for glass_motion_judder."""
from __future__ import annotations

import math
from collections import Counter
from fractions import Fraction
from typing import Any, Optional, Sequence

import numpy as np

PROVENANCE_MEASURED = "measured"
PROVENANCE_CALLER = "caller_supplied"
PROVENANCE_DEFAULT = "DEFAULT_ASSUMED"


def beat_quantisation_model(
    *,
    source_fps: float,
    capture_fps: float,
    source_fps_src: str,
    capture_fps_src: str,
) -> dict[str, Any]:
    """State capture/source periods, commensurate beat, reject wrong continuous floor.

    When source and capture are commensurate (24.000:30.000 = 4:5), the expected
    healthy mass is a DISCRETE hold/IFI mixture on the capture grid. Continuous
    quantisation RMS T_cap/sqrt(12) (~9.62 ms at 30 Hz) is the wrong floor and
    must not be subtracted as instrument noise for quadrature claims.
    """
    if source_fps <= 0 or capture_fps <= 0:
        return {
            "ok": False,
            "reason": "non_positive_fps",
            "source_fps": source_fps,
            "capture_fps": capture_fps,
        }
    t_src_ms = 1000.0 / source_fps
    t_cap_ms = 1000.0 / capture_fps
    ratio = Fraction(capture_fps / source_fps).limit_denominator(240)
    n_cap = int(ratio.numerator)
    n_src = int(ratio.denominator)
    pattern_ms = n_cap * t_cap_ms
    ratio_f = capture_fps / source_fps
    ratio_err = abs(float(ratio) - ratio_f)
    commensurate = ratio_err < 1e-9
    ideal_ifi_ms = t_src_ms
    k_lo = max(1, int(math.floor(ideal_ifi_ms / t_cap_ms + 1e-12)))
    k_hi = max(k_lo, int(math.ceil(ideal_ifi_ms / t_cap_ms - 1e-12)))
    discrete_ifi_ms = sorted({round(k * t_cap_ms, 6) for k in range(k_lo, k_hi + 1)})
    cont_quant_rms = t_cap_ms / math.sqrt(12.0)
    drop_ifi_ms = 2.0 * ideal_ifi_ms
    drop_k = drop_ifi_ms / t_cap_ms
    avg_hold = ratio_f
    healthy_holds = sorted(
        {
            max(1, int(math.floor(avg_hold + 1e-12))),
            max(1, int(math.ceil(avg_hold - 1e-12))),
        }
    )
    if commensurate:
        quant_note = (
            "REJECT continuous floor T_cap/sqrt(12) as baseline when source and "
            "capture are commensurate (e.g. 24.000:30.000 = 4:5). Expected healthy "
            "mass is DISCRETE on the capture grid (24@30 → holds {1,2} → IFI "
            "{33.333,66.667} ms, mean 41.667). A slow STABLE/WANDER beat needs "
            "independent clock offset, not this rational locked pattern. "
            f"T_cap/sqrt(12)={cont_quant_rms:.4f} ms is the wrong model here."
        )
    else:
        quant_note = (
            "Rates not exactly commensurate at limit_denominator(240); continuous "
            "quantisation may contribute, but still prefer discrete hold/IFI "
            "histogram over a single RMS floor."
        )
    return {
        "ok": True,
        "source_fps": source_fps,
        "source_fps_src": source_fps_src,
        "capture_fps": capture_fps,
        "capture_fps_src": capture_fps_src,
        "t_src_ms": round(t_src_ms, 6),
        "t_cap_ms": round(t_cap_ms, 6),
        "t_src_ms_src": "derived_1000_over_src_fps",
        "t_cap_ms_src": "derived_1000_over_cap_fps",
        "cap_over_src_ratio": f"{n_cap}/{n_src}",
        "cap_over_src_float": round(ratio_f, 9),
        "ratio_rational_error": ratio_err,
        "commensurate": commensurate,
        "pattern_period_capture_frames": n_cap,
        "pattern_period_source_frames": n_src,
        "pattern_period_ms": round(pattern_ms, 6),
        "ideal_content_ifi_ms": round(ideal_ifi_ms, 6),
        "ideal_content_ifi_ms_src": "derived_1000_over_src_fps",
        "discrete_ifi_ms_on_capture_grid": discrete_ifi_ms,
        "discrete_ifi_ms_src": "derived_k_times_t_cap",
        "healthy_hold_mass_expected": healthy_holds,
        "drop_signature_ifi_ms": round(drop_ifi_ms, 6),
        "drop_signature_hold_approx": round(drop_k, 4),
        "continuous_quant_rms_ms": round(cont_quant_rms, 6),
        "continuous_quant_rms_ms_src": "derived_t_cap_over_sqrt12",
        "continuous_quant_rms_usable": (not commensurate),
        "quant_note": quant_note,
    }


def ifi_stats_from_holds(
    holds: Sequence[int],
    *,
    capture_fps: float,
    source_fps: float,
) -> dict[str, Any]:
    """IFI_ms between successive DISTINCT content frames = hold * (1000/cap_fps)."""
    if capture_fps <= 0 or not holds:
        return {
            "n_ifi": 0,
            "ifi_ms_hist": {},
            "p50": None,
            "p95": None,
            "p99": None,
            "max": None,
            "mean": None,
            "src": PROVENANCE_MEASURED,
        }
    t_cap = 1000.0 / capture_fps
    ifis = [float(h) * t_cap for h in holds]
    arr = np.array(ifis, dtype=np.float64)
    hc: Counter[str] = Counter()
    for v in ifis:
        hc[f"{round(v, 3):.3f}"] += 1
    ideal = 1000.0 / source_fps if source_fps > 0 else float("nan")
    drop = 2.0 * ideal if ideal == ideal else float("nan")
    half = 0.5 * t_cap
    # Healthy discrete IFI on capture grid: k = floor/ceil(cap/src) holds.
    # CRITICAL: hold=2 → 66.667 ms must NOT count as drop (~83 ms). Using
    # |IFI - 83| <= half_cap falsely includes 66.667. Long-tail = beyond
    # max healthy grid IFI (hold >= ceil(cap/src)+1).
    import math
    if source_fps > 0:
        avg_hold = capture_fps / source_fps
        h_lo = max(1, int(math.floor(avg_hold + 1e-12)))
        h_hi = max(h_lo, int(math.ceil(avg_hold - 1e-12)))
        healthy_ifi_max = h_hi * t_cap
        healthy_ifi_min = h_lo * t_cap
    else:
        healthy_ifi_max = float("nan")
        healthy_ifi_min = float("nan")
    n_near_ideal = (
        int(sum(1 for v in ifis if abs(v - ideal) <= half + 1e-9)) if ideal == ideal else 0
    )
    # mass on healthy discrete grid bins only
    n_on_healthy_grid = (
        int(
            sum(
                1
                for v in ifis
                if v + 1e-6 >= healthy_ifi_min and v - 1e-6 <= healthy_ifi_max
            )
        )
        if healthy_ifi_max == healthy_ifi_max
        else 0
    )
    # drop signature: IFI strictly above healthy grid max (e.g. hold>=3 → ≥100ms)
    n_ge_drop = (
        int(sum(1 for v in ifis if v > healthy_ifi_max + 1e-6))
        if healthy_ifi_max == healthy_ifi_max
        else 0
    )
    # optional: near exact 2*ideal but still above healthy max
    n_near_drop = (
        int(
            sum(
                1
                for v in ifis
                if drop == drop
                and abs(v - drop) <= half + 1e-9
                and v > healthy_ifi_max + 1e-6
            )
        )
        if drop == drop and healthy_ifi_max == healthy_ifi_max
        else 0
    )
    return {
        "n_ifi": int(len(ifis)),
        "ifi_ms_head": [round(v, 4) for v in ifis[:80]],
        "ifi_ms_hist": {k: int(hc[k]) for k in sorted(hc, key=lambda x: float(x))},
        "p50": float(np.percentile(arr, 50)),
        "p95": float(np.percentile(arr, 95)),
        "p99": float(np.percentile(arr, 99)),
        "max": float(arr.max()),
        "mean": float(arr.mean()),
        "src": PROVENANCE_MEASURED,
        "t_cap_ms": round(t_cap, 6),
        "t_cap_ms_src": "derived_1000_over_cap_fps",
        "ideal_ifi_ms": round(ideal, 6) if ideal == ideal else None,
        "ideal_ifi_ms_src": "derived_1000_over_src_fps",
        "drop_ifi_ms": round(drop, 6) if drop == drop else None,
        "healthy_ifi_min_ms": round(healthy_ifi_min, 6) if healthy_ifi_min == healthy_ifi_min else None,
        "healthy_ifi_max_ms": round(healthy_ifi_max, 6) if healthy_ifi_max == healthy_ifi_max else None,
        "n_near_ideal": n_near_ideal,
        "n_on_healthy_grid": n_on_healthy_grid,
        "n_near_drop_signature": n_near_drop,
        "n_ge_drop_signature": n_ge_drop,
        "frac_near_ideal": round(n_near_ideal / len(ifis), 4),
        "frac_on_healthy_grid": round(n_on_healthy_grid / len(ifis), 4),
        "frac_ge_drop_signature": round(n_ge_drop / len(ifis), 4),
        "mean_note": (
            "ifi_mean informational only; use hist + p95/p99/max + "
            "frac_ge_drop_signature (IFI > healthy grid max). "
            "max-only headlines forbidden. hold=2@30fps=66.7ms is HEALTHY, not drop."
        ),
    }


def apply_role_attribution(
    rep: dict[str, Any],
    *,
    role: str,
    floor_baseline: Optional[dict[str, Any]] = None,
) -> dict[str, Any]:
    rep = dict(rep)
    rep["role"] = role
    rep["role_src"] = PROVENANCE_CALLER
    if role == "instrument_floor":
        if rep.get("verdict") == "JUDDER_OK":
            rep["verdict"] = "FLOOR_OK"
        elif rep.get("verdict") == "JUDDER_FAIL":
            rep["verdict"] = "FLOOR_IRREGULAR"
        rep["attribution"] = "instrument_floor_ms2109_path"
        rep["attribution_note"] = (
            "INSTRUMENT FLOOR (non-device source or static through same grabber). "
            "Publish hist+tail as floor. Do NOT cite as device motion health."
        )
        rep["device_attributable"] = False
        rep["device_attributable_src"] = PROVENANCE_MEASURED
        return rep

    if role != "device_under_test":
        rep["device_attributable"] = False
        rep["attribution_note"] = f"unknown role={role}"
        return rep

    if floor_baseline is None:
        rep["device_attributable"] = False
        rep["device_attributable_src"] = PROVENANCE_DEFAULT
        rep["attribution_note"] = (
            "NO instrument-floor baseline. Numbers are measured on pixels but "
            "NOT ATTRIBUTABLE to DE10-Nano — MS2109+host ffmpeg may be the tail. "
            "Run --role instrument_floor on host-cadence/static capture first; "
            "pass --floor-json."
        )
        return rep

    fb = floor_baseline
    rep["floor_baseline_label"] = fb.get("label")
    rep["floor_hold_hist"] = fb.get("hold_hist")
    rep["floor_outlier_count"] = fb.get("outlier_count")
    rep["floor_hold_max"] = fb.get("hold_max")
    rep["floor_ifi_p95"] = (fb.get("ifi") or {}).get("p95")
    rep["floor_ifi_max"] = (fb.get("ifi") or {}).get("max")
    rep["floor_verdict"] = fb.get("verdict")
    dev_out = int(rep.get("outlier_count") or 0)
    fl_out = int(fb.get("outlier_count") or 0)
    dev_max = int(rep.get("hold_max") or 0)
    fl_max = int(fb.get("hold_max") or 0)
    exceeds = dev_out >= fl_out + 3 or dev_max >= fl_max + 2
    rep["floor_compare_exceeds"] = exceeds
    rep["device_attributable_src"] = PROVENANCE_MEASURED
    if fb.get("verdict") in ("FLOOR_IRREGULAR", "JUDDER_FAIL") and not exceeds:
        rep["device_attributable"] = False
        rep["attribution_note"] = (
            "Floor irregular; device tail does not exceed floor by margin "
            "(outliers+3 or max_hold+2). NOT ATTRIBUTABLE to device."
        )
    elif exceeds:
        rep["device_attributable"] = True
        rep["attribution_note"] = (
            "Device hold/IFI tail exceeds floor baseline margin — attributable "
            "candidate (motion channel only; not lipsync)."
        )
    else:
        rep["device_attributable"] = True
        rep["attribution_note"] = (
            "Floor baseline present; device within floor envelope — cite floor "
            "hist beside any device claim."
        )
    return rep
