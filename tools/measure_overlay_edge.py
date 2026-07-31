#!/usr/bin/env python3
"""Measure overlay/idle edge sharpness on an HDMI (or synthetic) capture.

Parent acceptance criterion (w-osd-hires, measured on real device idle_warm.png):
  On a 1920x1080 capture of any overlay or idle artwork, the 10%%-to-90%% luma
  transition width measured perpendicular to a straight edge must be <= 2 output
  pixels (device baseline ~6). Diagonal edges may show 1-pixel stair steps but
  must not show a 3-or-4-row pitch.

This tool implements that criterion. It must go RED on the archived low-res-
upscaled idle capture and GREEN on a native-resolution render of the same art.

Usage:
  tools/measure_overlay_edge.py CAPTURE.png [--max-edge-width N] [--json]
  tools/measure_overlay_edge.py --selftest

Exit codes:
  0  PASS (edge width and pitch within limits)
  1  FAIL criterion (soft edges / coarse pitch)
  2  unusable input / tool error
Always prints a trailing ``true rc=N`` line so harnesses can capture the code
without shell pipes.
"""

from __future__ import annotations

import argparse
import json
import sys
from collections import Counter
from pathlib import Path

try:
    from PIL import Image, ImageDraw
except ImportError:
    print("ERROR: Pillow required (pip install Pillow)", file=sys.stderr)
    print("true rc=2")
    sys.exit(2)


# Parent-measured ramp on idle_warm.png (reference only; not used as threshold).
# [39, 36, 34, 44, 58, 69, 100, 139, 165, 169, 170, 171, 174] -> ~6 samples.


def luma_image(path: str | Path) -> Image.Image:
    return Image.open(path).convert("L")


