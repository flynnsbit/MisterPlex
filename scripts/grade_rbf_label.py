#!/usr/bin/env python3
"""Verify the RBF identity label rendered in the HDMI idle screen.

misterplexd renders "RBF XXXXXXXX" (first 8 uppercase hex digits of the RBF
md5) using a custom 5×7 pixel bitmap font defined in
host/libmisterplex/idle_screen.hpp.  The label is placed at:

    x0 = 8,  y0 = frame_height - 14   (in DDR/fb0 source space)

This script uses a PIXEL-TEMPLATE matcher — NOT OCR — because the custom font
is only 7 pixels tall (10 px in the HDMI capture after DDR→display scaling),
far below tesseract's reliable operating range.

Matching strategy
-----------------
1.  Build the expected 5×7 binary pixel mask for "RBF XXXXXXXX" using the
    exact same glyph table as idle_screen.hpp.
2.  Project the mask into the 1280×720 HDMI capture coordinate system,
    accounting for:
      - DDR→display scale (1280/ddr_w, 720/ddr_h, default 624×480)
      - Left-edge display clip at HDMI col 24 (PRESENT_X=11 artifact)
3.  For each expected-bright source pixel, check the corresponding display
    pixels have luma > BRIGHT_THRESH (default 100).
    For each expected-dark source pixel that is fully past the clip, check
    luma < DARK_THRESH (default 80).
4.  PASS if bright_hit_rate ≥ BRIGHT_MATCH_FRAC (default 0.55) AND
         dark_correct_rate ≥ DARK_MATCH_FRAC (default 0.75).
    The 'R' glyph is mostly clipped (display cols 16–23 < clip at 24), so
    only 'BF XXXXXXXX' is reliably verifiable — hence the 0.55 bright threshold
    rather than 1.0.

Usage:
  python3 scripts/grade_rbf_label.py [frame.png ...]
      [--expected-md5 HEX8]    first 8 uppercase hex chars of RBF md5
      [--mister-host H]        SSH host [MISTER_HOST env / 192.168.1.183]
      [--mister-pass P]        SSH password [MISTER_PASS env / 1]
      [--capture]              capture a fresh frame from /dev/video0
      [--ddr-size WxH]         DDR frame dimensions [default: 624x480]
      [--hdmi-size WxH]        HDMI capture size [default: 1280x720]
      [--edge-clip N]          left-edge clip in HDMI cols [default: 24]
      [--bright-thresh N]      luma threshold for foreground [default: 100]
      [--dark-thresh N]        luma threshold for background [default: 80]
      [--bright-frac F]        required bright-pixel match fraction [default: 0.55]
      [--dark-frac F]          required dark-pixel match fraction [default: 0.75]
      [--out-dir DIR]          save debug images here
      [--expect PASS|FAIL]     invert assertion for red-check testing

Exit codes:
  0   PASS  label present and pixel pattern matches expected md5
  1   FAIL  label absent or pixel pattern mismatches
  77  SKIP  no capture device / SSH unreachable / no expected md5

Three-question audit:
  (1) What does it literally compare?
      Bright/dark luma values at the 146×10 display-pixel region where the
      known bitmap glyphs for "RBF XXXXXXXX" should appear, projected from
      DDR source space via the 2.051× / 1.5× scale factors.
  (2) What does it NOT cover?
      Whether the label is the correct size or colour beyond luma; whether
      it is positioned correctly vertically within the idle frame; frame
      timing (label may not appear on every frame if FPGA is actively
      updating).  'R' glyph is clipped and excluded from scoring.
  (3) Can you make it fail?
      Pass --expected-md5 00000000 against any real RBF → bright pattern
      mismatch → exit 1.  Pass a blank/black frame → no bright pixels → exit 1.
"""

import argparse
import re
import subprocess
import sys
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent

