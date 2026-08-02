#!/usr/bin/env python3
"""Glass marker cadence + lipsync residual SNR from existing capture artifacts.

Does NOT claim single-frame drop detection. Marker period (~2 s) only resolves
multi-period presentation gaps. For frame-level drops use glass_template_skip
+ burned-in counter (separate instrument).

Inputs (any one):
  --report JSON from avsync_measure_hdmi
  --timeseries offset CSV (t_flash_s,...)  [pairs only — weaker]
  --flash-csv flash_onsets.csv
  --input capture.mkv (re-runs flash detect via measure tool helpers)

Prints interval p50/p95/p99/max + histogram + optional residual SNR vs another window.
Every value tagged measured|caller_supplied|DEFAULT_ASSUMED|NO-DATA.
"""
from __future__ import annotations

import argparse
import csv
import json
import math
import statistics
import sys
from pathlib import Path

# Reuse measure helpers when available
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from avsync_measure_hdmi import (  # noqa: E402
    FIXTURE_FLASH_PERIOD_S,
    inter_event_interval_stats,
    load_video_luma,
    detect_flashes,
    linreg_slope,
)


def load_times_from_csv(path: Path, col: str = "t_flash_s") -> list[float]:
    rows: list[float] = []
    with path.open() as f:
        r = csv.DictReader(f)
        if col not in (r.fieldnames or []):
            raise SystemExit(f"NO-DATA: column {col} missing in {path}")
        for row in r:
            rows.append(float(row[col]))
    return rows


def load_offsets(path: Path) -> list[tuple[float, float]]:
    out: list[tuple[float, float]] = []
    with path.open() as f:
        r = csv.DictReader(f)
        for row in r:
            out.append((float(row["t_flash_s"]), float(row["offset_ms"])))
    return out


def residual_series(pairs: list[tuple[float, float]]) -> list[float]:
    if len(pairs) < 2:
        return []
    xs = [p[0] for p in pairs]
    ys = [p[1] for p in pairs]
    slope, intercept, _ = linreg_slope(xs, ys)
    return [y - (slope * x + intercept) for x, y in zip(xs, ys)]


def f_test_var(a: list[float], b: list[float]) -> dict:
    """Two-sided variance ratio test (normal approx). Returns F and rough p."""
    if len(a) < 3 or len(b) < 3:
        return {"ok": False, "reason": "n<3", "src": "NO-DATA"}
    va = statistics.pvariance(a) if len(a) > 1 else 0.0
    vb = statistics.pvariance(b) if len(b) > 1 else 0.0
    # use sample variance for F
    va = statistics.variance(a)
    vb = statistics.variance(b)
    if va <= 0 or vb <= 0:
        return {"ok": False, "reason": "zero_var", "src": "measured"}
    # F = larger/smaller for two-sided
    if vb >= va:
        F = vb / va
        dfn, dfd = len(b) - 1, len(a) - 1
        ratio_dir = "B_over_A"
    else:
        F = va / vb
        dfn, dfd = len(a) - 1, len(b) - 1
        ratio_dir = "A_over_B"
    # Incomplete beta for p-value — simple critical compare at alpha=0.05 via
    # rough Fisher approximation when scipy absent.
    # Critical F approx using Doornik-Hansen-ish: use tabulated-ish formula
    # For parent honesty: report F, df, and whether F > Fcrit_approx.
    # Fcrit ~ exp(2*z*sqrt(2/9*(1/dfn+1/dfd))) rough — better: Wilson-Hilferty
    z = 1.95996398454  # two-sided 0.05 -> one-sided 0.025 on larger
    # one-sided upper 0.025 critical via Wilson–Hilferty cube-root approx
    def fcrit(df1: int, df2: int, z_one: float = 1.95996) -> float:
        h = 2.0 / (9.0 * df1)
        k = 2.0 / (9.0 * df2)
        num = (1.0 - k) + z_one * math.sqrt(h + k - h * k)
        den = 1.0 - h
        if den <= 0:
            return float("nan")
        return (num / den) ** 3

    fc = fcrit(dfn, dfd)
    # also report raw B/A ratio of residual RMS
    rms_a = math.sqrt(sum(x * x for x in a) / len(a))
    rms_b = math.sqrt(sum(x * x for x in b) / len(b))
    return {
        "ok": True,
        "F_ratio_larger_over_smaller": F,
        "F_crit_approx_0p05_twoside": fc,
        "significant_at_0p05_approx": bool(F > fc) if fc == fc else None,
        "dfn": dfn,
        "dfd": dfd,
        "ratio_dir": ratio_dir,
        "residual_rms_a": rms_a,
        "residual_rms_b": rms_b,
        "rms_ratio_b_over_a": (rms_b / rms_a) if rms_a > 0 else None,
        "method": "wilson_hilferty_Fcrit_approx",
        "method_src": "DEFAULT_ASSUMED_approx_no_scipy",
        "src": "derived",
        "note": "approx F-test; publish as such — not exact scipy.stats.f",
    }


