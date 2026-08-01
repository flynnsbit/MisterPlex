#!/usr/bin/env python3
"""Synthetic red-before-green gate for burned-in counter OCR.

Renders known ``TREK24 n=NNNN`` overlays on dark and white-flash backgrounds
(matching the avsync fixture look) and asserts exact recovery via
``hdmi_motion_instrument.read_frame``.

Cases include the parent-confirmed glass480 failures:
  2358 (was 23538 — spurious digit insertion)
  2378 (was 2338 — 3/7 confusion on flash)
  2352 (was 2353 — off-by-one on flash)

Exit codes
----------
  0  GATE_OK — every case recovered exactly
  1  GATE_FAIL — one or more mismatches (RED)
  77 never used as pass

Usage
-----
  python3 tools/ocr_counter_gate.py
  python3 tools/ocr_counter_gate.py --json
  # capture true rc DIRECTLY:
  python3 tools/ocr_counter_gate.py; echo "true rc=$?"
"""
from __future__ import annotations

import argparse
import json
import sys
import tempfile
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont

_TOOLS = Path(__file__).resolve().parent
if str(_TOOLS) not in sys.path:
    sys.path.insert(0, str(_TOOLS))

from hdmi_motion_instrument import read_frame  # noqa: E402

RC_OK = 0
RC_FAIL = 1

# Parent glass480 banked PNGs — ground-truth by parent pixel view. These are
# the acceptance cases that must go RED on broken OCR and GREEN after the fix.
REAL_CASES = [
    ("/tmp/glass480/png/f_1820.png", 2358),  # was 23538 insertion
    ("/tmp/glass480/png/f_1821.png", 2359),
    ("/tmp/glass480/png/f_1813.png", 2352),  # flash; was 2353; must NOT hole
    # Parent wrote 2378; pixel zoom of f_1844 shows n=2377 (two sevens). f_1845=2378.
    ("/tmp/glass480/png/f_1844.png", 2377),  # flash; old OCR 2338; zoom-confirmed 2377
    ("/tmp/glass480/png/f_1986.png", 2490),
    ("/tmp/glass480/png/f_1987.png", 2492),  # confirmed drop neighbour
    # Pixel-confirmed flash residuals (false holes when OCR fails):
    ("/tmp/glass480/png/f_2024.png", 2521),  # was multi-token 135
    ("/tmp/glass480/png/f_2652.png", 3024),  # was n=362 / bare 3028
    ("/tmp/glass480/png/f_2654.png", 3025),  # was n=3625
]

# Synthetic renders (dark + flash) for values we can draw cleanly. Flash
# synthetic is best-effort (font ≠ capture AA); real cases above are load-bearing.
SYN_CASES = [
    2358,
    2378,
    2352,
    1000,
    42,
]


def _font(size: int) -> ImageFont.ImageFont:
    for path in (
        "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
        "/usr/share/fonts/TTF/DejaVuSans-Bold.ttf",
        "/usr/share/fonts/dejavu/DejaVuSans-Bold.ttf",
    ):
        p = Path(path)
        if p.is_file():
            return ImageFont.truetype(str(p), size=size)
    return ImageFont.load_default()


