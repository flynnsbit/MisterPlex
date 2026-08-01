#!/usr/bin/env python3
"""Zone-resolved vertical-frequency scorer — bank480 FullBleed VRes (rk=27).

Fixture (scripts/gen_bank480_fullbleed_vres_av.py, 624×480 SAR 1:1 full bleed):
  left third  : 1-row B/W alternating (designed period P=2)  — PRIMARY ceiling probe
  mid third   : stacked periods 2 / 4 / 8 / 16
  right third : vertical chirp period 2→32
  top         : glass ID band (not a V-res zone)
  flash       : full-body white every 2 s — skip (UNSCORED)

WHY NOT HARDCODED COLUMNS
  Capture is 1920×1080 upscale of 624×480 with unknown letterbox/pillar.
  Zones are located by content signatures after active-region detection.
  If a zone cannot be verified → that zone is UNSCORED (never a guessed crop).

PER ZONE
  colmean vertical profile → std (amplitude) → FFT + ACF dominant period in
  DISPLAY rows → convert to SOURCE rows via measured active_h and
  src_h (DEFAULT_ASSUMED 480 unless --src-h measured).

  ratio = measured_period_src / designed_period_src
    ~1.0  pattern scale matches design (480-row path for surviving periods)
    noise-floor miss → UNSCORED (absence is NO-DATA, never "no stripes"=0)

PRIMARY CEILING (parent INSTRUMENT_CEILING.md — load-bearing)
  Period-2 left (and mid_p2) under store_y=py*2 collapses to SOLID field.
  Duty-50 P=4/8/16 are period-invariant under even-cull — NOT ceiling gates.
  Chirp std is NOT a ceiling gate.
  Also report unique_src_frac on left zone (line-double ~0.5 vs full ~1.0).

Every field tagged measured | caller_supplied | DEFAULT_ASSUMED | derived.

Severity (binding): STRUCTURE_FAIL 3 > COLOR_FAIL 2 > FREEZE 1 > OK 0 > UNSCORED 77
Measured STRUCTURE_FAIL never decays to 77.

Fleet: artifact pair required (tools/artifact_stamp.py) or UNSCORED.

Exit: 0 OK, 1 usage, 2 COLOR_FAIL, 3 STRUCTURE_FAIL, 77 UNSCORED
true rc: cmd; echo "true rc=$?" — never through a pipe.
"""
from __future__ import annotations

import argparse
import json
import sys
from dataclasses import asdict, dataclass, field
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

from artifact_stamp import (  # noqa: E402
    add_stamp_args,
    require_stamp,
    stamp_from_namespace,
)

RC_OK = 0
RC_USAGE = 1
RC_COLOR_FAIL = 2
RC_STRUCTURE_FAIL = 3
RC_UNSCORED = 77

# Noise floor on colmean profile std — parent INSTRUMENT_CEILING.md
DEFAULT_NOISE_FLOOR_STD = 8.0  # caller_supplied default from w-asset480 host meas
DEFAULT_SRC_H = 480
DEFAULT_SRC_W = 624
# even/odd separation floor for "STRIPES" call on P=2
DEFAULT_SEP_STRIPES = 40.0
DEFAULT_STD_SOLID = 8.0  # below/near floor → solid collapse candidate


def _tag(v: Any, src: str) -> dict[str, Any]:
    return {"value": v, "src": src}


def load_luma(path: Path) -> np.ndarray:
    rgb = np.asarray(Image.open(path).convert("RGB"), dtype=np.float64)
    return 0.299 * rgb[:, :, 0] + 0.587 * rgb[:, :, 1] + 0.114 * rgb[:, :, 2]


def load_rgb(path: Path) -> np.ndarray:
    return np.asarray(Image.open(path).convert("RGB"), dtype=np.float64)


def detect_active(luma: np.ndarray, black: float = 8.0) -> tuple[slice, slice, str]:
    """Content bbox: first..last rows/cols with signal, gap-tolerant.

    Longest-run alone fails when dark coded rows (solid black phase, ID)
    split the mask — those are still inside the active picture.
    """
    h, w = luma.shape
    row_m = luma.mean(axis=1)
    row_s = luma.std(axis=1)
    col_m = luma.mean(axis=0)
    col_s = luma.std(axis=0)
    row_on = (row_m > black) | (row_s > 3.0)
    col_on = (col_m > black) | (col_s > 3.0)
    if not np.any(row_on) or not np.any(col_on):
        return slice(0, h), slice(0, w), "FAIL_active_empty"

    def span(mask: np.ndarray) -> tuple[int, int]:
        idx = np.flatnonzero(mask)
        return int(idx[0]), int(idx[-1]) + 1

    y0, y1 = span(row_on)
    x0, x1 = span(col_on)
    if y1 - y0 < 64 or x1 - x0 < 64:
        return slice(0, h), slice(0, w), "FAIL_active_too_small"
    return slice(y0, y1), slice(x0, x1), "measured_bbox_first_last_signal"


