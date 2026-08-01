#!/usr/bin/env python3
"""Attribute residual A/V offset spread: video quantisation vs daemon fields.

Host-only. Reads parent-captured avsync JSON + optional sixfield rec*.txt.
Does NOT touch the device.

Context (parent 2026-08-01, corrected):
  - 117 ms bimodality = INSTRUMENT ARTIFACT (OLD ffmpeg argv, no wallclock/copyts).
  - NEW argv (wallclock both + copyts + start_at_zero): n=16, range 25.00 ms.
  - flash_onset_n_interp=0 on essentially all flashes → per-pair video onset
    is quantised to capture frame period T (~33 ms @ 30 fps). Beep hop ~2 ms.
  - Per-pair quant σ ≈ T/√12 does NOT set the floor on the *run median*:
    SE(median) ≈ 1.2533·σ/√n_pairs. With n_pairs≈44–45, SE≈1.8 ms and
    E[range across 16 runs]≈6.4 ms. Observed 25 ms ⇒ ~20 ms unattributed
    residual after averaging. Never publish "cannot resolve below ~33 ms"
    as a median-floor claim (that conflates per-pair with per-run-median).

Pre-registered H-QUANT (SE-median model):
  SUPPORT if between_run_range ≲ 1.5 × E[range of N run-medians under pure quant].
  REJECT  if between_run_range ≫ that expectation (residual beyond quant).
  Report residual_beyond_quant_range_ms = max(0, obs_range − E[range]).

H-FIELD: sixfield daemon field correlates with median_offset
         (|Spearman| > 0.5 and not constant). Else NULL.

Exit:
  0  = analysis completed (quant accounts OR fields reported)
  2  = H-QUANT rejected (range >> SE-median expectation) without field explanation
  77 = could-not-measure (no JSON / missing fields)
"""

from __future__ import annotations

import argparse
import json
import math
import re
import statistics
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence, Tuple

RC_OK = 0
RC_REJECT = 2
RC_UNSCORED = 77

REC_FIELDS = [
    "plxa_used",
    "plxd_liveness_proven",
    "published_bank",
    "free_bank_mask",
    "disp_bank",
    "swap_pending",
    "frames_done",
    "av_hold_count",
    "av_hold_wait_us",
    "audio_queued_first_ge0_since_origin_ms",
    "ddr_total_us",
    "ddr_copy_us",
    "ddr_doorbell_us",
    "ddr_plxa_poll_us",
]


@dataclass
class RunJson:
    path: str
    median_ms: Optional[float] = None
    stdev_ms: Optional[float] = None
    n_pairs: int = 0
    n_interp: Optional[int] = None
    n_step: Optional[int] = None
    n_flashes: Optional[int] = None
    quant_ms: Optional[float] = None
    period_ms: Optional[float] = None
    hop_ms: Optional[float] = None
    fps_nom: Optional[float] = None
    first_pair_ms: Optional[float] = None
    early_minus_late_ms: Optional[float] = None
    capture_fp: Optional[str] = None
    pairs: List[float] = field(default_factory=list)
    tag: str = ""


