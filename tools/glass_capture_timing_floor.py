#!/usr/bin/env python3
"""MS2109 capture-timing floor from ffmpeg showinfo pts_time.

Scope (hard)
------------
Bounds grabber+ffmpeg DELIVERY TIMING only. Static content ⇒ zero true motion;
any pts irregularity is path-side. Does NOT measure content duplication/skip
(a free-running 30 fps grabber on 60 Hz HDMI can duplicate content on perfect
timestamps). Content-hold/IFI claims stay device_attributable=False until a
content-duplication floor exists.

Do NOT pass this JSON as --floor-json for content judder attribution
(gates_content_hold_ifi=false).

Usage
-----
  # Parent capture (static logo on device — only available source without recable):
  ffmpeg -hide_banner -loglevel info -f v4l2 -input_format mjpeg \
    -video_size 1920x1080 -i /dev/video0 -vf showinfo -frames:v 150 \
    -f null - 2>&1 | tee /tmp/pts_static_raw.txt | rg pts_time > /tmp/pts_static.txt
  # NOTE: -v error suppresses showinfo — use -loglevel info (B2 trap).

  python3 tools/glass_capture_timing_floor.py /tmp/pts_static.txt; echo "true rc=$?"
  python3 tools/glass_capture_timing_floor.py /tmp/pts_static.txt --json > floor_capture_timing.json

Exit: 0 FLOOR_CAPTURE_TIMING_OK | 2 IRREGULAR | 77 UNSCORED
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any

import numpy as np

RC_OK = 0
RC_FAIL = 2
RC_UNSCORED = 77
DEFAULT_WARMUP_FRAMES = 15


def parse_pts_file(path: Path) -> list[float]:
    text = path.read_text(errors="replace")
    return [float(m.group(1)) for m in re.finditer(r"pts_time:\s*([0-9.eE+-]+)", text)]


def analyze_pts(
    pts: list[float],
    *,
    warmup_skip_frames: int = DEFAULT_WARMUP_FRAMES,
    label: str = "",
) -> dict[str, Any]:
    if len(pts) < warmup_skip_frames + 5:
        return {
            "role": "instrument_floor_capture_timing",
            "label": label,
            "verdict": "UNSCORED",
            "rc": RC_UNSCORED,
            "reason": f"too_few_pts n={len(pts)} need>={warmup_skip_frames + 5}",
            "device_attributable": False,
            "gates_content_hold_ifi": False,
            "content_duplication_floor": "UNMEASURED",
        }
    arr = np.asarray(pts, dtype=np.float64)
    d_all = np.diff(arr) * 1000.0
    d = d_all[warmup_skip_frames:]
    d = d[d > 0]
    if len(d) < 20:
        return {
            "role": "instrument_floor_capture_timing",
            "label": label,
            "verdict": "UNSCORED",
            "rc": RC_UNSCORED,
            "reason": f"too_few_intervals_after_warmup n={len(d)}",
            "device_attributable": False,
            "gates_content_hold_ifi": False,
            "content_duplication_floor": "UNMEASURED",
        }
    med = float(np.median(d))
    p50 = float(np.percentile(d, 50))
    p95 = float(np.percentile(d, 95))
    p99 = float(np.percentile(d, 99))
    mn = float(d.min())
    mx = float(d.max())
    mean = float(d.mean())
    std = float(d.std(ddof=1))
    out15 = int(np.sum(d > 1.5 * med))
    out20 = int(np.sum(d > 2.0 * med))
    fps = 1000.0 / mean if mean > 0 else None
    bins: dict[str, int] = {}
    for v in d:
        k = f"{round(float(v) * 2) / 2:.1f}"
        bins[k] = bins.get(k, 0) + 1
    max_dev = float(max(abs(mx - med), abs(mn - med)))
    # Pre-register (locked with parent measurement): OK if no 1.5x outliers and
    # max_dev < 10 ms. Parent static floor: max_dev≈4.0 ms, outliers=0.
    ok = out15 == 0 and max_dev < 10.0
    verdict = "FLOOR_CAPTURE_TIMING_OK" if ok else "FLOOR_CAPTURE_TIMING_IRREGULAR"
    rc = RC_OK if ok else RC_FAIL
    return {
        "role": "instrument_floor_capture_timing",
        "role_src": "caller_supplied",
        "label": label or "capture_timing_floor",
        "scope": (
            "Bounds MS2109+ffmpeg DELIVERY TIMING only (pts intervals). "
            "Static source ⇒ zero true motion by construction. "
            "Does NOT characterise content duplication/skip. "
            "Content-hold/IFI stays device_attributable=False until content-dup floor."
        ),
        "warmup_skip_frames": warmup_skip_frames,
        "warmup_skip_frames_src": "DEFAULT_ASSUMED",
        "n_pts": int(len(pts)),
        "n_pts_src": "measured",
        "n_intervals_raw": int(len(d_all)),
        "n_intervals": int(len(d)),
        "n_intervals_src": "measured",
        "interval_ms_min": round(mn, 4),
        "interval_ms_p50": round(p50, 4),
        "interval_ms_p95": round(p95, 4),
        "interval_ms_p99": round(p99, 4),
        "interval_ms_max": round(mx, 4),
        "interval_ms_mean": round(mean, 4),
        "interval_ms_stdev": round(std, 4),
        "interval_stats_src": "measured",
        "interval_hist_0_5ms": {k: bins[k] for k in sorted(bins, key=lambda x: float(x))},
        "outliers_gt_1_5x_median": out15,
        "outliers_gt_2x_median": out20,
        "outliers_src": "measured",
        "max_dev_from_median_ms": round(max_dev, 4),
        "implied_capture_fps": round(fps, 6) if fps else None,
        "implied_capture_fps_src": "derived_1000_over_mean_interval",
        "leading_gap_ms": round(float(d_all[0]), 4) if len(d_all) else None,
        "pre_register_pass_if": (
            "after warmup: outliers_gt_1.5x_median==0 AND max_dev_from_median_ms < 10"
        ),
        "verdict": verdict,
        "rc": rc,
        "device_attributable": False,
        "device_attributable_src": "measured",
        "content_duplication_floor": "UNMEASURED",
        "gates_content_hold_ifi": False,
        "gates_content_hold_ifi_note": (
            "Do NOT pass this report as glass_motion_judder --floor-json. "
            "It does not gate content hold/IFI attribution."
        ),
        "mean_note": (
            "interval_mean informational; use hist + p50/p95/p99/max + outlier counts. "
            "max-only headlines forbidden."
        ),
        "reading": (
            f"n_intervals={len(d)} [measured] p50={p50:.2f} p95={p95:.2f} "
            f"p99={p99:.2f} max={mx:.2f} mean={mean:.2f} stdev={std:.2f} ms; "
            f"outliers_1.5x={out15} outliers_2x={out20}; "
            f"implied_fps={fps:.4f} [derived]; max_dev_from_median={max_dev:.2f} ms. "
            + (
                "Delivery-timing drops ruled out as sole cause of ~50 ms class excursions. "
                if ok
                else "Delivery-timing IRREGULAR — investigate grabber/USB before device claims. "
            )
            + "Content duplication floor still UNMEASURED."
        ),
    }


def _print_human(rep: dict[str, Any]) -> None:
    print(f"label={rep.get('label')} role={rep.get('role')}")
    print(f"scope={rep.get('scope')}")
    if rep.get("verdict") == "UNSCORED":
        print(f"reason={rep.get('reason')}")
        print(f"VERDICT={rep.get('verdict')} rc={rep.get('rc')}")
        return
    print(
        f"intervals n={rep.get('n_intervals')} [measured] "
        f"warmup_skip_frames={rep.get('warmup_skip_frames')} [DEFAULT_ASSUMED] "
        f"leading_gap_ms={rep.get('leading_gap_ms')} [measured]"
    )
    print(
        f"interval_ms min={rep.get('interval_ms_min')} p50={rep.get('interval_ms_p50')} "
        f"p95={rep.get('interval_ms_p95')} p99={rep.get('interval_ms_p99')} "
        f"max={rep.get('interval_ms_max')} mean={rep.get('interval_ms_mean')} "
        f"stdev={rep.get('interval_ms_stdev')} [measured] "
        f"hist_0.5ms={rep.get('interval_hist_0_5ms')} NOTE={rep.get('mean_note')}"
    )
    print(
        f"outliers_gt_1.5x_median={rep.get('outliers_gt_1_5x_median')} "
        f"outliers_gt_2x_median={rep.get('outliers_gt_2x_median')} [measured] "
        f"max_dev_from_median_ms={rep.get('max_dev_from_median_ms')} [measured] "
        f"implied_capture_fps={rep.get('implied_capture_fps')} "
        f"[{rep.get('implied_capture_fps_src')}]"
    )
    print(
        f"device_attributable={rep.get('device_attributable')} "
        f"content_duplication_floor={rep.get('content_duplication_floor')} "
        f"gates_content_hold_ifi={rep.get('gates_content_hold_ifi')}"
    )
    print(f"reading={rep.get('reading')}")
    print(f"VERDICT={rep.get('verdict')} rc={rep.get('rc')}")


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("pts_file", type=Path, help="showinfo pts dump or pts_time lines")
    ap.add_argument("--warmup-skip-frames", type=int, default=DEFAULT_WARMUP_FRAMES)
    ap.add_argument("--label", default="")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args(argv)
    if not args.pts_file.is_file():
        print(f"ERROR: not found {args.pts_file}", file=sys.stderr)
        return RC_UNSCORED
    pts = parse_pts_file(args.pts_file)
    rep = analyze_pts(
        pts, warmup_skip_frames=int(args.warmup_skip_frames), label=args.label
    )
    if args.json:
        print(json.dumps(rep, indent=2))
    else:
        _print_human(rep)
    return int(rep.get("rc", RC_UNSCORED))


if __name__ == "__main__":
    raise SystemExit(main())
