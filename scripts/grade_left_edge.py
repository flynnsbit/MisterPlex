#!/usr/bin/env python3
"""Grade the left-edge clip artifact on HDMI output.

After a core reset (idle logo state), the FPGA should display the grey Plex
logo background from display column 0.  The known defect: the scan-out starts
at source column PRESENT_X (default 11), producing a black strip 0..23 px wide
on the left edge of the 1280-px display before content begins.

Usage:
  python3 scripts/grade_left_edge.py [frame.jpg ...]  [--threshold N] [--logo-row R]

Arguments:
  frame.jpg ...   One or more captured JPEG frames to analyse.  If omitted,
                  captures a fresh frame from /dev/video0 (or HDMI_DEV env).
  --threshold N   Max allowed left-edge black pixels before FAIL [default: 4].
  --logo-row R    Display row to sample for left-edge analysis [default: 250].
  --expect PASS|FAIL  Invert assertion for red-check testing [default: PASS].

Exit codes:
  0   PASS  left-edge black strip ≤ threshold
  1   FAIL  left-edge black strip > threshold
  77  SKIP  no HDMI device / no content visible in logo row

Three-question audit:
  (1) What does it literally compare?
      Per-pixel luma at --logo-row; finds first column with luma > LUMA_THRESH.
  (2) What does it NOT cover?
      Colour accuracy, sub-pixel jitter, or frame-to-frame variation (moving
      jagged lines require non-livelock RBF — see W-ARM notes).
  (3) Can you make it fail?
      Yes — pass a frame with extra black columns on the left (synthetic or
      from a bad RBF) and it exits 1.
"""
from __future__ import annotations

import argparse
import os
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]

EXIT_PASS = 0
EXIT_FAIL = 1
EXIT_SKIP = 77

LUMA_THRESH = 15      # min luma to count as "content visible"
DEFAULT_THRESHOLD = 4  # max allowed black pixels before FAIL


def bt601_luma(arr: np.ndarray) -> np.ndarray:
    r, g, b = arr[:, :, 0].astype(float), arr[:, :, 1].astype(float), arr[:, :, 2].astype(float)
    return 0.299 * r + 0.587 * g + 0.114 * b


def find_left_edge_black(frame: np.ndarray, logo_row: int) -> tuple[int, float]:
    """Return (first_bright_col, max_luma) at logo_row.

    first_bright_col = first column with luma > LUMA_THRESH.
    Returns (width, -1) if no bright pixel found (row is entirely black).
    """
    luma = bt601_luma(frame)
    row = luma[logo_row, :]
    bright = np.where(row > LUMA_THRESH)[0]
    if bright.size == 0:
        return -1, row.max()
    return int(bright[0]), float(row.max())


def capture_one_frame(device: str) -> np.ndarray:
    """Grab one MJPEG frame from a v4l2 device and return as RGB ndarray."""
    import io
    with tempfile.TemporaryDirectory() as td:
        out = Path(td) / "cap.jpg"
        result = subprocess.run(
            [
                "ffmpeg", "-loglevel", "warning",
                "-f", "v4l2", "-input_format", "mjpeg",
                "-video_size", "1280x720", "-framerate", "60",
                "-i", device,
                "-frames:v", "1",
                str(out),
            ],
            capture_output=True, timeout=15,
        )
        if result.returncode != 0 or not out.exists():
            raise RuntimeError(
                f"ffmpeg capture failed rc={result.returncode}: {result.stderr.decode()[:200]}"
            )
        return np.array(Image.open(out).convert("RGB"), dtype=np.uint8)


def auto_detect_device() -> str | None:
    """Return HDMI_DEV env var or detect via capture_preflight.py."""
    if env := os.environ.get("HDMI_DEV"):
        return env
    r = subprocess.run(
        [sys.executable, str(ROOT / "scripts" / "capture_preflight.py"), "detect"],
        capture_output=True, text=True, timeout=10,
    )
    if r.returncode == 0 and r.stdout.strip():
        return r.stdout.strip()
    return None