def load_run(path: Path) -> RunJson:
    d = json.loads(path.read_text(encoding="utf-8"))
    r = d.get("result") or {}
    fm = r.get("flash_meta") or {}
    bm = r.get("beep_meta") or {}
    cc = d.get("capture_config") or {}
    fp = None
    if isinstance(cc, dict):
        fp = cc.get("fingerprint") or cc.get("sha256")
    # fingerprint sometimes only in log; JSON may nest differently
    if fp is None and isinstance(d.get("capture_config_fingerprint"), str):
        fp = d["capture_config_fingerprint"]
    pairs = []
    for p in r.get("pairs") or []:
        if isinstance(p, dict) and "offset_ms" in p:
            pairs.append(float(p["offset_ms"]))
    med = r.get("median_offset_ms")
    return RunJson(
        path=str(path),
        median_ms=float(med) if med is not None else None,
        stdev_ms=float(r["stdev_offset_ms"]) if r.get("stdev_offset_ms") is not None else None,
        n_pairs=int(r.get("n_pairs") or 0),
        n_interp=int(fm["flash_onset_n_interp"]) if fm.get("flash_onset_n_interp") is not None else None,
        n_step=int(fm["flash_onset_n_step"]) if fm.get("flash_onset_n_step") is not None else None,
        n_flashes=int(fm["n_flashes"]) if fm.get("n_flashes") is not None else None,
        quant_ms=(
            float(fm["capture_frame_quant_ms_no_interp"])
            if fm.get("capture_frame_quant_ms_no_interp") is not None
            else None
        ),
        period_ms=(
            float(fm["capture_frame_period_ms"])
            if fm.get("capture_frame_period_ms") is not None
            else None
        ),
        hop_ms=float(bm["hop_ms"]) if bm.get("hop_ms") is not None else None,
        fps_nom=float(fm["fps_nom"]) if fm.get("fps_nom") is not None else None,
        first_pair_ms=(
            float(r["first_pair_offset_ms"]) if r.get("first_pair_offset_ms") is not None else None
        ),
        early_minus_late_ms=(
            float(r["early_minus_late_ms"]) if r.get("early_minus_late_ms") is not None else None
        ),
        capture_fp=str(fp) if fp else None,
        pairs=pairs,
        tag=path.stem,
    )


def parse_rec(path: Path) -> Dict[str, Any]:
    text = path.read_text(encoding="utf-8", errors="replace")
    out: Dict[str, Any] = {"path": str(path), "raw": text.strip()}
    for key in REC_FIELDS:
        m = re.search(rf"\b{re.escape(key)}=(\S+)", text)
        if not m:
            out[key] = None
            continue
        s = m.group(1)
        try:
            if "." in s:
                out[key] = float(s)
            else:
                out[key] = int(s)
        except ValueError:
            out[key] = s
    return out


def spearman(xs: List[float], ys: List[float]) -> Optional[float]:
    n = len(xs)
    if n < 3 or n != len(ys):
        return None
    def ranks(a: List[float]) -> List[float]:
        order = sorted(range(n), key=lambda i: a[i])
        r = [0.0] * n
        i = 0
        while i < n:
            j = i
            while j + 1 < n and a[order[j + 1]] == a[order[i]]:
                j += 1
            avg = (i + j) / 2.0 + 1.0
            for k in range(i, j + 1):
                r[order[k]] = avg
            i = j + 1
        return r
    rx, ry = ranks(xs), ranks(ys)
    mx, my = sum(rx) / n, sum(ry) / n
    num = sum((rx[i] - mx) * (ry[i] - my) for i in range(n))
    dx = math.sqrt(sum((rx[i] - mx) ** 2 for i in range(n)))
    dy = math.sqrt(sum((ry[i] - my) ** 2 for i in range(n)))
    if dx == 0 or dy == 0:
        return 0.0  # constant series → no correlation possible
    return num / (dx * dy)


def expected_uniform_range(T: float, n: int) -> float:
    """E[max-min] for n i.i.d. Uniform[0, T] = T * (n-1)/(n+1).

    Kept for reference / self-test of the Uniform formula only.
    Do NOT use this as the H-QUANT model for *run medians* (averaging applies).
    """
    if n < 2:
        return float("nan")
    return T * (n - 1) / (n + 1)


def pair_quant_sigma_ms(T: float) -> float:
    """σ of Uniform[0,T] (or equivalent span-T) onset error: T/√12."""
    return T / math.sqrt(12.0)


# Asymptotic SE(sample median) / (σ/√n) for large n, normal parent ≈ sqrt(π/2).
SE_MEDIAN_OVER_SEM = math.sqrt(math.pi / 2.0)  # ≈ 1.253314


def se_median_ms(T: float, n_pairs: int) -> float:
    """SE of the median of n_pairs i.i.d. pair offsets under pure frame quant.

    SE(median) ≈ 1.2533 · (T/√12) / √n_pairs
    tag when printing: derived_from_measured_T_and_n_pairs
    """
    if n_pairs < 1 or T <= 0:
        return float("nan")
    return SE_MEDIAN_OVER_SEM * pair_quant_sigma_ms(T) / math.sqrt(float(n_pairs))


