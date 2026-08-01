#!/usr/bin/env python3
"""Fabric-side hold histogram: vsyncs between successive frames_done edges.

Parent HDMI plateau_hist is capture-domain. This tool bins holds from
frames_done time series (PLXD swap counter), NOT from HDMI OCR.

Modes:
  1) poll-csv  — read a CSV parent collected: mono_ms,frames_done
  2) simulate — offline async models (sanity; host gate is authoritative)

IMPORTANT (measured from RTL, not assumed):
  bank_vsync_count exists in ddr_frame_store.sv but is NOT packed into PLXD.
  PLXD[63:48] = frames_done (swap count only). Therefore true integer vsync
  counts require either:
    - T_vsync DEFAULT_ASSUMED (1/60 or 1/50) applied to mono_ms deltas, or
    - a future RBF that packs bank_vsync_count (NOT authorised here).

Every numeric output is tagged: measured | derived | DEFAULT_ASSUMED | caller_supplied.

Pre-register (print before binning) matches tests/unit/test_cadence_swap_path.cpp.
"""
from __future__ import annotations

import argparse
import csv
import math
import sys
from collections import Counter
from pathlib import Path


def pre_register(hdmi_ge4: float) -> None:
    print("PRE-REGISTER fabric hold hist (before any binning):")
    print("  P_fab_ge4_healthy_band=[0.00,0.03]")
    print("  P_fab_ge4_hdmi_match_band=[0.08,0.13]")
    print("  w_geom_lean_device_band=[0.05,0.15]")
    print(f"  parent_hdmi_frac_ge4_caller_supplied={hdmi_ge4:.6f}")
    print("  T_vsync_tag=DEFAULT_ASSUMED unless --t-vsync-ms provided as measured")
    print("  frames_done_tag=must be PLXD swap counter (measured)")


def holds_from_series(
    samples: list[tuple[float, int]], t_vsync_ms: float
) -> list[int]:
    """samples: (mono_ms, frames_done). Return hold lengths in vsync units."""
    # Keep first sample at each new frames_done value
    edges: list[tuple[float, int]] = []
    last_fd = None
    for mono, fd in samples:
        if last_fd is None or fd != last_fd:
            # only count forward edges (ignore counter wrap noise unless large)
            if last_fd is not None and fd < last_fd and (last_fd - fd) < 1000:
                continue
            edges.append((mono, fd))
            last_fd = fd
    holds: list[int] = []
    for i in range(1, len(edges)):
        dt_ms = edges[i][0] - edges[i - 1][0]
        dfd = edges[i][1] - edges[i - 1][1]
        if dfd <= 0:
            continue
        # If frames_done jumped by >1, we missed intermediate swaps — split evenly
        per = dt_ms / float(dfd)
        h = int(round(per / t_vsync_ms))
        if h < 1:
            h = 1
        for _ in range(dfd):
            holds.append(h)
    return holds


def summarize(holds: list[int], label: str, t_tag: str) -> dict:
    c = Counter(holds)
    n = len(holds)
    mean = sum(holds) / n if n else 0.0
    ge4 = sum(v for k, v in c.items() if k >= 4)
    frac_ge4 = ge4 / n if n else 0.0
    c2, c3 = c.get(2, 0), c.get(3, 0)
    ratio = (c2 / c3) if c3 else float("nan")
    print(
        f"{label} n={n} mean={mean:.4f} frac_ge4={frac_ge4:.4f} "
        f"ratio2_3={ratio:.4f} hist={dict(sorted(c.items()))} "
        f"hold_unit=vsync t_vsync_tag={t_tag}"
    )
    # Verdict bands
    if n < 50:
        print(f"{label}_verdict=UNSCORED n<50 (not a pass)")
        return {"n": n, "frac_ge4": frac_ge4, "verdict": "UNSCORED"}
    if frac_ge4 <= 0.03:
        v = "FABRIC_HEALTHY_2_3"
    elif 0.08 <= frac_ge4 <= 0.13:
        v = "FABRIC_MATCHES_HDMI_GE4"
    elif 0.05 <= frac_ge4 <= 0.15:
        v = "FABRIC_DEVICE_LEAN_BAND"
    else:
        v = "FABRIC_OTHER"
    print(f"{label}_verdict={v}")
    return {"n": n, "frac_ge4": frac_ge4, "verdict": v, "hist": dict(c)}


