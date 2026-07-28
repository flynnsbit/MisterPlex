#!/usr/bin/env python3
"""Distinguish a locked HDMI capture from unlocked digital snow.

WHY THIS EXISTS
---------------
2026-07-28: a capture gate classified frames as CONTENT_PRESENT using
`spatial_std >= threshold`. Random noise maximises spatial std, so the gate
fired on HDMI sync-loss snow and reported "content present at t=20.2s" for a
frame that was pure static. A brightness/variance pair cannot tell structure
from noise; both are single-pixel statistics.

That same gate could never emit NO_SIGNAL for the MS2109 dongle, because it
tested `luma < LUMA_BLACK` FIRST and a no-signal frame is flat RGB(7,7,7).
The NO_SIGNAL branch was unreachable for the one condition it named, so
"0 NO_SIGNAL frames" was used as proof the HDMI link was alive when it was
structurally incapable of reporting otherwise.

WHAT THIS MEASURES
------------------
Spatial structure, which noise does not have:

  lag-N horizontal autocorrelation — real content stays correlated at a
      distance; snow decorrelates immediately. Lag 1 alone is NOT enough:
      MJPEG 8x8 block smoothing lifts a snow frame to ~0.65 at lag 1 while
      it sits at ~0.07 by lag 4.
  flat 8x8 block fraction — real UI/video has large uniform regions; snow
      has none at all.

Exit codes
  0   LOCKED     structured content, HDMI locked
  1   SNOW       unlocked / sync loss - NOT content, do not score as content
  2   usage/read error
  77  UNSCORED   no frames supplied
"""

import argparse
import os
import sys

LAG16_MIN = 0.35   # below this, structure is gone by 16 px
FLAT_MIN = 2.0     # percent of 8x8 blocks that are near-uniform


def analyse(path):
    import numpy as np
    from PIL import Image
    a = np.asarray(Image.open(path).convert("L"), dtype=np.float64)
    if a.ndim != 2 or a.shape[0] < 32 or a.shape[1] < 32:
        raise ValueError(f"{path}: image too small to analyse")

    def ac(lag):
        x = a[:, :-lag].ravel()
        y = a[:, lag:].ravel()
        sx, sy = x.std(), y.std()
        if sx == 0 or sy == 0:
            return 1.0  # perfectly flat: degenerate, treat as maximally correlated
        return float(np.corrcoef(x, y)[0, 1])

    h, w = a.shape
    H, W = h // 8 * 8, w // 8 * 8
    blocks = (a[:H, :W]
              .reshape(H // 8, 8, W // 8, 8)
              .transpose(0, 2, 1, 3)
              .reshape(-1, 64))
    flat = float((blocks.std(axis=1) < 2.0).mean() * 100.0)
    return {
        "luma": float(a.mean()),
        "std": float(a.std()),
        "lag1": ac(1),
        "lag4": ac(4),
        "lag16": ac(16),
        "flat_pct": flat,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("frames", nargs="*", help="PNG/JPG frames to classify")
    ap.add_argument("--lag16-min", type=float, default=LAG16_MIN)
    ap.add_argument("--flat-min", type=float, default=FLAT_MIN)
    args = ap.parse_args()

    frames = [f for f in args.frames if os.path.exists(f)]
    print(f"Scope: {len(frames)} frames "
          f"(thresholds lag16>={args.lag16_min} flat>={args.flat_min}%)")
    missing = [f for f in args.frames if not os.path.exists(f)]
    for m in missing:
        print(f"MISSING {m}", file=sys.stderr)
    if not frames:
        print("UNSCORED: no readable frames supplied; a gate with Scope: 0 "
              "cannot report LOCKED or SNOW", file=sys.stderr)
        return 77

    try:
        import numpy  # noqa: F401
        from PIL import Image  # noqa: F401
    except ImportError as e:
        print(f"UNSCORED: missing dependency ({e}); cannot measure", file=sys.stderr)
        return 77

    print(f"{'frame':38s} {'luma':>7} {'std':>7} {'lag1':>7} {'lag4':>7} "
          f"{'lag16':>7} {'flat%':>7}  verdict")
    snow = 0
    for f in frames:
        try:
            m = analyse(f)
        except Exception as e:  # noqa: BLE001
            print(f"ERROR {f}: {e}", file=sys.stderr)
            return 2
        is_snow = m["lag16"] < args.lag16_min and m["flat_pct"] < args.flat_min
        if is_snow:
            snow += 1
        print(f"{os.path.basename(f):38s} {m['luma']:7.2f} {m['std']:7.2f} "
              f"{m['lag1']:7.3f} {m['lag4']:7.3f} {m['lag16']:7.3f} "
              f"{m['flat_pct']:6.1f}%  {'SNOW' if is_snow else 'LOCKED'}")

    print(f"---\nsnow_frames={snow}/{len(frames)}")
    if snow:
        print("SNOW: at least one frame is unlocked HDMI noise. High spatial std "
              "on such a frame is NOISE, not content; do not score it as "
              "CONTENT_PRESENT.")
        return 1
    print("LOCKED: all frames show spatial structure consistent with a locked "
          "HDMI signal.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