def _norm_ppf(p: float) -> float:
    """Approximate standard-normal inverse CDF (Acklam rational, public domain)."""
    if p <= 0.0:
        return float("-inf")
    if p >= 1.0:
        return float("+inf")
    # Coefficients for central region
    a = [
        -3.969683028665376e01,
        2.209460984245205e02,
        -2.759285104469687e02,
        1.383577518672690e02,
        -3.066479806614716e01,
        2.506628277459239e00,
    ]
    b = [
        -5.447609879822406e01,
        1.615858368580409e02,
        -1.556989798598866e02,
        6.680131188771972e01,
        -1.328068155288572e01,
    ]
    c = [
        -7.784894002430293e-03,
        -3.223964580411365e-01,
        -2.400758277161838e00,
        -2.549732539343734e00,
        4.374664141464968e00,
        2.938163982698783e00,
    ]
    d = [
        7.784695709041462e-03,
        3.224671290700398e-01,
        2.445134137142996e00,
        3.754408661907416e00,
    ]
    plow = 0.02425
    phigh = 1.0 - plow
    if p < plow:
        q = math.sqrt(-2.0 * math.log(p))
        return (
            (((((c[0] * q + c[1]) * q + c[2]) * q + c[3]) * q + c[4]) * q + c[5])
            / ((((d[0] * q + d[1]) * q + d[2]) * q + d[3]) * q + 1.0)
        )
    if p > phigh:
        q = math.sqrt(-2.0 * math.log(1.0 - p))
        return -(
            (((((c[0] * q + c[1]) * q + c[2]) * q + c[3]) * q + c[4]) * q + c[5])
            / ((((d[0] * q + d[1]) * q + d[2]) * q + d[3]) * q + 1.0)
        )
    q = p - 0.5
    r = q * q
    return (
        (((((a[0] * r + a[1]) * r + a[2]) * r + a[3]) * r + a[4]) * r + a[5]) * q
        / (((((b[0] * r + b[1]) * r + b[2]) * r + b[3]) * r + b[4]) * r + 1.0)
    )


def expected_normal_range(sigma: float, n: int) -> float:
    """Approx E[max-min] for n i.i.d. N(0, sigma^2) via Blom extreme plotting positions.

    E[max]≈σ·Φ^{-1}((n-0.375)/(n+0.25)); E[min]=-E[max] ⇒ E[range]≈2·E[max].
    For n=16 this is ≈3.53·σ (parent used ~3.5×SE for the 6.4 ms figure).
    """
    if n < 2 or sigma < 0 or math.isnan(sigma):
        return float("nan")
    pmax = (n - 0.375) / (n + 0.25)
    return 2.0 * sigma * _norm_ppf(pmax)


