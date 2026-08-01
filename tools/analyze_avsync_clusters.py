#!/usr/bin/env python3
"""Cluster membership + whole-series shift analysis for avsync_measure_hdmi JSON.

Sign convention (matches tools/avsync_measure_hdmi.py):
  offset_ms = (t_audio_onset - t_video_flash) * 1000
  negative = audio LEADS (early)

Does NOT use av_drift_ms (provably blind to ~120 ms real offset gaps).

Usage:
  python3 tools/analyze_avsync_clusters.py path/to/*.json
  python3 tools/analyze_avsync_clusters.py .agent-work/avsync-cluster/
"""
from __future__ import annotations

import argparse
import json
import math
import statistics
import sys
from pathlib import Path
from typing import Any


A_CENTER = -317.0
B_CENTER = -196.3
MID = 0.5 * (A_CENTER + B_CENTER)


def load_pairs(path: Path) -> dict[str, Any]:
    with path.open() as f:
        j = json.load(f)
    r = j.get("result") or {}
    pairs = r.get("pairs") or []
    offs = [float(p["offset_ms"]) for p in pairs]
    ts = [float(p["t_flash_s"]) for p in pairs]
    return {
        "path": path,
        "name": path.name,
        "pairs": pairs,
        "offs": offs,
        "ts": ts,
        "median": statistics.median(offs) if offs else float("nan"),
        "mean": statistics.mean(offs) if offs else float("nan"),
        "stdev": statistics.stdev(offs) if len(offs) > 1 else 0.0,
        "n": len(offs),
        "slope": float(r.get("slope_ms_per_s") or 0.0),
        "sign": j.get("sign_convention"),
    }


def classify(med: float) -> str:
    d_a = abs(med - A_CENTER)
    d_b = abs(med - B_CENTER)
    if d_a < 40 and d_a <= d_b:
        return "A"
    if d_b < 40 and d_b < d_a:
        return "B"
    return f"? (dA={d_a:.1f} dB={d_b:.1f})"


def linreg(xs: list[float], ys: list[float]) -> tuple[float, float, float]:
    n = len(xs)
    if n < 2:
        return 0.0, 0.0, 0.0
    mx = sum(xs) / n
    my = sum(ys) / n
    num = sum((x - mx) * (y - my) for x, y in zip(xs, ys))
    den = sum((x - mx) ** 2 for x in xs) or 1e-30
    slope = num / den
    icept = my - slope * mx
    ss_tot = sum((y - my) ** 2 for y in ys) or 1e-30
    ss_res = sum((y - (slope * x + icept)) ** 2 for x, y in zip(xs, ys))
    return slope, icept, 1.0 - ss_res / ss_tot


def window_med(ts: list[float], offs: list[float], t0: float, t1: float) -> tuple[float | None, int]:
    vals = [o for t, o in zip(ts, offs) if t0 <= t < t1]
    if not vals:
        return None, 0
    return statistics.median(vals), len(vals)