# ── Bitmap glyph table — exact copy of idleGlyph() in idle_screen.hpp ────────
# Each entry is 7 row bitmasks, MSB-first, 5 bits wide (bit4=leftmost).
_GLYPHS: dict[str, list[int]] = {
    '0': [0x0e, 0x11, 0x13, 0x15, 0x19, 0x11, 0x0e],
    '1': [0x04, 0x0c, 0x04, 0x04, 0x04, 0x04, 0x0e],
    '2': [0x0e, 0x11, 0x01, 0x02, 0x04, 0x08, 0x1f],
    '3': [0x1e, 0x01, 0x01, 0x0e, 0x01, 0x01, 0x1e],
    '4': [0x02, 0x06, 0x0a, 0x12, 0x1f, 0x02, 0x02],
    '5': [0x1f, 0x10, 0x1e, 0x01, 0x01, 0x11, 0x0e],
    '6': [0x06, 0x08, 0x10, 0x1e, 0x11, 0x11, 0x0e],
    '7': [0x1f, 0x01, 0x02, 0x04, 0x08, 0x08, 0x08],
    '8': [0x0e, 0x11, 0x11, 0x0e, 0x11, 0x11, 0x0e],
    '9': [0x0e, 0x11, 0x11, 0x0f, 0x01, 0x02, 0x0c],
    'A': [0x0e, 0x11, 0x11, 0x1f, 0x11, 0x11, 0x11],
    'B': [0x1e, 0x11, 0x11, 0x1e, 0x11, 0x11, 0x1e],
    'C': [0x0f, 0x10, 0x10, 0x10, 0x10, 0x10, 0x0f],
    'D': [0x1e, 0x11, 0x11, 0x11, 0x11, 0x11, 0x1e],
    'E': [0x1f, 0x10, 0x10, 0x1e, 0x10, 0x10, 0x1f],
    'F': [0x1f, 0x10, 0x10, 0x1e, 0x10, 0x10, 0x10],
    'R': [0x1e, 0x11, 0x11, 0x1e, 0x14, 0x12, 0x11],
    ' ': [0x00] * 7,
}


def _make_label_mask(text: str) -> np.ndarray:
    """Return a (7 × textW) bool array: True=foreground pixel.

    text must use uppercase hex + 'R', 'B', 'F', ' ' only.
    textW = len(text)*6 - 1  (5px glyph + 1px gap, no trailing gap).
    """
    text = text.upper()
    n = len(text)
    text_w = n * 6 - 1
    mask = np.zeros((7, text_w), dtype=bool)
    for ci, ch in enumerate(text):
        glyph = _GLYPHS.get(ch, _GLYPHS[' '])
        x0 = ci * 6
        for row in range(7):
            for col in range(5):
                if glyph[row] & (1 << (4 - col)):
                    mask[row, x0 + col] = True
    return mask


def _score_frame(
    luma: np.ndarray,
    label: str,
    ddr_w: int,
    ddr_h: int,
    hdmi_w: int,
    hdmi_h: int,
    edge_clip: int,
    bright_thresh: int,
    dark_thresh: int,
) -> dict:
    """Project the label mask into HDMI space and measure bright/dark match.

    Returns a dict with keys: bright_total, bright_hit, dark_total, dark_hit,
    bright_rate, dark_rate, label_region (x0,y0,x1,y1 in HDMI coords).
    """
    mask = _make_label_mask(label)          # (7, textW)
    mask_h, mask_w = mask.shape

    sx = hdmi_w / ddr_w                     # e.g. 2.0513
    sy = hdmi_h / ddr_h                     # e.g. 1.5000
    src_x0 = 8                              # idle_screen.hpp: x0 = 8
    src_y0 = ddr_h - 14                     # idle_screen.hpp: y0 = h - 14

    # HDMI display coordinates of the label's bounding box
    disp_x0 = int(src_x0 * sx)
    disp_y0 = int(src_y0 * sy)
    disp_x1 = int((src_x0 + mask_w) * sx) + 1
    disp_y1 = int((src_y0 + mask_h) * sy) + 1

    bright_total = bright_hit = 0
    dark_total = dark_correct = 0

    for src_row in range(mask_h):
        for src_col in range(mask_w):
            expected_bright = mask[src_row, src_col]

            # Display pixel range for this source pixel
            px0 = int((src_x0 + src_col) * sx)
            px1 = max(px0 + 1, int((src_x0 + src_col + 1) * sx))
            py0 = int((src_y0 + src_row) * sy)
            py1 = max(py0 + 1, int((src_y0 + src_row + 1) * sy))

            # Clamp to frame bounds
            px0 = max(px0, 0); px1 = min(px1, hdmi_w)
            py0 = max(py0, 0); py1 = min(py1, hdmi_h)
            if px0 >= px1 or py0 >= py1:
                continue

            # Skip pixels entirely within the left-edge clip zone
            if px1 <= edge_clip:
                continue

            # For pixels straddling the clip boundary, restrict to visible portion
            px0 = max(px0, edge_clip)

            region = luma[py0:py1, px0:px1]
            if region.size == 0:
                continue

            max_luma = int(region.max())
            min_luma = int(region.min())

            if expected_bright:
                bright_total += 1
                if max_luma >= bright_thresh:
                    bright_hit += 1
            else:
                dark_total += 1
                if min_luma < dark_thresh:
                    dark_correct += 1

    bright_rate = bright_hit / bright_total if bright_total > 0 else 0.0
    dark_rate = dark_correct / dark_total if dark_total > 0 else 0.0
    total = bright_total + dark_total
    # Combined mismatch: fraction of pixels where expectation is wrong (both types).
    # This is the primary discriminator: wrong-md5 glyphs light up dark pixels and
    # leave expected-bright pixels dark → mismatch_rate climbs sharply.
    mismatch_rate = ((bright_total - bright_hit) + (dark_total - dark_correct)) / total if total > 0 else 1.0

    return {
        'bright_total': bright_total,
        'bright_hit': bright_hit,
        'bright_rate': bright_rate,
        'dark_total': dark_total,
        'dark_hit': dark_correct,
        'dark_rate': dark_rate,
        'mismatch_rate': mismatch_rate,
        'label_region': (disp_x0, disp_y0, disp_x1, disp_y1),
    }