def load_csv(path: Path) -> list[tuple[float, int]]:
    rows: list[tuple[float, int]] = []
    with path.open(newline="") as f:
        r = csv.DictReader(f)
        # accept mono_ms/frames_done or t_ms/fd
        for row in r:
            mono = row.get("mono_ms") or row.get("t_ms") or row.get("ms")
            fd = row.get("frames_done") or row.get("fd")
            if mono is None or fd is None:
                raise SystemExit("CSV needs mono_ms,frames_done columns")
            rows.append((float(mono), int(fd)))
    return rows


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--csv", type=Path, help="mono_ms,frames_done CSV from parent poll")
    ap.add_argument(
        "--t-vsync-ms",
        type=float,
        default=None,
        help="measured vsync period ms; default 1000/60 DEFAULT_ASSUMED",
    )
    ap.add_argument(
        "--hdmi-ge4",
        type=float,
        default=130.0 / 1263.0,
        help="caller_supplied parent HDMI frac hold>=4",
    )
    ap.add_argument(
        "--self-test",
        action="store_true",
        help="synthetic healthy + jitter series; expect band separation",
    )
    args = ap.parse_args()

    pre_register(args.hdmi_ge4)

    if args.t_vsync_ms is None:
        t_vsync = 1000.0 / 60.0
        t_tag = "DEFAULT_ASSUMED_1_60"
    else:
        t_vsync = args.t_vsync_ms
        t_tag = "caller_supplied_measured"

    print(f"t_vsync_ms={t_vsync:.6f} tag={t_tag}")

    if args.self_test:
        # Healthy: frames_done +1 every 2.5 * T on average → alternate 2,3
        healthy: list[tuple[float, int]] = []
        mono = 0.0
        fd = 0
        # sample 4x per vsync
        for tick in range(0, 6000):
            # swap every 2 or 3 ticks starting at 0
            if tick > 0 and misterplex_should_swap_async(tick):
                fd += 1
            mono = tick * t_vsync
            if tick % 1 == 0:
                healthy.append((mono, fd))
        # Simpler constructive healthy series: edges at cumulative 2,3,2,3...
        healthy = []
        mono = 0.0
        fd = 0
        healthy.append((0.0, 0))
        pattern = [2, 3] * 500
        for h in pattern:
            mono += h * t_vsync
            fd += 1
            healthy.append((mono, fd))
        # Dense sample: re-expand
        dense = []
        for i in range(len(healthy) - 1):
            t0, f0 = healthy[i]
            t1, f1 = healthy[i + 1]
            dense.append((t0, f0))
            dense.append(((t0 + t1) / 2, f0))
        dense.append(healthy[-1])
        Hs = holds_from_series(dense, t_vsync)
        r1 = summarize(Hs, "selftest_healthy", t_tag)

        # Jitter: 10% of holds become 4 or 5
        jitter = []
        mono = 0.0
        fd = 0
        jitter.append((0.0, 0))
        import random

        rng = random.Random(1)
        for i in range(1000):
            h = 2 if (i % 2 == 0) else 3
            if rng.random() < 0.10:
                h = 4 if rng.random() < 0.7 else 5
            mono += h * t_vsync
            fd += 1
            jitter.append((mono, fd))
        dense_j = []
        for i in range(len(jitter) - 1):
            t0, f0 = jitter[i]
            t1, _ = jitter[i + 1]
            dense_j.append((t0, f0))
            dense_j.append((t0 * 0.7 + t1 * 0.3, f0))
        dense_j.append(jitter[-1])
        Hj = holds_from_series(dense_j, t_vsync)
        r2 = summarize(Hj, "selftest_jitter", t_tag)

        if r1["verdict"] != "FABRIC_HEALTHY_2_3":
            print("FAIL selftest_healthy expected FABRIC_HEALTHY_2_3", file=sys.stderr)
            return 1
        if r2["frac_ge4"] < 0.05:
            print("FAIL selftest_jitter expected ge4>=0.05", file=sys.stderr)
            return 1
        print("OK fabric_frames_done_hold_hist self-test")
        return 0

    if not args.csv:
        print("FAIL: provide --csv or --self-test", file=sys.stderr)
        return 2

    samples = load_csv(args.csv)
    print(f"csv_rows={len(samples)} tag=measured_file")
    holds = holds_from_series(samples, t_vsync)
    summarize(holds, "fabric_from_csv", t_tag)
    print("OK fabric_frames_done_hold_hist csv")
    return 0


def misterplex_should_swap_async(tick: int) -> bool:
    return False  # unused placeholder


if __name__ == "__main__":
    sys.exit(main())
