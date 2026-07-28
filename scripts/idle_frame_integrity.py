#!/usr/bin/env python3
"""Grade a captured MiSTer idle frame for left-edge scanline integrity.

``hdmi_capture_classify.py`` answers "is there a signal, and is it black?".
That is not enough for the idle screen: the resident core presents a frame whose
every scanline loses a ragged, per-frame-random prefix, and a mean/stddev
classifier happily calls the result VALID_CONTENT. To a user that is the
"jagged black lines moving" on the left side.

The discriminator used here is the *left content edge per row*. On an
undamaged idle frame every row of the active picture begins at the same
pillarboxed column, so the first non-black x is near-constant down the frame. A
per-line DDR underrun eats a different number of leading pixels on each line, so
that column becomes a noisy signal. Its spread, not its value, is the defect,
which means the check needs no golden image and survives a change of pillarbox
or scaling.

``--self-test`` renders the clean, ragged and black cases synthetically and
asserts the grader separates them, so the red for this gate does not depend on
hardware being broken at the time it runs.
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

# Luma above this counts as picture rather than pillarbox/blanking. The idle
# logo's dark field is Y=0x2d at the source; MJPEG rounds it down but never
# near zero.
DEFAULT_LUMA_THRESHOLD = 16
# A row must be this fraction non-black to be considered part of the picture,
# so letterbox rows above and below the frame do not pollute the statistics.
DEFAULT_ROW_COVERAGE = 0.30
# Measured on an undamaged capture the per-row left edge is constant to within a
# pixel or two of MJPEG ringing. The observed defect spreads it over ~190px.
DEFAULT_MAX_SPREAD = 8

SCOPE = (
    "Scope: grades ONE captured idle frame (and optionally a second, for "
    "frame-to-frame instability) on whether every picture row starts at the same "
    "column. It detects a black or contentless frame, and detects scanlines that "
    "lose a ragged leading run of pixels. It does NOT identify which image is "
    "shown, does not verify colours, does not prove the source of the damage "
    "(FPGA underrun vs ARM overwrite), and does not capture anything itself."
)


def luma(path: Path) -> np.ndarray:
    with Image.open(path) as im:
        return np.asarray(im.convert("L"), dtype=np.int16)


def grade(
    frame: np.ndarray,
    threshold: int,
    row_coverage: float,
    max_spread: int,
) -> dict:
    height, width = frame.shape
    nonblack = frame > threshold
    coverage = nonblack.mean(axis=1)
    picture_rows = np.flatnonzero(coverage >= row_coverage)

    result: dict = {
        "height": int(height),
        "width": int(width),
        "mean": round(float(frame.mean()), 2),
        "nonblack_fraction": round(float(nonblack.mean()), 4),
        "picture_rows": int(picture_rows.size),
    }

    if picture_rows.size < height * 0.05:
        result["verdict"] = "NO_CONTENT"
        result["reason"] = (
            f"only {picture_rows.size} of {height} rows are >={row_coverage:.0%} "
            f"non-black; nothing is being presented"
        )
        return result

    # First non-black column for each picture row.
    rows = nonblack[picture_rows]
    left = np.argmax(rows, axis=1).astype(np.int32)

    p5, p50, p95 = (int(v) for v in np.percentile(left, [5, 50, 95]))
    spread = p95 - p5
    result.update(
        {
            "left_edge_p5": p5,
            "left_edge_median": p50,
            "left_edge_p95": p95,
            "left_edge_min": int(left.min()),
            "left_edge_max": int(left.max()),
            "left_edge_spread": int(spread),
            "max_spread": int(max_spread),
        }
    )
    if spread > max_spread:
        result["verdict"] = "RAGGED_LEFT"
        result["reason"] = (
            f"picture rows start between x={p5} and x={p95} (spread {spread} > "
            f"{max_spread}); each scanline is losing a different leading run"
        )
        return result
    result["verdict"] = "CLEAN"
    result["reason"] = f"every picture row starts within {spread}px of x={p50}"
    return result


def instability(a: np.ndarray, b: np.ndarray, threshold: int, region_x: int) -> dict:
    if a.shape != b.shape:
        return {"comparable": False}
    region = slice(0, max(region_x, 1))
    diff = np.abs(a[:, region].astype(np.int32) - b[:, region].astype(np.int32))
    changed = float((diff > threshold).mean())
    return {
        "comparable": True,
        "left_region_px": int(max(region_x, 1)),
        "left_changed_fraction": round(changed, 4),
    }


def synthetic(case: str, width: int = 1280, height: int = 720) -> np.ndarray:
    """Render the three states the grader must keep apart."""
    frame = np.zeros((height, width), dtype=np.int16)
    if case == "black":
        return frame
    top, bottom = 40, height - 40
    left, right = 22, width - 24
    # Dark field plus a bright blob, i.e. the shape of the idle logo screen.
    frame[top:bottom, left:right] = 0x2D
    frame[height // 2 - 60 : height // 2 + 60, width // 2 - 60 : width // 2 + 60] = 0xA0
    if case == "clean":
        return frame
    if case == "ragged":
        rng = np.random.default_rng(20260728)
        for y in range(top, bottom):
            eaten = int(rng.integers(0, 190))
            frame[y, left : left + eaten] = 0
        return frame
    raise ValueError(f"unknown synthetic case {case!r}")


def run_self_test(args: argparse.Namespace) -> int:
    failures = []
    cases = {
        "clean": "CLEAN",
        "ragged": "RAGGED_LEFT",
        "black": "NO_CONTENT",
    }
    for case, expected in cases.items():
        got = grade(
            synthetic(case), args.threshold, args.row_coverage, args.max_spread
        )
        verdict = got["verdict"]
        status = "OK" if verdict == expected else "FAIL"
        if verdict != expected:
            failures.append(f"{case}: expected {expected}, got {verdict}")
        print(f"{status} synthetic/{case}: verdict={verdict} {got.get('reason','')}")

    # A grader that calls everything ragged is as useless as one that calls
    # everything clean; require the clean case to be comfortably inside budget.
    clean = grade(synthetic("clean"), args.threshold, args.row_coverage, args.max_spread)
    if clean.get("left_edge_spread", 999) != 0:
        failures.append(f"clean case spread {clean.get('left_edge_spread')} != 0")
        print(f"FAIL synthetic/clean spread={clean.get('left_edge_spread')} (want 0)")
    else:
        print("OK synthetic/clean has zero left-edge spread")

    inst = instability(synthetic("ragged"), synthetic("clean"), args.threshold, 400)
    if inst.get("left_changed_fraction", 0) <= 0.01:
        failures.append("instability metric did not see ragged vs clean differ")
        print(f"FAIL instability ragged-vs-clean {inst}")
    else:
        print(f"OK instability separates ragged from clean {inst}")

    same = instability(synthetic("clean"), synthetic("clean"), args.threshold, 400)
    if same.get("left_changed_fraction", 1) != 0.0:
        failures.append("identical frames reported as unstable")
        print(f"FAIL instability clean-vs-clean {same}")
    else:
        print("OK identical frames report zero instability")

    if failures:
        print("IDLE_INTEGRITY_RESULT=FAIL " + "; ".join(failures))
        return RC_FAIL
    print("IDLE_INTEGRITY_RESULT=SELFTEST_PASS")
    return 0


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--input", help="captured frame (PNG/JPEG)")
    ap.add_argument("--previous", help="earlier capture, for instability")
    ap.add_argument("--threshold", type=int, default=DEFAULT_LUMA_THRESHOLD)
    ap.add_argument("--row-coverage", type=float, default=DEFAULT_ROW_COVERAGE)
    ap.add_argument("--max-spread", type=int, default=DEFAULT_MAX_SPREAD)
    ap.add_argument("--expect", choices=["clean", "any"], default="clean")
    ap.add_argument("--json", help="write the full grade here")
    ap.add_argument("--self-test", action="store_true")
    ap.add_argument(
        "--emit-synthetic",
        choices=["clean", "ragged", "black"],
        help="render a synthetic case to --emit-path (fixtures for gate red-checks)",
    )
    ap.add_argument("--emit-path")
    args = ap.parse_args(argv)

    print(SCOPE)
    if args.emit_synthetic:
        if not args.emit_path:
            print("IDLE_INTEGRITY_RESULT=UNSCORED reason=no-emit-path")
            return RC_UNSCORED
        out = Path(args.emit_path)
        out.parent.mkdir(parents=True, exist_ok=True)
        Image.fromarray(synthetic(args.emit_synthetic).astype(np.uint8), mode="L").convert(
            "RGB"
        ).save(out)
        print(f"IDLE_INTEGRITY_RESULT=EMITTED case={args.emit_synthetic} path={out}")
        return 0
    if args.self_test:
        return run_self_test(args)

    if not args.input:
        print("IDLE_INTEGRITY_RESULT=UNSCORED reason=no-input (pass --input or --self-test)")
        return RC_UNSCORED
    path = Path(args.input)
    if not path.is_file():
        print(f"IDLE_INTEGRITY_RESULT=UNSCORED reason=missing-input path={path}")
        return RC_UNSCORED

    frame = luma(path)
    result = grade(frame, args.threshold, args.row_coverage, args.max_spread)
    result["input"] = str(path)

    if args.previous and Path(args.previous).is_file():
        prev = luma(Path(args.previous))
        edge = result.get("left_edge_p95", 0) + 8
        result["instability"] = instability(prev, frame, args.threshold, edge)
        result["previous"] = args.previous

    if args.json:
        out = Path(args.json)
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    summary = " ".join(
        f"{k}={result[k]}"
        for k in (
            "verdict",
            "mean",
            "nonblack_fraction",
            "picture_rows",
            "left_edge_p5",
            "left_edge_median",
            "left_edge_p95",
            "left_edge_spread",
        )
        if k in result
    )
    print(f"IDLE_INTEGRITY {summary}")
    if "instability" in result and result["instability"].get("comparable"):
        print(f"IDLE_INTEGRITY instability={result['instability']}")
    print(f"IDLE_INTEGRITY reason: {result.get('reason','')}")

    if args.expect == "any":
        print(f"IDLE_INTEGRITY_RESULT=OBSERVED verdict={result['verdict']}")
        return 0
    if result["verdict"] == "CLEAN":
        print("IDLE_INTEGRITY_RESULT=PASS")
        return 0
    print(f"IDLE_INTEGRITY_RESULT=FAIL verdict={result['verdict']}")
    return RC_FAIL


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