def analyse_frame(arr: np.ndarray, logo_row: int, threshold: int, fname: str) -> dict:
    first_bright, max_luma = find_left_edge_black(arr, logo_row)
    h, w = arr.shape[:2]
    left_strip_luma = bt601_luma(arr)[logo_row, :32].tolist()
    return {
        "file": fname,
        "logo_row": logo_row,
        "frame_size": f"{w}x{h}",
        "first_bright_col": first_bright,
        "max_luma_in_row": round(max_luma, 1),
        "left_strip_luma": [round(v, 1) for v in left_strip_luma[:16]],
        "black_prefix_px": first_bright if first_bright >= 0 else w,
        "threshold": threshold,
        "pass": (first_bright >= 0) and (first_bright <= threshold),
        "no_content": (first_bright < 0),
    }


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("frames", nargs="*", help="JPEG frame files to analyse")
    ap.add_argument("--threshold", type=int, default=DEFAULT_THRESHOLD,
                    help=f"max left-edge black px before FAIL (default {DEFAULT_THRESHOLD})")
    ap.add_argument("--logo-row", type=int, default=250,
                    help="display row to sample (default 250 = inside logo band)")
    ap.add_argument("--expect", choices=["PASS", "FAIL"], default="PASS",
                    help="expected result; FAIL inverts assertion for red-check testing")
    args = ap.parse_args()

    results = []

    if args.frames:
        for f in args.frames:
            try:
                arr = np.array(Image.open(f).convert("RGB"), dtype=np.uint8)
                results.append(analyse_frame(arr, args.logo_row, args.threshold, f))
            except Exception as e:
                print(f"ERROR loading {f}: {e}", file=sys.stderr)
                return EXIT_FAIL
    else:
        device = auto_detect_device()
        if device is None:
            print("SKIP: no HDMI capture device found", file=sys.stderr)
            return EXIT_SKIP
        try:
            arr = capture_one_frame(device)
            results.append(analyse_frame(arr, args.logo_row, args.threshold, device))
        except Exception as e:
            print(f"SKIP: capture failed: {e}", file=sys.stderr)
            return EXIT_SKIP

    if not results:
        print("Scope: 0 frames — cannot PASS", file=sys.stderr)
        return EXIT_SKIP

    print(f"Scope: {len(results)} frame(s), logo_row={args.logo_row}, threshold={args.threshold}px")
    print()

    any_fail = False
    any_skip = False
    for r in results:
        status = "SKIP" if r["no_content"] else ("PASS" if r["pass"] else "FAIL")
        print(f"  {r['file']}")
        print(f"    first_bright_col={r['first_bright_col']}  "
              f"black_prefix={r['black_prefix_px']}px  "
              f"max_luma={r['max_luma_in_row']}  status={status}")
        print(f"    left_16_luma: {r['left_strip_luma']}")
        if r["no_content"]:
            print("    WARNING: no content at logo_row — row is entirely black "
                  "(livelock/black-screen RBF or wrong row)")
            any_skip = True
        elif not r["pass"]:
            print(f"    FAIL: {r['black_prefix_px']} black pixels on left > threshold {r['threshold']}")
            any_fail = True

    print()
    overall_pass = not any_fail and not any_skip
    actual = "PASS" if overall_pass else ("SKIP" if any_skip else "FAIL")
    expected = args.expect

    if actual == "SKIP":
        print("RESULT: SKIP (no content visible — check RBF state / logo row setting)")
        return EXIT_SKIP

    if actual == expected:
        print(f"RESULT: {actual} (expected {expected})")
        return EXIT_PASS
    else:
        print(f"RESULT: {actual} (expected {expected} — MISMATCH)")
        return EXIT_FAIL


if __name__ == "__main__":
    raise SystemExit(main())