def analyze_quant(runs: List[RunJson]) -> Dict[str, Any]:
    meds = [r.median_ms for r in runs if r.median_ms is not None]
    out: Dict[str, Any] = {
        "n_runs": len(meds),
        "n_runs_src": "measured",
    }
    if len(meds) < 2:
        out["status"] = "could-not-measure"
        out["rc"] = RC_UNSCORED
        return out

    meds_s = sorted(meds)
    rng = meds_s[-1] - meds_s[0]
    out["median_ms_list"] = meds_s
    out["between_run_range_ms"] = rng
    out["between_run_range_ms_src"] = "measured"
    out["between_run_stdev_ms"] = statistics.pstdev(meds) if len(meds) > 1 else 0.0
    out["between_run_stdev_ms_src"] = "measured"
    out["between_run_mean_ms"] = statistics.mean(meds)
    out["between_run_mean_ms_src"] = "measured"

    quants = [r.quant_ms for r in runs if r.quant_ms is not None]
    periods = [r.period_ms for r in runs if r.period_ms is not None]
    T = None
    if quants:
        T = statistics.median(quants)
        out["capture_frame_quant_ms"] = T
        out["capture_frame_quant_ms_src"] = "measured"
    elif periods:
        T = statistics.median(periods)
        out["capture_frame_quant_ms"] = T
        out["capture_frame_quant_ms_src"] = "measured_period"
    else:
        out["capture_frame_quant_ms"] = None
        out["capture_frame_quant_ms_src"] = "could-not-measure"

    n_interp = sum(r.n_interp or 0 for r in runs)
    n_step = sum(r.n_step or 0 for r in runs)
    n_flash = sum(r.n_flashes or 0 for r in runs)
    out["flash_onset_n_interp_total"] = n_interp
    out["flash_onset_n_step_total"] = n_step
    out["flash_onset_n_flashes_total"] = n_flash
    out["flash_onset_counts_src"] = "measured"

    hops = [r.hop_ms for r in runs if r.hop_ms is not None]
    if hops:
        out["beep_hop_ms"] = statistics.median(hops)
        out["beep_hop_ms_src"] = "measured"

    within = [r.stdev_ms for r in runs if r.stdev_ms is not None]
    if within:
        out["within_run_stdev_ms_median"] = statistics.median(within)
        out["within_run_stdev_ms_median_src"] = "measured"

    n_pairs_list = [r.n_pairs for r in runs if r.n_pairs and r.n_pairs > 0]
    n_pairs = int(statistics.median(n_pairs_list)) if n_pairs_list else 0
    out["n_pairs_median"] = n_pairs if n_pairs else None
    out["n_pairs_median_src"] = "measured" if n_pairs else "could-not-measure"

    if T is None:
        out["H_QUANT"] = {"verdict": "UNSCORED", "verdict_src": "could-not-measure"}
        out["rc"] = RC_UNSCORED
        out["status"] = "could-not-measure"
        return out

    if T:
        out["uniform_0_T_stdev_ms"] = pair_quant_sigma_ms(T)
        out["uniform_0_T_stdev_ms_src"] = "derived_from_measured_T"
        # Legacy Uniform-of-medians figure (WRONG model for averaged medians) — printed
        # only as contrast so nobody re-adopts range≤T as a median floor.
        n = len(meds)
        out["legacy_uniform_median_E_range_ms"] = expected_uniform_range(T, n)
        out["legacy_uniform_median_E_range_ms_src"] = (
            "derived_E_max_min_Uniform_0_T_DO_NOT_USE_as_median_floor"
        )

    all_step = n_flash > 0 and n_interp == 0
    out["all_flashes_step_no_interp"] = all_step
    out["all_flashes_step_no_interp_src"] = "measured"

    n = len(meds)
    if n_pairs < 1:
        out["H_QUANT"] = {
            "verdict": "UNSCORED",
            "verdict_src": "could-not-measure",
            "detail": "n_pairs missing; cannot compute SE(median)",
        }
        out["rc"] = RC_UNSCORED
        out["status"] = "could-not-measure"
        return out

    sigma_pair = pair_quant_sigma_ms(T)
    se_med = se_median_ms(T, n_pairs)
    e_range = expected_normal_range(se_med, n)
    out["pair_quant_sigma_ms"] = sigma_pair
    out["pair_quant_sigma_ms_src"] = "derived_T_over_sqrt12"
    out["se_median_ms"] = se_med
    out["se_median_ms_src"] = "derived_1.2533_sigma_over_sqrt_n_pairs"
    out["expected_between_run_range_ms"] = e_range
    out["expected_between_run_range_ms_src"] = (
        "derived_E_range_N_normals_sigma_eq_SE_median"
    )
    # Keep key name expected_uniform_range_ms only as alias for printers that
    # still look for it — value is the SE-median model, not Uniform[0,T].
    out["expected_uniform_range_ms"] = e_range
    out["expected_uniform_range_ms_src"] = out["expected_between_run_range_ms_src"]
    out["range_over_expected"] = (rng / e_range) if e_range and e_range > 0 else None
    out["range_over_expected_src"] = "measured/derived"
    out["range_over_T"] = rng / T if T else None
    out["range_over_T_src"] = "measured/derived_legacy_ratio_not_a_floor"
    residual = max(0.0, rng - e_range)
    out["residual_beyond_quant_range_ms"] = residual
    out["residual_beyond_quant_range_ms_src"] = "measured_minus_derived"

    # SUPPORT if obs range within 1.5× of SE-median expectation (finite-n slack).
    # REJECT if obs range > 2.0× expectation (clear excess beyond quant averaging).
    support_ok = e_range > 0 and rng <= e_range * 1.5 + 1e-9
    reject_ok = e_range > 0 and rng > e_range * 2.0 + 1e-9

    # Per-pair instrument quant (for documentation only — NOT a median floor).
    out["per_pair_quant_ms"] = T
    out["per_pair_quant_ms_src"] = "measured_capture_frame_quant"
    out["instrument_floor_ms"] = se_med
    out["instrument_floor_ms_src"] = (
        "SE_median_under_pure_quant_NOT_per_pair_T"
    )

    if support_ok and all_step:
        out["H_QUANT"] = {
            "verdict": "SUPPORTED",
            "verdict_src": "measured",
            "detail": (
                f"between_run_range_ms={rng:.4f} ≤ 1.5×E[range]={e_range:.4f}; "
                f"SE(median)={se_med:.4f} n_pairs={n_pairs} T={T:.4f}; "
                f"flash_onset_n_interp=0/{n_flash}"
            ),
        }
        out["consequence"] = (
            f"Between-run median range {rng:.2f} ms is consistent with "
            f"per-pair frame quant after averaging "
            f"(SE(median)≈{se_med:.2f} ms, E[range n={n}]≈{e_range:.2f} ms). "
            f"Per-pair onset is still quantised to T={T:.2f} ms; that is NOT "
            f"the run-median resolution. Residual beyond quant ≈ {residual:.2f} ms."
        )
        out["rc"] = RC_OK
        out["status"] = "quant_accounts_for_residual"
    elif reject_ok:
        out["H_QUANT"] = {
            "verdict": "REJECTED",
            "verdict_src": "measured",
            "detail": (
                f"between_run_range_ms={rng:.4f} > 2×E[range]={e_range:.4f}; "
                f"SE(median)={se_med:.4f} n_pairs={n_pairs} T={T:.4f}; "
                f"residual_beyond_quant_range_ms={residual:.4f}"
            ),
        }
        out["consequence"] = (
            f"Video-side frame quantisation alone cannot explain the "
            f"{rng:.2f} ms between-run median range after averaging "
            f"(E[range|SE_median,n={n}]≈{e_range:.2f} ms, "
            f"SE(median)≈{se_med:.2f} ms, T={T:.2f} ms, n_pairs≈{n_pairs}). "
            f"Unattributed residual range ≈ {residual:.2f} ms "
            f"(~{residual:.0f} ms of genuine run-to-run signal). "
            f"Do NOT publish a ~{T:.0f} ms median floor."
        )
        out["rc"] = RC_REJECT
        out["status"] = "quant_insufficient"
    else:
        out["H_QUANT"] = {
            "verdict": "INCONCLUSIVE",
            "verdict_src": "measured",
            "detail": (
                f"range={rng:.4f} E[range]={e_range:.4f} "
                f"ratio={out['range_over_expected']} all_step={all_step} "
                f"SE_median={se_med:.4f}"
            ),
        }
        out["consequence"] = (
            f"Between-run range {rng:.2f} ms vs E[range]≈{e_range:.2f} ms "
            f"is neither a clean SUPPORT (≤1.5×) nor REJECT (>2×). "
            f"Residual beyond quant ≈ {residual:.2f} ms. "
            f"Per-pair T={T:.2f} ms is not a median floor."
        )
        out["rc"] = RC_OK
        out["status"] = "quant_plausible"
    return out