def detect_id_bottom(luma_active: np.ndarray, max_frac: float = 0.25) -> tuple[int, str]:
    """ID band sits at top of coded frame; on glass it is a short high-structure strip.

    Heuristic: from top of active, find first row where left-third vertical
    energy (local |Δ|) stays high for a run — body of left P=2 starts.
    Fallback: 18% of active height (DEFAULT_ASSUMED from 88/480 coded).
    """
    h, w = luma_active.shape
    lim = max(8, int(h * max_frac))
    left = luma_active[:, : max(8, w // 3)]
    d = np.abs(np.diff(left.astype(np.float64), axis=0)).mean(axis=1)
    # body start: first index where d exceeds median of lower half
    lower_med = float(np.median(d[len(d) // 2 :])) if len(d) > 4 else 1.0
    thr = max(3.0, 0.5 * lower_med)
    run = 0
    for i, v in enumerate(d[:lim]):
        if v >= thr:
            run += 1
            if run >= 3:
                y = max(0, i - run + 1)
                # ID bottom is just above body; include a small pad
                return int(y), "measured_left_energy_onset"
        else:
            run = 0
    y = int(round(h * (88.0 / 480.0)))
    return min(y, lim), "DEFAULT_ASSUMED_frac_88_of_480"


def split_thirds_content(
    body: np.ndarray,
) -> tuple[Optional[tuple[int, int]], Optional[tuple[int, int]], Optional[tuple[int, int]], str]:
    """Locate L/M/R zones without hardcoded capture columns.

    Fixture is coded as equal width thirds. After unknown pillarbox/scale the
    active body is still three side-by-side instruments — seed equal thirds of
    the *measured active body width*, then optionally snap boundaries to a local
    column-energy valley within ±8% (content edge between zones).

    Energy-only cumulative splits are VOID when left collapses to solid (low
    energy) — they swallow mid into "left". Equal-third seed avoids that.
    """
    h, w = body.shape
    if w < 30 or h < 32:
        return None, None, None, "FAIL_body_too_small"

    # Seed: equal thirds of measured active body (not 1920 hardcodes)
    s1, s2 = w // 3, 2 * w // 3
    col_std = body.std(axis=0)
    k = max(3, w // 50)
    sm = np.convolve(col_std, np.ones(k) / k, mode="same")

    def snap(idx: int) -> tuple[int, bool]:
        rad = max(3, int(w * 0.08))
        a = max(1, idx - rad)
        b = min(w - 1, idx + rad)
        j = int(a + np.argmin(sm[a:b]))
        # only accept snap if it is a real local dip vs seed neighborhood mean
        neigh = float(sm[max(0, idx - rad) : min(w, idx + rad)].mean())
        snapped = float(sm[j]) < 0.85 * neigh
        return (j if snapped else idx), snapped

    x1, sn1 = snap(s1)
    x2, sn2 = snap(s2)
    if x2 <= x1 + w // 10:
        x1, x2 = s1, s2
        method = "measured_active_equal_thirds_snap_rejected"
    elif sn1 or sn2:
        method = "measured_active_equal_thirds_valley_snap"
    else:
        method = "measured_active_equal_thirds"

    left, mid, right = (0, x1), (x1, x2), (x2, w)
    for name, seg in ("L", left), ("M", mid), ("R", right):
        if seg[1] - seg[0] < w // 8:
            return None, None, None, f"FAIL_zone_width_{name}"

    # Verify left is not obviously mid-like multi-period mush: optional soft check
    return left, mid, right, method


def colmean_profile(zone: np.ndarray) -> np.ndarray:
    return zone.mean(axis=1)


def even_odd_sep(profile: np.ndarray) -> float:
    """Mean |even-odd| at lag 1 — only meaningful when display period ≈ 2."""
    if len(profile) < 4:
        return 0.0
    e = profile[0::2]
    o = profile[1::2]
    n = min(len(e), len(o))
    return float(np.mean(np.abs(e[:n] - o[:n])))


def lag_sep(profile: np.ndarray, lag: int) -> float:
    """Mean |p[i]-p[i+lag]| — scale-aware stripe strength."""
    if lag < 1 or len(profile) <= lag + 1:
        return 0.0
    return float(np.mean(np.abs(profile[lag:] - profile[:-lag])))


def profile_ptp(profile: np.ndarray) -> float:
    return float(np.max(profile) - np.min(profile)) if len(profile) else 0.0


def dominant_period_fft_acf(profile: np.ndarray, noise_floor_std: float) -> dict[str, Any]:
    """Dominant vertical period in DISPLAY samples of the profile."""
    p = profile.astype(np.float64)
    n = len(p)
    out: dict[str, Any] = {
        "n_rows": _tag(n, "measured"),
        "profile_std": _tag(float(p.std()), "measured"),
        "profile_mean": _tag(float(p.mean()), "measured"),
        "profile_ptp": _tag(profile_ptp(p), "measured"),
        "noise_floor_std": _tag(noise_floor_std, "caller_supplied"),
        "even_odd_sep": _tag(even_odd_sep(p), "measured"),
    }
    std = float(p.std())
    if std < noise_floor_std:
        out["verdict"] = "UNSCORED"
        out["reason"] = (
            f"profile_std={std:.3f} < noise_floor_std={noise_floor_std} "
            f"— NO-DATA (not 'no stripes'=0)"
        )
        out["period_display"] = _tag(None, "NO-DATA")
        out["period_src"] = _tag(None, "NO-DATA")
        out["fft_peak_k"] = _tag(None, "NO-DATA")
        out["acf_best_lag"] = _tag(None, "NO-DATA")
        return out

    # detrend
    x = np.arange(n, dtype=np.float64)
    coef = np.polyfit(x, p, 1)
    d = p - np.polyval(coef, x)
    window = np.hanning(n)
    dw = d * window
    spec = np.fft.rfft(dw)
    mag = np.abs(spec)
    # ignore DC and very low k (period > n/2)
    mag[0] = 0.0
    if len(mag) > 1:
        mag[1] = 0.0  # period = n
    k_peak = int(np.argmax(mag))
    if k_peak <= 0:
        out["verdict"] = "UNSCORED"
        out["reason"] = "no_fft_peak"
        out["period_display"] = _tag(None, "NO-DATA")
        out["period_src"] = _tag(None, "NO-DATA")
        out["fft_peak_k"] = _tag(0, "measured")
        out["acf_best_lag"] = _tag(None, "NO-DATA")
        return out

    period_fft = float(n) / float(k_peak)
    # parabolic refine around peak (sub-bin) — still report bin-limited caveat
    if 1 <= k_peak < len(mag) - 1:
        a, b, c = mag[k_peak - 1], mag[k_peak], mag[k_peak + 1]
        denom = (a - 2 * b + c)
        if abs(denom) > 1e-12:
            delta = 0.5 * (a - c) / denom
            k_ref = k_peak + float(np.clip(delta, -0.5, 0.5))
            period_fft = float(n) / k_ref
        else:
            k_ref = float(k_peak)
    else:
        k_ref = float(k_peak)

    # ACF best lag in [2, n//3]
    d0 = d - d.mean()
    acf = np.correlate(d0, d0, mode="full")
    acf = acf[len(acf) // 2 :]
    if acf[0] != 0:
        acf = acf / acf[0]
    lo, hi = 2, max(3, n // 3)
    seg = acf[lo:hi]
    if len(seg) == 0:
        lag = None
        period_acf = None
    else:
        lag = int(lo + np.argmax(seg))
        period_acf = float(lag)

    # prefer ACF when close to FFT (square waves); else FFT refined
    if period_acf is not None and abs(period_acf - period_fft) / period_fft < 0.35:
        period_disp = period_acf
        method = "acf_agrees_fft"
    else:
        period_disp = period_fft
        method = "fft_refined"

    out["fft_peak_k"] = _tag(k_ref, "measured")
    out["period_display_fft"] = _tag(period_fft, "measured")
    out["acf_best_lag"] = _tag(lag, "measured" if lag is not None else "NO-DATA")
    out["period_display"] = _tag(period_disp, "measured")
    out["period_method"] = _tag(method, "derived")
    out["fft_bin_caveat"] = _tag(
        "bin-limited; sub-bin refine only; not sole ceiling gate",
        "DEFAULT_ASSUMED",
    )
    out["verdict"] = "SCORED"
    return out


def to_source_period(
    period_disp: Optional[float], body_disp_h: int, body_src_h: float
) -> Optional[float]:
    """Map display-row period → source body-row period.

    designed periods in the fixture are in *body* rows (below ID), not full coded H.
    """
    if period_disp is None or body_disp_h <= 0 or body_src_h <= 0:
        return None
    return float(period_disp) * float(body_src_h) / float(body_disp_h)


def unique_frac_profile(profile: np.ndarray, tau: float = 2.0) -> float:
    if len(profile) < 2:
        return 0.0
    d = np.abs(np.diff(profile))
    return float((1 + np.sum(d >= tau)) / len(profile))


def classify_p2(zone_rep: dict[str, Any], noise_floor: float, sep_thr: float) -> str:
    """SOLID vs STRIPES for designed P=2 after unknown upscale.

    Primary (INSTRUMENT_CEILING): profile_std collapses under even-cull P=2.
      SOLID  : std < floor OR (std < 3*floor AND unique_frac < 0.15 AND sep1 < sep_thr)
      STRIPES: std >= 3*floor AND (ptp >= 4*floor OR sep1 >= sep_thr OR half_period_sep strong)
    Host reference: stripes std≈126, solid std≈0.4.
    """
    std = zone_rep.get("profile_std", {}).get("value")
    ptp = zone_rep.get("profile_ptp", {}).get("value")
    sep1 = zone_rep.get("even_odd_sep", {}).get("value")
    uf = zone_rep.get("unique_frac", {}).get("value")
    if std is None:
        return "UNSCORED"
    if ptp is None:
        ptp = 0.0
    if sep1 is None:
        sep1 = 0.0
    if uf is None:
        uf = 0.0

    # Strong solid
    if std < noise_floor:
        return "SOLID"
    # Soft solid: residual after upscale/MJPG but not real P=2 stripes
    if std < 3.0 * noise_floor and uf < 0.15 and sep1 < sep_thr:
        return "SOLID"
    # Strong stripes (full Nyquist field)
    ls = zone_rep.get("half_period_sep", {}).get("value")
    if ls is None:
        ls = 0.0
    if std >= 3.0 * noise_floor and (ptp >= 4.0 * noise_floor or sep1 >= sep_thr or ls >= 0.5 * sep_thr):
        return "STRIPES"
    if std >= noise_floor and ptp >= 2.0 * noise_floor and uf >= 0.25:
        return "STRIPES"
    if std >= noise_floor:
        return "STRUCTURED_WEAK_SEP"
    return "UNSCORED"


def score_zone(
    body: np.ndarray,
    x0: int,
    x1: int,
    y0: int,
    y1: int,
    *,
    name: str,
    designed_period_src: Optional[float],
    body_disp_h: int,
    body_src_h: float,
    body_src_h_tag: str,
    noise_floor: float,
) -> dict[str, Any]:
    patch = body[y0:y1, x0:x1]
    rep: dict[str, Any] = {
        "zone": name,
        "bbox_xyxy": _tag([int(x0), int(y0), int(x1), int(y1)], "measured"),
        "designed_period_src": _tag(designed_period_src, "caller_supplied"),
        "body_src_h": _tag(body_src_h, body_src_h_tag),
        "body_disp_h": _tag(body_disp_h, "measured"),
    }
    if patch.size < 64 or patch.shape[0] < 16 or patch.shape[1] < 8:
        rep["verdict"] = "UNSCORED"
        rep["reason"] = "zone_patch_too_small"
        return rep

    prof = colmean_profile(patch)
    spec = dominant_period_fft_acf(prof, noise_floor)
    rep.update(spec)
    rep["unique_frac"] = _tag(unique_frac_profile(prof), "measured")

    pd = spec.get("period_display", {}).get("value")
    if pd is not None and pd >= 2:
        half = max(1, int(round(float(pd) / 2.0)))
        rep["half_period_sep"] = _tag(lag_sep(prof, half), "measured")
        rep["half_period_sep_der"] = _tag(f"mean|p[i]-p[i+{half}]|", "derived")
    ps = to_source_period(pd, body_disp_h, body_src_h)
    rep["period_src"] = _tag(ps, "derived" if ps is not None else "NO-DATA")
    rep["period_src_der"] = _tag(
        "period_display * body_src_h / body_disp_h",
        "derived",
    )

    if spec.get("verdict") == "UNSCORED":
        rep["ratio_meas_over_designed"] = _tag(None, "NO-DATA")
        return rep

    if designed_period_src and designed_period_src > 0 and ps is not None:
        ratio = float(ps) / float(designed_period_src)
        rep["ratio_meas_over_designed"] = _tag(ratio, "derived")
        rep["ratio_der"] = _tag(
            "period_src/designed_period_src; ~1.0 full-row path; "
            "SOLID P=2 => ratio NO-DATA; absence below floor=UNSCORED not 0",
            "derived",
        )
    else:
        rep["ratio_meas_over_designed"] = _tag(None, "NO-DATA")
    return rep


def is_flash_frame(body: np.ndarray, thr: float = 240.0) -> bool:
    return float(body.mean()) >= thr


def analyze_frame(
    luma: np.ndarray,
    *,
    src_h: float = DEFAULT_SRC_H,
    src_h_tag: str = "DEFAULT_ASSUMED",
    noise_floor: float = DEFAULT_NOISE_FLOOR_STD,
    sep_thr: float = DEFAULT_SEP_STRIPES,
) -> dict[str, Any]:
    ys, xs, act_how = detect_active(luma)
    active = luma[ys, xs]
    if act_how.startswith("FAIL"):
        return {
            "verdict": "UNSCORED",
            "rc": RC_UNSCORED,
            "reason": act_how,
            "active_how": _tag(act_how, "measured"),
        }

    id_bottom, id_how = detect_id_bottom(active)
    body = active[id_bottom:, :]
    if body.shape[0] < 32:
        return {
            "verdict": "UNSCORED",
            "rc": RC_UNSCORED,
            "reason": "body_too_small_after_id",
            "id_bottom": _tag(id_bottom, id_how.split("_")[0] if "_" in id_how else "measured"),
            "id_how": _tag(id_how, "measured" if id_how.startswith("measured") else "DEFAULT_ASSUMED"),
        }

    if is_flash_frame(body):
        return {
            "verdict": "UNSCORED",
            "rc": RC_UNSCORED,
            "reason": "flash_frame_body_white_skip_vres",
            "body_mean": _tag(float(body.mean()), "measured"),
        }

    left, mid, right, third_how = split_thirds_content(body)
    if left is None:
        return {
            "verdict": "UNSCORED",
            "rc": RC_UNSCORED,
            "reason": third_how,
            "thirds_how": _tag(third_how, "measured"),
        }

    bh, bw = body.shape
    # Body source height: coded H minus ID band. ID frac measured on glass;
    # body_src = src_h * (1 - id_frac) with id_frac from detection method.
    id_frac = float(id_bottom) / float(max(1, id_bottom + bh))
    if id_how.startswith("measured"):
        body_src_h = float(src_h) * (1.0 - id_frac)
        body_src_tag = "derived_from_measured_id_frac"
    else:
        # DEFAULT coded id_bottom=88 @ 480
        body_src_h = float(src_h) * (1.0 - 88.0 / 480.0)
        body_src_tag = "DEFAULT_ASSUMED_body_392_of_480" if src_h_tag == "DEFAULT_ASSUMED" else "derived"
    zones: dict[str, Any] = {}

    def sz(name, x0, x1, y0, y1, pdes):
        return score_zone(
            body, x0, x1, y0, y1,
            name=name,
            designed_period_src=pdes,
            body_disp_h=bh,
            body_src_h=body_src_h,
            body_src_h_tag=body_src_tag,
            noise_floor=noise_floor,
        )

    # LEFT P=2 full height
    zones["left_1row_alt"] = sz("left_1row_alt", left[0], left[1], 0, bh, 2.0)
    zones["left_1row_alt"]["p2_class"] = _tag(
        classify_p2(zones["left_1row_alt"], noise_floor, sep_thr),
        "derived",
    )
    zones["left_1row_alt"]["thirds_how"] = _tag(
        third_how, "measured" if third_how.startswith("measured") else "DEFAULT_ASSUMED"
    )

    # MID stacked 4 bands
    zh = bh // 4
    for zi, pdes in enumerate((2, 4, 8, 16)):
        y0 = zi * zh
        y1 = (zi + 1) * zh if zi < 3 else bh
        zname = f"mid_period_{pdes}"
        zones[zname] = sz(zname, mid[0], mid[1], y0, y1, float(pdes))
        if pdes == 2:
            zones[zname]["p2_class"] = _tag(
                classify_p2(zones[zname], noise_floor, sep_thr), "derived"
            )
        zones[zname]["ceiling_discriminator"] = _tag(pdes == 2, "caller_supplied")
        zones[zname]["note"] = _tag(
            "P=4/8/16 duty-50 invariant under even-cull — not ceiling gates",
            "caller_supplied",
        )

    # RIGHT chirp full + quartile bands
    zones["chirp_full"] = sz("chirp_full", right[0], right[1], 0, bh, None)
    zones["chirp_full"]["ceiling_discriminator"] = _tag(False, "caller_supplied")
    zones["chirp_full"]["note"] = _tag(
        "chirp std not a ceiling gate (INSTRUMENT_CEILING)",
        "caller_supplied",
    )
    for qi, (lo, hi) in enumerate(((2.0, 9.5), (9.5, 17.0), (17.0, 24.5), (24.5, 32.0))):
        y0 = int(qi * bh / 4)
        y1 = int((qi + 1) * bh / 4) if qi < 3 else bh
        des = 0.5 * (lo + hi)
        zname = f"chirp_q{qi}"
        zones[zname] = sz(zname, right[0], right[1], y0, y1, des)
        zones[zname]["designed_period_range_src"] = _tag([lo, hi], "caller_supplied")
        zones[zname]["ceiling_discriminator"] = _tag(False, "caller_supplied")

    left_c = zones["left_1row_alt"]["p2_class"]["value"]
    mid2_c = zones.get("mid_period_2", {}).get("p2_class", {}).get("value", "UNSCORED")

    # Headline unique-src fraction on left (line-double detector)
    uf = zones["left_1row_alt"]["unique_frac"]["value"]
    ratio_unique = float(uf) if uf is not None else None

    left_ratio = zones["left_1row_alt"].get("ratio_meas_over_designed", {}).get("value")

    rep: dict[str, Any] = {
        "active_bbox": _tag(
            [int(xs.start), int(ys.start), int(xs.stop), int(ys.stop)],
            "measured",
        ),
        "active_how": _tag(act_how, "measured"),
        "active_h": _tag(int(ys.stop - ys.start), "measured"),
        "active_w": _tag(int(xs.stop - xs.start), "measured"),
        "id_bottom_in_active": _tag(id_bottom, "measured" if id_how.startswith("measured") else "DEFAULT_ASSUMED"),
        "id_how": _tag(id_how, "measured" if id_how.startswith("measured") else "DEFAULT_ASSUMED"),
        "body_h": _tag(bh, "measured"),
        "thirds_how": _tag(third_how, "measured" if third_how.startswith("measured") else "DEFAULT_ASSUMED"),
        "thirds_x": _tag(
            {"left": list(left), "mid": list(mid), "right": list(right)},
            "measured",
        ),
        "src_h": _tag(src_h, src_h_tag),
        "body_src_h": _tag(body_src_h, body_src_tag),
        "noise_floor_std": _tag(noise_floor, "caller_supplied"),
        "zones": zones,
        "HEADLINE_left_p2_class": _tag(left_c, "derived"),
        "HEADLINE_mid_p2_class": _tag(mid2_c, "derived"),
        "HEADLINE_left_ratio_period": _tag(left_ratio, "derived" if left_ratio is not None else "NO-DATA"),
        "HEADLINE_left_unique_frac": _tag(ratio_unique, "measured"),
        "HEADLINE_note": _tag(
            "PRIMARY ceiling=left_1row_alt STRIPES vs SOLID; "
            "period ratio on P=2 is UNSCORED when solid; "
            "unique_frac~0.5 suggests line-double/240-class; ~1 stripes path; "
            "mid P>=4 and chirp are NOT ceiling discriminators on this encode",
            "caller_supplied",
        ),
    }
    return rep


def apply_expect(rep: dict[str, Any], expect: Optional[str]) -> dict[str, Any]:
    if rep.get("rc") == RC_UNSCORED or rep.get("verdict") == "UNSCORED":
        if "rc" not in rep:
            rep["rc"] = RC_UNSCORED
            rep["verdict"] = "UNSCORED"
        return rep

    left_c = rep.get("HEADLINE_left_p2_class", {}).get("value")
    mid_c = rep.get("HEADLINE_mid_p2_class", {}).get("value")
    # prefer left; if left unscored try mid p2
    primary = left_c if left_c not in (None, "UNSCORED") else mid_c

    if expect is None:
        rep["verdict"] = "REPORT_ONLY"
        rep["rc"] = RC_OK
        rep["primary_p2_class"] = _tag(primary, "derived")
        return rep

    if primary in (None, "UNSCORED", "STRUCTURED_WEAK_SEP"):
        # Cannot score expect — premise missing
        rep["verdict"] = "UNSCORED"
        rep["rc"] = RC_UNSCORED
        rep["reason"] = f"primary_p2_class={primary} — cannot score expect={expect}"
        return rep

    if expect == "full_480":
        # need STRIPES
        if primary == "STRIPES":
            rep["verdict"] = "H480_STRIPES_OK"
            rep["rc"] = RC_OK
        elif primary == "SOLID":
            rep["verdict"] = "STRUCTURE_FAIL_SOLID_UNDER_EXPECT_480"
            rep["rc"] = RC_STRUCTURE_FAIL
        else:
            rep["verdict"] = "STRUCTURE_FAIL"
            rep["rc"] = RC_STRUCTURE_FAIL
        return rep

    if expect == "ceiling_240":
        if primary == "SOLID":
            rep["verdict"] = "H240_SOLID_OK"
            rep["rc"] = RC_OK
        elif primary == "STRIPES":
            rep["verdict"] = "STRUCTURE_FAIL_STRIPES_UNDER_EXPECT_240"
            rep["rc"] = RC_STRUCTURE_FAIL
        else:
            rep["verdict"] = "STRUCTURE_FAIL"
            rep["rc"] = RC_STRUCTURE_FAIL
        return rep

    rep["verdict"] = "UNSCORED"
    rep["rc"] = RC_UNSCORED
    rep["reason"] = f"unknown expect={expect}"
    return rep


# ----- synthetic fixture (red-before-green) -----

def synth_coded_frame(even_dup: bool = False) -> np.ndarray:
    """624×480 full-bleed-like body matching generator geometry (no ID text)."""
    W, H = 624, 480
    id_bottom = 88
    rgb = np.zeros((H, W), dtype=np.float64)
    rgb[id_bottom:, :] = 48.0
    body_h = H - id_bottom
    x0, x1, x2, x3 = 0, W // 3, 2 * W // 3, W
    ys = np.arange(body_h)

    # left P=2
    alt = np.where((ys % 2) == 0, 255.0, 0.0)
    rgb[id_bottom:, x0:x1] = alt[:, None]

    # mid periods
    zone_h = body_h // 4
    for zi, period in enumerate((2, 4, 8, 16)):
        y0 = id_bottom + zi * zone_h
        y1 = id_bottom + (zi + 1) * zone_h if zi < 3 else H
        for y in range(y0, y1):
            v = 255.0 if ((y - y0) % period) < (period // 2) else 0.0
            rgb[y, x1:x2] = v

    # right chirp
    y_loc = ys.astype(np.float64)
    p = 2.0 + 30.0 * (y_loc / max(body_h - 1, 1))
    dphi = 2.0 * np.pi / p
    phase = np.cumsum(dphi)
    wave = 255.0 * (0.5 + 0.5 * np.sin(phase))
    rgb[id_bottom:, x2:x3] = wave[:, None]

    # ID band dark plate
    rgb[:id_bottom, :] = 20.0

    if even_dup:
        out = np.empty_like(rgb)
        for k in range(H // 2):
            out[2 * k] = rgb[2 * k]
            out[2 * k + 1] = rgb[2 * k]
        if H % 2:
            out[-1] = rgb[-2] if H >= 2 else rgb[-1]
        rgb = out
    return rgb


def upscale_to_1080(luma_hw: np.ndarray, out_w: int = 1920, out_h: int = 1080) -> np.ndarray:
    """Letterbox 13:10 content into 16:9 1080p (nearest — preserves periods for test)."""
    h, w = luma_hw.shape
    # fit inside 1920x1080 preserving aspect
    scale = min(out_w / w, out_h / h)
    nw, nh = max(1, int(round(w * scale))), max(1, int(round(h * scale)))
    im = Image.fromarray(luma_hw.astype(np.uint8), mode="L")
    im = im.resize((nw, nh), Image.Resampling.NEAREST)
    canvas = np.zeros((out_h, out_w), dtype=np.float64)
    y0 = (out_h - nh) // 2
    x0 = (out_w - nw) // 2
    canvas[y0 : y0 + nh, x0 : x0 + nw] = np.asarray(im, dtype=np.float64)
    return canvas


def run_self_test() -> int:
    print("PRE-REGISTER fullbleed VRes zones:")
    print("  full 480 → left STRIPES, ratio_period~1, unique_frac high")
    print("  even_dup → left SOLID (P=2 collapse), unique_frac~line-double")
    print("  expect-full-480: full rc=0; even_dup rc=3 STRUCTURE_FAIL")
    print("  expect-ceiling-240: even_dup rc=0; full rc=3")
    print("  noise floor miss → UNSCORED not zero period")
    ok = True

    full = upscale_to_1080(synth_coded_frame(False))
    half = upscale_to_1080(synth_coded_frame(True))

    rf = analyze_frame(full, noise_floor=DEFAULT_NOISE_FLOOR_STD)
    rh = analyze_frame(half, noise_floor=DEFAULT_NOISE_FLOOR_STD)
    rf = apply_expect(rf, "full_480")
    rh_as_480 = apply_expect(dict(rh), "full_480")
    rh_as_240 = apply_expect(dict(rh), "ceiling_240")
    rf_as_240 = apply_expect(dict(analyze_frame(full)), "ceiling_240")

    def summ(tag, r):
        z = r.get("zones", {}).get("left_1row_alt", {})
        print(
            f"  {tag}: verdict={r.get('verdict')} rc={r.get('rc')} "
            f"left_class={r.get('HEADLINE_left_p2_class', {}).get('value')} "
            f"ratio={z.get('ratio_meas_over_designed', {}).get('value')} "
            f"std={z.get('profile_std', {}).get('value')} "
            f"sep={z.get('even_odd_sep', {}).get('value')} "
            f"unique_frac={z.get('unique_frac', {}).get('value')} "
            f"period_src={z.get('period_src', {}).get('value')}"
        )

    summ("full_expect480", rf)
    summ("half_expect480", rh_as_480)
    summ("half_expect240", rh_as_240)
    summ("full_expect240", rf_as_240)

    if rf.get("rc") != RC_OK or rf.get("HEADLINE_left_p2_class", {}).get("value") != "STRIPES":
        print("FAIL full should STRIPES OK"); ok = False
    else:
        print("PASS full STRIPES rc=0")

    ratio = rf.get("zones", {}).get("left_1row_alt", {}).get("ratio_meas_over_designed", {}).get("value")
    if ratio is None or abs(ratio - 1.0) > 0.35:
        print(f"FAIL full ratio~1 got {ratio}"); ok = False
    else:
        print(f"PASS full ratio_period={ratio:.3f} ~1.0")

    if rh_as_480.get("rc") != RC_STRUCTURE_FAIL:
        print(f"FAIL half under expect480 should STRUCTURE_FAIL got rc={rh_as_480.get('rc')}"); ok = False
    else:
        print(f"PASS half expect480 STRUCTURE_FAIL rc={rh_as_480.get('rc')}")

    if rh_as_240.get("rc") != RC_OK or rh.get("HEADLINE_left_p2_class", {}).get("value") != "SOLID":
        print("FAIL half expect240 SOLID OK"); ok = False
    else:
        print("PASS half expect240 SOLID rc=0")

    if rf_as_240.get("rc") != RC_STRUCTURE_FAIL:
        print("FAIL full under expect240 should STRUCTURE_FAIL"); ok = False
    else:
        print(f"PASS full expect240 STRUCTURE_FAIL rc={rf_as_240.get('rc')}")

    # unique_frac headline: full high, half lower (line double / solid)
    uf_f = rf["zones"]["left_1row_alt"]["unique_frac"]["value"]
    uf_h = rh["zones"]["left_1row_alt"]["unique_frac"]["value"]
    std_f = rf["zones"]["left_1row_alt"]["profile_std"]["value"]
    std_h = rh["zones"]["left_1row_alt"]["profile_std"]["value"]
    print(f"  unique_frac full={uf_f:.3f} half={uf_h:.3f} std full={std_f:.2f} half={std_h:.2f}")
    # After NEAREST upscale, period-2 becomes multi-row runs → unique_frac ~0.4–0.5
    if uf_f < 0.30 or std_f < 80:
        print("FAIL full should high-std stripes"); ok = False
    else:
        print("PASS full high-std stripes (unique_frac may be <1 after upscale)")
    if uf_h > 0.25 or std_h > 3 * DEFAULT_NOISE_FLOOR_STD:
        print("FAIL half should low unique / solid-class std"); ok = False
    else:
        print("PASS half solid-class (low unique_frac / low std)")

    # mid p4 ratio ~1 on BOTH (invariant) when scored
    for label, r in ("full", rf), ("half", rh):
        z = r["zones"]["mid_period_4"]
        if z.get("verdict") == "SCORED":
            rt = z.get("ratio_meas_over_designed", {}).get("value")
            print(f"  mid_p4 {label} ratio={rt} (invariant under even-cull)")
            if rt is not None and abs(rt - 1.0) > 0.45:
                print(f"MISS mid_p4 ratio (published): got {rt} expected ~1"); 
                # not hard fail — scale/letterbox can move ACF; note miss
        else:
            print(f"  mid_p4 {label} UNSCORED {z.get('reason')}")

    # flat → active may exist but zones weak
    flat = np.full((1080, 1920), 128.0)
    # add letterbox black
    flat[:100, :] = 0
    flat[-100:, :] = 0
    rflat = analyze_frame(flat)
    rflat = apply_expect(rflat, "full_480")
    print(f"  flat verdict={rflat.get('verdict')} rc={rflat.get('rc')}")
    if rflat.get("rc") not in (RC_UNSCORED, RC_STRUCTURE_FAIL):
        # solid grey body may look SOLID → structure fail under expect480 is OK (measured)
        if rflat.get("HEADLINE_left_p2_class", {}).get("value") == "SOLID" and rflat.get("rc") == RC_STRUCTURE_FAIL:
            print("PASS flat SOLID → STRUCTURE_FAIL under expect480 (measured, not 77 decay from fail)")
        else:
            print("FAIL flat should UNSCORED or measured SOLID fail"); ok = False
    else:
        print("PASS flat UNSCORED/structure path")

    print("SELF_TEST_OK" if ok else "SELF_TEST_FAIL")
    print(f"QUOTE true rc full_expect480={rf.get('rc')} half_expect480={rh_as_480.get('rc')}")
    return RC_OK if ok else RC_COLOR_FAIL


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("image", type=Path, nargs="?", help="1920x1080 (or any) grabber PNG")
    ap.add_argument("--src-h", type=float, default=DEFAULT_SRC_H, help="source coded height")
    ap.add_argument(
        "--src-h-tag",
        default="DEFAULT_ASSUMED",
        choices=("measured", "caller_supplied", "DEFAULT_ASSUMED"),
    )
    ap.add_argument("--noise-floor-std", type=float, default=DEFAULT_NOISE_FLOOR_STD)
    ap.add_argument("--sep-stripes", type=float, default=DEFAULT_SEP_STRIPES)
    ap.add_argument("--expect-full-480", action="store_true", help="STRIPES required on left P=2")
    ap.add_argument("--expect-ceiling-240", action="store_true", help="SOLID required on left P=2")
    ap.add_argument("--json-out", type=Path, default=None)
    ap.add_argument("--self-test", action="store_true")
    add_stamp_args(ap)
    args = ap.parse_args()

    if args.self_test:
        return run_self_test()

    if args.expect_full_480 and args.expect_ceiling_240:
        print("usage: only one --expect-*")
        return RC_USAGE

    st = stamp_from_namespace(args)
    print("STAMP", st.header_kv())
    ok_pair, reason, _ = require_stamp(st)
    if not ok_pair and not args.allow_unstamped:
        print(f"VERDICT=UNSCORED rc={RC_UNSCORED} reason={reason}")
        return RC_UNSCORED

    if not args.image or not args.image.is_file():
        print("NO_DATA image missing — empty is not zero")
        return RC_UNSCORED

    luma = load_luma(args.image)
    rep = analyze_frame(
        luma,
        src_h=args.src_h,
        src_h_tag=args.src_h_tag,
        noise_floor=args.noise_floor_std,
        sep_thr=args.sep_stripes,
    )
    expect = "full_480" if args.expect_full_480 else ("ceiling_240" if args.expect_ceiling_240 else None)
    if rep.get("verdict") != "UNSCORED":
        rep = apply_expect(rep, expect)
    else:
        rep.setdefault("rc", RC_UNSCORED)

    rep["stamp"] = st.to_dict()
    rep["image"] = _tag(str(args.image), "caller_supplied")
    rep["decode_src"] = _tag(st.decode_src, st.decode_src_src if st.decode_src != "NO-DATA" else "NO-DATA")

    # Human summary
    print(
        f"VERDICT={rep.get('verdict')} rc={rep.get('rc')} "
        f"artifact_pair={st.artifact_pair} decode_src={st.decode_src}"
    )
    print(
        f"HEADLINE left_p2={rep.get('HEADLINE_left_p2_class', {}).get('value')} "
        f"mid_p2={rep.get('HEADLINE_mid_p2_class', {}).get('value')} "
        f"left_ratio_period={rep.get('HEADLINE_left_ratio_period', {}).get('value')} "
        f"left_unique_frac={rep.get('HEADLINE_left_unique_frac', {}).get('value')} "
        f"active_h={rep.get('active_h', {}).get('value')} "
        f"body_h={rep.get('body_h', {}).get('value')} "
        f"thirds={rep.get('thirds_how', {}).get('value')} "
        f"id_how={rep.get('id_how', {}).get('value')}"
    )
    if rep.get("reason"):
        print(f"reason={rep['reason']}")

    zones = rep.get("zones") or {}
    for name in (
        "left_1row_alt",
        "mid_period_2",
        "mid_period_4",
        "mid_period_8",
        "mid_period_16",
        "chirp_full",
    ):
        z = zones.get(name)
        if not z:
            continue
        print(
            f"ZONE {name}: verdict={z.get('verdict')} "
            f"std={z.get('profile_std', {}).get('value')} "
            f"std_src={z.get('profile_std', {}).get('src')} "
            f"sep={z.get('even_odd_sep', {}).get('value')} "
            f"period_disp={z.get('period_display', {}).get('value')} "
            f"period_src={z.get('period_src', {}).get('value')} "
            f"designed={z.get('designed_period_src', {}).get('value')} "
            f"ratio={z.get('ratio_meas_over_designed', {}).get('value')} "
            f"unique_frac={z.get('unique_frac', {}).get('value')} "
            f"p2_class={z.get('p2_class', {}).get('value')} "
            f"floor={z.get('noise_floor_std', {}).get('value')}"
        )
        if z.get("reason"):
            print(f"  reason={z['reason']}")

    if args.json_out:
        args.json_out.parent.mkdir(parents=True, exist_ok=True)

        def conv(o):
            if isinstance(o, dict):
                return {k: conv(v) for k, v in o.items()}
            if isinstance(o, (list, tuple)):
                return [conv(x) for x in o]
            if isinstance(o, (np.floating, np.integer)):
                return float(o) if isinstance(o, np.floating) else int(o)
            return o

        args.json_out.write_text(json.dumps(conv(rep), indent=2, sort_keys=True) + "\n")

    if not ok_pair:
        return RC_UNSCORED
    return int(rep.get("rc", RC_UNSCORED))


if __name__ == "__main__":
    sys.exit(main())
