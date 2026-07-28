#!/usr/bin/env python3
"""Decide whether the idle screen is animating, from a series of captures.

"The frames differ" is not motion on this rig. The resident core damages a
ragged leading run of every scanline and re-randomises it each frame, so any
whole-frame difference metric reports large, constant change on a completely
static picture. A screensaver gate built on frame difference would pass while
the screensaver is off.

What actually distinguishes a moving logo from a static one is where the bright
pixels are. This tracks the centroid of the brightest content, inside a crop
that excludes the damaged left band, and reports how far it travels. A static
picture holds the centroid still even while its left edge boils.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import numpy as np
from PIL import Image

RC_FAIL = 1
RC_UNSCORED = 77

DEFAULT_CROP_LEFT = 200  # past the measured damaged band (rows start by x=136)
DEFAULT_MIN_TRAVEL = 8.0

SCOPE = (
    "Scope: measures how far the bright-content centroid travels across a series "
    "of captured frames, inside a crop that excludes the damaged left band, to "
    "decide MOVING vs STATIC. It does not identify the image, does not verify the "
    "animation is the intended screensaver, and does not capture anything itself."
)


def centroid(path: Path, crop_left: int, percentile: float) -> tuple[float, float, float]:
    with Image.open(path) as im:
        a = np.asarray(im.convert("L"), dtype=np.float32)
    a = a[:, crop_left:]
    if a.size == 0:
        raise ValueError("crop removed the whole frame")
    cut = float(np.percentile(a, percentile))
    mask = a > cut
    if not mask.any():
        # The percentile can land exactly on the brightest level when the bright
        # region is larger than the tail; a strict compare would then see nothing.
        mask = a >= cut
    if not mask.any():
        return float("nan"), float("nan"), 0.0
    ys, xs = np.nonzero(mask)
    frac = float(mask.mean())
    # If the "brightest" selection covers most of the crop, the frame is
    # effectively uniform and its centroid is just the geometric centre. That is
    # a degenerate reading, not a static picture, and must not be graded STATIC.
    if frac > 0.5:
        return float("nan"), float("nan"), frac
    weights = a[ys, xs]
    total = float(weights.sum())
    if total <= 0.0:
        return float("nan"), float("nan"), frac
    return (
        float((xs * weights).sum() / total) + crop_left,
        float((ys * weights).sum() / total),
        float(mask.mean()),
    )


def analyse(paths: list[Path], crop_left: int, percentile: float, min_travel: float) -> dict:
    points = []
    for p in paths:
        cx, cy, frac = centroid(p, crop_left, percentile)
        points.append({"input": str(p), "cx": round(cx, 2), "cy": round(cy, 2),
                       "bright_fraction": round(frac, 4)})
    coords = np.array([[pt["cx"], pt["cy"]] for pt in points], dtype=np.float64)
    if np.isnan(coords).any():
        return {"verdict": "NO_CONTENT", "points": points,
                "reason": "no bright content above the percentile cut in the crop"}
    spans = coords.max(axis=0) - coords.min(axis=0)
    travel = float(np.hypot(*spans))
    result = {
        "points": points,
        "span_x": round(float(spans[0]), 2),
        "span_y": round(float(spans[1]), 2),
        "travel": round(travel, 2),
        "min_travel": min_travel,
        "crop_left": crop_left,
    }
    result["verdict"] = "MOVING" if travel >= min_travel else "STATIC"
    result["reason"] = (
        f"bright centroid travelled {travel:.1f}px across {len(paths)} frames "
        f"(threshold {min_travel})"
    )
    return result


def synth(dx: int, dy: int, boil_seed: int) -> np.ndarray:
    """Static or moving blob, both with a boiling damaged left band."""
    h, w = 720, 1280
    f = np.zeros((h, w), dtype=np.uint8)
    f[40:h - 40, 22:w - 24] = 0x2D
    cy, cx = h // 2 + dy, w // 2 + dx
    f[cy - 60:cy + 60, cx - 60:cx + 60] = 0xA0
    rng = np.random.default_rng(boil_seed)
    for y in range(40, h - 40):
        f[y, 22:22 + int(rng.integers(0, 190))] = 0
    return f


def run_self_test(args: argparse.Namespace, work: Path) -> int:
    work.mkdir(parents=True, exist_ok=True)
    failures = []

    def write(name: str, arr: np.ndarray) -> Path:
        p = work / name
        Image.fromarray(arr, mode="L").convert("RGB").save(p)
        return p

    # Static logo, different left-edge damage on every frame. A frame-difference
    # metric would call this motion; the centroid must not.
    static = [write(f"static{i}.png", synth(0, 0, 100 + i)) for i in range(3)]
    got = analyse(static, args.crop_left, args.percentile, args.min_travel)
    if got["verdict"] == "STATIC":
        print(f"OK synthetic/static: {got['reason']}")
    else:
        failures.append(f"static frames graded {got['verdict']}")
        print(f"FAIL synthetic/static: {got['reason']}")

    moving = [write(f"moving{i}.png", synth(40 * i, 25 * i, 200 + i)) for i in range(3)]
    got = analyse(moving, args.crop_left, args.percentile, args.min_travel)
    if got["verdict"] == "MOVING":
        print(f"OK synthetic/moving: {got['reason']}")
    else:
        failures.append(f"moving frames graded {got['verdict']}")
        print(f"FAIL synthetic/moving: {got['reason']}")

    black = [write(f"black{i}.png", np.zeros((720, 1280), dtype=np.uint8)) for i in range(2)]
    got = analyse(black, args.crop_left, args.percentile, args.min_travel)
    if got["verdict"] in ("NO_CONTENT", "STATIC"):
        print(f"OK synthetic/black: verdict={got['verdict']}")
    else:
        failures.append(f"black frames graded {got['verdict']}")
        print(f"FAIL synthetic/black: verdict={got['verdict']}")

    # A uniform frame has no bright region, so its "centroid" is just the crop
    # centre and is identical on every frame. Grading that STATIC would report a
    # blank screen as a healthy static idle picture, which is how a screensaver
    # gate silently passes on a dead display.
    for level in (0x07, 0xFF):
        flat = [
            write(f"flat{level}_{i}.png", np.full((720, 1280), level, dtype=np.uint8))
            for i in range(2)
        ]
        got = analyse(flat, args.crop_left, args.percentile, args.min_travel)
        if got["verdict"] == "NO_CONTENT":
            print(f"OK synthetic/uniform-0x{level:02X}: verdict=NO_CONTENT")
        else:
            failures.append(f"uniform 0x{level:02X} frames graded {got['verdict']}")
            print(f"FAIL synthetic/uniform-0x{level:02X}: verdict={got['verdict']}")

    if failures:
        print("IDLE_MOTION_RESULT=FAIL " + "; ".join(failures))
        return RC_FAIL
    print("IDLE_MOTION_RESULT=SELFTEST_PASS")
    return 0


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("inputs", nargs="*", help="captured frames in time order")
    ap.add_argument("--crop-left", type=int, default=DEFAULT_CROP_LEFT)
    ap.add_argument("--percentile", type=float, default=99.0)
    ap.add_argument("--min-travel", type=float, default=DEFAULT_MIN_TRAVEL)
    ap.add_argument("--expect", choices=["moving", "static", "any"], default="any")
    ap.add_argument("--json")
    ap.add_argument("--self-test", action="store_true")
    ap.add_argument("--work", default="build/idle_motion_selftest")
    args = ap.parse_args(argv)

    print(SCOPE)
    if args.self_test:
        return run_self_test(args, Path(args.work))

    paths = [Path(p) for p in args.inputs]
    missing = [str(p) for p in paths if not p.is_file()]
    if len(paths) < 2 or missing:
        print(f"IDLE_MOTION_RESULT=UNSCORED reason=need>=2-frames missing={missing}")
        return RC_UNSCORED

    result = analyse(paths, args.crop_left, args.percentile, args.min_travel)
    if args.json:
        out = Path(args.json)
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    for pt in result["points"]:
        print(f"IDLE_MOTION point cx={pt['cx']} cy={pt['cy']} bright={pt['bright_fraction']} {pt['input']}")
    print(f"IDLE_MOTION verdict={result['verdict']} travel={result.get('travel')} "
          f"span_x={result.get('span_x')} span_y={result.get('span_y')}")
    print(f"IDLE_MOTION reason: {result['reason']}")

    if args.expect == "any":
        print(f"IDLE_MOTION_RESULT=OBSERVED verdict={result['verdict']}")
        return 0
    want = "MOVING" if args.expect == "moving" else "STATIC"
    if result["verdict"] == want:
        print(f"IDLE_MOTION_RESULT=PASS verdict={result['verdict']}")
        return 0
    print(f"IDLE_MOTION_RESULT=FAIL verdict={result['verdict']} expected={want}")
    return RC_FAIL


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