def transition_width_10_90(samples: list[int]) -> int | None:
    """Return 10%-90% transition width in samples, or None if no clear step.

    Direction is chosen from the sample trend (mean of last third vs first third)
    so a falling edge is measured on the reversed series. Taking min(up, down)
    is wrong: the reverse of a rising ramp is already past y90 on sample 0 and
    spuriously reports width 1.
    """
    if len(samples) < 4:
        return None
    lo = min(samples)
    hi = max(samples)
    span = hi - lo
    if span < 40:
        return None  # not a strong edge
    y10 = lo + 0.10 * span
    y90 = lo + 0.90 * span
    n = len(samples)
    t = max(1, n // 3)
    head = sum(samples[:t]) / t
    tail = sum(samples[-t:]) / t
    seq = samples if tail >= head else list(reversed(samples))

    i10 = i90 = None
    for i, v in enumerate(seq):
        if i10 is None and v >= y10:
            i10 = i
        if i10 is not None and v >= y90:
            i90 = i
            break
    if i10 is None or i90 is None:
        return None
    return max(1, i90 - i10 + 1)


def scan_horizontal_edges(im: Image.Image, step_y: int = 2) -> list[int]:
    """Collect 10-90 widths at the steepest local edge on each scanline.

    Centers a short window on the maximum |dL/dx| so we measure one edge
    crossing (parent method) rather than the full chevron stroke thickness.
    """
    w, h = im.size
    px = im.load()
    widths: list[int] = []
    y0, y1 = max(8, h // 20), min(h - 8, h - h // 20)
    half_win = 12  # 25-sample window around the peak gradient
    for y in range(y0, y1, step_y):
        row = [int(px[x, y]) for x in range(w)]
        # Peak absolute horizontal gradient (ignore image borders).
        peak_x = None
        peak_g = 0
        for x in range(2, w - 2):
            g = abs(row[x + 1] - row[x - 1])
            if g > peak_g:
                peak_g = g
                peak_x = x
        if peak_x is None or peak_g < 30:
            continue
        x0 = max(0, peak_x - half_win)
        x1 = min(w, peak_x + half_win + 1)
        tw = transition_width_10_90(row[x0:x1])
        if tw is not None:
            widths.append(tw)
    return widths


def diagonal_stair_run_lengths(im: Image.Image, min_grad: int = 40) -> dict[int, int]:
    """Histogram of vertical stair-step run lengths on the chevron diagonal.

    For each center-crop row, record the x of the peak horizontal gradient.
    Consecutive rows that share the same edge-x form a stair tread. Upscaled
    low-res art shows long treads (mode 3-4 at 1080p from ~480p); native 1080p
    diagonals advance nearly every row (mode 1).
    """
    w, h = im.size
    px = im.load()
    x0, x1 = w // 5, 4 * w // 5
    y0, y1 = h // 5, 4 * h // 5
    edge_x: list[int | None] = []
    for y in range(y0, y1):
        peak_x = None
        peak_g = 0
        for x in range(x0 + 1, x1 - 1):
            g = abs(int(px[x + 1, y]) - int(px[x - 1, y]))
            if g > peak_g:
                peak_g = g
                peak_x = x
        edge_x.append(peak_x if peak_g >= min_grad else None)

    runs: list[int] = []
    i = 0
    n = len(edge_x)
    while i < n:
        if edge_x[i] is None:
            i += 1
            continue
        j = i + 1
        while j < n and edge_x[j] == edge_x[i]:
            j += 1
        run = j - i
        if 1 <= run <= 12:
            runs.append(run)
        i = j
    return dict(Counter(runs))


def score_frame(
    path: str | Path,
    max_edge_width: int = 2,
    forbid_pitch: tuple[int, ...] = (3, 4),
) -> dict:
    im = luma_image(path)
    w, h = im.size
    lo, hi = im.getextrema()
    if lo == hi:
        return {
            "path": str(path),
            "usable": False,
            "reason": "uniform frame",
            "pass": False,
        }

    widths = scan_horizontal_edges(im)
    pitch = diagonal_stair_run_lengths(im)
    if not widths:
        return {
            "path": str(path),
            "usable": False,
            "reason": "no strong edge found",
            "pass": False,
            "size": [w, h],
        }

    # Parent criterion: worst (max) 10-90 transition across the frame.
    worst = max(widths)
    median = sorted(widths)[len(widths) // 2]
    mean = sum(widths) / len(widths)
    # Pitch mode over all gaps; coarse if 3 or 4 is a dominant mode (>=15%).
    mode_pitch = None
    if pitch:
        mode_pitch = max(pitch.items(), key=lambda kv: kv[1])[0]
    pitch_total = sum(pitch.values()) or 1
    # Fail if mode is coarse, any single forbidden bin is >=15%, or the
    # combined 3+4 share is >=20% (parent idle_warm showed a strong 3/4 peak).
    coarse = mode_pitch in forbid_pitch
    coarse = coarse or any(
        pitch.get(p, 0) / pitch_total >= 0.15 for p in forbid_pitch
    )
    forbid_share = sum(pitch.get(p, 0) for p in forbid_pitch) / pitch_total
    coarse = coarse or forbid_share >= 0.20

    edge_ok = worst <= max_edge_width
    pitch_ok = not coarse
    ok = edge_ok and pitch_ok

    return {
        "path": str(path),
        "usable": True,
        "size": [w, h],
        "edge_width_max": worst,
        "edge_width_median": median,
        "edge_width_mean": round(mean, 2),
        "edge_samples": len(widths),
        "max_edge_width_limit": max_edge_width,
        "edge_ok": edge_ok,
        "pitch_hist": {str(k): v for k, v in sorted(pitch.items())},
        "pitch_mode": mode_pitch,
        "pitch_coarse": coarse,
        "pitch_ok": pitch_ok,
        "pass": ok,
    }


def render_native_chevron(path: Path, w: int, h: int) -> None:
    """Author the idle chevron at output resolution (hard edges)."""
    bg = (0x1F, 0x23, 0x26)
    fg = (0xE5, 0xA0, 0x0D)
    im = Image.new("RGB", (w, h), bg)
    draw = ImageDraw.Draw(im)
    size = min(w, h) // 3
    ox = (w - size) // 2
    oy = (h - size) // 2
    stroke = max(1, size // 5)
    half = size // 2
    # Two thick diagonal arms meeting at the right vertex (matches idle_screen.hpp).
    for y in range(size):
        for x in range(size):
            d = (x - y) if y <= half else (x - (size - 1 - y))
            if 0 <= d < stroke:
                im.putpixel((ox + x, oy + y), fg)
    im.save(path)


def render_upscaled_chevron(path: Path, src_w: int, src_h: int, out_w: int, out_h: int) -> None:
    """Author at src, bilinear-upscale to out — device-like soft edges."""
    tmp = path.with_suffix(".src.png")
    render_native_chevron(tmp, src_w, src_h)
    im = Image.open(tmp).convert("RGB")
    up = im.resize((out_w, out_h), Image.BILINEAR)
    up.save(path)
    tmp.unlink(missing_ok=True)


def selftest(tmp: Path) -> int:
    tmp.mkdir(parents=True, exist_ok=True)
    native = tmp / "native_1080.png"
    soft = tmp / "upscaled_640_to_1080.png"
    render_native_chevron(native, 1920, 1080)
    render_upscaled_chevron(soft, 640, 480, 1920, 1080)

    r_native = score_frame(native)
    r_soft = score_frame(soft)
    print("SELFTEST native_1080:", json.dumps(r_native, indent=2))
    print("SELFTEST upscaled_640:", json.dumps(r_soft, indent=2))

    # Native must PASS; upscaled must FAIL (criterion is discriminating).
    if not r_native.get("pass"):
        print("SELFTEST FAIL: native 1080p chevron did not PASS")
        return 2
    if r_soft.get("pass"):
        print("SELFTEST FAIL: bilinear-upscaled 640x480 unexpectedly PASSED")
        return 2
    print("SELFTEST PASS: native GREEN, upscaled RED (criterion discriminates)")
    return 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("frames", nargs="*", help="PNG captures to score")
    ap.add_argument("--max-edge-width", type=int, default=2,
                    help="max allowed 10-90 luma transition width (default 2)")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--selftest", action="store_true",
                    help="prove GREEN on native 1080p and RED on upscaled 640")
    ap.add_argument("--selftest-dir", type=Path,
                    default=Path("build/osd-hires-fixtures"),
                    help="directory for selftest PNGs")
    args = ap.parse_args(argv)

    if args.selftest:
        rc = selftest(args.selftest_dir)
        print(f"true rc={rc}")
        return rc

    if not args.frames:
        print("ERROR: provide CAPTURE.png or --selftest", file=sys.stderr)
        print("true rc=2")
        return 2

    results = []
    overall_pass = True
    any_usable = False
    for f in args.frames:
        r = score_frame(f, max_edge_width=args.max_edge_width)
        results.append(r)
        if r.get("usable"):
            any_usable = True
            if not r.get("pass"):
                overall_pass = False
        else:
            overall_pass = False

    if args.json:
        print(json.dumps(results if len(results) > 1 else results[0], indent=2))
    else:
        for r in results:
            if not r.get("usable"):
                print(f"frame={r['path']} USABLE=no reason={r.get('reason')}")
                continue
            print(
                f"frame={r['path']} size={r['size'][0]}x{r['size'][1]} "
                f"edge_max={r['edge_width_max']} edge_med={r['edge_width_median']} "
                f"limit={r['max_edge_width_limit']} edge_ok={r['edge_ok']} "
                f"pitch_mode={r['pitch_mode']} pitch_coarse={r['pitch_coarse']} "
                f"pitch_ok={r['pitch_ok']}"
            )
            print(f"  pitch_hist={r['pitch_hist']}")
            print(f"  VERDICT={'PASS' if r['pass'] else 'FAIL'}")

    if not any_usable:
        rc = 2
    else:
        rc = 0 if overall_pass else 1
    print(f"true rc={rc}")
    return rc


if __name__ == "__main__":
    sys.exit(main())