def analyze_fields(
    pairs: List[Tuple[RunJson, Dict[str, Any]]],
) -> Dict[str, Any]:
    out: Dict[str, Any] = {"n_paired": len(pairs), "n_paired_src": "measured"}
    if len(pairs) < 2:
        out["status"] = "could-not-measure"
        out["rc"] = RC_UNSCORED
        out["H_FIELD"] = {"verdict": "UNSCORED", "verdict_src": "could-not-measure"}
        return out

    meds = [p[0].median_ms for p in pairs]
    if any(m is None for m in meds):
        out["status"] = "could-not-measure"
        out["rc"] = RC_UNSCORED
        out["H_FIELD"] = {"verdict": "UNSCORED", "verdict_src": "could-not-measure"}
        return out
    meds_f = [float(m) for m in meds]  # type: ignore[arg-type]

    field_report = []
    any_varies = False
    any_corr = False
    for key in REC_FIELDS:
        vals = [p[1].get(key) for p in pairs]
        if all(v is None for v in vals):
            field_report.append(
                {
                    "field": key,
                    "status": "absent",
                    "unique": [],
                    "spearman": None,
                    "spearman_src": "could-not-measure",
                }
            )
            continue
        # numeric only for correlation
        num_pairs = [
            (meds_f[i], float(vals[i]))
            for i in range(len(vals))
            if isinstance(vals[i], (int, float))
        ]
        uniq = sorted({v for v in vals if v is not None}, key=lambda x: str(x))
        varies = len(uniq) > 1
        if varies:
            any_varies = True
        sp = None
        if varies and len(num_pairs) >= 3:
            sp = spearman([a for a, _ in num_pairs], [b for _, b in num_pairs])
            if sp is not None and abs(sp) > 0.5:
                any_corr = True
        field_report.append(
            {
                "field": key,
                "status": "varies" if varies else "constant",
                "unique": uniq[:12],
                "n_unique": len(uniq),
                "spearman": sp,
                "spearman_src": "measured" if sp is not None else "could-not-measure",
            }
        )

    out["fields"] = field_report
    if not any_varies:
        out["H_FIELD"] = {
            "verdict": "NULL_all_constant",
            "verdict_src": "measured",
            "detail": "all present daemon fields identical across runs; no correlation possible",
        }
        out["status"] = "null_fields_identical"
        out["rc"] = RC_OK
    elif not any_corr:
        out["H_FIELD"] = {
            "verdict": "NULL_no_correlation",
            "verdict_src": "measured",
            "detail": "some fields vary but |Spearman|≤0.5 vs median_offset for all",
        }
        out["status"] = "null_no_correlation"
        out["rc"] = RC_OK
    else:
        hits = [f for f in field_report if f.get("spearman") is not None and abs(f["spearman"]) > 0.5]
        out["H_FIELD"] = {
            "verdict": "CORRELATED",
            "verdict_src": "measured",
            "hits": hits,
        }
        out["status"] = "field_correlation"
        out["rc"] = RC_OK
    return out


