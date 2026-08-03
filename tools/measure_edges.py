#!/usr/bin/env python3
"""Measure horizontal edge straightness of the MiSTer picture over HDMI capture.

Why this exists
---------------
The video defect that cost two days was diagnosed by one measurement: the LEFT
edge of the picture wandered per scanline while the RIGHT edge was pixel
perfect. That asymmetry is the fingerprint of a DDR line fetch starting late
(ddr_frame_store returns black on a miss), and it distinguishes an RTL
line-fetch problem from stride, decode, scaler or grabber faults -- all of which
would disturb BOTH edges.

Measured references (parent-captured, real hardware):
    dev core, idle screen : LEFT spread 27 px, RIGHT spread  0 px  -> DEFECT
    v0.2.0 core, playback : LEFT spread 13 px, RIGHT spread 12 px  -> OK

Grabber warm-up
---------------
The HDMI-over-USB grabber emits ~15 junk frames that are a single flat value
(min == max). Those are NOT evidence of a black screen. This tool discards every
uniform frame and fails loudly if nothing usable remains, so a dead capture can
never be misread as a passing black screen.

Usage:
    measure_edges.py FRAME.png [FRAME.png ...] [--threshold N] [--json]
"""

import argparse
import json
import sys

try:
    from PIL import Image
except ImportError:
    sys.exit("ERROR: Pillow required (pip install Pillow)")

WARMUP_NOTE = "uniform frame (grabber warm-up or no signal) - discarded, not evidence"


def frame_edges(path, threshold, min_run):
    """Return per-row first/last bright x, or None if the frame is unusable."""
    im = Image.open(path).convert("L")
    lo, hi = im.getextrema()
    if lo == hi:
        return None  # warm-up / no capture -- never scored
    w, h = im.size
    px = im.load()
    firsts, lasts = [], []
    for y in range(40, h - 40, 8):
        first = last = None
        for x in range(w):
            if px[x, y] > threshold:
                first = x
                break
        if first is None:
            continue
        for x in range(w - 1, -1, -1):
            if px[x, y] > threshold:
                last = x
                break
        # Ignore rows with almost no content; a few stray pixels are not an edge.
        if last - first >= min_run:
            firsts.append(first)
            lasts.append(last)
    if not firsts:
        return None
    return firsts, lasts


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("frames", nargs="+")
    ap.add_argument("--threshold", type=int, default=20)
    ap.add_argument("--min-run", type=int, default=200,
                    help="minimum bright span for a row to count as an edge")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    best = None
    discarded = 0
    for path in args.frames:
        res = frame_edges(path, args.threshold, args.min_run)
        if res is None:
            discarded += 1
            continue
        firsts, lasts = res
        # Score the frame with the most usable rows -- most content to judge.
        if best is None or len(firsts) > len(best[1]):
            best = (path, firsts, lasts)

    if best is None:
        print(f"FAIL no usable frame: {len(args.frames)} supplied, "
              f"{discarded} {WARMUP_NOTE}")
        return 2

    path, firsts, lasts = best
    left = max(firsts) - min(firsts)
    right = max(lasts) - min(lasts)
    out = {
        "frame": path,
        "rows": len(firsts),
        "discarded_uniform": discarded,
        "left_min": min(firsts), "left_max": max(firsts), "left_spread": left,
        "right_min": min(lasts), "right_max": max(lasts), "right_spread": right,
        # The defect signature: left wanders while right is solid.
        "asymmetric_left_wander": left >= 20 and right <= 5,
    }
    if args.json:
        print(json.dumps(out, indent=2))
    else:
        print(f"frame={path} rows={len(firsts)} discarded_uniform={discarded}")
        print(f"LEFT  min={min(firsts)} max={max(firsts)} spread={left}")
        print(f"RIGHT min={min(lasts)} max={max(lasts)} spread={right}")
        if out["asymmetric_left_wander"]:
            print("VERDICT: DEFECT - left edge wanders, right edge solid "
                  "-> DDR line fetch starting late (needs a Quartus fit)")
        else:
            print("VERDICT: no asymmetric left-wander signature")
    return 0


if __name__ == "__main__":
    sys.exit(main())
