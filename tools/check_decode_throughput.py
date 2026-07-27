#!/usr/bin/env python3
"""Check stream_path decode throughput against a declared realtime ratchet."""
from __future__ import annotations

import argparse
import json
import math
from pathlib import Path


def fail(msg: str) -> int:
    print(f"FAIL decode throughput: {msg}")
    return 1


def load_json(path: str) -> dict:
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def require(cond: bool, msg: str) -> None:
    if not cond:
        raise ValueError(msg)


def derive(compare: dict, ratchet: dict) -> dict:
    require(compare.get("format") == "misterplex.p3.frame_planes_compare.v1",
            "compare JSON is not misterplex.p3.frame_planes_compare.v1")
    require(ratchet.get("format") == "misterplex.decode_throughput_ratchet.v1",
            "ratchet JSON is not misterplex.decode_throughput_ratchet.v1")

    geometry = compare["geometry"]
    width = int(geometry["width"])
    height = int(geometry["height"])
    mb_w = width // 16
    mb_h = height // 16
    require(width % 16 == 0 and height % 16 == 0, "geometry is not whole macroblocks")
    frames = len(compare.get("frames", []))
    if frames == 0:
        frames = int(compare["summary"]["idr"]) + int(compare["summary"]["p"])
    require(frames > 0, "compare JSON has no decoded frames")
    cycles_total = int(compare["summary"]["cycles"])
    mbs_per_frame = mb_w * mb_h
    total_mbs = mbs_per_frame * frames

    target = ratchet["target"]
    clock_hz = int(target["stream_path_clock_hz"])
    fps = float(target["fps"])
    budget_cycles_per_frame = clock_hz / fps
    budget_cycles_per_mb = budget_cycles_per_frame / mbs_per_frame
    cycles_per_frame = cycles_total / frames
    cycles_per_mb = cycles_total / total_mbs
    margin_ratio = budget_cycles_per_frame / cycles_per_frame

    return {
        "format": "misterplex.decode_throughput_report.v1",
        "source": compare["source"],
        "geometry": {
            "width": width,
            "height": height,
            "mb_w": mb_w,
            "mb_h": mb_h,
            "mbs_per_frame": mbs_per_frame,
            "frames": frames,
        },
        "target": target,
        "measured": {
            "cycles_total": cycles_total,
            "cycles_per_frame": cycles_per_frame,
            "cycles_per_mb": cycles_per_mb,
        },
        "budget": {
            "cycles_per_frame": budget_cycles_per_frame,
            "cycles_per_mb": budget_cycles_per_mb,
            "margin_ratio": margin_ratio,
        },
        "stage_coverage": ratchet["stage_coverage"],
        "thresholds": ratchet["thresholds"],
    }


def check_report(report: dict) -> list[str]:
    thresholds = report["thresholds"]
    measured = report["measured"]
    budget = report["budget"]
    failures: list[str] = []
    max_total = thresholds.get("max_cycles_total")
    if max_total is not None and measured["cycles_total"] > float(max_total):
        failures.append(f"cycles_total {measured['cycles_total']} > ratchet {max_total}")
    max_frame = thresholds.get("max_cycles_per_frame")
    if max_frame is not None and measured["cycles_per_frame"] > float(max_frame):
        failures.append(
            f"cycles_per_frame {measured['cycles_per_frame']:.3f} > ratchet {float(max_frame):.3f}"
        )
    max_mb = thresholds.get("max_cycles_per_mb")
    if max_mb is not None and measured["cycles_per_mb"] > float(max_mb):
        failures.append(
            f"cycles_per_mb {measured['cycles_per_mb']:.3f} > ratchet {float(max_mb):.3f}"
        )
    min_margin = thresholds.get("min_budget_margin_ratio")
    if min_margin is not None and budget["margin_ratio"] < float(min_margin):
        failures.append(
            f"budget margin {budget['margin_ratio']:.3f} < required {float(min_margin):.3f}"
        )
    if measured["cycles_per_frame"] > budget["cycles_per_frame"]:
        failures.append(
            f"measured frame cost {measured['cycles_per_frame']:.3f} exceeds realtime budget "
            f"{budget['cycles_per_frame']:.3f}"
        )
    return failures


def print_raw(report: dict) -> None:
    g = report["geometry"]
    m = report["measured"]
    b = report["budget"]
    target = report["target"]
    print(
        "DECODE_THROUGHPUT_RAW "
        f"clock_hz={target['stream_path_clock_hz']} fps={target['fps']} "
        f"frames={g['frames']} mbs_per_frame={g['mbs_per_frame']} "
        f"cycles_total={m['cycles_total']} cycles_per_frame={m['cycles_per_frame']:.3f} "
        f"cycles_per_mb={m['cycles_per_mb']:.3f} "
        f"budget_cycles_per_frame={b['cycles_per_frame']:.3f} "
        f"budget_cycles_per_mb={b['cycles_per_mb']:.3f} "
        f"margin_ratio={b['margin_ratio']:.3f}"
    )
    for stage in report["stage_coverage"]:
        status = stage["status"]
        value = stage.get("cycles_per_mb")
        rendered = "UNKNOWN" if value is None else f"{float(value):.3f}"
        print(
            "DECODE_THROUGHPUT_STAGE "
            f"name={stage['name']} status={status} cycles_per_mb={rendered} "
            f"note={stage['note']}"
        )


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--compare-json", required=True)
    ap.add_argument("--ratchet", required=True)
    ap.add_argument("--report")
    args = ap.parse_args()

    try:
        report = derive(load_json(args.compare_json), load_json(args.ratchet))
    except (KeyError, TypeError, ValueError) as e:
        return fail(str(e))

    if args.report:
        Path(args.report).parent.mkdir(parents=True, exist_ok=True)
        Path(args.report).write_text(json.dumps(report, indent=2, sort_keys=True) + "\n",
                                     encoding="utf-8")

    print_raw(report)
    failures = check_report(report)
    if failures:
        for item in failures:
            print("FAIL decode throughput: " + item)
        return 1
    print(
        "OK decode throughput: "
        f"cycles_per_mb={report['measured']['cycles_per_mb']:.3f} "
        f"budget={report['budget']['cycles_per_mb']:.3f} "
        f"margin={report['budget']['margin_ratio']:.3f}x"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
