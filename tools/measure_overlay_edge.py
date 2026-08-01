#!/usr/bin/env python3
"""Overlay/idle edge-position lattice pitch (DE-raster criterion).

Supersedes the earlier "10-90% luma transition <=2 HDMI px" idea. That metric
rewards nearest-neighbour blockiness and punishes antialiased high-res type —
anti-correlated with legibility (parent supersede brief, w-osd-hires).

This tool measures **where** strong edges sit and histograms the gaps between
those positions. Content authored at 1/k of the raster puts edges on a k-pitch
lattice (the ~3–4 row pitch seen after 240-line DE + ascal is that signal).

Primary asserts
---------------
1. **Coarse gap mode (k>=2 only):** among inter-edge gaps of size >=2, the mode
   must not be in {3,4,5,6} with share >= 0.40. Gap=1 is ignored because soft
   ramps and single-pixel features produce it; the parent archive’s secondary
   peak at 3–4 is the lattice signal.
2. **Diagonal stair-step runs:** on a bright-region left silhouette with enough
   unique X samples, the share of runs with length >=3 must be < 0.28.
   Nearest-neighbour upscale of diagonals yields long flat runs (parent: peak
   at 4 rows).
3. **Legibility floor:** median stroke/cap runs must clear minima when enough
   runs are observed (blocks hairline “pass”).

Analysis raster
---------------
- Score **DE-native** buffers (529x240 or coded canvas) directly.
- Score **HDMI captures** at capture resolution (do **not** nearest-downsample
  1080→DE first — that destroys the lattice signature while leaving soft edges).
- Optional ``--de-resample WxH`` remains for experiments only.

Usage:
  tools/measure_overlay_edge.py CAPTURE.png [--json]
  tools/measure_overlay_edge.py --selftest

Exit: 0 PASS, 1 FAIL criterion, 2 bad input. Always prints ``true rc=N``.
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


def luma(im: Image.Image) -> Image.Image:
    return im.convert("L")


def bright_crop(im: Image.Image, thr: int = 90) -> tuple[int, int, int, int]:
    w, h = im.size
    px = im.load()
    xs: list[int] = []
    ys: list[int] = []
    for y in range(0, h, 2):
        for x in range(0, w, 2):
            if px[x, y] > thr:
                xs.append(x)
                ys.append(y)
    if len(xs) < 40:
        return w // 8, h // 8, 7 * w // 8, 7 * h // 8
    return (
        max(0, min(xs) - 4),
        max(0, min(ys) - 4),
        min(w - 1, max(xs) + 4),
        min(h - 1, max(ys) + 4),
    )


def edge_positions_1d(samples: list[int], min_grad: int = 28) -> list[int]:
    out: list[int] = []
    for i in range(1, len(samples)):
        if abs(samples[i] - samples[i - 1]) >= min_grad:
            out.append(i)
    return out


def gap_hist(positions: list[int], max_gap: int = 16) -> dict[int, int]:
    gaps: list[int] = []
    for a, b in zip(positions, positions[1:]):
        g = b - a
        if 1 <= g <= max_gap:
            gaps.append(g)
    return dict(Counter(gaps))


def coarse_mode(hist: dict[int, int]) -> tuple[int | None, float, int]:
    """Mode among gaps >=2. Returns (mode, share_of_ge2, n_ge2)."""
    h2 = {k: v for k, v in hist.items() if k >= 2}
    n = sum(h2.values())
    if n < 16:
        return None, 0.0, n
    mode, cnt = max(h2.items(), key=lambda kv: kv[1])
    return mode, cnt / n, n


def diagonal_stair(im: Image.Image, thr: int = 100) -> tuple[dict[int, int], int, float]:
    """Left-silhouette run lengths in the bright crop.

    Returns (run_hist, n_unique_x, share_runs_ge_3).
    """
    x0, y0, x1, y1 = bright_crop(im, thr=max(70, thr - 20))
    px = im.load()
    xs: list[int | None] = []
    for y in range(y0, y1 + 1):
        fx: int | None = None
        for x in range(x0, x1 + 1):
            if px[x, y] > thr:
                fx = x
                break
        xs.append(fx)
    uniq = len({x for x in xs if x is not None})
    runs: list[int] = []
    i = 0
    while i < len(xs):
        if xs[i] is None:
            i += 1
            continue
        j = i
        while j < len(xs) and xs[j] == xs[i]:
            j += 1
        runs.append(j - i)
        i = j
    hist = dict(Counter(runs))
    tot = sum(hist.values()) or 1
    share3 = sum(c for k, c in hist.items() if k >= 3) / tot
    return hist, uniq, share3


def stroke_stats(im: Image.Image) -> dict:
    w, h = im.size
    px = im.load()
    runs_h: list[int] = []
    for y in range(h // 5, 4 * h // 5, 2):
        run = 0
        for x in range(w):
            if px[x, y] > 140:
                run += 1
            else:
                if 2 <= run <= 40:
                    runs_h.append(run)
                run = 0
    runs_v: list[int] = []
    for x in range(w // 5, 4 * w // 5, 2):
        run = 0
        for y in range(h):
            if px[x, y] > 140:
                run += 1
            else:
                if 2 <= run <= 80:
                    runs_v.append(run)
                run = 0

    def med(xs: list[int]) -> int:
        if not xs:
            return 0
        xs = sorted(xs)
        return xs[len(xs) // 2]

    return {
        "stroke_width_med": med(runs_h),
        "cap_height_med": med(runs_v),
        "n_h_runs": len(runs_h),
        "n_v_runs": len(runs_v),
    }


def score_image(
    im: Image.Image,
    max_coarse_pitch: int = 2,
    min_stroke: int = 2,
    min_cap: int = 6,
    min_coarse_share: float = 0.40,
    max_stair_share3: float = 0.28,
    min_stair_unique_x: int = 8,
) -> dict:
    """Score one luma image. max_coarse_pitch: modes > this in {3..6} fail."""
    w, h = im.size
    lo, hi = im.getextrema()
    if lo == hi:
        return {"usable": False, "reason": "uniform", "pass": False, "size": [w, h]}

    x0, y0, x1, y1 = bright_crop(im)
    px = im.load()

    v_gaps: Counter[int] = Counter()
    for x in range(x0, x1 + 1, 2):
        col = [px[x, y] for y in range(y0, y1 + 1)]
        pos = edge_positions_1d(col)
        for g, c in gap_hist(pos).items():
            v_gaps[g] += c
    h_gaps: Counter[int] = Counter()
    for y in range(y0, y1 + 1, 2):
        row = [px[x, y] for x in range(x0, x1 + 1)]
        pos = edge_positions_1d(row)
        for g, c in gap_hist(pos).items():
            h_gaps[g] += c

    v_hist = dict(v_gaps)
    h_hist = dict(h_gaps)
    v_mode, v_share, v_n = coarse_mode(v_hist)
    h_mode, h_share, h_n = coarse_mode(h_hist)

    def is_coarse(mode: int | None, share: float) -> bool:
        if mode is None:
            return False
        # Upscale lattice pitches cluster in 3..6. Mode 2 is often even/odd
        # sampling; mode >=7 is usually feature spacing (glyph height, etc.).
        return max_coarse_pitch < mode <= 6 and share >= min_coarse_share

    v_coarse = is_coarse(v_mode, v_share)
    h_coarse = is_coarse(h_mode, h_share)

    stair_hist, stair_uniq, stair_share3 = diagonal_stair(im)
    stair_coarse = stair_uniq >= min_stair_unique_x and stair_share3 >= max_stair_share3

    leg = stroke_stats(im)
    leg_ok = True
    if leg["n_v_runs"] >= 8:
        leg_ok = leg_ok and leg["cap_height_med"] >= min_cap
    if leg["n_h_runs"] >= 8:
        leg_ok = leg_ok and leg["stroke_width_med"] >= min_stroke
    if leg["n_h_runs"] < 8 and leg["n_v_runs"] < 8:
        leg_ok = True

    pitch_ok = not v_coarse and not h_coarse and not stair_coarse
    ok = pitch_ok and leg_ok

    return {
        "usable": True,
        "size": [w, h],
        "crop": [x0, y0, x1, y1],
        "v_pitch_hist": {str(k): v for k, v in sorted(v_hist.items())},
        "h_pitch_hist": {str(k): v for k, v in sorted(h_hist.items())},
        "v_pitch_mode_ge2": v_mode,
        "h_pitch_mode_ge2": h_mode,
        "v_pitch_share_ge2": round(v_share, 3),
        "h_pitch_share_ge2": round(h_share, 3),
        "v_n_ge2": v_n,
        "h_n_ge2": h_n,
        "v_coarse": v_coarse,
        "h_coarse": h_coarse,
        "stair_hist": {str(k): v for k, v in sorted(stair_hist.items())},
        "stair_unique_x": stair_uniq,
        "stair_share_ge3": round(stair_share3, 3),
        "stair_coarse": stair_coarse,
        "pitch_ok": pitch_ok,
        "legibility": leg,
        "legibility_ok": leg_ok,
        "max_coarse_pitch": max_coarse_pitch,
        "pass": ok,
    }


def load_and_maybe_resample(path: Path, de: str | None) -> Image.Image:
    im = Image.open(path).convert("RGB")
    if not de:
        return luma(im)
    wh = de.lower().split("x")
    if len(wh) != 2:
        raise ValueError(f"bad --de-resample {de}")
    dw, dh = int(wh[0]), int(wh[1])
    small = im.resize((dw, dh), Image.NEAREST)
    return luma(small)


def _blit_glyph(im: Image.Image, x: int, y: int, rows: list[str], val: int = 235) -> None:
    for dy, row in enumerate(rows):
        for dx, ch in enumerate(row):
            if ch == "1":
                xx, yy = x + dx, y + dy
                if 0 <= xx < im.size[0] and 0 <= yy < im.size[1]:
                    im.putpixel((xx, yy), val)


# Compact 8x13-ish patterns for selftest (scale=1).
_GLYPH_A = [
    "00111100",
    "01100110",
    "11000011",
    "11000011",
    "11000011",
    "11111111",
    "11000011",
    "11000011",
    "11000011",
    "11000011",
    "11000011",
    "11000011",
    "11000011",
]
_GLYPH_0 = [
    "01111110",
    "11000011",
    "11000011",
    "11000011",
    "11000011",
    "11000011",
    "11000011",
    "11000011",
    "11000011",
    "11000011",
    "11000011",
    "11000011",
    "01111110",
]


def render_native_de(path: Path, w: int = 529, h: int = 240) -> None:
    """DE-native chrome: 1px font strokes + true 1-row diagonal stairs."""
    im = Image.new("L", (w, h), 0x22)
    d = ImageDraw.Draw(im)
    # Chevron / triangle with pitch-1 stairs (45°).
    for y in range(28, 150):
        half = y - 28
        x0 = 360 - half // 2
        x1 = 360 + half // 2
        for x in range(x0, x1):
            if 0 <= x < w:
                im.putpixel((x, y), 175)
    # Transport-like panel with scale=1 glyphs.
    d.rectangle([10, 175, w - 10, 228], fill=12, outline=70)
    for i, g in enumerate([_GLYPH_0, _GLYPH_A, _GLYPH_0, _GLYPH_A, _GLYPH_0, _GLYPH_A]):
        _blit_glyph(im, 24 + i * 20, 185, g)
    d.rectangle([24, 215, w - 24, 221], fill=55)
    d.rectangle([24, 215, w // 2, 221], fill=230)
    im.save(path)


def render_blocky_de(path: Path, w: int = 529, h: int = 240) -> None:
    """Native DE scene nearest-down then up — coarse lattice (scale ~4)."""
    tmp = path.with_suffix(".src.png")
    render_native_de(tmp, w, h)
    im = Image.open(tmp).resize((max(32, w // 4), max(16, h // 4)), Image.NEAREST)
    im = im.resize((w, h), Image.NEAREST)
    im.save(path)
    tmp.unlink(missing_ok=True)


def selftest(tmp: Path) -> int:
    tmp.mkdir(parents=True, exist_ok=True)
    native = tmp / "de_native_529x240.png"
    blocky = tmp / "blocky_scale_to_de.png"
    render_native_de(native)
    render_blocky_de(blocky)

    r_n = score_image(luma(Image.open(native)))
    r_b = score_image(luma(Image.open(blocky)))
    print("SELFTEST native_DE:", json.dumps(r_n, indent=2))
    print("SELFTEST blocky_DE:", json.dumps(r_b, indent=2))
    if not r_n.get("pass"):
        print("SELFTEST FAIL: native DE chrome should PASS lattice criterion")
        return 2
    if r_b.get("pass"):
        print("SELFTEST FAIL: blocky upscale should FAIL lattice criterion")
        return 2
    print("SELFTEST PASS: native GREEN, blocky RED")
    return 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("frames", nargs="*")
    ap.add_argument(
        "--de-resample",
        default=None,
        help="optional nearest downsample (experimental; can erase HDMI lattice)",
    )
    ap.add_argument("--max-coarse-pitch", type=int, default=2,
                    help="modes in (max_coarse_pitch, 6] fail when dominant")
    ap.add_argument("--min-stroke", type=int, default=2)
    ap.add_argument("--min-cap", type=int, default=6)
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--selftest-dir", type=Path, default=Path("build/osd-hires-fixtures"))
    args = ap.parse_args(argv)

    if args.selftest:
        rc = selftest(args.selftest_dir)
        print(f"true rc={rc}")
        return rc

    if not args.frames:
        print("ERROR: CAPTURE.png or --selftest", file=sys.stderr)
        print("true rc=2")
        return 2

    results = []
    overall = True
    usable = False
    for f in args.frames:
        try:
            im = load_and_maybe_resample(Path(f), args.de_resample)
        except Exception as e:
            results.append({"path": f, "usable": False, "reason": str(e), "pass": False})
            overall = False
            continue
        r = score_image(
            im,
            max_coarse_pitch=args.max_coarse_pitch,
            min_stroke=args.min_stroke,
            min_cap=args.min_cap,
        )
        r["path"] = f
        r["de_resample"] = args.de_resample
        results.append(r)
        if r.get("usable"):
            usable = True
            if not r.get("pass"):
                overall = False
        else:
            overall = False

    if args.json:
        print(json.dumps(results if len(results) > 1 else results[0], indent=2))
    else:
        for r in results:
            if not r.get("usable"):
                print(f"frame={r['path']} USABLE=no reason={r.get('reason')}")
                continue
            print(
                f"frame={r['path']} size={r['size'][0]}x{r['size'][1]} "
                f"de_resample={r.get('de_resample')} "
                f"v_mode_ge2={r['v_pitch_mode_ge2']} h_mode_ge2={r['h_pitch_mode_ge2']} "
                f"stair_share3={r['stair_share_ge3']} "
                f"pitch_ok={r['pitch_ok']} leg_ok={r['legibility_ok']} "
                f"stroke_med={r['legibility']['stroke_width_med']} "
                f"cap_med={r['legibility']['cap_height_med']}"
            )
            print(f"  v_hist={r['v_pitch_hist']}")
            print(f"  h_hist={r['h_pitch_hist']}")
            print(f"  stair_hist={r['stair_hist']} uniq_x={r['stair_unique_x']}")
            print(f"  VERDICT={'PASS' if r['pass'] else 'FAIL'}")

    rc = 2 if not usable else (0 if overall else 1)
    print(f"true rc={rc}")
    return rc


if __name__ == "__main__":
    sys.exit(main())
