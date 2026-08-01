#!/usr/bin/env python3
"""T4 — single-frame falsifier: period-P lattice in video ROI vs overlay ROI.

Parent method: mean |row[y+1]-row[y]|, bin by phase mod P,
contrast = max_phase / min_phase. On 1280x720 from 240 src lines, P=3 is
fundamental (720/240=3). On 1920x1080 grab of 1920x1440, vertical squash
gives 1080/240=4.5 -> strong P=4/5 as well; we report P=3 and best P.

PASS (post-ascal chrome plane live):
  - video ROI: period structure PRESENT (contrast_p3 or best >= VIDEO_MIN)
  - overlay ROI: period structure ABSENT (contrast <= OVERLAY_MAX AND ratio <= RATIO_MAX)

FAIL (today / ARM paint into F1): overlay lattice comparable to video.

SELFTEST:
  RED: synth P=3-everywhere + device archives must not plane_pass
  GREEN: synth period-3 video + sharp bottom chrome must plane_pass

Usage:
  python3 tools/score_overlay_vs_video_period3.py CAPTURE.png; echo "true rc=$?"
  python3 tools/score_overlay_vs_video_period3.py --selftest; echo "true rc=$?"

Exit: 0 PASS, 1 FAIL, 2 bad input. Prints true rc=N.
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

try:
    from PIL import Image, ImageDraw
except ImportError:
    print("ERROR: Pillow required", file=sys.stderr)
    print("true rc=2")
    sys.exit(2)

ROOT = Path(__file__).resolve().parents[1]
ARCHIVE_PAUSED = ROOT / "files" / "device-evidence" / "osd_pause_3883f5ab_PAUSED_PASS.png"
ARCHIVE_STOPPED = ROOT / "files" / "device-evidence" / "osd_hires_0370af91_STOPPED_PASS.png"

VIDEO_MIN = 2.5
OVERLAY_MAX = 1.8
RATIO_MAX = 0.40


def luma_px(im: Image.Image):
    return im.convert("L").load(), im.convert("L").size


def phase_contrast(px, size, box, period: int) -> float:
    w, h = size
    x0, y0, x1, y1 = box
    x0, y0 = max(0, x0), max(0, y0)
    x1, y1 = min(w, x1), min(h, y1)
    if y1 - y0 < period + 2 or x1 - x0 < 8:
        return 1.0
    bins = [0.0] * period
    counts = [0] * period
    for y in range(y0, y1 - 1):
        s = 0.0
        n = 0
        for x in range(x0, x1):
            s += abs(int(px[x, y + 1]) - int(px[x, y]))
            n += 1
        d = s / n if n else 0.0
        ph = (y - y0) % period
        bins[ph] += d
        counts[ph] += 1
    means = []
    for i in range(period):
        if counts[i] == 0:
            return 1.0
        means.append(bins[i] / counts[i])
    mn, mx = min(means), max(means)
    if mn < 1e-9:
        return 99.0 if mx > 1e-6 else 1.0
    return mx / mn


def best_period(px, size, box, periods=(2, 3, 4, 5, 6)):
    best_c, best_p = 1.0, 0
    detail = {}
    for p in periods:
        c = phase_contrast(px, size, box, p)
        detail[p] = round(c, 3)
        if c > best_c:
            best_c, best_p = c, p
    return best_c, best_p, detail


def default_rois(w: int, h: int):
    v = (w // 5, h // 10, 4 * w // 5, int(h * 0.55))
    o = (w // 10, int(h * 0.70), 9 * w // 10, int(h * 0.96))
    return v, o


def score_frame(path: Path | None = None, im: Image.Image | None = None) -> dict:
    if im is None:
        im = Image.open(path)
    px, size = luma_px(im)
    w, h = size
    vbox, obox = default_rois(w, h)
    vc, vp, vdet = best_period(px, size, vbox)
    oc, op, odet = best_period(px, size, obox)
    c3v = phase_contrast(px, size, vbox, 3)
    c3o = phase_contrast(px, size, obox, 3)
    ratio = oc / vc if vc > 1e-9 else 99.0
    video_ok = vc >= VIDEO_MIN or c3v >= VIDEO_MIN
    overlay_clean = oc <= OVERLAY_MAX and (ratio <= RATIO_MAX if video_ok else oc <= 1.35)
    plane = bool(video_ok and overlay_clean)
    return {
        "size": [w, h],
        "video_box": list(vbox),
        "overlay_box": list(obox),
        "video_best_c": round(vc, 3),
        "video_best_p": vp,
        "video_p3": round(c3v, 3),
        "video_periods": vdet,
        "overlay_best_c": round(oc, 3),
        "overlay_best_p": op,
        "overlay_p3": round(c3o, 3),
        "overlay_periods": odet,
        "ratio": round(ratio, 3),
        "video_structure": video_ok,
        "overlay_clean": overlay_clean,
        "plane_pass": plane,
    }


def make_green_synthetic(w=1280, h=720) -> Image.Image:
    """Period-3 video + flat post-scale chrome band (no vertical lattice).

    Glyphs on a true plane are 1:1 output pixels; a flat plate is the cleanest
    positive control that period structure is absent in the overlay ROI.
    """
    im = Image.new("RGB", (w, h), (20, 20, 20))
    px = im.load()
    for y in range(int(h * 0.65)):
        src = y // 3
        val = 40 + (src * 17) % 180
        for x in range(w):
            px[x, y] = (val, val, (val + x) % 200)
    y0 = int(h * 0.70)  # matches default overlay ROI start
    for y in range(y0, h):
        for x in range(w):
            px[x, y] = (48, 52, 60)  # opaque panel, constant luma
    return im


def make_red_synthetic(w=1280, h=720) -> Image.Image:
    im = Image.new("RGB", (w, h))
    px = im.load()
    for y in range(h):
        src = y // 3
        val = 40 + (src * 17) % 180
        for x in range(w):
            px[x, y] = (val, val, (val + (x // 3)) % 200)
    return im


def print_score(label: str, r: dict) -> None:
    print(f"{label} size={r['size']}")
    print(
        f"  video:   p3={r['video_p3']} best_p={r['video_best_p']} "
        f"best_c={r['video_best_c']} structure={r['video_structure']} periods={r['video_periods']}"
    )
    print(
        f"  overlay: p3={r['overlay_p3']} best_p={r['overlay_best_p']} "
        f"best_c={r['overlay_best_c']} clean={r['overlay_clean']} periods={r['overlay_periods']}"
    )
    print(f"  ratio={r['ratio']} plane_pass={r['plane_pass']}")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("capture", nargs="?", type=Path)
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args()

    if args.selftest:
        fails = 0
        r = score_frame(im=make_red_synthetic())
        print_score("synth_red_p3", r)
        if r["plane_pass"]:
            print("SELFTEST_RED_FAIL: synth_red plane_pass", file=sys.stderr)
            fails += 1
        for path in (ARCHIVE_PAUSED, ARCHIVE_STOPPED):
            if not path.is_file():
                print(f"WARN skip missing {path}", file=sys.stderr)
                continue
            r = score_frame(path=path)
            print_score(path.name, r)
            if r["plane_pass"]:
                print(f"SELFTEST_RED_FAIL: {path.name} plane_pass", file=sys.stderr)
                fails += 1
        r = score_frame(im=make_green_synthetic())
        print_score("synth_green_plane", r)
        if not r["plane_pass"]:
            print("SELFTEST_GREEN_FAIL: synth plane should PASS", file=sys.stderr)
            fails += 1
        if fails:
            print(f"SELFTEST_FAIL count={fails}")
            print("true rc=1")
            return 1
        print("SELFTEST_OK: RED fail plane; GREEN synth passes")
        print("true rc=0")
        return 0

    if not args.capture or not args.capture.is_file():
        print(
            "usage: score_overlay_vs_video_period3.py CAPTURE.png|--selftest",
            file=sys.stderr,
        )
        print("true rc=2")
        return 2

    r = score_frame(path=args.capture)
    print_score(str(args.capture), r)
    print(
        f"PASS: video_structure (best_c|p3>={VIDEO_MIN}) AND "
        f"overlay_clean (best_c<={OVERLAY_MAX}, ratio<={RATIO_MAX})"
    )
    print("Parent intent: P-structure ABSENT in overlay ROI, PRESENT in video ROI.")
    rc = 0 if r["plane_pass"] else 1
    print(f"VERDICT={'PASS' if rc == 0 else 'FAIL'}")
    print(f"true rc={rc}")
    return rc


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except SystemExit:
        raise
    except Exception as e:
        print(f"ERROR {e}", file=sys.stderr)
        print("true rc=2")
        raise SystemExit(2)