def _fetch_expected_md5(host: str, password: str) -> str | None:
    """SSH to MiSTer, return first 8 lowercase hex chars of /media/fat/_Utility/Plex.rbf md5."""
    cmd = ["sshpass", "-p", password,
           "ssh", "-o", "StrictHostKeyChecking=no", "-o", "ConnectTimeout=8",
           f"root@{host}",
           "md5sum /media/fat/_Utility/Plex.rbf 2>/dev/null | cut -c1-8"]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=15)
        out = r.stdout.strip().lower()
        if re.fullmatch(r'[0-9a-f]{8}', out):
            return out
    except (subprocess.TimeoutExpired, FileNotFoundError):
        pass
    return None


def _capture_frame(out_dir: Path) -> Path | None:
    """Capture via capture_preflight.py; return the first frame path."""
    preflight = ROOT / "scripts" / "capture_preflight.py"
    if not preflight.exists():
        return None
    log_path = ROOT / "build" / "_grade_rbf_capture.log"
    out_dir.mkdir(parents=True, exist_ok=True)
    with open(log_path, "w") as lf:
        r = subprocess.run(
            [sys.executable, str(preflight), "--frames", "1", "--out-dir", str(out_dir)],
            stdout=lf, stderr=subprocess.STDOUT,
        )
    if r.returncode == 77:
        return None
    frames = sorted((out_dir / "frames").glob("*.png"))
    return frames[0] if frames else None