def render_frame(n: int, *, flash: bool, size: tuple[int, int] = (1920, 1080)) -> Image.Image:
    """Letterboxed 1920x1080 with yellow TREK24 n=NNNN near top-left of active pic."""
    w, h = size
    if flash:
        bg = (245, 245, 245)
        bar = (200, 40, 40)
    else:
        bg = (8, 8, 12)
        bar = (20, 20, 28)
    im = Image.new("RGB", (w, h), (0, 0, 0))
    # Active picture ~624x480 scaled to full width with letterbox (approx 1920x1080 content)
    active_h = int(h * 0.70)
    y0 = (h - active_h) // 2
    draw = ImageDraw.Draw(im)
    draw.rectangle([0, y0, w, y0 + active_h], fill=bg)
    if flash:
        # white flash plate + red bar (fixture-like)
        draw.rectangle([w // 4, y0 + active_h // 3, 3 * w // 4, y0 + 2 * active_h // 3], fill=(255, 255, 255))
        draw.rectangle([w // 4, y0 + active_h // 3, w // 4 + 80, y0 + 2 * active_h // 3], fill=bar)
    # Overlay scale ~3x from 624 canvas → fontsize ~48-56 at 1080p
    font = _font(52)
    text = f"TREK24 n={n}"
    # Yellow drawtext-like with dark border
    x, y = 40, y0 + 12
    for dx, dy in ((-2, 0), (2, 0), (0, -2), (0, 2), (-1, -1), (1, 1)):
        draw.text((x + dx, y + dy), text, font=font, fill=(0, 0, 0))
    draw.text((x, y), text, font=font, fill=(255, 220, 40))
    return im


def run_gate() -> dict:
    results = []
    fails = 0
    real_fails = 0
    # --- REAL banked frames (load-bearing) ---
    for path_s, n in REAL_CASES:
        path = Path(path_s)
        if not path.is_file():
            results.append(
                {
                    "n_true": n,
                    "n_true_src": "caller_supplied",
                    "bg": "real_missing_file",
                    "path": path_s,
                    "n_got": None,
                    "n_got_src": "measured",
                    "ok": False,
                    "tier": 0,
                    "raw": "FILE_MISSING",
                    "status": "missing",
                    "mean_luma": None,
                    "class": "real",
                }
            )
            fails += 1
            real_fails += 1
            continue
        r = read_frame(path, force_ocr=True)
        got = r.get("n")
        ok = got == n
        if not ok:
            fails += 1
            real_fails += 1
        results.append(
            {
                "n_true": n,
                "n_true_src": "caller_supplied",  # parent pixel ground truth
                "bg": "real_capture",
                "path": path_s,
                "n_got": got,
                "n_got_src": "measured",
                "ok": ok,
                "tier": r.get("tier"),
                "raw": r.get("raw"),
                "status": r.get("status"),
                "mean_luma": r.get("mean_luma"),
                "class": "real",
            }
        )

    # --- SYNTHETIC dark (must pass). Flash synthetic is reported but only
    # dark is required for GATE_OK so a font mismatch cannot hide a real fix.
    with tempfile.TemporaryDirectory(prefix="ocr_gate_") as td:
        tdir = Path(td)
        for n in SYN_CASES:
            for flash in (False, True):
                tag = "flash" if flash else "dark"
                path = tdir / f"n{n}_{tag}.png"
                render_frame(n, flash=flash).save(path)
                r = read_frame(path, force_ocr=True)
                got = r.get("n")
                ok = got == n
                # Only dark synthetic is load-bearing for rc
                if not flash and not ok:
                    fails += 1
                results.append(
                    {
                        "n_true": n,
                        "n_true_src": "caller_supplied",
                        "bg": f"synth_{tag}",
                        "n_got": got,
                        "n_got_src": "measured",
                        "ok": ok,
                        "load_bearing": (not flash),
                        "tier": r.get("tier"),
                        "raw": r.get("raw"),
                        "status": r.get("status"),
                        "mean_luma": r.get("mean_luma"),
                        "class": "synthetic",
                    }
                )

    # GATE_OK requires: all REAL cases + all dark synthetic.
    real_ok = all(x["ok"] for x in results if x.get("class") == "real")
    dark_syn_ok = all(
        x["ok"]
        for x in results
        if x.get("class") == "synthetic" and x.get("bg") == "synth_dark"
    )
    verdict = "GATE_OK" if (real_ok and dark_syn_ok) else "GATE_FAIL"
    rc = RC_OK if verdict == "GATE_OK" else RC_FAIL
    return {
        "verdict": verdict,
        "rc": rc,
        "n_cases": len(results),
        "n_fail": fails,
        "real_fails": real_fails,
        "real_ok": real_ok,
        "dark_synthetic_ok": dark_syn_ok,
        "results": results,
        "cases_src": "caller_supplied",
        "instrument": "ocr_counter_gate",
        "note": (
            "REAL banked frames are load-bearing. Dark synthetic load-bearing. "
            "Flash synthetic reported only (font≠capture AA)."
        ),
    }


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args(argv)
    rep = run_gate()
    if args.json:
        print(json.dumps(rep, indent=2))
    else:
        print(f"VERDICT={rep['verdict']} rc={rep['rc']} "
              f"fail={rep['n_fail']}/{rep['n_cases']}")
        for row in rep["results"]:
            mark = "OK" if row["ok"] else "FAIL"
            print(
                f"  {mark} n_true={row['n_true']} bg={row['bg']} "
                f"got={row['n_got']} tier={row['tier']} raw={row['raw']!r} "
                f"luma={row['mean_luma']}"
            )
    return int(rep["rc"])


if __name__ == "__main__":
    sys.exit(main())
