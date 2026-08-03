#!/usr/bin/env python3
"""Minimum detectable A/V drift rate for a planned lipsync soak.

Uses ordinary least-squares slope SE under equal-spaced markers:
  Sxx = n*(n^2-1)*dt^2/12
  SE(slope) = sigma_res / sqrt(Sxx)
  delta_min (80% power, two-sided alpha=0.05) ≈ z_power * SE
  z_power ≈ 2.8  (1.96 + 0.84)  DEFAULT_ASSUMED normal approximation

All printed values tagged measured | caller_supplied | DEFAULT_ASSUMED | derived.

Exit: 0 always on successful print; 2 bad args.
"""
from __future__ import annotations

import argparse
import math
import sys


def sxx_equal_space(n: int, dt_s: float) -> float:
    if n < 3 or dt_s <= 0:
        return float("nan")
    return n * (n * n - 1) * (dt_s ** 2) / 12.0


def se_slope_ms_per_s(sigma_res_ms: float, n: int, dt_s: float) -> float:
    sxx = sxx_equal_space(n, dt_s)
    if not math.isfinite(sxx) or sxx <= 0:
        return float("nan")
    return float(sigma_res_ms) / math.sqrt(sxx)


def min_detectable_slope(
    sigma_res_ms: float,
    n: int,
    dt_s: float,
    *,
    z_power: float = 2.8,
) -> dict[str, float | int | str]:
    se = se_slope_ms_per_s(sigma_res_ms, n, dt_s)
    dmin = z_power * se if math.isfinite(se) else float("nan")
    span_s = (n - 1) * dt_s if n >= 2 else 0.0
    # End-of-soak cumulative offset if true slope = dmin
    cum_at_dmin = dmin * span_s if math.isfinite(dmin) else float("nan")
    return {
        "n_pairs": n,
        "marker_period_s": dt_s,
        "span_s": span_s,
        "sigma_res_ms": sigma_res_ms,
        "se_slope_ms_per_s": se,
        "z_power": z_power,
        "min_detectable_slope_ms_per_s": dmin,
        "cumulative_at_dmin_ms": cum_at_dmin,
    }


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "--duration-s",
        type=float,
        default=None,
        help="analysis span seconds (required unless --self-test)",
    )
    ap.add_argument(
        "--marker-period-s",
        type=float,
        default=2.0,
        help="flash+beep period (rk=27 = 2.0; legacy blip = 1.0)",
    )
    ap.add_argument(
        "--sigma-res-ms",
        type=float,
        default=16.0,
        help="expected residual RMS after detrend (parent 480p≈16 ms)",
    )
    ap.add_argument(
        "--sigma-src",
        default="DEFAULT_ASSUMED",
        help="tag for sigma (use measured after a pilot)",
    )
    ap.add_argument("--warmup-s", type=float, default=5.0)
    ap.add_argument("--z-power", type=float, default=2.8)
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args(argv)

    if args.self_test:
        # Hand check: n=30, dt=2, sigma=16 → Sxx = 30*899*4/12 = 8990
        # SE = 16/sqrt(8990) ≈ 0.1687; dmin ≈ 0.472 ms/s
        r = min_detectable_slope(16.0, 30, 2.0, z_power=2.8)
        se = float(r["se_slope_ms_per_s"])
        dmin = float(r["min_detectable_slope_ms_per_s"])
        assert abs(se - 16.0 / math.sqrt(30 * 899 * 4 / 12)) < 1e-9
        assert abs(dmin - 2.8 * se) < 1e-9
        # Longer soak must improve (smaller dmin)
        r2 = min_detectable_slope(16.0, 450, 2.0, z_power=2.8)
        assert float(r2["min_detectable_slope_ms_per_s"]) < dmin
        print("SELF_TEST_OK avsync_drift_power")
        print(
            f"pilot_n30_dmin_ms_per_s={dmin:.6f} src=derived "
            f"long_n450_dmin_ms_per_s={float(r2['min_detectable_slope_ms_per_s']):.6f} src=derived"
        )
        return 0

    if args.duration_s is None:
        print("error: --duration-s required unless --self-test", file=sys.stderr)
        return 2

    dt = float(args.marker_period_s)
    if dt <= 0 or args.duration_s <= 0:
        print("bad args", file=sys.stderr)
        return 2
    # Usable span after warmup; n = floor(span/dt)+1 markers if both ends included
    span = max(0.0, float(args.duration_s) - float(args.warmup_s))
    n = int(math.floor(span / dt)) + 1 if span > 0 else 0
    if n < 3:
        print(
            f"VERDICT=UNSCORED reason=too_few_pairs_for_slope n={n} "
            f"span_s={span:.3f} marker_period_s={dt}"
        )
        return 77

    period_src = "caller_supplied"
    sigma_src = str(args.sigma_src)
    z_src = "DEFAULT_ASSUMED" if abs(float(args.z_power) - 2.8) < 1e-12 else "caller_supplied"

    r = min_detectable_slope(
        float(args.sigma_res_ms), n, dt, z_power=float(args.z_power)
    )
    print("=== avsync_drift_power ===")
    print(f"duration_s={args.duration_s} src=caller_supplied")
    print(f"warmup_s={args.warmup_s} src=caller_supplied")
    print(f"analysis_span_s={span:.3f} src=derived")
    print(f"marker_period_s={dt} src={period_src}")
    print(f"n_pairs_expected={n} src=derived")
    print(f"sigma_res_ms={args.sigma_res_ms} src={sigma_src}")
    print(f"z_power={args.z_power} src={z_src}")
    print(
        f"se_slope_ms_per_s={r['se_slope_ms_per_s']:.6f} src=derived"
    )
    print(
        f"min_detectable_slope_ms_per_s={r['min_detectable_slope_ms_per_s']:.6f} "
        f"src=derived power=0.80 alpha=0.05_two_sided"
    )
    print(
        f"cumulative_offset_at_dmin_over_span_ms={r['cumulative_at_dmin_ms']:.3f} src=derived"
    )
    print(
        "null_result_meaning: if measured |slope| < min_detectable_slope_ms_per_s, "
        "cannot reject zero drift at 80% power; NOT proof of perfect sync"
    )
    print(
        "note: does_not_use_av_drift_ms (servo deadband, not lipsync GT)"
    )
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(77)