def score_quantum(abs_deltas: list[float], q: float) -> tuple[float, float]:
    if not abs_deltas or q <= 0:
        return float("nan"), float("nan")
    errs = [abs(abs(d) - q) for d in abs_deltas]
    mae = sum(errs) / len(errs)
    rmse = math.sqrt(sum(e * e for e in errs) / len(errs))
    return mae, rmse


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("paths", nargs="+", help="JSON files or directories")
    ap.add_argument("--margin-ms", type=float, default=5.0, help="quantum winner margin")
    args = ap.parse_args()

    files: list[Path] = []
    for p in args.paths:
        path = Path(p)
        if path.is_dir():
            files.extend(sorted(path.glob("avsync*.json")))
            files.extend(sorted(path.glob("*.json")))
        else:
            files.append(path)
    # unique preserve order
    seen = set()
    uniq: list[Path] = []
    for f in files:
        rp = f.resolve()
        if rp in seen or not f.is_file():
            continue
        seen.add(rp)
        uniq.append(f)
    if not uniq:
        print("ERROR: no JSON files", file=sys.stderr)
        return 2

    series = [load_pairs(f) for f in uniq]
    print("SIGN: offset_ms = t_audio_onset - t_video_flash; negative = audio LEADS")
    print("")

    for s in series:
        cl = classify(s["median"])
        s["cluster"] = cl
        ts, offs = s["ts"], s["offs"]
        tmin, tmax = (min(ts), max(ts)) if ts else (0.0, 0.0)
        span = tmax - tmin if ts else 0.0
        e_med, _ = window_med(ts, offs, tmin, tmin + span / 3) if span else (None, 0)
        l_med, _ = window_med(ts, offs, tmin + 2 * span / 3, tmax + 1) if span else (None, 0)
        n_below = sum(1 for o in offs if o < MID)
        print(
            f"=== {s['name']} cluster={cl} n={s['n']} median={s['median']:.3f} "
            f"stdev={s['stdev']:.3f} slope={s['slope']:.6f}"
        )
        if e_med is not None and l_med is not None:
            print(f"  early_third_med={e_med:.3f} late_third_med={l_med:.3f} "
                  f"|early-late|={abs(e_med - l_med):.3f}")
        print(f"  pairs_below_midpoint_{MID:.1f}: {n_below}/{s['n']} "
              f"({100.0 * n_below / s['n']:.1f}%)" if s["n"] else "  empty")
        # 30s bins — any within-run A↔B flip?
        labels = []
        if ts:
            bt0 = tmin
            while bt0 < tmax:
                bm, bn = window_med(ts, offs, bt0, bt0 + 30.0)
                if bn >= 5 and bm is not None:
                    labels.append("A" if bm < MID else "B")
                bt0 += 30.0
        print(f"  30s_bin_side={''.join(labels) or 'n/a'} "
              f"(flip_within_run={'YES' if labels and len(set(labels))>1 else 'NO'})")
        print("")

    # Cross-cluster median deltas
    cross: list[float] = []
    print("=== CROSS-CLUSTER |median_i - median_j| ===")
    for i, a in enumerate(series):
        for b in series[i + 1 :]:
            if a["cluster"] in ("A", "B") and b["cluster"] in ("A", "B") and a["cluster"] != b["cluster"]:
                d = abs(a["median"] - b["median"])
                cross.append(d)
                print(f"  {a['name']} ({a['cluster']}) vs {b['name']} ({b['cluster']}): {d:.3f} ms")
    if cross:
        mae100, rmse100 = score_quantum(cross, 100.0)
        mae125, rmse125 = score_quantum(cross, 125.0)
        margin = abs(mae100 - mae125)
        prefer = "125_three_frame" if mae125 < mae100 else "100_prefill"
        beats = margin >= args.margin_ms
        print("")
        print(f"quantum mae100={mae100:.3f} mae125={mae125:.3f} prefer={prefer} "
              f"margin={margin:.3f} decisive_margin>={args.margin_ms}={beats}")
        print("note: parent tol_ms=42 accepts BOTH |120-100| and |120-125|; "
              "use mean-|Δ−q| margin, not a single-band check.")
    else:
        print("  (no A/B cross pairs)")

    # Whole-series shift test on first A vs first B if present
    a_list = [s for s in series if s["cluster"] == "A"]
    b_list = [s for s in series if s["cluster"] == "B"]
    if a_list and b_list:
        a, b = a_list[0], b_list[0]
        n = min(a["n"], b["n"])
        d = [a["offs"][i] - b["offs"][i] for i in range(n)]
        ts = [(a["ts"][i] + b["ts"][i]) / 2 for i in range(n)]
        slope, icept, r2 = linreg(ts, d)
        span = ts[-1] - ts[0] if n > 1 else 0.0
        third = max(1, n // 3)
        e = statistics.median(d[:third])
        l = statistics.median(d[-third:])
        print("")
        print(f"=== ALIGNED DELTA {a['name']} - {b['name']} (whole-series test) ===")
        print(f"  delta_median={statistics.median(d):+.3f} slope={slope:+.6f} ms/s "
              f"drift_over_run={abs(slope)*span:.2f} ms")
        print(f"  early_third={e:+.3f} late_third={l:+.3f} |early-late|={abs(e-l):.3f}")
        whole = abs(statistics.median(d)) > 80 and abs(slope) * span < 30 and abs(e - l) < 40
        print(f"  verdict={'WHOLE_SERIES_SHIFT' if whole else 'MIXED_OR_DEVELOPING'}")

    print("")
    print("PRE_REGISTER HOLD_vs_CLUSTERS (product still past-biases kFeedTarget=100ms):")
    print("  collapse_if_startup_residual: between-run |Δmedian|<40 over n>=4")
    print("  intact_if_prefill_or_external: some pair |Δmedian|>=80 after HOLD")
    return 0


if __name__ == "__main__":
    sys.exit(main())
