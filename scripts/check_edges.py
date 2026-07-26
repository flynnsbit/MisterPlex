#!/usr/bin/env python3
"""Capture the MiSTer HDMI output and grade the luma edge-marker frame.

Companion to gen_edge_markers.py. Assumes the marker frame is already on screen.
Captures the grabber in uncompressed YUYV -- MJPEG's chroma subsampling and block
artifacts destroy the 1-pixel edge detail we are measuring -- and reports, for
each axis, where the first and last source column/row actually landed.

The core upscales 320 store columns across 529 display pixels, so a correctly
displayed edge column occupies 1-2 display pixels (roughly 4-7 pixels of a 1920
wide capture). A markedly wider run means that column is being repeated, which is
exactly the "bar" symptom on the right/bottom edge.

Exit code 0 = all four edges correct.
"""
import subprocess
import sys

import numpy as np
from PIL import Image

DEV = "/dev/video4"
CAP = "/tmp/edge_cap.png"
WARMUP = 60

MAX_EDGE_PX = 9  # widest a single source column may legitimately appear


def capture(path=CAP):
    subprocess.run(
        ["ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "v4l2",
         "-input_format", "yuyv422", "-video_size", "1920x1080", "-i", DEV,
         "-vf", f"select=gte(n\\,{WARMUP})", "-frames:v", "1", "-y", path],
        check=True,
    )
    return np.array(Image.open(path).convert("RGB")).astype(int)


def find_runs(line, lo, hi, min_len=2):
    """Return [(start, end)] runs of samples inside [lo, hi]."""
    out, start = [], None
    for i, v in enumerate(line):
        if lo <= v <= hi:
            if start is None:
                start = i
        elif start is not None:
            if i - start >= min_len:
                out.append((start, i - 1))
            start = None
    if start is not None and len(line) - start >= min_len:
        out.append((start, len(line) - 1))
    return out


def grade(line, axis):
    n = len(line)
    # The grabber applies limited-range expansion plus some gamma, so match on
    # broad bands rather than exact values: white is simply "very bright", and the
    # grey marker sits well above the near-black body.
    # Vertical scaling (240 -> 1080) interpolates hard enough that the top row can
    # survive as a single bright sample, so a 1-sample white run is a real hit. Only
    # column/row 0 is this bright, and we sample away from the reference bar band.
    whites = find_runs(line, 200, 300, min_len=1)
    greys = find_runs(line, 100, 175, min_len=2)
    problems, info = [], []

    if not whites:
        problems.append(f"{axis} leading edge: first column/row (white) is NOT displayed")
    else:
        s, e = whites[0]
        info.append(f"first@{s}-{e} (w={e-s+1})")
        if s > 3:
            problems.append(
                f"{axis} leading edge: first column/row starts at {s}, expected 0 "
                f"-- {s} pixels of something else are shown before it")
        if e - s + 1 > MAX_EDGE_PX:
            problems.append(
                f"{axis} leading edge: first column/row is {e-s+1}px wide "
                f"(max {MAX_EDGE_PX}) -- it is being repeated")

    if not greys:
        problems.append(f"{axis} trailing edge: last column/row (grey) is NOT displayed")
    else:
        s, e = greys[-1]
        info.append(f"last@{s}-{e} (w={e-s+1})")
        if e < n - 4:
            problems.append(
                f"{axis} trailing edge: last column/row ends at {e}, expected {n-1} "
                f"-- {n-1-e} pixels of something else are shown after it")
        if e - s + 1 > MAX_EDGE_PX:
            problems.append(
                f"{axis} trailing edge: last column/row is {e-s+1}px wide "
                f"(max {MAX_EDGE_PX}) -- it is repeated (this is the edge bar)")

    if whites and greys and greys[0][0] < whites[0][0]:
        problems.append(
            f"{axis} WRAP: the last column/row appears at {greys[0][0]}, before the first")

    return info, problems


def main():
    im = capture()
    h, w, _ = im.shape
    lum = im.mean(axis=2)
    print(f"capture {w}x{h}")

    allprob = []
    vx = int(w * 200 / 320)  # away from the reference bar band
    for axis, line in (("H", lum[h // 2, :]), ("V", lum[:, vx])):
        info, problems = grade(line, axis)
        print(f"{axis}: " + "  ".join(info))
        allprob += problems

    if allprob:
        print("\nFAIL")
        for p in allprob:
            print("  -", p)
        return 1
    print("\nPASS: all four edges correct")
    return 0


if __name__ == "__main__":
    sys.exit(main())