def print_interval_block(tag: str, stats: dict) -> None:
    print(f"=== {tag} inter_flash ===")
    if stats.get("interval_ms_src") != "measured":
        print(f"inter_flash=NO-DATA reason={stats.get('reason')} src=NO-DATA")
        return
    print(
        f"n_events={stats['n_events']} n_intervals={stats['n_intervals']} src=measured"
    )
    print(
        f"interval_ms p50={stats['interval_ms_p50']:.3f} "
        f"p95={stats['interval_ms_p95']:.3f} "
        f"p99={stats['interval_ms_p99']:.3f} "
        f"max={stats['interval_ms_max']:.3f} "
        f"min={stats['interval_ms_min']:.3f} "
        f"mean={stats['interval_ms_mean']:.3f} "
        f"stdev={stats['interval_ms_stdev']:.3f} src=measured"
    )
    print(
        f"expected_period_s={stats.get('expected_period_s')} "
        f"src={stats.get('expected_period_s_src')}"
    )
    print(
        f"n_interval_outliers={stats.get('n_interval_outliers')} "
        f"outliers_ms={stats.get('interval_outliers_ms')} "
        f"est_missed_markers={stats.get('est_missed_markers')} src=measured/derived"
    )
    labs = stats.get("histogram_bin_labels") or []
    cts = stats.get("histogram_counts") or []
    hist = " ".join(f"{a}={b}" for a, b in zip(labs, cts) if b)
    print(f"histogram {hist} src=measured")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--report", type=Path, default=None)
    ap.add_argument("--timeseries", type=Path, default=None, help="offset CSV")
    ap.add_argument("--flash-csv", type=Path, default=None)
    ap.add_argument("--input", type=Path, default=None, help="capture mkv/mp4")
    ap.add_argument("--marker-period-s", type=float, default=None)
    ap.add_argument("--marker-period-src", default="caller_supplied")
    ap.add_argument("--warmup-frames", type=int, default=0)
    ap.add_argument("--compare-timeseries", type=Path, default=None,
                    help="second window offset CSV for residual F-test")
    ap.add_argument("--label", default="A")
    ap.add_argument("--label-b", default="B")
    ap.add_argument("--json-out", type=Path, default=None)
    args = ap.parse_args()

    period = args.marker_period_s
    period_src = args.marker_period_src if period is not None else "NO-DATA"
    times: list[float] = []
    source = "NO-DATA"
    pairs: list[tuple[float, float]] = []

    if args.report and args.report.is_file():
        doc = json.loads(args.report.read_text())
        times = [float(x) for x in (doc.get("flash_onset_s") or [])]
        if not times and doc.get("result", {}).get("flash_onset_s"):
            times = [float(x) for x in doc["result"]["flash_onset_s"]]
        if times:
            source = "measured_report_flash_onset_s"
        ifr = doc.get("inter_flash") or doc.get("result", {}).get("inter_flash")
        if period is None and ifr and ifr.get("expected_period_s") is not None:
            period = float(ifr["expected_period_s"])
            period_src = str(ifr.get("expected_period_s_src") or "measured_report")
        # pairs from result
        for p in doc.get("result", {}).get("pairs") or []:
            pairs.append((float(p["t_flash_s"]), float(p["offset_ms"])))
        if not times and pairs:
            times = [p[0] for p in pairs]
            source = "measured_report_pair_t_flash_WEAKER_pairs_only"

    if not times and args.flash_csv and args.flash_csv.is_file():
        times = load_times_from_csv(args.flash_csv, "t_flash_s")
        source = "measured_flash_csv"

    if not times and args.timeseries and args.timeseries.is_file():
        pairs = load_offsets(args.timeseries)
        times = [p[0] for p in pairs]
        source = "measured_timeseries_pairs_only_WEAKER"

    if not times and args.input and args.input.is_file():
        luma, t, vmeta = load_video_luma(args.input)
        flashes, fmeta = detect_flashes(
            luma,
            t,
            vmeta.get("uniform"),
            warmup_frames=int(args.warmup_frames),
            marker_period_s=period,
            marker_period_src=period_src if period is not None else "DEFAULT_ASSUMED",
        )
        times = list(flashes)
        source = "measured_redetect_from_input"
        if period is None:
            period = float(fmeta.get("fixture_flash_period_s") or FIXTURE_FLASH_PERIOD_S)
            period_src = str(fmeta.get("fixture_flash_period_s_src") or "DEFAULT_ASSUMED")

    if not times:
        print("VERDICT=UNSCORED rc=77 reason=no_flash_times")
        return 77

    if period is None:
        # Infer median interval as period only for display — label DEFAULT if used as expected
        if len(times) >= 3:
            dti = sorted((times[i] - times[i - 1]) for i in range(1, len(times)))
            period = float(statistics.median(dti))
            period_src = "DEFAULT_ASSUMED_median_interval_as_period"
        else:
            period = float(FIXTURE_FLASH_PERIOD_S)
            period_src = "DEFAULT_ASSUMED_fixture_1s"

    print(f"flash_times_source={source} src=measured_path")
    print(f"n_flash_times={len(times)} src=measured")
    stats = inter_event_interval_stats(
        times, expected_period_s=float(period), expected_period_src=period_src
    )
    print_interval_block(args.label, stats)

    # residual from pairs if available
    resid = residual_series(pairs) if pairs else []
    if resid:
        rms = math.sqrt(sum(r * r for r in resid) / len(resid))
        print(
            f"offset_residual_rms_ms={rms:.4f} n={len(resid)} "
            f"detrended_max_abs_ms={max(abs(r) for r in resid):.4f} src=measured"
        )
    else:
        print("offset_residual_rms_ms=NO-DATA src=NO-DATA")

    compare = None
    if args.compare_timeseries and args.compare_timeseries.is_file():
        pb = load_offsets(args.compare_timeseries)
        rb = residual_series(pb)
        if resid and rb:
            compare = f_test_var(resid, rb)
            print(f"=== residual variance compare {args.label} vs {args.label_b} ===")
            for k, v in compare.items():
                print(f"{k}={v}")
            # SE of median style distinguishability for residual RMS alone is weak
            # (one summary per window). Prefer F on residual series.
            if compare.get("significant_at_0p05_approx") is True:
                print("VERDICT=WINDOWS_DISTINGUISHABLE_AT_0p05_APPROX src=derived")
            elif compare.get("significant_at_0p05_approx") is False:
                print(
                    "VERDICT=WINDOWS_NOT_DISTINGUISHABLE_AT_0p05_APPROX "
                    "src=derived note=do_not_claim_intermittent_from_these_two"
                )
            else:
                print("VERDICT=COMPARE_NO-DATA src=NO-DATA")
        else:
            print("compare=NO-DATA reason=need_residuals_both_sides src=NO-DATA")

    # Cadence vs lipsync honesty line
    n_out = stats.get("n_interval_outliers")
    print("=== SCOPE (binding) ===")
    print(
        "channel_lipsync=offset residual/detrended — A/V phase; NOT motion smoothness"
    )
    print(
        "channel_marker_cadence=inter_flash intervals — multi-period gaps only "
        f"(n_outliers={n_out})"
    )
    print(
        "channel_frame_drops=NOT_THIS_TOOL — need glass_template_skip + counter OCR "
        "or publish_cadence_score; marker@2s cannot see +1 frame loss"
    )
    print(
        "channel_motion_judder=NOT_THIS_TOOL — perceptual smoothness ≠ lipsync phase"
    )

    out = {
        "flash_times_source": source,
        "inter_flash": stats,
        "n_pairs_offsets": len(pairs),
        "residual_n": len(resid),
        "compare": compare,
    }
    if args.json_out:
        args.json_out.parent.mkdir(parents=True, exist_ok=True)
        args.json_out.write_text(json.dumps(out, indent=2) + "\n")
        print(f"json_out={args.json_out}")

    # rc: 0 always when measured; outliers are data not auto-fail here
    print("VERDICT=CADENCE_MEASURED rc=0")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("VERDICT=UNSCORED rc=77")
        sys.exit(77)