def print_report(title: str, q: Dict[str, Any], f: Optional[Dict[str, Any]] = None) -> None:
    print(f"=== {title} ===")
    for k in [
        "n_runs",
        "between_run_range_ms",
        "between_run_stdev_ms",
        "between_run_mean_ms",
        "capture_frame_quant_ms",
        "n_pairs_median",
        "pair_quant_sigma_ms",
        "se_median_ms",
        "expected_between_run_range_ms",
        "expected_uniform_range_ms",
        "range_over_expected",
        "range_over_T",
        "residual_beyond_quant_range_ms",
        "legacy_uniform_median_E_range_ms",
        "flash_onset_n_interp_total",
        "flash_onset_n_step_total",
        "flash_onset_n_flashes_total",
        "beep_hop_ms",
        "within_run_stdev_ms_median",
        "uniform_0_T_stdev_ms",
        "all_flashes_step_no_interp",
        "per_pair_quant_ms",
        "instrument_floor_ms",
        "status",
    ]:
        if k in q and not k.endswith("_src"):
            src = q.get(f"{k}_src", q.get("H_QUANT", {}).get("verdict_src", "?"))
            if f"{k}_src" in q:
                src = q[f"{k}_src"]
            print(f"{k}={q[k]} src={src}")
    if "median_ms_list" in q:
        print(
            "median_ms_list="
            + ",".join(f"{x:.4f}" for x in q["median_ms_list"])
            + " src=measured"
        )
    hq = q.get("H_QUANT") or {}
    print(f"H_QUANT={hq.get('verdict')} src={hq.get('verdict_src')} detail={hq.get('detail')}")
    if q.get("consequence"):
        print(f"CONSEQUENCE={q['consequence']}")
    if f:
        print(f"H_FIELD={f.get('H_FIELD', {}).get('verdict')} src={f.get('H_FIELD', {}).get('verdict_src')}")
        print(f"H_FIELD_detail={f.get('H_FIELD', {}).get('detail')}")
        for fr in f.get("fields") or []:
            print(
                f"  field={fr['field']} status={fr['status']} "
                f"n_unique={fr.get('n_unique')} unique={fr.get('unique')} "
                f"spearman={fr.get('spearman')} src={fr.get('spearman_src')}"
            )


