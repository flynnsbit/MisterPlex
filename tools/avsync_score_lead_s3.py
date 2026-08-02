#!/usr/bin/env python3
"""Score AV_PRESENT_LEAD_MS falsifier arms against pre-registered S3 bands.

Input: one or more --arm LEAD:path_to_daemon_tail
Extracts av_drift_ms values; prints median/min/max tagged measured.

Exit:
  0  S3_CONFIRMED (all arms in P_MEDIAN bands)
  2  S3_FALSIFIED or mixed fail
  77 UNSCORED (missing data)
"""
from __future__ import annotations

import argparse
import re
import statistics
import sys
from pathlib import Path

# Pre-registered P_MEDIAN bands (inclusive) — docs/AVSYNC_S3_LEAD_FALSIFIER.md
P_MEDIAN = {
    20: (-22.0, -12.0),
    40: (-42.0, -28.0),
    80: (-82.0, -60.0),
}
# Loose envelope still consistent with S3 (not H_REAL cluster)
P_ENV = {
    20: (-28.0, 5.0),
    40: (-45.0, -15.0),
    80: (-90.0, -40.0),
}
# H_REAL cluster if S3 false
H_REAL = (-45.0, -15.0)


def load_drifts(path: Path) -> tuple[list[float], list[str]]:
    text = path.read_text(errors="replace")
    drifts = [
        float(x)
        for x in re.findall(r"\bav_drift_ms=(-?[0-9]+(?:\.[0-9]+)?)", text)
    ]
    epochs = sorted(set(re.findall(r"\bsession_epoch=(\S+)", text)))
    return drifts, epochs

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--arm",
        action="append",
        required=True,
        help="LEAD:path e.g. 40:/path/daemon_tail.txt",
    )
    args = ap.parse_args()

    arms: dict[int, dict] = {}
    for spec in args.arm:
        if ":" not in spec:
            print(f"bad --arm {spec}", file=sys.stderr)
            return 77
        lead_s, path_s = spec.split(":", 1)
        lead = int(lead_s)
        path = Path(path_s)
        if not path.is_file():
            print(f"VERDICT=UNSCORED rc=77 reason=missing_file lead={lead} path={path}")
            return 77
        vals, epochs = load_drifts(path)
        if len(epochs) > 1:
            print(
                f"VERDICT=UNSCORED rc=77 reason=session_epoch_changed "
                f"lead={lead} epochs={epochs} "
                f"(align w-avsync/w-instr rc=79 for soak tools; S3 arm void)"
            )
            return 77
        if len(vals) < 5:
            print(
                f"VERDICT=UNSCORED rc=77 reason=too_few_av_drift samples={len(vals)} "
                f"lead={lead} (need>=5)"
            )
            return 77
        med = float(statistics.median(vals))
        arms[lead] = {
            "n": len(vals),
            "median": med,
            "min": float(min(vals)),
            "max": float(max(vals)),
            "path": str(path),
            "session_epochs": epochs,
        }

    print("=== avsync_score_lead_s3 ===")
    print("metric=av_drift_ms src=measured_from_log")
    print("note=NOT_lipsync GT; testing circularity vs AV_PRESENT_LEAD_MS")
    for lead in sorted(arms):
        a = arms[lead]
        lo, hi = P_MEDIAN.get(lead, (float("nan"), float("nan")))
        in_med = lo <= a["median"] <= hi
        elo, ehi = P_ENV.get(lead, (float("nan"), float("nan")))
        in_env = elo <= a["median"] <= ehi
        print(
            f"lead={lead} n={a['n']} median={a['median']:.4f} "
            f"min={a['min']:.4f} max={a['max']:.4f} src=measured"
        )
        print(
            f"lead={lead} p_median_band=[{lo},{hi}] in_p_median={int(in_med)} "
            f"p_env=[{elo},{ehi}] in_p_env={int(in_env)} src=caller_supplied_pre_register"
        )
        a["in_p_median"] = in_med
        a["in_p_env"] = in_env

    # Pairwise deltas
    leads = sorted(arms)
    for i, la in enumerate(leads):
        for lb in leads[i + 1 :]:
            d = arms[lb]["median"] - arms[la]["median"]
            dlead = lb - la
            print(
                f"delta_median_ms lead_{lb}_minus_{la}={d:.4f} "
                f"delta_lead={dlead} src=derived"
            )

    # H_REAL: all medians in [-45,-15]
    all_real = all(H_REAL[0] <= arms[L]["median"] <= H_REAL[1] for L in arms)
    all_s3 = all(arms[L]["in_p_median"] for L in arms)
    any_s3_env = all(arms[L]["in_p_env"] for L in arms)

    print(f"all_in_H_REAL_cluster_[-45,-15]={int(all_real)} src=derived")
    print(f"all_in_S3_P_MEDIAN={int(all_s3)} src=derived")

    if len(arms) < 2:
        print("VERDICT=UNSCORED rc=77 reason=need_at_least_2_arms")
        return 77

    if all_s3:
        print(
            "VERDICT=S3_CONFIRMED rc=0 "
            "reason=medians_track_LEAD_setpoint_bands"
        )
        print(
            "replace_av_drift_ms: use HDMI flash↔beep offset_ms "
            "(tools/avsync_measure_hdmi.py); never quote av-lock+drift as lipsync"
        )
        return 0

    if all_real and not any_s3_env:
        print(
            "VERDICT=S3_FALSIFIED rc=2 "
            "reason=medians_stuck_in_[-45,-15]_across_LEAD"
        )
        return 2

    if any_s3_env and not all_real:
        print(
            "VERDICT=S3_PARTIAL rc=2 "
            "reason=in_envelope_but_not_all_P_MEDIAN — inspect banners/epoch"
        )
        return 2

    print(
        "VERDICT=S3_INCONCLUSIVE rc=2 "
        "reason=pattern_matches_neither_clean_S3_nor_H_REAL"
    )
    return 2


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(77)