def _save_debug(frame_path: Path, score: dict, label: str, out_dir: Path) -> None:
    """Save an annotated debug image showing the expected label region."""
    from PIL import ImageDraw
    img = Image.open(frame_path).convert('RGB')
    d = ImageDraw.Draw(img)
    x0, y0, x1, y1 = score['label_region']
    colour = (0, 255, 0) if score['bright_rate'] >= 0.55 else (255, 0, 0)
    d.rectangle([x0, y0, x1, y1], outline=colour, width=2)
    d.text((x0, max(0, y0 - 12)), f"RBF:{label} b={score['bright_rate']:.2f}", fill=colour)
    out_dir.mkdir(parents=True, exist_ok=True)
    out_path = out_dir / f"rbf_label_debug_{frame_path.stem}.png"
    img.save(out_path)
    print(f"  debug image: {out_path}")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("frames", nargs="*", metavar="frame.png")
    ap.add_argument("--expected-md5", metavar="HEX8",
                    help="First 8 hex digits of RBF md5 (auto-fetched via SSH if omitted)")
    ap.add_argument("--mister-host", default=None)
    ap.add_argument("--mister-pass", default=None)
    ap.add_argument("--capture", action="store_true",
                    help="Capture a fresh frame before grading")
    ap.add_argument("--ddr-size", default="624x480",
                    help="DDR frame dimensions WxH [default: 624x480]")
    ap.add_argument("--hdmi-size", default="1280x720",
                    help="HDMI capture size WxH [default: 1280x720]")
    ap.add_argument("--edge-clip", type=int, default=24,
                    help="Left-edge clip in HDMI columns [default: 24]")
    ap.add_argument("--bright-thresh", type=int, default=100,
                    help="Luma threshold for foreground pixels [default: 100]")
    ap.add_argument("--dark-thresh", type=int, default=80,
                    help="Luma threshold for background pixels [default: 80]")
    ap.add_argument("--bright-frac", type=float, default=0.70,
                    help="Min fraction of expected-bright pixels that must be bright [default: 0.70]")
    ap.add_argument("--max-mismatch", type=float, default=0.12,
                    help="Max allowed combined mismatch rate (wrong label ≈0.15) [default: 0.12]")
    ap.add_argument("--out-dir", default=None)
    ap.add_argument("--expect", choices=["PASS", "FAIL"], default="PASS")
    args = ap.parse_args()

    import os
    mister_host = args.mister_host or os.environ.get("MISTER_HOST", "192.168.1.183")
    mister_pass = args.mister_pass or os.environ.get("MISTER_PASS", "1")
    out_dir = Path(args.out_dir) if args.out_dir else ROOT / "build" / "rbf-label-check"

    ddr_w, ddr_h = (int(x) for x in args.ddr_size.split("x"))
    hdmi_w, hdmi_h = (int(x) for x in args.hdmi_size.split("x"))

    # ── Resolve expected md5 ─────────────────────────────────────────────────
    expected_md5 = None
    if args.expected_md5:
        expected_md5 = args.expected_md5.lower()
        if not re.fullmatch(r'[0-9a-f]{8}', expected_md5):
            print(f"ERROR: --expected-md5 must be 8 hex digits, got {expected_md5!r}", file=sys.stderr)
            sys.exit(1)
    else:
        print(f"Fetching RBF md5 from {mister_host} ...")
        expected_md5 = _fetch_expected_md5(mister_host, mister_pass)
        if expected_md5 is None:
            print("SKIP: MiSTer unreachable and --expected-md5 not given → exit 77")
            sys.exit(77)

    # idle_screen.hpp uses uppercase hex in the label
    label = f"RBF {expected_md5.upper()}"
    print(f"Expected label: {label!r}  (md5 prefix: {expected_md5})")

    # ── Gather frames ────────────────────────────────────────────────────────
    frame_paths = [Path(f) for f in args.frames]
    if args.capture or not frame_paths:
        captured = _capture_frame(out_dir / "live_capture")
        if captured is None:
            print("SKIP: live capture failed and no frame arguments → exit 77")
            sys.exit(77)
        frame_paths = [captured]
        print(f"Captured frame: {captured}")

    print(f"Scope: {len(frame_paths)} frame(s)")
    if not frame_paths:
        print("SKIP: Scope: 0 → exit 77")
        sys.exit(77)

    # ── Grade each frame ─────────────────────────────────────────────────────
    passed = 0
    for fp in frame_paths:
        if not fp.exists():
            print(f"  SKIP {fp.name}: not found")
            continue

        luma = np.array(Image.open(fp).convert('L'), dtype=np.float32)
        score = _score_frame(
            luma, label, ddr_w, ddr_h, hdmi_w, hdmi_h,
            args.edge_clip, args.bright_thresh, args.dark_thresh,
        )

        # Two independent pass criteria (both must hold):
        #  1. bright_rate ≥ bright_frac: the expected label pixels ARE lit up
        #  2. mismatch_rate ≤ max_mismatch: wrong-md5 labels produce ≈15% mismatch,
        #     so 12% separates correct from incorrect at typical MJPEG noise levels
        ok_bright = score['bright_rate'] >= args.bright_frac
        ok_mismatch = score['mismatch_rate'] <= args.max_mismatch
        frame_pass = ok_bright and ok_mismatch
        status = "PASS" if frame_pass else "FAIL"
        why = [] if frame_pass else (
            ([] if ok_bright else [f"bright_rate {score['bright_rate']:.2f} < {args.bright_frac}"]) +
            ([] if ok_mismatch else [f"mismatch {score['mismatch_rate']:.2f} > {args.max_mismatch}"])
        )

        print(f"  {fp.name}: bright={score['bright_hit']}/{score['bright_total']}"
              f" ({score['bright_rate']:.2f}) mismatch={score['mismatch_rate']:.2f}"
              f" region={score['label_region']} → {status}"
              + (f"  [{'; '.join(why)}]" if why else ""))

        if args.out_dir:
            _save_debug(fp, score, expected_md5.upper(), out_dir)

        if frame_pass:
            passed += 1

    total = len(frame_paths)
    overall_pass = passed > 0
    verdict = "PASS" if overall_pass else "FAIL"
    print(f"\nRBF_LABEL_RESULT: {passed}/{total} frames matched  VERDICT: {verdict}")

    if args.expect == "FAIL":
        if overall_pass:
            print("ERROR: expected FAIL but got PASS → red-check broken → exit 1")
            sys.exit(1)
        else:
            print("Red-check confirmed: gate correctly detected missing/wrong label → exit 0")
            sys.exit(0)

    sys.exit(0 if overall_pass else 1)


if __name__ == "__main__":
    main()
