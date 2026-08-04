#!/usr/bin/env python3
"""Measure HDMI refresh from capture timestamps (parent host, /dev/video0).

Distinguishes 24 Hz from the 16.16 Hz same-clock trap. Single still frames cannot.

Does NOT use bare ffmpeg -frames:v 1 (false black). Uses multi-frame grab with PTS.
"""
from __future__ import annotations

import argparse
import statistics
import subprocess
import sys
import time


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--seconds", type=float, default=2.0)
    ap.add_argument("--device", default="/dev/video0")
    args = ap.parse_args()

    # Use ffmpeg showinfo on a short grab; parse pts_time deltas.
    # ~15 frame warm-up discarded by taking median of later dts.
    dur = max(args.seconds, 1.5)
    cmd = [
        "ffmpeg",
        "-hide_banner",
        "-loglevel",
        "info",
        "-f",
        "v4l2",
        "-i",
        args.device,
        "-t",
        str(dur),
        "-vf",
        "showinfo",
        "-f",
        "null",
        "-",
    ]
    print(f"PRE-REG bands: PASS 23.0-25.5 Hz; FAIL-trap 15.5-17.0 Hz; device={args.device}")
    try:
        proc = subprocess.run(
            cmd, text=True, capture_output=True, timeout=int(dur) + 30
        )
    except FileNotFoundError:
        print("FAIL: ffmpeg not found", file=sys.stderr)
        return 2
    except subprocess.TimeoutExpired:
        print("FAIL: ffmpeg timeout", file=sys.stderr)
        return 2

    err = proc.stderr or ""
    pts = []
    for line in err.splitlines():
        if "pts_time:" not in line:
            continue
        # n: 12 pts: 123 pts_time:1.23456
        try:
            part = line.split("pts_time:")[1].split()[0]
            pts.append(float(part))
        except (IndexError, ValueError):
            continue

    if len(pts) < 8:
        print(f"FAIL: too few pts ({len(pts)}); grabber busy or not ready", file=sys.stderr)
        print(err[-2000:], file=sys.stderr)
        return 1

    # Drop first 5 (warm-up)
    pts = pts[5:]
    dts = [pts[i + 1] - pts[i] for i in range(len(pts) - 1) if pts[i + 1] > pts[i]]
    if len(dts) < 4:
        print("FAIL: no positive dts", file=sys.stderr)
        return 1
    med = statistics.median(dts)
    fps = 1.0 / med if med > 0 else 0.0
    print(f"RESULT n_dts={len(dts)} median_dt={med:.6f}s fps={fps:.3f}")

    if 23.0 <= fps <= 25.5:
        print("PASS hdmi_measure_refresh: ~24 Hz band")
        return 0
    if 15.5 <= fps <= 17.0:
        print(
            "FAIL hdmi_measure_refresh: ~16.16 Hz SAME-CLOCK TRAP "
            "(clk_pix still effective 20 MHz on COMPACT glass)",
            file=sys.stderr,
        )
        return 1
    print(f"FAIL hdmi_measure_refresh: fps={fps:.3f} outside 24 and 16 bands", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
