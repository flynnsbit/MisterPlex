#!/usr/bin/env python3
"""Luma-only progress metric alongside unmodified tools/score_i420_candidate.py.

The product scorer's mb_exact() requires Y+U+V block match. When chroma is
still stubbed to 128, headline intra/inter MB-exact stays 0 even if luma is
correct. This tool reports Y-plane MB exact, 4x4 exact, pixel exact, and MAE
so decode progress is visible without weakening the headline scorer.

Does NOT modify or wrap score_i420_candidate.py.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any


def frame_bytes(width: int, height: int) -> int:
    return width * height * 3 // 2


def y_plane(blob: bytes, frame: int, width: int, height: int) -> memoryview:
    fb = frame_bytes(width, height)
    base = frame * fb
    return memoryview(blob)[base : base + width * height]


def score_frame_y(
    candidate: bytes, golden: bytes, frame: int, width: int, height: int
) -> dict[str, Any]:
    cy = y_plane(candidate, frame, width, height)
    gy = y_plane(golden, frame, width, height)
    n = width * height
    exact_px = 0
    sum_abs = 0
    max_abs = 0
    first_bad: dict[str, Any] | None = None
    for i in range(n):
        d = abs(int(cy[i]) - int(gy[i]))
        if d == 0:
            exact_px += 1
        else:
            sum_abs += d
            if d > max_abs:
                max_abs = d
            if first_bad is None:
                first_bad = {
                    "x": i % width,
                    "y": i // width,
                    "got": int(cy[i]),
                    "ref": int(gy[i]),
                    "abs": d,
                }

    mb_w = width // 16
    mb_h = height // 16
    mb_exact = 0
    blk4_exact = 0
    blk4_total = mb_w * mb_h * 16
    for my in range(mb_h):
        for mx in range(mb_w):
            mb_ok = True
            for by in range(4):
                for bx in range(4):
                    b_ok = True
                    for yy in range(4):
                        y = my * 16 + by * 4 + yy
                        row = y * width
                        for xx in range(4):
                            x = mx * 16 + bx * 4 + xx
                            if cy[row + x] != gy[row + x]:
                                b_ok = False
                                mb_ok = False
                                break
                        if not b_ok:
                            break
                    if b_ok:
                        blk4_exact += 1
            if mb_ok:
                mb_exact += 1

    return {
        "frame_index": frame,
        "y_mb_exact": mb_exact,
        "y_mb_total": mb_w * mb_h,
        "y_blk4_exact": blk4_exact,
        "y_blk4_total": blk4_total,
        "y_pixel_exact": exact_px,
        "y_pixel_total": n,
        "y_mae": (sum_abs / n) if n else 0.0,
        "y_max_abs": max_abs,
        "y_first_bad": first_bad,
    }


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--golden-planes", required=True)
    ap.add_argument("--candidate-planes", required=True)
    ap.add_argument("--width", type=int, required=True)
    ap.add_argument("--height", type=int, required=True)
    ap.add_argument("--frames", type=int, default=0, help="0 = infer from file size")
    ap.add_argument("--i-frames", type=int, default=1, help="leading I frames for intra bucket")
    ap.add_argument("--output", help="optional JSON path")
    args = ap.parse_args()

    w, h = args.width, args.height
    fb = frame_bytes(w, h)
    golden = Path(args.golden_planes).read_bytes()
    cand = Path(args.candidate_planes).read_bytes()
    if len(golden) % fb or len(cand) % fb:
        raise SystemExit(
            f"plane size not multiple of frame_bytes={fb}: "
            f"golden={len(golden)} candidate={len(cand)}"
        )
    if len(golden) != len(cand):
        raise SystemExit(f"size mismatch golden={len(golden)} candidate={len(cand)}")
    nframes = args.frames or (len(golden) // fb)
    if nframes * fb != len(golden):
        raise SystemExit("frames does not match plane size")

    frames = [score_frame_y(cand, golden, f, w, h) for f in range(nframes)]
    i_n = min(args.i_frames, nframes)
    intra = frames[:i_n]
    inter = frames[i_n:]

    def agg(rows: list[dict[str, Any]]) -> dict[str, Any]:
        if not rows:
            return {
                "frames": 0,
                "y_mb_exact": 0,
                "y_mb_total": 0,
                "y_blk4_exact": 0,
                "y_blk4_total": 0,
                "y_pixel_exact": 0,
                "y_pixel_total": 0,
                "y_mae_mean": 0.0,
            }
        return {
            "frames": len(rows),
            "y_mb_exact": sum(r["y_mb_exact"] for r in rows),
            "y_mb_total": sum(r["y_mb_total"] for r in rows),
            "y_blk4_exact": sum(r["y_blk4_exact"] for r in rows),
            "y_blk4_total": sum(r["y_blk4_total"] for r in rows),
            "y_pixel_exact": sum(r["y_pixel_exact"] for r in rows),
            "y_pixel_total": sum(r["y_pixel_total"] for r in rows),
            "y_mae_mean": sum(r["y_mae"] for r in rows) / len(rows),
        }

    out = {
        "format": "misterplex.p3.luma_progress.v1",
        "note": (
            "Companion to score_i420_candidate.py. Headline MB-exact stays Y+U+V; "
            "this metric is Y-only so chroma-stubbed decodes show real luma progress."
        ),
        "geometry": {"width": w, "height": h, "frames": nframes},
        "summary": {
            "intra": agg(intra),
            "inter": agg(inter),
            "all": agg(frames),
        },
        "frames": frames,
    }

    si = out["summary"]["intra"]
    sp = out["summary"]["inter"]
    print(
        f"LUMA_PROGRESS intra_y_mb={si['y_mb_exact']}/{si['y_mb_total']} "
        f"intra_y_blk4={si['y_blk4_exact']}/{si['y_blk4_total']} "
        f"intra_y_px={si['y_pixel_exact']}/{si['y_pixel_total']} "
        f"intra_y_mae={si['y_mae_mean']:.6f}"
    )
    print(
        f"LUMA_PROGRESS inter_y_mb={sp['y_mb_exact']}/{sp['y_mb_total']} "
        f"inter_y_blk4={sp['y_blk4_exact']}/{sp['y_blk4_total']} "
        f"inter_y_px={sp['y_pixel_exact']}/{sp['y_pixel_total']} "
        f"inter_y_mae={sp['y_mae_mean']:.6f}"
    )
    if frames:
        f0 = frames[0]
        print(
            f"LUMA_PROGRESS frame0 y_mb={f0['y_mb_exact']}/{f0['y_mb_total']} "
            f"y_blk4={f0['y_blk4_exact']}/{f0['y_blk4_total']} "
            f"y_px={f0['y_pixel_exact']}/{f0['y_pixel_total']} "
            f"y_mae={f0['y_mae']:.6f}"
        )

    if args.output:
        Path(args.output).write_text(json.dumps(out, indent=2) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