def self_test() -> int:
    fails = 0

    def check(c: bool, m: str) -> None:
        nonlocal fails
        if not c:
            print(f"FAIL {m}", file=sys.stderr)
            fails += 1
        else:
            print(f"PASS {m}")

    # Uniform formula still correct as pure math (not H-QUANT model)
    check(abs(expected_uniform_range(1.0, 2) - 1.0 / 3.0) < 1e-9, "E U-range n=2")
    check(abs(expected_uniform_range(33.333, 16) - 33.333 * 15 / 17) < 1e-6, "E U-range n=16")

    # Parent-verified SE(median) arithmetic (T=33.33, n_pairs=44)
    T = 33.33
    sig = pair_quant_sigma_ms(T)
    check(abs(sig - T / math.sqrt(12.0)) < 1e-12, "sigma=T/sqrt12")
    se = se_median_ms(T, 44)
    # 1.253314 * 9.6217 / sqrt(44) ≈ 1.821
    check(abs(se - 1.821) < 0.02, f"SE(median)≈1.82 got {se}")
    er = expected_normal_range(se, 16)
    # parent ≈ 3.5 * 1.82 ≈ 6.4
    check(abs(er - 6.4) < 0.4, f"E[range n=16]≈6.4 got {er}")

    # Parent NEW pool shape: range 25 ms, n_pairs=45, n_runs=16 → H-QUANT REJECTED
    meds = [-113, -107, -123, -113, -110, -119, -100, -125,
            -117, -115, -112, -118, -111, -120, -114, -116]
    # force range exactly 25
    meds = [-100.0 + i for i in range(15)] + [-100.0 + 25.0]
    runs = []
    for i, m in enumerate(meds):
        runs.append(
            RunJson(
                path=f"s{i}",
                median_ms=float(m),
                stdev_ms=14.0,
                n_pairs=45,
                n_interp=0,
                n_step=45,
                n_flashes=45,
                quant_ms=33.0,
                period_ms=33.0,
                hop_ms=2.0,
            )
        )
    q = analyze_quant(runs)
    check(q["H_QUANT"]["verdict"] == "REJECTED", f"quant reject got {q['H_QUANT']['verdict']}")
    check(q["between_run_range_ms"] == 25.0, "range=25")
    check(q["residual_beyond_quant_range_ms"] > 10.0, "residual>~10ms")
    check("Do NOT publish" in (q.get("consequence") or ""), "no false 33ms floor")
    # instrument_floor is SE(median), not T
    check(q["instrument_floor_ms"] < 5.0, f"floor is SE_med not T got {q['instrument_floor_ms']}")

    # Small range consistent with quant after averaging → SUPPORT
    runs_s = []
    base = -113.0
    for i in range(16):
        runs_s.append(
            RunJson(
                path=f"t{i}",
                median_ms=base + (i % 5) * 0.5,  # range 2.0 ms
                stdev_ms=9.0,
                n_pairs=45,
                n_interp=0,
                n_step=45,
                n_flashes=45,
                quant_ms=33.0,
                period_ms=33.0,
                hop_ms=2.0,
            )
        )
    qs = analyze_quant(runs_s)
    check(qs["H_QUANT"]["verdict"] == "SUPPORTED", f"quant support got {qs['H_QUANT']['verdict']}")

    # Large range still REJECT even if range < T (the old wrong SUPPORT path)
    runs_mid = [
        RunJson(
            path="a",
            median_ms=0.0,
            n_pairs=45,
            n_interp=0,
            n_step=45,
            n_flashes=45,
            quant_ms=33.0,
        ),
        RunJson(
            path="b",
            median_ms=25.0,
            n_pairs=45,
            n_interp=0,
            n_step=45,
            n_flashes=45,
            quant_ms=33.0,
        ),
    ]
    qm = analyze_quant(runs_mid)
    check(
        qm["H_QUANT"]["verdict"] == "REJECTED",
        f"range 25 < T=33 must still REJECT under SE model got {qm['H_QUANT']['verdict']}",
    )

    # Field null constant
    rj = RunJson(path="x", median_ms=-110.0)
    rec = {k: 1 for k in REC_FIELDS}
    f = analyze_fields([(rj, rec), (RunJson(path="y", median_ms=-120.0), dict(rec))])
    check(f["H_FIELD"]["verdict"] == "NULL_all_constant", f"field null got {f['H_FIELD']['verdict']}")

    if fails:
        print(f"SELF_TEST_FAIL fails={fails}")
        return RC_REJECT
    print("SELF_TEST_OK")
    return RC_OK


