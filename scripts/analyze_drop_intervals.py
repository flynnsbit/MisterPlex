#!/usr/bin/env python3
"""Discriminate regular (rate-mismatch sawtooth) vs Poisson (stall) drop times.

Input: one or more files of steady-state drop timestamps (one number per line,
seconds or milliseconds — auto-detected if max>1e6 treat as ms). Exclude
startup burst before invoking.

Exit: 0 always (analysis tool). Prints CV, Fano, KS-vs-Exp, verdict.

Thresholds (pre-registered in .agent-work/w-fit-1/STEADY_STATE_DROP_RCA.md):
  CV <= 0.25 → REGULAR (class A)
  CV >= 0.75 → POISSON-like (class B)
  else → INCONCLUSIVE
"""
from __future__ import annotations

import math
import sys
from pathlib import Path


def load_times(path: Path) -> list[float]:
    xs: list[float] = []
    for line in path.read_text(errors="replace").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        # allow "t=123.4" or bare number or csv first column
        for part in line.replace(",", " ").split():
            part = part.split("=")[-1]
            try:
                xs.append(float(part))
                break
            except ValueError:
                continue
    if len(xs) < 2:
        raise SystemExit(f"need >=2 timestamps in {path}")
    xs.sort()
    if max(xs) > 1_000_000:  # ms
        xs = [x / 1000.0 for x in xs]
    return xs


def intervals(ts: list[float]) -> list[float]:
    return [ts[i + 1] - ts[i] for i in range(len(ts) - 1) if ts[i + 1] > ts[i]]


def mean_stdev(xs: list[float]) -> tuple[float, float]:
    n = len(xs)
    if n == 0:
        return float("nan"), float("nan")
    m = sum(xs) / n
    if n == 1:
        return m, 0.0
    v = sum((x - m) ** 2 for x in xs) / (n - 1)
    return m, math.sqrt(v)


def fano(ts: list[float], width: float) -> float:
    if width <= 0 or len(ts) < 2:
        return float("nan")
    t0, t1 = ts[0], ts[-1]
    if t1 <= t0:
        return float("nan")
    k = max(1, int(math.floor((t1 - t0) / width)))
    counts = [0] * k
    for t in ts:
        b = int((t - t0) / width)
        if 0 <= b < k:
            counts[b] += 1
    m = sum(counts) / len(counts)
    if m <= 0:
        return float("nan")
    var = sum((c - m) ** 2 for c in counts) / len(counts)
    return var / m


def ks_exp(deltas: list[float]) -> float:
    """One-sample KS statistic vs Exp(λ=1/mean). Returns D in [0,1]."""
    if len(deltas) < 3:
        return float("nan")
    m = sum(deltas) / len(deltas)
    if m <= 0:
        return float("nan")
    xs = sorted(deltas)
    n = len(xs)
    d = 0.0
    for i, x in enumerate(xs, start=1):
        cdf = 1.0 - math.exp(-x / m)
        d = max(d, abs(i / n - cdf), abs((i - 1) / n - cdf))
    return d


def verdict(cv: float) -> str:
    if math.isnan(cv):
        return "UNKNOWN"
    if cv <= 0.25:
        return "REGULAR_class_A_rate_mismatch"
    if cv >= 0.75:
        return "POISSON_class_B_stalls"
    return "INCONCLUSIVE"


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print("usage: analyze_drop_intervals.py <run1.txt> [run2.txt ...]", file=sys.stderr)
        return 2
    all_dt: list[float] = []
    print("DROP_INTERVAL_ANALYSIS")
    print("prereg_CV_regular<=0.25 poisson>=0.75 else INCONCLUSIVE")
    print("prereg_partial_reset_R_ppm_for_tau30s≈1390 (NOT 2667 full-reset model)")
    for p in argv[1:]:
        path = Path(p)
        ts = load_times(path)
        dt = intervals(ts)
        all_dt.extend(dt)
        m, s = mean_stdev(dt)
        cv = s / m if m > 0 else float("nan")
        fan = fano(ts, m if m > 0 else 30.0)
        dks = ks_exp(dt)
        print(f"--- {path} ---")
        print(f"n_drops={len(ts)} n_intervals={len(dt)}")
        print(f"mean_s={m:.4f} stdev_s={s:.4f} CV={cv:.4f}")
        print(f"Fano_bin=mean_dt F={fan:.4f}")
        print(f"KS_D_vs_Exp={dks:.4f}")
        print(f"verdict_run={verdict(cv)}")
        # Implied rate error if class A + partial reset (T=1000/24 ms)
        t_frame = 1000.0 / 24.0
        if m > 0:
            r_ms_s = t_frame / m
            ppm = r_ms_s * 1000.0  # ms/s → ppm of content second
            print(f"if_class_A_partial_reset: R={r_ms_s:.4f} ms/s ≈ {ppm:.0f} ppm")
            print(f"if_class_A_full_reset_80ms: R={80.0/m:.4f} ms/s ≈ {80.0/m*1000:.0f} ppm (MODEL_FALSE_in_source)")
    if len(argv) > 2 and all_dt:
        m, s = mean_stdev(all_dt)
        cv = s / m if m > 0 else float("nan")
        print("--- POOLED intervals ---")
        print(f"n_intervals={len(all_dt)} mean_s={m:.4f} stdev_s={s:.4f} CV={cv:.4f}")
        print(f"verdict_pooled={verdict(cv)}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