def main(argv: Optional[Sequence[str]] = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--self-test", action="store_true")
    ap.add_argument("--json", action="append", default=[], help="avsync JSON (repeatable)")
    ap.add_argument("--json-glob", action="append", default=[], help="glob for JSON files")
    ap.add_argument("--rec", action="append", default=[], help="sixfield rec*.txt (repeatable)")
    ap.add_argument(
        "--rec-dir",
        type=Path,
        default=None,
        help="directory with recN.txt + avN.json paired by number",
    )
    ap.add_argument("--json-out", type=Path, default=None)
    args = ap.parse_args(argv)

    if args.self_test:
        return self_test()

    from glob import glob as gglob

    paths: List[Path] = [Path(p) for p in args.json]
    for g in args.json_glob:
        paths.extend(Path(p) for p in sorted(gglob(g)))

    # dedupe
    seen = set()
    uniq_paths: List[Path] = []
    for p in paths:
        if not p.exists():
            continue
        rp = str(p.resolve())
        if rp not in seen:
            seen.add(rp)
            uniq_paths.append(p)

    if args.rec_dir and args.rec_dir.is_dir():
        for jp in sorted(args.rec_dir.glob("av*.json")):
            if jp not in uniq_paths:
                uniq_paths.append(jp)

    if not uniq_paths:
        print("VERDICT=UNSCORED rc=77 reason=no_json src=could-not-measure")
        return RC_UNSCORED

    runs = [load_run(p) for p in uniq_paths]
    print(f"loaded_json_n={len(runs)} src=measured")
    for r in runs:
        print(
            f"  run={r.tag} median_ms={r.median_ms} quant_ms={r.quant_ms} "
            f"n_interp={r.n_interp} n_step={r.n_step} n_flash={r.n_flashes} "
            f"hop_ms={r.hop_ms} stdev_ms={r.stdev_ms} src=measured"
        )

    q = analyze_quant(runs)
    print_report("H-QUANT residual", q)

    # sixfield pairing
    field_pairs: List[Tuple[RunJson, Dict[str, Any]]] = []
    rec_paths = [Path(p) for p in args.rec]
    if args.rec_dir and args.rec_dir.is_dir():
        rec_paths.extend(sorted(args.rec_dir.glob("rec*.txt")))
    rec_by_num: Dict[str, Path] = {}
    for rp in rec_paths:
        m = re.search(r"rec(\d+)", rp.stem)
        if m:
            rec_by_num[m.group(1)] = rp
    for r in runs:
        m = re.search(r"(\d+)$", r.tag)
        if not m:
            m = re.search(r"av(\d+)", r.tag)
        if not m:
            continue
        num = m.group(1)
        if num in rec_by_num:
            field_pairs.append((r, parse_rec(rec_by_num[num])))

    frep = None
    if field_pairs:
        frep = analyze_fields(field_pairs)
        print_report("H-FIELD sixfield", q, frep)
    else:
        print("H_FIELD=UNSCORED src=could-not-measure detail=no_rec_pairs")

    payload = {"quant": q, "fields": frep, "runs": [r.tag for r in runs]}
    if args.json_out:
        args.json_out.parent.mkdir(parents=True, exist_ok=True)
        # make JSON-safe
        args.json_out.write_text(json.dumps(payload, indent=2, default=str), encoding="utf-8")
        print(f"json_out={args.json_out} src=measured")

    rc = q.get("rc", RC_UNSCORED)
    # Field null does not override quant REJECT; quant SUPPORT stays 0
    print(f"VERDICT_RC={rc} src=measured")
    return int(rc)


if __name__ == "__main__":
    sys.exit(main())
